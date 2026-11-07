// Las licencias que no trae Flutter por su cuenta: la de SENUS y las de los programas de terceros que
// van dentro del instalador (seftool, libusb, libwdi) y las letras. Se ven en Ajustes › Licencias.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

const _licencias = <(List<String>, String)>[
  (['SENUS'], 'assets/licencias/SENUS-GPL-3.0.txt'),
  (['seftool'], 'assets/licencias/seftool-MIT.txt'),
  (['libusb'], 'assets/licencias/libusb-LGPL-2.1.txt'),
  (['libwdi'], 'assets/licencias/libwdi-LGPL-3.0.txt'),
  (['Inter'], 'assets/fuentes/Inter-OFL.txt'),
  (['JetBrains Mono'], 'assets/fuentes/JetBrainsMono-OFL.txt'),
  (['whisper.cpp', 'anyascii'], 'assets/servicios/AVISOS_TERCEROS.txt'),
];

/// Las añade al registro de Flutter (la pantalla estándar de licencias las lee de ahí).
void registrarLicenciasTerceros() {
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(['SENUS'], _avisoSenus);
    for (final (paquetes, ruta) in _licencias) {
      try {
        yield LicenseEntryWithLineBreaks(paquetes, await rootBundle.loadString(ruta));
      } catch (_) {
        // Si falta un fichero, la pantalla enseña las demás.
      }
    }
  });
}

const _avisoSenus = 'SENUS es software libre (GPL-3.0). Código fuente: https://github.com/semakers/senus\n\n'
    'Es un proyecto nuevo, de la comunidad, sin relación con Sony ni con Sony Ericsson. Se usa bajo tu '
    'propio riesgo: instalar senew cambia el software del teléfono.\n\n'
    'Los paquetes R8BE001_*_GENERIC_*.zip (el «executor» original del teléfono) son de Sony Ericsson y '
    'van dentro solo para que la primera instalación funcione.';
