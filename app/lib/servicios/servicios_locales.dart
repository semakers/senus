// Los dos servicios locales juntos: escuchan en 127.0.0.1 mientras SENUS está
// abierta y su componente está instalado y verificado. Si un componente no está, su
// puerto no escucha: el teléfono ve lo mismo que hoy con el servicio parado.
//
// Sin Flutter (arranque_servicios.dart pone lo que depende de la app).

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'catalogo_componentes.dart';
import 'catalogo_musica.dart';
import 'gestor_componentes.dart';
import 'letra_telefono.dart';
import 'motor_dictado.dart';
import 'pistas_musica.dart';
import 'servicio_dictado.dart';
import 'servicio_musica.dart';

class ServiciosLocales {
  final GestorComponentes gestor;
  final LetraTelefono letra;
  final int puertoDeDictado;
  final int puertoDeMusica;
  final int colaDictado;
  final void Function(String)? registro;

  /// Se inyectan para las pruebas.
  final MotorDictado? motorDictado;
  final HerramientasMusica? herramientasMusica;
  final RedCatalogo? redCatalogo;

  ServicioDictado? dictado;
  ServicioMusica? musica;

  /// Lo que le impide escuchar (el puerto ocupado): para enseñarlo.
  String? problemaDictado, problemaMusica;

  final _cambios = StreamController<void>.broadcast();
  StreamSubscription<EstadoComponente>? _sub;
  Future<void> _cola = Future.value();
  bool _parado = true;

  ServiciosLocales({
    required this.gestor,
    required this.letra,
    this.puertoDeDictado = puertoDictado,
    this.puertoDeMusica = puertoMusica,
    this.colaDictado = 4,
    this.motorDictado,
    this.herramientasMusica,
    this.redCatalogo,
    this.registro,
  });

  /// Avisa cuando cambia algo de lo que enseña la pantalla.
  Stream<void> get cambios => _cambios.stream;

  bool get dictadoEscuchando => dictado?.servidor.escuchando ?? false;
  bool get musicaEscuchando => musica?.servidor.escuchando ?? false;

  Future<void> arrancar() async {
    _parado = false;
    _sub ??= gestor.cambios.listen((_) => _encolar(_sincronizar));
    await gestor.comprobar();
    await _encolar(_sincronizar);
  }

  Future<void> parar() async {
    _parado = true;
    await _sub?.cancel();
    _sub = null;
    await _encolar(_pararTodo);
  }

  Future<void> _encolar(Future<void> Function() f) {
    final r = _cola.then((_) => f());
    _cola = r.then<void>((_) {}, onError: (Object e) => registro?.call('servicios: $e'));
    return r;
  }

  bool _listo(String id) =>
      gestor.catalogo.any((c) => c.id == id) && gestor.estado(id).fase == FaseComponente.listo;

  Future<void> _sincronizar() async {
    if (_parado) return;
    await _unDictado();
    await _unaMusica();
    _cambios.add(null);
  }

  Future<void> _pararTodo() async {
    await dictado?.parar();
    await musica?.parar();
    dictado = null;
    musica = null;
    if (!_cambios.isClosed) _cambios.add(null);
  }

  Future<RutasMotor> _rutasMotor() async => RutasMotor(
        await gestor.rutaVerificada(idDictado, ayudanteDictado),
        await gestor.rutaVerificada(idDictado, modeloDictado),
        await gestor.rutaVerificada(idDictado, vadDictado),
      );

  Future<void> _unDictado() async {
    final listo = _listo(idDictado);
    if (!listo) {
      await dictado?.parar();
      dictado = null;
      problemaDictado = null;
      return;
    }
    if (dictado != null) return;
    final motor = motorDictado ?? MotorAyudante(rutas: _rutasMotor);
    final s = ServicioDictado(
      motor: motor,
      letra: letra,
      nombreModelo: nombreModeloDictado,
      puerto: puertoDeDictado,
      cola: colaDictado,
      registro: registro,
    );
    try {
      await s.arrancar();
      dictado = s;
      problemaDictado = null;
      // La primera vez, macOS compila los sombreadores de Metal (~6 s [medido]). Se
      // hace ahora y se suelta: la RAM solo se gasta al dictar.
      if (motor is MotorAyudante) unawaited(_precalentar(motor));
    } on SocketException catch (e) {
      problemaDictado = 'Otro programa está usando el puerto $puertoDeDictado.';
      registro?.call('dictado: $e');
    }
  }

  Future<void> _precalentar(MotorAyudante m) async {
    try {
      await m.precalentar();
    } on Object catch (e) {
      registro?.call('dictado: al precalentar: $e');
    }
  }

  HerramientasMusica _herramientas() => HerramientasMusica(
        ytDlp: () => gestor.rutaVerificada(idMusica, rutasMusica().ytDlp),
        deno: () => gestor.rutaVerificada(idMusica, rutasMusica().deno),
        ffmpeg: () => gestor.rutaVerificada(idMusica, rutasMusica().ffmpeg),
        cacheYtDlp: p.join(gestor.raiz.path, 'cache'),
      );

  Future<void> _unaMusica() async {
    final listo = _listo(idMusica);
    if (!listo) {
      await musica?.parar();
      musica = null;
      problemaMusica = null;
      return;
    }
    if (musica != null) return;
    final h = herramientasMusica ?? _herramientas();
    final cat = Catalogo(red: redCatalogo);
    final s = ServicioMusica(
      catalogo: cat,
      pistas: Pistas(herramientas: h, permitirHttp: gestor.permitirHttp, registro: registro),
      portadas: Portadas(cat, h.ffmpeg),
      letra: letra,
      versiones: versionesMusica,
      puerto: puertoDeMusica,
      registro: registro,
    );
    try {
      await s.arrancar();
      musica = s;
      problemaMusica = null;
    } on SocketException catch (e) {
      problemaMusica = 'Otro programa está usando el puerto $puertoDeMusica.';
      registro?.call('música: $e');
    }
  }
}
