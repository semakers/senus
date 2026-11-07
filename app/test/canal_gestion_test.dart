// El canal de gestión contra el teléfono simulado, byte a byte con el contrato.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:senus_app/datos/conexion_telefono.dart';
import 'package:senus_app/mtp/canal_gestion.dart';
import 'package:senus_app/mtp/operaciones.dart';
import 'package:senus_app/mtp/sesion_mtp.dart';

import 'apoyo/telefono_simulado.dart';

const imei = '35000000000009';

Future<(TelefonoSimulado, SesionMtp, CanalGestion)> banco(
    {bool canal = true}) async {
  final t = TelefonoSimulado();
  t.instalarYArrancar(
      ImagenConocida(mainDePrueba(290), 290, '0.29.0', canal: canal));
  t.idAparato = imei;
  final s = await PuertosSimulados(t).conectar();
  return (t, s, CanalGestion(s, pausaOcupado: Duration.zero));
}

void main() {
  group('SEN_INFO, 128 bytes fijos', () {
    Uint8List ejemplo() {
      final b = Uint8List(128);
      final v = ByteData.sublistView(b);
      v.setUint16(0, 1, Endian.little);
      v.setUint16(2, 128, Endian.little);
      v.setUint32(4, 290, Endian.little);
      v.setUint16(8, 1, Endian.little);
      v.setUint16(10, 11, Endian.little);
      v.setUint16(12, 1, Endian.little);
      b[14] = 87;
      b[15] = 0x17;
      b.setRange(16, 22, [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]);
      b.setRange(24, 30, ascii.encode('0.29.0'));
      b.setRange(40, 44, ascii.encode('w580'));
      b.setRange(48, 54, ascii.encode('DB2020'));
      b.setRange(56, 76, ascii.encode('Oct 31 2026 23:50:01'));
      b.setRange(80, 94, ascii.encode(imei));
      v.setUint32(96, 9, Endian.little);
      return b;
    }

    test('cada campo en su desplazamiento', () {
      final i = SenInfo.deBytes(ejemplo());
      expect(i.build, 290);
      expect(i.api, '1.11');
      expect(i.blVersion, 1);
      expect(i.bateria, 87);
      expect(i.hayTarjeta, isTrue);
      expect(i.cargando, isTrue);
      expect(i.puenteCompilado, isTrue);
      expect(i.arranqueVigilado, isFalse);
      expect(i.idVinculado, isTrue);
      expect(i.bdAddrTexto, 'aa:bb:cc:dd:ee:ff');
      expect(i.version, '0.29.0');
      expect(i.modelo, 'w580');
      expect(i.soc, 'DB2020');
      expect(i.compilacion, 'Oct 31 2026 23:50:01');
      expect(i.idAparato, imei);
      expect(i.ajustesVersion, 9);
    });

    test('lo que el teléfono no sabe', () {
      final b = ejemplo();
      b[14] = 0xFF;
      b.fillRange(16, 22, 0);
      b.fillRange(80, 96, 0);
      final i = SenInfo.deBytes(b);
      expect(i.bateria, isNull);
      expect(i.bdAddrTexto, isNull);
      expect(i.idAparato, '');
    });

    test('corto, otro formato u otro tamaño: no se cree', () {
      expect(() => SenInfo.deBytes(Uint8List(127)),
          throwsA(isA<CanalMalFormado>()));
      final f = ejemplo()..[0] = 2;
      expect(() => SenInfo.deBytes(f), throwsA(isA<CanalMalFormado>()));
      final t = ejemplo()..[2] = 64;
      expect(() => SenInfo.deBytes(t), throwsA(isA<CanalMalFormado>()));
    });

    test('ida y vuelta', () async {
      final (t, _, c) = await banco();
      final i = await c.info();
      expect(i.build, 290);
      expect(i.idAparato, imei);
      expect(i.aBytes(), t.senInfo().aBytes());
    });
  });

  group('detección por OperationsSupported', () {
    test('con 0x9400 hay canal', () async {
      final (_, s, _) = await banco();
      expect((await s.info()).valor!.canalGestion, isTrue);
    });

    test('sin él (sis28h) degrada: se conecta y lista sin romperse', () async {
      final (t, s, _) = await banco(canal: false);
      t.crearFichero(storageMemoria, t.carpeta(storageMemoria, 'apps')!.handle,
          'x.sen', Uint8List(4));
      final tel = (await leerTelefono(s)).valor!;
      expect(tel.canalGestion, isFalse);
      expect(tel.gestion, isNull);
      expect((await s.listarAppsMtp()).single.nombre, 'x.sen');
    });

    test('un SEN_INFO que falla no tumba la conexión', () async {
      final (t, s, _) = await banco();
      t.corriendo = ImagenConocida(mainDePrueba(1), 1, '0', canal: true);
      t.senInfoRoto = true;
      final tel = (await leerTelefono(s)).valor!;
      expect(tel.canalGestion, isTrue);
      expect(tel.gestion, isNull);
    });
  });

  group('ajustes', () {
    test('lee los 26, con tipo y rango', () async {
      final (_, _, c) = await banco();
      final l = await c.leerAjustes();
      expect(l, hasLength(26));
      final zona = l.firstWhere((a) => a.clave == 6);
      expect(zona.tipo, tipoAjI16);
      expect(zona.valor, -360);
      expect((zona.min, zona.max), (-720, 840));
      expect(l.firstWhere((a) => a.clave == 2).valor, isFalse);
      expect(l.firstWhere((a) => a.clave == 0x1A).esTexto, isTrue);
    });

    test('espera mientras haya cambios sin aplicar (R_OCUPADO)', () async {
      final (t, _, c) = await banco();
      t.ocupadoAjustes = 3;
      expect(await c.leerAjustes(), hasLength(26));
      expect(t.ocupadoAjustes, 0);
    });

    test('poner: cada clave es independiente', () async {
      final (t, _, c) = await banco();
      final r = await c.ponerAjustes(const [
        AjustePoner(0x07, tipoAjU8, 80),
        AjustePoner(0x0C, tipoAjU8, 9), // fuera de rango
        AjustePoner(0xFF, tipoAjU8, 1), // desconocida
        AjustePoner(0x06, tipoAjI16, 60),
        AjustePoner(0x1A, tipoAjTexto, '/fondos/a.gif'),
        AjustePoner(0x02, tipoAjBool, true),
      ]);
      expect((r.aplicadas, r.fueraDeRango, r.desconocidas), (4, 1, 1));
      Object v(int k) => t.ajustes.firstWhere((a) => a.clave == k).valor;
      expect(v(0x07), 80);
      expect(v(0x0C), 4);
      expect(v(0x06), 60);
      expect(v(0x1A), '/fondos/a.gif');
      expect(v(0x02), true);
    });

    test('un tipo que no cuadra cuenta como fuera de rango', () async {
      final (_, _, c) = await banco();
      final r = await c.ponerAjustes(const [AjustePoner(0x07, tipoAjI16, 80)]);
      expect(r.fueraDeRango, 1);
    });

    test('poner también espera con cambios sin aplicar (R_OCUPADO)', () async {
      final (t, _, c) = await banco();
      t.ocupadoAjustes = 3;
      final r = await c.ponerAjustes(const [AjustePoner(0x07, tipoAjU8, 80)]);
      expect(r.aplicadas, 1);
      expect(t.ocupadoAjustes, 0);
    });

    test('bytes de más tras la última entrada: R_PARAM_MAL', () async {
      final (t, s, _) = await banco();
      final b = empaquetarAjustes(const [AjustePoner(0x07, tipoAjU8, 80)]);
      final mal = Uint8List.fromList([...b, 0]);
      final (cod, _, _) = await s.operacion(opSenAjPoner, const [], datosSalida: mal);
      expect(cod, rParamMal);
      expect(t.ajustes.firstWhere((a) => a.clave == 7).valor, 50);
    });

    test('dataset truncado: R_PARAM_MAL y no se aplica nada', () async {
      final (t, s, _) = await banco();
      final b = empaquetarAjustes(const [AjustePoner(0x07, tipoAjU8, 80)]);
      final mal = Uint8List.sublistView(b, 0, b.length - 1);
      final (cod, _, _) = await s.operacion(opSenAjPoner, const [], datosSalida: mal);
      expect(cod, rParamMal);
      expect(t.ajustes.firstWhere((a) => a.clave == 7).valor, 50);
    });

    test('el dataset de poner es el del contrato, byte a byte', () {
      final b = empaquetarAjustes(const [
        AjustePoner(0x0006, tipoAjI16, -360),
        AjustePoner(0x0002, tipoAjBool, true),
        AjustePoner(0x001A, tipoAjTexto, 'ab'),
      ]);
      expect(b, [
        1, 0, 3, 0, //
        6, 0, 3, 2, 0x98, 0xFE, //
        2, 0, 1, 1, 1, //
        0x1A, 0, 4, 2, 0x61, 0x62, //
      ]);
    });

    test('parsear un dataset cortado no lee fuera', () {
      final b = empaquetarAjustesLeidos(const [
        AjusteLeido(clave: 1, tipo: tipoAjU8, min: 0, max: 4, valor: 2)
      ]);
      for (var n = 0; n < b.length; n++) {
        expect(() => parsearAjustes(Uint8List.sublistView(b, 0, n)),
            throwsA(isA<CanalMalFormado>()),
            reason: 'cortado a $n');
      }
    });

    test('un tipo desconocido se conserva crudo', () {
      final b = Uint8List.fromList(
          [1, 0, 1, 0, 0x30, 0, 9, 2, 0, 0, 0, 0, 7, 8]);
      final a = parsearAjustes(b).single;
      expect(a.tipo, 9);
      expect(a.valor, [7, 8]);
    });
  });

  group('reloj y vínculo', () {
    test('SEN_RELOJ: u32 utc, i16 zona, u16 reserva', () {
      final b = empaquetarReloj(DateTime.utc(2026, 11, 1), -360);
      final v = ByteData.sublistView(b);
      expect(b, hasLength(8));
      expect(v.getUint32(0, Endian.little),
          DateTime.utc(2026, 11, 1).millisecondsSinceEpoch ~/ 1000);
      expect(v.getInt16(4, Endian.little), -360);
      expect(v.getUint16(6, Endian.little), 0);
    });

    test('llega al teléfono', () async {
      final (t, _, c) = await banco();
      await c.ponerReloj(DateTime.utc(2026, 11, 1), 120);
      expect(t.zonaPuesta, 120);
      expect(t.utcPuesto, 1793491200);
    });

    test('reloj: espera con cambios sin aplicar (R_OCUPADO)', () async {
      final (t, _, c) = await banco();
      t.ocupadoAjustes = 2;
      await c.ponerReloj(DateTime.utc(2026, 11, 1), 120);
      expect(t.zonaPuesta, 120);
    });

    test('reloj: lo que el firmware rechazaría ni se manda', () async {
      final (t, _, c) = await banco();
      for (final (fecha, zona) in [
        (DateTime.utc(1999, 12, 31), 0),
        (DateTime.utc(2100, 1, 1), 0),
        (DateTime.utc(2026), -721),
        (DateTime.utc(2026), 841),
      ]) {
        await expectLater(c.ponerReloj(fecha, zona), throwsA(isA<CanalError>()));
      }
      expect(t.relojesRecibidos, 0, reason: 'ni se manda');
      expect(t.utcPuesto, 0);
    });

    test('reloj: los extremos valen', () async {
      final (t, _, c) = await banco();
      await c.ponerReloj(DateTime.utc(2000), -720);
      expect(t.zonaPuesta, -720);
      await c.ponerReloj(DateTime.utc(2099, 12, 31, 23, 59), 840);
      expect(t.zonaPuesta, 840);
    });

    test('un reloj fuera de rango lo rechaza también el doble', () async {
      final (_, s, _) = await banco();
      final (cod, _, _) = await s.operacion(opSenReloj, const [],
          datosSalida: empaquetarReloj(DateTime.utc(2100), 0));
      expect(cod, rParamMal);
      final (cod2, _, _) = await s.operacion(opSenReloj, const [],
          datosSalida: Uint8List(7));
      expect(cod2, rParamMal);
    });

    test('vincular: si el almacén falla, se dice', () async {
      final (t, _, c) = await banco();
      t.falloAlmacen = true;
      await expectLater(c.vincular(imei), throwsA(isA<CanalError>()));
    });

    test('vincular: 14 o 15 dígitos y NUL, char[16]', () async {
      final (t, _, c) = await banco();
      t.idAparato = '';
      await c.vincular('350000000000091');
      expect(t.idAparato, '350000000000091');
      await c.vincular(imei);
      expect(t.idAparato, imei);
      expect(empaquetarVincular(imei), hasLength(16));
      expect(empaquetarVincular(imei)[14], 0);
      expect(() => c.vincular('123'), throwsArgumentError);
      expect(() => c.vincular('3551280269645a'), throwsArgumentError);
    });
  });

  group('SEN_ENTRAR_BL', () {
    test('contesta OCUPADO, y al «Sí» R_OK', () async {
      final (t, _, c) = await banco();
      expect(await c.entrarBl(pausa: Duration.zero), RespuestaEntrarBl.aceptada);
      expect(t.estado, EstadoTel.senew,
          reason: 'solo después de soltar el USB');
    });

    test('con cambios sin aplicar, espera a que acaben', () async {
      final (t, _, c) = await banco();
      t.ocupadoAjustes = 3;
      expect(await c.entrarBl(pausa: Duration.zero), RespuestaEntrarBl.aceptada);
    });

    test('R_OP_NO: no disponible, no es un error', () async {
      final (t, _, c) = await banco();
      t.sinBl = true;
      expect(
          await c.entrarBl(pausa: Duration.zero), RespuestaEntrarBl.noDisponible);
    });

    test('otro código sí es un error', () async {
      final (t, _, c) = await banco();
      t.fallarEntrarBl = true;
      expect(c.entrarBl(pausa: Duration.zero), throwsA(isA<CanalError>()));
    });

    test('«No»: R_DENEGADO, y queda como al principio', () async {
      final (t, _, c) = await banco();
      t.diceSiAlBl = false;
      expect(await c.entrarBl(pausa: Duration.zero), RespuestaEntrarBl.denegada);
      expect(t.estado, EstadoTel.senew);
    });

    test('sin respuesta: se acaba el plazo', () async {
      final (t, _, c) = await banco();
      t.sinRespuestaAlBl = true;
      expect(
          await c.entrarBl(
              pausa: Duration.zero, plazo: const Duration(milliseconds: 20)),
          RespuestaEntrarBl.sinRespuesta);
    });
  });

  group('SEN_BT_ESTADO', () {
    test('12 bytes', () async {
      final (_, _, c) = await banco();
      final e = await c.btEstado();
      expect(e.encendido, isTrue);
      expect(e.puenteConectado, isFalse);
    });

    test('corto: no se cree', () {
      expect(() => BtEstado.deBytes(Uint8List(11)),
          throwsA(isA<CanalMalFormado>()));
    });
  });

  group('SEN_APPS', () {
    SenApp app(int i) => SenApp(
          origen: 0,
          banderas: 1,
          perfil: 1,
          iconoGen: 4,
          iconoAn: 16,
          apiMayor: 1,
          apiMenor: 7,
          verApp: i,
          tam: 100 + i,
          iconoFilas: List.filled(12, i),
          nombre: 'App $i',
          fichero: 'app$i.sen',
        );

    test('una entrada son 128 bytes, en sus desplazamientos', () {
      final b = app(3).aBytes();
      expect(b, hasLength(128));
      final v = ByteData.sublistView(b);
      expect(b[0], 0);
      expect(b[1], 1);
      expect(v.getUint32(12, Endian.little), 3);
      expect(v.getUint32(16, Endian.little), 103);
      expect(v.getUint16(20, Endian.little), 3);
      expect(ascii.decode(b.sublist(44, 49)), 'App 3');
      expect(ascii.decode(b.sublist(74, 82)), 'app3.sen');
      final a = SenApp.deBytes(b, 0);
      expect(a.nombre, 'App 3');
      expect(a.fichero, 'app3.sen');
      expect(a.protegida, isTrue);
      expect(a.tapada, isFalse);
      expect(a.iconoFilas, List.filled(12, 3));
    });

    test('pagina: 16 apps en páginas de 7', () async {
      final (t, _, c) = await banco();
      t.appsFabrica.addAll([for (var i = 0; i < 16; i++) app(i)]);
      final l = await c.apps();
      expect(l, hasLength(16));
      expect(l.map((a) => a.verApp).toSet(), hasLength(16));
    });

    test('hasta 64: el total del firmware manda', () async {
      final (t, _, c) = await banco();
      t.appsFabrica.addAll([for (var i = 0; i < 80; i++) app(i)]);
      expect(await c.apps(), hasLength(64));
    });

    test('cero apps', () async {
      final (_, _, c) = await banco();
      expect(await c.apps(), isEmpty);
    });

    test('si la lista cambia a medio recorrido, vuelve a empezar', () async {
      final (t, _, c) = await banco();
      t.appsFabrica.addAll([for (var i = 0; i < 10; i++) app(i)]);
      t.alPaginar = (desde) {
        if (desde == 7 && t.appsFabrica.length == 10) {
          t.appsFabrica.add(app(10));
        }
      };
      expect(await c.apps(), hasLength(11));
    });

    test('tam_entrada distinta: no se cree', () {
      final b = Uint8List(8)..[0] = 1;
      expect(() => PaginaApps.deBytes(b), throwsA(isA<CanalMalFormado>()));
    });

    test('n que no cabe: no se cree', () {
      final b = Uint8List(8);
      final v = ByteData.sublistView(b);
      v.setUint16(0, 1, Endian.little);
      v.setUint16(2, 3, Endian.little);
      v.setUint16(4, 3, Endian.little);
      v.setUint16(6, 128, Endian.little);
      expect(() => PaginaApps.deBytes(b), throwsA(isA<CanalMalFormado>()));
    });
  });

  test('sin sesión contesta R_SIN_SESION y se dice', () async {
    final (t, _, c) = await banco();
    t.sesionAbierta = false;
    expect(c.info, throwsA(isA<CanalError>()));
  });
}
