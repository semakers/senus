// W5RED v1: las tramas y las constantes del protocolo (bt/puente_red/PROTOCOLO.md,
// que es el contrato: el teléfono no cambia). Dart puro: esto corre también en
// `bin/puente_prueba.dart`, sin Flutter.

import 'dart:convert';
import 'dart:typed_data';

const List<int> magiaW5 = [0x57, 0x35, 0x52, 0x45, 0x44]; // «W5RED»
const int versionW5 = 1;

// Control (canal 0).
const int tHola = 0x01;
const int tHolaOk = 0x02;
const int tPing = 0x03;
const int tPong = 0x04;
const int tAdios = 0x05;

// Canales (1..N).
const int tAbreHttp = 0x10;
const int tAbreTcp = 0x11;
const int tListo = 0x12;
const int tRespuesta = 0x13;
const int tDatos = 0x14;
const int tVentana = 0x15;
const int tFin = 0x16;
const int tCierra = 0x17;

// Banderas de ABRE_*: el bit 0 es CUERPO en HTTP y TLS en TCP.
const int bCuerpo = 1;
const int bTls = 1;
const int bSinRedir = 2;
const int bSinVerificar = 4;

// Códigos de CIERRA y ADIOS.
const int cBien = 0;
const int cDns = 1;
const int cRechazada = 2;
const int cPlazo = 3;
const int cTls = 4;
const int cHttp = 5;
const int cRed = 6;
const int cCortada = 7;
const int cProhibido = 8;
const int cDemasiados = 9;
const int cProtocolo = 10;
const int cAbortada = 11;
const int cInterno = 12;

const List<String> nombresCodigo = [
  'BIEN', 'DNS', 'RECHAZADA', 'PLAZO', 'TLS', 'HTTP', 'RED', 'CORTADA',
  'PROHIBIDO', 'DEMASIADOS', 'PROTOCOLO', 'ABORTADA', 'INTERNO',
];

const String agenteW5 = 'senew-W580 (W5RED/1)';

/// Lo más que se guarda de un cuerpo de petición HTTP antes de mandarla.
const int cuerpoMax = 32 << 20;

/// (velocidad) hasta tanto por vuelta, en VARIAS DATOS y UNA sola escritura:
/// con una escritura por DATOS de 2 KB, Linux dejaba tramas RFCOMM de ~30 B.
const int loteW5 = 16 << 10;

/// (velocidad) la ventana del teléfono se devuelve de 32 en 32 KB.
const int ventanaLote = 32 << 10;

const int cargaMaxPuente = 4096;
const int canalesMaxPuente = 8;
const int ventanaAlTelefono = 256 << 10;
const String nombrePuenteW5 = 'puente W5RED de SENUS';

/// Una trama que no cumple el protocolo: quien la recibe corta la sesión.
class ErrorProtocolo implements Exception {
  final String motivo;
  const ErrorProtocolo(this.motivo);
  @override
  String toString() => motivo;
}

/// `u8 tipo · u8 canal · u16 largo · carga`.
Uint8List trama(int tipo, int canal, [List<int> carga = const []]) {
  if (carga.length > 0xFFFF) {
    throw ArgumentError('carga demasiado grande');
  }
  final b = Uint8List(4 + carga.length);
  b[0] = tipo;
  b[1] = canal;
  b[2] = carga.length & 0xFF;
  b[3] = carga.length >> 8;
  b.setRange(4, b.length, carga);
  return b;
}

class Trama {
  final int tipo;
  final int canal;
  final Uint8List carga;
  const Trama(this.tipo, this.canal, this.carga);
}

/// Saca tramas enteras de un flujo de bytes troceado como sea.
class CortadorTramas {
  Uint8List _b = Uint8List(8 << 10);
  int _ini = 0, _fin = 0;

  void anadir(Uint8List d) {
    if (_fin + d.length > _b.length) {
      final hay = _fin - _ini;
      if (hay + d.length > _b.length) {
        var tam = _b.length;
        while (tam < hay + d.length) {
          tam *= 2;
        }
        final n = Uint8List(tam);
        n.setRange(0, hay, _b, _ini);
        _b = n;
      } else {
        _b.setRange(0, hay, _b, _ini);
      }
      _ini = 0;
      _fin = hay;
    }
    _b.setRange(_fin, _fin + d.length, d);
    _fin += d.length;
  }

  /// La siguiente trama entera, o null si aún no ha llegado.
  Trama? siguiente() {
    final hay = _fin - _ini;
    if (hay < 4) return null;
    final largo = _b[_ini + 2] | (_b[_ini + 3] << 8);
    if (hay < 4 + largo) return null;
    final t = Trama(
      _b[_ini],
      _b[_ini + 1],
      Uint8List.fromList(Uint8List.sublistView(_b, _ini + 4, _ini + 4 + largo)),
    );
    _ini += 4 + largo;
    if (_ini == _fin) _ini = _fin = 0;
    return t;
  }
}

/// [n] cadenas terminadas en 0, y lo que sobra.
(List<String>, Uint8List) cadenasW5(Uint8List b, int n) {
  final out = <String>[];
  var i = 0;
  for (var k = 0; k < n; k++) {
    final fin = b.indexOf(0, i);
    if (fin < 0) throw const ErrorProtocolo('cadena sin terminar');
    out.add(utf8.decode(Uint8List.sublistView(b, i, fin), allowMalformed: true));
    i = fin + 1;
  }
  return (out, Uint8List.sublistView(b, i));
}

int leerU32(Uint8List b, int off) =>
    ByteData.sublistView(b).getUint32(off, Endian.little);

Uint8List u32le(int v) =>
    (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();
