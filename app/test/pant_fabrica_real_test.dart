// La pantalla de respaldo en MODO REAL (sin SENUS_TRANSPORTE): tiene que
// salir el campo del puerto serie, y no debe ejecutarse NADA por su cuenta.
//
// Este fichero se corre SIN SENUS_TRANSPORTE a propósito:
//   flutter test test/pant_fabrica_real_test.dart
// Si se corre con SENUS_TRANSPORTE=socket:… se salta solo, porque entonces
// la pantalla está —con razón— en modo simulado.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:senus_app/datos/respaldo_rollback.dart';
import 'package:senus_app/datos/telefono.dart';
import 'package:senus_app/tema/senus_tema.dart';
import 'package:senus_app/widgets/pant_fabrica.dart';

const _fabrica = Telefono(
  modelo: Modelo.w580,
  nombreAmigo: 'W580 de fábrica',
  serie: '35697201234567',
  versionSenew: '—',
  almacenes: [],
  deFabrica: true,
  cid: '53',
  color: 'RED',
  firmwareOriginal: 'R8BE001',
  puertoSerie: '/dev/ttyUSB-de-mentira',
);

void main() {
  testWidgets('en modo real sale el puerto, y sale el del aparato',
      (tester) async {
    if (EjecutorRespaldo.decidirSimulado()) {
      markTestSkipped(
          'Hay SENUS_TRANSPORTE=${Platform.environment['SENUS_TRANSPORTE']}: '
          'la pantalla está en modo simulado y este test no aplica.');
      return;
    }

    // Ventana grande: en 800x600 el botón queda bajo el pliegue y el
    // ListView ni lo construye.
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      theme: temaSenus(Brightness.dark),
      home: const Scaffold(body: PantFabrica(telefono: _fabrica)),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Puerto serie del cable'), findsOneWidget);
    // El puerto por el que el aparato ya contestó manda sobre la
    // autodetección.
    expect(find.text('/dev/ttyUSB-de-mentira'), findsOneWidget);

    // Los tres pasos siguen ahí y en «pendiente»: nada ha arrancado solo.
    expect(find.text('Identificar el aparato'), findsOneWidget);
    expect(find.text('Respaldo del firmware'), findsOneWidget);
    expect(find.text('Copia en otro equipo (opcional)'), findsOneWidget);
    expect(find.text('Empezar respaldo'), findsOneWidget);
    expect(find.textContaining('pendiente'), findsWidgets);
  });
}
