// Los 12 pasos del §6.1 contra un W580 y un backend simulados, con cortes en
// cada operación del BL. Todo [simulado]: mide que SENUS cumple el contrato, no
// el silicio.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:senus_app/datos/actualizacion_senew.dart';
import 'package:senus_app/datos/backend_semakers.dart';
import 'package:senus_app/datos/cliente_puente.dart';
import 'package:senus_app/datos/conexion_telefono.dart';
import 'package:senus_app/datos/indice_semakers.dart';
import 'package:senus_app/datos/telefono.dart';
import 'package:senus_app/datos/transporte_bl.dart';
import 'package:senus_app/mtp/sesion_mtp.dart';

import 'apoyo/backend_simulado.dart';
import 'apoyo/telefono_simulado.dart';

const imei = '35000000000009';
const idSis28h = 'PUEN1 Oct 28 2026 15:07:26';

class Banco {
  final Directory dir = Directory.systemTemp.createTempSync('senus_act_');
  final TelefonoSimulado tel = TelefonoSimulado();
  final RedSimulada red = RedSimulada();
  late final Publicador pub = Publicador(red);
  late final PuertosSimulados puertos = PuertosSimulados(tel);
  late final AlmacenActualizacion almacen =
      AlmacenActualizacion(Directory(p.join(dir.path, 'act')));
  late final ClienteBackend backend = ClienteBackend(
    red: red,
    cache: Directory(p.join(dir.path, 'cache')),
    claves: [publica],
    ahora: () => DateTime.utc(2026, 11, 1),
  );
  final List<EventoAct> eventos = [];
  ResumenConfirmacion? resumen;
  bool aceptar = true;
  int confirmaciones = 0;
  bool bateriaOk = true;
  int preguntasBateria = 0;

  late final ImagenConocida vieja;
  late final ImagenConocida nueva;

  Banco({bool canal = true}) {
    vieja = canal
        ? ImagenConocida(mainDePrueba(290), 290, '0.29.0')
        : ImagenConocida(mainDePrueba(288), 288, '0.28.8',
            canal: false, puente: true, idPuente: idSis28h);
    nueva = tel.anadirImagen(ImagenConocida(mainDePrueba(291), 291, '0.29.1'));
    tel.instalarYArrancar(vieja);
    tel.idAparato = canal ? imei : '';
    pub.publicarSenew(291, '0.29.1', nueva.bytes);
  }

  ActualizadorSenew actualizador() =>
      ActualizadorSenew(
        puertos: puertos,
        backend: backend,
        almacen: almacen,
        confirmar: (r) async {
          confirmaciones++;
          resumen = r;
          return aceptar;
        },
        confirmarBateria: () async {
          preguntasBateria++;
          return bateriaOk;
        },
        alEvento: eventos.add,
        plazoBl: Duration.zero,
        plazoSenew: Duration.zero,
        sondeoBl: Duration.zero,
        pausaEntrarBl: Duration.zero,
        plazoEntrarBl: const Duration(milliseconds: 50),
        esperaTarjeta: Duration.zero,
      );

  ReleaseIndice release(int build) {
    pub.firmarIndice();
    final b = pub.cuerpoIndice();
    return verificarIndice(
            bytes: b,
            firma: firmar(b),
            claves: [publica],
            ahora: DateTime.utc(2026, 11, 1),
            secuenciaVista: 0)
        .senew
        .firstWhere((r) => r.build == build);
  }

  Future<ResultadoAct> correr({
    int build = 291,
    ReleaseIndice? destino,
  }) async {
    final s = await puertos.conectar();
    final t = (await leerTelefono(s)).valor!;
    return actualizador().actualizar(
        sesion: s, telefono: t, destino: destino ?? release(build));
  }

  List<PasoAct> get pasos =>
      [for (final e in eventos) if (e.paso != null) e.paso!];

  void limpiar() => dir.deleteSync(recursive: true);

  /// Nada se tocó: el sistema de antes sigue arrancado.
  void exigirIntacto() {
    expect(tel.wipes, isEmpty, reason: 'no debía borrar');
    expect(tel.escrituras, isEmpty, reason: 'no debía escribir');
    expect(tel.estado, EstadoTel.senew);
    expect(tel.corriendo, same(vieja));
  }
}

void main() {
  group('camino feliz', () {
    test('de 290 a 291 con canal: los 11 pasos, en orden', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      final r = await b.correr();
      expect(r.fin, FinAct.hecho, reason: r.mensaje);
      expect(b.tel.corriendo?.build, 291);
      expect(r.telefono?.gestion?.build, 291);
      expect(b.pasos, PasoAct.values);
      expect(b.tel.salidas, 1);
      expect(b.tel.arrancoMedioMain, isFalse);
      expect(await b.almacen.leerPendiente(), isNull);
      await r.sesion!.cerrar();
    });

    test('la región 0 se graba la ÚLTIMA y el resto en orden ascendente',
        () async {
      final b = Banco();
      addTearDown(b.limpiar);
      await b.correr();
      final w = b.tel.escrituras;
      expect(w.first, blMainIni + blRegion);
      expect(w.last, blMainIni);
      expect(w.where((d) => d == blMainIni).length, 1);
      final resto = w.sublist(0, w.length - 1);
      expect(resto, [...resto]..sort());
    });

    test('el main actual queda guardado antes de borrar', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      await b.correr();
      final f = File(p.join(
          b.dir.path, 'act', 'mains', 'main_${sha(b.vieja.bytes)}.bin'));
      expect(f.existsSync(), isTrue);
      expect(sha(f.readAsBytesSync()), sha(b.vieja.bytes));
    });

    test('elegir una versión anterior avisa de que va hacia atrás', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      final m = b.tel.anadirImagen(ImagenConocida(mainDePrueba(280), 280, '0.28.0'));
      b.pub.publicarSenew(280, '0.28.0', m.bytes);
      final r = await b.correr(build: 280);
      expect(b.resumen!.haciaAtras, isTrue);
      expect(r.fin, FinAct.hecho, reason: r.mensaje);
      expect(b.tel.corriendo?.build, 280);
    });

    test('reinstalar la misma versión también pasa por confirmar', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.pub.publicarSenew(290, '0.29.0', b.vieja.bytes);
      final r = await b.correr(build: 290);
      expect(b.resumen!.misma, isTrue);
      expect(r.fin, FinAct.hecho, reason: r.mensaje);
    });
  });

  group('antes de borrar, cualquier fallo deja senew intacto', () {
    test('cancelar en SENUS no toca nada y la sesión sigue viva', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.aceptar = false;
      final r = await b.correr();
      expect(r.fin, FinAct.cancelado);
      b.exigirIntacto();
      expect((await r.sesion!.info()).bien, isTrue);
    });

    test('decir «No» en el teléfono no toca nada', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.diceSiAlBl = false;
      final r = await b.correr();
      expect(r.fin, FinAct.denegado);
      b.exigirIntacto();
      expect((await r.sesion!.info()).bien, isTrue);
    });

    test('si nadie contesta en el teléfono, no se toca nada', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.sinRespuestaAlBl = true;
      final r = await b.correr();
      expect(r.fin, FinAct.fallo);
      b.exigirIntacto();
    });

    test('batería baja sin cargar: no se empieza', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.bateria = 29;
      final r = await b.correr();
      expect(r.fin, FinAct.fallo);
      expect(r.mensaje, contains('29 %'));
      b.exigirIntacto();
    });

    test('batería baja pero cargando: se sigue', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.bateria = 29;
      b.tel.cargando = true;
      expect((await b.correr()).fin, FinAct.hecho);
    });

    test('la batería que el teléfono no sabe (0xFF) se le pregunta a la persona',
        () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.bateria = 0xFF;
      expect((await b.correr()).fin, FinAct.hecho);
      expect(b.resumen!.bateria, isNull);
      expect(b.preguntasBateria, 1);
    });

    test('la batería sabida no se pregunta', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      expect((await b.correr()).fin, FinAct.hecho);
      expect(b.preguntasBateria, 0);
    });

    test('si dice que no tiene el 30 %, no se toca nada', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.bateria = 0xFF;
      b.bateriaOk = false;
      final r = await b.correr();
      expect(r.fin, FinAct.cancelado);
      expect(r.mensaje, contains('30 %'));
      b.exigirIntacto();
    });

    test('sin quien pregunte, tampoco se sigue', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.bateria = 0xFF;
      final s = await b.puertos.conectar();
      final t = (await leerTelefono(s)).valor!;
      final r = await ActualizadorSenew(
        puertos: b.puertos,
        backend: b.backend,
        almacen: b.almacen,
        confirmar: (_) async => true,
      ).actualizar(sesion: s, telefono: t, destino: b.release(291));
      expect(r.fin, FinAct.cancelado);
      b.exigirIntacto();
    });

    test('sin red a mitad de la descarga: no ha pasado nada', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.red.cortarRuta = '/v1/archivos/${sha(b.nueva.bytes)}';
      final r = await b.correr();
      expect(r.fin, FinAct.fallo);
      expect(b.confirmaciones, 0);
      b.exigirIntacto();
    });

    test('imagen de otro SoC: se niega antes de descargar', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      final m = mainDePrueba(292);
      b.pub.publicarSenew(292, '0.29.2', m, soc: 'DB2010');
      final r = await b.correr(build: 292);
      expect(r.fin, FinAct.fallo);
      expect(r.mensaje, contains('DB2010'));
      b.exigirIntacto();
    });

    test('build_min_origen mayor que el instalado: se niega', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      final m = mainDePrueba(292);
      b.pub.publicarSenew(292, '0.29.2', m, buildMinOrigen: 291);
      final r = await b.correr(build: 292);
      expect(r.fin, FinAct.fallo);
      b.exigirIntacto();
    });

    test('bl_version_min que el teléfono no llega a tener: se niega', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      final m = mainDePrueba(292);
      b.pub.publicarSenew(292, '0.29.2', m, blMin: 2);
      final r = await b.correr(build: 292);
      expect(r.fin, FinAct.fallo);
      b.exigirIntacto();
    });

    test('con bl_version 0, el BL lo dice en el paso 6 y se sale sin borrar',
        () async {
      final b = Banco();
      addTearDown(b.limpiar);
      final m = mainDePrueba(292);
      b.pub.publicarSenew(292, '0.29.2', m, blMin: 2);
      final dest = b.release(292);
      final s = await b.puertos.conectar();
      final t = (await leerTelefono(s)).valor!;
      // El teléfono no sabe su BL: `SEN_INFO` da 0. El simulador contesta 1 en
      // BL_R_ID, así que el rechazo solo puede venir del paso 6.
      final ti = t.gestion!;
      expect(ti.blVersion, 1);
      b.tel.blVersion = 0;
      final r = await b
          .actualizador()
          .actualizar(sesion: s, telefono: t, destino: dest);
      expect(r.fin, FinAct.fallo);
      expect(b.tel.wipes, isEmpty);
      expect(b.tel.salidas, 1, reason: 'SALIR si ya estaba en el BL');
      expect(b.tel.estado, EstadoTel.senew);
    });

    test('el BL dice una entrada que no es la 1: se sale sin borrar', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.entradaFalsa = 2;
      final r = await b.correr();
      expect(r.fin, FinAct.fallo);
      expect(r.mensaje, contains('entrada 2'));
      expect(b.tel.wipes, isEmpty);
      expect(b.tel.salidas, 1);
    });

    test('se pierde el USB al llegar al BL: no se borró, y lo dice', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.idFalla = true;
      final r = await b.correr();
      expect(r.fin, FinAct.fallo);
      expect(r.mensaje, contains('No se borró nada'));
      expect(b.tel.wipes, isEmpty);
      b.tel.reconectar();
      expect((await b.actualizador().salirDelBl()).fin, FinAct.hecho);
      expect(b.tel.corriendo, same(b.vieja));
    });

    test('sin disco para guardar lo necesario: se sale sin borrar', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      // La carpeta de la actualización es un fichero: no se puede escribir.
      File(p.join(b.dir.path, 'act')).writeAsStringSync('x');
      final r = await b.correr();
      expect(r.fin, FinAct.fallo);
      expect(r.mensaje, contains('No se borró nada'));
      expect(b.tel.wipes, isEmpty);
      expect(b.tel.salidas, 1);
      expect(b.tel.corriendo, same(b.vieja));
    });

    test('lo leído no cuadra con el CRC del BL: se sale sin borrar', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.lecturaMala = true;
      final r = await b.correr();
      expect(r.fin, FinAct.fallo);
      expect(b.tel.wipes, isEmpty);
      expect(await b.almacen.leerPendiente(), isNull);
    });

    test('corte leyendo el main: no se borró y el BL queda con el main intacto',
        () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.corteEn = 1; // el CRC del paso 7
      final r = await b.correr();
      expect(r.fin, FinAct.fallo);
      expect(b.tel.wipes, isEmpty);
      expect(await b.almacen.leerPendiente(), isNull);
      b.tel.reconectar();
      final s = await b.actualizador().salirDelBl();
      expect(s.fin, FinAct.hecho);
      expect(b.tel.corriendo, same(b.vieja));
    });
  });

  group('verificación de la imagen: nada llega al teléfono', () {
    Future<void> rechaza(
        Banco b, void Function() romper, MotivoRechazo motivo) async {
      final dest = b.release(291);
      romper();
      final r = await b.correr(destino: dest);
      expect(r.fin, FinAct.fallo, reason: r.mensaje);
      expect(b.confirmaciones, 0);
      b.exigirIntacto();
      try {
        await b.backend.descargarRelease(dest);
        fail('debía rechazarse');
      } on ErrorVerificacion catch (e) {
        expect(e.motivo, motivo);
      }
    }

    test('imagen con otro sha256', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      await rechaza(b, () {
        final malo = Uint8List.fromList(b.nueva.bytes)..[0x1000] ^= 1;
        b.red.poner('/v1/archivos/${sha(b.nueva.bytes)}', malo);
      }, MotivoRechazo.shaDistinto);
    });

    test('manifiesto firmado con otra clave', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      await rechaza(b, () {
        final otra = Uint8List.fromList(List.filled(32, 7));
        final m = b.red.rutas[
            '/v1/senew/releases/291/manifiesto.json?modelo=w580']!;
        b.red.poner('/v1/senew/releases/291/manifiesto.json.sig?modelo=w580',
            firmar(m, claveDeSemilla(otra)));
      }, MotivoRechazo.firmaMala);
    });

    test('manifiesto reformateado: los bytes no son los firmados', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      await rechaza(b, () {
        const ruta = '/v1/senew/releases/291/manifiesto.json?modelo=w580';
        final j = jsonDecode(utf8.decode(b.red.rutas[ruta]!));
        b.red.poner(ruta, Uint8List.fromList(utf8.encode(jsonEncode(j))));
      }, MotivoRechazo.shaDistinto);
    });

    test('imagen sin vectores, aunque esté firmada', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      final m = Uint8List.fromList(mainDePrueba(293))..[0] = 0;
      b.pub.publicarSenew(293, '0.29.3', m);
      final r = await b.correr(build: 293);
      expect(r.fin, FinAct.fallo);
      b.exigirIntacto();
    });

    test('vector de reset fuera de la imagen, aunque esté firmada', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      final m = mainDePrueba(293);
      ByteData.sublistView(m).setUint32(0x20, blMainIni + m.length, Endian.little);
      b.pub.publicarSenew(293, '0.29.3', m);
      final r = await b.correr(build: 293);
      expect(r.fin, FinAct.fallo);
      expect(r.mensaje, contains('vector de reset'));
      b.exigirIntacto();
    });

    test('imagen de más de 9 bloques, aunque esté firmada', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      final m = mainDePrueba(293, tam: blMainFin - blMainIni + blRegion);
      b.pub.publicarSenew(293, '0.29.3', m);
      final r = await b.correr(build: 293);
      expect(r.fin, FinAct.fallo);
      b.exigirIntacto();
    });

    test('crc32 del manifiesto que no es el de la imagen', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      final m = mainDePrueba(293);
      b.pub.publicarSenew(293, '0.29.3', m, crc: 'deadbeef');
      final r = await b.correr(build: 293);
      expect(r.fin, FinAct.fallo);
      expect(r.mensaje, contains('CRC-32'));
      b.exigirIntacto();
    });
  });

  group('sis28h: sin canal, por la tabla del §4.4', () {
    test('sin SEN_INFO no hay batería: se pregunta, y si no, no entra al BL',
        () async {
      final b = Banco(canal: false);
      addTearDown(b.limpiar);
      b.bateriaOk = false;
      final r = await b.correr();
      expect(r.fin, FinAct.cancelado);
      expect(b.preguntasBateria, 1);
      expect(b.tel.puenteOrdenes, isEmpty);
      expect(b.tel.wipes, isEmpty);
    });

    test('sube a un build con canal', () async {
      final b = Banco(canal: false);
      addTearDown(b.limpiar);
      final r = await b.correr();
      expect(r.fin, FinAct.hecho, reason: r.mensaje);
      expect(b.tel.corriendo?.build, 291);
      expect(b.tel.vetoCarga, isTrue);
      expect(b.tel.cargaFuera, isTrue);
      expect(b.resumen!.buildOrigen, 288);
      expect(b.tel.escrituras.last, blMainIni);
    });

    test('la secuencia del puente es la de pu.py bootloader', () async {
      final b = Banco(canal: false);
      addTearDown(b.limpiar);
      await b.correr();
      expect(b.tel.puenteOrdenes, [
        'poke 203c4cbc',
        'llamar 44213db0',
        'poke f3002f00',
        'llamar 44180524',
      ]);
    });

    test('con otro identificador se niega y no entra al BL', () async {
      final b = Banco(canal: false);
      addTearDown(b.limpiar);
      final otra = ImagenConocida(mainDePrueba(289), 289, '0.28.9',
          canal: false, puente: true, idPuente: 'PUEN1 Oct 29 2026 01:02:03');
      b.tel.instalarYArrancar(otra);
      final r = await b.correr();
      expect(r.fin, FinAct.fallo);
      expect(r.mensaje, contains('SENUS se niega'));
      expect(b.tel.puenteOrdenes, isEmpty);
      expect(b.tel.corriendo, same(otra));
    });

    test('sin puente ni canal se niega', () async {
      final b = Banco(canal: false);
      addTearDown(b.limpiar);
      final sin = ImagenConocida(mainDePrueba(289), 289, '0.28.9', canal: false);
      b.tel.instalarYArrancar(sin);
      final r = await b.correr();
      expect(r.fin, FinAct.fallo);
      expect(b.tel.corriendo, same(sin));
      expect(b.tel.wipes, isEmpty);
    });


    test('volver a sis28h desde un build con canal: se confirma por el puente',
        () async {
      final b = Banco();
      addTearDown(b.limpiar);
      final m = b.tel.anadirImagen(ImagenConocida(mainDePrueba(288), 288,
          '0.28.8',
          canal: false, puente: true, idPuente: idSis28h));
      b.pub.publicarSenew(288, '0.28.8', m.bytes);
      final r = await b.correr(build: 288);
      expect(r.fin, FinAct.hecho, reason: r.mensaje);
      expect(b.resumen!.haciaAtras, isTrue);
    });

    test('un build sin canal ni puente arranca, pero no se puede confirmar',
        () async {
      final b = Banco();
      addTearDown(b.limpiar);
      final m = b.tel
          .anadirImagen(ImagenConocida(mainDePrueba(287), 287, '0.28.7', canal: false));
      b.pub.publicarSenew(287, '0.28.7', m.bytes);
      final r = await b.correr(build: 287);
      expect(r.fin, FinAct.sinConfirmar);
    });

    test('la primera versión con canal también está en la tabla', () {
      final e = entradaPuente('PUEN1 Nov  1 2026 00:17:30')!;
      expect(e.build, 290);
      expect(e.version, '0.29.0');
      expect(e.cargaVeto, 0x203c6cbc);
      expect(e.hwCargaFuera, 0x44215dc8);
      expect(e.reinicioCaliente, 0x44180524);
    });

    test('la 0.29.1 también, con las direcciones de su binario', () {
      final e = entradaPuente('PUEN1 Nov  1 2026 09:40:17')!;
      expect(e.build, 291);
      expect(e.version, '0.29.1');
      expect(e.cargaVeto, 0x203c6ccc);
      expect(e.hwCargaFuera, 0x442163d0);
      expect(e.reinicioCaliente, 0x44180524);
    });

    test('sis28h sigue, y con cualquier otro id se niega', () {
      expect(entradaPuente(idSis28h), isNotNull);
      for (final otro in [
        'PUEN1 Nov  1 2026 00:17:31', // otra compilación, un segundo después
        'PUEN1 Nov 1 2026 00:17:30', // sin el espacio de __DATE__
        'PUEN1 Nov  1 2026 00:17:30 ',
        'puen1 nov  1 2026 00:17:30',
        '',
      ]) {
        expect(entradaPuente(otro), isNull, reason: otro);
      }
    });

    test('esa versión entra por SUS direcciones, no por las de sis28h',
        () async {
      final b = Banco();
      addTearDown(b.limpiar);
      final v = ImagenConocida(mainDePrueba(290), 290, '0.29.0',
          puente: true, idPuente: 'PUEN1 Nov  1 2026 00:17:30');
      b.tel.imagenes.remove(b.vieja);
      b.tel.instalarYArrancar(v);
      b.tel.fallarEntrarBl = true;
      final r = await b.correr();
      expect(r.fin, FinAct.hecho, reason: r.mensaje);
      expect(b.tel.puenteOrdenes, [
        'poke 203c6cbc',
        'llamar 44215dc8',
        'poke f3002f00',
        'llamar 44180524',
      ]);
    });

    test('antes de reiniciar se da tiempo a que acabe la tarjeta', () async {
      final t = TelefonoSimulado();
      t.instalarYArrancar(ImagenConocida(mainDePrueba(288), 288, '0.28.8',
          canal: false, puente: true, idPuente: idSis28h));
      final t0 = DateTime.now();
      await ClientePuente(TransporteEp0Simulado(t),
              esperaTarjeta: const Duration(milliseconds: 40))
          .entrarAlBl(entradaPuente(idSis28h)!);
      expect(t.banderaPuestaEn!.difference(t0).inMilliseconds,
          greaterThanOrEqualTo(40));
    });

    test('la espera por omisión son más de 1 s', () {
      expect(esperaTarjetaPuente.inMilliseconds, greaterThan(1000));
    });

    test('la tabla dice lo que dice el ELF de sis28h', () {
      final e = entradaPuente(idSis28h)!;
      expect(e.cargaVeto, 0x203c4cbc);
      expect(e.hwCargaFuera, 0x44213db0);
      expect(e.reinicioCaliente, 0x44180524);
      expect(entradaPuente('PUEN1 Oct 28 2026 15:07:27'), isNull);
    });
  });

  group('primera versión con canal y puente', () {
    test('si SEN_ENTRAR_BL falla, entra por el puente de la tabla', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      final v = ImagenConocida(mainDePrueba(290), 290, '0.29.0',
          puente: true, idPuente: idSis28h);
      b.tel.imagenes.remove(b.vieja);
      b.tel.instalarYArrancar(v);
      b.tel.fallarEntrarBl = true;
      final r = await b.correr();
      expect(r.fin, FinAct.hecho, reason: r.mensaje);
      expect(b.tel.puenteOrdenes, isNotEmpty);
    });

    test('si SEN_ENTRAR_BL falla y no hay puente, se queda con la sesión viva',
        () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.fallarEntrarBl = true;
      final r = await b.correr();
      expect(r.fin, FinAct.fallo);
      b.exigirIntacto();
      expect((await r.sesion!.info()).bien, isTrue);
    });

    test('R_OP_NO es un sistema sin BL: no disponible, y NO va por el puente',
        () async {
      final b = Banco();
      addTearDown(b.limpiar);
      final v = ImagenConocida(mainDePrueba(290), 290, '0.29.0',
          puente: true, idPuente: idSis28h);
      b.tel.imagenes.remove(b.vieja);
      b.tel.instalarYArrancar(v);
      b.tel.sinBl = true;
      final r = await b.correr();
      expect(r.fin, FinAct.noDisponible);
      expect(r.mensaje, contains('no está disponible'));
      expect(b.tel.puenteOrdenes, isEmpty);
      expect(b.tel.wipes, isEmpty);
      expect(b.tel.corriendo, same(v));
    });

    test('un W600 ni empieza: no disponible', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      final s = await b.puertos.conectar();
      const t = Telefono(
          modelo: Modelo.w600,
          nombreAmigo: 'W600 sistema propio',
          serie: '',
          versionSenew: '0.29.0',
          almacenes: [],
          canalGestion: true);
      final r = await b
          .actualizador()
          .actualizar(sesion: s, telefono: t, destino: b.release(291));
      expect(r.fin, FinAct.noDisponible);
      b.exigirIntacto();
    });

    test('con ajustes sin aplicar, SEN_ENTRAR_BL espera', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.ocupadoAjustes = 3;
      final r = await b.correr();
      expect(r.fin, FinAct.hecho, reason: r.mensaje);
    });

  });

  group('CRC mal: reintenta y luego repone (§6.3)', () {
    test('un fallo en el tramo: borra y graba otra vez', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.pasadasMalas = 1;
      final r = await b.correr();
      expect(r.fin, FinAct.hecho, reason: r.mensaje);
      expect(b.tel.corriendo?.build, 291);
      expect(b.pasos.where((x) => x == PasoAct.borrar).length, 2);
    });

    test('un fallo en la región 0: borra y graba otra vez', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.region0Mala = 1;
      final r = await b.correr();
      expect(r.fin, FinAct.hecho, reason: r.mensaje);
    });

    test('dos fallos: repone el main guardado', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.pasadasMalas = 2;
      final r = await b.correr();
      expect(r.fin, FinAct.repuesto, reason: r.mensaje);
      expect(b.tel.corriendo, same(b.vieja));
      expect(b.tel.escrituras.last, blMainIni);
      expect(await b.almacen.leerPendiente(), isNull);
    });

    test('tres fallos: se para, sin vectores, y la recuperación lo arregla',
        () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.pasadasMalas = 3;
      final r = await b.correr();
      expect(r.fin, FinAct.corte, reason: r.mensaje);
      expect(b.tel.arrancoMedioMain, isFalse);
      final s = await b.actualizador().recuperar();
      expect(s.fin, FinAct.hecho, reason: s.mensaje);
      expect(b.tel.corriendo?.build, 291);
    });
  });

  group('arranque y build', () {
    void noAsusta(ResultadoAct r) {
      expect(r.fin, FinAct.sinVuelta);
      expect(r.mensaje, contains('La grabación fue correcta'));
      expect(r.mensaje, contains('basta con encenderlo'));
      expect(r.remedio, contains('no hace falta grabar de nuevo'));
      final todo = '${r.mensaje} ${r.remedio}'.toLowerCase();
      for (final no in ['no tiene vuelta', 'far', 'jdflasher', 'dañ', 'rescate']) {
        expect(todo, isNot(contains(no)), reason: no);
      }
    }

    test('no vuelve tras SALIR: la grabación fue correcta, basta encenderlo',
        () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.cuelgaAlArrancar = true;
      noAsusta(await b.correr());
      expect(b.tel.salidas, 1, reason: 'no se graba otra vez por esto');
      expect(b.pasos.where((x) => x == PasoAct.borrar), hasLength(1));
    });

    test('el riesgo del §7 no se esconde: queda en el registro', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.cuelgaAlArrancar = true;
      await b.correr();
      expect(b.eventos.any((e) => e.linea?.contains('Far') ?? false), isTrue);
    });

    test('se apaga al arrancar (un OK en «Encendido»): al encender, listo',
        () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.seApagaAlArrancar = true;
      noAsusta(await b.correr());
      expect(b.tel.estado, EstadoTel.apagado);
      expect(await b.almacen.leerPendiente(), isNotNull);

      b.tel.reconectar();
      expect(b.tel.corriendo?.build, 291, reason: 'lo grabado era bueno');
      final s = await b.puertos.conectar();
      final t = (await leerTelefono(s)).valor!;
      await b.almacen.olvidarSiYaArranco(t.gestion!.build);
      expect(await b.almacen.leerPendiente(), isNull);
    });

    test('olvidarSiYaArranco no olvida si es otro build', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.seApagaAlArrancar = true;
      await b.correr();
      await b.almacen.olvidarSiYaArranco(290);
      expect(await b.almacen.leerPendiente(), isNotNull);
    });

    test('la conexión se pierde al comprobar: tampoco asusta', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.puertos.alConectar = () => b.tel.cortarAlLeerDeviceInfo = true;
      noAsusta(await b.correr());
    });

    test('tras reponer el sistema tampoco asusta', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.pasadasMalas = 2;
      b.tel.cuelgaAlArrancar = true;
      final r = await b.correr();
      expect(r.fin, FinAct.sinVuelta);
      expect(r.mensaje, contains('quedó repuesto'));
      expect(r.mensaje, contains('basta con encenderlo'));
    });

    test('el aviso de «Encendido» sale ANTES de cada espera a senew', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      var esperas = 0, conAviso = 0;
      b.puertos.alEsperarSenew = () async {
        esperas++;
        if (b.eventos.isNotEmpty && b.eventos.last.aviso == avisoEncendido) {
          conAviso++;
        }
      };
      await b.correr();
      expect(esperas, 1);
      expect(conAviso, 1);
    });

    test('el aviso dice lo medido: Atrás, no OK, y el foco del permiso', () {
      expect(avisoEncendido, contains('«Encendido»'));
      expect(avisoEncendido, contains('Atrás'));
      expect(avisoEncendido, contains('no pulses OK'));
      expect(avisoEncendido, contains('apagaría'));
      expect(avisoEncendido, contains('«Conectado por USB»'));
      expect(avisoEncendido, contains('sube a «Sí»'));
    });

    test('arranca otro build: lo informa y no reintenta', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.imagenes.remove(b.nueva);
      b.tel.anadirImagen(ImagenConocida(b.nueva.bytes, 999, '9.9.9'));
      final r = await b.correr();
      expect(r.fin, FinAct.buildDistinto);
      expect(r.mensaje, contains('999'));
      expect(b.tel.salidas, 1, reason: 'no reintenta');
    });
  });

  group('recuperación', () {
    test('sin nada guardado: no graba a ciegas', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.nor.fillRange(0, tamNor, 0xFF);
      b.tel.arrancar();
      expect(b.tel.estado, EstadoTel.bl);
      final r = await b.actualizador().recuperar();
      expect(r.fin, FinAct.fallo);
      expect(b.tel.escrituras, isEmpty);
    });

    test('1209:0003: el BL installer sin main también se recupera', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.blInstaller = true;
      b.tel.corteEn = 5;
      b.tel.corteDePila = true;
      final r = await b.correr();
      expect(r.fin, FinAct.corte);
      expect(b.tel.pidBl, pidBlInstaller);
      final s = await b.actualizador().recuperar();
      expect(s.fin, FinAct.hecho, reason: s.mensaje);
    });

    test('lo guardado tocado en el disco no se graba', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.corteEn = 5;
      b.tel.corteDePila = true;
      await b.correr();
      final f = File(p.join(b.dir.path, 'act', 'pendiente', 'main.bin'));
      final d = f.readAsBytesSync()..[0x200] ^= 1;
      f.writeAsBytesSync(d);
      final w = b.tel.escrituras.length;
      final r = await b.actualizador().recuperar();
      expect(r.fin, FinAct.fallo);
      expect(r.mensaje, contains('no pasa la verificación'));
      expect(b.tel.escrituras.length, w);
    });

    group('recuperarCon verifica antes de tocar el teléfono', () {
      Future<(Banco, ReleaseDescargada)> preparar() async {
        final b = Banco();
        addTearDown(b.limpiar);
        b.tel.nor.fillRange(0, tamNor, 0xFF);
        b.tel.arrancar();
        return (b, await b.backend.descargarRelease(b.release(291)));
      }

      Future<ResultadoAct> grabar(Banco b, ReleaseDescargada d,
              {Uint8List? imagen, int build = 291, String version = '0.29.1'}) =>
          b.actualizador().recuperarCon(
              imagen: imagen ?? d.main,
              build: build,
              version: version,
              manifiesto: d.manifiesto);

      test('una imagen que no es la del manifiesto', () async {
        final (b, d) = await preparar();
        final otra = Uint8List.fromList(d.main)..[0x1000] ^= 1;
        final r = await grabar(b, d, imagen: otra);
        expect(r.fin, FinAct.fallo);
        expect(r.mensaje, contains('sha256'));
        expect(b.tel.escrituras, isEmpty);
        expect(await b.almacen.leerPendiente(), isNull);
      });

      test('un manifiesto sin firma válida', () async {
        final (b, d) = await preparar();
        final mala = ManifiestoVerificado(
            d.manifiesto.bytes, Uint8List(64), d.manifiesto.json);
        final r = await b.actualizador().recuperarCon(
            imagen: d.main,
            build: 291,
            version: '0.29.1',
            manifiesto: mala);
        expect(r.fin, FinAct.fallo);
        expect(b.tel.escrituras, isEmpty);
      });

      test('un build que no es el del manifiesto', () async {
        final (b, d) = await preparar();
        final r = await grabar(b, d, build: 292);
        expect(r.fin, FinAct.fallo);
        expect(b.tel.escrituras, isEmpty);
      });

      test('una imagen de otro tamaño', () async {
        final (b, d) = await preparar();
        final r = await grabar(b, d,
            imagen: Uint8List.fromList([...d.main, ...List.filled(0x400, 0)]));
        expect(r.fin, FinAct.fallo);
        expect(r.mensaje, contains('mide'));
        expect(b.tel.escrituras, isEmpty);
      });

      test('un bootloader más viejo que bl_version_min', () async {
        final b = Banco();
        addTearDown(b.limpiar);
        final m = mainDePrueba(293);
        b.tel.anadirImagen(ImagenConocida(m, 293, '0.29.3'));
        b.pub.publicarSenew(293, '0.29.3', m, blMin: 2);
        b.tel.nor.fillRange(0, tamNor, 0xFF);
        b.tel.arrancar();
        final d = await b.backend.descargarRelease(b.release(293));
        final r = await grabar(b, d, build: 293, version: '0.29.3');
        expect(r.fin, FinAct.fallo);
        expect(r.mensaje, contains('bootloader 2'));
        expect(b.tel.escrituras, isEmpty);
        expect(await b.almacen.leerPendiente(), isNull);
      });

      test('verificada, graba', () async {
        final (b, d) = await preparar();
        final r = await grabar(b, d);
        expect(r.fin, FinAct.hecho, reason: r.mensaje);
      });
    });

    test('corte después de grabar: no repite, solo sale', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      // El último CRC es la operación 9: corte de cable tras hacerlo.
      b.tel.corteEn = 9;
      b.tel.corteTrasEjecutar = true;
      final r = await b.correr();
      expect(r.fin, FinAct.corte);
      expect(b.tel.mainEntero, isTrue);
      b.tel.reconectar();
      final w = b.tel.escrituras.length;
      final s = await b.actualizador().recuperar();
      expect(s.fin, FinAct.hecho, reason: s.mensaje);
      expect(b.tel.escrituras.length, w, reason: 'no había nada que grabar');
    });
  });

  group('un PUT sin estado (bl_usb.c)', () {
    test('se repite una vez y la grabación acaba bien', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel
        ..putAtascado = 30
        ..vecesAtascado = 1;
      final r = await b.correr();
      expect(r.fin, FinAct.hecho, reason: r.mensaje);
      expect(b.tel.corriendo?.build, 291);
      expect(b.pasos.where((x) => x == PasoAct.borrar), hasLength(1),
          reason: 'no hace falta volver a borrar');
    });

    test('dos veces seguidas: corte normal, sin reintentos infinitos', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel
        ..putAtascado = 30
        ..vecesAtascado = 2;
      final r = await b.correr();
      expect(r.fin, FinAct.corte, reason: r.mensaje);
      expect(b.tel.vecesAtascado, 0);
      expect(b.tel.arrancoMedioMain, isFalse);
      final s = await b.actualizador().recuperar();
      expect(s.fin, FinAct.hecho, reason: s.mensaje);
    });

    test('tres veces: al tercero ni se llega', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel
        ..putAtascado = 30
        ..vecesAtascado = 3;
      final r = await b.correr();
      expect(r.fin, FinAct.corte);
      expect(b.tel.vecesAtascado, 1, reason: 'solo dos intentos');
    });

    test('el plazo es de 2 a 3 s, no los 30 de siempre', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      await b.correr();
      expect(b.tel.plazoPut!.inMilliseconds, inInclusiveRange(2000, 3000));
    });

    test('también en la región 0, repitiendo el mismo PUT', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      // 15 regiones del resto = 240 PUT; la región 0 son los 16 siguientes.
      b.tel
        ..putAtascado = 245
        ..vecesAtascado = 1;
      final r = await b.correr();
      expect(r.fin, FinAct.hecho, reason: r.mensaje);
      expect(b.tel.mainEntero, isTrue);
    });
  });

  group('actualizar no depende de ningún respaldo', () {
    test('son 11 pasos', () {
      expect(PasoAct.values, hasLength(11));
      expect(PasoAct.values.map((p) => p.name), isNot(contains('respaldo')));
    });

    test('el teléfono de otra persona, sin ningún respaldo en este computador',
        () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.idAparato = '99000000000001';
      final r = await b.correr();
      expect(r.fin, FinAct.hecho, reason: r.mensaje);
      expect(b.tel.corriendo?.build, 291);
      expect(b.tel.idAparato, '99000000000001', reason: 'ni lo mira ni lo cambia');
      expect(Directory(p.join(b.dir.path, 'respaldos')).existsSync(), isFalse);
    });

    test('sin id vinculado, igual, y no vincula nada', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.idAparato = '';
      expect((await b.correr()).fin, FinAct.hecho);
      expect(b.tel.idAparato, '');
    });

    test('un sis28h de otra persona: tampoco pide nada', () async {
      final b = Banco(canal: false);
      addTearDown(b.limpiar);
      final r = await b.correr();
      expect(r.fin, FinAct.hecho, reason: r.mensaje);
      expect(b.tel.corriendo?.build, 291);
      expect(b.tel.idAparato, '');
    });

    test('recuperar tras un corte tampoco lo mira', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.idAparato = '';
      b.tel
        ..corteEn = 5
        ..corteDePila = true;
      expect((await b.correr()).fin, FinAct.corte);
      final r = await b.actualizador().recuperar();
      expect(r.fin, FinAct.hecho, reason: r.mensaje);
      expect(b.tel.corriendo?.build, 291);
    });

    test('elegir otra imagen en el BL, sin respaldo ni id', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.nor.fillRange(0, tamNor, 0xFF);
      b.tel.arrancar();
      final d = await b.backend.descargarRelease(b.release(291));
      final r = await b.actualizador().recuperarCon(
          imagen: d.main,
          build: 291,
          version: '0.29.1',
          manifiesto: d.manifiesto);
      expect(r.fin, FinAct.hecho, reason: r.mensaje);
      expect(b.tel.corriendo?.build, 291);
    });

    test('un pendiente antiguo, con su campo imei, se reanuda', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel
        ..corteEn = 5
        ..corteDePila = true;
      await b.correr();
      final f = File(p.join(b.dir.path, 'act', 'pendiente', 'estado.json'));
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      expect(j, isNot(contains('imei')));
      j['imei'] = '35000000000009';
      f.writeAsStringSync(jsonEncode(j));
      expect(await b.almacen.leerPendiente(), isNotNull);
      final r = await b.actualizador().recuperar();
      expect(r.fin, FinAct.hecho, reason: r.mensaje);
    });

    test('sin firma válida no llega a WIPE, y ni entra al BL', () async {
      for (final canal in [true, false]) {
        final b = Banco(canal: canal);
        final dest = b.release(291);
        final m = b.red.rutas[
            '/v1/senew/releases/291/manifiesto.json?modelo=w580']!;
        b.red.poner('/v1/senew/releases/291/manifiesto.json.sig?modelo=w580',
            firmar(m, claveDeSemilla(Uint8List.fromList(List.filled(32, 9)))));
        final r = await b.correr(destino: dest);
        expect(r.fin, FinAct.fallo, reason: r.mensaje);
        expect(b.tel.wipes, isEmpty);
        expect(b.tel.escrituras, isEmpty);
        expect(b.tel.salidas, 0);
        expect(b.tel.puenteOrdenes, isEmpty);
        expect(b.confirmaciones, 0);
        expect(b.tel.corriendo, same(b.vieja));
        b.limpiar();
      }
    });
  });

  group('cortes en CADA operación del BL', () {
    // 16 KiB: CRC, WIPE, 4 WRITE, CRC, WRITE r0, CRC, SALIR.
    const operaciones = 10;

    for (final pila in [false, true]) {
      for (final tras in [false, true]) {
        for (var n = 1; n <= operaciones; n++) {
          final nombre = '${pila ? 'sin pila' : 'sin cable'}, '
              '${tras ? 'tras' : 'antes de'} la operación $n';
          test(nombre, () async {
            final b = Banco();
            addTearDown(b.limpiar);
            b.tel
              ..corteEn = n
              ..corteDePila = pila
              ..corteTrasEjecutar = tras;
            final r = await b.correr();

            // El invariante: JAMÁS vectores válidos sobre un main a medias.
            expect(b.tel.arrancoMedioMain, isFalse, reason: r.mensaje);
            if (b.tel.estado == EstadoTel.bl || !b.tel.cable) {
              expect(b.tel.mainEntero || !_conVectores(b.tel), isTrue,
                  reason: 'vectores sobre un main a medias');
            }

            b.tel.reconectar();
            if (b.tel.estado == EstadoTel.bl) {
              final q = await b.almacen.leerPendiente();
              final s = q != null
                  ? await b.actualizador().recuperar()
                  : await b.actualizador().salirDelBl();
              expect(s.fin, FinAct.hecho, reason: s.mensaje);
            }
            expect(b.tel.arrancoMedioMain, isFalse);
            expect(b.tel.estado, EstadoTel.senew);
            expect(b.tel.corriendo?.build, anyOf(290, 291));
            final q = await b.almacen.leerPendiente();
            if (q == null) {
              // Lo que se dio por hecho, está hecho.
              if (r.fin == FinAct.hecho) {
                expect(b.tel.corriendo?.build, 291);
              }
            }
          });
        }
      }
    }

    test('corte a medio WIPE, en cada bloque', () async {
      for (var bloque = 0; bloque < 9; bloque++) {
        final b = Banco();
        b.tel
          ..corteEn = 2 // el WIPE
          ..corteEnBloque = bloque
          ..corteTrasEjecutar = true
          ..corteDePila = true;
        final r = await b.correr();
        expect(r.fin, FinAct.corte, reason: r.mensaje);
        expect(b.tel.arrancoMedioMain, isFalse, reason: 'bloque $bloque');
        expect(b.tel.estado, EstadoTel.bl, reason: 'bloque $bloque');
        final s = await b.actualizador().recuperar();
        expect(s.fin, FinAct.hecho, reason: s.mensaje);
        expect(b.tel.corriendo?.build, 291);
        b.limpiar();
      }
    });

    test('dos cortes seguidos: la recuperación también se puede cortar',
        () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel
        ..corteEn = 4
        ..corteDePila = true;
      expect((await b.correr()).fin, FinAct.corte);
      // CRC de comprobación (1) + WIPE (2) + WRITE (3): se corta en el tercero.
      b.tel
        ..operacionesBl = 0
        ..corteEn = 3
        ..corteDePila = true;
      final r = await b.actualizador().recuperar();
      expect(r.fin, FinAct.corte, reason: r.mensaje);
      expect(b.tel.arrancoMedioMain, isFalse);
      expect(b.tel.estado, EstadoTel.bl);
      final s = await b.actualizador().recuperar();
      expect(s.fin, FinAct.hecho, reason: s.mensaje);
    });

    test('el corte deja lo necesario para reanudar ANTES de borrar', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.corteEn = 2; // antes del WIPE
      final r = await b.correr();
      expect(r.fin, FinAct.corte);
      expect(b.tel.wipes, isEmpty);
      final q = await b.almacen.leerPendiente();
      expect(q, isNotNull);
      expect(q!.buildDestino, 291);
      expect(await b.almacen.imagenPendiente(q, [publica]), b.nueva.bytes);
    });

    test('un TransporteError al pedir el RES del WIPE cuenta como corte',
        () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.corteEn = 2;
      b.tel.corteTrasEjecutar = true;
      final r = await b.correr();
      expect(r.fin, FinAct.corte);
      expect(b.tel.estado, EstadoTel.bl);
      expect(b.tel.cable, isFalse);
    });
  });

  group('Telefono', () {
    test('sin canal, se conecta y dice que no lo tiene', () async {
      final b = Banco(canal: false);
      addTearDown(b.limpiar);
      final s = await b.puertos.conectar();
      final t = (await leerTelefono(s)).valor!;
      expect(t.canalGestion, isFalse);
      expect(t.gestion, isNull);
      expect(t.imei, isNull);
      expect(t.versionTexto, 'S10');
    });

    test('con canal, sabe versión, build e IMEI', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      final s = await b.puertos.conectar();
      final SesionMtp ses = s;
      final t = (await leerTelefono(ses)).valor!;
      expect(t.canalGestion, isTrue);
      expect(t.imei, imei);
      expect(t.versionTexto, '0.29.0 (build 290)');
      expect(t.modelo, Modelo.w580);
      expect(t.memoria, isNotNull);
    });
  });
}

bool _conVectores(TelefonoSimulado t) {
  final v = ByteData.sublistView(t.nor);
  return v.getUint32(0, Endian.little) == 0xE59FF018;
}
