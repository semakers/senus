// `ClienteBlInstaller` contra el BL: la región 0, la última también en la
// primera instalación.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:senus_app/datos/cliente_bl_installer.dart';
import 'package:senus_app/datos/transporte_bl.dart';
import 'package:senus_app/mtp/transporte.dart' show DispositivoVisto;

import 'apoyo/telefono_simulado.dart';

/// El BL falso de siempre, apuntando el orden de los WRITE.
class _Espia extends TransporteBlFalso {
  final List<int> writes = [];
  final Map<int, int> args = {};
  _Espia() : super(vid: vidSenew, pid: pidBlInstaller);

  @override
  Future<void> controlOut(int bRequest, int wValue, int wIndex, Uint8List data,
      {Duration timeout = const Duration(seconds: 30)}) async {
    if (bRequest == blRArg0) args[0] = wValue | (wIndex << 16);
    if (bRequest == blRGo && (wValue & 0xFF) == blOpWrite) writes.add(args[0]!);
    await super.controlOut(bRequest, wValue, wIndex, data, timeout: timeout);
  }
}

Future<_Espia> _espiaAbierto() async {
  final e = _Espia();
  await e.abrir(DispositivoVisto(id: 0, vid: vidSenew, pid: pidBlInstaller, bcdDevice: 0));
  return e;
}

void main() {
  test('primera instalación: el main se graba con la región 0 al final', () async {
    final e = await _espiaAbierto();
    final c = ClienteBlInstaller(e, sondeo: Duration.zero);
    await c.instalar(main: mainDePrueba(1), blClasico: Uint8List(2048));
    expect(e.writes.first, blMainIni + blRegion);
    expect(e.writes.last, blMainIni);
    expect(e.writes.where((d) => d == blMainIni), hasLength(1));
    expect(e.haSalido, isTrue);
  });

  test('un main de una sola región no tiene tramo: solo la región 0', () async {
    final e = await _espiaAbierto();
    final c = ClienteBlInstaller(e, sondeo: Duration.zero);
    await c.instalar(main: mainDePrueba(1, tam: blRegion), blClasico: Uint8List(1024));
    expect(e.writes, [blMainIni]);
  });

  test('con CRC mal en el tramo, la región 0 no se graba', () async {
    final e = await _espiaAbierto();
    e.crcHonesto = false;
    final c = ClienteBlInstaller(e, sondeo: Duration.zero);
    await expectLater(
        c.instalar(main: mainDePrueba(1), blClasico: Uint8List(1024)),
        throwsA(isA<InstaladorBlError>()));
    expect(e.writes, isNot(contains(blMainIni)));
  });

  test('el tramo cuenta su progreso desde cero hasta el final', () async {
    final e = await _espiaAbierto();
    final c = ClienteBlInstaller(e, sondeo: Duration.zero);
    final p = <(int, int)>[];
    await c.grabarRestoMain(mainDePrueba(1), alProgreso: (et, h, t) {
      if (et == EtapaBl.grabarMain) p.add((h, t));
    });
    expect(p.first, (0, 0x4000 - blRegion));
    expect(p.last, (0x4000 - blRegion, 0x4000 - blRegion));
  });

  test('un main que no es múltiplo de la región se rechaza en el tramo', () async {
    final e = await _espiaAbierto();
    final c = ClienteBlInstaller(e, sondeo: Duration.zero);
    expect(c.grabarRestoMain(Uint8List(1000)), throwsA(isA<InstaladorBlError>()));
  });

  test('rellenarARegion pone 0xFF hasta el múltiplo', () {
    final r = ClienteBlInstaller.rellenarARegion(Uint8List(1));
    expect(r, hasLength(blRegion));
    expect(r.last, 0xFF);
    final d = Uint8List(blRegion);
    expect(identical(ClienteBlInstaller.rellenarARegion(d), d), isTrue);
  });

  test('leerNor va de 64 en 64 y devuelve lo que hay', () async {
    final t = TelefonoSimulado();
    t.instalarYArrancar(ImagenConocida(mainDePrueba(7), 7, '7'));
    t.entrarAlBlPorBandera();
    final c = ClienteBlInstaller(TransporteBlSimulado(t), sondeo: Duration.zero);
    final b = await c.leerNor(blMainIni + 3, 200);
    expect(b, t.nor.sublist(3, 203));
    expect(await c.crcNor(blMainIni, 0x4000),
        crc32DeDatos(t.nor.sublist(0, 0x4000)));
  });

  test('info: se niega si no es SNBL', () async {
    final c = ClienteBlInstaller(_Falsario(), sondeo: Duration.zero);
    expect(c.info(), throwsA(isA<InstaladorBlError>()));
  });
}

class _Falsario extends TransporteBlFalso {
  _Falsario() : super(vid: vidSenew, pid: pidBlPropio) {
    abierto = true;
  }
  @override
  Future<Uint8List> controlIn(int bRequest, int wValue, int wIndex, int wLength,
          {Duration timeout = const Duration(seconds: 30)}) async =>
      Uint8List(wLength);
}
