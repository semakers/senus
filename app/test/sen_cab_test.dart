// La cabecera .sen ampliada y la comprobación del fichero entero.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:senus_app/datos/iconos_sistema.dart';
import 'package:senus_app/datos/sen_cab.dart';
import 'package:senus_app/datos/transporte_bl.dart' show crc32DeDatos;

import 'apoyo/backend_simulado.dart';

void main() {
  test('lee los campos nuevos en sus desplazamientos', () {
    final c = SenCab.deBytes(senDePrueba(verApp: 7, nombre: 'Música'))!;
    expect(c.verApp, 7);
    expect(c.nombre, 'Música');
    expect(c.maquina, maquinaArmv5te);
    expect(c.caps, 0x02000300);
    expect(c.anMin, 240);
    expect(c.alMin, 320);
    expect(c.tamRec, 16);
    expect(c.perfil, 1);
    expect(c.apiMayor, 1);
    expect(c.apiMenor, 7);
    expect(c.crcRec, crc32DeDatos(Uint8List(16)..fillRange(0, 16, 0x55)));
    expect(c.crcCuerpo, crc32DeDatos(Uint8List(64)..fillRange(0, 64, 0xAA)));
  });

  test('con 128 bytes basta para la cabecera', () {
    final b = senDePrueba(verApp: 3);
    expect(SenCab.deBytes(Uint8List.sublistView(b, 0, 128))?.verApp, 3);
    expect(SenCab.deBytes(Uint8List.sublistView(b, 0, 127)), isNull);
  });

  test('sin la magia no es un .sen', () {
    final b = senDePrueba()..[0] = 0;
    expect(SenCab.deBytes(b), isNull);
    expect(problemaDeSen(b), contains('cabecera'));
  });

  test('conIcono conserva los campos nuevos', () {
    final c = SenCab.deBytes(senDePrueba(verApp: 9, iconoAn: 0))!;
    expect(c.traeIcono, isFalse);
    final i = conIcono(c);
    expect(i.traeIcono, isTrue);
    expect(i.verApp, 9);
    expect(i.caps, c.caps);
    expect(i.crcCab, c.crcCab);
  });

  group('problemaDeSen', () {
    test('uno bueno pasa', () {
      expect(problemaDeSen(senDePrueba()), isNull);
      expect(problemaDeSen(senDePrueba(tamRec: 0)), isNull);
    });

    test('CRC de la cabecera', () {
      final b = senDePrueba()..[90] ^= 1;
      expect(problemaDeSen(b), contains('cabecera'));
    });

    test('CRC del cuerpo', () {
      final b = senDePrueba()..[130] ^= 1;
      expect(problemaDeSen(b), contains('cuerpo'));
    });

    test('crc_cuerpo NO cubre los recursos: los cubre crc_rec', () {
      final b = senDePrueba();
      b[b.length - 1] ^= 1;
      expect(problemaDeSen(b), contains('recursos'));
    });

    test('cortado', () {
      final b = senDePrueba();
      expect(problemaDeSen(Uint8List.sublistView(b, 0, b.length - 1)),
          contains('cortado'));
    });

    test('le sobra algo', () {
      final b = senDePrueba();
      expect(problemaDeSen(Uint8List.fromList([...b, 0])), contains('cortado'));
    });

    test('otra máquina', () {
      final b = senDePrueba()..[6] = 2;
      _resellar(b);
      expect(problemaDeSen(b), contains('ARMv5TE'));
    });

    test('perfil desconocido', () {
      final b = senDePrueba()..[7] = 9;
      _resellar(b);
      expect(problemaDeSen(b), contains('Perfil'));
    });

    test('tam_rec que no cabe', () {
      final b = senDePrueba();
      ByteData.sublistView(b).setUint32(112, 0xFFFF, Endian.little);
      _resellar(b);
      expect(problemaDeSen(b), contains('recursos'));
    });
  });
}

void _resellar(Uint8List b) => ByteData.sublistView(b).setUint32(
    124, crc32DeDatos(Uint8List.sublistView(b, 0, 124)), Endian.little);
