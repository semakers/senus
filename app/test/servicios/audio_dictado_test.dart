// El audio antes de whisper.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:senus_app/servicios/audio_dictado.dart';

Float32List seno(double f, int hz, int n, {double a = 0.5}) {
  final x = Float32List(n);
  for (var i = 0; i < n; i++) {
    x[i] = a * math.sin(2 * math.pi * f * i / hz);
  }
  return x;
}

Uint8List aPcm(Float32List x) {
  final b = ByteData(x.length * 2);
  for (var i = 0; i < x.length; i++) {
    b.setInt16(i * 2, (x[i] * 32767).round(), Endian.little);
  }
  return b.buffer.asUint8List();
}

double dbfs(Float32List x) {
  var s = 0.0;
  for (final v in x) {
    s += v * v;
  }
  return 10 * math.log(s / x.length + 1e-20) / math.ln10;
}

void main() {
  test('8 kHz a 16 kHz: largo doble y el tono sale limpio (> 50 dB de SNR)', () {
    final x = seno(1000, 8000, 8000);
    final y = remuestrear(x, 8000, 16000);
    expect(y.length, 16000);
    final ideal = seno(1000, 16000, 16000);
    var ruido = 0.0, senal = 0.0;
    for (var i = 200; i < 15800; i++) {
      final d = y[i] - ideal[i];
      ruido += d * d;
      senal += ideal[i] * ideal[i];
    }
    expect(10 * math.log(senal / ruido) / math.ln10, greaterThan(50));
  });

  test('48 kHz a 16 kHz: lo que no cabe en 8 kHz de banda se va', () {
    final fuera = seno(12000, 48000, 48000);
    final y = remuestrear(fuera, 48000, 16000);
    expect(y.length, 16000);
    expect(dbfs(Float32List.sublistView(y, 100, 15900)), lessThan(-70));
    final dentro = seno(1000, 48000, 48000);
    final z = remuestrear(dentro, 48000, 16000);
    expect(dbfs(Float32List.sublistView(z, 100, 15900)), closeTo(dbfs(dentro), 0.2));
  });

  test('44,1 kHz (fracción racional larga): largo correcto', () {
    final y = remuestrear(seno(440, 44100, 44100), 44100, 16000);
    expect(y.length, 16000);
  });

  test('a 16 kHz no hace nada', () {
    final x = seno(1000, 16000, 100);
    expect(identical(remuestrear(x, 16000, 16000), x), isTrue);
  });

  test('voz baja (-50 dBFS): ganancia de +30 dB, el tope', () {
    final a = prepararAudio(aPcm(seno(1000, 8000, 8000, a: 0.003)), 8000);
    expect(a.gananciaDb, closeTo(30, 0.01));
    expect(dbfs(a.conGanancia) - dbfs(a.talCual), closeTo(30, 0.1));
  });

  test('el pico a -6 dBFS cuando la ganancia no llega al tope', () {
    final a = prepararAudio(aPcm(seno(1000, 8000, 8000, a: 0.1)), 8000);
    expect(a.gananciaDb, closeTo(14, 0.3));
  });

  test('audio fuerte: sin ganancia', () {
    final a = prepararAudio(aPcm(seno(1000, 8000, 8000, a: 0.9)), 8000);
    expect(a.gananciaDb, closeTo(0, 0.001));
  });

  test('quita la continua', () {
    final x = seno(1000, 8000, 8000, a: 0.1);
    for (var i = 0; i < x.length; i++) {
      x[i] += 0.2;
    }
    final a = prepararAudio(aPcm(x), 8000);
    final m = a.talCual.fold<double>(0, (s, v) => s + v) / a.talCual.length;
    expect(m.abs(), lessThan(1e-4));
  });

  test('sin audio', () {
    final a = prepararAudio(Uint8List(0), 8000);
    expect(a.talCual, isEmpty);
    expect(a.gananciaDb, 0);
  });

  test('juntar tramos en milisegundos, recortando lo que se sale', () {
    final x = Float32List(16000);
    for (var i = 0; i < x.length; i++) {
      x[i] = i.toDouble();
    }
    final y = juntarTramos(x, const [(0, 10), (100, 110), (995, 2000)]);
    expect(y.length, 160 + 160 + 80);
    expect(y[160], 1600);
    expect(y.last, 15999);
  });

  test('percentil como numpy', () {
    final x = Float32List.fromList([1, -2, 3, -4]);
    expect(percentilAbs(x, 50), closeTo(2.5, 1e-6));
    expect(percentilAbs(x, 100), 4);
  });
}
