// Humo del canal de plataforma REAL, sin pedir permiso de Bluetooth y sin emparejar:
// comprueba que los nombres, los argumentos y los tipos cuadran entre Dart y Swift,
// y que preguntar no clava la app. Las pruebas usan una plataforma falsa y esto no
// lo pueden decir. Se compila como app y escribe en /tmp/senus_g/humo.log:
//
//   flutter build macos --release -t tool/humo_puente_bt.dart
//   open -n -W build/macos/Build/Products/Release/senus_app.app

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:senus_app/conexion/puente_nativo.dart';
import 'package:senus_app/conexion/servicio_conexion.dart' show canalTelefono;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final f = File('/tmp/senus_g/humo.log');
  void log(String t) => f.writeAsStringSync('$t\n', mode: FileMode.append);
  try {
    final n = PuenteNativoPlataforma();
    final sub = n.eventos.listen((e) => log('evento: ${e.runtimeType}'));
    final t = Stopwatch()..start();
    final e = await n.consultar();
    log('consultar: ${t.elapsedMilliseconds} ms plataforma=${e.plataforma} '
        'hay=${e.hay} permiso=${e.permiso.name} encendido=${e.encendido} '
        'direccion=${e.direccion} motivo=${e.motivo}');
    try {
      await n.escribir(99, Uint8List(3));
      log('escribir a un canal que no existe: sin error (MAL)');
    } on FalloNativo catch (x) {
      log('escribir a un canal que no existe: ${x.codigo} ${x.mensaje}');
    }
    await n.cortar(99);
    // Sin nadie en la lista y con el servidor apagado no toca la radio.
    await n.vigilar(const [], canalTelefono);
    log('vigilar sin nadie: bien');
    try {
      await n.vigilar(const [], 0);
      log('vigilar en el canal 0: sin error (MAL)');
    } on FalloNativo catch (x) {
      log('vigilar en el canal 0: ${x.codigo}');
    }
    await n.desarmarEmparejamiento();
    await n.apagar();
    log('órdenes sin Bluetooth: bien');
    await sub.cancel();
    log('fin');
  } catch (x, s) {
    log('FALLO: $x\n$s');
  }
  exit(0);
}
