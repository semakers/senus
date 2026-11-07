// Las pausas de los ejecutores (reconectar el teléfono en modo C, abrir
// «executer») tienen que llegar a una persona. Un `Completer` que nadie
// completa deja colgado al ejecutor para siempre, y eso es lo que pasaba en
// el respaldo real y en la restauración real: sus pantallas no consumían
// `ev.pausa`.
//
// Ejecutores FALSOS (no abren ningún puerto ni tocan ningún aparato) y una
// carpeta temporal en vez de ~/senus/respaldos.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:senus_app/datos/instalacion.dart';
import 'package:senus_app/datos/respaldo_rollback.dart';
import 'package:senus_app/datos/seftool.dart';
import 'package:senus_app/datos/telefono.dart';
import 'package:senus_app/tema/senus_tema.dart';
import 'package:senus_app/widgets/comunes.dart';
import 'package:senus_app/widgets/pant_fabrica.dart';
import 'package:senus_app/widgets/pant_instalar_senew.dart';

const _tel = Telefono(
  modelo: Modelo.w580,
  nombreAmigo: 'W580 de fábrica',
  serie: '35697201234567',
  versionSenew: '—',
  almacenes: [],
  deFabrica: true,
  cid: '52',
  color: 'RED',
  firmwareOriginal: 'R8BE001',
  puertoSerie: '/dev/ttyUSB-de-mentira',
);

class _EjecutorRespaldoFalso extends EjecutorRespaldo {
  bool reanudado = false;
  _EjecutorRespaldoFalso(AlmacenRespaldos a)
      : super(telefono: _tel, almacen: a, simulado: true);

  @override
  Stream<EventoRespaldo> correr({String? copiaEspejoScp}) async* {
    yield const EventoRespaldo(paso: 'identificar', pasoHecho: false);
    yield const EventoRespaldo(paso: 'identificar', pasoHecho: true);
    final c = Completer<bool>();
    yield EventoRespaldo(
      pausa: c,
      pausaTitulo: 'Reconecta el teléfono en modo C',
      pausaDetalle: 'Mantén la tecla C pulsada mientras enchufas el cable.',
    );
    final seguir = await c.future;
    reanudado = true;
    if (!seguir) {
      yield const EventoRespaldo(
          paso: 'respaldo',
          pasoHecho: false,
          error: 'Cancelado por el usuario en la reconexión');
      return;
    }
    yield const EventoRespaldo(logLinea: 'FALSO: siguió tras la pausa');
  }
}

class _RestauracionFalsa extends EjecutorRestauracion {
  bool reanudada = false;
  bool? respuesta;

  /// Si true, al seguir termina bien pero A MEDIAS (solo el GDFS), como la
  /// red parcial de un RED sin executer.
  final bool terminaParcial;
  _RestauracionFalsa(RespaldoRollback r, AlmacenRespaldos a,
      {this.terminaParcial = false})
      : super(
            respaldo: r,
            almacen: a,
            seftool: Seftool(raiz: '/no/importa', puerto: '/dev/x', ensayo: true));

  @override
  Stream<EventoRespaldo> correr() async* {
    final c = Completer<bool>();
    yield EventoRespaldo(
      pausa: c,
      pausaTitulo: 'Reconecta el teléfono en modo C',
      pausaDetalle: 'seftool cerró el puerto: el teléfono está apagado.',
    );
    respuesta = await c.future;
    reanudada = true;
    // Como el ejecutor de verdad: cancelar no es un error, pero lo marca.
    if (respuesta == false) {
      yield const EventoRespaldo(
          cancelado: true, logLinea: 'Cancelado por el usuario.');
    } else if (terminaParcial) {
      yield const EventoRespaldo(
          parcial: true,
          logLinea: 'Hecho, pero PARCIAL: solo se restauró el GDFS.');
    }
  }
}

/// Instalación falsa: pide una pausa y, si la cancelan, termina como el
/// ejecutor de verdad (cancelado, sin error).
class _InstalacionFalsa extends EjecutorInstalacion {
  bool reanudada = false;
  bool? respuesta;
  _InstalacionFalsa(RespaldoRollback r, String? rutaSenew)
      : super(
            respaldo: r,
            seftool: Seftool(raiz: '/no/importa', puerto: '/dev/x', ensayo: true),
            forzarCamino: Camino.anycidReemplazoFrio,
            rutaSenew: rutaSenew);

  @override
  Stream<EventoRespaldo> correr() async* {
    final c = Completer<bool>();
    yield EventoRespaldo(
      pausa: c,
      pausaTitulo: 'Abre «executer» en el teléfono',
      pausaDetalle: 'Juegos → executer.',
    );
    respuesta = await c.future;
    reanudada = true;
    if (respuesta == false) {
      yield const EventoRespaldo(
          cancelado: true, logLinea: 'Cancelado por el usuario.');
    }
  }
}

Future<void> _bombear(WidgetTester tester, [int veces = 12]) async {
  for (var i = 0; i < veces; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Espera la E/S REAL de una pantalla (leer el almacén, descubrir los hitos).
/// El tiempo de testWidgets es falso: la E/S real solo avanza dentro de
/// `runAsync`, y como son varias esperas seguidas hacen falta varias vueltas
/// de (tiempo real + pintar).
Future<void> _esperarIO(WidgetTester tester, [int veces = 25]) async {
  for (var i = 0; i < veces; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void _ventanaGrande(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  group('resolverPausa', () {
    Future<(Completer<bool>, List<bool?>)> abrir(WidgetTester tester) async {
      final c = Completer<bool>();
      final resultado = <bool?>[];
      await tester.pumpWidget(MaterialApp(
        theme: temaSenus(Brightness.dark),
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  resultado.add(await resolverPausa(
                      ctx,
                      EventoRespaldo(
                        pausa: c,
                        pausaTitulo: 'Reconecta el teléfono en modo C',
                        pausaDetalle: 'Detalle de la pausa',
                      )));
                },
                child: const Text('abrir'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
      return (c, resultado);
    }

    testWidgets('Continuar completa el Completer con true', (tester) async {
      final (c, resultado) = await abrir(tester);
      expect(find.text('Reconecta el teléfono en modo C'), findsOneWidget);
      expect(find.text('Detalle de la pausa'), findsOneWidget);
      expect(c.isCompleted, isFalse, reason: 'mientras el diálogo está abierto');

      await tester.tap(find.text('Continuar'));
      await tester.pumpAndSettle();
      expect(c.isCompleted, isTrue);
      expect(await c.future, isTrue);
      expect(resultado, [true]);
    });

    testWidgets('Cancelar completa el Completer con false', (tester) async {
      final (c, resultado) = await abrir(tester);
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(c.isCompleted, isTrue);
      expect(await c.future, isFalse);
      expect(resultado, [false]);
    });

    testWidgets('si el diálogo no puede ni abrirse, el Completer se completa con '
        'false (el ejecutor no se queda colgado)', (tester) async {
      // Sin `temaSenus` el diálogo falla al buscar los colores de SENUS
      // (`context.col`): lo que la persona nunca llega a ver. Aun así, el
      // ejecutor que espera `c.future` tiene que despertar.
      late BuildContext contexto;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (ctx) {
          contexto = ctx;
          return const SizedBox();
        }),
      ));
      final c = Completer<bool>();
      Object? fallo;
      try {
        await resolverPausa(
            contexto,
            EventoRespaldo(
                pausa: c, pausaTitulo: 'Reconecta', pausaDetalle: 'Detalle'));
      } catch (e) {
        fallo = e;
      }
      expect(fallo, isNotNull, reason: 'el fallo del diálogo no se traga');
      expect(c.isCompleted, isTrue, reason: 'pero el Completer no se queda abierto');
      expect(await c.future, isFalse);
    });
  });

  group('PantFabrica consume las pausas del respaldo', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('senus-ui-fab-'));
    tearDown(() => tmp.deleteSync(recursive: true));

    testWidgets('Continuar: el ejecutor sigue', (tester) async {
      _ventanaGrande(tester);
      final almacen = AlmacenRespaldos.en(tmp.path);
      final falso = _EjecutorRespaldoFalso(almacen);
      await tester.pumpWidget(MaterialApp(
        theme: temaSenus(Brightness.dark),
        home: Scaffold(
            body: PantFabrica(
                telefono: _tel, almacen: almacen, crearEjecutor: () => falso)),
      ));
      await _bombear(tester);

      await tester.tap(find.text('Empezar respaldo'));
      await _bombear(tester);
      expect(find.text('Reconecta el teléfono en modo C'), findsOneWidget,
          reason: 'la pantalla tiene que enseñar la pausa');
      expect(falso.reanudado, isFalse, reason: 'sigue esperando a la persona');

      await tester.tap(find.text('Continuar'));
      await _bombear(tester);
      expect(falso.reanudado, isTrue);
      expect(find.textContaining('FALSO: siguió tras la pausa'), findsOneWidget);
    });

    testWidgets('Cancelar: el ejecutor lo sabe y el paso queda fallido',
        (tester) async {
      _ventanaGrande(tester);
      final almacen = AlmacenRespaldos.en(tmp.path);
      final falso = _EjecutorRespaldoFalso(almacen);
      await tester.pumpWidget(MaterialApp(
        theme: temaSenus(Brightness.dark),
        home: Scaffold(
            body: PantFabrica(
                telefono: _tel, almacen: almacen, crearEjecutor: () => falso)),
      ));
      await _bombear(tester);

      await tester.tap(find.text('Empezar respaldo'));
      await _bombear(tester);
      await tester.tap(find.text('Cancelar'));
      await _bombear(tester);

      expect(falso.reanudado, isTrue);
      expect(find.textContaining('Cancelado por el usuario en la reconexión'),
          findsWidgets);
      expect(find.text('fallido'), findsOneWidget);
    });

    testWidgets('el texto del paso 2 dice lo que va a pasar en un W580 RED',
        (tester) async {
      _ventanaGrande(tester);
      await tester.pumpWidget(MaterialApp(
        theme: temaSenus(Brightness.dark),
        home: Scaffold(
            body: PantFabrica(
                telefono: _tel, almacen: AlmacenRespaldos.en(tmp.path))),
      ));
      await _bombear(tester);
      expect(find.textContaining('exploit anycid'), findsOneWidget);
      expect(find.textContaining('4 pausas'), findsOneWidget);
    });
  });

  group('PantInstalarSenew consume las pausas de la restauración', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('senus-ui-inst-'));
    tearDown(() => tmp.deleteSync(recursive: true));

    for (final seguir in [true, false]) {
      testWidgets('«Volver al firmware original»: pausa → ${seguir ? "Continuar" : "Cancelar"}',
          (tester) async {
        _ventanaGrande(tester);
        final almacen = AlmacenRespaldos.en(tmp.path);
        // La E/S real NO avanza dentro del tiempo falso de testWidgets: hay que
        // hacerla (y esperarla) con runAsync.
        late RespaldoRollback r;
        await tester.runAsync(() async {
          final dir = await almacen.abrirCarpeta('W580', _tel.serie);
          r = await almacen.registrar(RespaldoRollback(
            carpeta: dir.path,
            modelo: 'W580',
            serie: _tel.serie,
            fecha: DateTime.now(),
            cid: '52',
            color: 'RED',
            firmwareOriginal: 'R8BE001',
            shaFlash: 'f' * 64,
            bytesFlash: 1,
            paqueteAnycid: 'R8BE001_CXC1123362_GENERIC_LA',
          ));
        });
        final falsa = _RestauracionFalsa(r, almacen);

        await tester.pumpWidget(MaterialApp(
          theme: temaSenus(Brightness.dark),
          home: Scaffold(
              body: PantInstalarSenew(
            telefono: _tel,
            onIrAFabrica: () {},
            almacen: almacen,
            carpetaAparato: tmp.path,
            crearRestauracion: (_) => falsa,
          )),
        ));
        // La pantalla lee el almacén y descubre los hitos con E/S real.
        await _esperarIO(tester);

        await tester.tap(find.text('Volver al firmware original').first);
        await _bombear(tester);
        await tester.tap(find.text('Restaurar'));
        await _bombear(tester);

        expect(find.text('Reconecta el teléfono en modo C'), findsOneWidget,
            reason: 'la restauración real también tiene que enseñar su pausa');
        expect(falsa.reanudada, isFalse);

        await tester.tap(find.text(seguir ? 'Continuar' : 'Cancelar'));
        await _bombear(tester);
        expect(falsa.reanudada, isTrue);
        expect(falsa.respuesta, seguir);

        // Al acabar, la pantalla relee el almacén (E/S real) y avisa.
        await _esperarIO(tester);
        if (seguir) {
          expect(find.textContaining('Firmware original restaurado'),
              findsOneWidget);
        } else {
          // Cancelar NO es haber restaurado: no puede decir «restaurado» ni
          // «usado» (el respaldo no se marcó).
          expect(find.textContaining('CANCELADA'), findsOneWidget);
          expect(find.textContaining('Firmware original restaurado'),
              findsNothing);
        }
      });
    }

    testWidgets('si termina PARCIAL (solo el GDFS) la pantalla lo dice: no '
        '«Firmware original restaurado»', (tester) async {
      _ventanaGrande(tester);
      final almacen = AlmacenRespaldos.en(tmp.path);
      late RespaldoRollback r;
      await tester.runAsync(() async {
        final dir = await almacen.abrirCarpeta('W580', _tel.serie);
        r = await almacen.registrar(RespaldoRollback(
          carpeta: dir.path,
          modelo: 'W580',
          serie: _tel.serie,
          fecha: DateTime.now(),
          cid: '52',
          color: 'RED',
          firmwareOriginal: 'R8BE001',
          shaFlash: 'f' * 64,
          bytesFlash: 1,
          paqueteAnycid: 'R8BE001_CXC1123362_GENERIC_LA',
        ));
      });
      final falsa = _RestauracionFalsa(r, almacen, terminaParcial: true);
      await tester.pumpWidget(MaterialApp(
        theme: temaSenus(Brightness.dark),
        home: Scaffold(
            body: PantInstalarSenew(
          telefono: _tel,
          onIrAFabrica: () {},
          almacen: almacen,
          carpetaAparato: tmp.path,
          crearRestauracion: (_) => falsa,
        )),
      ));
      await _esperarIO(tester);
      await tester.tap(find.text('Volver al firmware original').first);
      await _bombear(tester);
      await tester.tap(find.text('Restaurar'));
      await _bombear(tester);
      await tester.tap(find.text('Continuar'));
      await _bombear(tester);
      await _esperarIO(tester);

      expect(falsa.respuesta, isTrue);
      expect(find.textContaining('Restauración PARCIAL'), findsOneWidget);
      expect(find.textContaining('Firmware original restaurado'), findsNothing);
    });
  });

  group('PantInstalarSenew: la instalación cancelada no se pinta como hecha', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('senus-ui-ins-'));
    tearDown(() => tmp.deleteSync(recursive: true));

    for (final seguir in [false, true]) {
      testWidgets('pausa del executer → ${seguir ? "Continuar" : "Cancelar"}',
          (tester) async {
        _ventanaGrande(tester);
        final almacen = AlmacenRespaldos.en(tmp.path);
        await tester.runAsync(() async {
          final dir = await almacen.abrirCarpeta('W580', _tel.serie);
          await almacen.registrar(RespaldoRollback(
            carpeta: dir.path,
            modelo: 'W580',
            serie: _tel.serie,
            fecha: DateTime.now(),
            cid: '52',
            color: 'RED',
            firmwareOriginal: 'R8BE001',
            shaFlash: 'f' * 64,
            bytesFlash: 1,
            paqueteAnycid: 'R8BE001_CXC1123362_GENERIC_LA',
          ));
          // Un hito de senew en la carpeta del aparato: habilita el botón.
          File(p.join(tmp.path, 'sistema_44140000.bin'))
              .writeAsBytesSync(List<int>.filled(1024, 0x11));
        });
        late _InstalacionFalsa falsa;
        await tester.pumpWidget(MaterialApp(
          theme: temaSenus(Brightness.dark),
          home: Scaffold(
              body: PantInstalarSenew(
            telefono: _tel,
            onIrAFabrica: () {},
            almacen: almacen,
            carpetaAparato: tmp.path,
            // Camino heredado de 7 pasos: hoy detrás de SENUS_FLUJO_LEGADO.
            flujoLegado: true,
            crearInstalacion: (resp, {forzarCamino, rutaSenew}) =>
                falsa = _InstalacionFalsa(resp, rutaSenew),
          )),
        ));
        await _esperarIO(tester);

        final boton = find.text('Reemplazo frío (anycid)');
        await tester.ensureVisible(boton);
        await tester.tap(boton);
        await _bombear(tester);
        // El plan se confirma en un diálogo; su «Instalar» es el de abajo.
        final instalar = find.descendant(
            of: find.byType(AlertDialog), matching: find.text('Instalar'));
        expect(instalar, findsOneWidget);
        await tester.tap(instalar);
        await _bombear(tester);

        expect(find.text('Abre «executer» en el teléfono'), findsOneWidget);
        await tester.tap(find.text(seguir ? 'Continuar' : 'Cancelar'));
        await _bombear(tester);
        expect(falsa.respuesta, seguir);
        await _esperarIO(tester);

        if (seguir) {
          expect(find.text('senew instalado'), findsOneWidget);
        } else {
          expect(find.textContaining('Instalación CANCELADA'), findsOneWidget);
          expect(find.text('senew instalado'), findsNothing,
              reason: 'cancelar una pausa NO es haber instalado');
        }
      });
    }
  });
}
