// Las pantallas nuevas contra el teléfono y el backend simulados, por sus
// gestos: se pulsa lo que se pulsaría. La E/S de disco del backend es real, así
// que la carga corre dentro de `runAsync`.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:senus_app/datos/actualizacion_senew.dart';
import 'package:senus_app/datos/ajustes_senew.dart';
import 'package:senus_app/datos/apps_telefono.dart' show textoBytes;
import 'package:senus_app/datos/backend_semakers.dart';
import 'package:senus_app/datos/conexion_telefono.dart';
import 'package:senus_app/datos/telefono.dart';
import 'package:senus_app/main.dart';
import 'package:senus_app/mtp/canal_datos.dart';
import 'package:senus_app/mtp/operaciones.dart';
import 'package:senus_app/mtp/sesion_mtp.dart';
import 'package:senus_app/tema/senus_tema.dart';
import 'package:senus_app/widgets/pant_ajustes_telefono.dart';
import 'package:senus_app/widgets/comunes.dart';
import 'package:senus_app/widgets/pant_apps.dart';
import 'package:senus_app/widgets/pant_catalogo.dart';
import 'package:senus_app/widgets/pant_conectar.dart';
import 'package:senus_app/widgets/pant_inicio.dart';
import 'package:senus_app/widgets/pant_recuperacion.dart';
import 'package:senus_app/widgets/pant_version.dart';

import 'apoyo/backend_simulado.dart';
import 'apoyo/telefono_simulado.dart';

const imei = '35000000000009';

class Banco {
  final TelefonoSimulado tel = TelefonoSimulado();
  final Directory dir = Directory.systemTemp.createTempSync('senus_ui_');
  final RedSimulada red = RedSimulada();
  late final Publicador pub = Publicador(red);
  late final ClienteBackend backend = ClienteBackend(
    red: red,
    cache: Directory(p.join(dir.path, 'cache')),
    claves: [publica],
    ahora: () => DateTime.utc(2026, 11, 1),
  );
  late final PuertosSimulados puertos = PuertosSimulados(tel);
  late final AlmacenActualizacion almacen =
      AlmacenActualizacion(Directory(p.join(dir.path, 'act')));
  late final ContextoActualizacion contexto = ContextoActualizacion(
      backend: backend, puertos: puertos, almacen: almacen);
  late SesionMtp sesion;
  late Telefono telefono;

  Banco({bool canal = true}) {
    tel.instalarYArrancar(
        ImagenConocida(mainDePrueba(290), 290, '0.29.0', canal: canal));
    tel.idAparato = canal ? imei : '';
  }

  Future<void> conectar() async {
    sesion = await puertos.conectar();
    telefono = (await leerTelefono(sesion)).valor!;
  }

  void limpiar() => dir.deleteSync(recursive: true);
}

Future<void> montar(WidgetTester t, Widget w,
    {Size tam = const Size(1600, 1400)}) async {
  t.view.physicalSize = tam;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: temaSenus(Brightness.dark),
    home: Scaffold(body: w),
  ));
}

/// Alterna E/S real y fotogramas hasta que aparezca `f`.
Future<void> hasta(WidgetTester t, Finder f, {int vueltas = 200}) async {
  for (var i = 0; i < vueltas && f.evaluate().isEmpty; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await t.pump(const Duration(milliseconds: 16));
  }
  expect(f, findsWidgets, reason: 'no apareció');
}

Future<void> asentar(WidgetTester t) async {
  for (var i = 0; i < 20; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await t.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  group('Apps', () {
    testWidgets('origen, versión, y solo se quita lo que se puede', (t) async {
      final b = Banco();
      addTearDown(b.limpiar);
      await t.runAsync(() async {
        b.tel.appsFabrica.add(const SenApp(
          origen: 0,
          banderas: 1,
          perfil: 1,
          iconoGen: 4,
          iconoAn: 16,
          apiMayor: 1,
          apiMenor: 7,
          verApp: 2,
          tam: 2048,
          iconoFilas: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
          nombre: 'Música',
          fichero: 'musica.sen',
        ));
        b.tel.crearFichero(
            storageMemoria,
            b.tel.carpeta(storageMemoria, 'apps')!.handle,
            'calc.sen',
            senDePrueba(verApp: 1, nombre: 'Calculadora'));
        b.pub.publicarApp('calc', senDePrueba(verApp: 2, nombre: 'Calculadora'),
            nombre: 'Calculadora');
        b.pub.firmarIndice();
        await b.conectar();
      });
      await montar(
          t,
          PantApps(
              telefono: b.telefono, sesion: b.sesion, backend: b.backend));
      await hasta(t, find.text('Música'));
      await hasta(t, find.text('nueva: v2'));
      expect(find.text('De fábrica'), findsOneWidget);
      expect(find.text('Memoria'), findsOneWidget);
      expect(find.text('Calculadora'), findsOneWidget);
      expect(find.byTooltip('Quitar del teléfono'), findsOneWidget);
      expect(find.byTooltip('Protegida: es de fábrica, no se puede quitar'),
          findsOneWidget);

      // Actualizar de verdad.
      await t.tap(find.text('Actualizar'));
      await hasta(t, find.textContaining('Actualizada y comprobada'));
      await asentar(t);
      final o = b.tel.objetos.values.firstWhere((x) => x.nombre == 'calc.sen');
      expect(ByteData.sublistView(o.datos).getUint32(52, Endian.little), 2);
      expect(find.text('nueva: v2'), findsNothing);
    });

    testWidgets('tapada: la fila de la tarjeta lo arregla, la tapada lo dice',
        (t) async {
      final b = Banco();
      addTearDown(b.limpiar);
      await t.runAsync(() async {
        b.tel.hayTarjeta = true;
        final tj = b.tel.crearCarpeta(storageTarjeta, 'apps');
        b.tel.crearFichero(storageTarjeta, tj.handle, 'teclas.sen',
            senDePrueba(verApp: 1, nombre: 'Teclas'));
        b.tel.crearFichero(
            storageMemoria,
            b.tel.carpeta(storageMemoria, 'apps')!.handle,
            'teclas.sen',
            senDePrueba(verApp: 2, nombre: 'Teclas'));
        b.pub.publicarApp('teclas', senDePrueba(verApp: 2, nombre: 'Teclas'),
            nombre: 'Teclas');
        b.pub.firmarIndice();
        await b.conectar();
      });
      await montar(
          t, PantApps(telefono: b.telefono, sesion: b.sesion, backend: b.backend));
      await hasta(t, find.text('Quitar la copia de la tarjeta'));
      await asentar(t);
      expect(find.text('Actualizar'), findsNothing);
      expect(find.text('manda la de Tarjeta'), findsOneWidget);
      await t.tap(find.text('Quitar la copia de la tarjeta'));
      await hasta(t, find.text('Quitar'));
      await t.tap(find.text('Quitar'));
      await hasta(t, find.textContaining('ya manda la copia de la Memoria'));
      await asentar(t);
      expect(find.text('Quitar la copia de la tarjeta'), findsNothing);
      expect(find.text('manda la de Tarjeta'), findsNothing);
    });

    testWidgets('sin canal avisa y lista lo que ve', (t) async {
      final b = Banco(canal: false);
      addTearDown(b.limpiar);
      await t.runAsync(() async {
        b.tel.crearFichero(
            storageMemoria,
            b.tel.carpeta(storageMemoria, 'apps')!.handle,
            'calc.sen',
            senDePrueba(nombre: 'Calculadora'));
        await b.conectar();
      });
      await montar(
          t,
          PantApps(
              telefono: b.telefono, sesion: b.sesion, backend: b.backend));
      await hasta(t, find.text('Calculadora'));
      expect(find.textContaining('no tiene canal de gestión'), findsOneWidget);
    });
  });

  group('Catálogo', () {
    testWidgets('instala contra el backend y relee', (t) async {
      final b = Banco();
      addTearDown(b.limpiar);
      final sen = senDePrueba(verApp: 4, nombre: 'Calculadora');
      await t.runAsync(() async {
        b.pub.publicarApp('calc', sen, nombre: 'Calculadora');
        b.pub.firmarIndice();
        await b.conectar();
      });
      await montar(
          t,
          PantCatalogo(
              telefono: b.telefono, sesion: b.sesion, backend: b.backend));
      await hasta(t, find.text('Instalar'));
      expect(find.text('Calculadora'), findsOneWidget);
      await t.tap(find.text('Instalar'));
      await hasta(t, find.textContaining('Instalada y comprobada'));
      await asentar(t);
      expect(find.text('Instalada'), findsOneWidget);
      final o = b.tel.objetos.values.firstWhere((x) => x.nombre == 'calc.sen');
      expect(o.datos, sen);
    });

    testWidgets('relectura distinta: lo dice y no la da por instalada',
        (t) async {
      final b = Banco();
      addTearDown(b.limpiar);
      await t.runAsync(() async {
        b.pub.publicarApp('calc', senDePrueba(), nombre: 'Calculadora');
        b.pub.firmarIndice();
        await b.conectar();
      });
      await montar(
          t,
          PantCatalogo(
              telefono: b.telefono, sesion: b.sesion, backend: b.backend));
      await hasta(t, find.text('Instalar'));
      b.tel.corromperAlGuardar = true;
      await t.tap(find.text('Instalar'));
      await hasta(t, find.textContaining('no es lo que se subió'));
      await asentar(t);
      expect(find.text('Instalar'), findsOneWidget);
    });

    testWidgets('tapada por la tarjeta: lo explica y el botón lo arregla',
        (t) async {
      final b = Banco();
      addTearDown(b.limpiar);
      await t.runAsync(() async {
        b.tel.hayTarjeta = true;
        final tj = b.tel.crearCarpeta(storageTarjeta, 'apps');
        b.tel.crearFichero(storageTarjeta, tj.handle, 'teclas.sen',
            senDePrueba(verApp: 1, nombre: 'Teclas'));
        b.tel.crearFichero(
            storageMemoria,
            b.tel.carpeta(storageMemoria, 'apps')!.handle,
            'teclas.sen',
            senDePrueba(verApp: 2, nombre: 'Teclas'));
        b.pub.publicarApp('teclas', senDePrueba(verApp: 2, nombre: 'Teclas'),
            nombre: 'Teclas');
        b.pub.firmarIndice();
        await b.conectar();
      });
      await montar(
          t,
          PantCatalogo(
              telefono: b.telefono, sesion: b.sesion, backend: b.backend));
      await hasta(t, find.text('Quitar la copia de la tarjeta'));
      expect(find.textContaining('pero manda la copia de la tarjeta'),
          findsOneWidget);
      expect(find.text('Actualizar'), findsNothing,
          reason: 'nunca un botón que no cambia nada');
      await t.tap(find.text('Quitar la copia de la tarjeta'));
      await hasta(t, find.text('Quitar'));
      await t.tap(find.text('Quitar'));
      await hasta(t, find.textContaining('ya manda la copia de la Memoria'));
      await asentar(t);
      expect(find.text('Instalada'), findsOneWidget);
      expect(
          b.tel.objetos.values.where((o) => o.almacen == storageTarjeta && !o.carpeta),
          isEmpty);
    });

    testWidgets('sin red y con caché: avisa', (t) async {
      final b = Banco();
      addTearDown(b.limpiar);
      await t.runAsync(() async {
        b.pub.publicarApp('calc', senDePrueba(), nombre: 'Calculadora');
        b.pub.firmarIndice();
        await b.backend.indice();
        b.red.caido = true;
        await b.conectar();
      });
      await montar(
          t,
          PantCatalogo(
              telefono: b.telefono, sesion: b.sesion, backend: b.backend));
      await hasta(t, find.textContaining('Sin conexión'));
      expect(find.text('Calculadora'), findsOneWidget);
    });

    testWidgets('índice mal firmado y sin caché: no enseña nada', (t) async {
      final b = Banco();
      addTearDown(b.limpiar);
      await t.runAsync(() async {
        b.pub.publicarApp('calc', senDePrueba(), nombre: 'Calculadora');
        b.pub.firmarIndice(clave: claveDeSemilla(Uint8List(32)));
        await b.conectar();
      });
      await montar(
          t,
          PantCatalogo(
              telefono: b.telefono, sesion: b.sesion, backend: b.backend));
      await hasta(t, find.textContaining('no se puede usar'));
      expect(find.text('Calculadora'), findsNothing);
    });
  });

  group('Catálogo: juegos con datos en la tarjeta', () {
    Uint8List rel(int n, int k) =>
        Uint8List.fromList(List.generate(n, (i) => (i * 13 + k) & 0xFF));
    final datos = DatosPublicar('juego', {
      'nivel01.dat': rel(90000, 1),
      'nivel01.lvl': rel(3000, 2),
      'nivel02.dat': rel(20000, 3),
    });
    final sen = senDePrueba(nombre: 'Juego', perfil: 2);

    Future<Banco> banco(WidgetTester t, {bool tarjeta = true}) async {
      final b = Banco();
      addTearDown(b.limpiar);
      await t.runAsync(() async {
        b.tel.hayTarjeta = tarjeta;
        b.pub.publicarApp('juego', sen,
            nombre: 'Juego', destino: 'juegos', datos: datos);
        b.pub.firmarIndice();
        await b.conectar();
      });
      return b;
    }

    Objeto? juegos(Banco b) => b.tel.hijo(storageTarjeta, handleRaiz, 'juegos');

    testWidgets('dice «juego» y el tamaño total; instala y se quita desde aquí',
        (t) async {
      final b = await banco(t);
      await montar(t,
          PantCatalogo(telefono: b.telefono, sesion: b.sesion, backend: b.backend));
      await hasta(t, find.text('Instalar'));
      expect(find.text('juego'), findsOneWidget);
      expect(find.text(textoBytes(sen.length + datos.bytes)), findsOneWidget);
      expect(find.byTooltip('Quitar de la tarjeta'), findsNothing,
          reason: 'no hay nada que quitar');
      await t.tap(find.text('Instalar'));
      await hasta(t, find.textContaining('Instalado y comprobado en la tarjeta'));
      await asentar(t);
      expect(find.text('Instalada'), findsOneWidget);
      final j = juegos(b)!;
      expect(b.tel.hijo(storageTarjeta, j.handle, 'juego.sen')!.datos, sen);
      expect(b.tel.registro.last, 'subido juego.sen');

      await t.tap(find.byTooltip('Quitar de la tarjeta'));
      await hasta(t, find.text('Quitar'));
      expect(find.textContaining('/juegos/juego con sus 3 datos'), findsOneWidget);
      await t.tap(find.text('Quitar'));
      await hasta(t, find.textContaining('Quitado de la tarjeta'));
      await asentar(t);
      expect(find.text('Instalar'), findsOneWidget);
      expect(b.tel.hijo(storageTarjeta, j.handle, 'juego.sen'), isNull);
      expect(b.tel.hijo(storageTarjeta, j.handle, 'juego'), isNull);
    });

    testWidgets('sin tarjeta: «Necesita una tarjeta» y ningún botón', (t) async {
      final b = await banco(t, tarjeta: false);
      await montar(t,
          PantCatalogo(telefono: b.telefono, sesion: b.sesion, backend: b.backend));
      await hasta(t, find.text('Necesita una tarjeta'));
      await asentar(t);
      expect(find.text('Necesita una tarjeta'), findsOneWidget);
      expect(find.text('Instalar'), findsNothing);
      expect(find.byTooltip('Quitar de la tarjeta'), findsNothing);
    });

    testWidgets('incompleto: lo dice y «Reinstalar» lo termina', (t) async {
      final b = await banco(t);
      await t.runAsync(() async {
        final j = b.tel.crearCarpeta(storageTarjeta, 'juegos');
        final c = b.tel.crearCarpeta(storageTarjeta, 'juego', padre: j.handle);
        b.tel.crearFichero(storageTarjeta, j.handle, 'juego.sen', sen);
        b.tel.crearFichero(
            storageTarjeta, c.handle, 'nivel01.dat', datos.archivos['nivel01.dat']!);
        b.tel.crearFichero(
            storageTarjeta, c.handle, 'nivel01.lvl', datos.archivos['nivel01.lvl']!);
      });
      await montar(t,
          PantCatalogo(telefono: b.telefono, sesion: b.sesion, backend: b.backend));
      await hasta(t, find.text('Reinstalar'));
      expect(find.text('Incompleto: falta 1 de 3 datos'), findsOneWidget);
      expect(find.byTooltip('Quitar de la tarjeta'), findsOneWidget);
      await t.tap(find.text('Reinstalar'));
      await hasta(t, find.textContaining('Instalado y comprobado en la tarjeta'));
      await asentar(t);
      expect(find.text('Instalada'), findsOneWidget);
      expect(find.textContaining('Incompleto'), findsNothing);
      // El .sen que había sale antes de escribir el dato que falta.
      expect(b.tel.registro,
          ['borrado juego.sen', 'subido nivel02.dat', 'subido juego.sen']);
    });
  });

  group('Ajustes del teléfono', () {
    testWidgets('los 26, en grupos; aplica, relee y enseña lo que no entró',
        (t) async {
      final b = Banco();
      addTearDown(b.limpiar);
      await t.runAsync(b.conectar);
      await montar(t, PantAjustesTelefono(telefono: b.telefono, sesion: b.sesion));
      await hasta(t, find.text('Formato de 12 horas'));
      for (final g in ['RELOJ Y ALARMA', 'PANTALLA', 'SONIDO']) {
        expect(find.text(g), findsOneWidget);
      }
      expect(find.text('Sin cambios'), findsOneWidget);

      // Un interruptor de verdad.
      await t.tap(find.descendant(
          of: find.byKey(const ValueKey(ClaveAj.hora12)),
          matching: find.byType(Switch)));
      await t.pump();
      expect(find.text('Aplicar 1'), findsOneWidget);

      // El firmware dirá que sí y no lo guardará.
      b.tel.ajusteQueNoSeGuarda = ClaveAj.hora12;
      await t.tap(find.text('Aplicar 1'));
      await hasta(t, find.textContaining('No se aplicó todo'));
      expect(find.textContaining('Formato de 12 horas: se pidió sí'), findsOneWidget);

      // Sin el fallo, se aplica y se comprueba.
      b.tel.ajusteQueNoSeGuarda = null;
      await t.tap(find.descendant(
          of: find.byKey(const ValueKey(ClaveAj.hora12)),
          matching: find.byType(Switch)));
      await t.pump();
      await t.tap(find.text('Aplicar 1'));
      await hasta(t, find.text('1 ajuste aplicado y comprobado al releerlo.'));
      expect(b.tel.ajustes.firstWhere((a) => a.clave == ClaveAj.hora12).valor,
          isTrue);
    });

    testWidgets('los 26 están en la pantalla', (t) async {
      final b = Banco();
      addTearDown(b.limpiar);
      await t.runAsync(b.conectar);
      await montar(t, PantAjustesTelefono(telefono: b.telefono, sesion: b.sesion));
      await hasta(t, find.text('Formato de 12 horas'));
      for (final d in defsAjustes) {
        await t.dragUntilVisible(find.byKey(ValueKey(d.clave)),
            find.byType(ListView), const Offset(0, -200));
        expect(find.text(d.nombre), findsOneWidget, reason: d.campo);
      }
    });

    testWidgets('poner la hora: un botón', (t) async {
      final b = Banco();
      addTearDown(b.limpiar);
      await t.runAsync(b.conectar);
      final hora = DateTime.utc(2026, 11, 1, 6, 30);
      await montar(
          t,
          PantAjustesTelefono(
              telefono: b.telefono, sesion: b.sesion, ahora: () => hora));
      await hasta(t, find.text('Poner la hora'));
      await t.tap(find.text('Poner la hora'));
      await hasta(t, find.textContaining('Hora puesta'));
      expect(b.tel.utcPuesto, hora.millisecondsSinceEpoch ~/ 1000);
    });

    testWidgets('poner la hora no tira lo que está sin aplicar', (t) async {
      final b = Banco();
      addTearDown(b.limpiar);
      await t.runAsync(b.conectar);
      await montar(t, PantAjustesTelefono(telefono: b.telefono, sesion: b.sesion));
      await hasta(t, find.text('Poner la hora'));
      await t.tap(find.descendant(
          of: find.byKey(const ValueKey(ClaveAj.hora12)),
          matching: find.byType(Switch)));
      await t.pump();
      expect(find.text('Aplicar 1'), findsOneWidget);
      await t.tap(find.text('Poner la hora'));
      await hasta(t, find.textContaining('Hora puesta'));
      await asentar(t);
      expect(find.text('Aplicar 1'), findsOneWidget);
    });

    testWidgets('sin canal: pide actualizar, no se rompe', (t) async {
      final b = Banco(canal: false);
      addTearDown(b.limpiar);
      await t.runAsync(b.conectar);
      var pulsado = false;
      await montar(
          t,
          PantAjustesTelefono(
              telefono: b.telefono,
              sesion: b.sesion,
              onVersion: () => pulsado = true));
      await hasta(t, find.text('Hay que actualizar senew'));
      await t.tap(find.text('Ver versión'));
      expect(pulsado, isTrue);
    });
  });

  group('Versión', () {
    testWidgets('«Actualizar» recorre el flujo y vuelve con sesión', (t) async {
      final b = Banco();
      addTearDown(b.limpiar);
      SesionMtp? nueva;
      await t.runAsync(() async {
        final m = ImagenConocida(mainDePrueba(291), 291, '0.29.1');
        b.tel.anadirImagen(m);
        b.pub.publicarSenew(291, '0.29.1', m.bytes);
        b.pub.firmarIndice();
        await b.conectar();
      });
      await montar(
          t,
          PantVersion(
            telefono: b.telefono,
            sesion: b.sesion,
            contexto: b.contexto,
            onSesionNueva: (s, _) => nueva = s,
          ));
      await hasta(t, find.text('Actualizar a 0.29.1'));
      expect(find.text('0.29.0 (build 290)'), findsOneWidget);
      await t.tap(find.text('Actualizar a 0.29.1'));
      await hasta(t, find.text('Actualizar senew'));
      await t.tap(find.text('Instalar').last);
      await hasta(t, find.textContaining('Listo: build 291'), vueltas: 2000);
      expect(b.tel.corriendo?.build, 291);
      expect(nueva, isNotNull);
      expect(b.tel.escrituras.last, 0x44180000);
    });

    testWidgets('sin batería medible, la persona confirma el 30 %', (t) async {
      final b = Banco();
      addTearDown(b.limpiar);
      await t.runAsync(() async {
        final m = ImagenConocida(mainDePrueba(291), 291, '0.29.1');
        b.tel.anadirImagen(m);
        b.pub.publicarSenew(291, '0.29.1', m.bytes);
        b.pub.firmarIndice();
        b.tel.bateria = 0xFF;
        await b.conectar();
      });
      await montar(
          t,
          PantVersion(
              telefono: b.telefono, sesion: b.sesion, contexto: b.contexto));
      await hasta(t, find.text('Actualizar a 0.29.1'));
      await t.tap(find.text('Actualizar a 0.29.1'));
      await hasta(t, find.text('Actualizar senew'));
      await t.tap(find.text('Instalar').last);
      await hasta(t, find.text('Mira la batería del teléfono'));
      await t.tap(find.text('No, cancelar'));
      await hasta(t, find.textContaining('no se sigue'));
      await asentar(t);
      expect(b.tel.wipes, isEmpty);
    });

    testWidgets('una versión anterior avisa de que va hacia atrás', (t) async {
      final b = Banco();
      addTearDown(b.limpiar);
      await t.runAsync(() async {
        final m = ImagenConocida(mainDePrueba(280), 280, '0.28.0');
        b.tel.anadirImagen(m);
        b.pub.publicarSenew(280, '0.28.0', m.bytes);
        b.pub.firmarIndice();
        await b.conectar();
      });
      await montar(
          t,
          PantVersion(
              telefono: b.telefono, sesion: b.sesion, contexto: b.contexto));
      await hasta(t, find.text('Volver a esta'));
      expect(find.text('anterior'), findsOneWidget);
      expect(find.textContaining('Actualizar a'), findsNothing);
      await t.tap(find.text('Volver a esta'));
      await hasta(t, find.text('Vas hacia atrás'));
      expect(find.textContaining('ANTERIOR'), findsOneWidget);
      await t.tap(find.text('Cancelar'));
      await hasta(t, find.textContaining('Cancelado'));
      expect(b.tel.wipes, isEmpty);
    });

    testWidgets('en la espera del paso 12 se ve el aviso de «Encendido»',
        (t) async {
      final b = Banco();
      addTearDown(b.limpiar);
      final soltar = Completer<void>();
      await t.runAsync(() async {
        final m = ImagenConocida(mainDePrueba(291), 291, '0.29.1');
        b.tel.anadirImagen(m);
        b.pub.publicarSenew(291, '0.29.1', m.bytes);
        b.pub.firmarIndice();
        await b.conectar();
      });
      b.puertos.alEsperarSenew = () => soltar.future;
      await montar(
          t,
          PantVersion(
              telefono: b.telefono, sesion: b.sesion, contexto: b.contexto));
      await hasta(t, find.text('Actualizar a 0.29.1'));
      await t.tap(find.text('Actualizar a 0.29.1'));
      await hasta(t, find.text('Actualizar senew'));
      await t.tap(find.text('Instalar').last);
      await hasta(t, find.textContaining('no pulses OK'), vueltas: 2000);
      soltar.complete();
      await hasta(t, find.textContaining('Listo: build 291'), vueltas: 2000);
      await asentar(t);
      expect(find.textContaining('no pulses OK'), findsNothing);
    });

    testWidgets('no vuelve: aviso tranquilo, sin grabar otra vez ni recuperar',
        (t) async {
      final b = Banco();
      addTearDown(b.limpiar);
      var conectar = false;
      await t.runAsync(() async {
        final m = ImagenConocida(mainDePrueba(291), 291, '0.29.1');
        b.tel.anadirImagen(m);
        b.pub.publicarSenew(291, '0.29.1', m.bytes);
        b.pub.firmarIndice();
        await b.conectar();
      });
      b.tel.seApagaAlArrancar = true;
      await montar(
          t,
          PantVersion(
            telefono: b.telefono,
            sesion: b.sesion,
            contexto: b.contexto,
            onReconectar: () => conectar = true,
            onRecuperar: () {},
          ));
      await hasta(t, find.text('Actualizar a 0.29.1'));
      await t.tap(find.text('Actualizar a 0.29.1'));
      await hasta(t, find.text('Actualizar senew'));
      await t.tap(find.text('Instalar').last);
      await hasta(t, find.textContaining('La grabación fue correcta'),
          vueltas: 2000);
      await asentar(t);
      expect(find.byType(AvisoError), findsNothing);
      expect(find.text('Ir a recuperación'), findsNothing);
      expect(find.textContaining('Actualizar a'), findsNothing);
      final instalar = t.widget<OutlinedButton>(find.widgetWithText(
          OutlinedButton, 'Instalar'));
      expect(instalar.onPressed, isNull, reason: 'no ofrece grabar otra vez');
      await t.tap(find.text('Volver a conectar'));
      expect(conectar, isTrue);
    });

    testWidgets('un sistema sin BL: no disponible, no error de conexión',
        (t) async {
      final b = Banco();
      addTearDown(b.limpiar);
      await t.runAsync(() async {
        b.pub.publicarSenew(291, '0.29.1', mainDePrueba(291));
        b.pub.firmarIndice();
        await b.conectar();
      });
      b.tel.sinBl = true;
      await montar(
          t,
          PantVersion(
              telefono: b.telefono, sesion: b.sesion, contexto: b.contexto));
      await hasta(t, find.text('Actualizar a 0.29.1'));
      await t.tap(find.text('Actualizar a 0.29.1'));
      await hasta(t, find.text('Actualizar senew'));
      await t.tap(find.text('Instalar').last);
      await hasta(t, find.textContaining('no está disponible'), vueltas: 1000);
      await asentar(t);
      expect(find.byType(AvisoError), findsNothing);
      expect(find.textContaining('Actualizar a'), findsNothing);
    });

    testWidgets('un error de caché se dice en la pantalla, no se escapa',
        (t) async {
      final b = Banco();
      addTearDown(b.limpiar);
      await t.runAsync(b.conectar);
      b.red.errorRaro = const FileSystemException('no se pudo renombrar');
      await montar(
          t,
          PantVersion(
              telefono: b.telefono, sesion: b.sesion, contexto: b.contexto));
      await hasta(t, find.textContaining('no se pudo renombrar'));
      await asentar(t);
    });

    testWidgets('un W810: no disponible antes de empezar', (t) async {
      final b = Banco();
      addTearDown(b.limpiar);
      await t.runAsync(() async {
        b.pub.publicarSenew(291, '0.29.1', mainDePrueba(291));
        b.pub.firmarIndice();
      });
      const w810 = Telefono(
          modelo: Modelo.w810,
          nombreAmigo: 'W810 sistema propio',
          serie: '',
          versionSenew: '0.29.0',
          almacenes: []);
      await montar(
          t, PantVersion(telefono: w810, sesion: null, contexto: b.contexto));
      await hasta(t, find.textContaining('no está disponible'));
      await asentar(t);
      expect(find.textContaining('Actualizar a'), findsNothing);
    });

    testWidgets('la pantalla no habla de respaldos ni de IMEI', (t) async {
      final b = Banco();
      addTearDown(b.limpiar);
      await t.runAsync(() async {
        b.pub.publicarSenew(291, '0.29.1', mainDePrueba(291));
        b.pub.firmarIndice();
        b.tel.idAparato = '';
        await b.conectar();
      });
      await montar(
          t,
          PantVersion(
              telefono: b.telefono, sesion: b.sesion, contexto: b.contexto));
      await hasta(t, find.text('Actualizar a 0.29.1'));
      await asentar(t);
      for (final no in ['respaldo', 'IMEI', 'vincular', 'modo flash']) {
        expect(find.textContaining(no), findsNothing, reason: no);
      }
    });
  });

  group('Recuperación', () {
    testWidgets('reanuda lo que quedó a medias', (t) async {
      final b = Banco();
      addTearDown(b.limpiar);
      await t.runAsync(() async {
        final m = ImagenConocida(mainDePrueba(291), 291, '0.29.1');
        b.tel.anadirImagen(m);
        b.pub.publicarSenew(291, '0.29.1', m.bytes);
        b.pub.firmarIndice();
        await b.conectar();
        final dest = (await b.backend.indice()).indice.senew.single;
        final a = ActualizadorSenew(
          puertos: b.puertos,
          backend: b.backend,
          almacen: b.almacen,
          confirmar: (_) async => true,
          plazoBl: Duration.zero,
          plazoSenew: Duration.zero,
          sondeoBl: Duration.zero,
          pausaEntrarBl: Duration.zero,
        );
        b.tel
          ..corteEn = 4
          ..corteDePila = true;
        final r = await a.actualizar(
            sesion: b.sesion, telefono: b.telefono, destino: dest);
        expect(r.fin, FinAct.corte);
      });
      await montar(
          t,
          PantRecuperacion(
              telefono: Telefono.enBootloader(b.tel.pidBl),
              contexto: b.contexto));
      await hasta(t, find.text('Reanudar'));
      expect(find.textContaining('1209:0002'), findsOneWidget);
      await t.tap(find.text('Reanudar'));
      await hasta(t, find.textContaining('Listo: build 291'), vueltas: 2000);
      expect(b.tel.corriendo?.build, 291);
    });

    testWidgets('sin nada a medias: deja salir y ofrece versiones', (t) async {
      final b = Banco();
      addTearDown(b.limpiar);
      await t.runAsync(() async {
        b.pub.publicarSenew(291, '0.29.1', mainDePrueba(291));
        b.pub.firmarIndice();
      });
      b.tel.entrarAlBlPorBandera();
      await montar(
          t,
          PantRecuperacion(
              telefono: Telefono.enBootloader(pidBl), contexto: b.contexto));
      await hasta(t, find.text('Salir del bootloader'));
      expect(find.text('Grabar'), findsOneWidget);
      expect(find.textContaining('1209:0002'), findsOneWidget);
    });

    testWidgets('un error de caché se dice en la pantalla, no se escapa',
        (t) async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.red.errorRaro = const FileSystemException('no se pudo renombrar');
      await montar(
          t,
          PantRecuperacion(
              telefono: Telefono.enBootloader(pidBl), contexto: b.contexto));
      await hasta(t, find.textContaining('no se pudo renombrar'));
      expect(find.text('Salir del bootloader'), findsOneWidget,
          reason: 'la pantalla sigue siendo útil');
      await asentar(t);
    });

    testWidgets('1209:0003 se enseña tal cual', (t) async {
      final b = Banco();
      addTearDown(b.limpiar);
      await montar(
          t,
          PantRecuperacion(
              telefono: Telefono.enBootloader(0x0003), contexto: b.contexto));
      await hasta(t, find.textContaining('1209:0003'));
    });
  });

  group('en la ventana de 800x600, sin el menú: nada se desborda', () {
    const chica = Size(552, 600);

    Future<Banco> lleno(WidgetTester t) async {
      final b = Banco();
      await t.runAsync(() async {
        b.tel.appsFabrica.add(SenApp(
          origen: 0,
          banderas: 3,
          perfil: 1,
          iconoGen: 4,
          iconoAn: 16,
          apiMayor: 1,
          apiMenor: 7,
          verApp: 1,
          tam: 2048,
          iconoFilas: List.filled(12, 0),
          nombre: 'Un nombre de app bastante largo',
          fichero: 'calc.sen',
        ));
        b.tel.crearFichero(storageMemoria, b.tel.carpeta(storageMemoria, 'apps')!.handle,
            'calc.sen', senDePrueba(verApp: 1, nombre: 'Calculadora'));
        b.pub.publicarApp('calc', senDePrueba(verApp: 2), nombre: 'Calculadora');
        b.pub.publicarSenew(291, '0.29.1', mainDePrueba(291));
        b.pub.publicarSenew(280, '0.28.0', mainDePrueba(280));
        b.pub.firmarIndice();
        await b.conectar();
      });
      return b;
    }

    testWidgets('Apps', (t) async {
      final b = await lleno(t);
      addTearDown(b.limpiar);
      await montar(
          t, PantApps(telefono: b.telefono, sesion: b.sesion, backend: b.backend),
          tam: chica);
      await hasta(t, find.text('nueva: v2'));
      await asentar(t);
    });

    testWidgets('Catálogo', (t) async {
      final b = await lleno(t);
      addTearDown(b.limpiar);
      await montar(
          t, PantCatalogo(telefono: b.telefono, sesion: b.sesion, backend: b.backend),
          tam: chica);
      await hasta(t, find.text('Actualizar'));
      await asentar(t);
    });

    testWidgets('Ajustes', (t) async {
      final b = await lleno(t);
      addTearDown(b.limpiar);
      await montar(t, PantAjustesTelefono(telefono: b.telefono, sesion: b.sesion),
          tam: chica);
      await hasta(t, find.text('Formato de 12 horas'));
      await t.drag(find.byType(ListView), const Offset(0, -500));
      await t.pump();
    });

    testWidgets('Versión', (t) async {
      final b = await lleno(t);
      addTearDown(b.limpiar);
      await montar(
          t, PantVersion(telefono: b.telefono, sesion: b.sesion, contexto: b.contexto),
          tam: chica);
      await hasta(t, find.text('Volver a esta'));
    });

    testWidgets('Recuperación', (t) async {
      final b = await lleno(t);
      addTearDown(b.limpiar);
      await montar(
          t,
          PantRecuperacion(
              telefono: Telefono.enBootloader(pidBl), contexto: b.contexto),
          tam: chica);
      await hasta(t, find.text('Salir del bootloader'));
    });
  });

  group('mientras se actualiza no se cambia de pantalla', () {
    testWidgets('el menú no responde y al acabar sí', (t) async {
      final b = Banco();
      addTearDown(b.limpiar);
      final soltar = Completer<void>();
      await t.runAsync(() async {
        final m = ImagenConocida(mainDePrueba(291), 291, '0.29.1');
        b.tel.anadirImagen(m);
        b.pub.publicarSenew(291, '0.29.1', m.bytes);
        b.pub.firmarIndice();
        await b.conectar();
      });
      b.puertos.alEsperarSenew = () => soltar.future;
      t.view.physicalSize = const Size(1280, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(SenusApp(
          conexionInicial: ConexionViva(b.sesion, b.telefono),
          contexto: b.contexto));
      await t.pump(const Duration(seconds: 1));
      await t.tap(find.text('Versión'));
      await hasta(t, find.text('Actualizar a 0.29.1'));
      await t.tap(find.text('Actualizar a 0.29.1'));
      await hasta(t, find.text('Actualizar senew'));
      await t.tap(find.text('Instalar').last);
      await hasta(t, find.textContaining('no pulses OK'), vueltas: 2000);

      await t.tap(find.text('Apps'), warnIfMissed: false);
      await t.tap(find.byTooltip('Desconectar'), warnIfMissed: false);
      await asentar(t);
      expect(find.text('Versión de senew'), findsOneWidget);
      expect(find.text('Apps instaladas'), findsNothing);

      soltar.complete();
      await hasta(t, find.textContaining('Listo: build 291'), vueltas: 2000);
      await asentar(t);
      await t.tap(find.text('Apps'));
      await hasta(t, find.text('Apps instaladas'));
      await asentar(t);
    });
  });

  group('el menú lateral en una ventana de 800x600', () {
    Future<void> app(WidgetTester t, Telefono tel, Size tam) async {
      t.view.physicalSize = tam;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(SenusApp(conexionInicial: ConexionViva(null, tel)));
      await t.pump(const Duration(seconds: 1));
    }

    const conSenew = Telefono(
      modelo: Modelo.w580,
      nombreAmigo: 'W580 sistema propio',
      serie: '',
      versionSenew: 'S10',
      almacenes: [],
    );

    testWidgets('no se desborda y se llega a todo desplazándolo', (t) async {
      await app(t, conSenew, const Size(800, 600));
      expect(t.takeException(), isNull);
      final menu = find.ancestor(
          of: find.text('Inicio'), matching: find.byType(ListView));
      for (final e in ['Catálogo', 'Apps', 'Ajustes', 'Versión', 'Respaldo',
          'Fábrica', 'Instalar senew', 'Ajustes de SENUS']) {
        await t.dragUntilVisible(find.text(e), menu, const Offset(0, -60));
        expect(find.text(e), findsWidgets, reason: e);
      }
      expect(find.byTooltip('Desconectar'), findsOneWidget,
          reason: 'el teléfono no se va con el desplazamiento');
      expect(t.takeException(), isNull);
      await t.pump(const Duration(seconds: 1));
    });

    testWidgets('más baja todavía, tampoco', (t) async {
      await app(t, conSenew, const Size(800, 420));
      expect(t.takeException(), isNull);
      await t.pump(const Duration(seconds: 1));
    });

    testWidgets('en recuperación y de fábrica, tampoco', (t) async {
      await app(t, Telefono.enBootloader(pidBl), const Size(800, 600));
      expect(t.takeException(), isNull);
      await t.pump(const Duration(seconds: 1));
    });

    testWidgets('con sitio de sobra, el teléfono sigue abajo', (t) async {
      await app(t, conSenew, const Size(800, 1000));
      final chip = t.getBottomLeft(find.byTooltip('Desconectar')).dy;
      expect(chip, greaterThan(900));
      await t.pump(const Duration(seconds: 1));
    });
  });

  group('Conectar reconoce un teléfono en el bootloader', () {
    for (final pid in [0x0002, 0x0003]) {
      testWidgets('1209:000$pid: va a recuperación', (t) async {
        final tel = TelefonoSimulado()..estado = EstadoTel.bl;
        ConexionViva? c;
        await montar(
            t,
            PantConectar(
              modo: ThemeMode.dark,
              onModo: (_) {},
              onConectado: (x) => c = x,
              elegirTransporte: () => TransporteMtpSimulado(tel),
              buscarBl: () async => pid,
            ));
        await t.tap(find.text('Conectar'));
        await t.pump(const Duration(milliseconds: 50));
        await asentar(t);
        expect(c, isNotNull);
        expect(c!.sesion, isNull);
        expect(c!.telefono.enRecuperacion, isTrue);
        expect(c!.telefono.pidBootloader, pid);
      });
    }

    testWidgets('el aviso de «Encendido» está antes de pulsar Conectar',
        (t) async {
      await montar(
          t,
          PantConectar(
            modo: ThemeMode.dark,
            onModo: (_) {},
            onConectado: (_) {},
            elegirTransporte: () => TransporteMtpSimulado(TelefonoSimulado()),
            buscarBl: () async => 2,
          ));
      await t.pump(const Duration(milliseconds: 500));
      expect(find.text(avisoEncendido), findsOneWidget);
      expect(find.textContaining('«Conectado por USB»'), findsWidgets);
      expect(find.textContaining('«Conectar por USB»'), findsNothing);
    });

    testWidgets('con senew en marcha ni se mira el BL', (t) async {
      final tel = TelefonoSimulado();
      tel.instalarYArrancar(ImagenConocida(mainDePrueba(290), 290, '0.29.0'));
      tel.idAparato = imei;
      ConexionViva? c;
      var mirado = false;
      await montar(
          t,
          PantConectar(
            modo: ThemeMode.dark,
            onModo: (_) {},
            onConectado: (x) => c = x,
            elegirTransporte: () => TransporteMtpSimulado(tel),
            buscarBl: () async {
              mirado = true;
              return 2;
            },
          ));
      await t.tap(find.text('Conectar'));
      for (var i = 0; i < 40 && c == null; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
        await t.pump(const Duration(milliseconds: 20));
      }
      await asentar(t);
      expect(c?.telefono.imei, imei);
      expect(c?.telefono.canalGestion, isTrue);
      expect(mirado, isFalse);
    });
  });

  testWidgets('Inicio pide actualizar a un senew sin canal', (t) async {
    final b = Banco(canal: false);
    addTearDown(b.limpiar);
    await t.runAsync(b.conectar);
    var ir = false;
    await montar(t, PantInicio(telefono: b.telefono, onVersion: () => ir = true));
    await t.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('no tiene canal de gestión'), findsOneWidget);
    await t.tap(find.text('Ver versión'));
    expect(ir, isTrue);
  });
}

const pidBl = 0x0002;
