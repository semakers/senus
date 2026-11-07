// Lo que las pantallas usan sin saber de dónde sale: las rutas reales y el
// backend de esta compilación. Las pruebas inyectan otra cosa.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'actualizacion_senew.dart';
import 'backend_semakers.dart';
import 'claves_semakers.dart';

/// El backend de esta compilación: `SENUS_BACKEND` manda en tiempo de ejecución
/// sobre la URL; las claves son siempre las de la compilación.
Future<ClienteBackend> backendPredeterminado() async {
  final soporte = await getApplicationSupportDirectory();
  final url = Platform.environment['SENUS_BACKEND']?.trim();
  return ClienteBackend(
    red: RedHttp(url == null || url.isEmpty ? urlBackendPredeterminada : url),
    cache: Directory(p.join(soporte.path, 'backend')),
    claves: clavesAceptadas(),
  );
}

Future<AlmacenActualizacion> almacenPredeterminado() async {
  final soporte = await getApplicationSupportDirectory();
  return AlmacenActualizacion(Directory(p.join(soporte.path, 'actualizacion')));
}
