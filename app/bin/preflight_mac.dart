// Comprobación PREVIA (solo lectura) para la primera instalación en la Mac.
//
// No habla con el teléfono, no escribe nada, no lanza seftool: mira que estén
// las piezas y qué ve SENUS ahora mismo en el bus USB.
//
//   cd app && dart run bin/preflight_mac.dart
//
// Salida 0 = todo listo; 1 = falta algo (dice qué).

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:senus_app/datos/artefactos_instalador.dart';
import 'package:senus_app/datos/instalador_anycid.dart';
import 'package:senus_app/datos/respaldo_rollback.dart';
import 'package:senus_app/datos/seftool.dart';
import 'package:senus_app/datos/transporte_bl.dart';
import 'package:senus_app/mtp/libusb_bindings.dart';

var _mal = 0;
void _ok(String s) => stdout.writeln('  ✓ $s');
void _no(String s) {
  _mal++;
  stdout.writeln('  ✗ $s');
}

Future<void> main() async {
  stdout.writeln('SENUS · comprobación previa (solo lectura)\n');

  stdout.writeln('Plataforma');
  final g = GatePlataforma.evaluar();
  g.permitida
      ? _ok('${Platform.operatingSystem}: el instalador está disponible')
      : _no(g.motivo!);
  FlagsInstalacion.flujoLegado()
      ? _no('SENUS_FLUJO_LEGADO=1 está puesto: saldría el flujo VIEJO')
      : _ok('flujo nuevo activo (SENUS_FLUJO_LEGADO no está puesto)');

  stdout.writeln('\nInstalador empotrado');
  try {
    var d = Directory.current.path;
    String? assets;
    for (var i = 0; i < 3 && assets == null; i++) {
      final c = p.join(d, 'assets', 'instalador', 'w580');
      if (Directory(c).existsSync()) assets = c;
      d = p.dirname(d);
    }
    if (assets == null) throw const ArtefactosError('no encuentro assets/instalador/w580 (ejecuta desde app/)');
    final a = await ArtefactosW580.cargar(FuenteArtefactosCarpeta(assets));
    _ok('${a.sha256Por.length} ficheros comprobados contra el manifiesto');
    _ok('main ${a.main.length} B · BL ${a.blClasico.length} B · '
        '${a.paquetesR8be001.length} paquetes R8BE001');
    _ok('verificado en silicio: ${a.paqueteVerificado}');
  } on ArtefactosError catch (e) {
    _no('${e.motivo} ${e.remedio ?? ''}');
  }

  stdout.writeln('\nseftool');
  final raiz = Seftool.raizPredeterminada;
  final sef = Seftool(raiz: raiz, puerto: Seftool.autodetectarPuerto() ?? '');
  File(sef.binario).existsSync()
      ? _ok('binario: ${sef.binario}')
      : _no('no hay binario en ${sef.binario} (mac/build.sh)');
  for (final n in const ['loader', 'rest', 'backup']) {
    Directory(p.join(raiz, n)).existsSync()
        ? _ok('$n/ presente')
        : _no('falta $raiz/$n/');
  }
  sef.puerto == 'usb'
      ? _ok('puerto: usb (libusb directo, como debe ser en la Mac)')
      : _no('puerto «${sef.puerto}»: en la Mac debería ser «usb»');

  stdout.writeln('\nRespaldos');
  final alm = AlmacenRespaldos.predeterminado();
  final todos = await alm.listar();
  _ok('almacén: ${alm.rutaBase} (${todos.length} respaldos registrados)');
  for (final r in todos) {
    stdout.writeln('      · ${r.modelo} ${r.serie} ${r.fecha.toIso8601String().substring(0, 10)}'
        '${r.simulado ? ' [SIMULADO: no vale]' : ''}');
  }

  stdout.writeln('\nlibusb y bus USB');
  final lu = LibUsb.intenta();
  if (lu == null) {
    _no('no encuentro libusb-1.0 (brew install libusb)');
  } else {
    _ok('libusb cargada');
    const buscados = <(String, int, int)>[
      ('teléfono en modo C (SEMC USB Flash)', 0x0fce, 0xadde),
      ('BL installer tras «Juegos → eXploit»', vidSenew, pidBlInstaller),
      ('BL propio', vidSenew, pidBlPropio),
      ('senew en marcha', vidSenew, pidSenewNormal),
    ];
    for (final (nombre, vid, pid) in buscados) {
      final t = TransporteBlLibusb(lu, vid: vid, pid: pid);
      final vistos = await t.enumerar();
      stdout.writeln('  ${vistos.isEmpty ? '·' : '●'} '
          '${vid.toRadixString(16).padLeft(4, '0')}:${pid.toRadixString(16).padLeft(4, '0')}'
          '  $nombre: ${vistos.isEmpty ? 'no está' : 'VISTO (${vistos.length})'}');
    }
  }

  stdout.writeln(_mal == 0
      ? '\nTodo listo. Abre SENUS y enchufa el teléfono en modo C.'
      : '\nFalta algo ($_mal). Arréglalo antes de enchufar el teléfono.');
  exit(_mal == 0 ? 0 : 1);
}
