// Adónde se deja llegar al teléfono. Sus servicios en `localhost` del computador
// son privados salvo los puertos hechos para él, y 0.0.0.0 y :: nunca son un
// destino. Se comprueba lo RESUELTO, y el puente se conecta luego a esas mismas
// direcciones: un nombre no puede contestar una cosa aquí y otra al conectar.

import 'dart:io';

/// 8580 = música, 8581 = dictado: los servicios de SENUS para el teléfono.
const Set<int> puertosLocalesSenus = {8580, 8581};

class Prohibido implements Exception {
  final String motivo;
  const Prohibido(this.motivo);
  @override
  String toString() => motivo;
}

/// El nombre no existe.
class ErrorDns implements Exception {
  final String motivo;
  const ErrorDns(this.motivo);
  @override
  String toString() => motivo;
}

/// IPv4 que hay dentro de una IPv6 mapeada (::ffff:a.b.c.d) o compatible
/// (::a.b.c.d), o null. `::1` y `::` no cuentan: se miran aparte.
List<int>? _ipv4Dentro(List<int> b) {
  if (b.length != 16) return null;
  for (var i = 0; i < 10; i++) {
    if (b[i] != 0) return null;
  }
  final mapeada = b[10] == 0xFF && b[11] == 0xFF;
  final compatible = b[10] == 0 && b[11] == 0;
  if (!mapeada && !compatible) return null;
  if (compatible && b[12] == 0 && b[13] == 0 && b[14] == 0 && b[15] <= 1) {
    return null;
  }
  return b.sublist(12);
}

/// 0.0.0.0/8 o `::`: no es un destino.
bool esNoEspecificada(InternetAddress a) {
  final b = a.rawAddress;
  final v4 = b.length == 4 ? b : _ipv4Dentro(b);
  if (v4 != null) return v4[0] == 0;
  return b.every((x) => x == 0);
}

/// 127.0.0.0/8 o `::1`, también dentro de una IPv6 mapeada: `ipaddress` de
/// Python no la ve, y por ahí se entraría a lo local.
bool esLocal(InternetAddress a) {
  final b = a.rawAddress;
  final v4 = b.length == 4 ? b : _ipv4Dentro(b);
  if (v4 != null) return v4[0] == 127;
  for (var i = 0; i < 15; i++) {
    if (b[i] != 0) return false;
  }
  return b[15] == 1;
}

/// Resuelve un nombre. Se puede sustituir en las pruebas.
typedef Resolver = Future<List<InternetAddress>> Function(String host);

Future<List<InternetAddress>> resolverDeVerdad(String host) async {
  final literal = InternetAddress.tryParse(host);
  if (literal != null) return [literal];
  try {
    return await InternetAddress.lookup(host);
  } on SocketException catch (e) {
    throw ErrorDns('$host: ${e.osError?.message ?? e.message}');
  }
}

class PoliticaDestinos {
  /// Deja `localhost` entero. Solo para las pruebas: 0.0.0.0 y :: siguen fuera.
  final bool permitirLocal;

  /// Puertos de 127.0.0.1 y ::1 que sí se dejan.
  final Set<int> locales;
  final Resolver resolver;

  const PoliticaDestinos({
    this.permitirLocal = false,
    this.locales = puertosLocalesSenus,
    this.resolver = resolverDeVerdad,
  });

  /// Las direcciones a las que se puede conectar, en orden. Si UNA no se deja,
  /// no se deja el destino entero.
  Future<List<InternetAddress>> comprobar(String host, int puerto) async {
    final dirs = await resolver(host);
    if (dirs.isEmpty) throw ErrorDns('$host: sin direcciones');
    for (final d in dirs) {
      if (esNoEspecificada(d)) {
        throw Prohibido('$host:$puerto no es un destino (0.0.0.0 / ::)');
      }
      if (esLocal(d) && !permitirLocal && !locales.contains(puerto)) {
        throw Prohibido('$host:$puerto es local');
      }
    }
    return dirs;
  }
}
