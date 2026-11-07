// El gestor de componentes: baja, reanuda, comprueba, instala y borra lo que
// necesitan los servicios locales. La regla que manda aquí:
//
//   NINGÚN BINARIO NI MODELO SE USA SIN HABER CASADO CON LA HUELLA FIJADA EN EL
//   CÓDIGO. El único camino para obtener una ruta ejecutable es [rutaVerificada].
//
// La huella se recalcula al primer uso de cada sesión y, después, en cuanto
// cambian el tamaño o la fecha de cualquier fichero del árbol.
//
// Sin Flutter: lo usan también las pruebas y `bin/servicios_prueba.dart`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'componentes.dart';

enum FaseComponente { ausente, descargando, verificando, instalando, listo, fallo }

enum TipoFallo { red, huella, discoLleno, cancelado, paquete }

class FalloComponente implements Exception {
  final TipoFallo tipo;

  /// Para una persona: no nombra ni rutas ni protocolos.
  final String mensaje;

  /// Para el registro.
  final String? detalle;

  const FalloComponente(this.tipo, this.mensaje, {this.detalle});

  @override
  String toString() => 'FalloComponente($tipo): $mensaje${detalle == null ? '' : ' ($detalle)'}';
}

/// Lo que se le niega a quien pide una ruta sin verificar.
class NoVerificado implements Exception {
  final String ruta;
  final String porque;
  const NoVerificado(this.ruta, this.porque);

  @override
  String toString() => 'NoVerificado($ruta): $porque';
}

class EstadoComponente {
  final String id;
  final FaseComponente fase;

  /// Bytes bajados y totales de todo el componente (fase [FaseComponente.descargando]).
  final int recibidos;
  final int total;
  final FalloComponente? fallo;

  const EstadoComponente(this.id, this.fase, {this.recibidos = 0, this.total = 0, this.fallo});

  bool get ocupado =>
      fase == FaseComponente.descargando || fase == FaseComponente.verificando || fase == FaseComponente.instalando;

  double? get fraccion => total > 0 ? (recibidos / total).clamp(0.0, 1.0) : null;
}

/// Bytes libres donde vive [ruta], o null si no se sabe.
typedef EspacioLibre = Future<int?> Function(String ruta);

/// Escribe un trozo: se inyecta para simular el disco lleno.
typedef EscribirTrozo = Future<void> Function(RandomAccessFile f, List<int> trozo);

/// Los bytes de un asset de SENUS.
typedef LeerEmpotrado = Future<List<int>> Function(String asset);

/// Una tira de letras y cifras que identifica el fichero en el disco sin
/// leerlo: tamaño y fecha. Sirve solo para saber si hay que volver a calcular.
String _firmaStat(FileStat s) => '${s.size}:${s.modified.microsecondsSinceEpoch}';

Future<void> _escribirSinMas(RandomAccessFile f, List<int> trozo) => f.writeFrom(trozo);

/// Bytes libres con `df -k`, que está en macOS y en Linux. En Windows no hay
/// comprobación previa: el error de escritura se ve igual.
Future<int?> espacioLibrePorDf(String ruta) async {
  if (Platform.isWindows) return null;
  try {
    final r = await Process.run('df', ['-k', ruta]);
    if (r.exitCode != 0) return null;
    final lineas = (r.stdout as String).trim().split('\n');
    final col = lineas.last.trim().split(RegExp(r'\s+'));
    return col.length > 3 ? int.parse(col[3]) * 1024 : null;
  } on Object {
    return null;
  }
}

/// sha256 de un fichero, en hexadecimal.
Future<String> huellaFichero(String ruta) async {
  final d = await sha256.bind(File(ruta).openRead()).first;
  return d.toString();
}

/// Huella de un árbol de ficheros: sha256 de las líneas `ruta\0sha256\n`, con
/// las rutas relativas (separador `/`) en orden de bytes. Un enlace simbólico la
/// hace fallar: nada de lo que se instala los trae.
Future<String> huellaArbol(String carpeta) async {
  final lista = <String, File>{};
  await for (final e in Directory(carpeta).list(recursive: true, followLinks: false)) {
    if (e is Link) throw NoVerificado(e.path, 'hay un enlace simbólico');
    if (e is File) lista[p.posix.joinAll(p.split(p.relative(e.path, from: carpeta)))] = e;
  }
  final rutas = lista.keys.toList()..sort((a, b) => _cmpBytes(a, b));
  final b = BytesBuilder(copy: false);
  for (final r in rutas) {
    final h = await huellaFichero(lista[r]!.path);
    b.add(utf8.encode('$r\x00$h\n'));
  }
  return sha256.convert(b.takeBytes()).toString();
}

int _cmpBytes(String a, String b) {
  final x = utf8.encode(a), y = utf8.encode(b);
  for (var i = 0; i < x.length && i < y.length; i++) {
    if (x[i] != y[i]) return x[i] - y[i];
  }
  return x.length - y.length;
}

/// Tamaños y fechas de todo el árbol: barato, para el uso repetido.
Future<String> _firmaArbol(String ruta) async {
  final tipo = await FileSystemEntity.type(ruta, followLinks: false);
  if (tipo == FileSystemEntityType.file) return _firmaStat(await FileStat.stat(ruta));
  if (tipo != FileSystemEntityType.directory) return '';
  final t = <String>[];
  await for (final e in Directory(ruta).list(recursive: true, followLinks: false)) {
    if (e is Link) return 'enlace:${e.path}';
    if (e is File) t.add('${e.path}=${_firmaStat(await e.stat())}');
  }
  t.sort();
  return sha256.convert(utf8.encode(t.join('\n'))).toString();
}

/// Descomprime [zip] en [destino]. Rechaza rutas que se salgan de la carpeta,
/// enlaces simbólicos y lo que no sean ficheros o carpetas. Devuelve las rutas
/// que deben quedar ejecutables.
Future<List<String>> descomprimirZip(String zip, String destino) async {
  final entrada = InputFileStream(zip);
  try {
    final archivo = ZipDecoder().decodeBuffer(entrada);
    final ejecutables = <String>[];
    final raiz = p.normalize(p.absolute(destino));
    for (final f in archivo.files) {
      final nombre = f.name;
      if (nombre.isEmpty) continue;
      if (f.isSymbolicLink) {
        throw FalloComponente(TipoFallo.paquete, 'El paquete descargado no es válido.', detalle: 'enlace: $nombre');
      }
      if (nombre.contains('\\') || p.posix.isAbsolute(nombre) || p.posix.split(nombre).contains('..')) {
        throw FalloComponente(TipoFallo.paquete, 'El paquete descargado no es válido.', detalle: 'ruta: $nombre');
      }
      final ruta = p.normalize(p.join(raiz, nombre));
      if (!p.isWithin(raiz, ruta)) {
        throw FalloComponente(TipoFallo.paquete, 'El paquete descargado no es válido.', detalle: 'fuera: $nombre');
      }
      if (f.isFile) {
        await Directory(p.dirname(ruta)).create(recursive: true);
        final salida = OutputFileStream(ruta);
        f.writeContent(salida);
        await salida.close();
        if ((f.mode & 0x49) != 0) ejecutables.add(ruta);
      } else {
        await Directory(ruta).create(recursive: true);
      }
    }
    return ejecutables;
  } finally {
    await entrada.close();
  }
}

class _Cancelador {
  bool cancelado = false;
  void Function()? alCancelar;

  void cancelar() {
    cancelado = true;
    alCancelar?.call();
  }
}

class GestorComponentes {
  final Directory raiz;
  final List<Componente> catalogo;
  final EspacioLibre espacioLibre;
  final EscribirTrozo escribirTrozo;
  final LeerEmpotrado? leerEmpotrado;

  /// Solo para las pruebas contra un servidor local: fuera de eso, todo https.
  final bool permitirHttp;

  /// Sin recibir nada durante este tiempo, la descarga se da por cortada.
  final Duration plazoInactividad;

  /// Reanudaciones seguidas sin avanzar antes de rendirse.
  final int reintentos;

  final _cambios = StreamController<EstadoComponente>.broadcast();
  final _estado = <String, EstadoComponente>{};
  final _canceladores = <String, _Cancelador>{};

  /// ruta -> firma con la que casó su huella en esta sesión.
  final _verificadas = <String, String>{};

  GestorComponentes({
    required this.raiz,
    required this.catalogo,
    this.espacioLibre = espacioLibrePorDf,
    this.escribirTrozo = _escribirSinMas,
    this.leerEmpotrado,
    this.permitirHttp = false,
    this.plazoInactividad = const Duration(seconds: 60),
    this.reintentos = 3,
  });

  Stream<EstadoComponente> get cambios => _cambios.stream;

  EstadoComponente estado(String id) => _estado[id] ?? EstadoComponente(id, FaseComponente.ausente);

  Componente componente(String id) => catalogo.firstWhere((c) => c.id == id);

  Directory carpeta(Componente c) => Directory(p.join(raiz.path, '${c.id}-${c.version}'));

  String _rutaDe(Componente c, ArchivoComponente a) => p.join(carpeta(c).path, a.destino);

  String _rutaParcial(ArchivoComponente a) => p.join(raiz.path, 'descargas', '${a.sha256}.parcial');

  void _poner(EstadoComponente e) {
    _estado[e.id] = e;
    if (!_cambios.isClosed) _cambios.add(e);
  }

  Future<void> cerrar() async {
    for (final c in _canceladores.values) {
      c.cancelar();
    }
    await _cambios.close();
  }

  // --------------------------------------------------------------- estado

  /// Mira el disco y deja el estado de cada componente. Comprueba las huellas:
  /// lo que no case queda en fallo y no se ejecutará.
  Future<void> comprobar() async {
    for (final c in catalogo) {
      if (estado(c.id).ocupado) continue;
      final bajados = c.archivos.where((a) => a.tipo != TipoArchivo.empotrado);
      final presentes = await Future.wait(bajados.map((a) => _existe(_rutaDe(c, a))));
      if (presentes.every((x) => x)) {
        _poner(EstadoComponente(c.id, FaseComponente.verificando));
        try {
          // Lo que viene dentro de SENUS manda: si cambió con una actualización, o
          // lo tocaron, se copia de nuevo sin molestar a nadie.
          for (final a in c.archivos.where((a) => a.tipo == TipoArchivo.empotrado)) {
            if (!await _instaladoYBien(c, a)) await _copiarEmpotrado(c, a);
          }
          for (final a in c.archivos) {
            await _verificar(a, _rutaDe(c, a));
          }
          _poner(EstadoComponente(c.id, FaseComponente.listo));
        } on NoVerificado catch (e) {
          _poner(EstadoComponente(c.id, FaseComponente.fallo,
              fallo: FalloComponente(TipoFallo.huella, 'Hay ficheros dañados o cambiados. Hay que volver a descargarlos.',
                  detalle: '$e')));
        } on FalloComponente catch (e) {
          _poner(EstadoComponente(c.id, FaseComponente.fallo, fallo: e));
        }
      } else {
        _poner(EstadoComponente(c.id, FaseComponente.ausente));
      }
    }
  }

  Future<bool> _existe(String ruta) async => await FileSystemEntity.type(ruta) != FileSystemEntityType.notFound;

  // ---------------------------------------------------------- verificación

  Future<void> _verificar(ArchivoComponente a, String ruta) async {
    final firma = await _firmaArbol(ruta);
    if (firma.isEmpty) throw NoVerificado(ruta, 'no está');
    if (_verificadas[ruta] == firma) return;
    _verificadas.remove(ruta);
    final esperada = a.tipo == TipoArchivo.zip ? a.arbolSha256! : a.sha256;
    final hallada = await Isolate.run(() => a.tipo == TipoArchivo.zip ? huellaArbol(ruta) : huellaFichero(ruta));
    if (hallada != esperada) throw NoVerificado(ruta, 'la huella no casa');
    // La firma se vuelve a leer: si cambió mientras se calculaba, no vale.
    final despues = await _firmaArbol(ruta);
    if (despues != firma) throw NoVerificado(ruta, 'cambió mientras se comprobaba');
    _verificadas[ruta] = firma;
  }

  /// La ÚNICA forma de obtener la ruta de algo instalado. Lanza [NoVerificado] si
  /// no está o si no casa con la huella fijada en el código.
  Future<String> rutaVerificada(String id, String relativa) async {
    final c = componente(id);
    final primero = relativa.split('/').first;
    final a = c.archivos.firstWhere((x) => x.destino == primero,
        orElse: () => throw NoVerificado(relativa, 'no es de este componente'));
    final ruta = p.joinAll([carpeta(c).path, ...relativa.split('/')]);
    if (!p.isWithin(carpeta(c).path, ruta)) throw NoVerificado(relativa, 'fuera de la carpeta');
    final base = _rutaDe(c, a);
    try {
      await _verificar(a, base);
    } on NoVerificado catch (e) {
      _poner(EstadoComponente(id, FaseComponente.fallo,
          fallo: FalloComponente(TipoFallo.huella, 'Hay ficheros dañados o cambiados. Hay que volver a descargarlos.',
              detalle: '$e')));
      rethrow;
    }
    if (!await _existe(ruta)) throw NoVerificado(relativa, 'no está');
    return ruta;
  }

  // ------------------------------------------------------------ instalar

  void cancelar(String id) => _canceladores[id]?.cancelar();

  /// Baja e instala. El resultado se ve en [estado]: esta función no lanza.
  Future<void> instalar(String id) async {
    if (estado(id).ocupado) return;
    final c = componente(id);
    final cancelador = _canceladores[id] = _Cancelador();
    try {
      await raiz.create(recursive: true);
      await Directory(p.join(raiz.path, 'descargas')).create(recursive: true);
      await carpeta(c).create(recursive: true);
      final pendientes = <ArchivoComponente>[];
      for (final a in c.archivos) {
        if (await _instaladoYBien(c, a)) continue;
        pendientes.add(a);
      }
      await _comprobarEspacio(c, pendientes);
      final total = pendientes.where((a) => a.tipo != TipoArchivo.empotrado).fold<int>(0, (s, a) => s + a.tam);
      var hechos = 0;
      for (final a in pendientes) {
        if (a.tipo == TipoArchivo.empotrado) {
          await _copiarEmpotrado(c, a);
          continue;
        }
        final base = hechos;
        await _descargarConReintentos(a, cancelador, (n) {
          _poner(EstadoComponente(id, FaseComponente.descargando, recibidos: base + n, total: total));
        });
        hechos += a.tam;
        if (cancelador.cancelado) throw const FalloComponente(TipoFallo.cancelado, 'Descarga cancelada.');
        _poner(EstadoComponente(id, FaseComponente.verificando, recibidos: hechos, total: total));
        await _comprobarDescarga(a);
        _poner(EstadoComponente(id, FaseComponente.instalando, recibidos: hechos, total: total));
        await _colocar(c, a);
      }
      _poner(EstadoComponente(id, FaseComponente.listo));
    } on FalloComponente catch (e) {
      _poner(EstadoComponente(id, e.tipo == TipoFallo.cancelado ? FaseComponente.ausente : FaseComponente.fallo,
          fallo: e.tipo == TipoFallo.cancelado ? null : e));
    } on FileSystemException catch (e) {
      _poner(EstadoComponente(id, FaseComponente.fallo, fallo: _falloDisco(e)));
    } finally {
      _canceladores.remove(id);
    }
  }

  Future<bool> _instaladoYBien(Componente c, ArchivoComponente a) async {
    try {
      await _verificar(a, _rutaDe(c, a));
      return true;
    } on NoVerificado {
      return false;
    }
  }

  Future<void> _comprobarEspacio(Componente c, List<ArchivoComponente> pendientes) async {
    var hace = 0;
    for (final a in pendientes) {
      final parcial = File(_rutaParcial(a));
      final ya = await parcial.exists() ? await parcial.length() : 0;
      hace += (a.tipo == TipoArchivo.empotrado ? 0 : a.tam - ya) + a.tamInstalado;
    }
    final libre = await espacioLibre(raiz.path);
    if (libre != null && libre < hace) {
      throw FalloComponente(TipoFallo.discoLleno,
          'No hay espacio: hacen falta ${_mb(hace)} y quedan ${_mb(libre)} libres.');
    }
  }

  static String _mb(int b) => '${(b / 1000000).ceil()} MB';

  FalloComponente _falloDisco(FileSystemException e) {
    final codigo = e.osError?.errorCode;
    // ENOSPC 28, EDQUOT 69 (macOS) o 122 (Linux), ERROR_DISK_FULL 112, ERROR_HANDLE_DISK_FULL 39
    final macosLinux = !Platform.isWindows && (codigo == 28 || codigo == 69 || codigo == 122);
    final windows = Platform.isWindows && (codigo == 112 || codigo == 39);
    if (macosLinux || windows) {
      return FalloComponente(TipoFallo.discoLleno, 'El disco se llenó. Libera espacio y vuelve a intentarlo.', detalle: '$e');
    }
    return FalloComponente(TipoFallo.paquete, 'No se pudo guardar en el disco.', detalle: '$e');
  }

  Future<void> _descargarConReintentos(ArchivoComponente a, _Cancelador c, void Function(int) avance) async {
    var sinAvanzar = 0;
    final parcial = File(_rutaParcial(a));
    while (true) {
      final antes = await parcial.exists() ? await parcial.length() : 0;
      try {
        await _descargar(a, parcial, c, avance);
        return;
      } on _Corte catch (e) {
        if (c.cancelado) throw const FalloComponente(TipoFallo.cancelado, 'Descarga cancelada.');
        final ahora = await parcial.exists() ? await parcial.length() : 0;
        sinAvanzar = ahora > antes ? 0 : sinAvanzar + 1;
        if (sinAvanzar >= reintentos) {
          throw FalloComponente(TipoFallo.red, 'No se pudo descargar. Comprueba la conexión y vuelve a intentarlo.',
              detalle: e.motivo);
        }
      }
    }
  }

  Future<void> _descargar(ArchivoComponente a, File parcial, _Cancelador c, void Function(int) avance) async {
    var ya = await parcial.exists() ? await parcial.length() : 0;
    if (ya > a.tam) {
      await parcial.delete();
      ya = 0;
    }
    if (ya == a.tam) {
      avance(ya);
      return;
    }
    final cliente = HttpClient()
      ..userAgent = 'SENUS'
      ..connectionTimeout = const Duration(seconds: 30);
    c.alCancelar = () => cliente.close(force: true);
    RandomAccessFile? f;
    try {
      var uri = Uri.parse(a.origen);
      for (var saltos = 0;; saltos++) {
        if (saltos > 6) throw const FalloComponente(TipoFallo.red, 'No se pudo descargar.', detalle: 'demasiados saltos');
        if (uri.scheme != 'https' && !(permitirHttp && uri.scheme == 'http')) {
          throw FalloComponente(TipoFallo.red, 'No se pudo descargar.', detalle: 'sin https: $uri');
        }
        final pet = await cliente.getUrl(uri);
        pet.followRedirects = false;
        if (ya > 0) pet.headers.set(HttpHeaders.rangeHeader, 'bytes=$ya-');
        final res = await pet.close();
        if (res.isRedirect || const {301, 302, 303, 307, 308}.contains(res.statusCode)) {
          final destino = res.headers.value(HttpHeaders.locationHeader);
          await res.drain<void>();
          if (destino == null) throw const FalloComponente(TipoFallo.red, 'No se pudo descargar.', detalle: 'salto sin destino');
          uri = uri.resolve(destino);
          continue;
        }
        if (res.statusCode == 416) {
          // Lo que hay ya no vale para el servidor: se empieza de cero.
          await res.drain<void>();
          await parcial.delete();
          ya = 0;
          continue;
        }
        if (res.statusCode == 200) {
          ya = 0; // el servidor no reanuda
        } else if (res.statusCode == 206) {
          final inicio = _inicioRango(res.headers.value(HttpHeaders.contentRangeHeader));
          if (inicio != ya) {
            await res.drain<void>();
            await parcial.delete();
            ya = 0;
            continue;
          }
        } else {
          await res.drain<void>();
          if (res.statusCode >= 500) throw _Corte('HTTP ${res.statusCode}');
          throw FalloComponente(TipoFallo.red, 'No se pudo descargar: el origen ya no lo ofrece.',
              detalle: 'HTTP ${res.statusCode} de $uri');
        }
        f = await parcial.open(mode: ya > 0 ? FileMode.append : FileMode.write);
        var n = ya;
        await for (final trozo in res.timeout(plazoInactividad)) {
          n += trozo.length;
          if (n > a.tam) {
            throw FalloComponente(TipoFallo.huella, 'Lo descargado no es lo esperado.', detalle: 'más de ${a.tam} B');
          }
          await escribirTrozo(f, trozo);
          avance(n);
        }
        if (n < a.tam) throw _Corte('se cortó en $n de ${a.tam} B');
        return;
      }
    } on FalloComponente {
      rethrow;
    } on FileSystemException {
      rethrow;
    } on Object catch (e) {
      // Red caída, plazo agotado, cliente cerrado al cancelar: lo escrito se queda
      // en .parcial y se reanuda.
      throw _Corte('$e');
    } finally {
      c.alCancelar = null;
      await f?.close();
      cliente.close(force: true);
    }
  }

  int? _inicioRango(String? v) {
    final m = RegExp(r'^bytes (\d+)-').firstMatch(v ?? '');
    return m == null ? null : int.parse(m.group(1)!);
  }

  Future<void> _comprobarDescarga(ArchivoComponente a) async {
    final ruta = _rutaParcial(a);
    final h = await Isolate.run(() => huellaFichero(ruta));
    if (h != a.sha256) {
      await File(ruta).delete();
      throw FalloComponente(TipoFallo.huella, 'Lo descargado no es lo esperado. Vuelve a intentarlo.',
          detalle: 'sha256 $h de ${a.origen}');
    }
  }

  Future<void> _colocar(Componente c, ArchivoComponente a) async {
    final ruta = _rutaDe(c, a);
    final parcial = _rutaParcial(a);
    await _quitar(ruta);
    _verificadas.remove(ruta);
    if (a.tipo == TipoArchivo.directo) {
      await File(parcial).rename(ruta);
      return;
    }
    // Se descomprime al lado y solo se pone en su sitio si el árbol casa.
    final nuevo = '$ruta.nuevo';
    await _quitar(nuevo);
    final ejecutables = await Isolate.run(() => descomprimirZip(parcial, nuevo));
    try {
      final h = await Isolate.run(() => huellaArbol(nuevo));
      if (h != a.arbolSha256) {
        throw FalloComponente(TipoFallo.huella, 'Lo descargado no es lo esperado. Vuelve a intentarlo.',
            detalle: 'árbol $h de ${a.origen}');
      }
    } on Object {
      await _quitar(nuevo);
      await File(parcial).delete();
      rethrow;
    }
    await _hacerEjecutables(ejecutables);
    await Directory(nuevo).rename(ruta);
    await File(parcial).delete();
  }

  Future<void> _copiarEmpotrado(Componente c, ArchivoComponente a) async {
    final leer = leerEmpotrado;
    if (leer == null) throw const FalloComponente(TipoFallo.paquete, 'Falta un fichero de SENUS.', detalle: 'sin leerEmpotrado');
    final bytes = await leer(a.origen);
    final h = sha256.convert(bytes).toString();
    if (h != a.sha256) {
      throw FalloComponente(TipoFallo.huella, 'Un fichero de SENUS está dañado. Vuelve a instalar SENUS.', detalle: 'asset $h');
    }
    final ruta = _rutaDe(c, a);
    await _quitar(ruta);
    _verificadas.remove(ruta);
    await File(ruta).writeAsBytes(bytes, flush: true);
    await _hacerEjecutables([ruta]);
  }

  Future<void> _hacerEjecutables(List<String> rutas) async {
    if (Platform.isWindows || rutas.isEmpty) return;
    for (var i = 0; i < rutas.length; i += 50) {
      final r = await Process.run('chmod', ['755', ...rutas.skip(i).take(50)]);
      if (r.exitCode != 0) {
        throw FalloComponente(TipoFallo.paquete, 'No se pudo preparar la instalación.', detalle: '${r.stderr}');
      }
    }
  }

  Future<void> _quitar(String ruta) async {
    final t = await FileSystemEntity.type(ruta, followLinks: false);
    if (t == FileSystemEntityType.notFound) return;
    await (t == FileSystemEntityType.directory ? Directory(ruta) : File(ruta)).delete(recursive: true);
  }

  /// Quita el componente y sus descargas a medias.
  Future<void> borrar(String id) async {
    cancelar(id);
    final c = componente(id);
    for (final a in c.archivos) {
      _verificadas.remove(_rutaDe(c, a));
      await _quitar(_rutaParcial(a));
    }
    await _quitar(carpeta(c).path);
    _poner(EstadoComponente(id, FaseComponente.ausente));
  }

  /// Bytes ya bajados de una descarga a medias: para enseñar «seguir».
  Future<int> bytesParciales(String id) async {
    var n = 0;
    for (final a in componente(id).archivos) {
      final f = File(_rutaParcial(a));
      if (await f.exists()) n += await f.length();
    }
    return n;
  }
}

class _Corte implements Exception {
  final String motivo;
  _Corte(this.motivo);

  @override
  String toString() => motivo;
}

/// Para quien necesite comparar bytes en las pruebas.
Uint8List aBytes(List<int> b) => b is Uint8List ? b : Uint8List.fromList(b);
