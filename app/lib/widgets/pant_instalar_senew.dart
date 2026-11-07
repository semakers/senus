// Pantalla «Instalar senew» — vive en Herramientas, cumple la regla
// inviolable: si NO existe respaldo de rollback para el (modelo, serial) del
// aparato conectado, bloquea la pantalla con un mensaje y un botón «Ir a
// Fábrica». Si SÍ existe, muestra la ruta del respaldo con su SHA-256 y dos
// opciones: Instalar senew (protagonista) o Instalar modo demo (sin tocar
// firmware). Al terminar, dos tarjetas: «Tu respaldo» (ruta + abrir) y
// «Volver al firmware original».

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path/path.dart' as p;

import '../datos/hitos_senew.dart';
import '../datos/instalacion.dart';
import '../datos/instalador_anycid.dart' show FlagsInstalacion;
import '../datos/respaldo_rollback.dart';
import '../datos/seftool.dart';
import '../datos/telefono.dart';
import '../tema/senus_tema.dart';
import 'comunes.dart';

class PantInstalarSenew extends StatefulWidget {
  final Telefono telefono;
  final VoidCallback onIrAFabrica;

  /// Carpeta de donde se leen las imágenes de senew (`*_44140000.bin`) para
  /// poblar el dropdown del camino anycidReemplazoFrio. Null → `$HOME/dev/
  /// w580/sistema/build/aparato`. Los tests inyectan una carpeta temporal.
  final String? carpetaAparato;

  /// Almacén de respaldos. Null → `AlmacenRespaldos.predeterminado()`
  /// (`$HOME/senus/respaldos`). Los tests inyectan uno temporal.
  final AlmacenRespaldos? almacen;

  /// Fábrica del ejecutor de la restauración. Null → el de verdad. Los tests
  /// inyectan uno falso (el de verdad abre un puerto).
  final EjecutorRestauracion Function(RespaldoRollback)? crearRestauracion;

  /// Fábrica del ejecutor de la instalación. Null → el de verdad. Los tests
  /// inyectan uno falso (el de verdad abre un puerto).
  final EjecutorInstalacion Function(RespaldoRollback,
      {Camino? forzarCamino, String? rutaSenew})? crearInstalacion;

  /// Ofrecer el «Reemplazo frío por anycid» (7 pasos manuales). Null → lo que
  /// diga SENUS_FLUJO_LEGADO (apagado por omisión: lo sustituye la pantalla
  /// «Primera instalación»). Los tests del camino heredado lo encienden.
  final bool? flujoLegado;

  const PantInstalarSenew({
    super.key,
    required this.telefono,
    required this.onIrAFabrica,
    this.carpetaAparato,
    this.almacen,
    this.crearRestauracion,
    this.crearInstalacion,
    this.flujoLegado,
  });

  @override
  State<PantInstalarSenew> createState() => _PantInstalarSenewState();
}

enum _Fase { leyendo, bloqueada, lista, instalando, hecha, revirtiendo }

class _PantInstalarSenewState extends State<PantInstalarSenew> {
  late final AlmacenRespaldos _almacen =
      widget.almacen ?? AlmacenRespaldos.predeterminado();
  _Fase _fase = _Fase.leyendo;
  RespaldoRollback? _respaldo;
  double _progreso = 0;
  final List<String> _log = [];
  final ScrollController _scrollLog = ScrollController();
  bool _modoDemoHecho = false;

  List<HitoSenew> _hitos = const [];
  String? _hitoElegido;

  String get _carpetaAparato {
    if (widget.carpetaAparato != null) return widget.carpetaAparato!;
    final hogar =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
    return p.join(hogar, 'dev', 'w580', 'sistema', 'build', 'aparato');
  }

  @override
  void initState() {
    super.initState();
    _descubrirHitos();
    _recargar();
  }

  Future<void> _descubrirHitos() async {
    final encontrados = await descubrirHitos(_carpetaAparato);
    if (!mounted) return;
    setState(() {
      _hitos = encontrados;
      _hitoElegido = hitoPorOmision(encontrados);
    });
  }

  @override
  void dispose() {
    _scrollLog.dispose();
    super.dispose();
  }

  Future<void> _recargar() async {
    setState(() => _fase = _Fase.leyendo);
    final modelo = widget.telefono.modelo == Modelo.desconocido
        ? 'W580'
        : widget.telefono.modelo.name.toUpperCase();
    final r = await _almacen.buscar(modelo, widget.telefono.idRespaldo);
    if (!mounted) return;
    setState(() {
      _respaldo = r;
      _fase = r == null ? _Fase.bloqueada : _Fase.lista;
    });
  }

  void _agregarLog(String l) {
    setState(() => _log.add(l));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollLog.hasClients) {
        _scrollLog.jumpTo(_scrollLog.position.maxScrollExtent);
      }
    });
  }

  /// Puerto serie efectivo: el que contestó al identificar el aparato, si
  /// no SENUS_PUERTO, si no el primero autodetectado.
  String? get _puerto {
    final delAparato = widget.telefono.puertoSerie;
    if (delAparato != null && delAparato.trim().isNotEmpty) {
      return delAparato.trim();
    }
    final v = Platform.environment['SENUS_PUERTO'];
    if (v != null && v.trim().isNotEmpty) return v.trim();
    return Seftool.autodetectarPuerto();
  }

  Future<void> _instalarSenew({
    required bool modoDemo,
    Camino? forzarCamino,
  }) async {
    final r = _respaldo;
    if (r == null) return;

    if (modoDemo) {
      await _instalarDemoSimulado();
      return;
    }

    // Lo que va a pasar, resuelto ANTES de tocar nada, y confirmado.
    //
    // Para el camino anycidReemplazoFrio hay que decirle qué hito escribir.
    // Si no hay hito elegido (carpeta vacía), el botón ni siquiera estuvo
    // habilitado; aún así, falback defensivo a la ruta por omisión del
    // planificador (sistema_44140000.bin), que SIEMPRE escribe NOR.
    String? rutaSenew;
    if (forzarCamino == Camino.anycidReemplazoFrio && _hitoElegido != null) {
      rutaSenew = p.join(_carpetaAparato, _hitoElegido!);
    }
    final ejec = widget.crearInstalacion
            ?.call(r, forzarCamino: forzarCamino, rutaSenew: rutaSenew) ??
        EjecutorInstalacion(
            respaldo: r,
            puerto: _puerto,
            forzarCamino: forzarCamino,
            rutaSenew: rutaSenew);
    final plan = ejec.plan;
    final ok = await _confirmarInstalacion(plan);
    if (ok != true) return;

    setState(() {
      _fase = _Fase.instalando;
      _progreso = 0;
      _log.clear();
    });
    _agregarLog('Puerto: ${_puerto ?? '(ninguno detectado)'}');

    var huboError = false;
    var cancelado = false;
    try {
      await for (final ev in ejec.correr()) {
        if (!mounted) return;
        if (ev.logLinea != null) _agregarLog(ev.logLinea!);
        if (ev.progreso != null) setState(() => _progreso = ev.progreso!);
        if (ev.cancelado) cancelado = true;
        if (ev.pausa != null) {
          final seguir = await resolverPausa(context, ev);
          _agregarLog(seguir
              ? '· continuar (confirmado por el usuario)'
              : '· cancelado por el usuario');
        }
        if (ev.error != null) {
          huboError = true;
          _agregarLog('ERROR: ${ev.error}');
          final e = ev.error!;
          if (e.startsWith('CSLOADER29:')) {
            await _dialogoCsloader29(e.substring('CSLOADER29:'.length).trim());
          }
        }
      }
    } catch (e) {
      huboError = true;
      _agregarLog('EXCEPCIÓN: $e');
    }
    if (!mounted) return;
    setState(() {
      // Cancelar una pausa NO es haber instalado: no se enseña «completada».
      _fase = (huboError || cancelado) ? _Fase.lista : _Fase.hecha;
      _modoDemoHecho = false;
    });
    if ((huboError || cancelado) && mounted) {
      avisar(
          context,
          cancelado && !huboError
              ? 'Instalación CANCELADA: no se completó. Mira el registro.'
              : 'La instalación no se completó. Mira el registro.',
          bien: false);
    }
  }

  /// El modo demo no toca firmware: sigue siendo la animación de antes.
  Future<void> _instalarDemoSimulado() async {
    setState(() {
      _fase = _Fase.instalando;
      _progreso = 0;
      _log.clear();
    });
    _agregarLog('> Instalación en modo demo (no se toca el firmware)');
    const pasos = ['Preparando Memoria', 'Subiendo paquete demo', 'Verificando'];
    for (var i = 0; i < pasos.length; i++) {
      _agregarLog('[${i + 1}/${pasos.length}] ${pasos[i]}…');
      for (var k = 0; k < 10; k++) {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        if (!mounted) return;
        setState(() => _progreso = (i * 10 + k + 1) / (pasos.length * 10));
      }
      _agregarLog('    ok');
    }
    _agregarLog('> hecho');
    if (!mounted) return;
    setState(() {
      _fase = _Fase.hecha;
      _modoDemoHecho = true;
    });
  }

  /// Enseña el plan con sus avisos y pide confirmación. Si el plan está
  /// bloqueado, sólo informa: no hay botón de seguir.
  Future<bool?> _confirmarInstalacion(PlanInstalacion plan) {
    final c = context.col;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(plan.bloqueado ? Symbols.block : Symbols.rocket_launch,
            color: plan.bloqueado ? c.error : c.acento),
        title: Text(plan.bloqueado
            ? 'No se puede instalar todavía'
            : 'Instalar senew — ${plan.nombre}'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 420),
          child: SingleChildScrollView(
            child: SelectableText([
              plan.explicacion,
              if (plan.rutaBinario != null) '\nBinario: ${plan.rutaBinario}',
              if (plan.direccion != null)
                'Destino: 0x${plan.direccion!.toRadixString(16).toUpperCase()}',
              if (plan.paqueteAnycid != null)
                'Paquete anycid: ${plan.paqueteAnycid}',
              if (plan.avisos.isNotEmpty) '\n${plan.avisos.join('\n\n')}',
            ].join('\n')),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(plan.bloqueado ? 'Entendido' : 'Cancelar')),
          if (!plan.bloqueado)
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Instalar')),
        ],
      ),
    );
  }

  Future<void> _dialogoCsloader29(String detalle) {
    final c = context.col;
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Symbols.error, color: c.error),
        iconColor: c.error,
        title: const Text('El CSLoader no arrancó (error 29)'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SelectableText(detalle),
        ),
        actions: [
          FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Entendido')),
        ],
      ),
    );
  }

  /// Lo que se le dice a la persona ANTES de restaurar: las órdenes REALES
  /// según el camino que le toca a este respaldo.
  String _textoRestauracion(RespaldoRollback r) {
    final hayFlash = File(r.rutaFlash).existsSync();
    final gdfs = p.basename(r.rutaGdfsA);
    final String ordenes;
    if (!hayFlash) {
      ordenes = 'Este respaldo no trae flash_full.bin: solo se podrá restaurar '
          'el GDFS (seftool write-gdfs $gdfs). El main se queda como esté.';
    } else if (EjecutorRestauracion.restauraPorAnycid(r)) {
      ordenes = 'Órdenes: seftool convert raw2babe → upload-anycid → (tú abres '
          '«executer» en el teléfono) → flash-anycid main --cid ${r.cid} → '
          'write-gdfs $gdfs.\n'
          'Un W580 RED solo acepta una imagen sin firma por la rama anycid: '
          '`flash main` la rechaza. Si senew ya reemplazó el main original, el '
          'teléfono ya no arranca el Java de fábrica y el paso de «executer» '
          'no se podrá completar; entonces SENUS te ofrece restaurar SOLO el '
          'GDFS.';
    } else {
      ordenes = 'Órdenes: seftool convert raw2babe → flash main → write-gdfs '
          '$gdfs.';
    }
    return 'Vas a restaurar el firmware SEMC original desde:\n\n${r.carpeta}\n\n'
        'Se comprueba antes el SHA-256 del volcado; si no cuadra, no se '
        'escribe nada.\n\n'
        '$ordenes\n'
        'SENUS te pide reconectar el teléfono en modo C entre una orden y la '
        'siguiente (cada una lo apaga).\n'
        'NO se reescribe la zona del cargador (0x44000000..0x4413FFFF): '
        'se restaura desde el main.\n\n'
        'El respaldo NO se borra; solo queda marcado como «ya usado».';
  }

  Future<void> _volverAlOriginal() async {
    final r = _respaldo;
    if (r == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        icon: Icon(Symbols.restore, color: context.col.aviso),
        title: const Text('Volver al firmware original'),
        content: SelectableText(_textoRestauracion(r)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Restaurar')),
        ],
      ),
    );
    if (ok != true) return;

    setState(() {
      _fase = _Fase.revirtiendo;
      _progreso = 0;
      _log.clear();
    });
    _agregarLog('Puerto: ${_puerto ?? '(ninguno detectado)'}');

    var huboError = false;
    var cancelado = false;
    var parcial = false;
    try {
      final ejec = widget.crearRestauracion?.call(r) ??
          EjecutorRestauracion(respaldo: r, almacen: _almacen, puerto: _puerto);
      await for (final ev in ejec.correr()) {
        if (!mounted) return;
        if (ev.logLinea != null) _agregarLog(ev.logLinea!);
        if (ev.progreso != null) setState(() => _progreso = ev.progreso!);
        if (ev.cancelado) cancelado = true;
        if (ev.parcial) parcial = true;
        // La restauración pausa (reconectar en modo C, «executer»…). Sin este
        // consumidor el Completer no se completaba nunca y se colgaba.
        if (ev.pausa != null) {
          final seguir = await resolverPausa(context, ev);
          _agregarLog(seguir
              ? '· continuar (confirmado por el usuario)'
              : '· cancelado por el usuario');
        }
        if (ev.error != null) {
          huboError = true;
          _agregarLog('ERROR: ${ev.error}');
        }
      }
    } catch (e) {
      huboError = true;
      _agregarLog('EXCEPCIÓN: $e');
    }

    // El respaldo se relee del almacén: la marca «usado» la pone el ejecutor.
    final modelo = widget.telefono.modelo == Modelo.desconocido
        ? r.modelo
        : widget.telefono.modelo.name.toUpperCase();
    final nuevo = await _almacen.buscar(modelo, r.serie) ?? r;
    if (!mounted) return;
    setState(() {
      _respaldo = nuevo;
      _fase = _Fase.lista;
    });
    // Lo que se dice tiene que ser lo que pasó: cancelar una pausa o terminar
    // solo con el GDFS NO es «firmware original restaurado».
    final String texto;
    if (huboError) {
      texto = 'No se completó la restauración. Mira el registro; el respaldo '
          'sigue entero.';
    } else if (cancelado) {
      texto = 'Restauración CANCELADA: no se completó (mira el registro: puede '
          'que el main ya esté escrito y el GDFS no). El respaldo sigue entero '
          'y NO se marcó como «usado».';
    } else if (parcial) {
      texto = 'Restauración PARCIAL: solo se escribió el GDFS; el main NO se '
          'restauró. Mira el registro.';
    } else {
      texto = 'Firmware original restaurado. El respaldo queda guardado como '
          '«usado».';
    }
    avisar(context, texto, bien: !(huboError || cancelado || parcial));
  }

  Future<void> _abrirCarpeta(String ruta) async {
    try {
      if (Platform.isMacOS) {
        await Process.start('open', [ruta]);
      } else if (Platform.isLinux) {
        await Process.start('xdg-open', [ruta]);
      } else if (Platform.isWindows) {
        await Process.start('explorer', [ruta]);
      }
    } catch (e) {
      if (!mounted) return;
      avisar(context, 'No pude abrir la carpeta: $e', bien: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(Esp.x8, Esp.x8, Esp.x8, Esp.x8),
      children: [
        _cuerpo(),
      ],
    );
  }

  Widget _cuerpo() {
    switch (_fase) {
      case _Fase.leyendo:
        return const Center(child: Padding(
          padding: EdgeInsets.all(Esp.x12),
          child: CircularProgressIndicator(),
        ));
      case _Fase.bloqueada:
        return _BloqueoSinRespaldo(
            telefono: widget.telefono, onIrAFabrica: widget.onIrAFabrica);
      case _Fase.lista:
        return _TarjetaLista(
          respaldo: _respaldo!,
          onAbrir: () => _abrirCarpeta(_respaldo!.carpeta),
          onInstalar: () => _instalarSenew(modoDemo: false),
          onDemo: () => _instalarSenew(modoDemo: true),
          // El «Reemplazo frío por anycid» (qa2020 + bflash + 7 pasos manuales)
          // lo SUSTITUYE el flujo de «Primera instalación». Solo se ofrece con
          // SENUS_FLUJO_LEGADO=1, por si el nuevo no cubriera algún CID52.
          onFrioAnycid: (widget.flujoLegado ?? FlagsInstalacion.flujoLegado()) &&
                  _respaldo!.modelo.toUpperCase() == 'W580' &&
                  _hitos.isNotEmpty
              ? () => _instalarSenew(
                  modoDemo: false,
                  forzarCamino: Camino.anycidReemplazoFrio)
              : null,
          onVolver: _volverAlOriginal,
          hitos: _hitos,
          hitoElegido: _hitoElegido,
          onElegirHito: (v) => setState(() => _hitoElegido = v),
        );
      case _Fase.instalando:
      case _Fase.revirtiendo:
        return _PanelCorriendo(
          revirtiendo: _fase == _Fase.revirtiendo,
          progreso: _progreso,
          lineas: _log,
          scroll: _scrollLog,
        );
      case _Fase.hecha:
        return _TarjetaHecha(
          respaldo: _respaldo!,
          modoDemo: _modoDemoHecho,
          onAbrir: () => _abrirCarpeta(_respaldo!.carpeta),
          onVolver: _volverAlOriginal,
          onOtra: () => setState(() => _fase = _Fase.lista),
        );
    }
  }
}

class _BloqueoSinRespaldo extends StatelessWidget {
  final Telefono telefono;
  final VoidCallback onIrAFabrica;
  const _BloqueoSinRespaldo(
      {required this.telefono, required this.onIrAFabrica});

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    return Container(
      decoration: BoxDecoration(
        color: c.aviso.withAlpha(14),
        borderRadius: BorderRadius.circular(Rad.enorme),
        border: Border.all(color: c.aviso.withAlpha(100)),
      ),
      padding: const EdgeInsets.all(Esp.x8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Symbols.block, color: c.aviso, fill: 1, size: 36),
              const SizedBox(width: Esp.x3),
              Expanded(
                child: Text('Primero el respaldo de rollback',
                    style: context.tipo.headlineSmall),
              ),
            ],
          ),
          const SizedBox(height: Esp.x4),
          Text(
            'SENUS no instala senew en un aparato sin red de seguridad.\n'
            'Haz el respaldo del firmware original en la pantalla Fábrica — '
            'dos copias del GDFS, flash completo y metadatos — y vuelve aquí '
            'cuando esté hecho.',
            style: context.tipo.bodyLarge?.copyWith(color: c.texto),
          ),
          const SizedBox(height: Esp.x4),
          Wrap(
            spacing: Esp.x2,
            runSpacing: Esp.x2,
            children: [
              Etiqueta('Aparato: ${telefono.nombreAmigo}',
                  icono: Symbols.smartphone, color: c.textoTenue),
              if (telefono.serie.isNotEmpty)
                Etiqueta(telefono.serie,
                    icono: Symbols.badge, mono: true, color: c.textoTenue),
              Etiqueta('Sin respaldo',
                  icono: Symbols.warning, color: c.aviso),
            ],
          ),
          const SizedBox(height: Esp.x6),
          FilledButton.icon(
            onPressed: onIrAFabrica,
            icon: const Icon(Symbols.precision_manufacturing, size: 20),
            label: const Text('Ir a Fábrica'),
          ),
        ],
      ),
    );
  }
}

class _TarjetaLista extends StatelessWidget {
  final RespaldoRollback respaldo;
  final VoidCallback onAbrir;
  final VoidCallback onInstalar;
  final VoidCallback onDemo;
  final VoidCallback? onFrioAnycid; // null en W600/W810
  final VoidCallback onVolver;

  /// Imágenes de senew descubiertas en senew-w580/build/aparato/.
  /// Si está vacía (carpeta no existe o no hay `*_44140000.bin`), el camino
  /// anycidReemplazoFrio se deshabilita con tooltip explicativo.
  final List<HitoSenew> hitos;
  final String? hitoElegido;
  final ValueChanged<String?>? onElegirHito;

  const _TarjetaLista({
    required this.respaldo,
    required this.onAbrir,
    required this.onInstalar,
    required this.onDemo,
    required this.onVolver,
    this.onFrioAnycid,
    this.hitos = const [],
    this.hitoElegido,
    this.onElegirHito,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        EntradaSuave(
          child: _CajonRespaldo(
              respaldo: respaldo,
              onAbrir: onAbrir,
              onVolver: respaldo.usado ? null : onVolver),
        ),
        const SizedBox(height: Esp.x6),
        Padding(
          padding: const EdgeInsets.only(left: Esp.x1, bottom: Esp.x3),
          child: Text('INSTALACIÓN', style: context.tipo.labelSmall),
        ),
        LayoutBuilder(builder: (context, lim) {
          final ancho = lim.maxWidth > 640;
          final tarjetas = [
            EntradaSuave(
              child: _OpcionInstalar(
                protagonista: true,
                icono: Symbols.rocket_launch,
                titulo: 'Instalar senew',
                descripcion: respaldo.cid == '53'
                    ? 'CID53: anycid + payload sobre el A200. '
                        'El firmware original queda intacto; reset físico siempre vuelve.'
                    : 'Reemplazo frío: senew toma la NOR. '
                        'Puedes volver atrás con el respaldo (botón de abajo).',
                boton: 'Instalar',
                onTap: onInstalar,
              ),
            ),
            EntradaSuave(
              retraso: escalon(1),
              child: _OpcionInstalar(
                protagonista: false,
                icono: Symbols.science,
                titulo: 'Instalar modo demo',
                descripcion:
                    'Instala en Memoria sin tocar el firmware. Para probar '
                    'apps y mostrar la interfaz sin flashear.',
                boton: 'Modo demo',
                onTap: onDemo,
              ),
            ),
          ];
          if (!ancho) {
            return Column(
                children: [tarjetas[0], const SizedBox(height: Esp.x3), tarjetas[1]]);
          }
          return IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: tarjetas[0]),
                const SizedBox(width: Esp.x4),
                Expanded(child: tarjetas[1]),
              ],
            ),
          );
        }),
        if (onFrioAnycid != null) ...[
          const SizedBox(height: Esp.x6),
          Padding(
            padding: const EdgeInsets.only(left: Esp.x1, bottom: Esp.x3),
            child: Text('AVANZADO (W580)', style: context.tipo.labelSmall),
          ),
          if (hitos.isNotEmpty) ...[
            EntradaSuave(
              retraso: escalon(2),
              child: Superficie(
                relleno: const EdgeInsets.all(Esp.x4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Imagen de senew a grabar',
                        style: context.tipo.labelMedium),
                    const SizedBox(height: Esp.x2),
                    DropdownButtonFormField<String>(
                      key: const ValueKey('selectorHito'),
                      initialValue: hitoElegido,
                      isExpanded: true,
                      items: [
                        for (final h in hitos)
                          DropdownMenuItem(
                            value: h.nombreArchivo,
                            child: Text(
                              '${h.nombreArchivo} — ${h.etiqueta}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: onElegirHito,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    if (hitoElegido != null) ...[
                      const SizedBox(height: Esp.x2),
                      Builder(builder: (context) {
                        final h = hitos.firstWhere(
                            (e) => e.nombreArchivo == hitoElegido,
                            orElse: () => hitos.first);
                        return Text(
                          h.tocaNor
                              ? 'Escribe en NOR (${h.tamanoBytes} B)'
                              : 'NO toca NOR (${h.tamanoBytes} B)',
                          style: context.tipo.labelSmall?.copyWith(
                              color: h.tocaNor ? c.aviso : c.exito),
                        );
                      }),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: Esp.x3),
            EntradaSuave(
              retraso: escalon(2),
              child: _OpcionInstalar(
                protagonista: false,
                icono: Symbols.hardware,
                titulo: 'Reemplazo frío por anycid',
                descripcion:
                    'Sobrescribe el main en NOR con la imagen elegida arriba, '
                    'por la rama flash-anycid. Hace falta abrir Juegos → '
                    '«executer» en el teléfono entre medias. EXPERIMENTAL — '
                    'sin probar contra un W580 real; si falla a mitad, se '
                    'restaura con el respaldo.',
                boton: 'Reemplazo frío (anycid)',
                onTap: onFrioAnycid!,
              ),
            ),
          ] else ...[
            EntradaSuave(
              retraso: escalon(2),
              child: Superficie(
                relleno: const EdgeInsets.all(Esp.x4),
                child: Row(children: [
                  Icon(Symbols.folder_off, color: c.aviso),
                  const SizedBox(width: Esp.x3),
                  Expanded(
                    child: Text(
                      'No encuentro imágenes `*_44140000.bin` en '
                      'senew-w580/build/aparato/. Compila el sistema '
                      '(make en senew-w580) o cámbialo con la variable '
                      'de entorno/parametro `carpetaAparato`.',
                      style: context.tipo.bodySmall,
                    ),
                  ),
                ]),
              ),
            ),
          ],
        ],
      ],
    );
  }
}

class _CajonRespaldo extends StatelessWidget {
  final RespaldoRollback respaldo;
  final VoidCallback onAbrir;
  final VoidCallback? onVolver;
  const _CajonRespaldo(
      {required this.respaldo, required this.onAbrir, this.onVolver});

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    return Superficie(
      resaltada: true,
      relleno: const EdgeInsets.all(Esp.x6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TejaIcono(Symbols.shield,
              tam: 56, color: c.exito, fondo: c.exito.withAlpha(32)),
          const SizedBox(width: Esp.x4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('Respaldo disponible',
                        style: context.tipo.titleLarge),
                    const SizedBox(width: Esp.x2),
                    if (respaldo.usado)
                      Etiqueta('ya usado',
                          icono: Symbols.history, color: c.textoTenue),
                  ],
                ),
                const SizedBox(height: Esp.x2),
                InkWell(
                  onTap: onAbrir,
                  child: SelectableText(respaldo.carpeta,
                      style:
                          estiloDatos(context, tam: 12.5, color: c.acento)),
                ),
                const SizedBox(height: Esp.x3),
                Wrap(
                  spacing: Esp.x3,
                  runSpacing: Esp.x2,
                  children: [
                    Etiqueta('fecha ${respaldo.fecha.toLocal().toString().substring(0, 10)}',
                        icono: Symbols.event, color: c.textoTenue),
                    if (respaldo.cid != null)
                      Etiqueta('CID ${respaldo.cid}',
                          icono: Symbols.key, color: c.textoTenue),
                    Etiqueta('sha ${respaldo.shaFlash.substring(0, math.min(16, respaldo.shaFlash.length))}…',
                        mono: true, color: c.textoTenue),
                  ],
                ),
                if (onVolver != null) ...[
                  const SizedBox(height: Esp.x4),
                  OutlinedButton.icon(
                    onPressed: onVolver,
                    icon: const Icon(Symbols.restore, size: 18),
                    label: const Text('Volver al firmware original'),
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

class _OpcionInstalar extends StatelessWidget {
  final bool protagonista;
  final IconData icono;
  final String titulo;
  final String descripcion;
  final String boton;
  final VoidCallback onTap;
  const _OpcionInstalar({
    required this.protagonista,
    required this.icono,
    required this.titulo,
    required this.descripcion,
    required this.boton,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    return Superficie(
      onTap: onTap,
      relleno: const EdgeInsets.all(Esp.x6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TejaIcono(icono,
              tam: 56,
              color: protagonista ? c.sobreAcento : c.acento,
              fondo: protagonista ? c.acento : c.acentoApagado),
          const SizedBox(height: Esp.x4),
          Text(titulo, style: context.tipo.headlineSmall),
          const SizedBox(height: Esp.x2),
          Text(descripcion,
              style: context.tipo.bodyMedium?.copyWith(color: c.textoTenue)),
          const SizedBox(height: Esp.x4),
          protagonista
              ? FilledButton.icon(
                  onPressed: onTap,
                  icon: const Icon(Symbols.download, size: 20),
                  label: Text(boton))
              : OutlinedButton.icon(
                  onPressed: onTap,
                  icon: const Icon(Symbols.science, size: 20),
                  label: Text(boton)),
        ],
      ),
    );
  }
}

class _PanelCorriendo extends StatelessWidget {
  final bool revirtiendo;
  final double progreso;
  final List<String> lineas;
  final ScrollController scroll;
  const _PanelCorriendo({
    required this.revirtiendo,
    required this.progreso,
    required this.lineas,
    required this.scroll,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    return Superficie(
      resaltada: true,
      relleno: const EdgeInsets.all(Esp.x6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                  revirtiendo
                      ? Symbols.restore
                      : Symbols.rocket_launch,
                  color: c.acento,
                  fill: 1,
                  size: 28),
              const SizedBox(width: Esp.x3),
              Expanded(
                child: Text(
                    revirtiendo
                        ? 'Restaurando el firmware original…'
                        : 'Instalando senew…',
                    style: context.tipo.titleLarge),
              ),
              Text('${(progreso * 100).round()} %',
                  style: estiloDatos(context,
                      tam: 20, color: c.acento, peso: FontWeight.w500)),
            ],
          ),
          const SizedBox(height: Esp.x4),
          BarraUso(fraccion: progreso, alto: 10),
          const SizedBox(height: Esp.x4),
          Container(
            height: 220,
            decoration: BoxDecoration(
              color: const Color(0xFF0A0A0C),
              borderRadius: BorderRadius.circular(Rad.medio),
              border: Border.all(color: c.borde.withAlpha(90)),
            ),
            padding: const EdgeInsets.all(Esp.x3),
            child: ListView.builder(
              controller: scroll,
              itemCount: lineas.length,
              itemBuilder: (_, i) => Text(lineas[i],
                  style: estiloDatos(context,
                      tam: 11.5, color: const Color(0xFFD9DADE))),
            ),
          ),
        ],
      ),
    );
  }
}

class _TarjetaHecha extends StatelessWidget {
  final RespaldoRollback respaldo;
  final bool modoDemo;
  final VoidCallback onAbrir;
  final VoidCallback onVolver;
  final VoidCallback onOtra;
  const _TarjetaHecha({
    required this.respaldo,
    required this.modoDemo,
    required this.onAbrir,
    required this.onVolver,
    required this.onOtra,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        EntradaSuave(
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Rad.enorme),
              gradient: LinearGradient(colors: [
                Color.lerp(c.exito, c.superficie, 0.72)!,
                c.superficie,
              ]),
              border: Border.all(color: c.exito.withAlpha(110)),
              boxShadow: c.sombraSuave(nivel: 1.6),
            ),
            padding: const EdgeInsets.all(Esp.x6),
            child: Row(
              children: [
                Icon(Symbols.verified, color: c.exito, fill: 1, size: 40),
                const SizedBox(width: Esp.x4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        modoDemo
                            ? 'Modo demo instalado'
                            : 'senew instalado',
                        style: context.tipo.headlineSmall
                            ?.copyWith(color: c.exito),
                      ),
                      const SizedBox(height: Esp.x1),
                      Text(
                        modoDemo
                            ? 'Puedes probar las apps .sen sin haber tocado el firmware.'
                            : 'El teléfono arranca ahora con senew. Puedes volver al firmware original cuando quieras.',
                        style: context.tipo.bodyMedium
                            ?.copyWith(color: c.texto),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: Esp.x6),
        LayoutBuilder(builder: (context, lim) {
          final ancho = lim.maxWidth > 640;
          final tarjetas = [
            EntradaSuave(
              child: _TarjetaResultado(
                icono: Symbols.folder_open,
                titulo: 'Tu respaldo',
                lineas: [
                  respaldo.carpeta,
                  'sha ${respaldo.shaFlash.substring(0, math.min(16, respaldo.shaFlash.length))}…',
                  'fecha ${respaldo.fecha.toLocal().toString().substring(0, 16)}',
                ],
                boton: 'Abrir carpeta',
                iconoBoton: Symbols.folder_open,
                onTap: onAbrir,
                acento: context.col.acento,
              ),
            ),
            EntradaSuave(
              retraso: escalon(1),
              child: _TarjetaResultado(
                icono: Symbols.restore,
                titulo: 'Volver al firmware original',
                lineas: const [
                  'Restaura main.bin + GDFS desde el respaldo.',
                  'No se borra; queda como «ya usado».',
                ],
                boton: modoDemo
                    ? 'No aplica (modo demo)'
                    : 'Restaurar',
                iconoBoton: Symbols.restore,
                onTap: modoDemo ? null : onVolver,
                acento: context.col.aviso,
              ),
            ),
          ];
          if (!ancho) {
            return Column(children: [
              tarjetas[0],
              const SizedBox(height: Esp.x3),
              tarjetas[1],
            ]);
          }
          return IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: tarjetas[0]),
                const SizedBox(width: Esp.x4),
                Expanded(child: tarjetas[1]),
              ],
            ),
          );
        }),
        const SizedBox(height: Esp.x4),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: onOtra,
            icon: const Icon(Symbols.arrow_back, size: 18),
            label: const Text('Volver al panel'),
          ),
        ),
      ],
    );
  }
}

class _TarjetaResultado extends StatelessWidget {
  final IconData icono;
  final String titulo;
  final List<String> lineas;
  final String boton;
  final IconData iconoBoton;
  final VoidCallback? onTap;
  final Color acento;
  const _TarjetaResultado({
    required this.icono,
    required this.titulo,
    required this.lineas,
    required this.boton,
    required this.iconoBoton,
    required this.onTap,
    required this.acento,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    return Superficie(
      relleno: const EdgeInsets.all(Esp.x6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icono, color: acento, fill: 1, size: 24),
              const SizedBox(width: Esp.x2),
              Expanded(child: Text(titulo, style: context.tipo.titleMedium)),
            ],
          ),
          const SizedBox(height: Esp.x3),
          for (final l in lineas) ...[
            Text(l,
                style: estiloDatos(context, tam: 11.5, color: c.textoTenue)),
            const SizedBox(height: Esp.x1),
          ],
          const Spacer(),
          const SizedBox(height: Esp.x3),
          OutlinedButton.icon(
            onPressed: onTap,
            icon: Icon(iconoBoton, size: 18),
            label: Text(boton),
          ),
        ],
      ),
    );
  }
}
