// El servicio de música con binarios falsos que corren de verdad, un origen de audio
// local y el catálogo guardado. El contrato es el de bt/musica_yt/servicio.py.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:senus_app/servicios/catalogo_musica.dart';
import 'package:senus_app/servicios/gestor_componentes.dart';
import 'package:senus_app/servicios/letra_telefono.dart';
import 'package:senus_app/servicios/pistas_musica.dart';
import 'package:senus_app/servicios/servicio_musica.dart';

import 'apoyo_servicios.dart';
import 'catalogo_musica_test.dart' show RedGuardada;

class Resp {
  final int codigo;
  final String primera;
  final Map<String, String> cab;
  final Uint8List cuerpo;
  Resp(this.codigo, this.primera, this.cab, this.cuerpo);
  String get texto => utf8.decode(cuerpo);
}

Future<Resp> pedir(int puerto, String ruta, {Map<String, String> extra = const {}}) async {
  final s = await Socket.connect('127.0.0.1', puerto);
  final c = extra.entries.map((e) => '${e.key}: ${e.value}\r\n').join();
  s.add(latin1.encode('GET $ruta HTTP/1.1\r\nHost: 127.0.0.1:$puerto\r\n$c\r\n'));
  await s.flush();
  final b = BytesBuilder(copy: false);
  await s.forEach(b.add).timeout(const Duration(seconds: 20));
  s.destroy();
  final r = b.takeBytes();
  final t = latin1.decode(r);
  final i = t.indexOf('\r\n\r\n');
  final l = t.substring(0, i).split('\r\n');
  final cab = <String, String>{};
  for (final x in l.skip(1)) {
    final j = x.indexOf(': ');
    cab[x.substring(0, j)] = x.substring(j + 2);
  }
  return Resp(int.parse(l.first.split(' ')[1]), l.first, cab, Uint8List.sublistView(r, i + 4));
}

/// Tramas MP3 de verdad: FF FB 90 y 417 o 418 bytes, según el bit de relleno.
Uint8List tramas(int n) {
  final b = BytesBuilder();
  for (var i = 0; i < n; i++) {
    final relleno = i % 3 == 0 ? 2 : 0;
    final t = Uint8List(417 + (relleno >> 1));
    t[0] = 0xFF;
    t[1] = 0xFB;
    t[2] = 0x90 | relleno;
    t[3] = i & 255;
    for (var j = 4; j < t.length; j++) {
      t[j] = (i + j) & 0x7F;
    }
    b.add(t);
  }
  return b.takeBytes();
}

void main() {
  final letra = LetraTelefono.desdeTabla(File('assets/servicios/letra_telefono.bin').readAsBytesSync());
  late Directory t;
  late OrigenSimulado o;
  late String yt, deno, ff;
  late String mp3; // fichero con las tramas que «convierte» ffmpeg
  late Uint8List bytes;
  late ServicioMusica s;
  late Pistas pistas;
  late int puerto;

  Future<void> arrancar({
    Future<String> Function()? rutaFfmpeg,
    Future<String> Function()? rutaYt,
    int maximo = 6,
    int reintentos = 3,
  }) async {
    final cat = Catalogo(red: RedGuardada());
    final h = HerramientasMusica(
      ytDlp: rutaYt ?? () async => yt,
      deno: () async => deno,
      ffmpeg: rutaFfmpeg ?? () async => ff,
    );
    pistas = Pistas(
      herramientas: h,
      maximo: maximo,
      permitirHttp: true,
      reintentosAudio: reintentos,
      esperaReintento: const Duration(milliseconds: 10),
    );
    s = ServicioMusica(
      catalogo: cat,
      pistas: pistas,
      portadas: Portadas(cat, h.ffmpeg, bajar: (_) async => utf8.encode('jpeg')),
      letra: letra,
      versiones: 'falsas',
      puerto: 0,
    );
    await s.arrancar();
    puerto = s.servidor.puertoReal;
  }

  setUp(() async {
    t = await carpetaTemporal();
    o = await OrigenSimulado.crear();
    o.ficheros['audio'] = utf8.encode('A' * 20000);
    bytes = tramas(200);
    mp3 = p.join(t.path, 'salida.mp3');
    await File(mp3).writeAsBytes(bytes);
    deno = await ejecutable(t, 'deno', '#!/bin/sh\nexit 0\n');
    // yt-dlp falso: apunta sus argumentos; un id que empieza por «malo» no existe.
    yt = await ejecutable(t, 'yt-dlp', '''#!/bin/sh
for u; do :; done
echo "\$@" >> "${t.path}/args_yt"
case "\$u" in
  *v=malo*) echo "ERROR: [youtube] malo: Video unavailable" >&2; exit 1 ;;
  *v=largo*) echo '{"url":"${o.url('audio')}","duration":7300,"http_headers":{}}'; exit 0 ;;
  *v=roto*) echo 'esto no es json'; exit 0 ;;
esac
echo '{"url":"${o.url('audio')}","duration":6,"http_headers":{"User-Agent":"Agente-De-Prueba"}}'
''');
    // ffmpeg falso: se traga stdin, apunta cuántos bytes le llegaron y da las tramas.
    ff = await ejecutable(t, 'ffmpeg', '''#!/bin/sh
echo "\$@" >> "${t.path}/args_ff"
wc -c | tr -d ' ' >> "${t.path}/stdin_ff"
cat "$mp3"
''');
    await arrancar();
  });
  tearDown(() async {
    await s.parar();
    await o.cerrar();
    await t.delete(recursive: true);
  });

  test('buscar: W5MUS, n, hay más y una línea por canción', () async {
    final r = await pedir(puerto, '/buscar?q=carefree&desde=0&n=10');
    expect(r.codigo, 200);
    final l = r.texto.split('\n');
    expect(l[0], 'W5MUS 1\t10\t1');
    expect(l[1].split('\t'), ['qapK8Gx6ZTo', '206', 'Carefree', 'Kevin MacLeod', 'Carefree']);
    expect(l.where((x) => x.isNotEmpty).length, 11);
    expect(r.cab['Content-Type'], 'text/plain; charset=utf-8');
  });

  test('n se acota a 20', () async {
    expect((await pedir(puerto, '/buscar?q=c&n=99')).texto, startsWith('W5MUS 1\t20\t'));
  });

  test('siguientes: lo mismo, sin hay-más y con el tope de 25', () async {
    final r = await pedir(puerto, '/siguientes/qapK8Gx6ZTo?n=15');
    expect(r.texto, startsWith('W5MUS 1\t15\t0\n'));
    expect((await pedir(puerto, '/siguientes/qapK8Gx6ZTo?n=99')).texto, startsWith('W5MUS 1\t25\t0\n'));
  });

  test('buscar sin q y rutas que no existen: 404', () async {
    expect((await pedir(puerto, '/buscar')).codigo, 404);
    expect((await pedir(puerto, '/nada')).codigo, 404);
  });

  test('la pista: tramas enteras, las cabeceras y ffmpeg recibió el audio por stdin', () async {
    final r = await pedir(puerto, '/pista/abcdefghijk.mp3');
    expect(r.codigo, 200);
    expect(r.cuerpo, bytes);
    expect(r.cab['Content-Type'], 'audio/mpeg');
    expect(r.cab['X-Kbps'], '128');
    expect(r.cab['X-Desde-Ms'], '0');
    expect(r.cab['X-Desde-Byte'], '0');
    expect(r.cab, contains('X-Duracion-Ms'));
    expect(await File('${t.path}/stdin_ff').readAsString(), contains('20000'));
  });

  test('ya entera: Content-Length y la duración exacta (bytes / 16)', () async {
    await pedir(puerto, '/pista/abcdefghijk.mp3');
    await pistas.p['abcdefghijk']!.esperar(() => pistas.p['abcdefghijk']!.fin, const Duration(seconds: 5));
    final r = await pedir(puerto, '/pista/abcdefghijk.mp3');
    expect(r.cab['Content-Length'], '${bytes.length}');
    expect(r.cab['X-Duracion-Ms'], '${bytes.length ~/ 16}');
    expect(r.cuerpo, bytes);
  });

  test('ffmpeg NUNCA recibe una URL ni toca la red', () async {
    await pedir(puerto, '/pista/abcdefghijk.mp3');
    final a = await File('${t.path}/args_ff').readAsString();
    expect(a, isNot(contains('http')));
    expect(a, contains('-protocol_whitelist pipe'));
    expect(a, contains('-i pipe:0'));
    expect(Pistas.argumentosFfmpeg.join(' '), isNot(contains('tls_verify')));
  });

  test('el audio se pide con Range desde 0, con las cabeceras de yt-dlp', () async {
    await pedir(puerto, '/pista/abcdefghijk.mp3');
    expect(o.peticiones.single.$2, 'bytes=0-');
  });

  test('yt-dlp: sin configuración ajena, el motor verificado y el id al final', () async {
    await pedir(puerto, '/pista/abcdefghijk.mp3');
    final a = await File('${t.path}/args_yt').readAsString();
    expect(a, contains('--ignore-config'));
    expect(a, contains('--js-runtimes deno:$deno'));
    expect(a.trim(), endsWith('https://music.youtube.com/watch?v=abcdefghijk'));
  });

  test('el audio se corta: sigue con Range y ffmpeg lo recibe entero', () async {
    o.cortes.add(5000);
    final r = await pedir(puerto, '/pista/abcdefghijk.mp3');
    expect(r.cuerpo, bytes);
    expect(o.peticiones.length, 2);
    expect(o.peticiones.last.$2, startsWith('bytes='));
    expect(await File('${t.path}/stdin_ff').readAsString(), contains('20000'));
  });

  test('el audio se corta sin parar: 502 con el porqué, sin colgarse', () async {
    await s.parar();
    await arrancar(reintentos: 1);
    o.cortes.addAll(List.filled(10, 0));
    final r = await pedir(puerto, '/pista/abcdefghijk.mp3');
    expect(r.codigo, 502);
    expect(r.texto, startsWith('fallo: '));
  });

  test('el origen dice que no: 502 y no se insiste', () async {
    o.ficheros.remove('audio');
    final r = await pedir(puerto, '/pista/abcdefghijk.mp3');
    expect(r.codigo, 502);
    expect(r.texto, contains('HTTP 404'));
    expect(o.peticiones.length, 1);
  });

  test('una URL que aún no vale: no se pide hasta su available_at', () async {
    final t0 = DateTime.now();
    await pistas.bajarAudio(
        InfoAudio(o.url('audio'), 1, const {}, disponible: t0.add(const Duration(milliseconds: 400))), (_) async {});
    expect(DateTime.now().difference(t0).inMilliseconds, greaterThanOrEqualTo(390));
    expect(o.peticiones.length, 1, reason: 'a la primera: esperó en vez de chocar con el 403');
  });

  test('un available_at disparatado no deja la pista colgada', () {
    expect(esperaDisponibleMax, lessThan(const Duration(seconds: 30)), reason: 'el teléfono espera 30 s en red_http');
  });

  test('extraer lee available_at de yt-dlp', () async {
    final yt2 = await ejecutable(t, 'yt-dlp2', '''#!/bin/sh
echo '{"url":"${o.url('audio')}","duration":6,"available_at":1793552087,"http_headers":{}}'
''');
    final x = Pistas(herramientas: HerramientasMusica(ytDlp: () async => yt2, deno: () async => deno, ffmpeg: () async => ff));
    final i = await x.extraer('abcdefghijk');
    expect(i.disponible, DateTime.fromMillisecondsSinceEpoch(1793552087000));
    x.parar();
  });

  test('403 antes del primer byte: otra vuelta, y acaba bien', () async {
    o.prohibidas = 2;
    final r = await pedir(puerto, '/pista/abcdefghijk.mp3');
    expect(r.codigo, 200);
    expect(r.cuerpo, bytes);
    expect(o.peticiones.length, 3);
  });

  test('403 para siempre: 502, tras los reintentos', () async {
    o.prohibidas = 100;
    final r = await pedir(puerto, '/pista/abcdefghijk.mp3');
    expect(r.codigo, 502);
    expect(r.texto, contains('HTTP 403'));
    expect(o.peticiones.length, 4, reason: 'la primera y 3 reintentos');
  });

  test('una URL sin https no se baja fuera de las pruebas', () async {
    final x = Pistas(herramientas: HerramientasMusica(ytDlp: () async => yt, deno: () async => deno, ffmpeg: () async => ff));
    await expectLater(
      x.bajarAudio(InfoAudio(o.url('audio'), 1, const {}), (_) async {}),
      throwsA(predicate((e) => '$e'.contains('https'))),
    );
    expect(o.peticiones, isEmpty);
  });

  test('desde_ms: empieza en una trama, con su X-Desde-Ms y la cola exacta', () async {
    final r = await pedir(puerto, '/pista/abcdefghijk.mp3?desde_ms=1000');
    expect(r.codigo, 200);
    expect(r.cuerpo.sublist(0, 2), [0xFF, 0xFB]);
    final b = int.parse(r.cab['X-Desde-Byte']!);
    expect(b, greaterThanOrEqualTo(16000));
    expect(b, lessThan(16000 + 420));
    expect(int.parse(r.cab['X-Desde-Ms']!), b ~/ 16);
    expect(r.cuerpo, bytes.sublist(b));
  });

  test('Range: 206 desde el byte EXACTO, sin alinear, y con Content-Range si está entera', () async {
    await pedir(puerto, '/pista/abcdefghijk.mp3');
    await pistas.p['abcdefghijk']!.esperar(() => pistas.p['abcdefghijk']!.fin, const Duration(seconds: 5));
    final r = await pedir(puerto, '/pista/abcdefghijk.mp3', extra: {'Range': 'bytes=1001-'});
    expect(r.codigo, 206);
    expect(r.cuerpo, bytes.sublist(1001));
    expect(r.cab['Content-Range'], 'bytes 1001-${bytes.length - 1}/${bytes.length}');
    expect(r.cab['X-Desde-Byte'], '1001');
  });

  test('Range fuera de la pista: 502', () async {
    await pedir(puerto, '/pista/abcdefghijk.mp3');
    await pistas.p['abcdefghijk']!.esperar(() => pistas.p['abcdefghijk']!.fin, const Duration(seconds: 5));
    final r = await pedir(puerto, '/pista/abcdefghijk.mp3', extra: {'Range': 'bytes=${bytes.length + 5}-'});
    expect(r.codigo, 502);
  });

  test('Range raro se ignora', () async {
    final r = await pedir(puerto, '/pista/abcdefghijk.mp3', extra: {'Range': 'bytes=0-10'});
    expect(r.codigo, 200);
  });

  test('sig: prepara la siguiente al acabar esta, sin dos a la vez', () async {
    await pedir(puerto, '/pista/abcdefghijk.mp3?sig=otraotraotr');
    final q = await () async {
      for (var i = 0; i < 100; i++) {
        final x = pistas.p['otraotraotr'];
        if (x != null) return x;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      return null;
    }();
    expect(q, isNotNull);
    await q!.esperar(() => q.fin, const Duration(seconds: 5));
    expect(q.fin, isTrue);
  });

  test('preparar: 202', () async {
    final r = await pedir(puerto, '/preparar/abcdefghijk');
    expect(r.codigo, 202);
    expect(r.texto, 'preparando\n');
  });

  test('un id que no existe: 502 con el porqué, y otra vez se reintenta', () async {
    final r = await pedir(puerto, '/pista/malomalo123.mp3');
    expect(r.codigo, 502);
    expect(r.texto, contains('Video unavailable'));
    expect(r.cab, contains('X-Error'));
    final antes = (await File('${t.path}/args_yt').readAsLines()).length;
    await pedir(puerto, '/pista/malomalo123.mp3');
    expect((await File('${t.path}/args_yt').readAsLines()).length, antes + 1);
  });

  test('un id que quiere colarse en la orden: 502 y yt-dlp ni corre', () async {
    for (final mal in ['..%2Ffuera', 'a%20b', 'abc\$(id)', 'abc%0Adef', 'abc;def', 'a%2Fb']) {
      final r = await pedir(puerto, '/pista/$mal.mp3');
      expect(r.codigo, 502, reason: mal);
    }
    expect(await File('${t.path}/args_yt').exists(), isFalse);
    expect((await pedir(puerto, '/pista/abcdefghijk.mp3?sig=a%20b')).codigo, 502);
  });

  test('un id con guiones al principio (los hay de verdad) va dentro de la URL, no suelto', () async {
    await pedir(puerto, '/pista/--exec-sh12.mp3');
    final a = await File('${t.path}/args_yt').readAsString();
    expect(a.trim(), endsWith('https://music.youtube.com/watch?v=--exec-sh12'));
    expect(a.split(' '), isNot(contains('--exec-sh12')));
  });

  test('más de 2 horas: no se prepara', () async {
    final r = await pedir(puerto, '/pista/largolargol.mp3');
    expect(r.codigo, 502);
    expect(r.texto, contains('de más'));
  });

  test('yt-dlp da algo que no es JSON: 502', () async {
    expect((await pedir(puerto, '/pista/rotoroto123.mp3')).codigo, 502);
  });

  test('una extracción a la vez', () async {
    await s.parar();
    final marca = p.join(t.path, 'dentro');
    final lento = await ejecutable(t, 'yt-lento', '''#!/bin/sh
[ -e "$marca" ] && echo solapado >> "${t.path}/solapes"
touch "$marca"
sleep 0.2
rm "$marca"
echo '{"url":"${o.url('audio')}","duration":6,"http_headers":{}}'
''');
    await arrancar(rutaYt: () async => lento);
    await Future.wait([
      pedir(puerto, '/pista/uno45678901.mp3'),
      pedir(puerto, '/pista/dos45678901.mp3'),
      pedir(puerto, '/pista/tre45678901.mp3'),
    ]);
    expect(await File('${t.path}/solapes').exists(), isFalse);
  });

  test('en RAM las últimas: las viejas se sueltan', () async {
    await s.parar();
    await arrancar(maximo: 2);
    for (final id in ['aaa45678901', 'bbb45678901', 'ccc45678901', 'ddd45678901']) {
      await pedir(puerto, '/pista/$id.mp3');
      await pistas.p[id]!.esperar(() => pistas.p[id]!.fin, const Duration(seconds: 5));
    }
    expect(pistas.p.length, lessThanOrEqualTo(3));
    expect(pistas.p.containsKey('aaa45678901'), isFalse);
    expect(pistas.cuentas['soltadas'], greaterThan(0));
  });

  test('nada de audio al disco: el directorio de trabajo no crece con mp3', () async {
    await pedir(puerto, '/pista/abcdefghijk.mp3');
    final mp3s = t.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.mp3')).toList();
    expect(mp3s.map((f) => f.path), [mp3], reason: 'solo el de la prueba');
  });

  test('portada: RGB565 por ffmpeg, sin red para él, con caché y lado acotado', () async {
    await s.parar();
    final img = await ejecutable(t, 'ffmpeg-img', '''#!/bin/sh
echo "\$@" >> "${t.path}/args_img"
cat > /dev/null
head -c ${56 * 56 * 2} /dev/zero
''');
    await arrancar(rutaFfmpeg: () async => img);
    final r = await pedir(puerto, '/portada/abcdefghijk?lado=56');
    expect(r.codigo, 200);
    expect(r.cuerpo.length, 6272);
    expect(r.cab['Content-Type'], 'application/octet-stream');
    expect(r.cab['X-Ancho'], '56');
    expect(r.cab['X-Alto'], '56');
    expect(r.cab['X-Pixel'], 'RGB565-BE');
    await pedir(puerto, '/portada/abcdefghijk?lado=56');
    final a = await File('${t.path}/args_img').readAsLines();
    expect(a.length, 1, reason: 'la segunda sale de la caché');
    expect(a.single, contains('-protocol_whitelist pipe'));
    expect(a.single, contains('format=rgb565be'));
  });

  test('/estado', () async {
    await pedir(puerto, '/pista/abcdefghijk.mp3');
    final r = await pedir(puerto, '/estado');
    expect(r.texto, startsWith('senus-musica: falsas'));
    expect(r.texto, contains('abcdefghijk'));
  });

  test('lo que no casa NO SE EJECUTA: ffmpeg sin verificar', () async {
    await s.parar();
    final rastro = p.join(t.path, 'rastro');
    final malo = await ejecutable(t, 'ffmpeg-malo', '#!/bin/sh\ntouch "$rastro"\n');
    await arrancar(rutaFfmpeg: () async => throw NoVerificado(malo, 'la huella no casa'));
    final r = await pedir(puerto, '/pista/abcdefghijk.mp3');
    expect(r.codigo, 502);
    expect(await File(rastro).exists(), isFalse);
  });

  test('lo que no casa NO SE EJECUTA: yt-dlp sin verificar', () async {
    await s.parar();
    final rastro = p.join(t.path, 'rastro');
    final malo = await ejecutable(t, 'yt-malo', '#!/bin/sh\ntouch "$rastro"\n');
    await arrancar(rutaYt: () async => throw NoVerificado(malo, 'la huella no casa'));
    expect((await pedir(puerto, '/pista/abcdefghijk.mp3')).codigo, 502);
    expect(await File(rastro).exists(), isFalse);
  });

  test('parar mata lo que corra', () async {
    await s.parar();
    final pidf = p.join(t.path, 'pid');
    final lento = await ejecutable(t, 'ff-lento', '''#!/bin/sh
echo \$\$ > "$pidf"
exec sleep 30
''');
    await arrancar(rutaFfmpeg: () async => lento);
    await pedir(puerto, '/preparar/abcdefghijk');
    for (var i = 0; i < 200 && !File(pidf).existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final pid = (await File(pidf).readAsString()).trim();
    await s.parar();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final r = await Process.run('kill', ['-0', pid]);
    expect(r.exitCode, isNot(0), reason: 'el proceso murió');
  });

  group('alinear', () {
    test('salta lo que parece trama y no lo es', () {
      final d = Uint8List.fromList([...List.filled(5, 0), 0xFF, 0xFB, 0x90, 0, ...List.filled(10, 1), ...tramas(3)]);
      expect(alinear(d, d.length, 0), 19);
    });

    test('al final de lo que hay vale sin ver la siguiente', () {
      final d = tramas(1);
      expect(alinear(d, d.length, 0), 0);
    });

    test('sin tramas: null', () {
      expect(alinear(Uint8List(100), 100, 0), isNull);
    });
  });
}
