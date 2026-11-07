// Apoyo de las pruebas de lib/servicios: un servidor de descargas simulado y
// binarios falsos que dejan rastro de que se ejecutaron.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

String sha(List<int> b) => sha256.convert(b).toString();

/// Un origen de descargas de mentira, en 127.0.0.1. Va sobre un socket crudo para
/// poder cortar la conexión a mitad del cuerpo.
class OrigenSimulado {
  final ServerSocket _s;
  final Map<String, List<int>> ficheros = {};
  final List<(String, String?)> peticiones = []; // (ruta, Range)

  /// Corta la conexión tras servir hasta este byte del fichero, una vez por valor.
  final List<int> cortes = [];

  /// No entiende Range: siempre 200 desde el principio.
  bool sinRango = false;

  /// Responde 206 con un inicio equivocado.
  bool rangoMentiroso = false;

  /// Espera antes de seguir: para cancelar a mitad.
  Completer<void>? freno;
  int frenarEn = 0;

  /// Tantas peticiones reciben 403 antes de servir: una URL que aún no vale.
  int prohibidas = 0;

  /// Rutas que redirigen: origen -> destino.
  final Map<String, String> saltos = {};

  OrigenSimulado._(this._s) {
    _s.listen((c) => unawaited(_atender(c).catchError((Object _) {})));
  }

  static Future<OrigenSimulado> crear() async => OrigenSimulado._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));

  String url(String ruta) => 'http://127.0.0.1:${_s.port}/$ruta';

  Future<void> cerrar() => _s.close();

  Future<void> _atender(Socket c) async {
    final b0 = BytesBuilder();
    final it = StreamIterator<List<int>>(c.cast<List<int>>());
    while (!latin1.decode(b0.toBytes()).contains('\r\n\r\n')) {
      if (!await it.moveNext()) return;
      b0.add(it.current);
    }
    final lineas = latin1.decode(b0.toBytes()).split('\r\n');
    final ruta = lineas.first.split(' ')[1].substring(1);
    String? rango;
    for (final l in lineas) {
      if (l.toLowerCase().startsWith('range:')) rango = l.substring(6).trim();
    }
    peticiones.add((ruta, rango));
    void cab(String estado, List<String> extra) {
      c.add(latin1.encode('HTTP/1.1 $estado\r\nConnection: close\r\n${extra.map((x) => '$x\r\n').join()}\r\n'));
    }

    if (prohibidas > 0) {
      prohibidas--;
      cab('403 Forbidden', ['Content-Length: 0']);
      await c.flush();
      c.destroy();
      return;
    }
    final salto = saltos[ruta];
    if (salto != null) {
      cab('302 Found', ['Location: $salto', 'Content-Length: 0']);
      await c.flush();
      c.destroy();
      return;
    }
    final b = ficheros[ruta];
    if (b == null) {
      cab('404 Not Found', ['Content-Length: 0']);
      await c.flush();
      c.destroy();
      return;
    }
    var inicio = 0;
    var ultimo = b.length - 1; // un rango acotado (bytes=a-b) se respeta
    if (rango != null && !sinRango) {
      final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rango)!;
      inicio = int.parse(m.group(1)!);
      final hasta = int.tryParse(m.group(2)!);
      if (hasta != null && hasta < ultimo) ultimo = hasta;
      if (inicio >= b.length) {
        cab('416 Range Not Satisfiable', ['Content-Length: 0']);
        await c.flush();
        c.destroy();
        return;
      }
      final dicho = rangoMentiroso ? inicio + 1 : inicio;
      cab('206 Partial Content', ['Content-Range: bytes $dicho-$ultimo/${b.length}', 'Content-Length: ${ultimo + 1 - inicio}']);
    } else {
      cab('200 OK', ['Content-Length: ${b.length}']);
    }
    final corte = cortes.isEmpty ? null : cortes.removeAt(0);
    final fin = corte == null ? ultimo + 1 : corte.clamp(inicio, ultimo + 1);
    final f = freno;
    try {
      if (f != null && frenarEn > inicio && frenarEn < fin) {
        c.add(b.sublist(inicio, frenarEn));
        await c.flush();
        await f.future;
        c.add(b.sublist(frenarEn, fin));
      } else {
        c.add(b.sublist(inicio, fin));
      }
      await c.flush();
    } on Object {
      // el cliente ya se fue
    }
    // Cerrar sin más es lo que hace un corte: el cliente ve menos bytes de los dichos.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    c.destroy();
  }
}

/// Un zip con estos ficheros: nombre -> (contenido, modo).
List<int> hacerZip(Map<String, (List<int>, int)> f) {
  final a = Archive();
  f.forEach((n, v) {
    final x = ArchiveFile(n, v.$1.length, v.$1)..mode = v.$2;
    a.addFile(x);
  });
  return ZipEncoder().encode(a)!;
}

/// Crea un ejecutable de mentira que deja [rastro] al correr.
List<int> scriptConRastro(String rastro, {String resto = ''}) =>
    utf8.encode('#!/bin/sh\necho corrio >> "$rastro"\n$resto\n');

Future<Directory> carpetaTemporal() => Directory.systemTemp.createTemp('senus_h_');

/// Escribe un script ejecutable.
Future<String> ejecutable(Directory d, String nombre, String contenido) async {
  final r = p.join(d.path, nombre);
  await File(r).writeAsString(contenido);
  await Process.run('chmod', ['755', r]);
  return r;
}
