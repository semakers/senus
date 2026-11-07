// Capturas de las pantallas de SENUS, para revisar el diseño sin tener que
// mirar la pantalla de la máquina. Recorre la app de verdad contra el
// bridge_mock (socket) y guarda un PNG por pantalla y tema en test/capturas/.
//
//   python3 experimentos/bridge_mock.py --socket /tmp/senus-mock-capturas.sock &
//   SENUS_TRANSPORTE=socket:/tmp/senus-mock-capturas.sock \
//   SENUS_BACKEND=http://127.0.0.1:8600 \
//     flutter test --dart-define=SENUS_DESARROLLO=true --update-goldens \
//     --tags capturas test/capturas_test.dart
//
// Sin SENUS_TRANSPORTE el test se salta.

@Tags(['capturas'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:senus_app/main.dart';

Future<void> _cargarFuentes() async {
  final manifiesto = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final f in manifiesto.cast<Map<String, dynamic>>()) {
    final cargador = FontLoader(f['family'] as String);
    for (final a in (f['fonts'] as List).cast<Map<String, dynamic>>()) {
      cargador.addFont(rootBundle.load(a['asset'] as String));
    }
    await cargador.load();
  }
}

/// Deja correr la E/S real (socket) y luego los fotogramas de las animaciones.
Future<void> _esperar(WidgetTester t, {int ms = 600}) async {
  await t.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
  for (var i = 0; i < 12; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// Alterna E/S real y fotogramas hasta que aparezca `f` (o 15 s).
Future<void> _hasta(WidgetTester t, Finder f) async {
  for (var i = 0; i < 150 && f.evaluate().isEmpty; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await t.pump(const Duration(milliseconds: 50));
  }
  await _esperar(t, ms: 100);
}

Future<void> _foto(WidgetTester t, String nombre) async {
  await expectLater(find.byType(SenusApp), matchesGoldenFile('capturas/$nombre.png'));
}

void main() {
  final hayMock = (Platform.environment['SENUS_TRANSPORTE'] ?? '').startsWith('socket:');

  setUpAll(_cargarFuentes);

  for (final claro in [false, true]) {
    final sufijo = claro ? 'claro' : 'oscuro';
    testWidgets('recorrido $sufijo', (t) async {
      t.view.physicalSize = const Size(2560, 1600);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);

      await t.pumpWidget(const SenusApp());
      await _esperar(t);
      if (claro) {
        await t.tap(find.byTooltip('Modo claro'));
        await _esperar(t);
      }
      await _foto(t, '1_conectar_$sufijo');

      await t.tap(find.text('Conectar'));
      await _hasta(t, find.text('ALMACENAMIENTO'));
      await _foto(t, '2_inicio_$sufijo');

      await t.tap(find.text('Catálogo').first);
      await _hasta(t, find.text('Instalar'));
      await _foto(t, '3_catalogo_$sufijo');
      if (!claro) {
        // Instalar la primera app: estado «Instalada ✓».
        await t.tap(find.text('Instalar').first);
        await _hasta(t, find.text('Instalada'));
        await _foto(t, '3b_catalogo_instalada_$sufijo');
      }

      await t.tap(find.text('Apps').first);
      await _hasta(t, find.byTooltip('Bajar a la computadora'));
      await _foto(t, '4_apps_$sufijo');

      await t.tap(find.text('Respaldo').first);
      await _esperar(t, ms: 400);
      await _foto(t, '5_respaldo_$sufijo');

      await t.tap(find.text('Fábrica'));
      await _esperar(t, ms: 200);
      await _foto(t, '6_fabrica_$sufijo');

      await t.tap(find.text('Ajustes de SENUS'));
      await _esperar(t, ms: 200);
      await _foto(t, '7_ajustes_$sufijo');

      await t.tap(find.byTooltip('Desconectar'));
      await _esperar(t, ms: 600);
    }, skip: !hayMock);
  }
}
