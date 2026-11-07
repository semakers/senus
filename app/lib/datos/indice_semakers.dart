// El índice firmado y los manifiestos (§5 del diseño), sin red ni disco: qué
// dicen y si se les puede creer. La firma va sobre los bytes EXACTOS del JSON,
// sin reformatear: por eso aquí viajan los bytes, no el objeto.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as cripto;
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;

import 'sen_cab.dart';
import 'transporte_bl.dart'
    show blBloque, blMainFin, blMainIni, crc32DeDatos;

/// Por qué no se aceptó algo del backend. Todo lo que llega aquí ha fallado
/// ANTES de tocar el teléfono.
enum MotivoRechazo {
  sinClaves,
  firmaMala,
  formatoMalo,
  caducado,
  secuenciaVieja,
  shaDistinto,
  tamanoDistinto,
  noCuadraConIndice,
  imagenMala,
  otroAparato,
}

class ErrorVerificacion implements Exception {
  final MotivoRechazo motivo;
  final String detalle;
  const ErrorVerificacion(this.motivo, this.detalle);
  @override
  String toString() => detalle;
}

String sha256De(List<int> b) => cripto.sha256.convert(b).toString();

/// ¿Alguna de las claves firmó estos bytes exactos? Las públicas que no sean
/// de 32 bytes cuentan como que no firmaron.
bool firmaValida(Uint8List datos, Uint8List firma, List<Uint8List> claves) {
  if (firma.length != ed.SignatureSize) return false;
  for (final c in claves) {
    if (c.length != ed.PublicKeySize) continue;
    try {
      if (ed.verify(ed.PublicKey(c), datos, firma)) return true;
    } catch (_) {
      // Una clave o una firma imposibles no son una firma válida.
    }
  }
  return false;
}

void exigirFirma(Uint8List datos, Uint8List firma, List<Uint8List> claves,
    String que) {
  if (claves.isEmpty) {
    throw const ErrorVerificacion(
        MotivoRechazo.sinClaves,
        'Esta compilación de SENUS no tiene claves públicas: no puede verificar '
        'nada del catálogo.');
  }
  if (!firmaValida(datos, firma, claves)) {
    throw ErrorVerificacion(
        MotivoRechazo.firmaMala, '$que no lo firmó una clave aceptada.');
  }
}

Map<String, dynamic> _jsonDe(Uint8List bytes, String que) {
  try {
    final v = jsonDecode(utf8.decode(bytes));
    if (v is Map<String, dynamic>) return v;
  } catch (_) {
    // Cae al error de abajo.
  }
  throw ErrorVerificacion(MotivoRechazo.formatoMalo, '$que no es JSON válido.');
}

Never _malo(String que, String campo) => throw ErrorVerificacion(
    MotivoRechazo.formatoMalo, '$que no vale: campo «$campo».');

T _campo<T>(Map<String, dynamic> m, String c, String que) {
  final v = m[c];
  if (v is T) return v;
  _malo(que, c);
}

DateTime _fecha(Map<String, dynamic> m, String c, String que) {
  final t = DateTime.tryParse(_campo<String>(m, c, que));
  if (t == null) _malo(que, c);
  return t.toUtc();
}

(int, int) _api(String api, String que) {
  final m = RegExp(r'^(\d{1,4})\.(\d{1,4})$').firstMatch(api);
  if (m == null) _malo(que, 'api');
  return (int.parse(m[1]!), int.parse(m[2]!));
}

/// A dónde va una app (`docs/contrato_juegos_con_datos.md`): la Memoria, como
/// hasta ahora, o `/tarjeta/juegos` con sus datos al lado.
const String destinoApps = 'apps';
const String destinoJuegos = 'juegos';

/// Los topes del contrato para los datos de un juego.
const int maxArchivosDatos = 64;
const int maxBytesDato = 32 << 20;
const int maxBytesDatos = 96 << 20;
final RegExp _reCarpetaDatos = RegExp(r'^[a-z0-9_]{1,8}$');
final RegExp _reNombreDato = RegExp(r'^[a-z0-9_]{1,8}\.[a-z0-9]{1,3}$');
final RegExp _reSha256 = RegExp(r'^[0-9a-f]{64}$');

/// Un fichero de datos de un juego, como lo dice su manifiesto firmado.
class ArchivoDato {
  final String nombre;
  final int bytes;
  final String sha256;
  const ArchivoDato(this.nombre, this.bytes, this.sha256);
}

/// Los datos de un juego: van a `/tarjeta/juegos/<carpeta>/`.
class DatosJuego {
  final String carpeta;
  final List<ArchivoDato> archivos;
  const DatosJuego(this.carpeta, this.archivos);

  int get bytes => archivos.fold(0, (s, a) => s + a.bytes);

  /// `datos` de un manifiesto. Lanza si no cumple el contrato: 8.3 y
  /// minúsculas, sin repetidos, de 1 a 64, cada uno hasta 32 MiB y en total
  /// hasta 96 MiB.
  static DatosJuego deJson(Object? v, String que) {
    if (v is! Map<String, dynamic>) _malo(que, 'datos');
    final carpeta = v['carpeta'];
    if (carpeta is! String || !_reCarpetaDatos.hasMatch(carpeta)) {
      _malo(que, 'datos.carpeta');
    }
    final l = v['archivos'];
    if (l is! List || l.isEmpty || l.length > maxArchivosDatos) {
      _malo(que, 'datos.archivos');
    }
    final vistos = <String>{};
    final out = <ArchivoDato>[];
    var total = 0;
    for (final x in l) {
      if (x is! Map<String, dynamic>) _malo(que, 'datos.archivos');
      final n = x['nombre'], b = x['bytes'], s = x['sha256'];
      if (n is! String || !_reNombreDato.hasMatch(n) || !vistos.add(n)) {
        _malo(que, 'datos.archivos.nombre');
      }
      if (b is! int || b < 0 || b > maxBytesDato) {
        _malo(que, 'datos.archivos.bytes');
      }
      if (s is! String || !_reSha256.hasMatch(s)) {
        _malo(que, 'datos.archivos.sha256');
      }
      total += b;
      out.add(ArchivoDato(n, b, s));
    }
    if (total > maxBytesDatos) _malo(que, 'datos.archivos.bytes');
    return DatosJuego(carpeta, List.unmodifiable(out));
  }
}

/// Los datos de un manifiesto de app ya verificado; null si no trae.
DatosJuego? datosDeManifiesto(Map<String, dynamic> m) {
  final d = m['datos'];
  return d == null ? null : DatosJuego.deJson(d, 'El manifiesto de la app');
}

/// Una app del índice.
class AppIndice {
  final String id;
  final String nombre;
  final String autor;
  final String descripcion;
  final String categoria;
  final int verApp;
  final String versionTexto;
  final String api;
  final int maquina;
  final int perfil;
  final int caps;
  final int anMin;
  final int alMin;
  final int iconoGen;
  final int iconoAn;
  final List<int> iconoFilas;
  final int tam;
  final String sha256;
  final String notas;
  final String manifiestoSha256;

  /// `"apps"` (la Memoria) o `"juegos"` (la tarjeta). Un índice viejo no lo
  /// trae: entonces es `"apps"`. Otro valor se lee, pero no se instala.
  final String destino;

  /// Lo que suman los datos del juego; 0 si no lleva.
  final int datosBytes;

  const AppIndice({
    required this.id,
    required this.nombre,
    required this.autor,
    required this.descripcion,
    required this.categoria,
    required this.verApp,
    required this.versionTexto,
    required this.api,
    required this.maquina,
    required this.perfil,
    required this.caps,
    required this.anMin,
    required this.alMin,
    required this.iconoGen,
    required this.iconoAn,
    required this.iconoFilas,
    required this.tam,
    required this.sha256,
    required this.notas,
    required this.manifiestoSha256,
    this.destino = destinoApps,
    this.datosBytes = 0,
  });

  String get fichero => '$id.sen';

  /// Va a `/tarjeta/juegos`.
  bool get esJuego => destino == destinoJuegos;

  /// Esta SENUS sabe instalarla.
  bool get destinoConocido => destino == destinoApps || destino == destinoJuegos;

  /// Lo que ocupa en el teléfono: el `.sen` y sus datos.
  int get tamTotal => tam + datosBytes;

  /// Para pintarla con el mismo pintor que una cabecera.
  SenCab get cabecera => SenCab(
        nombre: nombre,
        iconoAn: iconoAn,
        iconoFilas: iconoFilas.length == 12
            ? iconoFilas
            : List<int>.filled(12, 0),
        iconoGen: iconoGen,
        tamFich: tam,
        perfil: perfil,
        apiMayor: _api(api, 'La app').$1,
        apiMenor: _api(api, 'La app').$2,
        verApp: verApp,
        maquina: maquina,
        caps: caps,
        anMin: anMin,
        alMin: alMin,
      );

  static AppIndice deJson(Map<String, dynamic> m) {
    const q = 'Una app del índice';
    final ic = _campo<Map<String, dynamic>>(m, 'icono', q);
    final id = _campo<String>(m, 'id', q);
    // El id es el nombre de fichero en el teléfono: nada de barras ni puntos.
    if (!RegExp(r'^[a-z0-9][a-z0-9_-]{0,47}$').hasMatch(id)) _malo(q, 'id');
    // Los dos campos de los juegos faltan en un índice viejo: valen lo de hoy.
    final destino = m['destino'] ?? destinoApps;
    if (destino is! String || destino.isEmpty) _malo(q, 'destino');
    final datosBytes = m['datos_bytes'] ?? 0;
    if (datosBytes is! int || datosBytes < 0 || datosBytes > maxBytesDatos) {
      _malo(q, 'datos_bytes');
    }
    if (destino == destinoApps && datosBytes != 0) _malo(q, 'datos_bytes');
    return AppIndice(
      destino: destino,
      datosBytes: datosBytes,
      id: id,
      nombre: _campo<String>(m, 'nombre', q),
      autor: _campo<String>(m, 'autor', q),
      descripcion: _campo<String>(m, 'descripcion', q),
      categoria: _campo<String>(m, 'categoria', q),
      verApp: _campo<int>(m, 'ver_app', q),
      versionTexto: _campo<String>(m, 'version_texto', q),
      api: _campo<String>(m, 'api', q),
      maquina: _campo<int>(m, 'maquina', q),
      perfil: _campo<int>(m, 'perfil', q),
      caps: _campo<int>(m, 'caps', q),
      anMin: _campo<int>(m, 'an_min', q),
      alMin: _campo<int>(m, 'al_min', q),
      iconoGen: _campo<int>(ic, 'gen', q),
      iconoAn: _campo<int>(ic, 'an', q),
      iconoFilas: _campo<List<dynamic>>(ic, 'filas', q).cast<int>(),
      tam: _campo<int>(m, 'tam', q),
      sha256: _campo<String>(m, 'sha256', q),
      notas: _campo<String>(m, 'notas', q),
      manifiestoSha256: _campo<String>(m, 'manifiesto_sha256', q),
    );
  }
}

/// Una release de senew del índice.
class ReleaseIndice {
  final String modelo;
  final String soc;
  final int build;
  final String version;
  final String canal;
  final String api;
  final int blVersionMin;
  final int buildMinOrigen;
  final String mainSha256;
  final int mainTam;
  final String notas;
  final DateTime publicada;
  final String manifiestoSha256;

  const ReleaseIndice({
    required this.modelo,
    required this.soc,
    required this.build,
    required this.version,
    required this.canal,
    required this.api,
    required this.blVersionMin,
    required this.buildMinOrigen,
    required this.mainSha256,
    required this.mainTam,
    required this.notas,
    required this.publicada,
    required this.manifiestoSha256,
  });

  static ReleaseIndice deJson(Map<String, dynamic> m) {
    const q = 'Una release del índice';
    return ReleaseIndice(
      modelo: _campo<String>(m, 'modelo', q),
      soc: _campo<String>(m, 'soc', q),
      build: _campo<int>(m, 'build', q),
      version: _campo<String>(m, 'version', q),
      canal: _campo<String>(m, 'canal', q),
      api: _campo<String>(m, 'api', q),
      blVersionMin: _campo<int>(m, 'bl_version_min', q),
      buildMinOrigen: _campo<int>(m, 'build_min_origen', q),
      mainSha256: _campo<String>(m, 'main_sha256', q),
      mainTam: _campo<int>(m, 'main_tam', q),
      notas: _campo<String>(m, 'notas', q),
      publicada: _fecha(m, 'publicada_utc', q),
      manifiestoSha256: _campo<String>(m, 'manifiesto_sha256', q),
    );
  }
}

class IndiceSemakers {
  final int secuencia;
  final DateTime generado;
  final DateTime caduca;
  final List<AppIndice> apps;
  final List<ReleaseIndice> senew;

  const IndiceSemakers({
    required this.secuencia,
    required this.generado,
    required this.caduca,
    required this.apps,
    required this.senew,
  });

  /// Las releases de un modelo, de la más nueva a la más vieja.
  List<ReleaseIndice> releasesDe(String modelo) =>
      senew.where((r) => r.modelo == modelo).toList()
        ..sort((a, b) => b.build.compareTo(a.build));

  AppIndice? app(String id) {
    for (final a in apps) {
      if (a.id == id) return a;
    }
    return null;
  }
}

/// Comprueba un índice por este orden: firma, forma, caducidad y secuencia.
/// Devuelve el índice solo si pasa todo.
IndiceSemakers verificarIndice({
  required Uint8List bytes,
  required Uint8List firma,
  required List<Uint8List> claves,
  required DateTime ahora,
  required int secuenciaVista,
  String? shaVisto,
}) {
  exigirFirma(bytes, firma, claves, 'El índice');
  const q = 'El índice';
  final m = _jsonDe(bytes, q);
  if (m['formato'] != 1) _malo(q, 'formato');
  if (m['tipo'] != 'indice') _malo(q, 'tipo');
  final sec = _campo<int>(m, 'secuencia', q);
  final caduca = _fecha(m, 'caduca_utc', q);
  if (ahora.toUtc().isAfter(caduca)) {
    throw ErrorVerificacion(MotivoRechazo.caducado,
        'El índice caducó el ${caduca.toIso8601String()}.');
  }
  if (sec < secuenciaVista) {
    throw ErrorVerificacion(
        MotivoRechazo.secuenciaVieja,
        'El índice es más viejo que el último visto '
        '(secuencia $sec, ya se vio la $secuenciaVista).');
  }
  // La misma secuencia con otros bytes no se puede dar sin la clave de firma:
  // si pasa, algo va mal y no se elige a ciegas cuál creer.
  if (sec == secuenciaVista && shaVisto != null && sha256De(bytes) != shaVisto) {
    throw ErrorVerificacion(MotivoRechazo.secuenciaVieja,
        'Dos índices distintos dicen ser la secuencia $sec.');
  }
  try {
    return IndiceSemakers(
      secuencia: sec,
      generado: _fecha(m, 'generado_utc', q),
      caduca: caduca,
      apps: [
        for (final a in _campo<List<dynamic>>(m, 'apps', q))
          AppIndice.deJson(a as Map<String, dynamic>)
      ],
      senew: [
        for (final s in _campo<List<dynamic>>(m, 'senew', q))
          ReleaseIndice.deJson(s as Map<String, dynamic>)
      ],
    );
  } on TypeError {
    _malo(q, 'contenido');
  }
}

/// Un manifiesto ya verificado: los bytes firmados y su firma se guardan tal
/// cual para reverificar sin red.
class ManifiestoVerificado {
  final Uint8List bytes;
  final Uint8List firma;
  final Map<String, dynamic> json;
  const ManifiestoVerificado(this.bytes, this.firma, this.json);
}

ManifiestoVerificado _verificarManifiesto(Uint8List bytes, Uint8List firma,
    List<Uint8List> claves, String shaEsperado, String que) {
  if (sha256De(bytes) != shaEsperado) {
    throw ErrorVerificacion(MotivoRechazo.shaDistinto,
        '$que no es el que dice el índice: su sha256 no coincide.');
  }
  exigirFirma(bytes, firma, claves, que);
  return ManifiestoVerificado(bytes, firma, _jsonDe(bytes, que));
}

Never _noCuadra(String que, String campo) => throw ErrorVerificacion(
    MotivoRechazo.noCuadraConIndice,
    '$que no coincide con el índice en «$campo».');

/// Verifica el manifiesto de una app contra su entrada del índice.
ManifiestoVerificado verificarManifiestoApp(Uint8List bytes, Uint8List firma,
    List<Uint8List> claves, AppIndice a) {
  const q = 'El manifiesto de la app';
  final v = _verificarManifiesto(bytes, firma, claves, a.manifiestoSha256, q);
  final m = v.json;
  if (m['formato'] != 1) _malo(q, 'formato');
  if (m['tipo'] != 'app') _malo(q, 'tipo');
  if (m['id'] != a.id) _noCuadra(q, 'id');
  if (m['ver_app'] != a.verApp) _noCuadra(q, 'ver_app');
  final s = _campo<Map<String, dynamic>>(m, 'sen', q);
  if (s['sha256'] != a.sha256 || s['archivo'] != a.sha256) {
    _noCuadra(q, 'sen.sha256');
  }
  if (s['bytes'] != a.tam) _noCuadra(q, 'sen.bytes');
  // Sin los campos de los juegos, el manifiesto es el de siempre.
  final destino = m['destino'] ?? destinoApps;
  if (destino != a.destino) _noCuadra(q, 'destino');
  if (!a.destinoConocido) {
    throw ErrorVerificacion(MotivoRechazo.formatoMalo,
        '«${a.nombre}» va a «${a.destino}», y esta SENUS no sabe instalar ahí.');
  }
  if (a.esJuego && (a.perfil != 2 || m['perfil'] != 2)) _malo(q, 'perfil');
  final d = m['datos'];
  if (d == null) {
    if (a.datosBytes != 0) _noCuadra(q, 'datos_bytes');
  } else {
    if (!a.esJuego) _malo(q, 'datos');
    if (DatosJuego.deJson(d, q).bytes != a.datosBytes) {
      _noCuadra(q, 'datos_bytes');
    }
  }
  return v;
}

/// Lo que se comprueba en los bytes de un .sen ya descargado.
void verificarSen(Uint8List bytes, AppIndice a) {
  if (bytes.length != a.tam) {
    throw ErrorVerificacion(MotivoRechazo.tamanoDistinto,
        '${a.fichero}: ${bytes.length} B, el índice dice ${a.tam}.');
  }
  if (sha256De(bytes) != a.sha256) {
    throw ErrorVerificacion(
        MotivoRechazo.shaDistinto, '${a.fichero}: el sha256 no coincide.');
  }
  final p = problemaDeSen(bytes);
  if (p != null) {
    throw ErrorVerificacion(MotivoRechazo.imagenMala, '${a.fichero}: $p');
  }
  final c = SenCab.deBytes(bytes)!;
  if (c.verApp != a.verApp) {
    throw ErrorVerificacion(MotivoRechazo.noCuadraConIndice,
        '${a.fichero}: la cabecera dice ver_app ${c.verApp} y el índice ${a.verApp}.');
  }
  // senew solo arranca un juego (perfil 2) desde /tarjeta/juegos.
  if (a.esJuego && c.perfil != 2) {
    throw ErrorVerificacion(MotivoRechazo.imagenMala,
        '${a.fichero}: va a «Juegos» y su cabecera dice perfil ${c.perfil}, no 2.');
  }
}

/// Verifica el manifiesto de una release contra su entrada del índice.
ManifiestoVerificado verificarManifiestoSenew(Uint8List bytes, Uint8List firma,
    List<Uint8List> claves, ReleaseIndice r) {
  const q = 'El manifiesto de la release';
  final v = _verificarManifiesto(bytes, firma, claves, r.manifiestoSha256, q);
  final m = v.json;
  if (m['formato'] != 1) _malo(q, 'formato');
  if (m['tipo'] != 'senew') _malo(q, 'tipo');
  if (m['modelo'] != r.modelo) _noCuadra(q, 'modelo');
  if (m['soc'] != r.soc) _noCuadra(q, 'soc');
  if (m['build'] != r.build) _noCuadra(q, 'build');
  if (m['version'] != r.version) _noCuadra(q, 'version');
  final p = _campo<Map<String, dynamic>>(m, 'main', q);
  if (p['sha256'] != r.mainSha256 || p['archivo'] != r.mainSha256) {
    _noCuadra(q, 'main.sha256');
  }
  if (p['bytes'] != r.mainTam) _noCuadra(q, 'main.bytes');
  return v;
}

const int _vecReset = 0xE59FF018; // ldr pc, [pc, #0x18]
const int _despReset = 0x20;

/// La regla de `bl_arranque.S`: ¿el BL saltaría a esta imagen? Primera palabra
/// y vector de reset dentro del tramo. Si no, devuelve el motivo.
String? problemaDeMain(Uint8List b) {
  if (b.length < _despReset + 4) return 'La imagen no llega ni a los vectores.';
  if (b.length > blMainFin - blMainIni) {
    return 'La imagen no cabe en los '
        '${(blMainFin - blMainIni) ~/ blBloque} bloques del main.';
  }
  final v = ByteData.sublistView(b);
  if (v.getUint32(0, Endian.little) != _vecReset) {
    return 'La primera palabra no es ldr pc, [pc, #0x18].';
  }
  final reset = v.getUint32(_despReset, Endian.little);
  // El BL solo mira el tramo; aquí además debe caer en la imagen: fuera de
  // ella solo habría flash en blanco.
  if (reset < blMainIni || reset >= blMainIni + b.length) {
    return 'El vector de reset 0x${reset.toRadixString(16)} cae fuera de la imagen.';
  }
  return null;
}

/// Todo lo que el §5.2 exige a una imagen antes de tocar el teléfono.
void verificarMain(Uint8List bytes, ReleaseIndice r, Map<String, dynamic> m) {
  if (bytes.length != r.mainTam) {
    throw ErrorVerificacion(MotivoRechazo.tamanoDistinto,
        'La imagen mide ${bytes.length} B y la release dice ${r.mainTam}.');
  }
  if (sha256De(bytes) != r.mainSha256) {
    throw const ErrorVerificacion(
        MotivoRechazo.shaDistinto, 'El sha256 de la imagen no coincide.');
  }
  final p = problemaDeMain(bytes);
  if (p != null) throw ErrorVerificacion(MotivoRechazo.imagenMala, p);
  final main = m['main'];
  if (main is! Map<String, dynamic>) _malo('El manifiesto', 'main');
  final crc = crc32DeDatos(bytes).toRadixString(16).padLeft(8, '0');
  if (main['crc32'] != crc) {
    throw ErrorVerificacion(MotivoRechazo.imagenMala,
        'El CRC-32 de la imagen ($crc) no es el del manifiesto.');
  }
  if (main['dir'] != '0x${blMainIni.toRadixString(16).padLeft(8, '0')}') {
    throw const ErrorVerificacion(MotivoRechazo.imagenMala,
        'El manifiesto manda la imagen a otra dirección.');
  }
}

/// Una imagen que no llega por el camino normal, sin entrada de índice con la
/// que cotejarla: se comprueba contra su manifiesto firmado, entero. Devuelve el
/// `bl.version_min` del manifiesto.
int verificarImagenFirmada(Uint8List imagen, ManifiestoVerificado m,
    List<Uint8List> claves, {required int build, required String version}) {
  const q = 'El manifiesto de la imagen';
  exigirFirma(m.bytes, m.firma, claves, q);
  final j = _jsonDe(m.bytes, q);
  if (j['formato'] != 1) _malo(q, 'formato');
  if (j['tipo'] != 'senew') _malo(q, 'tipo');
  if (j['modelo'] != 'w580' || j['soc'] != 'DB2020') {
    throw ErrorVerificacion(MotivoRechazo.otroAparato,
        'Esta imagen es para ${j['modelo']}/${j['soc']}.');
  }
  if (j['build'] != build) _noCuadra(q, 'build');
  if (j['version'] != version) _noCuadra(q, 'version');
  final main = _campo<Map<String, dynamic>>(j, 'main', q);
  if (imagen.length != main['bytes']) {
    throw ErrorVerificacion(MotivoRechazo.tamanoDistinto,
        'La imagen mide ${imagen.length} B y el manifiesto dice ${main['bytes']}.');
  }
  if (sha256De(imagen) != main['sha256']) {
    throw const ErrorVerificacion(MotivoRechazo.shaDistinto,
        'La imagen no es la del manifiesto: su sha256 no coincide.');
  }
  final crc = crc32DeDatos(imagen).toRadixString(16).padLeft(8, '0');
  if (main['crc32'] != crc) {
    throw ErrorVerificacion(MotivoRechazo.imagenMala,
        'El CRC-32 de la imagen ($crc) no es el del manifiesto.');
  }
  if (main['dir'] != '0x${blMainIni.toRadixString(16).padLeft(8, '0')}') {
    throw const ErrorVerificacion(MotivoRechazo.imagenMala,
        'El manifiesto manda la imagen a otra dirección.');
  }
  final p = problemaDeMain(imagen);
  if (p != null) throw ErrorVerificacion(MotivoRechazo.imagenMala, p);
  final bl = _campo<Map<String, dynamic>>(j, 'bl', q);
  return _campo<int>(bl, 'version_min', q);
}

/// ¿Esta release es para este aparato?
void verificarAparato(ReleaseIndice r,
    {required String modelo,
    required String soc,
    required int buildOrigen,
    required int blVersion}) {
  if (r.modelo != modelo || r.soc != soc) {
    throw ErrorVerificacion(MotivoRechazo.otroAparato,
        'Esta release es para ${r.modelo}/${r.soc} y el teléfono es $modelo/$soc.');
  }
  if (buildOrigen < r.buildMinOrigen) {
    throw ErrorVerificacion(MotivoRechazo.otroAparato,
        'Esta release pide venir del build ${r.buildMinOrigen} o posterior, y '
        'el teléfono tiene el $buildOrigen.');
  }
  // 0 = el teléfono no lo sabe: se comprueba en el paso 5, con BL_R_ID.
  if (blVersion != 0 && blVersion < r.blVersionMin) {
    throw ErrorVerificacion(MotivoRechazo.otroAparato,
        'Esta release pide el bootloader ${r.blVersionMin} y el teléfono tiene '
        'el $blVersion.');
  }
}
