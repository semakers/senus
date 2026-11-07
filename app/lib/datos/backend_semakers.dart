// Cliente del backend de Semakers: lee, verifica y guarda en disco. Sin red,
// sirve lo último que verificó. Toda la verificación pasa ANTES de tocar el
// teléfono; lo que llega del servidor no se cree hasta entonces.
//
// Caché, en la carpeta que le den:
//   indice.json, indice.json.sig    el último índice aceptado, bytes exactos
//   estado.json                     la secuencia más alta vista
//   manifiestos/<nombre>.json(.sig)
//   archivos/<sha256>               binarios verificados
//
// Un fichero se escribe a un temporal y se renombra: un corte no deja medio
// fichero con el nombre bueno. La caché es solo una ayuda: si no se puede leer
// o escribir, lo ya verificado se usa igual y no se guarda.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'indice_semakers.dart';

int _temporales = 0;

/// Escribe a un temporal único y renombra. Único por escritura, no por proceso:
/// dos pantallas pueden guardar el mismo fichero a la vez.
Future<void> escribirAtomico(File f, List<int> bytes) async {
  await f.parent.create(recursive: true);
  final t = File('${f.path}.tmp$pid.${_temporales++}');
  try {
    await t.writeAsBytes(bytes, flush: true);
    await t.rename(f.path);
  } catch (_) {
    try {
      await t.delete();
    } on FileSystemException {
      // Ya no estaba.
    }
    rethrow;
  }
}

/// No se pudo hablar con el servidor. Es lo que activa el modo sin red.
class SinRed implements Exception {
  final String detalle;
  const SinRed(this.detalle);
  @override
  String toString() => detalle;
}

class RespuestaRed {
  final int estado;
  final Uint8List cuerpo;
  const RespuestaRed(this.estado, this.cuerpo);
}

/// El GET, aparte para poder simularlo.
abstract class RedSemakers {
  /// Lanza [SinRed] si no hay conexión.
  Future<RespuestaRed> get(String ruta, {void Function(int, int)? alProgreso});
}

class RedHttp implements RedSemakers {
  final String base;
  final Duration plazoConexion;
  final Duration plazoRespuesta;

  /// Ni un binario llega a esto: un main son 2,25 MiB y un .sen hasta 16 MiB.
  static const int tope = 64 << 20;

  RedHttp(
    this.base, {
    this.plazoConexion = const Duration(seconds: 5),
    this.plazoRespuesta = const Duration(seconds: 60),
  });

  @override
  Future<RespuestaRed> get(String ruta,
      {void Function(int, int)? alProgreso}) async {
    final cli = HttpClient()..connectionTimeout = plazoConexion;
    try {
      final q = await cli.getUrl(Uri.parse('$base$ruta'));
      final r = await q.close().timeout(plazoRespuesta);
      final b = BytesBuilder(copy: false);
      await for (final trozo in r.timeout(plazoRespuesta)) {
        b.add(trozo);
        if (b.length > tope) {
          throw const SinRed('El servidor manda más de lo que cabe esperar.');
        }
        alProgreso?.call(b.length, r.contentLength);
      }
      return RespuestaRed(r.statusCode, b.toBytes());
    } on SocketException catch (e) {
      throw SinRed('Sin conexión con el servidor: ${e.message}');
    } on HttpException catch (e) {
      throw SinRed('La conexión con el servidor falló: ${e.message}');
    } on TimeoutException {
      throw const SinRed('El servidor no contestó a tiempo.');
    } finally {
      cli.close(force: true);
    }
  }
}

/// Lo que devuelve [ClienteBackend.indice].
class IndiceServido {
  final IndiceSemakers indice;

  /// true si viene de la caché: no se pudo hablar con el servidor o lo que dio
  /// no pasó la verificación.
  final bool sinRed;

  /// Si el servidor contestó algo inaceptable, por qué. El índice que se
  /// devuelve es entonces el de la caché.
  final ErrorVerificacion? rechazo;

  const IndiceServido(this.indice, {this.sinRed = false, this.rechazo});
}

class AppDescargada {
  final AppIndice app;
  final Uint8List bytes;
  final ManifiestoVerificado manifiesto;

  /// Los datos que lleva, si es un juego que los trae. Ya cotejados con el
  /// índice (`datos_bytes`); los ficheros se bajan con [ClienteBackend.descargarDato].
  final DatosJuego? datos;
  const AppDescargada(this.app, this.bytes, this.manifiesto, [this.datos]);
}

class ReleaseDescargada {
  final ReleaseIndice release;
  final Uint8List main;
  final ManifiestoVerificado manifiesto;
  const ReleaseDescargada(this.release, this.main, this.manifiesto);

  String get notas => manifiesto.json['notas'] as String? ?? release.notas;
}

class ClienteBackend {
  final RedSemakers red;
  final Directory cache;
  final List<Uint8List> claves;
  final DateTime Function() ahora;

  ClienteBackend({
    required this.red,
    required this.cache,
    required this.claves,
    DateTime Function()? ahora,
  }) : ahora = ahora ?? DateTime.now;

  File get _ficheroIndice => File(p.join(cache.path, 'indice.json'));
  File get _ficheroFirma => File(p.join(cache.path, 'indice.json.sig'));
  File get _ficheroEstado => File(p.join(cache.path, 'estado.json'));
  Directory get _dirManifiestos =>
      Directory(p.join(cache.path, 'manifiestos'));
  Directory get _dirArchivos => Directory(p.join(cache.path, 'archivos'));

  /// Guarda en la caché. Si no se puede, lo verificado sigue valiendo en memoria.
  Future<void> _escribir(File f, List<int> bytes) async {
    try {
      await escribirAtomico(f, bytes);
    } on FileSystemException {
      // Sin caché, la próxima vez se baja otra vez.
    }
  }

  Future<(int, String?)> _estado() async {
    try {
      final j = jsonDecode(await _ficheroEstado.readAsString())
          as Map<String, dynamic>;
      return (j['secuencia'] as int? ?? 0, j['sha256'] as String?);
    } catch (_) {
      return (0, null);
    }
  }

  /// El índice de la caché, reverificado entero: firma y caducidad se miran
  /// cada vez. Sin él, null. Caducado, lanza.
  Future<IndiceSemakers?> _indiceDeCache(int vista, String? shaVisto) async {
    final Uint8List bytes, firma;
    try {
      bytes = await _ficheroIndice.readAsBytes();
      firma = await _ficheroFirma.readAsBytes();
    } on FileSystemException {
      return null;
    }
    return verificarIndice(
      bytes: bytes,
      firma: firma,
      claves: claves,
      ahora: ahora(),
      secuenciaVista: vista,
      shaVisto: shaVisto,
    );
  }

  /// El índice vigente. Con red, lo trae y lo verifica; sin ella, o si lo que
  /// llega no pasa, se queda con lo último verificado. Lanza si no hay nada
  /// aceptable que enseñar.
  Future<IndiceServido> indice() async {
    final (vista, shaVisto) = await _estado();
    Uint8List bytes, firma;
    try {
      final r = await red.get('/v1/indice.json');
      final s = await red.get('/v1/indice.json.sig');
      if (r.estado != 200 || s.estado != 200) {
        throw SinRed('El servidor contestó ${r.estado}/${s.estado}.');
      }
      bytes = r.cuerpo;
      firma = s.cuerpo;
    } on SinRed {
      final c = await _indiceDeCache(vista, shaVisto);
      if (c == null) rethrow;
      return IndiceServido(c, sinRed: true);
    }
    final IndiceSemakers nuevo;
    try {
      nuevo = verificarIndice(
        bytes: bytes,
        firma: firma,
        claves: claves,
        ahora: ahora(),
        secuenciaVista: vista,
        shaVisto: shaVisto,
      );
    } on ErrorVerificacion catch (e) {
      final c = await _indiceDeCache(vista, shaVisto);
      if (c == null) rethrow;
      return IndiceServido(c, sinRed: true, rechazo: e);
    }
    await _escribir(_ficheroIndice, bytes);
    await _escribir(_ficheroFirma, firma);
    await _escribir(
        _ficheroEstado,
        utf8.encode(jsonEncode(
            {'secuencia': nuevo.secuencia, 'sha256': sha256De(bytes)})));
    return IndiceServido(nuevo);
  }

  Future<(Uint8List, Uint8List)?> _manifiestoDeCache(String nombre) async {
    final m = File(p.join(_dirManifiestos.path, '$nombre.json'));
    final s = File(p.join(_dirManifiestos.path, '$nombre.json.sig'));
    try {
      return (await m.readAsBytes(), await s.readAsBytes());
    } on FileSystemException {
      return null;
    }
  }

  Future<Uint8List> _bajar(String ruta) async {
    final r = await red.get(ruta);
    if (r.estado != 200) {
      throw SinRed('El servidor contestó ${r.estado} a $ruta.');
    }
    return r.cuerpo;
  }

  /// Trae un manifiesto de la caché si la verificación lo acepta y, si no, de
  /// la red. Lo que se guarda ya pasó por `verificar`.
  Future<ManifiestoVerificado> _manifiesto(
    String nombre,
    String ruta,
    ManifiestoVerificado Function(Uint8List, Uint8List) verificar, {
    String consulta = '',
  }) async {
    final c = await _manifiestoDeCache(nombre);
    if (c != null) {
      try {
        return verificar(c.$1, c.$2);
      } on ErrorVerificacion {
        // Copia de la caché que ya no vale: se trae otra.
      }
    }
    final bytes = await _bajar('$ruta$consulta');
    final firma = await _bajar('$ruta.sig$consulta');
    final v = verificar(bytes, firma);
    await _escribir(
        File(p.join(_dirManifiestos.path, '$nombre.json')), bytes);
    await _escribir(
        File(p.join(_dirManifiestos.path, '$nombre.json.sig')), firma);
    return v;
  }

  /// Un binario por su sha256. La caché se relee y se comprueba siempre: un
  /// fichero tocado en disco no pasa, se borra y se baja otra vez.
  Future<Uint8List> _archivo(String sha256,
      {void Function(int, int)? alProgreso}) async {
    final f = File(p.join(_dirArchivos.path, sha256));
    try {
      final b = await f.readAsBytes();
      if (sha256De(b) == sha256) return b;
      await f.delete();
    } on FileSystemException {
      // No está o no se puede leer: se baja.
    }
    final r = await red.get('/v1/archivos/$sha256', alProgreso: alProgreso);
    if (r.estado != 200) {
      throw SinRed('El servidor contestó ${r.estado} al pedir el archivo.');
    }
    if (sha256De(r.cuerpo) != sha256) {
      throw const ErrorVerificacion(MotivoRechazo.shaDistinto,
          'Lo descargado no tiene el sha256 esperado.');
    }
    await _escribir(f, r.cuerpo);
    return r.cuerpo;
  }

  /// El manifiesto firmado de una app, verificado contra su entrada del índice.
  Future<ManifiestoVerificado> manifiestoApp(AppIndice a) => _manifiesto(
        'app_${a.id}_${a.verApp}',
        '/v1/apps/${a.id}/versiones/${a.verApp}/manifiesto.json',
        (b, s) => verificarManifiestoApp(b, s, claves, a),
      );

  /// Los datos de un juego según su manifiesto firmado; null si no lleva.
  Future<DatosJuego?> datosDe(AppIndice a) async =>
      a.esJuego ? datosDeManifiesto((await manifiestoApp(a)).json) : null;

  /// Descarga una app y la deja verificada: manifiesto firmado, sha256 y las
  /// CRC del `.sen`. Si algo falla lanza y no se toca el teléfono.
  Future<AppDescargada> descargarApp(AppIndice a,
      {void Function(int, int)? alProgreso}) async {
    final m = await manifiestoApp(a);
    final bytes = await _archivo(a.sha256, alProgreso: alProgreso);
    verificarSen(bytes, a);
    return AppDescargada(a, bytes, m, a.esJuego ? datosDeManifiesto(m.json) : null);
  }

  /// Un fichero de datos de un juego, comprobado contra su manifiesto: sha256
  /// y tamaño. Lo que no cuadra no sale de aquí.
  Future<Uint8List> descargarDato(ArchivoDato d,
      {void Function(int, int)? alProgreso}) async {
    final b = await _archivo(d.sha256, alProgreso: alProgreso);
    if (b.length != d.bytes) {
      throw ErrorVerificacion(MotivoRechazo.tamanoDistinto,
          '${d.nombre}: ${b.length} B, el manifiesto dice ${d.bytes}.');
    }
    return b;
  }

  /// Descarga una release ENTERA a la caché y la verifica. Hasta que esto
  /// vuelve no empieza el flujo: si falla la red a mitad, no ha pasado nada.
  Future<ReleaseDescargada> descargarRelease(ReleaseIndice r,
      {void Function(int, int)? alProgreso}) async {
    final m = await _manifiesto(
      'senew_${r.modelo}_${r.build}',
      '/v1/senew/releases/${r.build}/manifiesto.json',
      (b, s) => verificarManifiestoSenew(b, s, claves, r),
      consulta: '?modelo=${r.modelo}',
    );
    final bytes = await _archivo(r.mainSha256, alProgreso: alProgreso);
    verificarMain(bytes, r, m.json);
    return ReleaseDescargada(r, bytes, m);
  }
}
