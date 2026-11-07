// Primera instalación de senew en un W580 por anycid + trampoline + BL installer.
//
// Es el flujo que se probó en silicio el 2026-10-30 (doc canónico:
// el diseño del instalador). SUSTITUYE al de
// `instalacion.dart` («Reemplazo frío por anycid», con qa2020 + bflash + 7
// pasos manuales) y al de `instalacion_inicial.dart` (executor.b propio, que el
// AMS rechaza): ahora hay UN solo paso manual.
//
//   identificar ─ respaldo GDFS ─ upload-anycid ─ [Juegos → eXploit] ─
//   BL installer (1209:0003) ─ main + BL ─ senew (1209:0001)
//
// QUÉ SE SUBE (empotrado, ver `artefactos_instalador.dart`):
//   DB2020.zip              NUESTRO: su executor.jar lleva el trampoline y el BL
//                           installer dentro de cid52/db2020.bin.
//   R8BE001_*_GENERIC_*.zip ORIGINALES de SE (el AMS valida su executor.b,
//                           CAFEB00B). seftool elige el de la región.
//
// REGLAS QUE ESTE FICHERO HACE CUMPLIR:
//  * ROLLBACK (senus-regla-rollback.md): sin un respaldo REAL del GDFS de ESTE
//    aparato (modelo + IMEI), no se sube nada. Si no lo hay, se hace aquí
//    mismo (dos lecturas con sha256) y se avisa al final dónde queda.
//  * macOS y Windows. Linux: «próximamente» (con un ajuste oculto).
//  * Solo lo que se probó: W580 RED CID52, firmware R8BE001. El resto se
//    rechaza con su motivo y queda el camino heredado detrás de
//    SENUS_FLUJO_LEGADO=1.
//  * Sin pantalla no se puede: el único paso manual es abrir un juego.
//
// TRES TRAMPAS PAGADAS el 2026-10-30:
//  1. El `executor.b` que valida el AMS es el ORIGINAL de SE; el código que el
//     exploit JVM ejecuta es cid52/db2020.bin DENTRO del jar. No se toca el .b.
//  2. `--imei` lleva los 14 dígitos del OTP, tal cual los imprime identify
//     (sin el verificador de 15).
//  3. `upload-anycid` va SIN `--anycid` (el flag cambia la ruta del loader).
//
// seftool lee `./anycid/` del directorio de trabajo. Aquí NO se pisa el
// `anycid/` del fork (lo usan el respaldo y el flujo heredado, que necesitan el
// DB2020.zip ORIGINAL de SE): se arma una carpeta temporal con NUESTROS zips y
// enlaces al `loader/`, `rest/` y `backup/` del fork, se lanza seftool allí y se
// borra al terminar.

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../mtp/transporte.dart' show TransporteError;
import 'artefactos_instalador.dart';
import 'cliente_bl_installer.dart';
import 'instalador_driver.dart';
import 'respaldo_rollback.dart';
import 'seftool.dart';
import 'telefono.dart';
import 'transporte_bl.dart';

// VID:PID del DB2020 cuando el teléfono está en modo flash (tecla C + cable).
// Lo usamos para esperar activamente al teléfono antes de lanzar seftool: cada
// orden de seftool apaga el aparato, y entre una y otra la persona lo
// reconecta en modo C; si lanzamos seftool antes de que macOS asiente el
// dispositivo, falla con «no encuentro 0fce:adde» o con un ACCESS transitorio.
const int vidSEMCFlash = 0x0fce;
const int pidSEMCFlash = 0xadde;

// -------------------------------------------------------------------------- //
// Puertas: plataforma y feature flags
// -------------------------------------------------------------------------- //

/// ¿Se puede instalar desde esta plataforma?
class GatePlataforma {
  final bool permitida;

  /// Por qué no (listo para enseñárselo a la persona). Null si se puede.
  final String? motivo;
  const GatePlataforma(this.permitida, [this.motivo]);

  /// Solo macOS está probado en silicio. Linux se puede activar a propósito
  /// con `SENUS_INSTALADOR_LINUX=1` (ajuste oculto: no hay botón). Windows no
  /// tiene driver WinUSB para 0fce:adde ni para 1209:000x todavía.
  static GatePlataforma evaluar({String? sistema, Map<String, String>? env}) {
    final so = sistema ?? Platform.operatingSystem;
    final e = env ?? Platform.environment;
    switch (so) {
      case 'macos':
        return const GatePlataforma(true);
      case 'linux':
        if ((e['SENUS_INSTALADOR_LINUX'] ?? '') == '1') {
          return const GatePlataforma(true);
        }
        return const GatePlataforma(
            false,
            'La instalación de senew en Linux está «próximamente». Hoy solo '
            'funciona en macOS, que es donde se probó en un teléfono real.');
      case 'windows':
        // Windows exige que el aparato lleve el driver WinUSB (Zadig, o el
        // que asigna el instalador): si no, libusb no puede abrirlo. Eso lo
        // detecta el flujo y lo explica (ver `remedioDriverWindows`).
        return const GatePlataforma(true);
      default:
        return GatePlataforma(
            false, 'La instalación de senew no está disponible en «$so».');
    }
  }
}

/// Interruptores para volver a lo heredado mientras no se sepa si el flujo
/// nuevo cubre todos los CID52 R8BE001.
class FlagsInstalacion {
  /// `SENUS_FLUJO_LEGADO=1`: vuelve a ofrecer el «Reemplazo frío por anycid»
  /// (7 pasos manuales) y la pantalla del executor.b propio. Por omisión, no.
  static bool flujoLegado({Map<String, String>? env}) =>
      ((env ?? Platform.environment)['SENUS_FLUJO_LEGADO'] ?? '') == '1';
}

// -------------------------------------------------------------------------- //
// Qué aparatos cubre
// -------------------------------------------------------------------------- //

/// Resultado de mirar si este aparato es de los que cubre el flujo nuevo.
class Aplicabilidad {
  final bool aplica;

  /// true si es exactamente la combinación que se probó en silicio.
  final bool verificadoEnSilicio;

  /// Por qué no aplica (solo si `aplica == false`).
  final String? motivo;

  /// Cosas que la persona tiene que leer antes de empezar.
  final List<String> avisos;
  const Aplicabilidad({
    required this.aplica,
    this.verificadoEnSilicio = false,
    this.motivo,
    this.avisos = const [],
  });
}

/// W580 RED CID52 con firmware R8BE001 y un paquete regional que SENUS trae.
/// Función pura: se prueba sin aparato.
Aplicabilidad evaluarAplicabilidad({
  required String modelo,
  required String cid,
  required String color,
  required String? firmware,
  required String? paquete,
  required ArtefactosW580 artefactos,

  /// false para una mirada previa (la pantalla de conexión no sabe el paquete
  /// regional: lo resuelve seftool al leer el GDFS).
  bool exigirPaquete = true,
}) {
  final m = modelo.toUpperCase();
  if (m != 'W580') {
    return Aplicabilidad(
        aplica: false,
        motivo: 'Este instalador es solo para el W580. Un $m va por otro '
            'camino (DB2010) que SENUS bloquea.');
  }
  if (color.toUpperCase() != 'RED') {
    return Aplicabilidad(
        aplica: false,
        motivo: 'Este W580 es «$color»: el flujo es para los RED (los que '
            'traen el firmware firmado de SE).');
  }
  final c = int.tryParse(cid.trim());
  if (c != 52) {
    return Aplicabilidad(
        aplica: false,
        motivo: c == 53
            ? 'W580 CID 53: el flujo nuevo solo se ha probado en CID 52. Para '
                'CID 53 queda el camino heredado (anycid + payload).'
            : 'W580 con CID «$cid»: el flujo nuevo solo se ha probado en '
                'CID 52.');
  }
  if ((firmware ?? '').toUpperCase() != 'R8BE001') {
    return Aplicabilidad(
        aplica: false,
        motivo: 'Firmware original «${firmware ?? '?'}»: el flujo nuevo solo '
            'cubre R8BE001.');
  }
  if ((exigirPaquete || paquete != null) && !artefactos.traePaquete(paquete)) {
    return Aplicabilidad(
        aplica: false,
        motivo: 'SENUS no trae el paquete de este teléfono '
            '(«${paquete ?? 'desconocido'}»). Trae: '
            '${artefactos.paquetesR8be001.keys.map((k) => k.replaceAll('.zip', '')).join(', ')}.');
  }
  final ver = artefactos.esElVerificado(paquete);
  return Aplicabilidad(
    aplica: true,
    verificadoEnSilicio: ver,
    avisos: [
      if (!ver)
        'Este paquete regional ($paquete) NO se ha probado todavía en un '
            'teléfono; el flujo solo se verificó con '
            '${artefactos.paqueteVerificado ?? 'otro paquete'}. Debería '
            'funcionar igual (el exploit es el mismo), pero no está medido. '
            'El respaldo del GDFS te protege.',
      'No desconectes el cable ni apagues el teléfono mientras SENUS escribe: '
          'son unos 45 segundos.',
    ],
  );
}

// -------------------------------------------------------------------------- //
// Eventos
// -------------------------------------------------------------------------- //

enum FaseInstalador {
  identificar,
  respaldo,
  subirAnycid,
  esperarExploit,
  instalar,
  esperarSenew,
}

String nombreFase(FaseInstalador f) => switch (f) {
      FaseInstalador.identificar => 'Identificar el teléfono',
      FaseInstalador.respaldo => 'Respaldar el GDFS (rollback)',
      FaseInstalador.subirAnycid => 'Subir el instalador al teléfono',
      FaseInstalador.esperarExploit => 'Abrir «Juegos → eXploit» en el teléfono',
      FaseInstalador.instalar => 'Grabar senew',
      FaseInstalador.esperarSenew => 'Esperar a que arranque senew',
    };

enum EstadoFase { corriendo, hecha, aviso, fallida }

/// Pausa humana: la UI enseña título + detalle y completa con true (seguir) o
/// false (cancelar).
class PausaInstalador {
  final Completer<bool> respuesta = Completer<bool>();
  final String titulo;
  final String detalle;

  /// Si no es null, el diálogo ofrece además «Instalar driver USB» para este
  /// aparato (Windows): la pantalla lo instala y la pausa sigue abierta hasta
  /// que la persona pulse Continuar.
  final AccionDriver? accionDriver;
  PausaInstalador(this.titulo, this.detalle, {this.accionDriver});
}

/// Lo que se le enseña a la persona al terminar (regla de rollback).
class ResumenInstalacion {
  final RespaldoRollback respaldo;
  final String? shaGdfsA;
  final String? shaGdfsB;
  final String paquete;
  final bool senewEnElBus;

  /// Texto de «dónde está el respaldo y cómo se vuelve atrás».
  final String textoRollback;
  const ResumenInstalacion({
    required this.respaldo,
    required this.shaGdfsA,
    required this.shaGdfsB,
    required this.paquete,
    required this.senewEnElBus,
    required this.textoRollback,
  });
}

class EventoInstalador {
  final FaseInstalador? fase;
  final EstadoFase? estado;
  final String? log;
  final String? nota;
  final double? progreso;
  final PausaInstalador? pausa;
  final String? error;
  final String? remedio;
  final bool sinBootloader;
  final bool cancelado;
  final ResumenInstalacion? resumen;

  /// Si no es null, la tarjeta de error ofrece «Instalar driver USB».
  final AccionDriver? accionDriver;

  const EventoInstalador._({
    this.fase,
    this.estado,
    this.log,
    this.nota,
    this.progreso,
    this.pausa,
    this.error,
    this.remedio,
    this.sinBootloader = false,
    this.cancelado = false,
    this.resumen,
    this.accionDriver,
  });

  factory EventoInstalador.linea(String s) => EventoInstalador._(log: s);
  factory EventoInstalador.faseEn(FaseInstalador f, EstadoFase e,
          {String? nota}) =>
      EventoInstalador._(fase: f, estado: e, nota: nota);
  factory EventoInstalador.avance(FaseInstalador f, String? nota,
          {double? progreso}) =>
      EventoInstalador._(fase: f, nota: nota, progreso: progreso);
  factory EventoInstalador.pausar(PausaInstalador p) =>
      EventoInstalador._(pausa: p);
  factory EventoInstalador.fallo(FaseInstalador? f, String error,
          {String? remedio,
          bool sinBootloader = false,
          AccionDriver? accionDriver}) =>
      EventoInstalador._(
          fase: f,
          estado: EstadoFase.fallida,
          error: error,
          remedio: remedio,
          sinBootloader: sinBootloader,
          accionDriver: accionDriver);
  factory EventoInstalador.cancelacion(FaseInstalador? f, String donde) =>
      EventoInstalador._(
          fase: f,
          estado: EstadoFase.fallida,
          cancelado: true,
          error: 'Cancelado $donde. No se escribió nada en la NOR.');
  factory EventoInstalador.fin(ResumenInstalacion r) =>
      EventoInstalador._(resumen: r);
}

/// Para el botón «Cancelar» de la pantalla. Se mira en las esperas y entre
/// fases; una orden de seftool a medias no se puede interrumpir.
class CancelacionInstalador {
  bool _c = false;
  bool get cancelado => _c;
  void cancelar() => _c = true;
}

// -------------------------------------------------------------------------- //
// Carpeta de trabajo de seftool con NUESTROS zips
// -------------------------------------------------------------------------- //

/// Una carpeta temporal con `anycid/` propio y enlaces a lo demás del fork.
class AnycidPreparado {
  final Directory dir;
  final Seftool seftool;
  const AnycidPreparado(this.dir, this.seftool);

  /// Borra la carpeta temporal SIN seguir los enlaces (el `loader/` y el
  /// `backup/` del fork no se tocan).
  Future<void> limpiar() async {
    try {
      if (!dir.existsSync()) return;
      for (final e in dir.listSync(followLinks: false)) {
        if (e is Link) {
          e.deleteSync();
        } else if (e is Directory) {
          e.deleteSync(recursive: true);
        } else {
          e.deleteSync();
        }
      }
      dir.deleteSync();
    } catch (_) {
      // Un temporal que no se borra no es motivo para fallar la instalación.
    }
  }
}

/// Monta la carpeta de trabajo: `anycid/{DB2020.zip, R8BE001_*.zip}` salidos de
/// los artefactos empotrados + enlaces al resto del fork.
Future<AnycidPreparado> prepararAnycid(Seftool real, ArtefactosW580 art) async {
  final dir = await Directory.systemTemp.createTemp('senus-anycid-');
  try {
    final anycid = Directory(p.join(dir.path, 'anycid'))..createSync();
    await File(p.join(anycid.path, ArtefactosW580.nombreDb2020))
        .writeAsBytes(art.db2020Zip);
    for (final e in art.paquetesR8be001.entries) {
      await File(p.join(anycid.path, e.key)).writeAsBytes(e.value);
    }
    // seftool resuelve ./loader, ./rest, ./break49 y ./backup relativos al cwd.
    for (final n in const ['loader', 'rest', 'break49', 'backup']) {
      final origen = p.join(real.raiz, n);
      if (Directory(origen).existsSync()) {
        await _enlazarODuplicarDir(p.join(dir.path, n), origen);
      }
    }
    final bin = real.binario;
    if (File(bin).existsSync()) {
      await _enlazarODuplicarFichero(
          p.join(dir.path, Platform.isWindows ? 'seftool.exe' : 'seftool'),
          bin);
    }
    final nuevo = Seftool(
      raiz: dir.path,
      puerto: real.puerto,
      baudios: real.baudios,
      ensayo: real.ensayo,
      identifyEnsayoStdout: real.identifyEnsayoStdout,
    );
    return AnycidPreparado(dir, nuevo);
  } catch (_) {
    await AnycidPreparado(dir, real).limpiar();
    rethrow;
  }
}

/// Enlace simbólico al directorio de [destino]; si el sistema no deja crearlo
/// (en Windows hace falta el modo desarrollador o ser administrador), se
/// DUPLICA el contenido: es solo lectura para seftool (loader/, rest/…) o un
/// directorio de trabajo nuevo (backup/).
Future<void> _enlazarODuplicarDir(String enlace, String destino) async {
  try {
    await Link(enlace).create(destino);
    return;
  } on FileSystemException {
    // sigue: se duplica.
  }
  await Directory(enlace).create(recursive: true);
  await for (final e in Directory(destino).list(recursive: true)) {
    final rel = p.relative(e.path, from: destino);
    if (e is Directory) {
      await Directory(p.join(enlace, rel)).create(recursive: true);
    } else if (e is File) {
      await e.copy(p.join(enlace, rel));
    }
  }
}

Future<void> _enlazarODuplicarFichero(String enlace, String destino) async {
  try {
    await Link(enlace).create(destino);
  } on FileSystemException {
    await File(destino).copy(enlace);
  }
}

/// En Windows, si el teléfono no lleva el driver WinUSB, libusb lo ve pero no
/// puede abrirlo (LIBUSB_ERROR_NOT_SUPPORTED). Devuelve el remedio, o null.
String? remedioDriverWindows(Iterable<String> lineas,
    {String? aparato, bool? esWindows}) {
  if (!(esWindows ?? Platform.isWindows)) return null;
  final t = lineas.join('\n');
  if (!t.contains('NOT_SUPPORTED') && !t.contains('LIBUSB_ERROR_NOT_FOUND')) {
    return null;
  }
  return 'Windows no tiene el driver WinUSB asignado a '
      '${aparato ?? '«SEMC USB Flash» (0fce:adde)'}. Con el teléfono en modo C, '
      'pulsa «Instalar driver USB» y acepta el aviso de permisos de Windows. '
      'Se hace una sola vez. (A mano, con Zadig: Options → List All Devices, '
      'elige «SEMC USB Flash», pon WinUSB y pulsa Install Driver.)';
}

/// Windows (solo lectura): ¿hay un «SEMC USB Flash» (0fce:adde) presente para
/// el sistema? libusb solo lista los aparatos con driver WinUSB, así que un
/// teléfono SIN driver (error 28 en el Administrador de dispositivos) es
/// invisible para ella pero Windows sí lo ve: ese es el caso de «falta Zadig».
Future<bool> windowsVeTelefonoEnModoFlash() async {
  if (!Platform.isWindows) return false;
  try {
    final r = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      r"@(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | "
          r"Where-Object { $_.InstanceId -like 'USB\VID_0FCE&PID_ADDE*' }).Count",
    ]);
    return (int.tryParse('${r.stdout}'.trim()) ?? 0) > 0;
  } catch (_) {
    return false;
  }
}

// -------------------------------------------------------------------------- //
// El flujo
// -------------------------------------------------------------------------- //

class _Caja<T> {
  T? valor;
  bool cancelado = false;
  bool fallo = false;
}

class InstaladorAnycid {
  /// El aparato que la pantalla de conexión ya conoce (serie = IMEI). Sirve
  /// para encontrar su respaldo sin gastar una sesión de seftool.
  final Telefono? telefono;
  final Seftool Function() fabricaSeftool;
  final AlmacenRespaldos almacen;
  final FuenteArtefactos fuente;

  /// Los artefactos ya leídos y comprobados (la pantalla los carga al abrirse
  /// para enseñar el resumen). Null → se leen y se comprueban aquí.
  final ArtefactosW580? artefactos;
  final TransporteBl Function(int pid) fabricaBl;

  /// Fábrica de transporte para enumerar el teléfono en MODO FLASH
  /// (0fce:adde). Los tests pueden inyectar uno que diga «ya está» de
  /// inmediato; en producción se abre uno con libusb. Si devuelve null, el
  /// instalador no espera y lanza seftool directamente (modo ensayo).
  final TransporteBl? Function()? fabricaBlModoC;

  /// ¿Windows ve el teléfono en modo flash aunque libusb no? (sin driver
  /// WinUSB). Por omisión consulta el sistema; los tests lo inyectan.
  final Future<bool> Function()? windowsVeSinDriver;

  /// El instalador/inspector del driver USB de Windows (PnP). Por omisión el
  /// de verdad; los tests inyectan uno simulado.
  final InstaladorDriverUsb? driverUsb;

  /// Cuánto se espera a ver 0fce:adde tras una reconexión.
  final Duration esperaModoC;
  final CancelacionInstalador cancelacion;

  /// Casilla de la pantalla: «mi teléfono tiene pantalla y SIM». Sin ella no
  /// se empieza (el paso del exploit es abrir un juego).
  final bool confirmaPantalla;

  /// Casilla de la pantalla para un paquete regional no probado en silicio.
  final bool aceptaNoVerificado;

  /// Inyectables para las pruebas.
  final String? sistema;
  final Map<String, String>? env;
  final Duration esperaExploit;
  final Duration esperaSenew;
  final Duration intervalo;
  final Duration sondeoBl;

  InstaladorAnycid({
    this.telefono,
    required this.fabricaSeftool,
    required this.almacen,
    required this.fuente,
    this.artefactos,
    TransporteBl Function(int pid)? fabricaBl,
    this.fabricaBlModoC,
    this.windowsVeSinDriver,
    this.driverUsb,
    this.esperaModoC = const Duration(seconds: 20),
    CancelacionInstalador? cancelacion,
    this.confirmaPantalla = false,
    this.aceptaNoVerificado = false,
    this.sistema,
    this.env,
    this.esperaExploit = const Duration(minutes: 5),
    this.esperaSenew = const Duration(seconds: 90),
    this.intervalo = const Duration(milliseconds: 500),
    this.sondeoBl = const Duration(milliseconds: 50),
  })  : fabricaBl = fabricaBl ??
            ((pid) => TransporteBl.elegir(vid: vidSenew, pid: pid)),
        cancelacion = cancelacion ?? CancelacionInstalador();

  /// Todas las fases, de punta a punta.
  Stream<EventoInstalador> correr() async* {
    // ---- 0. Puertas que no necesitan el aparato.
    final g = GatePlataforma.evaluar(sistema: sistema, env: env);
    if (!g.permitida) {
      yield EventoInstalador.fallo(null, g.motivo!);
      return;
    }
    if (!confirmaPantalla) {
      yield EventoInstalador.fallo(
          null,
          'Falta confirmar que el teléfono tiene pantalla y SIM.',
          remedio: 'El único paso manual es abrir «Juegos → eXploit» en el '
              'teléfono: sin pantalla no se puede. Un W580 sin pantalla '
              'queda fuera de este flujo.');
      return;
    }
    final ArtefactosW580 art;
    try {
      art = artefactos ?? await ArtefactosW580.cargar(fuente);
    } on ArtefactosError catch (e) {
      yield EventoInstalador.fallo(null, e.motivo, remedio: e.remedio);
      return;
    }
    yield EventoInstalador.linea(
        'Instalador empotrado verificado: ${art.sha256Por.length} ficheros '
        '(main ${art.main.length} B, BL ${art.blClasico.length} B, '
        '${art.paquetesR8be001.length} paquetes R8BE001).');

    final sef = fabricaSeftool();
    try {
      sef.exigirBinario();
    } on SeftoolError catch (e) {
      yield EventoInstalador.fallo(null, e.motivo, remedio: e.remedio);
      return;
    }
    if (sef.puerto.isEmpty) {
      yield EventoInstalador.fallo(
          null, 'No hay ningún puerto USB/serie a la vista.',
          remedio: 'Enchufa el cable con el teléfono en modo C.');
      return;
    }
    yield EventoInstalador.linea(
        'seftool: ${sef.binario} · puerto ${sef.puerto}'
        '${sef.ensayo ? ' · ENSAYO (no se ejecuta nada)' : ''}');

    // ---- 1. Identificar (o tomarlo del respaldo) + 2. Respaldo.
    final datos = _Caja<_DatosAparato>();
    yield* _identificarYRespaldar(sef, art, datos);
    if (datos.cancelado || datos.fallo || datos.valor == null) return;
    final d = datos.valor!;

    // ---- 3. upload-anycid
    if (cancelacion.cancelado) {
      yield EventoInstalador.cancelacion(
          FaseInstalador.subirAnycid, 'antes de subir el instalador');
      return;
    }
    final ok = _Caja<bool>();
    yield* _subirAnycid(sef, art, d, ok);
    if (ok.cancelado || ok.fallo) return;

    // ---- 4. El paso manual + 5. instalar + 6. senew
    final bl = _Caja<TransporteBl>();
    yield* _esperarExploit(bl);
    if (bl.cancelado || bl.fallo || bl.valor == null) return;

    final fin = _Caja<bool>();
    yield* _instalar(bl.valor!, art, d, fin);
    if (fin.fallo) return;

    final llego = _Caja<bool>();
    yield* _esperarSenew(llego);
    if (llego.cancelado) return;

    yield EventoInstalador.fin(ResumenInstalacion(
      respaldo: d.respaldo,
      shaGdfsA: await d.respaldo.shaGdfsAResuelto(),
      shaGdfsB: await d.respaldo.shaGdfsBResuelto(),
      paquete: d.paquete ?? '',
      senewEnElBus: llego.valor == true,
      textoRollback: textoRollback(d.respaldo),
    ));
  }

  // ---------------------------------------------------------------------- //
  // 1 + 2: identificar y respaldar
  // ---------------------------------------------------------------------- //

  Stream<EventoInstalador> _identificarYRespaldar(
      Seftool sef, ArtefactosW580 art, _Caja<_DatosAparato> out) async* {
    const f1 = FaseInstalador.identificar;
    const f2 = FaseInstalador.respaldo;

    // ¿Ya hay un respaldo válido de ESTE aparato? Se busca por el IMEI que la
    // pantalla de conexión ya leyó; así no se gasta otra sesión en identify.
    RespaldoRollback? resp;
    final imeiConocido = telefono?.serie ?? '';
    if (imeiConocido.isNotEmpty && Seftool.imeiValido(imeiConocido)) {
      resp = await buscarRespaldoValido(almacen, 'W580', imeiConocido);
    }

    if (resp != null) {
      yield EventoInstalador.faseEn(f1, EstadoFase.corriendo,
          nota: 'Datos tomados del respaldo existente');
      final a = evaluarAplicabilidad(
        modelo: resp.modelo,
        cid: resp.cid ?? '',
        color: resp.color ?? '',
        firmware: resp.firmwareOriginal,
        paquete: resp.paqueteAnycid,
        artefactos: art,
      );
      if (!a.aplica) {
        yield EventoInstalador.fallo(f1, a.motivo!);
        out.fallo = true;
        return;
      }
      if (!a.verificadoEnSilicio && !aceptaNoVerificado) {
        yield EventoInstalador.fallo(f1, a.avisos.first,
            remedio: 'Marca la casilla que acepta un paquete no probado '
                'para continuar.');
        out.fallo = true;
        return;
      }
      sef.imeiEsperado = resp.serie;
      yield EventoInstalador.faseEn(f1, EstadoFase.hecha,
          nota: 'W580 · CID ${resp.cid} · ${resp.paqueteAnycid ?? resp.firmwareOriginal}');
      yield EventoInstalador.faseEn(f2, EstadoFase.hecha,
          nota: 'Respaldo ya hecho: ${resp.carpeta}');
      out.valor = _DatosAparato(resp, resp.paqueteAnycid, resp.serie);
      return;
    }

    // No hay respaldo: identify + GDFS dos veces.
    yield EventoInstalador.faseEn(f1, EstadoFase.corriendo);
    final pide = PausaInstalador(
        tituloReconectar,
        detalleReconectar(
            cierre: 'para identificar el teléfono',
            alCancelar: 'no se lee ni se escribe nada.'));
    yield EventoInstalador.pausar(pide);
    if (!await pide.respuesta.future || cancelacion.cancelado) {
      yield EventoInstalador.cancelacion(f1, 'antes de identificar');
      out.cancelado = true;
      return;
    }
    if (!sef.ensayo) {
      final v = _Caja<bool>();
      yield* _asegurarModoC(
          f1,
          'Comprueba que lo apagaste, mantén C mientras enchufas '
          'el cable, y pulsa Repetir.',
          v);
      if (v.cancelado || v.fallo) {
        out.cancelado = v.cancelado;
        out.fallo = v.fallo;
        return;
      }
    }
    final InfoAparato ide;
    final cola = <String>[];
    try {
      ide = await sef.identify(alVuelo: (l) => cola.add(l.texto));
      for (final l in cola) {
        yield EventoInstalador.linea(l);
      }
    } on SeftoolError catch (e) {
      // Volcar lo que haya dicho seftool ANTES del error: sin esto, el panel
      // Registro no muestra la causa real (p. ej. «no encuentro 0fce:adde»).
      for (final l in cola) {
        yield EventoInstalador.linea(l);
      }
      final rd = remedioDriverWindows(cola);
      yield EventoInstalador.fallo(f1, e.motivo,
          remedio: rd ?? e.remedio,
          accionDriver: rd == null ? null : AccionDriver.modoFlash);
      out.fallo = true;
      return;
    }
    final a = evaluarAplicabilidad(
      modelo: ide.modeloCorto,
      cid: ide.cid,
      color: ide.color,
      firmware: ide.cxcVersion,
      paquete: ide.paqueteAnycid,
      artefactos: art,
    );
    if (!a.aplica) {
      yield EventoInstalador.fallo(f1, a.motivo!);
      out.fallo = true;
      return;
    }
    if (!a.verificadoEnSilicio && !aceptaNoVerificado) {
      yield EventoInstalador.fallo(f1, a.avisos.first,
          remedio: 'Marca la casilla que acepta un paquete no probado para '
              'continuar.');
      out.fallo = true;
      return;
    }
    if (!Seftool.imeiValido(ide.imei)) {
      yield EventoInstalador.fallo(f1,
          'identify no dio un IMEI utilizable («${ide.imei}»): sin él no se '
          'puede comprobar que el teléfono es el mismo en cada paso.');
      out.fallo = true;
      return;
    }
    sef.imeiEsperado = ide.imei;
    yield EventoInstalador.faseEn(f1, EstadoFase.hecha,
        nota: '${ide.modeloCorto} · IMEI ${ide.imei} · CID ${ide.cid} · '
            '${ide.paqueteAnycid}');

    // GDFS por duplicado (REGLA INVIOLABLE).
    yield EventoInstalador.faseEn(f2, EstadoFase.corriendo,
        nota: 'No hay respaldo de este aparato: se hace ahora');
    final dir = await almacen.abrirCarpeta(ide.modeloCorto, ide.imei);
    yield EventoInstalador.linea('Carpeta de respaldo: ${dir.path}');
    final shas = <String>[];
    for (final cual in const ['A', 'B']) {
      final pausa = PausaInstalador(
          tituloReconectar,
          detalleReconectar(
              cierre: 'para leer el GDFS (copia $cual)',
              alCancelar: 'el respaldo NO se completa ni se registra.'));
      yield EventoInstalador.pausar(pausa);
      if (!await pausa.respuesta.future || cancelacion.cancelado) {
        yield EventoInstalador.cancelacion(f2, 'antes de leer el GDFS');
        out.cancelado = true;
        return;
      }
      if (!sef.ensayo) {
        final v = _Caja<bool>();
        yield* _asegurarModoC(
            f2,
            'La orden anterior lo apagó; apágalo del todo, mantén '
            'C y enchufa el cable, y pulsa Repetir.',
            v);
        if (v.cancelado || v.fallo) {
          out.cancelado = v.cancelado;
          out.fallo = v.fallo;
          return;
        }
      }
      final cola = <String>[];
      try {
        final origen = await sef.leerGdfs(alVuelo: (l) => cola.add(l.texto));
        for (final l in cola) {
          yield EventoInstalador.linea(l);
        }
        final destino = File(p.join(dir.path, 'gdfs_$cual.bin'));
        await origen.copy(destino.path);
        final sha = sha256.convert(await destino.readAsBytes()).toString();
        await File(p.join(dir.path, 'gdfs_$cual.sha256'))
            .writeAsString('$sha  gdfs_$cual.bin\n');
        shas.add(sha);
        yield EventoInstalador.linea(
            '  GDFS $cual: ${destino.lengthSync()} B · sha256 $sha');
      } on SeftoolError catch (e) {
        for (final l in cola) {
          yield EventoInstalador.linea(l);
        }
        final rd = remedioDriverWindows(cola);
        yield EventoInstalador.fallo(f2, e.motivo,
            remedio: rd ?? e.remedio,
            accionDriver: rd == null ? null : AccionDriver.modoFlash);
        out.fallo = true;
        return;
      }
    }
    if (shas[0] != shas[1]) {
      yield EventoInstalador.fallo(
          f2, 'Las dos lecturas del GDFS no coinciden.',
          remedio: 'Un volcado que cambia entre lecturas no es de fiar. No '
              'se instala nada; repite el respaldo con el cable bien '
              'conectado.');
      out.fallo = true;
      return;
    }
    await File(p.join(dir.path, 'identify.txt')).writeAsString(ide.crudo);
    final r = RespaldoRollback(
      carpeta: dir.path,
      modelo: ide.modeloCorto,
      serie: ide.imei,
      fecha: DateTime.now(),
      cid: ide.cid,
      color: ide.color,
      firmwareOriginal: ide.cxcVersion,
      // Sin volcado de la NOR: en un RED CID52 leerla exige el ritual del
      // executer, justo lo que este flujo sustituye. El rollback es el GDFS
      // + el main original de SE (documento técnico §8).
      shaFlash: '',
      bytesFlash: 0,
      // Un ensayo no tocó ningún aparato: su «respaldo» no desbloquea nada
      // real (ver la guarda del transporte USB en `_instalar`).
      simulado: sef.ensayo,
      cxcArticulo: ide.cxcArticulo,
      paqueteAnycid: ide.paqueteAnycid,
      shaGdfsA: shas[0],
      shaGdfsB: shas[1],
    );
    await almacen.registrar(r);
    yield EventoInstalador.linea('metadatos.json escrito en ${r.rutaMetadatos}');
    yield EventoInstalador.faseEn(f2, EstadoFase.hecha,
        nota: 'GDFS ×2 · sha256 ${shas[0].substring(0, 16)}…');
    out.valor = _DatosAparato(r, ide.paqueteAnycid, ide.imei);
  }

  // ---------------------------------------------------------------------- //
  // 3: upload-anycid
  // ---------------------------------------------------------------------- //

  Stream<EventoInstalador> _subirAnycid(Seftool real, ArtefactosW580 art,
      _DatosAparato d, _Caja<bool> out) async* {
    const f = FaseInstalador.subirAnycid;
    yield EventoInstalador.faseEn(f, EstadoFase.corriendo);
    final pausa = PausaInstalador(
        tituloReconectar,
        detalleReconectar(
            cierre: 'para subir el instalador',
            alCancelar: 'no se sube nada; el respaldo ya hecho se conserva.'));
    yield EventoInstalador.pausar(pausa);
    if (!await pausa.respuesta.future || cancelacion.cancelado) {
      yield EventoInstalador.cancelacion(f, 'antes de subir el instalador');
      out.cancelado = true;
      return;
    }
    if (!real.ensayo) {
      final v = _Caja<bool>();
      yield* _asegurarModoC(
          f,
          'Apágalo del todo, mantén C mientras enchufas el cable, '
          'y pulsa Repetir.',
          v);
      if (v.cancelado || v.fallo) {
        out.cancelado = v.cancelado;
        out.fallo = v.fallo;
        return;
      }
    }

    final prep = await prepararAnycid(real, art);
    try {
      prep.seftool.imeiEsperado = d.imei;
      var terminoBien = false;
      var fsx = false;
      var error29 = false;
      String? paqueteSubido;
      final lineasUp = <String>[];
      try {
        await for (final l in prep.seftool.subirAnycidSinFlag()) {
          yield EventoInstalador.linea(l.texto);
          final t = l.texto;
          lineasUp.add(t);
          final m = RegExp(r'Uploading package:\s*\./anycid/(\S+?)\.zip')
              .firstMatch(t);
          if (m != null) paqueteSubido = m.group(1);
          if (t.contains('Starting FSX server') && t.contains('started')) {
            fsx = true;
          }
          if (RegExp(r'error:?\s*29').hasMatch(t) ||
              t.contains('refused to start')) {
            error29 = true;
          }
          if (t.contains('Turn on the phone with simcard installed')) {
            terminoBien = true;
          }
        }
      } on SeftoolError catch (e) {
        final rd = remedioDriverWindows(lineasUp);
        yield EventoInstalador.fallo(f, e.motivo,
            remedio: rd ??
                e.remedio ??
                'No se escribió nada en la NOR. Reconecta el teléfono en modo '
                    'C y vuelve a intentarlo.',
            accionDriver: rd == null ? null : AccionDriver.modoFlash);
        out.fallo = true;
        return;
      }
      if (!real.ensayo) {
        if (error29 || (!terminoBien && !fsx)) {
          yield EventoInstalador.fallo(
              f, 'El CS loader no arrancó sus servicios al subir el instalador.',
              remedio: 'No se escribió nada en la NOR. Reconecta el teléfono '
                  'en modo C y vuelve a intentarlo.');
          out.fallo = true;
          return;
        }
        if (paqueteSubido != null &&
            d.paquete != null &&
            paqueteSubido != d.paquete) {
          yield EventoInstalador.linea(
              'AVISO: seftool subió $paqueteSubido y el respaldo decía '
              '${d.paquete}.');
        }
      }
      yield EventoInstalador.faseEn(f, EstadoFase.hecha,
          nota: paqueteSubido ?? d.paquete);
    } finally {
      await prep.limpiar();
    }
  }

  // ---------------------------------------------------------------------- //
  // 4: el único paso manual — esperar a 1209:0003
  // ---------------------------------------------------------------------- //

  Stream<EventoInstalador> _esperarExploit(_Caja<TransporteBl> out) async* {
    const f = FaseInstalador.esperarExploit;
    yield EventoInstalador.faseEn(f, EstadoFase.corriendo,
        nota: 'Enciende el teléfono con SIM, abre Juegos → eXploit y córrelo.');
    final bl = fabricaBl(pidBlInstaller);
    final t0 = DateTime.now();
    final fin = t0.add(esperaExploit);
    var vistoEn = -1;
    var ultimaPregunta = t0;
    var pausasDeDriver = 0;
    while (DateTime.now().isBefore(fin)) {
      if (cancelacion.cancelado) {
        yield EventoInstalador.cancelacion(f, 'esperando el eXploit');
        out.cancelado = true;
        return;
      }
      try {
        final vistos = await bl.enumerar();
        if (vistos.isNotEmpty) {
          vistoEn = DateTime.now().difference(t0).inSeconds;
          break;
        }
      } on TransporteError catch (e) {
        yield EventoInstalador.fallo(f, 'No pude mirar el bus USB: ${e.motivo}');
        out.fallo = true;
        return;
      }
      // Windows: libusb NO lista un aparato sin driver WinUSB, así que el
      // bootloader puede estar ya corriendo y SENUS sin verlo. Cada 3 s se
      // pregunta al sistema; si lo ve sin driver, se ofrece instalarlo.
      if (_esWindows &&
          pausasDeDriver < 3 &&
          DateTime.now().difference(ultimaPregunta) >=
              (intervalo * 6 > const Duration(seconds: 3)
                  ? const Duration(seconds: 3)
                  : intervalo * 6)) {
        ultimaPregunta = DateTime.now();
        final est = await (driverUsb ?? InstaladorDriverUsb())
            .estado(AccionDriver.bootloaderInstaller);
        if (est == EstadoDriver.sinDriver) {
          pausasDeDriver++;
          final pausa = PausaInstalador(
            'Falta el driver USB del bootloader',
            'El teléfono ya corre el instalador (1209:0003) pero Windows no le '
                'puso el driver WinUSB, y SENUS no puede verlo. NO lo '
                'desconectes ni lo apagues: pulsa «Instalar driver USB», acepta '
                'el aviso de permisos de Windows y, cuando termine, pulsa '
                'Continuar.',
            accionDriver: AccionDriver.bootloaderInstaller,
          );
          yield EventoInstalador.pausar(pausa);
          if (!await pausa.respuesta.future || cancelacion.cancelado) {
            yield EventoInstalador.cancelacion(f, 'sin instalar el driver USB');
            out.cancelado = true;
            return;
          }
          continue; // vuelve a buscarlo (ya con driver)
        }
      }
      final s = DateTime.now().difference(t0).inSeconds;
      if (s % 5 == 0) {
        yield EventoInstalador.avance(f,
            'Esperando al bootloader 1209:0003… ${s}s. Si ya lo ejecutaste '
            'y no pasa nada, desenchufa y vuelve a enchufar el cable USB.');
      }
      await Future<void>.delayed(intervalo);
    }
    if (vistoEn < 0) {
      yield EventoInstalador.fallo(f,
          'No veo el bootloader (1209:0003) tras ${esperaExploit.inSeconds} s.',
          remedio: 'Comprueba que el teléfono encendió con SIM y que '
              '«Juegos → eXploit» llegó a correr (el MIDlet no pide nada: '
              'al abrirlo, la pantalla cambia). El instalador sigue subido: '
              'puedes reintentar desde este paso.');
      out.fallo = true;
      return;
    }
    // Abrir con reintentos: justo al aparecer, macOS a veces devuelve ACCESS.
    // En Windows, un NOT_SUPPORTED/NOT_FOUND es «falta WinUSB»: se ofrece
    // instalarlo y se reintenta (el bootloader sigue vivo mientras tanto).
    Object? ultimo;
    for (var ronda = 0; ronda < 3; ronda++) {
      ultimo = null;
      for (var i = 0; i < 10; i++) {
        try {
          final vistos = await bl.enumerar();
          if (vistos.isEmpty) {
            throw TransporteError('el BL ya no está en el bus');
          }
          await bl.abrir(vistos.first);
          ultimo = null;
          break;
        } on TransporteError catch (e) {
          ultimo = e;
          await Future<void>.delayed(intervalo);
        }
      }
      final sinDriver = _esWindows &&
          ultimo is TransporteError &&
          (ultimo.codigo == -12 || ultimo.codigo == -5);
      if (ultimo == null || !sinDriver) break;
      final pausa = PausaInstalador(
        'Falta el driver USB del bootloader',
        'El teléfono ya corre el instalador (1209:0003) pero Windows no le '
            'puso el driver WinUSB. NO lo desconectes ni lo apagues: pulsa '
            '«Instalar driver USB», acepta el aviso de permisos de Windows y, '
            'cuando termine, pulsa Continuar.',
        accionDriver: AccionDriver.bootloaderInstaller,
      );
      yield EventoInstalador.pausar(pausa);
      if (!await pausa.respuesta.future || cancelacion.cancelado) {
        yield EventoInstalador.cancelacion(f, 'sin instalar el driver USB');
        out.cancelado = true;
        return;
      }
    }
    if (ultimo != null) {
      final sinDriver = Platform.isWindows &&
          ultimo is TransporteError &&
          (ultimo.codigo == -12 || ultimo.codigo == -5);
      yield EventoInstalador.fallo(f, 'No pude abrir el bootloader: $ultimo',
          remedio: sinDriver
              ? remedioDriverWindows(['NOT_SUPPORTED'],
                  aparato: 'el bootloader (1209:0003)')
              : 'En macOS no hace falta ningún permiso especial para '
                  'libusb; si falla, desenchufa y vuelve a enchufar el cable.');
      out.fallo = true;
      return;
    }
    yield EventoInstalador.faseEn(f, EstadoFase.hecha,
        nota: 'Bootloader en el bus (1209:0003) tras ${vistoEn}s');
    out.valor = bl;
  }

  // ---------------------------------------------------------------------- //
  // 5: wipe/write main + wipe/write BL
  // ---------------------------------------------------------------------- //

  Stream<EventoInstalador> _instalar(TransporteBl bl, ArtefactosW580 art,
      _DatosAparato d, _Caja<bool> out) async* {
    const f = FaseInstalador.instalar;
    yield EventoInstalador.faseEn(f, EstadoFase.corriendo,
        nota: 'No desconectes el cable ni apagues el teléfono.');

    // Guarda de la regla de rollback: un «respaldo» de ensayo/simulado no
    // desbloquea escribir en un aparato de verdad.
    if (d.respaldo.simulado && bl is TransporteBlLibusb) {
      yield EventoInstalador.fallo(f,
          'El respaldo es de ensayo o simulado y el teléfono es de verdad.',
          remedio: 'Rehaz el respaldo con el teléfono conectado antes de '
              'instalar (regla de rollback). No se escribió nada.');
      out.fallo = true;
      await bl.cerrar();
      return;
    }

    final cliente = ClienteBlInstaller(bl, sondeo: sondeoBl);
    final c = StreamController<EventoInstalador>();
    final trabajo = () async {
      try {
        await cliente.instalar(
          main: art.main,
          blClasico: art.blClasico,
          alLog: (s) => c.add(EventoInstalador.linea(s)),
          alProgreso: (etapa, hecho, total) => c.add(EventoInstalador.avance(
              f, nombreEtapaBl(etapa),
              progreso: total > 0 ? hecho / total : null)),
        );
      } catch (e, st) {
        c.addError(e, st);
      } finally {
        await c.close();
      }
    }();
    try {
      await for (final ev in c.stream) {
        yield ev;
      }
    } on InstaladorBlError catch (e) {
      yield EventoInstalador.fallo(f, e.motivo,
          remedio: e.remedio, sinBootloader: e.sinBootloader);
      out.fallo = true;
    } on TransporteError catch (e) {
      yield EventoInstalador.fallo(f, 'USB: ${e.motivo}',
          remedio: 'Se cortó la comunicación con el teléfono. Si ya habías '
              'pasado el borrado, NO lo apagues: vuelve a ejecutar '
              '«Juegos → eXploit» y reintenta.',
          sinBootloader: true);
      out.fallo = true;
    } catch (e) {
      yield EventoInstalador.fallo(f, 'Error inesperado al grabar: $e',
          remedio: 'No apagues el teléfono; desconecta y vuelve a enchufar el '
              'cable y reintenta desde «Juegos → eXploit».',
          sinBootloader: true);
      out.fallo = true;
    } finally {
      await trabajo;
      try {
        await bl.cerrar();
      } catch (_) {}
    }
    if (out.fallo) return;
    yield EventoInstalador.faseEn(f, EstadoFase.hecha,
        nota: 'senew grabado y verificado (CRC-32)');
    out.valor = true;
  }

  // ---------------------------------------------------------------------- //
  // 6: esperar a senew
  // ---------------------------------------------------------------------- //

  Stream<EventoInstalador> _esperarSenew(_Caja<bool> out) async* {
    const f = FaseInstalador.esperarSenew;
    yield EventoInstalador.faseEn(f, EstadoFase.corriendo,
        nota: 'El teléfono arranca solo; puede tardar hasta '
            '${esperaSenew.inSeconds} s.');
    final t0 = DateTime.now();
    final fin = t0.add(esperaSenew);
    final sen = fabricaBl(pidSenewNormal);
    while (DateTime.now().isBefore(fin)) {
      if (cancelacion.cancelado) {
        // Ya está instalado y verificado: cancelar aquí solo deja de esperar.
        out.cancelado = false;
        break;
      }
      try {
        var visto = (await sen.enumerar()).isNotEmpty;
        // Windows: senew (1209:0001) no lleva WinUSB todavía y libusb no lo
        // lista; para saber que arrancó basta con que el sistema lo vea.
        if (!visto && _esWindows) {
          visto = await (driverUsb ?? InstaladorDriverUsb())
                  .estado(AccionDriver.senew) !=
              EstadoDriver.ausente;
        }
        if (visto) {
          out.valor = true;
          yield EventoInstalador.faseEn(f, EstadoFase.hecha,
              nota: 'senew en el bus (1209:0001)');
          return;
        }
      } on TransporteError {
        // El bus puede quedarse sin respuesta un instante al reiniciar.
      }
      final s = DateTime.now().difference(t0).inSeconds;
      if (s % 5 == 0) {
        yield EventoInstalador.avance(f, 'Esperando a senew… ${s}s');
      }
      await Future<void>.delayed(intervalo);
    }
    out.valor = false;
    yield EventoInstalador.faseEn(f, EstadoFase.aviso,
        nota: 'No lo veo en USB todavía, pero senew quedó grabado y '
            'verificado. Mira la pantalla del teléfono; si no arrancó, apágalo '
            'y enciéndelo.');
  }

  /// Espera a que el teléfono vuelva al bus USB en modo flash (0fce:adde) tras
  /// una reconexión. Devuelve los segundos que tardó en aparecer, o un número
  /// negativo si se agotó el tiempo. Da tiempo a macOS a enumerar el aparato
  /// recién enchufado — sin esta espera, seftool se adelanta y falla con
  /// «no encuentro 0fce:adde» o LIBUSB_ERROR_ACCESS transitorio.
  Future<int> _esperarEnModoC() async {
    final timeout = esperaModoC;
    // Transporte para enumerar 0fce:adde. En producción es libusb con VID
    // propio; en los tests, lo que inyecte quien construya el instalador. Si
    // no hay (p. ej. en modo ensayo en una máquina sin libusb), devolvemos 0
    // para no bloquear.
    final TransporteBl? bl;
    try {
      bl = fabricaBlModoC != null
          ? fabricaBlModoC!()
          : TransporteBl.elegir(vid: vidSEMCFlash, pid: pidSEMCFlash);
    } catch (_) {
      return 0;
    }
    if (bl == null) return 0;
    final t0 = DateTime.now();
    final fin = t0.add(timeout);
    // En Windows, pasada la sexta parte de la espera sin que libusb lo vea,
    // se pregunta al sistema: si LO VE, es que le falta el driver WinUSB y no
    // tiene sentido seguir esperando 20 s.
    final aviso = t0.add(Duration(milliseconds: timeout.inMilliseconds ~/ 6));
    var preguntado = false;
    while (DateTime.now().isBefore(fin)) {
      if (cancelacion.cancelado) return -1;
      try {
        if ((await bl.enumerar()).isNotEmpty) {
          return DateTime.now().difference(t0).inSeconds;
        }
      } catch (_) {
        // Enumerar puede fallar en transitorios; seguimos esperando.
      }
      if (_esWindows && !preguntado && DateTime.now().isAfter(aviso)) {
        preguntado = true;
        if (await (windowsVeSinDriver ?? windowsVeTelefonoEnModoFlash)()) {
          return -2;
        }
      }
      await Future<void>.delayed(intervalo);
    }
    return -1;
  }

  bool get _esWindows => (sistema ?? Platform.operatingSystem) == 'windows';

  /// Espera a ver el teléfono en modo C. Si en Windows lo ve el sistema pero
  /// no libusb (falta WinUSB), NO falla: abre una pausa con el botón «Instalar
  /// driver USB» y, al continuar, vuelve a esperar (hasta 3 veces). Deja en
  /// [out] el resultado: `valor == true` visto; `cancelado`; `fallo`.
  Stream<EventoInstalador> _asegurarModoC(
      FaseInstalador f, String remedioPorOmision, _Caja<bool> out) async* {
    yield EventoInstalador.linea(
        'Esperando al teléfono en modo flash (0fce:adde)…');
    var ultimoCodigo = -1;
    for (var intento = 0; intento < 3; intento++) {
      final vistoEn = await _esperarEnModoC();
      ultimoCodigo = vistoEn;
      if (vistoEn >= 0) {
        yield EventoInstalador.linea('  teléfono visto en el bus (${vistoEn}s)');
        out.valor = true;
        return;
      }
      if (vistoEn == -1 && cancelacion.cancelado) {
        yield EventoInstalador.cancelacion(f, 'esperando el modo C');
        out.cancelado = true;
        return;
      }
      if (vistoEn == -2) {
        final pausa = PausaInstalador(
          'Falta el driver USB del teléfono',
          'Windows ve el «SEMC USB Flash», pero no lleva el driver WinUSB y '
              'SENUS no puede abrirlo.\n\n'
              'Con el teléfono AÚN en modo C (si se apagó: apágalo, mantén C y '
              'enchufa el cable), pulsa «Instalar driver USB» y acepta el aviso '
              'de permisos de Windows. Cuando diga que terminó, pulsa '
              'Continuar. Se hace una sola vez.',
          accionDriver: AccionDriver.modoFlash,
        );
        yield EventoInstalador.pausar(pausa);
        if (!await pausa.respuesta.future || cancelacion.cancelado) {
          yield EventoInstalador.cancelacion(f, 'sin instalar el driver USB');
          out.cancelado = true;
          return;
        }
        continue; // vuelve a esperar al teléfono
      }
      break;
    }
    final (err, rem, accion) = await _noVisto(
        ultimoCodigo == -2 ? -2 : -1, remedioPorOmision);
    yield EventoInstalador.fallo(f, err, remedio: rem, accionDriver: accion);
    out.fallo = true;
  }

  /// El error y el remedio cuando no se vio el teléfono en modo flash.
  /// `codigo == -2`: Windows lo ve pero libusb no (falta el driver WinUSB).
  Future<(String, String, AccionDriver?)> _noVisto(
      int codigo, String remedioPorOmision) async {
    final sinDriver = codigo == -2 ||
        (_esWindows &&
            codigo != -1 &&
            await (windowsVeSinDriver ?? windowsVeTelefonoEnModoFlash)());
    if (sinDriver) {
      return (
        'Windows ve el teléfono en modo flash, pero sin el driver WinUSB: '
            'SENUS no puede abrirlo.',
        remedioDriverWindows(const ['NOT_SUPPORTED'], esWindows: true)!,
        AccionDriver.modoFlash,
      );
    }
    return (
      'No veo el teléfono en modo flash tras ${esperaModoC.inSeconds} s.',
      remedioPorOmision,
      null,
    );
  }
}

class _DatosAparato {
  final RespaldoRollback respaldo;
  final String? paquete;
  final String imei;
  const _DatosAparato(this.respaldo, this.paquete, this.imei);
}

// -------------------------------------------------------------------------- //
// Respaldo: buscar uno válido y texto de rollback
// -------------------------------------------------------------------------- //

/// El respaldo más reciente de (modelo, IMEI) que SIRVE: real (no de ensayo),
/// con las dos copias del GDFS en disco y con el sha256 que dicen sus
/// metadatos. Uno a medias o alterado cuenta como «no hay».
Future<RespaldoRollback?> buscarRespaldoValido(
    AlmacenRespaldos almacen, String modelo, String imei) async {
  final todos = (await almacen.listar())
      .where((r) => r.modelo == modelo && r.serie == imei && !r.simulado)
      .toList()
    ..sort((a, b) => b.fecha.compareTo(a.fecha));
  for (final r in todos) {
    var bien = true;
    for (final par in [
      (r.rutaGdfsA, await r.shaGdfsAResuelto()),
      (r.rutaGdfsB, await r.shaGdfsBResuelto()),
    ]) {
      final f = File(par.$1);
      if (par.$2 == null || !f.existsSync()) {
        bien = false;
        break;
      }
      final real = sha256.convert(await f.readAsBytes()).toString();
      if (real != par.$2) {
        bien = false;
        break;
      }
    }
    if (bien) return r;
  }
  return null;
}

/// Lo que se le dice a la persona al terminar: dónde queda el respaldo y cómo
/// se vuelve atrás (regla de rollback).
String textoRollback(RespaldoRollback r) {
  final sb = StringBuffer()
    ..writeln('Respaldo de rollback de este teléfono:')
    ..writeln('  ${r.carpeta}')
    ..writeln('  ${r.modelo} · IMEI ${r.serie} · CID ${r.cid ?? '?'} · '
        '${r.paqueteAnycid ?? r.firmwareOriginal ?? ''}')
    ..writeln('  gdfs_A.bin y gdfs_B.bin, con su sha256 en gdfs_*.sha256 y en '
        'metadatos.json.')
    ..writeln()
    ..writeln('Qué se tocó y qué no: se grabaron el main de senew y el '
        'bootloader en la NOR. El GDFS y el sistema de ficheros de fábrica NO '
        'se tocaron.')
    ..writeln()
    ..writeln('Para volver al firmware original de Sony Ericsson (por ahora a '
        'mano, documento técnico §8): grabar encima el main original '
        '(W580_R8BE001_MAIN_GENERIC_LA_RED52.mbn, con oflash) y, solo si '
        'hiciera falta, `seftool write-gdfs` con gdfs_A.bin.');
  return sb.toString();
}
