// Ajustes: los 26 campos, escribir, releer, comparar y enseñar lo que no entró.

import 'package:flutter_test/flutter_test.dart';
import 'package:senus_app/datos/ajustes_senew.dart';
import 'package:senus_app/mtp/canal_gestion.dart';

import 'apoyo/telefono_simulado.dart';

Future<(TelefonoSimulado, ServicioAjustes)> banco() async {
  final t = TelefonoSimulado();
  t.instalarYArrancar(ImagenConocida(mainDePrueba(290), 290, '0.29.0'));
  final s = await PuertosSimulados(t).conectar();
  return (t, ServicioAjustes(CanalGestion(s, pausaOcupado: Duration.zero)));
}

void main() {
  group('la tabla', () {
    test('son 26, con claves 0x0001..0x001A y sin repetir', () {
      expect(defsAjustes, hasLength(26));
      expect({for (final d in defsAjustes) d.clave},
          {for (var i = 1; i <= 26; i++) i});
      expect({for (final d in defsAjustes) d.campo}, hasLength(26));
    });

    test('todas tienen nombre para personas y grupo', () {
      for (final d in defsAjustes) {
        expect(d.nombre, isNotEmpty);
        expect(d.nombre, isNot(contains('_')), reason: d.campo);
        expect(d.grupo, isNot(GrupoAjuste.otros), reason: d.campo);
      }
    });

    test('los grupos del encargo', () {
      expect({for (final d in defsAjustes) d.grupo}, {
        GrupoAjuste.relojAlarma,
        GrupoAjuste.pantalla,
        GrupoAjuste.sonido,
        GrupoAjuste.podometro,
        GrupoAjuste.menu,
        GrupoAjuste.luces,
      });
    });

    test('los rangos no están en la tabla: los dice el firmware', () async {
      final (t, s) = await banco();
      t.ajustes.firstWhere((a) => a.clave == ClaveAj.volumen);
      final l = await s.leer();
      final v = l.firstWhere((a) => a.clave == ClaveAj.volumen);
      expect((v.min, v.max), (0, 5));
    });

    test('las opciones con nombre son las del firmware de hoy', () {
      expect(defDe(ClaveAj.tema)!.opciones, hasLength(5));
      expect(defDe(ClaveAj.menuEstilo)!.opciones, hasLength(6));
      // los nombres de m3_estilo_nombre (sistema/shell/m3d_dibujo.c), en su orden: M3_ESCRITORIO = 5
      expect(defDe(ClaveAj.menuEstilo)!.opciones[5], 'Escritorio');
      expect(defDe(ClaveAj.lucesColor)!.opciones, hasLength(10));
      expect(defDe(ClaveAj.mediosColor)!.opciones, hasLength(11));
      expect(defDe(ClaveAj.menuEfecto)!.opciones, hasLength(3));
      expect(defDe(ClaveAj.pasosAhorro)!.opciones, hasLength(3));
      expect(defDe(ClaveAj.menuEjes)!.opciones, hasLength(8));
    });
  });

  group('aplicar', () {
    test('escribe, relee y compara: todo bien', () async {
      final (t, s) = await banco();
      final antes = await s.leer();
      final r = await s.aplicar(const [
        AjustePoner(ClaveAj.brillo, tipoAjU8, 75),
        AjustePoner(ClaveAj.hora12, tipoAjBool, true),
        AjustePoner(ClaveAj.zonaMin, tipoAjI16, 120),
        AjustePoner(ClaveAj.fondo, tipoAjTexto, '/fondos/x.gif'),
      ], antes);
      expect(r.todoBien, isTrue);
      expect(r.aplicadas, hasLength(4));
      expect(r.corregidos, isEmpty);
      expect(t.ajustes.firstWhere((a) => a.clave == ClaveAj.brillo).valor, 75);
    });

    test('fuera de rango: se enseña qué no se aplicó', () async {
      final (_, s) = await banco();
      final antes = await s.leer();
      final r = await s.aplicar(const [
        AjustePoner(ClaveAj.brillo, tipoAjU8, 5), // por debajo del mínimo
        AjustePoner(ClaveAj.volumen, tipoAjU8, 2),
      ], antes);
      expect(r.todoBien, isFalse);
      expect(r.respuesta.fueraDeRango, 1);
      expect(r.aplicadas, [ClaveAj.volumen]);
      final d = r.noAplicadas.single;
      expect(d.clave, ClaveAj.brillo);
      expect(d.pedido, 5);
      expect(d.leido, 50);
      expect(d.nombre, 'Brillo de pantalla');
    });

    test('el firmware corrige atenuar al bajar apagar: se ve', () async {
      final (_, s) = await banco();
      final antes = await s.leer();
      final r = await s.aplicar(
          const [AjustePoner(ClaveAj.apagarS, tipoAjU8, 10)], antes);
      expect(r.todoBien, isTrue);
      final c = r.corregidos.single;
      expect(c.clave, ClaveAj.atenuarS);
      expect((c.pedido, c.leido), (15, 10));
    });

    test('pedir atenuar por encima de apagar: no se aplica y se ve', () async {
      final (_, s) = await banco();
      final antes = await s.leer();
      final r = await s.aplicar(
          const [AjustePoner(ClaveAj.atenuarS, tipoAjU8, 60)], antes);
      expect(r.todoBien, isFalse);
      expect(r.noAplicadas.single.leido, 30);
    });

    test('el aviso de «se aplicó» no se fía de p1: relee', () async {
      final (t, s) = await banco();
      final antes = await s.leer();
      t.ajusteQueNoSeGuarda = ClaveAj.tema;
      final r = await s.aplicar(
          const [AjustePoner(ClaveAj.tema, tipoAjU8, 3)], antes);
      expect(r.respuesta.aplicadas, 1, reason: 'el firmware dice que sí');
      expect(r.todoBien, isFalse, reason: 'y la relectura dice que no');
      expect(r.noAplicadas.single.leido, 0);
    });

    test('espera a que el hilo de la interfaz aplique (R_OCUPADO)', () async {
      final (t, s) = await banco();
      t.ajustesPendientes = 4;
      final antes = await s.leer();
      final r = await s.aplicar(
          const [AjustePoner(ClaveAj.brillo, tipoAjU8, 75)], antes);
      expect(r.todoBien, isTrue);
      expect(t.ocupadoAjustes, 0);
    });

    test('un bool que vuelve como bool cuadra', () {
      final (ok, mal, _) = compararAjustes(
        pedidos: const [AjustePoner(2, tipoAjBool, true)],
        antes: const [],
        despues: const [
          AjusteLeido(clave: 2, tipo: tipoAjBool, min: 0, max: 1, valor: true)
        ],
      );
      expect(ok, [2]);
      expect(mal, isEmpty);
    });

    test('una clave que desaparece al releer no cuenta como aplicada', () {
      final (ok, mal, _) = compararAjustes(
        pedidos: const [AjustePoner(2, tipoAjBool, true)],
        antes: const [],
        despues: const [],
      );
      expect(ok, isEmpty);
      expect(mal.single.leido, isNull);
    });
  });

  test('poner la hora: la del computador, en UTC, con su zona', () async {
    final (t, s) = await banco();
    final ahora = DateTime.utc(2026, 11, 1, 6, 30);
    await s.ponerHora(ahora);
    expect(t.utcPuesto, ahora.millisecondsSinceEpoch ~/ 1000);
    expect(t.zonaPuesta, 0);
  });

  test('textoAplicados: singular y plural', () {
    expect(textoAplicados(1, frase: true),
        '1 ajuste aplicado y comprobado al releerlo.');
    expect(textoAplicados(3, frase: true),
        '3 ajustes aplicados y comprobados al releerlos.');
    expect(textoAplicados(1), '1 ajuste aplicado y comprobado.');
    expect(textoAplicados(2), '2 ajustes aplicados y comprobados.');
  });

  test('textoZona', () {
    expect(textoZona(-360), 'UTC-6:00');
    expect(textoZona(330), 'UTC+5:30');
    expect(textoZona(0), 'UTC+0:00');
  });

  test('una clave nueva que este SENUS no conoce no se esconde', () async {
    final (t, s) = await banco();
    t.ajustes.add(AjSim(0x30, 2, 0, 9, 4));
    final l = await s.leer();
    expect(l, hasLength(27));
    expect(defDe(0x30), isNull);
    final r = await s.aplicar(const [AjustePoner(0x30, tipoAjU8, 5)], l);
    expect(r.todoBien, isTrue);
  });
}
