// La fuente de los artefactos del instalador que lee de los assets de Flutter
// (los que `pubspec.yaml` empotra en el .app). Aparte de
// `artefactos_instalador.dart` para que éste siga siendo Dart puro.

import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

import 'artefactos_instalador.dart';

class FuenteArtefactosBundle implements FuenteArtefactos {
  /// Carpeta de los assets (la misma que lista `pubspec.yaml`).
  static const base = 'assets/instalador/w580';

  const FuenteArtefactosBundle();

  @override
  Future<Uint8List> leer(String nombre) async {
    try {
      final d = await rootBundle.load('$base/$nombre');
      return d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes);
    } catch (_) {
      throw ArtefactosError('Falta $nombre en el instalador empotrado.',
          remedio: 'Esta compilación de SENUS no lo trae. Regenera con '
              '`python3 -I app/tool/empotrar_instalador_w580.py` y recompila.');
    }
  }
}
