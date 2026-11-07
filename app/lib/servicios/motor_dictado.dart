// El motor del dictado: el ayudante `senus_dictado` (tool/ayudante_dictado) corre
// en un proceso aparte, y aquí se le habla por stdin/stdout. Va aparte por lo
// medido el 1-nov: ggml aborta el proceso entero cuando algo le falla, y aborta
// también al salir si queda memoria de Metal viva. Dentro de SENUS, eso cerraría la
// app. Con stdin cerrado el ayudante sale solo: no quedan huérfanos.
//
// Se arranca con la primera petición (carga en ~0,3 s) y se apaga tras un rato sin
// uso: así los ~550 MB solo se gastan mientras se dicta.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'filtro_dictado.dart';

abstract class MotorDictado {
  /// Tramos de voz en milisegundos, sobre el audio a 16 kHz.
  Future<List<(int, int)>> tramosDeVoz(Float32List audio);

  Future<List<SegmentoWhisper>> transcribir(Float32List audio, String idioma);

  /// Suelta la memoria. Volverá a cargar con la siguiente petición.
  Future<void> apagar();

  /// Para /salud.
  String get descripcion;
}

class FalloMotor implements Exception {
  final String motivo;
  FalloMotor(this.motivo);

  @override
  String toString() => motivo;
}

/// Las rutas ya verificadas. Se piden en CADA arranque del ayudante: quien las da
/// ([GestorComponentes.rutaVerificada]) lanza si la huella no casa, y entonces el
/// proceso no llega a existir.
class RutasMotor {
  final String ayudante, modelo, vad;
  const RutasMotor(this.ayudante, this.modelo, this.vad);
}

typedef ObtenerRutasMotor = Future<RutasMotor> Function();

class MotorAyudante implements MotorDictado {
  final ObtenerRutasMotor rutas;
  final Duration plazoCarga;
  final Duration plazoPeticion;
  final Duration apagarTras;
  final List<String> argumentos;

  Process? _p;
  StreamIterator<String>? _lineas;
  Future<void>? _arrancando;
  Timer? _apagado;
  String _version = '';
  int _cargaMs = 0;
  int _peticiones = 0;
  int _enCurso = 0;

  MotorAyudante({
    required this.rutas,
    this.plazoCarga = const Duration(seconds: 60),
    this.plazoPeticion = const Duration(seconds: 60),
    this.apagarTras = const Duration(minutes: 5),
    this.argumentos = const ['--hilos', '4', '--ventana', '750'],
  });

  @override
  String get descripcion => _p == null ? 'en reposo' : 'cargado (whisper.cpp $_version, $_cargaMs ms)';

  Future<void> _asegurar() => _arrancando ??= _arrancar().whenComplete(() => _arrancando = null);

  Future<void> _arrancar() async {
    if (_p != null) return;
    final r = await rutas(); // lanza NoVerificado si algo no casa
    final p = await Process.start(r.ayudante, ['--modelo', r.modelo, '--vad', r.vad, ...argumentos]);
    unawaited(p.stderr.drain<void>().catchError((Object _) {}));
    final lineas = StreamIterator<String>(
        p.stdout.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()));
    try {
      if (!await lineas.moveNext().timeout(plazoCarga)) throw FalloMotor('el ayudante no arrancó');
      final hola = jsonDecode(lineas.current) as Map<String, dynamic>;
      if (hola['ok'] != true) throw FalloMotor('el ayudante dice: ${hola['fallo']}');
      _version = '${hola['version']}';
      _cargaMs = (hola['carga_ms'] as num).toInt();
    } on Object {
      p.kill(ProcessSignal.sigkill);
      await lineas.cancel();
      rethrow;
    }
    _p = p;
    _lineas = lineas;
    unawaited(p.exitCode.then((_) {
      if (identical(_p, p)) _soltar();
    }));
  }

  /// Arranca el ayudante y lo apaga: deja hecha la compilación de los sombreadores.
  /// Si entre tanto llegó una petición, el ayudante se queda: es suyo.
  Future<void> precalentar() async {
    final antes = _peticiones;
    await _asegurar();
    if (_peticiones == antes && _enCurso == 0) await apagar();
  }

  void _soltar() {
    _p = null;
    final l = _lineas;
    _lineas = null;
    unawaited(l?.cancel());
    _apagado?.cancel();
  }

  Future<Map<String, dynamic>> _pedir(int op, String idioma, Float32List x) async {
    _peticiones++;
    _enCurso++;
    try {
      return await _hablar(op, idioma, x);
    } finally {
      _enCurso--;
    }
  }

  Future<Map<String, dynamic>> _hablar(int op, String idioma, Float32List x) async {
    await _asegurar();
    _apagado?.cancel();
    final p = _p, l = _lineas;
    if (p == null || l == null) throw FalloMotor('el ayudante se fue');
    final cab = Uint8List(12);
    cab[0] = 0x57; // W
    cab[1] = 0x35; // 5
    cab[2] = op;
    final id = ascii.encode(idioma);
    cab.setRange(4, 4 + id.length.clamp(0, 4), id);
    ByteData.sublistView(cab).setUint32(8, x.length, Endian.little);
    try {
      p.stdin.add(cab);
      p.stdin.add(Uint8List.sublistView(x));
      await p.stdin.flush();
      if (!await l.moveNext().timeout(plazoPeticion)) throw FalloMotor('el ayudante se cayó');
      final r = jsonDecode(l.current) as Map<String, dynamic>;
      if (r['ok'] != true) throw FalloMotor('el ayudante dice: ${r['fallo']}');
      return r;
    } on Object {
      // Tras un plazo agotado la siguiente línea ya no sería de esta petición.
      p.kill(ProcessSignal.sigkill);
      _soltar();
      rethrow;
    } finally {
      _armarApagado();
    }
  }

  void _armarApagado() {
    _apagado?.cancel();
    _apagado = Timer(apagarTras, () => unawaited(apagar()));
  }

  @override
  Future<List<(int, int)>> tramosDeVoz(Float32List audio) async {
    final r = await _pedir(1, '', audio);
    return [
      for (final t in (r['tramos'] as List).cast<List>()) ((t[0] as num).toInt(), (t[1] as num).toInt()),
    ];
  }

  @override
  Future<List<SegmentoWhisper>> transcribir(Float32List audio, String idioma) async {
    final r = await _pedir(2, idioma, audio);
    return [
      for (final s in (r['segmentos'] as List).cast<Map>())
        SegmentoWhisper(s['t'] as String, (s['ns'] as num).toDouble(), (s['lp'] as num).toDouble()),
    ];
  }

  @override
  Future<void> apagar() async {
    final p = _p;
    _soltar();
    if (p == null) return;
    try {
      p.stdin.add(Uint8List(12)
        ..[0] = 0x57
        ..[1] = 0x35);
      await p.stdin.close();
    } on Object {
      // ya se había ido
    }
    final salio = await p.exitCode.timeout(const Duration(seconds: 3), onTimeout: () => -1);
    if (salio == -1) p.kill(ProcessSignal.sigkill);
  }
}
