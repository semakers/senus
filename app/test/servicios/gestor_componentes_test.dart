// El gestor de componentes contra un origen simulado. Lo que defiende: NADA sin
// verificar llega a ejecutarse.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:senus_app/servicios/componentes.dart';
import 'package:senus_app/servicios/gestor_componentes.dart';
import 'package:senus_app/servicios/motor_dictado.dart';

import 'apoyo_servicios.dart';

List<int> azar(int n, [int semilla = 1]) {
  final r = Random(semilla);
  return List.generate(n, (_) => r.nextInt(256));
}

void main() {
  late OrigenSimulado o;
  late Directory t;
  late List<int> datos;

  setUp(() async {
    o = await OrigenSimulado.crear();
    t = await carpetaTemporal();
    datos = azar(300000);
    o.ficheros['modelo.bin'] = datos;
  });
  tearDown(() async {
    await o.cerrar();
    await t.delete(recursive: true);
  });

  Componente directo({String? huella, String ruta = 'modelo.bin', int? tam, String? origen}) => Componente(
        id: 'c',
        version: '1',
        licencias: '',
        archivos: [
          ArchivoComponente(
            origen: origen ?? o.url(ruta),
            sha256: huella ?? sha(datos),
            tam: tam ?? datos.length,
            tipo: TipoArchivo.directo,
            destino: 'modelo.bin',
            tamInstalado: datos.length,
          ),
        ],
      );

  GestorComponentes gestor(
    Componente c, {
    bool http = true,
    EspacioLibre? libre,
    EscribirTrozo? escribir,
    LeerEmpotrado? empotrado,
    int reintentos = 3,
  }) =>
      GestorComponentes(
        raiz: Directory(p.join(t.path, 'raiz')),
        catalogo: [c],
        espacioLibre: libre ?? (_) async => 1 << 40,
        escribirTrozo: escribir ?? ((f, b) => f.writeFrom(b)),
        leerEmpotrado: empotrado,
        permitirHttp: http,
        reintentos: reintentos,
      );

  group('descargar', () {
    test('baja, comprueba la huella y da la ruta', () async {
      final g = gestor(directo());
      final vistos = <EstadoComponente>[];
      g.cambios.listen(vistos.add);
      await g.instalar('c');
      expect(g.estado('c').fase, FaseComponente.listo);
      final r = await g.rutaVerificada('c', 'modelo.bin');
      expect(await File(r).readAsBytes(), datos);
      final bajando = vistos.where((e) => e.fase == FaseComponente.descargando).toList();
      expect(bajando, isNotEmpty);
      expect(bajando.last.recibidos, datos.length);
      expect(bajando.last.total, datos.length);
      for (var i = 1; i < bajando.length; i++) {
        expect(bajando[i].recibidos, greaterThanOrEqualTo(bajando[i - 1].recibidos));
      }
      expect(vistos.any((e) => e.fase == FaseComponente.verificando), isTrue);
      await g.cerrar();
    });

    test('huella mala: fallo, nada en su sitio y nada que reanudar', () async {
      final g = gestor(directo(huella: 'a' * 64));
      await g.instalar('c');
      expect(g.estado('c').fase, FaseComponente.fallo);
      expect(g.estado('c').fallo!.tipo, TipoFallo.huella);
      expect(await File(p.join(t.path, 'raiz', 'c-1', 'modelo.bin')).exists(), isFalse);
      expect(await g.bytesParciales('c'), 0);
      await expectLater(g.rutaVerificada('c', 'modelo.bin'), throwsA(isA<NoVerificado>()));
      await g.cerrar();
    });

    test('un corte a media descarga se reanuda con Range y queda bien', () async {
      o.cortes.add(100000);
      final g = gestor(directo());
      await g.instalar('c');
      expect(g.estado('c').fase, FaseComponente.listo, reason: '${g.estado('c').fallo}');
      expect(o.peticiones.length, 2);
      expect(o.peticiones[0].$2, isNull);
      expect(o.peticiones[1].$2, startsWith('bytes='));
      final desde = int.parse(RegExp(r'\d+').firstMatch(o.peticiones[1].$2!)!.group(0)!);
      expect(desde, greaterThan(0));
      expect(desde, lessThanOrEqualTo(100000));
      expect(await File(await g.rutaVerificada('c', 'modelo.bin')).readAsBytes(), datos);
      await g.cerrar();
    });

    test('cortes sin avanzar: se rinde, conserva lo bajado y otra sesión reanuda', () async {
      o.cortes.addAll([50000, 50000, 50000, 50000, 50000]);
      final g = gestor(directo(), reintentos: 3);
      await g.instalar('c');
      expect(g.estado('c').fase, FaseComponente.fallo);
      expect(g.estado('c').fallo!.tipo, TipoFallo.red);
      expect(await g.bytesParciales('c'), greaterThan(0));
      await g.cerrar();
      o.cortes.clear();
      o.peticiones.clear();
      final g2 = gestor(directo());
      await g2.instalar('c');
      expect(g2.estado('c').fase, FaseComponente.listo);
      expect(o.peticiones.first.$2, isNotNull, reason: 'otra sesión sigue por donde iba');
      await g2.cerrar();
    });

    test('un origen sin Range: vuelve a empezar y queda bien', () async {
      o.cortes.add(100000);
      o.sinRango = true;
      final g = gestor(directo());
      await g.instalar('c');
      expect(g.estado('c').fase, FaseComponente.listo);
      expect(await File(await g.rutaVerificada('c', 'modelo.bin')).readAsBytes(), datos);
      await g.cerrar();
    });

    test('un Content-Range que no casa: empieza de cero', () async {
      o.cortes.add(100000);
      o.rangoMentiroso = true;
      final g = gestor(directo());
      await g.instalar('c');
      expect(g.estado('c').fase, FaseComponente.listo, reason: 'lo reanudado se tira y se pide entero');
      expect(o.peticiones.last.$2, isNull);
      expect(await File(await g.rutaVerificada('c', 'modelo.bin')).readAsBytes(), datos);
      await g.cerrar();
    });

    test('un origen que manda de más se corta ANTES de escribirlo: no llena el disco', () async {
      var escritos = 0;
      final g = gestor(directo(tam: 1000, huella: sha(datos.sublist(0, 1000))), escribir: (f, b) async {
        escritos += b.length;
        await f.writeFrom(b);
      });
      await g.instalar('c');
      expect(g.estado('c').fase, FaseComponente.fallo);
      expect(g.estado('c').fallo!.tipo, TipoFallo.huella);
      expect(escritos, lessThanOrEqualTo(1000));
      await g.cerrar();
    });

    test('cancelar: vuelve a ausente, guarda lo bajado y luego reanuda', () async {
      o.freno = Completer<void>();
      o.frenarEn = 120000;
      final g = gestor(directo());
      final hecho = g.instalar('c');
      await g.cambios.firstWhere((e) => e.recibidos >= 120000);
      g.cancelar('c');
      await hecho;
      expect(g.estado('c').fase, FaseComponente.ausente);
      expect(await g.bytesParciales('c'), greaterThan(0));
      o.freno!.complete();
      o.freno = null;
      o.peticiones.clear();
      await g.instalar('c');
      expect(g.estado('c').fase, FaseComponente.listo);
      expect(o.peticiones.first.$2, isNotNull);
      await g.cerrar();
    });

    test('fuera de las pruebas, solo https: no llega a pedir nada', () async {
      final g = gestor(directo(), http: false);
      await g.instalar('c');
      expect(g.estado('c').fase, FaseComponente.fallo);
      expect(o.peticiones, isEmpty);
      await g.cerrar();
    });

    test('sigue un salto, y un salto a http no vale sin permiso', () async {
      o.saltos['a'] = o.url('modelo.bin');
      final g = gestor(directo(ruta: 'a'));
      await g.instalar('c');
      expect(g.estado('c').fase, FaseComponente.listo);
      await g.cerrar();
    });

    test('demasiados saltos: se rinde', () async {
      o.saltos['a'] = o.url('a');
      final g = gestor(directo(ruta: 'a'));
      await g.instalar('c');
      expect(g.estado('c').fase, FaseComponente.fallo);
      expect(o.peticiones.length, lessThan(10));
      await g.cerrar();
    });

    test('un 404 no se reintenta', () async {
      final g = gestor(directo(ruta: 'no-existe'));
      await g.instalar('c');
      expect(g.estado('c').fase, FaseComponente.fallo);
      expect(o.peticiones.length, 1);
      await g.cerrar();
    });
  });

  group('disco lleno', () {
    test('antes de empezar: lo dice con números y no pide nada', () async {
      final g = gestor(directo(), libre: (_) async => 1000);
      await g.instalar('c');
      expect(g.estado('c').fallo!.tipo, TipoFallo.discoLleno);
      expect(g.estado('c').fallo!.mensaje, contains('MB'));
      expect(o.peticiones, isEmpty);
      await g.cerrar();
    });

    test('a mitad de escribir: lo dice y conserva lo bajado', () async {
      var n = 0;
      final g = gestor(directo(), escribir: (f, b) async {
        // Cabe una parte del trozo, como en un disco de verdad.
        final cabe = 150000 - n;
        if (b.length > cabe) {
          await f.writeFrom(b, 0, cabe);
          n += cabe;
          throw const FileSystemException('escribir', '/x', OSError('No space left on device', 28));
        }
        n += b.length;
        await f.writeFrom(b);
      });
      await g.instalar('c');
      expect(g.estado('c').fase, FaseComponente.fallo);
      expect(g.estado('c').fallo!.tipo, TipoFallo.discoLleno);
      expect(await g.bytesParciales('c'), greaterThan(0));
      await g.cerrar();
    });
  });

  group('zip', () {
    Future<Componente> conZip(List<int> zip, String arbol) async {
      o.ficheros['z.zip'] = zip;
      return Componente(id: 'c', version: '1', licencias: '', archivos: [
        ArchivoComponente(
          origen: o.url('z.zip'),
          sha256: sha(zip),
          tam: zip.length,
          tipo: TipoArchivo.zip,
          destino: 'bin',
          arbolSha256: arbol,
          tamInstalado: 1000,
        ),
      ]);
    }

    Future<String> arbolDe(Map<String, (List<int>, int)> f) async {
      final d = await Directory(p.join(t.path, 'modelo_arbol')).create();
      f.forEach((n, v) {
        final x = File(p.join(d.path, n))..createSync(recursive: true);
        x.writeAsBytesSync(v.$1);
      });
      final h = await huellaArbol(d.path);
      await d.delete(recursive: true);
      return h;
    }

    test('descomprime, comprueba el árbol, deja el bit de ejecutar y corre', () async {
      final rastro = p.join(t.path, 'rastro');
      final f = {
        'prog': (scriptConRastro(rastro), 0x1ED), // 0755
        'datos/dentro.txt': (utf8.encode('hola'), 0x1A4), // 0644
      };
      final c = await conZip(hacerZip(f), await arbolDe(f));
      final g = gestor(c);
      await g.instalar('c');
      expect(g.estado('c').fase, FaseComponente.listo, reason: '${g.estado('c').fallo}');
      final prog = await g.rutaVerificada('c', 'bin/prog');
      expect((await Process.run(prog, [])).exitCode, 0);
      expect(await File(rastro).exists(), isTrue);
      await g.cerrar();
    });

    test('zip bueno pero árbol que no casa: nada queda en su sitio', () async {
      final f = {'prog': (utf8.encode('x'), 0x1ED)};
      final c = await conZip(hacerZip(f), 'b' * 64);
      final g = gestor(c);
      await g.instalar('c');
      expect(g.estado('c').fallo!.tipo, TipoFallo.huella);
      expect(await Directory(p.join(t.path, 'raiz', 'c-1', 'bin')).exists(), isFalse);
      expect(await Directory(p.join(t.path, 'raiz', 'c-1', 'bin.nuevo')).exists(), isFalse);
      await g.cerrar();
    });

    test('una ruta que se sale de la carpeta no se descomprime', () async {
      final zip = hacerZip({'../fuera.txt': (utf8.encode('mal'), 0x1A4)});
      final c = await conZip(zip, 'b' * 64);
      final g = gestor(c);
      await g.instalar('c');
      expect(g.estado('c').fase, FaseComponente.fallo);
      expect(g.estado('c').fallo!.tipo, TipoFallo.paquete);
      expect(await File(p.join(t.path, 'raiz', 'c-1', 'fuera.txt')).exists(), isFalse);
      expect(await File(p.join(t.path, 'raiz', 'fuera.txt')).exists(), isFalse);
      await g.cerrar();
    });

    test('una barra invertida tampoco: en Windows sería una carpeta', () async {
      final zip = hacerZip({r'sub\..\..\fuera.txt': (utf8.encode('mal'), 0x1A4)});
      final c = await conZip(zip, 'b' * 64);
      final g = gestor(c);
      await g.instalar('c');
      expect(g.estado('c').fallo!.tipo, TipoFallo.paquete);
      await g.cerrar();
    });

    test('una ruta absoluta tampoco', () async {
      final salida = p.join(t.path, 'absoluta.txt');
      final zip = hacerZip({salida: (utf8.encode('mal'), 0x1A4)});
      final c = await conZip(zip, 'b' * 64);
      final g = gestor(c);
      await g.instalar('c');
      expect(g.estado('c').fallo!.tipo, TipoFallo.paquete);
      expect(await File(salida).exists(), isFalse);
      await g.cerrar();
    });
  });

  group('lo que no casa NO SE EJECUTA', () {
    late Componente c;
    late List<int> script;
    late String rastro;

    setUp(() {
      rastro = p.join(t.path, 'rastro');
      script = scriptConRastro(rastro, resto: 'exit 7');
      o.ficheros['prog'] = script;
      c = Componente(id: 'c', version: '1', licencias: '', archivos: [
        ArchivoComponente(
          origen: o.url('prog'),
          sha256: sha(script),
          tam: script.length,
          tipo: TipoArchivo.directo,
          destino: 'prog',
          tamInstalado: script.length,
        ),
      ]);
    });

    MotorAyudante motor(GestorComponentes g) => MotorAyudante(
          rutas: () async => RutasMotor(await g.rutaVerificada('c', 'prog'), 'm', 'v'),
          plazoCarga: const Duration(seconds: 5),
        );

    test('tocado en la misma sesión: no sale la ruta y el proceso no existe', () async {
      final g = gestor(c);
      await g.instalar('c');
      final r = await g.rutaVerificada('c', 'prog');
      await Process.run('chmod', ['755', r]);
      final b = await File(r).readAsBytes();
      b[b.length - 1] ^= 1;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await File(r).writeAsBytes(b, flush: true);
      await expectLater(g.rutaVerificada('c', 'prog'), throwsA(isA<NoVerificado>()));
      await expectLater(motor(g).tramosDeVoz(Float32List(10)), throwsA(isA<NoVerificado>()));
      expect(await File(rastro).exists(), isFalse, reason: 'el binario tocado NO corrió');
      expect(g.estado('c').fase, FaseComponente.fallo);
      await g.cerrar();
    });

    test('tocado entre sesiones, con el mismo tamaño y la misma fecha: la otra sesión lo caza', () async {
      final g = gestor(c);
      await g.instalar('c');
      final r = await g.rutaVerificada('c', 'prog');
      await g.cerrar();
      final f = File(r);
      final fecha = await f.lastModified();
      final b = await f.readAsBytes();
      b[0] ^= 1;
      await f.writeAsBytes(b, flush: true);
      await f.setLastModified(fecha);
      final g2 = gestor(c);
      await g2.comprobar();
      expect(g2.estado('c').fase, FaseComponente.fallo);
      await expectLater(g2.rutaVerificada('c', 'prog'), throwsA(isA<NoVerificado>()));
      await g2.cerrar();
    });

    test('la verificación se repite en cada arranque del motor: uno bueno sí corre', () async {
      final g = gestor(c);
      await g.instalar('c');
      await Process.run('chmod', ['755', await g.rutaVerificada('c', 'prog')]);
      // sale con 7 sin decir nada: el motor falla, pero el binario sí llegó a correr
      await expectLater(motor(g).tramosDeVoz(Float32List(10)), throwsA(anything));
      expect(await File(rastro).exists(), isTrue);
      await g.cerrar();
    });

    test('un fichero de más en el árbol no pasa', () async {
      final f = {'prog': (script, 0x1ED)};
      final zip = hacerZip(f);
      o.ficheros['z.zip'] = zip;
      final d = await Directory(p.join(t.path, 'a')).create();
      await File(p.join(d.path, 'prog')).writeAsBytes(script);
      final arbol = await huellaArbol(d.path);
      final cz = Componente(id: 'c', version: '1', licencias: '', archivos: [
        ArchivoComponente(
          origen: o.url('z.zip'),
          sha256: sha(zip),
          tam: zip.length,
          tipo: TipoArchivo.zip,
          destino: 'bin',
          arbolSha256: arbol,
          tamInstalado: 100,
        ),
      ]);
      final g = gestor(cz);
      await g.instalar('c');
      expect(g.estado('c').fase, FaseComponente.listo);
      await g.rutaVerificada('c', 'bin/prog');
      await File(p.join(t.path, 'raiz', 'c-1', 'bin', 'extra.dylib')).writeAsString('x');
      await expectLater(g.rutaVerificada('c', 'bin/prog'), throwsA(isA<NoVerificado>()));
      await g.cerrar();
    });

    test('un enlace simbólico en el árbol no pasa', () async {
      final d = await Directory(p.join(t.path, 'e')).create();
      await File(p.join(d.path, 'a')).writeAsString('x');
      await Link(p.join(d.path, 'l')).create('/etc/passwd');
      await expectLater(huellaArbol(d.path), throwsA(isA<NoVerificado>()));
    });

    test('una ruta que se sale del componente no se da', () async {
      final g = gestor(c);
      await g.instalar('c');
      await expectLater(g.rutaVerificada('c', '../../etc/passwd'), throwsA(isA<NoVerificado>()));
      await expectLater(g.rutaVerificada('c', 'prog/../../fuera'), throwsA(isA<NoVerificado>()));
      await g.cerrar();
    });

    test('sin instalar no hay ruta', () async {
      final g = gestor(c);
      await expectLater(g.rutaVerificada('c', 'prog'), throwsA(isA<NoVerificado>()));
      await g.cerrar();
    });
  });

  group('empotrado', () {
    Componente conAsset(List<int> b, {String? huella}) => Componente(id: 'c', version: '1', licencias: '', archivos: [
          ArchivoComponente(
            origen: 'assets/x',
            sha256: huella ?? sha(b),
            tam: b.length,
            tipo: TipoArchivo.empotrado,
            destino: 'ayudante',
            tamInstalado: b.length,
          ),
        ]);

    test('se copia y queda ejecutable', () async {
      final rastro = p.join(t.path, 'rastro');
      final b = scriptConRastro(rastro);
      final g = gestor(conAsset(b), empotrado: (_) async => b);
      await g.instalar('c');
      expect(g.estado('c').fase, FaseComponente.listo, reason: '${g.estado('c').fallo}');
      await Process.run(await g.rutaVerificada('c', 'ayudante'), []);
      expect(await File(rastro).exists(), isTrue);
      await g.cerrar();
    });

    test('comprobar: si cambió con una actualización de SENUS, se copia solo', () async {
      final b1 = utf8.encode('#!/bin/sh\necho uno\n'), b2 = utf8.encode('#!/bin/sh\necho dos\n');
      final g = gestor(conAsset(b1), empotrado: (_) async => b1);
      await g.instalar('c');
      await g.cerrar();
      final g2 = gestor(conAsset(b2), empotrado: (_) async => b2);
      await g2.comprobar();
      expect(g2.estado('c').fase, FaseComponente.listo, reason: '${g2.estado('c').fallo}');
      expect(await File(await g2.rutaVerificada('c', 'ayudante')).readAsBytes(), b2);
      await g2.cerrar();
    });

    test('un asset que no casa no se copia', () async {
      final b = utf8.encode('x');
      final g = gestor(conAsset(b, huella: 'c' * 64), empotrado: (_) async => b);
      await g.instalar('c');
      expect(g.estado('c').fallo!.tipo, TipoFallo.huella);
      expect(await File(p.join(t.path, 'raiz', 'c-1', 'ayudante')).exists(), isFalse);
      await g.cerrar();
    });
  });

  group('estado y borrar', () {
    test('comprobar ve lo instalado en otra sesión', () async {
      final g = gestor(directo());
      await g.instalar('c');
      await g.cerrar();
      final g2 = gestor(directo());
      expect(g2.estado('c').fase, FaseComponente.ausente);
      await g2.comprobar();
      expect(g2.estado('c').fase, FaseComponente.listo);
      await g2.cerrar();
    });

    test('borrar quita el componente y lo bajado a medias', () async {
      final g = gestor(directo());
      await g.instalar('c');
      await g.borrar('c');
      expect(g.estado('c').fase, FaseComponente.ausente);
      expect(await Directory(p.join(t.path, 'raiz', 'c-1')).exists(), isFalse);
      await expectLater(g.rutaVerificada('c', 'modelo.bin'), throwsA(isA<NoVerificado>()));
      await g.cerrar();
    });

    test('ya instalado: instalar no baja nada', () async {
      final g = gestor(directo());
      await g.instalar('c');
      o.peticiones.clear();
      await g.instalar('c');
      expect(o.peticiones, isEmpty);
      expect(g.estado('c').fase, FaseComponente.listo);
      await g.cerrar();
    });
  });
}
