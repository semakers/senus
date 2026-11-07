// Juegos con datos en la tarjeta (docs/contrato_juegos_con_datos.md): instalar,
// reinstalar, actualizar y quitar contra el teléfono y el backend simulados.
// Todo esto es [simulado]: el doble hace lo que dice `api/mtp.c`, no el silicio.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:senus_app/datos/app_sen.dart';
import 'package:senus_app/datos/apps_telefono.dart';
import 'package:senus_app/datos/backend_semakers.dart';
import 'package:senus_app/datos/conexion_telefono.dart';
import 'package:senus_app/datos/indice_semakers.dart';
import 'package:senus_app/datos/telefono.dart';
import 'package:senus_app/mtp/operaciones.dart';
import 'package:senus_app/mtp/sesion_mtp.dart';
import 'package:senus_app/mtp/transporte.dart';

import 'apoyo/backend_simulado.dart';
import 'apoyo/telefono_simulado.dart';

/// Bytes que no se repiten en trozos: un corrimiento se nota.
Uint8List relleno(int n, int semilla) {
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    b[i] = (i * 31 + semilla * 7 + (i >> 8)) & 0xFF;
  }
  return b;
}

/// El primero pasa de un trozo de subida (64 KiB) y de uno de relectura
/// (256 KiB): así se miden las costuras.
DatosPublicar datosJuego({int v = 1}) => DatosPublicar('juego', {
      'nivel01.dat': relleno(300000, 1),
      'nivel01.lvl': relleno(10000, 2 + v * 10),
      'nivel02.dat': relleno(100000, 3),
    });

class Banco {
  final TelefonoSimulado tel = TelefonoSimulado();
  final Directory dir = Directory.systemTemp.createTempSync('senus_juegos_');
  final RedSimulada red = RedSimulada();
  late final Publicador pub = Publicador(red);
  late final ClienteBackend backend = ClienteBackend(
    red: red,
    cache: dir,
    claves: [publica],
    ahora: () => DateTime.utc(2026, 11, 3),
  );
  late SesionMtp sesion;
  late Telefono telefono;
  late ServicioApps apps;

  Banco({bool tarjeta = true}) {
    tel.hayTarjeta = tarjeta;
    tel.instalarYArrancar(
        ImagenConocida(mainDePrueba(290), 290, '0.29.0', canal: true));
  }

  Future<void> conectar() async {
    sesion = await PuertosSimulados(tel).conectar();
    telefono = (await leerTelefono(sesion)).valor!;
    apps = ServicioApps(sesion, telefono);
  }

  Future<AppIndice> publicarJuego(
      {int verApp = 1, DatosPublicar? datos, bool sinDatos = false}) async {
    pub.publicarApp('juego', senDePrueba(verApp: verApp, nombre: 'Juego', perfil: 2),
        nombre: 'Juego',
        destino: 'juegos',
        datos: sinDatos ? null : (datos ?? datosJuego(v: verApp)));
    pub.firmarIndice();
    return (await backend.indice()).indice.app('juego')!;
  }

  Objeto? get juegos => tel.hijo(storageTarjeta, handleRaiz, 'juegos');
  Objeto? get carpetaJuego =>
      juegos == null ? null : tel.hijo(storageTarjeta, juegos!.handle, 'juego');
  Objeto? get senJuego =>
      juegos == null ? null : tel.hijo(storageTarjeta, juegos!.handle, 'juego.sen');
  Map<String, Uint8List> get datosEnTarjeta => {
        for (final o in tel.objetos.values)
          if (o.padre == carpetaJuego?.handle) o.nombre: o.datos
      };

  Future<SituacionCatalogo> situacion(AppIndice a) async {
    final d = await backend.datosDe(a);
    return situacionCatalogo(a, await apps.listar(),
        datos: d,
        enTarjeta: d == null ? null : await apps.datosEnTarjeta(d),
        hayTarjeta: await apps.tarjetaActual() != null);
  }

  void limpiar() => dir.deleteSync(recursive: true);
}

void main() {
  group('índice y manifiesto', () {
    test('un índice viejo, sin los campos nuevos: apps y 0, y se instala igual',
        () async {
      final b = Banco();
      addTearDown(b.limpiar);
      await b.conectar();
      final sen = senDePrueba(verApp: 3);
      b.pub.publicarApp('calc', sen);
      b.pub.firmarIndice();
      final bruto = String.fromCharCodes(b.red.rutas['/v1/indice.json']!);
      expect(bruto, isNot(contains('destino')),
          reason: 'la prueba tiene que usar el índice de antes');
      final a = (await b.backend.indice()).indice.app('calc')!;
      expect(a.destino, destinoApps);
      expect(a.datosBytes, 0);
      expect(a.esJuego, isFalse);
      expect(a.tamTotal, sen.length);
      await b.apps.instalar(b.backend, a);
      final o = b.tel.objetos.values.singleWhere((x) => x.nombre == 'calc.sen');
      expect(o.almacen, storageMemoria);
      expect(o.datos, sen);
      expect(b.tel.objetos.values.where((x) => x.almacen == storageTarjeta), isEmpty);
    });

    test('el índice nuevo con destino «apps» y 0 es lo mismo que el viejo',
        () async {
      final b = Banco();
      addTearDown(b.limpiar);
      await b.conectar();
      b.pub.indiceNuevo = true;
      b.pub.publicarApp('calc', senDePrueba());
      b.pub.firmarIndice();
      final a = (await b.backend.indice()).indice.app('calc')!;
      expect(a.destino, destinoApps);
      await b.apps.instalar(b.backend, a);
      expect(b.tel.objetos.values.singleWhere((x) => x.nombre == 'calc.sen').almacen,
          storageMemoria);
    });

    test('un juego trae destino, datos_bytes y el tamaño total', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      final a = await b.publicarJuego();
      expect(a.esJuego, isTrue);
      expect(a.datosBytes, 410000);
      expect(a.tamTotal, a.tam + 410000);
      final d = (await b.backend.datosDe(a))!;
      expect(d.carpeta, 'juego');
      expect(d.archivos.map((x) => x.nombre),
          ['nivel01.dat', 'nivel01.lvl', 'nivel02.dat']);
    });

    Future<void> rechaza(Banco b,
        {Map<String, dynamic> Function(Map<String, dynamic>)? m,
        Map<String, dynamic> Function(Map<String, dynamic>)? e,
        int perfil = 2,
        Matcher? motivo}) async {
      b.pub.publicarApp('juego', senDePrueba(nombre: 'Juego', perfil: perfil),
          destino: 'juegos', datos: datosJuego(), tocarManifiesto: m, tocarEntrada: e);
      b.pub.firmarIndice();
      final a = (await b.backend.indice()).indice.app('juego')!;
      await expectLater(b.backend.descargarApp(a),
          throwsA(isA<ErrorVerificacion>().having((x) => x.detalle, 'detalle', motivo ?? anything)));
    }

    Map<String, dynamic> conArchivos(
        Map<String, dynamic> m, void Function(List<dynamic>) f) {
      final d = Map<String, dynamic>.from(m['datos'] as Map);
      final l = [
        for (final x in d['archivos'] as List) Map<String, dynamic>.from(x as Map)
      ];
      f(l);
      d['archivos'] = l;
      return {...m, 'datos': d};
    }

    test('el manifiesto rechaza lo que el contrato no deja', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      // destino distinto del índice
      await rechaza(b,
          m: (m) => {...m, 'destino': 'apps'}, motivo: contains('destino'));
      // datos_bytes que no suma lo del manifiesto
      await rechaza(b,
          e: (e) => {...e, 'datos_bytes': 1}, motivo: contains('datos_bytes'));
      // un nombre que no es 8.3 en minúsculas
      await rechaza(b,
          m: (m) => conArchivos(m, (l) => l[0]['nombre'] = 'Nivel01.dat'),
          motivo: contains('nombre'));
      await rechaza(b,
          m: (m) => conArchivos(m, (l) => l[0]['nombre'] = 'nivelxx01.dat'),
          motivo: contains('nombre'));
      // repetido
      await rechaza(b,
          m: (m) => conArchivos(m, (l) => l[1]['nombre'] = l[0]['nombre']),
          motivo: contains('nombre'));
      // una carpeta que se sale
      await rechaza(b,
          m: (m) => {
                ...m,
                'datos': {...(m['datos'] as Map), 'carpeta': '../apps'}
              },
          motivo: contains('carpeta'));
      // más de 32 MiB
      await rechaza(b,
          m: (m) => conArchivos(m, (l) => l[0]['bytes'] = (32 << 20) + 1),
          e: (e) => {...e, 'datos_bytes': (32 << 20) + 1 + 110000},
          motivo: contains('bytes'));
      // un juego que no es de perfil 2
      await rechaza(b, perfil: 1, motivo: contains('perfil'));
    });

    test('datos sin destino «juegos» no vale', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.pub.publicarApp('juego', senDePrueba(nombre: 'Juego', perfil: 2),
          destino: 'apps', datos: datosJuego(),
          tocarEntrada: (e) => {...e, 'datos_bytes': 0});
      b.pub.firmarIndice();
      final a = (await b.backend.indice()).indice.app('juego')!;
      await expectLater(b.backend.descargarApp(a), throwsA(isA<ErrorVerificacion>()));
    });

    test('datos con destino «apps», aunque sumen 0 bytes, no vale', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.pub.publicarApp('juego', senDePrueba(nombre: 'Juego', perfil: 2),
          destino: 'apps',
          datos: DatosPublicar('juego', {'vacio.dat': Uint8List(0)}));
      b.pub.firmarIndice();
      final a = (await b.backend.indice()).indice.app('juego')!;
      expect(a.datosBytes, 0);
      await expectLater(
          b.backend.descargarApp(a),
          throwsA(isA<ErrorVerificacion>()
              .having((x) => x.detalle, 'detalle', contains('«datos»'))));
    });

    test('más de 64 datos no vale', () {
      final l = [
        for (var i = 0; i < 65; i++)
          {'nombre': 'n$i.dat', 'bytes': 1, 'sha256': 'a' * 64}
      ];
      expect(() => DatosJuego.deJson({'carpeta': 'x', 'archivos': l}, 'm'),
          throwsA(isA<ErrorVerificacion>()));
      expect(
          DatosJuego.deJson({'carpeta': 'x', 'archivos': l.sublist(0, 64)}, 'm')
              .archivos,
          hasLength(64));
    });

    test('un destino que esta SENUS no conoce: se enseña y no se instala',
        () async {
      final b = Banco();
      addTearDown(b.limpiar);
      await b.conectar();
      b.pub.publicarApp('tono', senDePrueba(),
          tocarEntrada: (e) => {...e, 'destino': 'tonos', 'datos_bytes': 0});
      b.pub.firmarIndice();
      final a = (await b.backend.indice()).indice.app('tono')!;
      expect(a.destinoConocido, isFalse);
      expect(situacionCatalogo(a, const []).estado, EstadoCatalogo.noSoportada);
      await expectLater(
          b.apps.instalar(b.backend, a), throwsA(isA<ErrorInstalarApp>()));
      expect(b.tel.subidos, isEmpty);
    });
  });

  group('instalar', () {
    test('crea las carpetas, sube y relee cada dato, y el .sen el último',
        () async {
      final b = Banco();
      addTearDown(b.limpiar);
      await b.conectar();
      final a = await b.publicarJuego();
      final pasos = <ProgresoInstalacion>[];
      await b.apps.instalar(b.backend, a, alProgreso: pasos.add);
      final datos = datosJuego();
      expect(b.datosEnTarjeta, datos.archivos);
      expect(b.senJuego!.datos, senDePrueba(nombre: 'Juego', perfil: 2));
      expect(b.tel.registro, [
        'carpeta juegos',
        'carpeta juego',
        'subido nivel01.dat',
        'subido nivel01.lvl',
        'subido nivel02.dat',
        'subido juego.sen',
      ]);
      // Progreso por bytes del total: subir y releer, sin volver atrás.
      final escritura =
          pasos.where((p) => p.total == 2 * a.tamTotal).toList();
      expect(escritura, isNotEmpty);
      for (var i = 1; i < escritura.length; i++) {
        expect(escritura[i].hechos, greaterThanOrEqualTo(escritura[i - 1].hechos));
      }
      expect(escritura.last.hechos, escritura.last.total);
      expect(escritura.where((p) => p.paso.startsWith('Subiendo nivel01.dat')).length,
          greaterThan(4), reason: '300 000 B van en varios trozos');
      final s = await b.situacion(a);
      expect(s.estado, EstadoCatalogo.alDia);
      final l = await b.apps.listar();
      expect(l.singleWhere((x) => x.id == 'juego').origen, OrigenApp.tarjetaJuegos);
    });

    test('lo que ya hay en la tarjeta se respeta: solo se toca lo del juego',
        () async {
      final b = Banco();
      addTearDown(b.limpiar);
      final j = b.tel.crearCarpeta(storageTarjeta, 'juegos');
      b.tel.crearFichero(storageTarjeta, j.handle, 'serpient.sen',
          senDePrueba(nombre: 'Serpiente', perfil: 2));
      final otra = b.tel.crearCarpeta(storageTarjeta, 'otro', padre: j.handle);
      b.tel.crearFichero(storageTarjeta, otra.handle, 'nivel01.dat', Uint8List(5));
      await b.conectar();
      final a = await b.publicarJuego();
      await b.apps.instalar(b.backend, a);
      expect(b.tel.registro.where((r) => r.startsWith('carpeta')), ['carpeta juego']);
      await b.apps.quitarJuego(b.backend, a);
      expect(b.tel.hijo(storageTarjeta, j.handle, 'serpient.sen'), isNotNull);
      expect(b.tel.hijo(storageTarjeta, otra.handle, 'nivel01.dat'), isNotNull);
      expect(b.juegos, isNotNull);
    });

    test('una carpeta «JUEGOS» en mayúsculas es la misma: no se crea otra',
        () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.crearCarpeta(storageTarjeta, 'JUEGOS');
      await b.conectar();
      final a = await b.publicarJuego();
      await b.apps.instalar(b.backend, a);
      expect(b.tel.registro.first, 'carpeta juego');
      expect(b.senJuego, isNotNull);
      expect((await b.situacion(a)).estado, EstadoCatalogo.alDia);
    });

    test('un juego sin datos: solo el .sen en /tarjeta/juegos', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      await b.conectar();
      final a = await b.publicarJuego(sinDatos: true);
      expect(a.datosBytes, 0);
      await b.apps.instalar(b.backend, a);
      expect(b.tel.registro, ['carpeta juegos', 'subido juego.sen']);
      expect((await b.situacion(a)).estado, EstadoCatalogo.alDia);
    });

    test('reinstalar encima: relee lo que hay y solo sube el .sen', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      await b.conectar();
      final a = await b.publicarJuego();
      await b.apps.instalar(b.backend, a);
      b.tel.registro.clear();
      final antes = b.tel.bytesSubidos;
      final pasos = <ProgresoInstalacion>[];
      await b.apps.instalar(b.backend, a, alProgreso: pasos.add);
      // Lo comprobado cuenta como hecho: el .sen empieza con todo lo demás ya en la barra.
      final sen = pasos.firstWhere((p) => p.paso == 'Subiendo juego.sen…');
      expect(sen.hechos, inInclusiveRange(2 * a.datosBytes, 2 * a.datosBytes + a.tam));
      final escritura = pasos.where((p) => p.total == 2 * a.tamTotal).toList();
      for (var i = 1; i < escritura.length; i++) {
        expect(escritura[i].hechos, greaterThanOrEqualTo(escritura[i - 1].hechos));
      }
      expect(b.tel.registro, ['subido juego.sen']);
      expect(b.tel.bytesSubidos - antes, a.tam);
      expect(b.datosEnTarjeta, datosJuego().archivos);
      expect(b.tel.objetos.values.where((o) => o.nombre == 'juego.sen'), hasLength(1));
      expect((await b.situacion(a)).estado, EstadoCatalogo.alDia);
    });

    test('un dato del mismo tamaño y otro contenido: se quita el .sen, se sube '
        'ese y el .sen al final', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      await b.conectar();
      final a = await b.publicarJuego();
      await b.apps.instalar(b.backend, a);
      final lod = b.tel.objetos.values.singleWhere((o) => o.nombre == 'nivel01.lvl');
      lod.datos = Uint8List.fromList(lod.datos)..[100] ^= 1;
      b.tel.registro.clear();
      await b.apps.instalar(b.backend, a);
      expect(b.tel.registro,
          ['borrado juego.sen', 'subido nivel01.lvl', 'subido juego.sen']);
      expect(b.datosEnTarjeta, datosJuego().archivos);
    });

    test('actualizar con otros datos: el .sen viejo sale antes de tocarlos',
        () async {
      final b = Banco();
      addTearDown(b.limpiar);
      await b.conectar();
      await b.apps.instalar(b.backend, await b.publicarJuego());
      final a2 = await b.publicarJuego(verApp: 2);
      expect((await b.situacion(a2)).estado, EstadoCatalogo.hayActualizacion);
      b.tel.registro.clear();
      await b.apps.instalar(b.backend, a2);
      expect(b.tel.registro,
          ['borrado juego.sen', 'subido nivel01.lvl', 'subido juego.sen']);
      expect(b.datosEnTarjeta, datosJuego(v: 2).archivos);
      expect((await b.situacion(a2)).estado, EstadoCatalogo.alDia);
    });

    test('corte del cable a mitad de un dato: no queda el .sen; reinstalar '
        'termina sin volver a subir lo que ya estaba', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      await b.conectar();
      final a = await b.publicarJuego();
      b.tel.cortarSubidaDe = 'nivel02.dat';
      b.tel.cortarTrasBytes = 40000;
      await expectLater(
          b.apps.instalar(b.backend, a), throwsA(isA<TransporteError>()));
      expect(b.tel.cortarSubidaDe, isNull, reason: 'el corte tiene que haber saltado');
      b.tel.reconectar();
      await b.conectar();
      expect(b.senJuego, isNull, reason: 'un juego a medias no sale en «Juegos»');
      expect(b.datosEnTarjeta.keys.toSet(), {'nivel01.dat', 'nivel01.lvl'},
          reason: 'de un fichero cortado no queda nada');
      final s = await b.situacion(a);
      expect(s.estado, EstadoCatalogo.incompleto);
      expect(s.faltaSen, isTrue);
      expect(s.faltan, 1);
      expect(s.explicacion, contains('Incompleto'));
      expect(s.accion, 'Reinstalar');
      b.tel.registro.clear();
      await b.apps.instalar(b.backend, a);
      expect(b.tel.registro, ['subido nivel02.dat', 'subido juego.sen']);
      expect(b.datosEnTarjeta, datosJuego().archivos);
      expect((await b.situacion(a)).estado, EstadoCatalogo.alDia);
    });

    test('corte a mitad de una actualización: tampoco queda el .sen viejo',
        () async {
      final b = Banco();
      addTearDown(b.limpiar);
      await b.conectar();
      await b.apps.instalar(b.backend, await b.publicarJuego());
      final a2 = await b.publicarJuego(verApp: 2);
      b.tel.cortarSubidaDe = 'nivel01.lvl';
      b.tel.cortarTrasBytes = 5000;
      await expectLater(
          b.apps.instalar(b.backend, a2), throwsA(isA<TransporteError>()));
      b.tel.reconectar();
      await b.conectar();
      expect(b.senJuego, isNull);
      expect((await b.situacion(a2)).estado, EstadoCatalogo.incompleto);
    });

    test('sha256 que no cuadra al releer: error, la copia mala fuera y sin .sen',
        () async {
      final b = Banco();
      addTearDown(b.limpiar);
      await b.conectar();
      final a = await b.publicarJuego();
      b.tel.corromperAlGuardar = true;
      b.tel.corromperSolo = 'nivel01.lvl';
      await expectLater(
          b.apps.instalar(b.backend, a),
          throwsA(isA<ErrorInstalarApp>().having(
              (e) => e.motivo, 'motivo', contains('no es lo que se subió'))));
      expect(b.senJuego, isNull);
      expect(b.datosEnTarjeta.keys, isNot(contains('nivel01.lvl')));
      expect(b.tel.subidos, isNot(contains('nivel02.dat')),
          reason: 'tras un fallo no se sigue');
    });

    test('sin tarjeta: «Necesita una tarjeta», sin bajar ni escribir nada',
        () async {
      final b = Banco(tarjeta: false);
      addTearDown(b.limpiar);
      await b.conectar();
      final a = await b.publicarJuego();
      final s = await b.situacion(a);
      expect(s.estado, EstadoCatalogo.sinTarjeta);
      expect(s.explicacion, 'Necesita una tarjeta');
      b.red.pedidas.clear();
      await expectLater(
          b.apps.instalar(b.backend, a),
          throwsA(isA<ErrorInstalarApp>()
              .having((e) => e.motivo, 'motivo', contains('necesita una tarjeta'))));
      expect(b.tel.registro, isEmpty);
      expect(b.red.pedidas.where((r) => r.startsWith('/v1/archivos/')), isEmpty);
    });

    test('tarjeta protegida: se dice y no se escribe', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.tarjetaSoloLectura = true;
      await b.conectar();
      final a = await b.publicarJuego();
      await expectLater(
          b.apps.instalar(b.backend, a),
          throwsA(isA<ErrorInstalarApp>()
              .having((e) => e.motivo, 'motivo', contains('protegida'))));
      expect(b.tel.registro, isEmpty);
    });

    test('sin espacio: se comprueba antes de empezar, sin bajar ni escribir nada',
        () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.tel.tarjetaCapacidad = 350000; // cabe el primer dato, no el juego
      await b.conectar();
      final a = await b.publicarJuego();
      b.red.pedidas.clear();
      await expectLater(
          b.apps.instalar(b.backend, a),
          throwsA(isA<ErrorInstalarApp>()
              .having((e) => e.motivo, 'motivo', contains('No cabe'))));
      expect(b.tel.registro, isEmpty);
      expect(b.red.pedidas.where((r) => r.startsWith('/v1/archivos/')), isEmpty);
    });

    test('el espacio cuenta lo que ya está: reinstalar con la tarjeta casi '
        'llena sí cabe', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      await b.conectar();
      final a = await b.publicarJuego();
      await b.apps.instalar(b.backend, a);
      b.tel.tarjetaCapacidad = 410000 + a.tam + 200000;
      await b.apps.instalar(b.backend, a);
      expect((await b.situacion(a)).estado, EstadoCatalogo.alDia);
    });

    test('la tabla de la tarjeta tiene 511 sitios: si no caben, ni se empieza',
        () async {
      final b = Banco();
      addTearDown(b.limpiar);
      final c = b.tel.crearCarpeta(storageTarjeta, 'musica');
      for (var i = 0; i < 506; i++) {
        b.tel.crearFichero(storageTarjeta, c.handle, 'p$i.mp3', Uint8List(1));
      }
      await b.conectar();
      final a = await b.publicarJuego();
      await expectLater(
          b.apps.instalar(b.backend, a),
          throwsA(isA<ErrorInstalarApp>()
              .having((e) => e.motivo, 'motivo', contains('511'))));
      expect(b.tel.registro, isEmpty);
    });

    test('sin red: no se toca la tarjeta', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      await b.conectar();
      final a = await b.publicarJuego();
      b.red.cortarRuta = '/v1/archivos/${sha256De(datosJuego().archivos['nivel02.dat']!)}';
      await expectLater(b.apps.instalar(b.backend, a), throwsA(isA<SinRed>()));
      expect(b.tel.registro, isEmpty);
    });

    test('un dato que el servidor cambia no llega al teléfono', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      await b.conectar();
      final a = await b.publicarJuego();
      final sha = sha256De(datosJuego().archivos['nivel01.lvl']!);
      b.red.poner('/v1/archivos/$sha', relleno(10000, 99));
      await expectLater(b.apps.instalar(b.backend, a),
          throwsA(isA<ErrorVerificacion>()));
      expect(b.tel.registro, isEmpty);
    });
  });

  group('quitar', () {
    test('primero el .sen y luego la carpeta entera, solo esa', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      await b.conectar();
      final a = await b.publicarJuego();
      await b.apps.instalar(b.backend, a);
      b.tel.registro.clear();
      await b.apps.quitarJuego(b.backend, a);
      expect(b.tel.registro.first, 'borrado juego.sen');
      expect(b.tel.registro.last, 'borrado juego');
      expect(b.tel.registro, hasLength(5));
      expect(b.senJuego, isNull);
      expect(b.carpetaJuego, isNull);
      expect(b.juegos, isNotNull, reason: '/tarjeta/juegos es de todos');
      expect(
          b.tel.objetos.values.where((o) =>
              o.almacen == storageTarjeta && o.handle != b.juegos!.handle),
          isEmpty);
      expect((await b.situacion(a)).estado, EstadoCatalogo.noInstalada);
    });

    test('quita también lo que dejó una instalación cortada', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      await b.conectar();
      final a = await b.publicarJuego();
      b.tel.cortarSubidaDe = 'nivel02.dat';
      b.tel.cortarTrasBytes = 1000;
      await expectLater(
          b.apps.instalar(b.backend, a), throwsA(isA<TransporteError>()));
      b.tel.reconectar();
      await b.conectar();
      expect((await b.situacion(a)).hayAlgoQueQuitar, isTrue);
      await b.apps.quitarJuego(b.backend, a);
      expect(b.carpetaJuego, isNull);
      expect((await b.situacion(a)).estado, EstadoCatalogo.noInstalada);
    });

    test('si el teléfono dice que sí y no borra, lo dice', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      await b.conectar();
      final a = await b.publicarJuego();
      await b.apps.instalar(b.backend, a);
      b.tel.borradoSinEfecto = true;
      await expectLater(
          b.apps.quitarJuego(b.backend, a),
          throwsA(isA<ErrorInstalarApp>()
              .having((e) => e.motivo, 'motivo', contains('sigue en la tarjeta'))));
    });
  });

  group('situación en el catálogo', () {
    test('falta un dato o no mide lo que debe: incompleto', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      await b.conectar();
      final a = await b.publicarJuego();
      expect((await b.situacion(a)).estado, EstadoCatalogo.noInstalada);
      await b.apps.instalar(b.backend, a);
      final lod = b.tel.objetos.values.singleWhere((o) => o.nombre == 'nivel01.lvl');
      lod.datos = Uint8List(5);
      var s = await b.situacion(a);
      expect(s.estado, EstadoCatalogo.incompleto);
      expect(s.explicacion, 'Incompleto: falta 1 de 3 datos');
      b.tel.objetos.remove(lod.handle);
      b.tel.objetos.removeWhere((_, o) => o.nombre == 'nivel02.dat');
      s = await b.situacion(a);
      expect(s.explicacion, 'Incompleto: faltan 2 de 3 datos');
      await b.apps.instalar(b.backend, a);
      expect((await b.situacion(a)).estado, EstadoCatalogo.alDia);
    });

    test('nombres en mayúsculas en la tarjeta cuentan', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      final j = b.tel.crearCarpeta(storageTarjeta, 'JUEGOS');
      final c = b.tel.crearCarpeta(storageTarjeta, 'JUEGO', padre: j.handle);
      b.tel.crearFichero(storageTarjeta, j.handle, 'JUEGO.SEN',
          senDePrueba(nombre: 'Juego', perfil: 2));
      for (final e in datosJuego().archivos.entries) {
        b.tel.crearFichero(storageTarjeta, c.handle, e.key.toUpperCase(), e.value);
      }
      await b.conectar();
      final a = await b.publicarJuego();
      expect((await b.situacion(a)).estado, EstadoCatalogo.alDia);
      // Reinstalar no sube nada con otra caja: el nombre que ya tienen.
      b.tel.registro.clear();
      await b.apps.instalar(b.backend, a);
      expect(b.tel.registro, ['subido JUEGO.SEN']);
      // Y un dato que hay que pisar se pisa con su nombre de la tarjeta: el
      // respondedor numera por nombre exacto y con otra caja saldría dos veces.
      final lod = b.tel.objetos.values.singleWhere((o) => o.nombre == 'NIVEL01.LVL');
      lod.datos = Uint8List(7);
      b.tel.registro.clear();
      await b.apps.instalar(b.backend, a);
      expect(b.tel.registro, ['borrado JUEGO.SEN', 'subido NIVEL01.LVL', 'subido juego.sen']);
      expect((await b.situacion(a)).estado, EstadoCatalogo.alDia);
    });
  });
}
