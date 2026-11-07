// Qué segmentos de whisper se quedan: la clase `Filtro` de bt/dictado/servicio.py,
// con los mismos umbrales y las mismas listas (medidos el 27 y 28-oct).

import 'dart:convert';
import 'dart:io';

class SegmentoWhisper {
  final String texto;
  final double noHabla;
  final double logProb;

  const SegmentoWhisper(this.texto, this.noHabla, this.logProb);

  /// Lo que faster-whisper llama compression_ratio: bytes / bytes con zlib.
  double get compresion {
    final b = utf8.encode(texto.trim());
    if (b.isEmpty) return 0;
    return b.length / zlib.encode(b).length;
  }
}

/// `á` -> `a`, para comparar frases. Lo que hace NFKD con el español y poco más.
const _sinAcento = {
  'á': 'a', 'à': 'a', 'ä': 'a', 'â': 'a', 'ã': 'a', 'é': 'e', 'è': 'e', 'ë': 'e', 'ê': 'e', 'í': 'i', 'ì': 'i', 'ï': 'i',
  'î': 'i', 'ó': 'o', 'ò': 'o', 'ö': 'o', 'ô': 'o', 'õ': 'o', 'ú': 'u', 'ù': 'u', 'ü': 'u', 'û': 'u', 'ñ': 'n', 'ç': 'c',
};

final _noPalabra = RegExp(r'[^\p{L}\p{N}_\s]', unicode: true);

/// Minúsculas, sin acentos ni puntuación, espacios simples.
String normal(String s) {
  final b = StringBuffer();
  for (final c in s.toLowerCase().runes) {
    final t = String.fromCharCode(c);
    if (c >= 0x300 && c <= 0x36F) continue;
    b.write(_sinAcento[t] ?? t);
  }
  return b.toString().replaceAll(_noPalabra, ' ').split(RegExp(r'\s+')).where((x) => x.isNotEmpty).join(' ');
}

/// Lo que whisper escribe cuando NO hay voz (lo aprendió de los subtítulos):
/// siempre se quita, nadie dicta esto a un teléfono.
final _alucinaciones = [
  r'\bsuscrib',
  r'\bsubtitul',
  r'\bamara\b',
  r'\bgracias por (ver|vernos|mirar|su atencion|tu atencion|escuchar|haber visto)',
  r'\bdale (like|me gusta|a like)',
  r'\bcampanita\b',
  r'\bnos vemos en el (proximo|siguiente) (video|capitulo)',
  r'\bhasta (el|la) (proximo|proxima|siguiente) (video|vez)\b',
  r'\b(mas|muchas) gracias por (ver|el video)',
].map(RegExp.new).toList();

/// Alucinación SOLO si whisper duda: también puede dictarse de verdad.
const _ambiguas = {
  'gracias', 'muchas gracias', 'gracias a todos', 'no', 'si', 'y', 'oye', 'oye oye', 'eh', 'ah', 'mmm', 'hmm', 'bueno',
  'adios', 'musica', 'aplausos', 'risas', 'chao', 'hola',
};

/// «[Música]», «(aplausos)», «*risas*», «♪».
final _etiquetas = RegExp(r'[\[(（*♪♫][^\])）*♪♫]{0,40}[\])）*♪♫]|[♪♫]+');

class Filtro {
  static const nsFuera = 0.9;
  static const nsAmbigua = 0.3;

  /// Era -1,3: «Bohemian Rhapsody de Queen» por el micrófono salía vacío. Con el
  /// VAD delante, un texto dudoso sirve más que nada en un buscador.
  static const lpFuera = -2.0;
  static const crFuera = 2.4;

  /// (texto limpio, motivo de quitarlo o null)
  (String, String?) segmento(SegmentoWhisper s) {
    final t = s.texto.replaceAll(_etiquetas, ' ').trim().split(RegExp(r'\s+')).where((x) => x.isNotEmpty).join(' ');
    final n = normal(t);
    if (n.isEmpty) return (t, 'vacio');
    if (_alucinaciones.any((p) => p.hasMatch(n))) return (t, 'alucinacion');
    if (s.noHabla > nsFuera) return (t, 'no-habla');
    if (s.compresion > crFuera) return (t, 'repetido');
    if (s.logProb < lpFuera) return (t, 'dudoso');
    if (_ambiguas.contains(n) && (s.noHabla > nsAmbigua || s.logProb < -0.8)) return (t, 'alucinacion');
    return (t, null);
  }
}

/// Los idiomas que conoce whisper.
const idiomasWhisper = {
  'af', 'am', 'ar', 'as', 'az', 'ba', 'be', 'bg', 'bn', 'bo', 'br', 'bs', 'ca', 'cs', 'cy', 'da', 'de', 'el', 'en', 'es',
  'et', 'eu', 'fa', 'fi', 'fo', 'fr', 'gl', 'gu', 'ha', 'haw', 'he', 'hi', 'hr', 'ht', 'hu', 'hy', 'id', 'is', 'it', 'ja',
  'jw', 'ka', 'kk', 'km', 'kn', 'ko', 'la', 'lb', 'ln', 'lo', 'lt', 'lv', 'mg', 'mi', 'mk', 'ml', 'mn', 'mr', 'ms', 'mt',
  'my', 'ne', 'nl', 'nn', 'no', 'oc', 'pa', 'pl', 'ps', 'pt', 'ro', 'ru', 'sa', 'sd', 'si', 'sk', 'sl', 'sn', 'so', 'sq',
  'sr', 'su', 'sv', 'sw', 'ta', 'te', 'tg', 'th', 'tk', 'tl', 'tr', 'tt', 'uk', 'ur', 'uz', 'vi', 'yi', 'yo', 'yue', 'zh',
};
