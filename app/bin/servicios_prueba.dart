// Los servicios locales sin interfaz, para probarlos de verdad en la Mac:
//
//   dart run bin/servicios_prueba.dart --raiz DIR [--dictado N] [--musica N] [--instalar]
//
// DIR es la carpeta de componentes. Con --instalar los baja si faltan. El ayudante
// se lee de assets/servicios/macos. Se para con una línea por stdin o al cerrarlo.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:senus_app/servicios/catalogo_componentes.dart';
import 'package:senus_app/servicios/gestor_componentes.dart';
import 'package:senus_app/servicios/letra_telefono.dart';
import 'package:senus_app/servicios/servicios_locales.dart';

Future<void> main(List<String> a) async {
  String? valor(String n) {
    final i = a.indexOf(n);
    return i >= 0 && i + 1 < a.length ? a[i + 1] : null;
  }

  final raiz = valor('--raiz');
  if (raiz == null) {
    stderr.writeln('falta --raiz');
    exit(2);
  }
  final gestor = GestorComponentes(
    raiz: Directory(raiz),
    catalogo: catalogoDePlataforma(),
    leerEmpotrado: (asset) => File(asset).readAsBytes(),
  );
  gestor.cambios.listen((e) {
    final f = e.fallo;
    stdout.writeln('${e.id}: ${e.fase.name} ${e.recibidos}/${e.total}${f == null ? '' : ' $f'}');
  });
  final s = ServiciosLocales(
    gestor: gestor,
    letra: LetraTelefono.desdeTabla(File(assetLetra).readAsBytesSync()),
    puertoDeDictado: int.parse(valor('--dictado') ?? '$puertoDePrueba'),
    puertoDeMusica: int.parse(valor('--musica') ?? '${puertoDePrueba - 1}'),
    colaDictado: int.parse(valor('--cola') ?? '4'),
    registro: stdout.writeln,
  );
  if (a.contains('--instalar')) {
    await gestor.comprobar();
    for (final c in gestor.catalogo) {
      await gestor.instalar(c.id);
    }
  }
  await s.arrancar();
  stdout.writeln('escuchando: dictado ${s.dictadoEscuchando} música ${s.musicaEscuchando}');
  await stdin.transform(utf8.decoder).first.catchError((Object _) => '');
  await s.parar();
  await gestor.cerrar();
  exit(0);
}

const puertoDePrueba = 58581;
