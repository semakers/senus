// Los puertos reales del flujo de actualización: sondean el USB de verdad con
// los transportes de siempre. Con SENUS_TRANSPORTE=socket… usan el bridge.

import 'dart:async';

import '../mtp/sesion_mtp.dart';
import '../mtp/transporte.dart' as mtp;
import 'actualizacion_senew.dart';
import 'transporte_bl.dart';

class PuertosLibusb implements PuertosUsb {
  final Duration sondeo;
  const PuertosLibusb({this.sondeo = const Duration(milliseconds: 500)});

  @override
  Future<SesionMtp?> esperarSenew(Duration plazo) async {
    final t = mtp.TransporteMtp.elegir();
    final fin = DateTime.now().add(plazo);
    while (DateTime.now().isBefore(fin)) {
      // Durante un reinicio el USB falla a ratos: se sigue hasta el plazo.
      try {
        final v = await t.enumerar();
        if (v.isNotEmpty) {
          await t.abrir(v.first);
          final s = SesionMtp(t);
          final r = await s.abrir(tiempoMax: fin.difference(DateTime.now()));
          if (r.bien) return s;
          await s.cerrar();
          return null;
        }
      } on mtp.TransporteError {
        await t.cerrar();
      }
      await Future<void>.delayed(sondeo);
    }
    return null;
  }

  @override
  Future<TransporteBl?> esperarBl(Duration plazo) async {
    // Fuera del bucle: cada transporte libusb abre su contexto.
    final candidatos = [
      for (final pid in const [pidBlPropio, pidBlInstaller])
        TransporteBl.elegir(vid: vidSenew, pid: pid)
    ];
    final fin = DateTime.now().add(plazo);
    while (true) {
      for (final t in candidatos) {
        try {
          final v = await t.enumerar();
          if (v.isNotEmpty) {
            await t.abrir(v.first);
            return t;
          }
        } on mtp.TransporteError {
          await t.cerrar();
        }
      }
      if (DateTime.now().isAfter(fin)) return null;
      await Future<void>.delayed(sondeo);
    }
  }

  @override
  Future<TransporteBl?> abrirEp0Senew(Duration plazo) async {
    final t = TransporteBl.elegir(
        vid: vidSenew, pid: pidSenewNormal, fijarConfiguracion: false);
    final fin = DateTime.now().add(plazo);
    while (true) {
      try {
        final v = await t.enumerar();
        if (v.isNotEmpty) {
          await t.abrir(v.first);
          return t;
        }
      } on mtp.TransporteError {
        await t.cerrar();
      }
      if (DateTime.now().isAfter(fin)) return null;
      await Future<void>.delayed(sondeo);
    }
  }
}

/// ¿Hay un teléfono parado en su bootloader? Devuelve su PID o null.
Future<int?> buscarBootloader() async {
  for (final pid in const [pidBlPropio, pidBlInstaller]) {
    final t = TransporteBl.elegir(vid: vidSenew, pid: pid);
    if ((await t.enumerar()).isNotEmpty) return pid;
  }
  return null;
}
