// El catálogo fijado en el código y los assets de los que depende.

import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:senus_app/servicios/catalogo_componentes.dart';
import 'package:senus_app/servicios/componentes.dart';
import 'package:senus_app/servicios/letra_telefono.dart';

void main() {
  const todos = [dictadoMacos, musicaMacos, musicaWindows];

  test('cada huella es un sha256 de verdad y cada zip tiene la de su árbol', () {
    final hex = RegExp(r'^[0-9a-f]{64}$');
    for (final c in todos) {
      for (final a in c.archivos) {
        expect(a.sha256, matches(hex), reason: a.destino);
        expect(a.tam, greaterThan(0));
        if (a.tipo == TipoArchivo.zip) expect(a.arbolSha256, matches(hex), reason: a.destino);
      }
    }
  });

  test('las fuentes son las oficiales, con https y versión fijada', () {
    const hosts = {'huggingface.co', 'github.com', 'ffmpeg.martin-riedl.de', 'www.gyan.dev'};
    for (final c in todos) {
      for (final a in c.archivos.where((a) => a.tipo != TipoArchivo.empotrado)) {
        final u = Uri.parse(a.origen);
        expect(u.scheme, 'https');
        expect(hosts, contains(u.host));
        expect(a.origen, isNot(contains('latest')));
        expect(a.origen, isNot(contains('/main/')));
        expect(a.origen.toLowerCase(), isNot(contains('semakers')));
        expect(a.origen.toLowerCase(), isNot(contains('nairda')));
      }
    }
  });

  test('el ayudante empotrado casa con lo fijado en el código', () {
    final b = File(assetAyudanteMacos).readAsBytesSync();
    expect(sha256.convert(b).toString(), shaAyudanteMacos);
    expect(b.length, tamAyudanteMacos);
  });

  // Lo que usa la app de verdad: si pubspec.yaml no los declarara, esto caería.
  test('la app los encuentra por rootBundle, no solo en el disco', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final ayudante = await rootBundle.load(assetAyudanteMacos);
    expect(sha256.convert(ayudante.buffer.asUint8List(ayudante.offsetInBytes, ayudante.lengthInBytes)).toString(), shaAyudanteMacos);
    final letra = await rootBundle.load(assetLetra);
    expect(LetraTelefono.desdeTabla(letra.buffer.asUint8List(letra.offsetInBytes, letra.lengthInBytes)).para('Сплин'), 'Splin');
    expect(await rootBundle.loadString('assets/servicios/AVISOS_TERCEROS.txt'), contains('MIT License'));
  });

  test('los tamaños que se enseñan son los medidos', () {
    expect(dictadoMacos.bytesDescarga, 265349705);
    expect(musicaMacos.bytesDescarga, 121331778);
    expect(musicaWindows.bytesDescarga, 23885596 + 42917472 + 114768076);
  });

  test('la plataforma: Mac con chip de Apple todo; Windows x64 Música y el dictado lo dice; Intel lo dice', () {
    expect(bloqueoDePlataforma(abi: Abi.macosArm64), isNull);
    expect(bloqueoDePlataforma(abi: Abi.windowsX64), isNull);
    expect(bloqueoDePlataforma(abi: Abi.windowsArm64)!.porque, contains('x64'));
    expect(bloqueoDePlataforma(abi: Abi.macosX64)!.porque, contains('chip de Apple'));
    expect(bloqueoDeComponente(idMusica, abi: Abi.windowsX64), isNull);
    expect(bloqueoDeComponente(idDictado, abi: Abi.windowsX64)!.porque, contains('dictado'));
    expect(bloqueoDeComponente(idDictado, abi: Abi.macosArm64), isNull);
    expect(catalogoDePlataforma(abi: Abi.windowsX64), [musicaWindows]);
    expect(catalogoDePlataforma(abi: Abi.macosArm64), [dictadoMacos, musicaMacos]);
    expect(catalogoDePlataforma(abi: Abi.linuxArm64), isEmpty);
  });

  test('las rutas de Música de cada plataforma caen dentro de un zip de su componente', () {
    for (final (c, r) in [(musicaMacos, rutasMusica(windows: false)), (musicaWindows, rutasMusica(windows: true))]) {
      final destinos = c.archivos.map((a) => a.destino).toSet();
      for (final ruta in [r.ytDlp, r.deno, r.ffmpeg]) {
        expect(destinos, contains(ruta.split('/').first), reason: ruta);
      }
    }
    expect(rutasMusica(windows: true).ffmpeg, endsWith('/bin/ffmpeg.exe'));
  });
}
