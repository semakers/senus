// Todo junto y sin dobles entre medias: origen simulado -> gestor -> rutas verificadas
// -> procesos de verdad (binarios falsos) -> puerto local.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:senus_app/servicios/catalogo_componentes.dart';
import 'package:senus_app/servicios/componentes.dart';
import 'package:senus_app/servicios/gestor_componentes.dart';
import 'package:senus_app/servicios/letra_telefono.dart';
import 'package:senus_app/servicios/servicios_locales.dart';

import 'apoyo_servicios.dart';
import 'catalogo_musica_test.dart' show RedGuardada;

ArchivoComponente directo(OrigenSimulado o, String nombre, List<int> b) {
  o.ficheros[nombre] = b;
  return ArchivoComponente(
    origen: o.url(nombre),
    sha256: sha(b),
    tam: b.length,
    tipo: TipoArchivo.directo,
    destino: nombre,
    tamInstalado: b.length,
  );
}

Future<ArchivoComponente> enZip(OrigenSimulado o, Directory t, String carpeta, String nombre, List<int> b) async {
  final zip = hacerZip({nombre: (b, 0x1ED)});
  o.ficheros['$carpeta.zip'] = zip;
  final d = await Directory(p.join(t.path, 'modelo_$carpeta')).create();
  await File(p.join(d.path, nombre)).writeAsBytes(b);
  final arbol = await huellaArbol(d.path);
  await d.delete(recursive: true);
  return ArchivoComponente(
    origen: o.url('$carpeta.zip'),
    sha256: sha(zip),
    tam: zip.length,
    tipo: TipoArchivo.zip,
    destino: carpeta,
    arbolSha256: arbol,
    tamInstalado: b.length,
  );
}

Future<(int, String)> pedir(int puerto, String pet, [List<int> cuerpo = const []]) async {
  final s = await Socket.connect('127.0.0.1', puerto);
  s.add(latin1.encode(pet));
  s.add(cuerpo);
  await s.flush();
  final b = BytesBuilder(copy: false);
  await s.forEach(b.add).timeout(const Duration(seconds: 15));
  s.destroy();
  final r = utf8.decode(b.takeBytes(), allowMalformed: true);
  return (int.parse(r.split(' ')[1]), r.substring(r.indexOf('\r\n\r\n') + 4));
}

void main() {
  late Directory t;
  late OrigenSimulado o;
  late GestorComponentes g;
  late ServiciosLocales s;
  late String rastroAyudante, rastroFfmpeg;
  final letra = LetraTelefono.desdeTabla(File('assets/servicios/letra_telefono.bin').readAsBytesSync());

  setUp(() async {
    t = await carpetaTemporal();
    o = await OrigenSimulado.crear();
    rastroAyudante = p.join(t.path, 'rastro_ayudante');
    rastroFfmpeg = p.join(t.path, 'rastro_ffmpeg');
    final ayudante = utf8.encode('''#!/usr/bin/python3
import json, struct, sys, os
open("$rastroAyudante", "a").write("corrio\\n")
assert sys.argv[1] == "--modelo" and open(sys.argv[2]).read() == "modelo" and sys.argv[3] == "--vad"
print(json.dumps({"ok": True, "listo": True, "version": "falsa", "carga_ms": 1}), flush=True)
i = sys.stdin.buffer
while True:
    c = i.read(12)
    if len(c) < 12 or c[2] == 0: os._exit(0)
    n = struct.unpack("<I", c[8:12])[0]
    i.read(4 * n)
    if c[2] == 1: print(json.dumps({"ok": True, "tramos": [[0, 900]]}), flush=True)
    else: print(json.dumps({"ok": True, "segmentos": [{"t": "Dictado de verdad.", "ns": 0.1, "lp": -0.2}]}), flush=True)
''');
    final dictado = Componente(id: idDictado, version: 't', licencias: '', archivos: [
      directo(o, modeloDictado, utf8.encode('modelo')),
      directo(o, vadDictado, utf8.encode('vad')),
      ArchivoComponente(
        origen: 'asset',
        sha256: sha(ayudante),
        tam: ayudante.length,
        tipo: TipoArchivo.empotrado,
        destino: ayudanteDictado,
        tamInstalado: ayudante.length,
      ),
    ]);
    o.ficheros['audio'] = List.filled(1000, 65);
    final yt = utf8.encode('''#!/bin/sh
echo '{"url":"${o.url('audio')}","duration":6,"http_headers":{}}'
''');
    final ff = utf8.encode('''#!/bin/sh
echo corrio >> "$rastroFfmpeg"
cat > /dev/null
printf '\\377\\373\\220\\000'
''');
    final musica = Componente(id: idMusica, version: 't', licencias: '', archivos: [
      await enZip(o, t, carpetaYtDlp, 'yt-dlp_macos', yt),
      await enZip(o, t, carpetaDeno, 'deno', utf8.encode('#!/bin/sh\n')),
      await enZip(o, t, carpetaFfmpeg, 'ffmpeg', ff),
    ]);
    g = GestorComponentes(
      raiz: Directory(p.join(t.path, 'raiz')),
      catalogo: [dictado, musica],
      espacioLibre: (_) async => 1 << 40,
      leerEmpotrado: (_) async => ayudante,
      permitirHttp: true,
    );
    s = ServiciosLocales(gestor: g, letra: letra, puertoDeDictado: 0, puertoDeMusica: 0, redCatalogo: RedGuardada());
  });

  tearDown(() async {
    await s.parar();
    await o.cerrar();
    await t.delete(recursive: true);
  });

  Future<void> hasta(bool Function() c) async {
    for (var i = 0; i < 300 && !c(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(c(), isTrue);
  }

  test('sin instalar no escucha nada', () async {
    await s.arrancar();
    expect(s.dictadoEscuchando, isFalse);
    expect(s.musicaEscuchando, isFalse);
  });

  test('instalar el dictado: escucha solo, y el POST del teléfono llega al ayudante verificado', () async {
    await s.arrancar();
    await g.instalar(idDictado);
    await hasta(() => s.dictadoEscuchando);
    expect(s.musicaEscuchando, isFalse);
    final puerto = s.dictado!.servidor.puertoReal;
    final pcm = Uint8List(16000);
    for (var i = 0; i < pcm.length; i += 2) {
      pcm[i + 1] = i % 32 < 16 ? 10 : 245;
    }
    final (e, texto) = await pedir(
        puerto, 'POST /dictar?hz=8000&idioma=es&max=500 HTTP/1.1\r\nHost: 127.0.0.1:$puerto\r\nContent-Length: ${pcm.length}\r\n\r\n', pcm);
    expect(e, 200);
    expect(texto, 'Dictado de verdad.');
    expect(await File(rastroAyudante).exists(), isTrue);
  });

  test('borrar: deja de escuchar', () async {
    await s.arrancar();
    await g.instalar(idDictado);
    await hasta(() => s.dictadoEscuchando);
    final puerto = s.dictado!.servidor.puertoReal;
    await g.borrar(idDictado);
    await hasta(() => !s.dictadoEscuchando);
    await expectLater(Socket.connect('127.0.0.1', puerto), throwsA(isA<SocketException>()));
  });

  test('la música de punta a punta, con binarios verificados', () async {
    await s.arrancar();
    await g.instalar(idMusica);
    await hasta(() => s.musicaEscuchando);
    final puerto = s.musica!.servidor.puertoReal;
    final (e, b) = await pedir(puerto, 'GET /buscar?q=carefree HTTP/1.1\r\nHost: 127.0.0.1:$puerto\r\n\r\n');
    expect(e, 200);
    expect(b, startsWith('W5MUS 1\t10\t1\n'));
    final (e2, _) = await pedir(puerto, 'GET /pista/abcdefghijk.mp3 HTTP/1.1\r\nHost: 127.0.0.1:$puerto\r\n\r\n');
    expect(e2, 200);
    expect(await File(rastroFfmpeg).exists(), isTrue);
  });

  for (final (nombre, relativa) in const [('yt-dlp', rutaYtDlp), ('deno', rutaDeno)]) {
    test('$nombre tocado con SENUS abierta: 502 y ffmpeg ni arranca', () async {
      await s.arrancar();
      await g.instalar(idMusica);
      await hasta(() => s.musicaEscuchando);
      final puerto = s.musica!.servidor.puertoReal;
      final r = await g.rutaVerificada(idMusica, relativa);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await File(r).writeAsString('\n# tocado\n', mode: FileMode.append, flush: true);
      final (e, _) = await pedir(puerto, 'GET /pista/abcdefghijk.mp3 HTTP/1.1\r\nHost: 127.0.0.1:$puerto\r\n\r\n');
      expect(e, 502);
      expect(await File(rastroFfmpeg).exists(), isFalse);
    });
  }

  test('ffmpeg tocado con SENUS abierta: 502 y NO corre', () async {
    await s.arrancar();
    await g.instalar(idMusica);
    await hasta(() => s.musicaEscuchando);
    final puerto = s.musica!.servidor.puertoReal;
    final r = await g.rutaVerificada(idMusica, rutaFfmpeg);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await File(r).writeAsString('#!/bin/sh\necho corrio >> "$rastroFfmpeg"\nsleep 30\n', flush: true);
    final (e, _) = await pedir(puerto, 'GET /pista/abcdefghijk.mp3 HTTP/1.1\r\nHost: 127.0.0.1:$puerto\r\n\r\n');
    expect(e, 502);
    expect(await File(rastroFfmpeg).exists(), isFalse);
  });

  for (final (nombre, relativa) in const [('ayudante', ayudanteDictado), ('modelo', modeloDictado), ('VAD', vadDictado)]) {
    test('$nombre tocado con SENUS abierta: 500 y el ayudante NO arranca', () async {
      await s.arrancar();
      await g.instalar(idDictado);
      await hasta(() => s.dictadoEscuchando);
      // El precalentado corre el ayudante una vez y lo suelta.
      await hasta(() => File(rastroAyudante).existsSync());
      await hasta(() => s.dictado!.motor.descripcion == 'en reposo');
      final veces = File(rastroAyudante).readAsLinesSync().length;
      final ruta = await g.rutaVerificada(idDictado, relativa);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // Un comentario al final: sigue siendo ejecutable, así que si esto corriera se
      // vería. Romperlo haría pasar la prueba por el motivo equivocado.
      await File(ruta).writeAsString('\n# tocado\n', mode: FileMode.append, flush: true);
      final puerto = s.dictado!.servidor.puertoReal;
      final pcm = Uint8List(16000);
      for (var i = 0; i < pcm.length; i += 2) {
        pcm[i + 1] = i % 32 < 16 ? 10 : 245;
      }
      final (e, _) = await pedir(puerto,
          'POST /dictar?hz=8000&idioma=es HTTP/1.1\r\nHost: 127.0.0.1:$puerto\r\nContent-Length: ${pcm.length}\r\n\r\n', pcm);
      expect(e, 500);
      expect(File(rastroAyudante).readAsLinesSync().length, veces, reason: 'no volvió a correr');
    });
  }

  test('ayudante tocado entre sesiones: se repone del asset; modelo tocado: no arranca', () async {
    await s.arrancar();
    await g.instalar(idDictado);
    await hasta(() => s.dictadoEscuchando);
    await s.parar();
    final modelo = await g.rutaVerificada(idDictado, modeloDictado);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await File(modelo).writeAsString('mODELO', flush: true);
    final antes = await File(rastroAyudante).exists();
    final g2 = GestorComponentes(
      raiz: g.raiz,
      catalogo: g.catalogo,
      espacioLibre: (_) async => 1 << 40,
      leerEmpotrado: g.leerEmpotrado,
      permitirHttp: true,
    );
    final s2 = ServiciosLocales(gestor: g2, letra: letra, puertoDeDictado: 0, puertoDeMusica: 0);
    await s2.arrancar();
    expect(g2.estado(idDictado).fase, FaseComponente.fallo);
    expect(s2.dictadoEscuchando, isFalse);
    await s2.parar();
    expect(antes, await File(rastroAyudante).exists());
  });

  test('el puerto ocupado: lo dice y SENUS sigue', () async {
    final ocupa = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    s = ServiciosLocales(gestor: g, letra: letra, puertoDeDictado: ocupa.port, puertoDeMusica: 0);
    await s.arrancar();
    await g.instalar(idDictado);
    await hasta(() => s.problemaDictado != null);
    expect(s.problemaDictado, contains('${ocupa.port}'));
    expect(s.dictadoEscuchando, isFalse);
    await ocupa.close();
  });

  test('parar: deja de escuchar', () async {
    await s.arrancar();
    await g.instalar(idDictado);
    await hasta(() => s.dictadoEscuchando);
    final puerto = s.dictado!.servidor.puertoReal;
    await s.parar();
    await expectLater(Socket.connect('127.0.0.1', puerto), throwsA(isA<SocketException>()));
  });
}
