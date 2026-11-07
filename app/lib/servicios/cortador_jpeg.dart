// Cortar en JPEG sueltos lo que sale de `ffmpeg -f image2pipe -c:v mjpeg`: los
// cuadros van pegados uno tras otro, sin nada que diga dónde acaba cada uno.
//
// No basta buscar FF D9: esos dos bytes pueden salir DENTRO de un segmento (una
// tabla DQT con un 255 seguido de un 217, un comentario COM, un APPn). Lo que sí
// vale es lo que dice JPEG (T.81, B.1):
//   - fuera de los datos de imagen, cada segmento es FF <código> <largo u16 BE> y se
//     salta entero por su largo; SOI, EOI, RSTn y TEM no llevan largo;
//   - dentro de los datos de imagen (tras SOS), un FF de los datos va siempre
//     relleno como FF 00, y FF D0..D7 son reinicios; cualquier otro FF xx es el
//     marcador que acaba los datos.
// Así, un EOI solo puede ser el de verdad. Los trozos pueden llegar partidos por
// cualquier byte: el estado se guarda entre lecturas.

import 'dart:typed_data';

enum _Fase { soi, marcador, datos }

class CortadorJpeg {
  /// Un cuadro que crece más que esto sin acabar es basura: se lanza.
  final int maximo;

  Uint8List _d = Uint8List(64 * 1024);
  int _n = 0;

  /// Dónde va la lectura y dónde empieza el cuadro en curso (-1: aún sin SOI).
  int _p = 0, _inicio = -1;
  _Fase _fase = _Fase.soi;

  /// Bytes tirados por venir fuera de un cuadro (no debería haber ninguno).
  int descartados = 0;

  CortadorJpeg({this.maximo = 1 << 20});

  /// Los cuadros que este trozo deja enteros, cada uno de SOI a EOI incluidos.
  List<Uint8List> anadir(List<int> trozo) {
    if (_n + trozo.length > _d.length) {
      var cap = _d.length;
      while (cap < _n + trozo.length) {
        cap *= 2;
      }
      _d = Uint8List(cap)..setRange(0, _n, _d);
    }
    _d.setRange(_n, _n + trozo.length, trozo);
    _n += trozo.length;
    final out = <Uint8List>[];
    while (_paso(out)) {}
    _compactar();
    if (_inicio >= 0 && _n - _inicio > maximo) {
      throw FormatException('un cuadro de más de $maximo bytes sin EOI');
    }
    return out;
  }

  /// Hay bytes de un cuadro a medias (al cerrar, sería un cuadro cortado).
  bool get aMedias => _inicio >= 0 || _n > 0;

  /// Avanza lo que pueda con lo que hay. false: faltan bytes.
  bool _paso(List<Uint8List> out) {
    final d = _d;
    switch (_fase) {
      case _Fase.soi:
        final desde = _p;
        while (_p + 1 < _n) {
          if (d[_p] == 0xFF && d[_p + 1] == 0xD8) {
            descartados += _p - desde;
            _inicio = _p;
            _p += 2;
            _fase = _Fase.marcador;
            return true;
          }
          _p++;
        }
        // el último byte se guarda: puede ser el FF de un SOI partido
        descartados += _p - desde;
        return false;
      case _Fase.marcador:
        if (_p >= _n) return false;
        if (d[_p] != 0xFF) throw FormatException('se esperaba un marcador en el byte ${_p - _inicio} del cuadro');
        // FF de relleno antes de un marcador (B.1.1.2)
        var q = _p + 1;
        while (q < _n && d[q] == 0xFF) {
          q++;
        }
        if (q >= _n) return false;
        final c = d[q];
        if (c == 0xD9) {
          out.add(Uint8List.fromList(Uint8List.sublistView(d, _inicio, q + 1)));
          _p = q + 1;
          _inicio = -1;
          _fase = _Fase.soi;
          return true;
        }
        if (c == 0x00 || c == 0xD8) throw FormatException('marcador FF ${c.toRadixString(16)} fuera de sitio');
        if (c == 0x01 || (c >= 0xD0 && c <= 0xD7)) {
          _p = q + 1;
          return true;
        }
        if (q + 2 >= _n) return false;
        final largo = (d[q + 1] << 8) | d[q + 2];
        if (largo < 2) throw FormatException('segmento FF ${c.toRadixString(16)} con largo $largo');
        final fin = q + 1 + largo;
        if (fin > _n) {
          if (fin - _inicio > maximo) throw FormatException('un segmento de $largo bytes no cabe en un cuadro');
          return false;
        }
        _p = fin;
        if (c == 0xDA) _fase = _Fase.datos;
        return true;
      case _Fase.datos:
        while (_p + 1 < _n) {
          if (d[_p] != 0xFF) {
            _p++;
            continue;
          }
          final x = d[_p + 1];
          if (x == 0x00 || (x >= 0xD0 && x <= 0xD7)) {
            _p += 2;
          } else if (x == 0xFF) {
            _p++;
          } else {
            _fase = _Fase.marcador;
            return true;
          }
        }
        return false;
    }
  }

  /// Suelta lo ya cortado: el búfer solo guarda el cuadro en curso.
  void _compactar() {
    final desde = _inicio >= 0 ? _inicio : _p;
    if (desde == 0) return;
    _d.setRange(0, _n - desde, _d, desde);
    _n -= desde;
    _p -= desde;
    if (_inicio >= 0) _inicio -= desde;
  }
}
