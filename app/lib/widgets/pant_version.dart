// Versión de senew: la instalada, «Actualizar» y elegir otra, también anterior.
// El flujo entero vive en `actualizacion_senew.dart`; aquí solo se enseña por
// dónde va y se le pregunta a la persona.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../datos/actualizacion_senew.dart';
import '../datos/backend_semakers.dart';
import '../datos/indice_semakers.dart';
import '../datos/puertos_libusb.dart';
import '../datos/servicios_senus.dart';
import '../datos/telefono.dart';
import '../mtp/sesion_mtp.dart';
import '../tema/senus_tema.dart';
import 'comunes.dart';

/// Todo lo que el flujo necesita de fuera. Las pruebas lo inyectan.
class ContextoActualizacion {
  final ClienteBackend backend;
  final PuertosUsb puertos;
  final AlmacenActualizacion almacen;
  const ContextoActualizacion({
    required this.backend,
    required this.puertos,
    required this.almacen,
  });

  static Future<ContextoActualizacion> predeterminado() async =>
      ContextoActualizacion(
        backend: await backendPredeterminado(),
        puertos: const PuertosLibusb(),
        almacen: await almacenPredeterminado(),
      );
}

class PantVersion extends StatefulWidget {
  final Telefono telefono;
  final SesionMtp? sesion;
  final ContextoActualizacion? contexto;

  /// El flujo terminó con senew arriba: hay sesión nueva.
  final void Function(SesionMtp sesion, Telefono telefono)? onSesionNueva;

  /// El teléfono quedó en el BL: a recuperación.
  final VoidCallback? onRecuperar;

  /// El flujo soltó la sesión y no quedó ninguna: a conectar otra vez.
  final VoidCallback? onReconectar;

  /// El flujo empieza o acaba. Mientras corre no se cambia de pantalla: el
  /// teléfono se va del bus y la sesión de las demás deja de valer.
  final ValueChanged<bool>? onOcupado;

  const PantVersion({
    super.key,
    required this.telefono,
    required this.sesion,
    this.contexto,
    this.onSesionNueva,
    this.onRecuperar,
    this.onReconectar,
    this.onOcupado,
  });

  @override
  State<PantVersion> createState() => _PantVersionState();
}

class _PantVersionState extends State<PantVersion> {
  ContextoActualizacion? _ctx;
  List<ReleaseIndice> _releases = const [];
  bool _cargando = true;
  String? _error;
  String? _avisoRed;

  bool _corriendo = false;
  PasoAct? _paso;
  final Set<PasoAct> _hechos = {};
  double? _progreso;
  String? _aviso;
  final List<String> _log = [];
  ResultadoAct? _fin;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() {
      _cargando = true;
      _error = null;
      _avisoRed = null;
    });
    try {
      final c = _ctx ??= widget.contexto ?? await ContextoActualizacion.predeterminado();
      final g = widget.telefono.gestion;
      // Una actualización a medias que acabó bien: ya no hay nada que reanudar.
      if (g != null) await c.almacen.olvidarSiYaArranco(g.build);
      final r = await c.backend.indice();
      if (!mounted) return;
      setState(() {
        _releases = r.indice.releasesDe(widget.telefono.modelo.name);
        _avisoRed = r.rechazo != null
            ? 'El servidor dio algo que no pasa la verificación: ${r.rechazo}\n'
                'Se enseña lo último verificado.'
            : (r.sinRed
                ? 'Sin conexión con el servidor: esto es lo último verificado.'
                : null);
      });
    } on SinRed catch (e) {
      if (mounted) setState(() => _error = 'No se pudo leer el catálogo: $e');
    } on ErrorVerificacion catch (e) {
      if (mounted) setState(() => _error = 'El catálogo no se puede usar: $e');
    } catch (e) {
      // Disco, caché, lo que sea: se dice en la pantalla, no se escapa.
      if (mounted) setState(() => _error = 'No se pudo leer el catálogo: $e');
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  int? get _buildInstalado => widget.telefono.gestion?.build;

  /// Solo el W580 tiene BL, y un `R_OP_NO` ya visto no se vuelve a intentar.
  /// Sin sesión tampoco: lo que toca es conectar, no grabar otra vez.
  bool get _sePuede =>
      widget.telefono.modelo == Modelo.w580 &&
      _fin?.fin != FinAct.noDisponible &&
      (_fin == null || _fin!.sesion != null);

  /// La más nueva, si es más nueva que la instalada.
  ReleaseIndice? get _actualizacion {
    if (_releases.isEmpty) return null;
    final b = _buildInstalado;
    return b == null || _releases.first.build > b ? _releases.first : null;
  }

  Future<bool> _confirmar(ResumenConfirmacion r) async {
    if (!mounted) return false;
    final c = context.col;
    final si = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (d) => AlertDialog(
        icon: Icon(r.haciaAtras ? Symbols.warning : Symbols.system_update,
            color: r.haciaAtras ? c.aviso : c.acento),
        title: Text(r.haciaAtras
            ? 'Vas hacia atrás'
            : (r.misma ? 'Reinstalar la misma versión' : 'Actualizar senew')),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('De ${r.versionOrigen} (build ${r.buildOrigen}) a '
                  '${r.versionDestino} (build ${r.buildDestino}).'),
              if (r.haciaAtras) ...[
                const SizedBox(height: Esp.x3),
                Text(
                  'Esta versión es ANTERIOR a la instalada. Puede no entender '
                  'lo que guardó la nueva.',
                  style: context.tipo.bodyMedium?.copyWith(color: c.aviso),
                ),
              ],
              if (r.notas.isNotEmpty) ...[
                const SizedBox(height: Esp.x3),
                Text('Notas', style: context.tipo.titleSmall),
                Text(r.notas),
              ],
              const SizedBox(height: Esp.x3),
              const Text('No desconectes el cable ni apagues el teléfono.'),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(d, true),
              child: Text(r.haciaAtras ? 'Volver a esa versión' : 'Instalar')),
        ],
      ),
    );
    return si ?? false;
  }

  /// El teléfono no dice su batería: la persona la mira y lo confirma.
  Future<bool> _confirmarBateria() async {
    if (!mounted) return false;
    final si = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (d) => AlertDialog(
        icon: Icon(Symbols.battery_alert, color: context.col.aviso),
        title: const Text('Mira la batería del teléfono'),
        content: const Text(
            'Este senew no le dice a SENUS su batería. Un apagón a mitad de la '
            'grabación es lo más delicado que puede pasar.\n\n'
            '¿Tiene al menos el ${ActualizadorSenew.bateriaMinimaPct} %?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: const Text('No, cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(d, true),
              child: const Text(
                  'Sí, tiene al menos el ${ActualizadorSenew.bateriaMinimaPct} %')),
        ],
      ),
    );
    return si ?? false;
  }

  Future<void> _instalar(ReleaseIndice r) async {
    final s = widget.sesion;
    final c = _ctx;
    if (s == null || c == null) return;
    widget.onOcupado?.call(true);
    setState(() {
      _corriendo = true;
      _fin = null;
      _paso = null;
      _hechos.clear();
      _log.clear();
      _progreso = null;
      _aviso = null;
    });
    final act = ActualizadorSenew(
      puertos: c.puertos,
      backend: c.backend,
      almacen: c.almacen,
      confirmar: _confirmar,
      confirmarBateria: _confirmarBateria,
      alEvento: _evento,
    );
    ResultadoAct res;
    try {
      res = await act.actualizar(
          sesion: s, telefono: widget.telefono, destino: r);
    } catch (e) {
      res = ResultadoAct(FinAct.fallo, 'Error inesperado: $e');
    }
    widget.onOcupado?.call(false);
    if (!mounted) return;
    setState(() {
      _corriendo = false;
      _fin = res;
      _aviso = null;
    });
    final ses = res.sesion, tel = res.telefono;
    if (ses != null && tel != null) widget.onSesionNueva?.call(ses, tel);
  }

  void _evento(EventoAct e) {
    if (!mounted) return;
    setState(() {
      final p = e.paso;
      if (p != null) {
        if (_paso != null) _hechos.add(_paso!);
        _paso = p;
        _progreso = null;
        _aviso = null;
      }
      if (e.aviso != null) _aviso = e.aviso;
      if (e.linea != null) _log.add(e.linea!);
      if (e.progreso != null) _progreso = e.progreso;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.telefono;
    return ListView(
      padding: const EdgeInsets.only(bottom: Esp.x8),
      children: [
        CabeceraPantalla(
          titulo: 'Versión de senew',
          subtitulo: t.nombreAmigo,
          acciones: [
            IconButton(
              onPressed: _cargando || _corriendo ? null : _cargar,
              icon: const Icon(Symbols.refresh),
              tooltip: 'Recargar',
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Esp.x8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null) ...[
                AvisoError(_error!),
                const SizedBox(height: Esp.x4),
              ],
              if (_avisoRed != null) ...[
                FranjaAviso(_avisoRed!),
                const SizedBox(height: Esp.x4),
              ],
              if (t.modelo != Modelo.w580) ...[
                const FranjaAviso(
                    'Este teléfono no tiene bootloader propio: actualizar senew '
                    'desde SENUS no está disponible.'),
                const SizedBox(height: Esp.x4),
              ] else if (!t.canalGestion) ...[
                const FranjaAviso(
                    'Este senew no tiene canal de gestión. Actualízalo: la '
                    'primera vez SENUS entra por el puente, si reconoce esta '
                    'compilación.'),
                const SizedBox(height: Esp.x4),
              ],
              _Instalada(telefono: t),
              const SizedBox(height: Esp.x4),
              if (_corriendo || _fin != null) ...[
                _Progreso(
                  paso: _paso,
                  hechos: _hechos,
                  progreso: _progreso,
                  aviso: _aviso,
                  log: _log,
                  fin: _fin,
                  corriendo: _corriendo,
                  onRecuperar: widget.onRecuperar,
                  onReconectar: widget.onReconectar,
                ),
                const SizedBox(height: Esp.x4),
              ],
              if (_actualizacion != null && !_corriendo && _sePuede) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    onPressed: () => _instalar(_actualizacion!),
                    icon: const Icon(Symbols.system_update, size: 20),
                    label: Text('Actualizar a ${_actualizacion!.version}'),
                  ),
                ),
                const SizedBox(height: Esp.x4),
              ],
              Padding(
                padding: const EdgeInsets.only(left: Esp.x1, bottom: Esp.x3),
                child: Text('TODAS LAS VERSIONES', style: context.tipo.labelSmall),
              ),
              if (_cargando)
                const Center(child: CircularProgressIndicator())
              else if (_releases.isEmpty)
                Text('El catálogo no trae versiones para este teléfono.',
                    style: context.tipo.bodyMedium)
              else
                for (final r in _releases)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Esp.x2),
                    child: _FilaRelease(
                      release: r,
                      instalado: _buildInstalado,
                      ocupado: _corriendo || !_sePuede,
                      onInstalar: () => _instalar(r),
                    ),
                  ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Instalada extends StatelessWidget {
  final Telefono telefono;
  const _Instalada({required this.telefono});

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    final g = telefono.gestion;
    final bat = g?.bateria;
    return Superficie(
      child: Row(
        children: [
          const TejaIcono(Symbols.system_update),
          const SizedBox(width: Esp.x4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Instalada', style: context.tipo.labelSmall),
                const SizedBox(height: 2),
                Text(telefono.versionTexto,
                    style: estiloDatos(context,
                        tam: 22, color: c.acento, peso: FontWeight.w500)),
                if (g != null) ...[
                  const SizedBox(height: Esp.x2),
                  Wrap(
                    spacing: Esp.x2,
                    runSpacing: Esp.x2,
                    children: [
                      Etiqueta('API ${g.api}', mono: true),
                      Etiqueta(
                          g.blVersion == 0
                              ? 'BL sin datos'
                              : 'BL ${g.blVersion}',
                          mono: true),
                      Etiqueta(bat == null ? 'batería sin datos' : 'batería $bat %',
                          mono: true),
                      if (g.compilacion.isNotEmpty)
                        Etiqueta(g.compilacion, mono: true),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FilaRelease extends StatelessWidget {
  final ReleaseIndice release;
  final int? instalado;
  final bool ocupado;
  final VoidCallback onInstalar;
  const _FilaRelease({
    required this.release,
    required this.instalado,
    required this.ocupado,
    required this.onInstalar,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    final r = release;
    final b = instalado;
    final misma = b == r.build;
    final atras = b != null && r.build < b;
    return Superficie(
      radio: Rad.medio,
      relleno: const EdgeInsets.fromLTRB(Esp.x4, Esp.x3, Esp.x3, Esp.x3),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: Esp.x2,
                  runSpacing: Esp.x1,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('${r.version}  (build ${r.build})',
                        style: context.tipo.titleMedium),
                    Etiqueta(r.canal),
                    if (misma)
                      Etiqueta('instalada',
                          icono: Symbols.check_circle, color: c.exito),
                    if (atras)
                      Etiqueta('anterior',
                          icono: Symbols.warning, color: c.aviso),
                  ],
                ),
                if (r.notas.isNotEmpty)
                  Text(r.notas,
                      style: context.tipo.bodySmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          const SizedBox(width: Esp.x3),
          OutlinedButton(
            onPressed: ocupado ? null : onInstalar,
            child: Text(misma
                ? 'Reinstalar'
                : (atras ? 'Volver a esta' : 'Instalar')),
          ),
        ],
      ),
    );
  }
}

class _Progreso extends StatelessWidget {
  final PasoAct? paso;
  final Set<PasoAct> hechos;
  final double? progreso;
  final String? aviso;
  final List<String> log;
  final ResultadoAct? fin;
  final bool corriendo;
  final VoidCallback? onRecuperar;
  final VoidCallback? onReconectar;
  const _Progreso({
    required this.paso,
    required this.hechos,
    required this.progreso,
    required this.aviso,
    required this.log,
    required this.fin,
    required this.corriendo,
    required this.onRecuperar,
    required this.onReconectar,
  });

  /// El último paso no tiene otro detrás que lo marque: lo cierra el final bueno.
  bool _hecho(PasoAct p) =>
      hechos.contains(p) || (p == paso && fin?.fin == FinAct.hecho);

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    final f = fin;
    return Superficie(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (f != null) ...[
            f.bien || f.fin == FinAct.noDisponible || f.fin == FinAct.sinVuelta
                ? FranjaAviso(
                    '${f.mensaje}${f.remedio == null ? '' : '\n${f.remedio}'}')
                : AvisoError(
                    '${f.mensaje}${f.remedio == null ? '' : '\n${f.remedio}'}'),
            const SizedBox(height: Esp.x3),
            if (f.fin == FinAct.corte && onRecuperar != null)
              FilledButton(
                  onPressed: onRecuperar,
                  child: const Text('Ir a recuperación')),
            if (f.sesion == null && f.fin != FinAct.corte && onReconectar != null)
              OutlinedButton(
                  onPressed: onReconectar,
                  child: const Text('Volver a conectar')),
            const SizedBox(height: Esp.x3),
          ],
          for (final p in PasoAct.values)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(
                    _hecho(p)
                        ? Symbols.check_circle
                        : (p == paso && corriendo
                            ? Symbols.pending
                            : Symbols.radio_button_unchecked),
                    size: 18,
                    color: _hecho(p)
                        ? c.exito
                        : (p == paso ? c.acento : c.textoTenue),
                  ),
                  const SizedBox(width: Esp.x2),
                  Text('${p.index + 1}. ${p.titulo}',
                      style: context.tipo.bodyMedium),
                ],
              ),
            ),
          if (corriendo && aviso != null) ...[
            const SizedBox(height: Esp.x3),
            FranjaAviso(aviso!),
          ],
          if (corriendo && progreso != null) ...[
            const SizedBox(height: Esp.x3),
            LinearProgressIndicator(value: progreso),
          ],
          if (log.isNotEmpty) ...[
            const SizedBox(height: Esp.x3),
            SelectableText(log.join('\n'), style: estiloDatos(context, tam: 11)),
          ],
        ],
      ),
    );
  }
}
