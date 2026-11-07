// La restauración de un W580 RED por flash-anycid, SIN aparato y SIN abrir
// ningún puerto.
//
// Por qué por flash-anycid: `flash main` en un W580 RED va por OFLASH con el
// flashloader FIRMADO y `flash_babe_fw` rechaza en el host cualquier imagen de
// `raw2babe` («Can not check BABE file»). Una imagen sin firma solo entra por
// la rama anycid del bflash, que exige el MIDlet «executer» corriendo.
//
// En ensayo seftool no se ejecuta. Para lo que depende de lo que contesta
// seftool (el executer que no está, un fallo a mitad de la escritura) se usa un
// `Seftool` hijo que EMITE LÍNEAS de seftool: prueba la lógica de SENUS frente
// a ellas, no simula ningún loader.

@Timeout(Duration(minutes: 5))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:senus_app/datos/instalacion.dart';
import 'package:senus_app/datos/respaldo_rollback.dart';
import 'package:senus_app/datos/seftool.dart';

const _imei = '35000000000000';

String _identify(String cid, {String modelo = 'W580i', String imei = _imei}) =>
    'Phone Info (from GDFS):\n'
    'Model: $modelo\n'
    'OTP: LOCKED:0 CID:$cid PAF:0 IMEI:$imei\n'
    'ACTIVE CID:$cid COLOR:RED\n'
    'MAPP CXC article: CXC1123362\n'
    'MAPP CXC version: R8BE001\n';

RespaldoRollback _resp(Directory dir,
    {String cid = '52',
    String color = 'RED',
    String modelo = 'W580',
    bool conFlash = true,
    String? shaFlash,
    String serie = _imei,
    String? cxcArticulo}) {
  final r = RespaldoRollback(
    carpeta: dir.path,
    modelo: modelo,
    serie: serie,
    fecha: DateTime.now(),
    cid: cid,
    color: color,
    firmwareOriginal: 'R8BE001',
    shaFlash: shaFlash ?? 'f' * 64,
    bytesFlash: 1,
    paqueteAnycid: 'R8BE001_CXC1123362_GENERIC_LA',
    cxcArticulo: cxcArticulo,
  );
  File(r.rutaGdfsA).writeAsBytesSync(List<int>.filled(16, 0x11));
  if (conFlash) File(r.rutaFlash).writeAsBytesSync(List<int>.filled(16, 0x22));
  return r;
}

class _Intento {
  final List<String> lineas;
  final bool falla;
  const _Intento(this.lineas, {this.falla = false});
}

/// seftool en ensayo, salvo `flash-anycid main`, que emite las líneas que se
/// le indiquen (un intento por llamada; el último se repite).
class _SeftoolRest extends Seftool {
  final List<_Intento> intentos;
  final comandos = <String>[];

  /// El `imeiEsperado` que tenía el seftool al hacer `identify` (la
  /// verificación: aún no puede estar fijado) y en cada `flash-anycid main`.
  String? imeiAlIdentificar = 'no se llamó';
  final imeisEnElMain = <String?>[];
  var _n = 0;
  _SeftoolRest(this.intentos, {String cid = '52', String modelo = 'W580i', String imei = _imei})
      : super(
            raiz: '/no/importa',
            puerto: '/dev/x',
            ensayo: true,
            identifyEnsayoStdout: _identify(cid, modelo: modelo, imei: imei));

  @override
  Future<InfoAparato> identify({void Function(LineaSeftool)? alVuelo}) {
    imeiAlIdentificar = imeiEsperado;
    return super.identify(alVuelo: alVuelo);
  }

  @override
  Stream<LineaSeftool> grabarMainAnycid(String rutaBabe, int cid) async* {
    comandos.add('flash-anycid main $rutaBabe --cid $cid');
    imeisEnElMain.add(imeiEsperado);
    // La orden REAL (en ensayo solo la escribe): así el ORDEN de las órdenes
    // (upload-anycid → flash-anycid → write-gdfs) y sus banderas se pueden
    // comprobar.
    yield* super.grabarMainAnycid(rutaBabe, cid);
    final g = intentos[_n < intentos.length ? _n : intentos.length - 1];
    _n++;
    for (final l in g.lineas) {
      yield LineaSeftool(l);
    }
    if (g.falla) {
      throw SeftoolError('seftool terminó con error (código 255).', salida: 255);
    }
  }
}

class _Pasada {
  final pausas = <({String titulo, String detalle})>[];
  final logs = <String>[];
  final errores = <String>[];
  var cancelado = false;
  var parcial = false;
  List<String> get ordenes => logs.where((l) => l.startsWith('> ')).toList();
  bool vio(String s) => logs.any((l) => l.contains(s));
}

Future<_Pasada> _correr(EjecutorRestauracion e,
    {bool Function(int i, String titulo)? responde}) async {
  final r = _Pasada();
  await for (final ev in e.correr()) {
    if (ev.logLinea != null) r.logs.add(ev.logLinea!);
    if (ev.error != null) r.errores.add(ev.error!);
    if (ev.cancelado) r.cancelado = true;
    if (ev.parcial) r.parcial = true;
    if (ev.pausa != null) {
      final i = r.pausas.length;
      r.pausas.add((titulo: ev.pausaTitulo ?? '', detalle: ev.pausaDetalle ?? ''));
      ev.pausa!.complete(responde == null ? true : responde(i, ev.pausaTitulo ?? ''));
    }
  }
  return r;
}

void main() {
  late Directory tmp;
  late AlmacenRespaldos almacen;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('senus-rest-anycid-');
    almacen = AlmacenRespaldos.en(p.join(tmp.path, 'respaldos'));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  EjecutorRestauracion ejecutor(RespaldoRollback r, Seftool sef) =>
      EjecutorRestauracion(respaldo: r, seftool: sef, almacen: almacen);

  group('restauraPorAnycid: a quién le toca', () {
    bool por(String modelo, String cid, String color) =>
        EjecutorRestauracion.restauraPorAnycid(
            _resp(tmp, modelo: modelo, cid: cid, color: color, conFlash: false));

    test('W580 RED 49/51/52 sí', () {
      for (final c in ['49', '51', '52']) {
        expect(por('W580', c, 'RED'), isTrue, reason: 'CID $c');
      }
    });

    test('CID 53, BROWN y los DB2010 conservan el camino heredado', () {
      expect(por('W580', '53', 'RED'), isFalse);
      expect(por('W580', '49', 'BROWN'), isFalse);
      expect(por('W810', '49', 'RED'), isFalse);
      expect(por('W600', '49', 'RED'), isFalse);
    });
  });

  group('W580 RED CID52 con flash_full.bin', () {
    test('reconexión → upload-anycid → executer → flash-anycid --cid 52 → '
        'reconexión → write-gdfs; y NUNCA `flash main`', () async {
      final r = _resp(tmp);
      final sef = _SeftoolRest([
        const _Intento(['Security disabled =)', '460 blocks flashed ok'])
      ]);
      final res = await _correr(ejecutor(r, sef));

      expect(res.errores, isEmpty, reason: res.errores.join('\n'));
      expect(res.pausas.length, 3);
      expect(res.pausas[0].titulo, tituloReconectar);
      expect(res.pausas[1].titulo, contains('executer'));
      expect(res.pausas[1].titulo, contains('intento 1/3'));
      expect(res.pausas[1].detalle, contains('senew ya reemplazó el main'));
      expect(res.pausas[2].titulo, tituloReconectar);
      expect(res.pausas[2].detalle, contains('flash-anycid'));

      final ord = res.ordenes;
      int pos(String s) => ord.indexWhere((l) => l.contains(s));
      expect(pos('upload-anycid'), greaterThanOrEqualTo(0));
      expect(pos('-a flash-anycid main'), greaterThan(pos('upload-anycid')),
          reason: 'el paquete se sube ANTES de escribir el main');
      expect(pos('write-gdfs'), greaterThan(pos('-a flash-anycid main')),
          reason: 'el GDFS va DESPUÉS del main');
      expect(ord.where((l) => l.contains('flash main')), isEmpty,
          reason: '`flash main` rechaza en el host una imagen sin firma');
      expect(sef.comandos.single, endsWith('--cid 52'));
      expect(res.vio('Camino parcial'), isFalse);
      expect(File(p.join(r.carpeta, 'restaurado.txt')).readAsStringSync(),
          contains('por flash-anycid'));
    });

    test('«Run executer first» una vez: se repite solo ese paso y sale bien',
        () async {
      final r = _resp(tmp);
      final sef = _SeftoolRest([
        const _Intento(['[QHTRY] Run executer first'], falla: true),
        const _Intento(['Security disabled =)', '460 blocks flashed ok']),
      ]);
      final res = await _correr(ejecutor(r, sef));
      expect(res.errores, isEmpty);
      final ex = res.pausas.where((x) => x.titulo.contains('executer')).toList();
      expect(ex.length, 2);
      expect(ex[1].titulo, contains('intento 2/3'));
      expect(ex[1].detalle, contains('El intento anterior falló'));
      expect(sef.comandos.length, 2);
      expect(res.ordenes.where((l) => l.contains('upload-anycid')).length, 1,
          reason: 'el paquete no se vuelve a subir');
      expect(res.ordenes.any((l) => l.contains('write-gdfs')), isTrue);
    });

    test('3 veces sin executer: la NOR no se tocó y se ofrece SOLO el GDFS',
        () async {
      final r = _resp(tmp);
      final sef = _SeftoolRest([
        const _Intento(['[QHTRY] Run executer first'], falla: true),
      ]);
      final res = await _correr(ejecutor(r, sef));
      expect(res.errores, isEmpty);
      expect(res.pausas.where((x) => x.titulo.contains('executer')).length, 3);
      final parcial = res.pausas.last;
      expect(parcial.titulo, contains('Red parcial'));
      expect(parcial.titulo, contains('modo C'));
      expect(parcial.detalle, contains('la NOR no se tocó'));
      expect(res.vio('Camino parcial: SOLO GDFS'), isTrue);
      expect(res.parcial, isTrue,
          reason: 'la pantalla no puede decir «restaurado» si el main no lo está');
      expect(res.cancelado, isFalse);
      expect(res.ordenes.any((l) => l.contains('write-gdfs')), isTrue);
      expect(File(p.join(r.carpeta, 'restaurado.txt')).readAsStringSync(),
          contains('solo GDFS'));
    });

    test('3 veces sin executer y la persona cancela: no se escribe NADA',
        () async {
      final r = _resp(tmp);
      final sef = _SeftoolRest([
        const _Intento(['[QHTRY] Run executer first'], falla: true),
      ]);
      final res = await _correr(ejecutor(r, sef),
          responde: (i, t) => !t.contains('Red parcial'));
      expect(res.errores, isEmpty, reason: 'cancelar no es un error');
      expect(res.cancelado, isTrue, reason: 'pero la pantalla tiene que saber que se canceló');
      expect(res.ordenes.any((l) => l.contains('write-gdfs')), isFalse);
    });

    test('un fallo MIENTRAS escribe no se reintenta: avisa que la NOR puede estar a medias',
        () async {
      final r = _resp(tmp);
      final sef = _SeftoolRest([
        const _Intento([
          'Security disabled =)',
          'flashing block 3/460 (addr 44170000 size 00010000)'
        ], falla: true),
      ]);
      final res = await _correr(ejecutor(r, sef));
      expect(res.errores.single, contains('a medias'));
      expect(res.errores.single, contains('NO apagues'));
      expect(res.pausas.where((x) => x.titulo.contains('executer')).length, 1);
      expect(res.ordenes.any((l) => l.contains('write-gdfs')), isFalse,
          reason: 'con la NOR a medias no se sigue');
    });

    test('«Run executer first» DESPUÉS de haber empezado a escribir NO se reintenta',
        () async {
      final r = _resp(tmp);
      final sef = _SeftoolRest([
        const _Intento([
          'Security disabled =)',
          'flashing block 3/460 (addr 44170000 size 00010000)',
          '[QHTRY] Run executer first'
        ], falla: true),
      ]);
      final res = await _correr(ejecutor(r, sef));
      expect(res.errores.single, contains('a medias'));
      expect(res.pausas.where((x) => x.titulo.contains('executer')).length, 1,
          reason: 'con la NOR a medias, otro intento a ciegas es lo peor');
      expect(res.ordenes.any((l) => l.contains('write-gdfs')), isFalse);
    });

    test('un fallo ANTES de escribir (sin «Run executer first») tampoco se reintenta',
        () async {
      final r = _resp(tmp);
      final sef = _SeftoolRest([
        const _Intento(['flash-anycid: x no pasa la comprobación'], falla: true),
      ]);
      final res = await _correr(ejecutor(r, sef));
      expect(res.errores.single, contains('antes de escribir'));
      expect(res.pausas.where((x) => x.titulo.contains('executer')).length, 1);
    });

    test('cancelar en el executer: no se escribe nada y no hay error', () async {
      final r = _resp(tmp);
      final sef = _SeftoolRest([const _Intento(['x'])]);
      final res = await _correr(ejecutor(r, sef),
          responde: (i, t) => !t.contains('executer'));
      expect(res.errores, isEmpty);
      expect(res.cancelado, isTrue);
      expect(sef.comandos, isEmpty);
      expect(res.ordenes.any((l) => l.contains('write-gdfs')), isFalse);
    });

    test('cancelar la reconexión inicial: ni siquiera se sube el paquete',
        () async {
      final r = _resp(tmp);
      final sef = _SeftoolRest([const _Intento(['x'])]);
      final res = await _correr(ejecutor(r, sef), responde: (i, t) => false);
      expect(res.errores, isEmpty);
      expect(res.cancelado, isTrue);
      expect(res.pausas.length, 1);
      expect(res.ordenes.any((l) => l.contains('upload-anycid')), isFalse);
    });
  });

  group('cancelar la ÚLTIMA reconexión (entre el main y write-gdfs)', () {
    test('anycid: el main SE escribió, write-gdfs NO corre, y la persona lo sabe',
        () async {
      final r = _resp(tmp);
      final sef = _SeftoolRest([
        const _Intento(['Security disabled =)', '460 blocks flashed ok'])
      ]);
      // Pausas: 0 reconexión, 1 executer, 2 main→gdfs. Se cancela SOLO la 2.
      final res = await _correr(ejecutor(r, sef), responde: (i, t) => i < 2);
      expect(res.pausas.length, 3);
      expect(res.errores, isEmpty, reason: 'cancelar no es un error');
      expect(res.cancelado, isTrue);
      expect(res.vio('-a flash-anycid main'), isTrue, reason: 'el main sí se escribió');
      expect(res.ordenes.any((l) => l.contains('write-gdfs')), isFalse,
          reason: 'pero el GDFS no: la persona canceló');
      expect(res.logs.any((l) => l.contains('El main se escribió; el GDFS NO')), isTrue);
      expect(File(p.join(r.carpeta, 'restaurado.txt')).existsSync(), isFalse,
          reason: 'una restauración cancelada no se anota como hecha');
    });

    test('camino heredado (CID 53): igual con `flash main`', () async {
      final r = _resp(tmp, cid: '53');
      final sef = _SeftoolRest([const _Intento(['x'])], cid: '53');
      // Pausas: 0 reconexión, 1 main→gdfs. Se cancela SOLO la 1.
      final res = await _correr(ejecutor(r, sef), responde: (i, t) => i < 1);
      expect(res.pausas.length, 2);
      expect(res.errores, isEmpty);
      expect(res.cancelado, isTrue);
      expect(res.ordenes.any((l) => l.contains('-a flash main')), isTrue);
      expect(res.ordenes.any((l) => l.contains('write-gdfs')), isFalse);
    });
  });

  group('upload-anycid que falla', () {
    test('el error llega como error y NO se pide el executer ni se escribe nada',
        () async {
      final r = _resp(tmp);
      final sef = _SeftoolSinFsx();
      final res = await _correr(ejecutor(r, sef));
      expect(res.errores.single, contains('CS loader no arrancó'));
      expect(res.pausas.length, 1, reason: 'solo la reconexión inicial; el executer ni se pide');
      expect(res.ordenes.any((l) => l.contains('flash-anycid')), isFalse);
      expect(res.ordenes.any((l) => l.contains('write-gdfs')), isFalse);
    });
  });

  group('el camino heredado (CID 53) también reconecta tras el identify', () {
    test('la primera pausa llega ANTES de `flash main`', () async {
      final r = _resp(tmp, cid: '53');
      final sef = _SeftoolRest([const _Intento(['x'])], cid: '53');
      final res = await _correr(ejecutor(r, sef));
      expect(res.pausas.first.titulo, tituloReconectar);
      expect(res.pausas.length, 2);
      expect(res.ordenes.any((l) => l.contains('flash main')), isTrue);
      expect(res.ordenes.any((l) => l.contains('flash-anycid')), isFalse);
    });
  });

  group('identidad (--imei): el respaldo es de ESTE teléfono', () {
    test('se fija DESPUÉS del identify de verificación y viaja en cada orden',
        () async {
      final r = _resp(tmp);
      final sef = _SeftoolRest([
        const _Intento(['Security disabled =)', '460 blocks flashed ok'])
      ]);
      final res = await _correr(ejecutor(r, sef));
      expect(res.errores, isEmpty, reason: res.errores.join('\n'));
      expect(sef.imeiAlIdentificar, isNull,
          reason: 'identify es quien descubre el IMEI: no puede llevarlo');
      expect(sef.imeiEsperado, _imei);
      expect(sef.imeisEnElMain, [_imei]);
      for (final a in ['upload-anycid', 'flash-anycid main', 'write-gdfs']) {
        final o = res.ordenes.firstWhere((l) => l.contains('-a $a'),
            orElse: () => fail('no hubo orden $a: ${res.ordenes}'));
        expect(o, contains('--imei $_imei -a $a'), reason: o);
      }
    });

    test('el camino heredado (CID 53) también: `flash main` y write-gdfs', () async {
      final r = _resp(tmp, cid: '53');
      final sef = _SeftoolRest([const _Intento(['x'])], cid: '53');
      final res = await _correr(ejecutor(r, sef));
      expect(res.errores, isEmpty);
      for (final a in ['flash main', 'write-gdfs']) {
        final o = res.ordenes.firstWhere((l) => l.contains('-a $a'));
        expect(o, contains('--imei $_imei -a $a'), reason: o);
      }
    });

    test('otro IMEI: no es el del respaldo, nada se fija ni se pide ni se escribe',
        () async {
      final r = _resp(tmp);
      final sef = _SeftoolRest([const _Intento(['x'])], imei: '99999999999999');
      final res = await _correr(ejecutor(r, sef));
      expect(res.errores.single, contains('NO es el del respaldo'));
      expect(sef.imeiEsperado, isNull);
      expect(res.pausas, isEmpty);
      expect(res.ordenes.any((l) => l.contains(' -a ')), isFalse);
    });

    test('el mismo IMEI pero OTRO CID: tampoco es el del respaldo', () async {
      final r = _resp(tmp); // CID 52
      final sef = _SeftoolRest([const _Intento(['x'])], cid: '51');
      final res = await _correr(ejecutor(r, sef));
      expect(res.errores.single, contains('NO es el del respaldo'));
      expect(res.errores.single, contains('CID 51'));
      expect(sef.imeiEsperado, isNull);
      expect(res.pausas, isEmpty);
      expect(res.ordenes.any((l) => l.contains(' -a ')), isFalse);
    });

    test('el mismo IMEI y CID pero OTRO modelo: tampoco', () async {
      final r = _resp(tmp); // W580
      final sef = _SeftoolRest([const _Intento(['x'])], modelo: 'W810i');
      final res = await _correr(ejecutor(r, sef));
      expect(res.errores.single, contains('NO es el del respaldo'));
      expect(res.errores.single, contains('W810'));
      expect(res.pausas, isEmpty);
      expect(res.ordenes.any((l) => l.contains(' -a ')), isFalse);
    });

    test('un IMEI en BLANCO («______________», un OTP vacío) en el aparato y en '
        'el respaldo tampoco cuadra', () async {
      final r = _resp(tmp, serie: '______________');
      final sef = _SeftoolRest([const _Intento(['x'])], imei: '______________');
      final res = await _correr(ejecutor(r, sef));
      expect(res.errores.single, contains('NO es el del respaldo'));
      expect(sef.imeiEsperado, isNull);
      expect(res.pausas, isEmpty);
      expect(res.ordenes.any((l) => l.contains(' -a ')), isFalse);
    });

    test('flash-anycid se niega por el IMEI (otro teléfono): sin ritual del '
        'executer, sin reintentos y SIN ofrecer la «red parcial»', () async {
      for (final conExecuterFirst in [false, true]) {
        // true = un seftool anterior, que además imprimía «Run executer first».
        final r = _resp(tmp);
        final sef = _SeftoolRest([
          _Intento([
            if (conExecuterFirst) '[QHTRY] Run executer first',
            'El aparato conectado dice IMEI «99999999999999» y se esperaba «$_imei».',
            'imei-check: REFUSED: no es el teléfono esperado; no se manda nada más.',
          ], falla: true),
        ]);
        final res = await _correr(ejecutor(r, sef));
        expect(res.errores.single, contains('NO es el del respaldo'),
            reason: 'executer=$conExecuterFirst');
        expect(res.errores.single, contains('99999999999999'));
        expect(res.pausas.where((x) => x.titulo.contains('executer')).length, 1,
            reason: 'executer=$conExecuterFirst');
        expect(res.pausas.where((x) => x.titulo.contains('Red parcial')), isEmpty,
            reason: 'con el teléfono equivocado no se ofrece escribir el GDFS');
        expect(sef.comandos.length, 1);
        expect(res.ordenes.any((l) => l.contains('write-gdfs')), isFalse);
        expect(res.parcial, isFalse);
      }
    });

    test('un IMEI vacío en el aparato Y en el respaldo no «cuadra»: no identifica a nadie',
        () async {
      final r = _resp(tmp, serie: '');
      final sef = _SeftoolRest([const _Intento(['x'])],
          imei: ''); // identify sin IMEI
      final res = await _correr(ejecutor(r, sef));
      expect(res.errores.single, contains('NO es el del respaldo'));
      expect(sef.imeiEsperado, isNull);
      expect(res.pausas, isEmpty);
    });
  });

  group('el volcado tiene que ser de ESTE firmware antes de escribirlo', () {
    /// 64 MiB creíbles (no uniformes ni repetidos), con o sin el ID del firmware.
    Uint8List nor({required bool conId}) {
      final b = Uint8List(EjecutorRespaldo.tamanoFlash);
      for (var i = 0; i < b.length; i += 97) {
        b[i] = (i ~/ 97) & 0xFF;
      }
      b[0] = 0xEA;
      b[0x140000] = 0xEA;
      b[0x140001] = 0x12;
      if (conId) {
        final id = 'R8BE001     prgCXC1123362_GENERIC_LA'.codeUnits;
        b.setRange(0x1A2B3C, 0x1A2B3C + id.length, id);
      }
      return b;
    }

    Future<_Pasada> restaura({required bool conId, String? articulo}) async {
      final b = nor(conId: conId);
      final r = _resp(tmp,
          conFlash: false,
          shaFlash: sha256.convert(b).toString(),
          cxcArticulo: articulo);
      File(r.rutaFlash).writeAsBytesSync(b);
      return _correr(ejecutor(r, _SeftoolRealFalso()));
    }

    test('sin el ID del firmware en el volcado: no sirve para restaurar', () async {
      final res = await restaura(conId: false, articulo: 'CXC1123362');
      expect(res.errores.single, contains('no sirve para restaurar'));
      expect(res.errores.single, contains('prgCXC1123362'));
      expect(res.pausas, isEmpty);
    });

    test('con el ID, esa comprobación pasa (el siguiente paso falla por otra cosa)',
        () async {
      final res = await restaura(conId: true, articulo: 'CXC1123362');
      expect(res.errores.join('\n'), isNot(contains('no sirve para restaurar')));
    });

    test('un respaldo sin artículo anotado no exige nada que no puede comprobar',
        () async {
      final res = await restaura(conId: false, articulo: null);
      expect(res.errores.join('\n'), isNot(contains('no sirve para restaurar')));
    });
  });

  group('el volcado tiene que ser creíble antes de escribirlo', () {
    test('el flash_full.bin no cuadra con su SHA-256: error, sin pausas ni órdenes',
        () async {
      // Real (no ensayo): el sha solo se compara ahí. El fichero es lo de
      // menos; lo que cuenta es que NO coincide con el sha del respaldo.
      final r = _resp(tmp, shaFlash: 'a' * 64);
      final sef = _SeftoolRealFalso();
      final res = await _correr(ejecutor(r, sef));
      expect(res.errores.single, contains('NO cuadra con su SHA-256'));
      expect(res.pausas, isEmpty);
      expect(res.ordenes.any((l) => l.contains(' -a ')), isFalse);
    });

    test('64 MiB de 0xFF: error y no se pide ni una pausa', () async {
      final b = Uint8List(EjecutorRespaldo.tamanoFlash)..fillRange(0, EjecutorRespaldo.tamanoFlash, 0xFF);
      final r = _resp(tmp,
          conFlash: false, shaFlash: sha256.convert(b).toString());
      File(r.rutaFlash).writeAsBytesSync(b);
      // Real (no ensayo): la verificación del sha y del volcado solo corre ahí.
      final sef = _SeftoolRealFalso();
      final res = await _correr(ejecutor(r, sef));
      expect(res.errores.single, contains('no sirve para restaurar'));
      expect(res.errores.single, contains('0xFF'));
      expect(res.pausas, isEmpty);
    });
  });
}

/// seftool en ensayo cuyo `upload-anycid` termina diciendo que el CS loader no
/// arrancó sus servicios (el «error:29» de la escena). Solo emite una línea.
class _SeftoolSinFsx extends Seftool {
  _SeftoolSinFsx()
      : super(
            raiz: '/no/importa',
            puerto: '/dev/x',
            ensayo: true,
            identifyEnsayoStdout: _identify('52'));

  @override
  Stream<LineaSeftool> subirAnycid() async* {
    yield const LineaSeftool(
        'CSloader refused to start GDFS services, error:29');
  }
}

/// seftool "real" (no ensayo) que solo contesta el identify: lo justo para
/// llegar a la verificación del volcado.
class _SeftoolRealFalso extends Seftool {
  _SeftoolRealFalso() : super(raiz: '/no/importa', puerto: '/dev/x', ensayo: false);

  @override
  void exigirBinario() {}

  @override
  Future<InfoAparato> identify({void Function(LineaSeftool)? alVuelo}) async =>
      Seftool.leerIdentify(_identify('52'));
}
