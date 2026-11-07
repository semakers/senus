// El puente W5RED de SENUS por su puerta TCP, sin Bluetooth ni Flutter: acepta los
// argumentos de `bt/puente_red/servidor.py servicio`, para que `prueba_puente.py`
// y `prueba_pc.py` corran contra este núcleo con un `servidor.py` de una línea.
//
//   puente_prueba servicio --sin-bt --prueba-tcp PUERTO [--permitir-local] [--local N]…

import 'dart:io';

import 'package:senus_app/conexion/destinos.dart';
import 'package:senus_app/conexion/puerta_tcp.dart';

Future<void> main(List<String> a) async {
  var puerto = 0;
  var permitirLocal = false;
  final locales = <int>{};
  for (var i = 0; i < a.length; i++) {
    switch (a[i]) {
      case '--prueba-tcp':
        puerto = int.parse(a[++i]);
      case '--local':
        locales.add(int.parse(a[++i]));
      case '--permitir-local':
        permitirLocal = true;
      case 'servicio':
      case '--sin-bt':
        break;
      default:
        stderr.writeln('argumento desconocido: ${a[i]}');
        exit(2);
    }
  }
  if (puerto == 0) {
    stderr.writeln('falta --prueba-tcp PUERTO');
    exit(2);
  }
  void log(String t) => stdout.writeln('${DateTime.now()} $t');
  await PuertaTcp.abrir(puerto,
      log: log,
      politica: PoliticaDestinos(permitirLocal: permitirLocal, locales: locales));
}
