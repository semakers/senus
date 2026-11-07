// El catálogo: con las MISMAS respuestas guardadas, Dart da las líneas que da
// bt/musica_yt/servicio.py con ytmusicapi.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:senus_app/servicios/catalogo_musica.dart';
import 'package:senus_app/servicios/letra_telefono.dart';

String guardada(String n) =>
    utf8.decode(gzip.decode(File('test/fixtures/servicios/$n.json.gz').readAsBytesSync()));

class RedGuardada implements RedCatalogo {
  final enviados = <(Uri, Map<String, String>, Map)>[];
  var obtenidos = 0;
  String? visitante = 'VISITANTE';

  @override
  Future<String> obtener(Uri url, Map<String, String> cabeceras) async {
    obtenidos++;
    return 'x ytcfg.set({"VISITOR_DATA":"$visitante","OTRA":1}); y';
  }

  @override
  Future<String> enviar(Uri url, Map<String, String> cabeceras, String cuerpo) async {
    final j = jsonDecode(cuerpo) as Map;
    enviados.add((url, cabeceras, j));
    if (url.path.endsWith('/next')) return guardada('siguientes');
    if (url.query.contains('ctoken')) return '{}';
    return guardada(j['query'].toString().startsWith('zzq') ? 'busca_nada' : 'busca');
  }
}

void main() {
  final letra = LetraTelefono.desdeTabla(File('assets/servicios/letra_telefono.bin').readAsBytesSync());
  final oro = jsonDecode(File('test/fixtures/servicios/catalogo_oro.json').readAsStringSync()) as Map;

  test('buscar: la primera página, línea a línea igual que Python', () async {
    final (lista, mas) = await Catalogo(red: RedGuardada()).buscar('carefree kevin macleod', 0, 10);
    final o = (oro['buscar_0_10'] as List).cast<String>();
    expect(lista.map((c) => c.linea(letra)).toList(), o.sublist(1));
    expect(mas ? '1' : '0', o[0]);
  });

  test('buscar: la segunda página, y sin volver a pedir', () async {
    final red = RedGuardada();
    final c = Catalogo(red: red);
    await c.buscar('carefree kevin macleod', 0, 10);
    final n = red.enviados.length;
    final (lista, mas) = await c.buscar('carefree kevin macleod', 10, 10);
    final o = (oro['buscar_10_10'] as List).cast<String>();
    expect(lista.map((c) => c.linea(letra)).toList(), o.sublist(1));
    expect(mas ? '1' : '0', o[0]);
    expect(red.enviados.length, n);
  });

  test('siguientes: la radio, igual que Python y sin la misma', () async {
    final lista = await Catalogo(red: RedGuardada()).siguientes('qapK8Gx6ZTo', 10);
    expect(lista.map((c) => c.linea(letra)).toList(), (oro['siguientes_10'] as List).cast<String>());
    expect(lista.any((c) => c.id == 'qapK8Gx6ZTo'), isFalse);
  });

  test('la portada de cada canción: la mayor', () async {
    // La misma secuencia que el oro: la radio trae portadas mayores de las mismas.
    final c = Catalogo(red: RedGuardada());
    await c.buscar('carefree kevin macleod', 0, 10);
    await c.buscar('carefree kevin macleod', 10, 10);
    await c.siguientes('qapK8Gx6ZTo', 10);
    (oro['portadas'] as Map).forEach((id, url) => expect(c.meta[id]?.portada, url, reason: '$id'));
  });

  test('lo que se manda: filtro de canciones, cliente, sin cuenta', () async {
    final red = RedGuardada();
    await Catalogo(red: red, ahora: () => DateTime.utc(2026, 11, 1)).buscar('  dos   palabras ', 0, 10);
    expect(red.obtenidos, 1);
    final (url, cab, cuerpo) = red.enviados.single;
    expect(url.toString(), 'https://music.youtube.com/youtubei/v1/search?alt=json');
    expect(cuerpo['query'], 'dos palabras');
    expect(cuerpo['params'], 'EgWKAQIIAWoMEA4QChADEAQQCRAF');
    expect(cuerpo['context']['client']['clientName'], 'WEB_REMIX');
    expect(cuerpo['context']['client']['clientVersion'], '1.20261101.01.00');
    expect(cab['X-Goog-Visitor-Id'], 'VISITANTE');
    expect(cab.keys.map((k) => k.toLowerCase()), isNot(contains('authorization')));
  });

  test('el visitante se pide una sola vez', () async {
    final red = RedGuardada();
    final c = Catalogo(red: red);
    await c.buscar('a', 0, 10);
    await c.buscar('b', 0, 10);
    expect(red.obtenidos, 1);
  });

  test('la consulta se recorta a 120 letras', () async {
    final red = RedGuardada();
    await Catalogo(red: red).buscar('x' * 300, 0, 10);
    expect((red.enviados.single.$3['query'] as String).length, 120);
  });

  test('la caché caduca a los 10 minutos y guarda 20 consultas', () async {
    final red = RedGuardada();
    var t = DateTime.utc(2026);
    final c = Catalogo(red: red, ahora: () => t);
    await c.buscar('a', 0, 10);
    await c.buscar('a', 0, 10);
    expect(red.enviados.where((e) => e.$1.path.endsWith('search')).length, 1);
    t = t.add(const Duration(minutes: 11));
    await c.buscar('a', 0, 10);
    expect(red.enviados.where((e) => e.$1.path.endsWith('search')).length, 2);
    for (var i = 0; i < 25; i++) {
      await c.buscar('q$i', 0, 10);
    }
    final n = red.enviados.length;
    await c.buscar('q0', 0, 10);
    expect(red.enviados.length, n + 1, reason: 'la más vieja ya se fue');
  });

  test('pedir más de lo que hay: lista vacía y sin más', () async {
    final (lista, mas) = await Catalogo(red: RedGuardada()).buscar('carefree', 40, 10);
    expect(lista, isEmpty);
    expect(mas, isFalse);
  });

  test('una respuesta sin contenidos no revienta', () {
    expect(leerBusqueda(const {}).$1, isEmpty);
    expect(leerBusqueda(const {'contents': {}}).$1, isEmpty);
    expect(leerContinuacion(const {}).$1, isEmpty);
    expect(() => leerRadio(const {}), throwsFormatException);
  });

  test('mm:ss', () {
    expect(mmssAS('3:26'), 206);
    expect(mmssAS('1:02:03'), 3723);
    expect(mmssAS('x'), 0);
    expect(mmssAS(null), 0);
  });
}
