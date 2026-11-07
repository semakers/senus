// CLI de validación: abre la sesión MTP y hace GetDeviceInfo + GetStorageInfo + lista /apps.
// Se usa donde Flutter desktop no compila (p. ej. Linux ARM64) con
//   SENUS_TRANSPORTE=socket:/tmp/senus-bridge.sock \
//     ~/dev/flutter-3471/bin/dart run bin/senus_cli.dart
// o en una Mac con libusb:
//   dart run bin/senus_cli.dart

import 'dart:io';
import 'package:senus_app/mtp/transporte.dart';
import 'package:senus_app/mtp/sesion_mtp.dart';

Future<int> main(List<String> args) async {
  TransporteMtp t;
  try {
    t = TransporteMtp.elegir();
  } on TransporteError catch (e) {
    stderr.writeln('TransporteError: ${e.motivo}');
    return 2;
  }
  stdout.writeln('Transporte: ${t.nombre}');

  final vistos = await t.enumerar();
  if (vistos.isEmpty) {
    stderr.writeln('No se encontró ningún teléfono senew (VID 1209:0001).');
    return 1;
  }
  for (final d in vistos) {
    stdout.writeln('  - $d');
  }
  final d = vistos.first;
  await t.abrir(d);
  final s = SesionMtp(t);

  final abierto = await s.abrir(tiempoMax: const Duration(seconds: 10));
  if (!abierto.bien) {
    stderr.writeln('OpenSession: $abierto');
    await s.cerrar();
    return 1;
  }
  final info = await s.info();
  stdout.writeln('info: $info');
  if (info.bien) {
    final tel = info.valor!;
    stdout.writeln('  modelo=${tel.modelo} nombre=${tel.nombreAmigo}');
    stdout.writeln('  serie=${tel.serie} senew=${tel.versionSenew}');
  }
  final alm = await s.almacenes();
  stdout.writeln('almacenes: $alm');
  if (alm.bien) {
    for (final a in alm.valor!) {
      stdout.writeln('  ${a.id.toRadixString(16)} ${a.etiqueta} '
          '${(a.bytesTotales / 1024 / 1024).toStringAsFixed(2)} MiB '
          'libres ${(a.bytesLibres / 1024 / 1024).toStringAsFixed(2)} MiB');
    }
  }
  final apps = await s.listarApps();
  stdout.writeln('apps: $apps');
  if (apps.bien) {
    for (final a in apps.valor!) {
      stdout.writeln('  h=${a.handle} ${a.nombre} ${a.bytes} B');
    }
  }
  await s.cerrar();
  return 0;
}
