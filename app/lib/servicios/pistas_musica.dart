// Las pistas de música: yt-dlp saca la URL del audio, Dart la baja con la
// verificación TLS del sistema y ffmpeg convierte a MP3 lo que le llega por stdin.
// ffmpeg NO toca la red: `-protocol_whitelist pipe`, así que tampoco un fichero raro
// puede hacerle abrir una URL. Lo demás es Pistas de bt/musica_yt/servicio.py. EL
// AUDIO SOLO EN RAM, nunca al disco: se guardan las últimas pistas y se sueltan las
// viejas. Una extracción a la vez, sin ráfagas contra el origen.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

const kbps = 128;

/// 16 bytes por ms con CBR a 128 kbps.
const bPorMs = kbps ~/ 8;

/// Una «canción» de más de 2 h no se prepara: son 115 MB de RAM.
const _durMax = 2 * 3600;

/// Quién ejecuta los binarios. Da las rutas por [rutaVerificada] en cada arranque.
class HerramientasMusica {
  final Future<String> Function() ytDlp;
  final Future<String> Function() deno;
  final Future<String> Function() ffmpeg;

  /// Carpeta de caché de yt-dlp (la solución del reto, no audio).
  final String? cacheYtDlp;

  const HerramientasMusica({required this.ytDlp, required this.deno, required this.ffmpeg, this.cacheYtDlp});
}

class InfoAudio {
  final String url;
  final int durS;
  final Map<String, String> cabeceras;

  /// Cuándo empieza a valer la URL (`available_at` de yt-dlp). Medido: en varias
  /// canciones el origen da 403 durante ~2 s tras sacarla, con cualquier cliente.
  /// yt-dlp duerme ese rato cuando baja él; aquí baja Dart, así que lo hace Dart.
  final DateTime? disponible;
  const InfoAudio(this.url, this.durS, this.cabeceras, {this.disponible});
}

/// Si `available_at` dijera algo raro, no se espera más que esto.
const esperaDisponibleMax = Duration(seconds: 15);

class Pista {
  final String id;
  Uint8List _b = Uint8List(1 << 20);
  int n = 0;
  bool fin = false;
  String? fallo;
  int durMs = 0;
  int lectores = 0;
  DateTime uso = DateTime.now();
  final _t0 = DateTime.now();
  DateTime? tUrl, tPrimer, tFin;
  Completer<void> _cambio = Completer<void>();

  Pista(this.id);

  Uint8List get datos => Uint8List.sublistView(_b, 0, n);

  void anadir(List<int> trozo) {
    if (n + trozo.length > _b.length) {
      final nuevo = Uint8List(math.max(_b.length * 2, n + trozo.length));
      nuevo.setRange(0, n, _b);
      _b = nuevo;
    }
    _b.setRange(n, n + trozo.length, trozo);
    n += trozo.length;
    tPrimer ??= DateTime.now();
    avisar();
  }

  void avisar() {
    final c = _cambio;
    _cambio = Completer<void>();
    c.complete();
  }

  /// Espera a que [cond] se cumpla, como mucho [plazo]. true si se cumplió.
  Future<bool> esperar(bool Function() cond, Duration plazo) async {
    final limite = DateTime.now().add(plazo);
    while (!cond()) {
      final queda = limite.difference(DateTime.now());
      if (queda <= Duration.zero) return false;
      try {
        await _cambio.future.timeout(queda);
      } on TimeoutException {
        return cond();
      }
    }
    return true;
  }
}

/// Primer comienzo de trama MPEG-1 capa III a 128 kbps 44,1 kHz desde [o]
/// (FF FB 9x, lo que da ffmpeg aquí), con la trama siguiente en su sitio.
int? alinear(Uint8List d, int n, int o) {
  while (o + 4 <= n) {
    if (d[o] == 0xFF && d[o + 1] == 0xFB && (d[o + 2] & 0xFC) == 0x90) {
      final tam = 144000 * kbps ~/ 44100 + ((d[o + 2] >> 1) & 1);
      if (o + tam + 2 > n || (d[o + tam] == 0xFF && d[o + tam + 1] == 0xFB)) return o;
    }
    o++;
  }
  return null;
}

/// Reintentar no arregla esto.
class _SinReintento extends HttpException {
  const _SinReintento(super.message);
}

class Pistas {
  final HerramientasMusica herramientas;
  final int maximo;
  final Duration plazoExtraer;

  /// Sin recibir nada del origen durante este tiempo, se reintenta.
  final Duration plazoAudio;

  /// Reconexiones seguidas sin recibir nada. Lo de `-reconnect` de ffmpeg.
  final int reintentosAudio;
  final Duration esperaReintento;

  /// Solo para las pruebas contra un origen local: fuera de eso, todo https.
  final bool permitirHttp;
  final void Function(String)? registro;

  final _cliente = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  final p = <String, Pista>{};
  final cuentas = <String, int>{};
  final _procesos = <Process>{};
  Future<void> _turno = Future.value();
  bool _parado = false;

  Pistas({
    required this.herramientas,
    this.maximo = 6,
    this.plazoExtraer = const Duration(seconds: 60),
    this.plazoAudio = const Duration(seconds: 20),
    this.reintentosAudio = 3,
    this.esperaReintento = const Duration(seconds: 1),
    this.permitirHttp = false,
    this.registro,
  });

  void _contar(String k) => cuentas[k] = (cuentas[k] ?? 0) + 1;

  Pista obtener(String id) {
    var q = p[id];
    if (q != null && q.fallo != null && q.lectores == 0) {
      // una que falló se vuelve a intentar al pedirla otra vez
      p.remove(id);
      q = null;
    }
    if (q == null) {
      q = p[id] = Pista(id);
      unawaited(_preparar(q));
      _soltarViejas();
    } else {
      p.remove(id);
      p[id] = q;
    }
    q.uso = DateTime.now();
    return q;
  }

  /// Preparar [id] cuando [primera] esté entera: «siguiente» no espera y no hay
  /// dos conversiones a la vez.
  void despues(Pista primera, String id) {
    if (id.isEmpty || p.containsKey(id)) return;
    unawaited(primera
        .esperar(() => primera.fin || primera.fallo != null, const Duration(seconds: 600))
        .then((_) {
      if (!_parado) obtener(id);
    }));
  }

  void _soltarViejas() {
    for (final id in p.keys.toList()) {
      if (p.length <= maximo) break;
      final q = p[id]!;
      if (q.lectores == 0 && (q.fin || q.fallo != null)) {
        p.remove(id);
        _contar('soltadas');
      }
    }
  }

  /// Una extracción a la vez.
  Future<T> _uno<T>(Future<T> Function() f) {
    final r = _turno.then((_) => f());
    _turno = r.then<void>((_) {}, onError: (Object _) {});
    return r;
  }

  Future<InfoAudio> extraer(String id) async {
    final yt = await herramientas.ytDlp();
    final deno = await herramientas.deno();
    final cache = herramientas.cacheYtDlp;
    final args = [
      '--ignore-config', // ningún fichero de configuración ajeno: nada de --exec
      '--no-warnings',
      '--no-playlist',
      '--no-progress',
      '--js-runtimes', 'deno:$deno',
      if (cache != null) ...['--cache-dir', cache] else '--no-cache-dir',
      '-f', '251/140/bestaudio',
      '-j',
      'https://music.youtube.com/watch?v=$id',
    ];
    final pr = await Process.start(yt, args);
    _procesos.add(pr);
    try {
      final salida = pr.stdout.transform(utf8.decoder).join();
      final errores = pr.stderr.transform(utf8.decoder).join();
      final codigo = await pr.exitCode.timeout(plazoExtraer);
      final texto = await salida, err = await errores;
      if (codigo != 0) {
        final linea = err.trim().split('\n').last;
        throw HttpException(linea.length > 240 ? linea.substring(linea.length - 240) : linea);
      }
      final j = jsonDecode(texto) as Map<String, dynamic>;
      final url = j['url'] as String?;
      if (url == null) throw const FormatException('sin URL');
      final cab = <String, String>{};
      (j['http_headers'] as Map?)?.forEach((k, v) => cab['$k'] = '$v');
      final at = j['available_at'] as num?;
      return InfoAudio(url, (j['duration'] as num?)?.toInt() ?? 0, cab,
          disponible: at == null ? null : DateTime.fromMillisecondsSinceEpoch((at * 1000).round()));
    } on TimeoutException {
      pr.kill(ProcessSignal.sigkill);
      throw HttpException('la extracción tardó más de ${plazoExtraer.inSeconds} s');
    } finally {
      _procesos.remove(pr);
    }
  }

  static const argumentosFfmpeg = [
    '-hide_banner', '-loglevel', 'error', '-nostdin',
    '-protocol_whitelist', 'pipe', // sin red: lee stdin y nada más
    '-i', 'pipe:0',
    '-vn', '-c:a', 'libmp3lame', '-b:a', '${kbps}k', '-ar', '44100', '-ac', '2',
    '-id3v2_version', '0', '-write_xing', '0', '-f', 'mp3', 'pipe:1',
  ];

  /// Baja el audio y se lo da a [escribir]. Si se corta, sigue con Range desde el
  /// byte que falta. La verificación TLS es la de dart:io, sin tocar.
  ///
  /// Con [trozo], por rangos acotados de ese tamaño, como hace yt-dlp (10 MiB): con un
  /// rango abierto, un fichero grande del origen sale a unas 2 veces su tasa (un video
  /// de 26 MB, a 13,6 KB/s; el mismo con `bytes=0-10485759`, a 16,9 MB/s [medido]).
  /// Sin [trozo], lo de siempre.
  Future<void> bajarAudio(InfoAudio i, Future<void> Function(List<int>) escribir, {int? trozo}) async {
    final uri = Uri.parse(i.url);
    if (uri.scheme != 'https' && !(permitirHttp && uri.scheme == 'http')) {
      throw const HttpException('la URL del audio no es https');
    }
    final falta = i.disponible?.difference(DateTime.now());
    if (falta != null && falta > Duration.zero) {
      await Future<void>.delayed(falta < esperaDisponibleMax ? falta : esperaDisponibleMax);
    }
    var hechos = 0, fallos = 0;
    int? total;
    while (true) {
      try {
        final pet = await _cliente.getUrl(uri);
        i.cabeceras.forEach((k, v) => pet.headers.set(k, v, preserveHeaderCase: true));
        pet.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        // Siempre con Range, también desde 0: sin él, el origen sirve a unas 2 veces
        // el tiempo real y una canción tarda 100 s en vez de 3 [medido].
        pet.headers.set(HttpHeaders.rangeHeader, 'bytes=$hechos-${trozo == null ? '' : hechos + trozo - 1}');
        final res = await pet.close().timeout(plazoAudio);
        final bien = res.statusCode == 206 || (res.statusCode == 200 && hechos == 0);
        if (!bien) {
          await res.drain<void>();
          final motivo = 'el origen contesta HTTP ${res.statusCode}';
          // Un 403 sin haber recibido nada puede ser que aún no vale y que el reloj de
          // aquí vaya por delante del suyo: otra vuelta. Lo demás no se arregla insistiendo.
          if (res.statusCode == 403 && hechos == 0) throw HttpException(motivo);
          throw _SinReintento(motivo);
        }
        int? ultimo; // el último byte que trae esta respuesta, si va por trozos
        if (trozo != null && res.statusCode == 206) {
          final m = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(res.headers.value('content-range') ?? '');
          if (m == null || int.parse(m.group(1)!) != hechos) {
            await res.listen(null).cancel();
            throw const _SinReintento('el origen no da el rango pedido');
          }
          ultimo = int.parse(m.group(2)!);
          total = int.parse(m.group(3)!);
        } else if (total == null && res.contentLength > 0) {
          total = hechos + res.contentLength;
        }
        await for (final b in res.timeout(plazoAudio)) {
          try {
            await escribir(b);
          } on Object catch (e) {
            throw _SinReintento('ffmpeg dejó de leer: ${e.runtimeType}');
          }
          hechos += b.length;
          fallos = 0;
        }
        final t = total;
        if (t == null || hechos >= t) return;
        if (ultimo != null && hechos > ultimo) continue; // el trozo entero: el siguiente
        throw const HttpException('el audio se cortó');
      } on _SinReintento {
        rethrow;
      } on Object catch (e) {
        if (_parado) rethrow;
        if (++fallos > reintentosAudio) {
          throw HttpException('el audio se cortó en $hechos B: ${e is HttpException ? e.message : e.runtimeType}');
        }
        await Future<void>.delayed(esperaReintento * fallos);
      }
    }
  }

  Future<void> _preparar(Pista q) async {
    try {
      final info = await _uno(() => extraer(q.id));
      q.tUrl = DateTime.now();
      if (info.durS > _durMax) throw HttpException('dura ${info.durS ~/ 60} min: de más');
      q.durMs = info.durS * 1000;
      final ff = await herramientas.ffmpeg();
      if (_parado) return;
      final pr = await Process.start(ff, argumentosFfmpeg);
      _procesos.add(pr);
      final errores = pr.stderr.transform(utf8.decoder).join();
      // Si ffmpeg muere, escribir falla: lo cuenta bajarAudio, no un error suelto.
      unawaited(pr.stdin.done.catchError((Object _) {}));
      final salida = pr.stdout.forEach(q.anadir);
      try {
        await bajarAudio(info, (b) async {
          pr.stdin.add(b);
          await pr.stdin.flush();
        });
        await pr.stdin.close();
      } on Object {
        pr.kill(ProcessSignal.sigkill);
        await salida;
        await pr.exitCode;
        _procesos.remove(pr);
        rethrow;
      }
      await salida;
      final codigo = await pr.exitCode;
      _procesos.remove(pr);
      final err = (await errores).trim();
      if (codigo != 0) {
        throw HttpException('ffmpeg $codigo: ${err.length > 200 ? err.substring(err.length - 200) : err}');
      }
      q.fin = true;
      q.tFin = DateTime.now();
      if (q.n > 0) q.durMs = q.n ~/ bPorMs; // la de verdad (CBR): la del origen viene en segundos enteros
      q.avisar();
      _contar('preparadas');
      registro?.call('pista ${q.id}: URL ${_s(q._t0, q.tUrl!)} s, primer byte +${_s(q.tUrl!, q.tPrimer)} s, '
          'entera +${_s(q.tUrl!, q.tFin)} s, ${q.n} B, ${q.durMs} ms');
    } on Object catch (e) {
      final t = (e is HttpException ? e.message : '${e.runtimeType}: $e').replaceAll('\n', ' ');
      q.fallo = t.length > 300 ? t.substring(0, 300) : t;
      q.avisar();
      _contar('fallos');
      registro?.call('pista ${q.id}: FALLO ${q.fallo}');
    }
  }

  String _s(DateTime a, DateTime? b) => ((b ?? a).difference(a).inMilliseconds / 1000).toStringAsFixed(2);

  /// Mata lo que esté corriendo y suelta la RAM.
  void parar() {
    _parado = true;
    _cliente.close(force: true);
    for (final pr in _procesos.toList()) {
      pr.kill(ProcessSignal.sigkill);
    }
    _procesos.clear();
    p.clear();
  }
}
