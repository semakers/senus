// El flujo heredado (`SENUS_FLUJO_LEGADO=1`): `InstalacionInicial.enviarMain`
// también graba la región 0 la última. El camino normal es ClienteBlInstaller.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:senus_app/datos/instalacion_inicial.dart';
import 'package:senus_app/datos/transporte_bl.dart';

import 'apoyo/telefono_simulado.dart';

class _Espia extends TransporteBlFalso {
  final List<int> writes = [];
  int crcs = 0;
  int? arg0;
  _Espia() : super(vid: vidSenew, pid: pidBlInstaller);

  @override
  Future<void> controlOut(int bRequest, int wValue, int wIndex, Uint8List data,
      {Duration timeout = const Duration(seconds: 30)}) async {
    if (bRequest == blRArg0) arg0 = wValue | (wIndex << 16);
    if (bRequest == blRGo) {
      final op = wValue & 0xFF;
      if (op == blOpWrite) writes.add(arg0!);
      if (op == blOpCrc) crcs++;
    }
    await super.controlOut(bRequest, wValue, wIndex, data, timeout: timeout);
  }
}

Future<(_Espia, InstalacionInicial)> abierto() async {
  final e = _Espia();
  final i = InstalacionInicial(fabricaBl: (_) => e);
  await i.esperarPuenteInstaller(
      timeout: const Duration(seconds: 1),
      intervalo: const Duration(milliseconds: 1));
  return (e, i);
}

void main() {
  test('enviarMain: la región 0 la última y el resto en orden', () async {
    final (e, i) = await abierto();
    await i.enviarMain(mainDePrueba(1));
    expect(e.writes.first, blMainIni + blRegion);
    expect(e.writes.last, blMainIni);
    expect(e.writes.where((d) => d == blMainIni), hasLength(1));
    final resto = e.writes.sublist(0, e.writes.length - 1);
    expect(resto, [...resto]..sort());
  });

  test('comprueba el tramo antes de grabar los vectores, y luego todo', () async {
    final (e, i) = await abierto();
    await i.enviarMain(mainDePrueba(1));
    expect(e.crcs, 2);
  });

  test('con CRC mal en el tramo, los vectores no se graban', () async {
    final (e, i) = await abierto();
    e.crcHonesto = false;
    await expectLater(
        i.enviarMain(mainDePrueba(1)), throwsA(isA<InstalacionInicialError>()));
    expect(e.writes, isNot(contains(blMainIni)));
  });

  test('un main de una región solo tiene la región 0', () async {
    final (e, i) = await abierto();
    await i.enviarMain(mainDePrueba(1, tam: blRegion));
    expect(e.writes, [blMainIni]);
  });

  test('el progreso llega al total y lo grabado es lo mandado', () async {
    final (e, i) = await abierto();
    final m = mainDePrueba(1);
    final p = <int>[];
    await i.enviarMain(m, onProgreso: (h, t) => p.add(h));
    expect(p.last, m.length);
    expect(p, [...p]..sort());
    expect(e.escritoPorRegion[blMainIni]!.sublist(0, 4), m.sublist(0, 4));
    expect(e.escritoPorRegion[blMainIni + 0x3C00], m.sublist(0x3C00));
  });

  test('el W6FS no tiene vectores: sigue en orden ascendente', () async {
    final (e, i) = await abierto();
    await i.enviarW6fs(Uint8List(0x2000), direccion: w6fsIniMin);
    expect(e.writes, [...e.writes]..sort());
    expect(e.writes.first, w6fsIniMin);
  });
}
