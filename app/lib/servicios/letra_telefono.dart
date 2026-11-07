// La letra del teléfono: la misma función `para_telefono` de bt/musica_yt/servicio.py.
// La Roboto del W580 tiene EXACTAMENTE ASCII y 27 signos más; lo demás se queda
// sin el acento que no hay o se translitera.
//
// La tabla (assets/servicios/letra_telefono.bin) la genera
// tool/generar_letra_telefono.py con la propia función de Python y anyascii (ISC):
// para cada código, el texto que le corresponde. Así Dart no carga con NFKD ni con
// las tablas de anyascii, y da lo mismo que Python por construcción.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// La tabla ya leída. Formato, tras gunzip, todo en little-endian:
///   u32 n_mapas, n_mapas × (u32 código, u8 largo, bytes en latin-1/UTF-8 ... )
///   u32 n_pares, n_pares × (u32 base, u32 marca, u32 compuesto): las composiciones NFC.
class LetraTelefono {
  static const extra = [
    0xE1, 0xE9, 0xED, 0xF3, 0xFA, 0xF1, 0xD1, 0xBF, 0xA1, 0xAB, 0xBB, 0xB0, 0xFC, 0xDC, 0xC1, 0xC9, 0xCD, 0xD3, 0xDA,
    0x2190, 0x2192, 0x2191, 0x2193, 0x2713, 0x2022, 0xB7, 0x2026,
  ];

  final Map<int, String> _mapa;
  final Map<int, int> _pares;

  LetraTelefono._(this._mapa, this._pares);

  /// Sin tabla: lo que no tenga letra se quita. Solo para las pruebas.
  factory LetraTelefono.vacia() => LetraTelefono._({}, {});

  factory LetraTelefono.desdeTabla(List<int> gz) {
    final b = Uint8List.fromList(gzip.decode(gz));
    final d = ByteData.sublistView(b);
    var o = 0;
    int u32() {
      final v = d.getUint32(o, Endian.little);
      o += 4;
      return v;
    }

    final mapa = <int, String>{};
    final n = u32();
    for (var i = 0; i < n; i++) {
      final codigo = u32();
      final largo = b[o++];
      mapa[codigo] = utf8.decode(Uint8List.sublistView(b, o, o + largo));
      o += largo;
    }
    final pares = <int, int>{};
    final m = u32();
    for (var i = 0; i < m; i++) {
      final base = u32(), marca = u32(), compuesto = u32();
      pares[base * 0x200000 + marca] = compuesto;
    }
    return LetraTelefono._(mapa, pares);
  }

  static bool permitido(int c) => (c >= 32 && c < 127) || extra.contains(c);

  /// NFC: basta juntar pares base + marca; los textos que llegan vienen ya
  /// compuestos casi siempre.
  List<int> _componer(Iterable<int> runas) {
    final out = <int>[];
    for (final r in runas) {
      if (out.isNotEmpty) {
        final c = _pares[out.last * 0x200000 + r];
        if (c != null) {
          out[out.length - 1] = c;
          continue;
        }
      }
      out.add(r);
    }
    return out;
  }

  /// Sin tabuladores ni saltos (el formato va por líneas y columnas), recortado a
  /// [maxB] bytes de UTF-8 con «…».
  String para(String? s, [int maxB = 96]) {
    final t = StringBuffer();
    for (var c in _componer((s ?? '').runes)) {
      if (c == 9 || c == 10 || c == 11 || c == 12 || c == 13) c = 32;
      if (permitido(c)) {
        t.writeCharCode(c);
      } else {
        final m = _mapa[c];
        if (m != null) t.write(m);
      }
    }
    var r = t.toString().split(' ').where((x) => x.isNotEmpty).join(' ');
    if (utf8.encode(r).length > maxB) {
      var runas = r.runes.toList();
      while (runas.isNotEmpty && utf8.encode(String.fromCharCodes(runas)).length + 3 > maxB) {
        runas = runas.sublist(0, runas.length - 1);
      }
      r = '${String.fromCharCodes(runas).trimRight()}…';
    }
    return r;
  }
}
