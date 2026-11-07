// El servicio de dictado en 127.0.0.1:8581: el mismo contrato que
// bt/dictado/servicio.py (docs/servicios_dictado_musica.md §1). Solo cambia el motor.

import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:typed_data';

import 'audio_dictado.dart';
import 'filtro_dictado.dart';
import 'letra_telefono.dart';
import 'motor_dictado.dart';
import 'servidor_local.dart';

const puertoDictado = 8581;

/// Un cuerpo que no acaba de llegar.
const _plazoLectura = Duration(seconds: 30);

/// Esperando turno. El teléfono espera la respuesta 30 s: más no sirve.
const _plazoCola = Duration(seconds: 20);

const _muyCortoS = 0.3;

class _Fallo implements Exception {
  final int codigo;
  final String texto;
  _Fallo(this.codigo, this.texto);

  @override
  String toString() => texto;
}

class _Ocupado implements Exception {
  final String texto;
  _Ocupado(this.texto);

  @override
  String toString() => texto;
}

class ResultadoDictado {
  String texto = '';
  String? motivo;
  int audioMs = 0, vozMs = 0, ms = 0;
  double gananciaDb = 0;
  final segmentos = <(String, String?, double, double, double)>[];
}

class ServicioDictado {
  final MotorDictado motor;
  final LetraTelefono letra;
  final String nombreModelo;
  final int maxS;
  final int cola;
  final double gananciaMaxDb;
  final Duration plazoCola;
  final void Function(String)? registro;

  late final ServidorLocal servidor;
  final _filtro = Filtro();

  /// Las peticiones van de una en una: whisper ya usa varios núcleos.
  final _esperando = Queue<Completer<void>>();
  bool _ocupado = false;
  int _enCurso = 0;

  final _cuentas = <String, int>{};
  final _ms = Queue<int>();
  final _t0 = DateTime.now();

  ServicioDictado({
    required this.motor,
    required this.letra,
    required this.nombreModelo,
    int puerto = puertoDictado,
    this.maxS = 60,
    this.cola = 4,
    this.gananciaMaxDb = 30,
    this.plazoCola = _plazoCola,
    this.registro,
  }) {
    servidor = ServidorLocal(puerto: puerto, nombre: 'senus-dictado/1', manejador: _atender, registro: registro);
  }

  Future<void> arrancar() => servidor.arrancar();

  Future<void> parar() async {
    await servidor.parar();
    await motor.apagar();
  }

  void _contar(String k) => _cuentas[k] = (_cuentas[k] ?? 0) + 1;

  Future<void> _tomarTurno() async {
    if (_enCurso >= 1 + cola) {
      _contar('ocupado');
      throw _Ocupado('cola llena ($cola esperando)');
    }
    _enCurso++;
    if (!_ocupado) {
      _ocupado = true;
      return;
    }
    final c = Completer<void>();
    _esperando.add(c);
    try {
      await c.future.timeout(plazoCola);
    } on TimeoutException {
      _esperando.remove(c);
      _enCurso--;
      _contar('ocupado');
      throw _Ocupado('el turno no llegó en ${plazoCola.inSeconds} s');
    }
  }

  void _soltarTurno() {
    _enCurso--;
    if (_esperando.isEmpty) {
      _ocupado = false;
    } else {
      _esperando.removeFirst().complete();
    }
  }

  /// Audio -> texto crudo, sin transliterar.
  Future<ResultadoDictado> reconocer(Uint8List pcm, int hz, String idioma) async {
    final r = ResultadoDictado()..audioMs = (pcm.length ~/ 2) * 1000 ~/ hz;
    final maxDb = gananciaMaxDb;
    final a = await Isolate.run(() => prepararAudio(pcm, hz, gananciaMaxDb: maxDb));
    r.gananciaDb = a.gananciaDb;
    final reloj = Stopwatch()..start();
    if (a.conGanancia.length < _muyCortoS * hzWhisper) {
      r.motivo = 'muy-corto';
      return r;
    }
    // EL VAD CON EL AUDIO TAL CUAL, whisper con la ganancia [medido 28-oct]: el
    // Silero encuentra la voz a cualquier nivel en la grabación real del W580, pero
    // con voz sintética limpia la pierde si se le sube.
    final tramos = await motor.tramosDeVoz(a.talCual);
    r.vozMs = tramos.fold(0, (s, t) => s + t.$2 - t.$1);
    if (tramos.isEmpty) {
      r.motivo = 'sin-voz';
      r.ms = reloj.elapsedMilliseconds;
      return r;
    }
    final voz = juntarTramos(a.conGanancia, tramos);
    final segmentos = await motor.transcribir(voz, idioma);
    final partes = <String>[];
    final motivos = <String?>[];
    for (final s in segmentos) {
      final (t, m) = _filtro.segmento(s);
      r.segmentos.add((t, m, s.noHabla, s.logProb, s.compresion));
      motivos.add(m);
      if (m == null) partes.add(t);
    }
    r.ms = reloj.elapsedMilliseconds;
    r.texto = partes.join(' ').split(RegExp(r'\s+')).where((x) => x.isNotEmpty).join(' ');
    if (r.texto.isEmpty) {
      r.motivo = motivos.isEmpty
          ? 'sin-voz'
          : motivos.contains('alucinacion')
              ? 'alucinacion'
              : (motivos.first != 'vacio' ? motivos.first : 'sin-voz');
    }
    return r;
  }

  String estado() {
    final ms = _ms.toList()..sort();
    final b = StringBuffer('W5DIC 1\tBIEN\t$nombreModelo\n')
      ..write('senus-dictado: modelo $nombreModelo, motor ${motor.descripcion}; ')
      ..write('en marcha desde hace ${DateTime.now().difference(_t0).inSeconds} s\n')
      ..write('en curso: $_enCurso; cola: $cola como mucho\n')
      ..write('cuentas: $_cuentas\n');
    if (ms.isNotEmpty) b.write('ms (las últimas ${ms.length}): mediana ${ms[ms.length ~/ 2]}, máximo ${ms.last}\n');
    return b.toString();
  }

  Future<Uint8List> _cuerpo(PeticionLocal pet, int hz) async {
    final cl = pet.cabecera('Content-Length');
    if (cl == null || !RegExp(r'^\d+$').hasMatch(cl.trim())) {
      throw _Fallo(411, 'hace falta Content-Length (sin trozos: chunked no)');
    }
    final n = int.parse(cl.trim());
    if (n == 0) throw _Fallo(400, 'cuerpo vacío: va el PCM (s16le mono)');
    final tope = maxS * hz * 2;
    if (n > tope) {
      await pet.descartar(n < 4 * maxS * 48000 * 2 ? n : 4 * maxS * 48000 * 2, _plazoLectura);
      throw _Fallo(413, 'cuerpo de $n B: como mucho $tope B ($maxS s de audio a $hz Hz)');
    }
    final Uint8List b;
    try {
      b = await pet.leerCuerpo(n, _plazoLectura);
    } on CuerpoCortado catch (e) {
      throw _Fallo(400, 'el cuerpo se cortó en ${e.recibidos} de $n B');
    }
    if (n.isOdd) throw _Fallo(400, 'cuerpo de $n B, impar: el PCM de 16 bits son bytes pares');
    return b;
  }

  Future<void> _atender(PeticionLocal pet, RespuestaLocal res) async {
    if (pet.metodo == 'GET') {
      if (pet.ruta == '/salud' || pet.ruta == '/estado') {
        await res.responder(200, estado());
      } else {
        await res.responder(404, 'no existe: GET ${pet.ruta} (POST /dictar, GET /salud)\n');
      }
      return;
    }
    await _post(pet, res);
  }

  Future<void> _post(PeticionLocal pet, RespuestaLocal res) async {
    final reloj = Stopwatch()..start();
    var enTurno = false;
    try {
      if (pet.ruta != '/dictar' && pet.ruta != '/depurar') {
        await pet.descartar(int.tryParse(pet.cabecera('Content-Length') ?? '') ?? 0, _plazoLectura);
        throw _Fallo(404, 'no existe: POST ${pet.ruta} (POST /dictar)');
      }
      final hz = int.tryParse(pet.consulta['hz'] ?? '8000');
      final maxPedido = int.tryParse(pet.consulta['max'] ?? '1000');
      if (hz == null || maxPedido == null) throw _Fallo(400, 'hz y max son números');
      final idioma = (pet.consulta['idioma'] ?? 'es').trim().toLowerCase();
      if (hz < 4000 || hz > 48000) throw _Fallo(400, 'hz=$hz: entre 4000 y 48000');
      if (!idiomasWhisper.contains(idioma)) {
        throw _Fallo(400, 'idioma «${idioma.length > 20 ? idioma.substring(0, 20) : idioma}»: no lo conoce whisper (es, en, …)');
      }
      final maxB = maxPedido.clamp(16, 4000);
      final pcm = await _cuerpo(pet, hz);
      final tCuerpo = reloj.elapsedMilliseconds;
      await _tomarTurno();
      enTurno = true;
      final tTurno = reloj.elapsedMilliseconds;
      final r = await reconocer(pcm, hz, idioma);
      _soltarTurno();
      enTurno = false;
      final ms = reloj.elapsedMilliseconds - tCuerpo, colaMs = tTurno - tCuerpo;
      final texto = r.texto.isEmpty ? '' : letra.para(r.texto, maxB);
      final cab = <(String, String)>[
        ('X-Dictado-Ms', '$ms'),
        ('X-Dictado-Cola-Ms', '$colaMs'),
        ('X-Dictado-Audio-Ms', '${r.audioMs}'),
        ('X-Dictado-Voz-Ms', '${r.vozMs}'),
        ('X-Dictado-Modelo', nombreModelo),
      ];
      if (texto.isEmpty) cab.add(('X-Dictado-Motivo', r.motivo ?? 'sin-voz'));
      _contar('peticiones');
      _contar(texto.isEmpty ? 'vacias-${r.motivo ?? 'sin-voz'}' : 'con-texto');
      _ms.add(ms);
      if (_ms.length > 100) _ms.removeFirst();
      if (pet.ruta == '/depurar') {
        final l = [
          'crudo: ${r.texto}',
          'telefono: $texto',
          'audio ${r.audioMs} ms, voz ${r.vozMs} ms, ganancia ${r.gananciaDb.toStringAsFixed(1)} dB, '
              'whisper ${r.ms} ms, total $ms ms (cola $colaMs)',
          for (final (t, m, ns, lp, cr) in r.segmentos)
            'segmento: ${m ?? 'BIEN'}\t$t\tno_speech ${ns.toStringAsFixed(3)}\tlogprob ${lp.toStringAsFixed(3)}\t'
                'compresion ${cr.toStringAsFixed(2)}',
        ];
        await res.responder(200, '${l.join('\n')}\n', extra: cab);
      } else {
        await res.responder(200, texto, extra: cab);
      }
      // Solo tamaños y tiempos: lo dictado no va al registro.
      registro?.call('${pet.ruta}: ${(r.audioMs / 1000).toStringAsFixed(1)} s a $hz Hz '
          '-> ${texto.length} letras en $ms ms (cola $colaMs)${texto.isEmpty ? ' [${r.motivo}]' : ''}');
    } on _Fallo catch (e) {
      _contar('error-${e.codigo}');
      await res.responder(e.codigo, 'fallo: $e\n', extra: [('X-Error', '${e.codigo}')]);
    } on _Ocupado catch (e) {
      await res.responder(503, 'fallo: ocupado: $e\n', extra: const [('X-Error', 'ocupado'), ('Retry-After', '2')]);
    } on Object catch (e) {
      _contar('fallos');
      registro?.call('${pet.ruta}: FALLO $e');
      if (!res.empezada) {
        final t = '$e';
        await res.responder(500, 'fallo: ${t.length > 200 ? t.substring(0, 200) : t}\n',
            extra: [('X-Error', e.runtimeType.toString())]);
      }
    } finally {
      if (enTurno) _soltarTurno();
    }
  }
}
