// Codificación de MTP 1.1: contenedores de 12 B, cadenas UCS-2 y fechas.
// Sin dependencias externas. Base del cable con senew (DISENO.md §4.3).

import 'dart:typed_data';

// Tipos de contenedor (MTP 1.1, Apéndice C).
const int tipoOrden = 1;
const int tipoDatos = 2;
const int tipoResp = 3;
const int tipoEvento = 4;

class Contenedor {
  final int tipo;
  final int codigo;
  final int idTransaccion;
  final List<int> parametros; // u32s (hasta 5 en Orden)
  final Uint8List datos;      // vacío si tipo != tipoDatos

  const Contenedor({
    required this.tipo,
    required this.codigo,
    required this.idTransaccion,
    this.parametros = const [],
    required this.datos,
  });

  /// Serializa a bytes LE con la cabecera de 12 B.
  Uint8List empaquetar() {
    final paramsBytes = tipo == tipoOrden ? parametros.length * 4 : 0;
    final n = 12 + paramsBytes + (tipo == tipoDatos ? datos.length : 0);
    final b = BytesBuilder(copy: false);
    final cab = ByteData(12);
    cab.setUint32(0, n, Endian.little);
    cab.setUint16(4, tipo, Endian.little);
    cab.setUint16(6, codigo, Endian.little);
    cab.setUint32(8, idTransaccion, Endian.little);
    b.add(cab.buffer.asUint8List());
    if (tipo == tipoOrden) {
      final p = ByteData(paramsBytes);
      for (var i = 0; i < parametros.length; i++) {
        p.setUint32(i * 4, parametros[i], Endian.little);
      }
      b.add(p.buffer.asUint8List());
    } else if (tipo == tipoDatos) {
      b.add(datos);
    }
    return b.toBytes();
  }

  /// Parsea bytes LE a un Contenedor (sin datos extendidos; se añaden por fuera).
  static Contenedor desempaquetarCabecera(Uint8List bruto) {
    final bd = ByteData.sublistView(bruto);
    final n = bd.getUint32(0, Endian.little);
    final tipo = bd.getUint16(4, Endian.little);
    final cod = bd.getUint16(6, Endian.little);
    final idT = bd.getUint32(8, Endian.little);
    final params = <int>[];
    // Para Respuesta: los parámetros son los bytes 12..n (hasta 5).
    for (var i = 12; i + 4 <= n && i < 12 + 20; i += 4) {
      params.add(bd.getUint32(i, Endian.little));
    }
    return Contenedor(
      tipo: tipo,
      codigo: cod,
      idTransaccion: idT,
      parametros: params,
      datos: Uint8List(0),
    );
  }
}

/// Cadena MTP 1.1 §3.2.3: prefijo u8 = número de UCS-2 CONTANDO el nulo (0 si vacía),
/// seguida de los UCS-2 LE y el nulo. Devuelve los bytes a escribir.
Uint8List cadenaMtp(String s) {
  if (s.isEmpty) return Uint8List.fromList([0]);
  final utf16 = <int>[];
  for (final r in s.runes) {
    if (r > 0xFFFF) {
      // Par sustituto UTF-16.
      final c = r - 0x10000;
      utf16.add(0xD800 | (c >> 10));
      utf16.add(0xDC00 | (c & 0x3FF));
    } else {
      utf16.add(r);
    }
  }
  utf16.add(0); // nulo
  final b = BytesBuilder(copy: false);
  b.addByte(utf16.length);
  final b16 = ByteData(utf16.length * 2);
  for (var i = 0; i < utf16.length; i++) {
    b16.setUint16(i * 2, utf16[i], Endian.little);
  }
  b.add(b16.buffer.asUint8List());
  return b.toBytes();
}

/// Lee una cadena MTP del buffer en el offset dado; devuelve (cadena, nuevoOffset).
(String, int) leerCadenaMtp(Uint8List b, int off) {
  final n = b[off];
  if (n == 0) return ('', off + 1);
  final bd = ByteData.sublistView(b, off + 1, off + 1 + n * 2);
  final cu = <int>[];
  for (var i = 0; i < n; i++) {
    cu.add(bd.getUint16(i * 2, Endian.little));
  }
  // Quita el nulo final si está.
  if (cu.isNotEmpty && cu.last == 0) cu.removeLast();
  return (String.fromCharCodes(cu), off + 1 + n * 2);
}

/// MTP 1.1 §3.2.5: "YYYYMMDDTHHMMSS".
String fechaMtp(DateTime t) {
  String dd(int x, int ancho) => x.toString().padLeft(ancho, '0');
  final u = t.toUtc();
  return '${dd(u.year, 4)}${dd(u.month, 2)}${dd(u.day, 2)}T'
      '${dd(u.hour, 2)}${dd(u.minute, 2)}${dd(u.second, 2)}';
}

DateTime? parsearFechaMtp(String s) {
  if (s.length < 15 || s[8] != 'T') return null;
  try {
    return DateTime.utc(
      int.parse(s.substring(0, 4)),
      int.parse(s.substring(4, 6)),
      int.parse(s.substring(6, 8)),
      int.parse(s.substring(9, 11)),
      int.parse(s.substring(11, 13)),
      int.parse(s.substring(13, 15)),
    );
  } catch (_) {
    return null;
  }
}
