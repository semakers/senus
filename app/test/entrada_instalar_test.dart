// «Mi W580 todavía no tiene senew»: la pantalla de conexión tiene que
// INVITAR a instalarlo, y llevar derecho a la instalación (no a Fábrica ni a
// una pantalla que dé por hecho que el teléfono ya corre senew).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:senus_app/datos/telefono.dart';
import 'package:senus_app/main.dart';

/// Las fuentes reales (Inter): la de prueba de Flutter es muy ancha y da
/// desbordamientos que en la app no existen.
Future<void> _cargarFuentes() async {
  final man =
      jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final f in man.cast<Map<String, dynamic>>()) {
    final c = FontLoader(f['family'] as String);
    for (final a in (f['fonts'] as List).cast<Map<String, dynamic>>()) {
      c.addFont(rootBundle.load(a['asset'] as String));
    }
    await c.load();
  }
}

Future<void> _bombear(WidgetTester tester, [int veces = 12]) async {
  for (var i = 0; i < veces; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  test('qué aparatos entran en el flujo nuevo', () {
    expect(Telefono.fabricaSinIdentificar.entraEnInstalacionInicial, isTrue);
    Telefono t({Modelo m = Modelo.w580, String? cid, bool fabrica = true}) =>
        Telefono(
          modelo: m,
          nombreAmigo: 'x',
          serie: '1',
          versionSenew: '—',
          almacenes: const [],
          deFabrica: fabrica,
          cid: cid,
        );
    expect(t(cid: '52').entraEnInstalacionInicial, isTrue);
    expect(t(cid: '53').entraEnInstalacionInicial, isFalse);
    expect(t(m: Modelo.w600, cid: '49').entraEnInstalacionInicial, isFalse);
    expect(t(m: Modelo.w810).entraEnInstalacionInicial, isFalse);
    expect(t(cid: '52', fabrica: false).entraEnInstalacionInicial, isFalse,
        reason: 'un teléfono que ya corre senew no es «primera instalación»');
  });

  testWidgets(
      'la pantalla de conexión invita a instalar senew y lleva derecho a la instalación',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.runAsync(_cargarFuentes);
    await tester.pumpWidget(const SenusApp());
    await _bombear(tester, 6);

    // La invitación está a la vista desde el primer momento.
    expect(find.text('¿Tu W580 todavía no tiene senew?'), findsOneWidget);
    final boton = find.byKey(const ValueKey('instalarSenew'));
    expect(boton, findsOneWidget);

    await tester.ensureVisible(boton);
    await tester.tap(boton);
    await _bombear(tester, 14);

    // Se aterriza en la instalación, con «Instalar senew» primero en el menú
    // y sin la pantalla heredada.
    expect(find.text('Instalar senew'), findsNWidgets(2),
        reason: 'una vez en el menú y otra como título de la pantalla');
    expect(find.text('Primera instalación'), findsNothing);
    expect(find.text('Instalación inicial'), findsNothing);
    // En macOS y Windows se enseña el plan; en el resto, «próximamente».
    expect(find.text(Platform.isMacOS || Platform.isWindows ? 'Qué va a pasar' : 'Próximamente'),
        findsOneWidget);
    // Y sigue estando «Fábrica» (respaldo) para quien lo busque.
    expect(find.text('Fábrica'), findsOneWidget);
  });
}
