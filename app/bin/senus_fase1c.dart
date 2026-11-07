// Validación fase 1c: ejercita las operaciones que usan las pantallas
// nuevas (Catálogo → subirApp, Apps → bajarApp y borrarApp, Respaldo →
// listarCarpeta + bajarObjeto). Pensado para correr contra bridge_mock.py.
//
// Uso:
//   python3 experimentos/bridge_mock.py --socket /tmp/senus-mock.sock &
//   SENUS_TRANSPORTE=socket:/tmp/senus-mock.sock \
//     ~/dev/flutter-3471/bin/dart run bin/senus_fase1c.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:senus_app/mtp/sesion_mtp.dart';
import 'package:senus_app/mtp/transporte.dart';
import 'package:senus_app/datos/sen_cab.dart';

Future<int> main(List<String> args) async {
  final t = TransporteMtp.elegir();
  final vistos = await t.enumerar();
  if (vistos.isEmpty) {
    stderr.writeln('Sin dispositivos.');
    return 1;
  }
  await t.abrir(vistos.first);
  final s = SesionMtp(t);
  final abierto = await s.abrir();
  if (!abierto.bien) {
    stderr.writeln('OpenSession: $abierto');
    return 1;
  }

  stdout.writeln('--- Listar /apps (antes) ---');
  var apps = await s.listarApps();
  for (final a in apps.valor ?? const []) {
    stdout.writeln('  h=${a.handle} ${a.nombre} ${a.bytes} B');
  }

  stdout.writeln('--- Subir una .sen falsa ---');
  // Construimos una cabecera W5X mínima para que el icono se decodifique.
  final cab = Uint8List(128);
  cab.setRange(0, 4, [0x57, 0x35, 0x58, 0x01]);
  cab[4] = 128; cab[5] = 0; // tam_cab
  cab[6] = 1;               // maquina ARMv5TE
  cab[7] = 1;               // perfil WIDGETS
  cab[57] = 8;              // icono_an = 8
  // Patrón de icono: un "corazón" sencillo (8 columnas, 12 filas).
  final patron = [0x66, 0xFF, 0xFF, 0xFF, 0x7E, 0x3C, 0x18, 0x00, 0, 0, 0, 0];
  for (var i = 0; i < 12; i++) {
    cab[58 + i * 2] = patron[i];
    cab[58 + i * 2 + 1] = 0;
  }
  // nombre: "Prueba\0"
  const nombre = 'Prueba';
  for (var i = 0; i < nombre.length; i++) {
    cab[82 + i] = nombre.codeUnitAt(i);
  }
  final cuerpo = Uint8List.fromList(cab + Uint8List.fromList(List.filled(16, 0)));
  final r = await s.subirApp('prueba.sen', cuerpo);
  stdout.writeln('subir: $r');

  stdout.writeln('--- Listar /apps (después) ---');
  apps = await s.listarApps();
  int? handleNuevo;
  for (final a in apps.valor ?? const []) {
    stdout.writeln('  h=${a.handle} ${a.nombre} ${a.bytes} B');
    if (a.nombre == 'prueba.sen') handleNuevo = a.handle;
  }

  if (handleNuevo != null) {
    stdout.writeln('--- Bajar prueba.sen ---');
    final b = await s.bajarApp(handleNuevo);
    stdout.writeln('  ${b.bien ? b.valor!.length : b.mensaje} bytes');
    if (b.bien) {
      final c = SenCab.deBytes(b.valor!);
      stdout.writeln('  cabecera: ${c?.nombre} icono_an=${c?.iconoAn}');
    }
    stdout.writeln('--- Borrar prueba.sen ---');
    final d = await s.borrarApp(handleNuevo);
    stdout.writeln('  $d');
  }

  stdout.writeln('--- Carpeta /mis_archivos ---');
  final hM = await s.handleCarpeta('mis_archivos');
  stdout.writeln('  handle: $hM');
  if (hM.bien && hM.valor != null) {
    final l = await s.listarCarpeta(hM.valor!);
    for (final o in l.valor ?? const []) {
      stdout.writeln('  - ${o.nombre} ${o.tamano}B carpeta=${o.esCarpeta}');
    }
  }

  await s.cerrar();
  return 0;
}
