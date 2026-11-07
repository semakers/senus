// Transporte USB al bootloader propio de senew y a su primo el installer.
//
// Dos protocolos muy pequeños, los dos sobre EP0 con vendor requests:
//
//   BL propio      : VID:PID 0x1209:0x0002 (plat/bl, documentado por pu_bl.py)
//   BL installer   : VID:PID 0x1209:0x0003 (plat/bl variante que escribe también
//                                           la zona 0x44140000..0x44180000 del
//                                           propio BL antes de rebotar a senew)
//
// Las dos variantes hablan el mismo juego de vendor requests (0xD0..0xDB) y
// el mismo juego de operaciones GO (NADA/WIPE/WRITE/CRC/SALIR) + 1 extra para
// el installer (WRITE_PROPIO). Lo que cambia es el PID y qué direcciones
// aceptan: el BL propio solo graba 0x44180000..0x443C0000 (el main); el
// installer, además, 0x44140000..0x44180000 (el BL propio) y la zona del
// W6FS (0x44400000+).
//
// Diseño: dos implementaciones, misma interfaz [TransporteBl]:
//
//   TransporteBlLibusb : producción, control transfers de libusb de verdad.
//   TransporteBlSocket : simulación, habla con bridge_mock.py --installer
//                        por el mismo socket Unix (nuevos marcos 'C'/'X').
//
// La elección vive en una variable de entorno paralela a SENUS_TRANSPORTE,
// para que el modo SIMULADO del installer se pueda activar sin tocar el MTP
// que ya está cableado para el teléfono «normal» (fase 1b):
//
//   SENUS_BL_TRANSPORTE=socket:/ruta/al/socket  → socket (bridge_mock)
//   SENUS_BL_TRANSPORTE=emu:/ruta               → el W580 en QEMU
//   SENUS_BL_TRANSPORTE=libusb                  → libusb (si está)
//   SENUS_BL_TRANSPORTE no fijado               → se mira SENUS_TRANSPORTE
//                                                 (si es socket:…, socket;
//                                                 si no, libusb).
//
// El WRITE por este camino se probó en silicio el 30-oct-2026 contra el BL
// installer. El teléfono no distingue el host: es EP0 estándar.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../mtp/libusb_bindings.dart';
import '../mtp/transporte.dart'
    show DispositivoVisto, TransporteError;
import '../mtp/transporte_emu.dart' show TransporteBlEmu;

// --- Constantes del protocolo del BL (coherentes con pu_bl.py y bl.h) ----

const int vidSenew = 0x1209;

/// senew en marcha, modo MTP (fase 1b): a quien le hablamos cuando ya está
/// instalado. Lo exporta este fichero para que pant_installar_inicial espere
/// por él al final del flujo sin tener que importar transporte.dart.
const int pidSenewNormal = 0x0001;

/// BL propio «de iteración» (pu.py bootloader lo arranca). No lo usa el
/// installer, pero se queda la constante aquí para auditoría cruzada.
const int pidBlPropio = 0x0002;

/// BL del installer de primera instalación (lo que estamos cableando).
/// Mismo juego de vendor requests que [pidBlPropio] + WRITE_PROPIO.
const int pidBlInstaller = 0x0003;

// Vendor requests (bRequest). Lo mismo que `BL_R_*` en bl.h / pu_bl.py.
const int blRId = 0xD0;
const int blRRes = 0xD1;
const int blRPut = 0xD2;
const int blRArg0 = 0xD3;
const int blRArg1 = 0xD4;
const int blRArg2 = 0xD5;
const int blRArg3 = 0xD6;
const int blRCur = 0xD7;
const int blRGo = 0xD8;
const int blRPoke = 0xD9;
const int blRGet = 0xDB;

// Operaciones (el u8 bajo de wValue en BL_R_GO). Lo mismo que `BL_OP_*`.
const int blOpNada = 0;
const int blOpWipe = 1;
const int blOpWrite = 2;
const int blOpCrc = 3;
const int blOpSalir = 4;
const int blOpRamw = 5;                // ya existente en el BL clásico (no colisionar)
const int blOpIr = 6;                  // ya existente en el BL clásico

/// Operaciones del BL del installer (fuera del rango denso del clásico, por eso
/// empiezan en 0xD4). Confirmadas contra `plat/bl/bl.h` de la rama
/// `bl-installer` en `senew-w580` el 29-oct-2026:
///   BL_OP_WRITE_PROPIO = 0xD4 — igual que WRITE pero el rango permitido se
///       amplía a [BL_INI, MAIN_FIN) (acepta reescribir el propio BL).
///   BL_OP_INSTALADOR_INI = 0xD5 — arg0 = total declarado en bytes; pone el
///       estado del instalador a (0 de total) y repinta la barra.
///   BL_OP_LISTO = 0xD6 — pinta «Listo. Reinicia.» y bloquea el bucle.
///   BL_OP_WIPE_PROPIO = 0xD7 — borra un bloque de 256 KiB en [BL_INI,
///       MAIN_FIN) (hace falta antes de WRITE_PROPIO sobre bloque con datos).
const int blOpWritePropio = 0xD4;
const int blOpInstaladorIni = 0xD5;
const int blOpListo = 0xD6;
const int blOpWipePropio = 0xD7;

/// Estados de la máquina de ejecución del BL (campo `estado` del RES).
const int blStLibre = 0;
const int blStPendiente = 1;
const int blStEjecutando = 2;
const int blStHecho = 3;

/// Geometría del main en el W580. Se usan como fallback cuando el BL todavía
/// no se ha identificado (p. ej. para montar la secuencia de WIPE antes de
/// pedir [TransporteBl.id]).
const int blMainIni = 0x44180000;
const int blMainFin = 0x443C0000;

/// Geometría del BL propio en el W580. Lo que WRITE_PROPIO sobrescribe.
const int blPropioIni = 0x44140000;
const int blPropioFin = 0x44180000;

/// Mínimo del W6FS (hwo_w6fs de plat/hw_w580.c): si el main es pequeño, el
/// W6FS está EXACTAMENTE aquí; si es grande, en el primer MiB libre tras
/// él, pero nunca por debajo de este valor.
const int w6fsIniMin = 0x44400000;

const int blBloque = 0x40000;
const int blRegion = 0x400;
const int blBufTam = 4096;

// --- bRequestType ---------------------------------------------------------
//
// Vendor + interface, EP0. Lo que usa pu_bl.py (`d.ctrl_transfer(0x40, …)`).
// VENDOR + INTERFACE + OUT = 0x41; aquí seguimos lo que pyusb/libusb aceptan
// de hecho para «endpoint 0 vendor»: 0x40 OUT, 0xC0 IN. Si el BL del aparato
// resulta más estricto (REQ_RECIPIENT_INTERFACE), se cambian ambos aquí.

const int bmReqtypeVendorOut = 0x40;
const int bmReqtypeVendorIn = 0xC0;

// --------------------------------------------------------------------------
// Interfaz pública
// --------------------------------------------------------------------------

/// Interfaz común. Expone el mínimo que necesita [InstalacionInicial] (y
/// cualquier futura herramienta que hable con el BL): control IN/OUT por EP0.
abstract class TransporteBl {
  /// Nombre humano del transporte, para los errores.
  String get nombre;

  /// Enumera candidatos filtrados por VID/PID.
  Future<List<DispositivoVisto>> enumerar();

  /// Reserva el dispositivo. Después de esto se puede hacer `controlIn`/
  /// `controlOut`. Puede fallar con [TransporteError].
  Future<void> abrir(DispositivoVisto d);

  /// Libera el dispositivo.
  Future<void> cerrar();

  /// Control OUT (bmRequestType = 0x40). Timeout en milisegundos
  /// (los WIPE del BL son ~9 s; usar 30 s por omisión).
  Future<void> controlOut(int bRequest, int wValue, int wIndex, Uint8List data,
      {Duration timeout = const Duration(seconds: 30)});

  /// Control IN (bmRequestType = 0xC0). Devuelve `wLength` bytes recibidos
  /// (menos si el aparato devuelve corto).
  Future<Uint8List> controlIn(int bRequest, int wValue, int wIndex, int wLength,
      {Duration timeout = const Duration(seconds: 30)});

  /// VID/PID por los que esta instancia filtra. Útil para
  /// `esperarPuente()` sin repetir cada vez el filtro.
  int get vidFiltro;
  int get pidFiltro;

  /// Fábrica: elige entre libusb y socket según
  /// SENUS_BL_TRANSPORTE / SENUS_TRANSPORTE / plataforma.
  ///
  /// [fijarConfiguracion] false para hablar con un senew EN MARCHA por EP0 (el
  /// puente): repetirle `SET_CONFIGURATION` no hace falta y no se ha medido.
  static TransporteBl elegir(
      {required int vid, required int pid, bool fijarConfiguracion = true}) {
    final blEnv = Platform.environment['SENUS_BL_TRANSPORTE'] ?? '';
    final gnEnv = Platform.environment['SENUS_TRANSPORTE'] ?? '';
    final env = blEnv.isNotEmpty ? blEnv : gnEnv;
    if (env.startsWith('socket:')) {
      final ruta = env.substring('socket:'.length);
      return TransporteBlSocket(ruta, vid: vid, pid: pid);
    }
    if (env.startsWith('emu:')) {
      return TransporteBlEmu(env.substring('emu:'.length), vid: vid, pid: pid);
    }
    if (env == 'simulado') {
      // Marcador abstracto, útil para los tests que inyectan el transporte a
      // mano: elegir() nunca lo devuelve en silencio. Si llegas aquí es que
      // alguien lo pidió explícitamente.
      throw TransporteError(
          'SENUS_BL_TRANSPORTE=simulado: inyecta un transporte a mano '
          '(TransporteBlFalso en las pruebas) en lugar de usar `elegir()`.');
    }
    final lu = LibUsb.intenta();
    if (lu == null) {
      throw TransporteError(
        'No se encontró libusb-1.0 en el sistema. '
        'En macOS: `brew install libusb`. '
        'En Linux: `sudo dnf install libusb1`. '
        'En Windows: libusb-1.0.dll al lado del ejecutable.',
      );
    }
    return TransporteBlLibusb(lu,
        vid: vid, pid: pid, fijarConfiguracion: fijarConfiguracion);
  }
}

// --------------------------------------------------------------------------
// Transporte libusb (producción)
// --------------------------------------------------------------------------

class TransporteBlLibusb implements TransporteBl {
  final LibUsb lu;
  @override
  final int vidFiltro;
  @override
  final int pidFiltro;

  final bool fijarConfiguracion;

  Pointer<Void> _ctx = nullptr;
  Pointer<Void> _handle = nullptr;

  TransporteBlLibusb(this.lu,
      {required int vid, required int pid, this.fijarConfiguracion = true})
      : vidFiltro = vid,
        pidFiltro = pid {
    final ppCtx = calloc<Pointer<Void>>();
    final r = lu.init(ppCtx);
    if (r != libusbSuccess) {
      calloc.free(ppCtx);
      throw TransporteError('libusb_init falló', r);
    }
    _ctx = ppCtx.value;
    calloc.free(ppCtx);
  }

  @override
  String get nombre =>
      'libusb(${vidFiltro.toRadixString(16).padLeft(4, '0')}:'
      '${pidFiltro.toRadixString(16).padLeft(4, '0')})';

  @override
  Future<List<DispositivoVisto>> enumerar() async {
    final ppList = calloc<Pointer<Pointer<Void>>>();
    final n = lu.getDeviceList(_ctx, ppList);
    if (n < 0) {
      calloc.free(ppList);
      throw TransporteError('libusb_get_device_list falló', n);
    }
    final list = ppList.value;
    final descPtr = calloc<LibusbDeviceDescriptor>();
    final vistos = <DispositivoVisto>[];
    try {
      for (var i = 0; i < n; i++) {
        final dev = list[i];
        if (dev.address == 0) continue;
        if (lu.getDeviceDescriptor(dev, descPtr) != libusbSuccess) continue;
        final d = descPtr.ref;
        if (d.idVendor != vidFiltro || d.idProduct != pidFiltro) continue;
        vistos.add(DispositivoVisto(
          id: i,
          vid: d.idVendor,
          pid: d.idProduct,
          bcdDevice: d.bcdDevice,
          etiquetaFabricante: null,
          etiquetaProducto: null,
          etiquetaSerie: null,
        ));
      }
    } finally {
      lu.freeDeviceList(list, 0);
      calloc.free(descPtr);
      calloc.free(ppList);
    }
    return vistos;
  }

  @override
  Future<void> abrir(DispositivoVisto d) async {
    final ppList = calloc<Pointer<Pointer<Void>>>();
    final n = lu.getDeviceList(_ctx, ppList);
    if (n < 0) {
      calloc.free(ppList);
      throw TransporteError('libusb_get_device_list falló', n);
    }
    final list = ppList.value;
    final descPtr = calloc<LibusbDeviceDescriptor>();
    Pointer<Void> elegido = nullptr;
    try {
      for (var i = 0; i < n; i++) {
        final dev = list[i];
        if (dev.address == 0) continue;
        if (lu.getDeviceDescriptor(dev, descPtr) != libusbSuccess) continue;
        final dd = descPtr.ref;
        if (dd.idVendor != d.vid || dd.idProduct != d.pid) continue;
        elegido = dev;
        break;
      }
      if (elegido.address == 0) {
        throw TransporteError(
            'No se encontró el BL al abrirlo', libusbErrorNoDevice);
      }
      final ppH = calloc<Pointer<Void>>();
      final ro = lu.open(elegido, ppH);
      if (ro != libusbSuccess) {
        calloc.free(ppH);
        throw TransporteError('libusb_open falló (¿permisos?)', ro);
      }
      _handle = ppH.value;
      calloc.free(ppH);
    } finally {
      lu.freeDeviceList(list, 1);
      calloc.free(descPtr);
      calloc.free(ppList);
    }
    // El BL no exige claim_interface (los vendor requests van a EP0, no a
    // una interfaz MTP). Si libusb lo pide por sanidad (p. ej. en algún
    // Linux), que lo intente y siga adelante si falla.
    try {
      lu.setAutoDetachKernelDriver?.call(_handle, 1);
    } catch (_) {}
    // pu_bl_installer.py hace `d.set_configuration()` dentro de un
    // try/except que se traga el error, y así se probó en silicio el
    // 2026-10-30. Igual aquí: si el aparato ya estaba configurado, o macOS no
    // deja, no pasa nada.
    if (fijarConfiguracion) {
      try {
        lu.setConfiguration(_handle, 1);
      } catch (_) {}
    }
  }

  @override
  Future<void> cerrar() async {
    if (_handle.address != 0) {
      lu.close(_handle);
      _handle = nullptr;
    }
  }

  @override
  Future<void> controlOut(
      int bRequest, int wValue, int wIndex, Uint8List data,
      {Duration timeout = const Duration(seconds: 30)}) async {
    if (_handle.address == 0) throw TransporteError('Transporte BL cerrado');
    if (data.length > 0xFFFF) {
      throw TransporteError(
          'controlOut: wLength no puede pasar de 0xFFFF (${data.length})');
    }
    final buf = calloc<Uint8>(data.isEmpty ? 1 : data.length);
    try {
      if (data.isNotEmpty) buf.asTypedList(data.length).setAll(0, data);
      final r = lu.controlTransfer(
        _handle,
        bmReqtypeVendorOut,
        bRequest,
        wValue & 0xFFFF,
        wIndex & 0xFFFF,
        buf,
        data.length,
        timeout.inMilliseconds,
      );
      if (r < 0) {
        throw TransporteError(
            'controlOut req=0x${bRequest.toRadixString(16)}: ${lu.mensaje(r)}',
            r);
      }
    } finally {
      calloc.free(buf);
    }
  }

  @override
  Future<Uint8List> controlIn(
      int bRequest, int wValue, int wIndex, int wLength,
      {Duration timeout = const Duration(seconds: 30)}) async {
    if (_handle.address == 0) throw TransporteError('Transporte BL cerrado');
    if (wLength > 0xFFFF) {
      throw TransporteError(
          'controlIn: wLength no puede pasar de 0xFFFF ($wLength)');
    }
    final buf = calloc<Uint8>(wLength == 0 ? 1 : wLength);
    try {
      final r = lu.controlTransfer(
        _handle,
        bmReqtypeVendorIn,
        bRequest,
        wValue & 0xFFFF,
        wIndex & 0xFFFF,
        buf,
        wLength,
        timeout.inMilliseconds,
      );
      if (r < 0) {
        throw TransporteError(
            'controlIn req=0x${bRequest.toRadixString(16)}: ${lu.mensaje(r)}',
            r);
      }
      return Uint8List.fromList(buf.asTypedList(r));
    } finally {
      calloc.free(buf);
    }
  }
}

// --------------------------------------------------------------------------
// Transporte socket (simulación: bridge_mock.py --installer)
// --------------------------------------------------------------------------
//
// Protocolo del socket, extensión del que ya usa el responder MTP:
//
//   OUT control: 'C' | u8 bmRequestType | u8 bRequest
//                    | u16 LE wValue | u16 LE wIndex
//                    | u32 LE wLength | wLength bytes
//
//   IN  control: 'X' | u8 bmRequestType | u8 bRequest
//                    | u16 LE wValue | u16 LE wIndex
//                    | u16 LE wLength
//                → respuesta: 'E' | u32 LE n | n bytes
//
// Se usan letras distintas a 'O'/'I'/'D' para que el mismo bridge pueda
// atender a la vez la cara MTP del aparato y la cara BL/installer; cuál
// toca lo decide bridge_mock al arrancar (`--installer`).

class TransporteBlSocket implements TransporteBl {
  final String rutaSocket;
  @override
  final int vidFiltro;
  @override
  final int pidFiltro;

  Socket? _s;
  final List<int> _bufRx = <int>[];
  final List<_EsperaBytes> _esperas = [];

  TransporteBlSocket(this.rutaSocket, {required int vid, required int pid})
      : vidFiltro = vid,
        pidFiltro = pid;

  @override
  String get nombre =>
      'socket:$rutaSocket(${vidFiltro.toRadixString(16).padLeft(4, '0')}:'
      '${pidFiltro.toRadixString(16).padLeft(4, '0')})';

  void _procesaPendientes() {
    while (_esperas.isNotEmpty && _bufRx.length >= _esperas.first.n) {
      final e = _esperas.removeAt(0);
      if (!e.c.isCompleted) e.c.complete();
    }
  }

  @override
  Future<List<DispositivoVisto>> enumerar() async {
    try {
      final s = await Socket.connect(
        InternetAddress(rutaSocket, type: InternetAddressType.unix),
        0,
      );
      await s.close();
    } catch (_) {
      return [];
    }
    // El bridge responde SIEMPRE con el VID/PID que le pedimos: la pantalla
    // de SENUS filtra por él como si fuera libusb. Si el bridge está en
    // modo MTP y nosotros preguntamos por installer (o al revés), su
    // respuesta a cualquier `controlIn` será un error, y lo veremos arriba.
    return [
      DispositivoVisto(
        id: 0,
        vid: vidFiltro,
        pid: pidFiltro,
        bcdDevice: 0x0013,
        etiquetaFabricante: 'Semakers (mock BL)',
        etiquetaProducto: 'BL installer simulado',
        etiquetaSerie: 'W580S10000001',
      )
    ];
  }

  @override
  Future<void> abrir(DispositivoVisto d) async {
    _s = await Socket.connect(
      InternetAddress(rutaSocket, type: InternetAddressType.unix),
      0,
    );
    _s!.listen((chunk) {
      _bufRx.addAll(chunk);
      _procesaPendientes();
    }, onDone: () {
      for (final e in _esperas) {
        if (!e.c.isCompleted) e.c.completeError(TransporteError('bridge cerró'));
      }
      _esperas.clear();
    });
  }

  @override
  Future<void> cerrar() async {
    try {
      await _s?.close();
    } catch (_) {}
    _s = null;
    _bufRx.clear();
  }

  Future<void> _leerAlMenos(int n, Duration timeout) async {
    if (_bufRx.length >= n) return;
    final e = _EsperaBytes(n);
    _esperas.add(e);
    try {
      await e.c.future.timeout(timeout);
    } on TimeoutException {
      _esperas.remove(e);
      throw TransporteError('timeout leyendo del bridge', libusbErrorTimeout);
    }
  }

  @override
  Future<void> controlOut(
      int bRequest, int wValue, int wIndex, Uint8List data,
      {Duration timeout = const Duration(seconds: 30)}) async {
    final s = _s;
    if (s == null) throw TransporteError('socket no abierto');
    final cab = ByteData(11);
    cab.setUint8(0, 'C'.codeUnitAt(0));
    cab.setUint8(1, bmReqtypeVendorOut);
    cab.setUint8(2, bRequest & 0xFF);
    cab.setUint16(3, wValue & 0xFFFF, Endian.little);
    cab.setUint16(5, wIndex & 0xFFFF, Endian.little);
    cab.setUint32(7, data.length, Endian.little);
    s.add(cab.buffer.asUint8List());
    if (data.isNotEmpty) s.add(data);
    await s.flush();
  }

  @override
  Future<Uint8List> controlIn(
      int bRequest, int wValue, int wIndex, int wLength,
      {Duration timeout = const Duration(seconds: 30)}) async {
    final s = _s;
    if (s == null) throw TransporteError('socket no abierto');
    final cab = ByteData(9);
    cab.setUint8(0, 'X'.codeUnitAt(0));
    cab.setUint8(1, bmReqtypeVendorIn);
    cab.setUint8(2, bRequest & 0xFF);
    cab.setUint16(3, wValue & 0xFFFF, Endian.little);
    cab.setUint16(5, wIndex & 0xFFFF, Endian.little);
    cab.setUint16(7, wLength & 0xFFFF, Endian.little);
    s.add(cab.buffer.asUint8List());
    await s.flush();

    await _leerAlMenos(5, timeout);
    final tipo = _bufRx[0];
    if (tipo != 'E'.codeUnitAt(0)) {
      _bufRx.removeRange(0, 1);
      throw TransporteError('respuesta mala del bridge (tipo=$tipo)');
    }
    final nbd = ByteData(4)
      ..buffer.asUint8List().setRange(0, 4, _bufRx.sublist(1, 5));
    final n = nbd.getUint32(0, Endian.little);
    _bufRx.removeRange(0, 5);
    if (n > 0) {
      await _leerAlMenos(n, timeout);
    }
    final out = n == 0 ? Uint8List(0) : Uint8List.fromList(_bufRx.sublist(0, n));
    if (n > 0) _bufRx.removeRange(0, n);
    return out;
  }
}

class _EsperaBytes {
  final int n;
  final Completer<void> c = Completer<void>();
  _EsperaBytes(this.n);
}

// --------------------------------------------------------------------------
// Transporte falso (inyectable para pruebas)
// --------------------------------------------------------------------------

/// Modela un BL en RAM: una «BUF» de 4 KiB y un GO que atiende las ops.
/// Los tests lo inyectan en [InstalacionInicial] para ir paso a paso sin
/// red ni USB real. Lo que escribe se queda en un `Map<int, Uint8List>`
/// (dirección → región de BL_REGION bytes).
class TransporteBlFalso implements TransporteBl {
  @override
  final int vidFiltro;
  @override
  final int pidFiltro;

  /// true si [abrir] ya corrió. Lo usa [esperarAbierto].
  bool abierto = false;

  /// Si > 0, cada `enumerar()` miente la primera `demoraEnumerar` veces y
  /// devuelve lista vacía (modela que el BL todavía no está en bus).
  int demoraEnumerar = 0;

  /// Bytes escritos por región (clave = dirección alineada a [blRegion]).
  final Map<int, Uint8List> escritoPorRegion = <int, Uint8List>{};

  /// Buffer de EP0 del BL (lo que `blRPut` acumula para el siguiente GO).
  final Uint8List buf = Uint8List(blBufTam);

  /// Si true, cada CRC devuelve el crc32 real de la zona escrita; si false,
  /// devuelve siempre 0 (para forzar un fallo de verificación en los tests).
  bool crcHonesto = true;

  /// true tras un BL_OP_SALIR. Los tests pueden asertarlo tras `salir()`.
  bool get haSalido => _salio;
  bool _salio = false;

  int _seq = 0;
  int _ultimaOp = blOpNada;
  int _ultimaR0 = 0;
  int _ultimaR1 = 0;

  TransporteBlFalso({required int vid, required int pid})
      : vidFiltro = vid,
        pidFiltro = pid;

  @override
  String get nombre => 'falso(${vidFiltro.toRadixString(16)}:'
      '${pidFiltro.toRadixString(16)})';

  @override
  Future<List<DispositivoVisto>> enumerar() async {
    if (demoraEnumerar > 0) {
      demoraEnumerar--;
      return const [];
    }
    return [
      DispositivoVisto(
        id: 0,
        vid: vidFiltro,
        pid: pidFiltro,
        bcdDevice: 0x0013,
      ),
    ];
  }

  @override
  Future<void> abrir(DispositivoVisto d) async {
    abierto = true;
  }

  @override
  Future<void> cerrar() async {
    abierto = false;
  }

  @override
  Future<void> controlOut(
      int bRequest, int wValue, int wIndex, Uint8List data,
      {Duration timeout = const Duration(seconds: 30)}) async {
    if (!abierto) throw TransporteError('BL falso cerrado');
    switch (bRequest) {
      case blRPut:
        final off = wValue & 0xFFFF;
        if (off + data.length > buf.length) {
          throw TransporteError('blRPut: fuera de BUF (off=$off, len=${data.length})');
        }
        buf.setRange(off, off + data.length, data);
        break;
      case blRArg0:
      case blRArg1:
      case blRArg2:
      case blRArg3:
        _args[bRequest - blRArg0] =
            (wValue & 0xFFFF) | ((wIndex & 0xFFFF) << 16);
        break;
      case blRGo:
        _seq = (wValue >> 8) & 0xFF;
        final op = wValue & 0xFF;
        _ejecutar(op);
        break;
      default:
        throw TransporteError(
            'controlOut: bRequest 0x${bRequest.toRadixString(16)} no soportado por el BL falso');
    }
  }

  final List<int> _args = [0, 0, 0, 0];

  void _ejecutar(int op) {
    _ultimaOp = op;
    _ultimaR0 = 0;
    _ultimaR1 = 0;
    switch (op) {
      case blOpNada:
        return;
      case blOpWipe:
        // El BL propio borra todo el main; el installer borra también la
        // zona que WRITE_PROPIO tocará. Modelamos la variante del installer
        // (la que probamos aquí) porque los tests van contra el PID 0x0003.
        escritoPorRegion.clear();
        _ultimaR0 = (blMainFin - blMainIni) ~/ blBloque;
        return;
      case blOpWrite:
      case blOpWritePropio:
        final dir = _args[0];
        final n = _args[1];
        if (n == 0 || n > buf.length) {
          throw TransporteError('WRITE con n fuera de rango ($n)');
        }
        _validarDireccion(op, dir, n);
        for (var i = 0; i < n; i += blRegion) {
          final r = (i + blRegion <= n) ? blRegion : (n - i);
          final datos = Uint8List(blRegion);
          datos.setRange(0, r, buf.sublist(i, i + r));
          if (r < blRegion) datos.fillRange(r, blRegion, 0xFF);
          escritoPorRegion[dir + i] = datos;
        }
        _ultimaR0 = n ~/ blRegion;
        return;
      case blOpCrc:
        final dir = _args[0];
        final n = _args[1];
        if (!crcHonesto) {
          _ultimaR0 = 0;
          return;
        }
        _ultimaR0 = _crc32Zona(dir, n);
        return;
      case blOpSalir:
        // El BL de verdad contesta HECHO y SOLO DESPUÉS resetea (de ahí que
        // `pu_bl.salir()` llame a `go(BL_OP_SALIR, [], plazo=5)` y espere
        // el RES). Si cerráramos aquí (abierto=false), la lectura de RES de
        // InstalacionInicial._go reventaría con "BL falso cerrado". Lo
        // dejamos abierto; el caller cierra con cerrar() cuando ha leído
        // el HECHO.
        _salio = true;
        return;
      case blOpWipePropio:
        // Borra el bloque de 256 KiB que empieza en arg0 (alineado).
        final dir = _args[0];
        if (dir < blPropioIni || dir >= blPropioFin) {
          throw TransporteError('WIPE_PROPIO fuera de zona 0x${dir.toRadixString(16)}');
        }
        escritoPorRegion.removeWhere((a, _) => a >= dir && a < dir + blBloque);
        _ultimaR0 = 1;
        return;
      case blOpInstaladorIni:
      case blOpListo:
        // Órdenes de pantalla: en el simulador no hacen nada observable.
        return;
      default:
        throw TransporteError('op desconocida $op');
    }
  }

  void _validarDireccion(int op, int dir, int n) {
    final fin = dir + n;
    if (op == blOpWritePropio) {
      if (dir < blPropioIni || fin > blPropioFin) {
        throw TransporteError(
            'WRITE_PROPIO fuera de rango 0x${dir.toRadixString(16)}..'
            '0x${fin.toRadixString(16)} '
            '(esperado 0x${blPropioIni.toRadixString(16)}..'
            '0x${blPropioFin.toRadixString(16)})');
      }
      return;
    }
    // WRITE normal: el main (0x44180000..0x443C0000) o el W6FS (0x44400000+).
    final enMain = dir >= blMainIni && fin <= blMainFin;
    final enFs = dir >= w6fsIniMin;
    if (!(enMain || enFs)) {
      throw TransporteError(
          'WRITE fuera de rango 0x${dir.toRadixString(16)}..'
          '0x${fin.toRadixString(16)}');
    }
  }

  int _crc32Zona(int dir, int n) {
    // CRC-32 de la secuencia de regiones escritas (con 0xFF para las que
    // nunca se tocaron). Es un CRC-32 estándar (polinomio 0xEDB88320),
    // compatible con `zlib.crc32` y con el BL de verdad.
    //
    // OJO con la cascada: `a ?? b..fillRange(…)` se parsea como
    // `(a ?? b)..fillRange(…)` (`..` tiene menor precedencia que `??`), así
    // que si la región estaba escrita, el fillRange la pisaba con 0xFF y
    // el CRC salía mal (los tests lo cazaron a la primera). Rellenamos a
    // mano, con una variable local.
    final vacia = Uint8List(blRegion)..fillRange(0, blRegion, 0xFF);
    var crc = 0xFFFFFFFF;
    for (var i = 0; i < n; i += blRegion) {
      final r = (i + blRegion <= n) ? blRegion : (n - i);
      final datos = escritoPorRegion[dir + i] ?? vacia;
      for (var k = 0; k < r; k++) {
        crc = (crc >> 8) ^ _tablaCrc32[(crc ^ datos[k]) & 0xFF];
      }
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  @override
  Future<Uint8List> controlIn(
      int bRequest, int wValue, int wIndex, int wLength,
      {Duration timeout = const Duration(seconds: 30)}) async {
    if (!abierto) throw TransporteError('BL falso cerrado');
    switch (bRequest) {
      case blRId:
        // 64 B: magia SNBL + v=19.6 + entrada=1 + main_ini/fin + bloque +
        // region + buf + buf_tam + mhz + fallos + fallo_pc + build.
        final b = ByteData(64);
        b.setUint8(0, 'S'.codeUnitAt(0));
        b.setUint8(1, 'N'.codeUnitAt(0));
        b.setUint8(2, 'B'.codeUnitAt(0));
        b.setUint8(3, 'L'.codeUnitAt(0));
        b.setUint16(4, 196, Endian.little); // versión 19.6 ≈ 196
        b.setUint16(6, 1, Endian.little); // entrada = 1 (bandera)
        b.setUint32(8, blPropioIni, Endian.little); // bl_ini
        b.setUint32(12, blMainIni, Endian.little);
        b.setUint32(16, blMainFin, Endian.little);
        b.setUint32(20, blBloque, Endian.little);
        b.setUint32(24, blRegion, Endian.little);
        b.setUint32(28, 0x44300000, Endian.little); // buf en RAM (de mentira)
        b.setUint32(32, blBufTam, Endian.little);
        b.setUint32(36, 13, Endian.little); // mhz
        b.setUint32(40, 0, Endian.little); // fallos
        b.setUint32(44, 0, Endian.little); // fallo_pc
        // build: "installer-mock" + ceros
        const build = 'installer-mock';
        for (var i = 0; i < build.length && i < 15; i++) {
          b.setUint8(48 + i, build.codeUnitAt(i));
        }
        return b.buffer.asUint8List().sublist(0, wLength);
      case blRRes:
        final b = ByteData(32);
        b.setUint8(0, blStHecho);
        b.setUint8(1, _seq & 0xFF);
        b.setUint16(2, _ultimaOp, Endian.little);
        b.setInt32(4, 0, Endian.little); // codigo = 0 (ok)
        b.setUint32(8, _ultimaR0, Endian.little);
        b.setUint32(12, _ultimaR1, Endian.little);
        b.setUint32(16, 0, Endian.little); // ordenes
        b.setUint32(20, 10, Endian.little); // ms
        return b.buffer.asUint8List().sublist(0, wLength);
      default:
        throw TransporteError(
            'controlIn: bRequest 0x${bRequest.toRadixString(16)} no soportado por el BL falso');
    }
  }
}

/// Tabla CRC-32 estándar (poly 0xEDB88320). Se usa en [TransporteBlFalso]
/// para dar respuestas creíbles a BL_OP_CRC desde el modo simulado.
final Uint32List _tablaCrc32 = () {
  final t = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? ((c >> 1) ^ 0xEDB88320) : (c >> 1);
    }
    t[i] = c;
  }
  return t;
}();

/// CRC-32 reutilizable fuera del transporte falso (lo pide la verificación de
/// `enviarMain` tras un WRITE para cotejar contra lo que diga el BL).
int crc32DeDatos(Uint8List datos) {
  var crc = 0xFFFFFFFF;
  for (var i = 0; i < datos.length; i++) {
    crc = (crc >> 8) ^ _tablaCrc32[(crc ^ datos[i]) & 0xFF];
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
