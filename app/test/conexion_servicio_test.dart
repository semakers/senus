// El servicio de Conexión con la plataforma Bluetooth falsa y el teléfono simulado:
// quién entra, encender, olvidar y emparejar por el cable. [simulado]: dice que
// SENUS hace lo que debe contra el contrato, no que IOBluetooth o senew lo hagan.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:senus_app/conexion/permitidos.dart';
import 'package:senus_app/conexion/puente_nativo.dart';
import 'package:senus_app/conexion/servicio_conexion.dart';
import 'package:senus_app/conexion/w5red_protocolo.dart';
import 'package:senus_app/mtp/canal_gestion.dart';
import 'package:senus_app/mtp/operaciones.dart';
import 'package:senus_app/mtp/sesion_mtp.dart';

import 'apoyo/puente_falso.dart';
import 'apoyo/telefono_simulado.dart';

const miDir = '02:11:22:33:44:55';
const dirTel = '01:02:03:04:05:06';
const otra = 'AA:AA:AA:AA:AA:AA';

class Banco {
  final PuenteNativoFalso n = PuenteNativoFalso();
  final Directory dir = Directory.systemTemp.createTempSync('senus_g_');
  final List<String> log = [];
  late final ServicioConexion s = ServicioConexion(
    nativo: n,
    ficheroPermitidos: () async => fichero,
    log: log.add,
    plazoEmparejar: const Duration(milliseconds: 600),
    pausaSondeo: const Duration(milliseconds: 5),
    graciaFallo: const Duration(milliseconds: 40),
  );

  File get fichero => File('${dir.path}/permitidos');

  Future<void> encendido([List<String> lista = const []]) async {
    if (lista.isNotEmpty) {
      fichero.writeAsStringSync('${lista.join('\n')}\n');
    }
    await s.encender();
  }
}

Future<void> pausa([int ms = 20]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

/// Un W580 con canal por USB.
Future<(TelefonoSimulado, SesionMtp, CanalGestion)> telefono() async {
  final t = TelefonoSimulado();
  t.instalarYArrancar(ImagenConocida(mainDePrueba(291), 291, '0.29.1'));
  final m = await PuertosSimulados(t).conectar();
  return (t, m, CanalGestion(m, pausaOcupado: Duration.zero));
}

BtEstado estado({bool lista = false, int fallo = 0}) => BtEstado(
      encendido: true,
      puenteConectado: lista,
      redLista: lista,
      fallo: fallo,
      puenteAddr: Uint8List(6),
    );

void main() {
  group('direcciones', () {
    test('se normalizan como las escribe cada sistema', () {
      expect(normalizarDireccion('02-11-22-33-44-55'), miDir);
      expect(normalizarDireccion(' 02:11:22:33:44:55 '), miDir);
      expect(normalizarDireccion('?'), isNull);
      expect(normalizarDireccion('02:11:22:33:44'), isNull);
      expect(direccionDeBytes([0x02, 0x11, 0x22, 0x33, 0x44, 0x55]), miDir);
      expect(bytesDeDireccion(miDir), [0x02, 0x11, 0x22, 0x33, 0x44, 0x55]);
    });

    test('la lista sobrevive en su fichero y admite comentarios', () async {
      final d = Directory.systemTemp.createTempSync('senus_g_');
      final f = File('${d.path}/sub/permitidos');
      final l = await ListaPermitidos.cargar(f);
      await l.anadir('aa-bb-cc-dd-ee-ff');
      expect(l.contiene('AA:BB:CC:DD:EE:FF'), isTrue);
      expect(f.readAsStringSync(), contains('AA:BB:CC:DD:EE:FF\n'));
      f.writeAsStringSync('# nota\n${f.readAsStringSync()}basura\n');
      final l2 = await ListaPermitidos.cargar(f);
      expect(l2.todas, ['AA:BB:CC:DD:EE:FF']);
      await l2.quitar('AA:BB:CC:DD:EE:FF');
      expect((await ListaPermitidos.cargar(f)).todas, isEmpty);
    });
  });

  group('sin Bluetooth', () {
    test('en Windows y Linux, «no disponible» con su motivo, sin romper', () async {
      final d = Directory.systemTemp.createTempSync('senus_g_');
      final s = ServicioConexion(
        nativo: const PuenteNoDisponible(),
        ficheroPermitidos: () async => File('${d.path}/p'),
      );
      await s.iniciar();
      expect(s.bt!.disponible, isFalse);
      expect(s.bt!.motivo, contains('macOS'));
      await s.encender();
      expect(s.encendido, isFalse);
      expect(s.error, contains('macOS'));
    });

    test('una máquina sin radio: no disponible', () {
      const e = EstadoBt(
          plataforma: true,
          hay: false,
          permiso: PermisoBt.concedido,
          encendido: false);
      expect(e.disponible, isFalse);
    });
  });

  group('el servidor', () {
    test('encender publica una vez; apagar corta y avisa al teléfono', () async {
      final b = Banco();
      await b.encendido([dirTel]);
      await b.s.encender();
      expect(b.n.llamadas.where((l) => l == 'encender').length, 1);
      expect(b.s.encendido, isTrue);
      expect(b.s.canalRfcomm, 7);
      final c = b.n.llama(dirTel);
      await c.saludar();
      await b.s.apagar();
      expect((await c.espera(0, tAdios)).carga[0], cBien);
      expect(b.n.llamadas, contains('apagar'));
      expect(b.s.encendido, isFalse);
      expect(b.s.telefonos, isEmpty);
    });

    test('sin permiso o apagado: lo dice y no queda a medias', () async {
      final b = Banco();
      b.n.falloEncender = const FalloNativo('sin_permiso', 'x');
      await b.s.encender();
      expect(b.s.error, contains('Privacidad'));
      expect(b.s.estado, EstadoServidor.apagado);
      b.n.falloEncender = const FalloNativo('apagado', 'x');
      await b.s.encender();
      expect(b.s.error, contains('apagado'));
      b.n.falloEncender = null;
      await b.s.encender();
      expect(b.s.encendido, isTrue);
      expect(b.s.error, isNull);
    });

    test('cerrar la app lo apaga todo y no deja nada', () async {
      final b = Banco();
      await b.encendido([dirTel]);
      final c = b.n.llama(dirTel);
      await c.saludar();
      await b.s.cerrar();
      expect(b.n.servidor, isFalse);
      expect(c.cortado, isTrue);
    });

    test('no toca el Bluetooth hasta que se abre el apartado', () {
      final b = Banco();
      expect(b.s, isNotNull);
      expect(b.n.llamadas, isEmpty);
    });
  });

  group('quién entra', () {
    test('emparejado y en la lista: sesión W5RED', () async {
      final b = Banco();
      await b.encendido([dirTel]);
      final c = b.n.llama('01-02-03-04-05-06');
      await c.saludar();
      expect(b.s.telefonos.single.direccion, dirTel);
      expect(b.s.telefonos.single.saludado, isTrue);
      expect(b.s.telefonos.single.nombre, 'prueba');
    });

    test('fuera de la lista: cortado sin decirle nada', () async {
      final b = Banco();
      await b.encendido([dirTel]);
      final c = b.n.llama(otra);
      c.manda(tHola, 0, c.hola());
      await pausa();
      expect(c.cortado, isTrue);
      expect(c.vistas, isEmpty);
      expect(b.s.telefonos, isEmpty);
      expect(b.log.join(), contains('NO está en la lista'));
    });

    test('en la lista y sin emparejar: cortado', () async {
      final b = Banco();
      await b.encendido([dirTel]);
      final c = b.n.llama(dirTel, emparejado: false);
      await pausa();
      expect(c.cortado, isTrue);
      expect(b.s.telefonos, isEmpty);
    });

    test('al irse el teléfono se acaba su sesión', () async {
      final b = Banco();
      await b.encendido([dirTel]);
      final c = b.n.llama(dirTel);
      await c.saludar();
      await b.n.cortar(b.n.idDe(c));
      await pausa();
      expect(b.s.telefonos, isEmpty);
    });

    test('olvidar: fuera de la lista, de su fichero y de la sesión', () async {
      final b = Banco();
      await b.encendido([dirTel]);
      final c = b.n.llama(dirTel);
      await c.saludar();
      expect(await b.s.olvidar(dirTel), isTrue);
      await pausa();
      expect(c.cortado, isTrue);
      expect(b.s.permitidos, isEmpty);
      expect(b.fichero.readAsStringSync(), isNot(contains(dirTel)));
      expect(b.n.llamadas, contains('olvidar'));
      final d = b.n.llama(dirTel);
      await pausa();
      expect(d.cortado, isTrue);
    });

    test('la velocidad sale de lo que se mueve', () async {
      final b = Banco();
      await b.encendido([dirTel]);
      final c = b.n.llama(dirTel);
      await c.saludar();
      for (var i = 0; i < 40; i++) {
        c.manda(tPing, 0, Uint8List(64));
      }
      await Future<void>.delayed(const Duration(milliseconds: 1150));
      expect(b.s.velSube, greaterThan(0));
      expect(b.s.velBaja, greaterThan(0));
      await b.s.apagar();
      expect(b.s.velBaja, 0);
    });
  });

  group('emparejar por el cable', () {
    /// El teléfono: al recibir la orden llama y saluda, como F lo hará.
    void llamaAlOrdenar(TelefonoSimulado t, Banco b, {void Function()? antes}) {
      t.alEmparejar = (addr, pin) {
        antes?.call();
        scheduleMicrotask(() async {
          b.n.emitir(const BtEmparejamiento(dirTel, 'enlace', 0));
          b.n.emitir(const BtEmparejamiento(dirTel, 'pin', 0));
          b.n.emitir(const BtEmparejamiento(dirTel, 'hecho', 0));
          final c = b.n.llama(dirTel);
          await c.saludar();
          t.btEstado = estado(lista: true);
        });
      };
    }

    test('la orden lleva lo del contrato y el teléfono queda en la lista', () async {
      final b = Banco();
      await b.encendido();
      final (t, _, canal) = await telefono();
      llamaAlOrdenar(t, b);
      await b.s.emparejar(canal);
      expect(b.s.listoEmparejar, isTrue);
      expect(b.s.errorEmparejar, isNull);
      expect(b.s.permitidos, [dirTel]);
      expect(b.s.telefonos.single.saludado, isTrue);

      final d = t.emparejarRecibido!;
      expect(d.length, 24);
      expect(d.sublist(0, 6), [0x02, 0x11, 0x22, 0x33, 0x44, 0x55]);
      final pin = ascii.decode(d.sublist(7, 7 + d[6]));
      expect(RegExp(r'^\d{6}$').hasMatch(pin), isTrue);
      expect(d.sublist(7 + d[6]).every((x) => x == 0), isTrue);
      expect(b.n.armada, dirTel);
      expect(b.n.pinArmado, pin, reason: 'el mismo PIN a los dos lados');
    });

    test('se arma ANTES de la orden y se desarma al acabar', () async {
      final b = Banco();
      await b.encendido();
      final (t, _, canal) = await telefono();
      var armadoAlOrdenar = false;
      llamaAlOrdenar(t, b, antes: () => armadoAlOrdenar = b.n.armada == dirTel);
      await b.s.emparejar(canal);
      expect(armadoAlOrdenar, isTrue);
      expect(b.n.llamadas.last, 'desarmar');
      expect(b.s.emparejando, isFalse);
    });

    test('el canal que abre mientras se empareja espera y luego sirve', () async {
      final b = Banco();
      await b.encendido();
      final (t, _, canal) = await telefono();
      t.alEmparejar = (addr, pin) {
        scheduleMicrotask(() async {
          final c = b.n.llama(dirTel, emparejado: false);
          c.manda(tHola, 0, c.hola());
          await pausa();
          expect(b.s.telefonos.single.sesion, isNull);
          b.n.emitir(const BtEmparejamiento(dirTel, 'hecho', 0));
          await c.espera(0, tHolaOk);
          t.btEstado = estado(lista: true);
        });
      };
      await b.s.emparejar(canal);
      expect(b.s.listoEmparejar, isTrue);
    });

    test('un senew que aún no sabe su dirección la da con la radio encendida',
        () async {
      final b = Banco();
      await b.encendido();
      final (t, _, canal) = await telefono();
      t.bdAddr = const [0, 0, 0, 0, 0, 0];
      llamaAlOrdenar(t, b, antes: () => t.bdAddr = const [1, 2, 3, 4, 5, 6]);
      await b.s.emparejar(canal);
      expect(b.s.listoEmparejar, isTrue);
      expect(b.n.armada, dirTel);
    });

    test('quien llama mientras no se sabe la dirección espera; otro no entra',
        () async {
      final b = Banco();
      await b.encendido();
      final (t, _, canal) = await telefono();
      t.bdAddr = const [0, 0, 0, 0, 0, 0];
      late ClienteW5 intruso;
      t.alEmparejar = (addr, pin) {
        scheduleMicrotask(() async {
          intruso = b.n.llama(otra);
          final c = b.n.llama(dirTel);
          c.manda(tHola, 0, c.hola());
          await pausa();
          expect(c.cortado, isFalse, reason: 'aún no se sabe quién es');
          t.bdAddr = const [1, 2, 3, 4, 5, 6];
          await c.espera(0, tHolaOk);
          t.btEstado = estado(lista: true);
        });
      };
      await b.s.emparejar(canal);
      expect(b.s.listoEmparejar, isTrue);
      expect(intruso.cortado, isTrue);
      expect(b.s.telefonos.single.direccion, dirTel);
      expect(b.s.permitidos, [dirTel]);
    });

    test('lo que quedó sin emparejar se corta al acabar', () async {
      final b = Banco();
      await b.encendido();
      final (t, _, canal) = await telefono();
      late ClienteW5 c;
      t.alEmparejar = (addr, pin) {
        c = b.n.llama(dirTel, emparejado: false);
        t.btEstado = estado(fallo: 4);
      };
      await expectLater(b.s.emparejar(canal), throwsA(isA<FalloEmparejar>()));
      expect(c.cortado, isTrue);
      expect(b.s.telefonos, isEmpty);
    });

    test('el fallo de antes de la orden no cuenta; el de después, sí', () async {
      final b = Banco();
      await b.encendido();
      final (t, _, canal) = await telefono();
      t.btEstado = estado(fallo: 4); // el de un intento anterior
      t.alEmparejar = (addr, pin) {
        scheduleMicrotask(() async {
          await pausa(25);
          t.btEstado = estado();
          await pausa(25);
          final c = b.n.llama(dirTel);
          await c.saludar();
          t.btEstado = estado(lista: true);
        });
      };
      await b.s.emparejar(canal);
      expect(b.s.listoEmparejar, isTrue);
    });

    test('«red lista» sin HOLA aquí no es «puente listo»', () async {
      final b = Banco();
      await b.encendido();
      final (t, _, canal) = await telefono();
      t.alEmparejar = (addr, pin) => t.btEstado = estado(lista: true);
      await expectLater(b.s.emparejar(canal), throwsA(isA<FalloEmparejar>()));
      expect(b.s.listoEmparejar, isFalse);
      expect(b.s.errorEmparejar, contains('no por este computador'));
      expect(b.s.permitidos, isEmpty);
    });

    test('si el teléfono falla: su motivo, fuera de la lista y desarmado', () async {
      final b = Banco();
      await b.encendido();
      final (t, _, canal) = await telefono();
      t.alEmparejar = (addr, pin) => t.btEstado = estado(fallo: 4);
      await expectLater(b.s.emparejar(canal), throwsA(isA<FalloEmparejar>()));
      expect(b.s.errorEmparejar, contains('PIN'));
      expect(b.s.permitidos, isEmpty);
      expect(b.n.llamadas.last, 'desarmar');
      expect(b.fichero.existsSync() ? b.fichero.readAsStringSync() : '',
          isNot(contains(dirTel)));
    });

    test('un fallo no borra a un teléfono que ya estaba en la lista', () async {
      final b = Banco();
      await b.encendido([dirTel]);
      final (t, _, canal) = await telefono();
      t.alEmparejar = (addr, pin) => t.btEstado = estado(fallo: 7);
      await expectLater(b.s.emparejar(canal), throwsA(isA<FalloEmparejar>()));
      expect(b.s.errorEmparejar, contains('robot'));
      expect(b.s.permitidos, [dirTel]);
    });

    test('con una app abierta reintenta, y si no se cierra lo dice', () async {
      final b = Banco();
      await b.encendido();
      final (t, _, canal) = await telefono();
      t.ocupadoEmparejar = 2;
      llamaAlOrdenar(t, b);
      await b.s.emparejar(canal);
      expect(b.s.listoEmparejar, isTrue);

      final b2 = Banco();
      await b2.encendido();
      final (t2, m2, _) = await telefono();
      t2.ocupadoEmparejar = 1 << 30;
      final corto = CanalGestion(m2,
          pausaOcupado: Duration.zero,
          plazoOcupado: const Duration(milliseconds: 5));
      await expectLater(b2.s.emparejar(corto), throwsA(isA<FalloEmparejar>()));
      expect(b2.s.errorEmparejar, contains('Cierra la app'));
    });

    test('un senew sin la orden pide actualizar', () async {
      final b = Banco();
      await b.encendido();
      final (t, _, canal) = await telefono();
      t.sinEmparejar = true;
      await expectLater(b.s.emparejar(canal), throwsA(isA<FalloEmparejar>()));
      expect(b.s.errorEmparejar, contains('0.29.1'));
      expect(b.s.permitidos, isEmpty);
    });

    test('con el servidor apagado no se manda nada', () async {
      final b = Banco();
      final (t, _, canal) = await telefono();
      await expectLater(b.s.emparejar(canal), throwsA(isA<FalloEmparejar>()));
      expect(t.emparejarRecibido, isNull);
    });

    test('si se quita el cable a media espera, lo dice', () async {
      final b = Banco();
      await b.encendido();
      final (t, _, canal) = await telefono();
      t.alEmparejar = (addr, pin) => t.cable = false;
      await expectLater(b.s.emparejar(canal), throwsA(isA<FalloEmparejar>()));
      expect(b.s.errorEmparejar, contains('cable'));
      expect(b.s.emparejando, isFalse);
    });

    test('al quitar el cable el puente sigue: no depende de la sesión MTP', () async {
      final b = Banco();
      await b.encendido();
      final (t, m, canal) = await telefono();
      late ClienteW5 c;
      t.alEmparejar = (addr, pin) {
        scheduleMicrotask(() async {
          b.n.emitir(const BtEmparejamiento(dirTel, 'hecho', 0));
          c = b.n.llama(dirTel);
          await c.saludar();
          t.btEstado = estado(lista: true);
        });
      };
      await b.s.emparejar(canal);
      t.cable = false;
      await m.cerrar().catchError((Object _) {});
      c.manda(tPing, 0, [9]);
      expect((await c.espera(0, tPong)).carga, [9]);
      expect(b.s.telefonos.single.saludado, isTrue);
    });
  });

  group('SENUS llama', () {
    test('al encender vigila a los permitidos, en el canal del teléfono', () async {
      final b = Banco();
      await b.encendido([otra, dirTel]);
      expect(canalTelefono, 7);
      expect(b.n.vigiladas, [dirTel, otra]);
      expect(b.n.canalVigilado, canalTelefono);
      expect(b.n.llamadas.indexOf('vigilar'),
          greaterThan(b.n.llamadas.indexOf('encender')));
    });

    test('el permitido que espera recibe la llamada y la sesión es la de siempre',
        () async {
      final b = Banco();
      await b.encendido([dirTel]);
      final c = await b.n
          .esperaLlamada(dirTel)
          .timeout(const Duration(seconds: 2));
      final ok = await c.saludar();
      expect(ok.tipo, tHolaOk);
      expect(b.s.telefonos.single.direccion, dirTel);
      expect(b.s.telefonos.single.saludado, isTrue);
    });

    test('a quien no está en la lista no se le llama', () async {
      final b = Banco();
      await b.encendido([dirTel]);
      unawaited(b.n.esperaLlamada(otra));
      await pausa();
      expect(b.n.llamado(otra), isFalse);
      expect(b.s.telefonos, isEmpty);
    });

    test('olvidar lo saca de lo vigilado; sin cambios no se repite', () async {
      final b = Banco();
      await b.encendido([dirTel, otra]);
      await b.s.encender();
      await b.s.olvidar('02:02:02:02:02:02'); // no estaba: nada cambia
      expect(b.n.vigilancias, hasLength(1));
      await b.s.olvidar(dirTel);
      expect(b.n.vigiladas, [otra]);
      expect(b.n.vigilancias, hasLength(2));
      unawaited(b.n.esperaLlamada(dirTel));
      await pausa();
      expect(b.n.llamado(dirTel), isFalse);
    });

    test('apagado no vigila; al volver a encender se manda otra vez', () async {
      final b = Banco();
      await b.encendido([dirTel, otra]);
      await b.s.apagar();
      expect(b.n.vigiladas, isEmpty);
      await b.s.encender();
      expect(b.n.vigilancias, hasLength(2),
          reason: 'la misma lista, pero `apagar` la vació al otro lado');
      expect(b.n.vigiladas, [dirTel, otra]);
      await b.s.apagar();
      await b.s.olvidar(otra);
      expect(b.n.vigilancias, hasLength(2), reason: 'con el servidor apagado');
      await b.s.encender();
      expect(b.n.vigiladas, [dirTel]);
    });

    test('si vigilar falla, el servidor sigue y se manda a la siguiente ocasión',
        () async {
      final b = Banco();
      b.n.falloVigilar = const FalloNativo('canal', 'canal malo');
      await b.encendido([dirTel, otra]);
      expect(b.s.encendido, isTrue);
      expect(b.log.join('\n'), contains('vigilar: canal malo'));
      b.n.falloVigilar = null;
      await b.s.olvidar('02:02:02:02:02:02'); // no estaba: la lista no cambia
      expect(b.n.vigiladas, [dirTel, otra], reason: 'lo que falló no cuenta como mandado');
    });

    test('emparejar: se arma y luego se vigila al teléfono del cable; si falla, se deja',
        () async {
      final b = Banco();
      await b.encendido();
      final (t, _, canal) = await telefono();
      List<String>? alOrdenar;
      t.alEmparejar = (addr, pin) {
        alOrdenar = b.n.vigiladas;
        t.btEstado = estado(fallo: 4);
      };
      await expectLater(b.s.emparejar(canal), throwsA(isA<FalloEmparejar>()));
      expect(alOrdenar, [dirTel]);
      final l = b.n.llamadas;
      final primera = b.n.vigilancias.indexWhere((v) => v.contains(dirTel));
      expect(b.n.armadoAlVigilar[primera], dirTel,
          reason: 'armado antes de llamarlo: si no, el Swift se lo salta '
              'por no estar emparejado');
      expect(b.n.vigiladas, isEmpty, reason: 'ya no se le llama');
      expect(l.lastIndexOf('vigilar'), lessThan(l.lastIndexOf('desarmar')));
    });

    test('emparejar de punta a punta: el teléfono espera, SENUS llama y empareja',
        () async {
      final b = Banco();
      await b.encendido();
      final (t, _, canal) = await telefono();
      var cortadoTrasReintento = true;
      t.alEmparejar = (addr, pin) {
        unawaited(b.n.esperaLlamada(dirTel, emparejado: false).then((c) async {
          c.manda(tHola, 0, c.hola());
          // Un intento de emparejar que no salió no es el final.
          b.n.emitir(const BtEmparejamiento(dirTel, 'reintento', -536870186));
          await pausa();
          cortadoTrasReintento = c.cortado;
          b.n.emitir(const BtEmparejamiento(dirTel, 'hecho', 0));
          await c.espera(0, tHolaOk);
          t.btEstado = estado(lista: true);
        }));
      };
      await b.s.emparejar(canal);
      expect(cortadoTrasReintento, isFalse);
      expect(b.s.listoEmparejar, isTrue);
      expect(b.s.telefonos.single.saludado, isTrue);
      expect(b.n.vigiladas, [dirTel], reason: 'se le sigue llamando');
      expect(b.log.join('\n'), contains('otro intento'));
    });

    test('un «fallo» sí corta el canal que esperaba; un «reintento», no', () async {
      final b = Banco();
      await b.encendido();
      final (t, _, canal) = await telefono();
      final cortes = <String, bool>{};
      t.alEmparejar = (addr, pin) {
        scheduleMicrotask(() async {
          final c = b.n.llama(dirTel, emparejado: false);
          b.n.emitir(const BtEmparejamiento(dirTel, 'reintento', 1));
          await pausa();
          cortes['reintento'] = c.cortado;
          b.n.emitir(const BtEmparejamiento(dirTel, 'fallo', 1));
          await pausa();
          cortes['fallo'] = c.cortado;
          t.btEstado = estado(fallo: 4);
        });
      };
      await expectLater(b.s.emparejar(canal), throwsA(isA<FalloEmparejar>()));
      expect(cortes, {'reintento': false, 'fallo': true});
    });
  });

  group('SEN_BT_EMPAREJAR, byte a byte', () {
    test('24 bytes con el contrato', () {
      final d = empaquetarEmparejar([1, 2, 3, 4, 5, 6], '1234');
      expect(d.length, 24);
      expect(d.sublist(0, 6), [1, 2, 3, 4, 5, 6]);
      expect(d[6], 4);
      expect(d.sublist(7, 11), ascii.encode('1234'));
      expect(d.sublist(11).every((x) => x == 0), isTrue);
    });

    test('lo que el firmware rechazaría ni se arma', () {
      expect(() => empaquetarEmparejar([1, 2], '1234'), throwsArgumentError);
      expect(() => empaquetarEmparejar(List.filled(6, 0), ''), throwsArgumentError);
      expect(() => empaquetarEmparejar(List.filled(6, 0), '1' * 17),
          throwsArgumentError);
      expect(() => empaquetarEmparejar(List.filled(6, 0), 'ñ'), throwsArgumentError);
      expect(empaquetarEmparejar(List.filled(6, 0), '1' * 16).length, 24);
    });

    test('SEN_BT_ESTADO se lee y se escribe igual', () {
      final e = BtEstado(
          encendido: true,
          puenteConectado: false,
          redLista: true,
          fallo: 4,
          puenteAddr: Uint8List.fromList([1, 2, 3, 4, 5, 6]));
      final d = BtEstado.deBytes(e.aBytes());
      expect(d.encendido, isTrue);
      expect(d.puenteConectado, isFalse);
      expect(d.redLista, isTrue);
      expect(d.fallo, 4);
      expect(d.puenteAddr, [1, 2, 3, 4, 5, 6]);
    });

    test('los códigos de fallo son los de red_sis.c', () {
      expect(textoFalloRed(4), contains('PIN'));
      expect(textoFalloRed(7), contains('robot'));
      expect(textoFalloRed(99), contains('99'));
    });

    test('0x9407 sale en las órdenes del teléfono simulado', () async {
      final (t, _, _) = await telefono();
      expect(t.deviceInfo(), isNotEmpty);
      expect(opSenBtEmparejar, 0x9407);
    });
  });
}
