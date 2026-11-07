// El servicio de música en 127.0.0.1:8580: el mismo contrato que
// bt/musica_yt/servicio.py (docs/servicios_dictado_musica.md §1).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'catalogo_musica.dart';
import 'letra_telefono.dart';
import 'pistas_musica.dart';
import 'servidor_local.dart';
import 'videos_youtube.dart';

const puertoMusica = 8580;

const _plazoPrimerByte = Duration(seconds: 40);

/// Un id de canción. Se comprueba siempre: acaba en la línea de órdenes de un
/// programa y en una URL.
final _idValido = RegExp(r'^[A-Za-z0-9_-]{4,32}$');

class _Malo implements Exception {
  final String texto;
  _Malo(this.texto);

  @override
  String toString() => texto;
}

class Portadas {
  final Catalogo catalogo;
  final Future<String> Function() ffmpeg;
  final Future<List<int>> Function(Uri) bajar;
  final _cache = <String, Uint8List>{};

  Portadas(this.catalogo, this.ffmpeg, {Future<List<int>> Function(Uri)? bajar}) : bajar = bajar ?? _bajar;

  static Future<List<int>> _bajar(Uri url) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final pet = await c.getUrl(url);
      pet.headers.set('User-Agent', 'Mozilla/5.0');
      final res = await pet.close().timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      final b = BytesBuilder(copy: false);
      await res.timeout(const Duration(seconds: 10)).forEach(b.add);
      return b.takeBytes();
    } finally {
      c.close(force: true);
    }
  }

  /// RGB565 con el byte alto primero, lado × lado.
  Future<Uint8List> obtener(String id, int lado) async {
    final k = '$id/$lado';
    final hay = _cache[k];
    if (hay != null) return hay;
    final c = catalogo.meta[id];
    var url = c != null && c.portada.isNotEmpty ? c.portada : 'https://i.ytimg.com/vi/$id/hqdefault.jpg';
    if (url.contains('googleusercontent.com') && url.contains('=')) {
      url = '${url.substring(0, url.lastIndexOf('='))}=w${lado * 2}-h${lado * 2}-l90-rj';
    }
    final jpeg = await bajar(Uri.parse(url));
    // La miniatura del vídeo viene en 4:3 con bandas: el cuadrado del centro.
    final recorte = url.contains('ytimg.com') ? r'if(eq(iw\,ih)\,iw\,min(iw\,floor(ih*3/4)))' : r'min(iw\,ih)';
    final b = await imagenRgb565(
        await ffmpeg(), jpeg, 'crop=w=$recorte:h=$recorte,scale=$lado:$lado:flags=lanczos', lado * lado * 2, 'portada');
    _cache[k] = b;
    while (_cache.length > 64) {
      _cache.remove(_cache.keys.first);
    }
    return b;
  }
}

/// Una imagen (los bytes de un JPEG) a RGB565 con el byte alto primero, por ffmpeg
/// sin red: [filtro] la deja del tamaño que da [bytes].
Future<Uint8List> imagenRgb565(String ffmpeg, List<int> jpeg, String filtro, int bytes, String que) async {
  final pr = await Process.start(ffmpeg, [
    '-hide_banner', '-loglevel', 'error', '-nostdin',
    '-protocol_whitelist', 'pipe',
    '-i', 'pipe:0',
    '-vf', '$filtro,format=rgb565be',
    '-frames:v', '1', '-f', 'rawvideo', 'pipe:1',
  ]);
  final salida = BytesBuilder(copy: false);
  final leer = pr.stdout.forEach(salida.add);
  final err = pr.stderr.transform(utf8.decoder).join();
  pr.stdin.add(jpeg);
  await pr.stdin.close().catchError((Object _) {});
  final codigo = await pr.exitCode.timeout(const Duration(seconds: 20), onTimeout: () {
    pr.kill(ProcessSignal.sigkill);
    return -1;
  });
  await leer;
  final b = salida.takeBytes();
  if (codigo != 0 || b.length != bytes) throw HttpException('$que: ffmpeg $codigo ${await err}');
  return b;
}

/// La miniatura de un video de YouTube, an × al, para la lista de la app Videos.
/// La de 320×180 (mqdefault) no trae bandas: se rellena el cuadro y se recorta lo
/// que sobre por los lados o por arriba y abajo.
class Miniaturas {
  final Future<String> Function() ffmpeg;
  final Future<List<int>> Function(Uri) bajar;
  final _cache = <String, Uint8List>{};

  Miniaturas(this.ffmpeg, {required this.bajar});

  Future<Uint8List> obtener(String id, int an, int al) async {
    final k = '$id/${an}x$al';
    final hay = _cache[k];
    if (hay != null) return hay;
    final jpeg = await bajar(Uri.parse('https://i.ytimg.com/vi/$id/mqdefault.jpg'));
    final b = await imagenRgb565(await ffmpeg(), jpeg,
        'scale=$an:$al:force_original_aspect_ratio=increase:flags=lanczos,crop=$an:$al', an * al * 2, 'miniatura');
    _cache[k] = b;
    while (_cache.length > 128) {
      _cache.remove(_cache.keys.first);
    }
    return b;
  }
}

class ServicioMusica {
  final Catalogo catalogo;
  final Pistas pistas;
  final Portadas portadas;
  final LetraTelefono letra;
  final String versiones;
  final void Function(String)? registro;

  /// La app Videos (docs/contrato_videos.md): con los mismos yt-dlp y ffmpeg, y la
  /// bajada de Pistas.
  late final Videos videos;
  late final Miniaturas miniaturas;

  late final ServidorLocal servidor;
  final _t0 = DateTime.now();

  ServicioMusica({
    required this.catalogo,
    required this.pistas,
    required this.portadas,
    required this.letra,
    Videos? videos,
    Miniaturas? miniaturas,
    this.versiones = '',
    int puerto = puertoMusica,
    this.registro,
  }) {
    this.videos = videos ?? Videos(herramientas: pistas.herramientas, bajar: pistas.bajarAudio, registro: registro);
    this.miniaturas = miniaturas ?? Miniaturas(pistas.herramientas.ffmpeg, bajar: portadas.bajar);
    servidor = ServidorLocal(puerto: puerto, nombre: 'senus-musica/1', manejador: _atender, registro: registro);
  }

  Future<void> arrancar() => servidor.arrancar();

  Future<void> parar() async {
    videos.parar();
    pistas.parar();
    await servidor.parar();
  }

  String estado() {
    final r = <String>[
      'senus-musica: $versiones; en marcha desde hace ${DateTime.now().difference(_t0).inSeconds} s',
      'cuentas: ${pistas.cuentas}',
      videos.estado(),
      for (final e in pistas.p.entries)
        '${e.key} ${e.value.fin ? 'ENTERA' : e.value.fallo != null ? 'FALLO' : 'convirtiendo'} ${e.value.n} B '
            '${e.value.durMs} ms lectores ${e.value.lectores}${e.value.fallo != null ? ' ${e.value.fallo}' : ''}',
    ];
    return '${r.join('\n')}\n';
  }

  int _entero(String? v, int omision) {
    if (v == null || v.isEmpty) return omision;
    return int.tryParse(v) ?? (throw _Malo('número mal formado: $v'));
  }

  String _id(String s) => _idValido.hasMatch(s) ? s : throw _Malo('id mal formado');

  Future<void> _atender(PeticionLocal pet, RespuestaLocal res) async {
    final q = pet.consulta;
    final partes = pet.ruta.split('/').where((p) => p.isNotEmpty).toList();
    final reloj = Stopwatch()..start();
    try {
      if (pet.metodo != 'GET') {
        await res.responder(501, 'fallo: solo GET\n');
      } else if (partes.length == 1 && partes[0] == 'buscar' && (q['q'] ?? '').trim().isNotEmpty) {
        final desde = math.max(0, _entero(q['desde'], 0));
        final n = _entero(q['n'], 10).clamp(1, 20);
        final (lista, mas) = await catalogo.buscar(q['q']!, desde, n);
        await res.responder(200, 'W5MUS 1\t${lista.length}\t${mas ? 1 : 0}\n${lista.map((c) => c.linea(letra)).join()}');
        registro?.call('buscar desde $desde: ${lista.length} en ${reloj.elapsedMilliseconds} ms');
      } else if (partes.length == 2 && partes[0] == 'siguientes') {
        final lista = await catalogo.siguientes(_id(partes[1]), _entero(q['n'], 10).clamp(1, 25));
        await res.responder(200, 'W5MUS 1\t${lista.length}\t0\n${lista.map((c) => c.linea(letra)).join()}');
        registro?.call('siguientes ${partes[1]}: ${lista.length} en ${reloj.elapsedMilliseconds} ms');
      } else if (partes.length == 2 && partes[0] == 'pista' && partes[1].endsWith('.mp3')) {
        final id = _id(partes[1].substring(0, partes[1].length - 4));
        final sig = q['sig'] ?? '';
        await _pista(res, id, _entero(q['desde_ms'], 0), sig.isEmpty ? '' : _id(sig), _rango(pet));
      } else if (partes.length == 2 && partes[0] == 'preparar') {
        pistas.obtener(_id(partes[1]));
        await res.responder(202, 'preparando\n');
      } else if (partes.length == 2 && partes[0] == 'portada') {
        final lado = _entero(q['lado'], 56).clamp(16, 128);
        await res.responder(
          200,
          await portadas.obtener(_id(partes[1]), lado),
          tipo: 'application/octet-stream',
          extra: [('X-Ancho', '$lado'), ('X-Alto', '$lado'), ('X-Pixel', 'RGB565-BE')],
        );
      } else if (partes.length == 1 && partes[0] == 'estado') {
        await res.responder(200, estado());
      } else if (partes.length >= 2 && partes[0] == 'videos') {
        await _videos(pet, res, partes.sublist(1), q, reloj);
      } else {
        await res.responder(404, 'no existe: ${pet.ruta}\n');
      }
    } on SocketException {
      registro?.call('${pet.ruta}: el teléfono cortó');
    } on ParametroMalo catch (e) {
      registro?.call('${pet.ruta}: 400 $e');
      if (!res.empezada) await res.responder(400, 'fallo: $e\n', extra: const [('X-Error', '400')]);
    } on Ocupado catch (e) {
      registro?.call('${pet.ruta}: 503 $e');
      if (!res.empezada) await res.responder(503, 'fallo: $e\n', extra: const [('X-Error', '503')]);
    } on Object catch (e) {
      registro?.call('${pet.ruta}: FALLO ${e.runtimeType}: $e');
      if (!res.empezada) {
        final t = e is HttpException ? e.message : '${e.runtimeType}: $e';
        await res.responder(502, 'fallo: ${t.length > 220 ? t.substring(0, 220) : t}\n',
            extra: [('X-Error', e.runtimeType.toString())]);
      }
    }
  }

  /// /videos/buscar, /videos/<id>.w5v y /videos/miniatura/<id> (docs/contrato_videos.md).
  /// Un parámetro que no case con el contrato es un 400 antes de ejecutar nada.
  Future<void> _videos(
      PeticionLocal pet, RespuestaLocal res, List<String> partes, Map<String, String> q, Stopwatch reloj) async {
    if (partes.length == 1 && partes[0] == 'buscar') {
      final texto = BuscadorVideos.normalizar(q['q'] ?? '');
      if (texto.isEmpty) throw const ParametroMalo('falta q');
      final desde = enteroDe(q, 'desde', 0);
      final n = enteroDe(q, 'n', 10).clamp(1, 20);
      final (lista, mas) = await videos.buscador.buscar(texto, desde, n);
      await res.responder(200, 'W5VID 1\t${lista.length}\t${mas ? 1 : 0}\n${lista.map((v) => v.linea(letra)).join()}');
      registro?.call('videos/buscar desde $desde: ${lista.length} en ${reloj.elapsedMilliseconds} ms');
    } else if (partes.length == 1 && partes[0].endsWith('.w5v')) {
      final id = idDeVideo(partes[0].substring(0, partes[0].length - 4));
      await videos.servirW5v(res, id, ParamsW5v.de(q), cierre: pet.vigilarCierre());
    } else if (partes.length == 2 && partes[0] == 'miniatura') {
      final id = idDeVideo(partes[1]);
      final an = enteroDe(q, 'an', 80), al = enteroDe(q, 'al', 45);
      if (an < 16 || an > 320 || al < 9 || al > 240) throw ParametroMalo('miniatura de ${an}x$al: fuera de 16..320 × 9..240');
      await res.responder(
        200,
        await miniaturas.obtener(id, an, al),
        tipo: 'application/octet-stream',
        extra: [('X-Ancho', '$an'), ('X-Alto', '$al'), ('X-Pixel', 'RGB565-BE')],
      );
    } else {
      await res.responder(404, 'no existe: /videos/${partes.join('/')}\n');
    }
  }

  int? _rango(PeticionLocal pet) {
    final r = (pet.cabecera('Range') ?? '').replaceAll(' ', '');
    final m = RegExp(r'^bytes=(\d+)-$').firstMatch(r);
    return m == null ? null : int.parse(m.group(1)!);
  }

  Future<void> _pista(RespuestaLocal res, String id, int desdeMs, String sig, int? byte) async {
    final p = pistas.obtener(id);
    final reloj = Stopwatch()..start();
    final quiero = byte ?? desdeMs * bPorMs;
    p.lectores++;
    try {
      await p.esperar(() => p.fallo != null || p.fin || p.n > quiero + 4096, _plazoPrimerByte);
      if (p.fallo != null || p.n == 0) {
        throw HttpException(p.fallo ?? 'no llegó nada en ${_plazoPrimerByte.inSeconds} s');
      }
      int o;
      if (byte != null) {
        // Range: el byte exacto (empalmar), sin alinear.
        await p.esperar(() => p.fallo != null || p.fin || p.n > byte, _plazoPrimerByte);
        if (p.fin && byte >= p.n) throw HttpException('Range $byte fuera de la pista (${p.n} B)');
        o = byte;
      } else {
        o = alinear(p.datos, p.n, math.min(quiero, p.n)) ?? (p.fin ? p.n : 0);
      }
      final cab = <(String, String)>[
        ('Content-Type', 'audio/mpeg'),
        ('X-Duracion-Ms', '${p.durMs}'),
        ('X-Desde-Ms', '${o ~/ bPorMs}'),
        ('X-Desde-Byte', '$o'),
        ('X-Kbps', '$kbps'),
      ];
      final entera = p.fin;
      if (entera) {
        cab.add(('Content-Length', '${p.n - o}'));
        if (byte != null) cab.add(('Content-Range', 'bytes $o-${p.n - 1}/${p.n}'));
      }
      if (sig.isNotEmpty) pistas.despues(p, sig);
      res.empezar(byte != null ? 206 : 200, cab);
      var pos = o, enviados = 0;
      while (true) {
        await p.esperar(() => p.n > pos || p.fin || p.fallo != null, const Duration(seconds: 60));
        final fin = math.min(pos + 16384, p.n);
        final trozo = fin > pos ? Uint8List.fromList(Uint8List.sublistView(p.datos, pos, fin)) : Uint8List(0);
        final acabada = (p.fin || p.fallo != null) && pos + trozo.length >= p.n;
        if (trozo.isNotEmpty) {
          await res.escribir(trozo);
          pos += trozo.length;
          enviados += trozo.length;
        }
        if (acabada && trozo.isEmpty) break;
        if (trozo.isEmpty && !acabada) throw const HttpException('la conversión se paró');
      }
      registro?.call('pista $id desde ${o ~/ bPorMs} ms: $enviados B en ${reloj.elapsedMilliseconds} ms '
          '(${entera ? 'ya entera' : 'según se convertía'})');
    } finally {
      p.lectores--;
      p.uso = DateTime.now();
    }
  }
}
