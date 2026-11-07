// El audio del dictado, antes de whisper. El mismo camino que `a_16k` de
// bt/dictado/servicio.py: de PCM s16le a float a 16 kHz, sin continua, y una copia
// con ganancia automática. Pura Dart: va en un Isolate para no parar la interfaz.

import 'dart:math' as math;
import 'dart:typed_data';

const hzWhisper = 16000;

/// Pico a -6 dBFS. La voz por el micrófono del W580 llega a -50 dBFS rms.
const _picoObjetivo = 0.5;

class AudioPreparado {
  /// Tal cual: lo que mira el VAD.
  final Float32List talCual;

  /// Con ganancia: lo que escucha whisper.
  final Float32List conGanancia;

  final double gananciaDb;

  AudioPreparado(this.talCual, this.conGanancia, this.gananciaDb);
}

int _mcd(int a, int b) => b == 0 ? a : _mcd(b, a % b);

/// I0 de Bessel, para la ventana de Kaiser.
double _i0(double x) {
  var s = 1.0, t = 1.0;
  for (var k = 1; k < 40; k++) {
    t *= (x / (2 * k)) * (x / (2 * k));
    s += t;
    if (t < 1e-12 * s) break;
  }
  return s;
}

/// Remuestreo por sinc con ventana, en fase racional: una tabla de L fases y el
/// mismo retardo que el original (la salida empieza en la misma muestra).
Float32List remuestrear(Float32List x, int hzDe, int hzA) {
  if (hzDe == hzA) return x;
  final g = _mcd(hzDe, hzA);
  final l = hzA ~/ g, m = hzDe ~/ g;
  // Corte en el Nyquist del más lento; el 0,95 deja banda de transición.
  final corte = 0.95 * math.min(1.0, hzA / hzDe);
  const cruces = 16;
  final mitad = (cruces / corte).ceil();
  final ancho = 2 * mitad + 1;
  const beta = 9.0;
  final fases = Float64List(l * ancho);
  final i0b = _i0(beta);
  for (var f = 0; f < l; f++) {
    final fr = f / l;
    var suma = 0.0;
    for (var k = 0; k < ancho; k++) {
      final t = (k - mitad) - fr;
      final v = t / (mitad + 1);
      final w = v.abs() >= 1 ? 0.0 : _i0(beta * math.sqrt(1 - v * v)) / i0b;
      final a = corte * t * math.pi;
      final s = a.abs() < 1e-9 ? 1.0 : math.sin(a) / a;
      final h = corte * s * w;
      fases[f * ancho + k] = h;
      suma += h;
    }
    // ganancia 1 en continua en cada fase
    for (var k = 0; k < ancho; k++) {
      fases[f * ancho + k] /= suma;
    }
  }
  final n = (x.length * l / m).floor();
  final y = Float32List(n);
  for (var i = 0; i < n; i++) {
    final pos = i * m;
    final base = pos ~/ l;
    final f = pos % l;
    var s = 0.0;
    for (var k = 0; k < ancho; k++) {
      final j = base + k - mitad;
      if (j >= 0 && j < x.length) s += x[j] * fases[f * ancho + k];
    }
    y[i] = s;
  }
  return y;
}

/// El percentil [q] (0-100) de |x|, con interpolación lineal como numpy.
double percentilAbs(Float32List x, double q) {
  final a = Float32List(x.length);
  for (var i = 0; i < x.length; i++) {
    a[i] = x[i].abs();
  }
  a.sort();
  final pos = (a.length - 1) * q / 100;
  final i = pos.floor();
  final j = math.min(i + 1, a.length - 1);
  return a[i] + (a[j] - a[i]) * (pos - i);
}

/// PCM s16le mono a [hz] -> lo que necesitan el VAD y whisper.
AudioPreparado prepararAudio(Uint8List pcm, int hz, {double gananciaMaxDb = 30}) {
  final d = ByteData.sublistView(pcm);
  final n = pcm.length ~/ 2;
  final x = Float32List(n);
  for (var i = 0; i < n; i++) {
    x[i] = d.getInt16(i * 2, Endian.little) / 32768.0;
  }
  final y = remuestrear(x, hz, hzWhisper);
  if (y.isEmpty) return AudioPreparado(y, y, 0);
  var media = 0.0;
  for (var i = 0; i < y.length; i++) {
    media += y[i];
  }
  media /= y.length;
  final sinCont = Float32List(y.length);
  for (var i = 0; i < y.length; i++) {
    sinCont[i] = y[i] - media;
  }
  final pico = percentilAbs(sinCont, 99.9) + 1e-9;
  final tope = math.pow(10, gananciaMaxDb / 20).toDouble();
  final g = math.min(math.max(_picoObjetivo / pico, 1.0), tope);
  final con = Float32List(y.length);
  for (var i = 0; i < y.length; i++) {
    con[i] = sinCont[i] * g;
  }
  return AudioPreparado(sinCont, con, 20 * math.log(g) / math.ln10);
}

/// Junta los tramos de voz (en milisegundos sobre el audio a 16 kHz).
Float32List juntarTramos(Float32List audio, List<(int, int)> tramos) {
  final trozos = <Float32List>[];
  var total = 0;
  for (final (a, b) in tramos) {
    final i = math.min(a * 16, audio.length), j = math.min(b * 16, audio.length);
    if (j <= i) continue;
    final t = Float32List.sublistView(audio, i, j);
    trozos.add(t);
    total += t.length;
  }
  final out = Float32List(total);
  var o = 0;
  for (final t in trozos) {
    out.setAll(o, t);
    o += t.length;
  }
  return out;
}
