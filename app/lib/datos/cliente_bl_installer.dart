// Cliente del BOOTLOADER INSTALLER de senew (VID:PID 1209:0003), en Dart.
//
// Es `senew-w580/herr/puente/pu_bl_installer.py` (el que grabó senew en
// el W580 bueno el 2026-10-30) traducido 1:1: la misma secuencia, los mismos
// vendor requests y los mismos plazos. Si uno cambia, cambia el otro.
//
//   INSTALADOR_INI [total]     declara el total para la barra del teléfono
//   WIPE                       borra el main: 9 bloques de 256 KiB (~11 s)
//   WRITE  main desde +0x400   4096 B por vuelta y CRC-32 de ese tramo (~19 s)
//   WRITE  región 0            la ÚLTIMA, y CRC-32 del main entero
//   WIPE_PROPIO [0x44140000]   borra el bloque del BL propio
//   WRITE_PROPIO bl → 0x44140000
//   LISTO                      pinta «Listo» en el teléfono
//   SALIR                      el BL salta al main nuevo
//
// LA REGIÓN 0, LA ÚLTIMA (bl.h, §6.2 del diseño; `op_write` no lo impone, así que
// el arreglo está solo aquí). Lleva los vectores: el BL salta al main si la
// primera palabra y el vector de reset cuadran. Grabada al final, un corte a
// medias deja el teléfono SIN vectores y el BL se queda en modo flasheo, donde
// SENUS lo recupera; grabada primero, el BL saltaría a un main a medio grabar.
//
// ORDEN DE SEGURIDAD (no cambiarlo): primero se graba y se VERIFICA el main; el
// BL propio solo se borra después. Si algo falla antes del WIPE_PROPIO, el
// installer sigue vivo en RAM del teléfono y basta reintentar. Entre el
// WIPE_PROPIO y el final de su WRITE (~0,1 s) el aparato no tiene bootloader
// en la NOR: un corte ahí lo deja sin arranque (ver §8 del documento técnico).
//
// El transporte es el de siempre ([TransporteBl]): libusb en producción, el
// socket de bridge_mock.py o un [TransporteBlFalso] en las pruebas.

import 'dart:async';
import 'dart:typed_data';

import '../mtp/transporte.dart' show TransporteError;
import 'transporte_bl.dart';

/// Algo salió mal hablando con el installer.
class InstaladorBlError implements Exception {
  final String motivo;
  final String? remedio;

  /// true si, cuando esto pasó, el teléfono podía estar SIN bootloader en la
  /// NOR (entre el WIPE_PROPIO y el final de su WRITE): la UI tiene que
  /// decirle a la persona que no desconecte nada y que reintente.
  final bool sinBootloader;

  /// true si el BL dejó de contestar: el estado de la grabación es desconocido
  /// y no se puede seguir por este camino.
  final bool sinRespuesta;
  const InstaladorBlError(this.motivo,
      {this.remedio, this.sinBootloader = false, this.sinRespuesta = false});
  @override
  String toString() => motivo;
}

/// Las etapas que la pantalla pinta (en este orden).
enum EtapaBl {
  borrarMain,
  grabarMain,
  verificarMain,
  grabarRegionCero,
  borrarPropio,
  grabarPropio,
  verificarPropio,
  cerrar,
}

String nombreEtapaBl(EtapaBl e) => switch (e) {
      EtapaBl.borrarMain => 'Borrando el main anterior',
      EtapaBl.grabarMain => 'Grabando senew',
      EtapaBl.verificarMain => 'Verificando senew (CRC-32)',
      EtapaBl.grabarRegionCero => 'Grabando los vectores de arranque',
      EtapaBl.borrarPropio => 'Preparando el bootloader',
      EtapaBl.grabarPropio => 'Grabando el bootloader',
      EtapaBl.verificarPropio => 'Verificando el bootloader (CRC-32)',
      EtapaBl.cerrar => 'Arrancando senew',
    };

/// `hecho`/`total` en bytes; `total == 0` si la etapa no tiene medida
/// (borrados, cierre).
typedef AlProgresoBl = void Function(EtapaBl etapa, int hecho, int total);

/// Respuesta de `BL_R_ID` (64 B): `magia=SNBL v1 entrada=2 build=Oct`.
class InfoBl {
  final String magia;
  final int version;
  final int entrada;
  final String build;
  const InfoBl(this.magia, this.version, this.entrada, this.build);

  /// `entrada == 2`: el BL arrancó sin main (primera grabación).
  bool get sinMain => entrada == 2;

  @override
  String toString() => 'magia=$magia v$version entrada=$entrada'
      '${sinMain ? ' (sin main)' : entrada == 1 ? ' (bandera)' : ' (?)'} '
      'build=$build';
}

/// Respuesta de `BL_R_RES` (32 B).
class RespBl {
  final int estado;
  final int seq;
  final int op;
  final int codigo;
  final int r0;
  final int r1;
  const RespBl(this.estado, this.seq, this.op, this.codigo, this.r0, this.r1);

  static RespBl leer(Uint8List b) {
    if (b.length < 16) {
      throw InstaladorBlError(
          'BL_R_RES devolvió ${b.length} B (se esperaban 32).');
    }
    final v = ByteData.sublistView(b);
    return RespBl(
      v.getUint8(0),
      v.getUint8(1),
      v.getUint16(2, Endian.little),
      v.getInt32(4, Endian.little),
      v.getUint32(8, Endian.little),
      v.getUint32(12, Endian.little),
    );
  }
}

class ClienteBlInstaller {
  final TransporteBl bl;

  /// Cada cuánto se lee `BL_R_RES` mientras el BL ejecuta (pu_bl_installer.py:
  /// 50 ms). Las pruebas lo bajan.
  final Duration sondeo;

  /// Plazos de pu_bl_installer.py.
  final Duration plazoBorrado;
  final Duration plazoEscritura;

  /// Plazo de cada PUT. Un PUT puede quedarse sin su estado si el dato entra
  /// antes de que el BL procese el SETUP (`bl_usb.c`): medido en el emulador,
  /// nunca visto en silicio. Se repite una vez: escribe en `bl_buf` por
  /// desplazamiento, así que repetirlo no cambia nada.
  final Duration plazoPut;

  int _seq = 1;

  ClienteBlInstaller(
    this.bl, {
    this.sondeo = const Duration(milliseconds: 50),
    this.plazoBorrado = const Duration(seconds: 120),
    this.plazoEscritura = const Duration(seconds: 60),
    this.plazoPut = const Duration(milliseconds: 2500),
  });

  // ---------------------------------------------------------------------- //

  /// `BL_R_ID`. Se niega si lo que contesta no es el BL de senew.
  Future<InfoBl> info() async {
    final raw = await bl.controlIn(blRId, 0, 0, 64);
    if (raw.length < 50) {
      throw InstaladorBlError('BL_R_ID devolvió ${raw.length} B (se esperaban 64).',
          remedio: 'Lo que contesta en 1209:0003 no parece el BL de senew.');
    }
    final v = ByteData.sublistView(raw);
    final magia = String.fromCharCodes(raw.sublist(0, 4));
    if (magia != 'SNBL') {
      throw InstaladorBlError(
        'El dispositivo 1209:0003 no dice «SNBL» sino «$magia».',
        remedio: 'No se escribió nada. Desconecta el cable y vuelve a empezar.',
      );
    }
    final fin = raw.sublist(48, raw.length < 64 ? raw.length : 64);
    final cero = fin.indexOf(0);
    final build = String.fromCharCodes(cero < 0 ? fin : fin.sublist(0, cero));
    return InfoBl(magia, v.getUint16(4, Endian.little),
        v.getUint16(6, Endian.little), build);
  }

  /// La instalación completa (`pu_bl_installer.instalar`). `main` va a
  /// 0x44180000 y `blClasico` a 0x44140000. Los dos se rellenan con 0xFF hasta
  /// un múltiplo de [blRegion], como el original.
  Future<void> instalar({
    required Uint8List main,
    required Uint8List blClasico,
    AlProgresoBl? alProgreso,
    void Function(String linea)? alLog,
  }) async {
    void log(String s) => alLog?.call(s);
    void prog(EtapaBl e, int h, int t) => alProgreso?.call(e, h, t);

    final i = await info();
    log('BL: $i');

    final mainR = _rellenar(main);
    final blR = _rellenar(blClasico);
    if (mainR.isEmpty || mainR.length > blMainFin - blMainIni) {
      throw InstaladorBlError(
          'El main mide ${mainR.length} B y la zona es de ${blMainFin - blMainIni} B.');
    }
    if (blR.isEmpty || blR.length > blBloque) {
      throw InstaladorBlError(
          'El BL mide ${blR.length} B y solo cabe un bloque de $blBloque B.');
    }
    final total = mainR.length + blR.length;
    log('total declarado: $total B');
    await _go(blOpInstaladorIni, [total]);

    // 1) main: borrar, grabar, verificar. El BL propio NO se toca todavía.
    prog(EtapaBl.borrarMain, 0, 0);
    log('wipe main: ${(blMainFin - blMainIni) ~/ blBloque} bloques…');
    final t0 = DateTime.now();
    final w = await _go(blOpWipe, const [], plazo: plazoBorrado);
    log('  ${w.r0} bloques borrados en '
        '${DateTime.now().difference(t0).inMilliseconds / 1000} s');

    await grabarRestoMain(mainR, alProgreso: alProgreso, alLog: alLog);
    await grabarRegionCero(mainR,
        bytesCrc: mainR.length,
        crcEsperado: crc32DeDatos(mainR),
        alProgreso: alProgreso,
        alLog: alLog);

    // 2) BL: solo ahora. Mismo orden que el cliente en Python.
    prog(EtapaBl.borrarPropio, 0, 0);
    log('wipe propio: bloque de 256 KiB en '
        '${blPropioIni.toRadixString(16).padLeft(8, '0')}…');
    await _go(blOpWipePropio, [blPropioIni], plazo: plazoBorrado);
    await _grabar(blPropioIni, blR,
        op: blOpWritePropio,
        etapa: EtapaBl.grabarPropio,
        etapaCrc: EtapaBl.verificarPropio,
        etiqueta: 'BL definitivo',
        peligroso: true,
        prog: prog,
        log: log);

    await _go(blOpListo, const []);
    log('instalación lista; SALIR → el BL salta al main nuevo.');
    prog(EtapaBl.cerrar, 0, 0);
    await _salir();
  }

  // ---------------------------------------------------------------------- //
  // Piezas de la actualización (§6.1 del diseño): cada una es un paso.

  /// `WIPE`: los 9 bloques del main, el de MAIN_INI primero. Devuelve cuántos.
  Future<int> borrarMain({AlProgresoBl? alProgreso}) async {
    alProgreso?.call(EtapaBl.borrarMain, 0, 0);
    final r = await _go(blOpWipe, const [], plazo: plazoBorrado);
    return r.r0;
  }

  /// Paso 9: `WRITE` desde `0x400` hasta el final y CRC de ese tramo. La región
  /// 0 sigue en blanco: sin vectores, un corte deja el teléfono en el BL.
  /// [datos] ya va rellenado a un múltiplo de [blRegion].
  Future<void> grabarRestoMain(Uint8List datos,
      {AlProgresoBl? alProgreso, void Function(String)? alLog}) async {
    void prog(EtapaBl e, int h, int t) => alProgreso?.call(e, h, t);
    if (datos.length % blRegion != 0 || datos.length < blRegion) {
      throw InstaladorBlError(
          'El main mide ${datos.length} B: no es un múltiplo de $blRegion.');
    }
    alLog?.call('grabar main: ${datos.length - blRegion} B desde '
        '${_h8(blMainIni + blRegion)}; la región 0 va al final');
    final t0 = DateTime.now();
    await _escribirTramo(blMainIni, datos, blRegion, datos.length,
        op: blOpWrite,
        etapa: EtapaBl.grabarMain,
        peligroso: false,
        prog: prog);
    if (datos.length == blRegion) return; // no hay tramo que comprobar
    prog(EtapaBl.verificarMain, 0, 0);
    final resto = Uint8List.sublistView(datos, blRegion);
    final r = await _go(blOpCrc, [blMainIni + blRegion, resto.length]);
    final esperado = crc32DeDatos(resto);
    if (r.r0 != esperado) {
      throw InstaladorBlError(
        'CRC mal en el main: aparato=${_h8(r.r0)} esperado=${_h8(esperado)}.',
        remedio: 'Los vectores no se han grabado: el teléfono sigue en el BL. '
            'Reintenta con el cable puesto.',
      );
    }
    alLog?.call('  CRC ${_h8(r.r0)} del tramo coincide '
        '(${DateTime.now().difference(t0).inMilliseconds / 1000} s)');
  }

  /// Paso 10: `WRITE` de la región 0 y CRC del main entero. [bytesCrc] y
  /// [crcEsperado] son los del manifiesto: los bytes reales, sin relleno.
  Future<void> grabarRegionCero(Uint8List datos,
      {required int bytesCrc,
      required int crcEsperado,
      AlProgresoBl? alProgreso,
      void Function(String)? alLog}) async {
    void prog(EtapaBl e, int h, int t) => alProgreso?.call(e, h, t);
    prog(EtapaBl.grabarRegionCero, 0, blRegion);
    await _put(datos, 0, blRegion);
    await _go(blOpWrite, [blMainIni, blRegion], plazo: plazoEscritura);
    prog(EtapaBl.grabarRegionCero, blRegion, blRegion);
    prog(EtapaBl.verificarMain, 0, 0);
    final r = await _go(blOpCrc, [blMainIni, bytesCrc]);
    if (r.r0 != crcEsperado) {
      throw InstaladorBlError(
        'CRC mal en el main entero: aparato=${_h8(r.r0)} '
        'esperado=${_h8(crcEsperado)}.',
        remedio: 'Hay que borrar y grabar otra vez: los vectores ya están.',
      );
    }
    alLog?.call('  CRC ${_h8(r.r0)} del main entero coincide');
  }

  /// `BL_R_GET`: lee la NOR de 64 en 64 (nivel 0: un paquete del EP0).
  Future<Uint8List> leerNor(int dir, int n,
      {void Function(int hecho, int total)? alProgreso}) async {
    final out = Uint8List(n);
    var off = 0;
    while (off < n) {
      final k = n - off < 64 ? n - off : 64;
      final a = dir + off;
      final d = await bl.controlIn(blRGet, a & 0xFFFF, (a >> 16) & 0xFFFF, k);
      if (d.length != k) {
        throw InstaladorBlError('BL_R_GET devolvió ${d.length} B de $k.');
      }
      out.setRange(off, off + k, d);
      off += k;
      if (off % 0x4000 == 0) {
        alProgreso?.call(off, n);
        await Future<void>.delayed(Duration.zero);
      }
    }
    alProgreso?.call(n, n);
    return out;
  }

  /// `BL_OP_CRC` de una zona.
  Future<int> crcNor(int dir, int n) async =>
      (await _go(blOpCrc, [dir, n])).r0;

  /// `SALIR`: el BL quita la bandera y vuelve a entrar por su reset.
  Future<void> salir() => _salir();

  // ---------------------------------------------------------------------- //

  Uint8List _rellenar(Uint8List d) => rellenarARegion(d);

  /// Rellena con 0xFF hasta un múltiplo de [blRegion].
  static Uint8List rellenarARegion(Uint8List d) {
    final mod = d.length % blRegion;
    if (mod == 0) return d;
    final n = d.length + (blRegion - mod);
    return Uint8List(n)
      ..setRange(0, d.length, d)
      ..fillRange(d.length, n, 0xFF);
  }

  Future<void> _grabar(
    int dirBase,
    Uint8List datos, {
    required int op,
    required EtapaBl etapa,
    required EtapaBl etapaCrc,
    required String etiqueta,
    required bool peligroso,
    required void Function(EtapaBl, int, int) prog,
    required void Function(String) log,
  }) async {
    log('grabar $etiqueta: ${datos.length} B → '
        '${dirBase.toRadixString(16).padLeft(8, '0')} '
        '(${op == blOpWritePropio ? 'propio' : 'main'})');
    final t0 = DateTime.now();
    await _escribirTramo(dirBase, datos, 0, datos.length,
        op: op, etapa: etapa, peligroso: peligroso, prog: prog);
    prog(etapaCrc, 0, 0);
    final r = await _go(blOpCrc, [dirBase, datos.length],
        sinBootloader: peligroso);
    final esperado = crc32DeDatos(datos);
    if (r.r0 != esperado) {
      throw InstaladorBlError(
        'CRC mal en $etiqueta: aparato=${_h8(r.r0)} esperado=${_h8(esperado)}.',
        remedio: peligroso
            ? 'NO apagues ni desconectes el teléfono: el BL propio puede estar '
                'a medias en la NOR. El installer sigue vivo en su RAM: '
                'reintenta la instalación con el cable puesto.'
            : 'El BL propio NO se ha tocado. El installer sigue vivo en la '
                'RAM del teléfono: reintenta la instalación con el cable '
                'puesto.',
        sinBootloader: peligroso,
      );
    }
    log('  CRC ${_h8(r.r0)} coincide '
        '(${DateTime.now().difference(t0).inMilliseconds / 1000} s)');
  }

  /// `WRITE` de `datos[desde..hasta)` a `dirBase + desde`, de [blBufTam] en
  /// [blBufTam]. El progreso cuenta desde 0.
  Future<void> _escribirTramo(
    int dirBase,
    Uint8List datos,
    int desde,
    int hasta, {
    required int op,
    required EtapaBl etapa,
    required bool peligroso,
    required void Function(EtapaBl, int, int) prog,
  }) async {
    final total = hasta - desde;
    var off = desde;
    prog(etapa, 0, total);
    while (off < hasta) {
      var n = hasta - off < blBufTam ? hasta - off : blBufTam;
      n = (n ~/ blRegion) * blRegion;
      await _put(datos, off, n);
      await _go(op, [dirBase + off, n],
          plazo: plazoEscritura, sinBootloader: peligroso);
      off += n;
      prog(etapa, off - desde, total);
      // Ceder el turno al bucle de eventos: sin esto los ~27 000 control
      // transfers de un main seguidos no dejan pintar ni un fotograma.
      await Future<void>.delayed(Duration.zero);
    }
  }

  static String _h8(int v) => v.toRadixString(16).padLeft(8, '0');

  /// `put()`: el buffer del BL se llena a 64 B por paquete de EP0. Si un PUT
  /// no acaba en [plazoPut] se repite UNA vez; si vuelve a fallar, es un corte.
  ///
  /// La pausa inicial evita una carrera del EP0 del BL, que no se puede cambiar:
  /// un PUT pegado al RES anterior se queda sin estado. Medido en el emulador con
  /// el BL exacto: 83 de 3000 sin pausa, 0 de 20 000 con 0,5 ms. Entre dos PUT no
  /// pasa (0 de 23 000). Va antes de cada tanda: solo la primera sigue a un RES.
  Future<void> _put(Uint8List datos, int desde, int n) async {
    await Future<void>.delayed(const Duration(milliseconds: 1));
    for (var i = 0; i < n; i += 64) {
      final hasta = i + 64 <= n ? i + 64 : n;
      final trozo = Uint8List.sublistView(datos, desde + i, desde + hasta);
      try {
        await bl.controlOut(blRPut, i, 0, trozo, timeout: plazoPut);
      } on TransporteError {
        await bl.controlOut(blRPut, i, 0, trozo, timeout: plazoPut);
      }
    }
  }

  Future<RespBl> _go(int op, List<int> args,
      {Duration plazo = const Duration(seconds: 60),
      bool sinBootloader = false}) async {
    final seq = _seq & 0xFF;
    _seq = (_seq + 1) & 0xFF;
    for (var i = 0; i < args.length && i < 4; i++) {
      final a = args[i] & 0xFFFFFFFF;
      await bl.controlOut(
          blRArg0 + i, a & 0xFFFF, (a >> 16) & 0xFFFF, Uint8List(0));
    }
    await bl.controlOut(blRGo, (op & 0xFF) | (seq << 8), 0, Uint8List(0));
    final t0 = DateTime.now();
    while (DateTime.now().difference(t0) < plazo) {
      final r = RespBl.leer(await bl.controlIn(blRRes, 0, 0, 32));
      if (r.estado == blStHecho && r.seq == seq) {
        if (r.codigo != 0) {
          throw InstaladorBlError(
            'op 0x${op.toRadixString(16)} falló: codigo=${r.codigo} '
            'r0=${_h8(r.r0)} r1=${_h8(r.r1)}.',
            remedio: 'Mira el log del BL (plat/bl/bl_nor.c) para descifrar el '
                'código. El installer sigue vivo: reintenta con el cable '
                'puesto.',
            sinBootloader: sinBootloader,
          );
        }
        return r;
      }
      await Future<void>.delayed(sondeo);
    }
    throw InstaladorBlError(
      'op 0x${op.toRadixString(16)}: el BL no contestó en ${plazo.inSeconds} s.',
      remedio: 'Probablemente el aparato quedó colgado: desconecta y vuelve a '
          'enchufar.',
      sinBootloader: sinBootloader,
      sinRespuesta: true,
    );
  }

  /// SALIR: el BL contesta HECHO y se reinicia. Si el aparato baja del bus
  /// antes de que se lea el RES, el transporte falla; eso aquí es lo esperado
  /// (el que dice si arrancó senew es quien espera a 1209:0001).
  Future<void> _salir() async {
    try {
      await _go(blOpSalir, const [], plazo: const Duration(seconds: 5));
    } on TransporteError {
      // reinicio antes de contestar
    }
  }
}
