// El backend de las pruebas, con una clave ed25519 propia de usar y tirar. Arma
// el índice y los manifiestos con el mismo JSON que `publicador.ts`
// (`JSON.stringify(v, null, 1)`) y los firma de verdad: lo que verifica SENUS es
// una firma real.

import 'dart:convert';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:senus_app/datos/backend_semakers.dart';
import 'package:senus_app/datos/indice_semakers.dart';
import 'package:senus_app/datos/transporte_bl.dart';

final Uint8List semilla = Uint8List.fromList(List.generate(32, (i) => i * 3));
final ed.PrivateKey privada = ed.newKeyFromSeed(semilla);
final Uint8List publica = Uint8List.fromList(ed.public(privada).bytes);

Uint8List firmar(Uint8List b, [ed.PrivateKey? k]) =>
    ed.sign(k ?? privada, b);

ed.PrivateKey claveDeSemilla(Uint8List semilla) => ed.newKeyFromSeed(semilla);

Uint8List jsonBytes(Object v) =>
    Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent(' ').convert(v)));

/// Un .sen válido con las tres CRC bien.
Uint8List senDePrueba({
  int verApp = 1,
  String nombre = 'Prueba',
  int tamCodigo = 64,
  int tamRec = 16,
  int perfil = 1,
  int iconoAn = 16,
}) {
  final cod = Uint8List(tamCodigo)..fillRange(0, tamCodigo, 0xAA);
  final rec = Uint8List(tamRec)..fillRange(0, tamRec, 0x55);
  final b = Uint8List(128 + tamCodigo + tamRec);
  final v = ByteData.sublistView(b);
  b.setRange(0, 4, const [0x57, 0x35, 0x58, 0x01]);
  v.setUint16(4, 128, Endian.little);
  b[6] = 1;
  b[7] = perfil;
  v.setUint16(8, 1, Endian.little);
  v.setUint16(10, 7, Endian.little);
  v.setUint32(12, 0x02000300, Endian.little);
  v.setUint16(16, 240, Endian.little);
  v.setUint16(18, 320, Endian.little);
  v.setUint32(20, b.length, Endian.little);
  v.setUint32(24, tamCodigo, Endian.little);
  v.setUint32(36, 4096, Endian.little);
  v.setUint32(52, verApp, Endian.little);
  b[56] = 4;
  b[57] = iconoAn;
  for (var i = 0; i < 12; i++) {
    v.setUint16(58 + i * 2, 0x0FF0, Endian.little);
  }
  b.setRange(82, 82 + utf8.encode(nombre).length, utf8.encode(nombre));
  v.setUint32(112, tamRec, Endian.little);
  b.setRange(128, 128 + tamCodigo, cod);
  b.setRange(128 + tamCodigo, b.length, rec);
  v.setUint32(116, crc32DeDatos(rec), Endian.little);
  v.setUint32(120, crc32DeDatos(cod), Endian.little);
  v.setUint32(124, crc32DeDatos(Uint8List.sublistView(b, 0, 124)), Endian.little);
  return b;
}

/// Los datos de un juego para publicar: nombre de fichero → contenido, en orden.
class DatosPublicar {
  final String carpeta;
  final Map<String, Uint8List> archivos;
  const DatosPublicar(this.carpeta, this.archivos);
  int get bytes => archivos.values.fold(0, (s, b) => s + b.length);
}

Map<String, dynamic> manifiestoApp(String id, Uint8List sen,
    {String nombre = 'Prueba',
    int? verApp,
    String? destino,
    DatosPublicar? datos}) {
  final s = sha256De(sen);
  final bd = ByteData.sublistView(sen);
  return {
    'formato': 1,
    'tipo': 'app',
    'id': id,
    'nombre': nombre,
    'autor': 'Semakers',
    'descripcion': 'Una app.',
    'categoria': 'utilidades',
    'ver_app': verApp ?? bd.getUint32(52, Endian.little),
    'version_texto': '1.0',
    'api': '1.7',
    'maquina': 1,
    'perfil': sen[7],
    'caps': bd.getUint32(12, Endian.little),
    'an_min': 240,
    'al_min': 320,
    'icono': {
      'gen': sen[56],
      'an': sen[57],
      'filas': [for (var i = 0; i < 12; i++) bd.getUint16(58 + i * 2, Endian.little)],
    },
    'sen': {'archivo': s, 'bytes': sen.length, 'sha256': s},
    // Como `manifiestoDeApp` del publicador: sin destino, ni el campo.
    if (destino != null) 'destino': destino,
    if (datos != null)
      'datos': {
        'carpeta': datos.carpeta,
        'archivos': [
          for (final e in datos.archivos.entries)
            {'nombre': e.key, 'bytes': e.value.length, 'sha256': sha256De(e.value)}
        ],
      },
    'notas': '',
    'publicada_utc': '2026-10-31T00:00:00.000Z',
  };
}

Map<String, dynamic> entradaApp(Map<String, dynamic> m, String manifSha,
        {bool nuevo = false}) =>
    {
      'id': m['id'],
      'nombre': m['nombre'],
      'autor': m['autor'],
      'descripcion': m['descripcion'],
      'categoria': m['categoria'],
      'ver_app': m['ver_app'],
      'version_texto': m['version_texto'],
      'api': m['api'],
      'maquina': m['maquina'],
      'perfil': m['perfil'],
      'caps': m['caps'],
      'an_min': m['an_min'],
      'al_min': m['al_min'],
      'icono': m['icono'],
      'tam': (m['sen'] as Map)['bytes'],
      'sha256': (m['sen'] as Map)['sha256'],
      // Un índice de los de antes no los trae; el nuevo, siempre.
      if (nuevo) 'destino': m['destino'] ?? 'apps',
      if (nuevo)
        'datos_bytes': [
          for (final a in ((m['datos'] as Map?)?['archivos'] as List?) ?? const [])
            (a as Map)['bytes'] as int
        ].fold<int>(0, (s, b) => s + b),
      'notas': m['notas'],
      'publicada_utc': m['publicada_utc'],
      'manifiesto_sha256': manifSha,
    };

Map<String, dynamic> manifiestoSenew(int build, String version, Uint8List main,
    {String modelo = 'w580',
    String soc = 'DB2020',
    int blMin = 1,
    int buildMinOrigen = 0,
    String canal = 'beta',
    String? crc}) {
  final s = sha256De(main);
  return {
    'formato': 1,
    'tipo': 'senew',
    'modelo': modelo,
    'soc': soc,
    'version': version,
    'build': build,
    'canal': canal,
    'publicada_utc': '2026-10-31T00:00:00.000Z',
    'main': {
      'archivo': s,
      'bytes': main.length,
      'sha256': s,
      'crc32': crc ?? crc32DeDatos(main).toRadixString(16).padLeft(8, '0'),
      'dir': '0x44180000',
    },
    'bl': {'version_min': blMin},
    'api': '1.11',
    'build_min_origen': buildMinOrigen,
    'notas': 'Notas de la $version.',
  };
}

Map<String, dynamic> entradaSenew(Map<String, dynamic> m, String manifSha) => {
      'modelo': m['modelo'],
      'soc': m['soc'],
      'build': m['build'],
      'version': m['version'],
      'canal': m['canal'],
      'api': m['api'],
      'bl_version_min': (m['bl'] as Map)['version_min'],
      'build_min_origen': m['build_min_origen'],
      'main_sha256': (m['main'] as Map)['sha256'],
      'main_tam': (m['main'] as Map)['bytes'],
      'notas': m['notas'],
      'publicada_utc': m['publicada_utc'],
      'manifiesto_sha256': manifSha,
    };

/// El servidor en memoria. `caido` simula que no hay red.
class RedSimulada implements RedSemakers {
  final Map<String, Uint8List> rutas = {};
  bool caido = false;
  int peticiones = 0;
  final List<String> pedidas = [];

  /// Corta la descarga de esta ruta a mitad.
  String? cortarRuta;

  /// Un fallo que no es de red, para ver que ninguna pantalla lo deja escapar.
  Object? errorRaro;

  void poner(String ruta, Uint8List b) => rutas[ruta] = b;

  @override
  Future<RespuestaRed> get(String ruta,
      {void Function(int, int)? alProgreso}) async {
    peticiones++;
    pedidas.add(ruta);
    if (errorRaro != null) throw errorRaro!;
    if (caido || ruta == cortarRuta) throw const SinRed('sin red simulada');
    final b = rutas[ruta];
    if (b == null) return RespuestaRed(404, Uint8List(0));
    alProgreso?.call(b.length, b.length);
    return RespuestaRed(200, b);
  }
}

/// Publica cosas en una [RedSimulada], como `publicar` en el backend de verdad.
class Publicador {
  final RedSimulada red;
  final List<Map<String, dynamic>> apps = [];
  final List<Map<String, dynamic>> senew = [];
  int secuencia = 0;

  Publicador(this.red);

  /// Un índice con `destino` y `datos_bytes` en todas las entradas, como el
  /// del backend nuevo. Sin esto, el de antes.
  bool indiceNuevo = false;

  Map<String, dynamic> publicarApp(String id, Uint8List sen,
      {String nombre = 'Prueba',
      ed.PrivateKey? clave,
      String? destino,
      DatosPublicar? datos,
      Map<String, dynamic> Function(Map<String, dynamic>)? tocarManifiesto,
      Map<String, dynamic> Function(Map<String, dynamic>)? tocarEntrada}) {
    // La entrada sale del manifiesto bueno; lo servido puede venir tocado.
    final m0 =
        manifiestoApp(id, sen, nombre: nombre, destino: destino, datos: datos);
    final m = tocarManifiesto == null ? m0 : tocarManifiesto(m0);
    final b = jsonBytes(m);
    final ver = m['ver_app'];
    red.poner('/v1/apps/$id/versiones/$ver/manifiesto.json', b);
    red.poner(
        '/v1/apps/$id/versiones/$ver/manifiesto.json.sig', firmar(b, clave));
    red.poner('/v1/archivos/${sha256De(sen)}', sen);
    for (final d in datos?.archivos.values ?? const <Uint8List>[]) {
      red.poner('/v1/archivos/${sha256De(d)}', d);
    }
    apps.removeWhere((a) => a['id'] == id);
    var e = entradaApp(m0, sha256De(b), nuevo: indiceNuevo || destino != null);
    if (tocarEntrada != null) e = tocarEntrada(e);
    apps.add(e);
    return e;
  }

  Map<String, dynamic> publicarSenew(int build, String version, Uint8List main,
      {String soc = 'DB2020',
      String modelo = 'w580',
      int blMin = 1,
      int buildMinOrigen = 0,
      String? crc,
      ed.PrivateKey? clave}) {
    final m = manifiestoSenew(build, version, main,
        modelo: modelo,
        soc: soc,
        blMin: blMin,
        buildMinOrigen: buildMinOrigen,
        crc: crc);
    final b = jsonBytes(m);
    red.poner('/v1/senew/releases/$build/manifiesto.json?modelo=$modelo', b);
    red.poner('/v1/senew/releases/$build/manifiesto.json.sig?modelo=$modelo',
        firmar(b, clave));
    red.poner('/v1/archivos/${sha256De(main)}', main);
    final e = entradaSenew(m, sha256De(b));
    senew.add(e);
    return e;
  }

  Uint8List cuerpoIndice(
      {int? sec, DateTime? caduca, DateTime? generado}) {
    final g = generado ?? DateTime.utc(2026, 10, 31);
    return jsonBytes({
      'formato': 1,
      'tipo': 'indice',
      'secuencia': sec ?? secuencia,
      'generado_utc': g.toIso8601String(),
      'caduca_utc':
          (caduca ?? DateTime.utc(2027, 1, 29)).toIso8601String(),
      'apps': apps,
      'senew': senew,
    });
  }

  /// Firma y sirve un índice nuevo.
  void firmarIndice({int? sec, DateTime? caduca, ed.PrivateKey? clave}) {
    secuencia = sec ?? secuencia + 1;
    final b = cuerpoIndice(caduca: caduca);
    red.poner('/v1/indice.json', b);
    red.poner('/v1/indice.json.sig', firmar(b, clave));
  }
}
