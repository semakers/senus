// El catálogo de música: buscar y «lo que sigue», sin cuenta. Es la parte de
// ytmusicapi que usa bt/musica_yt/servicio.py, portada a Dart: dos POST con un JSON
// por lado. Las rutas dentro de la respuesta son las de ytmusicapi 1.12.3.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'letra_telefono.dart';

const _dominio = 'https://music.youtube.com';
const _agente = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:88.0) Gecko/20100101 Firefox/88.0';

/// filter='songs' de ytmusicapi.
const _paramsCanciones = 'EgWKAQIIAWoMEA4QChADEAQQCRAF';

/// La red del catálogo: se inyecta en las pruebas.
abstract class RedCatalogo {
  Future<String> obtener(Uri url, Map<String, String> cabeceras);
  Future<String> enviar(Uri url, Map<String, String> cabeceras, String cuerpo);
}

class RedCatalogoHttp implements RedCatalogo {
  final _cliente = HttpClient()..connectionTimeout = const Duration(seconds: 15);

  Future<String> _leer(HttpClientRequest pet) async {
    final res = await pet.close().timeout(const Duration(seconds: 20));
    final t = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
    return t;
  }

  @override
  Future<String> obtener(Uri url, Map<String, String> cabeceras) async {
    final pet = await _cliente.getUrl(url);
    cabeceras.forEach(pet.headers.set);
    return _leer(pet);
  }

  @override
  Future<String> enviar(Uri url, Map<String, String> cabeceras, String cuerpo) async {
    final pet = await _cliente.postUrl(url);
    cabeceras.forEach(pet.headers.set);
    pet.add(utf8.encode(cuerpo));
    return _leer(pet);
  }
}

dynamic nav(dynamic raiz, List<Object> ruta) {
  dynamic v = raiz;
  for (final k in ruta) {
    if (k is int) {
      if (v is! List || k >= v.length) return null;
      v = v[k];
    } else {
      if (v is! Map) return null;
      v = v[k];
    }
    if (v == null) return null;
  }
  return v;
}

int mmssAS(String? t) {
  if (t == null) return 0;
  var s = 0;
  for (final p in t.split(':')) {
    final n = int.tryParse(p);
    if (n == null) return 0;
    s = s * 60 + n;
  }
  return s;
}

class Cancion {
  final String id;
  final int durS;
  final String titulo, artistas, album, portada;

  const Cancion(this.id, this.durS, this.titulo, this.artistas, this.album, this.portada);

  String linea(LetraTelefono l) =>
      '$id\t$durS\t${l.para(titulo)}\t${l.para(artistas, 64)}\t${l.para(album, 64)}\n';
}

class _Corrida {
  final List<String> artistas = [];
  String album = '';
  int durS = 0;
}

final _duracion = RegExp(r'^(\d+:)*\d+:\d+$');
final _anio = RegExp(r'^\d{4}$');

/// Lo que `parse_views` da por «reproducciones»: empieza por cifra y no es una
/// palabra suelta como «2Pac». Los textos no latinos no llegan: `hl` es inglés.
bool _esVistas(String t) => RegExp(r'^\d').hasMatch(t) && t.contains(' ');

/// El tipo de una corrida de texto: 'album', 'artista', 'duracion', 'anio', 'vistas'.
String _tipoCorrida(Map run) {
  final texto = run['text'] as String;
  if (run.containsKey('navigationEndpoint')) {
    final id = nav(run, ['navigationEndpoint', 'browseEndpoint', 'browseId']) as String?;
    if (id != null && (id.startsWith('MPRE') || id.contains('release_detail'))) return 'album';
    return 'artista';
  }
  if (_duracion.hasMatch(texto)) return 'duracion';
  if (_anio.hasMatch(texto)) return 'anio';
  if (_esVistas(texto)) return 'vistas';
  return 'artista';
}

_Corrida _leerCorridas(List runs, {bool saltarTipo = false}) {
  var lista = runs.cast<Map>();
  // «Song • Autor»: la primera no es un artista (parse_song_runs).
  if (saltarTipo &&
      lista.length > 2 &&
      !lista[0].containsKey('navigationEndpoint') &&
      _tipoCorrida(lista[0]) == 'artista' &&
      lista[1]['text'] == ' • ' &&
      const {'artista', 'duracion', 'vistas', 'anio'}.contains(_tipoCorrida(lista[2]))) {
    lista = lista.sublist(2);
  }
  final r = _Corrida();
  for (var i = 0; i < lista.length; i += 2) {
    final texto = lista[i]['text'] as String;
    switch (_tipoCorrida(lista[i])) {
      case 'album':
        r.album = texto;
      case 'artista':
        r.artistas.add(texto);
      case 'duracion':
        r.durS = mmssAS(texto);
    }
  }
  return r;
}

Map? _columna(Map item, int i) {
  final c = item['flexColumns'];
  if (c is! List || c.length <= i) return null;
  final col = c[i]['musicResponsiveListItemFlexColumnRenderer'];
  return nav(col, ['text', 'runs']) == null ? null : col as Map;
}

String _portadaMayor(dynamic lista) {
  if (lista is! List || lista.isEmpty) return '';
  Map mayor = lista.first as Map;
  for (final t in lista.cast<Map>()) {
    if (((t['width'] as num?) ?? 0) > ((mayor['width'] as num?) ?? 0)) mayor = t;
  }
  return (mayor['url'] as String?) ?? '';
}

/// Un elemento musicResponsiveListItemRenderer de una búsqueda de canciones.
Cancion? cancionDeBusqueda(Map item) {
  final id = nav(item, [
    'overlay', 'musicItemThumbnailOverlayRenderer', 'content', 'musicPlayButtonRenderer', 'playNavigationEndpoint',
    'watchEndpoint', 'videoId',
  ]) as String?;
  if (id == null || id.isEmpty) return null;
  final titulo = nav(_columna(item, 0), ['text', 'runs', 0, 'text']) as String? ?? '';
  final c1 = _columna(item, 1);
  if (c1 == null) return null;
  final runs = [...(nav(c1, ['text', 'runs']) as List)];
  final c2 = _columna(item, 2);
  if (c2 != null) {
    runs
      ..add(const {'text': ''})
      ..addAll(nav(c2, ['text', 'runs']) as List);
  }
  final r = _leerCorridas(runs, saltarTipo: true);
  final portada = _portadaMayor(nav(item, ['thumbnail', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails']));
  return Cancion(id, r.durS, titulo, r.artistas.join(', '), r.album, portada);
}

/// Las canciones de una respuesta y el testigo para pedir más.
(List<Cancion>, String?) leerBusqueda(Map json) {
  final contenidos = json['contents'];
  if (contenidos == null) return (const [], null);
  final resultados = contenidos is Map && contenidos.containsKey('tabbedSearchResultsRenderer')
      ? nav(contenidos, ['tabbedSearchResultsRenderer', 'tabs', 0, 'tabRenderer', 'content'])
      : contenidos;
  final secciones = nav(resultados, ['sectionListRenderer', 'contents']);
  if (secciones is! List) return (const [], null);
  final out = <Cancion>[];
  String? testigo;
  for (final s in secciones.cast<Map>()) {
    final estante = s['musicShelfRenderer'] as Map?;
    if (estante == null) continue;
    final items = estante['contents'];
    if (items is! List || items.isEmpty || !(items.first as Map).containsKey('musicResponsiveListItemRenderer')) continue;
    final categoria = nav(estante, ['title', 'runs', 0, 'text']) as String?;
    if (categoria != null && !categoria.toLowerCase().contains('song')) continue;
    for (final i in items.cast<Map>()) {
      final c = cancionDeBusqueda(i['musicResponsiveListItemRenderer'] as Map);
      if (c != null) out.add(c);
    }
    testigo = nav(estante, ['continuations', 0, 'nextContinuationData', 'continuation']) as String?;
  }
  return (out, testigo);
}

(List<Cancion>, String?) leerContinuacion(Map json) {
  final e = nav(json, ['continuationContents', 'musicShelfContinuation']);
  if (e is! Map) return (const [], null);
  final items = e['contents'];
  final out = <Cancion>[];
  if (items is List) {
    for (final i in items.cast<Map>()) {
      final r = i['musicResponsiveListItemRenderer'];
      if (r is Map) {
        final c = cancionDeBusqueda(r);
        if (c != null) out.add(c);
      }
    }
  }
  return (out, nav(e, ['continuations', 0, 'nextContinuationData', 'continuation']) as String?);
}

/// La cola de «next»: la radio de una canción.
List<Cancion> leerRadio(Map json) {
  final lista = nav(json, [
    'contents', 'singleColumnMusicWatchNextResultsRenderer', 'tabbedRenderer', 'watchNextTabbedResultsRenderer', 'tabs', 0,
    'tabRenderer', 'content', 'musicQueueRenderer', 'content', 'playlistPanelRenderer', 'contents',
  ]);
  if (lista is! List) throw const FormatException('sin cola');
  final out = <Cancion>[];
  for (Map r in lista.cast<Map>()) {
    final envoltura = r['playlistPanelVideoWrapperRenderer'];
    if (envoltura is Map) r = envoltura['primaryRenderer'] as Map;
    final d = r['playlistPanelVideoRenderer'];
    if (d is! Map || d.containsKey('unplayableText')) continue;
    final id = d['videoId'] as String?;
    if (id == null || id.isEmpty) continue;
    final byline = nav(d, ['longBylineText', 'runs']);
    final c = byline is List ? _leerCorridas(byline) : _Corrida();
    out.add(Cancion(
      id,
      mmssAS(nav(d, ['lengthText', 'runs', 0, 'text']) as String?),
      nav(d, ['title', 'runs', 0, 'text']) as String? ?? '',
      c.artistas.join(', '),
      c.album,
      _portadaMayor(nav(d, ['thumbnail', 'thumbnails'])),
    ));
  }
  return out;
}

class Catalogo {
  final RedCatalogo red;
  final DateTime Function() ahora;

  String? _visitante;
  final _busquedas = <String, (DateTime, List<Cancion>, String?)>{};

  /// id -> canción, para la portada y la duración.
  final meta = <String, Cancion>{};

  Catalogo({RedCatalogo? red, DateTime Function()? ahora})
      : red = red ?? RedCatalogoHttp(),
        ahora = ahora ?? DateTime.now;

  Map<String, String> get _base => const {
        'user-agent': _agente,
        'accept': '*/*',
        'origin': _dominio,
        'cookie': 'SOCS=CAI',
      };

  Future<String> _idVisitante() async {
    final v = _visitante;
    if (v != null) return v;
    final t = await red.obtener(Uri.parse(_dominio), _base);
    final m = RegExp(r'ytcfg\.set\s*\(\s*(\{.+?\})\s*\)\s*;').firstMatch(t);
    var id = '';
    if (m != null) {
      final d = jsonDecode(m.group(1)!);
      if (d is Map) id = (d['VISITOR_DATA'] as String?) ?? '';
    }
    return _visitante = id;
  }

  Future<Map> _post(String punto, Map<String, Object?> cuerpo, {String extra = ''}) async {
    final fecha = ahora().toUtc();
    final dia = '${fecha.year}${'${fecha.month}'.padLeft(2, '0')}${'${fecha.day}'.padLeft(2, '0')}';
    final todo = {
      ...cuerpo,
      'context': {
        'client': {'clientName': 'WEB_REMIX', 'clientVersion': '1.$dia.01.00', 'hl': 'en'},
        'user': <String, Object?>{},
      },
    };
    final visitante = await _idVisitante();
    final url = Uri.parse('$_dominio/youtubei/v1/$punto?alt=json$extra');
    final t = await red.enviar(
      url,
      {..._base, 'content-type': 'application/json', 'X-Goog-Visitor-Id': visitante},
      jsonEncode(todo),
    );
    return jsonDecode(t) as Map;
  }

  void _apuntar(List<Cancion> lista) {
    for (final c in lista) {
      meta[c.id] = c;
    }
    while (meta.length > 2000) {
      meta.remove(meta.keys.first);
    }
  }

  /// (la página, hay más). Como mucho 50 resultados: lo que da servicio.py.
  Future<(List<Cancion>, bool)> buscar(String q, int desde, int n) async {
    final consulta = q.split(RegExp(r'\s+')).where((x) => x.isNotEmpty).join(' ');
    final corta = consulta.length > 120 ? consulta.substring(0, 120) : consulta;
    final hace = _busquedas[corta];
    final quiero = desde + n < 50 ? desde + n : 50;
    List<Cancion> lista;
    if (hace != null && ahora().difference(hace.$1).inSeconds < 600 && hace.$2.length >= quiero) {
      lista = hace.$2;
    } else {
      final limite = (desde + n > 20 ? desde + n : 20).clamp(20, 50);
      final cuerpo = {'query': corta, 'params': _paramsCanciones};
      var (r, testigo) = leerBusqueda(await _post('search', cuerpo));
      final todas = [...r];
      while (testigo != null && todas.length < limite) {
        final t = testigo;
        final (mas, sigue) = leerContinuacion(await _post('search', cuerpo, extra: '&ctoken=$t&continuation=$t'));
        if (mas.isEmpty) break;
        todas.addAll(mas);
        testigo = sigue;
      }
      lista = todas.length > limite ? todas.sublist(0, limite) : todas;
      _apuntar(lista);
      _busquedas.remove(corta);
      _busquedas[corta] = (ahora(), lista, null);
      while (_busquedas.length > 20) {
        _busquedas.remove(_busquedas.keys.first);
      }
    }
    final fin = desde + n < lista.length ? desde + n : lista.length;
    return (desde >= lista.length ? <Cancion>[] : lista.sublist(desde, fin), lista.length > desde + n);
  }

  Future<List<Cancion>> siguientes(String id, int n) async {
    final j = await _post('next', {
      'enablePersistentPlaylistPanel': true,
      'isAudioOnly': true,
      'tunerSettingValue': 'AUTOMIX_SETTING_NORMAL',
      'videoId': id,
      'playlistId': 'RDAMVM$id',
      'watchEndpointMusicSupportedConfigs': {
        'watchEndpointMusicConfig': {'hasPersistentPlaylistPanel': true, 'musicVideoType': 'MUSIC_VIDEO_TYPE_ATV'},
      },
    });
    final lista = leerRadio(j);
    _apuntar(lista);
    final sin = lista.where((c) => c.id != id).toList();
    return sin.length > n ? sin.sublist(0, n) : sin;
  }
}
