// El icono de 1 bit de un .sen, escalado: el mismo en el Catálogo y en Apps.

import 'package:flutter/material.dart';

import '../datos/iconos_sistema.dart';
import '../datos/sen_cab.dart';

class IconoSen extends StatelessWidget {
  final SenCab cab;
  const IconoSen({super.key, required this.cab});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 48,
      height: 48,
      child: CustomPaint(
        painter: _PintorIcono(
          cab: conIcono(cab),
          encendido: Theme.of(context).colorScheme.onPrimaryContainer,
          fondo: Theme.of(context).colorScheme.primaryContainer,
        ),
      ),
    );
  }
}

class _PintorIcono extends CustomPainter {
  final SenCab cab;
  final Color encendido;
  final Color fondo;
  _PintorIcono({required this.cab, required this.encendido, required this.fondo});

  @override
  void paint(Canvas canvas, Size size) {
    final pFondo = Paint()..color = fondo;
    final rrect = RRect.fromRectAndRadius(
        Offset.zero & size, const Radius.circular(8));
    canvas.drawRRect(rrect, pFondo);
    if (!cab.traeIcono) {
      // Icono genérico: un cuadradito en el centro.
      final p = Paint()..color = encendido;
      final lado = size.shortestSide * 0.55;
      final rect = Rect.fromCenter(
          center: size.center(Offset.zero), width: lado, height: lado);
      canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(4)), p);
      return;
    }
    final mat = cab.aMatriz();
    final cols = cab.iconoAn;
    const rows = 12;
    // Espacio interior con 10 % de margen.
    final margen = size.shortestSide * 0.1;
    final anc = size.width - 2 * margen;
    final al = size.height - 2 * margen;
    final cx = anc / cols;
    final cy = al / rows;
    final c = cx < cy ? cx : cy;
    final totalX = c * cols;
    final totalY = c * rows;
    final x0 = (size.width - totalX) / 2;
    final y0 = (size.height - totalY) / 2;
    final p = Paint()..color = encendido;
    for (var r = 0; r < rows; r++) {
      for (var ci = 0; ci < cols; ci++) {
        if (mat[r][ci]) {
          canvas.drawRect(
            Rect.fromLTWH(x0 + ci * c, y0 + r * c, c + 0.5, c + 0.5),
            p,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PintorIcono old) =>
      old.cab != cab || old.encendido != encendido || old.fondo != fondo;
}
