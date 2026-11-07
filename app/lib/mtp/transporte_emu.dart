// Transporte al W580 SIMULADO (senew real en QEMU): herr/w580_simulado/simulado.py.
//
// Implementa las mismas interfaces que libusb ([TransporteMtp], [TransporteBl]), así que todo lo que hay por encima (SesionMtp, el canal
// de gestión, el cliente del BL) es el mismo código que hablará con el teléfono. A diferencia de TransporteSocket y TransporteBlSocket:
//   - enumerar() dice lo que de verdad hay en el bus: VID:PID y cadenas leídos del firmware. Si el teléfono se ha reiniciado o está en el
//     BL, enumerar por 1209:0001 devuelve vacío, como libusb.
//   - cada transferencia espera su resultado y los errores llevan el código de libusb: -4 sin aparato, -7 plazo, -9 STALL.
//   - un `abrir` queda atado a esa enumeración: si el aparato se va y vuelve, lo abierto falla con -4, también como libusb.
//
// Se elige con SENUS_TRANSPORTE=emu:/ruta/usb.sock (TransporteEmu.elegirDesdeEntorno, para quien tenga cableado el selector).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../datos/transporte_bl.dart'
    show TransporteBl, bmReqtypeVendorIn, bmReqtypeVendorOut, pidBlPropio;
import 'libusb_bindings.dart' show libusbErrorIo, libusbErrorNoDevice, libusbErrorTimeout;
import 'transporte.dart';

/// Una conexión con el socket USB del simulado: bytes con espera por longitud, y los marcos del protocolo.
class CanalEmu {
  final String ruta;
  Socket? _s;
  final BytesBuilder _rx = BytesBuilder(copy: false);
  Uint8List _pend = Uint8List(0);
  Completer<void>? _espera;
  bool _cerrado = false;

  CanalEmu(this.ruta);

  Future<void> conectar() async {
    final s = await Socket.connect(InternetAddress(ruta, type: InternetAddressType.unix), 0);
    _s = s;
    s.listen((d) {
      _rx.add(d);
      final e = _espera;
      if (e != null && !e.isCompleted) e.complete();
    }, onDone: () {
      _cerrado = true;
      final e = _espera;
      if (e != null && !e.isCompleted) e.complete();
    }, onError: (Object _) {
      _cerrado = true;
      final e = _espera;
      if (e != null && !e.isCompleted) e.complete();
    });
  }

  Future<void> cerrar() async {
    final s = _s;
    _s = null;
    if (s == null) return;
    try {
      s.destroy();
    } catch (_) {}
  }

  Future<Uint8List> _leer(int n, Duration plazo) async {
    final fin = DateTime.now().add(plazo);
    while (true) {
      if (_rx.isNotEmpty) {
        final b = BytesBuilder(copy: false)
          ..add(_pend)
          ..add(_rx.takeBytes());
        _pend = b.takeBytes();
      }
      if (_pend.length >= n) {
        final out = Uint8List.sublistView(_pend, 0, n);
        _pend = Uint8List.sublistView(_pend, n);
        return out;
      }
      if (_cerrado) throw TransporteError('el simulado cerró el socket', libusbErrorNoDevice);
      final queda = fin.difference(DateTime.now());
      if (queda.isNegative) throw TransporteError('plazo esperando al simulado', libusbErrorTimeout);
      final e = Completer<void>();
      _espera = e;
      try {
        await e.future.timeout(queda);
      } on TimeoutException {
        // lo mira el bucle
      }
    }
  }

  Future<void> _enviar(List<int> d) async {
    final s = _s;
    if (s == null) throw TransporteError('socket no abierto', libusbErrorNoDevice);
    try {
      s.add(d);
      await s.flush();
    } on SocketException catch (e) {
      throw TransporteError('socket: ${e.message}', libusbErrorNoDevice);
    }
  }

  Future<Uint8List> _resp(Duration plazo) async {
    final c = await _leer(9, plazo);
    final bd = ByteData.sublistView(c);
    if (bd.getUint8(0) != 0x72) throw TransporteError('marco inesperado del simulado', libusbErrorIo);
    final st = bd.getInt32(1, Endian.little);
    final n = bd.getUint32(5, Endian.little);
    final d = n > 0 ? await _leer(n, plazo) : Uint8List(0);
    if (st != 0) throw TransporteError('USB simulado', st);
    return d;
  }

  Future<List<Map<String, dynamic>>> listar() async {
    await _enviar('L'.codeUnits);
    final c = await _leer(5, const Duration(seconds: 10));
    final n = ByteData.sublistView(c).getUint32(1, Endian.little);
    final j = jsonDecode(utf8.decode(await _leer(n, const Duration(seconds: 10)))) as Map<String, dynamic>;
    return (j['dispositivos'] as List).cast<Map<String, dynamic>>();
  }

  Future<void> abrir(int gen) async {
    final b = ByteData(5)
      ..setUint8(0, 0x61)
      ..setUint32(1, gen, Endian.little);
    await _enviar(b.buffer.asUint8List());
    await _resp(const Duration(seconds: 10));
  }

  Future<void> bulkOut(Uint8List datos, Duration plazo) async {
    final b = ByteData(9)
      ..setUint8(0, 0x6F)
      ..setUint32(1, datos.length, Endian.little)
      ..setUint32(5, plazo.inMilliseconds, Endian.little);
    await _enviar(b.buffer.asUint8List());
    await _enviar(datos);
    await _resp(plazo + const Duration(seconds: 20));
  }

  Future<Uint8List> bulkIn(int maxLen, Duration plazo) async {
    final b = ByteData(9)
      ..setUint8(0, 0x69)
      ..setUint32(1, maxLen, Endian.little)
      ..setUint32(5, plazo.inMilliseconds, Endian.little);
    await _enviar(b.buffer.asUint8List());
    return _resp(plazo + const Duration(seconds: 20));
  }

  /// Respuestas por recoger de transferencias lanzadas sin esperar (ver [TransporteBlEmu]).
  int _enVuelo = 0;

  Future<void> drenar(Duration plazo) async {
    while (_enVuelo > 0) {
      _enVuelo--;
      await _resp(plazo);
    }
  }

  Future<void> _marcoControl(int rt, int req, int val, int idx, int wlen, Uint8List? datos, Duration plazo) async {
    final b = ByteData(13)
      ..setUint8(0, 0x63)
      ..setUint8(1, rt)
      ..setUint8(2, req)
      ..setUint16(3, val & 0xFFFF, Endian.little)
      ..setUint16(5, idx & 0xFFFF, Endian.little)
      ..setUint16(7, wlen & 0xFFFF, Endian.little)
      ..setUint32(9, plazo.inMilliseconds, Endian.little);
    await _enviar(b.buffer.asUint8List());
    if (datos != null && datos.isNotEmpty) await _enviar(datos);
  }

  Future<Uint8List> control(int rt, int req, int val, int idx, int wlen, Uint8List? datos, Duration plazo) async {
    await drenar(plazo + const Duration(seconds: 20));
    await _marcoControl(rt, req, val, idx, wlen, datos, plazo);
    return _resp(plazo + const Duration(seconds: 20));
  }

  /// Control lanzado sin esperar el resultado; el error, si lo hay, sale en la siguiente orden.
  Future<void> controlEnVuelo(int rt, int req, int val, int idx, int wlen, Uint8List? datos, Duration plazo) async {
    await _marcoControl(rt, req, val, idx, wlen, datos, plazo);
    _enVuelo++;
    if (_enVuelo >= 128) await drenar(plazo + const Duration(seconds: 20));
  }

  /// Varios control IN seguidos, lanzados de golpe y recogidos en orden.
  Future<List<Uint8List>> controlesIn(List<(int, int, int, int, int)> l, Duration plazo) async {
    await drenar(plazo + const Duration(seconds: 20));
    for (final (rt, req, val, idx, wlen) in l) {
      await _marcoControl(rt, req, val, idx, wlen, null, plazo);
    }
    return [for (final _ in l) await _resp(plazo + const Duration(seconds: 20))];
  }
}

DispositivoVisto _visto(Map<String, dynamic> m) => DispositivoVisto(
      id: m['gen'] as int,
      vid: m['vid'] as int,
      pid: m['pid'] as int,
      bcdDevice: m['bcd'] as int,
      etiquetaFabricante: m['fab'] as String?,
      etiquetaProducto: m['prod'] as String?,
      etiquetaSerie: m['serie'] as String?,
    );

/// Enumeración en una conexión de un solo uso. Sin simulado, nada: como un bus sin teléfono.
Future<List<DispositivoVisto>> _enumerar(String ruta, int vid, int pid) async {
  final c = CanalEmu(ruta);
  try {
    await c.conectar();
    final l = await c.listar();
    return l.map(_visto).where((d) => d.vid == vid && d.pid == pid).toList();
  } on SocketException {
    return [];
  } on TransporteError {
    return [];
  } finally {
    await c.cerrar();
  }
}

/// El lado MTP del simulado.
class TransporteEmu implements TransporteMtp {
  final String ruta;
  CanalEmu? _c;

  TransporteEmu(this.ruta);

  /// `SENUS_TRANSPORTE=emu:/ruta/usb.sock`, o null.
  static TransporteEmu? elegirDesdeEntorno() {
    final v = Platform.environment['SENUS_TRANSPORTE'] ?? '';
    return v.startsWith('emu:') ? TransporteEmu(v.substring(4)) : null;
  }

  @override
  String get nombre => 'emu:$ruta';

  @override
  int get mps => 64;

  @override
  Future<List<DispositivoVisto>> enumerar() => _enumerar(ruta, vidSenew, pidSenew);

  @override
  Future<void> abrir(DispositivoVisto d) async {
    final c = CanalEmu(ruta);
    await c.conectar();
    await c.abrir(d.id);
    _c = c;
  }

  @override
  Future<void> cerrar() async {
    await _c?.cerrar();
    _c = null;
  }

  CanalEmu get _canal {
    final c = _c;
    if (c == null) throw TransporteError('Transporte no abierto');
    return c;
  }

  @override
  Future<int> bulkOut(Uint8List datos, {Duration timeout = const Duration(seconds: 5)}) async {
    await _canal.bulkOut(datos, timeout);
    return datos.length;
  }

  @override
  Future<Uint8List> bulkIn(int maxLen, {Duration timeout = const Duration(seconds: 5)}) =>
      _canal.bulkIn(maxLen, timeout);
}

/// El lado BL del simulado: las peticiones de vendedor por el EP0 del bootloader real.
///
/// El BL ve exactamente las mismas transferencias, en el mismo orden, que con libusb. Lo único que cambia es el lado del cliente: como en
/// la Mac cada ida y vuelta por el túnel son milisegundos y un main son decenas de miles de transferencias, los `PUT` se lanzan sin esperar y los `GET`
/// se piden de 512 en 512. Un fallo sale en la orden siguiente en vez de en esa misma. Con `SENUS_EMU_SIN_LOTES=1` va una a una.
class TransporteBlEmu implements TransporteBl {
  static final bool _lotes = Platform.environment['SENUS_EMU_SIN_LOTES'] != '1';
  static const int _rGet = 0xDB, _rPut = 0xD2, _porLote = 512;
  int _getIni = 0;
  Uint8List _getD = Uint8List(0);

  final String ruta;
  @override
  final int vidFiltro;
  @override
  final int pidFiltro;
  CanalEmu? _c;

  TransporteBlEmu(this.ruta, {int vid = vidSenew, int pid = pidBlPropio})
      : vidFiltro = vid,
        pidFiltro = pid;

  static TransporteBlEmu? elegirDesdeEntorno({required int vid, required int pid}) {
    final v = Platform.environment['SENUS_BL_TRANSPORTE'] ?? Platform.environment['SENUS_TRANSPORTE'] ?? '';
    return v.startsWith('emu:') ? TransporteBlEmu(v.substring(4), vid: vid, pid: pid) : null;
  }

  @override
  String get nombre => 'emu:$ruta(${vidFiltro.toRadixString(16)}:${pidFiltro.toRadixString(16)})';

  @override
  Future<List<DispositivoVisto>> enumerar() => _enumerar(ruta, vidFiltro, pidFiltro);

  @override
  Future<void> abrir(DispositivoVisto d) async {
    final c = CanalEmu(ruta);
    await c.conectar();
    await c.abrir(d.id);
    _c = c;
  }

  @override
  Future<void> cerrar() async {
    await _c?.cerrar();
    _c = null;
  }

  CanalEmu get _canal {
    final c = _c;
    if (c == null) throw TransporteError('Transporte no abierto');
    return c;
  }

  @override
  Future<void> controlOut(int bRequest, int wValue, int wIndex, Uint8List data,
      {Duration timeout = const Duration(seconds: 30)}) async {
    _getD = Uint8List(0);
    if (_lotes && bRequest == _rPut) {
      await _canal.controlEnVuelo(bmReqtypeVendorOut, bRequest, wValue, wIndex, data.length, data, timeout);
      return;
    }
    await _canal.control(bmReqtypeVendorOut, bRequest, wValue, wIndex, data.length, data, timeout);
  }

  @override
  Future<Uint8List> controlIn(int bRequest, int wValue, int wIndex, int wLength,
      {Duration timeout = const Duration(seconds: 30)}) async {
    if (!_lotes || bRequest != _rGet || wLength != 64) {
      return _canal.control(bmReqtypeVendorIn, bRequest, wValue, wIndex, wLength, null, timeout);
    }
    final a = wValue | (wIndex << 16);
    if (a < _getIni || a + wLength > _getIni + _getD.length) {
      final l = <(int, int, int, int, int)>[
        for (var i = 0; i < _porLote; i++)
          (bmReqtypeVendorIn, _rGet, (a + i * 64) & 0xFFFF, ((a + i * 64) >> 16) & 0xFFFF, 64)
      ];
      final b = BytesBuilder(copy: false);
      for (final d in await _canal.controlesIn(l, timeout)) {
        b.add(d);
      }
      _getIni = a;
      _getD = b.takeBytes();
    }
    return Uint8List.sublistView(_getD, a - _getIni, a - _getIni + wLength);
  }
}
