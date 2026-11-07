// Apps: todas las origins, instalar con relectura y quitar solo lo que se puede.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:senus_app/datos/app_sen.dart';
import 'package:senus_app/datos/apps_telefono.dart';
import 'package:senus_app/datos/backend_semakers.dart';
import 'package:senus_app/datos/conexion_telefono.dart';
import 'package:senus_app/datos/indice_semakers.dart';
import 'package:senus_app/datos/telefono.dart';
import 'package:senus_app/mtp/canal_datos.dart';
import 'package:senus_app/mtp/operaciones.dart';
import 'package:senus_app/mtp/sesion_mtp.dart';

import 'apoyo/backend_simulado.dart';
import 'apoyo/telefono_simulado.dart';

SenApp fabrica(String fichero, String nombre, {int ver = 1}) => SenApp(
      origen: 0,
      banderas: 1,
      perfil: 1,
      iconoGen: 4,
      iconoAn: 16,
      apiMayor: 1,
      apiMenor: 7,
      verApp: ver,
      tam: 2048,
      iconoFilas: List.filled(12, 0x0FF0),
      nombre: nombre,
      fichero: fichero,
    );

class Banco {
  final TelefonoSimulado tel = TelefonoSimulado();
  final Directory dir = Directory.systemTemp.createTempSync('senus_apps_');
  final RedSimulada red = RedSimulada();
  late final Publicador pub = Publicador(red);
  late final ClienteBackend backend = ClienteBackend(
    red: red,
    cache: dir,
    claves: [publica],
    ahora: () => DateTime.utc(2026, 11, 1),
  );
  late SesionMtp sesion;
  late Telefono telefono;
  late ServicioApps apps;

  Banco({bool canal = true, bool tarjeta = false}) {
    tel.hayTarjeta = tarjeta;
    if (tarjeta) {
      tel.crearCarpeta(storageTarjeta, 'apps');
      tel.crearCarpeta(storageTarjeta, 'juegos');
    }
    tel.instalarYArrancar(
        ImagenConocida(mainDePrueba(290), 290, '0.29.0', canal: canal));
  }

  Future<void> conectar() async {
    sesion = await PuertosSimulados(tel).conectar();
    telefono = (await leerTelefono(sesion)).valor!;
    apps = ServicioApps(sesion, telefono);
  }

  void enMemoria(String n, Uint8List d) => tel.crearFichero(
      storageMemoria, tel.carpeta(storageMemoria, 'apps')!.handle, n, d);
  void enTarjeta(String c, String n, Uint8List d) => tel.crearFichero(
      storageTarjeta, tel.carpeta(storageTarjeta, c)!.handle, n, d);

  Future<AppIndice> publicar(String id, Uint8List sen) async {
    pub.publicarApp(id, sen);
    pub.firmarIndice();
    return (await backend.indice()).indice.app(id)!;
  }

  void limpiar() => dir.deleteSync(recursive: true);
}

void main() {
  group('listar', () {
    test('con canal: los cuatro orígenes, con versión e icono', () async {
      final b = Banco(tarjeta: true);
      addTearDown(b.limpiar);
      b.tel.appsFabrica.add(fabrica('musica.sen', 'Música', ver: 2));
      b.enMemoria('calc.sen', senDePrueba(verApp: 5, nombre: 'Calculadora'));
      b.enTarjeta('apps', 'mapa.sen', senDePrueba(nombre: 'Mapa'));
      b.enTarjeta('juegos', 'juego.sen', senDePrueba(nombre: 'Juego', perfil: 2));
      await b.conectar();
      final l = await b.apps.listar();
      expect(l.map((a) => a.origen).toSet(), {
        OrigenApp.fabrica,
        OrigenApp.memoria,
        OrigenApp.tarjetaApps,
        OrigenApp.tarjetaJuegos
      });
      final m = l.firstWhere((a) => a.nombre == 'musica.sen');
      expect(m.deFabrica, isTrue, reason: 'deFabrica ya no queda sin poner');
      expect(m.titulo, 'Música');
      expect(m.verApp, 2);
      expect(m.iconoAn, 16);
      expect(m.iconoFilas, hasLength(12));
      expect(m.handle, 0);
      final c = l.firstWhere((a) => a.nombre == 'calc.sen');
      expect(c.verApp, 5);
      expect(c.handle, isNot(0));
    });

    test('sin canal: lo que MTP alcanza, con la cabecera por GetPartialObject',
        () async {
      final b = Banco(canal: false, tarjeta: true);
      addTearDown(b.limpiar);
      b.tel.appsFabrica.add(fabrica('musica.sen', 'Música'));
      b.enMemoria('calc.sen', senDePrueba(verApp: 5, nombre: 'Calculadora'));
      b.enTarjeta('juegos', 'juego.sen', senDePrueba(nombre: 'Juego'));
      b.enMemoria('notas.txt', Uint8List(4));
      await b.conectar();
      final l = await b.apps.listar();
      expect(l.map((a) => a.nombre).toSet(), {'calc.sen', 'juego.sen'});
      expect(l.firstWhere((a) => a.nombre == 'calc.sen').verApp, 5);
    });

    test('con canal: una .sen con la cabecera mala sale y se puede quitar',
        () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.enMemoria('buena.sen', senDePrueba(nombre: 'Buena'));
      b.enMemoria('rota.sen', Uint8List(200));
      await b.conectar();
      final l = await b.apps.listar();
      expect(l, hasLength(2));
      final r = l.firstWhere((a) => a.nombre == 'rota.sen');
      expect(r.verApp, isNull);
      expect(r.sePuedeQuitar, isTrue);
      await b.apps.quitar(r);
      expect(await b.apps.listar(), hasLength(1));
    });

    test('con canal: lo que pasa de las 64 entradas también sale', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      for (var i = 0; i < 70; i++) {
        b.enMemoria('app$i.sen', senDePrueba(nombre: 'App $i'));
      }
      await b.conectar();
      expect(await b.apps.listar(), hasLength(70));
    });

    test('una cabecera ilegible sale igual, sin versión', () async {
      final b = Banco(canal: false);
      addTearDown(b.limpiar);
      b.enMemoria('raro.sen', Uint8List(10));
      await b.conectar();
      final a = (await b.apps.listar()).single;
      expect(a.verApp, isNull);
      expect(a.tituloVisible, 'raro.sen');
    });
  });

  group('instalar', () {
    test('sube, relee y compara', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      await b.conectar();
      final sen = senDePrueba(verApp: 3);
      final a = await b.publicar('calc', sen);
      await b.apps.instalar(b.backend, a);
      final o = b.tel.objetos.values.firstWhere((x) => x.nombre == 'calc.sen');
      expect(o.datos, sen);
      expect(copiaQueManda(await b.apps.listar(), 'calc')?.verApp, 3);
    });

    test('relectura distinta: error, y la copia mala se borra', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      await b.conectar();
      final a = await b.publicar('calc', senDePrueba());
      b.tel.corromperAlGuardar = true;
      await expectLater(b.apps.instalar(b.backend, a),
          throwsA(isA<ErrorInstalarApp>().having(
              (e) => e.motivo, 'motivo', contains('no es lo que se subió'))));
      expect(b.tel.objetos.values.where((x) => x.nombre == 'calc.sen'), isEmpty);
    });

    test('actualizar pisa la versión anterior', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.enMemoria('calc.sen', senDePrueba(verApp: 1));
      await b.conectar();
      final a = await b.publicar('calc', senDePrueba(verApp: 2));
      final antes = copiaQueManda(await b.apps.listar(), 'calc');
      expect(estadoFrente(a, antes), EstadoCatalogo.hayActualizacion);
      await b.apps.instalar(b.backend, a);
      final l = await b.apps.listar();
      expect(l.where((x) => x.id == 'calc'), hasLength(1));
      expect(estadoFrente(a, copiaQueManda(l, 'calc')), EstadoCatalogo.alDia);
    });

    test('lo que no pasa la verificación no toca el teléfono', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      await b.conectar();
      final sen = senDePrueba();
      final a = await b.publicar('calc', sen);
      b.red.poner('/v1/archivos/${a.sha256}', senDePrueba(verApp: 9));
      await expectLater(
          b.apps.instalar(b.backend, a), throwsA(isA<ErrorVerificacion>()));
      expect(b.tel.objetos.values.where((x) => !x.carpeta), isEmpty);
    });

    test('sin red y sin caché: no toca el teléfono', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      await b.conectar();
      final a = await b.publicar('calc', senDePrueba());
      b.red.caido = true;
      await expectLater(b.apps.instalar(b.backend, a), throwsA(isA<SinRed>()));
      expect(b.tel.objetos.values.where((x) => !x.carpeta), isEmpty);
    });

    test('si no cabe, ni se intenta', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      await b.conectar();
      final a = await b.publicar('calc', senDePrueba());
      final t = b.telefono.copiarCon(almacenes: const [
        Almacen(
            id: storageMemoria,
            etiqueta: 'Memoria',
            bytesTotales: 1024,
            bytesLibres: 10,
            soloLectura: false)
      ]);
      await expectLater(ServicioApps(b.sesion, t).instalar(b.backend, a),
          throwsA(isA<ErrorInstalarApp>()));
      expect(b.tel.objetos.values.where((x) => !x.carpeta), isEmpty);
    });

    test('sin carpeta /apps se dice, no cae en la raíz', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.objetos.clear();
      await b.conectar();
      final r = await b.sesion.subirApp('x.sen', senDePrueba());
      expect(r.bien, isFalse);
      expect(r.mensaje, contains('/apps'));
    });

    test('un .sen de fábrica tapado por el nuevo: manda la de la Memoria',
        () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.appsFabrica.add(fabrica('calc.sen', 'Calc', ver: 1));
      await b.conectar();
      final a = await b.publicar('calc', senDePrueba(verApp: 2));
      await b.apps.instalar(b.backend, a);
      final l = await b.apps.listar();
      expect(l.where((x) => x.id == 'calc'), hasLength(2));
      expect(l.firstWhere((x) => x.deFabrica).tapada, isTrue);
      final m = copiaQueManda(l, 'calc')!;
      expect(m.origen, OrigenApp.memoria);
      expect(m.verApp, 2);
    });
  });

  group('quitar', () {
    test('lo que se puede quitar, se quita', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.enMemoria('calc.sen', senDePrueba());
      await b.conectar();
      final a = (await b.apps.listar()).single;
      expect(a.sePuedeQuitar, isTrue);
      await b.apps.quitar(a);
      expect(await b.apps.listar(), isEmpty);
    });

    test('la de fábrica no llega a pedirse', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.appsFabrica.add(fabrica('musica.sen', 'Música'));
      await b.conectar();
      final a = (await b.apps.listar()).single;
      expect(a.sePuedeQuitar, isFalse);
      await expectLater(b.apps.quitar(a), throwsA(isA<ErrorInstalarApp>()));
      expect(await b.apps.listar(), hasLength(1));
    });

    test('la carpeta /apps contesta R_PROTEGIDO y se dice bien', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      await b.conectar();
      final r = await b.sesion
          .borrarApp(b.tel.carpeta(storageMemoria, 'apps')!.handle);
      expect(r.bien, isFalse);
      expect(r.codigoResp, rProtegido);
      expect(b.tel.carpeta(storageMemoria, 'apps'), isNotNull);
    });

    test('la protegida tampoco', () {
      const a = AppSen(handle: 5, nombre: 'x.sen', bytes: 1, protegida: true);
      expect(a.sePuedeQuitar, isFalse);
    });

    test('quitar la copia de la Memoria devuelve la de fábrica', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.appsFabrica.add(fabrica('calc.sen', 'Calc'));
      b.enMemoria('calc.sen', senDePrueba(verApp: 2));
      await b.conectar();
      final l = await b.apps.listar();
      await b.apps.quitar(l.firstWhere((x) => x.origen == OrigenApp.memoria));
      final d = await b.apps.listar();
      expect(d.single.deFabrica, isTrue);
      expect(d.single.tapada, isFalse);
    });

    test('también se quita de la tarjeta', () async {
      final b = Banco(tarjeta: true);
      addTearDown(b.limpiar);
      b.enTarjeta('apps', 'mapa.sen', senDePrueba());
      await b.conectar();
      await b.apps.quitar((await b.apps.listar()).single);
      expect(await b.apps.listar(), isEmpty);
    });
  });

  group('la copia de la tarjeta manda sobre la de la Memoria', () {
    Future<(Banco, AppIndice)> caso({
      required int tarjeta,
      int? memoria,
      required int tienda,
      bool canal = true,
    }) async {
      final b = Banco(tarjeta: true, canal: canal);
      addTearDown(b.limpiar);
      b.enTarjeta('apps', 'teclas.sen', senDePrueba(verApp: tarjeta, nombre: 'Teclas'));
      if (memoria != null) {
        b.enMemoria('teclas.sen', senDePrueba(verApp: memoria, nombre: 'Teclas'));
      }
      await b.conectar();
      final c = await b.publicar('teclas', senDePrueba(verApp: tienda, nombre: 'Teclas'));
      return (b, c);
    }

    test('el caso de C: el doble lista lo mismo que el firmware', () async {
      final (b, _) = await caso(tarjeta: 1, memoria: 2, tienda: 2);
      final l = await b.apps.listar();
      expect(l.map((x) => (x.origen, x.verApp, x.tapada)).toList(), [
        (OrigenApp.tarjetaApps, 1, false),
        (OrigenApp.memoria, 2, true),
      ]);
    });

    test('en Memoria la nueva, manda la vieja: tapada, no «hay actualización»',
        () async {
      final (b, c) = await caso(tarjeta: 1, memoria: 2, tienda: 2);
      final s = situacionCatalogo(c, await b.apps.listar());
      expect(s.estado, EstadoCatalogo.tapada);
      expect(s.hayQueSubir, isFalse);
      expect(s.rival?.origen, OrigenApp.tarjetaApps);
      expect(s.explicacion,
          'Instalada en Memoria, pero manda la copia de la tarjeta (v1)');
      expect(s.accion, 'Quitar la copia de la tarjeta');
    });

    test('quitar la copia de la tarjeta lo resuelve de verdad', () async {
      final (b, c) = await caso(tarjeta: 1, memoria: 2, tienda: 2);
      final s = situacionCatalogo(c, await b.apps.listar());
      await b.apps.resolverTapada(b.backend, c, s);
      final l = await b.apps.listar();
      expect(l.single.origen, OrigenApp.memoria);
      expect(l.single.tapada, isFalse);
      expect(situacionCatalogo(c, l).estado, EstadoCatalogo.alDia);
    });

    test('sin copia en la Memoria: subir solo no cambiaría nada', () async {
      final (b, c) = await caso(tarjeta: 1, tienda: 2);
      final s = situacionCatalogo(c, await b.apps.listar());
      expect(s.estado, EstadoCatalogo.tapada);
      expect(s.hayQueSubir, isTrue);
      expect(s.accion, 'Instalar y quitar la de la tarjeta');
      // Lo que se quiere evitar: instalar sin más deja la vieja mandando.
      await b.apps.instalar(b.backend, c);
      final d = situacionCatalogo(c, await b.apps.listar());
      expect(d.estado, EstadoCatalogo.tapada);
      expect(d.hayQueSubir, isFalse);
    });

    test('instalar y quitar: la app nunca desaparece y queda la nueva', () async {
      final (b, c) = await caso(tarjeta: 1, tienda: 2);
      final s = situacionCatalogo(c, await b.apps.listar());
      await b.apps.resolverTapada(b.backend, c, s);
      final l = await b.apps.listar();
      expect(l.single.origen, OrigenApp.memoria);
      expect(l.single.verApp, 2);
    });

    test('si la subida falla, lo de la tarjeta no se toca', () async {
      final (b, c) = await caso(tarjeta: 1, tienda: 2);
      final s = situacionCatalogo(c, await b.apps.listar());
      b.tel.corromperAlGuardar = true;
      await expectLater(b.apps.resolverTapada(b.backend, c, s),
          throwsA(isA<ErrorInstalarApp>()));
      final l = await b.apps.listar();
      expect(l.single.origen, OrigenApp.tarjetaApps);
    });

    test('si tras quitar sigue sin mandar, lo dice', () async {
      final (b, c) = await caso(tarjeta: 1, memoria: 2, tienda: 2);
      final s = situacionCatalogo(c, await b.apps.listar());
      b.tel.borradoSinEfecto = true;
      await expectLater(
          b.apps.resolverTapada(b.backend, c, s),
          throwsA(isA<ErrorInstalarApp>().having(
              (e) => e.motivo, 'motivo', contains('sigue sin ser la que manda'))));
    });

    test('si no se puede quitar, no se ofrece: nunca un botón que no cambia nada',
        () async {
      final (b, c) = await caso(tarjeta: 1, memoria: 2, tienda: 2);
      final l = await b.apps.listar();
      final conProtegida = [
        for (final a in l)
          a.origen == OrigenApp.tarjetaApps
              ? AppSen(
                  handle: a.handle,
                  nombre: a.nombre,
                  bytes: a.bytes,
                  origen: a.origen,
                  protegida: true,
                  titulo: a.titulo,
                  verApp: a.verApp)
              : a
      ];
      final s = situacionCatalogo(c, conProtegida);
      expect(s.estado, EstadoCatalogo.tapada);
      expect(s.sePuedeResolver, isFalse);
      expect(s.explicacion, contains('no se puede quitar desde aquí'));
      await expectLater(b.apps.resolverTapada(b.backend, c, s),
          throwsA(isA<ErrorInstalarApp>()));
      expect(await b.apps.listar(), hasLength(2));
    });

    test('la de la tarjeta al día: no se molesta a nadie', () async {
      final (b, c) = await caso(tarjeta: 2, memoria: 1, tienda: 2);
      expect(situacionCatalogo(c, await b.apps.listar()).estado,
          EstadoCatalogo.alDia);
    });

    test('la de la tarjeta más nueva que la tienda: tampoco', () async {
      final (b, c) = await caso(tarjeta: 3, tienda: 2);
      expect(situacionCatalogo(c, await b.apps.listar()).estado,
          EstadoCatalogo.masNueva);
    });

    test('la de fábrica no es rival: la Memoria manda sobre ella', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.appsFabrica.add(fabrica('calc.sen', 'Calc', ver: 1));
      await b.conectar();
      final c = await b.publicar('calc', senDePrueba(verApp: 2));
      expect(situacionCatalogo(c, await b.apps.listar()).estado,
          EstadoCatalogo.hayActualizacion);
    });

    test('dos ficheros con el mismo nombre visible: manda el primero', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.appsFabrica.add(fabrica('ytmusic.sen', 'Música'));
      b.enMemoria('musica.sen', senDePrueba(nombre: 'Música', verApp: 2));
      await b.conectar();
      final l = await b.apps.listar();
      final m = l.firstWhere((x) => x.id == 'musica');
      expect(m.tapada, isTrue);
      expect(copiaQueLaTapa(l, m)?.nombre, 'ytmusic.sen');
      final c = await b.publicar('musica', senDePrueba(nombre: 'Música', verApp: 3));
      final s = situacionCatalogo(c, await b.apps.listar());
      expect(s.estado, EstadoCatalogo.tapada);
      expect(s.sePuedeResolver, isFalse, reason: 'la de fábrica no se quita');
      expect(s.explicacion, contains('la de fábrica'));
    });

    test('sin canal se aplica el mismo orden', () async {
      final (b, c) = await caso(tarjeta: 1, memoria: 2, tienda: 2, canal: false);
      final l = await b.apps.listar();
      expect(l.firstWhere((x) => x.origen == OrigenApp.memoria).tapada, isTrue);
      expect(l.firstWhere((x) => x.origen == OrigenApp.tarjetaApps).tapada,
          isFalse);
      expect(situacionCatalogo(c, l).estado, EstadoCatalogo.tapada);
    });

    test('sin canal, un juego de /tarjeta/juegos tampoco tapa a la Memoria',
        () async {
      final b = Banco(tarjeta: true, canal: false);
      addTearDown(b.limpiar);
      b.enTarjeta('juegos', 'teclas.sen', senDePrueba(verApp: 1, nombre: 'Teclas'));
      b.enMemoria('teclas.sen', senDePrueba(verApp: 2, nombre: 'Teclas'));
      await b.conectar();
      final c = await b.publicar('teclas', senDePrueba(verApp: 2, nombre: 'Teclas'));
      final l = await b.apps.listar();
      expect(l.firstWhere((x) => x.origen == OrigenApp.memoria).tapada, isFalse);
      expect(l.firstWhere((x) => x.origen == OrigenApp.tarjetaJuegos).tapada,
          isTrue);
      expect(situacionCatalogo(c, l).estado, EstadoCatalogo.alDia);
    });

    test('un juego de /tarjeta/juegos no tapa: va detrás de la Memoria', () async {
      final b = Banco(tarjeta: true);
      addTearDown(b.limpiar);
      b.enTarjeta('juegos', 'teclas.sen', senDePrueba(verApp: 1, nombre: 'Teclas'));
      b.enMemoria('teclas.sen', senDePrueba(verApp: 2, nombre: 'Teclas'));
      await b.conectar();
      final c = await b.publicar('teclas', senDePrueba(verApp: 2, nombre: 'Teclas'));
      final l = await b.apps.listar();
      expect(l.firstWhere((x) => x.origen == OrigenApp.tarjetaJuegos).tapada,
          isTrue);
      expect(situacionCatalogo(c, l).estado, EstadoCatalogo.alDia);
    });
  });

  group('frente al catálogo', () {
    AppIndice cat(int v) => AppIndice(
          id: 'x',
          nombre: 'X',
          autor: 'a',
          descripcion: '',
          categoria: 'c',
          verApp: v,
          versionTexto: '$v',
          api: '1.7',
          maquina: 1,
          perfil: 1,
          caps: 0,
          anMin: 0,
          alMin: 0,
          iconoGen: 0,
          iconoAn: 0,
          iconoFilas: const [],
          tam: 1,
          sha256: '',
          notas: '',
          manifiestoSha256: '',
        );
    AppSen ins(int? v) => AppSen(handle: 1, nombre: 'x.sen', bytes: 1, verApp: v);

    test('no instalada', () {
      expect(estadoFrente(cat(1), null), EstadoCatalogo.noInstalada);
    });
    test('vieja', () {
      expect(estadoFrente(cat(2), ins(1)), EstadoCatalogo.hayActualizacion);
    });
    test('igual', () {
      expect(estadoFrente(cat(2), ins(2)), EstadoCatalogo.alDia);
    });
    test('más nueva que el catálogo: no se ofrece bajar', () {
      expect(estadoFrente(cat(2), ins(3)), EstadoCatalogo.masNueva);
    });
    test('versión desconocida: se ofrece', () {
      expect(estadoFrente(cat(2), ins(null)), EstadoCatalogo.hayActualizacion);
    });
    test('el id es el nombre de fichero, sin mayúsculas ni .sen', () {
      const a = AppSen(handle: 1, nombre: 'Musica.SEN', bytes: 1);
      expect(a.id, 'musica');
    });
  });
}
