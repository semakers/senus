// Los puertos del flujo de actualización contra el W580 simulado: el mismo contrato que PuertosLibusb, sondeando el bus del simulado.

import 'dart:async';

import '../datos/actualizacion_senew.dart';
import '../datos/transporte_bl.dart';
import 'sesion_mtp.dart';
import 'transporte.dart' as mtp;
import 'transporte_emu.dart';

class PuertosEmu implements PuertosUsb {
  final String ruta;
  final Duration sondeo;
  const PuertosEmu(this.ruta, {this.sondeo = const Duration(milliseconds: 100)});

  @override
  Future<SesionMtp?> esperarSenew(Duration plazo) async {
    final t = TransporteEmu(ruta);
    final fin = DateTime.now().add(plazo);
    while (DateTime.now().isBefore(fin)) {
      final v = await t.enumerar();
      if (v.isNotEmpty) {
        try {
          await t.abrir(v.first);
        } on mtp.TransporteError {
          await Future<void>.delayed(sondeo);
          continue;                // se fue entre enumerar y abrir
        }
        final s = SesionMtp(t);
        final r = await s.abrir(tiempoMax: fin.difference(DateTime.now()));
        if (r.bien) return s;
        await s.cerrar();
        return null;
      }
      await Future<void>.delayed(sondeo);
    }
    return null;
  }

  @override
  Future<TransporteBl?> esperarBl(Duration plazo) async {
    final fin = DateTime.now().add(plazo);
    while (true) {
      for (final pid in const [pidBlPropio, pidBlInstaller]) {
        final t = TransporteBlEmu(ruta, pid: pid);
        final v = await t.enumerar();
        if (v.isNotEmpty) {
          await t.abrir(v.first);
          return t;
        }
      }
      if (DateTime.now().isAfter(fin)) return null;
      await Future<void>.delayed(sondeo);
    }
  }

  @override
  Future<TransporteBl?> abrirEp0Senew(Duration plazo) async {
    final t = TransporteBlEmu(ruta, pid: pidSenewNormal);
    final fin = DateTime.now().add(plazo);
    while (true) {
      final v = await t.enumerar();
      if (v.isNotEmpty) {
        await t.abrir(v.first);
        return t;
      }
      if (DateTime.now().isAfter(fin)) return null;
      await Future<void>.delayed(sondeo);
    }
  }
}
