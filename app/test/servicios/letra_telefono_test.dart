// La letra del teléfono: Dart da lo mismo que `para_telefono` de Python.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:senus_app/servicios/letra_telefono.dart';

void main() {
  final l = LetraTelefono.desdeTabla(File('assets/servicios/letra_telefono.bin').readAsBytesSync());

  test('los casos de oro de Python, uno a uno', () {
    final oro = jsonDecode(File('test/fixtures/servicios/letra_oro.json').readAsStringSync()) as List;
    expect(oro.length, greaterThan(1000));
    var malos = 0;
    final ejemplos = <String>[];
    for (final c in oro.cast<Map>()) {
      final r = l.para(c['s'] as String, c['max'] as int);
      if (r != c['r']) {
        malos++;
        if (ejemplos.length < 8) ejemplos.add('«${c['s']}» max ${c['max']}: dart «$r» python «${c['r']}»');
      }
    }
    expect(malos, 0, reason: ejemplos.join('\n'));
  });

  test('los casos de prueba_musica.py', () {
    expect(l.para('Motörhead'), 'Motorhead');
    expect(l.para('Canción ñandú ¿sí?'), 'Canción ñandú ¿sí?');
    expect(l.para('Сплин'), 'Splin');
    expect(l.para('Ça\tva\n'), 'Ca va');
    expect(l.para('米津玄師 - Lemon'), 'Mi Jin Xuan Shi - Lemon');
    expect(l.para('“Hey” — Jude'), '"Hey" - Jude');
  });

  test('largo: como mucho max bytes y con «…»', () {
    final r = l.para('Ü' * 200);
    expect(utf8.encode(r).length, lessThanOrEqualTo(96));
    expect(r, endsWith('…'));
  });

  test('nulo y vacío', () {
    expect(l.para(null), '');
    expect(l.para(''), '');
  });
}
