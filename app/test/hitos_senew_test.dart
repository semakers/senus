// Pruebas del catálogo de imágenes de senew (lógica pura, sin widgets).
//
// `pant_instalar_senew.dart` monta el dropdown a partir de la salida de
// `descubrirHitos()`; aquí probamos la ordenación, las etiquetas y el
// hito-por-omisión directamente, sin arrancar el engine de Flutter. En
// la Asahi, el `flutter test` corre bajo qemu-x86 y tarda minutos solo
// por levantar el engine; `dart test` sobre lógica pura va en segundos.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:senus_app/datos/hitos_senew.dart';

void main() {
  group('hitos_senew', () {
    test('tocaNorPorNombre: `sin_escritura` NO toca; el resto sí', () {
      expect(tocaNorPorNombre('hito_2_44140000.bin'), isTrue);
      expect(tocaNorPorNombre('sistema_44140000.bin'), isTrue);
      expect(tocaNorPorNombre('paso_7_sin_escritura_44140000.bin'), isFalse);
      expect(tocaNorPorNombre('sistema_sin_escritura_44140000.bin'), isFalse);
    });

    test('compararHitos: orden del MANIFIESTO antes que el alfabético', () {
      // alfabético puro los pondría distinto: `h3_todas` antes que `h4`.
      final nombres = [
        'sistema_44140000.bin',
        'hito_5_44140000.bin',
        'hito_2_44140000.bin',
        'hito_3_todas_44140000.bin',
        'hito_3_44140000.bin',
        'nuevo_hito_xx_44140000.bin', // no está en el MANIFIESTO
      ]..sort(compararHitos);
      expect(nombres, [
        'hito_2_44140000.bin',
        'hito_3_44140000.bin',
        'hito_3_todas_44140000.bin',
        'hito_5_44140000.bin',
        'sistema_44140000.bin',
        'nuevo_hito_xx_44140000.bin', // al final, por alfabético
      ]);
    });

    test('hitoPorOmision: hito_2 si está, si no el primero del MANIFIESTO',
        () {
      HitoSenew h(String n) => HitoSenew(n, 1, true, '');
      expect(
          hitoPorOmision([
            h('hito_6_44140000.bin'),
            h('hito_2_44140000.bin'),
          ]),
          'hito_2_44140000.bin');
      // Sin hito_2, cae al primero del orden que esté.
      expect(
          hitoPorOmision([
            h('hito_6_44140000.bin'),
            h('sistema_44140000.bin'),
          ]),
          'hito_6_44140000.bin');
      // Nada del MANIFIESTO → el primero de la lista.
      expect(
          hitoPorOmision([h('otro_xx_44140000.bin'), h('otro_yy_44140000.bin')]),
          'otro_xx_44140000.bin');
      expect(hitoPorOmision(const []), isNull);
    });

    test('descubrirHitos: lee la carpeta y los devuelve ordenados', () async {
      final tmp = await Directory.systemTemp.createTemp('senus-hitos-');
      try {
        for (final n in const [
          'sistema_44140000.bin',
          'hito_5_44140000.bin',
          'hito_2_44140000.bin',
          'paso_7_sin_escritura_44140000.bin',
          'README.txt', // debe filtrarse
          'basura.bin', // debe filtrarse (no termina en _44140000.bin)
        ]) {
          await File(p.join(tmp.path, n)).writeAsBytes([1, 2, 3]);
        }
        final hitos = await descubrirHitos(tmp.path);
        expect(hitos.map((h) => h.nombreArchivo).toList(), [
          'hito_2_44140000.bin',
          'hito_5_44140000.bin',
          'paso_7_sin_escritura_44140000.bin',
          'sistema_44140000.bin',
        ]);
        // Las etiquetas del MANIFIESTO y el aviso de NOR cuadran.
        final paso7 = hitos
            .firstWhere((h) => h.nombreArchivo == 'paso_7_sin_escritura_44140000.bin');
        expect(paso7.tocaNor, isFalse);
        expect(paso7.etiqueta, contains('NO toca NOR'));
        final sistema =
            hitos.firstWhere((h) => h.nombreArchivo == 'sistema_44140000.bin');
        expect(sistema.tocaNor, isTrue);
        expect(sistema.etiqueta, contains('escribe NOR'));
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('descubrirHitos: carpeta inexistente → lista vacía', () async {
      expect(
          await descubrirHitos('/ruta/que/no/existe-xyz-${DateTime.now().microsecondsSinceEpoch}'),
          isEmpty);
    });
  });
}
