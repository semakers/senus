// El núcleo W5RED contra un teléfono en Dart y servidores de verdad en 127.0.0.1.
// Lo que `prueba_puente.py` no toca: lo que manda de verdad cada byte al servidor,
// los lotes, y el daño posible (destinos, tramas malas, cortes).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:senus_app/conexion/cliente_http.dart';
import 'package:senus_app/conexion/destinos.dart';
import 'package:senus_app/conexion/puerta_tcp.dart';
import 'package:senus_app/conexion/w5red_protocolo.dart';
import 'package:senus_app/conexion/w5red_sesion.dart';

import 'apoyo/puente_falso.dart';

const dejarLocal = PoliticaDestinos(permitirLocal: true);

class Banco {
  final TransporteMemoria t = TransporteMemoria();
  late final Sesion s;
  final List<String> log = [];
  late final Future<void> fin;

  Banco({
    PoliticaDestinos politica = dejarLocal,
    Duration plazoHola = const Duration(seconds: 15),
  }) {
    s = Sesion(t, log: log.add, politica: politica, plazoHola: plazoHola);
    fin = s.correr();
  }

  ClienteW5 get c => t.cliente;
}

Future<Banco> saludado({PoliticaDestinos politica = dejarLocal}) async {
  final b = Banco(politica: politica);
  await b.c.saludar();
  return b;
}

/// Un servidor que contesta [respuesta] (bytes crudos) y guarda lo que le pidieron.
class ServidorCrudo {
  late final ServerSocket srv;
  final BytesBuilder pedido = BytesBuilder();
  final List<int> respuesta;
  final bool cerrarAlAcabar;
  final Completer<void> leida = Completer();

  ServidorCrudo(this.respuesta, {this.cerrarAlAcabar = true});

  int get puerto => srv.port;
  String get textoPedido => latin1.decode(pedido.toBytes());

  Future<void> arrancar() async {
    srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    srv.listen((s) {
      s.listen((d) {
        pedido.add(d);
        if (leida.isCompleted) return;
        if (!textoPedido.contains('\r\n\r\n')) return;
        leida.complete();
        s.add(respuesta);
        if (cerrarAlAcabar) {
          s.flush().then((_) => s.destroy());
        }
      }, onError: (_) {}, onDone: () {});
    });
  }
}

Future<ServidorCrudo> crudo(String r, {bool cerrar = true}) async {
  final s = ServidorCrudo(latin1.encode(r), cerrarAlAcabar: cerrar);
  await s.arrancar();
  return s;
}

Future<HttpServer> web(void Function(HttpRequest) f) async {
  final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  s.listen(f);
  return s;
}

/// Eco TCP.
Future<ServerSocket> eco() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  s.listen((c) {
    c.listen(c.add, onDone: c.close, onError: (_) {});
  });
  return s;
}

Future<void> pausa([int ms = 60]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  group('tramas', () {
    test('la cabecera, little-endian', () {
      expect(trama(tDatos, 3, [9, 8]), [0x14, 3, 2, 0, 9, 8]);
      final grande = trama(tDatos, 1, Uint8List(0x1234));
      expect(grande.sublist(2, 4), [0x34, 0x12]);
    });

    test('una trama partida byte a byte sale entera, y dos juntas salen dos', () {
      final c = CortadorTramas();
      final b = BytesBuilder()
        ..add(trama(tPing, 0, [1, 2, 3]))
        ..add(trama(tPong, 0));
      final d = b.toBytes();
      final out = <Trama>[];
      for (final x in d) {
        c.anadir(Uint8List.fromList([x]));
        final t = c.siguiente();
        if (t != null) out.add(t);
      }
      expect(out.map((t) => t.tipo), [tPing, tPong]);
      expect(out.first.carga, [1, 2, 3]);
      expect(c.siguiente(), isNull);
    });

    test('cadenas sin terminar son error de protocolo', () {
      expect(() => cadenasW5(Uint8List.fromList([65, 66]), 1),
          throwsA(isA<ErrorProtocolo>()));
      final (l, resto) = cadenasW5(Uint8List.fromList([65, 0, 66, 0, 9]), 2);
      expect(l, ['A', 'B']);
      expect(resto, [9]);
    });
  });

  group('HOLA', () {
    test('carga y canales: el mínimo de los dos, y el teléfono empieza', () async {
      final b = Banco();
      final r = await b.c.saludar(carga: 2048, canales: 4);
      final v = ByteData.sublistView(r.carga);
      expect(r.carga.sublist(0, 5), magiaW5);
      expect(r.carga[5], 1);
      expect(v.getUint16(6, Endian.little), 2048);
      expect(r.carga[8], 4);
      expect(utf8.decode(r.carga.sublist(9)), nombrePuenteW5);
      expect(b.s.cargaMax, 2048);
      expect(b.s.cliente, 'prueba');
    });

    test('el puente pone tope: 4096 B y 8 canales', () async {
      final b = Banco();
      await b.c.saludar(carga: 60000, canales: 200);
      expect(b.s.cargaMax, 4096);
      expect(b.s.canalesMax, 8);
    });

    test('nada sale antes del HOLA_OK', () async {
      final b = Banco();
      await pausa();
      expect(b.c.vistas, isEmpty);
    });

    test('otra versión: ADIOS PROTOCOLO y corte', () async {
      final b = Banco();
      b.c.manda(tHola, 0, b.c.hola(version: 2));
      final a = await b.c.espera(0, tAdios);
      expect(a.carga[0], cProtocolo);
      await b.fin;
      expect(b.t.cerrado, isTrue);
    });

    test('otra cosa que no sea HOLA: ADIOS y corte', () async {
      final b = Banco();
      b.c.manda(tPing, 0, [1]);
      final a = await b.c.espera(0, tAdios);
      expect(a.carga[0], cProtocolo);
      await b.fin;
    });

    test('si no saluda, se corta y no se queda el enlace colgado', () async {
      final b = Banco(plazoHola: const Duration(milliseconds: 50));
      await b.fin;
      expect(b.t.cerrado, isTrue);
      expect(b.s.viva, isFalse);
    });
  });

  group('control', () {
    test('PING: PONG con su carga, 64 B como mucho', () async {
      final b = await saludado();
      b.c.manda(tPing, 0, List.filled(100, 7));
      final r = await b.c.espera(0, tPong);
      expect(r.carga.length, 64);
    });

    test('ADIOS del teléfono corta la sesión y aborta los canales', () async {
      final b = await saludado();
      final e = await eco();
      b.c.abrirTcp(1, '127.0.0.1', e.port);
      await b.c.espera(1, tListo);
      b.c.manda(tAdios, 0, [cBien, 0]);
      await b.fin;
      expect(b.s.canales, isEmpty);
      await e.close();
    });

    test('tipo desconocido en el canal 0 o en uno abierto: ADIOS', () async {
      final b = await saludado();
      b.c.manda(0x7F, 0);
      expect((await b.c.espera(0, tAdios)).carga[0], cProtocolo);
      await b.fin;

      final b2 = await saludado();
      final e = await eco();
      b2.c.abrirTcp(1, '127.0.0.1', e.port);
      await b2.c.espera(1, tListo);
      b2.c.manda(0x7F, 1);
      expect((await b2.c.espera(0, tAdios)).carga[0], cProtocolo);
      await b2.fin;
      await e.close();
    });

    test('una trama para un canal cerrado se ignora', () async {
      final b = await saludado();
      b.c.manda(tDatos, 3, [1, 2]);
      b.c.manda(tVentana, 3, u32le(10));
      b.c.manda(tFin, 3);
      b.c.manda(tPing, 0, [1]);
      await b.c.espera(0, tPong);
      expect(b.s.viva, isTrue);
    });

    test('una trama más larga que lo acordado: ADIOS', () async {
      final b = Banco();
      await b.c.saludar(carga: 100);
      b.c.manda(tPing, 0, Uint8List(101));
      expect((await b.c.espera(0, tAdios)).carga[0], cProtocolo);
      await b.fin;
    });

    test('ABRE corto o sin cadena: ADIOS', () async {
      final b = await saludado();
      b.c.manda(tAbreHttp, 1, [0, 0, 0]);
      expect((await b.c.espera(0, tAdios)).carga[0], cProtocolo);
      await b.fin;

      final b2 = await saludado();
      b2.c.manda(tAbreHttp, 1, [...u32le(100), 0, 0, 65, 66]);
      expect((await b2.c.espera(0, tAdios)).carga[0], cProtocolo);
      await b2.fin;
    });

    test('canal ocupado o fuera de rango: CIERRA DEMASIADOS', () async {
      final b = await saludado();
      final e = await eco();
      b.c.abrirTcp(1, '127.0.0.1', e.port);
      await b.c.espera(1, tListo);
      b.c.abrirTcp(1, '127.0.0.1', e.port);
      expect((await b.c.espera(1, tCierra)).carga[0], cDemasiados);
      b.c.abrirTcp(5, '127.0.0.1', e.port); // acordó 4
      expect((await b.c.espera(5, tCierra)).carga[0], cDemasiados);
      await e.close();
    });

    test('si el enlace falla al escribir, se acaba la sesión', () async {
      final b = await saludado();
      b.t.roto = true;
      b.c.manda(tPing, 0, [1]);
      await b.fin;
      expect(b.s.viva, isFalse);
      expect(b.log.join(), contains('no se pudo mandar'));
    });

    test('al cortarse la sesión, el socket del canal se cierra', () async {
      final b = await saludado();
      final srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final cerrado = Completer<void>();
      srv.listen((c) {
        c.listen((_) {}, onDone: cerrado.complete, onError: (_) {
          if (!cerrado.isCompleted) cerrado.complete();
        });
      });
      b.c.abrirTcp(1, '127.0.0.1', srv.port);
      await b.c.espera(1, tListo);
      await b.t.corte();
      await cerrado.future.timeout(const Duration(seconds: 3));
      await srv.close();
    });
  });

  group('ventanas y lotes', () {
    test('nunca se manda más de la ventana hasta que el teléfono la abre', () async {
      final b = await saludado();
      final d = Uint8List(100000);
      final w = await web((r) {
        r.response.contentLength = d.length;
        r.response.add(d);
        r.response.close();
      });
      b.c.abrirHttp(1, 'GET', 'http://127.0.0.1:${w.port}/', ventana: 8192);
      await b.c.espera(1, tListo);
      await b.c.espera(1, tRespuesta);
      var n = 0;
      while (n < 8192) {
        final t = await b.c.siguiente(1);
        expect(t.tipo, tDatos);
        n += t.carga.length;
      }
      expect(n, 8192);
      await pausa(120);
      expect(b.c.vistas.where((t) => t.canal == 1 && t.tipo == tDatos).fold<int>(
          0, (a, t) => a + t.carga.length), 8192, reason: 'sin VENTANA no sigue');
      b.c.manda(tVentana, 1, u32le(100));
      final t = await b.c.siguiente(1);
      expect(t.carga.length, 100);
      await w.close(force: true);
    });

    test('hasta 16 KB en una sola escritura, en DATOS de la carga acordada', () async {
      final b = await saludado();
      final d = Uint8List(200000);
      final w = await web((r) {
        r.response.contentLength = d.length;
        r.response.add(d);
        r.response.close();
      });
      b.t.escrituras.clear();
      b.c.abrirHttp(1, 'GET', 'http://127.0.0.1:${w.port}/');
      final r = await b.c.respuesta(1);
      expect(r.cuerpo.length, d.length);
      expect(r.datosMax, 2048);
      final mayor = b.t.escrituras.reduce((a, x) => a > x ? a : x);
      expect(mayor, greaterThanOrEqualTo(16 << 10),
          reason: 'una escritura por DATOS deja tramas RFCOMM a medias');
      expect(mayor, lessThan(32 << 10));
      await w.close(force: true);
    });

    test('un enlace lento frena: no se acumulan lotes en la cola', () async {
      final b = await saludado();
      final d = Uint8List(300000);
      final w = await web((r) {
        r.response.contentLength = d.length;
        r.response.add(d);
        r.response.close();
      });
      var vueltas = 0;
      b.t.freno = () async {
        vueltas++;
        await pausa(5);
      };
      b.c.abrirHttp(1, 'GET', 'http://127.0.0.1:${w.port}/');
      await b.c.respuesta(1);
      expect(vueltas, greaterThan(15));
      await w.close(force: true);
    });

    test('una ráfaga del teléfono no provoca una VENTANA por DATOS', () async {
      final b = await saludado();
      final e = await eco();
      b.c.abrirTcp(1, '127.0.0.1', e.port);
      await b.c.espera(1, tListo);
      const total = 90000;
      for (var i = 0; i < total; i += 2000) {
        b.c.manda(tDatos, 1, Uint8List(2000));
      }
      var n = 0;
      while (n < total) {
        n += (await b.c.espera(1, tDatos)).carga.length;
      }
      await pausa(100);
      final vs = b.c.vistas.where((t) => t.canal == 1 && t.tipo == tVentana);
      final suma = vs.fold<int>(0, (a, t) => a + leerU32(t.carga, 0));
      expect(suma, total, reason: 'al vaciarse la cola se devuelve lo que falte');
      expect(vs.length, lessThanOrEqualTo(8),
          reason: 'una por DATOS es la lentitud vieja: tramas que compiten');
      await e.close();
    });

    test('un cuerpo HTTP se devuelve de 32 en 32 KB', () async {
      final b = await saludado();
      final w = await web((r) async {
        await r.drain<void>();
        await r.response.close();
      });
      b.c.abrirHttp(1, 'POST', 'http://127.0.0.1:${w.port}/', banderas: bCuerpo);
      await b.c.espera(1, tListo);
      for (var i = 0; i < 70000; i += 2000) {
        b.c.manda(tDatos, 1, Uint8List(2000));
      }
      b.c.manda(tFin, 1);
      await b.c.respuesta(1);
      final vs = b.c.vistas.where((t) => t.canal == 1 && t.tipo == tVentana);
      expect(vs.map((t) => leerU32(t.carga, 0)), [34000, 34000],
          reason: 'la primera vez que pasa de 32 KB (32768 B), y no antes');
      await w.close(force: true);
    });

    test('TCP_NODELAY en lo que se conecta', () async {
      final e = await eco();
      final s = await conectarA(
          [InternetAddress.loopbackIPv4], e.port, const Duration(seconds: 2));
      final v = s.getRawOption(
          RawSocketOption(RawSocketOption.levelTcp, 1 /* TCP_NODELAY */, Uint8List(4)));
      expect(ByteData.sublistView(v).getUint32(0, Endian.host), isNot(0));
      s.destroy();
      await e.close();
    });
  });

  group('HTTP: lo que recibe el servidor', () {
    test('cabeceras de urllib, Host con su puerto y Connection: close', () async {
      final b = await saludado();
      final s = await crudo('HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n');
      b.c.abrirHttp(1, 'get', 'http://127.0.0.1:${s.puerto}/a%20b/?x=%7e1#frag');
      await b.c.respuesta(1);
      final p = s.textoPedido;
      expect(p, startsWith('GET /a%20b/?x=%7e1 HTTP/1.1\r\n'), reason: 'tal cual la app');
      expect(p, contains('Host: 127.0.0.1:${s.puerto}\r\n'));
      expect(p, contains('Accept-Encoding: identity\r\n'));
      expect(p, contains('User-Agent: $agenteW5\r\n'));
      expect(p, contains('Connection: close\r\n'));
      expect(p, isNot(contains('Content-Length')));
    });

    test('lo que pone la app manda, salvo lo que podría colgar al servidor', () async {
      final b = await saludado();
      final s = await crudo('HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n');
      b.c.abrirHttp(1, 'POST', 'http://127.0.0.1:${s.puerto}/',
          cabeceras: 'User-Agent: mio\r\nAccept-Encoding: gzip\r\n'
              'Content-Length: 999\r\nConnection: keep-alive\r\nX-App: Sí\r\n',
          banderas: bCuerpo);
      await b.c.espera(1, tListo);
      b.c.manda(tDatos, 1, [1, 2, 3]);
      b.c.manda(tFin, 1);
      await b.c.respuesta(1);
      final p = s.textoPedido;
      expect(p, contains('User-Agent: mio\r\n'));
      expect(p, contains('Accept-Encoding: gzip\r\n'));
      expect(p, contains('Content-Length: 3\r\n'));
      expect(p, isNot(contains('999')));
      expect(p, contains('Connection: close\r\n'));
      expect(p, isNot(contains('keep-alive')));
      expect(p, contains('Content-Type: application/x-www-form-urlencoded\r\n'));
    });

    test('POST sin cuerpo lleva Content-Length: 0', () async {
      final b = await saludado();
      final s = await crudo('HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n');
      b.c.abrirHttp(1, 'POST', 'http://127.0.0.1:${s.puerto}/');
      await b.c.respuesta(1);
      expect(s.textoPedido, contains('Content-Length: 0\r\n'));
    });

    test('el cuerpo llega entero aunque el teléfono lo mande a trozos', () async {
      final b = await saludado();
      late Uint8List recibido;
      final w = await web((r) async {
        final l = BytesBuilder();
        await r.forEach(l.add);
        recibido = l.takeBytes();
        r.response.statusCode = 201;
        await r.response.close();
      });
      b.c.abrirHttp(1, 'PUT', 'http://127.0.0.1:${w.port}/', banderas: bCuerpo);
      await b.c.espera(1, tListo);
      final d = Uint8List.fromList(List.generate(70000, (i) => i * 7 & 0xFF));
      for (var i = 0; i < d.length; i += 2000) {
        final fin = i + 2000 > d.length ? d.length : i + 2000;
        b.c.manda(tDatos, 1, d.sublist(i, fin));
      }
      b.c.manda(tFin, 1);
      final r = await b.c.respuesta(1);
      expect(r.estado, 201);
      expect(recibido, d);
      await w.close(force: true);
    });
  });

  group('HTTP: lo que recibe el teléfono', () {
    test('las cabeceras llegan como las mandó el servidor, repetidas incluidas',
        () async {
      final b = await saludado();
      final s = await crudo('HTTP/1.1 200 OK\r\nContent-Length: 2\r\n'
          'X-Duracion-Ms: 1000\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\n'
          'ETag: "x"\r\n\r\nhi');
      b.c.abrirHttp(1, 'GET', 'http://127.0.0.1:${s.puerto}/');
      final r = await b.c.respuesta(1);
      expect(r.cabeceras, contains('Content-Length: 2\r\n'),
          reason: 'musica_red.c busca «Content-Length» por su nombre');
      expect(r.cabeceras, contains('X-Duracion-Ms: 1000\r\n'));
      expect(r.cabeceras, contains('Set-Cookie: a=1\r\nSet-Cookie: b=2\r\n'));
      expect(r.cabeceras, contains('ETag: "x"\r\n'));
      expect(r.urlFinal, 'http://127.0.0.1:${s.puerto}/');
      expect(utf8.decode(r.cuerpo.takeBytes()), 'hi');
      expect(r.fin, isTrue);
      expect(r.codigo, cBien);
    });

    test('el cuerpo pasa TAL CUAL: gzip no se descomprime', () async {
      final b = await saludado();
      final g = GZipCodec().encode(utf8.encode('hola hola hola hola'));
      final srv = ServidorCrudo([
        ...latin1.encode('HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n'
            'Content-Length: ${g.length}\r\n\r\n'),
        ...g
      ]);
      await srv.arrancar();
      b.c.abrirHttp(1, 'GET', 'http://127.0.0.1:${srv.puerto}/',
          cabeceras: 'Accept-Encoding: gzip\r\n');
      final r = await b.c.respuesta(1);
      expect(r.cuerpo.takeBytes(), g);
    });

    test('chunked se desarma, también con extensiones y remolques', () async {
      final b = await saludado();
      final s = await crudo('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n'
          '5;x=1\r\nhola \r\n6\r\nmundo!\r\n0\r\nX-Fin: si\r\n\r\n');
      b.c.abrirHttp(1, 'GET', 'http://127.0.0.1:${s.puerto}/');
      final r = await b.c.respuesta(1);
      expect(utf8.decode(r.cuerpo.takeBytes()), 'hola mundo!');
      expect(r.codigo, cBien);
    });

    test('sin largo ni chunked, hasta que cierre', () async {
      final b = await saludado();
      final s = await crudo('HTTP/1.0 200 OK\r\n\r\nlo que sea');
      b.c.abrirHttp(1, 'GET', 'http://127.0.0.1:${s.puerto}/');
      final r = await b.c.respuesta(1);
      expect(utf8.decode(r.cuerpo.takeBytes()), 'lo que sea');
      expect(r.codigo, cBien);
    });

    test('HEAD y 204 no esperan cuerpo', () async {
      final b = await saludado();
      final s = await crudo('HTTP/1.1 200 OK\r\nContent-Length: 500\r\n\r\n',
          cerrar: false);
      b.c.abrirHttp(1, 'HEAD', 'http://127.0.0.1:${s.puerto}/');
      final r = await b.c.respuesta(1);
      expect(r.estado, 200);
      expect(r.cuerpo.length, 0);
      expect(r.codigo, cBien);

      final s2 = await crudo('HTTP/1.1 204 No Content\r\n\r\n', cerrar: false);
      b.c.abrirHttp(2, 'GET', 'http://127.0.0.1:${s2.puerto}/');
      expect((await b.c.respuesta(2)).codigo, cBien);
    });

    test('el 100 Continue se salta', () async {
      final b = await saludado();
      final s = await crudo(
          'HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n');
      b.c.abrirHttp(1, 'GET', 'http://127.0.0.1:${s.puerto}/');
      expect((await b.c.respuesta(1)).estado, 200);
    });

    test('un cuerpo cortado NO se da por bueno', () async {
      final b = await saludado();
      final s = await crudo('HTTP/1.1 200 OK\r\nContent-Length: 500\r\n\r\ncorto');
      b.c.abrirHttp(1, 'GET', 'http://127.0.0.1:${s.puerto}/');
      final r = await b.c.respuesta(1);
      expect(r.nombreCodigo, 'CORTADA');
      expect(r.fin, isFalse);
    });

    test('una respuesta imposible: HTTP; un cierre sin contestar: CORTADA', () async {
      final b = await saludado();
      final s = await crudo('ESTO NO ES HTTP\r\n\r\n');
      b.c.abrirHttp(1, 'GET', 'http://127.0.0.1:${s.puerto}/');
      expect((await b.c.respuesta(1)).nombreCodigo, 'HTTP');
      final s2 = await crudo('');
      b.c.abrirHttp(2, 'GET', 'http://127.0.0.1:${s2.puerto}/');
      expect((await b.c.respuesta(2)).nombreCodigo, 'CORTADA');
    });

    test('un servidor mudo: PLAZO, y un cuerpo que se atasca, también', () async {
      final b = await saludado();
      final s = await crudo('', cerrar: false);
      b.c.abrirHttp(1, 'GET', 'http://127.0.0.1:${s.puerto}/', plazo: 1);
      expect((await b.c.respuesta(1)).nombreCodigo, 'PLAZO');
      final s2 = await crudo('HTTP/1.1 200 OK\r\nContent-Length: 500\r\n\r\nxx',
          cerrar: false);
      b.c.abrirHttp(2, 'GET', 'http://127.0.0.1:${s2.puerto}/', plazo: 1);
      expect((await b.c.respuesta(2)).nombreCodigo, 'PLAZO');
    });

    test('solo http y https, sin LISTO', () async {
      final b = await saludado();
      for (final u in ['ftp://x/', 'http://', 'nada', 'http://a b/']) {
        b.c.abrirHttp(1, 'GET', u);
        final r = await b.c.respuesta(1);
        expect(r.nombreCodigo, 'HTTP', reason: u);
        expect(r.listo, isNull, reason: u);
      }
    });

    test('cabeceras que no caben: se recortan y se dice, y la trama cumple', () async {
      final b = Banco();
      await b.c.saludar(carga: 300);
      final muchas = StringBuffer('HTTP/1.1 200 OK\r\nContent-Length: 0\r\n');
      for (var i = 0; i < 40; i++) {
        muchas.write('X-Larga-$i: ${'v' * 20}\r\n');
      }
      muchas.write('\r\n');
      final s = await crudo(muchas.toString());
      b.c.abrirHttp(1, 'GET', 'http://127.0.0.1:${s.puerto}/');
      final r = await b.c.respuesta(1);
      expect(r.tamRespuesta, lessThanOrEqualTo(300));
      expect(r.cabeceras, contains('X-W5RED-Recortadas: '));
    });

    test('con la carga mínima y una URL larga, la RESPUESTA tampoco se pasa', () async {
      final b = Banco();
      await b.c.saludar(carga: 64);
      final s = await crudo('HTTP/1.1 200 OK\r\nX-A: 1\r\nContent-Length: 0\r\n\r\n');
      b.c.abrirHttp(1, 'GET', 'http://127.0.0.1:${s.puerto}/${'a' * 10}');
      final r = await b.c.respuesta(1);
      expect(r.tamRespuesta, lessThanOrEqualTo(64));
    });
  });

  group('redirecciones', () {
    test('GET y POST siguen; POST pasa a GET sin cuerpo ni sus cabeceras', () async {
      final b = await saludado();
      final metodos = <String>[];
      final tipos = <String?>[];
      final w = await web((r) async {
        metodos.add(r.method);
        tipos.add(r.headers.value('x-tipo') ?? r.headers.contentType?.mimeType);
        await r.drain<void>();
        if (r.uri.path == '/a') {
          r.response.statusCode = 302;
          r.response.headers.set('Location', '/b');
        }
        await r.response.close();
      });
      b.c.abrirHttp(1, 'POST', 'http://127.0.0.1:${w.port}/a',
          cabeceras: 'Content-Type: text/plain\r\nX-Tipo: t\r\n', banderas: bCuerpo);
      await b.c.espera(1, tListo);
      b.c.manda(tDatos, 1, [1]);
      b.c.manda(tFin, 1);
      final r = await b.c.respuesta(1);
      expect(r.estado, 200);
      expect(metodos, ['POST', 'GET']);
      expect(tipos.last, 't', reason: 'X-Tipo sigue; Content-Type no');
      expect(r.urlFinal, endsWith('/b'));
      await w.close(force: true);
    });

    test('un 307 de POST no se sigue: se entrega tal cual', () async {
      final b = await saludado();
      final w = await web((r) async {
        await r.drain<void>();
        r.response.statusCode = 307;
        r.response.headers.set('Location', '/b');
        await r.response.close();
      });
      b.c.abrirHttp(1, 'POST', 'http://127.0.0.1:${w.port}/a');
      expect((await b.c.respuesta(1)).estado, 307);
      await w.close(force: true);
    });

    test('un bucle acaba entregando el 3xx', () async {
      final b = await saludado();
      var n = 0;
      final w = await web((r) async {
        n++;
        r.response.statusCode = 302;
        r.response.headers.set('Location', '/a');
        await r.response.close();
      });
      b.c.abrirHttp(1, 'GET', 'http://127.0.0.1:${w.port}/a');
      expect((await b.c.respuesta(1)).estado, 302);
      expect(n, lessThan(12));
      await w.close(force: true);
    });

    test('una redirección a lo local no entra: PROHIBIDO', () async {
      final b = await saludado(
          politica: const PoliticaDestinos(locales: {}, resolver: _publico));
      final destino = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      var tocado = false;
      destino.listen((c) {
        tocado = true;
        c.destroy();
      });
      final s = await crudo('HTTP/1.1 302 Found\r\n'
          'Location: http://127.0.0.1:${destino.port}/secreto\r\n'
          'Content-Length: 0\r\n\r\n');
      b.c.abrirHttp(1, 'GET', 'http://afuera.test:${s.puerto}/');
      final r = await b.c.respuesta(1);
      expect(r.nombreCodigo, 'PROHIBIDO');
      expect(tocado, isFalse);
      await destino.close();
    });
  });

  group('destinos', () {
    InternetAddress ip(String t) => InternetAddress(t);

    test('qué es local y qué no es destino', () {
      for (final t in ['127.0.0.1', '127.5.5.5', '::1', '::ffff:127.0.0.1']) {
        expect(esLocal(ip(t)), isTrue, reason: t);
      }
      for (final t in ['8.8.8.8', '192.168.1.5', '::2', '2001:db8::1']) {
        expect(esLocal(ip(t)), isFalse, reason: t);
      }
      for (final t in ['0.0.0.0', '0.1.2.3', '::', '::ffff:0.0.0.0']) {
        expect(esNoEspecificada(ip(t)), isTrue, reason: t);
      }
      for (final t in ['127.0.0.1', '::1', '8.8.8.8']) {
        expect(esNoEspecificada(ip(t)), isFalse, reason: t);
      }
    });

    test('solo los puertos de SENUS, 8580 y 8581', () async {
      const p = PoliticaDestinos();
      expect(puertosLocalesSenus, {8580, 8581});
      expect(await p.comprobar('127.0.0.1', 8580), isNotEmpty);
      expect(await p.comprobar('127.0.0.1', 8581), isNotEmpty);
      await expectLater(p.comprobar('127.0.0.1', 8582), throwsA(isA<Prohibido>()));
      await expectLater(p.comprobar('127.0.0.1', 22), throwsA(isA<Prohibido>()));
      await expectLater(p.comprobar('::1', 22), throwsA(isA<Prohibido>()));
    });

    test('una IPv6 mapeada no se cuela a lo local', () async {
      const p = PoliticaDestinos();
      await expectLater(
          p.comprobar('::ffff:127.0.0.1', 22), throwsA(isA<Prohibido>()));
    });

    test('un nombre que resuelve a lo local tampoco', () async {
      final p = PoliticaDestinos(
          locales: const {},
          resolver: (_) async => [ip('8.8.8.8'), ip('127.0.0.1')]);
      await expectLater(p.comprobar('truco.test', 80), throwsA(isA<Prohibido>()));
    });

    test('0.0.0.0 y :: nunca, ni con todo lo local permitido', () async {
      const p = PoliticaDestinos(permitirLocal: true);
      await expectLater(p.comprobar('0.0.0.0', 80), throwsA(isA<Prohibido>()));
      await expectLater(p.comprobar('::', 80), throwsA(isA<Prohibido>()));
      await expectLater(
          const PoliticaDestinos().comprobar('0.0.0.0', 8580),
          throwsA(isA<Prohibido>()));
    });

    test('el canal dice PROHIBIDO por TCP y por HTTP', () async {
      final b = await saludado(politica: const PoliticaDestinos());
      b.c.abrirTcp(1, '127.0.0.1', 22);
      expect((await b.c.respuesta(1)).nombreCodigo, 'PROHIBIDO');
      b.c.abrirHttp(2, 'GET', 'http://127.0.0.1:22/');
      expect((await b.c.respuesta(2)).nombreCodigo, 'PROHIBIDO');
    });

    test('se conecta a la dirección comprobada, no vuelve a resolver', () async {
      var veces = 0;
      final s = await crudo('HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n');
      final b = await saludado(
          politica: PoliticaDestinos(
              locales: {s.puerto},
              resolver: (_) async {
                veces++;
                return [InternetAddress.loopbackIPv4];
              }));
      b.c.abrirHttp(1, 'GET', 'http://cambiante.test:${s.puerto}/');
      expect((await b.c.respuesta(1)).estado, 200);
      expect(veces, 1);
      expect(s.textoPedido, contains('Host: cambiante.test:${s.puerto}\r\n'));
    });
  });

  group('TCP', () {
    test('eco, medio cierre y CIERRA BIEN', () async {
      final b = await saludado();
      final e = await eco();
      b.c.abrirTcp(1, '127.0.0.1', e.port);
      final l = await b.c.espera(1, tListo);
      expect(utf8.decode(l.carga.sublist(4, l.carga.length - 1)),
          '127.0.0.1:${e.port}');
      b.c.manda(tDatos, 1, utf8.encode('hola'));
      b.c.manda(tFin, 1);
      final r = await b.c.respuesta(1);
      expect(utf8.decode(r.cuerpo.takeBytes()), 'hola');
      expect(r.fin, isTrue);
      expect(r.codigo, cBien);
      await e.close();
    });

    test('la otra punta cierra primero: FIN, y el teléfono aún puede hablar', () async {
      final b = await saludado();
      final recibido = Completer<String>();
      final srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      srv.listen((c) async {
        await c.close(); // su FIN
        final l = <int>[];
        c.listen(l.addAll, onDone: () => recibido.complete(utf8.decode(l)));
      });
      b.c.abrirTcp(1, '127.0.0.1', srv.port);
      await b.c.espera(1, tListo);
      await b.c.espera(1, tFin);
      expect(b.s.canales.containsKey(1), isTrue, reason: 'el canal sigue');
      b.c.manda(tDatos, 1, utf8.encode('tarde'));
      b.c.manda(tFin, 1);
      expect(await recibido.future.timeout(const Duration(seconds: 3)), 'tarde');
      expect((await b.c.espera(1, tCierra)).carga[0], cBien);
      await srv.close();
    });

    test('puerto cerrado: RECHAZADA; nombre que no existe: DNS', () async {
      final b = await saludado();
      final srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final libre = srv.port;
      await srv.close();
      b.c.abrirTcp(1, '127.0.0.1', libre);
      expect((await b.c.respuesta(1)).nombreCodigo, 'RECHAZADA');
      b.c.abrirTcp(2, 'no-existe.invalid', 80);
      expect((await b.c.respuesta(2)).nombreCodigo, 'DNS');
    });

    test('TLS contra algo que no habla TLS: código TLS', () async {
      final b = await saludado();
      final e = await crudo('no soy tls\r\n\r\n');
      b.c.abrirTcp(1, '127.0.0.1', e.puerto, banderas: bTls, plazo: 2);
      expect((await b.c.respuesta(1)).nombreCodigo, anyOf('TLS', 'PLAZO'));
    });

    test('abortar: CIERRA ABORTADA y el número se puede reutilizar', () async {
      final b = await saludado();
      final e = await eco();
      b.c.abrirTcp(1, '127.0.0.1', e.port);
      await b.c.espera(1, tListo);
      b.c.manda(tCierra, 1, [cAbortada, 0]);
      expect((await b.c.espera(1, tCierra)).carga[0], cAbortada);
      expect(b.s.canales.containsKey(1), isFalse);
      b.c.abrirTcp(1, '127.0.0.1', e.port);
      await b.c.espera(1, tListo);
      await e.close();
    });

    test('abortar a media descarga corta el socket y no llegan más datos', () async {
      final b = await saludado();
      final cortado = Completer<void>();
      final srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      srv.listen((c) async {
        c.listen((_) {}, onError: (_) {}, onDone: () {
          if (!cortado.isCompleted) cortado.complete();
        });
        try {
          c.add(latin1.encode('HTTP/1.1 200 OK\r\nContent-Length: 999999999\r\n\r\n'));
          while (!cortado.isCompleted) {
            c.add(Uint8List(64 << 10));
            await c.flush();
          }
        } catch (_) {
          if (!cortado.isCompleted) cortado.complete();
        }
      });
      b.c.abrirHttp(1, 'GET', 'http://127.0.0.1:${srv.port}/', ventana: 8192);
      await b.c.espera(1, tDatos);
      b.c.manda(tCierra, 1, [cAbortada, 0]);
      expect((await b.c.espera(1, tCierra)).carga[0], cAbortada);
      await cortado.future.timeout(const Duration(seconds: 5));
      final antes = b.c.vistas.length;
      await pausa(100);
      expect(b.c.vistas.length, antes);
      await srv.close();
    });
  });

  test('la puerta de pruebas: solo 127.0.0.1, y habla la misma sesión', () async {
    final logs = <String>[];
    final p = await PuertaTcp.abrir(0, log: logs.add);
    expect(p.direccion, '127.0.0.1');
    final s = await Socket.connect('127.0.0.1', p.puerto);
    s.add(trama(tHola, 0, [...magiaW5, 1, 0, 8, 4]));
    final r = await s.first.timeout(const Duration(seconds: 3));
    expect(r[0], tHolaOk);
    s.destroy();
    await p.cerrar();
  });

  test('el búfer de recepción se limita: una descarga lenta no se corta al final', () async {
    // Lo que defiende se midió contra un servidor de verdad, a 130 KB/s: sin el
    // límite, 1 MB se cortaba 5 de 5 veces (ver limitarRecepcion). Aquí, que siga puesto.
    final srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    srv.listen((c) => c.destroy());
    final s = await conectarA(
        [InternetAddress.loopbackIPv4], srv.port, const Duration(seconds: 5));
    expect(bufRecepcionDe(s), anyOf(bufRecepcionRed, bufRecepcionRed * 2));
    s.destroy();
    await srv.close();
  });

  test('códigos: lo que el puente de Python llama igual', () {
    expect(nombresCodigo.length, 13);
    expect(codigoDe(const SocketException('x',
        osError: OSError('Connection refused', 61))), cRechazada);
    expect(codigoDe(const SocketException('x',
        osError: OSError('Connection refused', 111))), cRechazada);
    expect(codigoDe(const SocketException('x',
        osError: OSError('Connection reset', 54))), cCortada);
    expect(codigoDe(const SocketException('x',
        osError: OSError('Broken pipe', 32))), cCortada);
    expect(codigoDe(const SocketException('x',
        osError: OSError('Network is down', 50))), cRed);
    expect(codigoDe(TimeoutException('x')), cPlazo);
    expect(codigoDe(const HandshakeException('x')), cTls);
    expect(codigoDe(const Prohibido('x')), cProhibido);
    expect(codigoDe(const ErrorDns('x')), cDns);
    expect(codigoDe(const ErrorHttp('x')), cHttp);
    expect(codigoDe(StateError('x')), cInterno);
  });
}

Future<List<InternetAddress>> _publico(String host) async {
  // «afuera.test» hace de servidor público; los literales son lo que son.
  return [InternetAddress.tryParse(host) ?? InternetAddress('127.0.0.1')];
}
