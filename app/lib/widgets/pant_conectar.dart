// V1 — Conectar. Lista dispositivos USB con VID/PID de senew y pide elegir uno.
// Al pulsar: TransporteMtp.elegir() → enumerar() → abrir() → OpenSession → GetDeviceInfo.
// Si libusb no está, enseña el error exacto en vez de reventar.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../datos/conexion_telefono.dart';
import '../datos/puertos_libusb.dart';
import '../datos/respaldo_rollback.dart';
import '../datos/seftool.dart';
import '../datos/telefono.dart';
import '../mtp/sesion_mtp.dart';
import '../mtp/transporte.dart';
import '../tema/senus_tema.dart';
import 'comunes.dart';

/// Resultado de una conexión exitosa — lo pasa a la pantalla siguiente.
///
/// `sesion` es null cuando el aparato es DE FÁBRICA: ahí no hay MTP, se le
/// encontró por el cable serie y lo único que se puede hacer es el respaldo
/// de rollback y la instalación.
class ConexionViva {
  final SesionMtp? sesion;
  final Telefono telefono;
  ConexionViva(this.sesion, this.telefono);
}

class PantConectar extends StatefulWidget {
  final void Function(ConexionViva) onConectado;
  final ThemeMode modo;
  final ValueChanged<ThemeMode> onModo;

  /// «Mi W580 todavía no tiene senew»: va derecho a instalarlo. Null → no se
  /// ofrece (las pruebas que no lo necesitan).
  final VoidCallback? onInstalarSenew;

  /// El apartado Conexión, que no necesita cable. Null → no se ofrece.
  final VoidCallback? onConexion;

  /// De dónde salen el transporte y la búsqueda del BL. Las pruebas los
  /// inyectan para no tocar el USB de verdad.
  final TransporteMtp Function() elegirTransporte;
  final Future<int?> Function() buscarBl;
  const PantConectar({
    super.key,
    required this.onConectado,
    required this.modo,
    required this.onModo,
    this.onInstalarSenew,
    this.onConexion,
    this.elegirTransporte = TransporteMtp.elegir,
    this.buscarBl = buscarBootloader,
  });

  @override
  State<PantConectar> createState() => _PantConectarState();
}

class _PantConectarState extends State<PantConectar> {
  bool _conectando = false;
  String? _error;
  /// Puerto serie que se está interrogando, si estamos en el segundo intento.
  String? _buscandoFabrica;

  Future<void> _conectar() async {
    setState(() {
      _conectando = true;
      _error = null;
    });
    TransporteMtp? t;
    SesionMtp? s;
    try {
      t = widget.elegirTransporte();
      final vistos = await t.enumerar();
      if (vistos.isEmpty) {
        // Sin senew: ¿está parado en su bootloader? Antes parecía «ningún
        // teléfono»; es lo que queda tras un corte a media actualización.
        if (await _probarBootloader()) return;
        // Tampoco: a lo mejor es un aparato DE FÁBRICA por el cable serie.
        if (await _probarDeFabrica()) return;
        setState(() => _error =
            'No se detectó ningún teléfono con senew. Enchufa el cable USB '
            'y acepta en el teléfono el aviso «Conectado por USB».\n'
            '$avisoEncendido');
        return;
      }
      final d = vistos.first;
      await t.abrir(d);
      s = SesionMtp(t);
      final rAbrir = await s.abrir(tiempoMax: const Duration(seconds: 30));
      if (!rAbrir.bien) {
        setState(() => _error = rAbrir.mensaje ??
            'El teléfono no abrió la sesión MTP.');
        await s.cerrar();
        return;
      }
      final info = await leerTelefono(s);
      if (!info.bien) {
        setState(() => _error = info.mensaje ??
            'No se pudo leer la información del teléfono.');
        await s.cerrar();
        return;
      }
      widget.onConectado(ConexionViva(s, info.valor!));
    } on TransporteError catch (e) {
      // libusb no está, el socket no responde, falló claim, etc. Antes de
      // darlo por perdido: ¿hay un aparato de fábrica en el cable serie?
      try { await s?.cerrar(); } catch (_) {}
      if (await _probarBootloader()) return;
      if (await _probarDeFabrica()) return;
      setState(() => _error = e.motivo);
    } catch (e) {
      try { await s?.cerrar(); } catch (_) {}
      setState(() => _error = 'Error inesperado: $e');
    } finally {
      if (mounted) setState(() => _conectando = false);
    }
  }

  /// ¿Hay un teléfono en 1209:0002 o 1209:0003? Si lo hay, a recuperación.
  Future<bool> _probarBootloader() async {
    try {
      final pid = await widget.buscarBl();
      if (pid == null) return false;
      if (mounted) {
        widget.onConectado(ConexionViva(null, Telefono.enBootloader(pid)));
      }
      return true;
    } on TransporteError {
      return false;
    }
  }

  /// Segundo intento: no hay teléfono con senew por USB, pero puede haber uno
  /// DE FÁBRICA al otro lado de un cable serie. Se le pregunta con
  /// `seftool identify`; si contesta, se entra con `deFabrica: true` y SENUS
  /// lleva derecho al respaldo de rollback.
  ///
  /// Prudencia: esto SÓLO corre cuando el camino MTP no dio nada, no se
  /// intenta en paralelo, y si no hay puerto o no está seftool se calla y
  /// deja el mensaje normal de «no veo tu teléfono».
  Future<bool> _probarDeFabrica() async {
    if (EjecutorRespaldo.decidirSimulado()) return false; // bridge_mock
    final puerto = Platform.environment['SENUS_PUERTO']?.trim().isNotEmpty ==
            true
        ? Platform.environment['SENUS_PUERTO']!.trim()
        : Seftool.autodetectarPuerto();
    if (puerto == null) return false;

    final sef = Seftool(raiz: Seftool.raizPredeterminada, puerto: puerto);
    try {
      sef.exigirBinario();
    } on SeftoolError {
      return false; // sin seftool no hay camino de fábrica; ni se menciona
    }

    setState(() => _buscandoFabrica = puerto);
    try {
      final info = await sef.identify();
      final tel = Telefono(
        modelo: modeloDeNombre('${info.modeloCorto} '),
        nombreAmigo: '${info.modeloCorto} de fábrica',
        serie: info.imei,
        versionSenew: '—',
        almacenes: const [],
        deFabrica: true,
        cid: info.cid,
        color: info.color,
        firmwareOriginal: info.cxcVersion,
        puertoSerie: puerto,
      );
      if (!mounted) return true;
      widget.onConectado(ConexionViva(null, tel));
      return true;
    } on SeftoolError {
      // Había puerto pero no contestó: no es nuestro aparato, o no está en
      // modo servicio. Que siga el mensaje normal.
      return false;
    } catch (_) {
      return false;
    } finally {
      if (mounted) setState(() => _buscandoFabrica = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    final oscuro = widget.modo != ThemeMode.light;
    return Scaffold(
      body: Stack(
        children: [
          // Resplandor ámbar detrás del logo, como la luz del teclado Walkman.
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0, -0.42),
                  radius: 0.9,
                  colors: [c.acento.withAlpha(oscuro ? 38 : 30), c.fondo.withAlpha(0)],
                ),
              ),
            ),
          ),
          Positioned(
            top: Esp.x4,
            right: Esp.x4,
            child: IconButton(
              tooltip: oscuro ? 'Modo claro' : 'Modo oscuro',
              icon: Icon(oscuro ? Symbols.light_mode : Symbols.dark_mode),
              onPressed: () => widget.onModo(oscuro ? ThemeMode.light : ThemeMode.dark),
            ),
          ),
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(Esp.x8, Esp.x6, Esp.x8, Esp.x8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const EntradaSuave(desplazamiento: 20, child: MarcaSenus(compacta: false)),
                    const SizedBox(height: Esp.x6),
                    EntradaSuave(
                      retraso: escalon(2),
                      child: Column(
                        children: [
                          // En la ventana de 800x600 el aro no cabe junto al aviso de error.
                          if (_error == null) ...[
                            _IconoCable(activo: _conectando),
                            const SizedBox(height: Esp.x4),
                          ],
                          Text('Conecta tu teléfono por el cable USB',
                              textAlign: TextAlign.center,
                              style: context.tipo.headlineSmall),
                          const SizedBox(height: Esp.x2),
                          Text(
                            'Con senew encendido, pulsa Conectar y acepta en el '
                            'teléfono el aviso «Conectado por USB».',
                            textAlign: TextAlign.center,
                            style: context.tipo.bodyMedium?.copyWith(color: c.textoTenue),
                          ),
                          if (_error == null) ...[
                            const SizedBox(height: Esp.x2),
                            Text(avisoEncendido,
                                textAlign: TextAlign.center,
                                style: context.tipo.bodySmall
                                    ?.copyWith(color: c.textoTenue)),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: Esp.x6),
                    AnimatedSize(
                      duration: Mov.normal,
                      curve: Mov.curva,
                      child: _error == null
                          ? const SizedBox(width: double.infinity)
                          : Padding(
                              padding: const EdgeInsets.only(bottom: Esp.x6),
                              child: AvisoError(_error!),
                            ),
                    ),
                    EntradaSuave(
                      retraso: escalon(3),
                      child: Center(
                        child: Pulsable(
                          activo: !_conectando,
                          child: SizedBox(
                            width: 300,
                            height: 56,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(Rad.medio),
                                boxShadow: _conectando ? null : c.resplandor(),
                              ),
                              child: FilledButton.icon(
                                onPressed: _conectando ? null : _conectar,
                                icon: _conectando
                                    ? SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2.2, color: c.acento),
                                      )
                                    : const Icon(Symbols.cable, size: 22),
                                label: Text(_conectando ? 'Conectando…' : 'Conectar',
                                    style: context.tipo.titleMedium
                                        ?.copyWith(color: _conectando ? c.textoTenue : c.sobreAcento)),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (_buscandoFabrica != null) ...[
                      const SizedBox(height: Esp.x3),
                      Center(
                        child: Text(
                          'Sin senew por USB. Preguntando por el cable serie '
                          '($_buscandoFabrica)…',
                          textAlign: TextAlign.center,
                          style: context.tipo.bodySmall
                              ?.copyWith(color: c.textoTenue),
                        ),
                      ),
                    ],
                    if (widget.onInstalarSenew != null) ...[
                      const SizedBox(height: Esp.x8),
                      EntradaSuave(
                        retraso: escalon(4),
                        child: _TarjetaInstalar(
                            onTap: _conectando ? null : widget.onInstalarSenew!),
                      ),
                    ],
                    const SizedBox(height: Esp.x3),
                    Center(
                      child: TextButton.icon(
                        onPressed: _ayuda,
                        icon: const Icon(Symbols.help, size: 18),
                        label: const Text('No ve mi teléfono'),
                      ),
                    ),
                    if (widget.onConexion != null)
                      Center(
                        child: TextButton.icon(
                          key: const ValueKey('abrirConexion'),
                          onPressed: _conectando ? null : widget.onConexion,
                          icon: const Icon(Symbols.bluetooth, size: 18),
                          label: const Text('Internet por Bluetooth'),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: Esp.x3,
            // (6-nov-2026) solo lo que está soportado: el W600i y el W810i aún no
            child: Text('semakers  ·  W580i',
                textAlign: TextAlign.center, style: estiloDatos(context, tam: 11)),
          ),
        ],
      ),
    );
  }

  void _ayuda() {
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        icon: Icon(Symbols.cable, color: context.col.acento),
        title: const Text('No ve tu teléfono'),
        content: const SingleChildScrollView(
          child: Text(
            'Comprueba, en este orden:\n\n'
            '1. El cable es el bueno (de datos, no solo de carga).\n'
            '2. En el teléfono, acepta el aviso «Conectado por USB». '
            '$avisoEncendido\n'
            '3. En Windows, el teléfono necesita el driver WinUSB: con Zadig, '
            'elige el aparato (Options → List All Devices), pon «WinUSB» y '
            'pulsa Replace Driver. Una vez por aparato.\n'
            '4. En Linux, puede faltar la regla udev para VID 1209:0001 (sin ella, hace falta sudo).\n'
            '5. En macOS, necesitas libusb instalada (`brew install libusb` o compilarla a mano).\n'
            '6. Para validar la lógica MTP sin un teléfono real, exporta '
            'SENUS_TRANSPORTE=socket:/tmp/senus-bridge.sock y arranca '
            'experimentos/bridge_mtp_socket.py.',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cerrar')),
        ],
      ),
    );
  }
}

/// La invitación a instalar senew: para quien todavía no lo tiene.
class _TarjetaInstalar extends StatelessWidget {
  final VoidCallback? onTap;
  const _TarjetaInstalar({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    return Container(
      padding: const EdgeInsets.all(Esp.x4),
      decoration: BoxDecoration(
        color: c.superficieElevada,
        borderRadius: BorderRadius.circular(Rad.medio),
        border: Border.all(color: c.borde),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Symbols.rocket_launch, color: c.acento, size: 22),
            const SizedBox(width: Esp.x3),
            Expanded(
              child: Text('¿Tu W580 todavía no tiene senew?',
                  style: context.tipo.titleSmall),
            ),
          ]),
          const SizedBox(height: Esp.x2),
          Text(
            'Instálalo desde aquí: SENUS respalda tu teléfono, le sube el '
            'instalador y graba senew. Necesitas el cable, el teléfono con su '
            'firmware original de Sony Ericsson, SIM y pantalla.',
            style: context.tipo.bodySmall?.copyWith(color: c.textoTenue),
          ),
          const SizedBox(height: Esp.x3),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const ValueKey('instalarSenew'),
              onPressed: onTap,
              icon: const Icon(Symbols.arrow_forward, size: 18),
              label: const Text('Instalar senew en mi W580'),
            ),
          ),
        ],
      ),
    );
  }
}

/// El conector USB dentro de un anillo; late suave mientras se conecta.
class _IconoCable extends StatefulWidget {
  final bool activo;
  const _IconoCable({required this.activo});

  @override
  State<_IconoCable> createState() => _IconoCableState();
}

class _IconoCableState extends State<_IconoCable> with SingleTickerProviderStateMixin {
  late final AnimationController _a =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void didUpdateWidget(covariant _IconoCable old) {
    super.didUpdateWidget(old);
    if (widget.activo && !_a.isAnimating) {
      _a.repeat(reverse: true);
    } else if (!widget.activo && _a.isAnimating) {
      _a.animateTo(0, duration: Mov.normal);
    }
  }

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    return AnimatedBuilder(
      animation: _a,
      builder: (_, __) {
        final v = Curves.easeInOut.transform(_a.value);
        return Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: c.acentoApagado,
            border: Border.all(color: c.acento.withAlpha((60 + 140 * v).round()), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: c.acento.withAlpha((50 * v).round()),
                blurRadius: 24,
                spreadRadius: 4 * v,
              ),
            ],
          ),
          child: Icon(Symbols.usb, color: c.acento, size: 26, weight: 500),
        );
      },
    );
  }
}
