import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:senus_app/datos/seftool.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('seftool_raiz_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File escribir(String ruta, String texto) =>
      File(ruta)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(texto);

  test('SENUS_SEFTOOL_RAIZ manda', () {
    expect(Seftool.resolverRaiz(env: {'SENUS_SEFTOOL_RAIZ': '/x/y'}, exe: '/a/b'), '/x/y');
  });

  test('Windows: la carpeta seftool junto al ejecutable', () {
    escribir(p.join(tmp.path, 'SENUS', 'seftool', 'seftool.exe'), 'exe');
    expect(Seftool.resolverRaiz(env: {'USERPROFILE': tmp.path}, exe: p.join(tmp.path, 'SENUS', 'senus_app.exe')),
        p.join(tmp.path, 'SENUS', 'seftool'));
  });

  test('macOS: el seftool del .app se copia a Application Support y se usa la copia', () {
    final res = p.join(tmp.path, 'SENUS.app', 'Contents', 'Resources', 'seftool');
    escribir(p.join(res, 'seftool'), 'binario-v1');
    escribir(p.join(res, 'loader', 'db2020_x.bin'), 'loader');
    final hogar = p.join(tmp.path, 'casa');
    final exe = p.join(tmp.path, 'SENUS.app', 'Contents', 'MacOS', 'SENUS');
    final raiz = Seftool.resolverRaiz(env: {'HOME': hogar}, exe: exe);
    expect(raiz, p.join(hogar, 'Library', 'Application Support', 'SENUS', 'seftool'));
    expect(File(p.join(raiz, 'seftool')).readAsStringSync(), 'binario-v1');
    expect(File(p.join(raiz, 'loader', 'db2020_x.bin')).existsSync(), isTrue);

    // Un volcado de la persona se queda; un seftool nuevo en el .app sustituye al viejo.
    escribir(p.join(raiz, 'backup', 'gdfs.bin'), 'mio');
    sleep(const Duration(milliseconds: 1100));
    escribir(p.join(res, 'seftool'), 'binario-v2-mas-largo');
    Seftool.resolverRaiz(env: {'HOME': hogar}, exe: exe);
    expect(File(p.join(raiz, 'seftool')).readAsStringSync(), 'binario-v2-mas-largo');
    expect(File(p.join(raiz, 'backup', 'gdfs.bin')).readAsStringSync(), 'mio');
  });

  test('sin nada empaquetado: el fork de desarrollo', () {
    expect(Seftool.resolverRaiz(env: {'HOME': '/casa'}, exe: '/opt/x/senus_app'),
        p.join('/casa', 'dev', 'seftool-senew'));
  });
}
