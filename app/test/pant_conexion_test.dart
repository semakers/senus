// La pantalla Conexión contra el servicio con la plataforma falsa. [simulado].

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:senus_app/conexion/puente_nativo.dart';
import 'package:senus_app/conexion/servicio_conexion.dart';
import 'package:senus_app/datos/telefono.dart';
import 'package:senus_app/main.dart';
import 'package:senus_app/mtp/canal_gestion.dart';
import 'package:senus_app/mtp/sesion_mtp.dart';
import 'package:senus_app/tema/senus_tema.dart';
import 'package:senus_app/widgets/pant_conectar.dart';
import 'package:senus_app/widgets/pant_conexion.dart';

import 'apoyo/puente_falso.dart';
import 'apoyo/telefono_simulado.dart';

const dirTel = '01:02:03:04:05:06';

const telCanal = Telefono(
  modelo: Modelo.w580,
  nombreAmigo: 'W580 sistema propio',
  serie: 'S',
  versionSenew: '0.29.1+291',
  almacenes: [],
  canalGestion: true,
);

const telSinCanal = Telefono(
  modelo: Modelo.w580,
  nombreAmigo: 'W580 sistema propio',
  serie: 'S',
  versionSenew: 'S10',
  almacenes: [],
);

ServicioConexion servicio(PuenteNativo n, {File? f}) {
  final d = Directory.systemTemp.createTempSync('senus_g_');
  return ServicioConexion(
    nativo: n,
    ficheroPermitidos: () async => f ?? File('${d.path}/p'),
    pausaSondeo: const Duration(milliseconds: 5),
    graciaFallo: Duration.zero,
    plazoEmparejar: const Duration(seconds: 2),
  );
}

Widget marco(Widget h) => MaterialApp(
      theme: temaSenus(Brightness.dark),
      home: Scaffold(body: h),
    );

FilledButton boton(WidgetTester t, String clave) =>
    t.widget<FilledButton>(find.byKey(ValueKey(clave)));

/// Deja correr lo pendiente: el reloj del probador es falso, y los ficheros no.
Future<void> asentar(WidgetTester t) async {
  for (var i = 0; i < 12; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 4)));
    await t.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('sin puente en esta máquina lo explica y no ofrece nada', (t) async {
    final s = servicio(const PuenteNoDisponible());
    await t.pumpWidget(marco(PantConexion(conexion: s)));
    await asentar(t);
    expect(find.text('Sin puente en esta máquina'), findsOneWidget);
    expect(find.textContaining('macOS'), findsOneWidget);
    expect(find.byKey(const ValueKey('encenderServidor')), findsNothing);
    expect(find.byKey(const ValueKey('emparejar')), findsNothing);
  });

  testWidgets('permiso denegado: dice dónde se arregla', (t) async {
    final n = PuenteNativoFalso();
    n.estado = const EstadoBt(
        plataforma: true,
        hay: true,
        permiso: PermisoBt.denegado,
        encendido: false);
    await t.pumpWidget(marco(PantConexion(conexion: servicio(n))));
    await asentar(t);
    expect(find.textContaining('Privacidad y seguridad'), findsOneWidget);
  });

  testWidgets('emparejar solo con teléfono por USB, canal y servidor encendido',
      (t) async {
    final n = PuenteNativoFalso();
    final s = servicio(n);
    final tel = TelefonoSimulado()
      ..instalarYArrancar(ImagenConocida(mainDePrueba(291), 291, '0.29.1'));
    late SesionMtp m;
    await t.runAsync(() async => m = await PuertosSimulados(tel).conectar());

    // Sin cable.
    await t.pumpWidget(marco(PantConexion(conexion: s)));
    await asentar(t);
    expect(boton(t, 'emparejar').onPressed, isNull);
    expect(find.textContaining('Conecta el teléfono por el cable'), findsOneWidget);

    // Con cable y sin canal.
    await t.pumpWidget(
        marco(PantConexion(conexion: s, telefono: telSinCanal, sesion: m)));
    await t.pump();
    expect(boton(t, 'emparejar').onPressed, isNull);
    expect(find.textContaining('canal de gestión'), findsOneWidget);

    // Con canal y el servidor apagado.
    await t.pumpWidget(
        marco(PantConexion(conexion: s, telefono: telCanal, sesion: m)));
    await t.pump();
    expect(boton(t, 'emparejar').onPressed, isNull);
    expect(find.textContaining('Enciende antes'), findsOneWidget);

    // Encendido: ya.
    await t.tap(find.byKey(const ValueKey('encenderServidor')));
    await asentar(t);
    expect(find.text('Encendido'), findsOneWidget);
    expect(boton(t, 'emparejar').onPressed, isNotNull);
    await t.runAsync(s.cerrar);
  });

  testWidgets('emparejar acaba en «Puente listo» y con el teléfono en la lista',
      (t) async {
    final n = PuenteNativoFalso();
    final s = servicio(n);
    final tel = TelefonoSimulado()
      ..instalarYArrancar(ImagenConocida(mainDePrueba(291), 291, '0.29.1'));
    late SesionMtp m;
    await t.runAsync(() async => m = await PuertosSimulados(tel).conectar());
    tel.alEmparejar = (addr, pin) {
      n.emitir(const BtEmparejamiento(dirTel, 'hecho', 0));
      final c = n.llama(dirTel);
      c.manda(0x01, 0, c.hola());
      tel.btEstado = BtEstado(
          encendido: true,
          puenteConectado: true,
          redLista: true,
          fallo: 0,
          puenteAddr: Uint8List(6));
    };
    await t.pumpWidget(
        marco(PantConexion(conexion: s, telefono: telCanal, sesion: m)));
    await asentar(t);
    await t.tap(find.byKey(const ValueKey('encenderServidor')));
    await asentar(t);
    await t.tap(find.byKey(const ValueKey('emparejar')));
    await t.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await asentar(t);
    await asentar(t);
    expect(find.text('Puente listo: ya puedes quitar el cable'), findsOneWidget);
    expect(find.text('prueba'), findsOneWidget, reason: 'el teléfono conectado');
    expect(find.text('Teléfonos emparejados'), findsOneWidget);
    expect(find.byKey(const ValueKey('olvidar$dirTel')), findsOneWidget);
    expect(find.byKey(const ValueKey('velBaja')), findsOneWidget);
    await t.runAsync(s.cerrar);
  });

  testWidgets('un fallo se enseña con su motivo', (t) async {
    final n = PuenteNativoFalso();
    final s = servicio(n);
    final tel = TelefonoSimulado()
      ..instalarYArrancar(ImagenConocida(mainDePrueba(291), 291, '0.29.1'));
    tel.sinEmparejar = true;
    late SesionMtp m;
    await t.runAsync(() async => m = await PuertosSimulados(tel).conectar());
    await t.pumpWidget(
        marco(PantConexion(conexion: s, telefono: telCanal, sesion: m)));
    await asentar(t);
    await t.tap(find.byKey(const ValueKey('encenderServidor')));
    await asentar(t);
    await t.tap(find.byKey(const ValueKey('emparejar')));
    await asentar(t);
    expect(find.textContaining('0.29.1'), findsOneWidget);
    expect(find.text('Puente listo: ya puedes quitar el cable'), findsNothing);
    await t.runAsync(s.cerrar);
  });

  testWidgets('el hueco de H sale debajo', (t) async {
    await t.pumpWidget(marco(PantConexion(
      conexion: servicio(PuenteNativoFalso()),
      seccionServicios: const Text('DICTADO Y MÚSICA'),
    )));
    await asentar(t);
    await t.scrollUntilVisible(find.text('DICTADO Y MÚSICA'), 200);
    expect(find.text('DICTADO Y MÚSICA'), findsOneWidget);
  });

  testWidgets('sale en el menú con un teléfono con senew', (t) async {
    final tel = TelefonoSimulado()
      ..instalarYArrancar(ImagenConocida(mainDePrueba(291), 291, '0.29.1'));
    late SesionMtp m;
    await t.runAsync(() async => m = await PuertosSimulados(tel).conectar());
    t.view.physicalSize = const Size(1200, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    final s = servicio(PuenteNativoFalso());
    await t.pumpWidget(SenusApp(
        conexion: s, conexionInicial: ConexionViva(m, telCanal)));
    await t.pump(const Duration(milliseconds: 500));
    await t.tap(find.text('Conexión'));
    await asentar(t);
    expect(find.byType(PantConexion), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('sin cable también se llega: el puente no depende del USB', (t) async {
    t.view.physicalSize = const Size(1200, 1500);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    final s = servicio(PuenteNativoFalso());
    await t.pumpWidget(SenusApp(conexion: s));
    await t.pump(const Duration(milliseconds: 500));
    await t.tap(find.byKey(const ValueKey('abrirConexion')));
    await asentar(t);
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byType(PantConexion), findsOneWidget);
    await t.tap(find.text('Volver'));
    await t.pump(const Duration(milliseconds: 500));
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byType(PantConectar), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
}
