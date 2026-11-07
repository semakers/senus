// Un servidor HTTP/1.0 mínimo, solo en el bucle local. Se escribe a mano y no con
// HttpServer por tres motivos medidos en el protocolo actual del teléfono:
//   - La respuesta acaba al cerrar: HttpServer metería `Transfer-Encoding: chunked`.
//   - El teléfono lee las cabeceras por su nombre exacto (`Content-Length`,
//     `X-Duracion-Ms`, `X-Desde-Byte`): dart:io las pasa a minúsculas.
//   - Es lo que habla bt/*/servicio.py (BaseHTTPRequestHandler).
//
// Nunca escucha fuera de 127.0.0.1. Una página web puede pedirle cosas a
// 127.0.0.1 desde el navegador: se rechaza lo que traiga `Origin` o
// `Sec-Fetch-Site`, y un `Host` que no sea local (DNS rebinding).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const _frases = {
  200: 'OK',
  202: 'Accepted',
  206: 'Partial Content',
  400: 'Bad Request',
  403: 'Forbidden',
  404: 'Not Found',
  411: 'Length Required',
  413: 'Request Entity Too Large',
  500: 'Internal Server Error',
  501: 'Not Implemented',
  502: 'Bad Gateway',
  503: 'Service Unavailable',
};

class CuerpoCortado implements Exception {
  final int recibidos;
  CuerpoCortado(this.recibidos);
}

class PeticionLocal {
  final String metodo;
  final String ruta;
  final Map<String, String> consulta;
  final Map<String, String> _cabeceras;
  final _Lector _lector;

  PeticionLocal._(this.metodo, this.ruta, this.consulta, this._cabeceras, this._lector);

  /// Sin distinguir mayúsculas.
  String? cabecera(String nombre) => _cabeceras[nombre.toLowerCase()];

  /// Los [n] bytes del cuerpo, o [CuerpoCortado] si la conexión se acaba antes.
  Future<Uint8List> leerCuerpo(int n, Duration plazo) => _lector.leer(n).timeout(plazo);

  /// Lee y tira, para que quien mandó de más reciba la respuesta y no un corte.
  Future<void> descartar(int n, Duration plazo) => _lector.descartar(n).timeout(plazo);

  /// Para un GET con una respuesta larga: se sigue leyendo (y tirando) lo que
  /// llegue, que en HTTP/1.0 es nada, y esto acaba cuando el otro lado cierra (o
  /// medio cierra). Hace falta porque una escritura a quien ya colgó puede quedarse
  /// esperando para siempre en vez de fallar [medido en macOS con escrituras
  /// pequeñas y espaciadas]: así se sabe que se fue.
  Future<void> vigilarCierre() => _lector.vigilar();
}

class RespuestaLocal {
  final Socket _s;
  final String _servidor;
  bool _empezada = false;

  RespuestaLocal._(this._s, this._servidor);

  bool get empezada => _empezada;

  /// Línea de estado y cabeceras, con los nombres tal cual se escriben aquí.
  void empezar(int codigo, List<(String, String)> cabeceras) {
    _empezada = true;
    final b = StringBuffer('HTTP/1.0 $codigo ${_frases[codigo] ?? 'Error'}\r\n')
      ..write('Server: $_servidor\r\n')
      ..write('Date: ${HttpDate.format(DateTime.now())}\r\n');
    for (final (k, v) in cabeceras) {
      b.write('$k: $v\r\n');
    }
    b.write('\r\n');
    _s.add(latin1.encode(b.toString()));
  }

  /// Escribe y espera a que salga: así un cliente lento frena al que manda.
  Future<void> escribir(List<int> datos) async {
    _s.add(datos);
    await _s.flush();
  }

  Future<void> responder(
    int codigo,
    Object cuerpo, {
    String tipo = 'text/plain; charset=utf-8',
    List<(String, String)> extra = const [],
  }) async {
    final b = cuerpo is String ? utf8.encode(cuerpo) : cuerpo as List<int>;
    empezar(codigo, [('Content-Type', tipo), ('Content-Length', '${b.length}'), ...extra]);
    await escribir(b);
  }
}

typedef Manejador = Future<void> Function(PeticionLocal pet, RespuestaLocal res);

class ServidorLocal {
  final int puerto;
  final String nombre;
  final Manejador manejador;
  final Duration plazoCabeceras;
  final void Function(String)? registro;

  ServerSocket? _sock;
  final _vivas = <Socket>{};

  ServidorLocal({
    required this.puerto,
    required this.nombre,
    required this.manejador,
    this.plazoCabeceras = const Duration(seconds: 30),
    this.registro,
  });

  bool get escuchando => _sock != null;

  /// El puerto real: con [puerto] 0, el que dio el sistema.
  int get puertoReal => _sock?.port ?? puerto;

  /// Solo en 127.0.0.1. Lanza SocketException si el puerto está ocupado.
  Future<void> arrancar() async {
    if (_sock != null) return;
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, puerto);
    _sock = s;
    s.listen(_atender, onError: (Object _) {}, cancelOnError: false);
  }

  Future<void> parar() async {
    final s = _sock;
    _sock = null;
    await s?.close();
    for (final c in _vivas.toList()) {
      c.destroy();
    }
    _vivas.clear();
  }

  void _atender(Socket s) {
    // Comprobado también aquí: un socket que no venga del bucle local no se atiende.
    if (!s.remoteAddress.isLoopback) {
      s.destroy();
      return;
    }
    _vivas.add(s);
    s.setOption(SocketOption.tcpNoDelay, true);
    unawaited(_conexion(s).whenComplete(() {
      _vivas.remove(s);
      s.destroy();
    }));
  }

  Future<void> _conexion(Socket s) async {
    final lector = _Lector(s);
    final res = RespuestaLocal._(s, nombre);
    try {
      final PeticionLocal pet;
      try {
        pet = await _leerPeticion(lector).timeout(plazoCabeceras);
      } on _MalFormada catch (e) {
        await res.responder(e.codigo, 'fallo: ${e.texto}\n');
        return;
      } on TimeoutException {
        return;
      }
      final rechazo = _rechazo(pet);
      if (rechazo != null) {
        await res.responder(403, 'fallo: $rechazo\n', extra: const [('X-Error', '403')]);
        return;
      }
      await manejador(pet, res);
      await s.flush();
    } on SocketException {
      // el otro lado se fue
    } on CuerpoCortado {
      // ídem, a mitad del cuerpo
    } on TimeoutException {
      // cuerpo que no acaba de llegar
    } on StateError {
      // el socket ya estaba cerrado
    } on Object catch (e) {
      registro?.call('$nombre: $e');
    } finally {
      await lector.soltar();
    }
  }

  String? _rechazo(PeticionLocal pet) {
    if (pet.cabecera('Origin') != null || pet.cabecera('Sec-Fetch-Site') != null) {
      return 'solo para el teléfono';
    }
    final host = pet.cabecera('Host');
    if (host != null) {
      final nombreHost = host.startsWith('[') ? host.split(']').first.substring(1) : host.split(':').first;
      if (!const {'127.0.0.1', 'localhost', '::1'}.contains(nombreHost.toLowerCase())) {
        return 'solo para el teléfono';
      }
    }
    return null;
  }

  Future<PeticionLocal> _leerPeticion(_Lector l) async {
    final bruto = await l.leerCabeceras();
    final lineas = latin1.decode(bruto).split('\r\n');
    final partes = lineas.first.split(' ');
    if (partes.length != 3 || !partes[2].startsWith('HTTP/')) throw _MalFormada(400, 'petición mal formada');
    final metodo = partes[0], destino = partes[1];
    if (metodo != 'GET' && metodo != 'POST') throw _MalFormada(501, 'solo GET y POST');
    final cab = <String, String>{};
    for (final linea in lineas.skip(1)) {
      if (linea.isEmpty) continue;
      final i = linea.indexOf(':');
      if (i <= 0) throw _MalFormada(400, 'cabecera mal formada');
      cab[linea.substring(0, i).trim().toLowerCase()] = linea.substring(i + 1).trim();
    }
    final Uri u;
    try {
      u = Uri.parse(destino);
    } on FormatException {
      throw _MalFormada(400, 'ruta mal formada');
    }
    final Map<String, String> consulta;
    try {
      consulta = u.queryParameters;
    } on FormatException {
      throw _MalFormada(400, 'consulta mal formada');
    }
    return PeticionLocal._(metodo, u.path, consulta, cab, l);
  }
}

class _MalFormada implements Exception {
  final int codigo;
  final String texto;
  _MalFormada(this.codigo, this.texto);
}

/// Lee de un socket por trozos pedidos, sin soltar lo que sobra de cada lectura.
class _Lector {
  static const _maxCabeceras = 64 * 1024;

  final StreamIterator<Uint8List> _it;
  final BytesBuilder _b = BytesBuilder(copy: false);

  _Lector(Socket s) : _it = StreamIterator<Uint8List>(s);

  Future<bool> _mas() async {
    if (!await _it.moveNext()) return false;
    _b.add(_it.current);
    return true;
  }

  Future<Uint8List> leerCabeceras() async {
    while (true) {
      final b = _b.toBytes();
      for (var i = 3; i < b.length; i++) {
        if (b[i] == 10 && b[i - 1] == 13 && b[i - 2] == 10 && b[i - 3] == 13) {
          _b.clear();
          _b.add(Uint8List.sublistView(b, i + 1));
          return Uint8List.sublistView(b, 0, i - 1);
        }
      }
      if (b.length > _maxCabeceras) throw _MalFormada(400, 'cabeceras demasiado largas');
      if (!await _mas()) throw _MalFormada(400, 'la petición se cortó');
    }
  }

  Future<Uint8List> leer(int n) async {
    while (_b.length < n) {
      if (!await _mas()) throw CuerpoCortado(_b.length);
    }
    final b = _b.takeBytes();
    if (b.length > n) _b.add(Uint8List.sublistView(b, n));
    return Uint8List.sublistView(b, 0, n);
  }

  Future<void> descartar(int n) async {
    var queda = n;
    while (queda > 0) {
      if (_b.isEmpty && !await _mas()) return;
      final b = _b.takeBytes();
      if (b.length > queda) {
        _b.add(Uint8List.sublistView(b, queda));
        return;
      }
      queda -= b.length;
    }
  }

  Future<void>? _vigilancia;

  Future<void> vigilar() => _vigilancia ??= () async {
        _b.clear();
        try {
          while (await _it.moveNext()) {}
        } on Object {
          // un error de lectura también es que se fue
        }
      }();

  Future<void> soltar() => _it.cancel();
}
