// La sección de la pantalla Conexión.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:senus_app/servicios/catalogo_componentes.dart';
import 'package:senus_app/servicios/componentes.dart';
import 'package:senus_app/servicios/gestor_componentes.dart';
import 'package:senus_app/servicios/letra_telefono.dart';
import 'package:senus_app/servicios/seccion_servicios.dart';
import 'package:senus_app/servicios/servicios_locales.dart';
import 'package:senus_app/tema/senus_tema.dart';

import 'apoyo_servicios.dart';

/// Un gestor con el estado puesto a mano, para pintar cada fase.
class GestorFalso extends GestorComponentes {
  final _c = StreamController<EstadoComponente>.broadcast();
  final _e = <String, EstadoComponente>{};
  final instalados = <String>[];
  final cancelados = <String>[];
  final borrados = <String>[];

  GestorFalso(Directory d) : super(raiz: d, catalogo: const [dictadoMacos, musicaMacos]);

  void poner(EstadoComponente e) {
    _e[e.id] = e;
    _c.add(e);
  }

  @override
  Stream<EstadoComponente> get cambios => _c.stream;
  @override
  EstadoComponente estado(String id) => _e[id] ?? EstadoComponente(id, FaseComponente.ausente);
  @override
  Future<void> instalar(String id) async => instalados.add(id);
  @override
  void cancelar(String id) => cancelados.add(id);
  @override
  Future<void> borrar(String id) async => borrados.add(id);
}

void main() {
  late Directory t;
  late GestorFalso g;
  late ServiciosLocales s;

  setUp(() async {
    t = await carpetaTemporal();
    g = GestorFalso(t);
    s = ServiciosLocales(gestor: g, letra: LetraTelefono.vacia(), puertoDeDictado: 0, puertoDeMusica: 0);
  });
  tearDown(() => t.delete(recursive: true));

  Widget app({ComponenteNoDisponible? bloqueo}) => MaterialApp(
        theme: temaSenus(Brightness.dark),
        home: Scaffold(
          body: SingleChildScrollView(child: SeccionServicios(servicios: s, bloqueo: bloqueo)),
        ),
      );

  testWidgets('sin instalar: el botón con el tamaño real', (w) async {
    await w.pumpWidget(app());
    await w.pump();
    expect(find.text('Descargar y configurar (265 MB)'), findsOneWidget);
    expect(find.text('Descargar y configurar (121 MB)'), findsOneWidget);
    // (6-nov-2026) se llama extensión, y dice que Música y Videos dependen de ella y lo que baja
    expect(find.text('Extensión de música y videos'), findsOneWidget);
    expect(find.textContaining('Música y Videos necesitan esta extensión'), findsOneWidget);
    expect(find.textContaining('una sola vez (121 MB)'), findsOneWidget);
    await w.tap(find.text('Descargar y configurar (265 MB)'));
    expect(g.instalados, ['dictado']);
    expect(find.textContaining('Solo funcionan con SENUS abierta'), findsOneWidget);
  });

  testWidgets('descargando: progreso con bytes y Cancelar', (w) async {
    await w.pumpWidget(app());
    g.poner(const EstadoComponente(idDictado, FaseComponente.descargando, recibidos: 132000000, total: 265000000));
    await w.pump();
    expect(find.text('132 MB de 265 MB'), findsOneWidget);
    await w.tap(find.text('Cancelar'));
    expect(g.cancelados, ['dictado']);
    await w.pump(const Duration(seconds: 1));
  });

  testWidgets('comprobando y configurando se dicen', (w) async {
    await w.pumpWidget(app());
    g.poner(const EstadoComponente(idMusica, FaseComponente.verificando));
    await w.pump();
    expect(find.text('Comprobando lo descargado…'), findsOneWidget);
    g.poner(const EstadoComponente(idMusica, FaseComponente.instalando));
    await w.pump();
    expect(find.text('Configurando…'), findsOneWidget);
  });

  testWidgets('un fallo: el mensaje y Reintentar', (w) async {
    await w.pumpWidget(app());
    g.poner(const EstadoComponente(idDictado, FaseComponente.fallo,
        fallo: FalloComponente(TipoFallo.discoLleno, 'No hay espacio: hacen falta 265 MB y quedan 12 MB libres.')));
    await w.pump(const Duration(seconds: 1));
    expect(find.textContaining('No hay espacio'), findsOneWidget);
    await w.tap(find.text('Reintentar'));
    expect(g.instalados, ['dictado']);
  });

  testWidgets('listo: la etiqueta y borrar con confirmación', (w) async {
    await w.pumpWidget(app());
    g.poner(const EstadoComponente(idDictado, FaseComponente.listo));
    await w.pump();
    expect(find.text('Preparando…'), findsOneWidget);
    await w.tap(find.text('Borrar'));
    await w.pumpAndSettle();
    expect(find.textContaining('Libera 272 MB'), findsOneWidget);
    await w.tap(find.widgetWithText(FilledButton, 'Borrar'));
    await w.pumpAndSettle();
    expect(g.borrados, ['dictado']);
  });

  testWidgets('el puerto ocupado se dice', (w) async {
    s.problemaMusica = 'Otro programa está usando el puerto 8580.';
    await w.pumpWidget(app());
    g.poner(const EstadoComponente(idMusica, FaseComponente.listo));
    await w.pump();
    expect(find.text('Otro programa está usando el puerto 8580.'), findsOneWidget);
    expect(find.textContaining('necesitan esta extensión'), findsNothing);
  });

  testWidgets('en Windows se dice y no hay botón de descargar', (w) async {
    await w.pumpWidget(app(bloqueo: const ComponenteNoDisponible('En Windows aún no está disponible: faltan el ayudante.')));
    await w.pump();
    expect(find.textContaining('En Windows aún no está disponible'), findsNWidgets(2));
    expect(find.textContaining('Descargar y configurar'), findsNothing);
  });

  test('en los textos para personas no se nombra de dónde sale la música', () {
    final textos = [
      File(p.join('lib', 'servicios', 'seccion_servicios.dart')).readAsStringSync(),
      File(p.join('lib', 'servicios', 'gestor_componentes.dart')).readAsStringSync(),
    ].join();
    expect(textos.toLowerCase(), isNot(contains('youtube')));
    // Los mensajes de catalogo_componentes (bloqueos) tampoco.
    final bloqueos = RegExp(r"ComponenteNoDisponible\([^;]*?\);", dotAll: true)
        .allMatches(File(p.join('lib', 'servicios', 'catalogo_componentes.dart')).readAsStringSync())
        .map((m) => m.group(0)!)
        .join();
    expect(bloqueos.toLowerCase(), isNot(contains('youtube')));
  });
}
