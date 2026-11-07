// La parte del Bluetooth que depende de la plataforma, vista desde Dart. Existe en
// macOS (`macos/Runner/PuenteBluetooth*.swift`) y en Windows
// (`windows/runner/puente_bluetooth.cpp`, 6-nov-2026), con el mismo contrato; en
// Linux, y en una máquina sin Bluetooth, todo dice «no disponible» y la pantalla lo
// explica.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// El permiso de Bluetooth que da el sistema.
enum PermisoBt { concedido, denegado, restringido, sinDecidir }

class EstadoBt {
  /// El sistema operativo tiene puente: no lo hay en Linux.
  final bool plataforma;

  /// Esta máquina tiene radio Bluetooth.
  final bool hay;
  final PermisoBt permiso;
  final bool encendido;
  final String? direccion;

  /// Por qué no: se enseña tal cual.
  final String? motivo;

  const EstadoBt({
    required this.plataforma,
    required this.hay,
    required this.permiso,
    required this.encendido,
    this.direccion,
    this.motivo,
  });

  bool get disponible => plataforma && hay;
}

sealed class EventoBt {
  const EventoBt();
}

class BtConectado extends EventoBt {
  final int id;
  final String direccion;
  final bool emparejado;
  final int mtu;
  const BtConectado(this.id, this.direccion, this.emparejado, this.mtu);
}

class BtDatos extends EventoBt {
  final int id;
  final Uint8List datos;
  const BtDatos(this.id, this.datos);
}

class BtCerrado extends EventoBt {
  final int id;
  const BtCerrado(this.id);
}

/// armado, enlace, pin, hecho, ya, reintento, fallo. «reintento»: un intento de
/// esta Mac no salió y vendrá otro; no es el final, que lo pone el plazo de Dart.
class BtEmparejamiento extends EventoBt {
  final String direccion;
  final String estado;
  final int codigo;
  const BtEmparejamiento(this.direccion, this.estado, this.codigo);
}

class BtRegistro extends EventoBt {
  final String texto;
  const BtRegistro(this.texto);
}

class FalloNativo implements Exception {
  /// sin_adaptador, sin_permiso, apagado, sdp, escucha, direccion, canal,
  /// no_disponible…
  final String codigo;
  final String mensaje;
  const FalloNativo(this.codigo, this.mensaje);
  @override
  String toString() => mensaje;
}

abstract class PuenteNativo {
  Stream<EventoBt> get eventos;
  Future<EstadoBt> consultar();

  /// Publica el servicio y escucha; devuelve el canal RFCOMM. La primera vez abre
  /// el diálogo de permiso del sistema.
  Future<int> encender({required String nombre, required int canal});
  Future<void> apagar();

  /// A quién llama esta máquina mientras el servidor esté encendido: cada pocos
  /// segundos, a cada dirección sin canal ni llamada en curso, abre el RFCOMM
  /// [canal] del teléfono. Lo que conteste llega como [BtConectado], igual que un
  /// canal entrante. Sustituye la lista anterior; `apagar` la vacía.
  Future<void> vigilar(List<String> direcciones, int canal);
  Future<void> armarEmparejamiento(String direccion, String pin);
  Future<void> desarmarEmparejamiento();
  Future<bool> olvidar(String direccion);

  /// Completa cuando los bytes están en el hardware.
  Future<void> escribir(int id, Uint8List d);
  Future<void> cortar(int id);
}

const String motivoSinPuente =
    'En este sistema SENUS aún no puede ser puente Bluetooth: de momento solo '
    'funciona en macOS y Windows.';

class PuenteNoDisponible implements PuenteNativo {
  final String motivo;
  const PuenteNoDisponible([this.motivo = motivoSinPuente]);

  Never _no() => throw FalloNativo('no_disponible', motivo);

  @override
  Stream<EventoBt> get eventos => const Stream.empty();
  @override
  Future<EstadoBt> consultar() async => EstadoBt(
      plataforma: false,
      hay: false,
      permiso: PermisoBt.sinDecidir,
      encendido: false,
      motivo: motivo);
  @override
  Future<int> encender({required String nombre, required int canal}) async =>
      _no();
  @override
  Future<void> apagar() async {}
  @override
  Future<void> vigilar(List<String> direcciones, int canal) async {}
  @override
  Future<void> armarEmparejamiento(String direccion, String pin) async => _no();
  @override
  Future<void> desarmarEmparejamiento() async {}
  @override
  Future<bool> olvidar(String direccion) async => false;
  @override
  Future<void> escribir(int id, Uint8List d) async => _no();
  @override
  Future<void> cortar(int id) async {}
}

class PuenteNativoPlataforma implements PuenteNativo {
  static const _ordenes = MethodChannel('senus/puente_bt');
  static const _avisos = EventChannel('senus/puente_bt/eventos');

  late final Stream<EventoBt> _eventos =
      _avisos.receiveBroadcastStream().map(_evento).where((e) => e != null).cast();

  static EventoBt? _evento(dynamic m) {
    if (m is! Map) return null;
    switch (m['e']) {
      case 'conectado':
        return BtConectado(m['id'] as int, m['direccion'] as String,
            m['emparejado'] as bool, m['mtu'] as int);
      case 'datos':
        return BtDatos(m['id'] as int, m['datos'] as Uint8List);
      case 'cerrado':
        return BtCerrado(m['id'] as int);
      case 'emparejamiento':
        return BtEmparejamiento(m['direccion'] as String, m['estado'] as String,
            m['codigo'] as int);
      case 'registro':
        return BtRegistro(m['texto'] as String);
    }
    return null;
  }

  Future<T?> _llamar<T>(String metodo, [Map<String, Object?>? a]) async {
    try {
      return await _ordenes.invokeMethod<T>(metodo, a);
    } on PlatformException catch (e) {
      throw FalloNativo(e.code, e.message ?? e.code);
    } on MissingPluginException {
      throw const FalloNativo('no_disponible', motivoSinPuente);
    }
  }

  @override
  Stream<EventoBt> get eventos => _eventos;

  @override
  Future<EstadoBt> consultar() async {
    final Map<Object?, Object?>? m;
    try {
      m = await _llamar<Map<Object?, Object?>>('consultar');
    } on FalloNativo catch (e) {
      return EstadoBt(
          plataforma: false,
          hay: false,
          permiso: PermisoBt.sinDecidir,
          encendido: false,
          motivo: e.mensaje);
    }
    final hay = m?['hay'] == true;
    return EstadoBt(
      plataforma: true,
      hay: hay,
      permiso: switch (m?['permiso']) {
        'concedido' => PermisoBt.concedido,
        'denegado' => PermisoBt.denegado,
        'restringido' => PermisoBt.restringido,
        _ => PermisoBt.sinDecidir,
      },
      encendido: m?['encendido'] == true,
      direccion: m?['direccion'] as String?,
      motivo: hay ? null : 'Esta máquina no tiene Bluetooth.',
    );
  }

  @override
  Future<int> encender({required String nombre, required int canal}) async =>
      (await _llamar<int>('encender', {'nombre': nombre, 'canal': canal}))!;

  @override
  Future<void> apagar() => _llamar<void>('apagar');

  @override
  Future<void> vigilar(List<String> direcciones, int canal) =>
      _llamar<void>('vigilar', {'direcciones': direcciones, 'canal': canal});

  @override
  Future<void> armarEmparejamiento(String direccion, String pin) =>
      _llamar<void>(
          'armarEmparejamiento', {'direccion': direccion, 'pin': pin});

  @override
  Future<void> desarmarEmparejamiento() =>
      _llamar<void>('desarmarEmparejamiento');

  @override
  Future<bool> olvidar(String direccion) async =>
      await _llamar<bool>('olvidar', {'direccion': direccion}) ?? false;

  @override
  Future<void> escribir(int id, Uint8List d) =>
      _llamar<void>('escribir', {'id': id, 'datos': d});

  @override
  Future<void> cortar(int id) => _llamar<void>('cortar', {'id': id});
}

/// El de esta máquina.
PuenteNativo puenteNativoDeEstaMaquina() =>
    Platform.isMacOS || Platform.isWindows
        ? PuenteNativoPlataforma()
        : const PuenteNoDisponible();
