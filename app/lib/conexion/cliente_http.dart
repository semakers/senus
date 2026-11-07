// Cliente HTTP/1.1 mínimo para los canales de W5RED. No es `HttpClient`, y es a
// propósito: `HttpClient` pasa los nombres de cabecera a minúsculas y el teléfono
// lee `Content-Length` y `X-Duracion-Ms` como llegan; el cuerpo tiene que pasar
// TAL CUAL, comprimido si la app lo pidió así, y hay que conectarse a la dirección
// que `PoliticaDestinos` ya comprobó. Una conexión por petición, siempre
// `Connection: close`, como `urllib`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'lector_bytes.dart';

/// Respuesta imposible de leer.
class ErrorHttp implements Exception {
  final String motivo;
  const ErrorHttp(this.motivo);
  @override
  String toString() => motivo;
}

/// La otra punta cortó antes de tiempo.
class ConexionCortada implements Exception {
  final String motivo;
  const ConexionCortada(this.motivo);
  @override
  String toString() => motivo;
}

const int _maxLinea = 65536;
const int _maxCabeceras = 200;

/// Lo que el sistema puede guardar por socket antes de que lo leamos.
const int bufRecepcionRed = 64 * 1024;

/// `SO_RCVBUF`: 0x1002 en macOS y Windows, 8 en Linux.
int get _soRcvbuf => Platform.isLinux ? 8 : 0x1002;

/// Un búfer de recepción pequeño es lo que deja entera una descarga lenta.
/// Con el de por omisión, el sistema se queda con megas que el teléfono aún no
/// ha pedido: el servidor acaba, cierra, a los ~7 s olvida la conexión y
/// contesta RST a nuestro siguiente ACK. `dart:io` da el RST en cuanto llega y
/// pierde lo que había sin leer, mientras que un `recv` lo entregaría antes.
/// Medido contra speed.cloudflare.com a 130 KB/s, lo que da el Bluetooth: 1 MB
/// cortado 5 de 5 veces y 3 MB cortados en 834 943 B; con este límite, 5 de 5 y
/// 2 de 2 enteros. Python no lo necesita. Además deja que un teléfono lento
/// frene de verdad al servidor.
void limitarRecepcion(Socket s) {
  try {
    s.setRawOption(RawSocketOption.fromInt(
        RawSocketOption.levelSocket, _soRcvbuf, bufRecepcionRed));
  } on SocketException {
    // Sin el límite solo se corre el riesgo de arriba: se sigue.
  }
}

/// Lo que el sistema dice que tiene [s] como búfer de recepción.
int bufRecepcionDe(Socket s) {
  final b = s.getRawOption(RawSocketOption(
      RawSocketOption.levelSocket, _soRcvbuf, Uint8List(4)));
  return ByteData.sublistView(b).getInt32(0, Endian.host);
}

/// Conecta a la primera dirección que conteste. [plazo] vale para TODO, y un
/// nombre con 20 direcciones no tarda 20 veces más.
Future<Socket> conectarA(
    List<InternetAddress> dirs, int puerto, Duration plazo) async {
  final fin = DateTime.now().add(plazo);
  Object? ultimo;
  for (final d in dirs) {
    var queda = fin.difference(DateTime.now());
    if (queda <= Duration.zero) {
      throw TimeoutException('plazo de ${plazo.inSeconds} s agotado', plazo);
    }
    if (queda < const Duration(seconds: 1)) queda = const Duration(seconds: 1);
    try {
      final s = await Socket.connect(d, puerto, timeout: queda);
      s.setOption(SocketOption.tcpNoDelay, true);
      limitarRecepcion(s);
      return s;
    } on SocketException catch (e) {
      ultimo = e;
    }
  }
  if (ultimo != null) throw ultimo;
  throw const SocketException('sin direcciones');
}

/// TLS sobre una conexión ya abierta, con el nombre para SNI y para el
/// certificado.
Future<SecureSocket> abrirTls(
    Socket s, String host, bool verificar, Duration plazo) async {
  try {
    final t = await SecureSocket.secure(
      s,
      host: host,
      onBadCertificate: verificar ? null : (_) => true,
    ).timeout(plazo);
    t.setOption(SocketOption.tcpNoDelay, true);
    return t;
  } catch (_) {
    s.destroy();
    rethrow;
  }
}

/// La URL partida. El objetivo sale del texto original: `Uri` reescribe los
/// `%xx`, y el servidor tiene que recibir lo que pidió la app.
class UrlHttp {
  final String esquema;
  final String host;
  final int puerto;
  final String objetivo;
  final String autoridad; // para `Host:`
  final String texto;
  const UrlHttp(this.esquema, this.host, this.puerto, this.objetivo,
      this.autoridad, this.texto);

  bool get tls => esquema == 'https';

  /// null si no es una URL http:// o https:// utilizable.
  static UrlHttp? deTexto(String url) {
    if (RegExp(r'[\x00-\x20\x7F]').hasMatch(url)) return null;
    final Uri u;
    try {
      u = Uri.parse(url);
    } on FormatException {
      return null;
    }
    final esquema = u.scheme.toLowerCase();
    if ((esquema != 'http' && esquema != 'https') || u.host.isEmpty) {
      return null;
    }
    final hasta = url.indexOf('://');
    if (hasta < 0) return null;
    var resto = url.substring(hasta + 3);
    final almohadilla = resto.indexOf('#');
    if (almohadilla >= 0) resto = resto.substring(0, almohadilla);
    final barra = resto.indexOf(RegExp(r'[/?]'));
    var objetivo = barra < 0 ? '/' : resto.substring(barra);
    if (objetivo.startsWith('?')) objetivo = '/$objetivo';
    objetivo = _soloAscii(objetivo);
    final porDefecto = esquema == 'https' ? 443 : 80;
    final puerto = u.hasPort ? u.port : porDefecto;
    final h = u.host.contains(':') ? '[${u.host}]' : u.host;
    return UrlHttp(esquema, u.host, puerto, objetivo,
        puerto == porDefecto ? h : '$h:$puerto', url);
  }

  static String _soloAscii(String s) {
    if (s.codeUnits.every((c) => c < 0x80)) return s;
    final out = StringBuffer();
    for (final b in utf8.encode(s)) {
      if (b < 0x80) {
        out.writeCharCode(b);
      } else {
        out.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return out.toString();
  }
}

/// Resuelve `Location` contra la URL de la que viene, como `urljoin`.
String? urlDeRedireccion(UrlHttp origen, String location) {
  try {
    final u = Uri.parse(origen.texto).resolve(location.trim());
    return u.toString();
  } on FormatException {
    return null;
  }
}

enum _Marco { nada, largo, trozos, hastaCierre }

class RespuestaCruda {
  final int estado;

  /// `Nombre: valor`, con el nombre tal como llegó y en el orden en que llegó.
  final List<String> cabeceras;
  final Socket _s;
  final LectorBytes _l;
  final _Marco _marco;
  int _queda; // del largo, o del trozo actual
  bool _acabada;

  RespuestaCruda._(this.estado, this.cabeceras, this._s, this._l, this._marco,
      this._queda, this._acabada);

  String? cabecera(String nombre) {
    final n = nombre.toLowerCase();
    for (final l in cabeceras) {
      final i = l.indexOf(':');
      if (i > 0 && l.substring(0, i).toLowerCase() == n) {
        return l.substring(i + 1).trim();
      }
    }
    return null;
  }

  /// Hasta [max] bytes del cuerpo; vacío = se acabó.
  Future<Uint8List> leer(int max, Duration plazo) async {
    if (_acabada) return Uint8List(0);
    switch (_marco) {
      case _Marco.nada:
        _acabada = true;
        return Uint8List(0);
      case _Marco.hastaCierre:
        final d = await _l.leer(max, plazo: plazo);
        if (d.isEmpty) _acabada = true;
        return d;
      case _Marco.largo:
        final d = await _l.leer(max < _queda ? max : _queda, plazo: plazo);
        if (d.isEmpty) {
          throw ConexionCortada('faltaban $_queda B del cuerpo');
        }
        _queda -= d.length;
        if (_queda == 0) _acabada = true;
        return d;
      case _Marco.trozos:
        if (_queda == 0) {
          final n = await _leerTamTrozo(plazo);
          if (n == 0) {
            _acabada = true;
            return Uint8List(0);
          }
          _queda = n;
        }
        final d = await _l.leer(max < _queda ? max : _queda, plazo: plazo);
        if (d.isEmpty) throw const ConexionCortada('trozo sin acabar');
        _queda -= d.length;
        if (_queda == 0) await _l.leerLinea(_maxLinea, plazo: plazo); // su CRLF
        return d;
    }
  }

  Future<int> _leerTamTrozo(Duration plazo) async {
    final l = latin1
        .decode(await _l.leerLinea(_maxLinea, plazo: plazo))
        .split(';')
        .first
        .trim();
    if (l.isEmpty) throw const ConexionCortada('sin tamaño de trozo');
    final n = int.tryParse(l, radix: 16);
    if (n == null || n < 0) throw ErrorHttp('trozo mal formado: «$l»');
    return n;
  }

  void cerrar() {
    _l.cancelar();
    _s.destroy();
  }
}

/// Manda la petición y lee la cabecera de la respuesta. [alSocket] entrega el
/// socket en cuanto existe, para que un aborto lo pueda cortar; false = ya se
/// abortó.
Future<RespuestaCruda> pedirHttp({
  required UrlHttp url,
  required String metodo,
  required List<MapEntry<String, String>> cabeceras,
  required Uint8List? cuerpo,
  required List<InternetAddress> dirs,
  required bool verificarTls,
  required Duration plazo,
  required bool Function(Socket s, LectorBytes? l) alSocket,
}) async {
  Socket s = await conectarA(dirs, url.puerto, plazo);
  if (!alSocket(s, null)) throw const ConexionCortada('abortada');
  if (url.tls) {
    s = await abrirTls(s, url.host, verificarTls, plazo);
    if (!alSocket(s, null)) throw const ConexionCortada('abortada');
  }
  final l = LectorBytes(s);
  if (!alSocket(s, l)) throw const ConexionCortada('abortada');
  unawaited(s.done.then<void>((_) {}, onError: (Object _) {}));

  final cab = StringBuffer('$metodo ${url.objetivo} HTTP/1.1\r\n');
  for (final e in cabeceras) {
    cab.write('${e.key}: ${e.value}\r\n');
  }
  cab.write('\r\n');
  s.add(utf8.encode(cab.toString()));
  if (cuerpo != null && cuerpo.isNotEmpty) s.add(cuerpo);
  await s.flush().timeout(plazo);

  final sinCuerpo = metodo == 'HEAD';
  while (true) {
    final linea = await l.leerLinea(_maxLinea, plazo: plazo);
    if (linea.isEmpty) {
      throw const ConexionCortada('la otra punta cerró sin contestar');
    }
    final partes = latin1.decode(linea).trim().split(RegExp(r'\s+'));
    if (partes.length < 2 || !partes[0].startsWith('HTTP/')) {
      throw ErrorHttp('línea de estado imposible: ${partes.join(' ')}');
    }
    final estado = int.tryParse(partes[1]);
    if (estado == null || estado < 100 || estado > 999) {
      throw ErrorHttp('estado imposible: ${partes[1]}');
    }
    final lineas = await _leerCabeceras(l, plazo);
    if (estado >= 100 && estado < 200 && estado != 101) continue;
    return _armar(estado, lineas, s, l, sinCuerpo);
  }
}

Future<List<String>> _leerCabeceras(LectorBytes l, Duration plazo) async {
  final out = <String>[];
  while (true) {
    final b = await l.leerLinea(_maxLinea, plazo: plazo);
    if (b.isEmpty) {
      throw const ConexionCortada('cabeceras sin acabar');
    }
    final t = latin1.decode(b).replaceAll(RegExp(r'[\r\n]+$'), '');
    if (t.isEmpty) return out;
    if ((t.startsWith(' ') || t.startsWith('\t')) && out.isNotEmpty) {
      out[out.length - 1] = '${out.last} ${t.trim()}'; // línea doblada
      continue;
    }
    final i = t.indexOf(':');
    if (i <= 0) continue; // basura entre cabeceras: `http.client` tampoco se rinde
    out.add('${t.substring(0, i)}: ${t.substring(i + 1).trim()}');
    if (out.length > _maxCabeceras) throw const ErrorHttp('demasiadas cabeceras');
  }
}

RespuestaCruda _armar(int estado, List<String> lineas, Socket s, LectorBytes l,
    bool sinCuerpo) {
  String? mira(String n) {
    for (final x in lineas) {
      final i = x.indexOf(':');
      if (x.substring(0, i).toLowerCase() == n) {
        return x.substring(i + 1).trim();
      }
    }
    return null;
  }

  if (sinCuerpo || estado == 204 || estado == 304 || estado < 200) {
    return RespuestaCruda._(estado, lineas, s, l, _Marco.nada, 0, false);
  }
  final te = mira('transfer-encoding')?.toLowerCase() ?? '';
  if (te.contains('chunked')) {
    return RespuestaCruda._(estado, lineas, s, l, _Marco.trozos, 0, false);
  }
  final cl = mira('content-length');
  if (cl != null) {
    final n = int.tryParse(cl.trim());
    if (n != null && n >= 0) {
      return RespuestaCruda._(estado, lineas, s, l, _Marco.largo, n, n == 0);
    }
  }
  return RespuestaCruda._(estado, lineas, s, l, _Marco.hastaCierre, 0, false);
}
