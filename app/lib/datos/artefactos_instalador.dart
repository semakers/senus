// Artefactos EMPOTRADOS del instalador anycid + trampoline del W580.
//
// SENUS los CONSUME, no los produce: los copia tal cual
// `app/tool/empotrar_instalador_w580.py` desde donde nacen y deja el
// `MANIFIESTO.json` con el sha256 de cada uno. Aquí se leen, se comprueba que
// son lo que el manifiesto dice y que tienen la forma que el flujo necesita.
// Nada se modifica ni se recomprime.
//
//   DB2020.zip              NUESTRO. Su executor.jar lleva dentro
//                           cid52/db2020.bin = prefijo de SE + trampoline +
//                           bl.bin del installer. Es lo que el exploit JVM
//                           ejecuta. NO lleva executor.b.
//   R8BE001_*_GENERIC_*.zip ORIGINALES de Sony Ericsson (uno por región). Su
//                           executor.b (cabecero CAFEB00B) es lo que el AMS
//                           valida: si se toca, «Aplicación no válida». Se
//                           guardan INTACTOS; seftool elige el que toca según
//                           el CXC que lee del GDFS del aparato.
//   sistema_44180000.bin    main de senew (sis28h), al 0x44180000.
//   bl.bin                  BL clásico, al 0x44140000 (para la vuelta atrás y
//                           las iteraciones: el que queda grabado).
//
// Este fichero es Dart puro (sin Flutter) para poder probarse con `dart run`.
// La fuente que lee de los assets de Flutter vive en `artefactos_bundle.dart`.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'transporte_bl.dart' show blBloque, blMainFin, blMainIni;

/// De dónde salen los bytes. `nombre` es el del fichero dentro de la carpeta
/// del instalador (p. ej. `DB2020.zip`).
abstract class FuenteArtefactos {
  Future<Uint8List> leer(String nombre);
}

/// Una carpeta del disco (tests, CLI y la propia carpeta `assets/`).
class FuenteArtefactosCarpeta implements FuenteArtefactos {
  final String carpeta;
  const FuenteArtefactosCarpeta(this.carpeta);

  @override
  Future<Uint8List> leer(String nombre) async {
    final f = File(p.join(carpeta, nombre));
    if (!f.existsSync()) {
      throw ArtefactosError('Falta $nombre en el instalador empotrado.',
          remedio: 'Esta compilación de SENUS no lo trae. Regenera con '
              '`python3 -I app/tool/empotrar_instalador_w580.py` y recompila.');
    }
    return Uint8List.fromList(await f.readAsBytes());
  }
}

class ArtefactosError implements Exception {
  final String motivo;
  final String? remedio;
  const ArtefactosError(this.motivo, {this.remedio});
  @override
  String toString() => motivo;
}

/// Los artefactos ya leídos y comprobados.
class ArtefactosW580 {
  static const nombreDb2020 = 'DB2020.zip';
  static const nombreMain = 'sistema_44180000.bin';
  static const nombreBl = 'bl.bin';
  static const nombreManifiesto = 'MANIFIESTO.json';
  static const _executorB = 'tpa/preset/custom/executor.b';
  static const _executorJar = 'tpa/preset/custom/executor.jar';
  static const _customize = 'tpa/preset/custom/customize_upgrade.xml';
  static final _reR8be001 = RegExp(r'^R8BE001_.+_GENERIC_[A-Z]+\.zip$');

  /// El paquete de plataforma (NUESTRO).
  final Uint8List db2020Zip;

  /// Los paquetes por región (ORIGINALES de SE), por nombre CON `.zip`.
  final Map<String, Uint8List> paquetesR8be001;

  /// Main de senew (se graba en [blMainIni]).
  final Uint8List main;

  /// BL clásico (se graba en 0x44140000).
  final Uint8List blClasico;

  /// sha256 de cada fichero, tal como los fijó el manifiesto.
  final Map<String, String> sha256Por;

  /// Paquete en el que se verificó el flujo en silicio (del manifiesto).
  final String? paqueteVerificado;

  const ArtefactosW580._({
    required this.db2020Zip,
    required this.paquetesR8be001,
    required this.main,
    required this.blClasico,
    required this.sha256Por,
    required this.paqueteVerificado,
  });

  /// Nombre del paquete SIN `.zip`, como lo imprime `identify`
  /// («R8BE001_CXC1123362_GENERIC_LA»). ¿Lo trae esta compilación?
  bool traePaquete(String? sinZip) =>
      sinZip != null && paquetesR8be001.containsKey('$sinZip.zip');

  /// ¿Es el paquete en el que el flujo se probó en el aparato?
  bool esElVerificado(String? sinZip) =>
      sinZip != null && sinZip == paqueteVerificado;

  /// Lee y comprueba todo. Lanza [ArtefactosError] a la primera cosa rara,
  /// ANTES de que se toque el teléfono.
  static Future<ArtefactosW580> cargar(FuenteArtefactos fuente) async {
    final Map<String, dynamic> man;
    try {
      man = jsonDecode(utf8.decode(await fuente.leer(nombreManifiesto)))
          as Map<String, dynamic>;
    } on ArtefactosError {
      rethrow;
    } catch (e) {
      throw ArtefactosError('El MANIFIESTO.json del instalador no se puede '
          'leer ($e).');
    }
    final fich = (man['ficheros'] as Map?)?.cast<String, dynamic>() ?? const {};
    for (final n in [nombreDb2020, nombreMain, nombreBl]) {
      if (!fich.containsKey(n)) {
        throw ArtefactosError('El manifiesto no lista $n.');
      }
    }
    final nombresR8 = fich.keys.where(_reR8be001.hasMatch).toList()..sort();
    if (nombresR8.isEmpty) {
      throw const ArtefactosError(
          'El manifiesto no lista ningún paquete R8BE001.');
    }

    final shas = <String, String>{};
    Future<Uint8List> leerVerificado(String n) async {
      final b = await fuente.leer(n);
      final esperado = (fich[n] as Map)['sha256'] as String;
      final tam = (fich[n] as Map)['bytes'] as int;
      final real = sha256.convert(b).toString();
      if (real != esperado || b.length != tam) {
        throw ArtefactosError(
          '$n no es el que fijó el manifiesto '
          '(sha256 ${real.substring(0, 12)}…, ${b.length} B; se esperaba '
          '${esperado.substring(0, 12)}…, $tam B).',
          remedio: 'El fichero se alteró o se actualizó sin regenerar el '
              'manifiesto. Regenera con '
              '`python3 -I app/tool/empotrar_instalador_w580.py`.',
        );
      }
      shas[n] = real;
      return b;
    }

    final db2020 = await leerVerificado(nombreDb2020);
    final main = await leerVerificado(nombreMain);
    final bl = await leerVerificado(nombreBl);
    final r8 = <String, Uint8List>{};
    for (final n in nombresR8) {
      r8[n] = await leerVerificado(n);
    }

    _comprobarDb2020(db2020);
    for (final e in r8.entries) {
      _comprobarR8be001(e.key, e.value);
    }
    // El main va a 0x44180000..0x443C0000; el BL, a UN bloque de 256 KiB.
    if (main.isEmpty || main.length > blMainFin - blMainIni) {
      throw ArtefactosError('$nombreMain mide ${main.length} B y la zona del '
          'main es de ${blMainFin - blMainIni} B.');
    }
    if (bl.isEmpty || bl.length > blBloque) {
      throw ArtefactosError(
          '$nombreBl mide ${bl.length} B y cabe a lo sumo un bloque de '
          '$blBloque B.');
    }

    final v = (man['verificado_en_silicio'] as Map?)?.cast<String, dynamic>();
    return ArtefactosW580._(
      db2020Zip: db2020,
      paquetesR8be001: r8,
      main: main,
      blClasico: bl,
      sha256Por: shas,
      paqueteVerificado: v?['paquete'] as String?,
    );
  }

  /// DB2020.zip: lleva executor.jar con el exploit y NO lleva executor.b (el
  /// que valida el AMS es el original, en el zip por región).
  static void _comprobarDb2020(Uint8List b) {
    final z = ZipDecoder().decodeBytes(b);
    final nombres = {for (final f in z.files) f.name};
    for (final n in [_executorJar, _customize]) {
      if (!nombres.contains(n)) {
        throw ArtefactosError('$nombreDb2020 no trae $n.');
      }
    }
    if (nombres.contains(_executorB)) {
      throw const ArtefactosError(
        '$nombreDb2020 lleva un executor.b.',
        remedio: 'El .b que valida el AMS es el ORIGINAL de SE y va en el zip '
            'R8BE001; si se toca, el teléfono dice «Aplicación no válida».',
      );
    }
    final jar = z.files.firstWhere((f) => f.name == _executorJar);
    final j = ZipDecoder().decodeBytes(jar.content as List<int>);
    final bin = j.files.where((f) => f.name == 'cid52/db2020.bin');
    if (bin.isEmpty || (bin.first.content as List<int>).length <= 0x1B0) {
      throw const ArtefactosError(
          'El executor.jar de DB2020.zip no trae un cid52/db2020.bin con el '
          'trampoline y el BL installer.');
    }
  }

  /// R8BE001_*.zip: su executor.b es el ORIGINAL de SE (cabecero CAFEB00B).
  static void _comprobarR8be001(String nombre, Uint8List b) {
    final z = ZipDecoder().decodeBytes(b);
    final eb = z.files.where((f) => f.name == _executorB);
    if (eb.isEmpty) {
      throw ArtefactosError('$nombre no trae $_executorB.');
    }
    final c = eb.first.content as List<int>;
    if (c.length < 4 ||
        c[0] != 0xCA ||
        c[1] != 0xFE ||
        c[2] != 0xB0 ||
        c[3] != 0x0B) {
      throw ArtefactosError(
        '$nombre: su executor.b no empieza por CAFEB00B: NO es el original '
        'de SE.',
        remedio: 'El AMS rechaza un .b modificado. Hay que volver a empotrar '
            'el paquete original.',
      );
    }
  }
}
