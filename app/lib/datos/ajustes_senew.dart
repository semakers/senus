// Los 26 ajustes de senew para personas: nombre, grupo y textos de cada clave.
// Los RANGOS no están aquí: los dice el firmware en `SEN_AJ_LEER`, porque
// dependen de `N_TEMAS` y compañía. Una clave nueva que este SENUS no conozca
// sale en «Otros» con su rango; no se esconde ni se inventa.
//
// El firmware aplica en el hilo de la interfaz y puede ajustar valores
// relacionados (`atenuar_s` ≤ `apagar_s`), así que la única confirmación por
// clave es releer: eso hace [ServicioAjustes.aplicar].

import '../mtp/canal_gestion.dart';

enum GrupoAjuste {
  relojAlarma('Reloj y alarma'),
  pantalla('Pantalla'),
  sonido('Sonido'),
  podometro('Podómetro'),
  menu('Menú'),
  luces('Luces'),
  otros('Otros');

  final String nombre;
  const GrupoAjuste(this.nombre);
}

/// Claves estables del §3 del contrato: no se renumeran nunca.
abstract final class ClaveAj {
  static const int tema = 0x0001;
  static const int hora12 = 0x0002;
  static const int alarmaOn = 0x0003;
  static const int alarmaH = 0x0004;
  static const int alarmaM = 0x0005;
  static const int zonaMin = 0x0006;
  static const int brillo = 0x0007;
  static const int atenuarS = 0x0008;
  static const int apagarS = 0x0009;
  static const int bloqueoAuto = 0x000A;
  static const int tapaApaga = 0x000B;
  static const int volumen = 0x000C;
  static const int tonoTeclas = 0x000D;
  static const int pasos = 0x000E;
  static const int pasosAhorro = 0x000F;
  static const int menuEstilo = 0x0010;
  static const int menuEfecto = 0x0011;
  static const int menuIntensidad = 0x0012;
  static const int menuEjes = 0x0013;
  static const int luces = 0x0014;
  static const int lucesColor = 0x0015;
  static const int lucesLatido = 0x0016;
  static const int menuPropio = 0x0017;
  static const int giro = 0x0018;
  static const int mediosColor = 0x0019;
  static const int fondo = 0x001A;
}

/// Cómo se pinta un ajuste. Sale del tipo que dice el firmware y de esto.
enum ModoEdicion { interruptor, opciones, deslizador, zona, texto }

class DefAjuste {
  final int clave;
  final String campo;
  final String nombre;
  final String? ayuda;
  final GrupoAjuste grupo;
  final ModoEdicion modo;

  /// Texto de cada valor, si tiene nombre. Son los que enseña el teléfono en
  /// su pantalla de Ajustes. Un valor sin texto se enseña como número.
  final Map<int, String> opciones;

  /// Unidad para el deslizador.
  final String unidad;

  const DefAjuste(
    this.clave,
    this.campo,
    this.nombre,
    this.grupo, {
    this.ayuda,
    this.modo = ModoEdicion.interruptor,
    this.opciones = const {},
    this.unidad = '',
  });
}

const _plazos = <int, String>{
  0: 'nunca',
  5: '5 s',
  10: '10 s',
  15: '15 s',
  30: '30 s',
  60: '1 min',
  120: '2 min',
};

const List<DefAjuste> defsAjustes = [
  // Reloj y alarma
  DefAjuste(ClaveAj.hora12, 'hora12', 'Formato de 12 horas',
      GrupoAjuste.relojAlarma),
  DefAjuste(ClaveAj.zonaMin, 'zona_min', 'Zona horaria',
      GrupoAjuste.relojAlarma,
      ayuda: 'Desfase de la hora local respecto a UTC.',
      modo: ModoEdicion.zona),
  DefAjuste(ClaveAj.alarmaOn, 'alarma_on', 'Alarma', GrupoAjuste.relojAlarma),
  DefAjuste(ClaveAj.alarmaH, 'alarma_h', 'Alarma: hora',
      GrupoAjuste.relojAlarma,
      modo: ModoEdicion.deslizador),
  DefAjuste(ClaveAj.alarmaM, 'alarma_m', 'Alarma: minuto',
      GrupoAjuste.relojAlarma,
      modo: ModoEdicion.deslizador),
  // Pantalla
  DefAjuste(ClaveAj.tema, 'tema', 'Tema', GrupoAjuste.pantalla,
      modo: ModoEdicion.opciones,
      opciones: {
        0: 'Material oscuro',
        1: 'Material claro',
        2: 'Clásico oscuro',
        3: 'Clásico claro',
        4: 'Clásico fósforo',
      }),
  DefAjuste(ClaveAj.brillo, 'brillo', 'Brillo de pantalla', GrupoAjuste.pantalla,
      modo: ModoEdicion.deslizador, unidad: ' %'),
  DefAjuste(ClaveAj.atenuarS, 'atenuar_s', 'Atenuar la luz', GrupoAjuste.pantalla,
      ayuda: 'Nunca después de apagar la pantalla: el teléfono lo corrige.',
      modo: ModoEdicion.opciones,
      opciones: _plazos),
  DefAjuste(ClaveAj.apagarS, 'apagar_s', 'Apagar la pantalla',
      GrupoAjuste.pantalla,
      modo: ModoEdicion.opciones, opciones: _plazos),
  DefAjuste(ClaveAj.bloqueoAuto, 'bloqueo_auto', 'Bloqueo automático',
      GrupoAjuste.pantalla),
  DefAjuste(ClaveAj.tapaApaga, 'tapa_apaga', 'Cerrar el teléfono apaga',
      GrupoAjuste.pantalla),
  DefAjuste(ClaveAj.giro, 'giro', 'Girar la pantalla', GrupoAjuste.pantalla),
  DefAjuste(ClaveAj.fondo, 'fondo', 'Fondo del standby', GrupoAjuste.pantalla,
      ayuda: 'Ruta de la imagen en el teléfono. Vacío, liso.',
      modo: ModoEdicion.texto),
  // Sonido
  DefAjuste(ClaveAj.volumen, 'volumen', 'Volumen', GrupoAjuste.sonido,
      ayuda: '0 es silencio.', modo: ModoEdicion.deslizador),
  DefAjuste(ClaveAj.tonoTeclas, 'tono_teclas', 'Clic al pulsar una tecla',
      GrupoAjuste.sonido),
  // Podómetro
  DefAjuste(ClaveAj.pasos, 'pasos', 'Podómetro', GrupoAjuste.podometro),
  DefAjuste(ClaveAj.pasosAhorro, 'pasos_ahorro', 'Ahorro en reposo',
      GrupoAjuste.podometro,
      modo: ModoEdicion.opciones,
      opciones: {0: 'no', 1: 'fiel al original', 2: 'corregido'}),
  // Menú
  DefAjuste(ClaveAj.menuEstilo, 'menu_estilo', 'Estilo del menú', GrupoAjuste.menu,
      modo: ModoEdicion.opciones,
      opciones: {
        0: 'Rejilla',
        1: 'Walkman',
        2: 'Cristal',
        3: 'Neón',
        4: 'Medios',
        5: 'Escritorio', // (senew 0.30.0) el escritorio de XP; un senew anterior dice max = 4 y no se ofrece
      }),
  DefAjuste(ClaveAj.menuEfecto, 'menu_efecto', 'Efecto', GrupoAjuste.menu,
      modo: ModoEdicion.opciones,
      opciones: {0: 'inclinación', 1: 'vaivén', 2: 'quieto'}),
  DefAjuste(ClaveAj.menuIntensidad, 'menu_intensidad', 'Intensidad',
      GrupoAjuste.menu,
      modo: ModoEdicion.deslizador),
  DefAjuste(ClaveAj.menuEjes, 'menu_ejes', 'Ejes del sensor', GrupoAjuste.menu,
      modo: ModoEdicion.opciones,
      opciones: {
        0: 'X  Y',
        1: '-X  Y',
        2: 'X  -Y',
        3: '-X  -Y',
        4: 'Y  X',
        5: '-Y  X',
        6: 'Y  -X',
        7: '-Y  -X',
      }),
  DefAjuste(ClaveAj.mediosColor, 'medios_color', 'Color de Medios',
      GrupoAjuste.menu,
      modo: ModoEdicion.opciones,
      opciones: {
        0: 'Rojo',
        1: 'Naranja',
        2: 'Oro',
        3: 'Verde',
        4: 'Turquesa',
        5: 'Azul',
        6: 'Morado',
        7: 'Rosa',
        8: 'Plata',
        9: 'Negro',
        10: 'Según el mes',
      }),
  DefAjuste(ClaveAj.menuPropio, 'menu_propio', 'Menú principal a tu gusto',
      GrupoAjuste.menu,
      ayuda: 'Apagado, la disposición de fábrica.'),
  // Luces
  DefAjuste(ClaveAj.luces, 'luces', 'Luces laterales', GrupoAjuste.luces),
  DefAjuste(ClaveAj.lucesColor, 'luces_color', 'Color', GrupoAjuste.luces,
      modo: ModoEdicion.opciones,
      opciones: {
        0: 'automático',
        1: 'blanco',
        2: 'naranja',
        3: 'rojo',
        4: 'verde',
        5: 'azul',
        6: 'amarillo',
        7: 'turquesa',
        8: 'rosa',
        9: 'púrpura',
      }),
  DefAjuste(ClaveAj.lucesLatido, 'luces_latido', 'Latido', GrupoAjuste.luces),
];

DefAjuste? defDe(int clave) {
  for (final d in defsAjustes) {
    if (d.clave == clave) return d;
  }
  return null;
}

/// Un ajuste que no se quedó como se pidió.
class DiferenciaAjuste {
  final int clave;
  final Object pedido;

  /// Lo que dice el teléfono al releer; null si ya no lo lista.
  final Object? leido;
  const DiferenciaAjuste(this.clave, this.pedido, this.leido);

  String get nombre =>
      defDe(clave)?.nombre ?? 'clave 0x${clave.toRadixString(16)}';
}

/// Lo que pasó al aplicar: lo que dijo el firmware y lo que se releyó.
class ResultadoAjustes {
  final RespuestaPoner respuesta;
  final List<AjusteLeido> releidos;
  final List<int> aplicadas;
  final List<DiferenciaAjuste> noAplicadas;

  /// Ajustes que NO se pidieron y cambiaron: el firmware corrigió algo
  /// relacionado (`atenuar_s` al bajar `apagar_s`).
  final List<DiferenciaAjuste> corregidos;

  const ResultadoAjustes({
    required this.respuesta,
    required this.releidos,
    required this.aplicadas,
    required this.noAplicadas,
    required this.corregidos,
  });

  bool get todoBien => noAplicadas.isEmpty;
}

bool _igual(Object? a, Object? b) {
  if (a is bool && b is int) return (a ? 1 : 0) == b;
  if (a is int && b is bool) return a == (b ? 1 : 0);
  return a == b;
}

/// Compara lo pedido con lo releído. Pura, para probarla sin teléfono.
(List<int>, List<DiferenciaAjuste>, List<DiferenciaAjuste>) compararAjustes({
  required List<AjustePoner> pedidos,
  required List<AjusteLeido> antes,
  required List<AjusteLeido> despues,
}) {
  final mapa = {for (final a in despues) a.clave: a};
  final aplicadas = <int>[];
  final mal = <DiferenciaAjuste>[];
  for (final q in pedidos) {
    final l = mapa[q.clave];
    if (l != null && _igual(q.valor, l.valor)) {
      aplicadas.add(q.clave);
    } else {
      mal.add(DiferenciaAjuste(q.clave, q.valor, l?.valor));
    }
  }
  final pedidas = {for (final q in pedidos) q.clave};
  final corregidos = <DiferenciaAjuste>[];
  for (final a in antes) {
    if (pedidas.contains(a.clave)) continue;
    final l = mapa[a.clave];
    if (l != null && !_igual(a.valor, l.valor)) {
      corregidos.add(DiferenciaAjuste(a.clave, a.valor, l.valor));
    }
  }
  return (aplicadas, mal, corregidos);
}

class ServicioAjustes {
  final CanalGestion canal;
  ServicioAjustes(this.canal);

  Future<List<AjusteLeido>> leer() => canal.leerAjustes();

  /// Escribe, relee y compara. [antes] son los valores que tenía la pantalla:
  /// sirven para ver lo que el firmware corrigió por su cuenta.
  Future<ResultadoAjustes> aplicar(
      List<AjustePoner> cambios, List<AjusteLeido> antes) async {
    final r = await canal.ponerAjustes(cambios);
    final despues = await canal.leerAjustes();
    final (aplicadas, mal, corregidos) =
        compararAjustes(pedidos: cambios, antes: antes, despues: despues);
    return ResultadoAjustes(
      respuesta: r,
      releidos: despues,
      aplicadas: aplicadas,
      noAplicadas: mal,
      corregidos: corregidos,
    );
  }

  /// Pone la hora del computador: UTC y su zona.
  Future<void> ponerHora(DateTime ahora) =>
      canal.ponerReloj(ahora.toUtc(), ahora.timeZoneOffset.inMinutes);
}

/// «1 ajuste aplicado», «3 ajustes aplicados»; [frase], con el cierre de cuando
/// todo salió bien.
String textoAplicados(int n, {bool frase = false}) {
  final base = n == 1
      ? '1 ajuste aplicado y comprobado'
      : '$n ajustes aplicados y comprobados';
  if (!frase) return '$base.';
  return n == 1 ? '$base al releerlo.' : '$base al releerlos.';
}

/// Texto de una zona, «UTC-6:00».
String textoZona(int min) {
  final s = min < 0 ? '-' : '+';
  final a = min.abs();
  return 'UTC$s${a ~/ 60}:${(a % 60).toString().padLeft(2, '0')}';
}
