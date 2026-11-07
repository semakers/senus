// Un `recv` sobre un flujo: pide «hasta n bytes» y solo saca del origen lo que
// se va pidiendo. Pausa el origen cuando acumula [tope]: así una ventana cerrada
// del teléfono frena de verdad al servidor, y los canales se leen como en el
// puente de Python, una vuelta cada vez.

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

class LectorBytes {
  final int tope;
  final ListQueue<Uint8List> _cola = ListQueue();
  late final StreamSubscription<Uint8List> _sub;
  int _hay = 0;
  int _off = 0; // lo ya sacado del primero de la cola
  bool _fin = false;
  bool _pausado = false;
  Object? _error;
  StackTrace? _traza;
  Completer<void>? _espera;

  LectorBytes(Stream<Uint8List> origen, {this.tope = 64 * 1024}) {
    _sub = origen.listen(
      _dato,
      onError: (Object e, StackTrace s) {
        _error ??= e;
        _traza ??= s;
        _fin = true;
        _despertar();
      },
      onDone: () {
        _fin = true;
        _despertar();
      },
      cancelOnError: false,
    );
  }

  void _dato(Uint8List d) {
    if (d.isEmpty) return;
    _cola.add(d);
    _hay += d.length;
    if (_hay >= tope && !_pausado) {
      _pausado = true;
      _sub.pause();
    }
    _despertar();
  }

  void _despertar() {
    final c = _espera;
    _espera = null;
    if (c != null && !c.isCompleted) c.complete();
  }

  void _quizaReanudar() {
    if (_pausado && _hay < tope ~/ 2) {
      _pausado = false;
      _sub.resume();
    }
  }

  Future<void> _esperarAlgo(Duration? plazo) async {
    final fin = plazo == null ? null : DateTime.now().add(plazo);
    while (_hay == 0 && !_fin) {
      final c = _espera ??= Completer<void>();
      if (fin == null) {
        await c.future;
      } else {
        final queda = fin.difference(DateTime.now());
        if (queda <= Duration.zero) {
          throw TimeoutException('sin datos', plazo);
        }
        await c.future.timeout(queda);
      }
    }
  }

  /// Hasta [max] bytes. Vacío = se acabó. Un error del origen llega después de
  /// lo que ya estaba leído, como en un socket.
  Future<Uint8List> leer(int max, {Duration? plazo}) async {
    await _esperarAlgo(plazo);
    if (_hay == 0) {
      final e = _error;
      if (e != null) Error.throwWithStackTrace(e, _traza ?? StackTrace.current);
      return Uint8List(0);
    }
    final primero = _cola.first;
    final disponibleAqui = primero.length - _off;
    final Uint8List r;
    if (_off == 0 && disponibleAqui <= max) {
      r = primero;
      _cola.removeFirst();
    } else if (disponibleAqui <= max) {
      r = Uint8List.sublistView(primero, _off);
      _cola.removeFirst();
      _off = 0;
    } else {
      r = Uint8List.sublistView(primero, _off, _off + max);
      _off += max;
    }
    _hay -= r.length;
    _quizaReanudar();
    return r;
  }

  /// Hasta el `\n` incluido, o lo que quede al acabarse el origen.
  Future<Uint8List> leerLinea(int max, {Duration? plazo}) async {
    final out = BytesBuilder(copy: true);
    while (true) {
      await _esperarAlgo(plazo);
      if (_hay == 0) {
        final e = _error;
        if (e != null) {
          Error.throwWithStackTrace(e, _traza ?? StackTrace.current);
        }
        return out.takeBytes();
      }
      final primero = _cola.first;
      final i = primero.indexOf(10, _off);
      final fin = i < 0 ? primero.length : i + 1;
      out.add(Uint8List.sublistView(primero, _off, fin));
      _hay -= fin - _off;
      if (fin == primero.length) {
        _cola.removeFirst();
        _off = 0;
      } else {
        _off = fin;
      }
      _quizaReanudar();
      if (i >= 0) return out.takeBytes();
      if (out.length > max) throw const FormatException('línea demasiado larga');
    }
  }

  /// Deja de leer: quien estuviera esperando recibe «se acabó».
  void cancelar() {
    _fin = true;
    _cola.clear();
    _hay = 0;
    _off = 0;
    _despertar();
    unawaited(_sub.cancel());
  }
}
