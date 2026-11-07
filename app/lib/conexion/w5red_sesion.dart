// W5RED v1, el lado del PUENTE: una sesión por teléfono sobre cualquier flujo de
// bytes ya conectado (el RFCOMM de la plataforma o, en las pruebas, un TCP local).
// Port de bt/puente_red/w5red.py; el contrato es PROTOCOLO.md. Dart puro.
//
// Todo lo que va al teléfono pasa por una sola cola ([Sesion.mandar]): las tramas
// nunca se mezclan. Cada canal respeta la ventana que le da el teléfono y le da
// la suya, así ningún canal llena la memoria de nadie.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'cliente_http.dart';
import 'destinos.dart';
import 'lector_bytes.dart';
import 'w5red_protocolo.dart';

/// El flujo de bytes de una sesión.
abstract class TransporteW5 {
  /// Quién está al otro lado, para los registros.
  String get quien;

  /// Lo que llega del teléfono. Se escucha una sola vez.
  Stream<Uint8List> get entrada;

  /// Completa cuando el transporte se ha quedado los bytes: de ahí sale que un
  /// enlace lento frene a los canales. Nunca hay dos a la vez.
  Future<void> escribir(Uint8List d);

  Future<void> cerrar();
}

/// Excepción de red → código de CIERRA.
int codigoDe(Object e) {
  if (e is Prohibido) return cProhibido;
  if (e is ErrorDns) return cDns;
  if (e is TimeoutException) return cPlazo;
  if (e is TlsException) return cTls;
  if (e is ErrorHttp) return cHttp;
  if (e is FormatException) return cHttp;
  if (e is ConexionCortada) return cCortada;
  if (e is SocketException) {
    final n = e.osError?.errorCode;
    if (const {61, 111, 10061}.contains(n)) return cRechazada;
    if (const {60, 110, 10060}.contains(n)) return cPlazo;
    if (const {32, 53, 54, 103, 104, 10053, 10054}.contains(n)) return cCortada;
    final t = '${e.message} ${e.osError?.message}'.toLowerCase();
    if (t.contains('timed out')) return cPlazo;
    if (t.contains('refused')) return cRechazada;
    return cRed;
  }
  return cInterno;
}

class _Envio {
  final Uint8List b;
  final Completer<bool> hecho;
  _Envio(this.b, this.hecho);
}

class _Adios implements Exception {}

class Sesion {
  final TransporteW5 t;
  final void Function(String) log;
  final PoliticaDestinos politica;
  final Duration plazoHola;
  final int ventanaTel;

  int cargaMax = cargaMaxPuente;
  int canalesMax = canalesMaxPuente;

  final Map<int, Canal> canales = {};
  bool viva = true;
  int bytesRx = 0, bytesTx = 0;

  /// Lo que dijo el teléfono en su HOLA.
  String cliente = '';

  /// El HOLA ya se contestó: el teléfono habla W5RED de verdad.
  bool get saludada => _saludada;
  bool _saludada = false;

  final void Function()? alSaludar;

  final CortadorTramas _corte = CortadorTramas();
  final ListQueue<_Envio> _cola = ListQueue();
  final Completer<void> _fin = Completer();
  final DateTime _t0 = DateTime.now();
  StreamSubscription<Uint8List>? _sub;
  Timer? _tHola;
  bool _bombeando = false;
  bool _acabando = false;
  bool _acabada = false;

  Sesion(
    this.t, {
    required this.log,
    this.politica = const PoliticaDestinos(),
    this.plazoHola = const Duration(seconds: 15),
    this.ventanaTel = ventanaAlTelefono,
    this.alSaludar,
  });

  // ---- envío

  /// Pone una trama en la cola. Completa con false si la sesión ya no vive.
  Future<bool> mandar(int tipo, int canal, [List<int> carga = const []]) =>
      _encolar(trama(tipo, canal, carga));

  /// [d] en DATOS de hasta `cargaMax`, TODAS en una sola escritura.
  Future<bool> mandarDatos(int canal, Uint8List d) {
    final cm = cargaMax;
    final b = BytesBuilder(copy: false);
    for (var i = 0; i < d.length; i += cm) {
      b.add(trama(tDatos, canal,
          Uint8List.sublistView(d, i, math.min(i + cm, d.length))));
    }
    return _encolar(b.takeBytes());
  }

  Future<bool> _encolar(Uint8List b) {
    if (!viva) return Future.value(false);
    final e = _Envio(b, Completer<bool>());
    _cola.add(e);
    unawaited(_bombear());
    return e.hecho.future;
  }

  /// Junta lo que haya hasta un lote y lo escribe de una vez. Una sola bomba
  /// por sesión: `escribir` nunca se solapa.
  Future<void> _bombear() async {
    if (_bombeando) return;
    _bombeando = true;
    try {
      while (_cola.isNotEmpty && viva) {
        final hechos = <Completer<bool>>[];
        final b = BytesBuilder(copy: false);
        while (_cola.isNotEmpty && b.length < loteW5) {
          final e = _cola.removeFirst();
          b.add(e.b);
          hechos.add(e.hecho);
        }
        final n = b.length;
        await t.escribir(b.takeBytes());
        bytesTx += n;
        for (final h in hechos) {
          h.complete(true);
        }
      }
    } catch (e) {
      log('${t.quien}: no se pudo mandar ($e): fin de sesión');
      _acabar();
    } finally {
      _bombeando = false;
    }
  }

  // ---- recepción

  /// Corre la sesión; completa cuando se corta.
  Future<void> correr() {
    _tHola = Timer(plazoHola, () {
      log('${t.quien}: no llegó el HOLA');
      _acabar();
    });
    _sub = t.entrada.listen(
      _llega,
      onError: (Object e) {
        log('${t.quien}: la sesión se cortó ($e)');
        _acabar();
      },
      onDone: _acabar,
      cancelOnError: true,
    );
    return _fin.future;
  }

  void _llega(Uint8List d) {
    if (!viva || _acabando) return;
    bytesRx += d.length;
    _corte.anadir(d);
    try {
      while (viva && !_acabando) {
        final x = _corte.siguiente();
        if (x == null) break;
        if (_saludada) {
          if (x.carga.length > cargaMax) {
            throw ErrorProtocolo(
                'trama de ${x.carga.length} B (máx. $cargaMax)');
          }
          _despachar(x.tipo, x.canal, x.carga);
        } else {
          _hola(x);
        }
      }
    } on ErrorProtocolo catch (e) {
      log('${t.quien}: error de protocolo: $e');
      final txt = utf8.encode('$e');
      unawaited(_despedirse(
          [cProtocolo, ...txt.take(60), 0]));
    } on _Adios {
      _acabar();
    }
  }

  void _hola(Trama x) {
    final c = x.carga;
    var bien = x.tipo == tHola && x.canal == 0 && c.length >= 9;
    for (var i = 0; bien && i < magiaW5.length; i++) {
      bien = c[i] == magiaW5[i];
    }
    if (!bien) throw const ErrorProtocolo('no empezó con HOLA');
    final ver = c[5];
    final carga = c[6] | (c[7] << 8);
    final nc = c[8];
    cliente = utf8.decode(c.sublist(9), allowMalformed: true);
    if (ver != versionW5) throw ErrorProtocolo('versión $ver');
    cargaMax = math.max(64, math.min(cargaMax, carga));
    canalesMax = math.max(1, math.min(math.min(canalesMax, nc), 15));
    _tHola?.cancel();
    mandar(tHolaOk, 0, [
      ...magiaW5,
      versionW5,
      cargaMax & 0xFF,
      cargaMax >> 8,
      canalesMax,
      ...utf8.encode(nombrePuenteW5),
    ]);
    _saludada = true;
    log('${t.quien}: HOLA de «$cliente»: carga $cargaMax, $canalesMax canales');
    alSaludar?.call();
  }

  void _despachar(int tipo, int canal, Uint8List c) {
    if (canal == 0) {
      switch (tipo) {
        case tPing:
          mandar(tPong, 0, c.length > 64 ? c.sublist(0, 64) : c);
        case tPong:
          break;
        case tAdios:
          throw _Adios();
        default:
          throw ErrorProtocolo(
              'tipo 0x${tipo.toRadixString(16).padLeft(2, '0')} en el canal 0');
      }
      return;
    }
    final k = canales[canal];
    if (tipo == tAbreHttp || tipo == tAbreTcp) {
      if (canal > canalesMax || k != null) {
        mandar(tCierra, canal,
            [cDemasiados, ...utf8.encode('canal ocupado o fuera de rango'), 0]);
        return;
      }
      if (c.length < 6 + (tipo == tAbreTcp ? 2 : 0)) {
        throw const ErrorProtocolo('ABRE corto');
      }
      final v = ByteData.sublistView(c);
      final ventana = v.getUint32(0, Endian.little);
      final banderas = c[4];
      final plazo = c[5] == 0 ? 30 : c[5];
      final resto = Uint8List.sublistView(c, 6);
      final Canal n = tipo == tAbreHttp
          ? CanalHttp(this, canal, ventana, banderas, plazo, resto)
          : CanalTcp(this, canal, ventana, banderas, plazo, resto);
      canales[canal] = n;
      n.arrancar();
      return;
    }
    if (k == null) return; // un canal ya cerrado: se ignora (PROTOCOLO.md §3)
    switch (tipo) {
      case tDatos:
        k.datosDelTelefono(c);
      case tVentana:
        if (c.length < 4) throw const ErrorProtocolo('VENTANA corta');
        k.masVentana(leerU32(c, 0));
      case tFin:
        k.finDelTelefono();
      case tCierra:
        k.abortar(avisar: true); // contesta con CIERRA(ABORTADA)
      default:
        throw ErrorProtocolo(
            'tipo 0x${tipo.toRadixString(16).padLeft(2, '0')} en un canal');
    }
  }

  void soltar(int canal, Canal k) {
    if (identical(canales[canal], k)) canales.remove(canal);
  }

  /// Avisa con un ADIOS y corta. El plazo es por si el enlace ya no traga.
  Future<void> _despedirse(List<int> carga) async {
    if (_acabando) return;
    _acabando = true;
    try {
      await mandar(tAdios, 0, carga)
          .timeout(const Duration(seconds: 2), onTimeout: () => false);
    } finally {
      _acabar();
    }
  }

  /// La corta el puente: al apagar el servidor o al cerrar SENUS.
  Future<void> parar() async {
    await _despedirse([cBien, ...utf8.encode('puente apagado'), 0]);
    _acabar();
  }

  void _acabar() {
    if (_acabada) return;
    _acabada = true;
    viva = false;
    _tHola?.cancel();
    for (final k in canales.values.toList()) {
      k.abortar(avisar: false);
    }
    while (_cola.isNotEmpty) {
      _cola.removeFirst().hecho.complete(false);
    }
    unawaited(_sub?.cancel());
    unawaited(t.cerrar().then<void>((_) {}, onError: (Object _) {}));
    final s = DateTime.now().difference(_t0).inSeconds;
    log('${t.quien}: fin de sesión ($s s, $bytesRx B recibidos, '
        '$bytesTx mandados)');
    _fin.complete();
  }
}

abstract class Canal {
  final Sesion ses;
  final int n;
  final int banderas;
  final Duration plazo;
  int ventana; // lo que podemos mandarle aún
  bool cerrado = false; // ya no se manda nada por este canal
  bool finTel = false;
  int bytesAlTel = 0, bytesDelTel = 0;
  int _ventDebe = 0;
  final DateTime _t0 = DateTime.now();
  Completer<void>? _cv;

  Canal(this.ses, this.n, this.ventana, this.banderas, int plazoS)
      : plazo = Duration(seconds: plazoS);

  String get que;
  bool get _sinVerificar => banderas & bSinVerificar != 0;

  void datosDelTelefono(Uint8List d);
  void finDelTelefono();
  Future<void> trabajar();
  void liberar() {}

  void _avisar() {
    final c = _cv;
    _cv = null;
    c?.complete();
  }

  /// Espera a que cambie algo del canal, [max] como mucho.
  Future<void> _esperar([Duration? max]) {
    final c = _cv ??= Completer<void>();
    if (max == null) return c.future;
    return c.future.timeout(max, onTimeout: () {});
  }

  Future<bool> mandar(int tipo, [List<int> carga = const []]) {
    if (cerrado) return Future.value(false);
    return ses.mandar(tipo, n, carga);
  }

  void masVentana(int k) {
    ventana = math.min(ventana + k, 0xFFFFFFFF);
    _avisar();
  }

  /// Cuánto se puede mandar ya (<= quiero, hasta un lote); 0 = el canal se cerró.
  Future<int> esperarVentana(int quiero) async {
    while (ventana <= 0 && !cerrado && ses.viva) {
      await _esperar();
    }
    if (cerrado || !ses.viva) return 0;
    final k = math.min(math.min(quiero, ventana), loteW5);
    ventana -= k;
    return k;
  }

  Future<bool> mandarLote(Uint8List d) {
    if (cerrado) return Future.value(false);
    return ses.mandarDatos(n, d);
  }

  /// Lo que el teléfono mandó y ya se consumió: se le devuelve de 32 en 32 KB
  /// (o ya, si se pide).
  void devolverVentana(int k, {bool ya = false}) {
    _ventDebe += k;
    if (_ventDebe >= ventanaLote || (ya && _ventDebe > 0)) {
      mandar(tVentana, u32le(_ventDebe));
      _ventDebe = 0;
    }
  }

  /// El puente da el canal por terminado, bien o mal: CIERRA y fuera.
  void cerrar(int codigo, [String texto = '']) {
    if (cerrado) return;
    final t = utf8.encode(texto);
    ses.mandar(
        tCierra, n, [codigo, ...(t.length > 200 ? t.sublist(0, 200) : t), 0]);
    cerrado = true;
    _avisar();
    ses.soltar(n, this);
    liberar();
    final ms = DateTime.now().difference(_t0).inMilliseconds;
    ses.log('${ses.t.quien}: canal $n $que: ${nombresCodigo[codigo]}'
        '${texto.isEmpty ? '' : ' — $texto'} (${(ms / 1000).toStringAsFixed(2)} s, '
        '$bytesAlTel B al teléfono, $bytesDelTel B de él)');
  }

  /// El teléfono pide cerrar ([avisar]: contestar con CIERRA) o la sesión acabó.
  void abortar({required bool avisar}) {
    if (cerrado) return;
    if (avisar) {
      ses.mandar(
          tCierra, n, [cAbortada, ...utf8.encode('cerrado a peticion'), 0]);
    }
    cerrado = true;
    _avisar();
    ses.soltar(n, this);
    liberar();
    ses.log('${ses.t.quien}: canal $n $que: ABORTADO');
  }

  void arrancar() => unawaited(_hilo());

  /// Cualquier fallo cierra SOLO este canal.
  Future<void> _hilo() async {
    try {
      await trabajar();
    } catch (e) {
      if (!cerrado) cerrar(codigoDe(e), '$e');
    }
  }
}

class CanalHttp extends Canal {
  late final String metodo;
  late final String url;
  final List<MapEntry<String, String>> cabeceras = [];
  final BytesBuilder _cuerpo = BytesBuilder(copy: true);
  String _que = '';
  Socket? _s;
  LectorBytes? _l;

  CanalHttp(super.ses, super.n, super.ventana, super.banderas, super.plazoS,
      Uint8List resto) {
    final (t, _) = cadenasW5(resto, 3);
    metodo = t[0].isEmpty ? 'GET' : t[0].toUpperCase();
    url = t[1];
    for (final l in t[2].split('\r\n')) {
      final i = l.indexOf(':');
      if (i > 0) {
        cabeceras.add(MapEntry(l.substring(0, i).trim(), l.substring(i + 1).trim()));
      }
    }
    _que = '$metodo $url';
  }

  @override
  String get que => _que;

  @override
  void datosDelTelefono(Uint8List d) {
    bytesDelTel += d.length;
    if (_cuerpo.length + d.length > cuerpoMax) {
      cerrar(cHttp, 'cuerpo de la petición de más de ${cuerpoMax >> 20} MB');
      return;
    }
    _cuerpo.add(d);
    devolverVentana(d.length); // guardado: que siga (de 32 en 32 KB)
  }

  @override
  void finDelTelefono() {
    finTel = true;
    _avisar();
  }

  @override
  void liberar() {
    final s = _s, l = _l;
    _s = null;
    _l = null;
    l?.cancelar();
    s?.destroy();
  }

  bool _alSocket(Socket s, LectorBytes? l) {
    if (cerrado) {
      l?.cancelar();
      s.destroy();
      return false;
    }
    _s = s;
    _l = l;
    return true;
  }

  /// Las cabeceras de la petición, con lo que añade `urllib` si la app no lo
  /// puso. Las de cuerpo las calcula el puente: un `Content-Length` que no
  /// cuadre colgaría al servidor.
  List<MapEntry<String, String>> _cabecerasDe(
      UrlHttp u, Uint8List? cuerpo, List<MapEntry<String, String>> propias) {
    final m = <String, MapEntry<String, String>>{};
    for (final e in propias) {
      m[e.key.toLowerCase()] = e; // la última manda, como `add_header`
    }
    m.remove('content-length');
    m.remove('transfer-encoding');
    m.remove('connection');
    final extra = <MapEntry<String, String>>[];
    void poner(String clave, String nombre, String valor) {
      if (!m.containsKey(clave)) extra.add(MapEntry(nombre, valor));
    }

    poner('host', 'Host', u.autoridad);
    poner('accept-encoding', 'Accept-Encoding', 'identity');
    poner('user-agent', 'User-Agent', agenteW5);
    if (cuerpo != null) {
      poner('content-type', 'Content-Type', 'application/x-www-form-urlencoded');
      extra.add(MapEntry('Content-Length', '${cuerpo.length}'));
    } else if (const {'POST', 'PUT', 'PATCH'}.contains(metodo)) {
      extra.add(const MapEntry('Content-Length', '0'));
    }
    return [
      ...extra,
      ...m.values,
      const MapEntry('Connection', 'close'),
    ];
  }

  @override
  Future<void> trabajar() async {
    final u0 = UrlHttp.deTexto(url);
    if (u0 == null) {
      cerrar(cHttp, 'URL no válida (solo http:// y https://)');
      return;
    }
    await mandar(tListo, [...u32le(ses.ventanaTel), 0]);
    final conCuerpo = banderas & bCuerpo != 0;
    if (conCuerpo) {
      final limite = DateTime.now().add(const Duration(seconds: 300));
      while (!finTel &&
          !cerrado &&
          ses.viva &&
          DateTime.now().isBefore(limite)) {
        await _esperar(const Duration(seconds: 1));
      }
      if (cerrado || !ses.viva) return;
      if (!finTel) {
        cerrar(cPlazo, 'el cuerpo de la petición no acabó');
        return;
      }
    }

    var u = u0;
    var met = metodo;
    Uint8List? cuerpo = conCuerpo ? _cuerpo.takeBytes() : null;
    var propias = cabeceras;
    final vistas = <String, int>{};
    RespuestaCruda r;
    while (true) {
      final dirs = await ses.politica.comprobar(u.host, u.puerto);
      if (cerrado) return;
      r = await pedirHttp(
        url: u,
        metodo: met,
        cabeceras: _cabecerasDe(u, cuerpo, propias),
        cuerpo: cuerpo,
        dirs: dirs,
        verificarTls: !_sinVerificar,
        plazo: plazo,
        alSocket: _alSocket,
      );
      final destino = _aDondeRedirige(r, u, met);
      if (destino == null) break;
      final veces = vistas[destino.texto] = (vistas[destino.texto] ?? 0) + 1;
      if (veces > 4 || vistas.length > 10) break; // lo de `urllib`: el 3xx tal cual
      r.cerrar();
      if (cerrado) return;
      u = destino;
      if (met != 'HEAD') met = 'GET';
      cuerpo = null;
      propias = [
        for (final e in propias)
          if (!const {'content-length', 'content-type'}
              .contains(e.key.toLowerCase()))
            e
      ];
    }

    try {
      final cab = StringBuffer();
      for (final l in r.cabeceras) {
        cab.write('$l\r\n');
      }
      var urlB = utf8.encode(u.texto);
      final maxUrl = math.min(512, ses.cargaMax - 48);
      if (urlB.length > maxUrl) urlB = urlB.sublist(0, maxUrl);
      var cabB = utf8.encode(cab.toString());
      final sitio = ses.cargaMax - 2 - urlB.length - 2;
      if (cabB.length > sitio) {
        final out = BytesBuilder();
        var quitadas = 0;
        for (final l in r.cabeceras) {
          final b = utf8.encode(l);
          if (out.length + b.length + 2 + 40 <= sitio) {
            out
              ..add(b)
              ..add(const [13, 10]);
          } else {
            quitadas++;
          }
        }
        out.add(utf8.encode('X-W5RED-Recortadas: $quitadas\r\n'));
        cabB = out.takeBytes();
      }
      await mandar(tRespuesta, [
        r.estado & 0xFF,
        r.estado >> 8,
        ...urlB,
        0,
        ...cabB,
        0,
      ]);
      _que = '$metodo $url -> ${r.estado}';
      while (!cerrado) {
        final k = await esperarVentana(loteW5);
        if (k == 0) return;
        final d = await r.leer(k, plazo);
        if (d.isEmpty) {
          masVentana(k);
          break;
        }
        if (d.length < k) masVentana(k - d.length);
        if (!await mandarLote(d)) return;
        bytesAlTel += d.length;
      }
      await mandar(tFin);
      cerrar(cBien);
    } finally {
      r.cerrar();
    }
  }

  /// A dónde sigue esta respuesta, o null si es la que se entrega. Mismas reglas
  /// que `urllib`: un 3xx que no se sigue es una respuesta normal.
  UrlHttp? _aDondeRedirige(RespuestaCruda r, UrlHttp u, String met) {
    if (banderas & bSinRedir != 0) return null;
    final c = r.estado;
    final vale = (const {301, 302, 303, 307, 308}.contains(c) &&
            (met == 'GET' || met == 'HEAD')) ||
        (const {301, 302, 303}.contains(c) && met == 'POST');
    if (!vale) return null;
    final loc = r.cabecera('location') ?? r.cabecera('uri');
    if (loc == null) return null;
    final t = urlDeRedireccion(u, loc);
    return t == null ? null : UrlHttp.deTexto(t);
  }
}

class CanalTcp extends Canal {
  late final int puerto;
  late final String host;
  Socket? _sock;
  LectorBytes? _l;
  final ListQueue<Uint8List?> _cola = ListQueue(); // null = FIN
  Completer<void>? _hayCola;
  bool _finRemoto = false;

  CanalTcp(super.ses, super.n, super.ventana, super.banderas, super.plazoS,
      Uint8List resto) {
    puerto = resto[0] | (resto[1] << 8);
    final (t, _) = cadenasW5(Uint8List.sublistView(resto, 2), 1);
    host = t[0];
  }

  @override
  String get que =>
      'TCP${banderas & bTls != 0 ? '+TLS' : ''} $host:$puerto';

  void _poner(Uint8List? d) {
    _cola.add(d);
    final c = _hayCola;
    _hayCola = null;
    c?.complete();
  }

  @override
  void datosDelTelefono(Uint8List d) {
    bytesDelTel += d.length;
    _poner(d);
  }

  @override
  void finDelTelefono() => _poner(null);

  @override
  void liberar() {
    _poner(null);
    final s = _sock, l = _l;
    _sock = null;
    _l = null;
    l?.cancelar();
    s?.destroy();
  }

  Future<void> _escritor() async {
    try {
      while (true) {
        while (_cola.isEmpty) {
          await (_hayCola ??= Completer<void>()).future;
        }
        final d = _cola.removeFirst();
        final s = _sock;
        if (d == null || cerrado || s == null) break;
        s.add(d);
        await s.flush();
        // De 32 en 32 KB, o lo que haya si ya no queda nada por escribir.
        devolverVentana(d.length, ya: _cola.isEmpty);
      }
      final s = _sock;
      if (!cerrado && s != null) {
        // `close` de un Socket es el medio cierre: se sigue leyendo.
        unawaited(s.close().then<void>((_) {}, onError: (Object _) {}));
        finTel = true; // los dos lados acabados: lo cierra quien llegue segundo
        if (_finRemoto) cerrar(cBien);
      }
    } catch (e) {
      if (!cerrado) cerrar(codigoDe(e), '$e');
    }
  }

  @override
  Future<void> trabajar() async {
    final dirs = await ses.politica.comprobar(host, puerto);
    if (cerrado) return;
    Socket s = await conectarA(dirs, puerto, plazo);
    if (cerrado) {
      s.destroy();
      return;
    }
    if (banderas & bTls != 0) {
      s = await abrirTls(s, host, !_sinVerificar, plazo);
      if (cerrado) {
        s.destroy();
        return;
      }
    }
    unawaited(s.done.then<void>((_) {}, onError: (Object _) {}));
    _sock = s;
    final l = LectorBytes(s);
    _l = l;
    await mandar(tListo, [
      ...u32le(ses.ventanaTel),
      ...utf8.encode('${s.remoteAddress.address}:${s.remotePort}'),
      0,
    ]);
    unawaited(_escritor());
    while (!cerrado) {
      final k = await esperarVentana(loteW5);
      if (k == 0) return;
      final d = await l.leer(k);
      if (d.length < k) masVentana(k - d.length);
      if (d.isEmpty) {
        await mandar(tFin);
        _finRemoto = true;
        if (finTel) cerrar(cBien);
        return; // el escritor cierra cuando el teléfono mande su FIN
      }
      if (!await mandarLote(d)) return;
      bytesAlTel += d.length;
    }
  }
}
