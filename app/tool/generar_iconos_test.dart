// Dibuja el icono de SENUS (el MISMO logo de la app: `LogoSenus`, el disco naranja
// con los tres anillos) sobre una baldosa oscura, a todos los tamaños que piden
// Windows y macOS, y los deja como PNG en build/iconos/.
//
//   flutter test tool/generar_iconos_test.dart
//   python3 -I tool/generar_iconos.py        (arma el .ico y el set de macOS)
//
// Se dibuja cada tamaño por separado (es vectorial): el de 16 px es nítido en vez
// de un 1024 reducido.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:senus_app/widgets/comunes.dart';

const _tamanos = [16, 24, 32, 48, 64, 128, 256, 512, 1024];

// El fondo oscuro del tema de SENUS (senus_tema.dart: fondo = 0xFF121315).
const _baldosa = Color(0xFF121315);

void main() {
  testWidgets('genera los iconos de SENUS', (tester) async {
    final salida = Directory('build/iconos')..createSync(recursive: true);
    for (final tam in _tamanos) {
      final clave = GlobalKey();
      tester.view.physicalSize = Size(tam.toDouble(), tam.toDouble());
      tester.view.devicePixelRatio = 1.0;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: RepaintBoundary(
            key: clave,
            child: SizedBox(
              width: tam.toDouble(),
              height: tam.toDouble(),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: _baldosa,
                  borderRadius: BorderRadius.circular(tam * 0.22),
                ),
                child: Center(child: LogoSenus(tam: tam * 0.74)),
              ),
            ),
          ),
        ),
      );
      final frontera =
          clave.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final bytes = await tester.runAsync(() async {
        final img = await frontera.toImage(pixelRatio: 1.0);
        final d = await img.toByteData(format: ui.ImageByteFormat.png);
        return d!.buffer.asUint8List();
      });
      File('${salida.path}/icono_$tam.png').writeAsBytesSync(bytes!);
    }
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  });
}
