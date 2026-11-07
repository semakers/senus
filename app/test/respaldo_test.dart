// El respaldo REAL de rollback (EjecutorRespaldo en modo real), SIN aparato y
// SIN abrir ningún puerto.
//
//  - En ensayo (SENUS_SEFTOOL_ENSAYO=1) seftool no se ejecuta: se comprueba el
//    orden de las órdenes y de las pausas con `identifyEnsayoStdout`.
//  - Para lo que depende de lo que contesta seftool (reintentos, «Run executer
//    first», negativas de la compuerta, un volcado que no sirve) se usa un
//    `Seftool` hijo que EMITE LÍNEAS de seftool. No simula ningún loader ni
//    ningún teléfono: prueba la lógica de SENUS frente a esas líneas.

@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:senus_app/datos/instalacion.dart';
import 'package:senus_app/datos/respaldo_rollback.dart';
import 'package:senus_app/datos/seftool.dart';
import 'package:senus_app/datos/telefono.dart';

const _tel = Telefono(
  modelo: Modelo.w580,
  nombreAmigo: 'W580 de fábrica',
  serie: '35000000000000',
  versionSenew: '—',
  almacenes: [],
);

String _identify(String cid, String color, {String modelo = 'W580i'}) =>
    'Phone Info (from GDFS):\n'
    'Model: $modelo\n'
    'OTP: LOCKED:0 CID:$cid PAF:0 IMEI:35000000000000\n'
    'ACTIVE CID:$cid COLOR:$color\n'
    'MAPP CXC article: CXC1123362\n'
    'MAPP CXC version: R8BE001\n'
    'SIMLOCKS NOT DETECTED\n'
    'Anycid package: ./anycid/R8BE001_CXC1123362_GENERIC_LA.zip\n';

/// Lo que dejó una pasada del ejecutor.
class _Pasada {
  final pausas = <({String titulo, String detalle})>[];
  final logs = <String>[];
  final errores = <String>[];
  final eventos = <EventoRespaldo>[];
  String get todoElLog => logs.join('\n');
}

/// Corre el ejecutor contestando cada pausa con `responde(índice, título)`.
Future<_Pasada> _correr(EjecutorRespaldo e,
    {bool Function(int i, String titulo)? responde}) async {
  final r = _Pasada();
  await for (final ev in e.correr()) {
    r.eventos.add(ev);
    if (ev.logLinea != null) r.logs.add(ev.logLinea!);
    if (ev.error != null) r.errores.add(ev.error!);
    if (ev.pausa != null) {
      final i = r.pausas.length;
      r.pausas.add((titulo: ev.pausaTitulo ?? '', detalle: ev.pausaDetalle ?? ''));
      ev.pausa!.complete(responde == null ? true : responde(i, ev.pausaTitulo ?? ''));
    }
  }
  return r;
}

EjecutorRespaldo _ejecutor(Seftool sef, AlmacenRespaldos alm) =>
    EjecutorRespaldo(
        telefono: _tel,
        almacen: alm,
        simulado: false,
        puerto: '/dev/x',
        seftool: sef);

/// seftool que solo EMITE LÍNEAS (ver la cabecera). `intentosReadFlash` dice,
/// para cada `read-flash`, qué escribe en stdout y si termina con error o no.
class _SeftoolGuionado extends Seftool {
  final List<_RespuestaReadFlash> intentosReadFlash;
  final String imeiGdfs;

  /// Lo que dice `identify` (por omisión, un W580 CID 52 RED con IMEI).
  final String salidaIdentify;

  /// Líneas que emite `upload-anycid`.
  final List<String> subirAnycidLineas;

  /// `read-gdfs` deja un fichero de 0 B.
  final bool gdfsVacio;

  /// La 2.ª lectura del GDFS difiere de la 1.ª.
  final bool gdfsDistinto;
  final comandos = <String>[];

  /// El `imeiEsperado` que tenía el seftool en cada orden que habla con el
  /// teléfono (menos identify): el ejecutor tiene que fijarlo ANTES.
  final imeisVistos = <String?>[];
  var _n = 0;
  var _g = 0;

  _SeftoolGuionado(String raiz, this.intentosReadFlash,
      {this.imeiGdfs = '35000000000000',
      String? salidaIdentify,
      this.subirAnycidLineas = const ['Starting FSX server... started'],
      this.gdfsVacio = false,
      this.gdfsDistinto = false})
      : salidaIdentify = salidaIdentify ?? _identify('52', 'RED'),
        super(raiz: raiz, puerto: '/dev/x', ensayo: false);

  @override
  void exigirBinario() {}

  @override
  Future<InfoAparato> identify({void Function(LineaSeftool)? alVuelo}) async =>
      Seftool.leerIdentify(salidaIdentify);

  @override
  Future<File> leerGdfs({void Function(LineaSeftool)? alVuelo}) async {
    comandos.add('read-gdfs');
    imeisVistos.add(imeiEsperado);
    dirBackup.createSync(recursive: true);
    final f = File(p.join(dirBackup.path, 'GDFS_W580i_$imeiGdfs.bin'));
    final k = _g++;
    f.writeAsBytesSync(gdfsVacio
        ? <int>[]
        : List<int>.generate(4096, (i) => (i * 7 + (gdfsDistinto ? k : 0)) & 0xFF));
    return f;
  }

  @override
  Stream<LineaSeftool> subirAnycid() async* {
    comandos.add('upload-anycid');
    imeisVistos.add(imeiEsperado);
    for (final l in subirAnycidLineas) {
      yield LineaSeftool(l);
    }
  }

  @override
  Stream<LineaSeftool> correr(List<String> accion,
      {bool escribe = false,
      bool conPuerto = true,
      List<String> extras = const []}) async* {
    comandos.add([...extras, ...accion].join(' '));
    imeisVistos.add(imeiEsperado);
    if (accion.first != 'read-flash') return;
    final r = intentosReadFlash[_n < intentosReadFlash.length ? _n : intentosReadFlash.length - 1];
    _n++;
    // El volcado se deja ANTES de emitir las líneas: así «Flash dump saved»
    // puede llevar el SHA-1 de verdad, como el de seftool.
    r.alTerminar?.call(dirBackup);
    for (final l in r.salida) {
      yield LineaSeftool(l);
    }
    if (r.marcador != null) {
      final f = File(p.join(dirBackup.path, r.marcador!));
      if (f.existsSync()) {
        final sha = r.sha1Mentira
            ? 'f' * 40
            : sha1.convert(f.readAsBytesSync()).toString();
        yield LineaSeftool('Flash dump saved ./backup/${r.marcador} '
            '(${f.lengthSync()} bytes, SHA-1 $sha)');
      }
    }
    if (r.falla) {
      throw SeftoolError('seftool terminó con error (código 255).',
          remedio: r.salida.isEmpty ? null : r.salida.last, salida: 255);
    }
  }
}

class _RespuestaReadFlash {
  final List<String> salida;
  final bool falla;
  final void Function(Directory backup)? alTerminar;

  /// Nombre del volcado que seftool «confirma» con su línea `Flash dump saved
  /// … SHA-1 …` (calculada sobre el fichero que dejó `alTerminar`); null = no
  /// imprime la confirmación.
  final String? marcador;

  /// La línea de confirmación lleva un SHA-1 que no es el del fichero.
  final bool sha1Mentira;
  const _RespuestaReadFlash(this.salida,
      {this.falla = false,
      this.alTerminar,
      this.marcador,
      this.sha1Mentira = false});
}

const _nombreVolcado = 'flashdump_35000000000000_44000000_04000000.bin';

/// Los 64 MiB de una NOR creíble: no uniforme en el arranque ni en el inicio
/// del main, distinta de un MiB a otro y, si `conId`, con el ID del firmware.
Uint8List _bytesVolcado(
    {int? relleno, bool conId = true, int? espejoEnMib, int? tam}) {
  final b = Uint8List(tam ?? EjecutorRespaldo.tamanoFlash);
  if (relleno != null) {
    b.fillRange(0, b.length, relleno);
    return b;
  }
  for (var i = 0; i < b.length; i += 97) {
    b[i] = (i ~/ 97) & 0xFF;
  }
  b[0] = 0xEA; // que el arranque no sea uniforme
  b[0x140000] = 0xEA; // ni el inicio del main
  b[0x140001] = 0x12;
  if (conId) {
    // El main de fábrica lleva el ID de su firmware tal cual.
    b.setRange(0x1A2B3C, 0x1A2B3C + _idFirmware.length, _idFirmware);
  }
  if (espejoEnMib != null) {
    // Un loader que ignora la dirección: el primer MiB se repite ahí.
    const mib = 0x100000;
    b.setRange(espejoEnMib * mib, (espejoEnMib + 1) * mib, b.sublist(0, mib));
  }
  return b;
}

/// Deja en `backup/` un volcado de 64 MiB: con datos creíbles (`relleno` null)
/// o de un solo byte repetido.
void Function(Directory) _dejaVolcado(
        {int? relleno,
        String nombre = _nombreVolcado,
        bool conId = true,
        int? espejoEnMib}) =>
    (Directory backup) {
      backup.createSync(recursive: true);
      File(p.join(backup.path, nombre)).writeAsBytesSync(_bytesVolcado(
          relleno: relleno, conId: conId, espejoEnMib: espejoEnMib));
    };

/// Lo que el main de un W580 de fábrica lleva dentro (`R8BE001     prgCXC1123362_GENERIC_LA`).
final _idFirmware = 'R8BE001     prgCXC1123362_GENERIC_LA'.codeUnits;

void main() {
  late Directory tmp;
  late AlmacenRespaldos almacen;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('senus-respaldo-');
    almacen = AlmacenRespaldos.en(p.join(tmp.path, 'respaldos'));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  group('lo que decide el CID (ensayo, sin ejecutar nada)', () {
    Seftool ensayo(String cid, String color, {String modelo = 'W580i'}) =>
        Seftool(
            raiz: '/no/importa',
            puerto: '/dev/x',
            ensayo: true,
            identifyEnsayoStdout: _identify(cid, color, modelo: modelo));

    test('W580 RED CID52: 4 pausas, GDFS×2 ANTES del exploit, read-flash --anycid --cid 52',
        () async {
      final r = await _correr(_ejecutor(ensayo('52', 'RED'), almacen));

      expect(r.errores, isEmpty);
      expect(r.pausas.length, 4);
      for (final pa in r.pausas.take(2)) {
        expect(pa.titulo, tituloReconectar);
      }
      expect(r.pausas[2].titulo, contains('modo C'));
      expect(r.pausas[2].titulo, contains('exploit'));
      expect(r.pausas[2].detalle, contains('DESDE AQUÍ YA NO ES SOLO LECTURA'));
      expect(r.pausas[3].titulo, contains('executer'));
      expect(r.pausas[3].titulo, contains('intento 1/3'));
      expect(r.pausas[3].detalle, contains('Juegos'));
      expect(r.pausas[3].detalle, contains('tecla C'));

      final cmd = r.logs.where((l) => l.startsWith('> ')).toList();
      int pos(String s) => cmd.indexWhere((l) => l.contains(s));
      expect(pos('read-gdfs'), greaterThanOrEqualTo(0));
      expect(pos('upload-anycid'), greaterThan(pos('read-gdfs')),
          reason: 'lo irrepetible (GDFS) va antes de tocar nada del exploit');
      final rf = cmd.firstWhere((l) => l.contains('read-flash'));
      expect(rf, contains('-p /dev/x -b 921600 --anycid --cid 52 '
          '--imei 35000000000000 -a read-flash start 0x44000000 size 0x4000000'));
      expect(cmd.indexOf(rf), greaterThan(pos('upload-anycid')));
      expect(cmd.where((l) => l.contains('-a read-gdfs')).length, 2);
    });

    test('--imei: identify no lo lleva; TODAS las órdenes que siguen, sí',
        () async {
      final r = await _correr(_ejecutor(ensayo('52', 'RED'), almacen));
      final cmd = r.logs.where((l) => l.startsWith('> ') && l.contains(' -p ')).toList();
      // gdfs×2, upload-anycid, read-flash. (En ensayo identify no escribe
      // ninguna línea de orden; que identify no lleva --imei está en
      // seftool_test.)
      expect(cmd.length, greaterThanOrEqualTo(4));
      for (final l in cmd) {
        expect(l, contains('--imei 35000000000000 -a '), reason: l);
      }
    });

    test('identify sin un IMEI utilizable: aborta antes de leer nada ni registrar',
        () async {
      final sin = Seftool(
          raiz: '/no/importa',
          puerto: '/dev/x',
          ensayo: true,
          identifyEnsayoStdout:
              _identify('52', 'RED').replaceAll('IMEI:35000000000000', 'IMEI:'));
      final r = await _correr(_ejecutor(sin, almacen));
      expect(r.errores.single, contains('IMEI utilizable'));
      expect(r.pausas, isEmpty);
      expect(r.logs.where((l) => l.contains('read-gdfs')), isEmpty);
      expect(await almacen.listar(), isEmpty);
    });

    test('un ensayo NO registra un respaldo «real»: queda como simulado', () async {
      await _correr(_ejecutor(ensayo('52', 'RED'), almacen));
      final todos = await almacen.listar();
      expect(todos.length, 1);
      expect(todos.single.simulado, isTrue,
          reason: 'un relleno de 64 KiB no puede desbloquear «Instalar»');
      expect(todos.single.cid, '52');
    });

    test('W580 RED CID53: aborta tras identify, sin pausas ni órdenes ni carpeta',
        () async {
      final r = await _correr(_ejecutor(ensayo('53', 'RED'), almacen));
      expect(r.pausas, isEmpty);
      expect(r.errores.single, contains('CID 53'));
      expect(r.errores.single, contains('SEFTOOL_SENEW_FORCE'));
      expect(r.errores.single, contains('no se registró ningún respaldo'));
      expect(r.logs.where((l) => l.contains('read-gdfs')), isEmpty);
      expect(await almacen.listar(), isEmpty);
      final carpetas = Directory(almacen.rutaBase)
          .listSync()
          .whereType<Directory>()
          .toList();
      expect(carpetas, isEmpty, reason: 'ni siquiera se abrió la carpeta');
    });

    test('el evento de error lleva `paso` (si no, PantFabrica lo descartaría)',
        () async {
      final r = await _correr(_ejecutor(ensayo('53', 'RED'), almacen));
      final ev = r.eventos.firstWhere((e) => e.error != null);
      expect(ev.paso, 'respaldo');
      expect(ev.pasoHecho, isFalse);
    });

    test('W810 RED CID49: aborta (exige --break-rsa o anycid)', () async {
      final r = await _correr(
          _ejecutor(ensayo('49', 'RED', modelo: 'W810i'), almacen));
      expect(r.pausas, isEmpty);
      expect(r.errores.single, contains('--break-rsa'));
      expect(await almacen.listar(), isEmpty);
    });

    test('W580 BROWN: lectura directa, 3 pausas y sin upload-anycid', () async {
      final r = await _correr(_ejecutor(ensayo('49', 'BROWN'), almacen));
      expect(r.errores, isEmpty);
      expect(r.pausas.length, 3);
      expect(r.logs.where((l) => l.contains('upload-anycid')), isEmpty);
      final rf = r.logs.firstWhere((l) => l.startsWith('> ') && l.contains('read-flash'));
      expect(rf, isNot(contains('--anycid')));
    });

    test('cancelar la primera pausa: no se llama a seftool ni se registra nada',
        () async {
      final r = await _correr(_ejecutor(ensayo('52', 'RED'), almacen),
          responde: (i, _) => false);
      expect(r.pausas.length, 1);
      expect(r.errores.single, startsWith('Cancelado por el usuario'));
      expect(r.errores.single, contains('NO se completa ni se registra'));
      expect(r.logs.where((l) => l.startsWith('> ')), isEmpty);
      expect(await almacen.listar(), isEmpty);
    });

    test('cancelar en el paso de «executer»: ya se subió el paquete, no se lee la NOR',
        () async {
      final r = await _correr(_ejecutor(ensayo('52', 'RED'), almacen),
          responde: (i, t) => !t.contains('executer'));
      expect(r.logs.any((l) => l.startsWith('> ') && l.contains('upload-anycid')), isTrue);
      expect(r.logs.any((l) => l.startsWith('> ') && l.contains('read-flash')), isFalse);
      expect(r.errores.single, contains('executer'));
      expect(await almacen.listar(), isEmpty);
    });
  });

  group('frente a lo que contesta seftool (hijo que emite líneas)', () {
    test('«Run executer first» en el 1.er intento: se repite SOLO ese paso y sale bien',
        () async {
      final sef = _SeftoolGuionado(tmp.path, [
        const _RespuestaReadFlash(['[QHTRY] Run executer first'], falla: true),
        _RespuestaReadFlash(['Security disabled =)'],
            alTerminar: _dejaVolcado(), marcador: _nombreVolcado),
      ]);
      final r = await _correr(_ejecutor(sef, almacen));

      expect(r.errores, isEmpty, reason: r.errores.join('\n'));
      final ex = r.pausas.where((x) => x.titulo.contains('executer')).toList();
      expect(ex.length, 2);
      expect(ex[0].titulo, contains('intento 1/3'));
      expect(ex[1].titulo, contains('intento 2/3'));
      expect(ex[1].detalle, contains('El intento anterior falló'));
      expect(ex[1].detalle, contains('Run executer first'));
      expect(sef.comandos.where((c) => c == 'read-gdfs').length, 2,
          reason: 'los GDFS NO se repiten');
      expect(sef.comandos.where((c) => c == 'upload-anycid').length, 1,
          reason: 'el paquete tampoco: ya está en el teléfono');

      final reg = (await almacen.listar()).single;
      expect(reg.simulado, isFalse);
      expect(reg.bytesFlash, EjecutorRespaldo.tamanoFlash);
      final bytes = File(reg.rutaFlash).readAsBytesSync();
      expect(reg.shaFlash, sha256.convert(bytes).toString());
      expect(File(p.join(sef.dirBackup.path, _nombreVolcado)).existsSync(), isFalse,
          reason: 'el volcado se MUEVE al respaldo');
      expect(r.todoElLog, contains('coincide con el que imprimió seftool'));

      // Lo que se registra tiene que bastar para RESTAURAR por anycid: sin el
      // color (o el CID) `restauraPorAnycid` daría false en producción.
      expect(reg.color, 'RED');
      expect(reg.cid, '52');
      expect(reg.modelo, 'W580');
      expect(reg.serie, '35000000000000');
      expect(reg.cxcArticulo, 'CXC1123362');
      expect(reg.paqueteAnycid, isNotNull);
      expect(EjecutorRestauracion.restauraPorAnycid(reg), isTrue);

      // La identidad se fijó DESPUÉS de identify y ANTES de toda orden que
      // habla con el teléfono (GDFS×2, upload-anycid, read-flash×2).
      expect(sef.imeiEsperado, '35000000000000');
      expect(sef.imeisVistos, isNotEmpty);
      expect(sef.imeisVistos.every((i) => i == '35000000000000'), isTrue,
          reason: sef.imeisVistos.toString());
    });

    test('tres fallos seguidos: error con el motivo y nada registrado', () async {
      final sef = _SeftoolGuionado(tmp.path, [
        const _RespuestaReadFlash(['[QHTRY] Run executer first'], falla: true),
      ]);
      final r = await _correr(_ejecutor(sef, almacen));
      expect(r.pausas.where((x) => x.titulo.contains('executer')).length, 3);
      expect(r.errores.single, contains('3 intentos'));
      expect(await almacen.listar(), isEmpty);
    });

    test('una negativa de la compuerta (REFUSED) NO se reintenta', () async {
      final sef = _SeftoolGuionado(tmp.path, [
        const _RespuestaReadFlash([
          'read-flash --anycid: REFUSED: falta --cid <N>; no se manda ningún loader.'
        ], falla: true),
      ]);
      final r = await _correr(_ejecutor(sef, almacen));
      expect(r.pausas.where((x) => x.titulo.contains('executer')).length, 1);
      expect(r.errores.single, contains('se negó'));
      expect(r.errores.single, contains('REFUSED'));
      expect(await almacen.listar(), isEmpty);
    });

    test('seftool sale con error DESPUÉS de guardar el volcado entero: se acepta con aviso',
        () async {
      final sef = _SeftoolGuionado(tmp.path, [
        _RespuestaReadFlash(['Shutdown phone'],
            falla: true, alTerminar: _dejaVolcado(), marcador: _nombreVolcado),
      ]);
      final r = await _correr(_ejecutor(sef, almacen));
      expect(r.errores, isEmpty, reason: r.errores.join('\n'));
      expect(r.todoElLog, contains('AVISO: seftool terminó con error DESPUÉS'));
      expect((await almacen.listar()).single.simulado, isFalse);
      expect(r.pausas.where((x) => x.titulo.contains('executer')).length, 1,
          reason: 'no se repiten 64 MiB por un fallo al apagar');
    });

    test('un volcado de 0xFF enteros no es un respaldo', () async {
      final sef = _SeftoolGuionado(tmp.path, [
        _RespuestaReadFlash([],
            alTerminar: _dejaVolcado(relleno: 0xFF), marcador: _nombreVolcado),
      ]);
      final r = await _correr(_ejecutor(sef, almacen));
      expect(r.errores.single, contains('no sirve como respaldo'));
      expect(r.errores.single, contains('0xFF'));
      expect(await almacen.listar(), isEmpty);
    });

    test('un volcado de otro IMEI no se toma por el de este teléfono', () async {
      final sef = _SeftoolGuionado(tmp.path, [
        _RespuestaReadFlash([],
            alTerminar: _dejaVolcado(
                nombre: 'flashdump_99999999999999_44000000_04000000.bin'),
            marcador: 'flashdump_99999999999999_44000000_04000000.bin'),
      ]);
      final r = await _correr(_ejecutor(sef, almacen));
      expect(r.errores.single, contains('otro IMEI'));
      expect(r.errores.single, contains('99999999999999'));
      expect(r.pausas.where((x) => x.titulo.contains('executer')).length, 1,
          reason: 'enchufar otro teléfono no se arregla reintentando');
      expect(await almacen.listar(), isEmpty);
    });

    test('un GDFS de otro IMEI aborta el respaldo (no se mezclan aparatos)',
        () async {
      final sef = _SeftoolGuionado(tmp.path, [const _RespuestaReadFlash([])],
          imeiGdfs: '99999999999999');
      final r = await _correr(_ejecutor(sef, almacen));
      expect(r.errores.single, contains('no lleva el IMEI'));
      expect(r.errores.single, contains('¿Cambiaste de teléfono'));
      expect(sef.comandos, ['read-gdfs']);
      expect(await almacen.listar(), isEmpty);
    });
  });

  group('el volcado se cotejó con lo que imprimió seftool', () {
    List<String> deLaCarpeta(Seftool sef, String prefijo) => sef.dirBackup
        .listSync()
        .map((e) => p.basename(e.path))
        .where((n) => n.startsWith(prefijo))
        .toList();

    test('un volcado VIEJO con el mismo nombre se aparta y no se toma por el de ahora',
        () async {
      // seftool «termina bien» pero esta vez no escribe nada; el que hay es de
      // otra pasada (p. ej. una orden a mano en el CLI, mismo IMEI y tamaño).
      final sef = _SeftoolGuionado(
          tmp.path, [const _RespuestaReadFlash(['Security disabled =)'])]);
      _dejaVolcado()(sef.dirBackup);
      final r = await _correr(_ejecutor(sef, almacen));
      expect(r.errores.single, contains('no dejó $_nombreVolcado entero'));
      expect(File(p.join(sef.dirBackup.path, _nombreVolcado)).existsSync(), isFalse,
          reason: 'el viejo ya no está bajo el nombre que se espera');
      expect(deLaCarpeta(sef, '$_nombreVolcado.previo-').length, 1,
          reason: 'apartado, no borrado');
      expect(r.todoElLog, contains('se aparta como'));
      expect(await almacen.listar(), isEmpty);
    });

    test('con un volcado viejo delante, lo que se registra es el NUEVO', () async {
      final sef = _SeftoolGuionado(tmp.path, [
        _RespuestaReadFlash(['Security disabled =)'],
            alTerminar: _dejaVolcado(), marcador: _nombreVolcado),
      ]);
      _dejaVolcado(relleno: 0xAB)(sef.dirBackup); // el viejo: 0xAB enteros
      final r = await _correr(_ejecutor(sef, almacen));
      expect(r.errores, isEmpty, reason: r.errores.join('\n'));
      final reg = (await almacen.listar()).single;
      // Por huella: `equals` sobre 64 M de enteros tarda más de un minuto.
      expect(sha256.convert(File(reg.rutaFlash).readAsBytesSync()).toString(),
          sha256.convert(_bytesVolcado()).toString());
      final previo = deLaCarpeta(sef, '$_nombreVolcado.previo-').single;
      expect(File(p.join(sef.dirBackup.path, previo)).readAsBytesSync().first, 0xAB,
          reason: 'el viejo sigue ahí, intacto');
    });

    test('un volcado propio TRUNCADO se nombra con su tamaño (no es «de otro IMEI»)',
        () async {
      final sef = _SeftoolGuionado(tmp.path, [
        _RespuestaReadFlash(['Security disabled =)'], alTerminar: (backup) {
          backup.createSync(recursive: true);
          File(p.join(backup.path, _nombreVolcado)).writeAsBytesSync([1, 2, 3]);
        }),
      ]);
      final r = await _correr(_ejecutor(sef, almacen));
      expect(r.errores.single, contains('no dejó $_nombreVolcado entero'));
      expect(r.errores.single, contains('mide 3 B'));
      expect(r.errores.single, isNot(contains('otro IMEI')),
          reason: 'su propio fichero no es el de otro teléfono');
      expect(await almacen.listar(), isEmpty);
    });

    test('un volcado completo SIN la confirmación de seftool no se acepta',
        () async {
      final sef = _SeftoolGuionado(tmp.path, [
        _RespuestaReadFlash(['Security disabled =)'], alTerminar: _dejaVolcado()),
      ]);
      final r = await _correr(_ejecutor(sef, almacen));
      expect(r.errores.single, contains('No se pudo confirmar'));
      expect(r.errores.single, contains('Flash dump saved'));
      expect(r.pausas.where((x) => x.titulo.contains('executer')).length, 1,
          reason: 'no se repiten 64 MiB: no es un fallo del executer');
      expect(File(p.join(sef.dirBackup.path, _nombreVolcado)).existsSync(), isTrue,
          reason: 'no se movió: nadie sabe de quién es');
      expect(await almacen.listar(), isEmpty);
    });

    test('seftool confirma OTRO nombre: no se acepta', () async {
      final sef = _SeftoolGuionado(tmp.path, [
        _RespuestaReadFlash([
          'Flash dump saved ./backup/flashdump_35000000000000_44000000_00020000.bin '
              '(131072 bytes, SHA-1 ${'a' * 40})'
        ], alTerminar: _dejaVolcado()),
      ]);
      final r = await _correr(_ejecutor(sef, almacen));
      expect(r.errores.single, contains('No se pudo confirmar'));
      expect(r.errores.single, contains('confirmó otro volcado'));
      expect(await almacen.listar(), isEmpty);
    });

    test('el SHA-1 del disco no es el que imprimió seftool: no se acepta',
        () async {
      final sef = _SeftoolGuionado(tmp.path, [
        _RespuestaReadFlash(['Security disabled =)'],
            alTerminar: _dejaVolcado(),
            marcador: _nombreVolcado,
            sha1Mentira: true),
      ]);
      final r = await _correr(_ejecutor(sef, almacen));
      expect(r.errores.single, contains('No se pudo confirmar'));
      expect(r.errores.single, contains('no es el que seftool dijo'));
      expect(await almacen.listar(), isEmpty);
    });

    test('un volcado que se repite (el MiB 0 también en el 16, 32 o 48) no sirve',
        () async {
      for (final mib in [16, 32, 48]) {
        final sef = _SeftoolGuionado(Directory.systemTemp.createTempSync('senus-esp').path, [
          _RespuestaReadFlash([],
              alTerminar: _dejaVolcado(espejoEnMib: mib), marcador: _nombreVolcado),
        ]);
        final r = await _correr(_ejecutor(sef, almacen));
        expect(r.errores.single, contains('no sirve como respaldo'), reason: 'MiB $mib');
        expect(r.errores.single, contains('la NOR se repite'), reason: 'MiB $mib');
        expect(await almacen.listar(), isEmpty, reason: 'MiB $mib');
        // Se conserva junto al respaldo como prueba, pero sin registrar.
        final carpeta = Directory(almacen.rutaBase).listSync().whereType<Directory>().single;
        expect(File(p.join(carpeta.path, 'flash_full.bin')).existsSync(), isTrue);
        Directory(carpeta.path).deleteSync(recursive: true);
        Directory(sef.raiz).deleteSync(recursive: true);
      }
    });

    test('un volcado sin el ID del firmware de ESTE aparato no sirve', () async {
      final sef = _SeftoolGuionado(tmp.path, [
        _RespuestaReadFlash([],
            alTerminar: _dejaVolcado(conId: false), marcador: _nombreVolcado),
      ]);
      final r = await _correr(_ejecutor(sef, almacen));
      expect(r.errores.single, contains('no sirve como respaldo'));
      expect(r.errores.single, contains('prgCXC1123362'));
      expect(await almacen.listar(), isEmpty);
    });

    test('un GDFS vacío aborta el respaldo (un respaldo con 0 B no restaura nada)',
        () async {
      final sef = _SeftoolGuionado(tmp.path, [const _RespuestaReadFlash([])],
          gdfsVacio: true);
      final r = await _correr(_ejecutor(sef, almacen));
      expect(r.errores.single, contains('está vacío'));
      expect(sef.comandos, ['read-gdfs']);
      expect(await almacen.listar(), isEmpty);
    });

    test('upload-anycid que falla (error:29): no se pide el executer ni se lee la NOR',
        () async {
      final sef = _SeftoolGuionado(tmp.path, [const _RespuestaReadFlash([])],
          subirAnycidLineas: const [
            'Starting FSX server... failed',
            'csloader: error: 29'
          ]);
      final r = await _correr(_ejecutor(sef, almacen));
      expect(r.errores.single, contains('no arrancó sus servicios'));
      expect(r.pausas.where((x) => x.titulo.contains('executer')), isEmpty);
      expect(sef.comandos.where((c) => c.contains('read-flash')), isEmpty);
      expect(await almacen.listar(), isEmpty);
    });

    test('upload-anycid que ni siquiera dice «started» tampoco se da por hecho',
        () async {
      final sef = _SeftoolGuionado(tmp.path, [const _RespuestaReadFlash([])],
          subirAnycidLineas: const ['nada que ver']);
      final r = await _correr(_ejecutor(sef, almacen));
      expect(r.errores.single, contains('no arrancó sus servicios'));
      expect(r.pausas.where((x) => x.titulo.contains('executer')), isEmpty);
    });

    test('seftool se niega por el IMEI (otro teléfono): UN solo intento, sin el '
        'ritual del executer ni reintentos', () async {
      for (final conExecuterFirst in [false, true]) {
        // true = un seftool anterior, que además imprimía «Run executer first».
        final raiz = Directory.systemTemp.createTempSync('senus-neg');
        final sef = _SeftoolGuionado(raiz.path, [
          _RespuestaReadFlash([
            if (conExecuterFirst) '[QHTRY] Run executer first',
            'El aparato conectado dice IMEI «99999999999999» y se esperaba «35000000000000».',
            'imei-check: REFUSED: no es el teléfono esperado; no se manda nada más.',
            if (conExecuterFirst)
              'read-flash --anycid: no cargó el loader de setool2 (¿executer activo?)',
          ], falla: true),
        ]);
        final r = await _correr(_ejecutor(sef, almacen));
        expect(r.errores.single, contains('NO es el del respaldo'),
            reason: 'executer=$conExecuterFirst');
        expect(r.errores.single, contains('99999999999999'));
        expect(r.pausas.where((x) => x.titulo.contains('executer')).length, 1,
            reason: 'otro teléfono no se arregla repitiendo el ritual '
                '(executer=$conExecuterFirst)');
        expect(sef.comandos.where((c) => c.contains('read-flash')).length, 1);
        expect(await almacen.listar(), isEmpty);
        raiz.deleteSync(recursive: true);
      }
    });

    test('un IMEI en blanco en identify («______________») aborta antes de leer nada',
        () async {
      final blanco = Seftool(
          raiz: '/no/importa',
          puerto: '/dev/x',
          ensayo: true,
          identifyEnsayoStdout: _identify('52', 'RED')
              .replaceAll('IMEI:35000000000000', 'IMEI:______________'));
      final r = await _correr(_ejecutor(blanco, almacen));
      expect(r.errores.single, contains('IMEI utilizable'));
      expect(r.pausas, isEmpty);
      expect(await almacen.listar(), isEmpty);
    });

    test('el .INCOMPLETO de un intento anterior se BORRA (no se acumulan hasta '
        '64 MiB por intento)', () async {
      const parcial = '$_nombreVolcado.INCOMPLETO';
      void dejaParcial(Directory backup) {
        backup.createSync(recursive: true);
        File(p.join(backup.path, parcial)).writeAsBytesSync(List.filled(1000, 7));
      }

      final sef = _SeftoolGuionado(tmp.path, [
        _RespuestaReadFlash(['[QHTRY] Run executer first'],
            falla: true, alTerminar: dejaParcial),
      ]);
      dejaParcial(sef.dirBackup); // uno de antes de empezar
      final r = await _correr(_ejecutor(sef, almacen));
      final nombres =
          sef.dirBackup.listSync().map((e) => p.basename(e.path)).toList();
      expect(nombres.where((n) => n.contains('INCOMPLETO')).toList(), [parcial],
          reason: 'solo el del último intento; los 3 intentos no apilan nada');
      expect(nombres.where((n) => n.contains('previo')), isEmpty);
      expect(r.todoElLog, contains('se borra'));
    });

    test('rehacer el respaldo el mismo día NO pisa el ya registrado, aunque el '
        'nuevo se rechace', () async {
      // Un respaldo bueno ya registrado.
      final dir1 = await almacen.abrirCarpeta('W580', '35000000000000');
      File(p.join(dir1.path, 'flash_full.bin')).writeAsBytesSync([1, 2, 3]);
      File(p.join(dir1.path, 'gdfs_A.bin')).writeAsBytesSync([4, 5, 6]);
      await almacen.registrar(RespaldoRollback(
          carpeta: dir1.path,
          modelo: 'W580',
          serie: '35000000000000',
          fecha: DateTime.now(),
          cid: '52',
          color: 'RED',
          firmwareOriginal: 'R8BE001',
          shaFlash: 'a' * 64,
          bytesFlash: 3));
      // Otro intento el mismo día, con un volcado de 0xFF.
      final sef = _SeftoolGuionado(tmp.path, [
        _RespuestaReadFlash([],
            alTerminar: _dejaVolcado(relleno: 0xFF), marcador: _nombreVolcado),
      ]);
      final r = await _correr(_ejecutor(sef, almacen));
      expect(r.errores.single, contains('no sirve como respaldo'));
      expect(File(p.join(dir1.path, 'flash_full.bin')).readAsBytesSync(), [1, 2, 3],
          reason: 'el flash_full.bin registrado sigue intacto');
      expect(File(p.join(dir1.path, 'gdfs_A.bin')).readAsBytesSync(), [4, 5, 6],
          reason: 'y su GDFS también');
      final todos = await almacen.listar();
      expect(todos.single.carpeta, dir1.path, reason: 'el índice no cambió');
      final carpetas = Directory(almacen.rutaBase)
          .listSync()
          .whereType<Directory>()
          .map((d) => p.basename(d.path))
          .toList()
        ..sort();
      expect(carpetas.length, 2);
      expect(carpetas.last, endsWith('-2'), reason: 'el intento nuevo va aparte');
    });

    test('GDFS A y B iguales: lo dice; si difieren: AVISO', () async {
      // read-flash se niega enseguida: lo que se mira es lo que se dijo antes.
      const rechazo = _RespuestaReadFlash(
          ['read-flash --anycid: REFUSED: x'], falla: true);
      final iguales = await _correr(
          _ejecutor(_SeftoolGuionado(tmp.path, [rechazo]), almacen));
      expect(iguales.todoElLog, contains('GDFS A y B iguales'));
      expect(iguales.todoElLog, isNot(contains('AVISO: GDFS A y B difieren')));

      final otra = Directory.systemTemp.createTempSync('senus-ab');
      final difieren = await _correr(_ejecutor(
          _SeftoolGuionado(otra.path, [rechazo], gdfsDistinto: true), almacen));
      expect(difieren.todoElLog, contains('AVISO: GDFS A y B difieren'));
      expect(difieren.todoElLog, isNot(contains('GDFS A y B iguales')));
      otra.deleteSync(recursive: true);
    });
  });

  group('AlmacenRespaldos.abrirCarpeta', () {
    RespaldoRollback respaldo(Directory d) => RespaldoRollback(
        carpeta: d.path,
        modelo: 'W580',
        serie: '35000000000000',
        fecha: DateTime.now(),
        cid: '52',
        color: 'RED',
        firmwareOriginal: 'R8BE001',
        shaFlash: 'a' * 64,
        bytesFlash: 1);

    test('una carpeta SIN respaldo registrado se reutiliza', () async {
      final a = await almacen.abrirCarpeta('W580', '35000000000000');
      final b = await almacen.abrirCarpeta('W580', '35000000000000');
      expect(b.path, a.path);
    });

    test('con un respaldo registrado, la siguiente es -2, y luego -3', () async {
      final a = await almacen.abrirCarpeta('W580', '35000000000000');
      await almacen.registrar(respaldo(a));
      final b = await almacen.abrirCarpeta('W580', '35000000000000');
      expect(b.path, '${a.path}-2');
      await almacen.registrar(respaldo(b));
      final c = await almacen.abrirCarpeta('W580', '35000000000000');
      expect(c.path, '${a.path}-3');
    });

    test('también si el índice se perdió: basta el metadatos.json de la carpeta',
        () async {
      final a = await almacen.abrirCarpeta('W580', '35000000000000');
      await almacen.registrar(respaldo(a));
      File(almacen.rutaIndice).deleteSync();
      final b = await almacen.abrirCarpeta('W580', '35000000000000');
      expect(b.path, '${a.path}-2');
    });
  });

  group('analizarVolcadoNor', () {
    test('devuelve el SHA-1 del fichero (el de sha1sum) cuando es creíble',
        () async {
      final f = File(p.join(tmp.path, 'bien.bin'))
        ..writeAsBytesSync(_bytesVolcado());
      final a = await analizarVolcadoNor(f, cxcArticulo: 'CXC1123362');
      expect(a.motivo, isNull);
      expect(a.sha1, sha1.convert(f.readAsBytesSync()).toString());
    });

    test('el ID del firmware se encuentra en CUALQUIER posición de la juntura '
        'entre dos trozos de 1 MiB', () async {
      const mib = 0x100000;
      const id = 'prgCXC1123362'; // 13 bytes
      // k bytes en el primer MiB y el resto en el segundo, para k = 1..12.
      for (var k = 1; k < id.length; k++) {
        final b = _bytesVolcado(tam: 3 * mib, conId: false);
        b.setRange(mib - k, mib - k + id.length, id.codeUnits);
        final f = File(p.join(tmp.path, 'junta$k.bin'))..writeAsBytesSync(b);
        final a = await analizarVolcadoNor(f,
            esperado: 3 * mib, cxcArticulo: 'CXC1123362');
        expect(a.motivo, isNull, reason: 'partido $k + ${id.length - k}');
      }
    });

    test('un ID parecido pero distinto no vale', () async {
      final b = _bytesVolcado(conId: false);
      b.setRange(0x1A2B3C, 0x1A2B3C + 13, 'prgCXC1123363'.codeUnits);
      final f = File(p.join(tmp.path, 'parecido.bin'))..writeAsBytesSync(b);
      final a = await analizarVolcadoNor(f, cxcArticulo: 'CXC1123362');
      expect(a.motivo, contains('prgCXC1123362'));
      expect(a.sha1, isNull);
    });

    test('sin ID que buscar (artículo vacío o null) no se exige nada', () async {
      final f = File(p.join(tmp.path, 'sinid.bin'))
        ..writeAsBytesSync(_bytesVolcado(conId: false));
      expect((await analizarVolcadoNor(f)).motivo, isNull);
      expect((await analizarVolcadoNor(f, cxcArticulo: '')).motivo, isNull);
    });

    test('el MiB 0 repetido en el 16, el 32 o el 48 se detecta, cada uno', () async {
      for (final mib in [16, 32, 48]) {
        final f = File(p.join(tmp.path, 'esp$mib.bin'))
          ..writeAsBytesSync(_bytesVolcado(espejoEnMib: mib));
        final m = (await analizarVolcadoNor(f)).motivo;
        expect(m, contains('se repite'), reason: 'MiB $mib');
        expect(m, contains('0x${(0x44000000 + mib * 0x100000).toRadixString(16).toUpperCase()}'),
            reason: 'MiB $mib');
      }
    });

    test('un volcado de la mitad (32 MiB) con ventanas creíbles → «mide»', () async {
      final b = _bytesVolcado().sublist(0, 32 * 0x100000);
      final f = File(p.join(tmp.path, 'mitad.bin'))..writeAsBytesSync(b);
      expect(await verificarVolcadoNor(f), contains('mide'));
    });

    test('un volcado más largo de lo esperado tampoco', () async {
      final f = File(p.join(tmp.path, 'largo.bin'))
        ..writeAsBytesSync(Uint8List(EjecutorRespaldo.tamanoFlash + 1));
      expect(await verificarVolcadoNor(f), contains('mide'));
    });
  });

  group('verificarVolcadoNor', () {
    test('tamaño distinto → motivo', () async {
      final f = File(p.join(tmp.path, 'corto.bin'))..writeAsBytesSync([1, 2, 3]);
      expect(await verificarVolcadoNor(f), contains('3 B'));
    });

    test('0x00 enteros en el arranque → motivo', () async {
      final f = File(p.join(tmp.path, 'ceros.bin'));
      f.writeAsBytesSync(Uint8List(EjecutorRespaldo.tamanoFlash));
      expect(await verificarVolcadoNor(f), contains('0x00'));
    });

    test('el arranque bien pero el main en 0xFF → motivo que nombra el main',
        () async {
      final f = File(p.join(tmp.path, 'main_ff.bin'));
      final b = Uint8List(EjecutorRespaldo.tamanoFlash);
      for (var i = 0; i < 0x40000; i++) {
        b[i] = i & 0xFF;
      }
      b.fillRange(0x140000, 0x180000, 0xFF);
      f.writeAsBytesSync(b);
      final m = await verificarVolcadoNor(f);
      expect(m, contains('0x44140000'));
      expect(m, contains('0xFF'));
    });

    test('datos creíbles → null', () async {
      final f = File(p.join(tmp.path, 'bien.bin'));
      final b = Uint8List(EjecutorRespaldo.tamanoFlash);
      for (var i = 0; i < b.length; i += 13) {
        b[i] = (i ~/ 13) & 0xFF;
      }
      b[0] = 0xAA;
      b[1] = 0x55;
      b[0x140000] = 0xAA;
      b[0x140001] = 0x55;
      f.writeAsBytesSync(b);
      expect(await verificarVolcadoNor(f), isNull);
    });
  });
}
