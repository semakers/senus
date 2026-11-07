// Dos pantallas pueden hablar a la vez por la misma sesión: cambiar de pestaña
// no cancela lo que estaba en marcha. El USB lleva una transacción a la vez.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:senus_app/mtp/canal_gestion.dart';
import 'package:senus_app/mtp/operaciones.dart';
import 'package:senus_app/mtp/sesion_mtp.dart';

import 'apoyo/backend_simulado.dart';
import 'apoyo/telefono_simulado.dart';

Future<(TelefonoSimulado, SesionMtp)> banco() async {
  final t = TelefonoSimulado();
  t.instalarYArrancar(ImagenConocida(mainDePrueba(290), 290, '0.29.0'));
  return (t, await PuertosSimulados(t).conectar());
}

void main() {
  test('órdenes a la vez: cada una recibe lo suyo', () async {
    final (t, s) = await banco();
    t.crearFichero(storageMemoria, t.carpeta(storageMemoria, 'apps')!.handle,
        'x.sen', senDePrueba());
    final c = CanalGestion(s);
    final r = await Future.wait<Object?>([
      c.info(),
      c.leerAjustes(),
      s.almacenes(),
      s.listarAppsMtp(),
      c.apps(),
      c.btEstado(),
    ]);
    expect((r[0] as SenInfo).build, 290);
    expect(r[1] as List, hasLength(26));
    expect((r[2] as ResultadoMtp).bien, isTrue);
    expect(r[3] as List, hasLength(1));
    expect(r[4] as List, hasLength(1));
    expect((r[5] as BtEstado).encendido, isTrue);
  });

  test('nada se cuela entre SendObjectInfo y SendObject', () async {
    final (t, s) = await banco();
    final a = senDePrueba(nombre: 'A');
    final b = senDePrueba(nombre: 'B');
    final r = await Future.wait<Object?>([
      s.subirApp('a.sen', a),
      s.listarAppsMtp(),
      s.subirApp('b.sen', b),
      s.almacenes(),
    ]);
    expect((r[0] as ResultadoMtp).bien, isTrue, reason: '${r[0]}');
    expect((r[2] as ResultadoMtp).bien, isTrue, reason: '${r[2]}');
    final h = t.carpeta(storageMemoria, 'apps')!.handle;
    final subidos = t.objetos.values.where((o) => o.padre == h);
    expect(subidos.map((o) => o.nombre).toSet(), {'a.sen', 'b.sen'});
    expect(subidos.firstWhere((o) => o.nombre == 'b.sen').datos, b);
  });

  test('una orden que falla no atasca la cola', () async {
    final (t, s) = await banco();
    t.cable = false;
    await expectLater(s.almacenes(), throwsA(anything));
    t.cable = true;
    expect((await s.almacenes()).bien, isTrue);
  });

  test('cerrar espera a lo que está en marcha', () async {
    final (t, s) = await banco();
    final f = s.leerParcial(t.carpeta(storageMemoria, 'apps')!.handle, 0, 0);
    await s.cerrar();
    expect((await f).codigoResp, isNot(0));
    expect(t.sesionAbierta, isFalse);
  });

  test('subir por la otra entrada, también pegado', () async {
    final (t, s) = await banco();
    final h = t.carpeta(storageMemoria, 'apps')!.handle;
    final b = Uint8List.fromList([1, 2, 3]);
    final r = await Future.wait<Object?>(
        [s.enviarObjeto(h, 'x.bin', b), s.almacenes()]);
    expect((r[0] as ResultadoMtp).bien, isTrue);
    expect(t.objetos.values.firstWhere((o) => o.nombre == 'x.bin').datos, b);
  });
}
