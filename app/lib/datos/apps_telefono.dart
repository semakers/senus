// Las apps del teléfono: de dónde se leen y cómo se comparan con el catálogo.
//
// Con canal, la lista la da `SEN_APPS`, única forma de ver las de fábrica; el
// handle para quitar una se saca por MTP. `SEN_APPS` no trae una `.sen` con la
// cabecera mala ni pasa de 64: esas se añaden de lo que ve MTP, para que se
// puedan quitar. Sin canal (sis28h), solo lo que MTP alcanza.
//
// Los juegos con datos (`docs/contrato_juegos_con_datos.md`) van a la tarjeta:
// `/tarjeta/juegos/<id>.sen` y sus ficheros en `/tarjeta/juegos/<carpeta>/`. El
// `.sen` se sube el último y se quita el primero: senew lista en «Juegos» todo
// `.sen` de esa carpeta, y un juego a medias no debe salir ahí.

import 'dart:typed_data';

import '../mtp/canal_gestion.dart';
import '../mtp/operaciones.dart';
import '../mtp/sesion_mtp.dart';
import 'app_sen.dart';
import 'backend_semakers.dart';
import 'indice_semakers.dart';
import 'telefono.dart';

class ErrorInstalarApp implements Exception {
  final String motivo;
  const ErrorInstalarApp(this.motivo);
  @override
  String toString() => motivo;
}

/// Cómo está una app del catálogo respecto al teléfono.
enum EstadoCatalogo {
  noInstalada,
  alDia,
  hayActualizacion,
  masNueva,

  /// Lo que manda en el teléfono es una copia más vieja que no está en la
  /// Memoria: subir a la Memoria, sin más, no cambiaría nada.
  tapada,

  /// Un juego del que falta algo: el `.sen` o algún dato, o un dato que no
  /// mide lo que dice su manifiesto. El botón reinstala.
  incompleto,

  /// Un juego y el teléfono no tiene tarjeta: no hay dónde ponerlo.
  sinTarjeta,

  /// Va a un sitio que esta SENUS no conoce: se enseña, no se instala.
  noSoportada,
}

/// Un paso de una instalación con su avance en bytes, para la barra.
class ProgresoInstalacion {
  final String paso;
  final int hechos;
  final int total;
  const ProgresoInstalacion(this.paso, this.hechos, this.total);

  double? get fraccion =>
      total <= 0 ? null : (hechos / total).clamp(0.0, 1.0).toDouble();

  @override
  String toString() => '$paso $hechos/$total';
}

/// Para personas: «17,5 MB», «707 KB».
String textoBytes(int b) {
  if (b >= 1000000) {
    return '${(b / 1000000).toStringAsFixed(1).replaceAll('.', ',')} MB';
  }
  return '${(b / 1000).ceil()} KB';
}

/// Una app del catálogo frente a lo que hay en el teléfono. Lo que se ofrece
/// sale de aquí: nunca un botón que no cambie nada.
class SituacionCatalogo {
  final EstadoCatalogo estado;

  /// La copia que manda hoy.
  final AppSen? manda;

  /// La copia que impide que mande la de la Memoria.
  final AppSen? rival;

  /// Hay que subir la versión del catálogo a la Memoria.
  final bool hayQueSubir;

  /// De un juego incompleto: los datos que faltan o no miden lo que deben, de
  /// cuántos lleva. Si falta el `.sen`, [faltaSen].
  final int faltan;
  final int datosTotal;
  final bool faltaSen;

  /// Hay algo del juego en la tarjeta que quitar: su `.sen` o su carpeta.
  final bool hayAlgoQueQuitar;

  const SituacionCatalogo(this.estado,
      {this.manda,
      this.rival,
      this.hayQueSubir = false,
      this.faltan = 0,
      this.datosTotal = 0,
      this.faltaSen = false,
      this.hayAlgoQueQuitar = false});

  /// ¿Se puede arreglar desde aquí? Solo si se puede quitar lo que tapa.
  bool get sePuedeResolver =>
      estado == EstadoCatalogo.tapada && (rival?.sePuedeQuitar ?? false);

  /// Para personas: por qué lo instalado no es lo que se ve.
  String get explicacion {
    switch (estado) {
      case EstadoCatalogo.sinTarjeta:
        return 'Necesita una tarjeta';
      case EstadoCatalogo.noSoportada:
        return 'Esta SENUS no sabe instalarla: actualiza SENUS';
      case EstadoCatalogo.incompleto:
        if (faltaSen) return 'Incompleto: están los datos y falta el juego';
        return 'Incompleto: ${faltan == 1 ? 'falta 1' : 'faltan $faltan'} '
            'de $datosTotal datos';
      default:
        break;
    }
    final r = rival;
    if (estado != EstadoCatalogo.tapada || r == null) return '';
    final donde = r.deFabrica ? 'la de fábrica' : 'la copia de la tarjeta';
    final ver = r.verApp == null ? '' : ' (v${r.verApp})';
    final base = hayQueSubir
        ? 'Manda $donde$ver'
        : 'Instalada en Memoria, pero manda $donde$ver';
    return sePuedeResolver ? base : '$base, y no se puede quitar desde aquí';
  }

  /// Lo que hace el botón, si lo hay.
  String get accion => estado == EstadoCatalogo.incompleto
      ? 'Reinstalar'
      : hayQueSubir
          ? 'Instalar y quitar la de la tarjeta'
          : 'Quitar la copia de la tarjeta';
}

/// Lo que hace falta para no pasarse del espacio libre: FAT reparte por
/// clústeres, y en una tarjeta de hasta 32 GB no pasan de 64 KiB.
const int margenPorObjeto = 64 << 10;

/// Objetos de la tarjeta que senew numera por MTP: 512 entradas, una es la
/// raíz (`MTP_TJ_MAX`, api/mtp.c). Lo que pasa de ahí no se ve.
const int maxObjetosTarjeta = 511;

class ServicioApps {
  final SesionMtp sesion;
  final Telefono telefono;
  ServicioApps(this.sesion, this.telefono);

  Future<Map<String, ObjetoMtp>> _objetosDe(int almacen, String carpeta) async {
    final h = almacen == storageTarjeta
        ? await _hijo(carpeta, carpeta: true)
        : await sesion.handleCarpeta(carpeta, almacen: almacen);
    if (!h.bien || h.valor == null) return const {};
    final l = await sesion.listarCarpeta(h.valor!, almacen: almacen);
    if (!l.bien) return const {};
    return {
      for (final o in l.valor!)
        if (!o.esCarpeta && o.nombre.toLowerCase().endsWith('.sen')) o.nombre: o
    };
  }

  /// Todas las apps. Sin canal, lo mismo que MTP deja ver.
  Future<List<AppSen>> listar() async {
    if (!telefono.canalGestion) return sesion.listarAppsMtp();
    final lista = await CanalGestion(sesion).apps();
    final hayTarjeta = telefono.tarjeta != null ||
        telefono.gestion?.hayTarjeta == true ||
        lista.any((a) =>
            a.origen == OrigenApp.tarjetaApps.index ||
            a.origen == OrigenApp.tarjetaJuegos.index);
    final porOrigen = <OrigenApp, Map<String, ObjetoMtp>>{
      OrigenApp.memoria: await _objetosDe(storageMemoria, 'apps'),
      if (hayTarjeta) ...{
        OrigenApp.tarjetaApps: await _objetosDe(storageTarjeta, 'apps'),
        OrigenApp.tarjetaJuegos: await _objetosDe(storageTarjeta, 'juegos'),
      },
    };
    final vistas = <(OrigenApp, String)>{};
    final out = <AppSen>[];
    for (final a in lista) {
      final origen = OrigenApp.deCodigo(a.origen);
      vistas.add((origen, a.fichero));
      final o = porOrigen[origen]?[a.fichero];
      out.add(AppSen(
        handle: o?.handle ?? 0,
        nombre: a.fichero,
        bytes: a.tam,
        modificado: o?.modificado,
        origen: origen,
        protegida: a.protegida,
        tapada: a.tapada,
        titulo: a.nombre,
        verApp: a.verApp,
        perfil: a.perfil,
        iconoGen: a.iconoGen,
        iconoAn: a.iconoAn,
        iconoFilas: a.iconoFilas,
        apiMayor: a.apiMayor,
        apiMenor: a.apiMenor,
      ));
    }
    porOrigen.forEach((origen, objetos) {
      objetos.forEach((nombre, o) {
        if (vistas.contains((origen, nombre))) return;
        out.add(AppSen(
            handle: o.handle,
            nombre: nombre,
            bytes: o.tamano,
            modificado: o.modificado,
            origen: origen));
      });
    });
    return out;
  }

  /// Descarga, verifica, sube y relee. Actualizar es lo mismo: MTP pisa de
  /// forma atómica. Una app va a la Memoria (§5.3); un juego, a la tarjeta.
  Future<void> instalar(ClienteBackend backend, AppIndice app,
      {void Function(String)? alPaso,
      void Function(ProgresoInstalacion)? alProgreso}) async {
    if (!app.destinoConocido) {
      throw ErrorInstalarApp('«${app.nombre}» va a «${app.destino}», y esta '
          'SENUS no sabe instalar ahí. Actualiza SENUS.');
    }
    if (app.esJuego) {
      return _instalarJuego(backend, app, alPaso: alPaso, alProgreso: alProgreso);
    }
    alPaso?.call('Descargando y verificando…');
    final d = await backend.descargarApp(app);
    final libre = telefono.memoria?.bytesLibres;
    if (libre != null && libre < d.bytes.length) {
      throw ErrorInstalarApp('No cabe en la Memoria: ocupa ${d.bytes.length} B '
          'y quedan $libre B libres.');
    }
    alPaso?.call('Subiendo al teléfono…');
    final r = await sesion.subirAppVerificada(app.fichero, d.bytes);
    if (!r.bien) {
      throw ErrorInstalarApp(r.mensaje ?? 'No se pudo instalar ${app.nombre}.');
    }
  }

  /// Arregla una app tapada: primero asegura la copia de la Memoria y luego
  /// quita lo que la tapa, así la app no desaparece en medio. Comprueba al final
  /// que mandar, manda: si no, lo dice en vez de darlo por hecho.
  Future<void> resolverTapada(ClienteBackend backend, AppIndice cat,
      SituacionCatalogo s, {void Function(String)? alPaso}) async {
    final r = s.rival;
    if (r == null || !s.sePuedeResolver) {
      throw ErrorInstalarApp(s.explicacion);
    }
    if (s.hayQueSubir) await instalar(backend, cat, alPaso: alPaso);
    alPaso?.call('Quitando lo que la tapa…');
    await quitar(r);
    final d = situacionCatalogo(cat, await listar());
    if (d.estado != EstadoCatalogo.alDia && d.estado != EstadoCatalogo.masNueva) {
      throw ErrorInstalarApp('Se quitó «${r.nombre}», pero «${cat.nombre}» sigue '
          'sin ser la que manda.');
    }
  }

  /// Quita una app. Lo que no se puede quitar no llega a pedírsele al teléfono.
  Future<void> quitar(AppSen a) async {
    if (!a.sePuedeQuitar) {
      throw ErrorInstalarApp(a.deFabrica
          ? '«${a.tituloVisible}» es de fábrica y no se puede quitar.'
          : '«${a.tituloVisible}» está protegida.');
    }
    final r = await sesion.borrarApp(a.handle);
    if (!r.bien) {
      throw ErrorInstalarApp(r.mensaje ?? 'No se pudo quitar ${a.nombre}.');
    }
  }

  // ---------------------------------------------------------------- juegos

  /// La tarjeta como está AHORA: lo que se leyó al conectar puede ser viejo.
  /// Null si no hay.
  Future<Almacen?> tarjetaActual() async {
    final r = await sesion.almacenes();
    if (!r.bien) return telefono.tarjeta;
    for (final a in r.valor!) {
      if (a.id == storageTarjeta) return a;
    }
    return null;
  }

  /// Un hijo de la tarjeta por su nombre, sin mirar mayúsculas. Si hay algo
  /// con ese nombre y no es lo que se busca (carpeta o fichero), lo dice.
  Future<ResultadoMtp<int?>> _hijo(String nombre,
      {int padre = handleRaiz, required bool carpeta}) async {
    final r = await sesion.buscarHijo(nombre,
        almacen: storageTarjeta, padre: padre);
    if (!r.bien) return ResultadoMtp.error(r.codigoResp, r.mensaje);
    final o = r.valor;
    if (o == null) return const ResultadoMtp.ok(null);
    if (o.esCarpeta != carpeta) {
      return ResultadoMtp.error(
          rGeneral,
          'En la tarjeta, «${o.nombre}» es ${o.esCarpeta ? 'una carpeta' : 'un fichero'} '
          'y aquí hace falta ${carpeta ? 'una carpeta' : 'un fichero'}.');
    }
    return ResultadoMtp.ok(o.handle);
  }

  Future<int?> _hijoO(String nombre,
      {int padre = handleRaiz, required bool carpeta}) async {
    final r = await _hijo(nombre, padre: padre, carpeta: carpeta);
    if (!r.bien) {
      throw ErrorInstalarApp(r.mensaje ?? 'No se pudo leer la tarjeta.');
    }
    return r.valor;
  }

  Future<ObjetoMtp?> _buscar(String nombre, int padre) async {
    final r =
        await sesion.buscarHijo(nombre, almacen: storageTarjeta, padre: padre);
    if (!r.bien) {
      throw ErrorInstalarApp(r.mensaje ?? 'No se pudo leer la tarjeta.');
    }
    return r.valor;
  }

  /// Lo que hay en `/tarjeta/juegos/<carpeta>/`: nombre en minúsculas y su
  /// objeto. Vacío si la carpeta no está.
  Future<Map<String, ObjetoMtp>> _enCarpeta(int? carpeta) async {
    if (carpeta == null) return const {};
    final l = await sesion.listarCarpeta(carpeta, almacen: storageTarjeta);
    if (!l.bien) {
      throw ErrorInstalarApp(l.mensaje ?? 'No se pudo leer la tarjeta.');
    }
    return {
      for (final o in l.valor!)
        if (!o.esCarpeta) o.nombre.toLowerCase(): o
    };
  }

  /// Los datos de un juego que hay en la tarjeta (nombre en minúsculas →
  /// bytes), o null si no hay tarjeta. Para la situación en el catálogo.
  Future<Map<String, int>?> datosEnTarjeta(DatosJuego d) async {
    if (await tarjetaActual() == null) return null;
    final juegos = await _hijoO('juegos', carpeta: true);
    if (juegos == null) return const {};
    final c = await _hijoO(d.carpeta, padre: juegos, carpeta: true);
    return {for (final e in (await _enCarpeta(c)).entries) e.key: e.value.tamano};
  }

  /// Instala un juego en la tarjeta. Por este orden, y sin tocar nada hasta
  /// el paso 4: tarjeta escribible; el manifiesto firmado y lo que ya hay;
  /// espacio y sitio en la tabla de la tarjeta; todo descargado y verificado.
  /// Luego: carpetas, cada dato subido y releído (el que ya está con su tamaño
  /// se relee y, si cuadra, no se sube), y el `.sen` el último. Si hay que
  /// escribir algún dato y había un `.sen`, ese se quita antes: un juego a
  /// medias no sale en «Juegos».
  Future<void> _instalarJuego(ClienteBackend backend, AppIndice app,
      {void Function(String)? alPaso,
      void Function(ProgresoInstalacion)? alProgreso}) async {
    void paso(String p, int hechos, int total) {
      alPaso?.call(p);
      alProgreso?.call(ProgresoInstalacion(p, hechos, total));
    }

    // 1. La tarjeta, antes de bajar nada.
    final tj = await tarjetaActual();
    if (tj == null) {
      throw ErrorInstalarApp(
          '«${app.nombre}» es un juego y va a la tarjeta: necesita una tarjeta '
          'en el teléfono.');
    }
    if (tj.soloLectura) {
      throw ErrorInstalarApp(
          'La tarjeta está protegida contra escritura: no se puede instalar '
          '«${app.nombre}».');
    }

    // 2. Qué lleva (manifiesto firmado) y qué hay ya.
    paso('Leyendo el catálogo…', 0, 0);
    final datos = await backend.datosDe(app);
    final archivos = datos?.archivos ?? const <ArchivoDato>[];
    final juegos = await _hijoO('juegos', carpeta: true);
    final carpeta = datos == null || juegos == null
        ? null
        : await _hijoO(datos.carpeta, padre: juegos, carpeta: true);
    final presentes = await _enCarpeta(carpeta);
    ObjetoMtp? senViejo;
    if (juegos != null) {
      final sv = await _buscar(app.fichero, juegos);
      if (sv != null && sv.esCarpeta) {
        throw ErrorInstalarApp(
            'En la tarjeta, /juegos/${sv.nombre} es una carpeta: no se '
            'puede poner ahí el juego.');
      }
      senViejo = sv;
    }

    // 3. Espacio y sitio en la tabla, ANTES de empezar.
    var hace = app.tam + margenPorObjeto;
    var nuevos = senViejo == null ? 1 : 0;
    if (juegos == null) {
      hace += margenPorObjeto;
      nuevos++;
    }
    if (datos != null && carpeta == null) {
      hace += margenPorObjeto;
      nuevos++;
    }
    for (final a in archivos) {
      final p = presentes[a.nombre];
      if (p == null) nuevos++;
      if (p == null || p.tamano != a.bytes) hace += a.bytes + margenPorObjeto;
    }
    if (hace > tj.bytesLibres) {
      throw ErrorInstalarApp(
          'No cabe en la tarjeta: «${app.nombre}» necesita ${textoBytes(hace)} '
          'y quedan ${textoBytes(tj.bytesLibres)} libres.');
    }
    final n = await sesion.contarObjetos(storageTarjeta);
    if (n.bien && n.valor! + nuevos > maxObjetosTarjeta) {
      throw ErrorInstalarApp(
          'La tarjeta tiene ${n.valor} ficheros y carpetas; con los $nuevos de '
          '«${app.nombre}» pasaría de los $maxObjetosTarjeta que senew ve por '
          'USB. Libera algunos antes.');
    }

    // 4. Todo descargado y verificado antes de escribir.
    final bajar = app.tam + (datos?.bytes ?? 0);
    var bajado = 0;
    paso('Descargando y verificando…', 0, bajar);
    final d = await backend.descargarApp(app,
        alProgreso: (h, _) => paso('Descargando y verificando…', h, bajar));
    bajado += app.tam;
    final contenidos = <Uint8List>[];
    for (final a in archivos) {
      final base = bajado;
      contenidos.add(await backend.descargarDato(a,
          alProgreso: (h, _) =>
              paso('Descargando ${a.nombre}…', base + h, bajar)));
      bajado += a.bytes;
      paso('Descargando y verificando…', bajado, bajar);
    }

    // 5. A la tarjeta. El total cuenta subir y releer: el doble.
    final total = 2 * bajar;
    var hecho = 0;
    Future<void> quitarSenViejo() async {
      final v = senViejo;
      if (v == null) return;
      senViejo = null;
      final r = await sesion.borrarApp(v.handle);
      if (!r.bien) {
        throw ErrorInstalarApp(
            'No se pudo quitar el ${v.nombre} viejo antes de cambiar los datos: '
            '${r.mensaje}. No se tocó nada más.');
      }
    }

    Future<int> carpetaNueva(String nombre, int padre) async {
      final r = await sesion.crearCarpeta(nombre,
          almacen: storageTarjeta, padre: padre);
      if (!r.bien) {
        throw ErrorInstalarApp('${r.mensaje} (0x${r.codigoResp.toRadixString(16)}).');
      }
      return r.valor!;
    }

    final hJuegos = juegos ?? await carpetaNueva('juegos', handleRaiz);
    final hCarpeta = datos == null
        ? null
        : carpeta ?? await carpetaNueva(datos.carpeta, hJuegos);
    for (var i = 0; i < archivos.length; i++) {
      final a = archivos[i];
      final b = contenidos[i];
      final p = presentes[a.nombre];
      final base = hecho;
      if (p != null && p.tamano == a.bytes) {
        final s = await sesion.shaDeObjeto(p.handle, a.bytes,
            alProgreso: (h, _) =>
                paso('Comprobando ${a.nombre}…', base + 2 * h, total));
        if (!s.bien) {
          throw ErrorInstalarApp('No se pudo releer ${a.nombre}: ${s.mensaje}.');
        }
        if (s.valor == a.sha256) {
          hecho += 2 * a.bytes;
          continue;
        }
      }
      await quitarSenViejo();
      // Al pisar, el nombre que ya tiene: el respondedor numera la tarjeta por
      // nombre exacto, y con otra caja saldría dos veces.
      final r = await sesion.subirVerificado(
          storageTarjeta, hCarpeta!, p?.nombre ?? a.nombre, b,
          alProgreso: (h, _) => paso(
              h <= a.bytes ? 'Subiendo ${a.nombre}…' : 'Comprobando ${a.nombre}…',
              base + h,
              total));
      if (!r.bien) throw ErrorInstalarApp(_motivoTarjeta(a.nombre, r));
      hecho += 2 * a.bytes;
    }

    // 6. El .sen, el último: con él el juego sale en «Juegos».
    final base = hecho;
    final r = await sesion.subirVerificado(
        storageTarjeta, hJuegos, senViejo?.nombre ?? app.fichero, d.bytes,
        alProgreso: (h, _) => paso(
            h <= d.bytes.length
                ? 'Subiendo ${app.fichero}…'
                : 'Comprobando ${app.fichero}…',
            base + h,
            total));
    if (!r.bien) throw ErrorInstalarApp(_motivoTarjeta(app.fichero, r));
    paso('Instalado', total, total);
  }

  String _motivoTarjeta(String nombre, ResultadoMtp<int> r) {
    final c = r.codigoResp;
    final que = c == rLlena
        ? 'la tarjeta se llenó'
        : c == rSoloLectura
            ? 'la tarjeta está protegida contra escritura'
            : (r.mensaje ?? 'error 0x${c.toRadixString(16)}');
    return 'No se pudo subir $nombre: $que. El juego no queda en «Juegos»; '
        'vuelve a instalarlo para terminar.';
  }

  /// Quita un juego: primero su `.sen` (deja de salir en «Juegos») y luego la
  /// carpeta de sus datos entera, solo esa. Comprueba al final que no queda.
  Future<void> quitarJuego(ClienteBackend backend, AppIndice app) async {
    final datos = await backend.datosDe(app);
    if (await tarjetaActual() == null) {
      throw const ErrorInstalarApp(
          'No hay tarjeta en el teléfono: no hay nada que quitar.');
    }
    final juegos = await _hijoO('juegos', carpeta: true);
    if (juegos == null) return;
    Future<ObjetoMtp?> sen() => _buscar(app.fichero, juegos);
    Future<int?> carpeta() async => datos == null
        ? null
        : await _hijoO(datos.carpeta, padre: juegos, carpeta: true);
    final s = await sen();
    if (s != null) {
      final r = await sesion.borrarApp(s.handle);
      if (!r.bien) {
        throw ErrorInstalarApp('No se pudo quitar ${s.nombre}: ${r.mensaje}. '
            'Sus datos siguen en la tarjeta.');
      }
    }
    final c = await carpeta();
    if (c != null) {
      final r = await sesion.borrarApp(c);
      if (!r.bien) {
        throw ErrorInstalarApp('Se quitó el juego, pero no la carpeta de sus '
            'datos (/juegos/${datos!.carpeta}): ${r.mensaje}.');
      }
    }
    if (await sen() != null || await carpeta() != null) {
      throw ErrorInstalarApp('El teléfono dijo que sí, pero «${app.nombre}» '
          'sigue en la tarjeta.');
    }
  }
}

/// La copia que manda de una app: la que no está tapada por otra.
AppSen? copiaQueManda(List<AppSen> apps, String id) {
  AppSen? tapada;
  for (final a in apps) {
    if (a.id != id) continue;
    if (!a.tapada) return a;
    tapada ??= a;
  }
  return tapada;
}

/// Quién tapa a [a]: la copia viva de su mismo fichero o de su mismo nombre
/// visible (el firmware no repite nombres en el menú).
AppSen? copiaQueLaTapa(List<AppSen> apps, AppSen a) {
  if (!a.tapada) return null;
  for (final b in apps) {
    if (b.tapada || identical(a, b)) continue;
    if (b.id == a.id || (b.titulo.isNotEmpty && b.titulo == a.titulo)) return b;
  }
  return null;
}

/// Lo que impediría que mandase la copia de la Memoria, que es donde instala
/// la tienda. Si la Memoria tiene copia, lo dice su bit de tapada. Si no, lo
/// único que la taparía es la de la tarjeta: el menú mira antes `/tarjeta/apps`
/// (`ap_dirs`, shell/gestion_sis.c). La de fábrica no: la Memoria manda sobre ella.
AppSen? rivalDeMemoria(List<AppSen> apps, String id) {
  for (final a in apps) {
    if (a.id == id && a.origen == OrigenApp.memoria) {
      return copiaQueLaTapa(apps, a);
    }
  }
  for (final a in apps) {
    if (a.id == id && a.origen == OrigenApp.tarjetaApps && !a.tapada) return a;
  }
  return null;
}

/// La situación de una app del catálogo, mirando quién manda de verdad. Para
/// un juego, además, sus datos: [datos] según su manifiesto y [enTarjeta] lo
/// que hay en su carpeta (nombre en minúsculas → bytes; null si no se sabe).
SituacionCatalogo situacionCatalogo(AppIndice cat, List<AppSen> apps,
    {DatosJuego? datos, Map<String, int>? enTarjeta, bool hayTarjeta = true}) {
  if (!cat.destinoConocido) {
    return const SituacionCatalogo(EstadoCatalogo.noSoportada);
  }
  if (cat.esJuego) {
    return situacionJuego(cat, apps,
        datos: datos, enTarjeta: enTarjeta, hayTarjeta: hayTarjeta);
  }
  final manda = copiaQueManda(apps, cat.id);
  final rival = rivalDeMemoria(apps, cat.id);
  final vigente = rival ?? manda;
  final estado = estadoFrente(cat, vigente);
  if (rival == null || estado != EstadoCatalogo.hayActualizacion) {
    return SituacionCatalogo(estado, manda: vigente);
  }
  AppSen? enMemoria;
  for (final a in apps) {
    if (a.id == cat.id && a.origen == OrigenApp.memoria) enMemoria = a;
  }
  final v = enMemoria?.verApp;
  return SituacionCatalogo(EstadoCatalogo.tapada,
      manda: vigente,
      rival: rival,
      hayQueSubir: v == null || v < cat.verApp);
}

/// Un juego: instalado si está su `.sen` en `/tarjeta/juegos` y todos sus
/// datos con su tamaño. Si falta algo, incompleto.
SituacionCatalogo situacionJuego(AppIndice cat, List<AppSen> apps,
    {DatosJuego? datos, Map<String, int>? enTarjeta, required bool hayTarjeta}) {
  if (!hayTarjeta) return const SituacionCatalogo(EstadoCatalogo.sinTarjeta);
  AppSen? sen;
  for (final a in apps) {
    if (a.id == cat.id && a.origen == OrigenApp.tarjetaJuegos) sen = a;
  }
  final archivos = datos?.archivos ?? const <ArchivoDato>[];
  final hay = enTarjeta ?? const <String, int>{};
  final faltan = archivos.where((a) => hay[a.nombre] != a.bytes).length;
  final algunDato = archivos.any((a) => hay.containsKey(a.nombre));
  if (sen == null) {
    return algunDato
        ? SituacionCatalogo(EstadoCatalogo.incompleto,
            faltaSen: true,
            faltan: faltan,
            datosTotal: archivos.length,
            hayAlgoQueQuitar: true)
        : const SituacionCatalogo(EstadoCatalogo.noInstalada);
  }
  // Sin saber qué datos lleva (o lo que hay en su carpeta), solo el .sen.
  if (enTarjeta != null && faltan > 0) {
    return SituacionCatalogo(EstadoCatalogo.incompleto,
        manda: sen,
        faltan: faltan,
        datosTotal: archivos.length,
        hayAlgoQueQuitar: true);
  }
  return SituacionCatalogo(estadoFrente(cat, sen),
      manda: sen, hayAlgoQueQuitar: true);
}

EstadoCatalogo estadoFrente(AppIndice cat, AppSen? instalada) {
  if (instalada == null) return EstadoCatalogo.noInstalada;
  final v = instalada.verApp;
  if (v == null || v < cat.verApp) return EstadoCatalogo.hayActualizacion;
  return v == cat.verApp ? EstadoCatalogo.alDia : EstadoCatalogo.masNueva;
}
