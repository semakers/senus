// Pruebas de la capa de instalación / restauración, SIN aparato y SIN abrir
// ningún puerto. La sustitución del executor.b se prueba contra el paquete
// anycid DE VERDAD del fork, si está; si no, contra uno armado aquí.

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:senus_app/datos/instalacion.dart';
import 'package:senus_app/datos/respaldo_rollback.dart';
import 'package:senus_app/datos/seftool.dart';
import 'package:senus_app/datos/telefono.dart';

RespaldoRollback _respaldo({
  required String modelo,
  required String cid,
  bool simulado = false,
  String? anycid,
  String carpeta = '/tmp/senus-respaldo-de-mentira',
}) =>
    RespaldoRollback(
      carpeta: carpeta,
      modelo: modelo,
      serie: '35697201234567',
      fecha: DateTime(2026, 10, 20),
      cid: cid,
      color: 'RED',
      firmwareOriginal: 'R8BE001',
      shaFlash: 'da39a3ee5e6b4b0d3255bfef95601890afd80709',
      bytesFlash: 0x04000000,
      simulado: simulado,
      paqueteAnycid: anycid,
    );

List<int> _zipDeMentira() {
  final a = Archive();
  final b = List<int>.filled(3692, 0xAA);
  a.addFile(ArchiveFile('tpa/preset/custom/executor.b', b.length, b));
  final xml = '<customize/>'.codeUnits;
  a.addFile(
      ArchiveFile('tpa/preset/custom/customize_upgrade.xml', xml.length, xml));
  final jar = List<int>.filled(1024, 0x50);
  a.addFile(ArchiveFile('tpa/preset/custom/executor.jar', jar.length, jar));
  return ZipEncoder().encode(a)!;
}

void main() {
  group('planificar: qué camino toca', () {
    test('W580 CID53 → anycid + payload', () {
      final plan = planificar(
          _respaldo(modelo: 'W580', cid: '53', anycid: 'R8BE001_X_GENERIC_LA'),
          rutaPayload: '/no/existe.b');
      expect(plan.camino, Camino.anycidPayload);
      expect(plan.bloqueado, isTrue); // falta el payload
      expect(plan.avisos.join(), contains('Juegos'));
      expect(plan.avisos.join(), contains('CRC-24'));
    });

    test('W580 forzando anycidReemplazoFrio: pide payload del main y pausa',
        () {
      final plan = planificar(
          _respaldo(modelo: 'W580', cid: '53', anycid: 'R8BE001_X_GENERIC_LA'),
          rutaSenew: '/no/existe-sistema.bin',
          forzarCamino: Camino.anycidReemplazoFrio);
      expect(plan.camino, Camino.anycidReemplazoFrio);
      expect(plan.direccion, 0x44140000);
      expect(plan.bloqueado, isTrue); // falta el binario
      expect(plan.avisos.join(), contains('EXPERIMENTAL'));
      expect(plan.avisos.join(), contains('PASO MANUAL'));
      expect(plan.avisos.join(), contains('executer'));
    });

    test('W810 forzando anycidReemplazoFrio: rechazado (solo DB2020)', () {
      final plan = planificar(_respaldo(modelo: 'W810', cid: '49'),
          rutaSenew: '/no/existe.bin',
          forzarCamino: Camino.anycidReemplazoFrio);
      expect(plan.bloqueado, isTrue);
      expect(plan.avisos.first, contains('sólo para W580'));
    });

    test('W580 CID52 por reemplazo frío plano: bloquea y manda a flash-anycid',
        () {
      final plan = planificar(_respaldo(modelo: 'W580', cid: '52'),
          rutaSenew: '/no/existe.bin');
      expect(plan.camino, Camino.reemplazoFrio);
      expect(plan.bloqueado, isTrue);
      expect(plan.avisos.first, contains('DB2020'));
      expect(plan.avisos.first, contains('flash-anycid'));
    });

    test('W810 CID49 → reemplazo frío a 0x44140000', () {
      final plan = planificar(_respaldo(modelo: 'W810', cid: '49'),
          rutaSenew: '/no/existe.bin');
      expect(plan.camino, Camino.reemplazoFrio);
      expect(plan.direccion, 0x44140000);
      expect(plan.avisos.any((a) => a.contains('DB2020')), isFalse);
    });

    test('W600 CID49 → el main va a 0x440A0000, no a 0x44140000', () {
      final plan = planificar(_respaldo(modelo: 'W600', cid: '49'),
          rutaSenew: '/no/existe.bin');
      expect(plan.direccion, 0x440A0000);
    });

    test('un respaldo SIMULADO bloquea la instalación', () {
      final plan = planificar(
          _respaldo(modelo: 'W810', cid: '49', simulado: true),
          rutaSenew: '/no/existe.bin');
      expect(plan.bloqueado, isTrue);
      expect(plan.avisos.join(), contains('SIMULADO'));
    });
  });

  group('DB2010 que necesitaría --break-rsa: SENUS no lo hace', () {
    File binarioDeMentira() {
      final tmp = Directory.systemTemp.createTempSync('senus-brk-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      return File(p.join(tmp.path, 'sistema.bin'))
        ..writeAsBytesSync(List<int>.filled(1024, 0x11));
    }

    test('necesitaBreakRsa: solo W600/W810 con CID ≤ 49', () {
      for (final m in ['W600', 'W810', 'w810']) {
        expect(necesitaBreakRsa(m, '49'), isTrue, reason: m);
        expect(necesitaBreakRsa(m, '36'), isTrue, reason: m);
        expect(necesitaBreakRsa(m, '50'), isFalse, reason: m);
        expect(necesitaBreakRsa(m, '53'), isFalse, reason: m);
        expect(necesitaBreakRsa(m, ''), isFalse, reason: '$m, CID ilegible');
      }
      expect(necesitaBreakRsa('W580', '49'), isFalse);
    });

    test('el plan de un W810/W600 CID 49 queda BLOQUEADO, aunque haya binario, '
        'y explica por qué', () {
      for (final m in ['W810', 'W600']) {
        final plan = planificar(_respaldo(modelo: m, cid: '49'),
            rutaSenew: binarioDeMentira().path);
        expect(plan.camino, Camino.reemplazoFrio, reason: m);
        expect(plan.bloqueado, isTrue, reason: m);
        final a = plan.avisos.first;
        expect(a, contains('--break-rsa'), reason: m);
        expect(a, contains('SEFTOOL_BREAK_CONFIRM'), reason: m);
        expect(a, contains('No se escribió nada'), reason: m);
      }
    });

    test('un W810 CID 51 no lo necesita: el plan no se bloquea por esto', () {
      final plan = planificar(_respaldo(modelo: 'W810', cid: '51'),
          rutaSenew: binarioDeMentira().path);
      expect(plan.bloqueado, isFalse);
    });

    test('correr() en un W810 CID 49: error, y NINGUNA orden sale', () async {
      final ejec = EjecutorInstalacion(
        respaldo: _respaldo(modelo: 'W810', cid: '49'),
        seftool: Seftool(raiz: '/no/importa', puerto: '/dev/x', ensayo: true),
        rutaSenew: binarioDeMentira().path,
      );
      final ordenes = <String>[];
      final errores = <String>[];
      await for (final ev in ejec.correr()) {
        if (ev.pausa != null) ev.pausa!.complete(true);
        final l = ev.logLinea ?? '';
        if (l.startsWith('> ')) ordenes.add(l);
        if (ev.error != null) errores.add(ev.error!);
      }
      expect(ordenes, isEmpty);
      expect(errores.single, contains('No se puede instalar'));
      expect(errores.single, contains('--break-rsa'));
    });

    test('ninguna orden de SENUS lleva --break-rsa (W810 CID 51, el camino sí corre)',
        () async {
      final ejec = EjecutorInstalacion(
        respaldo: _respaldo(modelo: 'W810', cid: '51'),
        seftool: Seftool(raiz: '/no/importa', puerto: '/dev/x', ensayo: true),
        rutaSenew: binarioDeMentira().path,
      );
      final ordenes = <String>[];
      await for (final ev in ejec.correr()) {
        if (ev.pausa != null) ev.pausa!.complete(true);
        final l = ev.logLinea ?? '';
        if (l.startsWith('> ') && l.contains(' -p ')) ordenes.add(l);
      }
      expect(ordenes.any((o) => o.contains('-a flash main')), isTrue,
          reason: 'el camino corrió: ${ordenes.join('\n')}');
      expect(ordenes.any((o) => o.contains('--break-rsa')), isFalse);
    });
  });

  group('armarZipAnycid', () {
    test('sustituye executor.b y deja el jar y el xml intactos', () {
      final original = _zipDeMentira();
      final payload = List<int>.filled(3692, 0x5E);
      final z = armarZipAnycid(original, payload);

      expect(z.rutaDentro, 'tpa/preset/custom/executor.b');
      expect(z.tamanoOriginalDelB, 3692);
      expect(z.tamanoNuevoDelB, 3692);

      final vuelta = ZipDecoder().decodeBytes(z.bytes);
      final b = vuelta.files.firstWhere((f) => f.name.endsWith('executor.b'));
      expect(b.content, equals(payload));

      // El jar NO se toca: es el que hace el salto de firma.
      final jarAntes = ZipDecoder()
          .decodeBytes(original)
          .files
          .firstWhere((f) => f.name.endsWith('.jar'));
      final jarDespues =
          vuelta.files.firstWhere((f) => f.name.endsWith('.jar'));
      expect(sha256.convert(jarDespues.content as List<int>).toString(),
          sha256.convert(jarAntes.content as List<int>).toString());
      expect(vuelta.files.where((f) => f.isFile).length, 3);
    });

    test('un zip sin executor.b da un error que lo dice', () {
      final a = Archive();
      a.addFile(ArchiveFile('tpa/otra/cosa.txt', 3, [1, 2, 3]));
      expect(() => armarZipAnycid(ZipEncoder().encode(a)!, [0]),
          throwsA(isA<SeftoolError>()));
    });

    test('contra el paquete anycid REAL del fork, si está', () {
      final zip = File(p.join(Seftool.raizPredeterminada, 'anycid',
          'R8BE001_CXC1123362_GENERIC_LA.zip'));
      if (!zip.existsSync()) {
        markTestSkipped('No está ${zip.path}');
        return;
      }
      final payload = List<int>.filled(3692, 0x5E);
      final z = armarZipAnycid(zip.readAsBytesSync(), payload);
      expect(z.rutaDentro, endsWith('executor.b'));
      expect(z.tamanoNuevoDelB, 3692);
      final vuelta = ZipDecoder().decodeBytes(z.bytes);
      expect(
          vuelta.files.firstWhere((f) => f.name.endsWith('executor.b')).content,
          equals(payload));
      // El zip original NO se ha tocado.
      expect(zip.lengthSync(), greaterThan(0));
    });
  });

  group('RespaldoRollback: shaGdfsA/B', () {
    test('round-trip JSON conserva shaGdfsA y shaGdfsB', () {
      final r = RespaldoRollback(
        carpeta: '/tmp/x',
        modelo: 'W580',
        serie: '35000000000000',
        fecha: DateTime.utc(2026, 10, 16),
        cid: '52',
        color: 'RED',
        firmwareOriginal: 'R8BE001',
        shaFlash: 'f' * 64,
        bytesFlash: 1,
        shaGdfsA: 'a' * 64,
        shaGdfsB: 'b' * 64,
      );
      final j2 = RespaldoRollback.deJson(r.aJson());
      expect(j2.shaGdfsA, 'a' * 64);
      expect(j2.shaGdfsB, 'b' * 64);
    });

    test('JSON antiguo (sin sha_gdfs_a) → shaGdfsA == null', () {
      final j2 = RespaldoRollback.deJson({
        'carpeta': '/tmp/x',
        'modelo': 'W580',
        'serie': '35000000000000',
        'fecha_utc': DateTime.utc(2026, 10, 16).toIso8601String(),
        'cid': '52',
        'color': 'RED',
        'firmware_original': 'R8BE001',
        'sha_flash': 'f' * 64,
        'bytes_flash': 1,
      });
      expect(j2.shaGdfsA, isNull);
      expect(j2.shaGdfsB, isNull);
    });

    test('shaGdfsAResuelto cae a gdfs_A.sha256 del disco si el modelo lo trae null',
        () async {
      final tmp = Directory.systemTemp.createTempSync('senus-sha-');
      await File(p.join(tmp.path, 'gdfs_A.sha256'))
          .writeAsString('${'a' * 64}  gdfs_A.bin\n');
      final r = RespaldoRollback(
        carpeta: tmp.path,
        modelo: 'W580',
        serie: '35000000000000',
        fecha: DateTime.now(),
        cid: '52',
        color: 'RED',
        firmwareOriginal: 'R8BE001',
        shaFlash: 'f' * 64,
        bytesFlash: 1,
        // shaGdfsA deliberadamente null → fallback
      );
      expect(await r.shaGdfsAResuelto(), 'a' * 64);
      expect(await r.shaGdfsBResuelto(), isNull); // no hay gdfs_B.sha256
    });

    test('AlmacenRespaldos.en guarda y recupera shaGdfsA/B por el índice',
        () async {
      final tmp = Directory.systemTemp.createTempSync('senus-almacen-');
      final almacen = AlmacenRespaldos.en(tmp.path);
      final r = RespaldoRollback(
        carpeta: tmp.path,
        modelo: 'W580',
        serie: '35000000000000',
        fecha: DateTime.now(),
        cid: '52',
        color: 'RED',
        firmwareOriginal: 'R8BE001',
        shaFlash: 'f' * 64,
        bytesFlash: 1,
        shaGdfsA: 'a' * 64,
        shaGdfsB: 'b' * 64,
      );
      await almacen.registrar(r);
      final lista = await almacen.listar();
      expect(lista, hasLength(1));
      expect(lista.first.shaGdfsA, 'a' * 64);
      expect(lista.first.shaGdfsB, 'b' * 64);
    });
  });

  group('restauración', () {
    test('se niega con un respaldo simulado', () async {
      final ev = await EjecutorRestauracion(
        respaldo: _respaldo(modelo: 'W580', cid: '53', simulado: true),
        seftool: Seftool(raiz: '/no/importa', puerto: '/dev/x', ensayo: true),
        almacen: AlmacenRespaldos.en(
            Directory.systemTemp.createTempSync('senus-rest-').path),
      ).correr().toList();
      expect(ev.any((e) => (e.error ?? '').contains('SIMULADO')), isTrue);
    });

    test('por omisión NO reescribe la zona del cargador', () {
      final r = EjecutorRestauracion(
        respaldo: _respaldo(modelo: 'W580', cid: '52'),
        seftool: Seftool(raiz: '/no/importa', puerto: '/dev/x', ensayo: true),
      );
      expect(r.direccion, 0x44140000);
      expect(r.direccion, isNot(0x44000000));
    });

    test('desdeElPrincipio sí arranca en 0x44000000', () {
      final r = EjecutorRestauracion(
        respaldo: _respaldo(modelo: 'W580', cid: '52'),
        seftool: Seftool(raiz: '/no/importa', puerto: '/dev/x', ensayo: true),
        desdeElPrincipio: true,
      );
      expect(r.direccion, 0x44000000);
    });

    test('identify que no cuadra → error antes de tocar nada', () async {
      // Ensayo devuelve W580i/CID 53/IMEI 000000000000000; nuestro respaldo
      // lleva un IMEI distinto. La restauración debe salir con error.
      final tmp = Directory.systemTemp.createTempSync('senus-identify-mal-');
      final ev = await EjecutorRestauracion(
        respaldo: _respaldo(
            modelo: 'W580', cid: '53', carpeta: tmp.path),
        seftool: Seftool(raiz: '/no/importa', puerto: '/dev/x', ensayo: true),
        almacen: AlmacenRespaldos.en(tmp.path),
      ).correr().toList();
      expect(
          ev.any((e) =>
              (e.error ?? '').contains('NO es el del respaldo')),
          isTrue);
    });

    test('identify que cuadra: sigue el flujo', () async {
      // Respaldo con el IMEI/modelo/cid que devuelve el ensayo (W580/53).
      final tmp = Directory.systemTemp.createTempSync('senus-identify-ok-');
      final r = RespaldoRollback(
        carpeta: tmp.path,
        modelo: 'W580',
        serie: '000000000000000',
        fecha: DateTime.now(),
        cid: '53',
        color: 'RED',
        firmwareOriginal: 'R8BE001',
        shaFlash: 'f' * 64,
        bytesFlash: 1,
        paqueteAnycid: 'R8BE001_CXC1123362_GENERIC_LA',
      );
      // Para que llegue hasta la pausa de reconexión creamos los ficheros.
      File(r.rutaFlash).writeAsBytesSync([0]);
      File(r.rutaGdfsA).writeAsBytesSync([0]);
      var vioError = false;
      var vioIdentifyOk = false;
      await for (final ev in EjecutorRestauracion(
        respaldo: r,
        seftool: Seftool(raiz: '/no/importa', puerto: '/dev/x', ensayo: true),
        almacen: AlmacenRespaldos.en(tmp.path),
      ).correr()) {
        if (ev.pausa != null) ev.pausa!.complete(false); // corta ahí
        if ((ev.logLinea ?? '').contains('identify OK')) vioIdentifyOk = true;
        if ((ev.error ?? '').contains('NO es el del respaldo')) vioError = true;
      }
      expect(vioError, isFalse);
      expect(vioIdentifyOk, isTrue);
    });

    test('pausa entre flash main y write-gdfs: aceptar → sale write-gdfs',
        () async {
      final tmp = Directory.systemTemp.createTempSync('senus-pausa-rest-');
      // Respaldo con el aparato ficticio del ensayo y los dos ficheros
      // mínimos: así el flujo llega hasta la pausa.
      final r = RespaldoRollback(
        carpeta: tmp.path,
        modelo: 'W580',
        serie: '000000000000000',
        fecha: DateTime.now(),
        cid: '53',
        color: 'RED',
        firmwareOriginal: 'R8BE001',
        shaFlash: 'f' * 64,
        bytesFlash: 1,
        paqueteAnycid: 'R8BE001_CXC1123362_GENERIC_LA',
      );
      File(r.rutaFlash).writeAsBytesSync(List<int>.filled(1, 0));
      File(r.rutaGdfsA).writeAsBytesSync(List<int>.filled(1, 0));
      final ejec = EjecutorRestauracion(
        respaldo: r,
        seftool: Seftool(raiz: '/no/importa', puerto: '/dev/x', ensayo: true),
        almacen: AlmacenRespaldos.en(tmp.path),
      );
      var vioPausa = false;
      var vioWriteGdfs = false;
      await for (final ev in ejec.correr()) {
        if (ev.pausa != null) {
          vioPausa = true;
          expect(ev.pausaTitulo, contains('modo C'));
          ev.pausa!.complete(true);
        }
        final t = ev.logLinea ?? '';
        if (t.contains('seftool -p') && t.contains('write-gdfs')) {
          vioWriteGdfs = true;
        }
      }
      expect(vioPausa, isTrue, reason: 'la pausa tiene que llegar');
      expect(vioWriteGdfs, isTrue,
          reason: 'tras Continuar, el write-gdfs tiene que arrancar');
    });

    test('pausa cancelada: write-gdfs NO corre y no hay error', () async {
      final tmp = Directory.systemTemp.createTempSync('senus-pausa-cancel-');
      final r = RespaldoRollback(
        carpeta: tmp.path,
        modelo: 'W580',
        serie: '000000000000000',
        fecha: DateTime.now(),
        cid: '53',
        color: 'RED',
        firmwareOriginal: 'R8BE001',
        shaFlash: 'f' * 64,
        bytesFlash: 1,
        paqueteAnycid: 'R8BE001_CXC1123362_GENERIC_LA',
      );
      File(r.rutaFlash).writeAsBytesSync(List<int>.filled(1, 0));
      File(r.rutaGdfsA).writeAsBytesSync(List<int>.filled(1, 0));
      final ejec = EjecutorRestauracion(
        respaldo: r,
        seftool: Seftool(raiz: '/no/importa', puerto: '/dev/x', ensayo: true),
        almacen: AlmacenRespaldos.en(tmp.path),
      );
      var vioWriteGdfs = false;
      var vioError = false;
      await for (final ev in ejec.correr()) {
        if (ev.pausa != null) ev.pausa!.complete(false);
        final t = ev.logLinea ?? '';
        if (t.contains('seftool -p') && t.contains('write-gdfs')) {
          vioWriteGdfs = true;
        }
        if (ev.error != null) vioError = true;
      }
      expect(vioWriteGdfs, isFalse,
          reason: 'si se cancela, write-gdfs NO corre');
      expect(vioError, isFalse, reason: 'cancelar no es un error');
    });

    // Stub de identify que simula un W580 RED CID 52 con el mismo IMEI que
    // el respaldo de este bloque de tests.
    const identifyCid52 = 'Phone Info (from GDFS):\n'
        'Model: W580i\n'
        'OTP: LOCKED:0 CID:52 PAF:0 IMEI:35000000000000\n'
        'ACTIVE CID:52 COLOR:RED\n'
        'MAPP CXC article: CXC1123362\n'
        'MAPP CXC version: R8BE001\n'
        'SIMLOCKS NOT DETECTED\n'
        'Anycid package: ./anycid/R8BE001_CXC1123362_GENERIC_LA.zip\n';

    RespaldoRollback respaldoCid52(String carpeta, {String? shaGdfsA}) =>
        RespaldoRollback(
          carpeta: carpeta,
          modelo: 'W580',
          serie: '35000000000000',
          fecha: DateTime.now(),
          cid: '52',
          color: 'RED',
          firmwareOriginal: 'R8BE001',
          shaFlash: 'f' * 64,
          bytesFlash: 1,
          paqueteAnycid: 'R8BE001_CXC1123362_GENERIC_LA',
          shaGdfsA: shaGdfsA,
        );

    test('W580 CID53 sin flash_full.bin → error (no activa la red parcial)',
        () async {
      // El camino parcial es SOLO para CID 52 RED; para otros, falta de
      // flash_full.bin sigue siendo error duro.
      final tmp = Directory.systemTemp.createTempSync('senus-cid53-sin-flash-');
      final r = RespaldoRollback(
        carpeta: tmp.path,
        modelo: 'W580',
        serie: '000000000000000',
        fecha: DateTime.now(),
        cid: '53',
        color: 'RED',
        firmwareOriginal: 'R8BE001',
        shaFlash: 'f' * 64,
        bytesFlash: 1,
      );
      File(r.rutaGdfsA).writeAsBytesSync(List<int>.filled(16, 0));
      final ev = await EjecutorRestauracion(
        respaldo: r,
        seftool: Seftool(raiz: '/no/importa', puerto: '/dev/x', ensayo: true),
        almacen: AlmacenRespaldos.en(tmp.path),
        permitirSoloGdfs: true,
      ).correr().toList();
      expect(
          ev.any((e) => (e.error ?? '').contains('Falta un fichero')),
          isTrue);
    });

    test('W580 CID52 RED sin flash + permitirSoloGdfs: solo write-gdfs',
        () async {
      final tmp = Directory.systemTemp.createTempSync('senus-solo-gdfs-ok-');
      final r = respaldoCid52(tmp.path);
      File(r.rutaGdfsA).writeAsBytesSync(List<int>.filled(16, 0x11));
      // No creamos flash_full.bin.
      var vioFlashMain = false;
      var vioWriteGdfs = false;
      var vioError = false;
      var vioAvisoParcial = false;
      await for (final ev in EjecutorRestauracion(
        respaldo: r,
        seftool: Seftool(
            raiz: '/no/importa',
            puerto: '/dev/x',
            ensayo: true,
            identifyEnsayoStdout: identifyCid52),
        almacen: AlmacenRespaldos.en(tmp.path),
        permitirSoloGdfs: true,
      ).correr()) {
        final t = ev.logLinea ?? '';
        if (t.contains('seftool -p') && t.contains('flash main')) {
          vioFlashMain = true;
        }
        if (t.contains('seftool -p') && t.contains('write-gdfs')) {
          vioWriteGdfs = true;
        }
        if (t.contains('Camino parcial')) vioAvisoParcial = true;
        if (ev.error != null) vioError = true;
      }
      expect(vioFlashMain, isFalse, reason: 'no se escribe el main');
      expect(vioWriteGdfs, isTrue, reason: 'sí se escribe el GDFS');
      expect(vioAvisoParcial, isTrue, reason: 'avisa que es parcial');
      expect(vioError, isFalse);
    });

    test('W580 CID52 RED sin flash + pausa cancelada: nada se escribe',
        () async {
      final tmp = Directory.systemTemp.createTempSync('senus-solo-gdfs-cancel-');
      final r = respaldoCid52(tmp.path);
      File(r.rutaGdfsA).writeAsBytesSync(List<int>.filled(16, 0x22));
      var vioWriteGdfs = false;
      await for (final ev in EjecutorRestauracion(
        respaldo: r,
        seftool: Seftool(
            raiz: '/no/importa',
            puerto: '/dev/x',
            ensayo: true,
            identifyEnsayoStdout: identifyCid52),
        almacen: AlmacenRespaldos.en(tmp.path),
      ).correr()) {
        if (ev.pausa != null) ev.pausa!.complete(false);
        final t = ev.logLinea ?? '';
        if (t.contains('seftool -p') && t.contains('write-gdfs')) {
          vioWriteGdfs = true;
        }
      }
      expect(vioWriteGdfs, isFalse);
    });

    test('gdfs_A con sha256 que no cuadra → error antes de write-gdfs',
        () async {
      final tmp = Directory.systemTemp.createTempSync('senus-gdfs-sha-mal-');
      // Datos del fichero: su sha256 real ≠ 'a'*64.
      await File(p.join(tmp.path, 'gdfs_A.bin'))
          .writeAsBytes(List<int>.filled(16, 0x33));
      // Flash entero para que no se dispare el camino parcial.
      await File(p.join(tmp.path, 'flash_full.bin'))
          .writeAsBytes(List<int>.filled(16, 0x44));
      final r = respaldoCid52(tmp.path, shaGdfsA: 'a' * 64);
      // Como ensayo:true salta la verificación del flash_full (ensayo salta
      // SHA del flash), pero NO la del gdfs (se verifica siempre que el
      // modelo traiga el sha esperado o esté en disco).
      // Para que el flujo pase la comprobación del flash_full, cambiamos a
      // ensayo:true (sin SHA check del flash) y hacemos que la del gdfs
      // falle.
      final ev = await EjecutorRestauracion(
        respaldo: r,
        seftool: Seftool(
            raiz: '/no/importa',
            puerto: '/dev/x',
            ensayo: true,
            identifyEnsayoStdout: identifyCid52),
        almacen: AlmacenRespaldos.en(tmp.path),
      ).correr().toList();
      expect(
          ev.any((e) => (e.error ?? '').contains('gdfs_A.bin NO cuadra')),
          isTrue);
    });

    test('falta un fichero del respaldo → error, no excepción', () async {
      final ev = await EjecutorRestauracion(
        respaldo: _respaldo(
            modelo: 'W810', cid: '49', carpeta: '/tmp/no-existe-esta-carpeta'),
        seftool: Seftool(
            raiz: '/ruta/que/no/existe', puerto: '/dev/x', ensayo: false),
        almacen: AlmacenRespaldos.en(
            Directory.systemTemp.createTempSync('senus-rest2-').path),
      ).correr().toList();
      expect(ev.any((e) => e.error != null), isTrue);
    }, timeout: const Timeout(Duration(seconds: 10)));
  });

  group('aparato de fábrica', () {
    test('Telefono.esDeFabrica sale de deFabrica, y por omisión es false', () {
      const normal = Telefono(
        modelo: Modelo.w580,
        nombreAmigo: 'W580 sistema propio',
        serie: 'W580S10000001',
        versionSenew: '0.19',
        almacenes: [],
      );
      expect(normal.esDeFabrica, isFalse);

      const fabrica = Telefono(
        modelo: Modelo.w580,
        nombreAmigo: 'W580 de fábrica',
        serie: '35697201234567',
        versionSenew: '—',
        almacenes: [],
        deFabrica: true,
        cid: '53',
        color: 'RED',
        firmwareOriginal: 'R8BE001',
        puertoSerie: '/dev/ttyUSB0',
      );
      expect(fabrica.esDeFabrica, isTrue);
      expect(fabrica.puertoSerie, '/dev/ttyUSB0');
      expect(fabrica.cid, '53');
    });
  });

  group('pausa cooperativa (cerrojo físico)', () {
    test('anycidReemplazoFrio emite una pausa y espera true para seguir',
        () async {
      final tmp = Directory.systemTemp.createTempSync('senus-pausa-');
      final binSenew = File(p.join(tmp.path, 'sistema.bin'))
        ..writeAsBytesSync(List<int>.filled(1024, 0x11));
      final almacen = AlmacenRespaldos.en(tmp.path);
      final r = await almacen.registrar(RespaldoRollback(
        carpeta: tmp.path,
        modelo: 'W580',
        serie: '35697201234567',
        fecha: DateTime.now(),
        cid: '53',
        color: 'RED',
        firmwareOriginal: 'R8BE001',
        shaFlash: 'x',
        bytesFlash: 1,
        paqueteAnycid: 'R8BE001_X_GENERIC_LA',
      ));

      final ejec = EjecutorInstalacion(
        respaldo: r,
        seftool: Seftool(raiz: '/no/importa', puerto: '/dev/x', ensayo: true),
        rutaSenew: binSenew.path,
        forzarCamino: Camino.anycidReemplazoFrio,
      );
      expect(ejec.plan.camino, Camino.anycidReemplazoFrio);
      expect(ejec.plan.bloqueado, isFalse);

      var vioPausa = false;
      var vioFlashAnycid = false;
      await for (final ev in ejec.correr()) {
        if (ev.pausa != null) {
          vioPausa = true;
          expect(ev.pausaTitulo, isNotNull);
          expect(ev.pausaDetalle, contains('executer'));
          ev.pausa!.complete(true);  // simula al usuario pulsando Continuar
        }
        if ((ev.logLinea ?? '').contains('seftool -p') && (ev.logLinea ?? '').contains('flash-anycid main')) {
          vioFlashAnycid = true;
        }
      }
      expect(vioPausa, isTrue, reason: 'tiene que llegar la pausa');
      expect(vioFlashAnycid, isTrue,
          reason: 'después de Continuar tiene que correr flash-anycid');
    });

    test('cancelar la pausa detiene el flujo sin correr flash-anycid',
        () async {
      final tmp = Directory.systemTemp.createTempSync('senus-pausa2-');
      final binSenew = File(p.join(tmp.path, 'sistema.bin'))
        ..writeAsBytesSync(List<int>.filled(1024, 0x22));
      final almacen = AlmacenRespaldos.en(tmp.path);
      final r = await almacen.registrar(RespaldoRollback(
        carpeta: tmp.path,
        modelo: 'W580',
        serie: '35697201234567',
        fecha: DateTime.now(),
        cid: '53',
        color: 'RED',
        firmwareOriginal: 'R8BE001',
        shaFlash: 'x',
        bytesFlash: 1,
        paqueteAnycid: 'R8BE001_X_GENERIC_LA',
      ));

      final ejec = EjecutorInstalacion(
        respaldo: r,
        seftool: Seftool(raiz: '/no/importa', puerto: '/dev/x', ensayo: true),
        rutaSenew: binSenew.path,
        forzarCamino: Camino.anycidReemplazoFrio,
      );
      var vioFlashAnycid = false;
      await for (final ev in ejec.correr()) {
        if (ev.pausa != null) ev.pausa!.complete(false);
        if ((ev.logLinea ?? '').contains('seftool -p') && (ev.logLinea ?? '').contains('flash-anycid main')) {
          vioFlashAnycid = true;
        }
      }
      expect(vioFlashAnycid, isFalse,
          reason: 'si el usuario cancela, flash-anycid NO corre');
    });
  });

  group('identidad (--imei) en la instalación', () {
    Future<EjecutorInstalacion> ejecutor(String serie) async {
      final tmp = Directory.systemTemp.createTempSync('senus-imei-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final binSenew = File(p.join(tmp.path, 'sistema.bin'))
        ..writeAsBytesSync(List<int>.filled(1024, 0x11));
      final almacen = AlmacenRespaldos.en(tmp.path);
      final r = await almacen.registrar(RespaldoRollback(
        carpeta: tmp.path,
        modelo: 'W580',
        serie: serie,
        fecha: DateTime.now(),
        cid: '53',
        color: 'RED',
        firmwareOriginal: 'R8BE001',
        shaFlash: 'x',
        bytesFlash: 1,
        paqueteAnycid: 'R8BE001_X_GENERIC_LA',
      ));
      return EjecutorInstalacion(
        respaldo: r,
        seftool: Seftool(raiz: '/no/importa', puerto: '/dev/x', ensayo: true),
        rutaSenew: binSenew.path,
        forzarCamino: Camino.anycidReemplazoFrio,
      );
    }

    test('cada orden que habla con el teléfono lleva --imei del respaldo',
        () async {
      final ejec = await ejecutor('35697201234567');
      final ordenes = <String>[];
      final errores = <String>[];
      await for (final ev in ejec.correr()) {
        if (ev.pausa != null) ev.pausa!.complete(true);
        final l = ev.logLinea ?? '';
        if (l.startsWith('> ') && l.contains(' -p ')) ordenes.add(l);
        if (ev.error != null) errores.add(ev.error!);
      }
      expect(errores, isEmpty, reason: errores.join('\n'));
      expect(ordenes, isNotEmpty);
      for (final o in ordenes) {
        expect(o, contains('--imei 35697201234567 -a '), reason: o);
      }
      expect(ordenes.any((o) => o.contains('flash-anycid main')), isTrue);
    });

    test('un respaldo con un IMEI que seftool no aceptaría no escribe NADA',
        () async {
      final ejec = await ejecutor('ñandú 12');
      final ordenes = <String>[];
      final errores = <String>[];
      await for (final ev in ejec.correr()) {
        if (ev.pausa != null) ev.pausa!.complete(true);
        final l = ev.logLinea ?? '';
        if (l.startsWith('> ') && l.contains(' -p ')) ordenes.add(l);
        if (ev.error != null) errores.add(ev.error!);
      }
      expect(ordenes, isEmpty, reason: 'ninguna orden llegó a salir');
      expect(errores.join('\n'), contains('no es uno que seftool acepte'));
    });
  });

  group('errores del CS loader en la instalación', () {
    test('«error:29» del CS loader llega como el aviso CSLOADER29:, no como excepción',
        () async {
      // Un error que lanza un sub-generador y se reenvía con `yield*` no lo
      // atrapan los catch de quien lo llama: se iba directo al flujo de
      // salida y la pantalla nunca llegaba a enseñar su diálogo del error 29.
      final tmp = Directory.systemTemp.createTempSync('senus-err29-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final binSenew = File(p.join(tmp.path, 'sistema.bin'))
        ..writeAsBytesSync(List<int>.filled(1024, 0x11));
      final almacen = AlmacenRespaldos.en(tmp.path);
      final r = await almacen.registrar(RespaldoRollback(
        carpeta: tmp.path,
        modelo: 'W580',
        serie: '35697201234567',
        fecha: DateTime.now(),
        cid: '52',
        color: 'RED',
        firmwareOriginal: 'R8BE001',
        shaFlash: 'x',
        bytesFlash: 1,
        paqueteAnycid: 'R8BE001_X_GENERIC_LA',
      ));
      final ejec = EjecutorInstalacion(
        respaldo: r,
        seftool: _SeftoolConError29(),
        rutaSenew: binSenew.path,
        forzarCamino: Camino.anycidReemplazoFrio,
      );
      final errores = <String>[];
      Object? excepcion;
      try {
        await for (final ev in ejec.correr()) {
          if (ev.pausa != null) ev.pausa!.complete(true);
          if (ev.error != null) errores.add(ev.error!);
        }
      } catch (e) {
        excepcion = e;
      }
      expect(excepcion, isNull, reason: 'no puede escaparse como excepción');
      expect(errores.single, startsWith('CSLOADER29:'));
    });
  });
}

/// seftool en ensayo cuyo `upload-anycid` contesta como el CS loader de un
/// CID 53 que se niega a arrancar sus servicios. Solo emite una línea.
class _SeftoolConError29 extends Seftool {
  _SeftoolConError29()
      : super(raiz: '/no/importa', puerto: '/dev/x', ensayo: true);

  @override
  Stream<LineaSeftool> subirAnycid() async* {
    yield const LineaSeftool(
        'CSloader refused to start GDFS services, error:29');
  }
}
