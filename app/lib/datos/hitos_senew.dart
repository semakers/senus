// Descubre y describe las imágenes de senew (`*_44140000.bin`) del
// directorio de build del aparato. La UI del dropdown de instalación
// (pant_instalar_senew.dart) consume este catálogo; el banco de pruebas
// `bin/prueba_cable_real.dart` también lo usa para enumerar los hitos
// a instalar.
//
// Se separa aquí porque es lógica pura (IO del disco, sin UI): se prueba
// con `dart test` directamente, sin arrancar el engine de Flutter.

import 'dart:io';

import 'package:path/path.dart' as p;

/// Una imagen de senew encontrada en la carpeta `build/aparato/`.
class HitoSenew {
  final String nombreArchivo;
  final int tamanoBytes;
  final bool tocaNor;
  final String etiqueta;
  const HitoSenew(
      this.nombreArchivo, this.tamanoBytes, this.tocaNor, this.etiqueta);
}

/// Orden de la primera prueba, calcado del MANIFIESTO del sistema (ver
/// `senew-w580/build/aparato/MANIFIESTO.txt`). Las imágenes que
/// no caen aquí dentro se ordenan alfabéticamente al final.
const ordenHitosManifiesto = <String>[
  'hito_2_44140000.bin',
  'hito_6_44140000.bin',
  'hito_3_44140000.bin',
  'hito_3_todas_44140000.bin',
  'hito_4_44140000.bin',
  'hito_5_44140000.bin',
  'paso_7_sin_escritura_44140000.bin',
  'sistema_sin_escritura_44140000.bin',
  'sistema_44140000.bin',
];

/// Etiquetas humanas por nombre de archivo. Las imágenes del MANIFIESTO
/// las enumera abajo; las nuevas (si en algún futuro se añaden) caen a
/// una etiqueta genérica.
const etiquetasHitosManifiesto = <String, String>{
  'hito_2_44140000.bin': 'señal de vida mínima (NOR: 1 sector físico)',
  'hito_6_44140000.bin': 'reloj + pulsadores',
  'hito_3_44140000.bin': 'LCD',
  'hito_3_todas_44140000.bin': 'LCD alternativo (si el anterior se queda a oscuras)',
  'hito_4_44140000.bin': 'teclado y luces',
  'hito_5_44140000.bin': 'audio',
  'paso_7_sin_escritura_44140000.bin': 'MMU + interrupciones + PMU — NO toca NOR',
  'sistema_sin_escritura_44140000.bin': 'sistema sin escrituras — NO toca NOR',
  'sistema_44140000.bin': 'main completo — escribe NOR',
};

/// Convención del MANIFIESTO: un nombre con `sin_escritura` indica que
/// la imagen NO toca NOR. Es un detalle crítico para la UI (color del
/// aviso) y para la decisión del humano al pulsar.
bool tocaNorPorNombre(String nombre) => !nombre.contains('sin_escritura');

/// Comparador de hitos: primero los del MANIFIESTO en el orden fijado,
/// después los que no están, por orden alfabético.
int compararHitos(String a, String b) {
  final ia = ordenHitosManifiesto.indexOf(a);
  final ib = ordenHitosManifiesto.indexOf(b);
  if (ia >= 0 && ib >= 0) return ia.compareTo(ib);
  if (ia >= 0) return -1;
  if (ib >= 0) return 1;
  return a.compareTo(b);
}

/// Nombre del hito que debería estar seleccionado por omisión: el primero
/// de la secuencia del MANIFIESTO que esté presente. Si la lista está
/// vacía, null.
String? hitoPorOmision(List<HitoSenew> hitos) {
  if (hitos.isEmpty) return null;
  for (final n in ordenHitosManifiesto) {
    final match = hitos.where((h) => h.nombreArchivo == n);
    if (match.isNotEmpty) return match.first.nombreArchivo;
  }
  return hitos.first.nombreArchivo;
}

/// Descubre las imágenes `*_44140000.bin` dentro de [carpeta] y las
/// devuelve ordenadas por [compararHitos]. Si la carpeta no existe,
/// devuelve una lista vacía (en vez de lanzar).
Future<List<HitoSenew>> descubrirHitos(String carpeta) async {
  final dir = Directory(carpeta);
  if (!await dir.exists()) return const [];
  final re = RegExp(r'_44140000\.bin$');
  final out = <HitoSenew>[];
  await for (final e in dir.list()) {
    if (e is! File) continue;
    final nombre = p.basename(e.path);
    if (!re.hasMatch(nombre)) continue;
    final tam = await e.length();
    final etiqueta = etiquetasHitosManifiesto[nombre] ?? '(sin descripción)';
    out.add(HitoSenew(nombre, tam, tocaNorPorNombre(nombre), etiqueta));
  }
  out.sort((a, b) => compararHitos(a.nombreArchivo, b.nombreArchivo));
  return out;
}
