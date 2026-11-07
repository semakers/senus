// La app Videos en el servicio de música (docs/contrato_videos.md): el corte de los
// JPEG, el formato .w5v, la búsqueda, los parámetros y el corte del teléfono. Con
// yt-dlp y ffmpeg falsos que corren de verdad y un origen local para la bajada.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:senus_app/servicios/catalogo_musica.dart';
import 'package:senus_app/servicios/cortador_jpeg.dart';
import 'package:senus_app/servicios/letra_telefono.dart';
import 'package:senus_app/servicios/pistas_musica.dart';
import 'package:senus_app/servicios/servicio_musica.dart';
import 'package:senus_app/servicios/videos_youtube.dart';

import 'apoyo_servicios.dart';
import 'catalogo_musica_test.dart' show RedGuardada;
import 'servicio_musica_test.dart' show pedir;

/// Un JPEG con la forma de los de ffmpeg y TRAMPAS: un FF D9 y un FF D8 dentro de un
/// comentario, un 255 seguido de un 217 en la tabla de cuantificación, rellenos FF 00
/// y un reinicio en los datos, y un FF de relleno antes del EOI.
Uint8List jpegConTrampas(int semilla, {int datos = 300, int? tam}) {
  final b = BytesBuilder();
  void seg(int c, List<int> cuerpo) {
    final l = cuerpo.length + 2;
    b
      ..add([0xFF, c, l >> 8, l & 255])
      ..add(cuerpo);
  }

  b.add([0xFF, 0xD8]);
  seg(0xE0, [...'JFIF'.codeUnits, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0]);
  seg(0xFE, [0x41, 0xFF, 0xD9, 0x42, 0xFF, 0xD8, 0x43]);
  final q = List<int>.generate(64, (i) => 1 + (i * 7 + semilla) % 200);
  q[10] = 0xFF;
  q[11] = 0xD9;
  seg(0xDB, [0, ...q]);
  seg(0xC0, [8, 0, 90, 0, 160, 3, 1, 0x22, 0, 2, 0x11, 0, 3, 0x11, 0]);
  seg(0xC4, [0x00, 1, ...List.filled(15, 0), 0x2A]);
  seg(0xDA, [3, 1, 0, 2, 0x11, 3, 0x11, 0, 63, 0]);
  final n = tam == null ? datos : tam - b.length - 9;
  for (var i = 0; i < n; i++) {
    final v = (i * 31 + semilla * 17) & 0xFF;
    b.addByte(v);
    if (v == 0xFF) b.addByte(0x00);
  }
  b.add([0xFF, 0x00, 0xFF, 0xD3, 0x12, 0xFF, 0xFF, 0xD9]);
  return b.takeBytes();
}

/// Corta [todo] dándoselo al cortador en los trozos que diga [trozos].
List<Uint8List> cortar(Uint8List todo, Iterable<int> trozos, {CortadorJpeg? c}) {
  final x = c ?? CortadorJpeg();
  final out = <Uint8List>[];
  var o = 0;
  for (final t in trozos) {
    if (o >= todo.length) break;
    final f = min(o + t, todo.length);
    out.addAll(x.anadir(Uint8List.sublistView(todo, o, f)));
    o = f;
  }
  if (o < todo.length) out.addAll(x.anadir(Uint8List.sublistView(todo, o)));
  return out;
}

Uint8List juntar(List<Uint8List> l) => Uint8List.fromList(l.expand((x) => x).toList());

/// Lo que trae un .w5v.
class W5v {
  final int an, al, fps, durMs;
  final List<(int, Uint8List)> cuadros; // (pts, jpeg)
  final bool fin;
  W5v(this.an, this.al, this.fps, this.durMs, this.cuadros, this.fin);
}

W5v leerW5v(Uint8List b) {
  final d = ByteData.sublistView(b);
  expect(ascii.decode(b.sublist(0, 4)), 'W5V1');
  expect(d.getUint16(10, Endian.little), 0, reason: 'reservado');
  final cuadros = <(int, Uint8List)>[];
  var o = 16;
  var fin = false;
  while (o + 8 <= b.length) {
    final n = d.getUint32(o, Endian.little), pts = d.getUint32(o + 4, Endian.little);
    o += 8;
    if (n == 0 && pts == 0xFFFFFFFF) {
      fin = true;
      break;
    }
    cuadros.add((pts, Uint8List.sublistView(b, o, o + n)));
    o += n;
  }
  expect(o, b.length, reason: 'nada suelto detrás');
  return W5v(d.getUint16(4, Endian.little), d.getUint16(6, Endian.little), d.getUint16(8, Endian.little),
      d.getUint32(12, Endian.little), cuadros, fin);
}

/// Un cliente que lee a su ritmo y puede colgar a mitad: el teléfono.
class Lector {
  final Socket s;
  final StreamIterator<Uint8List> it;
  final b = BytesBuilder(copy: false);
  Lector._(this.s) : it = StreamIterator(s);

  static Future<Lector> pedir(int puerto, String ruta) async {
    final s = await Socket.connect('127.0.0.1', puerto);
    s.add(latin1.encode('GET $ruta HTTP/1.1\r\nHost: 127.0.0.1:$puerto\r\n\r\n'));
    await s.flush();
    return Lector._(s);
  }

  /// Lee hasta tener [n] bytes en total (cabeceras HTTP incluidas). false si se cerró antes.
  Future<bool> hasta(int n, {Duration plazo = const Duration(seconds: 10)}) async {
    while (b.length < n) {
      if (!await it.moveNext().timeout(plazo)) return false;
      b.add(it.current);
    }
    return true;
  }

  Future<String> cabeceras() async {
    while (!latin1.decode(b.toBytes(), allowInvalid: true).contains('\r\n\r\n')) {
      if (!await it.moveNext().timeout(const Duration(seconds: 10))) break;
      b.add(it.current);
    }
    final t = latin1.decode(b.toBytes(), allowInvalid: true);
    return t.substring(0, t.indexOf('\r\n\r\n'));
  }

  int get finCabeceras => latin1.decode(b.toBytes(), allowInvalid: true).indexOf('\r\n\r\n') + 4;

  void colgar() => s.destroy();
}

Future<bool> vivo(String pid) async => (await Process.run('kill', ['-0', pid])).exitCode == 0;

Future<void> esperarA(bool Function() cond, {int ms = 5000}) async {
  for (var i = 0; i < ms ~/ 20 && !cond(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  group('cortador de JPEG', () {
    final cuadros = [for (var i = 0; i < 5; i++) jpegConTrampas(i, datos: 200 + 97 * i)];
    final todo = juntar(cuadros);

    test('la trampa es de verdad: buscar FF D9 sin más corta mal', () {
      final ingenuo = <int>[];
      for (var i = 0; i + 1 < cuadros[0].length; i++) {
        if (cuadros[0][i] == 0xFF && cuadros[0][i + 1] == 0xD9) ingenuo.add(i);
      }
      expect(ingenuo.length, greaterThanOrEqualTo(3), reason: 'en el COM, en la DQT y el EOI');
    });

    test('de un tirón: los cinco, enteros y sin un byte de más ni de menos', () {
      final r = CortadorJpeg().anadir(todo);
      expect(r.length, 5);
      for (var i = 0; i < 5; i++) {
        expect(r[i], cuadros[i], reason: 'cuadro $i');
      }
    });

    test('byte a byte: cada corte posible entre lecturas (FF|D9, FF|00, en mitad de un largo)', () {
      final r = cortar(todo, Iterable.generate(todo.length, (_) => 1));
      expect(r.length, 5);
      for (var i = 0; i < 5; i++) {
        expect(r[i], cuadros[i]);
      }
    });

    test('trozos al azar, 200 veces', () {
      final azar = Random(7);
      for (var vuelta = 0; vuelta < 200; vuelta++) {
        final r = cortar(todo, Iterable.generate(10000, (_) => 1 + azar.nextInt(700)));
        expect(r.length, 5, reason: 'vuelta $vuelta');
        expect(juntar(r), todo);
      }
    });

    test('un cuadro no sale hasta su EOI, aunque falte un solo byte', () {
      final c = CortadorJpeg();
      expect(c.anadir(Uint8List.sublistView(todo, 0, cuadros[0].length - 1)), isEmpty);
      expect(c.aMedias, isTrue);
      expect(c.anadir([0xD9]).single, cuadros[0]);
    });

    test('lo de antes del primer SOI se tira y se cuenta', () {
      final c = CortadorJpeg();
      final r = c.anadir([1, 2, 3, 0xFF, ...cuadros[1]]);
      expect(r.single, cuadros[1]);
      expect(c.descartados, 4);
    });

    test('un cuadro que no acaba: se lanza en vez de llenar la RAM', () {
      final c = CortadorJpeg(maximo: 1000);
      final sinFin = jpegConTrampas(9, datos: 3000);
      expect(() => c.anadir(Uint8List.sublistView(sinFin, 0, sinFin.length - 2)), throwsFormatException);
    });

    test('basura donde va un marcador: se lanza', () {
      expect(() => CortadorJpeg().anadir([0xFF, 0xD8, 0x12, 0x34]), throwsFormatException);
    });

    test('lo que da ffmpeg de verdad (testsrc2, 160×90, q6): seis JPEG base 4:2:0 y nada suelto', () {
      final b = File('test/fixtures/servicios/mjpeg_ffmpeg_testsrc2_160x90.bin').readAsBytesSync();
      final r = cortar(b, Iterable.generate(b.length, (i) => 1 + i % 13));
      expect(r.length, 6);
      expect(juntar(r), b);
      for (final j in r) {
        expect(j.sublist(0, 2), [0xFF, 0xD8]);
        expect(j.sublist(j.length - 2), [0xFF, 0xD9]);
        // los segmentos hasta SOS, por su largo
        final marcas = <int>[];
        var o = 2;
        Uint8List? sof;
        while (true) {
          expect(j[o], 0xFF);
          final c = j[o + 1], l = (j[o + 2] << 8) | j[o + 3];
          marcas.add(c);
          if (c == 0xC0) sof = Uint8List.sublistView(j, o + 4, o + 2 + l);
          o += 2 + l;
          if (c == 0xDA) break;
        }
        expect(marcas, isNot(contains(0xDD)), reason: 'sin DRI');
        expect(marcas, isNot(contains(0xC2)), reason: 'base, no progresivo');
        expect(sof![5], 3, reason: 'tres componentes');
        expect([sof[7], sof[10], sof[13]], [0x22, 0x11, 0x11], reason: '4:2:0');
      }
    });
  });

  group('formato .w5v', () {
    test('cabecera: W5V1 y todo little-endian', () {
      expect(cabeceraW5v(160, 90, 12, 0x01020304),
          [0x57, 0x35, 0x56, 0x31, 160, 0, 90, 0, 12, 0, 0, 0, 4, 3, 2, 1]);
      expect(cabeceraW5v(320, 240, 15, 0).sublist(4, 8), [0x40, 0x01, 0xF0, 0x00]);
    });

    test('cuadro: n, pts y el JPEG; el fin', () {
      final j = Uint8List.fromList([0xFF, 0xD8, 7, 0xFF, 0xD9]);
      expect(cuadroW5v(0x0A0B0C, j), [5, 0, 0, 0, 0x0C, 0x0B, 0x0A, 0, ...j]);
      expect(finW5v(), [0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF]);
    });

    test('pts: del número de cuadro y los fps, con desde_ms sumado', () {
      const a = ParamsW5v(fps: 12);
      expect([for (var k = 0; k < 5; k++) a.pts(k)], [0, 83, 167, 250, 333]);
      expect(a.pts(12 * 60), 60000);
      expect(const ParamsW5v(fps: 15, desdeMs: 61000).pts(3), 61200);
    });
  });

  group('parámetros', () {
    test('lo de omisión es el del contrato', () {
      final p = ParamsW5v.de(const {});
      expect([p.an, p.al, p.fps, p.cal, p.desdeMs], [160, 90, 12, 6, 0]);
    });

    test('los bordes valen', () {
      final p = ParamsW5v.de(const {'an': '64', 'al': '36', 'fps': '4', 'cal': '2'});
      expect([p.an, p.al, p.fps, p.cal], [64, 36, 4, 2]);
      final q = ParamsW5v.de(const {'an': '320', 'al': '240', 'fps': '15', 'cal': '15', 'desde_ms': '90000'});
      expect([q.an, q.al, q.fps, q.cal, q.desdeMs], [320, 240, 15, 15, 90000]);
    });

    for (final (k, v) in [
      ('an', '161'), ('an', '62'), ('an', '322'), ('al', '91'), ('al', '34'), ('al', '242'), ('fps', '3'), ('fps', '16'),
      ('cal', '1'), ('cal', '16'), ('an', 'abc'), ('an', '-160'), ('an', '+160'), ('an', ' 160'), ('fps', '12.5'),
      ('desde_ms', '-1'), ('desde_ms', '1e3'), ('desde_ms', '99999999999'),
    ]) {
      test('$k=$v: ParametroMalo', () {
        expect(() => ParamsW5v.de({k: v}), throwsA(isA<ParametroMalo>()));
      });
    }

    test('el selector de formato pide lo que llega al cuadro, sin audio y sin m3u8 ni DASH', () {
      final f = selectorFormato(160, 90);
      expect(f, startsWith('wv[height>=90]'));
      expect(f, contains('wv[width>=160]'));
      expect(f.split('/').every((x) => x.contains('[protocol^=http][protocol!*=dash]')), isTrue);
    });

    test('ffmpeg: sin red, sin audio, MJPEG 4:2:0 de rango completo, un hilo, el tamaño y los fps', () {
      final a = argumentosFfmpegVideo(const ParamsW5v(an: 160, al: 90, fps: 12, cal: 7)).join(' ');
      expect(a, contains('-protocol_whitelist pipe -i pipe:0'));
      expect(a, isNot(contains('http')));
      expect(a, contains('-an'));
      expect(a, contains('-f image2pipe -c:v mjpeg -pix_fmt yuvj420p -q:v 7 pipe:1'));
      expect(a, contains('-threads 1'));
      expect(a, contains('fps=12,scale=160:90:force_original_aspect_ratio=decrease'));
      expect(a, contains('pad=160:90:(ow-iw)/2:(oh-ih)/2'));
      expect(a, isNot(contains('trim')));
      expect(argumentosFfmpegVideo(const ParamsW5v(desdeMs: 61500)).join(' '),
          contains('trim=start=61.500,setpts=PTS-STARTPTS,fps=12'));
    });
  });

  group('leer la búsqueda de yt-dlp', () {
    test('sin directos, sin anunciados, sin duración, sin ids raros ni repetidos', () {
      final v = leerBusquedaVideos({
        'entries': [
          {'id': 'aaaaaaaaaaa', 'title': 'Uno', 'channel': 'Canal', 'duration': 61, 'live_status': null},
          {'id': 'bbbbbbbbbbb', 'title': 'Directo', 'channel': 'C', 'duration': null, 'live_status': 'is_live'},
          {'id': 'ccccccccccc', 'title': 'Luego', 'channel': 'C', 'duration': 30, 'live_status': 'is_upcoming'},
          {'id': 'ddddddddddd', 'title': 'Sin duración', 'channel': 'C'},
          {'id': 'a b;c', 'title': 'Id raro', 'channel': 'C', 'duration': 5},
          {'id': 'aaaaaaaaaaa', 'title': 'Repetido', 'channel': 'C', 'duration': 5},
          {'id': 'eeeeeeeeeee', 'title': 'Canal', 'ie_key': 'YoutubeTab', 'duration': 5},
          {'id': 'fffffffffff', 'title': 'Del uploader', 'uploader': 'Subió', 'duration': 9.6, 'live_status': 'was_live'},
        ],
      });
      expect(v.map((x) => x.id), ['aaaaaaaaaaa', 'fffffffffff']);
      expect(v[1].canal, 'Subió');
      expect(v[1].durS, 10);
    });

    test('la línea: id, título, canal, duración; sin tabuladores ni saltos', () {
      final l = LetraTelefono.desdeTabla(File('assets/servicios/letra_telefono.bin').readAsBytesSync());
      expect(const Video('aaaaaaaaaaa', 'Gatos\tgraciosos\n2', 'Canal', 61).linea(l),
          'aaaaaaaaaaa\tGatos graciosos 2\tCanal\t61\n');
    });
  });

  group('en el servicio', () {
    final letra = LetraTelefono.desdeTabla(File('assets/servicios/letra_telefono.bin').readAsBytesSync());
    late Directory t;
    late OrigenSimulado o;
    late String yt, deno, ff;
    late ServicioMusica s;
    late int puerto;
    late List<Uint8List> cuadros;
    late List<Uri> bajadasImagen;

    // 30 resultados crudos: cada 4.º es un directo, el 7.º no tiene duración.
    Map<String, Object?> busqueda(int k) => {
          '_type': 'playlist',
          'entries': [
            for (var i = 0; i < min(k, 30); i++)
              {
                '_type': 'url',
                'ie_key': 'Youtube',
                'id': 'vid${'$i'.padLeft(8, '0')}',
                'title': i == 0 ? 'Gatos\tgraciosos\ncon salto' : 'Video $i',
                'channel': 'Canal $i',
                'duration': i == 7 ? null : 60 + i,
                'live_status': i % 4 == 3 ? 'is_live' : null,
              },
          ],
        };

    Future<void> arrancar({String? ffmpeg, int maxConversiones = 2}) async {
      final h = HerramientasMusica(ytDlp: () async => yt, deno: () async => deno, ffmpeg: () async => ffmpeg ?? ff);
      final pistas = Pistas(herramientas: h, permitirHttp: true, esperaReintento: const Duration(milliseconds: 10));
      final cat = Catalogo(red: RedGuardada());
      s = ServicioMusica(
        catalogo: cat,
        pistas: pistas,
        portadas: Portadas(cat, h.ffmpeg, bajar: (_) async => utf8.encode('jpeg')),
        videos: Videos(
          herramientas: h,
          bajar: pistas.bajarAudio,
          maxConversiones: maxConversiones,
          graciaCierre: const Duration(milliseconds: 300),
        ),
        miniaturas: Miniaturas(h.ffmpeg, bajar: (u) async {
          bajadasImagen.add(u);
          return utf8.encode('jpeg');
        }),
        letra: letra,
        puerto: 0,
      );
      await s.arrancar();
      puerto = s.servidor.puertoReal;
    }

    /// Un ffmpeg falso que se traga stdin, apunta lo que recibió y da [salida] (sh).
    // (Un proceso suelto de sh lee de /dev/null si no se le da otra entrada: por eso el 3.)
    Future<String> ffmpegQue(String nombre, String salida) => ejecutable(t, nombre, '''#!/bin/sh
printf '%s\\n' "\$@" > "${t.path}/args_ff"
exec 3<&0
(wc -c <&3 | tr -d ' ' > "${t.path}/stdin_ff") 2>/dev/null &
$salida
wait
''');

    setUp(() async {
      t = await carpetaTemporal();
      o = await OrigenSimulado.crear();
      o.ficheros['video'] = utf8.encode('V' * 30000);
      bajadasImagen = [];
      for (final k in [20, 40, 60]) {
        await File(p.join(t.path, 'b$k.json')).writeAsString(jsonEncode(busqueda(k)));
      }
      // 6 cuadros con trampas; el 3.º pasa de 32 KB y no se manda.
      cuadros = [
        for (var i = 0; i < 6; i++) i == 2 ? jpegConTrampas(i, tam: 40000) : jpegConTrampas(i, datos: 400 + 50 * i),
      ];
      await File(p.join(t.path, 'cuadros.mjpeg')).writeAsBytes(juntar(cuadros));
      await File(p.join(t.path, 'uno.jpg')).writeAsBytes(cuadros[0]);
      deno = await ejecutable(t, 'deno', '#!/bin/sh\nexit 0\n');
      // yt-dlp falso: busca de 20 en 20 o da la URL del origen; ids «malo…» no existen.
      yt = await ejecutable(t, 'yt-dlp', '''#!/bin/sh
for u; do :; done
printf '%s\\n' "\$@" >> "${t.path}/args_yt"
echo --- >> "${t.path}/args_yt"
case "\$u" in
  ytsearch20:*) cat "${t.path}/b20.json"; exit 0 ;;
  ytsearch40:*) cat "${t.path}/b40.json"; exit 0 ;;
  ytsearch60:*) cat "${t.path}/b60.json"; exit 0 ;;
  *v=malo*) echo "ERROR: [youtube] malo: Video unavailable" >&2; exit 1 ;;
  *v=vivo*) echo '{"url":"${o.url('video')}","duration":null,"is_live":true,"live_status":"is_live","http_headers":{}}'; exit 0 ;;
esac
echo '{"url":"${o.url('video')}","duration":66.4,"format_id":"160","width":256,"height":144,"vcodec":"avc1","http_headers":{"User-Agent":"Prueba"}}'
''');
      ff = await ffmpegQue('ffmpeg', 'cat "${t.path}/cuadros.mjpeg"');
      await arrancar();
    });

    tearDown(() async {
      await s.parar();
      await o.cerrar();
      await t.delete(recursive: true);
    });

    Future<int> corridasYt() async {
      final f = File(p.join(t.path, 'args_yt'));
      return f.existsSync() ? (await f.readAsLines()).where((l) => l == '---').length : 0;
    }

    test('buscar: W5VID, n, hay más y id·título·canal·duración; sin directos ni sin duración', () async {
      final r = await pedir(puerto, '/videos/buscar?q=gatos%20graciosos&n=10');
      expect(r.codigo, 200);
      expect(r.cab['Content-Type'], 'text/plain; charset=utf-8');
      final l = r.texto.split('\n');
      expect(l.first, 'W5VID 1\t10\t1');
      expect(l.last, '');
      final filas = l.sublist(1, l.length - 1).map((x) => x.split('\t')).toList();
      expect(filas.length, 10);
      expect(filas.every((f) => f.length == 4), isTrue);
      expect(filas.first, ['vid00000000', 'Gatos graciosos con salto', 'Canal 0', '60']);
      final ids = filas.map((f) => int.parse(f[0].substring(3))).toList();
      expect(ids.where((i) => i % 4 == 3 || i == 7), isEmpty);
      final a = await File(p.join(t.path, 'args_yt')).readAsLines();
      expect(a, containsAll(['--ignore-config', '--flat-playlist', '-J']));
      expect(a[a.length - 2], 'ytsearch20:gatos graciosos');
    });

    test('páginas: desde y n; pide más a yt-dlp solo cuando hace falta, y la caché vale', () async {
      expect((await pedir(puerto, '/videos/buscar?q=gatos&n=10')).texto, startsWith('W5VID 1\t10\t1\n'));
      expect(await corridasYt(), 1);
      // 20 crudos dan 15 que se ven: para 10..19 (y saber si hay más) hacen falta más
      final r = await pedir(puerto, '/videos/buscar?q=gatos&desde=10&n=10');
      expect(r.texto, startsWith('W5VID 1\t10\t1\n'));
      expect(await corridasYt(), 2);
      expect(r.texto.split('\n')[1], startsWith('vid00000013\t'));
      // 30 crudos (todos los que hay) dan 23: la tercera página trae 3 y ya no hay más,
      // sin volver a preguntar
      final u = await pedir(puerto, '/videos/buscar?q=gatos&desde=20&n=10');
      expect(u.texto, startsWith('W5VID 1\t3\t0\n'));
      expect(await corridasYt(), 2);
      await pedir(puerto, '/videos/buscar?q=gatos&desde=0&n=5');
      expect(await corridasYt(), 2, reason: 'de la caché');
    });

    test('n se acota a 20; sin q, 400', () async {
      expect((await pedir(puerto, '/videos/buscar?q=gatos&n=99')).texto, startsWith('W5VID 1\t20\t'));
      expect((await pedir(puerto, '/videos/buscar')).codigo, 400);
      expect((await pedir(puerto, '/videos/buscar?q=%20%20')).codigo, 400);
      expect((await pedir(puerto, '/videos/buscar?q=gatos&desde=x')).codigo, 400);
    });

    test('una consulta que parece una opción va dentro del argumento de la búsqueda', () async {
      await pedir(puerto, '/videos/buscar?q=--exec%20rm%20-rf');
      final a = await File(p.join(t.path, 'args_yt')).readAsLines();
      expect(a, contains('ytsearch20:--exec rm -rf'));
      expect(a, isNot(contains('--exec')));
    });

    test('el .w5v: cabeceras, W5V1, los JPEG enteros con su pts, el de más de 32 KB saltado, y el fin', () async {
      final r = await pedir(puerto, '/videos/abcdefghijk.w5v?an=160&al=90&fps=12');
      expect(r.codigo, 200);
      expect(r.cab['Content-Type'], 'application/octet-stream');
      expect(r.cab['X-Duracion-Ms'], '66400');
      expect(r.cab['X-Ancho'], '160');
      expect(r.cab['X-Alto'], '90');
      expect(r.cab['X-Fps'], '12');
      expect(r.cab.containsKey('Content-Length'), isFalse, reason: 'se manda según sale');
      final w = leerW5v(r.cuerpo);
      expect([w.an, w.al, w.fps, w.durMs], [160, 90, 12, 66400]);
      expect(w.fin, isTrue);
      expect(w.cuadros.map((c) => c.$1), [0, 83, 250, 333, 417], reason: 'el 2 (167 ms) no cabía');
      expect(w.cuadros.map((c) => c.$2).toList(), [cuadros[0], cuadros[1], cuadros[3], cuadros[4], cuadros[5]]);
      expect(w.cuadros.every((c) => c.$2.length <= 32 * 1024), isTrue);
      expect(s.videos.cuentas['cuadros_grandes'], 1);
    });

    test('la bajada: por rangos de 10 MiB y las cabeceras de yt-dlp; ffmpeg lo recibe por stdin', () async {
      await pedir(puerto, '/videos/abcdefghijk.w5v');
      expect(o.peticiones.single.$2, 'bytes=0-10485759');
      await esperarA(() => File(p.join(t.path, 'stdin_ff')).existsSync());
      expect((await File(p.join(t.path, 'stdin_ff')).readAsString()).trim(), '30000');
      final a = await File(p.join(t.path, 'args_ff')).readAsLines();
      expect(a.join(' '), isNot(contains('http')));
      expect(a.join(' '), contains('-protocol_whitelist pipe -i pipe:0'));
    });

    test('por trozos: cada rango acotado, el último corto, y un corte a mitad sigue desde el byte que falta', () async {
      final pistas = Pistas(
          herramientas: HerramientasMusica(ytDlp: () async => yt, deno: () async => deno, ffmpeg: () async => ff),
          permitirHttp: true,
          esperaReintento: const Duration(milliseconds: 10));
      final original = Uint8List.fromList(List.generate(30000, (i) => i * 7 & 255));
      o.ficheros['video'] = original;
      o.cortes.add(5000);
      final b = BytesBuilder();
      await pistas.bajarAudio(InfoAudio(o.url('video'), 1, const {}), (x) async => b.add(x), trozo: 7000);
      expect(b.takeBytes(), original);
      expect(o.peticiones.map((x) => x.$2), [
        'bytes=0-6999', // cortada en 5000
        'bytes=5000-11999',
        'bytes=12000-18999',
        'bytes=19000-25999',
        'bytes=26000-32999', // trae 26000-29999 y se acaba
      ]);
      pistas.parar();
    });

    test('por trozos: si el origen da otro rango, no se sigue a ciegas', () async {
      final pistas = Pistas(
          herramientas: HerramientasMusica(ytDlp: () async => yt, deno: () async => deno, ffmpeg: () async => ff),
          permitirHttp: true);
      o.rangoMentiroso = true;
      await expectLater(pistas.bajarAudio(InfoAudio(o.url('video'), 1, const {}), (_) async {}, trozo: 7000),
          throwsA(predicate((e) => '$e'.contains('rango'))));
      pistas.parar();
    });

    test('yt-dlp: el selector del tamaño pedido, sin configuración ajena y la URL al final', () async {
      await pedir(puerto, '/videos/--exec-sh12.w5v?an=320&al=240');
      final a = await File(p.join(t.path, 'args_yt')).readAsLines();
      expect(a, contains('--ignore-config'));
      expect(a, contains('deno:$deno'));
      expect(a[a.indexOf('-f') + 1], selectorFormato(320, 240));
      expect(a[a.length - 2], 'https://www.youtube.com/watch?v=--exec-sh12');
      expect(a, isNot(contains('--exec-sh12')));
    });

    test('desde_ms: pts desde ahí y ffmpeg recorta', () async {
      final r = await pedir(puerto, '/videos/abcdefghijk.w5v?fps=10&desde_ms=5000');
      expect(leerW5v(r.cuerpo).cuadros.first.$1, 5000);
      expect(leerW5v(r.cuerpo).cuadros[1].$1, 5100);
      expect((await File(p.join(t.path, 'args_ff')).readAsString()), contains('trim=start=5.000'));
    });

    test('desde_ms más allá del final: 400', () async {
      final r = await pedir(puerto, '/videos/abcdefghijk.w5v?desde_ms=66400');
      expect(r.codigo, 400);
    });

    test('mientras se convierte: el primer cuadro llega antes de que ffmpeg acabe', () async {
      await s.parar();
      final lento = await ffmpegQue('ff-lento', 'cat "${t.path}/uno.jpg"; sleep 1.5; cat "${t.path}/cuadros.mjpeg"');
      await arrancar(ffmpeg: lento);
      final reloj = Stopwatch()..start();
      final l = await Lector.pedir(puerto, '/videos/abcdefghijk.w5v');
      final cab = await l.cabeceras();
      expect(cab, startsWith('HTTP/1.0 200'));
      expect(await l.hasta(l.finCabeceras + 16 + 8 + cuadros[0].length), isTrue);
      final primero = reloj.elapsedMilliseconds;
      expect(primero, lessThan(1200), reason: 'no esperó al final');
      while (await l.it.moveNext()) {
        l.b.add(l.it.current);
      }
      expect(reloj.elapsedMilliseconds, greaterThan(1400));
      final ini = l.finCabeceras;
      final w = leerW5v(Uint8List.sublistView(l.b.takeBytes(), ini));
      expect(w.cuadros.length, 6);
      expect(w.fin, isTrue);
      l.colgar();
    });

    test('un cliente que solo cierra su mitad y sigue leyendo NO se corta', () async {
      await s.parar();
      final lento = await ffmpegQue('ff-lento', 'cat "${t.path}/uno.jpg"; sleep 1; cat "${t.path}/cuadros.mjpeg"');
      await arrancar(ffmpeg: lento);
      final l = await Lector.pedir(puerto, '/videos/abcdefghijk.w5v');
      await l.s.close(); // FIN: medio cierre
      await l.cabeceras();
      while (await l.it.moveNext().timeout(const Duration(seconds: 10))) {
        l.b.add(l.it.current);
      }
      final ini = l.finCabeceras;
      final w = leerW5v(Uint8List.sublistView(l.b.takeBytes(), ini));
      expect(w.cuadros.length, 6);
      expect(w.fin, isTrue);
      expect(s.videos.cuentas['cortados'], isNull);
      l.colgar();
    });

    group('el teléfono corta', () {
      late String pidf;
      setUp(() async {
        await s.parar();
        pidf = p.join(t.path, 'pid_ff');
        // Un ffmpeg que no acaba: un cuadro cada 20 ms, y apunta su pid.
        final sinFin = await ffmpegQue('ff-sinfin', '''echo \$\$ >> "$pidf"
while :; do cat "${t.path}/uno.jpg"; sleep 0.02; done''');
        await arrancar(ffmpeg: sinFin);
      });

      Future<List<String>> pids(int n) async {
        await esperarA(() => File(pidf).existsSync() && File(pidf).readAsLinesSync().length >= n);
        return File(pidf).readAsLinesSync();
      }

      test('se mata ffmpeg, se suelta la plaza y la bajada para', () async {
        final l = await Lector.pedir(puerto, '/videos/abcdefghijk.w5v');
        await l.cabeceras();
        expect(await l.hasta(l.finCabeceras + 16 + 3 * (8 + cuadros[0].length)), isTrue, reason: 'tres cuadros');
        final pid = (await pids(1)).single;
        expect(await vivo(pid), isTrue);
        expect(s.videos.activas, 1);
        l.colgar();
        await esperarA(() => s.videos.activas == 0);
        expect(s.videos.activas, 0);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(await vivo(pid), isFalse, reason: 'ffmpeg murió');
        expect(s.videos.cuentas['cortados'], 1);
        expect(o.peticiones.length, 1, reason: 'no se reintentó la bajada');
      });

      test('como mucho dos a la vez: la tercera 503 y, al cortar una, cabe otra', () async {
        final a = await Lector.pedir(puerto, '/videos/aaaaaaaaaaa.w5v');
        final b = await Lector.pedir(puerto, '/videos/bbbbbbbbbbb.w5v');
        expect(await a.cabeceras(), startsWith('HTTP/1.0 200'));
        expect(await b.cabeceras(), startsWith('HTTP/1.0 200'));
        final r = await pedir(puerto, '/videos/ccccccccccc.w5v');
        expect(r.codigo, 503);
        expect(r.texto, contains('2 videos'));
        a.colgar();
        await esperarA(() => s.videos.activas == 1);
        final c = await Lector.pedir(puerto, '/videos/ccccccccccc.w5v');
        expect(await c.cabeceras(), startsWith('HTTP/1.0 200'));
        expect(s.videos.activas, 2);
        b.colgar();
        c.colgar();
        await esperarA(() => s.videos.activas == 0);
        final ps = await pids(3);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        for (final x in ps) {
          expect(await vivo(x), isFalse, reason: 'ffmpeg $x');
        }
      });

      test('parar el servicio mata las conversiones', () async {
        final l = await Lector.pedir(puerto, '/videos/abcdefghijk.w5v');
        await l.cabeceras();
        final pid = (await pids(1)).single;
        await s.parar();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(await vivo(pid), isFalse);
        l.colgar();
      });
    });

    test('parámetros malos: 400 y yt-dlp ni corre', () async {
      for (final mal in [
        '/videos/abcdefghijk.w5v?an=161',
        '/videos/abcdefghijk.w5v?an=400',
        '/videos/abcdefghijk.w5v?al=35',
        '/videos/abcdefghijk.w5v?al=91',
        '/videos/abcdefghijk.w5v?fps=3',
        '/videos/abcdefghijk.w5v?fps=16',
        '/videos/abcdefghijk.w5v?fps=doce',
        '/videos/abcdefghijk.w5v?cal=1',
        '/videos/abcdefghijk.w5v?cal=16',
        '/videos/abcdefghijk.w5v?desde_ms=-5',
        '/videos/a%20b.w5v',
        '/videos/abc\$(id).w5v',
        '/videos/abc;def.w5v',
        '/videos/..%2Ffuera.w5v',
        '/videos/miniatura/a%20b',
        '/videos/miniatura/abcdefghijk?an=8',
        '/videos/miniatura/abcdefghijk?al=500',
      ]) {
        final r = await pedir(puerto, mal);
        expect(r.codigo, 400, reason: mal);
        expect(r.texto, startsWith('fallo: '), reason: mal);
      }
      expect(await corridasYt(), 0);
      expect(bajadasImagen, isEmpty);
    });

    test('un video que no existe: 502 con el porqué', () async {
      final r = await pedir(puerto, '/videos/malomalo123.w5v');
      expect(r.codigo, 502);
      expect(r.texto, contains('Video unavailable'));
      expect(s.videos.activas, 0);
    });

    test('un directo: 502 y ffmpeg ni arranca', () async {
      final r = await pedir(puerto, '/videos/vivovivo123.w5v');
      expect(r.codigo, 502);
      expect(r.texto, contains('directo'));
      expect(File(p.join(t.path, 'args_ff')).existsSync(), isFalse);
    });

    test('ffmpeg falla sin dar cuadros: 502 con su error', () async {
      await s.parar();
      await arrancar(ffmpeg: await ffmpegQue('ff-malo', 'echo "pipe:0: Invalid data found" >&2; exit 1'));
      final r = await pedir(puerto, '/videos/abcdefghijk.w5v');
      expect(r.codigo, 502);
      expect(r.texto, contains('Invalid data'));
    });

    test('ffmpeg muere a mitad: los cuadros que hubo y SIN el fin', () async {
      await s.parar();
      await arrancar(ffmpeg: await ffmpegQue('ff-mitad', 'cat "${t.path}/uno.jpg" "${t.path}/uno.jpg"; exit 1'));
      final r = await pedir(puerto, '/videos/abcdefghijk.w5v');
      expect(r.codigo, 200);
      final w = leerW5v(r.cuerpo);
      expect(w.cuadros.length, 2);
      expect(w.fin, isFalse);
    });

    test('la bajada no llega: 502 con el porqué del origen, no el de ffmpeg', () async {
      await s.parar();
      // Como ffmpeg: sin nada por stdin, no hay cuadros.
      final comoFf = await ejecutable(t, 'ff-stdin', '''#!/bin/sh
n=\$(wc -c | tr -d ' ')
if [ "\$n" -gt 0 ]; then cat "${t.path}/cuadros.mjpeg"; else echo "pipe:0: Invalid data found" >&2; exit 1; fi
''');
      await arrancar(ffmpeg: comoFf);
      o.ficheros.remove('video');
      final r = await pedir(puerto, '/videos/abcdefghijk.w5v');
      expect(r.codigo, 502);
      expect(r.texto, contains('HTTP 404'));
    });

    test('miniatura: RGB565 an×al de mqdefault, por ffmpeg sin red, con caché', () async {
      await s.parar();
      final img = await ejecutable(t, 'ffmpeg-img', '''#!/bin/sh
echo "\$@" >> "${t.path}/args_img"
cat > /dev/null
head -c ${80 * 45 * 2} /dev/zero
''');
      await arrancar(ffmpeg: img);
      final r = await pedir(puerto, '/videos/miniatura/abcdefghijk?an=80&al=45');
      expect(r.codigo, 200);
      expect(r.cuerpo.length, 7200);
      expect(r.cab['X-Ancho'], '80');
      expect(r.cab['X-Alto'], '45');
      expect(r.cab['X-Pixel'], 'RGB565-BE');
      expect(bajadasImagen.single.toString(), 'https://i.ytimg.com/vi/abcdefghijk/mqdefault.jpg');
      await pedir(puerto, '/videos/miniatura/abcdefghijk');
      final a = await File(p.join(t.path, 'args_img')).readAsLines();
      expect(a.length, 1, reason: 'la segunda, de la caché (80×45 es lo de omisión)');
      expect(a.single, contains('-protocol_whitelist pipe'));
      expect(a.single, contains('scale=80:45:force_original_aspect_ratio=increase'));
      expect(a.single, contains('crop=80:45,format=rgb565be'));
    });

    test('miniatura de un tamaño que ffmpeg no da: 502', () async {
      await s.parar();
      final img = await ejecutable(t, 'ffmpeg-img', '#!/bin/sh\ncat > /dev/null\nhead -c 100 /dev/zero\n');
      await arrancar(ffmpeg: img);
      expect((await pedir(puerto, '/videos/miniatura/abcdefghijk')).codigo, 502);
    });

    test('/estado cuenta los videos', () async {
      await pedir(puerto, '/videos/abcdefghijk.w5v');
      final r = await pedir(puerto, '/estado');
      expect(r.texto, contains('videos: 0 convirtiéndose'));
      expect(r.texto, contains('enteros: 1'));
    });

    test('lo de Música sigue igual: /videos no pisa /buscar ni /portada', () async {
      expect((await pedir(puerto, '/buscar?q=carefree&n=3')).texto, startsWith('W5MUS 1\t3\t'));
      expect((await pedir(puerto, '/videos/nada/mas/aqui')).codigo, 404);
    });
  });
}
