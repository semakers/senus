// Capa de transporte MTP: dos implementaciones, misma interfaz.
//
//  TransporteLibusb : producción, habla por USB real contra el teléfono.
//  TransporteSocket : validación, habla por un socket Unix contra el
//                     bridge Python que encapsula el emulador USB
//                     (experimentos/bridge_mtp_socket.py).
//
// En Dart puro: no depende de Flutter, así que un CLI (bin/senus_cli.dart)
// puede usarlo para validar sin levantar la GUI.
//
// Selección: la variable de entorno SENUS_TRANSPORTE manda.
//   SENUS_TRANSPORTE=socket:/ruta/al/socket   → fuerza socket.
//   SENUS_TRANSPORTE=emu:/ruta                → el W580 en QEMU (transporte_emu.dart).
//   (vacío)                                   → libusb si está, si no error.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'libusb_bindings.dart';
import 'transporte_emu.dart';

/// VID/PID de senew en los tres aparatos (DISENO.md §4.2).
const int vidSenew = 0x1209;
const int pidSenew = 0x0001;

/// Un teléfono encontrado por el transporte (todavía sin abrir).
class DispositivoVisto {
  /// Id opaco para pasar a `abrir` (en libusb es el índice en la lista).
  final int id;
  final int vid;
  final int pid;
  final int bcdDevice;
  final String? etiquetaFabricante; // "Semakers" o lo que exponga iManufacturer
  final String? etiquetaProducto;   // "W580 sistema propio" (iProduct)
  final String? etiquetaSerie;      // iSerialNumber si lo expone

  DispositivoVisto({
    required this.id,
    required this.vid,
    required this.pid,
    required this.bcdDevice,
    this.etiquetaFabricante,
    this.etiquetaProducto,
    this.etiquetaSerie,
  });

  @override
  String toString() =>
      'USB ${vid.toRadixString(16).padLeft(4, '0')}:'
      '${pid.toRadixString(16).padLeft(4, '0')} '
      '${etiquetaProducto ?? '(sin iProduct)'}';
}

/// Error del transporte USB: libusb no encontrada, acceso denegado, etc.
class TransporteError implements Exception {
  final String motivo;
  final int? codigo; // libusb error o 0
  TransporteError(this.motivo, [this.codigo]);
  @override
  String toString() => 'TransporteError: $motivo${codigo == null ? '' : ' (cod=$codigo)'}';
}

/// Interfaz común. Trabaja a nivel de bulk IN/OUT: la lógica MTP (contenedores
/// de 12 B, orden/datos/respuesta) vive por encima, en sesion_mtp.dart.
abstract class TransporteMtp {
  /// Nombre humano del transporte, para errores.
  String get nombre;

  /// Enumera teléfonos candidatos (filtrados por VID/PID de senew).
  Future<List<DispositivoVisto>> enumerar();

  /// Reserva el dispositivo y la interfaz MTP. Después de esto se pueden
  /// hacer bulk IN/OUT.
  Future<void> abrir(DispositivoVisto d);

  /// Libera la interfaz y cierra el handle.
  Future<void> cerrar();

  /// Escribe en el endpoint OUT. Devuelve bytes escritos (debería = datos.length).
  Future<int> bulkOut(Uint8List datos, {Duration timeout = const Duration(seconds: 5)});

  /// Lee un paquete del endpoint IN. Devuelve bytes recibidos (puede ser
  /// corto; MTP lo usa como marca de fin de transferencia).
  Future<Uint8List> bulkIn(int maxLen, {Duration timeout = const Duration(seconds: 5)});

  /// Tamaño máximo del paquete bulk (64 en FS, 512 en HS). Para detectar
  /// final por paquete corto.
  int get mps;

  /// Fábrica: devuelve el transporte según SENUS_TRANSPORTE o la plataforma.
  static TransporteMtp elegir() {
    final env = Platform.environment['SENUS_TRANSPORTE'] ?? '';
    if (env.startsWith('socket:')) {
      final ruta = env.substring('socket:'.length);
      return TransporteSocket(ruta);
    }
    if (env.startsWith('emu:')) {
      return TransporteEmu(env.substring('emu:'.length));
    }
    final lu = LibUsb.intenta();
    if (lu == null) {
      throw TransporteError(
        'No se encontró libusb-1.0 en el sistema. '
        'En macOS: `brew install libusb` (o compílala en libusb/). '
        'En Linux: paquete libusb1 / libusb-1.0-0. '
        'En Windows: libusb-1.0.dll al lado del ejecutable.',
      );
    }
    return TransporteLibusb(lu);
  }
}

// --------------------------------------------------------------------------
// Transporte 1: libusb real.
// --------------------------------------------------------------------------

class TransporteLibusb implements TransporteMtp {
  final LibUsb lu;
  Pointer<Void> _ctx = nullptr;
  Pointer<Void> _handle = nullptr;
  int _epIn = 0;
  int _epOut = 0;
  int _mps = 64;
  int _iface = 0;

  TransporteLibusb(this.lu) {
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
  String get nombre => 'libusb';

  @override
  int get mps => _mps;

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
        final rr = lu.getDeviceDescriptor(dev, descPtr);
        if (rr != libusbSuccess) continue;
        final d = descPtr.ref;
        if (d.idVendor != vidSenew || d.idProduct != pidSenew) continue;
        // Intenta leer iManufacturer / iProduct / iSerial (requiere open).
        String? fab, prod, ser;
        final ppH = calloc<Pointer<Void>>();
        if (lu.open(dev, ppH) == libusbSuccess) {
          final h = ppH.value;
          fab = _leerCadena(h, d.iManufacturer);
          prod = _leerCadena(h, d.iProduct);
          ser = _leerCadena(h, d.iSerialNumber);
          lu.close(h);
        }
        calloc.free(ppH);
        vistos.add(DispositivoVisto(
          id: i,
          vid: d.idVendor,
          pid: d.idProduct,
          bcdDevice: d.bcdDevice,
          etiquetaFabricante: fab,
          etiquetaProducto: prod,
          etiquetaSerie: ser,
        ));
      }
    } finally {
      lu.freeDeviceList(list, 0); // 0 = no unref (los retenemos uno a uno más abajo)
      calloc.free(descPtr);
      calloc.free(ppList);
    }
    return vistos;
  }

  String? _leerCadena(Pointer<Void> h, int idx) {
    if (idx == 0) return null;
    final buf = calloc<Uint8>(256);
    try {
      final n = lu.getStringDescriptorAscii(h, idx, buf, 256);
      if (n <= 0) return null;
      final bytes = buf.asTypedList(n);
      return String.fromCharCodes(bytes);
    } finally {
      calloc.free(buf);
    }
  }

  @override
  Future<void> abrir(DispositivoVisto d) async {
    // Re-enumera para localizar al dispositivo elegido (su índice puede haber cambiado).
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
        throw TransporteError('No se encontró el teléfono para abrirlo', libusbErrorNoDevice);
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

    // Permitir que libusb desenganche el driver del kernel (Linux).
    try {
      lu.setAutoDetachKernelDriver?.call(_handle, 1);
    } catch (_) {}

    // El responder de senew expone una sola interfaz MTP (class 6 = Still
    // Image / PTP). En lugar de parsear descriptores (otro trozo FFI
    // grande), tiramos de los endpoints documentados en api/usb.c y
    // usb_contrato.md: iface 0, EP 0x02 OUT, 0x82 IN, bulk, 64 B en FS.
    _iface = 0;
    _epOut = 0x02;
    _epIn = 0x82;
    _mps = 64;

    final rc = lu.claimInterface(_handle, _iface);
    if (rc != libusbSuccess) {
      lu.close(_handle);
      _handle = nullptr;
      throw TransporteError('claim_interface falló (¿otro proceso?)', rc);
    }
  }

  @override
  Future<void> cerrar() async {
    if (_handle.address != 0) {
      try { lu.releaseInterface(_handle, _iface); } catch (_) {}
      lu.close(_handle);
      _handle = nullptr;
    }
  }

  @override
  Future<int> bulkOut(Uint8List datos, {Duration timeout = const Duration(seconds: 5)}) async {
    if (_handle.address == 0) throw TransporteError('Transporte no abierto');
    final buf = calloc<Uint8>(datos.length);
    buf.asTypedList(datos.length).setAll(0, datos);
    final transferred = calloc<Int32>();
    try {
      final r = lu.bulkTransfer(_handle, _epOut, buf, datos.length,
          transferred, timeout.inMilliseconds);
      if (r != libusbSuccess) {
        throw TransporteError('bulk_transfer OUT falló: ${lu.mensaje(r)}', r);
      }
      return transferred.value;
    } finally {
      calloc.free(buf);
      calloc.free(transferred);
    }
  }

  @override
  Future<Uint8List> bulkIn(int maxLen, {Duration timeout = const Duration(seconds: 5)}) async {
    if (_handle.address == 0) throw TransporteError('Transporte no abierto');
    final buf = calloc<Uint8>(maxLen);
    final transferred = calloc<Int32>();
    try {
      final r = lu.bulkTransfer(_handle, _epIn, buf, maxLen,
          transferred, timeout.inMilliseconds);
      if (r != libusbSuccess) {
        throw TransporteError('bulk_transfer IN falló: ${lu.mensaje(r)}', r);
      }
      return Uint8List.fromList(buf.asTypedList(transferred.value));
    } finally {
      calloc.free(buf);
      calloc.free(transferred);
    }
  }
}

// --------------------------------------------------------------------------
// Transporte 2: socket Unix al bridge Python.
// --------------------------------------------------------------------------
//
// Protocolo del bridge (plano, uno-a-uno con bulk IN/OUT):
//
//   OUT: cabecera 5 bytes:  'O' | u32 LE longitud          seguido de bytes
//   IN : cabecera 5 bytes:  'I' | u32 LE maxLen            → el bridge responde
//                                                            'D' | u32 LE n | bytes
//
// Para enumerar y abrir, el bridge presenta siempre un único dispositivo
// virtual con VID/PID = 0x1209/0x0001, nombre "W580 sistema propio" (o lo
// que diga la variable BRIDGE_PRODUCTO).

class TransporteSocket implements TransporteMtp {
  final String rutaSocket;
  Socket? _s;
  final List<int> _bufRx = <int>[];
  // Esperas pendientes: cada una pide N bytes y se cumple cuando _bufRx los tiene.
  final List<_EsperaBytes> _esperas = [];

  TransporteSocket(this.rutaSocket);

  void _procesaPendientes() {
    while (_esperas.isNotEmpty && _bufRx.length >= _esperas.first.n) {
      final e = _esperas.removeAt(0);
      if (!e.c.isCompleted) e.c.complete();
    }
  }

  @override
  String get nombre => 'socket:$rutaSocket';

  @override
  int get mps => 64;

  @override
  Future<List<DispositivoVisto>> enumerar() async {
    // El bridge siempre presenta uno. Si no se puede conectar, enumeración vacía.
    try {
      final s = await Socket.connect(
        InternetAddress(rutaSocket, type: InternetAddressType.unix),
        0,
      );
      await s.close();
    } catch (e) {
      return [];
    }
    return [
      DispositivoVisto(
        id: 0,
        vid: vidSenew,
        pid: pidSenew,
        bcdDevice: 0x0013,
        etiquetaFabricante: 'Semakers',
        etiquetaProducto: Platform.environment['BRIDGE_PRODUCTO'] ?? 'W580 sistema propio',
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
    try { await _s?.close(); } catch (_) {}
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
  Future<int> bulkOut(Uint8List datos, {Duration timeout = const Duration(seconds: 5)}) async {
    final s = _s;
    if (s == null) throw TransporteError('socket no abierto');
    final cab = ByteData(5);
    cab.setUint8(0, 'O'.codeUnitAt(0));
    cab.setUint32(1, datos.length, Endian.little);
    s.add(cab.buffer.asUint8List());
    s.add(datos);
    await s.flush();
    return datos.length;
  }

  @override
  Future<Uint8List> bulkIn(int maxLen, {Duration timeout = const Duration(seconds: 5)}) async {
    final s = _s;
    if (s == null) throw TransporteError('socket no abierto');
    final cab = ByteData(5);
    cab.setUint8(0, 'I'.codeUnitAt(0));
    cab.setUint32(1, maxLen, Endian.little);
    s.add(cab.buffer.asUint8List());
    await s.flush();

    await _leerAlMenos(5, timeout);
    final tipo = _bufRx[0];
    if (tipo != 'D'.codeUnitAt(0)) {
      _bufRx.removeRange(0, 1);
      throw TransporteError('respuesta del bridge mala (tipo=$tipo)');
    }
    final nbd = ByteData(4)..buffer.asUint8List().setRange(0, 4, _bufRx.sublist(1, 5));
    final n = nbd.getUint32(0, Endian.little);
    _bufRx.removeRange(0, 5);
    await _leerAlMenos(n, timeout);
    final out = Uint8List.fromList(_bufRx.sublist(0, n));
    _bufRx.removeRange(0, n);
    return out;
  }
}

class _EsperaBytes {
  final int n;
  final Completer<void> c = Completer<void>();
  _EsperaBytes(this.n);
}
