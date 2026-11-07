// Instalación de senew por PRIMERA VEZ en un W580 recién salido de la caja.
//
// Es una variante de `instalacion.dart` que, en lugar de pelearse con la
// firma del fork SEMC para escribir en NOR, saca a jugar a NUESTRO installer:
// un pequeño programa Java (executor.jar) que suelta un `.b` nativo cargado
// por el AMS; ese `.b` reclama USB y expone el bootloader propio con PID
// 0x0003 (ver `transporte_bl.dart`). Desde ahí SENUS escribe el main en
// 0x44180000 y el W6FS en su dirección (y, si hay que iterar sobre el BL
// propio, por WRITE_PROPIO en 0x44140000..0x44180000). Al terminar manda
// SALIR y el teléfono arranca con senew.
//
// Pasos (los que verá la pantalla):
//
//   0. identificar — con seftool: modelo, IMEI, CID, color.
//   1. respaldo de rollback — REGLA (senus-regla-rollback.md): no se avanza
//      sin él. Se delega en EjecutorRespaldo; si no hay respaldo para
//      (modelo, IMEI), se hace primero.
//   2. subir el executor del installer — seftool upload-anycid leyendo
//      ./anycid/senew_installer/<modelo>/{customize_upgrade.xml, executor.jar,
//      executor.b}. Preparado como armarZipAnycid() y guardando el zip
//      original del fork en un fichero `.original-senus` para reponerlo
//      pase lo que pase.
//   3. ritual del usuario — desconectar, Juegos → «Senew Installer»,
//      pulsar seleccionar, sacar la pila, volver a ponerla, encender SIN
//      cable, enchufar al ver «Senew Installer» en pantalla.
//   4. esperar el puente del installer — polling USB a 1209:0003 (hasta 2 min).
//   5. enviar main — WRITE a 0x44180000 (barra de progreso + CRC-32 al final).
//   6. enviar W6FS — WRITE a `w6fs_XXXXXXXX.bin` (dirección en el nombre;
//      es el convenio de `herr/aparato/hacer_aparato.py`).
//   7. SALIR — el BL salta a senew.
//   8. esperar senew normal — polling USB a 1209:0001 (hasta 1 min).
//   9. opcional — copia de apps del catálogo por MTP (reusa SesionMtp).
//
// REGLA INVIOLABLE: lo que `instalacion.dart` dice de `instalacion_inicial`
// vale igual: respaldo PRIMERO y notificado al final. Las comprobaciones de
// IMEI y la pausa humana están alineadas con las de las otras pantallas.
//
// MODO SIMULADO: todo este flujo se puede probar sin aparato con
// bridge_mock.py --installer; ver `experimentos/bridge_mock.py` y
// `app/bin/prueba_instalacion_inicial.dart`.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'seftool.dart';
import 'transporte_bl.dart';

// La UI de respaldo/instalación consume [EventoRespaldo] para pintar barras,
// pausas y errores. Lo re-exportamos aquí para que la pantalla de instalación
// inicial sólo tenga que importar `instalacion_inicial.dart`.
export 'respaldo_rollback.dart' show EventoRespaldo;

/// Pasos públicos (para que la pantalla pueda pintar su barra de pasos).
enum PasoInstalacion {
  identificar,
  respaldo,
  subirExecutor,
  ritualUsuario,
  esperarInstaller,
  enviarMain,
  enviarW6fs,
  salir,
  esperarSenew,
  copiarApps,
}

/// Nombre humano del paso. Pública para que la UI muestre lo mismo que el
/// log del ejecutor.
String nombrePaso(PasoInstalacion p) => switch (p) {
      PasoInstalacion.identificar => 'Identificar el aparato',
      PasoInstalacion.respaldo => 'Respaldo de rollback',
      PasoInstalacion.subirExecutor => 'Subir el instalador',
      PasoInstalacion.ritualUsuario => 'Instrucciones en el teléfono',
      PasoInstalacion.esperarInstaller => 'Esperar al bootloader',
      PasoInstalacion.enviarMain => 'Enviar el main de senew',
      PasoInstalacion.enviarW6fs => 'Enviar el W6FS',
      PasoInstalacion.salir => 'Arrancar senew',
      PasoInstalacion.esperarSenew => 'Esperar a senew',
      PasoInstalacion.copiarApps => 'Copiar apps (opcional)',
    };

/// Lo que la UI pasa a `enviarMain`/`enviarW6fs` para pintar la barra.
typedef OnProgreso = void Function(int hecho, int total);

/// Un hallazgo en la carpeta `build/aparato_sis…` del sistema.
class HitoAparato {
  final String carpeta;
  final DateTime fecha;
  final File sistemaBin; // sistema_44180000.bin
  final int direccionMain;
  final File w6fsBin; // w6fs_XXXXXXXX.bin
  final int direccionW6fs;
  const HitoAparato({
    required this.carpeta,
    required this.fecha,
    required this.sistemaBin,
    required this.direccionMain,
    required this.w6fsBin,
    required this.direccionW6fs,
  });

  String get nombre => p.basename(carpeta);
}

/// Busca el último hito `build/aparato_sis*` en el fork del sistema. Público
/// para los tests y para que la pantalla ofrezca escoger entre varios si
/// hay más de uno.
Future<List<HitoAparato>> listarHitosAparato(String raizSistema) async {
  final dir = Directory(p.join(raizSistema, 'build'));
  if (!dir.existsSync()) return const [];
  final out = <HitoAparato>[];
  await for (final e in dir.list()) {
    if (e is! Directory) continue;
    final b = p.basename(e.path);
    if (!b.startsWith('aparato_sis') && b != 'aparato') continue;
    final h = await _leerHito(e);
    if (h != null) out.add(h);
  }
  out.sort((a, b) => b.fecha.compareTo(a.fecha));
  return out;
}

Future<HitoAparato?> _leerHito(Directory dir) async {
  File? sistema;
  int direccionMain = 0;
  File? w6fs;
  int direccionW6fs = 0;
  await for (final f in dir.list()) {
    if (f is! File) continue;
    final b = p.basename(f.path);
    final mSis = RegExp(r'^sistema_([0-9a-fA-F]{8})\.bin$').firstMatch(b);
    if (mSis != null) {
      sistema = f;
      direccionMain = int.parse(mSis.group(1)!, radix: 16);
      continue;
    }
    final mFs = RegExp(r'^w6fs_([0-9a-fA-F]{8})\.bin$').firstMatch(b);
    if (mFs != null) {
      w6fs = f;
      direccionW6fs = int.parse(mFs.group(1)!, radix: 16);
    }
  }
  if (sistema == null || w6fs == null) return null;
  return HitoAparato(
    carpeta: dir.path,
    fecha: sistema.statSync().modified,
    sistemaBin: sistema,
    direccionMain: direccionMain,
    w6fsBin: w6fs,
    direccionW6fs: direccionW6fs,
  );
}

/// Error específico del flujo de primera instalación. Separado de
/// [SeftoolError] para que la pantalla distinga los dos.
class InstalacionInicialError implements Exception {
  final String motivo;
  final String? remedio;
  final PasoInstalacion? paso;
  InstalacionInicialError(this.motivo, {this.remedio, this.paso});
  @override
  String toString() => motivo;
}

// --------------------------------------------------------------------------
// Orquestador
// --------------------------------------------------------------------------

/// Instalación inicial por el executor + installer. Expone los métodos
/// pedidos por la especificación (subirExecutor, esperarPuenteInstaller,
/// enviarMain, enviarW6fs, salir, esperarSenewNormal) + un `correrTodo` que
/// los teje; la pantalla llama al que necesite paso a paso para enseñarlos.
class InstalacionInicial {
  /// Transporte USB al installer. Si es null, se crea con
  /// `TransporteBl.elegir(..., pid=0x0003)` la primera vez que haga falta
  /// (p. ej. en el polling de [esperarPuenteInstaller]).
  TransporteBl? _bl;

  /// Transporte USB a senew normal (PID 0x0001). Igual que arriba,
  /// vago hasta que [esperarSenewNormal] lo necesite.
  TransporteBl? _senewNormal;

  /// Fabrica de transportes BL: inyectable por los tests. Si es null se usa
  /// [TransporteBl.elegir]. El VID siempre es `vidSenew`.
  final TransporteBl Function(int pid)? fabricaBl;

  /// Si no es null, [subirExecutor] la llama con cada línea de seftool para
  /// que la pantalla la vea.
  final void Function(String linea)? alLogSeftool;

  InstalacionInicial({this.fabricaBl, this.alLogSeftool});

  // ---------------------------------------------------------------------- //
  // Paso 2 — subir el executor del installer
  // ---------------------------------------------------------------------- //

  /// Monta el zip anycid del installer tomando de [carpetaAnycid] (p. ej.
  /// `anycid/senew_installer/w580`) y lo sube con
  /// `seftool upload-anycid --imei <imei>`.
  ///
  /// seftool exige que el zip esté en `./anycid/<target>.zip` dentro del
  /// fork; esta función lo arma en memoria, lo copia a ese sitio (apartando
  /// el original con `.original-senus`), y lo repone pase lo que pase.
  Future<void> subirExecutor(
      Seftool seftool, String imei, String carpetaAnycid) async {
    // 1) Validar entradas.
    final imeiLimpio = imei.trim();
    if (!Seftool.imeiValido(imeiLimpio)) {
      throw InstalacionInicialError(
        'IMEI no válido para seftool: «$imeiLimpio»',
        remedio: 'Tiene que ser el IMEI tal como lo imprime identify.',
        paso: PasoInstalacion.subirExecutor,
      );
    }
    final dir = Directory(carpetaAnycid);
    final xml = File(p.join(dir.path, 'customize_upgrade.xml'));
    final jar = File(p.join(dir.path, 'executor.jar'));
    final b = File(p.join(dir.path, 'executor.b'));
    for (final f in [xml, jar, b]) {
      if (!f.existsSync()) {
        throw InstalacionInicialError(
          'Falta ${p.basename(f.path)} en\n  ${dir.path}',
          remedio: f == b
              ? 'El `executor.b` lo produce el proyecto '
                  'senew-w580 (rama bl-installer) con\n'
                  '  herr/bl/empaquetar_installer.py\n'
                  'y hay que dejarlo en ${dir.path}.'
              : 'Copia el fichero del paquete AnyCID genérico '
                  '(DB2020.zip o R8BE001_...GENERIC_LA.zip).',
          paso: PasoInstalacion.subirExecutor,
        );
      }
    }

    // 2) Resolver qué target quiere seftool. En el flujo nuevo, `identify`
    //    ya reportó un paquete anycid que es el de este firmware; aquí no
    //    lo asumimos: el que importa es el que seftool llamará (el que
    //    aparece en el stdout del `identify` que la UI pasó). Como no
    //    tenemos ese valor aquí, nos lo pasa el fuera del método: en el
    //    MVP, instalamos SIEMPRE en el paquete genérico del W580
    //    (`DB2020.zip`, igual que hace `upload-anycid` sin flags).
    //    seftool fija el nombre dentro con `--anycid`; aquí vamos con eso
    //    para no sorprenderse: lo que escribe el fork en 3 ficheros es
    //    `tpa/preset/custom/{customize_upgrade.xml, executor.jar,
    //    executor.b}`, los mismos que tenemos.
    //
    // TODO: el `identify` del respaldo trae `paqueteAnycid`
    // («R8BE001_CXC1123362_GENERIC_LA»). Puede valer para no romper si en
    // el futuro hay varios por aparato. Para esta primera iteración
    // reusamos lo que mande seftool con --anycid.
    final zipDestino = File(p.join(seftool.raiz, 'anycid', 'DB2020.zip'));
    if (!zipDestino.existsSync() && !seftool.ensayo) {
      throw InstalacionInicialError(
        'No está el paquete anycid genérico en ${zipDestino.path}',
        remedio: 'Instala el fork `seftool-senew` entero; `anycid/DB2020.zip` '
            'viene con él.',
        paso: PasoInstalacion.subirExecutor,
      );
    }

    // 3) Armar el zip con los 3 ficheros nuestros. Los metemos tal cual
    //    (sin firma: el executor.jar original de SE ya está firmado y es el
    //    que salta la validación del AMS; nosotros reemplazamos su .b).
    final zipNuestro = Archive();
    void anadir(String ruta, List<int> bytes) {
      final af = ArchiveFile(ruta, bytes.length, bytes);
      zipNuestro.addFile(af);
    }

    final xmlBytes = await xml.readAsBytes();
    final jarBytes = await jar.readAsBytes();
    final bBytes = await b.readAsBytes();
    // Las entradas de directorio hacen el zip más parecido al que lee la
    // escena (upload-anycid se queja si falta alguna).
    zipNuestro.addFile(ArchiveFile('tpa/', 0, const <int>[])..isFile = false);
    zipNuestro.addFile(ArchiveFile('tpa/preset/', 0, const <int>[])
      ..isFile = false);
    zipNuestro.addFile(ArchiveFile('tpa/preset/custom/', 0, const <int>[])
      ..isFile = false);
    anadir('tpa/preset/custom/customize_upgrade.xml', xmlBytes);
    anadir('tpa/preset/custom/executor.jar', jarBytes);
    anadir('tpa/preset/custom/executor.b', bBytes);
    final nuevoBytes = ZipEncoder().encode(zipNuestro);
    if (nuevoBytes == null) {
      throw InstalacionInicialError('No pude recomprimir el anycid del installer.',
          paso: PasoInstalacion.subirExecutor);
    }

    // 4) Guardar el original a un lado y poner el nuestro.
    final guardado = File('${zipDestino.path}.original-senus');
    var hayQueReponer = false;
    try {
      if (!seftool.ensayo) {
        if (!guardado.existsSync()) {
          await zipDestino.copy(guardado.path);
          alLogSeftool
              ?.call('  original guardado en ${guardado.path}');
        }
        await zipDestino.writeAsBytes(nuevoBytes);
        hayQueReponer = true;
        alLogSeftool?.call('  installer puesto en ${zipDestino.path} '
            '(${nuevoBytes.length} B)');
      }

      // 5) Lanzar seftool upload-anycid.
      seftool.imeiEsperado = imeiLimpio;
      var arrancoFsx = false;
      var fallo = false;
      await for (final l in seftool.subirAnycid()) {
        alLogSeftool?.call(l.texto);
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
      if ((fallo || !arrancoFsx) && !seftool.ensayo) {
        throw InstalacionInicialError(
          'El CS loader no arrancó sus servicios al subir el installer.',
          remedio:
              'No se escribió nada en la NOR. Reconecta el teléfono en modo C '
              'y vuelve a intentarlo; si vuelve a pasar, hay que medir con el '
              'cable serie — docs/CID53_RUTA.md §4.',
          paso: PasoInstalacion.subirExecutor,
        );
      }
    } finally {
      if (hayQueReponer && guardado.existsSync()) {
        try {
          await guardado.copy(zipDestino.path);
        } catch (_) {
          /* el usuario puede reponerlo a mano desde ${guardado.path} */
        }
      }
    }
  }

  // ---------------------------------------------------------------------- //
  // Paso 4 — esperar al installer
  // ---------------------------------------------------------------------- //

  /// Hace polling USB al VID:PID del installer hasta que aparezca o se cumpla
  /// `timeout`. Devuelve el transporte YA abierto (listo para controlOut).
  Future<TransporteBl> esperarPuenteInstaller({
    Duration timeout = const Duration(minutes: 2),
    Duration intervalo = const Duration(milliseconds: 500),
  }) async {
    final bl = _bl ??=
        (fabricaBl ?? _elegirDeVerdad)(pidBlInstaller);
    final tope = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(tope)) {
      final vistos = await bl.enumerar();
      if (vistos.isNotEmpty) {
        await bl.abrir(vistos.first);
        return bl;
      }
      await Future<void>.delayed(intervalo);
    }
    throw InstalacionInicialError(
      'No veo al installer en el bus USB tras ${timeout.inSeconds} s.',
      remedio: 'Comprueba que el teléfono encendió, que pone «Senew Installer» '
          'en pantalla, y que el cable está enchufado. En Linux, mira dmesg '
          'por si falta la regla udev para 1209:0003.',
      paso: PasoInstalacion.esperarInstaller,
    );
  }

  TransporteBl _elegirDeVerdad(int pid) =>
      TransporteBl.elegir(vid: vidSenew, pid: pid);

  // ---------------------------------------------------------------------- //
  // Paso 5/6 — enviar main / W6FS
  // ---------------------------------------------------------------------- //

  /// Envía `datos` al installer con WRITE a `direccion` (por omisión, el main
  /// en 0x44180000). Hace WIPE del main antes del WRITE (igual que
  /// pu_bl.escribir) y comprueba el CRC-32 al final. Reporta progreso en
  /// bytes.
  Future<void> enviarMain(Uint8List datos,
      {int direccion = blMainIni, OnProgreso? onProgreso}) async {
    final bl = _bl;
    if (bl == null) {
      throw InstalacionInicialError(
          'enviarMain sin transporte abierto: llama primero a esperarPuenteInstaller().',
          paso: PasoInstalacion.enviarMain);
    }
    await _escribirZona(bl, datos,
        direccion: direccion,
        op: blOpWrite,
        hayQueBorrarMain: true,
        regionCeroAlFinal: true,
        onProgreso: onProgreso);
  }

  /// Envía el W6FS a su dirección. Sin WIPE previo (el W6FS está en una zona
  /// de la NOR distinta; el installer borra la zona que WRITE pisará si hace
  /// falta — ver `plat/bl/bl_nor.c`). Reporta progreso en bytes.
  Future<void> enviarW6fs(Uint8List datos,
      {required int direccion, OnProgreso? onProgreso}) async {
    final bl = _bl;
    if (bl == null) {
      throw InstalacionInicialError(
          'enviarW6fs sin transporte abierto.',
          paso: PasoInstalacion.enviarW6fs);
    }
    await _escribirZona(bl, datos,
        direccion: direccion, op: blOpWrite, hayQueBorrarMain: false, onProgreso: onProgreso);
  }

  /// Envía el BL propio a su zona (0x44140000..0x44180000). Lo expone esta
  /// capa por si en el futuro la pantalla ofrece re-grabarlo (el flujo
  /// normal lo hace una sola vez: la primera instalación).
  ///
  /// AVISO: el BL del aparato exige WIPE_PROPIO antes del WRITE_PROPIO (igual
  /// que la zona del main). Si el usuario corta la grabación entre el WIPE y
  /// el final del WRITE, el aparato queda sin arranque en la NOR y hay que
  /// recuperar con oflash R8BE001. La UI debe avisar antes de llamar a este
  /// método.
  Future<void> enviarBlPropio(Uint8List datos,
      {OnProgreso? onProgreso}) async {
    final bl = _bl;
    if (bl == null) {
      throw InstalacionInicialError('enviarBlPropio sin transporte abierto.');
    }
    // El bloque Intel del BL propio = los 256 KiB de BL_INI..MAIN_INI, un
    // solo bloque de borrado. Mandamos WIPE_PROPIO con arg0 = BL_INI.
    await _go(bl, blOpWipePropio, [blPropioIni],
        plazo: const Duration(seconds: 30));
    await _escribirZona(bl, datos,
        direccion: blPropioIni,
        op: blOpWritePropio,
        hayQueBorrarMain: false,
        onProgreso: onProgreso);
  }

  Future<void> _escribirZona(TransporteBl bl, Uint8List datos,
      {required int direccion,
      required int op,
      required bool hayQueBorrarMain,
      bool regionCeroAlFinal = false,
      OnProgreso? onProgreso}) async {
    if (datos.isEmpty) {
      throw InstalacionInicialError(
          'enviar: no se mandan 0 bytes a 0x${direccion.toRadixString(16).toUpperCase()}');
    }
    // Rellenar hasta múltiplo de BL_REGION con 0xFF (igual que pu_bl.escribir).
    // Nota: el operador de cascada en una expresión condicional se enlazaba
    // al bloque entero, no solo al case de `mod!=0`, y eso aplicaba
    // `fillRange` también sobre `datos` cuando mod==0 → RangeError. Hecho
    // paso a paso para que sea obvio.
    final Uint8List rellenado;
    final mod = datos.length % blRegion;
    if (mod == 0) {
      rellenado = datos;
    } else {
      final n = datos.length + (blRegion - mod);
      rellenado = Uint8List(n)
        ..setRange(0, datos.length, datos)
        ..fillRange(datos.length, n, 0xFF);
    }

    if (hayQueBorrarMain) {
      // WIPE borra la zona del main entera, no sólo lo que vayamos a escribir
      // (igual que el BL propio): bl_nor.c borra 9 bloques de 256 KiB. Si en
      // el futuro el installer tiene un WIPE acotado, se cambia aquí.
      await _go(bl, blOpWipe, const [], plazo: const Duration(seconds: 120));
    }

    // La región 0 lleva los vectores: el BL salta al main si los ve (bl.h,
    // §6.2 del diseño). Grabada la última, un corte a medias deja el teléfono
    // en el BL, recuperable; grabada primero, saltaría a un main a medio grabar.
    var hecho = 0;
    Future<void> tramo(int desde, int hasta) async {
      var off = desde;
      while (off < hasta) {
        var n = (blBufTam ~/ blRegion) * blRegion; // 4096 B exactos
        if (off + n > hasta) n = hasta - off;
        final trozo = rellenado.sublist(off, off + n);
        // Troceamos el PUT a 64 B por paquete EP0 (igual que pu_bl.put).
        for (var i = 0; i < n; i += 64) {
          final fin = (i + 64 <= n) ? i + 64 : n;
          await bl.controlOut(
              blRPut, i, 0, Uint8List.fromList(trozo.sublist(i, fin)));
        }
        await _go(bl, op, [direccion + off, n],
            plazo: const Duration(seconds: 60));
        off += n;
        hecho += n;
        onProgreso?.call(hecho.clamp(0, datos.length), datos.length);
      }
    }

    final conResto = regionCeroAlFinal && rellenado.length > blRegion;
    if (conResto) {
      await tramo(blRegion, rellenado.length);
      final resto = Uint8List.sublistView(rellenado, blRegion);
      final r = await _go(bl, blOpCrc, [direccion + blRegion, resto.length],
          plazo: const Duration(seconds: 60));
      if (r.r0 != crc32DeDatos(resto)) {
        throw InstalacionInicialError(
          'CRC mal en el main: aparato=0x${r.r0.toRadixString(16)} '
          'esperado=0x${crc32DeDatos(resto).toRadixString(16)}.',
          remedio: 'Los vectores no se han grabado: el teléfono se queda en el '
              'BL. Reintenta la instalación con el cable puesto.',
        );
      }
      await tramo(0, blRegion);
    } else {
      await tramo(0, rellenado.length);
    }

    // Al terminar, un CRC-32 para que el aparato nos diga que lo que grabó
    // es idéntico a lo que mandamos. Es la red del flujo: si no coincide,
    // hay un bit mal en NOR y no debemos cantar victoria.
    final crcLocal = crc32DeDatos(rellenado);
    final r = await _go(bl, blOpCrc, [direccion, rellenado.length],
        plazo: const Duration(seconds: 60));
    final crcAparato = r.r0;
    if (crcLocal != crcAparato) {
      throw InstalacionInicialError(
        'CRC mal tras escribir 0x${direccion.toRadixString(16).toUpperCase()}: '
        'aparato=0x${crcAparato.toRadixString(16)} esperado=0x${crcLocal.toRadixString(16)}.',
        remedio: 'La NOR puede estar a medias — NO apagues el teléfono. '
            'Reintenta la instalación con el cable puesto; el installer sigue '
            'en RAM.',
      );
    }
  }

  // ---------------------------------------------------------------------- //
  // Paso 7 — SALIR
  // ---------------------------------------------------------------------- //

  /// Manda la orden SALIR al installer: el BL quita la bandera y rebota al
  /// main nuevo (senew). El transporte se cierra solo cuando el aparato
  /// baje del bus; aquí lo marcamos como cerrado para que ningún método
  /// posterior intente usar un handle muerto.
  Future<void> salir() async {
    final bl = _bl;
    if (bl == null) {
      throw InstalacionInicialError('salir() sin transporte abierto.');
    }
    try {
      await _go(bl, blOpSalir, const [], plazo: const Duration(seconds: 5));
    } finally {
      try {
        await bl.cerrar();
      } catch (_) {}
      _bl = null;
    }
  }

  // ---------------------------------------------------------------------- //
  // Paso 8 — esperar a senew
  // ---------------------------------------------------------------------- //

  /// Espera a que senew (PID 0x0001) aparezca en el bus. Devuelve true si
  /// llegó antes del timeout; en caso contrario, false (la pantalla lo
  /// interpreta como «arranca a mano»).
  Future<bool> esperarSenewNormal({
    Duration timeout = const Duration(minutes: 1),
    Duration intervalo = const Duration(milliseconds: 500),
  }) async {
    final bl = _senewNormal ??=
        (fabricaBl ?? _elegirDeVerdad)(pidSenewNormal);
    final tope = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(tope)) {
      final vistos = await bl.enumerar();
      if (vistos.isNotEmpty) {
        return true;
      }
      await Future<void>.delayed(intervalo);
    }
    return false;
  }

  // ---------------------------------------------------------------------- //
  // Helpers del BL (GO/RES) — espejo de pu_bl.go
  // ---------------------------------------------------------------------- //

  int _seq = 0;
  Future<_RespBl> _go(TransporteBl bl, int op, List<int> args,
      {Duration plazo = const Duration(seconds: 60)}) async {
    _seq = (_seq + 1) & 0xFF;
    for (var i = 0; i < args.length && i < 4; i++) {
      final a = args[i] & 0xFFFFFFFF;
      await bl.controlOut(
          blRArg0 + i, a & 0xFFFF, (a >> 16) & 0xFFFF, Uint8List(0));
    }
    final val = (op & 0xFF) | (_seq << 8);
    await bl.controlOut(blRGo, val, 0, Uint8List(0));
    final t0 = DateTime.now();
    while (DateTime.now().difference(t0) < plazo) {
      final b = await bl.controlIn(blRRes, 0, 0, 32);
      final r = _RespBl.parsear(b);
      if (r.estado == blStHecho && r.seq == _seq) {
        if (r.codigo != 0) {
          throw InstalacionInicialError(
            'op $op falló: codigo=${r.codigo} r0=0x${r.r0.toRadixString(16)} '
            'r1=0x${r.r1.toRadixString(16)}.',
            remedio: 'Mira el log del BL propio (bl_nor.c) para '
                'descifrar el código.',
          );
        }
        return r;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw InstalacionInicialError(
      'op $op: el BL no contestó en ${plazo.inSeconds} s.',
      remedio: 'Probablemente el aparato quedó colgado — '
          'desconecta y vuelve a enchufar.',
    );
  }
}

/// Lectura de un paquete BL_R_RES del BL (32 B). Pública para los tests.
class _RespBl {
  final int estado;
  final int seq;
  final int op;
  final int codigo;
  final int r0;
  final int r1;
  final int ordenes;
  final int ms;
  _RespBl(this.estado, this.seq, this.op, this.codigo, this.r0, this.r1,
      this.ordenes, this.ms);

  static _RespBl parsear(Uint8List b) {
    if (b.length < 24) {
      throw InstalacionInicialError(
          'BL_R_RES devolvió ${b.length} B (se esperaban ≥ 24)');
    }
    final v = ByteData.sublistView(b);
    return _RespBl(
      v.getUint8(0),
      v.getUint8(1),
      v.getUint16(2, Endian.little),
      v.getInt32(4, Endian.little),
      v.getUint32(8, Endian.little),
      v.getUint32(12, Endian.little),
      v.getUint32(16, Endian.little),
      v.getUint32(20, Endian.little),
    );
  }
}

// --------------------------------------------------------------------------
// (export de EventoRespaldo arriba, junto a los imports)
