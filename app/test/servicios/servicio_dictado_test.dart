// El servicio de dictado con un motor de mentira, y el ayudante real del protocolo
// contra un binario falso. El contrato es el de bt/dictado/servicio.py.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:senus_app/servicios/filtro_dictado.dart';
import 'package:senus_app/servicios/gestor_componentes.dart';
import 'package:senus_app/servicios/letra_telefono.dart';
import 'package:senus_app/servicios/motor_dictado.dart';
import 'package:senus_app/servicios/servicio_dictado.dart';

import 'apoyo_servicios.dart';

class MotorFalso implements MotorDictado {
  List<(int, int)> tramos = const [(0, 1000)];
  List<SegmentoWhisper> segmentos = const [SegmentoWhisper('Hola, ¿qué tal?', 0.05, -0.2)];
  Completer<void>? freno;
  Object? fallo;
  int vads = 0, whispers = 0, apagados = 0;
  Float32List? audioVad, audioWhisper;
  String? idioma;

  @override
  String get descripcion => 'falso';

  @override
  Future<void> apagar() async => apagados++;

  @override
  Future<List<(int, int)>> tramosDeVoz(Float32List a) async {
    vads++;
    audioVad = a;
    await freno?.future;
    if (fallo != null) throw fallo!;
    return tramos;
  }

  @override
  Future<List<SegmentoWhisper>> transcribir(Float32List a, String i) async {
    whispers++;
    audioWhisper = a;
    idioma = i;
    return segmentos;
  }
}

class Resp {
  final int codigo;
  final Map<String, String> cab;
  final String cuerpo;
  Resp(this.codigo, this.cab, this.cuerpo);
}

Future<Resp> post(int puerto, String ruta, List<int> cuerpo, {bool conLargo = true}) async {
  final s = await Socket.connect('127.0.0.1', puerto);
  s.add(latin1.encode('POST $ruta HTTP/1.1\r\nHost: 127.0.0.1:$puerto\r\nContent-Type: application/octet-stream\r\n'
      '${conLargo ? 'Content-Length: ${cuerpo.length}\r\n' : ''}\r\n'));
  s.add(cuerpo);
  await s.flush();
  final b = BytesBuilder(copy: false);
  await s.forEach(b.add).timeout(const Duration(seconds: 15));
  s.destroy();
  return _partir(b.takeBytes());
}

Future<Resp> obtener(int puerto, String ruta) async {
  final s = await Socket.connect('127.0.0.1', puerto);
  s.add(latin1.encode('GET $ruta HTTP/1.1\r\nHost: 127.0.0.1:$puerto\r\n\r\n'));
  await s.flush();
  final b = BytesBuilder(copy: false);
  await s.forEach(b.add).timeout(const Duration(seconds: 15));
  s.destroy();
  return _partir(b.takeBytes());
}

Resp _partir(List<int> r) {
  final t = latin1.decode(r);
  final i = t.indexOf('\r\n\r\n');
  final l = t.substring(0, i).split('\r\n');
  final cab = <String, String>{};
  for (final x in l.skip(1)) {
    final j = x.indexOf(': ');
    cab[x.substring(0, j)] = x.substring(j + 2);
  }
  return Resp(int.parse(l.first.split(' ')[1]), cab, utf8.decode(r.sublist(i + 4), allowMalformed: true));
}

/// 1 s de PCM a 8 kHz con un tono.
Uint8List voz([int ms = 1000]) {
  final b = ByteData(ms * 16);
  for (var i = 0; i < ms * 8; i++) {
    b.setInt16(i * 2, (i % 16 < 8) ? 2000 : -2000, Endian.little);
  }
  return b.buffer.asUint8List();
}

/// Texto largo que no se repite: uno repetido caería por «repetido», como debe.
String textoLargo(int palabras) {
  final r = Random(3);
  return List.generate(palabras, (_) => String.fromCharCodes(List.generate(6, (_) => 97 + r.nextInt(26)))).join(' ');
}

void main() {
  final letra = LetraTelefono.desdeTabla(File('assets/servicios/letra_telefono.bin').readAsBytesSync());
  late MotorFalso m;
  late ServicioDictado s;
  late int p;

  Future<void> arrancar({int cola = 4, Duration plazoCola = const Duration(seconds: 20)}) async {
    m = MotorFalso();
    s = ServicioDictado(motor: m, letra: letra, nombreModelo: 'prueba', puerto: 0, cola: cola, plazoCola: plazoCola);
    await s.arrancar();
    p = s.servidor.puertoReal;
  }

  setUp(arrancar);
  tearDown(() => s.parar());

  const tel = '/dictar?hz=8000&idioma=es&max=500';

  test('la petición del teléfono: 200, texto en una línea y las cabeceras X-Dictado', () async {
    final r = await post(p, tel, voz());
    expect(r.codigo, 200);
    expect(r.cuerpo, 'Hola, ¿qué tal?');
    expect(r.cab['Content-Type'], 'text/plain; charset=utf-8');
    expect(r.cab['Content-Length'], '${utf8.encode(r.cuerpo).length}');
    expect(r.cab['X-Dictado-Audio-Ms'], '1000');
    expect(r.cab['X-Dictado-Voz-Ms'], '1000');
    expect(r.cab['X-Dictado-Modelo'], 'prueba');
    expect(r.cab, contains('X-Dictado-Ms'));
    expect(r.cab, contains('X-Dictado-Cola-Ms'));
    expect(r.cab, isNot(contains('X-Dictado-Motivo')));
    expect(r.cab.values.join(' ').toLowerCase(), isNot(contains('hola')), reason: 'el texto no va en cabeceras');
    expect(m.idioma, 'es');
  });

  test('el VAD ve el audio tal cual y whisper con ganancia', () async {
    await post(p, tel, voz());
    final maxVad = m.audioVad!.fold<double>(0, (a, b) => b.abs() > a ? b.abs() : a);
    final maxWh = m.audioWhisper!.fold<double>(0, (a, b) => b.abs() > a ? b.abs() : a);
    expect(maxWh, greaterThan(maxVad * 2));
    expect(m.audioVad!.length, closeTo(16000, 2), reason: 'ya a 16 kHz');
  });

  test('sin voz: 200 VACÍO con el porqué', () async {
    m.tramos = const [];
    final r = await post(p, tel, voz());
    expect(r.codigo, 200);
    expect(r.cuerpo, '');
    expect(r.cab['Content-Length'], '0');
    expect(r.cab['X-Dictado-Motivo'], 'sin-voz');
    expect(m.whispers, 0);
  });

  test('alucinación: vacío con su motivo', () async {
    m.segmentos = const [SegmentoWhisper('¡Suscríbete!', 0.1, -0.3)];
    final r = await post(p, tel, voz());
    expect(r.cuerpo, '');
    expect(r.cab['X-Dictado-Motivo'], 'alucinacion');
  });

  test('muy corto: vacío y ni llega al motor', () async {
    final r = await post(p, tel, voz(100));
    expect(r.cuerpo, '');
    expect(r.cab['X-Dictado-Motivo'], 'muy-corto');
    expect(m.vads, 0);
  });

  test('la letra del teléfono y el tope de max', () async {
    m.segmentos = const [SegmentoWhisper('Motörhead y Сплин', 0.1, -0.3)];
    expect((await post(p, tel, voz())).cuerpo, 'Motorhead y Splin');
    m.segmentos = [SegmentoWhisper(textoLargo(50), 0.1, -0.3)];
    final r = await post(p, '/dictar?max=20', voz());
    expect(utf8.encode(r.cuerpo).length, lessThanOrEqualTo(20));
    expect(r.cuerpo, endsWith('…'));
  });

  test('max se acota entre 16 y 4000', () async {
    m.segmentos = [SegmentoWhisper(textoLargo(2000), 0.1, -0.3)];
    expect(utf8.encode((await post(p, '/dictar?max=1', voz())).cuerpo).length, lessThanOrEqualTo(16));
    expect(utf8.encode((await post(p, '/dictar?max=99999', voz())).cuerpo).length, closeTo(4000, 8));
  });

  test('/depurar: crudo, teléfono y segmentos', () async {
    m.segmentos = const [SegmentoWhisper('Canción', 0.1, -0.3), SegmentoWhisper('¡Suscríbete!', 0.1, -0.3)];
    final r = await post(p, '/depurar?hz=8000', voz());
    expect(r.cuerpo, contains('crudo: Canción'));
    expect(r.cuerpo, contains('telefono: Canción'));
    expect(r.cuerpo, contains('segmento: BIEN\tCanción'));
    expect(r.cuerpo, contains('segmento: alucinacion'));
  });

  group('errores', () {
    test('cuerpo vacío 400, impar 400', () async {
      expect((await post(p, tel, const [])).codigo, 400);
      final r = await post(p, tel, voz().sublist(0, 1001));
      expect(r.codigo, 400);
      expect(r.cuerpo, startsWith('fallo: '));
      expect(r.cab['X-Error'], '400');
    });

    test('sin Content-Length: 411', () async {
      expect((await post(p, tel, const [], conLargo: false)).codigo, 411);
    });

    test('más de 60 s: 413, y lo recibe en vez de un corte', () async {
      final r = await post(p, tel, Uint8List(61 * 8000 * 2));
      expect(r.codigo, 413);
      expect(r.cuerpo, startsWith('fallo: cuerpo de 976000 B'));
    });

    test('hz y max raros, idioma desconocido: 400', () async {
      expect((await post(p, '/dictar?hz=100', voz())).codigo, 400);
      expect((await post(p, '/dictar?hz=99999', voz())).codigo, 400);
      expect((await post(p, '/dictar?hz=abc', voz())).codigo, 400);
      expect((await post(p, '/dictar?max=abc', voz())).codigo, 400);
      expect((await post(p, '/dictar?idioma=xx', voz())).codigo, 400);
    });

    test('rutas que no existen: 404', () async {
      expect((await post(p, '/nada', voz())).codigo, 404);
      expect((await obtener(p, '/nada')).codigo, 404);
    });

    test('el motor falla: 500 y sigue atendiendo', () async {
      m.fallo = FalloMotor('se cayó');
      final r = await post(p, tel, voz());
      expect(r.codigo, 500);
      expect(r.cuerpo, startsWith('fallo: se cayó'));
      m.fallo = null;
      expect((await post(p, tel, voz())).codigo, 200);
    });
  });

  test('/salud', () async {
    final r = await obtener(p, '/salud');
    expect(r.codigo, 200);
    expect(r.cuerpo, startsWith('W5DIC 1\tBIEN\tprueba\n'));
    expect((await obtener(p, '/estado')).codigo, 200);
  });

  group('de una en una', () {
    test('la segunda espera turno y lleva su espera en X-Dictado-Cola-Ms', () async {
      m.freno = Completer<void>();
      final a = post(p, tel, voz());
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final b = post(p, tel, voz());
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(m.vads, 1, reason: 'la segunda no entró');
      m.freno!.complete();
      m.freno = null;
      final (ra, rb) = await (a, b).wait;
      expect(ra.codigo, 200);
      expect(rb.codigo, 200);
      expect(int.parse(rb.cab['X-Dictado-Cola-Ms']!), greaterThan(50));
    });

    test('cola llena: 503 con Retry-After', () async {
      await s.parar();
      await arrancar(cola: 1);
      m.freno = Completer<void>();
      final a = post(p, tel, voz());
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final b = post(p, tel, voz());
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final c = await post(p, tel, voz());
      expect(c.codigo, 503);
      expect(c.cab['Retry-After'], '2');
      expect(c.cab['X-Error'], 'ocupado');
      m.freno!.complete();
      expect((await a).codigo, 200);
      expect((await b).codigo, 200);
    });

    test('el turno que no llega: 503', () async {
      await s.parar();
      await arrancar(plazoCola: const Duration(milliseconds: 200));
      m.freno = Completer<void>();
      final a = post(p, tel, voz());
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final b = await post(p, tel, voz());
      expect(b.codigo, 503);
      m.freno!.complete();
      expect((await a).codigo, 200);
      expect((await post(p, tel, voz())).codigo, 200, reason: 'el turno no se quedó tomado');
    });
  });

  test('parar apaga el motor', () async {
    await s.parar();
    expect(m.apagados, 1);
    await expectLater(Socket.connect('127.0.0.1', p), throwsA(isA<SocketException>()));
  });

  group('el ayudante, contra un binario falso', () {
    late Directory t;
    setUp(() async => t = await carpetaTemporal());
    tearDown(() => t.delete(recursive: true));

    // Habla el protocolo del ayudante de verdad: cabecera de 12 bytes y una línea.
    Future<String> falso({String extra = ''}) => ejecutable(t, 'ayudante', '''#!/usr/bin/python3
import json, struct, sys, os
print(json.dumps({"ok": True, "listo": True, "version": "falsa", "carga_ms": 1}), flush=True)
i = sys.stdin.buffer
$extra
while True:
    c = i.read(12)
    if len(c) < 12: os._exit(0)
    assert c[:2] == b"W5"
    op = c[2]
    if op == 0: os._exit(0)
    idioma = c[4:8].rstrip(b"\\0").decode()
    n = struct.unpack("<I", c[8:12])[0]
    x = struct.unpack("<%df" % n, i.read(4 * n))
    if op == 1:
        print(json.dumps({"ok": True, "tramos": [[0, 500], [700, len(x) // 16]]}), flush=True)
    else:
        print(json.dumps({"ok": True, "segmentos": [{"t": idioma + " %d" % n, "ns": 0.25, "lp": -0.5}]}), flush=True)
''');

    MotorAyudante motor(String ruta, {Duration plazo = const Duration(seconds: 10), Duration? apagar}) => MotorAyudante(
          rutas: () async => RutasMotor(ruta, 'm', 'v'),
          plazoPeticion: plazo,
          apagarTras: apagar ?? const Duration(minutes: 5),
        );

    test('VAD y whisper por stdin/stdout, con los datos íntegros', () async {
      final m = motor(await falso());
      expect(await m.tramosDeVoz(Float32List(16000)), [(0, 500), (700, 1000)]);
      final s = await m.transcribir(Float32List(1234), 'es');
      expect(s.single.texto, 'es 1234');
      expect(s.single.noHabla, 0.25);
      expect(s.single.logProb, -0.5);
      await m.apagar();
    });

    test('se apaga solo tras el rato sin uso y vuelve a arrancar', () async {
      final m = motor(await falso(), apagar: const Duration(milliseconds: 100));
      await m.tramosDeVoz(Float32List(10));
      expect(m.descripcion, startsWith('cargado'));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(m.descripcion, 'en reposo');
      expect(await m.tramosDeVoz(Float32List(16000)), hasLength(2));
      await m.apagar();
    });

    test('si se cae a media petición: falla esa y la siguiente arranca otro', () async {
      final r = await falso();
      final marca = '${t.path}/una_vez';
      final m = motor(await ejecutable(t, 'cae', '''#!/bin/sh
if [ ! -e "$marca" ]; then touch "$marca"; echo '{"ok":true,"listo":true,"version":"x","carga_ms":1}'; exit 3; fi
exec "$r"
'''));
      await expectLater(m.tramosDeVoz(Float32List(10)), throwsA(anything));
      expect(await m.tramosDeVoz(Float32List(16000)), hasLength(2));
      await m.apagar();
    });

    test('precalentar no corta una petición que llegue mientras tanto', () async {
      final m = motor(await falso(extra: 'import time\ntime.sleep(0.2)'));
      final pre = m.precalentar();
      final r = m.tramosDeVoz(Float32List(16000));
      expect(await r, hasLength(2));
      await pre;
      expect(m.descripcion, startsWith('cargado'));
      await m.apagar();
    });

    test('precalentar, a solas, deja la memoria libre', () async {
      final m = motor(await falso());
      await m.precalentar();
      expect(m.descripcion, 'en reposo');
    });

    test('un ayudante colgado se mata al agotar el plazo', () async {
      final m = motor(await falso(extra: 'import time\ntime.sleep(60)'), plazo: const Duration(milliseconds: 300));
      await expectLater(m.tramosDeVoz(Float32List(10)), throwsA(isA<TimeoutException>()));
      expect(m.descripcion, 'en reposo');
    });

    test('un ayudante que dice que no: falla con el porqué', () async {
      final r = await ejecutable(t, 'no', '''#!/bin/sh
echo '{"ok":false,"fallo":"el modelo no carga"}'
exit 3
''');
      await expectLater(motor(r).tramosDeVoz(Float32List(10)), throwsA(predicate((e) => '$e'.contains('el modelo no carga'))));
    });

    test('sin rutas verificadas no se arranca nada', () async {
      final rastro = '${t.path}/rastro';
      final malo = await ejecutable(t, 'malo', '#!/bin/sh\ntouch "$rastro"\n');
      final m = MotorAyudante(rutas: () async {
        throw NoVerificado(malo, 'la huella no casa');
      });
      await expectLater(m.tramosDeVoz(Float32List(10)), throwsA(isA<NoVerificado>()));
      expect(await File(rastro).exists(), isFalse);
    });

    test('el servicio entero contra el binario falso', () async {
      final motorReal = motor(await falso());
      final srv = ServicioDictado(motor: motorReal, letra: letra, nombreModelo: 'x', puerto: 0);
      await srv.arrancar();
      final r = await post(srv.servidor.puertoReal, '/dictar?hz=8000&idioma=es', voz());
      expect(r.codigo, 200);
      expect(r.cuerpo, startsWith('es '));
      expect(r.cab['X-Dictado-Voz-Ms'], '800');
      await srv.parar();
    });
  });
}
