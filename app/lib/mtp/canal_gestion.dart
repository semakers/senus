// El canal de gestión MTP de senew, del lado de SENUS. Contrato:
// docs/contrato_canal_gestion.md. Cada orden es una operación MTP de vendedor
// sobre la sesión abierta, así que hereda el «Sí» del teléfono.
//
// Un senew sin canal (sis28h) no llega aquí: quien mira es
// [Telefono.canalGestion], que sale de OperationsSupported.

import 'dart:async';
import 'dart:typed_data';

import 'canal_datos.dart';
import 'operaciones.dart';
import 'sesion_mtp.dart';

export 'canal_datos.dart';

/// Una orden del canal que el teléfono rechazó.
class CanalError implements Exception {
  final int codigo;
  final String motivo;
  const CanalError(this.codigo, this.motivo);
  @override
  String toString() =>
      '$motivo (0x${codigo.toRadixString(16).padLeft(4, '0')})';
}

/// Qué pasó con `SEN_ENTRAR_BL`.
enum RespuestaEntrarBl {
  /// Dijo «Sí»: el teléfono suelta el USB y entra al bootloader.
  aceptada,

  /// Dijo «No». Nada cambió.
  denegada,

  /// Nadie contestó en el teléfono dentro del plazo.
  sinRespuesta,

  /// `R_OP_NO`: este sistema no tiene BL (W600, W810). No es un fallo.
  noDisponible,
}

/// Lo que devuelve `SEN_AJ_PONER` en los parámetros de la respuesta.
class RespuestaPoner {
  final int aplicadas;
  final int fueraDeRango;
  final int desconocidas;
  const RespuestaPoner(this.aplicadas, this.fueraDeRango, this.desconocidas);
}

class CanalGestion {
  final SesionMtp sesion;

  /// Mientras el firmware contesta `R_OCUPADO`, cuánto esperar entre intentos
  /// y hasta cuándo.
  final Duration pausaOcupado;
  final Duration plazoOcupado;

  CanalGestion(
    this.sesion, {
    this.pausaOcupado = const Duration(milliseconds: 200),
    this.plazoOcupado = const Duration(seconds: 10),
  });

  Future<(int, List<int>, Uint8List)> _conReintento(
    int op,
    List<int> params, {
    Uint8List? salida,
    bool entrada = false,
  }) async {
    final fin = DateTime.now().add(plazoOcupado);
    while (true) {
      final r = await sesion.operacion(op, params,
          datosSalida: salida, esperaDatos: entrada);
      if (r.$1 != rOcupado || DateTime.now().isAfter(fin)) return r;
      await Future<void>.delayed(pausaOcupado);
    }
  }

  static String _nombre(int op) => 'orden 0x${op.toRadixString(16)}';

  Never _fallo(int op, int cod) {
    final texto = switch (cod) {
      rOcupado => 'El teléfono sigue ocupado',
      rDenegado => 'El teléfono dijo que no',
      rParamMal => 'El teléfono rechazó los datos: no se aplicó nada',
      rOpNo => 'Este senew no implementa esa orden',
      rSinSesion => 'No hay sesión abierta con el teléfono',
      _ => 'El teléfono contestó con un error en la ${_nombre(op)}',
    };
    throw CanalError(cod, texto);
  }

  /// `SEN_INFO`.
  Future<SenInfo> info() async {
    final (cod, _, d) = await _conReintento(opSenInfo, const [], entrada: true);
    if (cod != rOk) _fallo(opSenInfo, cod);
    return SenInfo.deBytes(d);
  }

  /// `SEN_AJ_LEER`. Mientras haya cambios sin aplicar, el firmware dice
  /// `R_OCUPADO`: por eso esta lectura ya espera a que acaben.
  Future<List<AjusteLeido>> leerAjustes() async {
    final (cod, _, d) =
        await _conReintento(opSenAjLeer, const [], entrada: true);
    if (cod != rOk) _fallo(opSenAjLeer, cod);
    return parsearAjustes(d);
  }

  /// `SEN_AJ_PONER`. Solo dice qué aceptó: la confirmación por clave es releer.
  Future<RespuestaPoner> ponerAjustes(List<AjustePoner> l) async {
    final (cod, p, _) = await _conReintento(opSenAjPoner, const [],
        salida: empaquetarAjustes(l));
    if (cod != rOk) _fallo(opSenAjPoner, cod);
    int par(int i) => i < p.length ? p[i] : 0;
    return RespuestaPoner(par(0), par(1), par(2));
  }

  /// `SEN_RELOJ`. Lo que el firmware rechazaría ni se manda.
  Future<void> ponerReloj(DateTime utc, int zonaMin) async {
    if (!relojValido(utc, zonaMin)) {
      throw CanalError(
          rParamMal,
          'El teléfono solo admite años 2000..2099 y zonas de -12:00 a +14:00 '
          '(${utc.toUtc().year}, $zonaMin min)');
    }
    final (cod, _, _) = await _conReintento(opSenReloj, const [],
        salida: empaquetarReloj(utc, zonaMin));
    if (cod != rOk) _fallo(opSenReloj, cod);
  }

  /// `SEN_VINCULAR`. Quien llama ya comprobó que `id_aparato` está vacío o
  /// difiere (§4 del contrato).
  Future<void> vincular(String id) async {
    final (cod, _, _) = await _conReintento(opSenVincular, const [],
        salida: empaquetarVincular(id));
    if (cod != rOk) _fallo(opSenVincular, cod);
  }

  /// `SEN_BT_ESTADO`.
  Future<BtEstado> btEstado() async {
    final (cod, _, d) =
        await _conReintento(opSenBtEstado, const [], entrada: true);
    if (cod != rOk) _fallo(opSenBtEstado, cod);
    return BtEstado.deBytes(d);
  }

  /// `SEN_BT_EMPAREJAR`: solo encola. El resultado se lee sondeando [btEstado].
  /// Con una app en pantalla contesta `R_OCUPADO`, y aquí se reintenta.
  Future<void> emparejar(List<int> addr, String pin) async {
    final (cod, _, _) = await _conReintento(opSenBtEmparejar, const [],
        salida: empaquetarEmparejar(addr, pin));
    if (cod != rOk) _fallo(opSenBtEmparejar, cod);
  }

  /// `SEN_ENTRAR_BL` (§5): la primera llamada abre «¿Actualizar el sistema?»
  /// en el teléfono y contesta `R_OCUPADO`. Se reintenta cada 500 ms hasta 60 s.
  /// También contesta `R_OCUPADO` mientras haya ajustes sin aplicar.
  Future<RespuestaEntrarBl> entrarBl({
    Duration pausa = const Duration(milliseconds: 500),
    Duration plazo = const Duration(seconds: 60),
  }) async {
    final fin = DateTime.now().add(plazo);
    while (true) {
      final (cod, _, _) = await sesion.operacion(opSenEntrarBl, const []);
      if (cod == rOk) return RespuestaEntrarBl.aceptada;
      if (cod == rDenegado) return RespuestaEntrarBl.denegada;
      if (cod == rOpNo) return RespuestaEntrarBl.noDisponible;
      if (cod != rOcupado) _fallo(opSenEntrarBl, cod);
      if (DateTime.now().isAfter(fin)) return RespuestaEntrarBl.sinRespuesta;
      await Future<void>.delayed(pausa);
    }
  }

  /// `SEN_APPS`, todas las páginas: hasta 64 entradas, 7 por página. Si la lista cambia mientras se recorre
  /// (`total` distinto entre páginas), empieza otra vez: una lista mezclada
  /// haría borrar lo que no es.
  Future<List<SenApp>> apps() async {
    for (var vuelta = 0; vuelta < 3; vuelta++) {
      final out = <SenApp>[];
      int? total;
      var cambio = false;
      while (true) {
        final (cod, _, d) =
            await _conReintento(opSenApps, [out.length], entrada: true);
        if (cod != rOk) _fallo(opSenApps, cod);
        final pag = PaginaApps.deBytes(d);
        if (total != null && pag.total != total) {
          cambio = true;
          break;
        }
        total = pag.total;
        out.addAll(pag.apps);
        if (out.length >= pag.total) break;
        if (pag.apps.isEmpty) {
          throw CanalMalFormado(
              'SEN_APPS dijo ${pag.total} apps y se quedó en ${out.length}.');
        }
      }
      if (!cambio) return out;
    }
    throw const CanalError(rOcupado, 'La lista de apps no deja de cambiar');
  }
}
