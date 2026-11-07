// La pantalla «Instalar senew» (primera instalación, flujo anycid + trampoline)
// contra un teléfono y un BL FALSOS. Nada de esto toca un aparato:
//   * seftool va en ENSAYO (registra la orden y no ejecuta nada);
//   * el BL installer y senew son TransporteBlFalso.
//
// Lo que se comprueba es la pantalla: que en Windows/Linux diga «próximamente»
// y no deje empezar, que no deje empezar sin confirmar la pantalla del
// teléfono, que un teléfono que no entra en el flujo se rechace, y que el
// camino feliz llegue a «¡Listo!» con la notificación de rollback a la vista.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:senus_app/datos/artefactos_instalador.dart';
import 'package:senus_app/datos/respaldo_rollback.dart';
import 'package:senus_app/datos/seftool.dart';
import 'package:senus_app/datos/telefono.dart';
import 'package:senus_app/datos/transporte_bl.dart';
import 'package:senus_app/tema/senus_tema.dart';
import 'package:senus_app/widgets/pant_fabrica.dart';
import 'package:senus_app/widgets/pant_instalar_inicial.dart';

const _imei = '35000000000001';
const _identify = 'Phone Info (from GDFS):\n'
    'Model: W580i\n'
    'OTP: LOCKED:1 CID:52 PAF:0 IMEI:$_imei\n'
    'ACTIVE CID:52 COLOR:RED\n'
    'MAPP CXC article: CXC1123362\n'
    'MAPP CXC version: R8BE001\n'
    'SIMLOCKS NOT DETECTED\n'
    'Anycid package: ./anycid/R8BE001_CXC1123362_GENERIC_LA.zip\n';

const _w580 = Telefono(
  modelo: Modelo.w580,
  nombreAmigo: 'W580 de fábrica',
  serie: _imei,
  versionSenew: '—',
  almacenes: [],
  deFabrica: true,
  cid: '52',
  color: 'RED',
  firmwareOriginal: 'R8BE001',
);

String _assets() {
  var d = Directory.current.path;
  for (var i = 0; i < 4; i++) {
    final c = p.join(d, 'assets', 'instalador', 'w580');
    if (Directory(c).existsSync()) return c;
    d = p.dirname(d);
  }
  throw StateError('no encuentro app/assets/instalador/w580');
}

Future<void> _esperarIO(WidgetTester tester, [int veces = 10]) async {
  for (var i = 0; i < veces; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// Espera (en tiempo real) a que se cumpla [cond]; falla si pasa [max].
Future<void> _hasta(WidgetTester tester, bool Function() cond,
    {Duration max = const Duration(seconds: 90), String? que}) async {
  final fin = DateTime.now().add(max);
  while (!cond()) {
    if (DateTime.now().isAfter(fin)) {
      fail('Se agotó la espera de: ${que ?? 'la condición'}');
    }
    await _esperarIO(tester, 1);
  }
}

/// La pantalla carga y verifica los artefactos al abrirse (lee ~1,8 MiB).
Future<void> _artefactosListos(WidgetTester tester) => _hasta(
    tester, () => find.textContaining('Instalador empotrado').evaluate().isNotEmpty,
    que: 'la carga de los artefactos');

Widget _app(Widget hijo) => MaterialApp(
      theme: temaSenus(Brightness.dark),
      home: Scaffold(body: hijo),
    );

void _ventanaGrande(WidgetTester tester) {
  tester.view.physicalSize = const Size(1500, 2200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

PantInstalarInicial _pantalla(
  Directory tmp, {
  Telefono tel = _w580,
  String sistema = 'macos',
  String identify = _identify,
  TransporteBl Function(int)? bl,
}) =>
    PantInstalarInicial(
      telefono: tel,
      almacen: AlmacenRespaldos.en(p.join(tmp.path, 'respaldos')),
      fuente: FuenteArtefactosCarpeta(_assets()),
      fabricaSeftool: () => Seftool(
          raiz: p.join(tmp.path, 'fork'),
          puerto: 'usb',
          ensayo: true,
          identifyEnsayoStdout: identify),
      fabricaBl: bl ?? (pid) => TransporteBlFalso(vid: vidSenew, pid: pid),
      sistema: sistema,
      env: const {},
    );

FilledButton _boton(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byKey(const ValueKey('empezar')));

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('senus-pant-'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  testWidgets('en Windows se enseña el plan igual que en macOS',
      (tester) async {
    _ventanaGrande(tester);
    await tester.pumpWidget(_app(_pantalla(tmp, sistema: 'windows')));
    await _artefactosListos(tester);
    expect(find.text('Próximamente'), findsNothing);
    expect(find.text('Qué va a pasar'), findsOneWidget);
    expect(_boton(tester).onPressed, isNull); // falta marcar pantalla y SIM
  });

  testWidgets('en Linux también (sin el ajuste oculto)', (tester) async {
    _ventanaGrande(tester);
    await tester.pumpWidget(_app(_pantalla(tmp, sistema: 'linux')));
    await _esperarIO(tester, 4);
    expect(find.text('Próximamente'), findsOneWidget);
    expect(_boton(tester).onPressed, isNull);
  });

  testWidgets('en macOS no deja empezar sin confirmar pantalla y SIM',
      (tester) async {
    _ventanaGrande(tester);
    await tester.pumpWidget(_app(_pantalla(tmp)));
    await _artefactosListos(tester);
    expect(find.text('Qué va a pasar'), findsOneWidget);
    expect(_boton(tester).onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('casillaPantalla')));
    await tester.pump();
    expect(_boton(tester).onPressed, isNotNull);
  });

  testWidgets('un teléfono que ya corre senew se rechaza', (tester) async {
    _ventanaGrande(tester);
    const conSenew = Telefono(
      modelo: Modelo.w580,
      nombreAmigo: 'W580 sistema propio',
      serie: 'W580S10000001',
      versionSenew: '0.19',
      almacenes: [],
    );
    await tester.pumpWidget(_app(_pantalla(tmp, tel: conSenew)));
    await _artefactosListos(tester);
    expect(find.textContaining('ya corre senew'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('casillaPantalla')));
    await tester.pump();
    expect(_boton(tester).onPressed, isNull);
  });

  testWidgets('un W580 CID53 de fábrica se rechaza antes de empezar',
      (tester) async {
    _ventanaGrande(tester);
    const cid53 = Telefono(
      modelo: Modelo.w580,
      nombreAmigo: 'W580 de fábrica',
      serie: _imei,
      versionSenew: '—',
      almacenes: [],
      deFabrica: true,
      cid: '53',
      color: 'RED',
      firmwareOriginal: 'R8BE001',
    );
    await tester.pumpWidget(_app(_pantalla(tmp, tel: cid53)));
    await _artefactosListos(tester);
    expect(find.textContaining('CID 53'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('casillaPantalla')));
    await tester.pump();
    expect(_boton(tester).onPressed, isNull);
  });

  testWidgets('camino feliz: pausas → fases → «¡Listo!» con el rollback',
      (tester) async {
    _ventanaGrande(tester);
    await tester.pumpWidget(_app(_pantalla(tmp)));
    await _artefactosListos(tester);
    await tester.tap(find.byKey(const ValueKey('casillaPantalla')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('empezar')));
    await tester.pump();

    var pausas = 0;
    await _hasta(tester, () {
      final seguir = find.text('Continuar');
      if (seguir.evaluate().isNotEmpty) {
        pausas++;
        // El tap es asíncrono; se resuelve en la siguiente vuelta.
        unawaited(tester.tap(seguir).then((_) => tester.pump()));
      }
      return find.textContaining('¡Listo!').evaluate().isNotEmpty;
    }, que: '«¡Listo!»', max: const Duration(minutes: 3));

    expect(find.textContaining('¡Listo!'), findsOneWidget);
    // identify, GDFS A, GDFS B y el upload: cuatro reconexiones en modo C.
    expect(pausas, greaterThanOrEqualTo(4));
    // La regla de rollback: dónde queda el respaldo y cómo se vuelve atrás.
    expect(find.textContaining('Respaldo de rollback de este teléfono'),
        findsOneWidget);
    expect(find.textContaining('gdfs_A.bin'), findsWidgets);
    expect(find.textContaining('write-gdfs'), findsWidgets);
    expect(find.text('Abrir el respaldo'), findsOneWidget);
    // El registro lleva la orden de seftool SIN --anycid.
    final ordenes = find
        .byType(Text)
        .evaluate()
        .map((e) => (e.widget as Text).data ?? '')
        .where((t) => t.startsWith('> ') && t.contains('upload-anycid'))
        .toList();
    expect(ordenes, hasLength(1));
    expect(ordenes.single.contains('--anycid'), isFalse);
    expect(ordenes.single.contains('--imei $_imei'), isTrue);
    // Al terminar el botón vuelve a poder usarse como «Repetir».
    expect(find.text('Repetir'), findsOneWidget);
    // No queda ningún temporal del instalador.
    final restos = Directory.systemTemp
        .listSync()
        .where((e) => p.basename(e.path).startsWith('senus-anycid-'));
    expect(restos, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 4)));

  testWidgets('cancelar una pausa para el flujo sin escribir nada',
      (tester) async {
    _ventanaGrande(tester);
    final exploit = TransporteBlFalso(vid: vidSenew, pid: pidBlInstaller);
    await tester.pumpWidget(_app(_pantalla(tmp, bl: (pid) => exploit)));
    await _artefactosListos(tester);
    await tester.tap(find.byKey(const ValueKey('casillaPantalla')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('empezar')));
    await tester.pump();
    await _hasta(tester, () => find.byType(AlertDialog).evaluate().isNotEmpty,
        que: 'la primera pausa');
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('Cancelar')));
    await _hasta(tester,
        () => find.textContaining('Cancelado').evaluate().isNotEmpty,
        que: 'el aviso de cancelado');
    expect(find.textContaining('¡Listo!'), findsNothing);
    expect(exploit.escritoPorRegion, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('el respaldo solo-GDFS del flujo nuevo no rompe la pantalla Fábrica',
      (tester) async {
    _ventanaGrande(tester);
    final alm = AlmacenRespaldos.en(p.join(tmp.path, 'respaldos'));
    final dir = await tester.runAsync(() => alm.abrirCarpeta('W580', _imei));
    await tester.runAsync(() => alm.registrar(RespaldoRollback(
        carpeta: dir!.path,
        modelo: 'W580',
        serie: _imei,
        fecha: DateTime.now(),
        cid: '52',
        color: 'RED',
        firmwareOriginal: 'R8BE001',
        shaFlash: '',
        bytesFlash: 0)));
    await tester.pumpWidget(_app(PantFabrica(telefono: _w580, almacen: alm)));
    for (var i = 0; i < 20; i++) {
      await _esperarIO(tester, 1);
    }
    expect(tester.takeException(), isNull);
    expect(find.textContaining('solo GDFS'), findsOneWidget);
  });
}
