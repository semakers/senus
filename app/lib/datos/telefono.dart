// Modelo del teléfono reconocido por SENUS: lo que da GetDeviceInfo +
// StorageInfo y, si el senew tiene canal de gestión, `SEN_INFO`.

import '../mtp/canal_datos.dart';

enum Modelo { w580, w600, w810, desconocido }

/// Lo que se le dice a la persona cada vez que tiene que aceptar en el teléfono.
/// Al arrancar con el cable salen apilados un menú «Encendido» espurio, con el
/// foco en «Apagar el teléfono», «USB conectado» y el permiso: un OK a ciegas
/// APAGA el teléfono. Medido en el emulador con la polaridad del silicio
/// (1-nov): Atrás, C y «Cancelar» cierran cada diálogo igual; el permiso se
/// abre con el foco en «No» (`ui_confirmar_no`).
const String avisoEncendido =
    'Si en el teléfono sale «Encendido», ciérralo con la tecla Atrás; no pulses '
    'OK: apagaría el teléfono. Cierra también «USB conectado» y, en «Conectado '
    'por USB», sube a «Sí» y pulsa OK.';

/// Cómo está instalado senew en el aparato. El flujo público para DB2020 CID53
/// no reemplaza firmware (no hay RSA break DB2020); lo que la escena publicó
/// es un payload HOSPEDADO que arranca bajo el A200 del R8BE001 (ver
/// `seftool-senew/docs/cid53_payload.md`). Esto cambia:
///   - qué pantalla se muestra en SENUS fase 2/3 (la de «este aparato lleva
///     senew encima del SEMC, no en lugar del SEMC»);
///   - qué garantías damos («puedes volver atrás con un reset físico»);
///   - qué camino de actualización ofrecemos («reemplazas el fichero .b del
///     payload por el nuevo, no flasheamos NOR»).
///
/// Fase 1: SENUS no lo deduce por sí sola (requiere diálogo con el aparato,
/// y por ahora solo W600/W810 CID49 están en TestFlight de senew). El valor
/// vive aquí para que las pantallas de fase 2 ya puedan ramificar sin
/// tocar el modelo de datos.
enum ModoInstalacion {
  /// Reemplazo frío: senew tomó la NOR en 0x44140000 (W600/W810 CID49 con
  /// break49, o un hipotético W580 CID49). El A200 ya no existe.
  reemplazoFrio,

  /// Payload sobre el A200: senew corre como un stub `.b` cargado por el
  /// AMS tras el flujo anycid del DB2020. El A200 original sigue en NOR
  /// y vuelve con un reset físico. Caso W580 CID53 (opción B de
  /// cid53_payload.md).
  payloadAnycid,

  /// Sin determinar: el aparato responde senew por MTP pero no publica
  /// aún en qué modo arranca. Fase 1 lo trata como `reemplazoFrio` para
  /// no cambiar el camino feliz.
  sinDeterminar,
}

Modelo modeloDeNombre(String nombreAmigo) {
  if (nombreAmigo.startsWith('W580 ')) return Modelo.w580;
  if (nombreAmigo.startsWith('W600 ')) return Modelo.w600;
  if (nombreAmigo.startsWith('W810 ')) return Modelo.w810;
  return Modelo.desconocido;
}

String socDe(Modelo m) {
  switch (m) {
    case Modelo.w580:
      return 'DB2020';
    case Modelo.w600:
    case Modelo.w810:
      return 'DB2010';
    case Modelo.desconocido:
      return 'desconocido';
  }
}

class Almacen {
  final int id;             // 0x00010001 (Memoria) o 0x00020001 (Tarjeta/NAND)
  final String etiqueta;    // "Memoria" | "Tarjeta"
  final int bytesTotales;
  final int bytesLibres;
  final bool soloLectura;

  const Almacen({
    required this.id,
    required this.etiqueta,
    required this.bytesTotales,
    required this.bytesLibres,
    required this.soloLectura,
  });
}

class Telefono {
  final Modelo modelo;
  final String nombreAmigo;     // "W580 sistema propio"
  final String serie;           // "W580S10000001"
  final String versionSenew;    // DeviceVersion: «S10» (sis28h) o «0.29.0+290»
  final List<Almacen> almacenes;
  final ModoInstalacion modoInstalacion;

  /// true si `OperationsSupported` trae 0x9400. Un senew sin canal (sis28h) se
  /// lista por MTP y se le pide actualizar.
  final bool canalGestion;

  /// `SEN_INFO`, si hay canal. Null si no lo hay o si falló al leerlo.
  final SenInfo? gestion;

  /// El teléfono está en su bootloader (1209:0002 o 1209:0003): no hay senew
  /// con quien hablar y solo queda el modo recuperación.
  final int? pidBootloader;

  /// true cuando el aparato NO corre senew: se le encontró por el cable
  /// serie y contestó a `seftool identify`. Entonces no hay sesión MTP, y lo
  /// único que SENUS ofrece es el respaldo de rollback y la instalación.
  final bool deFabrica;

  /// Lo que dijo `identify` (sólo en aparatos de fábrica).
  final String? cid;
  final String? color;
  final String? firmwareOriginal;
  /// Puerto serie por el que contestó.
  final String? puertoSerie;

  const Telefono({
    required this.modelo,
    required this.nombreAmigo,
    required this.serie,
    required this.versionSenew,
    required this.almacenes,
    this.modoInstalacion = ModoInstalacion.sinDeterminar,
    this.canalGestion = false,
    this.gestion,
    this.pidBootloader,
    this.deFabrica = false,
    this.cid,
    this.color,
    this.firmwareOriginal,
    this.puertoSerie,
  });

  String get soc => socDe(modelo);

  /// El IMEI, si se sabe. Solo lo usa la primera instalación: actualizar no
  /// depende de él.
  String? get imei {
    if (deFabrica) return serie.isEmpty ? null : serie;
    final id = gestion?.idAparato ?? '';
    return id.isEmpty ? null : id;
  }

  /// Con qué se busca su respaldo: por IMEI. La serie MTP de un senew vinculado
  /// es un hash, y la de un sis28h es igual en todos.
  String get idRespaldo => imei ?? serie;

  /// Versión para personas: la de `SEN_INFO` si hay canal.
  String get versionTexto {
    final g = gestion;
    return g == null ? versionSenew : '${g.version} (build ${g.build})';
  }

  bool get enRecuperacion => pidBootloader != null;

  Telefono copiarCon({List<Almacen>? almacenes, SenInfo? gestion}) => Telefono(
        modelo: modelo,
        nombreAmigo: nombreAmigo,
        serie: serie,
        versionSenew: versionSenew,
        almacenes: almacenes ?? this.almacenes,
        modoInstalacion: modoInstalacion,
        canalGestion: canalGestion,
        gestion: gestion ?? this.gestion,
        pidBootloader: pidBootloader,
        deFabrica: deFabrica,
        cid: cid,
        color: color,
        firmwareOriginal: firmwareOriginal,
        puertoSerie: puertoSerie,
      );

  Almacen? get memoria =>
      almacenes.where((a) => a.id == 0x00010001).cast<Almacen?>().firstOrNull;
  Almacen? get tarjeta =>
      almacenes.where((a) => a.id == 0x00020001).cast<Almacen?>().firstOrNull;

  /// El W580 que la persona dice tener de fábrica, antes de identificarlo:
  /// la entrada «Instalar senew» de la pantalla de conexión lo usa para ir
  /// derecho a la instalación (que identifica y respalda por su cuenta). Sin
  /// serie, el instalador no busca un respaldo previo: identifica primero.
  static const Telefono fabricaSinIdentificar = Telefono(
    modelo: Modelo.w580,
    nombreAmigo: 'W580 de fábrica',
    serie: '',
    versionSenew: '—',
    almacenes: [],
    deFabrica: true,
  );

  /// ¿Este aparato entra en el flujo nuevo de primera instalación (anycid +
  /// trampoline)? Un W580 de fábrica con CID 52 (o sin identificar todavía).
  /// El CID 53, el W600 y el W810 siguen por los caminos heredados.
  bool get entraEnInstalacionInicial =>
      deFabrica &&
      modelo == Modelo.w580 &&
      (cid == null || cid!.isEmpty || cid == '52');

  /// Un teléfono detenido en su bootloader. El modelo es el W580: es el único
  /// con este BL.
  factory Telefono.enBootloader(int pid) => Telefono(
        modelo: Modelo.w580,
        nombreAmigo: 'W580 en el bootloader',
        serie: '',
        versionSenew: '—',
        almacenes: const [],
        pidBootloader: pid,
      );

  /// true si el aparato se encontró por el cable serie sin senew. El
  /// Catálogo bloquea la instalación de .sen mientras lo sea, y la regla de
  /// rollback exige el respaldo antes de instalar nada.
  bool get esDeFabrica => deFabrica;
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
