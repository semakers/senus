// Cabecera W5X / .sen (sistema/api/cargable.h): 128 bytes, little-endian.
//
// `SenCab.deBytes` lee solo la cabecera: basta para pintar una tarjeta con los
// primeros 128 bytes (GetPartialObject). Si el fichero no empieza por "W5X\1" o
// es más corto que 128 bytes devuelve `null` y la UI pinta un icono genérico.
//
// `problemaDeSen` mira el fichero entero con las tres CRC. OJO: `crc_cuerpo` NO
// cubre los recursos: llega hasta `fin - tam_rec`.

import 'dart:convert';
import 'dart:typed_data';

import 'transporte_bl.dart' show crc32DeDatos;

/// `W5_MAQ_ARMV5TE`: la única máquina que existe hoy.
const int maquinaArmv5te = 1;

class SenCab {
  final String nombre;          // nombre[30] UTF-8 nul-terminado
  final int iconoAn;            // 1..16; 0 = no trae
  final List<int> iconoFilas;   // 12 u16, bit (iconoAn-1) = píxel de la izquierda
  final int iconoGen;           // W5_IC_* como respaldo
  final int tamFich;            // bytes totales declarados
  final int perfil;             // W5_PERFIL_WIDGETS=1, JUEGO=2
  final int apiMayor, apiMenor;
  final int verApp;             // entero creciente, por app
  final int maquina;            // W5_MAQ_*
  final int caps;               // capacidades que pide
  final int anMin, alMin;       // pantalla mínima que necesita; 0 = cualquiera
  final int tamRec;             // bytes de recursos al final del fichero
  final int crcRec;             // CRC-32 de los recursos
  final int crcCuerpo;          // CRC-32 de [128, fin - tam_rec)
  final int crcCab;             // CRC-32 de los 124 primeros bytes

  const SenCab({
    required this.nombre,
    required this.iconoAn,
    required this.iconoFilas,
    required this.iconoGen,
    required this.tamFich,
    required this.perfil,
    required this.apiMayor,
    required this.apiMenor,
    this.verApp = 0,
    this.maquina = maquinaArmv5te,
    this.caps = 0,
    this.anMin = 0,
    this.alMin = 0,
    this.tamRec = 0,
    this.crcRec = 0,
    this.crcCuerpo = 0,
    this.crcCab = 0,
  });

  static const magia = <int>[0x57, 0x35, 0x58, 0x01]; // "W5X\1"
  static const tam = 128;

  /// Parsea los primeros 128 bytes de un .sen. Si no empieza por la magia,
  /// devuelve `null` (no es un .sen válido o es basura).
  static SenCab? deBytes(Uint8List b) {
    if (b.length < tam) return null;
    for (var i = 0; i < 4; i++) {
      if (b[i] != magia[i]) return null;
    }
    final bd = ByteData.sublistView(b, 0, tam);
    final filas = <int>[];
    for (var i = 0; i < 12; i++) {
      filas.add(bd.getUint16(58 + i * 2, Endian.little));
    }
    // nombre[30] en offset 82, nul-terminado UTF-8.
    final nombreBytes = <int>[];
    for (var i = 0; i < 30; i++) {
      final c = b[82 + i];
      if (c == 0) break;
      nombreBytes.add(c);
    }
    String nombre;
    try {
      nombre = utf8.decode(nombreBytes);
    } catch (_) {
      nombre = String.fromCharCodes(nombreBytes);
    }
    return SenCab(
      nombre: nombre,
      iconoAn: bd.getUint8(57),
      iconoFilas: filas,
      iconoGen: bd.getUint8(56),
      tamFich: bd.getUint32(20, Endian.little),
      perfil: bd.getUint8(7),
      apiMayor: bd.getUint16(8, Endian.little),
      apiMenor: bd.getUint16(10, Endian.little),
      verApp: bd.getUint32(52, Endian.little),
      maquina: bd.getUint8(6),
      caps: bd.getUint32(12, Endian.little),
      anMin: bd.getUint16(16, Endian.little),
      alMin: bd.getUint16(18, Endian.little),
      tamRec: bd.getUint32(112, Endian.little),
      crcRec: bd.getUint32(116, Endian.little),
      crcCuerpo: bd.getUint32(120, Endian.little),
      crcCab: bd.getUint32(124, Endian.little),
    );
  }

  bool get traeIcono => iconoAn >= 1 && iconoAn <= 16;

  /// Devuelve matrix[row][col] = true si pixel encendido. 12 filas × iconoAn col.
  List<List<bool>> aMatriz() {
    final an = traeIcono ? iconoAn : 0;
    final out = List.generate(12, (_) => List<bool>.filled(an, false));
    if (an == 0) return out;
    for (var r = 0; r < 12; r++) {
      final fila = iconoFilas[r];
      for (var c = 0; c < an; c++) {
        // bit (iconoAn-1) = píxel de la izquierda → columna 0.
        final bit = (an - 1) - c;
        out[r][c] = (fila >> bit) & 1 == 1;
      }
    }
    return out;
  }

  /// Un rótulo tipo "widgets" o "juego" para el subtítulo de la tarjeta.
  String get rotuloPerfil => perfil == 2 ? 'juego' : (perfil == 1 ? 'app' : '');
}

/// Mira un .sen ENTERO como lo mira el backend al publicarlo. Devuelve el
/// motivo si no vale y null si vale. La comprobación del teléfono al cargar es
/// aparte: aquí se rechaza lo que no valdría en ninguno.
String? problemaDeSen(Uint8List b) {
  final c = SenCab.deBytes(b);
  if (c == null) return 'No es un .sen: le falta la cabecera W5X.';
  final bd = ByteData.sublistView(b);
  if (bd.getUint16(4, Endian.little) != SenCab.tam) {
    return 'La cabecera no mide ${SenCab.tam} bytes.';
  }
  if (crc32DeDatos(Uint8List.sublistView(b, 0, 124)) != c.crcCab) {
    return 'La CRC de la cabecera no cuadra.';
  }
  if (c.maquina != maquinaArmv5te) return 'La máquina no es ARMv5TE.';
  if (c.perfil != 1 && c.perfil != 2) return 'Perfil desconocido.';
  if (c.tamFich != b.length) {
    return 'El fichero está cortado o le sobra algo '
        '(${b.length} B, la cabecera dice ${c.tamFich}).';
  }
  if (c.tamRec > b.length - SenCab.tam) return 'Los recursos no caben.';
  final finCuerpo = b.length - c.tamRec;
  if (crc32DeDatos(Uint8List.sublistView(b, SenCab.tam, finCuerpo)) !=
      c.crcCuerpo) {
    return 'La CRC del cuerpo no cuadra.';
  }
  if (crc32DeDatos(Uint8List.sublistView(b, finCuerpo)) != c.crcRec) {
    return 'La CRC de los recursos no cuadra.';
  }
  return null;
}
