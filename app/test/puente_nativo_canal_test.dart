// Lo que `PuenteNativoPlataforma` pone en el canal `senus/puente_bt` para las órdenes
// nuevas, con el otro extremo falso. [simulado]: dice que Dart manda lo que
// PuenteBluetoothCanal.swift lee (nombre, claves y tipos), no que macOS haga nada.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:senus_app/conexion/puente_nativo.dart';
import 'package:senus_app/conexion/servicio_conexion.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const canal = MethodChannel('senus/puente_bt');
  final mensajero =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final vistas = <MethodCall>[];

  setUp(() => vistas.clear());
  tearDown(() => mensajero.setMockMethodCallHandler(canal, null));

  test('vigilar manda la lista y el canal como los lee el Swift', () async {
    mensajero.setMockMethodCallHandler(canal, (c) async {
      vistas.add(c);
      return null;
    });
    await PuenteNativoPlataforma()
        .vigilar(['01:02:03:04:05:06', 'AA:AA:AA:AA:AA:AA'], canalTelefono);
    final c = vistas.single;
    expect(c.method, 'vigilar');
    final a = c.arguments as Map<Object?, Object?>;
    expect(a.keys.toSet(), {'direcciones', 'canal'});
    expect(a['direcciones'], ['01:02:03:04:05:06', 'AA:AA:AA:AA:AA:AA']);
    expect(a['canal'], 7);
  });

  test('un canal que el Swift rechaza llega como FalloNativo con su código',
      () async {
    mensajero.setMockMethodCallHandler(canal, (c) async {
      throw PlatformException(code: 'canal', message: 'canalMalo');
    });
    await expectLater(
        PuenteNativoPlataforma().vigilar(const [], 31),
        throwsA(isA<FalloNativo>()
            .having((e) => e.codigo, 'codigo', 'canal')));
  });

  test('sin el lado nativo, vigilar dice «no disponible»', () async {
    await expectLater(PuenteNativoPlataforma().vigilar(const [], 7),
        throwsA(isA<FalloNativo>()
            .having((e) => e.codigo, 'codigo', 'no_disponible')));
  });

  test('donde no hay puente, vigilar no rompe', () async {
    await const PuenteNoDisponible().vigilar(const ['01:02:03:04:05:06'], 7);
  });
}
