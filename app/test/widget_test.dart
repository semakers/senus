// Pruebas mínimas de la codificación MTP (round-trip).
// Las pruebas de widgets viven en otros ficheros si se añaden; esta sustituye
// al smoke test que dejó `flutter create` y que no aplicaba a SENUS.

import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:senus_app/mtp/codificacion.dart';

void main() {
  test('round trip de cadena MTP', () {
    final b = cadenaMtp('W580 sistema propio');
    final (s, _) = leerCadenaMtp(b, 0);
    expect(s, 'W580 sistema propio');
  });

  test('empaquetar/desempaquetar contenedor', () {
    final c = Contenedor(
      tipo: tipoOrden,
      codigo: 0x1001,
      idTransaccion: 7,
      parametros: const [0x00010001],
      datos: Uint8List(0),
    );
    final b = c.empaquetar();
    expect(b.length, 12 + 4);
    final c2 = Contenedor.desempaquetarCabecera(b);
    expect(c2.tipo, tipoOrden);
    expect(c2.codigo, 0x1001);
    expect(c2.parametros, [0x00010001]);
  });

  test('fecha MTP', () {
    expect(fechaMtp(DateTime.utc(2026, 10, 15, 12, 34, 56)), '20261015T123456');
    final d = parsearFechaMtp('20261015T123456');
    expect(d, isNotNull);
    expect(d!.year, 2026);
  });
}
