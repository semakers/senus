// La puerta TCP de pruebas, como `servidor.py --prueba-tcp`: la misma sesión W5RED
// sobre 127.0.0.1, sin Bluetooth. Solo la usan `bin/puente_prueba.dart` y las
// pruebas: la app no la abre, porque dejaría a cualquier programa del computador
// hablar con los puertos locales del teléfono.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'destinos.dart';
import 'w5red_sesion.dart';

class TransporteSocket implements TransporteW5 {
  final Socket s;
  @override
  final String quien;

  TransporteSocket(this.s, this.quien) {
    s.setOption(SocketOption.tcpNoDelay, true);
    unawaited(s.done.then<void>((_) {}, onError: (Object _) {}));
  }

  @override
  Stream<Uint8List> get entrada => s;

  @override
  Future<void> escribir(Uint8List d) async {
    s.add(d);
    await s.flush();
  }

  @override
  Future<void> cerrar() async => s.destroy();
}

class PuertaTcp {
  final ServerSocket _srv;
  PuertaTcp._(this._srv);

  int get puerto => _srv.port;
  String get direccion => _srv.address.address;

  /// [puerto] 0 = uno libre. Solo 127.0.0.1.
  static Future<PuertaTcp> abrir(
    int puerto, {
    required void Function(String) log,
    PoliticaDestinos politica = const PoliticaDestinos(),
  }) async {
    final srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, puerto);
    final p = PuertaTcp._(srv);
    log('pruebas: sesiones W5RED también en 127.0.0.1:${srv.port}');
    srv.listen((c) {
      final t = TransporteSocket(c, 'tcp:${c.remotePort}');
      unawaited(Sesion(t, log: log, politica: politica).correr());
    });
    return p;
  }

  Future<void> cerrar() => _srv.close();
}
