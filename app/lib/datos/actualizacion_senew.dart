// Actualizar senew: los 11 pasos y la recuperación. Es el §6.1 del diseño sin su
// paso de respaldo: decisión de Adrián, 1-nov-2026. Quien ya tiene senew no
// depende de ningún respaldo del sistema original, y se puede actualizar el
// teléfono de otra persona: aquí no hay IMEI ni modo flash. Lo que protege es
// verificar la imagen y guardar el main actual antes de borrar.
//
//   1 comprobar · 2 identificar · 3 descargar y verificar · 4 confirmar ·
//   5 entrar al BL · 6 guardar el main · 7 WIPE · 8 WRITE desde 0x400 y CRC ·
//   9 WRITE de la región 0 y CRC · 10 SALIR · 11 comprobar el build
//
// Hasta el paso 6, senew sigue intacto y cualquier fallo se cancela; si ya se
// estaba en el BL, se sale con SALIR. Desde el paso 7, un corte deja el teléfono
// sin vectores, en el BL, y `recuperar` reanuda desde lo que se guardó ANTES de
// borrar. Lo que no se puede arreglar por USB (§7 del diseño) no se esconde: se
// informa con [FinAct.sinVuelta].
//
// Este fichero no sabe de libusb ni de pantallas: todo llega por los puertos,
// para poder inyectar un corte en cada paso.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../mtp/canal_gestion.dart';
import '../mtp/sesion_mtp.dart';
import '../mtp/transporte.dart' show TransporteError;
import 'backend_semakers.dart';
import 'cliente_bl_installer.dart';
import 'cliente_puente.dart';
import 'conexion_telefono.dart';
import 'indice_semakers.dart';
import 'telefono.dart';
import 'transporte_bl.dart';

enum PasoAct {
  comprobar('Comprobar el teléfono'),
  identificar('Identificar el sistema'),
  descargar('Descargar y verificar'),
  confirmar('Confirmar'),
  entrarBl('Entrar al bootloader'),
  guardarMain('Guardar el sistema actual'),
  borrar('Borrar el sistema'),
  grabarResto('Grabar el sistema nuevo'),
  grabarRegion0('Grabar los vectores de arranque'),
  salir('Reiniciar'),
  comprobarFinal('Comprobar la versión');

  final String titulo;
  const PasoAct(this.titulo);
}

/// Cómo acabó.
enum FinAct {
  /// El teléfono arrancó el build pedido.
  hecho,

  /// La persona dijo que no en SENUS. Nada se tocó.
  cancelado,

  /// La persona dijo «No» en el teléfono. Nada se tocó.
  denegado,

  /// Este sistema no se actualiza por aquí: no tiene BL (W600, W810). No es un
  /// fallo y no es un problema de conexión.
  noDisponible,

  /// Falló antes de borrar: senew sigue intacto.
  fallo,

  /// Corte durante la grabación: hay que entrar en modo recuperación.
  corte,

  /// La imagen no se pudo grabar y se repuso el sistema que había.
  repuesto,

  /// Arrancó otro build. Se informa y no se reintenta.
  buildDistinto,

  /// Arrancó un senew que no se puede identificar por USB.
  sinConfirmar,

  /// No volvió `1209:0001` ni se ve el BL. Tras un SALIR con el CRC bueno, lo
  /// normal es que se apagara: basta con encenderlo. El resto, §7 del diseño.
  sinVuelta,
}

class ResultadoAct {
  final FinAct fin;
  final String mensaje;
  final String? remedio;

  /// La sesión que quedó abierta al volver senew, si volvió.
  final SesionMtp? sesion;
  final Telefono? telefono;

  const ResultadoAct(this.fin, this.mensaje,
      {this.remedio, this.sesion, this.telefono});

  bool get bien => fin == FinAct.hecho;
}

class EventoAct {
  final PasoAct? paso;
  final String? linea;
  final double? progreso;

  /// Lo que la persona tiene que ver mientras se espera al teléfono.
  final String? aviso;
  const EventoAct({this.paso, this.linea, this.progreso, this.aviso});
}

/// Lo que se le enseña a la persona en el paso 4.
class ResumenConfirmacion {
  final String versionOrigen;
  final int buildOrigen;
  final String versionDestino;
  final int buildDestino;
  final String notas;
  final int? bateria;
  const ResumenConfirmacion({
    required this.versionOrigen,
    required this.buildOrigen,
    required this.versionDestino,
    required this.buildDestino,
    required this.notas,
    required this.bateria,
  });

  bool get haciaAtras => buildDestino < buildOrigen;
  bool get misma => buildDestino == buildOrigen;
}

/// Los dispositivos USB, tal como aparecen y desaparecen durante el flujo.
abstract class PuertosUsb {
  /// Espera a senew (1209:0001), abre la sesión y devuelve; null si no llega.
  Future<SesionMtp?> esperarSenew(Duration plazo);

  /// Espera al BL (1209:0002 o 1209:0003) y lo abre; null si no llega.
  Future<TransporteBl?> esperarBl(Duration plazo);

  /// EP0 de un senew en marcha, para el puente; null si no está.
  Future<TransporteBl?> abrirEp0Senew(Duration plazo);
}

/// Lo que hay guardado para reanudar.
class Pendiente {
  final String modelo;
  final int buildOrigen;
  final int buildDestino;
  final String versionDestino;
  final String sha256;
  final int bytes;
  final int crc32;
  final String? mainGuardado;
  final String? shaGuardado;

  const Pendiente({
    required this.modelo,
    required this.buildOrigen,
    required this.buildDestino,
    required this.versionDestino,
    required this.sha256,
    required this.bytes,
    required this.crc32,
    required this.mainGuardado,
    required this.shaGuardado,
  });

  Map<String, dynamic> aJson() => {
        'modelo': modelo,
        'build_origen': buildOrigen,
        'build_destino': buildDestino,
        'version_destino': versionDestino,
        'sha256': sha256,
        'bytes': bytes,
        'crc32': crc32,
        'main_guardado': mainGuardado,
        'sha_guardado': shaGuardado,
      };

  /// Uno guardado por una versión anterior trae además `imei`: se ignora.
  static Pendiente deJson(Map<String, dynamic> j) => Pendiente(
        modelo: j['modelo'] as String,
        buildOrigen: j['build_origen'] as int,
        buildDestino: j['build_destino'] as int,
        versionDestino: j['version_destino'] as String,
        sha256: j['sha256'] as String,
        bytes: j['bytes'] as int,
        crc32: j['crc32'] as int,
        mainGuardado: j['main_guardado'] as String?,
        shaGuardado: j['sha_guardado'] as String?,
      );
}

/// Carpeta de la actualización en curso y de los mains guardados.
class AlmacenActualizacion {
  final Directory base;
  AlmacenActualizacion(this.base);

  Directory get _pend => Directory(p.join(base.path, 'pendiente'));
  File get _estado => File(p.join(_pend.path, 'estado.json'));
  File get _main => File(p.join(_pend.path, 'main.bin'));
  File get _manif => File(p.join(_pend.path, 'manifiesto.json'));
  File get _firma => File(p.join(_pend.path, 'manifiesto.json.sig'));

  Future<void> _escribir(File f, List<int> b) => escribirAtomico(f, b);

  /// `estado.json` se escribe el último: sin él, lo demás no cuenta.
  Future<void> guardarPendiente(
      Pendiente q, Uint8List main, ManifiestoVerificado m) async {
    await _escribir(_main, main);
    await _escribir(_manif, m.bytes);
    await _escribir(_firma, m.firma);
    await _escribir(_estado, utf8.encode(jsonEncode(q.aJson())));
  }

  /// El teléfono ya corre el build pendiente: no queda nada que reanudar.
  Future<void> olvidarSiYaArranco(int build) async {
    final q = await leerPendiente();
    if (q != null && q.buildDestino == build) await borrarPendiente();
  }

  Future<void> borrarPendiente() async {
    if (await _estado.exists()) await _estado.delete();
    if (await _pend.exists()) await _pend.delete(recursive: true);
  }

  Future<Pendiente?> leerPendiente() async {
    if (!await _estado.exists()) return null;
    try {
      return Pendiente.deJson(jsonDecode(await _estado.readAsString())
          as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// La imagen pendiente, reverificada por entero: sha256, firma del manifiesto
  /// y forma. Null si algo no cuadra: mejor no grabar que grabar a ciegas.
  Future<Uint8List?> imagenPendiente(
      Pendiente q, List<Uint8List> claves) async {
    try {
      final b = await _main.readAsBytes();
      final mb = await _manif.readAsBytes();
      final fb = await _firma.readAsBytes();
      if (sha256De(b) != q.sha256 || b.length != q.bytes) return null;
      if (crc32DeDatos(b) != q.crc32) return null;
      if (!firmaValida(mb, fb, claves)) return null;
      final m = jsonDecode(utf8.decode(mb)) as Map<String, dynamic>;
      if ((m['main'] as Map<String, dynamic>)['sha256'] != q.sha256) return null;
      if (m['build'] != q.buildDestino) return null;
      return problemaDeMain(b) == null ? b : null;
    } catch (_) {
      return null;
    }
  }

  /// Guarda el main leído del teléfono, sin el 0xFF del final.
  Future<(String, String)> guardarMain(Uint8List crudo) async {
    var fin = crudo.length;
    while (fin > 0 && crudo[fin - 1] == 0xFF) {
      fin--;
    }
    final b = Uint8List.sublistView(crudo, 0, fin);
    final sha = sha256De(b);
    final f = File(p.join(base.path, 'mains', 'main_$sha.bin'));
    await _escribir(f, b);
    return (f.path, sha);
  }

  Future<Uint8List?> leerMainGuardado(String? ruta, String? sha) async {
    if (ruta == null || sha == null) return null;
    final f = File(ruta);
    if (!await f.exists()) return null;
    final b = await f.readAsBytes();
    if (sha256De(b) != sha || problemaDeMain(b) != null) return null;
    return b;
  }
}

class _Corte implements Exception {
  final String detalle;
  const _Corte(this.detalle);
}

class ActualizadorSenew {
  final PuertosUsb puertos;
  final ClienteBackend backend;
  final AlmacenActualizacion almacen;

  /// Paso 4. Sin confirmación no se sigue.
  final Future<bool> Function(ResumenConfirmacion) confirmar;

  /// La batería no se puede medir (sis28h no tiene `SEN_INFO`): la persona
  /// confirma que hay al menos [bateriaMinimaPct]. Sin esto, no se sigue.
  final Future<bool> Function()? confirmarBateria;
  final void Function(EventoAct)? alEvento;

  /// Por debajo, no se empieza: un apagón a mitad es lo que no se arregla.
  static const int bateriaMinimaPct = 30;

  /// Plazos. Las pruebas los bajan.
  final Duration plazoBl;
  final Duration plazoSenew;
  final Duration sondeoBl;
  final Duration pausaEntrarBl;
  final Duration plazoEntrarBl;
  final Duration esperaTarjeta;

  ActualizadorSenew({
    required this.puertos,
    required this.backend,
    required this.almacen,
    required this.confirmar,
    this.confirmarBateria,
    this.alEvento,
    this.plazoBl = const Duration(seconds: 30),
    this.plazoSenew = const Duration(seconds: 120),
    this.sondeoBl = const Duration(milliseconds: 50),
    this.pausaEntrarBl = const Duration(milliseconds: 500),
    this.plazoEntrarBl = const Duration(seconds: 60),
    this.esperaTarjeta = esperaTarjetaPuente,
  });

  void _paso(PasoAct p) => alEvento?.call(EventoAct(paso: p));
  void _log(String s) => alEvento?.call(EventoAct(linea: s));
  void _prog(double f) => alEvento?.call(EventoAct(progreso: f));

  /// Antes de cada espera en la que se le pide aceptar en el teléfono.
  void _avisarEncendido() =>
      alEvento?.call(const EventoAct(aviso: avisoEncendido));

  /// El teléfono no volvió tras un SALIR con el CRC bueno. Lo normal es que se
  /// apagara o que nadie aceptara: ni el teléfono está dañado ni hay que grabar
  /// otra vez. El riesgo del §7 existe, y se deja dicho en el registro.
  ResultadoAct _noVolvio(bool nueva) {
    _log('Si al encenderlo no llegara a arrancar, queda el rescate por Far y '
        'jdflasher (§7 del diseño). Lo guardado sigue en la carpeta de SENUS.');
    return ResultadoAct(
        FinAct.sinVuelta,
        nueva
            ? 'La grabación fue correcta: el CRC del sistema nuevo coincide. El '
                'teléfono no ha vuelto por USB, y basta con encenderlo.'
            : 'El sistema que había quedó repuesto y su CRC coincide. El '
                'teléfono no ha vuelto por USB, y basta con encenderlo.',
        remedio: 'Si se apagó, enciéndelo; si sigue encendido, acepta el aviso '
            'de conexión. Después vuelve a conectar: no hace falta grabar de '
            'nuevo.');
  }

  Future<void> _cerrar(SesionMtp? s) async {
    try {
      await s?.cerrar();
    } catch (_) {
      // El teléfono pudo irse ya: es lo que se espera tras entrar al BL.
    }
  }

  /// Los pasos del 1 al 11.
  Future<ResultadoAct> actualizar({
    required SesionMtp sesion,
    required Telefono telefono,
    required ReleaseIndice destino,
  }) async {
    SesionMtp? ses = sesion;

    // Antes de entrar al BL, un final no cierra nada: la sesión sigue viva y la
    // pantalla la sigue usando. Si ya se cerró, va null y hay que reconectar.
    ResultadoAct fin(FinAct f, String m, {String? remedio}) => ResultadoAct(
        f, m,
        remedio: remedio, sesion: ses, telefono: ses == null ? null : telefono);

    // ---- 1. Comprobar
    _paso(PasoAct.comprobar);
    if (telefono.modelo != Modelo.w580) {
      return fin(
          FinAct.noDisponible,
          'Este teléfono no tiene bootloader propio: actualizar desde SENUS no '
          'está disponible. No se tocó nada.');
    }
    SenInfo? info;
    if (telefono.canalGestion) {
      try {
        info = await CanalGestion(ses).info();
      } on CanalError catch (e) {
        return fin(FinAct.fallo, 'SEN_INFO falló: $e. No se tocó nada.');
      } on CanalMalFormado catch (e) {
        return fin(FinAct.fallo, '$e. No se tocó nada.');
      }
      final b = info.bateria;
      if (b != null && b < bateriaMinimaPct && !info.cargando) {
        return fin(
            FinAct.fallo,
            'La batería está al $b %. Hace falta el $bateriaMinimaPct % para '
            'actualizar. No se tocó nada.',
            remedio: 'Carga el teléfono y vuelve a intentarlo.');
      }
    }

    // ---- 2. Identificar
    _paso(PasoAct.identificar);
    int buildOrigen;
    String versionOrigen;
    EntradaPuente? puente;
    if (info != null) {
      buildOrigen = info.build;
      versionOrigen = info.version;
      _log('senew ${info.version} build ${info.build}, API ${info.api}');
    } else {
      // Sin canal: solo el puente dice qué compilación es.
      await _cerrar(ses);
      ses = null;
      final ep0 = await puertos.abrirEp0Senew(const Duration(seconds: 10));
      if (ep0 == null) {
        return const ResultadoAct(FinAct.fallo,
            'El teléfono no contesta por USB. No se tocó nada.');
      }
      String? id;
      try {
        id = await ClientePuente(ep0).identificador();
      } on TransporteError {
        id = null;
      } finally {
        await ep0.cerrar();
      }
      puente = id == null ? null : entradaPuente(id);
      if (puente == null) {
        return ResultadoAct(
            FinAct.fallo,
            'Este senew no tiene canal de gestión y no es una compilación '
            'conocida (${id ?? 'sin puente'}). SENUS se niega: las direcciones '
            'de la tabla no valdrían. No se tocó nada.',
            remedio: 'Hay que reinstalar senew.');
      }
      buildOrigen = puente.build;
      versionOrigen = puente.version;
      _log('Identificado por el puente: $id (build $buildOrigen)');
    }

    // ---- 3. Descargar y verificar
    _paso(PasoAct.descargar);
    final ReleaseDescargada rel;
    try {
      verificarAparato(destino,
          modelo: info?.modelo ?? 'w580',
          soc: info?.soc ?? 'DB2020',
          buildOrigen: buildOrigen,
          blVersion: info?.blVersion ?? 0);
      rel = await backend.descargarRelease(destino, alProgreso: (h, t) {
        if (t > 0) _prog(h / t);
      });
    } on ErrorVerificacion catch (e) {
      return fin(FinAct.fallo, '$e No se tocó nada.');
    } on SinRed catch (e) {
      return fin(FinAct.fallo,
          'No se pudo descargar la imagen: $e. No se tocó nada.');
    }
    _log('Imagen verificada: ${rel.main.length} B, sha256 '
        '${rel.release.mainSha256.substring(0, 16)}…');

    // ---- 4. Confirmar
    _paso(PasoAct.confirmar);
    final si = await confirmar(ResumenConfirmacion(
      versionOrigen: versionOrigen,
      buildOrigen: buildOrigen,
      versionDestino: destino.version,
      buildDestino: destino.build,
      notas: rel.notas,
      bateria: info?.bateria,
    ));
    if (!si) return fin(FinAct.cancelado, 'Cancelado. No se tocó nada.');
    if (info?.bateria == null) {
      final c = confirmarBateria;
      if (c == null || !await c()) {
        return fin(
            FinAct.cancelado,
            'Sin saber que hay al menos el $bateriaMinimaPct % de batería no se '
            'sigue. No se tocó nada.');
      }
    }

    // ---- 5. Entrar al BL
    _paso(PasoAct.entrarBl);
    if (info != null) {
      RespuestaEntrarBl resp;
      try {
        _log('Acepta «¿Actualizar el sistema?» en el teléfono: sube a «Sí» y '
            'pulsa OK.');
        resp = await CanalGestion(ses!)
            .entrarBl(pausa: pausaEntrarBl, plazo: plazoEntrarBl);
      } on CanalError catch (e) {
        // El puente pide soltar la sesión; si no hay puente, sigue viva.
        if (!info.puenteCompilado) {
          return fin(FinAct.fallo,
              'El teléfono no quiso entrar al bootloader: $e. No se tocó nada.');
        }
        await _cerrar(ses);
        ses = null;
        if (!await _entrarPorPuenteSiHay()) {
          return fin(FinAct.fallo,
              'El teléfono no quiso entrar al bootloader: $e. No se tocó nada.',
              remedio: 'Vuelve a conectar el teléfono.');
        }
        resp = RespuestaEntrarBl.aceptada;
      }
      if (resp == RespuestaEntrarBl.denegada) {
        return fin(
            FinAct.denegado, 'Se dijo «No» en el teléfono. No se tocó nada.');
      }
      if (resp == RespuestaEntrarBl.noDisponible) {
        return fin(
            FinAct.noDisponible,
            'Este sistema no tiene bootloader propio: actualizar desde SENUS no '
            'está disponible. No se tocó nada.');
      }
      if (resp == RespuestaEntrarBl.sinRespuesta) {
        return fin(
            FinAct.fallo, 'Nadie contestó en el teléfono. No se tocó nada.');
      }
      // Dijo «Sí»: el teléfono ya se va. Se suelta el USB sin CloseSession.
      await ses?.soltar();
      ses = null;
    } else {
      await _cerrar(ses);
      ses = null;
      final ep0 = await puertos.abrirEp0Senew(const Duration(seconds: 30));
      if (ep0 == null) {
        return const ResultadoAct(FinAct.fallo,
            'El teléfono no contesta por USB. No se tocó nada.');
      }
      try {
        await ClientePuente(ep0, esperaTarjeta: esperaTarjeta)
            .entrarAlBl(puente!);
      } on TransporteError catch (e) {
        return ResultadoAct(FinAct.fallo,
            'El puente falló antes de entrar al bootloader: ${e.motivo}.');
      } on PuenteError catch (e) {
        return ResultadoAct(FinAct.fallo,
            'El puente falló antes de entrar al bootloader: ${e.motivo}.');
      } finally {
        await ep0.cerrar();
      }
    }

    final bl = await puertos.esperarBl(plazoBl);
    if (bl == null) {
      return const ResultadoAct(FinAct.sinVuelta,
          'El teléfono no apareció en el bootloader. No se llegó a borrar nada.',
          remedio: 'Desconecta el cable y enciende el teléfono.');
    }
    final cliente = ClienteBlInstaller(bl, sondeo: sondeoBl);
    final InfoBl ib;
    try {
      ib = await cliente.info();
    } on InstaladorBlError catch (e) {
      await bl.cerrar();
      return ResultadoAct(FinAct.fallo, '$e No se borró nada.');
    } on TransporteError catch (e) {
      await bl.cerrar();
      return ResultadoAct(FinAct.fallo,
          'Se perdió el USB al llegar al bootloader: ${e.motivo}. No se borró nada.',
          remedio: 'Reconecta el teléfono: el modo recuperación lo saca de ahí.');
    }
    _log('BL: $ib');
    if (ib.entrada != 1) {
      return _salirSinTocar(cliente, bl,
          'El bootloader dice entrada ${ib.entrada} y se esperaba 1.');
    }
    if (ib.version < destino.blVersionMin) {
      return _salirSinTocar(
          cliente,
          bl,
          'La imagen pide el bootloader ${destino.blVersionMin} y el teléfono '
          'tiene el ${ib.version}.');
    }

    // ---- 6. Guardar el main actual
    _paso(PasoAct.guardarMain);
    final Uint8List crudo;
    final String rutaGuardado, shaGuardado;
    try {
      crudo = await cliente.leerNor(blMainIni, blMainFin - blMainIni,
          alProgreso: (h, t) => _prog(h / t));
      final crc = await cliente.crcNor(blMainIni, crudo.length);
      if (crc != crc32DeDatos(crudo)) {
        return await _salirSinTocar(cliente, bl,
            'Lo leído del teléfono no cuadra con su CRC: se deja como estaba.');
      }
      final g = await almacen.guardarMain(crudo);
      rutaGuardado = g.$1;
      shaGuardado = g.$2;
      _log('Sistema actual guardado en $rutaGuardado');
    } on InstaladorBlError catch (e) {
      return await _salirSinTocar(cliente, bl, 'No se pudo leer el sistema: $e');
    } on FileSystemException catch (e) {
      return await _salirSinTocar(
          cliente, bl, 'No se pudo guardar el sistema actual: ${e.message}.');
    } on TransporteError catch (e) {
      await bl.cerrar();
      return ResultadoAct(FinAct.fallo,
          'Se perdió el USB leyendo el sistema: ${e.motivo}. No se borró nada.',
          remedio: 'El teléfono sigue en el bootloader con su sistema intacto: '
              'reconéctalo y usa el modo recuperación para salir.');
    }

    final q = Pendiente(
      modelo: 'W580',
      buildOrigen: buildOrigen,
      buildDestino: destino.build,
      versionDestino: destino.version,
      sha256: destino.mainSha256,
      bytes: rel.main.length,
      crc32: crc32DeDatos(rel.main),
      mainGuardado: rutaGuardado,
      shaGuardado: shaGuardado,
    );
    // Antes de borrar: desde aquí, esto es lo único que permite reanudar. Sin
    // esto guardado no se borra nada.
    try {
      await almacen.guardarPendiente(q, rel.main, rel.manifiesto);
    } on FileSystemException catch (e) {
      return await _salirSinTocar(cliente, bl,
          'No se pudo guardar lo necesario para reanudar: ${e.message}.');
    }

    return _grabarYArrancar(
      cliente: cliente,
      bl: bl,
      imagen: rel.main,
      q: q,
    );
  }

  Future<bool> _entrarPorPuenteSiHay() async {
    final ep0 = await puertos.abrirEp0Senew(const Duration(seconds: 10));
    if (ep0 == null) return false;
    try {
      final c = ClientePuente(ep0, esperaTarjeta: esperaTarjeta);
      final id = await c.identificador();
      final e = id == null ? null : entradaPuente(id);
      if (e == null) return false;
      _log('SEN_ENTRAR_BL no fue: se entra por el puente ($id).');
      await c.entrarAlBl(e);
      return true;
    } on TransporteError {
      return false;
    } on PuenteError {
      return false;
    } finally {
      await ep0.cerrar();
    }
  }

  Future<ResultadoAct> _salirSinTocar(
      ClienteBlInstaller c, TransporteBl bl, String motivo) async {
    try {
      await c.salir();
    } catch (_) {
      // Si no sale, el modo recuperación lo ve al reconectar.
    }
    await bl.cerrar();
    return ResultadoAct(FinAct.fallo, '$motivo No se borró nada.');
  }

  /// Pasos 7, 8 y 9 con los reintentos del §6.3: el CRC mal se reintenta una
  /// vez y, tras dos fallos, se repone lo guardado. Devuelve true si grabó la
  /// imagen pedida y false si repuso la guardada. Un corte sale por [_Corte].
  Future<bool> _grabar(ClienteBlInstaller c, Uint8List imagen, Pendiente q) async {
    final datos = ClienteBlInstaller.rellenarARegion(imagen);
    for (var intento = 1; intento <= 2; intento++) {
      try {
        await _unaGrabacion(c, datos, imagen.length, q.crc32);
        return true;
      } on InstaladorBlError catch (e) {
        if (e.sinRespuesta) throw _Corte(e.motivo);
        _log('Intento $intento falló: ${e.motivo}');
      } on TransporteError catch (e) {
        throw _Corte(e.motivo);
      }
    }
    final g = await almacen.leerMainGuardado(q.mainGuardado, q.shaGuardado);
    if (g == null) {
      throw const _Corte(
          'La imagen no se pudo grabar y no hay un sistema guardado que reponer.');
    }
    _log('Se repone el sistema que había (${g.length} B).');
    try {
      await _unaGrabacion(c, ClienteBlInstaller.rellenarARegion(g), g.length,
          crc32DeDatos(g));
    } on InstaladorBlError catch (e) {
      throw _Corte('Tampoco se pudo reponer el sistema: ${e.motivo}');
    } on TransporteError catch (e) {
      throw _Corte(e.motivo);
    }
    return false;
  }

  Future<void> _unaGrabacion(
      ClienteBlInstaller c, Uint8List datos, int bytes, int crc) async {
    _paso(PasoAct.borrar);
    await c.borrarMain();
    _paso(PasoAct.grabarResto);
    await c.grabarRestoMain(datos,
        alProgreso: (e, h, t) {
          if (t > 0) _prog(h / t);
        },
        alLog: _log);
    _paso(PasoAct.grabarRegion0);
    await c.grabarRegionCero(datos,
        bytesCrc: bytes, crcEsperado: crc, alLog: _log);
  }

  /// Del paso 7 al 11. La recuperación entra aquí directamente.
  Future<ResultadoAct> _grabarYArrancar({
    required ClienteBlInstaller cliente,
    required TransporteBl bl,
    required Uint8List imagen,
    required Pendiente q,
    bool yaGrabada = false,
  }) async {
    bool nueva = true;
    if (!yaGrabada) {
      try {
        nueva = await _grabar(cliente, imagen, q);
      } on _Corte catch (e) {
        await bl.cerrar();
        return ResultadoAct(FinAct.corte, 'Se cortó la grabación: ${e.detalle}.',
            remedio: 'El teléfono está sin vectores y se queda en el '
                'bootloader. Reconéctalo: SENUS reanuda desde lo guardado.');
      }
    }

    // ---- 10. Salir
    _paso(PasoAct.salir);
    try {
      await cliente.salir();
    } on InstaladorBlError catch (e) {
      // No contestó al SALIR: lo que manda es si senew vuelve.
      _log('SALIR sin respuesta: ${e.motivo}');
    }
    await bl.cerrar();

    // ---- 11. Comprobar
    _paso(PasoAct.comprobarFinal);
    _avisarEncendido();
    final ses = await puertos.esperarSenew(plazoSenew);
    if (ses == null) {
      final otra = await puertos.esperarBl(const Duration(seconds: 3));
      if (otra != null) {
        await otra.cerrar();
        return const ResultadoAct(FinAct.corte,
            'El teléfono volvió al bootloader en lugar de arrancar.',
            remedio: 'Usa el modo recuperación.');
      }
      return _noVolvio(nueva);
    }
    final ResultadoMtp<Telefono> r;
    try {
      r = await leerTelefono(ses);
    } on TransporteError catch (e) {
      // Pudo apagarse aquí mismo: un OK en «Encendido» hace justo esto.
      _log('Se perdió la conexión al comprobar: ${e.motivo}');
      return _noVolvio(nueva);
    }
    if (!r.bien) {
      return ResultadoAct(
          FinAct.sinConfirmar, 'senew volvió, pero no contesta: ${r.mensaje}.',
          sesion: ses);
    }
    final tel = r.valor!;
    await almacen.borrarPendiente();
    final esperado = nueva ? q.buildDestino : q.buildOrigen;
    final g = tel.gestion;
    if (g == null) {
      final ok = await _confirmarPorPuente(esperado);
      return ResultadoAct(
          ok ? FinAct.hecho : FinAct.sinConfirmar,
          ok
              ? 'Listo: senew arrancó (build $esperado, confirmado por el puente).'
              : 'senew arrancó, pero este build no se puede comprobar por USB.',
          sesion: ses,
          telefono: tel);
    }
    if (g.build != esperado) {
      return ResultadoAct(FinAct.buildDistinto,
          'El teléfono arrancó el build ${g.build} y se esperaba el $esperado.',
          remedio: 'SENUS no reintenta solo.', sesion: ses, telefono: tel);
    }
    if (!nueva) {
      return ResultadoAct(FinAct.repuesto,
          'La imagen no se pudo grabar y se repuso el sistema que había.',
          sesion: ses, telefono: tel);
    }
    return ResultadoAct(FinAct.hecho, 'Listo: build ${g.build} en marcha.',
        sesion: ses, telefono: tel);
  }

  Future<bool> _confirmarPorPuente(int build) async {
    final ep0 = await puertos.abrirEp0Senew(const Duration(seconds: 5));
    if (ep0 == null) return false;
    try {
      final id = await ClientePuente(ep0).identificador();
      final e = id == null ? null : entradaPuente(id);
      return e?.build == build;
    } on TransporteError {
      return false;
    } finally {
      await ep0.cerrar();
    }
  }

  /// Reanuda desde lo guardado antes de borrar. Sin nada guardado devuelve
  /// [FinAct.fallo]: la pantalla ofrece elegir otra imagen ([recuperarCon]).
  Future<ResultadoAct> recuperar() async {
    final bl = await puertos.esperarBl(plazoBl);
    if (bl == null) {
      return const ResultadoAct(
          FinAct.fallo, 'No se ve el teléfono en el bootloader.');
    }
    final q = await almacen.leerPendiente();
    if (q == null) {
      await bl.cerrar();
      return const ResultadoAct(FinAct.fallo,
          'No hay una actualización a medias que reanudar.',
          remedio: 'Elige una imagen para grabar.');
    }
    final img = await almacen.imagenPendiente(q, backend.claves);
    if (img == null) {
      await bl.cerrar();
      return const ResultadoAct(FinAct.fallo,
          'Lo guardado no pasa la verificación: no se graba.',
          remedio: 'Elige una imagen para grabar.');
    }
    return _reanudar(ClienteBlInstaller(bl, sondeo: sondeoBl), bl, img, q);
  }

  Future<ResultadoAct> _reanudar(ClienteBlInstaller c, TransporteBl bl,
      Uint8List img, Pendiente q) async {
    try {
      final i = await c.info();
      _log('BL: $i');
      // Si el corte fue después de grabar, no hay nada que repetir.
      final cabeza = await c.leerNor(blMainIni, 64);
      final crc = await c.crcNor(blMainIni, img.length);
      final hecha = crc == q.crc32 &&
          ByteData.sublistView(cabeza).getUint32(0, Endian.little) ==
              ByteData.sublistView(img).getUint32(0, Endian.little);
      if (hecha) _log('La imagen ya estaba entera: solo falta salir.');
      return await _grabarYArrancar(
          cliente: c, bl: bl, imagen: img, q: q, yaGrabada: hecha);
    } on InstaladorBlError catch (e) {
      await bl.cerrar();
      return ResultadoAct(FinAct.corte, 'El BL dejó de contestar: $e.');
    } on TransporteError catch (e) {
      await bl.cerrar();
      return ResultadoAct(FinAct.corte, 'Se cortó otra vez: ${e.motivo}.',
          remedio: 'Reconecta el teléfono: lo guardado sigue ahí.');
    }
  }

  /// Graba otra imagen en un teléfono parado en el BL, sin nada que reanudar.
  Future<ResultadoAct> recuperarCon({
    required Uint8List imagen,
    required int build,
    required String version,
    required ManifiestoVerificado manifiesto,
  }) async {
    final int blMin;
    try {
      blMin = verificarImagenFirmada(imagen, manifiesto, backend.claves,
          build: build, version: version);
    } on ErrorVerificacion catch (e) {
      return ResultadoAct(FinAct.fallo, '$e No se grabó nada.');
    }
    final bl = await puertos.esperarBl(plazoBl);
    if (bl == null) {
      return const ResultadoAct(
          FinAct.fallo, 'No se ve el teléfono en el bootloader.');
    }
    final cliente = ClienteBlInstaller(bl, sondeo: sondeoBl);
    try {
      final ib = await cliente.info();
      if (ib.version < blMin) {
        await bl.cerrar();
        return ResultadoAct(
            FinAct.fallo,
            'La imagen pide el bootloader $blMin y el teléfono tiene el '
            '${ib.version}. No se grabó nada.');
      }
    } on InstaladorBlError catch (e) {
      await bl.cerrar();
      return ResultadoAct(FinAct.fallo, '$e No se grabó nada.');
    } on TransporteError catch (e) {
      await bl.cerrar();
      return ResultadoAct(
          FinAct.fallo, 'Se perdió el USB: ${e.motivo}. No se grabó nada.');
    }
    final q = Pendiente(
      modelo: 'W580',
      buildOrigen: 0,
      buildDestino: build,
      versionDestino: version,
      sha256: sha256De(imagen),
      bytes: imagen.length,
      crc32: crc32DeDatos(imagen),
      mainGuardado: null,
      shaGuardado: null,
    );
    await almacen.guardarPendiente(q, imagen, manifiesto);
    return _reanudar(cliente, bl, imagen, q);
  }

  /// Sale del BL sin tocar nada: para un teléfono que entró y tiene su sistema.
  Future<ResultadoAct> salirDelBl() async {
    final bl = await puertos.esperarBl(plazoBl);
    if (bl == null) {
      return const ResultadoAct(
          FinAct.fallo, 'No se ve el teléfono en el bootloader.');
    }
    final c = ClienteBlInstaller(bl, sondeo: sondeoBl);
    try {
      await c.salir();
    } on InstaladorBlError catch (e) {
      _log('SALIR sin respuesta: ${e.motivo}');
    } finally {
      await bl.cerrar();
    }
    _avisarEncendido();
    final ses = await puertos.esperarSenew(plazoSenew);
    if (ses == null) {
      return const ResultadoAct(
          FinAct.sinVuelta, 'El teléfono no ha vuelto por USB.',
          remedio: 'Si se apagó, enciéndelo; si sigue encendido, acepta el aviso '
              'de conexión. Después vuelve a conectar.');
    }
    final r = await leerTelefono(ses);
    return ResultadoAct(FinAct.hecho, 'senew arrancó.',
        sesion: ses, telefono: r.valor);
  }
}

/// ¿Qué hay en el main? Primera palabra y vector de reset. Pura.
bool tieneVectores(Uint8List cabeza) {
  if (cabeza.length < 36) return false;
  final v = ByteData.sublistView(cabeza);
  final reset = v.getUint32(0x20, Endian.little);
  return v.getUint32(0, Endian.little) == 0xE59FF018 &&
      reset >= blMainIni &&
      reset < blMainFin;
}
