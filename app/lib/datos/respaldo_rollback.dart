// Respaldo de rollback — la red de seguridad SEMC original de cada aparato.
//
// REGLA INVIOLABLE (senus-regla-rollback.md): SENUS no instala senew en un
// aparato sin haber guardado antes su respaldo de fábrica (GDFS por duplicado
// + read-flash completo + metadatos). Al terminar la instalación el usuario
// ve claramente dónde queda guardado y cómo volver atrás.
//
// Este fichero: modelo de datos + almacén en disco (~/senus/respaldos/) +
// ejecutor de seftool como subproceso (con stdout/stderr capturados). Para
// las pruebas en Mac contra bridge_mock no hay aparato, así que el ejecutor
// cae en «modo simulado»: produce ficheros rellenables y una barra de progreso
// creíble para validar la UI sin tocar hardware.
//
// Carpeta por aparato:
//   ~/senus/respaldos/<MODELO>_<serial>_<YYYY-MM-DD>/
//     gdfs_A.bin, gdfs_A.sha256
//     gdfs_B.bin, gdfs_B.sha256
//     flash_full.bin, flash_full.sha256
//     identify.txt
//     metadatos.json
//
// Índice global: ~/senus/respaldos/indice.json (lista de respaldos).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'seftool.dart';
import 'telefono.dart';

/// Un respaldo de rollback existente en el disco.
class RespaldoRollback {
  final String carpeta;            // ruta absoluta
  final String modelo;             // "W580"
  final String serie;              // "W580S10000001" o el que dé identify
  final DateTime fecha;
  final String? cid;
  final String? color;
  final String? firmwareOriginal;  // p. ej. "R8BE001"
  final String shaFlash;           // sha256 del flash_full.bin
  final int bytesFlash;
  final bool usado;                // si ya se usó para volver atrás alguna vez
  /// true si el respaldo lo produjo el modo SIMULADO (sin aparato). Un
  /// respaldo simulado NO sirve para volver atrás de verdad; la UI lo marca
  /// y la restauración real se niega a usarlo.
  final bool simulado;
  final String? cxcArticulo;       // "CXC1123362"
  final String? paqueteAnycid;     // "R8BE001_CXC1123362_GENERIC_LA"
  /// sha256 del gdfs_A.bin / gdfs_B.bin tal como salieron del aparato.
  /// Null para respaldos antiguos que no los guardaban; la restauración
  /// hace fallback a `gdfs_A.sha256` / `gdfs_B.sha256` del disco (que
  /// EjecutorRespaldo escribe siempre).
  final String? shaGdfsA;
  final String? shaGdfsB;

  const RespaldoRollback({
    required this.carpeta,
    required this.modelo,
    required this.serie,
    required this.fecha,
    this.cid,
    this.color,
    this.firmwareOriginal,
    required this.shaFlash,
    required this.bytesFlash,
    this.usado = false,
    this.simulado = false,
    this.cxcArticulo,
    this.paqueteAnycid,
    this.shaGdfsA,
    this.shaGdfsB,
  });

  String get rutaMetadatos => p.join(carpeta, 'metadatos.json');
  String get rutaFlash => p.join(carpeta, 'flash_full.bin');
  String get rutaGdfsA => p.join(carpeta, 'gdfs_A.bin');
  String get rutaGdfsB => p.join(carpeta, 'gdfs_B.bin');
  String get rutaShaGdfsA => p.join(carpeta, 'gdfs_A.sha256');
  String get rutaShaGdfsB => p.join(carpeta, 'gdfs_B.sha256');

  /// sha256 del gdfs_A: primero el campo del modelo; si falta, el fichero
  /// `gdfs_A.sha256` del disco (que EjecutorRespaldo deja al lado del bin).
  /// Devuelve null si tampoco está en disco o viene malformado.
  Future<String?> shaGdfsAResuelto() => _leerShaDe(shaGdfsA, rutaShaGdfsA);
  Future<String?> shaGdfsBResuelto() => _leerShaDe(shaGdfsB, rutaShaGdfsB);

  static Future<String?> _leerShaDe(String? delModelo, String ruta) async {
    if (delModelo != null && delModelo.isNotEmpty) return delModelo;
    final f = File(ruta);
    if (!await f.exists()) return null;
    // Formato: "<sha256>  <nombre>\n".
    final txt = (await f.readAsString()).trim();
    if (txt.isEmpty) return null;
    final sp = txt.split(RegExp(r'\s+'));
    return sp.first.length == 64 ? sp.first : null;
  }

  Map<String, dynamic> aJson() => {
        'carpeta': carpeta,
        'modelo': modelo,
        'serie': serie,
        'fecha_utc': fecha.toUtc().toIso8601String(),
        'cid': cid,
        'color': color,
        'firmware_original': firmwareOriginal,
        'sha_flash': shaFlash,
        'bytes_flash': bytesFlash,
        'usado': usado,
        'simulado': simulado,
        'cxc_articulo': cxcArticulo,
        'paquete_anycid': paqueteAnycid,
        'sha_gdfs_a': shaGdfsA,
        'sha_gdfs_b': shaGdfsB,
      };

  static RespaldoRollback deJson(Map<String, dynamic> j) => RespaldoRollback(
        carpeta: j['carpeta'] as String,
        modelo: j['modelo'] as String? ?? '',
        serie: j['serie'] as String? ?? '',
        fecha: DateTime.tryParse(j['fecha_utc'] as String? ?? '')?.toLocal() ??
            DateTime(2000),
        cid: j['cid'] as String?,
        color: j['color'] as String?,
        firmwareOriginal: j['firmware_original'] as String?,
        shaFlash: j['sha_flash'] as String? ?? '',
        bytesFlash: j['bytes_flash'] as int? ?? 0,
        usado: j['usado'] as bool? ?? false,
        simulado: j['simulado'] as bool? ?? false,
        cxcArticulo: j['cxc_articulo'] as String?,
        paqueteAnycid: j['paquete_anycid'] as String?,
        shaGdfsA: j['sha_gdfs_a'] as String?,
        shaGdfsB: j['sha_gdfs_b'] as String?,
      );

  RespaldoRollback copiarConUsado(bool v) => RespaldoRollback(
        carpeta: carpeta,
        modelo: modelo,
        serie: serie,
        fecha: fecha,
        cid: cid,
        color: color,
        firmwareOriginal: firmwareOriginal,
        shaFlash: shaFlash,
        bytesFlash: bytesFlash,
        usado: v,
        simulado: simulado,
        cxcArticulo: cxcArticulo,
        paqueteAnycid: paqueteAnycid,
        shaGdfsA: shaGdfsA,
        shaGdfsB: shaGdfsB,
      );
}

/// Almacén en disco. Expone list/buscar/guardar/marcarUsado + mantiene el
/// índice JSON a la par.
class AlmacenRespaldos {
  /// Ruta base. En Mac/Linux: `$HOME/senus/respaldos`.
  final String rutaBase;

  AlmacenRespaldos._(this.rutaBase);

  factory AlmacenRespaldos.predeterminado() {
    final hogar =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
    return AlmacenRespaldos._(p.join(hogar, 'senus', 'respaldos'));
  }

  factory AlmacenRespaldos.en(String ruta) => AlmacenRespaldos._(ruta);

  Directory get _dir => Directory(rutaBase);
  File get _indice => File(p.join(rutaBase, 'indice.json'));

  String get rutaIndice => _indice.path;

  Future<void> _asegurar() async {
    if (!await _dir.exists()) await _dir.create(recursive: true);
  }

  /// Lee el índice JSON. Si no existe o está corrupto, lo reconstruye
  /// escaneando subcarpetas con metadatos.json.
  Future<List<RespaldoRollback>> listar() async {
    await _asegurar();
    if (await _indice.exists()) {
      try {
        final j = jsonDecode(await _indice.readAsString()) as Map<String, dynamic>;
        final arr = (j['respaldos'] as List? ?? const []);
        return arr
            .whereType<Map<String, dynamic>>()
            .map(RespaldoRollback.deJson)
            .toList();
      } catch (_) {
        // Caerá en reconstrucción.
      }
    }
    final out = <RespaldoRollback>[];
    if (await _dir.exists()) {
      await for (final entry in _dir.list()) {
        if (entry is! Directory) continue;
        final meta = File(p.join(entry.path, 'metadatos.json'));
        if (!await meta.exists()) continue;
        try {
          final j = jsonDecode(await meta.readAsString()) as Map<String, dynamic>;
          j['carpeta'] = entry.path;
          out.add(RespaldoRollback.deJson(j));
        } catch (_) {}
      }
    }
    await _reescribirIndice(out);
    return out;
  }

  Future<RespaldoRollback?> buscar(String modelo, String serie) async {
    final todos = await listar();
    for (final r in todos) {
      if (r.modelo == modelo && r.serie == serie) return r;
    }
    return null;
  }

  Future<void> _reescribirIndice(List<RespaldoRollback> lista) async {
    await _asegurar();
    final j = {
      'formato_senus': 1,
      'actualizado_utc': DateTime.now().toUtc().toIso8601String(),
      'respaldos': [for (final r in lista) r.aJson()],
    };
    await _indice.writeAsString(const JsonEncoder.withIndent('  ').convert(j));
  }

  /// Reserva la carpeta del nuevo respaldo (vacía) y devuelve su ruta.
  ///
  /// Nunca devuelve una carpeta que ya tenga un respaldo REGISTRADO: rehacer
  /// el respaldo el mismo día (o uno que falla a medias, con un volcado
  /// rechazado) pisaría el `flash_full.bin` y los GDFS del bueno mientras el
  /// índice sigue diciendo su SHA-256, y la restauración lo rechazaría. En ese
  /// caso se abre `<nombre>-2`, `-3`… Una carpeta sin `metadatos.json` (un
  /// intento anterior que no llegó a registrarse) sí se reutiliza.
  Future<Directory> abrirCarpeta(String modelo, String serie) async {
    await _asegurar();
    final hoy = DateTime.now().toLocal().toIso8601String().substring(0, 10);
    final nombre = '${modelo}_${_safe(serie)}_$hoy';
    var d = Directory(p.join(rutaBase, nombre));
    final registradas = {for (final r in await listar()) r.carpeta};
    for (var n = 2;
        await File(p.join(d.path, 'metadatos.json')).exists() ||
            registradas.contains(d.path);
        n++) {
      d = Directory(p.join(rutaBase, '$nombre-$n'));
    }
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// Da de alta un respaldo recién creado (metadatos.json + índice).
  Future<RespaldoRollback> registrar(RespaldoRollback r) async {
    await File(r.rutaMetadatos)
        .writeAsString(const JsonEncoder.withIndent('  ').convert(r.aJson()));
    final todos = await listar();
    todos.removeWhere((x) =>
        x.modelo == r.modelo && x.serie == r.serie && x.carpeta == r.carpeta);
    todos.add(r);
    await _reescribirIndice(todos);
    return r;
  }

  Future<RespaldoRollback> marcarUsado(RespaldoRollback r) async {
    final nuevo = r.copiarConUsado(true);
    await File(nuevo.rutaMetadatos)
        .writeAsString(const JsonEncoder.withIndent('  ').convert(nuevo.aJson()));
    final todos = await listar();
    final i = todos.indexWhere((x) => x.carpeta == r.carpeta);
    if (i >= 0) {
      todos[i] = nuevo;
    } else {
      todos.add(nuevo);
    }
    await _reescribirIndice(todos);
    return nuevo;
  }

  String _safe(String s) =>
      s.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_').isEmpty
          ? 'sin-serie'
          : s.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
}

/// Un paso del flujo de respaldo que la pantalla va a mostrar.
enum EstadoPaso { pendiente, corriendo, hecho, fallido }

/// Un evento que sale del ejecutor: una línea de log o un porcentaje.
class EventoRespaldo {
  final String? logLinea;      // texto para el panel de log
  final double? progreso;      // 0..1 (sólo para read-flash)
  final String? paso;          // "identificar", "respaldo", "espejo", "flash"
  final bool? pasoHecho;
  final String? error;
  /// Pausa cooperativa: el ejecutor va a esperar `await pausa.future` antes
  /// de seguir. La UI, al verlo, enseña un diálogo con instrucciones y
  /// completa con true (continuar) o false (cancelar). Se usa en el camino
  /// anycid del DB2020: hace falta que el humano abra Juegos → executer en
  /// el teléfono entre `upload-anycid` y `flash-anycid`, y nadie lo puede
  /// automatizar sin pantalla.
  final Completer<bool>? pausa;
  final String? pausaTitulo;
  final String? pausaDetalle;

  /// La persona canceló una pausa y el ejecutor se paró ahí. NO es un error
  /// (no hay `error`), pero tampoco un éxito: la pantalla tiene que decir que
  /// se canceló, no «restaurado» ni «instalación completada».
  final bool cancelado;

  /// La operación terminó bien pero a medias (p. ej. se restauró SOLO el
  /// GDFS y el main no): la pantalla no puede decir «firmware original
  /// restaurado».
  final bool parcial;
  const EventoRespaldo({
    this.logLinea,
    this.progreso,
    this.paso,
    this.pasoHecho,
    this.error,
    this.pausa,
    this.pausaTitulo,
    this.pausaDetalle,
    this.cancelado = false,
    this.parcial = false,
  });
}

/// Datos leídos por `seftool identify`.
class SalidaIdentify {
  final String modelo;
  final String serie;   // el IMEI: `identify` no tiene línea «Serial:»
  final String cid;
  final String color;
  final String firmwareOriginal;
  /// stdout tal cual, para dejarlo en identify.txt sin reescribirlo.
  final String? crudo;
  /// Paquete anycid que seftool resolvió solo a partir del CXC de la GDFS
  /// (p. ej. `R8BE001_CXC1123362_GENERIC_LA`). Null si no lo imprimió.
  final String? paqueteAnycid;
  final String? cxcArticulo;
  const SalidaIdentify({
    required this.modelo,
    required this.serie,
    required this.cid,
    required this.color,
    required this.firmwareOriginal,
    this.crudo,
    this.paqueteAnycid,
    this.cxcArticulo,
  });
}

// ---------------------------------------------------------------------------
// Pausas y pasos compartidos por el respaldo y la restauración.
//
// Cada orden de seftool termina apagando el teléfono (o dejando el CS loader
// en RAM): para la siguiente hay que volver a entrar en modo C. Por eso el
// ejecutor PAUSA entre sesiones y le explica a la persona qué hacer. El título
// de toda pausa de reconexión lleva «modo C» (las pruebas lo exigen).
// ---------------------------------------------------------------------------

/// Cuántas veces se intenta el paso del exploit (abrir «executer» + la orden
/// que lo necesita) antes de rendirse. Cada intento es una pausa.
const int maxIntentosExecuter = 3;

const String tituloReconectar = 'Reconecta el teléfono en modo C';

/// Decisión de una pausa. Un generador auxiliar la rellena y quien lo llama
/// la lee después de `yield*`: así las pausas viven en una función aparte.
class DecisionPausa {
  bool seguir = false;
}

/// Emite una pausa y espera a que la persona la resuelva (Continuar/Cancelar).
Stream<EventoRespaldo> pausar(DecisionPausa d,
    {required String titulo, required String detalle}) async* {
  final c = Completer<bool>();
  yield EventoRespaldo(pausa: c, pausaTitulo: titulo, pausaDetalle: detalle);
  d.seguir = await c.future;
}

/// Cuerpo de una pausa «reconecta en modo C». [cierre] dice para qué es
/// (completa «Pulsa Continuar …»); [alCancelar], qué pasa si se cancela.
String detalleReconectar({
  required String cierre,
  required String alCancelar,
  String? aviso,
}) =>
    '${aviso == null ? '' : '$aviso\n\n'}'
    'seftool cierra el puerto al terminar cada orden (equivale a «Shutdown '
    'phone»): el teléfono está APAGADO.\n\n'
    '1. Mantén la tecla C pulsada mientras enchufas el cable DCU-60.\n'
    '2. Espera a que el aparato aparezca como SEMC USB Flash (0fce:adde).\n'
    '3. Pulsa Continuar $cierre.\n\n'
    'Si cancelas: $alCancelar';

/// Título de la pausa del exploit; con intentos, «(intento n/N)».
String tituloExecuter({int? intento}) => intento == null
    ? 'Abre «executer» en el teléfono'
    : 'Abre «executer» en el teléfono (intento $intento/$maxIntentosExecuter)';

/// Cuerpo de la pausa del exploit: los 7 pasos manuales (cerrojo físico).
String detalleExecuter({required String alCancelar, String? fallo}) =>
    '${fallo == null ? '' : 'El intento anterior falló: $fallo\n\n'}'
    'Para que seftool pueda saltarse la firma, el MIDlet «executer» tiene que '
    'estar corriendo en el teléfono. Haz esto en orden:\n\n'
    '1. Desconecta el cable DCU-60.\n'
    '2. Pon la SIM en el teléfono.\n'
    '3. Enciende el teléfono normalmente.\n'
    '4. Menú → Juegos → abre «executer».\n'
    '5. Cuando el MIDlet esté activo (ventana del exploit cargada), apaga el '
    'teléfono.\n'
    '6. Mantén la tecla C pulsada mientras vuelves a conectar el cable para '
    'que entre en modo servicio.\n'
    '7. Pulsa Continuar aquí.\n\n'
    'Si cancelas: $alCancelar';

/// `upload-anycid` guiado: sube el paquete de plataforma y el del firmware al
/// sistema de archivos del teléfono (ESCRIBE 3 ficheros; no toca la NOR ni el
/// GDFS). Lanza [SeftoolError] si el CS loader no arrancó sus servicios (el
/// «error:29» que la escena documenta para CID 53). No reenvía el progreso:
/// la barra de la pantalla es la de la lectura de la NOR.
Stream<EventoRespaldo> subirAnycidGuiado(Seftool sef) async* {
  var arrancoFsx = false;
  var fallo = false;
  await for (final l in sef.subirAnycid()) {
    yield EventoRespaldo(logLinea: l.texto);
    final t = l.texto;
    if (t.contains('Starting FSX server') && t.contains('started')) {
      arrancoFsx = true;
    }
    if (RegExp(r'error:?\s*29').hasMatch(t) ||
        t.contains('refused to start') ||
        (t.contains('Starting FSX server') && t.contains('failed'))) {
      fallo = true;
    }
  }
  if (fallo || (!arrancoFsx && !sef.ensayo)) {
    throw SeftoolError(
      'El CS loader no arrancó sus servicios al subir el paquete anycid.',
      remedio: 'No se escribió nada en la NOR. Hay que MEDIRLO, no reintentar '
          'a ciegas (seftool-senew/docs/CID53_RUTA.md §4).',
    );
  }
}

/// Lo que se midió en un volcado de la NOR: el motivo por el que NO sirve
/// (null = creíble) y su SHA-1 (null si ni se llegó a leer entero).
typedef AnalisisNor = ({String? motivo, String? sha1});

/// ¿El volcado de la NOR es creíble como respaldo? UNA pasada por el fichero
/// (64 MiB se leen una sola vez):
///
///  - el tamaño exacto;
///  - que los 256 KiB de `0x44000000` (el arranque) y los de `0x44140000` (el
///    inicio del main) no sean un solo byte repetido: un 0xFF o 0x00 enteros
///    quieren decir que la lectura no devolvió flash real;
///  - que la NOR no sea la misma pieza repetida: un loader que ignorase la
///    dirección devolvería el mismo trozo una y otra vez, y eso no lo ve el
///    punto anterior si el trozo tiene datos. El primer MiB tiene que ser
///    distinto del MiB 16, 32 y 48 (solo con la NOR entera);
///  - si se conoce el ID del firmware (`MAPP CXC article`), que el volcado lo
///    lleve: el main de fábrica contiene «prg<artículo>_…» tal cual
///    (`R8BE001     prgCXC1123362_GENERIC_LA`). Un volcado sin él no es de
///    ESTE firmware;
///  - su SHA-1, para cotejarlo con el que imprimió seftool.
///
/// El motivo es el PRIMERO que se encuentra y se deja de leer en cuanto
/// aparece (el ID del firmware, que puede estar en cualquier sitio, se
/// comprueba al final): con un motivo, `sha1` es null.
Future<AnalisisNor> analizarVolcadoNor(File f,
    {int esperado = EjecutorRespaldo.tamanoFlash, String? cxcArticulo}) async {
  final largo = await f.length();
  if (largo != esperado) {
    return (
      motivo: 'El volcado mide $largo B y se esperaban $esperado B.',
      sha1: null
    );
  }
  const mib = 0x100000;
  final aguja = (cxcArticulo == null || cxcArticulo.isEmpty)
      ? null
      : Uint8List.fromList(ascii.encode('prg$cxcArticulo'));
  var vistoElId = aguja == null; // sin ID que buscar no hay nada que exigir
  var cola = Uint8List(0); // el final del trozo anterior (por si el ID cae en la juntura)
  Uint8List? primero;
  final ctx = AccumulatorSink<Digest>();
  final h = sha1.startChunkedConversion(ctx);
  final raf = await f.open();
  try {
    for (var desde = 0; desde < esperado; desde += mib) {
      final quiero = esperado - desde < mib ? esperado - desde : mib;
      final b = await raf.read(quiero);
      if (b.length < quiero) {
        return (
          motivo: 'El volcado se acaba antes de '
              '0x${(0x44000000 + desde).toRadixString(16).toUpperCase()}.',
          sha1: null
        );
      }
      if (desde == 0) {
        primero = b;
        if (_uniforme(b, 0, 0x40000)) {
          return (motivo: _msgUniforme('el arranque (0x44000000)', b[0]), sha1: null);
        }
      }
      if (desde == mib && b.length >= 0x80000 && _uniforme(b, 0x40000, 0x40000)) {
        return (
          motivo: _msgUniforme('el inicio del main (0x44140000)', b[0x40000]),
          sha1: null
        );
      }
      if (esperado == EjecutorRespaldo.tamanoFlash &&
          (desde == 16 * mib || desde == 32 * mib || desde == 48 * mib) &&
          _iguales(primero!, b)) {
        return (
          motivo: 'El MiB 0x${(0x44000000 + desde).toRadixString(16).toUpperCase()} '
              'es idéntico al del arranque (0x44000000): la NOR se repite, el '
              'loader ignoró la dirección.',
          sha1: null
        );
      }
      if (!vistoElId) {
        final ventana = Uint8List(cola.length + b.length)
          ..setRange(0, cola.length, cola)
          ..setRange(cola.length, cola.length + b.length, b);
        vistoElId = _contiene(ventana, aguja!);
        final n = aguja.length - 1;
        cola = b.length > n ? b.sublist(b.length - n) : Uint8List.fromList(b);
      }
      h.add(b);
    }
  } finally {
    await raf.close();
  }
  h.close();
  if (!vistoElId) {
    return (
      motivo: 'El volcado no contiene «prg$cxcArticulo», el ID del firmware '
          'de este aparato: no es la NOR de este teléfono, o la lectura no '
          'devolvió el main.',
      sha1: null
    );
  }
  return (motivo: null, sha1: ctx.events.single.toString());
}

bool _uniforme(Uint8List b, int desde, int largo) {
  final primero = b[desde];
  for (var i = desde + 1; i < desde + largo; i++) {
    if (b[i] != primero) return false;
  }
  return true;
}

String _msgUniforme(String donde, int byte) =>
    'Los 256 KiB de $donde son todos 0x'
    '${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}: la lectura no '
    'devolvió la flash real.';

bool _iguales(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _contiene(Uint8List pajar, Uint8List aguja) {
  final n = aguja.length;
  var i = 0;
  while (true) {
    i = pajar.indexOf(aguja[0], i);
    if (i < 0 || i + n > pajar.length) return false;
    var k = 1;
    while (k < n && pajar[i + k] == aguja[k]) {
      k++;
    }
    if (k == n) return true;
    i++;
  }
}

/// Como [analizarVolcadoNor] pero solo devuelve el motivo (null = creíble).
Future<String?> verificarVolcadoNor(File f,
        {int esperado = EjecutorRespaldo.tamanoFlash, String? cxcArticulo}) async =>
    (await analizarVolcadoNor(f, esperado: esperado, cxcArticulo: cxcArticulo))
        .motivo;

/// Lo que dejó un intento de `read-flash` (lo rellena [_intentoReadFlash]).
class _IntentoNor {
  bool ok = false;
  bool rechazado = false;
  bool executerFalto = false;

  /// seftool imprimió `Flash dump saved <ruta> (<n> bytes, SHA-1 <hex>)`.
  bool guardado = false;
  String? rutaImpresa;
  int? bytesImpresos;
  String? sha1Impreso;

  /// seftool comprobó el IMEI (`--imei`) y se negó: hay OTRO teléfono conectado.
  bool imeiRechazado = false;

  /// seftool dijo que terminó bien pero el volcado que dejó es de OTRO IMEI.
  bool otroTelefono = false;

  /// El volcado que hay en disco no es el que seftool dice haber guardado
  /// (falta su confirmación, o el SHA-1/tamaño/nombre no cuadran): puede ser
  /// de una pasada anterior o haberse estropeado. No se reintenta.
  bool sinConfirmar = false;

  /// El volcado es del tamaño y nombre esperados pero NO es creíble como NOR
  /// (todo un byte, repetido, sin el ID del firmware…). No se registra.
  bool volcadoMalo = false;
  String? motivo;
}

/// Lo que dejó la lectura de la NOR entera (cancelada o hecha).
class _ResultadoNor {
  bool cancelado = false;
}

/// Ejecutor del flujo de respaldo. Tiene DOS modos:
///
///  - **simulado**: no hay aparato (bridge_mock en el Mac). Escribe ficheros
///    pequeños pero reales, con SHA-256 válido, y emite eventos con cadencia
///    creíble para validar la UI. Es lo que había antes y no ha cambiado.
///  - **real**: hay un teléfono DE FÁBRICA al otro lado de un cable serie.
///    Llama a `seftool-senew` por subproceso (ver `seftool.dart`) y mueve a
///    nuestra carpeta los volcados que seftool deja en su `./backup/`.
///
/// Se elige con el transporte efectivo:
///   SENUS_TRANSPORTE=socket:...  (bridge_mock) → simulado
///   SENUS_TRANSPORTE=emu:...     (W580 en QEMU) → simulado
///   SENUS_TRANSPORTE=simulado                  → simulado
///   SENUS_SIMULADO=1                           → simulado (escape de mano)
///   cualquier otra cosa, incluido vacío        → REAL (libusb / cable serie)
///
/// En modo real NADA se ejecuta hasta que el usuario pulsa el botón, y lo
/// primero es `identify`: si falla, se aborta sin haber escrito un byte.
class EjecutorRespaldo {
  final Telefono telefono;
  final AlmacenRespaldos almacen;
  final bool _simulado;

  /// Puerto serie del cable. Si no se da, se autodetecta; si no hay nada que
  /// autodetectar, la pantalla lo pide con un campo de texto.
  final String? puerto;

  /// Inyectable para las pruebas.
  final Seftool? _seftool;

  EjecutorRespaldo({
    required this.telefono,
    AlmacenRespaldos? almacen,
    bool? simulado,
    this.puerto,
    Seftool? seftool,
  })  : almacen = almacen ?? AlmacenRespaldos.predeterminado(),
        _seftool = seftool,
        _simulado = simulado ?? decidirSimulado();

  bool get esSimulado => _simulado;

  /// Zona que se vuelca entera: la NOR del aparato, 64 MiB desde 0x44000000.
  static const int inicioFlash = 0x44000000;
  static const int tamanoFlash = 0x04000000;

  static bool decidirSimulado() {
    if ((Platform.environment['SENUS_SIMULADO'] ?? '') == '1') return true;
    final t = Platform.environment['SENUS_TRANSPORTE'] ?? '';
    if (t.startsWith('socket:')) return true;
    if (t.startsWith('emu:')) return true; // el W580 en QEMU: sin cable serie
    if (t == 'simulado') return true;
    // Vacío o `libusb:*` = aparato de verdad: se cablea seftool.
    return false;
  }

  Seftool _herramienta() =>
      _seftool ??
      Seftool(
        raiz: Seftool.raizPredeterminada,
        puerto: puerto ?? Seftool.autodetectarPuerto() ?? '',
      );

  Stream<EventoRespaldo> correr({String? copiaEspejoScp}) async* {
    Seftool? sef;
    if (!_simulado) {
      sef = _herramienta();
      if (sef.puerto.isEmpty) {
        yield const EventoRespaldo(
          paso: 'identificar',
          pasoHecho: false,
          error: 'No hay ningún puerto serie a la vista. Enchufa el cable '
              'DCU-60 (teléfono APAGADO, tecla C pulsada) o escribe el '
              'puerto a mano.',
        );
        return;
      }
      try {
        sef.exigirBinario();
      } on SeftoolError catch (e) {
        yield EventoRespaldo(
            paso: 'identificar',
            pasoHecho: false,
            error: '${e.motivo}\n${e.remedio ?? ''}');
        return;
      }
      yield EventoRespaldo(
          logLinea: 'Modo REAL · puerto ${sef.puerto} · ${sef.binario}');
      if (sef.ensayo) {
        yield const EventoRespaldo(
            logLinea: 'SENUS_SEFTOOL_ENSAYO=1: se registran las órdenes, '
                'no se ejecuta ninguna.');
      }
    } else {
      yield const EventoRespaldo(
          logLinea: 'Modo SIMULADO (sin aparato): ficheros de relleno.');
    }

    // ---- 1. IDENTIFICAR
    yield const EventoRespaldo(paso: 'identificar', pasoHecho: false);
    SalidaIdentify ide;
    try {
      if (_simulado) {
        yield const EventoRespaldo(logLinea: '> seftool identify');
        ide = await _identifySimulado();
      } else {
        final cola = <EventoRespaldo>[];
        final info =
            await sef!.identify(alVuelo: (l) => cola.add(EventoRespaldo(logLinea: l.texto)));
        yield* Stream.fromIterable(cola);
        ide = SalidaIdentify(
          modelo: info.modeloCorto,
          serie: info.imei,
          cid: info.cid,
          color: info.color,
          firmwareOriginal: info.cxcVersion,
          crudo: info.crudo,
          paqueteAnycid: info.paqueteAnycid,
          cxcArticulo: info.cxcArticulo,
        );
      }
      yield EventoRespaldo(logLinea: 'Modelo:   ${ide.modelo}');
      yield EventoRespaldo(logLinea: 'Serial (IMEI): ${ide.serie}');
      yield EventoRespaldo(logLinea: 'ACTIVE CID: ${ide.cid}');
      yield EventoRespaldo(logLinea: 'COLOR:      ${ide.color}');
      yield EventoRespaldo(
          logLinea: 'Firmware original: ${ide.firmwareOriginal}');
      if (ide.paqueteAnycid != null) {
        yield EventoRespaldo(
            logLinea: 'Paquete anycid que resolvió seftool: '
                '${ide.paqueteAnycid}');
      }
      if (!_simulado) {
        // Todas las sesiones que siguen (GDFS, paquete anycid, NOR) tienen que
        // ser de ESTE teléfono: seftool lo comprueba con --imei en cuanto el
        // primer loader dice el suyo. Sin IMEI no hay con qué comprobarlo.
        if (!Seftool.imeiValido(ide.serie)) {
          yield EventoRespaldo(
              paso: 'identificar',
              pasoHecho: false,
              error: 'identify no trajo un IMEI utilizable '
                  '(«${ide.serie}»): sin él no se puede garantizar que todas '
                  'las sesiones del respaldo sean del mismo teléfono. No se '
                  'leyó nada más y no se registró ningún respaldo.');
          return;
        }
        sef!.imeiEsperado = ide.serie;
      }
      yield const EventoRespaldo(paso: 'identificar', pasoHecho: true);
    } on SeftoolError catch (e) {
      yield EventoRespaldo(
          paso: 'identificar',
          pasoHecho: false,
          error: '${e.motivo}\n${e.remedio ?? ''}');
      return;
    } catch (e) {
      yield EventoRespaldo(
          paso: 'identificar', pasoHecho: false, error: 'identify: $e');
      return;
    }

    // ---- 2. RESPALDO (2 GDFS + flash full + metadatos)
    // Cómo se lee la NOR de ESTE aparato se decide ANTES de tocar nada más: si
    // no se puede, mejor saberlo ahora que tras tres reconexiones.
    final nor = _simulado
        ? (via: LecturaNor.directa, motivo: null)
        : lecturaNorPara(modelo: ide.modelo, cid: ide.cid, color: ide.color);
    if (nor.via == LecturaNor.noDisponible) {
      yield EventoRespaldo(
          paso: 'respaldo',
          pasoHecho: false,
          error: 'SENUS no puede hacer el respaldo completo de este aparato.\n'
              '${nor.motivo}\n'
              'No se leyó ni se escribió nada más y no se registró ningún '
              'respaldo.');
      return;
    }
    yield const EventoRespaldo(paso: 'respaldo', pasoHecho: false);
    final dir = await almacen.abrirCarpeta(ide.modelo, ide.serie);
    yield EventoRespaldo(logLinea: 'Carpeta de respaldo: ${dir.path}');
    final alCancelar = 'el respaldo NO se completa ni se registra. Lo ya '
        'leído queda en ${dir.path}.';

    String shaFlash;
    int bytesFlash;
    final shasGdfs = <String>[]; // sobrevive al try; se pasa al RespaldoRollback
    try {
      // --- GDFS por duplicado
      final shas = shasGdfs;
      for (final cual in const ['A', 'B']) {
        if (!_simulado) {
          // La orden anterior apagó el teléfono: hay que volver a entrar en C.
          final d = DecisionPausa();
          yield* pausar(d,
              titulo: tituloReconectar,
              detalle: detalleReconectar(
                  cierre: 'para leer el GDFS (copia $cual)',
                  alCancelar: alCancelar));
          if (!d.seguir) {
            yield EventoRespaldo(
                paso: 'respaldo',
                pasoHecho: false,
                error: 'Cancelado por el usuario antes de leer el GDFS '
                    '$cual: $alCancelar');
            return;
          }
        }
        yield EventoRespaldo(logLinea: '> seftool read-gdfs (copia $cual)');
        final destino = File(p.join(dir.path, 'gdfs_$cual.bin'));
        if (_simulado) {
          final datos = await _gdfsSimulado();
          await destino.writeAsBytes(datos);
        } else {
          final cola = <EventoRespaldo>[];
          final origen = await sef!
              .leerGdfs(alVuelo: (l) => cola.add(EventoRespaldo(logLinea: l.texto)));
          yield* Stream.fromIterable(cola);
          // El nombre lleva el IMEI de la sesión: si no es el de identify, se
          // enchufó OTRO teléfono entre dos pasos (con las pausas de por medio
          // es posible) y no se mezclan aparatos en un respaldo.
          if (!sef.ensayo && !p.basename(origen.path).contains(ide.serie)) {
            throw SeftoolError(
              'El GDFS que dejó seftool (${p.basename(origen.path)}) no lleva '
              'el IMEI de identify (${ide.serie}).',
              remedio: '¿Cambiaste de teléfono entre dos pasos? Empieza el '
                  'respaldo de nuevo con un solo aparato.',
            );
          }
          // seftool lo dejó en SU ./backup con nombre por IMEI (trampa 2):
          // lo copiamos al respaldo con nuestro nombre.
          await origen.copy(destino.path);
          if (await destino.length() == 0) {
            throw SeftoolError(
              'El GDFS $cual que dejó seftool (${p.basename(origen.path)}) '
              'está vacío.',
              remedio: 'Un respaldo con un GDFS de 0 B no sirve para '
                  'restaurar nada. No se leyó nada más.',
            );
          }
          yield EventoRespaldo(
              logLinea: '  ${p.basename(origen.path)} → gdfs_$cual.bin');
        }
        final sha = await _sha256DeFichero(destino);
        shas.add(sha);
        await File(p.join(dir.path, 'gdfs_$cual.sha256'))
            .writeAsString('$sha  gdfs_$cual.bin\n');
        yield EventoRespaldo(
            logLinea: 'GDFS $cual: ${await destino.length()} B  ·  '
                'sha256 ${sha.substring(0, 16)}…');
      }
      if (shas[0] != shas[1]) {
        // Aviso, NO fallo: el procedimiento dice guardar las dos.
        yield const EventoRespaldo(
            logLinea: 'AVISO: GDFS A y B difieren bit a bit — se guardan '
                'ambos. No sigas sin instrumentar.');
      } else {
        yield const EventoRespaldo(logLinea: 'GDFS A y B iguales. Validados.');
      }

      // --- NOR entera
      yield EventoRespaldo(
          logLinea: 'NOR entera: 64 MiB desde '
              '0x${inicioFlash.toRadixString(16).toUpperCase()} '
              '(es lento).');
      final destinoFlash = File(p.join(dir.path, 'flash_full.bin'));
      if (_simulado) {
        final sink = destinoFlash.openWrite();
        final ctx = AccumulatorSink<Digest>();
        final inp = sha256.startChunkedConversion(ctx);
        var n = 0;
        await for (final chunk in _flashSimulado()) {
          sink.add(chunk.datos);
          inp.add(chunk.datos);
          n += chunk.datos.length;
          yield EventoRespaldo(progreso: chunk.fraccion);
        }
        await sink.flush();
        await sink.close();
        inp.close();
        shaFlash = ctx.events.single.toString();
        bytesFlash = n;
      } else {
        final real = sef!;
        final res = _ResultadoNor();
        // OJO: `await for`, no `yield*`. El error de un sub-generador que se
        // reenvía con `yield*` NO lo atrapa el try/catch de aquí abajo.
        await for (final e
            in _leerNorReal(real, ide, nor.via, destinoFlash, alCancelar, res)) {
          yield e;
        }
        if (res.cancelado) return;
        // El volcado ya se cotejó con lo que imprimió seftool y se comprobó
        // que es creíble como NOR dentro de _intentoReadFlash.
        bytesFlash = await destinoFlash.length();
        shaFlash = await _sha256DeFichero(destinoFlash);
      }
      await File(p.join(dir.path, 'flash_full.sha256'))
          .writeAsString('$shaFlash  flash_full.bin\n');
      yield EventoRespaldo(
          logLinea: 'FLASH: $bytesFlash B  ·  '
              'sha256 ${shaFlash.substring(0, 16)}…');
    } on SeftoolError catch (e) {
      yield EventoRespaldo(
          paso: 'respaldo',
          pasoHecho: false,
          error: '${e.motivo}\n${e.remedio ?? ''}');
      return;
    } catch (e) {
      yield EventoRespaldo(
          paso: 'respaldo', pasoHecho: false, error: 'respaldo: $e');
      return;
    }

    // identify.txt tal cual lo escupió seftool.
    await File(p.join(dir.path, 'identify.txt')).writeAsString(ide.crudo ??
        'Model: ${ide.modelo}\nSerial: ${ide.serie}\nACTIVE CID: ${ide.cid}\n'
            'COLOR: ${ide.color}\nFirmware: ${ide.firmwareOriginal}\n');

    final r = RespaldoRollback(
      carpeta: dir.path,
      modelo: ide.modelo,
      serie: ide.serie,
      fecha: DateTime.now(),
      cid: ide.cid,
      color: ide.color,
      firmwareOriginal: ide.firmwareOriginal,
      shaFlash: shaFlash,
      bytesFlash: bytesFlash,
      // Un ensayo (SENUS_SEFTOOL_ENSAYO=1) no tocó ningún aparato: su
      // «respaldo» lleva un relleno de 64 KiB y no puede desbloquear Instalar.
      simulado: _simulado || (sef?.ensayo ?? false),
      cxcArticulo: ide.cxcArticulo,
      paqueteAnycid: ide.paqueteAnycid,
      // shas[0] y shas[1] vienen del bucle de read-gdfs de arriba, en el
      // mismo orden que las copias ('A', 'B').
      shaGdfsA: shasGdfs.isNotEmpty ? shasGdfs[0] : null,
      shaGdfsB: shasGdfs.length > 1 ? shasGdfs[1] : null,
    );
    await almacen.registrar(r);
    yield EventoRespaldo(logLinea: 'metadatos.json escrito en ${r.rutaMetadatos}');
    yield EventoRespaldo(logLinea: 'índice actualizado: ${almacen.rutaIndice}');
    yield const EventoRespaldo(paso: 'respaldo', pasoHecho: true);

    // ---- 3. COPIA ESPEJO AL x86 (opcional)
    yield const EventoRespaldo(paso: 'espejo', pasoHecho: false);
    if (copiaEspejoScp == null || copiaEspejoScp.isEmpty) {
      yield const EventoRespaldo(logLinea: 'Omitida (sin destino SCP).');
      yield const EventoRespaldo(paso: 'espejo', pasoHecho: true);
    } else {
      try {
        yield EventoRespaldo(logLinea: '> scp -r ${dir.path} $copiaEspejoScp');
        if (_simulado) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          yield const EventoRespaldo(
              logLinea: '[simulado] copia espejo completada');
        } else {
          final res = await Process.run(
              'scp', ['-r', dir.path, copiaEspejoScp],
              runInShell: false);
          final salida = res.stdout.toString().trim();
          if (salida.isNotEmpty) yield EventoRespaldo(logLinea: salida);
          if (res.exitCode != 0) {
            yield EventoRespaldo(
                paso: 'espejo',
                pasoHecho: false,
                error: 'scp exit ${res.exitCode}: ${res.stderr}\n'
                    'El respaldo local SIGUE BIEN en ${dir.path}');
            return;
          }
        }
        yield const EventoRespaldo(paso: 'espejo', pasoHecho: true);
      } catch (e) {
        yield EventoRespaldo(
            paso: 'espejo',
            pasoHecho: false,
            error: 'scp: $e\nEl respaldo local SIGUE BIEN en ${dir.path}');
      }
    }
  }

  // ---------------- Modo real ---------------- //

  /// Lee la NOR entera por la vía que toque, con las pausas de reconexión.
  /// Cancelar una pausa deja `res.cancelado` y el error ya emitido.
  Stream<EventoRespaldo> _leerNorReal(Seftool sef, SalidaIdentify ide,
      LecturaNor via, File destino, String alCancelar, _ResultadoNor res) async* {
    EventoRespaldo cancelado(String donde) => EventoRespaldo(
        paso: 'respaldo',
        pasoHecho: false,
        error: 'Cancelado por el usuario ($donde): $alCancelar');

    if (via == LecturaNor.anycid) {
      final cid = int.tryParse(ide.cid);
      if (cid == null) {
        throw SeftoolError(
            'No pude leer el CID activo del aparato («${ide.cid}»).',
            remedio: 'seftool exige --cid para leer la NOR por anycid.');
      }
      // Desde aquí el respaldo deja de ser de solo lectura.
      final d = DecisionPausa();
      yield* pausar(d,
          titulo: '$tituloReconectar: empieza la parte con exploit',
          detalle: detalleReconectar(
              aviso: 'DESDE AQUÍ YA NO ES SOLO LECTURA. `upload-anycid` '
                  'escribe 3 ficheros en el sistema de archivos del teléfono '
                  '(/tpa/preset/custom/…). No toca la NOR ni el GDFS, pero el '
                  'volcado de la NOR los incluirá.',
              cierre: 'para subir el paquete anycid',
              alCancelar: alCancelar));
      if (!d.seguir) {
        res.cancelado = true;
        yield cancelado('antes de subir el paquete anycid');
        return;
      }
      yield const EventoRespaldo(
          logLinea: '────────────────────────────────────────');
      yield* subirAnycidGuiado(sef);

      String? ultimoFallo;
      for (var intento = 1; intento <= maxIntentosExecuter; intento++) {
        final dx = DecisionPausa();
        yield* pausar(dx,
            titulo: tituloExecuter(intento: intento),
            detalle:
                detalleExecuter(alCancelar: alCancelar, fallo: ultimoFallo));
        if (!dx.seguir) {
          res.cancelado = true;
          yield cancelado('en el paso de «executer»');
          return;
        }
        final o = _IntentoNor();
        yield* _intentoReadFlash(sef, ide, destino,
            anycid: true, cid: cid, out: o);
        if (o.ok) return;
        if (o.imeiRechazado) {
          // Otro teléfono: ni el ritual del executer ni un reintento lo arreglan.
          throw SeftoolError(mensajeOtroTelefono,
              remedio: o.motivo, imeiRechazado: true);
        }
        if (o.rechazado) {
          // Una negativa de las compuertas no se arregla reintentando.
          throw SeftoolError('seftool se negó a leer la NOR.',
              remedio: o.motivo);
        }
        if (o.otroTelefono) {
          // Tampoco enchufar otro teléfono.
          throw SeftoolError('Se leyó OTRO teléfono, no el del respaldo.',
              remedio: o.motivo);
        }
        if (o.sinConfirmar) {
          throw SeftoolError(
              'No se pudo confirmar que el volcado sea el de esta lectura.',
              remedio: '${o.motivo} No se registra ningún respaldo.');
        }
        if (o.volcadoMalo) {
          throw SeftoolError('El volcado de la NOR no sirve como respaldo.',
              remedio: '${o.motivo} No se registra ningún respaldo.');
        }
        ultimoFallo = o.executerFalto
            ? 'seftool no encontró el executer activo («Run executer first»).'
            : (o.motivo ?? 'seftool terminó con error.');
        yield EventoRespaldo(
            logLinea:
                'Intento $intento/$maxIntentosExecuter fallido: $ultimoFallo');
      }
      throw SeftoolError(
          'No se pudo leer la NOR tras $maxIntentosExecuter intentos.',
          remedio: ultimoFallo);
    }

    // Lectura directa (BROWN u otros): una sola orden.
    final d = DecisionPausa();
    yield* pausar(d,
        titulo: tituloReconectar,
        detalle: detalleReconectar(
            cierre: 'para leer la NOR entera (64 MiB, es lento)',
            alCancelar: alCancelar));
    if (!d.seguir) {
      res.cancelado = true;
      yield cancelado('antes de leer la NOR');
      return;
    }
    final o = _IntentoNor();
    yield* _intentoReadFlash(sef, ide, destino, anycid: false, out: o);
    if (!o.ok) {
      if (o.imeiRechazado) {
        throw SeftoolError(mensajeOtroTelefono,
            remedio: o.motivo, imeiRechazado: true);
      }
      if (o.sinConfirmar) {
        throw SeftoolError(
            'No se pudo confirmar que el volcado sea el de esta lectura.',
            remedio: '${o.motivo} No se registra ningún respaldo.');
      }
      if (o.volcadoMalo) {
        throw SeftoolError('El volcado de la NOR no sirve como respaldo.',
            remedio: '${o.motivo} No se registra ningún respaldo.');
      }
      throw SeftoolError('read-flash falló.', remedio: o.motivo);
    }
  }

  /// `Flash dump saved <ruta> (<n> bytes, SHA-1 <hex>)`: lo que imprime seftool
  /// cuando el volcado está entero, comprobado en disco y publicado.
  static final _marcadorVolcado = RegExp(
      r'Flash dump saved (.+) \((\d+) bytes, SHA-1 ([0-9a-fA-F]{40})\)');

  /// Aparta (no borra) un fichero de una pasada ANTERIOR con el nombre que va
  /// a producir seftool (otro intento, una orden a mano en el CLI…): si no,
  /// «seftool terminó bien y el volcado está ahí» lo daría por suyo.
  static Future<String?> _apartarViejo(File f) async {
    if (!f.existsSync()) return null;
    final t = DateTime.now();
    String dos(int v) => v.toString().padLeft(2, '0');
    final marca = '${t.year}${dos(t.month)}${dos(t.day)}'
        '${dos(t.hour)}${dos(t.minute)}${dos(t.second)}';
    var destino = '${f.path}.previo-$marca';
    for (var n = 2; File(destino).existsSync(); n++) {
      destino = '${f.path}.previo-$marca-$n';
    }
    await f.rename(destino);
    return destino;
  }

  /// UN intento de `read-flash` de la NOR entera. El progreso sale de dos
  /// sitios: de la línea «reading block: n/total» de seftool y, como red, del
  /// tamaño del `.INCOMPLETO` que seftool va engordando (el nombre definitivo
  /// solo aparece al terminar y comprobarse). Rellena `out` y, si salió bien,
  /// deja el volcado en `destino`. Los marcadores de seftool (`REFUSED`,
  /// `Run executer first`, `Flash dump saved`) se leen del flujo de líneas.
  ///
  /// Un volcado solo se da por bueno si seftool lo CONFIRMA en esta pasada
  /// (`Flash dump saved <nombre> (<n> bytes, SHA-1 <hex>)`) y el fichero que
  /// hay en disco tiene ese tamaño y ese SHA-1, y además es creíble como NOR
  /// ([analizarVolcadoNor]).
  Stream<EventoRespaldo> _intentoReadFlash(
      Seftool sef, SalidaIdentify ide, File destino,
      {required bool anycid, int? cid, required _IntentoNor out}) async* {
    final orden = Seftool.ordenLeerFlash(
        inicio: inicioFlash, tamano: tamanoFlash, anycid: anycid, cid: cid);
    String h8(int v) => v.toRadixString(16).toUpperCase().padLeft(8, '0');
    final nombre =
        'flashdump_${ide.serie}_${h8(inicioFlash)}_${h8(tamanoFlash)}.bin';
    final esperado = File(p.join(sef.dirBackup.path, nombre));
    final parcial = File('${esperado.path}.INCOMPLETO');

    if (!sef.ensayo) {
      final apartado = await _apartarViejo(esperado);
      if (apartado != null) {
        yield EventoRespaldo(
            logLinea: 'AVISO: ya había un ${p.basename(esperado.path)} de otra '
                'pasada; se aparta como ${p.basename(apartado)} para no '
                'confundirlo con la lectura de ahora.');
      }
      // El `.INCOMPLETO` de un intento anterior es lo que seftool mismo marca
      // «do NOT use it»: no vale como respaldo de nada y el siguiente intento
      // lo trunca. Se borra (apartarlo dejaría hasta 64 MiB por intento) para
      // que además la barra de progreso no parta de su tamaño.
      if (parcial.existsSync()) {
        await parcial.delete();
        yield EventoRespaldo(
            logLinea: 'AVISO: se borra ${p.basename(parcial.path)} de un '
                'intento anterior (incompleto: no sirve).');
      }
    }

    final cola = StreamController<EventoRespaldo>();
    Timer? vigilante;
    var ultimo = 0.0;
    var salioBien = false;

    if (!sef.ensayo) {
      vigilante = Timer.periodic(const Duration(seconds: 1), (_) {
        try {
          if (parcial.existsSync()) {
            final f = (parcial.lengthSync() / tamanoFlash).clamp(0.0, 1.0);
            if (f > ultimo) {
              ultimo = f;
              cola.add(EventoRespaldo(progreso: f));
            }
          }
        } catch (_) {}
      });
    }

    final tarea = () async {
      var identidad = ''; // «El aparato conectado dice IMEI «X» y se esperaba «Y»»
      try {
        await for (final l in sef.correr(orden.accion, extras: orden.extras)) {
          final t = l.texto;
          if (t.contains('El aparato conectado dice IMEI') ||
              t.contains('El aparato no ha dicho su IMEI')) {
            identidad = t.trim();
          }
          if (t.contains('imei-check: REFUSED')) {
            out.imeiRechazado = true;
            out.motivo = [identidad, t.trim()].where((x) => x.isNotEmpty).join('\n');
          }
          if (t.contains('read-flash --anycid: REFUSED')) {
            out.rechazado = true;
            out.motivo = t.trim();
          }
          if (t.contains('Run executer first')) out.executerFalto = true;
          final m = _marcadorVolcado.firstMatch(t);
          if (m != null) {
            out.guardado = true;
            out.rutaImpresa = m[1];
            out.bytesImpresos = int.tryParse(m[2]!);
            out.sha1Impreso = m[3]!.toLowerCase();
          }
          if (l.progreso != null && l.progreso! > ultimo) {
            ultimo = l.progreso!;
            cola.add(EventoRespaldo(progreso: l.progreso));
          } else if (l.progreso == null) {
            cola.add(EventoRespaldo(logLinea: t));
          }
        }
        salioBien = true;
      } on SeftoolError catch (e) {
        if (e.imeiRechazado) out.imeiRechazado = true;
        out.motivo ??= '${e.motivo}${e.remedio == null ? '' : ' ${e.remedio}'}';
      } catch (e) {
        cola.addError(e); // algo inesperado: que lo vea quien llama
      } finally {
        vigilante?.cancel();
        await cola.close();
      }
    }();

    yield* cola.stream;
    await tarea;

    if (out.rechazado || out.imeiRechazado) return;

    if (sef.ensayo) {
      await destino.writeAsBytes(List<int>.filled(64 * 1024, 0x5A));
      yield const EventoRespaldo(
          logLinea: '  [ensayo] flash_full.bin de relleno (64 KiB).');
      out.ok = true;
      return;
    }

    final propio = esperado.existsSync() ? esperado.lengthSync() : null;
    final completo = propio == tamanoFlash;
    if (salioBien || (out.guardado && completo)) {
      if (!completo) {
        // Lo que NO se hace es tomar «el flashdump más nuevo»: podría ser de
        // otro teléfono. Los volcados de OTRO IMEI se nombran; el propio, si
        // existe pero incompleto, también.
        final otros = sef.dirBackup.existsSync()
            ? sef.dirBackup
                .listSync()
                .whereType<File>()
                .map((f) => p.basename(f.path))
                .where((n) =>
                    n != nombre &&
                    n.startsWith('flashdump_') &&
                    n.endsWith('_${h8(inicioFlash)}_${h8(tamanoFlash)}.bin'))
                .toList()
            : <String>[];
        out.otroTelefono = otros.isNotEmpty;
        out.motivo = 'seftool terminó bien pero no dejó $nombre entero'
            '${propio == null ? '' : ' (mide $propio B)'}'
            '${otros.isEmpty ? '' : ' (hay volcados de otro IMEI: '
                '${otros.join(', ')}; ¿cambiaste de teléfono entre dos pasos?)'}.';
        return;
      }

      // ---- ¿Es el volcado de ESTA lectura?
      final impresa = out.rutaImpresa;
      if (!out.guardado || impresa == null || out.sha1Impreso == null) {
        out.sinConfirmar = true;
        out.motivo = 'seftool no confirmó el volcado (falta la línea «Flash '
            'dump saved <ruta> (<n> bytes, SHA-1 <hex>)»): lo que hay en '
            '${p.basename(esperado.path)} puede ser de otra pasada, o seftool '
            'es anterior a la lectura atómica.';
        return;
      }
      if (p.basename(impresa) != nombre || out.bytesImpresos != tamanoFlash) {
        out.sinConfirmar = true;
        out.motivo = 'seftool confirmó otro volcado ($impresa, '
            '${out.bytesImpresos} B) y se esperaba $nombre ($tamanoFlash B).';
        return;
      }
      final an = await analizarVolcadoNor(esperado, cxcArticulo: ide.cxcArticulo);
      if (an.motivo != null) {
        // Se conserva junto al respaldo como prueba, pero no se registra.
        await _moverA(esperado, destino);
        out.volcadoMalo = true;
        out.motivo = an.motivo;
        return;
      }
      if (an.sha1 != out.sha1Impreso) {
        out.sinConfirmar = true;
        out.motivo = 'El volcado en disco (SHA-1 ${an.sha1}) no es el que '
            'seftool dijo haber guardado (SHA-1 ${out.sha1Impreso}).';
        return;
      }

      if (!salioBien) {
        yield const EventoRespaldo(
            logLinea: 'AVISO: seftool terminó con error DESPUÉS de guardar el '
                'volcado entero (suele ser el apagado final): se acepta el '
                'volcado.');
      }
      await _moverA(esperado, destino);
      yield const EventoRespaldo(progreso: 1.0);
      yield EventoRespaldo(
          logLinea: '  $nombre → flash_full.bin  ·  SHA-1 ${out.sha1Impreso} '
              '(coincide con el que imprimió seftool)');
      out.ok = true;
    }
  }

  static Future<void> _moverA(File origen, File destino) async {
    await origen.rename(destino.path).catchError((_) async {
      // rename falla entre sistemas de ficheros distintos: copiar y borrar.
      await origen.copy(destino.path);
      await origen.delete();
      return destino;
    });
  }

  static Future<String> _sha256DeFichero(File f) async {
    final ctx = AccumulatorSink<Digest>();
    final inp = sha256.startChunkedConversion(ctx);
    await for (final trozo in f.openRead()) {
      inp.add(trozo);
    }
    inp.close();
    return ctx.events.single.toString();
  }

  // ---------------- Modo simulado (sin cambios de comportamiento) -------- //

  Future<SalidaIdentify> _identifySimulado() async {
    await Future<void>.delayed(const Duration(milliseconds: 350));
    final mod = telefono.modelo == Modelo.desconocido
        ? 'W580'
        : telefono.modelo.name.toUpperCase();
    return SalidaIdentify(
      modelo: mod,
      serie: telefono.serie.isEmpty ? '${mod}S10000001' : telefono.serie,
      cid: mod == 'W580' ? '53' : '49',
      color: 'RED',
      firmwareOriginal: mod == 'W580' ? 'R8BE001' : 'R1KG001',
    );
  }

  Future<Uint8List> _gdfsSimulado() async {
    await Future<void>.delayed(const Duration(milliseconds: 450));
    // Un GDFS creíble: cabecera + 48 KiB rellenos a partir del serial, para
    // que las dos copias den el mismo SHA (como pide el procedimiento).
    final semilla = telefono.serie.hashCode;
    final b = Uint8List(48 * 1024);
    for (var i = 0; i < b.length; i++) {
      b[i] = (semilla + i * 7) & 0xff;
    }
    b[0] = 0x47; // 'G'
    b[1] = 0x44; // 'D'
    b[2] = 0x46; // 'F'
    b[3] = 0x53; // 'S'
    return b;
  }

  Stream<_TrozoFlash> _flashSimulado() async* {
    // Fingir 64 MiB en 32 trozos (2 MiB cada uno), con cadencia visible.
    const total = 32;
    final patron = Uint8List(2 * 1024 * 1024);
    final semilla = telefono.serie.hashCode;
    for (var i = 0; i < patron.length; i += 1024) {
      patron[i] = (semilla + i) & 0xff;
    }
    for (var i = 0; i < total; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      yield _TrozoFlash(patron, (i + 1) / total);
    }
  }
}

class _TrozoFlash {
  final Uint8List datos;
  final double fraccion;
  const _TrozoFlash(this.datos, this.fraccion);
}

/// Agrupa chunks SHA-256 (equivalente a convert's AccumulatorSink<Digest>).
class AccumulatorSink<T> implements Sink<T> {
  final List<T> events = [];
  @override
  void add(T data) => events.add(data);
  @override
  void close() {}
}
