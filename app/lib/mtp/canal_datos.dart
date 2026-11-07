// Los datos del canal de gestión MTP (docs/contrato_canal_gestion.md), sin E/S:
// qué dice cada dataset y cómo se escribe. Todo es little-endian. El protocolo
// vive en `canal_gestion.dart`; aquí solo hay bytes.

import 'dart:convert';
import 'dart:typed_data';

/// Un dataset que no se entiende. Ningún parseador de este fichero lee fuera
/// del buffer: lo que no cuadra termina aquí.
class CanalMalFormado implements Exception {
  final String motivo;
  const CanalMalFormado(this.motivo);
  @override
  String toString() => 'Respuesta del canal mal formada: $motivo';
}

/// Tipos de ajuste del §3 del contrato.
const int tipoAjBool = 1;
const int tipoAjU8 = 2;
const int tipoAjI16 = 3;
const int tipoAjTexto = 4;

String _textoFijo(Uint8List b, int off, int largo) {
  final fin = off + largo;
  var i = off;
  while (i < fin && b[i] != 0) {
    i++;
  }
  return utf8.decode(Uint8List.sublistView(b, off, i), allowMalformed: true);
}

/// `SEN_INFO`: 128 bytes fijos (§2).
class SenInfo {
  final int build;
  final int apiMayor;
  final int apiMenor;
  final int blVersion;      // 0 = no se sabe
  final int bateriaPct;     // 0..100; 0xFF = no se sabe
  final int banderas;
  final Uint8List bdAddr;   // 6 bytes; todo 0 = no se sabe
  final String version;     // «0.29.0»
  final String modelo;      // «w580»
  final String soc;         // «DB2020»
  final String compilacion; // «Oct 31 2026 23:50:01»
  final String idAparato;   // el IMEI vinculado, o vacío
  final int ajustesVersion;

  const SenInfo({
    required this.build,
    required this.apiMayor,
    required this.apiMenor,
    required this.blVersion,
    required this.bateriaPct,
    required this.banderas,
    required this.bdAddr,
    required this.version,
    required this.modelo,
    required this.soc,
    required this.compilacion,
    required this.idAparato,
    required this.ajustesVersion,
  });

  static const int tam = 128;

  bool get hayTarjeta => banderas & 0x01 != 0;
  bool get cargando => banderas & 0x02 != 0;
  bool get puenteCompilado => banderas & 0x04 != 0;
  bool get arranqueVigilado => banderas & 0x08 != 0;
  bool get idVinculado => banderas & 0x10 != 0;

  /// null si el teléfono no sabe su batería.
  int? get bateria => bateriaPct == 0xFF ? null : bateriaPct;

  String get api => '$apiMayor.$apiMenor';

  /// Dirección Bluetooth tal como la da el teléfono; null si no la sabe.
  String? get bdAddrTexto {
    if (bdAddr.every((b) => b == 0)) return null;
    return bdAddr.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');
  }

  static SenInfo deBytes(Uint8List b) {
    if (b.length < tam) {
      throw CanalMalFormado('SEN_INFO trajo ${b.length} B y son $tam.');
    }
    final v = ByteData.sublistView(b);
    final formato = v.getUint16(0, Endian.little);
    final declarado = v.getUint16(2, Endian.little);
    if (formato != 1) throw CanalMalFormado('SEN_INFO formato $formato.');
    if (declarado != tam) {
      throw CanalMalFormado('SEN_INFO dice medir $declarado B y son $tam.');
    }
    return SenInfo(
      build: v.getUint32(4, Endian.little),
      apiMayor: v.getUint16(8, Endian.little),
      apiMenor: v.getUint16(10, Endian.little),
      blVersion: v.getUint16(12, Endian.little),
      bateriaPct: v.getUint8(14),
      banderas: v.getUint8(15),
      bdAddr: Uint8List.fromList(b.sublist(16, 22)),
      version: _textoFijo(b, 24, 16),
      modelo: _textoFijo(b, 40, 8),
      soc: _textoFijo(b, 48, 8),
      compilacion: _textoFijo(b, 56, 24),
      idAparato: _textoFijo(b, 80, 16),
      ajustesVersion: v.getUint32(96, Endian.little),
    );
  }

  /// Escribe el dataset. Lo usan los dobles de las pruebas: así el formato no
  /// se copia a mano en dos sitios.
  Uint8List aBytes() {
    final b = Uint8List(tam);
    final v = ByteData.sublistView(b);
    v.setUint16(0, 1, Endian.little);
    v.setUint16(2, tam, Endian.little);
    v.setUint32(4, build, Endian.little);
    v.setUint16(8, apiMayor, Endian.little);
    v.setUint16(10, apiMenor, Endian.little);
    v.setUint16(12, blVersion, Endian.little);
    v.setUint8(14, bateriaPct);
    v.setUint8(15, banderas);
    b.setRange(16, 22, bdAddr);
    void texto(int off, int max, String s) {
      final u = utf8.encode(s);
      b.setRange(off, off + (u.length < max ? u.length : max - 1), u);
    }

    texto(24, 16, version);
    texto(40, 8, modelo);
    texto(48, 8, soc);
    texto(56, 24, compilacion);
    texto(80, 16, idAparato);
    v.setUint32(96, ajustesVersion, Endian.little);
    return b;
  }
}

/// Un ajuste tal como lo devuelve `SEN_AJ_LEER`. El rango lo dice el firmware.
class AjusteLeido {
  final int clave;
  final int tipo;
  final int min;
  final int max;      // tipo 4: capacidad en bytes
  final Object valor; // bool, int o String

  const AjusteLeido({
    required this.clave,
    required this.tipo,
    required this.min,
    required this.max,
    required this.valor,
  });

  bool get esBool => tipo == tipoAjBool;
  bool get esTexto => tipo == tipoAjTexto;
  int get entero => valor is bool ? ((valor as bool) ? 1 : 0) : valor as int;
  String get texto => valor is String ? valor as String : '$valor';
}

/// Lo que se manda a `SEN_AJ_PONER`.
class AjustePoner {
  final int clave;
  final int tipo;
  final Object valor;
  const AjustePoner(this.clave, this.tipo, this.valor);
}

Object _valorDeBytes(int tipo, Uint8List v) {
  switch (tipo) {
    case tipoAjBool:
      if (v.length != 1) throw const CanalMalFormado('bool de largo distinto a 1.');
      return v[0] != 0;
    case tipoAjU8:
      if (v.length != 1) throw const CanalMalFormado('u8 de largo distinto a 1.');
      return v[0];
    case tipoAjI16:
      if (v.length != 2) throw const CanalMalFormado('i16 de largo distinto a 2.');
      return ByteData.sublistView(v).getInt16(0, Endian.little);
    case tipoAjTexto:
      return utf8.decode(v, allowMalformed: true);
    default:
      // Un tipo que este SENUS no conoce: se conserva crudo, sin interpretarlo.
      return Uint8List.fromList(v);
  }
}

Uint8List _valorABytes(int tipo, Object valor) {
  switch (tipo) {
    case tipoAjBool:
      final b = valor is bool ? valor : (valor as int) != 0;
      return Uint8List.fromList([b ? 1 : 0]);
    case tipoAjU8:
      return Uint8List.fromList([(valor as int) & 0xFF]);
    case tipoAjI16:
      final d = ByteData(2)..setInt16(0, valor as int, Endian.little);
      return d.buffer.asUint8List();
    case tipoAjTexto:
      final u = Uint8List.fromList(utf8.encode(valor as String));
      if (u.length > 255) {
        throw ArgumentError('Un texto de ajuste no pasa de 255 bytes.');
      }
      return u;
    default:
      throw ArgumentError('Tipo de ajuste desconocido: $tipo');
  }
}

/// Dataset de `SEN_AJ_LEER`: `u16 formato=1, u16 n`, y n veces
/// `{ u16 clave, u8 tipo, u8 largo, i16 min, i16 max, u8 valor[largo] }`.
List<AjusteLeido> parsearAjustes(Uint8List b) {
  if (b.length < 4) throw const CanalMalFormado('SEN_AJ_LEER sin cabecera.');
  final v = ByteData.sublistView(b);
  final formato = v.getUint16(0, Endian.little);
  if (formato != 1) throw CanalMalFormado('SEN_AJ_LEER formato $formato.');
  final n = v.getUint16(2, Endian.little);
  final out = <AjusteLeido>[];
  var off = 4;
  for (var i = 0; i < n; i++) {
    if (off + 8 > b.length) {
      throw CanalMalFormado('SEN_AJ_LEER cortado en la entrada $i de $n.');
    }
    final clave = v.getUint16(off, Endian.little);
    final tipo = v.getUint8(off + 2);
    final largo = v.getUint8(off + 3);
    final min = v.getInt16(off + 4, Endian.little);
    final max = v.getInt16(off + 6, Endian.little);
    off += 8;
    if (off + largo > b.length) {
      throw CanalMalFormado('El valor de 0x${clave.toRadixString(16)} se sale.');
    }
    out.add(AjusteLeido(
      clave: clave,
      tipo: tipo,
      min: min,
      max: max,
      valor: _valorDeBytes(tipo, Uint8List.sublistView(b, off, off + largo)),
    ));
    off += largo;
  }
  return out;
}

/// Escribe el dataset de `SEN_AJ_LEER`, para los dobles de las pruebas.
Uint8List empaquetarAjustesLeidos(List<AjusteLeido> l) {
  final b = BytesBuilder(copy: false);
  final cab = ByteData(4)
    ..setUint16(0, 1, Endian.little)
    ..setUint16(2, l.length, Endian.little);
  b.add(cab.buffer.asUint8List());
  for (final a in l) {
    final v = _valorABytes(a.tipo, a.valor);
    final e = ByteData(8)
      ..setUint16(0, a.clave, Endian.little)
      ..setUint8(2, a.tipo)
      ..setUint8(3, v.length)
      ..setInt16(4, a.min, Endian.little)
      ..setInt16(6, a.max, Endian.little);
    b.add(e.buffer.asUint8List());
    b.add(v);
  }
  return b.toBytes();
}

/// Dataset de `SEN_AJ_PONER`: `u16 formato=1, u16 n`, y n veces
/// `{ u16 clave, u8 tipo, u8 largo, u8 valor[largo] }`.
Uint8List empaquetarAjustes(List<AjustePoner> l) {
  final b = BytesBuilder(copy: false);
  final cab = ByteData(4)
    ..setUint16(0, 1, Endian.little)
    ..setUint16(2, l.length, Endian.little);
  b.add(cab.buffer.asUint8List());
  for (final a in l) {
    final v = _valorABytes(a.tipo, a.valor);
    final e = ByteData(4)
      ..setUint16(0, a.clave, Endian.little)
      ..setUint8(2, a.tipo)
      ..setUint8(3, v.length);
    b.add(e.buffer.asUint8List());
    b.add(v);
  }
  return b.toBytes();
}

/// ¿Lo aceptaría `SEN_RELOJ`? Años 2000..2099 y zona -720..840.
bool relojValido(DateTime utc, int zonaMin) {
  final a = utc.toUtc().year;
  return a >= 2000 && a <= 2099 && zonaMin >= -720 && zonaMin <= 840;
}

/// `SEN_RELOJ`: `u32 utc_unix, i16 zona_min, u16 reserva`.
Uint8List empaquetarReloj(DateTime utc, int zonaMin) {
  final d = ByteData(8)
    ..setUint32(0, utc.toUtc().millisecondsSinceEpoch ~/ 1000, Endian.little)
    ..setInt16(4, zonaMin, Endian.little)
    ..setUint16(6, 0, Endian.little);
  return d.buffer.asUint8List();
}

/// ¿Vale como identificador para `SEN_VINCULAR`? 14 o 15 dígitos.
bool idVincularValido(String id) => RegExp(r'^\d{14,15}$').hasMatch(id);

/// `SEN_VINCULAR`: `char id[16]`: 14 o 15 dígitos y NUL.
Uint8List empaquetarVincular(String id) {
  if (!idVincularValido(id)) {
    throw ArgumentError('El id de aparato son 14 o 15 dígitos.');
  }
  final b = Uint8List(16);
  b.setRange(0, id.length, ascii.encode(id));
  return b;
}

/// `SEN_BT_ESTADO`: 12 bytes.
class BtEstado {
  final bool encendido;
  final bool puenteConectado;
  final bool redLista;
  final int fallo;
  final Uint8List puenteAddr;

  const BtEstado({
    required this.encendido,
    required this.puenteConectado,
    required this.redLista,
    required this.fallo,
    required this.puenteAddr,
  });

  static const int tam = 12;

  static BtEstado deBytes(Uint8List b) {
    if (b.length < tam) {
      throw CanalMalFormado('SEN_BT_ESTADO trajo ${b.length} B y son $tam.');
    }
    return BtEstado(
      encendido: b[0] != 0,
      puenteConectado: b[1] != 0,
      redLista: b[2] != 0,
      fallo: b[3],
      puenteAddr: Uint8List.fromList(b.sublist(4, 10)),
    );
  }

  /// Escribe el dataset, para los dobles de las pruebas.
  Uint8List aBytes() {
    final b = Uint8List(tam);
    b[0] = encendido ? 1 : 0;
    b[1] = puenteConectado ? 1 : 0;
    b[2] = redLista ? 1 : 0;
    b[3] = fallo;
    b.setRange(4, 10, puenteAddr);
    return b;
  }
}

/// ¿Vale como PIN de `SEN_BT_EMPAREJAR`? 1..16 caracteres ASCII imprimibles.
bool pinEmparejarValido(String pin) =>
    RegExp(r'^[\x20-\x7E]{1,16}$').hasMatch(pin);

/// `SEN_BT_EMPAREJAR`: 24 bytes: `u8 addr[6]`, `u8 pin_n`, `char pin[16]`,
/// `u8 reserva`. [addr] va en el mismo orden que `bd_addr`.
Uint8List empaquetarEmparejar(List<int> addr, String pin) {
  if (addr.length != 6) {
    throw ArgumentError('La dirección Bluetooth son 6 bytes.');
  }
  if (!pinEmparejarValido(pin)) {
    throw ArgumentError('El PIN son de 1 a 16 caracteres ASCII.');
  }
  final b = Uint8List(24);
  b.setRange(0, 6, addr);
  b[6] = pin.length;
  b.setRange(7, 7 + pin.length, ascii.encode(pin));
  return b;
}

/// Una entrada de `SEN_APPS` (§6): 128 bytes.
class SenApp {
  final int origen; // 0 fábrica, 1 /memoria/apps, 2 /tarjeta/apps, 3 /tarjeta/juegos
  final int banderas;
  final int perfil;
  final int iconoGen;
  final int iconoAn;
  final int apiMayor;
  final int apiMenor;
  final int verApp;
  final int tam;
  final List<int> iconoFilas; // 12 u16
  final String nombre;
  final String fichero;

  const SenApp({
    required this.origen,
    required this.banderas,
    required this.perfil,
    required this.iconoGen,
    required this.iconoAn,
    required this.apiMayor,
    required this.apiMenor,
    required this.verApp,
    required this.tam,
    required this.iconoFilas,
    required this.nombre,
    required this.fichero,
  });

  static const int tamEntrada = 128;

  bool get protegida => banderas & 0x01 != 0;
  bool get tapada => banderas & 0x02 != 0;

  static SenApp deBytes(Uint8List b, int off) {
    if (off + tamEntrada > b.length) {
      throw const CanalMalFormado('Entrada de SEN_APPS cortada.');
    }
    final v = ByteData.sublistView(b, off, off + tamEntrada);
    return SenApp(
      origen: v.getUint8(0),
      banderas: v.getUint8(1),
      perfil: v.getUint8(2),
      iconoGen: v.getUint8(3),
      iconoAn: v.getUint8(4),
      apiMayor: v.getUint16(6, Endian.little),
      apiMenor: v.getUint16(8, Endian.little),
      verApp: v.getUint32(12, Endian.little),
      tam: v.getUint32(16, Endian.little),
      iconoFilas: [
        for (var i = 0; i < 12; i++) v.getUint16(20 + i * 2, Endian.little)
      ],
      nombre: _textoFijo(b, off + 44, 30),
      fichero: _textoFijo(b, off + 74, 54),
    );
  }

  /// Escribe la entrada, para los dobles de las pruebas.
  Uint8List aBytes() {
    final b = Uint8List(tamEntrada);
    final v = ByteData.sublistView(b);
    v.setUint8(0, origen);
    v.setUint8(1, banderas);
    v.setUint8(2, perfil);
    v.setUint8(3, iconoGen);
    v.setUint8(4, iconoAn);
    v.setUint16(6, apiMayor, Endian.little);
    v.setUint16(8, apiMenor, Endian.little);
    v.setUint32(12, verApp, Endian.little);
    v.setUint32(16, tam, Endian.little);
    for (var i = 0; i < 12; i++) {
      v.setUint16(20 + i * 2, iconoFilas[i], Endian.little);
    }
    void texto(int o, int max, String s) {
      final u = utf8.encode(s);
      b.setRange(o, o + (u.length < max ? u.length : max - 1), u);
    }

    texto(44, 30, nombre);
    texto(74, 54, fichero);
    return b;
  }
}

/// Cabecera de `SEN_APPS`: `u16 formato=1, u16 total, u16 n, u16 tam_entrada`.
class PaginaApps {
  final int total;
  final List<SenApp> apps;
  const PaginaApps(this.total, this.apps);

  static PaginaApps deBytes(Uint8List b) {
    if (b.length < 8) throw const CanalMalFormado('SEN_APPS sin cabecera.');
    final v = ByteData.sublistView(b);
    final formato = v.getUint16(0, Endian.little);
    if (formato != 1) throw CanalMalFormado('SEN_APPS formato $formato.');
    final total = v.getUint16(2, Endian.little);
    final n = v.getUint16(4, Endian.little);
    final tam = v.getUint16(6, Endian.little);
    if (tam != SenApp.tamEntrada) {
      throw CanalMalFormado('SEN_APPS tam_entrada $tam.');
    }
    if (8 + n * tam > b.length) {
      throw CanalMalFormado('SEN_APPS anuncia $n entradas y no caben.');
    }
    return PaginaApps(
        total, [for (var i = 0; i < n; i++) SenApp.deBytes(b, 8 + i * tam)]);
  }
}
