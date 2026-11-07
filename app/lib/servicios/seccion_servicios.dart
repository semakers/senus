// La sección de los servicios en la pantalla Conexión: el dictado y la música, cada
// uno con su descarga bajo demanda. En los textos no se dice de dónde sale la música.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../tema/senus_tema.dart';
import '../widgets/comunes.dart';
import 'arranque_servicios.dart';
import 'catalogo_componentes.dart';
import 'componentes.dart';
import 'gestor_componentes.dart';
import 'servicios_locales.dart';

String textoMb(int bytes) {
  if (bytes >= 1000000000) {
    return '${(bytes / 1000000000).toStringAsFixed(1).replaceAll('.', ',')} GB';
  }
  return '${(bytes / 1000000).round()} MB';
}

class SeccionServicios extends StatefulWidget {
  /// Para las pruebas; sin él, los servicios de esta sesión.
  final ServiciosLocales? servicios;

  /// Por qué no se puede aquí. Para las pruebas; sin él, el de la plataforma.
  final ComponenteNoDisponible? bloqueo;

  const SeccionServicios({super.key, this.servicios, this.bloqueo});

  @override
  State<SeccionServicios> createState() => _SeccionServiciosState();
}

class _SeccionServiciosState extends State<SeccionServicios> {
  ServiciosLocales? _s;
  StreamSubscription<void>? _uno, _otro;

  @override
  void initState() {
    super.initState();
    if (widget.servicios != null) {
      _enganchar(widget.servicios!);
    } else if (_bloqueo == null) {
      unawaited(serviciosSenus().then((s) {
        if (mounted) _enganchar(s);
      }).catchError((Object e) {
        // Sin servicios la pantalla queda sin botones; lo demás de SENUS sigue.
        debugPrint('servicios: $e');
      }));
    }
  }

  ComponenteNoDisponible? get _bloqueo => widget.bloqueo ?? (widget.servicios == null ? bloqueoDePlataforma() : null);

  void _enganchar(ServiciosLocales s) {
    setState(() => _s = s);
    _uno = s.gestor.cambios.listen((_) {
      if (mounted) setState(() {});
    });
    _otro = s.cambios.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    unawaited(_uno?.cancel());
    unawaited(_otro?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bloqueo = _bloqueo;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Tarjeta(
          icono: Symbols.mic,
          titulo: 'Dictado por voz',
          descripcion: 'Dicta en cualquier campo de texto del teléfono: mantén pulsada la tecla *. '
              'Tu voz se reconoce en este computador, no sale a internet.',
          id: idDictado,
          servicios: _s,
          // (6-nov-2026) en Windows x64 Música sí y el dictado todavía no
          bloqueo: bloqueo ?? (widget.servicios == null ? bloqueoDeComponente(idDictado) : null),
          problema: _s?.problemaDictado,
          escuchando: _s?.dictadoEscuchando ?? false,
          textoListo: 'Listo para dictar',
        ),
        const SizedBox(height: Esp.x3),
        _Tarjeta(
          icono: Symbols.music_note,
          // (6-nov-2026, Adrián) una extensión, y de las dos apps: Videos usa lo mismo (servicio_musica.dart sirve /videos)
          titulo: 'Extensión de música y videos',
          descripcion: 'Para las apps Música y Videos del teléfono: busca y escucha canciones y mira videos, sin cuenta.',
          nota: (mb) => 'Música y Videos necesitan esta extensión para funcionar: sin ella el teléfono no encuentra '
              'canciones ni videos. SENUS la descarga una sola vez${mb == null ? '' : ' ($mb)'} y la guarda en este computador.',
          id: idMusica,
          servicios: _s,
          bloqueo: bloqueo ?? (widget.servicios == null ? bloqueoDeComponente(idMusica) : null),
          problema: _s?.problemaMusica,
          escuchando: _s?.musicaEscuchando ?? false,
          textoListo: 'Lista para sonar',
        ),
        const SizedBox(height: Esp.x2),
        Text('Solo funcionan con SENUS abierta.', style: context.tipo.bodySmall?.copyWith(color: context.col.textoTenue)),
      ],
    );
  }
}

class _Tarjeta extends StatelessWidget {
  final IconData icono;
  final String titulo, descripcion, id, textoListo;
  final ServiciosLocales? servicios;
  final ComponenteNoDisponible? bloqueo;
  final String? problema;
  final bool escuchando;

  /// Lo que se dice mientras no está instalado (con el tamaño de la descarga, si se sabe).
  final String Function(String? mb)? nota;

  const _Tarjeta({
    required this.icono,
    required this.titulo,
    required this.descripcion,
    required this.id,
    required this.servicios,
    required this.bloqueo,
    required this.problema,
    required this.escuchando,
    required this.textoListo,
    this.nota,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    final g = servicios?.gestor;
    final e = g?.estado(id);
    return Superficie(
      relleno: const EdgeInsets.all(Esp.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TejaIcono(icono),
              const SizedBox(width: Esp.x4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(titulo, style: context.tipo.titleMedium),
                    const SizedBox(height: Esp.x1),
                    Text(descripcion, style: context.tipo.bodySmall?.copyWith(color: c.textoTenue)),
                  ],
                ),
              ),
              const SizedBox(width: Esp.x3),
              if (bloqueo == null && g != null && e != null) _accion(context, g, e),
            ],
          ),
          if (bloqueo != null) ...[
            const SizedBox(height: Esp.x3),
            FranjaAviso(bloqueo!.porque),
          ] else if (e != null) ..._detalle(context, e),
          if (bloqueo == null && nota != null && (e == null || e.fase == FaseComponente.ausente)) ...[
            const SizedBox(height: Esp.x3),
            FranjaAviso(nota!(_mb(g)), color: c.acento),
          ],
        ],
      ),
    );
  }

  String? _mb(GestorComponentes? g) =>
      g != null && g.catalogo.any((x) => x.id == id) ? textoMb(g.componente(id).bytesDescarga) : null;

  Widget _accion(BuildContext context, GestorComponentes g, EstadoComponente e) {
    final tam = g.catalogo.any((x) => x.id == id) ? g.componente(id) : null;
    if (tam == null) return const SizedBox.shrink();
    switch (e.fase) {
      case FaseComponente.descargando:
        return TextButton(onPressed: () => g.cancelar(id), child: const Text('Cancelar'));
      case FaseComponente.verificando:
      case FaseComponente.instalando:
        return const SizedBox.shrink();
      case FaseComponente.listo:
        return TextButton(
          onPressed: () => _confirmarBorrar(context, g, tam),
          child: const Text('Borrar'),
        );
      case FaseComponente.fallo:
        return FilledButton(onPressed: () => unawaited(g.instalar(id)), child: const Text('Reintentar'));
      case FaseComponente.ausente:
        return FilledButton(
          onPressed: () => unawaited(g.instalar(id)),
          child: Text('Descargar y configurar (${textoMb(tam.bytesDescarga)})'),
        );
    }
  }

  Future<void> _confirmarBorrar(BuildContext context, GestorComponentes g, Componente comp) async {
    final si = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('¿Borrar $titulo?'),
        content: Text('Libera ${textoMb(comp.bytesInstalado)}. Se puede volver a descargar cuando quieras.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Borrar')),
        ],
      ),
    );
    if (si == true) await g.borrar(id);
  }

  List<Widget> _detalle(BuildContext context, EstadoComponente e) {
    final c = context.col;
    final t = context.tipo.bodySmall?.copyWith(color: c.textoTenue);
    switch (e.fase) {
      case FaseComponente.descargando:
        return [
          const SizedBox(height: Esp.x3),
          BarraUso(fraccion: e.fraccion ?? 0),
          const SizedBox(height: Esp.x1),
          Text('${textoMb(e.recibidos)} de ${textoMb(e.total)}', style: t),
        ];
      case FaseComponente.verificando:
        return [const SizedBox(height: Esp.x3), Text('Comprobando lo descargado…', style: t)];
      case FaseComponente.instalando:
        return [const SizedBox(height: Esp.x3), Text('Configurando…', style: t)];
      case FaseComponente.fallo:
        return [const SizedBox(height: Esp.x3), AvisoError(e.fallo?.mensaje ?? 'Algo falló.')];
      case FaseComponente.listo:
        if (problema != null) return [const SizedBox(height: Esp.x3), FranjaAviso(problema!)];
        return [
          const SizedBox(height: Esp.x3),
          Align(
            alignment: Alignment.centerLeft,
            child: Etiqueta(escuchando ? textoListo : 'Preparando…', icono: Symbols.check_circle, color: c.exito),
          ),
        ];
      case FaseComponente.ausente:
        return const [];
    }
  }
}
