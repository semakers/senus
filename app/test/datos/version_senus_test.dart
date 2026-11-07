import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:senus_app/datos/version_senus.dart';

void main() {
  test('la versión que enseña la app es la de pubspec.yaml', () {
    final pub = File('pubspec.yaml').readAsStringSync();
    final m = RegExp(r'^version:\s*([0-9][^\s+]*)', multiLine: true).firstMatch(pub);
    expect(m, isNotNull);
    expect(versionSenus, m!.group(1));
  });

  test('las licencias de terceros están en los assets', () {
    for (final f in [
      'assets/licencias/SENUS-GPL-3.0.txt',
      'assets/licencias/seftool-MIT.txt',
      'assets/licencias/libusb-LGPL-2.1.txt',
      'assets/licencias/libwdi-LGPL-3.0.txt',
      'assets/licencias/AVISOS.txt',
      'assets/fuentes/Inter-OFL.txt',
      'assets/fuentes/JetBrainsMono-OFL.txt',
    ]) {
      expect(File(f).existsSync(), isTrue, reason: f);
    }
  });
}
