// Modo recuperación: el teléfono está en su bootloader (1209:0002 o 1209:0003).
// Antes, un teléfono ahí parecía «ningún teléfono». Reanuda desde lo guardado
// antes de borrar; sin nada guardado, deja salir o elegir una versión.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../datos/actualizacion_senew.dart';
import '../datos/backend_semakers.dart';
import '../datos/indice_semakers.dart';
import '../datos/telefono.dart';
import '../datos/transporte_bl.dart';
import '../mtp/sesion_mtp.dart';
import '../tema/senus_tema.dart';
import 'comunes.dart';
import 'pant_version.dart' show ContextoActualizacion;

class PantRecuperacion extends StatefulWidget {
  final Telefono telefono;
  final ContextoActualizacion? contexto;
  final void Function(SesionMtp sesion, Telefono telefono)? onSesionNueva;

  /// Mientras graba no se cambia de pantalla.
  final ValueChanged<bool>? onOcupado;
  const PantRecuperacion({
    super.key,
    required this.telefono,
    this.contexto,
    this.onSesionNueva,
    this.onOcupado,
  });

  @override
  State<PantRecuperacion> createState() => _PantRecuperacionState();
}

class _PantRecuperacionState extends State<PantRecuperacion> {
  ContextoActualizacion? _ctx;
  Pendiente? _pendiente;
  List<ReleaseIndice> _releases = const [];
  bool _cargando = true;
  bool _corriendo = false;
  ResultadoAct? _fin;
  final List<String> _log = [];
  double? _progreso;
  String? _aviso;
  String? _errorCarga;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    Pendiente? q;
    var rel = const <ReleaseIndice>[];
    String? error;
    try {
      final c = _ctx ??=
          widget.contexto ?? await ContextoActualizacion.predeterminado();
      q = await c.almacen.leerPendiente();
      if (q == null) {
        try {
          rel = (await c.backend.indice()).indice.releasesDe('w580');
        } on SinRed {
          // Sin red y sin nada guardado no hay imagen que ofrecer.
        } on ErrorVerificacion {
          // Tampoco hay imagen en la que confiar.
        }
      }
    } catch (e) {
      // Disco, caché, lo que sea: se dice en la pantalla, no se escapa.
      error = 'No se pudo leer lo guardado: $e';
    }
    if (!mounted) return;
    setState(() {
      _pendiente = q;
      _releases = rel;
      _errorCarga = error;
      _cargando = false;
    });
  }

  ActualizadorSenew _actualizador() {
    final c = _ctx!;
    return ActualizadorSenew(
      puertos: c.puertos,
      backend: c.backend,
      almacen: c.almacen,
      confirmar: (_) async => true,
      alEvento: (e) {
        if (!mounted) return;
        setState(() {
          if (e.linea != null) _log.add(e.linea!);
          if (e.paso != null) {
            _log.add('— ${e.paso!.titulo}');
            _aviso = null;
          }
          if (e.aviso != null) _aviso = e.aviso;
          if (e.progreso != null) _progreso = e.progreso;
        });
      },
    );
  }

  Future<void> _correr(Future<ResultadoAct> Function() trabajo) async {
    widget.onOcupado?.call(true);
    setState(() {
      _corriendo = true;
      _fin = null;
      _log.clear();
      _progreso = null;
      _aviso = null;
    });
    ResultadoAct r;
    try {
      r = await trabajo();
    } catch (e) {
      r = ResultadoAct(FinAct.fallo, 'Error inesperado: $e');
    }
    widget.onOcupado?.call(false);
    if (!mounted) return;
    setState(() {
      _corriendo = false;
      _fin = r;
      _aviso = null;
    });
    final s = r.sesion, t = r.telefono;
    if (s != null && t != null) widget.onSesionNueva?.call(s, t);
    await _cargar();
  }

  Future<void> _reanudar() => _correr(() => _actualizador().recuperar());
  Future<void> _salir() => _correr(() => _actualizador().salirDelBl());

  Future<void> _grabar(ReleaseIndice r) => _correr(() async {
        final act = _actualizador();
        final d = await _ctx!.backend.descargarRelease(r);
        return act.recuperarCon(
          imagen: d.main,
          build: r.build,
          version: r.version,
          manifiesto: d.manifiesto,
        );
      });

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    final pid = widget.telefono.pidBootloader ?? pidBlPropio;
    final q = _pendiente;
    return ListView(
      padding: const EdgeInsets.only(bottom: Esp.x8),
      children: [
        CabeceraPantalla(
          titulo: 'Modo recuperación',
          subtitulo: 'Teléfono en el bootloader  ·  1209:'
              '${pid.toRadixString(16).padLeft(4, '0')}',
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Esp.x8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const FranjaAviso(
                  'El teléfono está parado en su bootloader. Es recuperable: no '
                  'desconectes el cable ni le quites la batería mientras SENUS '
                  'graba.'),
              const SizedBox(height: Esp.x4),
              if (_errorCarga != null) ...[
                AvisoError(_errorCarga!),
                const SizedBox(height: Esp.x4),
              ],
              if (_cargando)
                const Center(child: CircularProgressIndicator())
              else if (q != null)
                Superficie(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Hay una actualización a medias',
                          style: context.tipo.titleMedium),
                      const SizedBox(height: Esp.x1),
                      Text('Hacia ${q.versionDestino} (build ${q.buildDestino}), '
                          'desde el build ${q.buildOrigen}. Lo necesario se '
                          'guardó antes de borrar.',
                          style: context.tipo.bodyMedium?.copyWith(color: c.textoTenue)),
                      const SizedBox(height: Esp.x3),
                      FilledButton.icon(
                        onPressed: _corriendo ? null : _reanudar,
                        icon: const Icon(Symbols.play_arrow, size: 20),
                        label: const Text('Reanudar'),
                      ),
                    ],
                  ),
                )
              else ...[
                Superficie(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('No hay nada a medias', style: context.tipo.titleMedium),
                      const SizedBox(height: Esp.x1),
                      Text(
                        'Si el teléfono tiene su sistema entero, basta con salir '
                        'del bootloader.',
                        style: context.tipo.bodyMedium?.copyWith(color: c.textoTenue),
                      ),
                      const SizedBox(height: Esp.x3),
                      OutlinedButton.icon(
                        onPressed: _corriendo ? null : _salir,
                        icon: const Icon(Symbols.logout, size: 20),
                        label: const Text('Salir del bootloader'),
                      ),
                    ],
                  ),
                ),
                if (_releases.isNotEmpty) ...[
                  const SizedBox(height: Esp.x4),
                  Text('O GRABAR UNA VERSIÓN', style: context.tipo.labelSmall),
                  const SizedBox(height: Esp.x2),
                  for (final r in _releases)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Esp.x2),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text('${r.version} (build ${r.build})',
                                style: context.tipo.bodyMedium),
                          ),
                          OutlinedButton(
                            onPressed: _corriendo ? null : () => _grabar(r),
                            child: const Text('Grabar'),
                          ),
                        ],
                      ),
                    ),
                ],
              ],
              if (_corriendo) ...[
                const SizedBox(height: Esp.x4),
                LinearProgressIndicator(value: _progreso),
              ],
              if (_corriendo && _aviso != null) ...[
                const SizedBox(height: Esp.x4),
                FranjaAviso(_aviso!),
              ],
              if (_fin != null) ...[
                const SizedBox(height: Esp.x4),
                _fin!.bien || _fin!.fin == FinAct.sinVuelta
                    ? FranjaAviso('${_fin!.mensaje}'
                        '${_fin!.remedio == null ? '' : '\n${_fin!.remedio}'}')
                    : AvisoError('${_fin!.mensaje}'
                        '${_fin!.remedio == null ? '' : '\n${_fin!.remedio}'}'),
              ],
              if (_log.isNotEmpty) ...[
                const SizedBox(height: Esp.x4),
                SelectableText(_log.join('\n'),
                    style: estiloDatos(context, tam: 11)),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
