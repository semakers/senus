// Instalación de senew y vuelta al firmware original, contra el aparato de
// verdad (seftool-senew por subproceso).
//
// REGLA INVIOLABLE (senus-regla-rollback.md): aquí no se entra sin un
// respaldo de rollback REAL del aparato. Un respaldo hecho en modo simulado
// no vale: `EjecutorInstalacion` y `EjecutorRestauracion` se niegan.
//
// Dos caminos, los decide el CID leído en `identify` y guardado en el
// respaldo:
//
//  A) REEMPLAZO FRÍO  (W600/W810 DB2010 CID49, y W580 CID52 «en teoría»)
//     `flash main <senew.ssw>` sobrescribe el main en la NOR.
//     ⚠ MEDIDO EN EL FUENTE DEL FORK, y cambia lo que se puede esperar:
//       - `action_flash_fw` sólo usa BFLASH (el que imprime «Security
//         disabled =)» y permite escribir firmware NO firmado) si
//         (DB2000|DB2010) && cid<=49 && break_rsa==1, o si el color es
//         BROWN → por eso el W600/W810 CID49 necesita `--break-rsa`, que
//         ESCRIBE un bootloader parchado en la NOR. seftool exige confirmarlo
//         a propósito (SEFTOOL_BREAK_CONFIRM=1 en SU terminal y quitar/poner la
//         batería pulsando Y), y SENUS no puede: no hereda esa variable y cierra
//         stdin. Por eso este camino está BLOQUEADO en el plan y SENUS nunca
//         pasa `--break-rsa`.
//       - Para todo lo demás usa OFLASH, y `loader_send_oflash_ldr()` hace
//         `phone->anycid = 0` nada más entrar (oflash.c:181) y manda el
//         flashloader FIRMADO del CID (CID49/51/52/53).
//       - PERO el camino bueno para DB2020 SÍ existe en el fork:
//         `loader_send_bflash_ldr_db2020()` con `anycid == 1` sube el
//         preloader+loader de setool2 e imprime «Security disabled =)».
//         Lo que pasa es que (a) exige que el exploit «executer» se haya
//         corrido ANTES desde el teléfono — si no, «[QHTRY] Run executer
//         first» — y (b) `flash` nunca llega a llamarlo, porque la condición
//         de arriba no contempla DB2020.
//       => en un W580 RED (CID52 o CID53) el reemplazo frío NO es imposible:
//          es un PORTILLO CERRADO. Abrirlo es tocar la condición del fork,
//          pero no se puede validar sin el aparato Y su pantalla (el paso
//          del executer). El plan lo dice en voz alta antes de dejar pulsar
//          nada, en vez de descubrirlo con el teléfono abierto en la mesa.
//
//  B) ANYCID + PAYLOAD  (W580 DB2020 CID53)
//     No se toca la NOR: el firmware SEMC sigue entero y un reset físico
//     siempre lo devuelve. Se sube un paquete anycid con NUESTRO
//     `executor.b` (el payload de senew en SDRAM) y el MIDlet lo carga.
//     El último paso NO es automatizable: hay que abrir «Juegos» en el
//     teléfono. Ver w580-cid53-sin-pantalla.md.
//
// TRAMPA del anycid: `action_upload_anycid` no acepta la ruta de un zip; lee
// `./anycid/<target>.zip` de la raíz del fork, con el target que resolvió él
// mismo del CXC de la GDFS. Para subir el nuestro hay que DEJARLO EN SU
// SITIO. Esta capa guarda el original a un lado antes y lo repone después,
// pase lo que pase.

import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'respaldo_rollback.dart';
import 'seftool.dart';

/// Qué camino toca para este aparato.
enum Camino {
  /// Sobrescribir el main en la NOR.
  reemplazoFrio,

  /// Subir el payload como `executor.b` por el flujo anycid.
  /// El firmware SEMC se queda entero en la NOR; senew corre encima como
  /// stub cargado por el AMS. No puede brickar.
  anycidPayload,

  /// Reemplazo frío por anycid (DB2020). Secuencia:
  ///   1. `upload-anycid` sube los paquetes (CSLoader, por USB).
  ///   2. [HUMANO] desconecta, pone SIM, enciende, Juegos → «executer»,
  ///      reconecta en modo servicio. SENUS pausa aquí (cerrojo físico).
  ///   3. `flash-anycid main <senew.ssw>` entra por bflash_ldr_db2020 con
  ///      anycid=1 («Security disabled =)») y escribe el main sin firma.
  /// EXPERIMENTAL: la pieza nueva del fork `flash-anycid` NO se ha probado
  /// contra un W580 real. Si falla a mitad del flash main, el aparato
  /// requiere restaurar desde el respaldo de rollback — por eso la regla
  /// bloquea esto si no hay respaldo verificado.
  anycidReemplazoFrio,
}

/// Dónde vive el `.b` del payload CID53 dentro del fork del sistema.
const _rutaPayloadPorOmision =
    'dev/w580/work/cid53_payload/build/w580i-cid53/senew_payload.b';

/// Candidatos del binario de senew por modelo, en orden de preferencia, y la
/// dirección en la NOR donde va el main (de `placas/<x>/placa.c`, ZONA_MAIN).
const Map<String, List<String>> _candidatosSenew = {
  // El MANIFIESTO de build/aparato dice que éste es «lo que iría a un
  // W580i»; lleva la dirección en el nombre a propósito.
  'W580': [
    'dev/w580/sistema/build/aparato/sistema_44140000.bin',
    'dev/w580/sistema/build/sistema.bin',
    'dev/w580/sistema/build/c_arr/sistema.bin',
  ],
  'W600': [
    'dev/w580/sistema/build/w600i/sistema.bin',
  ],
  'W810': [
    'dev/w580/sistema/build/w810i/sistema.bin',
  ],
};

const Map<String, int> _direccionMain = {
  'W580': 0x44140000, // placas/w580i: ZONA_MAIN
  'W810': 0x44140000, // placas/w810i/placa.c:19
  'W600': 0x440A0000, // placas/w600i/placa.c:15
};

String get _hogar =>
    Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';

/// Lo que se va a hacer, resuelto ANTES de tocar nada, para poder enseñarlo.
class PlanInstalacion {
  final Camino camino;
  final String modelo;
  final String cid;

  /// Binario a grabar (reemplazo frío) o payload `.b` (anycid). null si no se
  /// encontró en ninguno de los sitios esperados.
  final String? rutaBinario;

  /// Dónde va el main en la NOR (sólo reemplazo frío).
  final int? direccion;

  /// Nombre del paquete anycid que resolvió seftool (sólo anycid).
  final String? paqueteAnycid;

  /// Cosas que el usuario tiene que saber ANTES de pulsar. Las de peso van
  /// primero.
  final List<String> avisos;

  /// Si es true, el plan no se puede ejecutar y `avisos` dice por qué.
  final bool bloqueado;

  const PlanInstalacion({
    required this.camino,
    required this.modelo,
    required this.cid,
    required this.rutaBinario,
    required this.direccion,
    required this.paqueteAnycid,
    required this.avisos,
    required this.bloqueado,
  });

  String get nombre {
    switch (camino) {
      case Camino.anycidPayload:
        return 'anycid + payload (no se toca la NOR)';
      case Camino.anycidReemplazoFrio:
        return 'reemplazo frío por anycid (EXPERIMENTAL)';
      case Camino.reemplazoFrio:
        return 'reemplazo frío del main';
    }
  }

  String get explicacion {
    switch (camino) {
      case Camino.anycidPayload:
        return 'El firmware SEMC se queda entero en la NOR. senew se sube como '
            '«executor.b» y lo carga el AMS. Un reset físico siempre devuelve '
            'el teléfono a su firmware. No puede quedar inservible.';
      case Camino.anycidReemplazoFrio:
        return 'Camino nuevo para W580: 1) sube el paquete anycid por USB, '
            '2) tú abres Juegos → «executer» en el teléfono, 3) SENUS escribe '
            'el main senew sin firma por la rama bflash. Volver atrás exige '
            'el respaldo de rollback. SIN PROBAR contra aparato — ver avisos.';
      case Camino.reemplazoFrio:
        return 'Se sobrescribe el main de la NOR con senew. Volver atrás exige '
            'el respaldo (flash_full.bin + gdfs_A.bin).';
    }
  }
}

/// ¿Este aparato (DB2010: W600/W810, CID ≤ 49) solo acepta firmware sin firmar
/// tras `--break-rsa`? Un CID ilegible cuenta como 99 (no).
bool necesitaBreakRsa(String modelo, String cid) {
  final m = modelo.toUpperCase();
  return (m == 'W600' || m == 'W810') && (int.tryParse(cid) ?? 99) <= 49;
}

/// Por qué SENUS no instala en un aparato que necesita `--break-rsa`.
String avisoBreakRsa(String modelo, String cid) =>
    'SENUS no instala en un $modelo con CID $cid: seftool solo escribe '
    'firmware sin firmar ahí tras `--break-rsa`, que ESCRIBE un bootloader '
    'parchado en la NOR. seftool exige confirmarlo a propósito '
    '(SEFTOOL_BREAK_CONFIRM=1 en la terminal) y quitar y volver a poner la '
    'batería pulsando Y, y SENUS no hace ninguna de las dos cosas: no hereda '
    'esa variable ni tiene terminal. No se escribió nada.\n'
    'Si de verdad quieres hacerlo, es a mano desde seftool-senew, sabiendo '
    'que un fallo a medias puede dejar el teléfono sin arrancar.';

/// Resuelve el plan a partir del respaldo (que ya trae modelo, CID y el
/// paquete anycid que seftool dedujo del CXC).
PlanInstalacion planificar(
  RespaldoRollback r, {
  String? rutaSenew,
  String? rutaPayload,
  Camino? forzarCamino,
}) {
  final modelo = r.modelo.toUpperCase();
  final cid = r.cid ?? '';
  final esDb2020 = modelo == 'W580';
  final camino = forzarCamino ??
      ((esDb2020 && cid == '53')
          ? Camino.anycidPayload
          : Camino.reemplazoFrio);
  final avisos = <String>[];
  var bloqueado = false;

  if (r.simulado) {
    avisos.add(
        'Este respaldo se hizo en modo SIMULADO: no es el firmware de un '
        'aparato y no sirve para volver atrás. Hay que rehacerlo con el '
        'teléfono conectado antes de instalar nada.');
    bloqueado = true;
  }

  String? binario;
  int? direccion;
  String? paquete;

  // Nota: tres caminos excluyentes. Antes esto era un if/else y
  // anycidReemplazoFrio caía por el `else` de reemplazoFrio y se
  // auto-bloqueaba. Ahora cada camino tiene su rama separada.
  if (camino == Camino.anycidPayload) {
    paquete = r.paqueteAnycid;
    binario = rutaPayload ?? p.join(_hogar, _rutaPayloadPorOmision);
    if (!File(binario).existsSync()) {
      avisos.add('No encuentro el payload en:\n  $binario\n'
          'Compílalo con «make w580-cid53-payload» en '
          'el payload CID53.');
      bloqueado = true;
      binario = null;
    }
    if (paquete == null || paquete.isEmpty) {
      avisos.add('El identify de este respaldo no trajo el paquete anycid. '
          'Vuelve a identificar el aparato con el cable puesto.');
      bloqueado = true;
    }
    avisos.add('El último paso NO es automático: cuando seftool termine, hay '
        'que encender el teléfono CON SIM y abrir el MIDlet «executer» desde '
        'el menú Juegos. Sin pantalla no se puede.');
    avisos.add('Pendiente de medir en el aparato: la palabra 0x04 del .b (el '
        'probable CRC-24) no se recalcula. Si el AMS la valida, rechazará el '
        '.b. Es el riesgo conocido; el plan B está en '
        'seftool-senew/docs/cid53_payload.md.');
  } else if (camino == Camino.reemplazoFrio) {
    direccion = _direccionMain[modelo];
    if (rutaSenew != null) {
      binario = rutaSenew;
    } else {
      for (final rel in _candidatosSenew[modelo] ?? const <String>[]) {
        final f = p.join(_hogar, rel);
        if (File(f).existsSync()) {
          binario = f;
          break;
        }
      }
    }
    if (binario == null || !File(binario).existsSync()) {
      avisos.add('No encuentro el binario de senew para $modelo. Se buscó en:'
          '\n  ${(_candidatosSenew[modelo] ?? const []).map((x) => p.join(_hogar, x)).join('\n  ')}');
      bloqueado = true;
      binario = null;
    }
    if (direccion == null) {
      avisos.add('No sé en qué dirección va el main de $modelo.');
      bloqueado = true;
    }
    if (esDb2020) {
      avisos.insert(
          0,
          'AVISO FUERTE (DB2020): el camino `flash` normal del fork va por '
          'OFLASH con flashloader FIRMADO y rechazará un main sin firma. '
          'Para un W580 el camino bueno es «Reemplazo frío por anycid» '
          '(flash-anycid), no éste.');
      bloqueado = true;
    }
    if (necesitaBreakRsa(modelo, cid)) {
      avisos.insert(0, avisoBreakRsa(modelo, cid));
      bloqueado = true;
    }
  }

  if (camino == Camino.anycidReemplazoFrio) {
    direccion = _direccionMain[modelo];
    paquete = r.paqueteAnycid;
    if (rutaSenew != null) {
      binario = rutaSenew;
    } else {
      for (final rel in _candidatosSenew[modelo] ?? const <String>[]) {
        final f = p.join(_hogar, rel);
        if (File(f).existsSync()) {
          binario = f;
          break;
        }
      }
    }
    if (!esDb2020) {
      avisos.insert(0, 'anycidReemplazoFrio es sólo para W580 (DB2020). '
          'En $modelo usa «Reemplazo frío» con --break-rsa.');
      bloqueado = true;
    }
    if (binario == null || !File(binario).existsSync()) {
      avisos.add('No encuentro el binario de senew para $modelo. Se buscó en:'
          '\n  ${(_candidatosSenew[modelo] ?? const []).map((x) => p.join(_hogar, x)).join('\n  ')}');
      bloqueado = true;
      binario = null;
    }
    if (direccion == null) {
      avisos.add('No sé en qué dirección va el main de $modelo.');
      bloqueado = true;
    }
    if (paquete == null || paquete.isEmpty) {
      avisos.add('El identify de este respaldo no trajo el paquete anycid. '
          'Vuelve a identificar el aparato con el cable puesto.');
      bloqueado = true;
    }
    avisos.add(
        'EXPERIMENTAL: la acción `flash-anycid` del fork no se ha probado '
        'contra un W580 real todavía. Si falla a mitad del flash main, el '
        'aparato queda inservible hasta restaurar el respaldo de rollback '
        '— el que se hizo en el paso de Fábrica.');
    avisos.add(
        'PASO MANUAL (cerrojo físico): entre subir el paquete anycid y '
        'escribir el main, SENUS pausa. Hay que desconectar el cable, '
        'poner la SIM, encender el teléfono, abrir Juegos → «executer», '
        'esperar a que el MIDlet corra, volver a conectar en modo servicio '
        '(apagar + tecla C + cable), y pulsar Continuar en SENUS.');
  }

  return PlanInstalacion(
    camino: camino,
    modelo: modelo,
    cid: cid,
    rutaBinario: binario,
    direccion: direccion,
    paqueteAnycid: paquete,
    avisos: avisos,
    bloqueado: bloqueado,
  );
}

/// Resultado de meter nuestro payload en un paquete anycid.
class ZipAnycid {
  final List<int> bytes;
  final int tamanoOriginalDelB;
  final int tamanoNuevoDelB;
  final String rutaDentro; // p. ej. tpa/preset/custom/executor.b
  const ZipAnycid({
    required this.bytes,
    required this.tamanoOriginalDelB,
    required this.tamanoNuevoDelB,
    required this.rutaDentro,
  });
}

/// Sustituye `executor.b` dentro de un paquete anycid por nuestro payload,
/// dejando el resto del zip (el `customize_upgrade.xml` y el `executor.jar`)
/// EXACTAMENTE igual: el salto de firma lo hace ese jar original de 2008, no
/// nuestro código. Pública para poder probarla sin aparato.
ZipAnycid armarZipAnycid(List<int> zipOriginal, List<int> payload) {
  final archivo = ZipDecoder().decodeBytes(zipOriginal);
  final salida = Archive();
  var original = -1;
  var ruta = '';
  for (final e in archivo.files) {
    if (!e.isFile) {
      // Las entradas de directorio (tpa/, tpa/preset/, …) se conservan tal
      // cual: el zip del fork las trae y no hay motivo para alterar nada que
      // no sea el .b.
      salida.addFile(ArchiveFile('${e.name.replaceAll(RegExp(r'/$'), '')}/', 0,
          const <int>[])
        ..isFile = false);
      continue;
    }
    if (p.posix.basename(e.name) == 'executor.b') {
      original = e.size;
      ruta = e.name;
      salida.addFile(ArchiveFile(e.name, payload.length, payload));
    } else {
      salida.addFile(ArchiveFile(e.name, e.size, e.content));
    }
  }
  if (original < 0) {
    throw SeftoolError(
        'El paquete anycid no trae ningún executor.b: no sé dónde meter el '
        'payload.');
  }
  final bytes = ZipEncoder().encode(salida);
  if (bytes == null) throw SeftoolError('No pude recomprimir el anycid.');
  return ZipAnycid(
    bytes: bytes,
    tamanoOriginalDelB: original,
    tamanoNuevoDelB: payload.length,
    rutaDentro: ruta,
  );
}

/// El csloader se negó a arrancar los servicios (el «error:29» que documenta
/// la escena para CID53). Se distingue para poder enseñar el diálogo rojo.
class ErrorCsloader implements Exception {
  final String detalle;
  ErrorCsloader(this.detalle);
  @override
  String toString() => detalle;
}

/// Instala senew. Emite los mismos eventos que el respaldo, para que la UI
/// reaproveche el panel de registro y la barra.
class EjecutorInstalacion {
  final RespaldoRollback respaldo;
  final Seftool _seftool;
  final PlanInstalacion plan;

  EjecutorInstalacion({
    required this.respaldo,
    Seftool? seftool,
    String? puerto,
    String? rutaSenew,
    String? rutaPayload,
    Camino? forzarCamino,
  })  : _seftool = seftool ??
            Seftool(
              raiz: Seftool.raizPredeterminada,
              puerto: puerto ?? Seftool.autodetectarPuerto() ?? '',
            ),
        plan = planificar(respaldo,
            rutaSenew: rutaSenew,
            rutaPayload: rutaPayload,
            forzarCamino: forzarCamino);

  Stream<EventoRespaldo> correr() async* {
    if (plan.bloqueado) {
      yield EventoRespaldo(
          error: 'No se puede instalar:\n${plan.avisos.join('\n\n')}');
      return;
    }
    try {
      _seftool.exigirBinario();
    } on SeftoolError catch (e) {
      yield EventoRespaldo(error: '${e.motivo}\n${e.remedio ?? ''}');
      return;
    }
    // El respaldo es de ESTE aparato: seftool se niega (--imei) a escribir en
    // otro teléfono que se haya enchufado entre una orden y la siguiente. Sin
    // `if`: un respaldo sin IMEI utilizable hace fallar la primera orden con
    // puerto («El IMEI esperado…») antes de ejecutar nada; nunca se escribe
    // sin poder comprobar de quién es el teléfono.
    _seftool.imeiEsperado = respaldo.serie;

    yield EventoRespaldo(logLinea: 'Camino: ${plan.nombre}');
    yield EventoRespaldo(
        logLinea: 'Respaldo de rollback: ${respaldo.carpeta}');
    for (final a in plan.avisos) {
      yield EventoRespaldo(logLinea: '⚠ $a');
    }

    try {
      // OJO: `await for`, no `yield*`. Un error que lanza un sub-generador y
      // se reenvía con `yield*` NO lo atrapan los `catch` de aquí abajo: se
      // iba directo al flujo de salida y el ErrorCsloader nunca llegaba a ser
      // el aviso «CSLOADER29:» que la pantalla espera.
      final Stream<EventoRespaldo> camino;
      switch (plan.camino) {
        case Camino.anycidPayload:
          camino = _correrAnycid();
          break;
        case Camino.anycidReemplazoFrio:
          camino = _correrAnycidReemplazoFrio();
          break;
        case Camino.reemplazoFrio:
          camino = _correrReemplazoFrio();
          break;
      }
      await for (final ev in camino) {
        yield ev;
      }
    } on ErrorCsloader catch (e) {
      yield EventoRespaldo(error: 'CSLOADER29: ${e.detalle}');
    } on SeftoolError catch (e) {
      yield EventoRespaldo(error: '${e.motivo}\n${e.remedio ?? ''}');
    } catch (e) {
      yield EventoRespaldo(error: '$e');
    }
  }

  // ---------------- A) reemplazo frío ---------------- //

  Stream<EventoRespaldo> _correrReemplazoFrio() async* {
    final bin = plan.rutaBinario!;
    final dir = plan.direccion!;
    yield EventoRespaldo(
        logLinea: 'Binario: $bin\n'
            'Destino: 0x${dir.toRadixString(16).toUpperCase()}');

    // Trampa 4 de seftool.dart: `flash main` exige BABE.
    yield const EventoRespaldo(
        logLinea: '> conversión a BABE (flash main no acepta binario crudo)');
    final cola = <EventoRespaldo>[];
    final babe = await _seftool.convertirABabe(bin, dir,
        alVuelo: (l) => cola.add(EventoRespaldo(logLinea: l.texto)));
    yield* Stream.fromIterable(cola);
    yield EventoRespaldo(logLinea: 'BABE: $babe');

    // SENUS NUNCA pasa `--break-rsa` (escribe un bootloader parchado y exige
    // una confirmación humana en la terminal): `planificar` bloquea los
    // aparatos que lo necesitarían (necesitaBreakRsa), así que aquí no llegan.
    await for (final l
        in _seftool.correr(['flash', 'main', babe], escribe: true)) {
      yield EventoRespaldo(logLinea: l.texto, progreso: l.progreso);
    }
    yield const EventoRespaldo(
        logLinea: 'Grabado. Desconecta y arranca el teléfono.');
  }

  // ---------------- B) anycid + payload ---------------- //

  Stream<EventoRespaldo> _correrAnycid() async* {
    final destinoNombre = '${plan.paqueteAnycid}.zip';
    final zipOriginal = File(p.join(_seftool.raiz, 'anycid', destinoNombre));
    if (!zipOriginal.existsSync() && !_seftool.ensayo) {
      throw SeftoolError(
        'No está el paquete anycid que pide el aparato: $destinoNombre',
        remedio: 'Se esperaba en ${zipOriginal.path}',
      );
    }

    // 1. Armar en /tmp una copia del zip con NUESTRO executor.b dentro.
    final tmp = await Directory.systemTemp.createTemp('senus-anycid-');
    final zipNuestro = File(p.join(tmp.path, destinoNombre));
    yield EventoRespaldo(logLinea: '> preparando ${zipNuestro.path}');

    if (_seftool.ensayo) {
      yield EventoRespaldo(
          logLinea: '  [ensayo] se sustituiría tpa/preset/custom/executor.b '
              'por ${plan.rutaBinario}');
    } else {
      final payload = await File(plan.rutaBinario!).readAsBytes();
      final sha = sha256.convert(payload).toString();
      final z = armarZipAnycid(await zipOriginal.readAsBytes(), payload);
      yield EventoRespaldo(
          logLinea: '  ${z.rutaDentro}: ${z.tamanoOriginalDelB} B → '
              '${z.tamanoNuevoDelB} B (sha256 ${sha.substring(0, 16)}…)');
      await zipNuestro.writeAsBytes(z.bytes);
      yield EventoRespaldo(logLinea: '  zip armado: ${z.bytes.length} B');
    }

    // 2. upload-anycid SÓLO lee ./anycid/<target>.zip de la raíz del fork.
    //    Guardamos el original, ponemos el nuestro, y lo reponemos SIEMPRE.
    final guardado =
        File('${zipOriginal.path}.original-senus');
    var hayQueReponer = false;
    try {
      if (!_seftool.ensayo) {
        if (!guardado.existsSync()) {
          await zipOriginal.copy(guardado.path);
          yield EventoRespaldo(
              logLinea: '  original guardado en ${guardado.path}');
        }
        await zipNuestro.copy(zipOriginal.path);
        hayQueReponer = true;
        yield EventoRespaldo(
            logLinea: '  nuestro zip puesto en ${zipOriginal.path}');
      } else {
        yield EventoRespaldo(
            logLinea: '  [ensayo] se copiaría a ${zipOriginal.path} '
                '(con el original a salvo en ${guardado.path})');
      }

      // 3. Subida.
      var arrancoFsx = false;
      var fallo = false;
      await for (final l in _seftool.subirAnycid()) {
        yield EventoRespaldo(logLinea: l.texto, progreso: l.progreso);
        final t = l.texto;
        if (t.contains('Starting FSX server') && t.contains('started')) {
          arrancoFsx = true;
        }
        if (RegExp(r'error:?\s*29').hasMatch(t) ||
            t.contains('refused to start')) {
          fallo = true;
        }
        if (t.contains('Starting FSX server') && t.contains('failed')) {
          fallo = true;
        }
      }
      if (fallo || (!arrancoFsx && !_seftool.ensayo)) {
        throw ErrorCsloader(
          'El CSLoader no arrancó sus servicios (el «error:29» que la escena '
          'documenta para CID53). Esto pasa ANTES de que el AMS llegue a ver '
          'nuestro .b, así que no dice nada todavía sobre el CRC-24 de la '
          'palabra 0x04: lo que falla es la entrada por el cable. Hay que '
          'MEDIRLO, no reintentar a ciegas — '
          'seftool-senew/docs/CID53_RUTA.md §4 y cid53_payload.md §4.',
        );
      }

      yield const EventoRespaldo(
          logLinea: '────────────────────────────────────────');
      yield const EventoRespaldo(
          logLinea: 'PASO MANUAL, EN EL TELÉFONO (no se puede automatizar):');
      yield const EventoRespaldo(
          logLinea: '  1. Desconecta el cable y pon la SIM.');
      yield const EventoRespaldo(logLinea: '  2. Enciende el teléfono.');
      yield const EventoRespaldo(
          logLinea: '  3. Menú → Juegos → abre «executer» y acepta.');
      yield const EventoRespaldo(
          logLinea: 'Si el AMS rechaza el .b, es el CRC-24 de 0x04: plan B en '
              'docs/cid53_payload.md. La NOR sigue intacta; un reset físico '
              'devuelve el firmware SEMC.');
    } finally {
      if (hayQueReponer && guardado.existsSync()) {
        try {
          await guardado.copy(zipOriginal.path);
        } catch (_) {}
      }
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  }

  // ---------------- C) anycid + reemplazo frío ---------------- //

  /// 1. upload-anycid con el executor.b canónico del fork (NO lo sustituimos:
  ///    aquí no estamos cargando senew como payload en SDRAM; usamos el
  ///    MIDlet para cebar el exploit del AMS y nada más).
  /// 2. [HUMANO] Juegos → executer → reconectar. SENUS pausa aquí.
  /// 3. convert raw2babe del main de senew.
  /// 4. flash-anycid main <babe>.
  Stream<EventoRespaldo> _correrAnycidReemplazoFrio() async* {
    final bin = plan.rutaBinario!;
    final dir = plan.direccion!;
    final destinoNombre = '${plan.paqueteAnycid}.zip';
    final zipOriginal = File(p.join(_seftool.raiz, 'anycid', destinoNombre));
    if (!zipOriginal.existsSync() && !_seftool.ensayo) {
      throw SeftoolError(
          'No está el paquete anycid que pide el aparato: $destinoNombre',
          remedio: 'Se esperaba en ${zipOriginal.path}');
    }

    yield EventoRespaldo(logLinea: 'Binario: $bin');
    yield EventoRespaldo(
        logLinea: 'Destino en NOR: 0x${dir.toRadixString(16).toUpperCase()}');
    yield EventoRespaldo(logLinea: 'Paquete anycid: $destinoNombre');

    // ---- Paso 1: upload-anycid (sin sustituir el .b)
    yield const EventoRespaldo(
        logLinea: '────────────────────────────────────────');
    yield const EventoRespaldo(
        logLinea: 'Paso 1/4: subir el paquete anycid al teléfono');
    var arrancoFsx = false;
    var fallo = false;
    await for (final l in _seftool.subirAnycid()) {
      yield EventoRespaldo(logLinea: l.texto, progreso: l.progreso);
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
    if (fallo || (!arrancoFsx && !_seftool.ensayo)) {
      throw ErrorCsloader(
        'El CSLoader no arrancó sus servicios (el «error:29» que la escena '
        'documenta para CID53). La subida del paquete anycid falló ANTES de '
        'tocar la NOR: no se escribió nada. Hay que MEDIRLO, no reintentar '
        'a ciegas — seftool-senew/docs/CID53_RUTA.md §4.',
      );
    }

    // ---- Paso 2: pausa manual (cerrojo físico)
    yield const EventoRespaldo(
        logLinea: '────────────────────────────────────────');
    yield const EventoRespaldo(
        logLinea: 'Paso 2/4: paso manual en el teléfono (cerrojo físico)');
    final confirmar = Completer<bool>();
    yield EventoRespaldo(
      pausa: confirmar,
      pausaTitulo: 'Abre «executer» en el teléfono',
      pausaDetalle:
          'Para que el fork pueda escribir el main sin firma, el MIDlet '
          '«executer» tiene que estar corriendo en el teléfono. Haz esto en '
          'orden:\n\n'
          '1. Desconecta el cable DCU-60.\n'
          '2. Pon la SIM en el teléfono.\n'
          '3. Enciende el teléfono normalmente.\n'
          '4. Menú → Juegos → abre «executer».\n'
          '5. Cuando el MIDlet esté activo (ventana del exploit cargada), '
          'apaga el teléfono.\n'
          '6. Mantén la tecla C pulsada mientras vuelves a conectar el '
          'cable para que entre en modo servicio.\n'
          '7. Pulsa Continuar aquí.\n\n'
          'Si cancelas, no se escribe nada: la NOR queda como está. El '
          'respaldo de rollback sigue intacto en\n${respaldo.carpeta}',
    );
    final seguir = await confirmar.future;
    if (!seguir) {
      yield const EventoRespaldo(
          cancelado: true,
          logLinea: 'Cancelado por el usuario. Nada se escribió en la NOR.');
      return;
    }

    // ---- Paso 3: convertir a BABE
    yield const EventoRespaldo(
        logLinea: '────────────────────────────────────────');
    yield const EventoRespaldo(
        logLinea: 'Paso 3/4: convertir el main de senew a BABE');
    final cola = <EventoRespaldo>[];
    final babe = await _seftool.convertirABabe(bin, dir,
        alVuelo: (l) => cola.add(EventoRespaldo(logLinea: l.texto)));
    yield* Stream.fromIterable(cola);
    yield EventoRespaldo(logLinea: 'BABE: $babe');

    // ---- Paso 4: flash-anycid main
    // seftool exige --cid (el ACTIVE CID de identify). Si no se pudo leer,
    // pasa 0 y seftool se niega a escribir: es el fallo seguro.
    final cidNum = int.tryParse(plan.cid) ?? 0;
    yield const EventoRespaldo(
        logLinea: '────────────────────────────────────────');
    yield const EventoRespaldo(
        logLinea: 'Paso 4/4: flash-anycid main (ESCRIBE EN LA NOR)');
    var vioSeguridad = false;
    var executerFalto = false;
    await for (final l in _seftool.grabarMainAnycid(babe, cidNum)) {
      if (l.texto.contains('Security disabled')) vioSeguridad = true;
      if (l.texto.contains('Run executer first')) executerFalto = true;
      yield EventoRespaldo(logLinea: l.texto, progreso: l.progreso);
    }
    if (executerFalto) {
      yield const EventoRespaldo(
          logLinea: 'El fork no vio el executer activo. NO SE ESCRIBIÓ EN LA '
              'NOR: el fallo fue antes del flash main. Puedes reintentar '
              'desde el paso 2 (abrir el MIDlet).');
      return;
    }
    if (!vioSeguridad && !_seftool.ensayo) {
      yield const EventoRespaldo(
          logLinea: '⚠ No se vio «Security disabled =)»: comprueba el '
              'registro antes de dar por bueno el flash.');
    }
    yield const EventoRespaldo(
        logLinea: 'Flash completado. Desconecta y arranca el teléfono — '
            'ahora debería arrancar senew. Si no arranca o se queda colgado, '
            'usa «Volver al firmware original» para restaurar.');
  }
}

/// Vuelta al firmware original desde un respaldo de rollback.
///
/// Por omisión NO reescribe la zona del cargador (0x44000000..0x4413FFFF):
/// el MANIFIESTO del sistema dice «NO SE TOCA», y un corte a mitad de esa
/// zona sí deja el aparato inservible. Se restaura desde el main en adelante,
/// que es lo que senew sobrescribió. `desdeElPrincipio: true` lo fuerza
/// entero, para quien sepa lo que hace.
class EjecutorRestauracion {
  final RespaldoRollback respaldo;
  final AlmacenRespaldos almacen;
  final Seftool _seftool;
  final bool desdeElPrincipio;

  /// Para RED CID52 sin `flash_full.bin` (un respaldo anterior a que SENUS
  /// leyera la NOR por anycid, o que no la trae): si es true, la restauración
  /// recorre SOLO el camino de `write-gdfs` sin pedir pausa, sin tocar el
  /// main. Para los tests. En producción el usuario lo elige en una pausa
  /// humana.
  final bool permitirSoloGdfs;

  /// ¿Este respaldo se restaura con `flash-anycid` en vez de `flash main`?
  /// `flash main` en un W580 RED va por OFLASH con el flashloader FIRMADO y
  /// `flash_babe_fw` rechaza en el host cualquier imagen de `raw2babe`
  /// («Can not check BABE file»): una imagen sin firma solo entra por la rama
  /// anycid del bflash. Pública para poder probarla.
  static bool restauraPorAnycid(RespaldoRollback r) =>
      lecturaNorPara(
              modelo: r.modelo, cid: r.cid ?? '', color: r.color ?? '')
          .via ==
      LecturaNor.anycid;

  EjecutorRestauracion({
    required this.respaldo,
    AlmacenRespaldos? almacen,
    Seftool? seftool,
    String? puerto,
    this.desdeElPrincipio = false,
    this.permitirSoloGdfs = false,
  })  : almacen = almacen ?? AlmacenRespaldos.predeterminado(),
        _seftool = seftool ??
            Seftool(
              raiz: Seftool.raizPredeterminada,
              puerto: puerto ?? Seftool.autodetectarPuerto() ?? '',
            );

  /// Dirección desde la que se reescribe.
  int get direccion => desdeElPrincipio
      ? EjecutorRespaldo.inicioFlash
      : (_direccionMain[respaldo.modelo.toUpperCase()] ??
          EjecutorRespaldo.inicioFlash);

  Stream<EventoRespaldo> correr() async* {
    if (respaldo.simulado) {
      yield const EventoRespaldo(
          error: 'Este respaldo es SIMULADO: no contiene el firmware de un '
              'aparato. No se restaura nada.');
      return;
    }
    try {
      _seftool.exigirBinario();
    } on SeftoolError catch (e) {
      yield EventoRespaldo(error: '${e.motivo}\n${e.remedio ?? ''}');
      return;
    }

    // Antes de leer el respaldo del disco, confirmar que el aparato conectado
    // ES el del respaldo: si no, no se restaura. El respaldo del BUENO escrito
    // en otro W580 pisa su IMEI, su simlock y su calibración.
    yield const EventoRespaldo(
        logLinea:
            '> verificando que el aparato conectado es el del respaldo (identify)…');
    try {
      final info = await _seftool.identify();
      // Un IMEI vacío (o que seftool no aceptaría en --imei) no identifica a
      // nadie: dos vacíos «cuadrarían» y se escribiría sin poder comprobar.
      final imeiCuadra =
          Seftool.imeiValido(info.imei) && info.imei == respaldo.serie;
      final modeloCuadra = info.modeloCorto == respaldo.modelo;
      // identify imprime el CID activo o, si no, el OTP; el respaldo lleva el
      // que vio «identify» cuando se hizo. Comparar literal con el string.
      final cidCuadra = info.cid == (respaldo.cid ?? '');
      if (!(imeiCuadra && modeloCuadra && cidCuadra)) {
        yield EventoRespaldo(
            error: 'El aparato conectado '
                '(${info.modeloCorto}/CID ${info.cid}/IMEI ${info.imei}) '
                'NO es el del respaldo '
                '(${respaldo.modelo}/CID ${respaldo.cid}/IMEI ${respaldo.serie}). '
                'No se restaura nada.');
        return;
      }
      yield EventoRespaldo(
          logLinea:
              '  identify OK: ${info.modeloCorto} CID ${info.cid} IMEI ${info.imei}');
      // Entre esta comprobación y las órdenes que escriben hay varias
      // reconexiones: seftool vuelve a comprobar el IMEI (--imei) en cada
      // sesión, antes de escribir nada.
      _seftool.imeiEsperado = respaldo.serie;
    } on SeftoolError catch (e) {
      yield EventoRespaldo(error: '${e.motivo}\n${e.remedio ?? ''}');
      return;
    }

    final flash = File(respaldo.rutaFlash);
    final gdfs = File(respaldo.rutaGdfsA);
    // Antes `hayFlash` cedía ante ensayo (daba por existente lo que no estaba
    // en disco); eso tapaba el camino parcial para RED CID52 en los tests.
    // Ahora pide el fichero de verdad: en los tests, crear un stub mínimo si
    // se quiere el flujo completo, y dejarlo fuera si se quiere el parcial.
    final hayFlash = flash.existsSync();
    final hayGdfs = gdfs.existsSync();
    if (!hayGdfs) {
      yield EventoRespaldo(error: 'Falta un fichero del respaldo:\n  ${gdfs.path}');
      return;
    }
    // Red parcial para RED CID52 sin flash_full.bin: `read-flash --anycid` no
    // está implementado todavía, así que el respaldo del aparato RED CID52
    // puede quedarse sin main volcado. Permitimos restaurar SOLO el GDFS si
    // el usuario lo confirma. Para otros aparatos sigue siendo error duro.
    var soloGdfs = false;
    if (!hayFlash) {
      final esRedCid52 =
          (respaldo.cid == '52') && ((respaldo.color ?? '').toUpperCase() == 'RED');
      if (!esRedCid52) {
        yield EventoRespaldo(
            error: 'Falta un fichero del respaldo:\n  ${flash.path}');
        return;
      }
      final seguir = Completer<bool>();
      if (permitirSoloGdfs) {
        seguir.complete(true);
      } else {
        yield EventoRespaldo(
          pausa: seguir,
          pausaTitulo: 'Red parcial: solo GDFS — reconecta en modo C',
          pausaDetalle:
              'Este respaldo RED CID52 no trae flash_full.bin (se hizo antes '
              'de que SENUS leyera la NOR por anycid, o ese paso se omitió). '
              'Opciones:\n\n'
              '• Continuar → se restaura SOLO el GDFS. El main se queda como '
              'esté (si senew ya se escribió a medias, no arrancará). Antes de '
              'pulsar Continuar, reconecta el teléfono en modo C: el `identify` '
              'de verificación lo apagó; mantén la tecla C pulsada mientras '
              'enchufas el cable DCU-60.\n'
              '• Cancelar → no se escribe nada. Vuelve a Fábrica y rehaz el '
              'respaldo completo.',
        );
      }
      if (!await seguir.future) {
        yield const EventoRespaldo(
            cancelado: true,
            logLinea: 'Cancelado por el usuario. Nada se escribió.');
        return;
      }
      soloGdfs = true;
      yield const EventoRespaldo(
          logLinea: 'Camino parcial: SOLO GDFS (sin tocar el main).');
    }

    try {
      // ---- 1. Verificar que el respaldo es el que dice ser.
      yield const EventoRespaldo(logLinea: '> verificando SHA-256 del respaldo');
      if (!soloGdfs) {
        if (_seftool.ensayo) {
          yield const EventoRespaldo(
              logLinea: '  [ensayo] flash_full.bin omitido');
        } else {
          final sha = await _sha256(flash);
          if (sha != respaldo.shaFlash) {
            yield EventoRespaldo(
                error: 'El flash_full.bin NO cuadra con su SHA-256.\n'
                    'esperado: ${respaldo.shaFlash}\n'
                    'leído:    $sha\n'
                    'No se restaura nada con un respaldo dudoso.');
            return;
          }
          yield EventoRespaldo(
              logLinea: '  flash_full.bin OK (${sha.substring(0, 16)}…)');
          // El sha solo dice que es el MISMO fichero del respaldo; para
          // escribirlo en la NOR por anycid tiene que además ser un volcado
          // entero y creíble (no 0xFF/0x00 enteros ni uno cortado).
          if (restauraPorAnycid(respaldo)) {
            final malo = await verificarVolcadoNor(flash,
                cxcArticulo: respaldo.cxcArticulo);
            if (malo != null) {
              yield EventoRespaldo(
                  error: 'El flash_full.bin no sirve para restaurar: $malo\n'
                      'No se escribe nada.');
              return;
            }
          }
        }
      }
      // GDFS siempre: tanto en modo real como en ensayo, si está corrupto en
      // disco, lo detectamos ANTES de llamar a write-gdfs. En ensayo el
      // fichero es minúsculo, así que la verificación es inmediata.
      {
        final esperadoGdfs = await respaldo.shaGdfsAResuelto();
        if (esperadoGdfs != null) {
          final shaGdfs = await _sha256(gdfs);
          if (shaGdfs != esperadoGdfs) {
            yield EventoRespaldo(
                error: 'El gdfs_A.bin NO cuadra con su SHA-256.\n'
                    'esperado: $esperadoGdfs\n'
                    'leído:    $shaGdfs\n'
                    'No se escribe el GDFS con un fichero dudoso.');
            return;
          }
          yield EventoRespaldo(
              logLinea: '  gdfs_A.bin OK (${shaGdfs.substring(0, 16)}…)');
        } else {
          yield const EventoRespaldo(
              logLinea:
                  '  gdfs_A.bin sin sha256 de referencia (respaldo antiguo); '
                  'se escribe sin verificar.');
        }
      }

      // ---- 2. Recortar, convertir a BABE y grabar el main (si procede).
      if (!soloGdfs) {
        var origen = flash.path;
        final d = direccion;
        if (!desdeElPrincipio && d != EjecutorRespaldo.inicioFlash) {
          final salto = d - EjecutorRespaldo.inicioFlash;
          yield EventoRespaldo(
              logLinea:
                  'Se restaura desde 0x${d.toRadixString(16).toUpperCase()}'
                  ' (se respeta el cargador, 0x'
                  '${EjecutorRespaldo.inicioFlash.toRadixString(16).toUpperCase()}'
                  '..0x${(d - 1).toRadixString(16).toUpperCase()}).');
          if (!_seftool.ensayo) {
            final recorte =
                File(p.join(respaldo.carpeta, 'restaurar_main.bin'));
            final bytes = await flash.readAsBytes();
            if (salto >= bytes.length) {
              yield const EventoRespaldo(
                  error: 'El volcado es más corto que el salto hasta el main.');
              return;
            }
            await recorte.writeAsBytes(bytes.sublist(salto));
            origen = recorte.path;
            yield EventoRespaldo(
                logLinea: '  recorte: ${await recorte.length()} B → '
                    '${p.basename(recorte.path)}');
          }
        }
        final cola = <EventoRespaldo>[];
        final babe = await _seftool.convertirABabe(origen, d,
            alVuelo: (l) => cola.add(EventoRespaldo(logLinea: l.texto)));
        yield* Stream.fromIterable(cola);

        // El `identify` de verificación (y cualquier orden anterior) apagó el
        // teléfono: hay que volver a entrar en modo C ANTES de la primera
        // orden que escribe. Esta pausa va después de todas las
        // comprobaciones del respaldo, para no pedir nada si ya iba a fallar.
        final alCancelar = 'no se ha escrito nada. El respaldo sigue entero '
            'en ${respaldo.carpeta}.';
        final dRec = DecisionPausa();
        yield* pausar(dRec,
            titulo: tituloReconectar,
            detalle: detalleReconectar(
                cierre: restauraPorAnycid(respaldo)
                    ? 'para subir el paquete anycid'
                    : 'para escribir el main original',
                alCancelar: alCancelar));
        if (!dRec.seguir) {
          yield EventoRespaldo(
              cancelado: true,
              logLinea: 'Cancelado por el usuario antes de escribir: '
                  '$alCancelar');
          return;
        }

        if (restauraPorAnycid(respaldo)) {
          // ---- 3a'. W580 RED: el main entra por la rama anycid (sin firma).
          final res = _ResultadoMainAnycid();
          // `await for`, no `yield*`: el SeftoolError del sub-generador tiene
          // que llegar al catch de esta función (con `yield*` se reenvía).
          await for (final ev in _restaurarMainPorAnycid(
              babe, int.parse(respaldo.cid!), alCancelar, res)) {
            yield ev;
          }
          if (res.cancelado) return;
          if (res.sinExecuter) {
            // La NOR sigue intacta; lo único restaurable es el GDFS. Se
            // pregunta (no se decide por la persona).
            final solo = DecisionPausa();
            yield* pausar(solo,
                titulo: 'Red parcial: main NO restaurado — reconecta en modo C',
                detalle: 'flash-anycid no encontró «executer» activo en '
                    '${res.intentos} intentos, así que el main NO se '
                    'restauró (la NOR no se tocó). Si senew ya reemplazó el '
                    'main original, el teléfono ya no arranca el Java de '
                    'fábrica y ese paso no se puede completar.\n\n'
                    '• Continuar → se escribe SOLO el GDFS del respaldo. '
                    'Antes, reconecta el teléfono en modo C (tecla C + cable).\n'
                    '• Cancelar → no se escribe nada más.');
            if (!solo.seguir) {
              yield const EventoRespaldo(
                  cancelado: true,
                  logLinea: 'Cancelado por el usuario. No se restauró el '
                      'main y tampoco se escribió el GDFS.');
              return;
            }
            soloGdfs = true;
            yield const EventoRespaldo(
                logLinea: 'Camino parcial: SOLO GDFS (el main no se pudo '
                    'restaurar sin «executer»).');
          }
        } else {
          // ---- 3a. Grabar el main original (camino heredado).
          await for (final l in _seftool.grabarMain(babe)) {
            yield EventoRespaldo(logLinea: l.texto, progreso: l.progreso);
          }
        }

        // Pausa humana: seftool cerró el puerto al terminar (el loader_shutdown
        // imprime «Shutdown phone»). El teléfono está apagado; si enlazamos
        // directamente con `write-gdfs`, abrirá un puerto que no responde.
        // Esperamos a que el usuario reconecte en modo C. (Si el main no se
        // restauró y la persona ya aceptó seguir solo con el GDFS, esa pausa
        // ya incluyó la reconexión.)
        if (!soloGdfs) {
          final seguirGdfs = Completer<bool>();
          yield EventoRespaldo(
            pausa: seguirGdfs,
            pausaTitulo: 'Reconecta el teléfono en modo C',
            pausaDetalle:
                'seftool cerró el puerto al terminar «${restauraPorAnycid(respaldo) ? 'flash-anycid' : 'flash main'}» '
                '(equivalente a Shutdown phone). El teléfono está APAGADO.\n\n'
                '1. Mantén la tecla C pulsada mientras enchufas el cable DCU-60.\n'
                '2. Espera a que el aparato aparezca como SEMC USB Flash '
                '(0fce:adde).\n'
                '3. Pulsa Continuar para escribir el GDFS del respaldo.\n\n'
                'Si cancelas: el main original ya se escribió, pero el GDFS NO. '
                'Puedes repetir la restauración cuando puedas reconectar.',
          );
          if (!await seguirGdfs.future) {
            yield const EventoRespaldo(
                cancelado: true,
                logLinea:
                    'Cancelado por el usuario entre el main y write-gdfs. '
                    'El main se escribió; el GDFS NO. Repítelo cuando puedas.');
            return;
          }
        }
      }

      // ---- 3b. Reponer el GDFS. Siempre; es el camino único cuando soloGdfs.
      await for (final l in _seftool.escribirGdfs(gdfs.path)) {
        yield EventoRespaldo(logLinea: l.texto, progreso: l.progreso);
      }

      // ---- 4. Marcar como usado SIN borrar nada.
      await almacen.marcarUsado(respaldo);
      final linea = soloGdfs
          ? 'solo GDFS (el main NO se restauró: red parcial RED CID52)'
          : 'desde 0x${direccion.toRadixString(16).toUpperCase()}'
              '${restauraPorAnycid(respaldo) ? ' por flash-anycid' : ' por flash main'}';
      await File(p.join(respaldo.carpeta, 'restaurado.txt')).writeAsString(
          'Restaurado el ${DateTime.now().toLocal()}\n'
          '$linea\n'
          'El respaldo NO se borra.\n',
          mode: FileMode.append);
      yield EventoRespaldo(
          parcial: soloGdfs,
          logLinea: soloGdfs
              ? 'Hecho, pero PARCIAL: solo se restauró el GDFS; el main NO. '
                  'El respaldo queda marcado «usado» y SIGUE EN SU CARPETA.'
              : 'Hecho. El respaldo queda marcado «usado» y SIGUE EN SU '
                  'CARPETA: se puede volver a usar.');
    } on SeftoolError catch (e) {
      yield EventoRespaldo(error: '${e.motivo}\n${e.remedio ?? ''}');
    } catch (e) {
      yield EventoRespaldo(error: '$e');
    }
  }

  static Future<String> _sha256(File f) async {
    final ctx = AccumulatorSink<Digest>();
    final inp = sha256.startChunkedConversion(ctx);
    await for (final t in f.openRead()) {
      inp.add(t);
    }
    inp.close();
    return ctx.events.single.toString();
  }

  /// `upload-anycid` + el paso de «executer» + `flash-anycid main <babe>
  /// --cid N`, con hasta [maxIntentosExecuter] intentos mientras el fallo sea
  /// «Run executer first» (la NOR no se toca). Cualquier otro fallo NO se
  /// reintenta a ciegas: si ya había empezado a escribir, la NOR puede estar a
  /// medias y lo primero es no apagar nada.
  Stream<EventoRespaldo> _restaurarMainPorAnycid(String babe, int cid,
      String alCancelar, _ResultadoMainAnycid res) async* {
    yield const EventoRespaldo(
        logLinea: '────────────────────────────────────────');
    yield const EventoRespaldo(
        logLinea: 'W580 RED: el main se restaura por flash-anycid (sin '
            'firma); `flash main` no puede con una imagen sin firmar.');
    yield* subirAnycidGuiado(_seftool);

    String? ultimoFallo;
    for (var intento = 1; intento <= maxIntentosExecuter; intento++) {
      res.intentos = intento;
      final dx = DecisionPausa();
      yield* pausar(dx,
          titulo: tituloExecuter(intento: intento),
          detalle: '${detalleExecuter(alCancelar: alCancelar, fallo: ultimoFallo)}'
              '\n\nOJO: si senew ya reemplazó el main original, el teléfono ya '
              'no arranca el Java de fábrica y este paso no podrá completarse.');
      if (!dx.seguir) {
        res.cancelado = true;
        yield EventoRespaldo(
            cancelado: true,
            logLinea: 'Cancelado por el usuario en el paso de «executer»: '
                '$alCancelar');
        return;
      }

      var executerFalto = false;
      var empezoAEscribir = false;
      var otroTelefono = false;
      var identidad = '';
      String? error;
      try {
        await for (final l in _seftool.grabarMainAnycid(babe, cid)) {
          final t = l.texto;
          if (t.contains('Run executer first')) executerFalto = true;
          if (t.contains('flashing block')) empezoAEscribir = true;
          if (t.contains('El aparato conectado dice IMEI') ||
              t.contains('El aparato no ha dicho su IMEI')) {
            identidad = t.trim();
          }
          if (t.contains('imei-check: REFUSED')) {
            otroTelefono = true;
            identidad = [identidad, t.trim()].where((x) => x.isNotEmpty).join('\n');
          }
          yield EventoRespaldo(logLinea: t, progreso: l.progreso);
        }
      } on SeftoolError catch (e) {
        if (e.imeiRechazado) otroTelefono = true;
        error = '${e.motivo}${e.remedio == null ? '' : ' ${e.remedio}'}';
      }
      if (error == null) return; // main restaurado

      if (otroTelefono) {
        // Otro teléfono: ni el ritual del executer, ni un reintento, ni la
        // «red parcial» lo arreglan (y write-gdfs se negaría igual).
        throw SeftoolError(mensajeOtroTelefono,
            remedio: '${identidad.isEmpty ? error : identidad}\n'
                'Repite la restauración con el teléfono del respaldo; el '
                'respaldo sigue entero en ${respaldo.carpeta}.',
            imeiRechazado: true);
      }

      if (executerFalto && !empezoAEscribir) {
        ultimoFallo = 'seftool no encontró el executer activo («Run executer '
            'first»); la NOR no se tocó.';
        yield EventoRespaldo(
            logLinea: 'Intento $intento/$maxIntentosExecuter fallido: '
                '$ultimoFallo');
        continue;
      }
      // Otro fallo: no se reintenta a ciegas.
      throw SeftoolError(
        empezoAEscribir
            ? 'flash-anycid falló MIENTRAS escribía: la NOR puede estar a '
                'medias. NO apagues ni desconectes.'
            : 'flash-anycid falló antes de escribir en la NOR.',
        remedio: '$error Repite la restauración; el respaldo sigue entero en '
            '${respaldo.carpeta}.',
      );
    }
    res.sinExecuter = true;
  }
}

/// Lo que dejó la restauración del main por anycid.
class _ResultadoMainAnycid {
  bool cancelado = false;

  /// Se acabaron los intentos sin que el executer estuviera activo (la NOR
  /// quedó intacta).
  bool sinExecuter = false;
  int intentos = 0;
}
