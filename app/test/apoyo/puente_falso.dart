// Dobles del puente: un teléfono W5RED en Dart, un transporte en memoria y la
// plataforma Bluetooth sin Bluetooth. Es [simulado]: prueba la lógica de SENUS, no
// IOBluetooth ni el teléfono.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:senus_app/conexion/permitidos.dart';
import 'package:senus_app/conexion/puente_nativo.dart';
import 'package:senus_app/conexion/w5red_protocolo.dart';
import 'package:senus_app/conexion/w5red_sesion.dart';

/// El lado del teléfono, mínimo: cola de tramas por canal.
class ClienteW5 {
  final void Function(Uint8List) sal;
  final CortadorTramas _c = CortadorTramas();
  final Map<int, ListQueue<Trama>> _colas = {};
  final Map<int, Completer<void>> _esperas = {};
  bool cortado = false;

  /// Todas las tramas, en orden.
  final List<Trama> vistas = [];

  ClienteW5(this.sal);

  void manda(int tipo, int canal, [List<int> carga = const []]) =>
      sal(trama(tipo, canal, carga));

  void recibe(Uint8List d) {
    _c.anadir(d);
    while (true) {
      final t = _c.siguiente();
      if (t == null) break;
      vistas.add(t);
      (_colas[t.canal] ??= ListQueue()).add(t);
      _esperas.remove(t.canal)?.complete();
    }
  }

  /// La siguiente trama de ese canal.
  Future<Trama> siguiente(int canal,
      {Duration plazo = const Duration(seconds: 10)}) async {
    final fin = DateTime.now().add(plazo);
    while ((_colas[canal] ?? ListQueue()).isEmpty) {
      final queda = fin.difference(DateTime.now());
      if (queda <= Duration.zero) {
        throw TimeoutException('sin tramas en el canal $canal');
      }
      await (_esperas[canal] ??= Completer<void>()).future.timeout(queda);
    }
    return _colas[canal]!.removeFirst();
  }

  /// Espera una de ese tipo, saltándose las demás.
  Future<Trama> espera(int canal, int tipo) async {
    while (true) {
      final t = await siguiente(canal);
      if (t.tipo == tipo) return t;
    }
  }

  Uint8List hola({int carga = 2048, int canales = 4, int version = 1}) =>
      Uint8List.fromList([
        ...magiaW5,
        version,
        carga & 0xFF,
        carga >> 8,
        canales,
        ...utf8.encode('prueba'),
      ]);

  Future<Trama> saludar({int carga = 2048, int canales = 4}) {
    manda(tHola, 0, hola(carga: carga, canales: canales));
    return espera(0, tHolaOk);
  }

  void abrirHttp(int canal, String metodo, String url,
      {String cabeceras = '',
      int ventana = 1 << 20,
      int banderas = 0,
      int plazo = 5}) {
    manda(tAbreHttp, canal, [
      ...u32le(ventana),
      banderas,
      plazo,
      ...utf8.encode(metodo),
      0,
      ...utf8.encode(url),
      0,
      ...utf8.encode(cabeceras),
      0,
    ]);
  }

  void abrirTcp(int canal, String host, int puerto,
      {int ventana = 1 << 20, int banderas = 0, int plazo = 5}) {
    manda(tAbreTcp, canal, [
      ...u32le(ventana),
      banderas,
      plazo,
      puerto & 0xFF,
      puerto >> 8,
      ...utf8.encode(host),
      0,
    ]);
  }

  /// Recoge hasta el CIERRA.
  Future<RespuestaW5> respuesta(int canal, {bool devolver = true}) async {
    final r = RespuestaW5();
    while (true) {
      final t = await siguiente(canal);
      switch (t.tipo) {
        case tListo:
          r.listo = utf8.decode(t.carga.sublist(4, t.carga.indexOf(0, 4)));
        case tRespuesta:
          r.estado = t.carga[0] | (t.carga[1] << 8);
          final fin = t.carga.indexOf(0, 2);
          r.urlFinal = utf8.decode(t.carga.sublist(2, fin));
          final fc = t.carga.indexOf(0, fin + 1);
          r.cabeceras = utf8.decode(t.carga.sublist(fin + 1, fc));
          r.tamRespuesta = t.carga.length;
        case tDatos:
          r.cuerpo.add(t.carga);
          r.datosMax = t.carga.length > r.datosMax ? t.carga.length : r.datosMax;
          if (devolver) manda(tVentana, canal, u32le(t.carga.length));
        case tFin:
          r.fin = true;
        case tCierra:
          r.codigo = t.carga[0];
          r.texto = utf8.decode(t.carga.sublist(1, t.carga.indexOf(0, 1)),
              allowMalformed: true);
          return r;
      }
    }
  }
}

class RespuestaW5 {
  String? listo;
  int? estado;
  String urlFinal = '';
  String cabeceras = '';
  int tamRespuesta = 0;
  final BytesBuilder cuerpo = BytesBuilder();
  bool fin = false;
  int codigo = -1;
  String texto = '';
  int datosMax = 0;
  String get nombreCodigo => nombresCodigo[codigo];
}

/// Un transporte en memoria: lo que escribe la sesión llega al [cliente].
class TransporteMemoria implements TransporteW5 {
  final StreamController<Uint8List> _entra = StreamController();
  late final ClienteW5 cliente = ClienteW5((d) {
    if (!_cerrado) _entra.add(d);
  });
  final List<int> escrituras = [];
  bool _cerrado = false;
  bool get cerrado => _cerrado;

  /// Una escritura falla, como un enlace que se cae.
  bool roto = false;

  /// Si está, cada escritura espera a este futuro: un enlace lento.
  Future<void> Function()? freno;

  @override
  String get quien => 'memoria';
  @override
  Stream<Uint8List> get entrada => _entra.stream;

  @override
  Future<void> escribir(Uint8List d) async {
    if (roto) throw StateError('enlace caído');
    escrituras.add(d.length);
    if (freno != null) await freno!();
    cliente.recibe(d);
  }

  @override
  Future<void> cerrar() async {
    if (_cerrado) return;
    _cerrado = true;
    await _entra.close();
  }

  /// El teléfono se va.
  Future<void> corte() => cerrar();
}

class PuenteNativoFalso implements PuenteNativo {
  final StreamController<EventoBt> _ev = StreamController.broadcast();
  EstadoBt estado = const EstadoBt(
    plataforma: true,
    hay: true,
    permiso: PermisoBt.concedido,
    encendido: true,
    direccion: '02:11:22:33:44:55',
  );
  FalloNativo? falloEncender;
  bool servidor = false;
  final List<String> llamadas = [];
  final List<int> cortados = [];
  final Map<int, ClienteW5> _clientes = {};
  int _sig = 1;

  /// Dirección y PIN del último `armarEmparejamiento`.
  String? armada;
  String? pinArmado;

  /// Lo que está armado ahora mismo: `desarmar` lo quita.
  String? _armadaAhora;

  /// Lo último que se mandó a `vigilar`, por qué canal, y todas las listas.
  List<String> vigiladas = const [];
  int? canalVigilado;
  final List<List<String>> vigilancias = [];

  /// Lo que estaba armado al llegar cada una de [vigilancias].
  final List<String?> armadoAlVigilar = [];
  FalloNativo? falloVigilar;

  /// Teléfonos conectables que esperan a que esta máquina los llame.
  final Map<String, (bool, Completer<ClienteW5>)> _esperan = {};

  void emitir(EventoBt e) => _ev.add(e);

  /// Un teléfono abre el canal RFCOMM. Devuelve su lado W5RED.
  ClienteW5 llama(String direccion, {bool emparejado = true}) {
    final id = _sig++;
    final c = ClienteW5((d) => _ev.add(BtDatos(id, d)));
    _clientes[id] = c;
    _ev.add(BtConectado(id, direccion, emparejado, 1000));
    return c;
  }

  /// Un teléfono conectable (senew 0.29.3 queriendo red): contesta en cuanto esté
  /// en lo vigilado, ahora o en un `vigilar` de después, como el Swift en su
  /// siguiente vuelta. Como allí, a quien no está emparejado solo se le llama si
  /// es el que está armado.
  Future<ClienteW5> esperaLlamada(String direccion, {bool emparejado = true}) {
    final c = Completer<ClienteW5>();
    _esperan[normalizarDireccion(direccion)!] = (emparejado, c);
    _llamarALosQueEsperan();
    return c.future;
  }

  /// Si ya llamó a ese teléfono.
  bool llamado(String direccion) =>
      !_esperan.containsKey(normalizarDireccion(direccion));

  void _llamarALosQueEsperan() {
    if (!servidor) return;
    for (final d in vigiladas) {
      final e = _esperan[d];
      if (e == null || !(e.$1 || d == _armadaAhora)) continue;
      _esperan.remove(d);
      e.$2.complete(llama(d, emparejado: e.$1));
    }
  }

  int idDe(ClienteW5 c) =>
      _clientes.entries.firstWhere((e) => identical(e.value, c)).key;

  @override
  Stream<EventoBt> get eventos => _ev.stream;
  @override
  Future<EstadoBt> consultar() async => estado;

  @override
  Future<int> encender({required String nombre, required int canal}) async {
    llamadas.add('encender');
    final f = falloEncender;
    if (f != null) throw f;
    servidor = true;
    return 7;
  }

  @override
  Future<void> apagar() async {
    llamadas.add('apagar');
    servidor = false;
    vigiladas = const [];
  }

  @override
  Future<void> vigilar(List<String> direcciones, int canal) async {
    llamadas.add('vigilar');
    final f = falloVigilar;
    if (f != null) throw f;
    vigiladas = List.unmodifiable(direcciones);
    canalVigilado = canal;
    vigilancias.add(vigiladas);
    armadoAlVigilar.add(_armadaAhora);
    _llamarALosQueEsperan();
  }

  @override
  Future<void> armarEmparejamiento(String direccion, String pin) async {
    llamadas.add('armar');
    armada = direccion;
    _armadaAhora = normalizarDireccion(direccion);
    pinArmado = pin;
  }

  @override
  Future<void> desarmarEmparejamiento() async {
    llamadas.add('desarmar');
    _armadaAhora = null;
  }

  @override
  Future<bool> olvidar(String direccion) async {
    llamadas.add('olvidar');
    return true;
  }

  @override
  Future<void> escribir(int id, Uint8List d) async {
    _clientes[id]?.recibe(d);
  }

  @override
  Future<void> cortar(int id) async {
    cortados.add(id);
    _clientes[id]?.cortado = true;
    _ev.add(BtCerrado(id));
  }
}
