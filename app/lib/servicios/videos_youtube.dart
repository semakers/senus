// Los videos de YouTube para la app «Videos» del teléfono: el lado de SENUS de
// docs/contrato_videos.md, en el mismo puerto que Música (8580).
//
//   - Buscar: `yt-dlp --flat-playlist -J "ytsearchN:…"`, sin directos ni videos sin
//     duración, con caché corta por consulta.
//   - Ver: el video SIN sonido como cuadros JPEG con su tiempo (.w5v), según se
//     convierten. yt-dlp elige el formato de video más pequeño que llegue al
//     tamaño pedido y da su URL; Dart lo baja por rangos de 10 MiB con la
//     verificación TLS de dart:io (Pistas.bajarAudio, la de Música); ffmpeg lo
//     recibe por stdin, sin red (`-protocol_whitelist pipe`), y saca MJPEG por
//     stdout; se corta en JPEG por sus marcadores (cortador_jpeg.dart) y cada uno
//     sale con su cabecera de 8 bytes en cuanto está entero.
//   - La URL se saca antes de responder porque las cabeceras llevan la duración
//     (X-Duracion-Ms) y porque así un video que no existe da 502 con el porqué.
//
// El sonido es el de Música, sin cambios: /pista/<id>.mp3. NADA al disco: los
// cuadros pasan por la RAM y se sueltan al mandarlos.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'cortador_jpeg.dart';
import 'letra_telefono.dart';
import 'pistas_musica.dart';
import 'servidor_local.dart';

/// Un id de YouTube: la misma expresión que Música.
final idVideoValido = RegExp(r'^[A-Za-z0-9_-]{4,32}$');

/// Lo que el teléfono pidió mal: 400.
class ParametroMalo implements Exception {
  final String texto;
  const ParametroMalo(this.texto);

  @override
  String toString() => texto;
}

/// Ya hay tantas conversiones como se permiten: 503.
class Ocupado implements Exception {
  final String texto;
  const Ocupado(this.texto);

  @override
  String toString() => texto;
}

String idDeVideo(String s) => idVideoValido.hasMatch(s) ? s : throw const ParametroMalo('id mal formado');

/// Un número entero sin signo, sin espacios y sin más: lo que no sea eso, 400.
int enteroDe(Map<String, String> q, String nombre, int omision) {
  final v = q[nombre];
  if (v == null || v.isEmpty) return omision;
  if (!RegExp(r'^\d{1,9}$').hasMatch(v)) throw ParametroMalo('$nombre mal formado: $v');
  return int.parse(v);
}

int _enRango(Map<String, String> q, String nombre, int omision, int min, int max, {bool par = false}) {
  final v = enteroDe(q, nombre, omision);
  if (v < min || v > max) throw ParametroMalo('$nombre fuera de $min..$max: $v');
  if (par && v.isOdd) throw ParametroMalo('$nombre tiene que ser par: $v');
  return v;
}

// ------------------------------------------------------------------ buscar

class Video {
  final String id, titulo, canal;
  final int durS;

  const Video(this.id, this.titulo, this.canal, this.durS);

  /// `<id>\t<título>\t<canal>\t<duración en s>\n`
  String linea(LetraTelefono l) => '$id\t${l.para(titulo)}\t${l.para(canal, 64)}\t$durS\n';
}

const _sinVer = {'is_live', 'is_upcoming', 'post_live'};

/// Las entradas de `yt-dlp --flat-playlist -J "ytsearchN:…"` que se pueden ver:
/// ni directos, ni anunciados, ni sin duración, y con un id que pasa la expresión.
List<Video> leerBusquedaVideos(Map json) {
  final e = json['entries'];
  if (e is! List) throw const FormatException('la búsqueda no trae entries');
  final out = <Video>[];
  final vistos = <String>{};
  for (final x in e) {
    if (x is! Map) continue;
    final id = x['id'];
    if (id is! String || !idVideoValido.hasMatch(id) || !vistos.add(id)) continue;
    final ie = x['ie_key'];
    if (ie != null && ie != 'Youtube') continue; // canales, listas
    if (_sinVer.contains(x['live_status']) || x['is_live'] == true) continue;
    final d = x['duration'];
    if (d is! num || d < 1) continue;
    final canal = x['channel'] ?? x['uploader'] ?? '';
    out.add(Video(id, '${x['title'] ?? ''}', '$canal', d.round()));
  }
  return out;
}

/// Lo que da yt-dlp por la salida estándar, o HttpException con su último error.
typedef CorrerProceso = Future<String> Function(String ejecutable, List<String> args, Duration plazo);

class BuscadorVideos {
  final HerramientasMusica herramientas;
  final CorrerProceso correr;
  final DateTime Function() ahora;
  final Duration vida;
  final Duration plazo;

  /// Lo que se le pide a yt-dlp como mucho: con más, cada página tarda más.
  static const tope = 60;

  final _cache = <String, (DateTime, List<Video>, bool)>{};
  final _enCurso = <String, Future<(List<Video>, bool)>>{};
  int busquedas = 0;

  BuscadorVideos({
    required this.herramientas,
    required this.correr,
    DateTime Function()? ahora,
    this.vida = const Duration(minutes: 5),
    this.plazo = const Duration(seconds: 30),
  }) : ahora = ahora ?? DateTime.now;

  static String normalizar(String q) {
    final t = q.split(RegExp(r'\s+')).where((x) => x.isNotEmpty).join(' ');
    return t.length > 120 ? t.substring(0, 120) : t;
  }

  /// [k] resultados de YouTube: (los que se pueden ver, se acabaron los que hay).
  Future<(List<Video>, bool)> _pedir(String q, int k) async {
    busquedas++;
    final cache = herramientas.cacheYtDlp;
    final t = await correr(await herramientas.ytDlp(), [
      '--ignore-config',
      '--no-warnings',
      '--no-progress',
      if (cache != null) ...['--cache-dir', cache] else '--no-cache-dir',
      '--flat-playlist',
      '-J',
      // Un solo argumento que empieza por «ytsearch»: la consulta nunca es una opción.
      'ytsearch$k:$q',
    ], plazo);
    final j = jsonDecode(t);
    if (j is! Map) throw const FormatException('la búsqueda no es un objeto');
    final crudos = j['entries'] is List ? (j['entries'] as List).length : 0;
    return (leerBusquedaVideos(j), crudos < k);
  }

  /// (la página, hay más).
  Future<(List<Video>, bool)> buscar(String consulta, int desde, int n) async {
    final q = normalizar(consulta);
    final quiero = desde + n + 1; // uno más: para saber si hay más
    var hay = _cache[q];
    if (hay == null || ahora().difference(hay.$1) > vida || (hay.$2.length < quiero && !hay.$3)) {
      final enCurso = _enCurso[q];
      // (Las llaves importan: devolver lo que quita remove sería esperar a este mismo futuro.)
      final (lista, agotada) = await (enCurso ??
          (_enCurso[q] = _llenar(q, quiero).whenComplete(() {
            _enCurso.remove(q);
          })));
      hay = (ahora(), lista, agotada);
      _cache.remove(q);
      _cache[q] = hay;
      while (_cache.length > 20) {
        _cache.remove(_cache.keys.first);
      }
    }
    final lista = hay.$2;
    final fin = desde + n < lista.length ? desde + n : lista.length;
    return (desde >= lista.length ? <Video>[] : lista.sublist(desde, fin), lista.length > desde + n);
  }

  Future<(List<Video>, bool)> _llenar(String q, int quiero) async {
    // De 20 en 20 (lo que da YouTube por página), hasta tener [quiero] que se vean.
    var k = ((quiero + 19) ~/ 20 * 20).clamp(20, tope);
    while (true) {
      final (lista, agotada) = await _pedir(q, k);
      if (lista.length >= quiero || agotada || k >= tope) return (lista, agotada || k >= tope);
      k = (k + 20).clamp(20, tope);
    }
  }
}

// ------------------------------------------------------------------ .w5v

class ParamsW5v {
  final int an, al, fps, cal, desdeMs;
  const ParamsW5v({this.an = 160, this.al = 90, this.fps = 12, this.cal = 6, this.desdeMs = 0});

  /// Los de la consulta, comprobados: lo que no case con el contrato, [ParametroMalo].
  factory ParamsW5v.de(Map<String, String> q) => ParamsW5v(
        an: _enRango(q, 'an', 160, 64, 320, par: true),
        al: _enRango(q, 'al', 90, 36, 240, par: true),
        fps: _enRango(q, 'fps', 12, 4, 15),
        cal: _enRango(q, 'cal', 6, 2, 15),
        desdeMs: _enRango(q, 'desde_ms', 0, 0, 24 * 3600 * 1000),
      );

  /// El tiempo del cuadro [k] de ffmpeg (el filtro fps los da a k/fps exactos).
  int pts(int k) => desdeMs + (k * 1000 / fps).round();
}

/// El cuadro más grande que se manda: el teléfono tiene 32 KB para uno.
const maxCuadroW5v = 32 * 1024;

/// 'W5V1' u16 ancho, u16 alto, u16 fps, u16 0, u32 duración_ms. Little-endian.
Uint8List cabeceraW5v(int an, int al, int fps, int durMs) {
  final b = ByteData(16);
  b.setUint8(0, 0x57); // W
  b.setUint8(1, 0x35); // 5
  b.setUint8(2, 0x56); // V
  b.setUint8(3, 0x31); // 1
  b.setUint16(4, an, Endian.little);
  b.setUint16(6, al, Endian.little);
  b.setUint16(8, fps, Endian.little);
  b.setUint16(10, 0, Endian.little);
  b.setUint32(12, durMs, Endian.little);
  return b.buffer.asUint8List();
}

/// u32 n, u32 pts_ms y los n bytes del JPEG.
Uint8List cuadroW5v(int ptsMs, Uint8List jpeg) {
  final b = Uint8List(8 + jpeg.length);
  ByteData.sublistView(b)
    ..setUint32(0, jpeg.length, Endian.little)
    ..setUint32(4, ptsMs, Endian.little);
  b.setRange(8, b.length, jpeg);
  return b;
}

/// u32 0, u32 0xFFFFFFFF.
Uint8List finW5v() {
  final b = ByteData(8)..setUint32(4, 0xFFFFFFFF, Endian.little);
  return b.buffer.asUint8List();
}

const _https = '[protocol^=http][protocol!*=dash]';

/// El formato de video más pequeño que llegue al tamaño pedido, sin audio y
/// bajable de un tirón (nada de m3u8 ni de trozos DASH). «Llegar» es no tener que
/// ampliar: que el ancho o el alto lleguen al del cuadro. Si ninguno llega, el
/// mayor; si no hay ninguno solo de video, el de video y sonido (ffmpeg quita el sonido).
String selectorFormato(int an, int al) => 'wv[height>=$al]$_https/wv[width>=$an]$_https/bv$_https/b$_https';

/// ffmpeg: stdin → MJPEG por stdout. Sin red. Un solo hilo en el codificador: con
/// hilos de corte (`-thread_type slice`) el MJPEG de ffmpeg 9.0.2 mete DRI y RSTn, y
/// el decodificador del teléfono no los lleva [medido]; con los de omisión no, pero
/// así no depende de ellos.
List<String> argumentosFfmpegVideo(ParamsW5v p) {
  final w = p.an, h = p.al;
  final filtro = [
    if (p.desdeMs > 0) ...['trim=start=${(p.desdeMs / 1000).toStringAsFixed(3)}', 'setpts=PTS-STARTPTS'],
    'fps=${p.fps}',
    'scale=$w:$h:force_original_aspect_ratio=decrease:force_divisible_by=2:flags=area',
    'pad=$w:$h:(ow-iw)/2:(oh-ih)/2:color=black',
    'setsar=1',
  ].join(',');
  return [
    '-hide_banner', '-loglevel', 'error', '-nostdin',
    '-protocol_whitelist', 'pipe', // sin red: lee stdin y nada más
    '-i', 'pipe:0',
    '-an', '-sn', '-dn',
    '-vf', filtro,
    '-threads', '1',
    '-f', 'image2pipe', '-c:v', 'mjpeg', '-pix_fmt', 'yuvj420p', '-q:v', '${p.cal}',
    'pipe:1',
  ];
}

class InfoVideo {
  final InfoAudio fuente; // la URL, sus cabeceras y su available_at: lo que baja Pistas.bajarAudio
  final int durMs;
  final bool vivo;
  final String formato;

  const InfoVideo(this.fuente, this.durMs, {this.vivo = false, this.formato = ''});
}

/// El último trozo de lo que escriba un proceso por stderr, sin llenar la RAM.
Future<String> colaDeTexto(Stream<List<int>> s, {int max = 2000}) async {
  var t = '';
  await for (final x in s.transform(const Utf8Decoder(allowMalformed: true))) {
    t += x;
    if (t.length > max) t = t.substring(t.length - max);
  }
  return t;
}

/// El teléfono dejó de leer.
class _Corte implements Exception {
  const _Corte();
}

/// Bajar la URL de un formato y dárselo a [escribir] trozo a trozo.
typedef BajarFuente = Future<void> Function(InfoAudio i, Future<void> Function(List<int>) escribir, {int? trozo});

class Videos {
  final HerramientasMusica herramientas;
  final BajarFuente bajar;
  final int maxConversiones;
  final Duration plazoExtraer;
  final Duration plazoPrimerCuadro;

  /// Lo que se espera a que salga lo escrito tras ver que el otro lado cerró.
  final Duration graciaCierre;

  /// La bajada va por rangos de este tamaño (Pistas.bajarAudio).
  final int trozoBajada;
  final void Function(String)? registro;
  late final BuscadorVideos buscador;

  final _procesos = <Process>{};
  int activas = 0;
  bool _parado = false;
  final cuentas = <String, int>{};

  Videos({
    required this.herramientas,
    required this.bajar,
    this.maxConversiones = 2,
    this.plazoExtraer = const Duration(seconds: 60),
    this.plazoPrimerCuadro = const Duration(seconds: 40),
    this.graciaCierre = const Duration(seconds: 2),
    this.trozoBajada = 10 << 20,
    this.registro,
    CorrerProceso? correr,
    DateTime Function()? ahora,
  }) {
    buscador = BuscadorVideos(herramientas: herramientas, correr: correr ?? _correr, ahora: ahora);
  }

  void _contar(String k) => cuentas[k] = (cuentas[k] ?? 0) + 1;

  Future<String> _correr(String exe, List<String> args, Duration plazo) async {
    final pr = await Process.start(exe, args);
    _procesos.add(pr);
    try {
      final salida = pr.stdout.transform(utf8.decoder).join();
      final errores = colaDeTexto(pr.stderr);
      final codigo = await pr.exitCode.timeout(plazo);
      final texto = await salida, err = await errores;
      if (codigo != 0) {
        final linea = err.trim().split('\n').last;
        throw HttpException(linea.length > 240 ? linea.substring(linea.length - 240) : linea);
      }
      return texto;
    } on TimeoutException {
      pr.kill(ProcessSignal.sigkill);
      throw HttpException('yt-dlp tardó más de ${plazo.inSeconds} s');
    } finally {
      _procesos.remove(pr);
    }
  }

  /// La URL del formato que toca, su duración y si es un directo.
  Future<InfoVideo> extraer(String id, int an, int al) async {
    final yt = await herramientas.ytDlp();
    final deno = await herramientas.deno();
    final cache = herramientas.cacheYtDlp;
    final t = await buscador.correr(yt, [
      '--ignore-config', // ningún fichero de configuración ajeno: nada de --exec
      '--no-warnings',
      '--no-playlist',
      '--no-progress',
      '--js-runtimes', 'deno:$deno',
      if (cache != null) ...['--cache-dir', cache] else '--no-cache-dir',
      '-f', selectorFormato(an, al),
      '-j',
      'https://www.youtube.com/watch?v=$id',
    ], plazoExtraer);
    final j = jsonDecode(t);
    if (j is! Map) throw const FormatException('yt-dlp no dio un objeto');
    final url = j['url'];
    if (url is! String) throw const HttpException('yt-dlp no dio la URL del video');
    final cab = <String, String>{};
    (j['http_headers'] as Map?)?.forEach((k, v) => cab['$k'] = '$v');
    final at = j['available_at'] as num?;
    final d = j['duration'];
    return InfoVideo(
      InfoAudio(url, d is num ? d.round() : 0, cab,
          disponible: at == null ? null : DateTime.fromMillisecondsSinceEpoch((at * 1000).round())),
      d is num ? (d * 1000).round() : 0,
      vivo: j['is_live'] == true || _sinVer.contains(j['live_status']),
      formato: '${j['format_id']} ${j['width']}x${j['height']} ${j['vcodec']}',
    );
  }

  /// El .w5v por [res]. Lanza antes de empezar la respuesta (502, 400, 503); una vez
  /// empezada, un corte del teléfono acaba aquí sin más y mata la tubería.
  Future<void> servirW5v(RespuestaLocal res, String id, ParamsW5v p, {Future<void>? cierre}) async {
    if (activas >= maxConversiones) {
      _contar('rechazadas');
      throw Ocupado('ya hay $maxConversiones videos convirtiéndose');
    }
    activas++;
    _contar('pedidas');
    final reloj = Stopwatch()..start();
    Process? pr;
    StreamIterator<List<int>>? it;
    var cancelado = false;
    String? falloBajada;
    var ffmpegNoLee = false;
    var cuadros = 0, grandes = 0, bytes = 0, tExtraer = 0, tPrimero = 0;
    var como = 'falló';
    try {
      final info = await extraer(id, p.an, p.al);
      tExtraer = reloj.elapsedMilliseconds;
      if (info.vivo) throw const HttpException('es un directo: no se puede ver');
      if (info.durMs > 0 && p.desdeMs >= info.durMs) {
        throw ParametroMalo('desde_ms pasa del final del video (${info.durMs} ms)');
      }
      final ff = await herramientas.ffmpeg();
      if (_parado) throw const HttpException('el servicio se está parando');
      final proc = pr = await Process.start(ff, argumentosFfmpegVideo(p));
      _procesos.add(proc);
      final errores = colaDeTexto(proc.stderr); // no falla: ni con bytes que no sean UTF-8
      // Si ffmpeg muere, escribir falla: lo cuenta la bajada, no un error suelto.
      unawaited(proc.stdin.done.catchError((Object _) {}));
      unawaited(bajar(info.fuente, (b) async {
        if (cancelado) throw const HttpException('cancelado');
        try {
          proc.stdin.add(b);
          await proc.stdin.flush();
        } on Object {
          ffmpegNoLee = true;
          rethrow;
        }
      }, trozo: trozoBajada).then((_) {}, onError: (Object e) {
        if (!cancelado) falloBajada = e is HttpException ? e.message : '${e.runtimeType}';
      }).whenComplete(() => proc.stdin.close().catchError((Object _) {})));

      final iter = it = StreamIterator<List<int>>(proc.stdout);
      final cortador = CortadorJpeg();
      final cola = Queue<Uint8List>();
      var k = 0;
      // (número del cuadro según ffmpeg, el JPEG), o null si ffmpeg acabó.
      Future<(int, Uint8List)?> siguiente() async {
        while (cola.isEmpty) {
          if (!await iter.moveNext()) return null;
          cola.addAll(cortador.anadir(iter.current));
        }
        return (k++, cola.removeFirst());
      }

      Future<(int, Uint8List)?> siguienteQueQuepa() async {
        while (true) {
          final x = await siguiente();
          if (x == null || x.$2.length <= maxCuadroW5v) return x;
          grandes++;
          _contar('cuadros_grandes');
        }
      }

      final (int, Uint8List)? primero;
      try {
        primero = await siguienteQueQuepa().timeout(plazoPrimerCuadro);
      } on TimeoutException {
        throw HttpException('no salió ningún cuadro en ${plazoPrimerCuadro.inSeconds} s'
            '${falloBajada == null ? '' : ': $falloBajada'}');
      }
      if (primero == null) {
        final codigo = await proc.exitCode;
        final err = (await errores).trim().replaceAll('\n', ' ');
        final deFfmpeg = 'ffmpeg $codigo: ${err.length > 200 ? err.substring(err.length - 200) : err}';
        // La causa: si la bajada falló por su cuenta, esa (ffmpeg se quejará de que no le
        // llegó nada); si falló porque ffmpeg ya no leía, lo que diga ffmpeg.
        final fb = falloBajada;
        throw HttpException(fb != null && !ffmpegNoLee
            ? fb
            : codigo != 0
                ? deFfmpeg
                : fb ?? 'el video no dio ningún cuadro');
      }
      tPrimero = reloj.elapsedMilliseconds;

      res.empezar(200, [
        ('Content-Type', 'application/octet-stream'),
        ('X-Duracion-Ms', '${info.durMs}'),
        ('X-Ancho', '${p.an}'),
        ('X-Alto', '${p.al}'),
        ('X-Fps', '${p.fps}'),
      ]);
      // Un cliente que cuelga no siempre hace fallar la escritura: con cuadros pequeños
      // y espaciados (~0,6 KB cada ~0,1 s), dart:io deja una esperando para siempre
      // [medido en macOS; con los trozos de 16 KB seguidos de /pista, sí falla, también
      // medido]. Lo que se ve siempre es el cierre por la lectura
      // ([cierre]). Tras él, si lo escrito no sale en [graciaCierre], no hay nadie: un
      // cliente que solo cerró su mitad y sigue leyendo no se corta. Mientras no
      // cierre, se espera lo que haga falta: un teléfono en pausa frena aquí.
      Future<void> mandar(Uint8List b) async {
        try {
          var salio = false;
          final w = res.escribir(b).then((_) => salio = true);
          if (cierre == null) {
            await w;
          } else {
            await Future.any([w, cierre]);
            if (!salio) await w.timeout(graciaCierre);
          }
        } on Object {
          throw const _Corte();
        }
        bytes += b.length;
      }

      final b0 = BytesBuilder(copy: false)
        ..add(cabeceraW5v(p.an, p.al, p.fps, info.durMs))
        ..add(cuadroW5v(p.pts(primero.$1), primero.$2));
      await mandar(b0.takeBytes());
      cuadros++;
      for (var x = await siguienteQueQuepa(); x != null; x = await siguienteQueQuepa()) {
        await mandar(cuadroW5v(p.pts(x.$1), x.$2));
        cuadros++;
      }
      final codigo = await proc.exitCode;
      if (codigo == 0 && falloBajada == null && !cortador.aMedias) {
        await mandar(finW5v());
        como = 'entero';
        _contar('enteros');
      } else {
        // Sin el fin: el teléfono ve que se cortó.
        como = 'cortado por aquí (${falloBajada ?? 'ffmpeg $codigo'})';
        _contar('fallos');
      }
    } on _Corte {
      como = 'el teléfono cortó';
      _contar('cortados');
    } on Object {
      _contar('fallos');
      rethrow;
    } finally {
      cancelado = true;
      final x = pr;
      if (x != null) {
        x.kill(ProcessSignal.sigkill);
        _procesos.remove(x);
      }
      activas--;
      final i = it;
      if (i != null) await i.cancel().timeout(const Duration(seconds: 2), onTimeout: () {});
      final s = reloj.elapsedMilliseconds;
      registro?.call('video $id ${p.an}x${p.al}@${p.fps} q${p.cal} desde ${p.desdeMs} ms: $como; '
          'URL ${tExtraer / 1000} s, primer cuadro ${tPrimero / 1000} s, $cuadros cuadros'
          '${grandes > 0 ? ' ($grandes de más de 32 KB, saltados)' : ''}, $bytes B en ${s / 1000} s');
    }
  }

  String estado() => 'videos: $activas convirtiéndose (máx. $maxConversiones); cuentas: $cuentas; '
      'búsquedas a yt-dlp: ${buscador.busquedas}';

  /// Mata lo que esté corriendo.
  void parar() {
    _parado = true;
    for (final pr in _procesos.toList()) {
      pr.kill(ProcessSignal.sigkill);
    }
    _procesos.clear();
  }
}
