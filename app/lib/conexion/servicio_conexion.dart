// El apartado Conexión sin pantalla: el servidor Bluetooth, las sesiones W5RED,
// quién puede entrar y emparejar por el cable. Llama SENUS: mientras el servidor
// está encendido, `vigilar` abre el canal del teléfono a cada permitido que espere
// (macOS 26 no deja a una app ser servidor clásico; medido el 4-nov). Lo de
// después no cambia: el teléfono manda HOLA al abrirse el canal.
//
// Vive en `_SenusAppState`, no en la pantalla: el teléfono sigue con internet al
// quitar el cable y al cambiar de apartado. Solo hay internet con SENUS abierta:
// al cerrarla, esto se apaga.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../mtp/canal_gestion.dart';
import '../mtp/operaciones.dart';
import '../mtp/transporte.dart' show TransporteError;
import 'destinos.dart';
import 'permitidos.dart';
import 'puente_nativo.dart';
import 'w5red_sesion.dart';

enum EstadoServidor { apagado, encendiendo, encendido }

/// El canal RFCOMM que senew ofrece mientras quiere red (0.29.3). Solo aquí.
const int canalTelefono = 7;

/// Los fallos de `sh_red_fallo` (`sistema/shell/red_sis.c`), para personas.
String textoFalloRed(int f) => switch (f) {
      1 => 'Este teléfono no tiene radio Bluetooth.',
      2 => 'El teléfono no tiene puente elegido.',
      3 => 'La radio del teléfono no arrancó.',
      4 => 'No hubo enlace con este computador, o se rechazó el PIN.',
      5 => 'Contestó algo que no es un puente W5RED.',
      6 => 'El enlace se cortó.',
      7 => 'El Bluetooth del teléfono está ocupado con un robot.',
      _ => 'El teléfono falló con el código $f.',
    };

/// Un fallo de emparejar, dicho para la persona.
class FalloEmparejar implements Exception {
  final String motivo;
  const FalloEmparejar(this.motivo);
  @override
  String toString() => motivo;
}

class TransporteRfcomm implements TransporteW5 {
  final PuenteNativo nativo;
  final int id;
  final String direccion;
  final StreamController<Uint8List> _c = StreamController();
  bool _cerrado = false;

  TransporteRfcomm(this.nativo, this.id, this.direccion);

  @override
  String get quien => direccion;

  @override
  Stream<Uint8List> get entrada => _c.stream;

  void llega(Uint8List d) {
    if (!_cerrado) _c.add(d);
  }

  /// La otra punta se fue.
  void acabo() {
    if (_cerrado) return;
    _cerrado = true;
    unawaited(_c.close());
  }

  @override
  Future<void> escribir(Uint8List d) => nativo.escribir(id, d);

  @override
  Future<void> cerrar() async {
    final ya = _cerrado;
    acabo();
    if (ya) return;
    try {
      await nativo.cortar(id);
    } on FalloNativo {
      // Ya no estaba: era lo que se quería.
    }
  }
}

/// Un teléfono al otro lado de un canal RFCOMM.
class TelefonoConectado {
  final int id;
  final String direccion;
  final TransporteRfcomm transporte;

  /// Lo que dijo el sistema al abrirse el canal.
  final bool emparejado;
  Sesion? sesion; // null mientras acaba de emparejarse
  TelefonoConectado(this.id, this.direccion, this.transporte, this.emparejado);

  bool get saludado => sesion?.saludada ?? false;
  String get nombre => sesion?.cliente ?? '';
}

class ServicioConexion extends ChangeNotifier {
  final PuenteNativo nativo;
  final Future<File> Function() ficheroPermitidos;
  final PoliticaDestinos politica;
  final void Function(String) log;

  /// Cuánto se espera al teléfono en total, y cada cuánto se le pregunta.
  final Duration plazoEmparejar;
  final Duration pausaSondeo;

  /// Lo que `SEN_BT_ESTADO.fallo` diga en este rato después de la orden no
  /// cuenta: el hilo de la interfaz aún no la ha atendido y es el fallo de antes.
  final Duration graciaFallo;

  ServicioConexion({
    required this.nativo,
    required this.ficheroPermitidos,
    this.politica = const PoliticaDestinos(),
    void Function(String)? log,
    this.plazoEmparejar = const Duration(seconds: 90),
    this.pausaSondeo = const Duration(milliseconds: 500),
    this.graciaFallo = const Duration(seconds: 2),
  }) : log = log ?? _nada;

  static void _nada(String _) {}

  factory ServicioConexion.deEstaMaquina() => ServicioConexion(
        nativo: puenteNativoDeEstaMaquina(),
        ficheroPermitidos: () async => File(p.join(
            (await getApplicationSupportDirectory()).path,
            'puente_permitidos.txt')),
      );

  EstadoBt? bt;
  EstadoServidor estado = EstadoServidor.apagado;
  int canalRfcomm = 0;
  String? error;

  /// Bytes por segundo: bajada (al teléfono) y subida.
  double velBaja = 0, velSube = 0;

  /// Fase de un emparejamiento en marcha, para enseñarla; null si no hay.
  String? faseEmparejar;

  /// El PIN del emparejamiento en marcha: si macOS lo pide, lo teclea la persona.
  String? pinEmparejar;
  bool listoEmparejar = false;
  String? errorEmparejar;
  String? _direccionEmparejando;

  ListaPermitidos? _lista;
  StreamSubscription<EventoBt>? _sub;
  final Map<int, TelefonoConectado> _telefonos = {};
  Timer? _reloj;
  int _rxAntes = 0, _txAntes = 0;
  DateTime _tAntes = DateTime.now();
  Future<void>? _iniciando;
  bool _cerrado = false;

  /// Lo último que se mandó a `vigilar`: solo se repite si cambia.
  String? _vigilado;

  List<TelefonoConectado> get telefonos => _telefonos.values.toList();
  List<String> get permitidos => _lista?.todas ?? const [];
  bool get emparejando => faseEmparejar != null;
  bool get encendido => estado == EstadoServidor.encendido;

  /// Se llama al abrir el apartado: hasta entonces no se toca el Bluetooth, y la
  /// app arranca como siempre.
  Future<void> iniciar() => _iniciando ??= _iniciar();

  Future<void> _iniciar() async {
    _lista = await ListaPermitidos.cargar(await ficheroPermitidos());
    _sub = nativo.eventos.listen(_evento);
    await refrescar();
  }

  Future<void> refrescar() async {
    bt = await nativo.consultar();
    _avisar();
  }

  void _avisar() {
    if (!_cerrado) notifyListeners();
  }

  // ---- el servidor

  Future<void> encender() async {
    await iniciar();
    if (estado != EstadoServidor.apagado) return;
    estado = EstadoServidor.encendiendo;
    error = null;
    _avisar();
    try {
      canalRfcomm = await nativo.encender(nombre: 'SENUS W5RED', canal: 10);
      estado = EstadoServidor.encendido;
      _tAntes = DateTime.now();
      _rxAntes = _txAntes = 0;
      _reloj ??= Timer.periodic(const Duration(seconds: 1), (_) => _medir());
      log('puente de red listo: SPP en el canal RFCOMM $canalRfcomm; se llama a '
          'los permitidos en su canal $canalTelefono');
      await _vigilar();
      await refrescar();
    } on FalloNativo catch (e) {
      estado = EstadoServidor.apagado;
      error = _textoFallo(e);
      await refrescar();
    }
  }

  static String _textoFallo(FalloNativo e) => switch (e.codigo) {
        'sin_permiso' => 'SENUS no tiene permiso de Bluetooth. Actívalo en Ajustes '
            'del Sistema → Privacidad y seguridad → Bluetooth.',
        'apagado' => 'El Bluetooth de este computador está apagado. Enciéndelo y '
            'vuelve a intentarlo.',
        'sin_adaptador' => 'Esta máquina no tiene Bluetooth.',
        'sdp' => 'El sistema no dejó publicar el servicio: ${e.mensaje}',
        _ => e.mensaje,
      };

  Future<void> apagar() async {
    _reloj?.cancel();
    _reloj = null;
    for (final t in _telefonos.values.toList()) {
      final s = t.sesion;
      if (s != null) {
        await s.parar();
      } else {
        await t.transporte.cerrar();
      }
    }
    _telefonos.clear();
    _vigilado = null; // `apagar` vacía la lista del otro lado
    try {
      await nativo.apagar();
    } on FalloNativo catch (e) {
      log('al apagar: $e');
    }
    estado = EstadoServidor.apagado;
    canalRfcomm = 0;
    velBaja = velSube = 0;
    _avisar();
  }

  /// Quita el teléfono de la lista y corta su sesión. También pide al sistema
  /// olvidar el emparejamiento; si no puede, sin lista no entra igualmente.
  Future<bool> olvidar(String direccion) async {
    await iniciar();
    await _lista!.quitar(direccion);
    await _vigilar();
    for (final t in _telefonos.values.toList()) {
      if (t.direccion == normalizarDireccion(direccion)) {
        await t.sesion?.parar();
        await t.transporte.cerrar();
      }
    }
    var delSistema = false;
    try {
      delSistema = await nativo.olvidar(direccion);
    } on FalloNativo catch (e) {
      log('olvidar: $e');
    }
    _avisar();
    return delSistema;
  }

  /// A quién se llama: los permitidos y, mientras se empareja, el teléfono del
  /// cable aunque aún no esté en la lista.
  Future<void> _vigilar() async {
    if (!encendido) return;
    final l = <String>{...permitidos};
    final e = _direccionEmparejando;
    if (e != null) l.add(e);
    final orden = l.toList()..sort();
    final clave = orden.join(' ');
    if (clave == _vigilado) return;
    _vigilado = clave;
    try {
      await nativo.vigilar(orden, canalTelefono);
    } on FalloNativo catch (x) {
      _vigilado = null; // a la siguiente se vuelve a mandar
      log('vigilar: $x');
    }
  }

  // ---- lo que llega de la plataforma

  void _evento(EventoBt e) {
    switch (e) {
      case BtConectado():
        _conectado(e);
      case BtDatos():
        _telefonos[e.id]?.transporte.llega(e.datos);
      case BtCerrado():
        final t = _telefonos.remove(e.id);
        t?.transporte.acabo();
        _avisar();
      case BtEmparejamiento():
        _emparejamiento(e);
      case BtRegistro():
        log(e.texto);
    }
  }

  void _conectado(BtConectado e) {
    final dir = normalizarDireccion(e.direccion) ?? e.direccion;
    final t = TelefonoConectado(
        e.id, dir, TransporteRfcomm(nativo, e.id, dir), e.emparejado);
    _telefonos[e.id] = t;
    if (emparejando && _direccionEmparejando == null) {
      // Un senew sin dirección guardada no la dice hasta tener la radio
      // encendida, y puede llamar antes del siguiente sondeo: espera a saberla.
      log('$dir: llamó antes de saber quién se empareja');
    } else {
      _admitir(t);
    }
    _avisar();
  }

  void _admitir(TelefonoConectado t) {
    final dir = t.direccion;
    if (!(_lista?.contiene(dir) ?? false)) {
      log('$dir quiere conectarse y NO está en la lista: cortado');
      _echar(t);
    } else if (t.emparejado) {
      _arrancarSesion(t);
    } else if (_direccionEmparejando == dir) {
      // Se está emparejando ahora mismo: lo que mande espera en la cola del
      // transporte hasta que el sistema confirme.
      log('$dir: canal abierto, a la espera de emparejar');
    } else {
      log('$dir no está emparejado con este computador: cortado');
      _echar(t);
    }
  }

  void _echar(TelefonoConectado t) {
    _telefonos.remove(t.id);
    unawaited(t.transporte.cerrar());
  }

  void _arrancarSesion(TelefonoConectado t) {
    if (t.sesion != null) return;
    log('${t.direccion}: conectado por Bluetooth');
    final s = Sesion(t.transporte, log: log, politica: politica, alSaludar: _avisar);
    t.sesion = s;
    unawaited(s.correr().whenComplete(() {
      if (identical(_telefonos[t.id], t)) _telefonos.remove(t.id);
      _avisar();
    }));
  }

  void _emparejamiento(BtEmparejamiento e) {
    final dir = normalizarDireccion(e.direccion);
    switch (e.estado) {
      case 'hecho':
      case 'ya':
        for (final t in _telefonos.values.toList()) {
          if (t.direccion == dir) _arrancarSesion(t);
        }
        if (emparejando) faseEmparejar = 'Emparejado. Esperando su saludo…';
      case 'fallo':
        log('emparejar: el sistema dijo $dir ${e.codigo}');
        for (final t in _telefonos.values.toList()) {
          if (t.direccion == dir && t.sesion == null) _echar(t);
        }
      case 'reintento':
        // Un intento de esta Mac que no salió: viene otro, y no se corta nada.
        log('emparejar: otro intento con $dir (${e.codigo})');
      case 'enlace':
        if (emparejando) faseEmparejar = 'Enlace con el teléfono. Emparejando…';
      case 'pin':
        if (emparejando) faseEmparejar = 'Contestando el PIN…';
    }
    _avisar();
  }

  void _medir() {
    var rx = 0, tx = 0;
    for (final t in _telefonos.values) {
      rx += t.sesion?.bytesRx ?? 0;
      tx += t.sesion?.bytesTx ?? 0;
    }
    final ahora = DateTime.now();
    final s = ahora.difference(_tAntes).inMilliseconds / 1000;
    if (s <= 0) return;
    // Una sesión que se va deja los contadores por debajo: no es velocidad negativa.
    final nuevaSube = math.max(0, rx - _rxAntes) / s;
    final nuevaBaja = math.max(0, tx - _txAntes) / s;
    _rxAntes = rx;
    _txAntes = tx;
    _tAntes = ahora;
    if (nuevaSube != velSube || nuevaBaja != velBaja) {
      velSube = nuevaSube;
      velBaja = nuevaBaja;
      _avisar();
    }
  }

  // ---- emparejar por el cable

  static String _pinNuevo() {
    final r = math.Random.secure();
    return List.generate(6, (_) => r.nextInt(10)).join();
  }

  Future<void> _preparar(String tel, String pin) async {
    await _lista!.anadir(tel);
    _direccionEmparejando = tel;
    // Armado antes de llamarlo: así la Mac lo llama aunque no esté emparejado.
    await nativo.armarEmparejamiento(tel, pin);
    await _vigilar();
    for (final t in _telefonos.values.toList()) {
      if (t.sesion == null) _admitir(t);
    }
  }

  /// Emparejar por el cable: el teléfono recibe la dirección del computador y el
  /// PIN y se pone conectable; SENUS lo llama, empareja y abre su canal. Sin
  /// búsqueda y sin visibilidad. Lanza [FalloEmparejar] con el motivo para la
  /// persona.
  Future<void> emparejar(CanalGestion canal) async {
    await iniciar();
    if (!encendido) {
      throw const FalloEmparejar('Enciende antes el servidor Bluetooth.');
    }
    if (emparejando) return;
    final miDir = bt?.direccion;
    if (miDir == null) {
      throw const FalloEmparejar(
          'No se pudo leer la dirección Bluetooth de este computador.');
    }
    final pin = _pinNuevo();
    pinEmparejar = pin;
    listoEmparejar = false;
    errorEmparejar = null;
    _fase('Preguntando al teléfono…');
    String? tel;
    var yaEstaba = false;
    try {
      final info = await canal.info();
      final t = info.bdAddrTexto;
      if (t != null) {
        tel = normalizarDireccion(t);
        yaEstaba = _lista!.contiene(tel!);
        await _preparar(tel, pin);
      }
      _fase('Mandando la orden al teléfono…');
      await canal.emparejar(
          Uint8List.fromList(bytesDeDireccion(miDir)), pin);
      final t0 = DateTime.now();
      _fase('Encendiendo la radio del teléfono…');
      while (true) {
        final pasado = DateTime.now().difference(t0);
        if (tel == null) {
          // Sin la radio encendida un senew puede no saber su dirección.
          final i = await canal.info();
          final x = i.bdAddrTexto;
          if (x != null) {
            tel = normalizarDireccion(x);
            yaEstaba = _lista!.contiene(tel!);
            await _preparar(tel, pin);
            _fase('Llamando al teléfono…');
          }
        }
        final e = await canal.btEstado();
        if (e.redLista && tel != null && _saludo(tel)) break;
        if (e.fallo != 0 && pasado >= graciaFallo) {
          throw FalloEmparejar(textoFalloRed(e.fallo));
        }
        if (pasado >= plazoEmparejar) {
          throw FalloEmparejar(e.redLista
              ? 'El teléfono dice que tiene red, pero no por este computador. '
                  'Apaga su red y vuelve a intentarlo.'
              : 'El teléfono no llegó a conectar en '
                  '${plazoEmparejar.inSeconds} s.');
        }
        await Future<void>.delayed(pausaSondeo);
      }
      listoEmparejar = true;
    } on CanalError catch (e) {
      final m = _textoCanal(e);
      errorEmparejar = m;
      await _deshacer(tel, yaEstaba);
      throw FalloEmparejar(m);
    } on FalloEmparejar catch (e) {
      errorEmparejar = e.motivo;
      await _deshacer(tel, yaEstaba);
      rethrow;
    } on FalloNativo catch (e) {
      errorEmparejar = e.mensaje;
      await _deshacer(tel, yaEstaba);
      throw FalloEmparejar(e.mensaje);
    } on CanalMalFormado catch (e) {
      errorEmparejar = '$e';
      await _deshacer(tel, yaEstaba);
      throw FalloEmparejar('$e');
    } on TransporteError catch (e) {
      final m = 'Se perdió el cable antes de acabar: ${e.motivo}';
      errorEmparejar = m;
      await _deshacer(tel, yaEstaba);
      throw FalloEmparejar(m);
    } finally {
      _direccionEmparejando = null;
      faseEmparejar = null;
      for (final t in _telefonos.values.toList()) {
        if (t.sesion == null) _echar(t); // el emparejamiento no llegó a nada
      }
      pinEmparejar = null;
      await _vigilar(); // si falló, se le deja de llamar
      try {
        await nativo.desarmarEmparejamiento();
      } on FalloNativo catch (e) {
        log('al desarmar: $e');
      }
      _avisar();
    }
  }

  bool _saludo(String tel) =>
      _telefonos.values.any((t) => t.direccion == tel && t.saludado);

  /// Si falló, un teléfono que no estaba en la lista no se queda en ella.
  Future<void> _deshacer(String? tel, bool yaEstaba) async {
    if (tel != null && !yaEstaba) await _lista!.quitar(tel);
  }

  static String _textoCanal(CanalError e) => switch (e.codigo) {
        rOcupado => 'Cierra la app que esté abierta en el teléfono y vuelve a '
            'intentarlo.',
        rOpNo => 'Este senew todavía no sabe emparejar por el cable: '
            'actualízalo a la 0.29.1 o más nueva.',
        _ => '$e',
      };

  void _fase(String t) {
    faseEmparejar = t;
    _avisar();
  }

  /// Lo apaga todo: al cerrar la app.
  Future<void> cerrar() async {
    if (_cerrado) return;
    _cerrado = true; // desde aquí, ni un aviso: la pantalla puede ya no estar
    await apagar();
    await _sub?.cancel();
  }

  @override
  void dispose() {
    unawaited(cerrar());
    super.dispose();
  }
}
