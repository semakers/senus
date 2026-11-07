// El puente de depuración de senew por EP0 (api/puente.h), solo para lo que el
// canal de gestión aún no puede: el sis28h no tiene canal, y la primera versión
// que entre en el teléfono conserva esta puerta al BL (§8 del diseño).
//
// Únicamente el nivel 0 del puente, lo probado en silicio: respuestas de un
// paquete y órdenes sin fase de datos OUT. Y únicamente la secuencia de
// `pu.py bootloader`, con direcciones de una tabla fija: con otro identificador
// SENUS se niega, porque esas direcciones no valdrían.

import 'dart:convert';
import 'dart:typed_data';

import '../mtp/transporte.dart' show TransporteError;
import 'transporte_bl.dart';

/// bRequest del puente (`api/puente.h`).
const int puRId = 0xB0;
const int puRRes = 0xB4;
const int puRArg0 = 0xC0;
const int puRGo = 0xC8;

const int puOpLlamar = 3;
const int puOpPoke = 9;

const int puStHecho = 3;
const int puStFalloCpu = 4;

/// iRAM: [0] = BL_MAGIA, [1] = ~BL_MAGIA (bl.h).
const int blBandera = 0xF3002F00;
const int blMagia = 0x424C4F41;

/// Una compilación conocida: sus direcciones valen para ella y para nada más.
class EntradaPuente {
  final String id;
  final int cargaVeto;
  final int hwCargaFuera;
  final int reinicioCaliente;
  final int build;
  final String version;
  const EntradaPuente({
    required this.id,
    required this.cargaVeto,
    required this.hwCargaFuera,
    required this.reinicioCaliente,
    required this.build,
    required this.version,
  });
}

/// Tabla del §4.4. Direcciones comprobadas con `nm` sobre `build/sis28h/sistema.elf`
/// y el id contra el `sistema_44180000.bin` empotrado en SENUS. Cada compilación
/// con puente deja su entrada en `senus_tabla.json`. La segunda es la primera
/// versión con canal y puente (§8): vale SOLO para ese binario,
/// `build/agente_a_telefono/sistema.bin`, sha256 `65006c80…ba461`; cotejada con
/// su `senus_tabla.json` (sha256 `f992d775…04848`), con `nm` sobre su ELF y con
/// el id dentro del binario. Si se recompila, el id lleva la hora: esta entrada
/// deja de valer y SENUS se niega, que es lo que debe hacer. La tercera vale SOLO
/// para `build/agente_f_telefono/sistema.bin`, sha256 `655ead66…f2eed`: cotejada
/// con su `senus_tabla.json` (sha256 `b4e6e149…`), con `nm` sobre su ELF, con el id
/// dentro del binario y con el teléfono en el emulador. Esta tabla se quita
/// cuando no queden sis28h.
const List<EntradaPuente> tablaPuente = [
  EntradaPuente(
    id: 'PUEN1 Oct 28 2026 15:07:26',
    cargaVeto: 0x203C4CBC,
    hwCargaFuera: 0x44213DB0,
    reinicioCaliente: 0x44180524,
    build: 288,
    version: '0.28.8',
  ),
  EntradaPuente(
    id: 'PUEN1 Nov  1 2026 00:17:30',
    cargaVeto: 0x203C6CBC,
    hwCargaFuera: 0x44215DC8,
    reinicioCaliente: 0x44180524,
    build: 290,
    version: '0.29.0',
  ),
  EntradaPuente(
    id: 'PUEN1 Nov  1 2026 09:40:17',
    cargaVeto: 0x203C6CCC,
    hwCargaFuera: 0x442163D0,
    reinicioCaliente: 0x44180524,
    build: 291,
    version: '0.29.1',
  ),
];

EntradaPuente? entradaPuente(String id) {
  for (final e in tablaPuente) {
    if (e.id == id) return e;
  }
  return null;
}

/// `hw_entrar_bl` cierra la tarjeta antes de irse (`hwo_tarjeta_apagar`) y la
/// secuencia del puente no: la tabla no trae esa función y llamar por dirección
/// sin haberla medido es peor. Lo único seguro es dar tiempo a que acabe una
/// escritura en la M2 que acabe de empezar. Sospecha de la auditoría, sin medir.
const Duration esperaTarjetaPuente = Duration(milliseconds: 1500);

class PuenteError implements Exception {
  final String motivo;
  const PuenteError(this.motivo);
  @override
  String toString() => motivo;
}

class ClientePuente {
  final TransporteBl t;

  /// Cada cuánto se lee `PU_R_RES`.
  final Duration sondeo;
  final Duration plazo;
  final Duration esperaTarjeta;

  /// Lo que hay escrito en cada `ARG`. Un `null` obliga a escribirlo.
  final List<int?> _args = List<int?>.filled(6, null);
  int _seq = 0;

  ClientePuente(
    this.t, {
    this.sondeo = const Duration(milliseconds: 20),
    this.plazo = const Duration(seconds: 15),
    this.esperaTarjeta = esperaTarjetaPuente,
  });

  /// `PU_R_ID`: el identificador de la compilación, o null si este senew no
  /// lleva puente o lo que contesta no es el puente.
  Future<String?> identificador() async {
    Uint8List d;
    try {
      d = await t.controlIn(puRId, 0, 0, 60);
    } on TransporteError {
      return null; // STALL: sin -DPUENTE
    }
    if (d.length < 60 || ascii.decode(d.sublist(0, 4), allowInvalid: true) != 'PUEN') {
      return null;
    }
    final campo = d.sublist(32, 60);
    final fin = campo.indexOf(0);
    return latin1.decode(fin < 0 ? campo : campo.sublist(0, fin));
  }

  /// `PU_R_RES` (48 B): estado, seq, código y r0.
  Future<(int, int, int, int)> _res() async {
    final d = await t.controlIn(puRRes, 0, 0, 48);
    if (d.length < 16) throw const PuenteError('PU_R_RES corto.');
    final v = ByteData.sublistView(d);
    return (
      v.getUint8(0),
      v.getUint8(1),
      v.getInt32(4, Endian.little),
      v.getUint32(8, Endian.little)
    );
  }

  /// Una orden, nivel 0: las palabras que cambian por ARG y el GO.
  Future<int> _orden(int op, List<int> p) async {
    final a = [for (final x in p) x & 0xFFFFFFFF];
    while (a.length < 6) {
      a.add(0);
    }
    _seq = (_seq + 1) & 0xFF;
    for (var k = 0; k < 6; k++) {
      if (_args[k] == a[k]) continue;
      _args[k] = null;
      await t.controlOut(
          puRArg0 + k, a[k] & 0xFFFF, a[k] >> 16, Uint8List(0));
      _args[k] = a[k];
    }
    await t.controlOut(puRGo, op | (_seq << 8), 0, Uint8List(0));
    final fin = DateTime.now().add(plazo);
    while (true) {
      final (est, seq, cod, r0) = await _res();
      if (seq == _seq && (est == puStHecho || est == puStFalloCpu)) {
        if (est == puStFalloCpu) {
          throw const PuenteError('La orden del puente dio una excepción de CPU.');
        }
        if (cod != 0) throw PuenteError('El puente contestó el error $cod.');
        return r0;
      }
      if (DateTime.now().isAfter(fin)) {
        throw const PuenteError('El puente no contesta.');
      }
      await Future<void>.delayed(sondeo);
    }
  }

  /// La secuencia de `pu.py bootloader`: veto de carga, carga fuera, bandera
  /// BLOA y `reinicio_caliente`. NUNCA `hw_reiniciar`: cae al bootrom. Esta
  /// última llamada no vuelve: el USB se va.
  Future<void> entrarAlBl(EntradaPuente e) async {
    // Seguir la numeración del teléfono: un seq repetido daría por hecha la
    // orden con el HECHO de la anterior.
    _seq = (await _res()).$2;
    await Future<void>.delayed(esperaTarjeta);
    await _orden(puOpPoke, [e.cargaVeto, 1 | (1 << 8), 1]);
    await _orden(puOpLlamar, [e.hwCargaFuera, 0, 0, 0, 0, 0]);
    await _orden(puOpPoke,
        [blBandera, 4 | (2 << 8), blMagia, (~blMagia) & 0xFFFFFFFF]);
    try {
      await _orden(puOpLlamar, [e.reinicioCaliente, 0, 0, 0, 0, 0]);
    } on TransporteError {
      // Lo esperado: senew ya no está.
    } on PuenteError {
      // Tampoco contesta si saltó antes de acabar la orden.
    }
  }
}
