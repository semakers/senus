// El cliente del backend: lo que se acepta, lo que no y el modo sin red. Las
// firmas son reales (ed25519) con una clave de prueba.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:senus_app/datos/backend_semakers.dart';
import 'package:senus_app/datos/claves_semakers.dart';
import 'package:senus_app/datos/indice_semakers.dart';

import 'apoyo/backend_simulado.dart';

final hoy = DateTime.utc(2026, 11, 1);

class Banco {
  final Directory dir = Directory.systemTemp.createTempSync('senus_back_');
  final RedSimulada red = RedSimulada();
  late final Publicador pub = Publicador(red);
  DateTime ahora = hoy;
  late ClienteBackend cli = nuevo();

  ClienteBackend nuevo({List<Uint8List>? claves}) => ClienteBackend(
        red: red,
        cache: dir,
        claves: claves ?? [publica],
        ahora: () => ahora,
      );

  void limpiar() => dir.deleteSync(recursive: true);
}

Matcher rechazado(MotivoRechazo m) => throwsA(
    isA<ErrorVerificacion>().having((e) => e.motivo, 'motivo', m));

void main() {
  group('índice', () {
    test('uno bueno se acepta y se guarda', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.pub.publicarApp('calc', senDePrueba());
      b.pub.firmarIndice();
      final r = await b.cli.indice();
      expect(r.sinRed, isFalse);
      expect(r.indice.secuencia, 1);
      expect(r.indice.apps.single.id, 'calc');
      expect(File(p.join(b.dir.path, 'indice.json')).existsSync(), isTrue);
    });

    test('mal firmado: no entra', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.pub.firmarIndice(clave: claveDeSemilla(Uint8List(32)));
      expect(b.cli.indice(), rechazado(MotivoRechazo.firmaMala));
    });

    test('un byte cambiado rompe la firma', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.pub.firmarIndice();
      final x = Uint8List.fromList(b.red.rutas['/v1/indice.json']!);
      x[20] ^= 1;
      b.red.poner('/v1/indice.json', x);
      expect(b.cli.indice(), rechazado(MotivoRechazo.firmaMala));
    });

    test('firma de 63 bytes: no entra', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.pub.firmarIndice();
      b.red.poner('/v1/indice.json.sig',
          b.red.rutas['/v1/indice.json.sig']!.sublist(0, 63));
      expect(b.cli.indice(), rechazado(MotivoRechazo.firmaMala));
    });

    test('caducado: no entra aunque la firma sea buena', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.pub.firmarIndice(caduca: hoy.subtract(const Duration(seconds: 1)));
      expect(b.cli.indice(), rechazado(MotivoRechazo.caducado));
    });

    test('sin caducar por un segundo: entra', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.pub.firmarIndice(caduca: hoy.add(const Duration(seconds: 1)));
      expect((await b.cli.indice()).indice.secuencia, 1);
    });

    test('secuencia que retrocede: se queda con el que tenía', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.pub.firmarIndice(sec: 5);
      await b.cli.indice();
      b.pub.firmarIndice(sec: 4);
      final r = await b.cli.indice();
      expect(r.rechazo?.motivo, MotivoRechazo.secuenciaVieja);
      expect(r.indice.secuencia, 5);
      expect(r.sinRed, isTrue);
    });

    test('la secuencia vista sobrevive a reiniciar SENUS', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.pub.firmarIndice(sec: 5);
      await b.cli.indice();
      b.pub.firmarIndice(sec: 4);
      final r = await b.nuevo().indice();
      expect(r.rechazo?.motivo, MotivoRechazo.secuenciaVieja);
    });

    test('un índice rechazado no mueve la secuencia vista', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.pub.firmarIndice(sec: 5);
      await b.cli.indice();
      b.pub.firmarIndice(sec: 9, clave: claveDeSemilla(Uint8List(32)));
      await b.cli.indice();
      b.pub.firmarIndice(sec: 6);
      expect((await b.cli.indice()).indice.secuencia, 6);
    });

    test('la misma secuencia con otros bytes: no se cree', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.pub.firmarIndice(sec: 5);
      await b.cli.indice();
      b.pub.publicarApp('otra', senDePrueba());
      b.pub.firmarIndice(sec: 5);
      final r = await b.cli.indice();
      expect(r.rechazo?.motivo, MotivoRechazo.secuenciaVieja);
      expect(r.indice.apps, isEmpty);
    });

    test('la misma secuencia con los mismos bytes: normal', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.pub.firmarIndice(sec: 5);
      await b.cli.indice();
      final r = await b.cli.indice();
      expect(r.rechazo, isNull);
      expect(r.sinRed, isFalse);
    });

    test('JSON roto, aunque esté firmado: no entra', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      final x = Uint8List.fromList('{"formato":1'.codeUnits);
      b.red.poner('/v1/indice.json', x);
      b.red.poner('/v1/indice.json.sig', firmar(x));
      expect(b.cli.indice(), rechazado(MotivoRechazo.formatoMalo));
    });

    test('un id con barras, aunque esté firmado: no entra', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.pub.publicarApp('calc', senDePrueba());
      b.pub.apps.first['id'] = '../sistema';
      b.pub.firmarIndice();
      expect(b.cli.indice(), rechazado(MotivoRechazo.formatoMalo));
    });

    test('sin claves en esta compilación: se dice, no se acepta', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.pub.firmarIndice();
      expect(b.nuevo(claves: const []).indice(),
          rechazado(MotivoRechazo.sinClaves));
    });
  });

  group('la caché con varias pantallas a la vez', () {
    test('dos indice() a la vez no se pisan el temporal', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.pub.publicarApp('calc', senDePrueba());
      b.pub.firmarIndice();
      final r = await Future.wait([for (var i = 0; i < 8; i++) b.cli.indice()]);
      expect(r.every((x) => x.rechazo == null && !x.sinRed), isTrue);
      expect((await b.cli.indice()).indice.secuencia, 1);
      expect(
          b.dir.listSync(recursive: true).where((f) => f.path.contains('.tmp')),
          isEmpty);
    });

    test('escribirAtomico: veinte a la vez, gana una entera', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      final f = File(p.join(b.dir.path, 'sub', 'x.bin'));
      final datos = [
        for (var i = 0; i < 20; i++) List<int>.filled(4096, i)
      ];
      await Future.wait([for (final d in datos) escribirAtomico(f, d)]);
      final l = f.readAsBytesSync();
      expect(l, hasLength(4096));
      expect(l.toSet(), hasLength(1));
      expect(f.parent.listSync(), hasLength(1), reason: 'sin temporales');
    });

    test('escribirAtomico: si no se puede, no deja temporales', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      final dir = Directory(p.join(b.dir.path, 'destino'))..createSync();
      await expectLater(escribirAtomico(File(dir.path), [1]),
          throwsA(isA<FileSystemException>()));
      expect(
          b.dir.listSync().where((f) => f.path.contains('.tmp')), isEmpty);
    });

    test('una caché que no se puede escribir no impide nada', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      final bloqueo = File(p.join(b.dir.path, 'es_un_fichero'))
        ..writeAsStringSync('x');
      final cli = ClienteBackend(
          red: b.red,
          cache: Directory(bloqueo.path),
          claves: [publica],
          ahora: () => hoy);
      final sen = senDePrueba();
      b.pub.publicarApp('calc', sen);
      b.pub.firmarIndice();
      final i = await cli.indice();
      expect(i.indice.apps, hasLength(1));
      expect((await cli.descargarApp(i.indice.apps.single)).bytes, sen);
    });
  });

  group('claves fijadas', () {
    test('sin modo desarrollo: solo las dos reales, la de desarrollo NO', () {
      final l = clavesAceptadas(desarrollo: false);
      expect(l, hasLength(2));
      final dev = clavePublica(clavePublicaDesarrollo);
      expect(l.any((k) => k.toString() == dev.toString()), isFalse);
    });

    test('en modo desarrollo, además la de claves/desarrollo.pub', () {
      final l = clavesAceptadas(desarrollo: true);
      expect(l, hasLength(3));
      expect(l.last, clavePublica(clavePublicaDesarrollo));
      for (final k in l) {
        expect(k, hasLength(32));
      }
    });

    test('por omisión, el backend de producción', () {
      expect(urlBackendPredeterminada, 'https://api.semakers.com');
    });

    test('esta compilación de pruebas no lleva el modo desarrollo', () {
      expect(modoDesarrollo, isFalse);
    });
  });

  group('sin red', () {
    test('sirve lo último verificado', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.pub.publicarApp('calc', senDePrueba());
      b.pub.firmarIndice(sec: 3);
      await b.cli.indice();
      b.red.caido = true;
      final r = await b.cli.indice();
      expect(r.sinRed, isTrue);
      expect(r.rechazo, isNull);
      expect(r.indice.secuencia, 3);
      expect(r.indice.apps, hasLength(1));
    });

    test('sin caché y sin red: lo dice', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.red.caido = true;
      expect(b.cli.indice(), throwsA(isA<SinRed>()));
    });

    test('un 500 del servidor cuenta como sin red', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.pub.firmarIndice(sec: 3);
      await b.cli.indice();
      b.red.rutas.remove('/v1/indice.json');
      expect((await b.cli.indice()).sinRed, isTrue);
    });

    test('la caché también caduca', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.pub.firmarIndice(sec: 3, caduca: hoy.add(const Duration(days: 1)));
      await b.cli.indice();
      b.red.caido = true;
      b.ahora = hoy.add(const Duration(days: 2));
      expect(b.cli.indice(), rechazado(MotivoRechazo.caducado));
    });

    test('un índice tocado en el disco no vale', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.pub.firmarIndice(sec: 3);
      await b.cli.indice();
      final f = File(p.join(b.dir.path, 'indice.json'));
      final d = f.readAsBytesSync()..[5] ^= 1;
      f.writeAsBytesSync(d);
      b.red.caido = true;
      expect(b.cli.indice(), rechazado(MotivoRechazo.firmaMala));
    });

    test('una app ya descargada se reinstala sin red', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      final sen = senDePrueba();
      b.pub.publicarApp('calc', sen);
      b.pub.firmarIndice();
      final a = (await b.cli.indice()).indice.apps.single;
      await b.cli.descargarApp(a);
      b.red.caido = true;
      final d = await b.cli.descargarApp(a);
      expect(d.bytes, sen);
    });

    test('una app sin bajar, sin red: lo dice', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.pub.publicarApp('calc', senDePrueba());
      b.pub.firmarIndice();
      final a = (await b.cli.indice()).indice.apps.single;
      b.red.caido = true;
      expect(b.cli.descargarApp(a), throwsA(isA<SinRed>()));
    });
  });

  group('app', () {
    Future<(Banco, AppIndice, String)> preparar() async {
      final b = Banco();
      addTearDown(b.limpiar);
      final sen = senDePrueba(nombre: 'Calculadora');
      b.pub.publicarApp('calc', sen, nombre: 'Calculadora');
      b.pub.firmarIndice();
      final a = (await b.cli.indice()).indice.apps.single;
      return (b, a, a.sha256);
    }

    test('buena: firma, sha256 y CRC', () async {
      final (b, a, _) = await preparar();
      final d = await b.cli.descargarApp(a);
      expect(d.manifiesto.json['id'], 'calc');
    });

    test('un binario con otro sha256 no se guarda', () async {
      final (b, a, sha) = await preparar();
      final malo = Uint8List.fromList(senDePrueba(verApp: 2));
      b.red.poner('/v1/archivos/$sha', malo);
      await expectLater(
          b.cli.descargarApp(a), rechazado(MotivoRechazo.shaDistinto));
      expect(File(p.join(b.dir.path, 'archivos', sha)).existsSync(), isFalse);
    });

    test('un binario tocado en la caché se vuelve a bajar', () async {
      final (b, a, sha) = await preparar();
      await b.cli.descargarApp(a);
      final f = File(p.join(b.dir.path, 'archivos', sha));
      f.writeAsBytesSync([1, 2, 3]);
      final d = await b.cli.descargarApp(a);
      expect(sha256De(d.bytes), sha);
    });

    test('manifiesto cambiado: su sha256 no es el del índice', () async {
      final (b, a, _) = await preparar();
      const r = '/v1/apps/calc/versiones/1/manifiesto.json';
      final x = Uint8List.fromList(b.red.rutas[r]!)..[30] ^= 1;
      b.red.poner(r, x);
      b.red.poner('$r.sig', firmar(x));
      expect(b.cli.descargarApp(a), rechazado(MotivoRechazo.shaDistinto));
    });

    test('manifiesto mal firmado', () async {
      final (b, a, _) = await preparar();
      const r = '/v1/apps/calc/versiones/1/manifiesto.json';
      b.red.poner('$r.sig', firmar(b.red.rutas[r]!, claveDeSemilla(Uint8List(32))));
      expect(b.cli.descargarApp(a), rechazado(MotivoRechazo.firmaMala));
    });

    test('un .sen firmado con la CRC del cuerpo mal no se acepta', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      final sen = senDePrueba()..[130] ^= 1;
      b.pub.publicarApp('calc', sen);
      b.pub.firmarIndice();
      final a = (await b.cli.indice()).indice.apps.single;
      expect(b.cli.descargarApp(a), rechazado(MotivoRechazo.imagenMala));
    });

    test('verificarSen por sí sola: mismo tamaño y otro sha256', () async {
      final (_, a, _) = await preparar();
      final otro = senDePrueba(nombre: 'Calculadorb');
      expect(otro.length, a.tam);
      expect(() => verificarSen(otro, a), rechazado(MotivoRechazo.shaDistinto));
    });

    test('verificarSen por sí sola: otro tamaño', () async {
      final (_, a, _) = await preparar();
      expect(() => verificarSen(senDePrueba(tamCodigo: 128), a),
          rechazado(MotivoRechazo.tamanoDistinto));
    });

    test('ver_app del índice distinta de la cabecera no se acepta', () async {
      final b = Banco();
      addTearDown(b.limpiar);
      b.pub.publicarApp('calc', senDePrueba(verApp: 2));
      b.pub.apps.first['ver_app'] = 3;
      b.pub.firmarIndice();
      final a = (await b.cli.indice()).indice.apps.single;
      await expectLater(b.cli.descargarApp(a), throwsA(isA<Exception>()));
    });
  });

  test('verificarMain por sí sola: mismo tamaño y otro sha256', () async {
    final b = Banco();
    addTearDown(b.limpiar);
    final m = _main();
    b.pub.publicarSenew(291, '0.29.1', m);
    b.pub.firmarIndice();
    final r = (await b.cli.indice()).indice.senew.single;
    final d = await b.cli.descargarRelease(r);
    final otro = Uint8List.fromList(m)..[0x800] ^= 1;
    expect(() => verificarMain(otro, r, d.manifiesto.json),
        rechazado(MotivoRechazo.shaDistinto));
  });

  test('una release que no existe cuenta como sin red', () async {
    final b = Banco();
    addTearDown(b.limpiar);
    b.pub.publicarSenew(291, '0.29.1', _main());
    b.pub.firmarIndice();
    final r = (await b.cli.indice()).indice.senew.single;
    b.red.rutas.removeWhere((k, _) => k.contains('releases'));
    expect(b.cli.descargarRelease(r), throwsA(isA<SinRed>()));
  });

  test('releases por modelo, de la más nueva a la más vieja', () async {
    final b = Banco();
    addTearDown(b.limpiar);
    b.pub.publicarSenew(288, '0.28.8', _main());
    b.pub.publicarSenew(291, '0.29.1', _main());
    b.pub.publicarSenew(290, '0.29.0', _main());
    b.pub.firmarIndice();
    final i = (await b.cli.indice()).indice;
    expect(i.releasesDe('w580').map((r) => r.build), [291, 290, 288]);
    expect(i.releasesDe('w600'), isEmpty);
  });

  group('vectores RFC 8032 con el ed25519 elegido', () {
    Uint8List h(String s) => Uint8List.fromList([
          for (var i = 0; i < s.length; i += 2)
            int.parse(s.substring(i, i + 2), radix: 16)
        ]);

    final pub1 = h('d75a980182b10ab7d54bfed3c964073a'
        '0ee172f3daa62325af021a68f707511a');
    final sig1 = h('e5564300c360ac729086e2cc806e828a'
        '84877f1eb8e5d974d873e06522490155'
        '5fb8821590a33bacc61e39701cf9b46b'
        'd25bf5f0595bbe24655141438e7a100b');

    test('TEST 1 vale', () {
      expect(firmaValida(Uint8List(0), sig1, [pub1]), isTrue);
    });

    test('con un bit cambiado, no', () {
      final s = Uint8List.fromList(sig1)..[0] ^= 1;
      expect(firmaValida(Uint8List(0), s, [pub1]), isFalse);
    });

    test('S no canónico (S + L) no vale', () {
      // S + L: misma firma si no se comprueba S < L.
      final s = BigInt.parse(
          sig1.sublist(32).reversed.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
          radix: 16);
      final l = (BigInt.one << 252) +
          BigInt.parse('27742317777372353535851937790883648493');
      final t = s + l;
      final bytes = Uint8List(32);
      var x = t;
      for (var i = 0; i < 32; i++) {
        bytes[i] = (x & BigInt.from(0xFF)).toInt();
        x >>= 8;
      }
      final mala = Uint8List.fromList([...sig1.sublist(0, 32), ...bytes]);
      expect(firmaValida(Uint8List(0), mala, [pub1]), isFalse);
    });

    test('una clave de otro tamaño cuenta como que no firmó', () {
      expect(firmaValida(Uint8List(0), sig1, [Uint8List(31)]), isFalse);
    });

    test('la segunda clave también vale: principal y reserva', () {
      expect(firmaValida(Uint8List(0), sig1, [publica, pub1]), isTrue);
    });
  });
}

Uint8List _main() {
  final b = Uint8List(0x1000);
  final v = ByteData.sublistView(b);
  for (var i = 0; i < 8; i++) {
    v.setUint32(i * 4, 0xE59FF018, Endian.little);
  }
  v.setUint32(0x20, 0x441800B0, Endian.little);
  return b;
}
