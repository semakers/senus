// Pruebas de la capa de mando de seftool, SIN aparato y SIN abrir un puerto.
//
// Lo que se comprueba:
//   - el parseo de la salida real de `identify` (texto copiado del fuente del
//     fork: loader.c:545,552 y action.c:218-290);
//   - que un seftool que NO existe da un SeftoolError con remedio, y no se
//     queda colgado ni revienta con una excepción de plataforma;
//   - que la autodetección de puerto no abre nada;
//   - el modo ensayo (SENUS_SEFTOOL_ENSAYO=1) no ejecuta nada.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:senus_app/datos/seftool.dart';

// Salida real de seftool para un W580i CID53 RED, montada a partir de los
// printf del fork. OJO al «ACTIVE CID:53» sin espacio y a que NO hay línea
// «Serial:»: el número de serie es el IMEI.
const _identifyW580Cid53 = '''
Phone type: DB2020
FLASH ID: 0x8918 (Intel)
OTP: LOCKED:1 CID:53 PAF:0 IMEI:35697201234567

ACTIVE CID:53 COLOR:RED

Phone Info (from GDFS):
Model: W580i
Brand: Sony Ericsson
MAPP CXC article: CXC1123362
MAPP CXC version: R8BE001
Language Package: CXC1250374
CDA article: CDA102030
CDA revision: R4A
Default article: CXC1123362
Default version: R8BE001
SIMLOCKS NOT DETECTED
Provider: -

Restore firmware not found
Anycid package: ./anycid/R8BE001_CXC1123362_GENERIC_LA.zip
''';

const _identifyW810Cid49 = '''
FLASH ID: 0x88CF (Intel)
OTP: LOCKED:1 CID:49 PAF:0 IMEI:35812300765432

Phone Info (from GDFS):
Model: W810i
Brand: Sony Ericsson
MAPP CXC version: R4EA031
LOCKED
Provider: 334-020
User code: 0000
''';

void main() {
  group('leerIdentify', () {
    test('W580i CID53 RED: saca modelo, IMEI, CID, color, firmware y anycid',
        () {
      final i = Seftool.leerIdentify(_identifyW580Cid53);
      expect(i.modelo, 'W580i');
      expect(i.modeloCorto, 'W580');
      expect(i.soc, 'DB2020');
      expect(i.imei, '35697201234567');
      expect(i.cidActivo, '53');
      expect(i.cidOtp, '53');
      expect(i.cid, '53');
      expect(i.color, 'RED');
      expect(i.cxcArticulo, 'CXC1123362');
      expect(i.cxcVersion, 'R8BE001');
      expect(i.paqueteAnycid, 'R8BE001_CXC1123362_GENERIC_LA');
      expect(i.simlockDetectado, isFalse);
      // El camino del martes: W580 CID53 => anycid, no reemplazo frío.
      expect(i.necesitaAnycid, isTrue);
    });

    test('W810i CID49: sin línea ACTIVE CID, el CID sale del OTP', () {
      final i = Seftool.leerIdentify(_identifyW810Cid49);
      expect(i.modeloCorto, 'W810');
      expect(i.soc, 'DB2010');
      expect(i.cidActivo, isEmpty);
      expect(i.cid, '49'); // cae al OTP
      expect(i.imei, '35812300765432');
      expect(i.cxcVersion, 'R4EA031');
      expect(i.simlockDetectado, isTrue);
      expect(i.necesitaAnycid, isFalse); // DB2010 => reemplazo frío
    });

    test('un CID con cero delante no se queda en "0"', () {
      final i = Seftool.leerIdentify('ACTIVE CID:49 COLOR:RED\n');
      expect(i.cidActivo, '49');
    });

    test('«IMEI:» sin valor no se lleva la primera palabra de la línea siguiente',
        () {
      // El IMEI identifica al aparato en cada orden (--imei): «ACTIVE» no
      // puede pasar por uno.
      final i = Seftool.leerIdentify(
          'OTP: LOCKED:0 CID:52 PAF:0 IMEI:\nACTIVE CID:52 COLOR:RED\n');
      expect(i.imei, isEmpty);
      expect(i.cidActivo, '52');
      // Con espacio y con valor, sí.
      expect(Seftool.leerIdentify('IMEI: 49015420323751\n').imei, '49015420323751');
      expect(Seftool.leerIdentify('IMEI:49015420323751\n').imei, '49015420323751');
    });

    test('salida vacía no revienta, sólo queda todo vacío', () {
      final i = Seftool.leerIdentify('');
      expect(i.modelo, isEmpty);
      expect(i.imei, isEmpty);
      expect(i.paqueteAnycid, isNull);
    });
  });

  group('binario ausente', () {
    test('exigirBinario da SeftoolError con la ruta esperada y el remedio', () {
      final s = Seftool(
          raiz: '/ruta/que/no/existe/seftool-senew',
          puerto: '/dev/puerto-que-no-existe',
          ensayo: false);
      expect(
        () => s.exigirBinario(),
        // En la Mac seftool se compila con mac/build.sh (sin cmake) y deja el
        // binario en la raíz; en Linux, con cmake, en build/seftool.
        throwsA(isA<SeftoolError>()
            .having((e) => e.remedio, 'remedio',
                contains(Platform.isMacOS ? 'mac/build.sh' : 'cmake --build'))
            .having((e) => e.remedio, 'remedio',
                contains(Platform.isMacOS ? '/seftool' : 'build/seftool'))),
      );
    });

    test('correr() falla limpio y PRONTO, sin colgarse ni abrir el puerto',
        () async {
      final s = Seftool(
          raiz: '/ruta/que/no/existe/seftool-senew',
          puerto: '/dev/puerto-que-no-existe',
          ensayo: false);
      await expectLater(
        s.correr(['identify']).toList(),
        throwsA(isA<SeftoolError>()),
      );
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('identify() con binario ausente también falla limpio', () async {
      final s = Seftool(
          raiz: '/ruta/que/no/existe/seftool-senew',
          puerto: '/dev/puerto-que-no-existe',
          ensayo: false);
      await expectLater(s.identify(), throwsA(isA<SeftoolError>()));
    }, timeout: const Timeout(Duration(seconds: 10)));
  });

  group('puertos', () {
    test('autodetectar no abre nada y aguanta no encontrar ninguno', () {
      // No se afirma QUÉ encuentra (depende de la máquina); se afirma que no
      // explota y que, si devuelve algo, es una ruta con pinta de puerto.
      final c = Seftool.puertosCandidatos();
      for (final x in c) {
        expect(
            x,
            // «usb»: en la Mac se habla con el teléfono por libusb directo.
            anyOf(contains('tty'), contains('cu.'), equals('usb'),
                matches(RegExp(r'^COM\d+$'))));
      }
      final uno = Seftool.autodetectarPuerto();
      expect(uno, c.isEmpty ? isNull : equals(c.first));
    });
  });

  group('modo ensayo', () {
    test('no ejecuta nada y devuelve un aparato de mentira', () async {
      final s = Seftool(raiz: '/no/importa', puerto: '/dev/nada', ensayo: true);
      final lineas = await s.correr(['identify']).toList();
      expect(lineas.map((l) => l.texto).join('\n'), contains('[ensayo]'));

      final i = await s.identify();
      expect(i.modeloCorto, 'W580');
      expect(i.cid, '53');
    });
  });
  group('línea de órdenes', () {
    test('lleva -b 921600 justo después de -p', () async {
      final s = Seftool(raiz: '/no/importa', puerto: '/dev/x', ensayo: true);
      final l = (await s.correr(['read-gdfs']).toList()).first.texto;
      // Varias pruebas buscan «seftool -p»: el -b va DESPUÉS del puerto.
      expect(l, contains('seftool -p /dev/x -b 921600 -a read-gdfs'));
    });

    test('la velocidad se puede cambiar', () async {
      final s = Seftool(
          raiz: '/no/importa', puerto: 'usb', ensayo: true, baudios: 115200);
      final l = (await s.correr(['identify']).toList()).first.texto;
      expect(l, contains('-p usb -b 115200 -a identify'));
    });

    test('una orden sin puerto (convert) no lleva ni -p ni -b', () async {
      final s = Seftool(raiz: '/no/importa', puerto: '/dev/x', ensayo: true);
      final l = (await s.correr(['convert', 'raw2babe', 'x.bin', '0x44140000'],
              conPuerto: false)
          .toList())
          .first
          .texto;
      expect(l, isNot(contains(' -p ')));
      expect(l, isNot(contains(' -b ')));
    });
  });

  group('read-flash', () {
    test('ordenLeerFlash sin anycid: solo la acción', () {
      final o = Seftool.ordenLeerFlash(inicio: 0x44000000, tamano: 0x4000000);
      expect(o.accion,
          ['read-flash', 'start', '0x44000000', 'size', '0x4000000']);
      expect(o.extras, isEmpty);
    });

    test('con anycid: --anycid --cid N van en los extras (antes de -a)', () {
      final o = Seftool.ordenLeerFlash(
          inicio: 0x44000000, tamano: 0x4000000, anycid: true, cid: 52);
      expect(o.extras, ['--anycid', '--cid', '52']);
      expect(o.accion.first, 'read-flash');
    });

    test('anycid sin cid (o con cid 0): error, no una orden que seftool negaría',
        () {
      expect(
          () => Seftool.ordenLeerFlash(
              inicio: 0x44000000, tamano: 0x4000000, anycid: true),
          throwsArgumentError);
      expect(
          () => Seftool.ordenLeerFlash(
              inicio: 0x44000000, tamano: 0x4000000, anycid: true, cid: 0),
          throwsArgumentError);
    });

    test('leerFlash en ensayo: la orden entera, con --anycid --cid 52 antes de -a',
        () async {
      final s = Seftool(raiz: '/no/importa', puerto: 'usb', ensayo: true);
      final lineas = <String>[];
      await s.leerFlash(
          inicio: 0x44000000,
          tamano: 0x4000000,
          anycid: true,
          cid: 52,
          alVuelo: (l) => lineas.add(l.texto));
      expect(
          lineas.first,
          contains('-p usb -b 921600 --anycid --cid 52 -a read-flash '
              'start 0x44000000 size 0x4000000'));
    });
  });

  group('identidad del aparato (--imei)', () {
    const imei = '49015420323751';
    Seftool ensayo() => Seftool(raiz: '/no/importa', puerto: 'usb', ensayo: true);
    Future<String> orden(Seftool s, List<String> accion,
            {List<String> extras = const [], bool conPuerto = true}) async =>
        (await s.correr(accion, extras: extras, conPuerto: conPuerto).toList())
            .first
            .texto;

    test('sin imeiEsperado ninguna orden lleva --imei', () async {
      final s = ensayo();
      for (final a in [
        ['read-gdfs'],
        ['upload-anycid'],
        ['read-flash', 'start', '0x44000000', 'size', '0x4000000'],
      ]) {
        expect(await orden(s, a), isNot(contains('--imei')), reason: '$a');
      }
    });

    test('con imeiEsperado, --imei va ANTES de -a y después de los extras',
        () async {
      final s = ensayo()..imeiEsperado = imei;
      final l = await orden(
          s, ['read-flash', 'start', '0x44000000', 'size', '0x4000000'],
          extras: ['--anycid', '--cid', '52']);
      expect(
          l,
          contains('-p usb -b 921600 --anycid --cid 52 --imei $imei '
              '-a read-flash start 0x44000000 size 0x4000000'));
    });

    test('lo llevan las órdenes que escriben y las que leen', () async {
      final s = ensayo()..imeiEsperado = imei;
      for (final a in [
        ['read-gdfs'],
        ['write-gdfs', 'x.bin'],
        ['upload-anycid'],
        ['flash', 'main', 'x.bin'],
      ]) {
        expect(await orden(s, a), contains('--imei $imei -a ${a.first}'),
            reason: '$a');
      }
    });

    test('identify NO lo lleva: es quien descubre el IMEI', () async {
      final s = ensayo()..imeiEsperado = imei;
      final l = await orden(s, ['identify']);
      expect(l, isNot(contains('--imei')));
      expect(l, contains('-a identify'));
    });

    test('una orden sin puerto (convert) tampoco: no habla con ningún teléfono',
        () async {
      final s = ensayo()..imeiEsperado = imei;
      final l = await orden(s, ['convert', 'raw2babe', 'x.bin', '0x44140000'],
          conPuerto: false);
      expect(l, isNot(contains('--imei')));
    });

    test('un IMEI que seftool no aceptaría se rechaza AQUÍ, sin ejecutar nada',
        () async {
      for (final malo in ['', ' ', '4901542032375 1', '123456789012345678', 'a-b', '49015420323751;ls']) {
        final s = ensayo()..imeiEsperado = malo;
        await expectLater(
            s.correr(['read-gdfs']).toList(),
            throwsA(isA<SeftoolError>()
                .having((e) => e.motivo, 'motivo', contains('no es uno que seftool acepte'))),
            reason: 'IMEI «$malo»');
        // identify sigue pudiendo correr: es el que lo descubre.
        expect(await orden(s, ['identify']), contains('-a identify'));
      }
    });

    test('imeiValido: el mismo criterio que el parser de seftool', () {
      for (final bien in ['49015420323751', '490154203237518', 'W580S10000001', 'a_B_1']) {
        expect(Seftool.imeiValido(bien), isTrue, reason: bien);
      }
      for (final mal in ['', ' ', '1234567890123456', '12 34', 'ñ', '1.2', '-1']) {
        expect(Seftool.imeiValido(mal), isFalse, reason: '«$mal»');
      }
    });

    test('un IMEI en blanco («______________», un OTP vacío) no identifica a nadie',
        () {
      for (final blanco in ['_', '__', '______________']) {
        expect(Seftool.imeiValido(blanco), isFalse, reason: blanco);
      }
      // Con alguna cifra o letra, aunque tenga guiones bajos, sí.
      expect(Seftool.imeiValido('3551280269645_'), isTrue);
      expect(Seftool.imeiValido('_A'), isTrue);
    });
  });

  group('seftool se niega por el IMEI (proceso real de mentira)', () {
    late Directory raiz;
    setUp(() => raiz = Directory.systemTemp.createTempSync('senus-imei-neg-'));
    tearDown(() => raiz.deleteSync(recursive: true));

    /// Un `seftool` de mentira que imprime lo que se le diga y sale con `rc`.
    Seftool conSalida(String stdoutTxt, String stderrTxt, int rc) {
      final bin = File(p.join(raiz.path, 'build', 'seftool'))
        ..createSync(recursive: true)
        ..writeAsStringSync('#!/bin/sh\n'
            "printf '%s' '$stdoutTxt'\n"
            "printf '%s' '$stderrTxt' >&2\n"
            'exit $rc\n');
      Process.runSync('chmod', ['+x', bin.path]);
      return Seftool(raiz: raiz.path, puerto: '/dev/x', ensayo: false)
        ..imeiEsperado = '35000000000000';
    }

    const identidad = 'El aparato conectado dice IMEI «99999999999999» y se esperaba «35000000000000».';
    const rechazo = 'imei-check: REFUSED: no es el teléfono esperado; no se manda nada más.';

    test('con la línea imei-check como última: error con imeiRechazado', () async {
      final s = conSalida('', '$identidad\n$rechazo\n', 255);
      final e = await s.correrYJuntar(['read-gdfs']).then<Object>((_) => 'sin error',
          onError: (Object e) => e);
      expect(e, isA<SeftoolError>());
      e as SeftoolError;
      expect(e.imeiRechazado, isTrue);
      expect(e.motivo, mensajeOtroTelefono);
      expect(e.remedio, contains('99999999999999'));
      expect(e.remedio, contains('imei-check: REFUSED'));
      expect(e.salida, 255);
    });

    test('aunque seftool (uno anterior) añada DESPUÉS «Run executer first» y la '
        'lista de causas, el motivo real sigue siendo el IMEI', () async {
      final s = conSalida('[QHTRY] Run executer first\n',
          '$identidad\n$rechazo\nread-flash --anycid: el loader de setool2 no cargó. Causas probables:\n', 255);
      final e = await s.correrYJuntar(['read-flash']).then<Object>((_) => 'sin error',
          onError: (Object e) => e);
      e as SeftoolError;
      expect(e.imeiRechazado, isTrue);
      expect(e.motivo, mensajeOtroTelefono);
    });

    test('un fallo cualquiera de seftool NO se toma por una negativa del IMEI',
        () async {
      final s = conSalida('', 'algo se rompió\n', 255);
      final e = await s.correrYJuntar(['read-gdfs']).then<Object>((_) => 'sin error',
          onError: (Object e) => e);
      e as SeftoolError;
      expect(e.imeiRechazado, isFalse);
      expect(e.motivo, contains('código 255'));
      expect(e.remedio, 'algo se rompió');
    });

    test('rc 0: no hay error aunque la salida mencione el IMEI', () async {
      final s = conSalida('todo bien, imei-check: ok\n', '', 0);
      await s.correrYJuntar(['read-gdfs']);
    });
  });

  group('entorno del hijo', () {
    test('no arrastra las confirmaciones del humano (FORCE y BREAK_CONFIRM), '
        'en ninguna grafía', () {
      final e = Seftool.entornoDelHijo({
        'PATH': '/usr/bin',
        'SEFTOOL_SENEW_FORCE': '1',
        'seftool_senew_force': '1',
        'SEFTOOL_BREAK_CONFIRM': '1',
        'Seftool_Break_Confirm': '1',
      });
      expect(e.keys.map((k) => k.toUpperCase()),
          isNot(contains('SEFTOOL_SENEW_FORCE')));
      expect(e.keys.map((k) => k.toUpperCase()),
          isNot(contains('SEFTOOL_BREAK_CONFIRM')));
      expect(e.keys, ['PATH']);
    });

    test('la lista de confirmaciones es exactamente esas dos', () {
      expect(Seftool.confirmacionesDelHumano,
          unorderedEquals(['SEFTOOL_SENEW_FORCE', 'SEFTOOL_BREAK_CONFIRM']));
    });

    test('conserva todo lo demás (también otras SEFTOOL_*)', () {
      final e = Seftool.entornoDelHijo({
        'PATH': '/usr/bin',
        'HOME': '/home/x',
        'SEFTOOL_OTRA': '1',
        'SEFTOOL_SENEW_FORCE': '1',
        'SEFTOOL_BREAK_CONFIRM': '1',
      });
      expect(e['PATH'], '/usr/bin');
      expect(e['HOME'], '/home/x');
      expect(e['SEFTOOL_OTRA'], '1');
    });
  });

  group('lecturaNorPara: cómo se lee la NOR', () {
    LecturaNor via(String m, String cid, String color) =>
        lecturaNorPara(modelo: m, cid: cid, color: color).via;

    test('W580 RED 49/51/52 → por anycid', () {
      for (final c in ['49', '51', '52']) {
        expect(via('W580', c, 'RED'), LecturaNor.anycid, reason: 'CID $c');
      }
    });

    test('W580 RED 53 → no disponible, y el motivo dice FORCE y CID 53', () {
      final r = lecturaNorPara(modelo: 'W580', cid: '53', color: 'RED');
      expect(r.via, LecturaNor.noDisponible);
      expect(r.motivo, contains('CID 53'));
      expect(r.motivo, contains('SEFTOOL_SENEW_FORCE'));
    });

    test('W580 RED con un CID raro o ilegible → no disponible (no se adivina)',
        () {
      expect(via('W580', '50', 'RED'), LecturaNor.noDisponible);
      expect(via('W580', '', 'RED'), LecturaNor.noDisponible);
      expect(via('W580', 'abc', 'RED'), LecturaNor.noDisponible);
    });

    test('W580 BROWN → directa', () {
      expect(via('W580', '49', 'BROWN'), LecturaNor.directa);
    });

    test('W600/W810 RED CID 49+ → no disponible (exige --break-rsa o anycid)',
        () {
      for (final m in ['W600', 'W810']) {
        final r = lecturaNorPara(modelo: m, cid: '49', color: 'RED');
        expect(r.via, LecturaNor.noDisponible, reason: m);
        expect(r.motivo, contains('--break-rsa'));
      }
    });

    test('W600/W810 RED con un CID ilegible o que no es de los conocidos → '
        'no disponible (ilegible no es «bajo»)', () {
      for (final m in ['W600', 'W810']) {
        for (final c in ['', 'abc', '53', '99', '50']) {
          expect(via(m, c, 'RED'), LecturaNor.noDisponible,
              reason: '$m RED CID «$c»');
        }
      }
    });

    test('W600/W810 RED: la frontera es el CID 49 (48 todavía se lee directo)',
        () {
      for (final m in ['W600', 'W810']) {
        expect(via(m, '48', 'RED'), LecturaNor.directa, reason: m);
        expect(via(m, '49', 'RED'), LecturaNor.noDisponible, reason: m);
      }
    });

    test('W600/W810 BROWN o con CID bajo → directa', () {
      expect(via('W810', '49', 'BROWN'), LecturaNor.directa);
      expect(via('W600', '36', 'RED'), LecturaNor.directa);
    });

    test('un modelo que no es de los nuestros → directa, sin opinión', () {
      expect(via('DESCONOCIDO', '49', 'RED'), LecturaNor.directa);
    });
  });
}
