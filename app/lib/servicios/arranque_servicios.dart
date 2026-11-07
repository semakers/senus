// Lo que los servicios locales necesitan de la app: la carpeta de soporte, los
// assets y las licencias. Se llama una vez al abrir SENUS.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'catalogo_componentes.dart';
import 'gestor_componentes.dart';
import 'letra_telefono.dart';
import 'servicios_locales.dart';

Future<ServiciosLocales>? _instancia;

const _assetAvisos = 'assets/servicios/AVISOS_TERCEROS.txt';

/// Los servicios de esta sesión: se crean la primera vez.
Future<ServiciosLocales> serviciosSenus() => _instancia ??= _crear();

Future<ServiciosLocales> _crear() async {
  final soporte = await getApplicationSupportDirectory();
  final gz = await rootBundle.load(assetLetra);
  return ServiciosLocales(
    gestor: GestorComponentes(
      raiz: Directory(p.join(soporte.path, 'servicios')),
      catalogo: catalogoDePlataforma(),
      leerEmpotrado: (asset) async {
        final b = await rootBundle.load(asset);
        return b.buffer.asUint8List(b.offsetInBytes, b.lengthInBytes);
      },
    ),
    letra: LetraTelefono.desdeTabla(gz.buffer.asUint8List(gz.offsetInBytes, gz.lengthInBytes)),
    registro: kDebugMode ? debugPrint : null,
  );
}

/// Al abrir SENUS. No lanza: un fallo aquí no debe impedir abrir la app, y sin
/// servicios el teléfono lo dice igual que hoy con el servicio parado.
Future<void> iniciarServiciosSenus() async {
  LicenseRegistry.addLicense(() async* {
    final t = await rootBundle.loadString(_assetAvisos);
    yield LicenseEntryWithLineBreaks(const ['whisper.cpp', 'anyascii'], t);
  });
  try {
    final s = await serviciosSenus();
    await s.arrancar();
  } on Object catch (e) {
    debugPrint('servicios: $e');
  }
}
