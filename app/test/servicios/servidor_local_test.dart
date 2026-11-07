// El servidor HTTP/1.0: la forma exacta en la que habla al teléfono y lo que rechaza.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:senus_app/servicios/servidor_local.dart';

/// Manda una petición cruda y devuelve todo lo que llega hasta el cierre.
Future<List<int>> crudo(int puerto, List<int> pet, {String host = '127.0.0.1'}) async {
  final s = await Socket.connect(host, puerto);
  s.add(pet);
  await s.flush();
  final b = BytesBuilder(copy: false);
  await s.forEach(b.add).timeout(const Duration(seconds: 5));
  s.destroy();
  return b.takeBytes();
}

void main() {
  late ServidorLocal s;
  late int puerto;

  setUp(() async {
    s = ServidorLocal(
      puerto: 0,
      nombre: 'prueba/1',
      manejador: (pet, res) async {
        if (pet.ruta == '/eco') {
          final n = int.parse(pet.cabecera('content-length') ?? '0');
          final b = await pet.leerCuerpo(n, const Duration(seconds: 5));
          await res.responder(200, b, tipo: 'application/octet-stream', extra: [('X-Largo', '$n')]);
        } else if (pet.ruta == '/flujo') {
          res.empezar(200, const [('Content-Type', 'audio/mpeg'), ('X-Duracion-Ms', '1000')]);
          await res.escribir(utf8.encode('uno'));
          await res.escribir(utf8.encode('dos'));
        } else {
          await res.responder(200, '${pet.metodo} ${pet.ruta} ${pet.consulta}');
        }
      },
    );
    await s.arrancar();
    puerto = s.puertoReal;
  });
  tearDown(() => s.parar());

  test('HTTP/1.0, cabeceras con su nombre exacto y sin trozos', () async {
    final r = latin1.decode(await crudo(puerto, latin1.encode('GET /flujo HTTP/1.1\r\nHost: 127.0.0.1:$puerto\r\n\r\n')));
    expect(r, startsWith('HTTP/1.0 200 OK\r\n'));
    expect(r, contains('\r\nX-Duracion-Ms: 1000\r\n'));
    expect(r, contains('\r\nContent-Type: audio/mpeg\r\n'));
    expect(r.toLowerCase(), isNot(contains('transfer-encoding')));
    expect(r.toLowerCase(), isNot(contains('content-length')));
    expect(r, endsWith('\r\n\r\nunodos'));
  });

  test('la respuesta acaba al cerrar y lleva Content-Length si se conoce', () async {
    final r = latin1.decode(await crudo(puerto, latin1.encode('GET /x?a=1&b=dos%20tres HTTP/1.0\r\n\r\n')));
    final cuerpo = r.substring(r.indexOf('\r\n\r\n') + 4);
    expect(cuerpo, 'GET /x {a: 1, b: dos tres}');
    expect(r, contains('Content-Length: ${cuerpo.length}\r\n'));
  });

  test('cuerpo binario entero y sin tocar, aunque llegue a trozos', () async {
    final b = List<int>.generate(200000, (i) => i * 7 & 255);
    final sock = await Socket.connect('127.0.0.1', puerto);
    sock.add(latin1.encode('POST /eco HTTP/1.1\r\nContent-Length: ${b.length}\r\n\r\n'));
    sock.add(b.sublist(0, 100));
    await sock.flush();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    sock.add(b.sublist(100));
    await sock.flush();
    final t = BytesBuilder(copy: false);
    await sock.forEach(t.add);
    final r = t.takeBytes();
    final i = latin1.decode(r).indexOf('\r\n\r\n') + 4;
    expect(r.sublist(i), b);
  });

  test('una cabecera puede partirse entre dos lecturas', () async {
    final sock = await Socket.connect('127.0.0.1', puerto);
    sock.add(latin1.encode('GET /parti'));
    await sock.flush();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    sock.add(latin1.encode('do HTTP/1.0\r'));
    await sock.flush();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    sock.add(latin1.encode('\n\r\n'));
    await sock.flush();
    final t = BytesBuilder(copy: false);
    await sock.forEach(t.add);
    expect(latin1.decode(t.takeBytes()), contains('GET /partido'));
  });

  group('lo que se rechaza', () {
    Future<String> pedir(String p) async => latin1.decode(await crudo(puerto, latin1.encode(p)));

    test('una página web: con Origin', () async {
      final r = await pedir('POST /eco HTTP/1.1\r\nOrigin: https://mala.example\r\nContent-Length: 0\r\n\r\n');
      expect(r, startsWith('HTTP/1.0 403'));
    });

    test('una página web: con Sec-Fetch-Site', () async {
      expect(await pedir('GET /x HTTP/1.1\r\nSec-Fetch-Site: cross-site\r\n\r\n'), startsWith('HTTP/1.0 403'));
    });

    test('DNS rebinding: un Host que no es local', () async {
      expect(await pedir('GET /x HTTP/1.1\r\nHost: mala.example:8580\r\n\r\n'), startsWith('HTTP/1.0 403'));
      expect(await pedir('GET /x HTTP/1.1\r\nHost: 127.0.0.1.mala.example\r\n\r\n'), startsWith('HTTP/1.0 403'));
    });

    test('los Host locales sí pasan', () async {
      for (final h in ['127.0.0.1:8580', 'localhost:8580', 'LOCALHOST', '[::1]:8580']) {
        expect(await pedir('GET /x HTTP/1.1\r\nHost: $h\r\n\r\n'), startsWith('HTTP/1.0 200'), reason: h);
      }
    });

    test('métodos que no son GET ni POST: 501', () async {
      expect(await pedir('PUT /x HTTP/1.1\r\n\r\n'), startsWith('HTTP/1.0 501'));
      expect(await pedir('HEAD /x HTTP/1.1\r\n\r\n'), startsWith('HTTP/1.0 501'));
    });

    test('mal formada: 400', () async {
      expect(await pedir('hola\r\n\r\n'), startsWith('HTTP/1.0 400'));
      expect(await pedir('GET /x HTTP/1.1\r\nsin dos puntos\r\n\r\n'), startsWith('HTTP/1.0 400'));
    });

    test('cabeceras sin fin: 400 y no se llena la memoria', () async {
      final r = await pedir('GET /x HTTP/1.1\r\nX: ${'a' * 70000}');
      expect(r, startsWith('HTTP/1.0 400'));
    });
  });

  test('solo escucha en el bucle local: por otra dirección del equipo no se llega', () async {
    final direcciones = await NetworkInterface.list(type: InternetAddressType.IPv4);
    final fuera = direcciones.expand((i) => i.addresses).where((a) => !a.isLoopback).toList();
    for (final a in fuera) {
      await expectLater(
        Socket.connect(a, puerto, timeout: const Duration(seconds: 1)),
        throwsA(isA<SocketException>()),
        reason: a.address,
      );
    }
  });

  test('puerto ocupado: lanza, no se queda a medias', () async {
    final otro = ServidorLocal(puerto: puerto, nombre: 'x', manejador: (_, __) async {});
    await expectLater(otro.arrancar(), throwsA(isA<SocketException>()));
    expect(otro.escuchando, isFalse);
  });

  test('parar corta lo que siga vivo y libera el puerto', () async {
    final sock = await Socket.connect('127.0.0.1', puerto);
    sock.add(latin1.encode('GET /sin-acabar'));
    await sock.flush();
    await s.parar();
    // Cortada: con datos sin leer el sistema manda un reset, y si no, un cierre normal.
    // Las dos valen; lo que no vale es que siga abierta.
    try {
      await sock.drain<void>().timeout(const Duration(seconds: 2));
    } on SocketException {
      // reset
    }
    final nuevo = ServidorLocal(puerto: puerto, nombre: 'x', manejador: (_, __) async {});
    await nuevo.arrancar();
    await nuevo.parar();
  });
}
