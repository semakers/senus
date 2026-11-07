// Capa de mando de `seftool-senew` como subproceso.
//
// Esto es el cable entre SENUS y el fork `~/dev/seftool-senew/`. Todo lo que
// SENUS sabe del teléfono DE FÁBRICA (el que todavía corre el firmware SEMC)
// pasa por aquí: identificar, respaldar GDFS, volcar la NOR, grabar, subir el
// paquete anycid.
//
// TRAMPAS MEDIDAS EN EL FUENTE DEL FORK (no cambiar sin volver a medirlas):
//
//  1. seftool resuelve TODAS sus rutas de datos relativas al **directorio de
//     trabajo**, no a la ubicación del binario:
//        ./loader/<x>.bin     cargadores firmados   (loader.c:75,120)
//        ./anycid/<x>.zip     paquetes anycid       (action.c:335,342)
//        ./break49/, ./rest/  break RSA y restores
//        ./backup/            TODO lo que vuelca
//     => hay que lanzarlo SIEMPRE con workingDirectory = raíz del fork.
//
//  2. `read-gdfs` NO deja `gdfs.bin` en el directorio actual (eso es lo que
//     supone `bin/senus-cid53-leer.sh`, y por eso su `mv gdfs.bin` fallaría).
//     Deja  ./backup/GDFS_<nombre>_<imei>.bin                (csloader.c:317)
//
//  3. `read-flash` deja ./backup/flashdump_<imei>_<ADDR>_<SIZE>.bin
//     con ADDR y SIZE en hexadecimal de 8 dígitos en MAYÚSCULAS. Desde el
//     2026-10-17 se escribe de forma atómica: mientras lee, el fichero es
//     `<nombre>.INCOMPLETO`; solo al terminar y comprobarse pasa a su nombre
//     (el anterior, a `.anterior`) y seftool imprime «Flash dump saved <ruta>
//     (<n> bytes, SHA-1 <hex>)». En un W580 RED hace falta `--anycid --cid N`.
//
//  4. `flash main <fichero>` NO acepta un binario crudo: exige formato BABE
//     y lo valida entero (flash_babe_fw → babe_check CHECKBABE_CHECKFULL).
//     Un .bin crudo hay que convertirlo antes con
//        `-a convert raw2babe <fichero> <dirección>`  → deja <fichero>.ssw
//     (action.c:707). Esta capa lo hace sola.
//
//  5. El progreso sale con '\r' y fflush, no con '\n' (flash.c:674,
//     csloader.c:863). Hay que trocear por \r Y por \n o no se ve nada
//     hasta el final.
//
//  6. `identify` imprime, entre otras:
//        OTP: LOCKED:1 CID:53 PAF:0 IMEI:35...     (loader.c:545)
//        ACTIVE CID:53 COLOR:RED                   (loader.c:552, solo DB2020)
//        Model: W580i                              (action.c:231)
//        MAPP CXC article / MAPP CXC version
//        Anycid package: ./anycid/R8BE001_CXC1123362_GENERIC_LA.zip
//     Ojo: «ACTIVE CID:53», SIN espacio tras los dos puntos. No hay ninguna
//     línea «Serial:»: el número de serie del aparato ES el IMEI.
//     El `--json` del fork existe SOLO para `--check-senew` (main.c), no para
//     identify; así que el parseo es de texto.
//
//  7. Algunas rutas de VKP preguntan por stdin (flash.c:699 ask_user_choice).
//     Ninguna de las nuestras pasa por ahí, pero cerramos stdin igualmente
//     para que un seftool que pregunte muera en vez de colgarse para siempre.
//
// ENTORNO: el hijo NO hereda SEFTOOL_SENEW_FORCE ni SEFTOOL_BREAK_CONFIRM.
// Son los dos interruptores con los que un humano, desde su terminal,
// confirma a propósito algo que seftool se niega a hacer solo: FORCE salta
// las compuertas de senew (la negativa de CID 53, la ventana de la NOR) y
// BREAK_CONFIRM autoriza `--break-rsa`, que ESCRIBE un bootloader parchado en
// la NOR. Una variable olvidada en el shell no puede confirmarlo por él, y
// SENUS no tiene terminal para el resto del ritual (quitar la batería y
// pulsar Y). SENUS NO pasa `--break-rsa` en ninguna orden: el plan de
// instalación bloquea los aparatos que lo necesitarían (DB2010 CID≤49).
//
// SEGURIDAD: nada de esta capa abre un puerto por su cuenta. Las acciones que
// ESCRIBEN en el aparato están marcadas `escribe: true` y sólo salen de un
// gesto explícito del usuario en la UI. Con SENUS_SEFTOOL_ENSAYO=1 ninguna
// orden se ejecuta: se registra la línea de órdenes y se devuelve éxito
// vacío (es como se prueba este fichero sin teléfono).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Algo salió mal al hablar con seftool. `remedio` es lo que se le enseña al
/// usuario (no una traza).
class SeftoolError implements Exception {
  final String motivo;
  final String? remedio;
  final int? salida;

  /// seftool comprobó el IMEI (`--imei`) y se negó a seguir: hay OTRO teléfono
  /// conectado. No se reintenta ni se pide el ritual del executer: no hay nada
  /// que arreglar con este aparato.
  final bool imeiRechazado;
  SeftoolError(this.motivo,
      {this.remedio, this.salida, this.imeiRechazado = false});
  @override
  String toString() => motivo;
}

/// Lo que se le dice a la persona cuando seftool se niega por el IMEI.
const mensajeOtroTelefono = 'El teléfono conectado NO es el del respaldo: '
    'seftool comprobó su IMEI y se negó a seguir. No se escribió nada.';

/// Una línea de salida de seftool ya normalizada, con el progreso si lo trae.
class LineaSeftool {
  final String texto;
  /// 0..1 si la línea era una barra de progreso de seftool.
  final double? progreso;
  const LineaSeftool(this.texto, {this.progreso});
}

/// Lo que `identify` dejó ver del aparato.
class InfoAparato {
  final String modelo; // "W580i"
  final String imei; // sirve de número de serie
  final String cidActivo; // "53"
  final String cidOtp; // "53"
  final String color; // "RED"
  final String cxcArticulo; // "CXC1123362"
  final String cxcVersion; // "R8BE001"  (firmware original)
  final String? paqueteAnycid; // "R8BE001_CXC1123362_GENERIC_LA"
  final bool simlockDetectado;
  final String crudo; // stdout tal cual, se guarda como identify.txt

  const InfoAparato({
    required this.modelo,
    required this.imei,
    required this.cidActivo,
    required this.cidOtp,
    required this.color,
    required this.cxcArticulo,
    required this.cxcVersion,
    required this.paqueteAnycid,
    required this.simlockDetectado,
    required this.crudo,
  });

  /// El CID que manda para decidir el camino de instalación: el de la EROM si
  /// se pudo leer, si no el del OTP.
  String get cid => cidActivo.isNotEmpty ? cidActivo : cidOtp;

  /// Modelo en la forma corta que usa el almacén de respaldos: W580/W600/W810.
  String get modeloCorto {
    final m = modelo.toUpperCase();
    for (final x in const ['W580', 'W600', 'W810']) {
      if (m.contains(x)) return x;
    }
    return m.isEmpty ? 'DESCONOCIDO' : m.replaceAll(RegExp(r'[^A-Z0-9]'), '');
  }

  /// DB2020 (W580) frente a DB2010 (W600/W810).
  String get soc => modeloCorto == 'W580' ? 'DB2020' : 'DB2010';

  /// true si el camino es anycid + payload (W580 CID53) en vez de reemplazo
  /// frío de la NOR.
  bool get necesitaAnycid => soc == 'DB2020' && cid == '53';
}

/// Cómo se puede leer la NOR de un aparato (lo decide el respaldo).
enum LecturaNor {
  /// `read-flash` a secas.
  directa,

  /// Por el exploit anycid (W580 RED CID 49/51/52): `upload-anycid` + abrir
  /// «executer» + `read-flash --anycid --cid N`.
  anycid,

  /// SENUS no sabe leerla: CID 53 sin verificar (seftool lo niega), un CID
  /// que no es de los conocidos, o un DB2010 RED (CID 49+: `read-flash` exige
  /// `--break-rsa`, que ESCRIBE un bootloader, o el exploit).
  noDisponible,
}

/// Decide cómo leer la NOR y, si no se puede, por qué (`motivo` no es null
/// solo en `noDisponible`). Función pura: se prueba sin aparato.
({LecturaNor via, String? motivo}) lecturaNorPara({
  required String modelo,
  required String cid,
  required String color,
}) {
  final m = modelo.toUpperCase();
  final rojo = color.toUpperCase() == 'RED';
  final c = int.tryParse(cid.trim());

  if (m == 'W580' && rojo) {
    if (c == 49 || c == 51 || c == 52) {
      return (via: LecturaNor.anycid, motivo: null);
    }
    if (c == 53) {
      return (
        via: LecturaNor.noDisponible,
        motivo: 'W580 RED CID 53: leer la NOR por anycid está SIN VERIFICAR '
            'en un aparato real y seftool lo niega (docs/CID53_RUTA.md, '
            'paso 4). Con SEFTOOL_SENEW_FORCE=1 se puede intentar a mano '
            'desde el CLI; SENUS no lo activa.'
      );
    }
    return (
      via: LecturaNor.noDisponible,
      motivo: 'W580 RED con CID «$cid»: no es uno de los que conoce la tabla '
          'de senew (49, 51, 52).'
    );
  }
  if ((m == 'W600' || m == 'W810') && rojo && (c == null || c >= 49)) {
    return (
      via: LecturaNor.noDisponible,
      motivo: '$m RED (DB2010), CID «$cid»: para leer su NOR seftool exige '
          '--break-rsa (que ESCRIBE un bootloader: nunca en el W600) o el '
          'exploit anycid. El respaldo de SENUS no hace ninguna de las dos.'
    );
  }
  return (via: LecturaNor.directa, motivo: null);
}

/// Mando de seftool.
class Seftool {
  /// Raíz del fork; de aquí cuelgan build/, loader/, anycid/, backup/.
  final String raiz;

  /// Puerto serie del cable (p. ej. `/dev/ttyUSB0`, `COM3`).
  final String puerto;

  /// Con true no se ejecuta nada: sólo se registra la orden. Lo enciende
  /// SENUS_SEFTOOL_ENSAYO=1 y es como se prueba sin aparato.
  final bool ensayo;

  /// Solo en `ensayo`: stdout canónico que `identify()` devuelve. Por
  /// omisión, el aparato ficticio W580i CID 53 RED IMEI 000... Los tests
  /// pueden inyectar otro para forzar flujos (p. ej. CID 52).
  final String? identifyEnsayoStdout;

  /// Velocidad que se le pide a seftool (`-b`). 921600 es la de todas las
  /// recetas validadas del CLI; con la de por omisión de seftool (115200) los
  /// 64 MiB de la NOR por un cable serie tardarían ~1,5 h. Con `-p usb` (Mac)
  /// la velocidad no cuenta.
  final int baudios;

  /// El IMEI que tiene que decir el aparato conectado (el de `identify` o el
  /// del respaldo). Mientras no sea null, cada orden con puerto lleva
  /// `--imei <IMEI>` (salvo `identify`, que es quien lo descubre): seftool
  /// compara en cuanto el primer loader dice su IMEI y se niega, antes de
  /// escribir nada, si es otro teléfono. Cada orden es una sesión nueva y
  /// entre una y otra se vuelve a enchufar el cable: sin esto, otro W580
  /// recibiría la imagen y el GDFS de este respaldo.
  String? imeiEsperado;

  /// El IMEI tal como lo acepta `--imei` de seftool (el mismo criterio que su
  /// parser): de 1 a 15 letras, cifras o «_». Un IMEI que no pase esto no se
  /// manda: se rechaza AQUÍ en vez de saltarse la comprobación.
  ///
  /// Y con alguna letra o cifra: un OTP en blanco (todo 0x00/0xFF) sale de
  /// seftool como «______________», que no identifica a ningún teléfono (dos
  /// en blanco «cuadrarían»).
  static bool imeiValido(String s) =>
      RegExp(r'^[0-9A-Za-z_]{1,15}$').hasMatch(s) && s.replaceAll('_', '').isNotEmpty;

  Seftool({
    required this.raiz,
    required this.puerto,
    bool? ensayo,
    this.identifyEnsayoStdout,
    this.baudios = 921600,
  }) : ensayo = ensayo ?? esEnsayo;

  static bool get esEnsayo =>
      (Platform.environment['SENUS_SEFTOOL_ENSAYO'] ?? '') == '1';

  /// CMake (Linux/Asahi) deja `build/seftool`; `mac/build.sh` (macOS, sin
  /// cmake) deja `seftool` en la propia raíz del fork.
  String get binario {
    // En Windows el ejecutable lleva .exe (win/build.sh lo deja en la raíz).
    final nombres = Platform.isWindows
        ? const ['build/seftool.exe', 'seftool.exe']
        : const ['build/seftool', 'seftool'];
    for (final rel in nombres) {
      final f = p.join(raiz, rel);
      if (File(f).existsSync()) return f;
    }
    return p.join(raiz, 'build', nombres.first.split('/').last);
  }
  Directory get dirBackup => Directory(p.join(raiz, 'backup'));

  /// Raíz de seftool, por orden:
  ///  1. SENUS_SEFTOOL_RAIZ.
  ///  2. La instalación empaquetada: `<carpeta de SENUS>/seftool`, con el
  ///     binario dentro (la deja el instalador de Windows).
  ///  3. La de macOS: `SENUS.app/Contents/Resources/seftool`. El .app no se
  ///     puede escribir (seftool deja sus volcados en `<raíz>/backup`), así que
  ///     se copia a `~/Library/Application Support/SENUS/seftool` y se usa esa.
  ///  4. El fork de desarrollo: `~/dev/seftool-senew`.
  static String get raizPredeterminada => resolverRaiz();

  /// [raizPredeterminada] con las entradas inyectables (para las pruebas).
  static String resolverRaiz({Map<String, String>? env, String? exe}) {
    final e = env ?? Platform.environment;
    final v = e['SENUS_SEFTOOL_RAIZ'];
    if (v != null && v.trim().isNotEmpty) return v.trim();
    final dirExe = p.dirname(exe ?? Platform.resolvedExecutable);
    final junto = p.join(dirExe, 'seftool');
    for (final bin in const ['seftool.exe', 'seftool']) {
      if (File(p.join(junto, bin)).existsSync()) return junto;
    }
    final hogar = e['HOME'] ?? e['USERPROFILE'] ?? '.';
    final enApp = p.join(p.dirname(dirExe), 'Resources', 'seftool');
    if (File(p.join(enApp, 'seftool')).existsSync()) {
      final destino = p.join(hogar, 'Library', 'Application Support', 'SENUS', 'seftool');
      try {
        copiarSiCambio(enApp, destino);
        return destino;
      } catch (_) {
        // Sin copia (disco lleno, permisos): mejor el empaquetado que nada; solo fallarán los volcados.
        return enApp;
      }
    }
    return p.join(hogar, 'dev', 'seftool-senew');
  }

  /// Copia el árbol de seftool de [origen] a [destino] (lo que falte o haya cambiado de tamaño o
  /// de fecha), sin tocar `backup/`, y deja el binario ejecutable.
  static void copiarSiCambio(String origen, String destino) {
    final raizOrigen = Directory(origen);
    for (final ent in raizOrigen.listSync(recursive: true, followLinks: false)) {
      if (ent is! File) continue;
      final rel = p.relative(ent.path, from: origen);
      if (rel.split(p.separator).first == 'backup') continue;
      final dst = File(p.join(destino, rel));
      final so = ent.statSync();
      if (dst.existsSync()) {
        final sd = dst.statSync();
        if (sd.size == so.size && !so.modified.isAfter(sd.modified)) continue;
      }
      dst.parent.createSync(recursive: true);
      ent.copySync(dst.path);
    }
    if (!Platform.isWindows) {
      final bin = p.join(destino, 'seftool');
      if (File(bin).existsSync()) Process.runSync('chmod', ['755', bin]);
    }
  }

  /// Comprueba que el binario existe y es ejecutable. Si no, un error con la
  /// ruta esperada y cómo compilarlo — nunca una excepción pelada.
  void exigirBinario() {
    if (ensayo) return;
    final f = File(binario);
    if (!f.existsSync()) {
      throw SeftoolError(
        'No encuentro el programa seftool.',
        remedio: 'Se esperaba en:\n  $binario\n\n'
            'Compílalo con:\n'
            '${Platform.isMacOS ? '  ${p.join(raiz, 'mac', 'build.sh')}' : Platform.isWindows ? '  sh ${p.join(raiz, 'win', 'build.sh')}   (en una shell MSYS2 MINGW64)' : '  cd ${p.join(raiz, 'build')} && cmake --build .'}\n\n'
            'Si lo tienes en otro sitio, arranca SENUS con\n'
            '  SENUS_SEFTOOL_RAIZ=/ruta/al/fork',
      );
    }
  }

  // ------------------------------------------------------------------ //
  // Puertos serie
  // ------------------------------------------------------------------ //

  /// Puertos que PARECEN el cable del teléfono, por plataforma. No abre
  /// ninguno: sólo mira qué nodos existen.
  static List<String> puertosCandidatos() {
    final out = <String>[];
    try {
      if (Platform.isLinux) {
        final d = Directory('/dev');
        if (d.existsSync()) {
          for (final e in d.listSync()) {
            final n = p.basename(e.path);
            if (RegExp(r'^ttyUSB\d+$').hasMatch(n) ||
                RegExp(r'^ttyACM\d+$').hasMatch(n)) {
              out.add(e.path);
            }
          }
        }
      } else if (Platform.isMacOS) {
        // El DB2020 en modo C es «SEMC USB Flash» 0fce:adde (clase 255):
        // macOS NO le crea /dev/cu.*. El seftool de la Mac se compila con
        // mac/sp_usb.c en lugar de libserialport y SOLO acepta el puerto
        // «usb» (sp_usb.c:50): un /dev/cu.* ni siquiera abriría. Si el
        // aparato no está en modo servicio, seftool falla al instante con
        // «no encuentro 0fce:adde».
        out.add('usb');
      } else if (Platform.isWindows) {
        // Como en la Mac: el DB2020 en modo C es «SEMC USB Flash» 0fce:adde
        // (clase 255) y el seftool de Windows se compila con mac/sp_usb.c
        // (libusb sobre WinUSB) en lugar de libserialport: SOLO acepta el
        // puerto «usb». Hace falta el driver WinUSB asignado al aparato.
        out.add('usb');
      }
    } catch (_) {
      // Un /dev ilegible no es motivo para tumbar la pantalla.
    }
    out.sort();
    return out;
  }

  /// El primero de los candidatos, o null si no hay ninguno (entonces la UI
  /// pide el puerto con un campo de texto).
  static String? autodetectarPuerto() {
    final c = puertosCandidatos();
    return c.isEmpty ? null : c.first;
  }

  // ------------------------------------------------------------------ //
  // Ejecución
  // ------------------------------------------------------------------ //

  /// Lanza seftool y va soltando sus líneas. `escribe` es sólo documentación
  /// de la intención en el registro, para que el log diga alto y claro cuándo
  /// una orden toca el aparato.
  Stream<LineaSeftool> correr(
    List<String> accion, {
    bool escribe = false,
    bool conPuerto = true,
    List<String> extras = const [],
  }) async* {
    exigirBinario();
    final imei = imeiEsperado;
    final llevaImei = conPuerto && imei != null && accion.first != 'identify';
    if (llevaImei && !imeiValido(imei)) {
      // Nunca «sin --imei por si acaso»: o se comprueba la identidad o no se
      // ejecuta nada.
      throw SeftoolError(
        'El IMEI esperado («$imei») no es uno que seftool acepte; no se '
        'ejecutó nada.',
        remedio: 'Tiene que ser el IMEI tal como lo imprime identify: de 1 a '
            '15 letras, cifras o «_».',
      );
    }
    final args = <String>[
      if (conPuerto) ...['-p', puerto, '-b', '$baudios'],
      ...extras,
      if (llevaImei) ...['--imei', imei],
      '-a',
      ...accion,
    ];
    final linea = '$binario ${args.join(' ')}';
    yield LineaSeftool('> ${escribe ? '[ESCRIBE] ' : ''}$linea');

    if (ensayo) {
      yield const LineaSeftool(
          '  [ensayo] SENUS_SEFTOOL_ENSAYO=1 — no se ejecuta nada.');
      return;
    }

    final proc = await Process.start(
      binario,
      args,
      workingDirectory: raiz, // trampa 1
      runInShell: false,
      environment: entornoDelHijo(),
      includeParentEnvironment: false,
    );
    // Trampa 7: que no se quede esperando una respuesta que nadie va a dar.
    await proc.stdin.close();

    final cola = StreamController<LineaSeftool>();
    var ultimaError = ''; // última línea de stderr: es lo que explica el fallo
    var identidad = ''; // «El aparato conectado dice IMEI «X» y se esperaba «Y»»
    var rechazoImei = '';
    var abiertos = 2;
    void cerrarUno() {
      if (--abiertos == 0) cola.close();
    }

    void enchufar(Stream<List<int>> s, {required bool error}) {
      s.transform(const SystemEncodingDecoder()).listen(
        (trozo) {
          for (final l in _trocear(trozo)) {
            if (l.trim().isEmpty) continue;
            if (error) ultimaError = l.trim();
            if (l.contains('El aparato conectado dice IMEI') ||
                l.contains('El aparato no ha dicho su IMEI')) {
              identidad = l.trim();
            }
            if (l.contains('imei-check: REFUSED')) rechazoImei = l.trim();
            cola.add(LineaSeftool(l, progreso: _progresoDe(l)));
          }
        },
        onDone: cerrarUno,
        onError: (_) => cerrarUno(),
        cancelOnError: false,
      );
    }

    enchufar(proc.stdout, error: false);
    enchufar(proc.stderr, error: true);

    yield* cola.stream;

    final salida = await proc.exitCode;
    if (salida != 0) {
      if (rechazoImei.isNotEmpty) {
        // Aunque no sea la última línea (un seftool anterior añadía después la
        // lista de causas del executer), el motivo REAL es el IMEI.
        throw SeftoolError(mensajeOtroTelefono,
            remedio: [identidad, rechazoImei].where((x) => x.isNotEmpty).join('\n'),
            salida: salida,
            imeiRechazado: true);
      }
      throw SeftoolError('seftool terminó con error (código $salida).',
          remedio: ultimaError.isEmpty ? null : ultimaError, salida: salida);
    }
  }

  /// Las variables con las que un humano confirma, desde su terminal, algo que
  /// seftool se niega a hacer solo. El hijo no las hereda (ver la cabecera).
  static const confirmacionesDelHumano = [
    'SEFTOOL_SENEW_FORCE',
    'SEFTOOL_BREAK_CONFIRM',
  ];

  /// El entorno con el que se lanza seftool: el del padre SIN
  /// [confirmacionesDelHumano], en cualquier grafía de mayúsculas. Público
  /// para poder probarlo.
  static Map<String, String> entornoDelHijo([Map<String, String>? padre]) {
    final e = Map<String, String>.of(padre ?? Platform.environment);
    e.removeWhere((k, _) => confirmacionesDelHumano.contains(k.toUpperCase()));
    return e;
  }

  /// Igual que `correr`, pero junta todo el texto. Para órdenes cortas.
  Future<String> correrYJuntar(
    List<String> accion, {
    bool escribe = false,
    bool conPuerto = true,
    List<String> extras = const [],
    void Function(LineaSeftool)? alVuelo,
  }) async {
    final buf = StringBuffer();
    await for (final l in correr(accion,
        escribe: escribe, conPuerto: conPuerto, extras: extras)) {
      buf.writeln(l.texto);
      alVuelo?.call(l);
    }
    return buf.toString();
  }

  // Trampa 5: \r es salto de línea aquí.
  static Iterable<String> _trocear(String s) =>
      s.split(RegExp(r'[\r\n]+')).where((x) => x.isNotEmpty);

  static final _reBloques = RegExp(
      r'(?:reading|flashing|Reading|Writing)\s+block\D*(\d+)\s*/\s*(\d+)');
  static final _reBytes = RegExp(r'(\d+)\s*/\s*(\d+)\s*bytes');

  static double? _progresoDe(String l) {
    for (final re in [_reBloques, _reBytes]) {
      final m = re.firstMatch(l);
      if (m != null) {
        final a = int.tryParse(m.group(1)!) ?? 0;
        final b = int.tryParse(m.group(2)!) ?? 0;
        if (b > 0) return (a / b).clamp(0.0, 1.0);
      }
    }
    return null;
  }

  // ------------------------------------------------------------------ //
  // Acciones
  // ------------------------------------------------------------------ //

  /// `identify`. Es la primera orden SIEMPRE: si falla, no se toca nada más.
  Future<InfoAparato> identify({void Function(LineaSeftool)? alVuelo}) async {
    if (ensayo) {
      const falsoPorOmision = 'Phone Info (from GDFS):\n'
          'Model: W580i\n'
          'OTP: LOCKED:1 CID:53 PAF:0 IMEI:000000000000000\n'
          'ACTIVE CID:53 COLOR:RED\n'
          'MAPP CXC article: CXC1123362\n'
          'MAPP CXC version: R8BE001\n'
          'SIMLOCKS NOT DETECTED\n'
          'Anycid package: ./anycid/R8BE001_CXC1123362_GENERIC_LA.zip\n';
      final falso = identifyEnsayoStdout ?? falsoPorOmision;
      alVuelo?.call(const LineaSeftool(
          '  [ensayo] identify devuelve un aparato de mentira.'));
      return leerIdentify(falso);
    }
    final txt = await correrYJuntar(['identify'], alVuelo: alVuelo);
    final info = leerIdentify(txt);
    if (info.imei.isEmpty && info.modelo.isEmpty) {
      throw SeftoolError(
        'seftool contestó, pero no reconocí ningún aparato en su salida.',
        remedio: 'Comprueba que el teléfono está APAGADO, con la tecla C '
            'pulsada al enchufar el cable, y que ningún otro programa '
            '(PC Suite, otra SENUS) tiene abierto $puerto.',
      );
    }
    return info;
  }

  /// Parseo del texto de `identify`. Público para poder probarlo sin aparato.
  static InfoAparato leerIdentify(String txt) {
    String g(RegExp r, [int grupo = 1]) =>
        r.firstMatch(txt)?.group(grupo)?.trim() ?? '';

    var anycid = g(RegExp(r'Anycid package:\s*\./anycid/(\S+?)\.zip'));
    // seftool solo imprime esa línea si ./anycid/<paquete>.zip existe junto a
    // él: en una instalación empaquetada (sin anycid/) no sale, aunque el
    // aparato sea perfectamente reconocible. Se deduce igual que seftool
    // (parse_cxc_article_to_anycid_pkg): «R8BE001     prgCXC1123362_GENERIC_LA»
    // → «R8BE001_CXC1123362_GENERIC_LA».
    if (anycid.isEmpty) {
      final m = RegExp(r'MAPP CXC article:\s*(R\S*)\s+prg(\S+)').firstMatch(txt);
      if (m != null) anycid = '${m.group(1)}_${m.group(2)}';
    }
    var version = g(RegExp(r'MAPP CXC version:\s*(\S+)'));
    if (version.isEmpty) version = g(RegExp(r'Default version:\s*(\S+)'));

    return InfoAparato(
      modelo: g(RegExp(r'^Model:\s*(\S+)', multiLine: true)),
      // `[ \t]*`, no `\s*`: con «IMEI:» vacío, `\s*` cruzaba el salto de línea
      // y se llevaba la primera palabra de la línea siguiente («ACTIVE») como
      // si fuera el IMEI, que ahora identifica al aparato en cada orden.
      imei: g(RegExp(r'IMEI:[ \t]*(\S+)')),
      // Trampa 6: «ACTIVE CID:53», sin espacio.
      cidActivo: g(RegExp(r'ACTIVE CID:\s*0*(\d+)')),
      cidOtp: g(RegExp(r'OTP:.*?\bCID:\s*0*(\d+)')),
      color: g(RegExp(r'COLOR:\s*([A-Z]+)')),
      cxcArticulo: g(RegExp(r'MAPP CXC article:\s*(\S+)')),
      cxcVersion: version,
      paqueteAnycid: anycid.isEmpty ? null : anycid,
      simlockDetectado: txt.contains(RegExp(r'^LOCKED$', multiLine: true)),
      crudo: txt,
    );
  }

  /// `read-gdfs`. Devuelve el fichero que seftool dejó en ./backup (trampa 2).
  Future<File> leerGdfs({void Function(LineaSeftool)? alVuelo}) async {
    final antes = _instantanea();
    await correrYJuntar(['read-gdfs'], alVuelo: alVuelo);
    if (ensayo) return _ficheroEnsayo('GDFS_ensayo.bin', 48 * 1024);
    final f = _nuevoEn(antes, RegExp(r'^GDFS_.*\.bin$'));
    if (f == null) {
      throw SeftoolError(
        'read-gdfs terminó sin dejar el volcado donde se esperaba.',
        remedio: 'Debería aparecer un GDFS_*.bin en ${dirBackup.path}',
      );
    }
    return f;
  }

  /// La orden de `read-flash` como (acción, extras); los `extras` van ANTES
  /// de `-a`, que es donde los pone `correr`. En un W580 RED hay que leer por
  /// el exploit: `anycid: true` exige `cid`, el «ACTIVE CID» de `identify`
  /// (seftool se niega sin él antes de mandar ningún loader).
  static ({List<String> accion, List<String> extras}) ordenLeerFlash({
    required int inicio,
    required int tamano,
    bool anycid = false,
    int? cid,
  }) {
    if (anycid && (cid == null || cid <= 0)) {
      throw ArgumentError(
          'read-flash --anycid exige el CID activo del aparato (--cid N)');
    }
    return (
      accion: [
        'read-flash',
        'start',
        '0x${inicio.toRadixString(16).toUpperCase()}',
        'size',
        '0x${tamano.toRadixString(16).toUpperCase()}',
      ],
      extras: [if (anycid) ...['--anycid', '--cid', '$cid']],
    );
  }

  /// Nombre que deja seftool para una ventana (trampa 3), sin el IMEI.
  static RegExp _patronVolcado(int inicio, int tamano) {
    String h8(int v) => v.toRadixString(16).toUpperCase().padLeft(8, '0');
    return RegExp('^flashdump_.*_${h8(inicio)}_${h8(tamano)}\\.bin\$');
  }

  /// `read-flash start <inicio> size <tamaño>` (trampa 3). Devuelve el
  /// volcado de ESA ventana; un `.INCOMPLETO` (lectura a medias) no cuenta.
  Future<File> leerFlash({
    required int inicio,
    required int tamano,
    bool anycid = false,
    int? cid,
    void Function(LineaSeftool)? alVuelo,
  }) async {
    final antes = _instantanea();
    final o = ordenLeerFlash(
        inicio: inicio, tamano: tamano, anycid: anycid, cid: cid);
    await correrYJuntar(o.accion, extras: o.extras, alVuelo: alVuelo);
    if (ensayo) return _ficheroEnsayo('flashdump_ensayo.bin', 64 * 1024);
    final f = _nuevoEn(antes, _patronVolcado(inicio, tamano));
    if (f == null) {
      throw SeftoolError(
        'read-flash terminó sin dejar el volcado donde se esperaba.',
        remedio: 'Debería aparecer un flashdump_*.bin en ${dirBackup.path}',
      );
    }
    return f;
  }

  /// Trampa 4: `flash main` exige BABE. Convierte un .bin crudo y devuelve
  /// la ruta del .ssw resultante.
  Future<String> convertirABabe(String rutaBin, int direccion,
      {void Function(LineaSeftool)? alVuelo}) async {
    final destino = '$rutaBin.ssw';
    if (ensayo) {
      alVuelo?.call(LineaSeftool('  [ensayo] raw2babe $rutaBin -> $destino'));
      return destino;
    }
    if (!File(rutaBin).existsSync()) {
      throw SeftoolError('No existe el binario a grabar:\n  $rutaBin');
    }
    await correrYJuntar([
      'convert',
      'raw2babe',
      rutaBin,
      '0x${direccion.toRadixString(16).toUpperCase()}',
    ], conPuerto: false, alVuelo: alVuelo);
    if (!File(destino).existsSync()) {
      throw SeftoolError('La conversión a BABE no dejó $destino');
    }
    return destino;
  }

  /// `flash main <babe>`. ESCRIBE en la NOR.
  Stream<LineaSeftool> grabarMain(String rutaBabe) =>
      correr(['flash', 'main', rutaBabe], escribe: true);

  /// `write-gdfs <fichero>`. ESCRIBE en el GDFS.
  Stream<LineaSeftool> escribirGdfs(String ruta) =>
      correr(['write-gdfs', ruta], escribe: true);

  /// `upload-anycid`. Sube ./anycid/DB2020.zip + el paquete del firmware al
  /// FFX. No toca la NOR, pero deja ficheros en el teléfono.
  ///
  /// Esta es la forma HEREDADA (la que escribió la rama cable-real sin
  /// aparato): lleva `--anycid`. Para el flujo nuevo, ver [subirAnycidSinFlag].
  Stream<LineaSeftool> subirAnycid() =>
      correr(['upload-anycid'], escribe: true, extras: const ['--anycid']);

  /// `upload-anycid` tal como se PROBÓ EN SILICIO el 2026-10-30:
  /// `-a upload-anycid --imei <IMEI>`, SIN `--anycid`. Con `--anycid` seftool
  /// salta la lectura de la EROM en el loader (loader.c:926), y esa no fue la
  /// ruta que funcionó. Lo usa `InstaladorAnycid`.
  Stream<LineaSeftool> subirAnycidSinFlag() =>
      correr(['upload-anycid'], escribe: true);

  /// `flash-anycid main <babe>`. DB2020 only, ESCRIBE en la NOR por la rama
  /// anycid del bflash. Precondición: `upload-anycid` ya corrió Y el usuario
  /// abrió «Juegos → executer» en el teléfono. Si el executer no está
  /// activo, el fork aborta con «Run executer first» ANTES de tocar NOR.
  ///
  /// `cid` es el «ACTIVE CID» que leyó `identify` (el plan lo guarda). seftool
  /// lo exige: en un DB2020 recién conectado el CID activo todavía no se
  /// conoce, y es lo que permite contrastar con la tabla de senew y con la
  /// cabecera de la imagen ANTES de escribir nada en la NOR.
  Stream<LineaSeftool> grabarMainAnycid(String rutaBabe, int cid) => correr(
      ['flash-anycid', 'main', rutaBabe],
      escribe: true,
      extras: ['--cid', '$cid']);

  // ------------------------------------------------------------------ //

  Set<String> _instantanea() {
    if (ensayo || !dirBackup.existsSync()) return <String>{};
    return dirBackup.listSync().whereType<File>().map((f) => f.path).toSet();
  }

  File? _nuevoEn(Set<String> antes, RegExp patron) {
    if (!dirBackup.existsSync()) return null;
    final candidatos = dirBackup
        .listSync()
        .whereType<File>()
        .where((f) => patron.hasMatch(p.basename(f.path)))
        .toList();
    if (candidatos.isEmpty) return null;
    // Preferimos uno que no estuviera antes; si seftool reescribió el mismo
    // nombre (segunda lectura del GDFS), vale el más reciente.
    final nuevos = candidatos.where((f) => !antes.contains(f.path)).toList();
    final lista = nuevos.isNotEmpty ? nuevos : candidatos;
    lista.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    return lista.first;
  }

  Future<File> _ficheroEnsayo(String nombre, int bytes) async {
    final d = Directory(p.join(Directory.systemTemp.path, 'senus-ensayo'));
    if (!d.existsSync()) d.createSync(recursive: true);
    final f = File(p.join(d.path, nombre));
    await f.writeAsBytes(List<int>.filled(bytes, 0x5A));
    return f;
  }
}

/// Decodificador tolerante: el fork escribe ASCII, pero un byte suelto de una
/// trama no debe tumbar el flujo.
class SystemEncodingDecoder extends Converter<List<int>, String> {
  const SystemEncodingDecoder();
  @override
  String convert(List<int> input) =>
      const Utf8Decoder(allowMalformed: true).convert(input);
  @override
  Sink<List<int>> startChunkedConversion(Sink<String> sink) =>
      _SinkDecodificador(sink);
}

class _SinkDecodificador implements Sink<List<int>> {
  final Sink<String> destino;
  _SinkDecodificador(this.destino);
  @override
  void add(List<int> data) =>
      destino.add(const Utf8Decoder(allowMalformed: true).convert(data));
  @override
  void close() => destino.close();
}
