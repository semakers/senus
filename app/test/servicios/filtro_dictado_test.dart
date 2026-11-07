// El filtro de alucinaciones: los mismos casos que bt/dictado/servicio.py.

import 'package:flutter_test/flutter_test.dart';
import 'package:senus_app/servicios/filtro_dictado.dart';

void main() {
  final f = Filtro();
  String? motivo(String t, {double ns = 0.1, double lp = -0.3}) => f.segmento(SegmentoWhisper(t, ns, lp)).$2;

  test('normal: minúsculas, sin acentos ni puntuación', () {
    expect(normal('¡Suscríbete, YA!'), 'suscribete ya');
    expect(normal('  Hola   ñandú… '), 'hola nandu');
    expect(normal('Canción_1'), 'cancion_1');
  });

  test('una frase normal pasa', () {
    expect(motivo('Comprar pan, leche y café para mañana.'), isNull);
  });

  test('las alucinaciones de los subtítulos se quitan siempre', () {
    for (final t in [
      '¡Suscríbete!',
      'Suscribete al canal',
      'no olvides suscribirte',
      'Subtítulos realizados por la comunidad de Amara.org',
      'Subtitulado por Fulano',
      'Gracias por ver el video',
      'Muchas gracias por ver',
      'Dale like',
      'Activa la campanita',
      'Nos vemos en el próximo video',
      'Hasta la próxima vez',
    ]) {
      expect(motivo(t), 'alucinacion', reason: t);
    }
  });

  test('las ambiguas solo si whisper duda', () {
    expect(motivo('Gracias.', ns: 0.1, lp: -0.3), isNull);
    expect(motivo('Gracias.', ns: 0.5, lp: -0.3), 'alucinacion');
    expect(motivo('Hola', ns: 0.1, lp: -0.9), 'alucinacion');
  });

  test('las etiquetas se van y si no queda nada es vacío', () {
    expect(motivo('[Música]'), 'vacio');
    expect(motivo('(aplausos)'), 'vacio');
    expect(motivo('♪ ♪ ♪'), 'vacio');
    expect(f.segmento(const SegmentoWhisper('[Música] hola a todos', 0.1, -0.3)).$1, 'hola a todos');
  });

  test('umbrales: no-habla, dudoso, repetido', () {
    expect(motivo('algo que se dijo', ns: 0.95), 'no-habla');
    expect(motivo('algo que se dijo', lp: -2.1), 'dudoso');
    expect(motivo('Bohini en la ciudad de Queen.', lp: -1.5), isNull, reason: 'el -2,0 del 28-oct');
    expect(motivo('y y y y y y y y y y y y y y y y y y y y y y y y y y y y y y y y y y y y y y'), 'repetido');
  });

  test('la compresión es la de faster-whisper', () {
    expect(const SegmentoWhisper('', 0, 0).compresion, 0);
    expect(const SegmentoWhisper('hola', 0, 0).compresion, lessThan(1));
  });

  test('los idiomas: es y en sí, inventados no', () {
    expect(idiomasWhisper, containsAll(['es', 'en', 'yue']));
    expect(idiomasWhisper.contains('xx'), isFalse);
    expect(idiomasWhisper.length, 100);
  });
}
