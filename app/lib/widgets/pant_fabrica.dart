// V5 — Respaldo de rollback (antes «Fábrica»).
//
// Regla inviolable de SENUS: antes de instalar senew en un aparato, guarda su
// respaldo de rollback. Tres pasos verticales con estado (pendiente /
// corriendo / hecho ✓):
//   1. Identificar       seftool identify  → Modelo, CID, COLOR, firmware
//   2. Respaldo          2 x read-gdfs + read-flash (64 MiB) + metadatos
//   3. Copia espejo x86  scp opcional (recomendada)
//
// Al terminar, tarjeta verde con la ruta del respaldo (clickable para abrir
// en el gestor de archivos del sistema) y botón «Habilitar instalación de
// senew» que lleva a la pantalla «Instalar senew».

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../datos/respaldo_rollback.dart';
import '../datos/seftool.dart';
import '../datos/telefono.dart';
import '../tema/senus_tema.dart';
import 'comunes.dart';

class PantFabrica extends StatefulWidget {
  final Telefono telefono;
  final VoidCallback? onIrAInstalar;

  /// Almacén de respaldos. Null → `$HOME/senus/respaldos`. Los tests inyectan
  /// uno temporal.
  final AlmacenRespaldos? almacen;

  /// Fábrica del ejecutor. Null → el de verdad (abre el cable). Los tests
  /// inyectan uno falso.
  final EjecutorRespaldo Function()? crearEjecutor;

  const PantFabrica({
    super.key,
    required this.telefono,
    this.onIrAInstalar,
    this.almacen,
    this.crearEjecutor,
  });

  @override
  State<PantFabrica> createState() => _PantFabricaState();
}

class _PantFabricaState extends State<PantFabrica> {
  late final AlmacenRespaldos _almacen =
      widget.almacen ?? AlmacenRespaldos.predeterminado();

  bool _trabajando = false;
  RespaldoRollback? _resultado;
  RespaldoRollback? _existente;

  // Estado de cada paso.
  final Map<String, EstadoPaso> _estados = {
    'identificar': EstadoPaso.pendiente,
    'respaldo': EstadoPaso.pendiente,
    'espejo': EstadoPaso.pendiente,
  };
  double _progresoFlash = 0;
  final List<String> _log = [];
  final ScrollController _scrollLog = ScrollController();

  final TextEditingController _ctrlScp = TextEditingController(
      text: Platform.environment['SENUS_RESPALDO_SCP'] ?? '');

  /// Puerto serie del cable. Se autodetecta; si no hay nada que detectar,
  /// queda vacío y el usuario lo escribe.
  late final TextEditingController _ctrlPuerto;

  /// En simulado (bridge_mock) no hay puerto que pedir.
  final bool _simulado = EjecutorRespaldo.decidirSimulado();
  late final List<String> _puertosVistos;

  @override
  void initState() {
    super.initState();
    _puertosVistos = _simulado ? const [] : Seftool.puertosCandidatos();
    // El mejor dato es el puerto por el que el aparato YA contestó al
    // identificarlo en la pantalla de conectar.
    _ctrlPuerto = TextEditingController(
        text: widget.telefono.puertoSerie ??
            Platform.environment['SENUS_PUERTO'] ??
            (_puertosVistos.isNotEmpty ? _puertosVistos.first : ''));
    _buscarExistente();
  }

  @override
  void dispose() {
    _ctrlPuerto.dispose();
    _ctrlScp.dispose();
    _scrollLog.dispose();
    super.dispose();
  }

  Future<void> _buscarExistente() async {
    final modelo = widget.telefono.modelo == Modelo.desconocido
        ? 'W580'
        : widget.telefono.modelo.name.toUpperCase();
    final r = await _almacen.buscar(modelo, widget.telefono.idRespaldo);
    if (!mounted) return;
    setState(() {
      _existente = r;
      _resultado = r;
    });
  }

  Future<void> _correr() async {
    setState(() {
      _trabajando = true;
      _resultado = null;
      _log.clear();
      _progresoFlash = 0;
      _estados['identificar'] = EstadoPaso.corriendo;
      _estados['respaldo'] = EstadoPaso.pendiente;
      _estados['espejo'] = EstadoPaso.pendiente;
    });
    final ejec = widget.crearEjecutor?.call() ??
        EjecutorRespaldo(
          telefono: widget.telefono,
          almacen: _almacen,
          puerto: _ctrlPuerto.text.trim().isEmpty
              ? null
              : _ctrlPuerto.text.trim(),
        );
    final espejo = _ctrlScp.text.trim();
    try {
      await for (final ev in ejec.correr(copiaEspejoScp: espejo)) {
        if (!mounted) return;
        setState(() {
          if (ev.logLinea != null) _log.add(ev.logLinea!);
          if (ev.progreso != null) _progresoFlash = ev.progreso!;
          if (ev.error != null) {
            // Un error SIN paso también se enseña (antes se descartaba).
            _log.add('ERROR: ${ev.error}');
            if (ev.paso != null) _estados[ev.paso!] = EstadoPaso.fallido;
          } else if (ev.paso != null) {
            if (ev.pasoHecho == true) {
              _estados[ev.paso!] = EstadoPaso.hecho;
              // El siguiente arranca en «corriendo» si no es el último.
              final orden = ['identificar', 'respaldo', 'espejo'];
              final i = orden.indexOf(ev.paso!);
              if (i >= 0 && i < orden.length - 1) {
                _estados[orden[i + 1]] = EstadoPaso.corriendo;
              }
            } else if (ev.pasoHecho == false) {
              _estados[ev.paso!] = EstadoPaso.corriendo;
            }
          }
        });
        // Pausa del ejecutor (reconectar en modo C, «executer»…): sin este
        // consumidor el Completer no se completaba nunca y el respaldo real
        // se quedaba colgado en la primera reconexión.
        if (ev.pausa != null) {
          final seguir = await resolverPausa(context, ev);
          if (!mounted) return;
          setState(() => _log.add(seguir
              ? '· continuar (confirmado por el usuario)'
              : '· cancelado por el usuario'));
        }
        // Autoscroll del log.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollLog.hasClients) {
            _scrollLog.jumpTo(_scrollLog.position.maxScrollExtent);
          }
        });
      }
      final modelo = widget.telefono.modelo == Modelo.desconocido
          ? 'W580'
          : widget.telefono.modelo.name.toUpperCase();
      final r = await _almacen.buscar(modelo, widget.telefono.idRespaldo);
      if (!mounted) return;
      setState(() {
        _resultado = r;
        _existente = r;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _log.add('EXCEPCIÓN: $e'));
    } finally {
      if (mounted) setState(() => _trabajando = false);
    }
  }

  /// Lo que hace el paso 2 con ESTE aparato, si ya se sabe su CID y color
  /// (los trae `Telefono` del identify de la pantalla de conectar).
  String _descripcionRespaldo() {
    const base = 'Dos copias del GDFS con SHA-256, read-flash completo de '
        '64 MiB y los metadatos del aparato.';
    final t = widget.telefono;
    if (t.cid == null || t.color == null) return base;
    final r = lecturaNorPara(
        modelo: t.modelo.name.toUpperCase(), cid: t.cid!, color: t.color!);
    switch (r.via) {
      case LecturaNor.anycid:
        return '$base En este aparato (RED) la NOR se lee por el exploit '
            'anycid: SENUS sube un paquete al teléfono (3 ficheros en su '
            'sistema de archivos: desde ahí ya no es solo lectura) y te pide '
            'abrir «executer». Son 4 pausas para volver a entrar en modo C.';
      case LecturaNor.noDisponible:
        return '$base ⚠ SENUS no puede completarlo con este aparato: '
            '${r.motivo}';
      case LecturaNor.directa:
        return '$base Son 3 pausas para volver a entrar en modo C.';
    }
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
      if (mounted) avisar(context, 'No pude abrir la carpeta: $e', bien: false);
    }
  }

  /// Puerto serie: lo que se autodetectó, y un campo para corregirlo. Si no
  /// se detectó nada, el campo sale vacío con la pista de qué escribir.
  Widget _campoPuerto(BuildContext context) {
    final c = context.col;
    return Padding(
      padding: const EdgeInsets.only(top: Esp.x3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctrlPuerto,
                  enabled: !_trabajando,
                  style: estiloDatos(context, tam: 12.5),
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: 'Puerto serie del cable',
                    hintText: Platform.isWindows
                        ? 'COM3'
                        : Platform.isMacOS
                            ? 'usb'
                            : '/dev/ttyUSB0',
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(Rad.chico)),
                  ),
                ),
              ),
              if (_puertosVistos.length > 1) ...[
                const SizedBox(width: Esp.x2),
                PopupMenuButton<String>(
                  tooltip: 'Puertos detectados',
                  enabled: !_trabajando,
                  icon: const Icon(Symbols.usb, size: 20),
                  itemBuilder: (_) => [
                    for (final x in _puertosVistos)
                      PopupMenuItem(value: x, child: Text(x)),
                  ],
                  onSelected: (x) => setState(() => _ctrlPuerto.text = x),
                ),
              ],
            ],
          ),
          const SizedBox(height: Esp.x2),
          Text(
            Platform.isMacOS
                ? 'En macOS el puerto es «usb» (el teléfono en modo C, APAGADO '
                    'y con la tecla C pulsada al enchufar, no crea /dev/cu.*). '
                    'Cada acción de seftool apaga el teléfono: SENUS te avisa '
                    'antes de cada paso para que vuelvas a entrar en modo C.'
                : _puertosVistos.isEmpty
                    ? 'No se detectó ningún puerto. Enchufa el cable DCU-60 con el '
                        'teléfono APAGADO y la tecla C pulsada, y escribe el puerto.'
                    : 'Detectado${_puertosVistos.length > 1 ? 's' : ''}: '
                        '${_puertosVistos.join(', ')}',
            style: context.tipo.bodySmall?.copyWith(color: c.textoTenue),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    return ListView(
      padding: const EdgeInsets.fromLTRB(Esp.x8, Esp.x8, Esp.x8, Esp.x8),
      children: [
        _CabeceraRollback(telefono: widget.telefono, existente: _existente),
        const SizedBox(height: Esp.x6),
        Padding(
          padding: const EdgeInsets.only(left: Esp.x1, bottom: Esp.x3),
          child: Text('PROCEDIMIENTO', style: context.tipo.labelSmall),
        ),
        EntradaSuave(
            child: _PasoTarjeta(
          numero: 1,
          icono: Symbols.manage_search,
          titulo: 'Identificar el aparato',
          descripcion:
              'Corre seftool identify. Lee Modelo, CID, COLOR y la versión de firmware original.',
          estado: _estados['identificar']!,
          hijo: _simulado ? null : _campoPuerto(context),
        )),
        const SizedBox(height: Esp.x3),
        EntradaSuave(
            retraso: escalon(1),
            child: _PasoTarjeta(
              numero: 2,
              icono: Symbols.cloud_download,
              titulo: 'Respaldo del firmware',
              descripcion: _descripcionRespaldo(),
              estado: _estados['respaldo']!,
              progreso: _estados['respaldo'] == EstadoPaso.corriendo
                  ? _progresoFlash
                  : null,
            )),
        const SizedBox(height: Esp.x3),
        EntradaSuave(
            retraso: escalon(2),
            child: _PasoTarjeta(
              numero: 3,
              icono: Symbols.cloud_sync,
              titulo: 'Copia en otro equipo (opcional)',
              descripcion:
                  'Guarda una segunda copia del respaldo en otro computador o servidor (se copia con scp -r).',
              estado: _estados['espejo']!,
              hijo: Padding(
                padding: const EdgeInsets.only(top: Esp.x3),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _ctrlScp,
                        enabled: !_trabajando,
                        style: estiloDatos(context, tam: 12.5),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: 'usuario@servidor:respaldos/senus/  (vacío = omitir)',
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(Rad.chico)),
                        ),
                      ),
                    ),
                    const SizedBox(width: Esp.x2),
                    TextButton(
                      onPressed:
                          _trabajando ? null : () => _ctrlScp.text = '',
                      child: const Text('Omitir'),
                    ),
                  ],
                ),
              ),
            )),
        const SizedBox(height: Esp.x6),
        Row(
          children: [
            FilledButton.icon(
              onPressed: _trabajando ? null : _correr,
              icon: Icon(
                  _resultado != null
                      ? Symbols.restart_alt
                      : Symbols.play_circle,
                  size: 20),
              label: Text(_resultado != null
                  ? 'Rehacer respaldo'
                  : 'Empezar respaldo'),
            ),
            const SizedBox(width: Esp.x3),
            if (_trabajando)
              Text('Corriendo…',
                  style: context.tipo.bodyMedium
                      ?.copyWith(color: c.textoTenue)),
          ],
        ),
        if (_log.isNotEmpty) ...[
          const SizedBox(height: Esp.x6),
          Padding(
            padding: const EdgeInsets.only(left: Esp.x1, bottom: Esp.x3),
            child: Text('REGISTRO', style: context.tipo.labelSmall),
          ),
          _PanelLog(scroll: _scrollLog, lineas: _log),
        ],
        if (_resultado != null) ...[
          const SizedBox(height: Esp.x6),
          EntradaSuave(
              child: _TarjetaExito(
            r: _resultado!,
            onAbrir: () => _abrirCarpeta(_resultado!.carpeta),
            onIrAInstalar: widget.onIrAInstalar,
          )),
        ],
        const SizedBox(height: Esp.x8),
      ],
    );
  }
}

class _CabeceraRollback extends StatelessWidget {
  final Telefono telefono;
  final RespaldoRollback? existente;
  const _CabeceraRollback({required this.telefono, this.existente});

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    return Superficie(
      relleno: const EdgeInsets.all(Esp.x6),
      resaltada: existente != null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TejaIcono(Symbols.verified_user,
              tam: 56,
              color: existente != null ? c.exito : c.acento,
              fondo:
                  (existente != null ? c.exito : c.acento).withAlpha(32)),
          const SizedBox(width: Esp.x4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Respaldo de rollback',
                    style: context.tipo.headlineSmall),
                const SizedBox(height: Esp.x1),
                Text(
                  'SENUS nunca instala senew sin haber guardado antes el firmware original. '
                  'Si algo sale mal, siempre puedes volver atrás.',
                  style: context.tipo.bodyMedium
                      ?.copyWith(color: c.textoTenue),
                ),
                const SizedBox(height: Esp.x3),
                Wrap(
                  spacing: Esp.x2,
                  runSpacing: Esp.x2,
                  children: [
                    Etiqueta('Aparato: ${telefono.nombreAmigo}',
                        icono: Symbols.smartphone,
                        color: c.textoTenue),
                    if (telefono.serie.isNotEmpty)
                      Etiqueta(telefono.serie,
                          icono: Symbols.badge,
                          mono: true,
                          color: c.textoTenue),
                    if (existente != null)
                      Etiqueta(
                          'Respaldo del ${existente!.fecha.toLocal().toString().substring(0, 10)}',
                          icono: Symbols.check_circle,
                          color: c.exito),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PasoTarjeta extends StatelessWidget {
  final int numero;
  final IconData icono;
  final String titulo;
  final String descripcion;
  final EstadoPaso estado;
  final double? progreso;
  final Widget? hijo;
  const _PasoTarjeta({
    required this.numero,
    required this.icono,
    required this.titulo,
    required this.descripcion,
    required this.estado,
    this.progreso,
    this.hijo,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    final (colFondo, colBorde, insignia) = _estilo(estado, c);
    return AnimatedContainer(
      duration: Mov.normal,
      curve: Mov.curva,
      decoration: BoxDecoration(
        color: colFondo,
        borderRadius: BorderRadius.circular(Rad.grande),
        border: Border.all(color: colBorde),
        boxShadow: c.sombraSuave(nivel: 1),
      ),
      padding: const EdgeInsets.all(Esp.x4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _NumeroPaso(numero: numero, estado: estado),
          const SizedBox(width: Esp.x4),
          Icon(icono, size: 24, color: c.acento, fill: 1),
          const SizedBox(width: Esp.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(titulo, style: context.tipo.titleMedium),
                    ),
                    insignia,
                  ],
                ),
                const SizedBox(height: Esp.x1),
                Text(descripcion,
                    style: context.tipo.bodySmall
                        ?.copyWith(color: c.textoTenue)),
                if (progreso != null) ...[
                  const SizedBox(height: Esp.x3),
                  Row(
                    children: [
                      Expanded(child: BarraUso(fraccion: progreso!, alto: 8)),
                      const SizedBox(width: Esp.x3),
                      Text('${(progreso! * 100).round()} %',
                          style: estiloDatos(context,
                              tam: 12, color: c.acento)),
                    ],
                  ),
                ],
                if (hijo != null) hijo!,
              ],
            ),
          ),
        ],
      ),
    );
  }

  (Color, Color, Widget) _estilo(EstadoPaso e, SenusColores c) {
    switch (e) {
      case EstadoPaso.pendiente:
        return (
          c.superficie,
          c.borde.withAlpha(140),
          Etiqueta('pendiente',
              icono: Symbols.schedule, color: c.textoTenue),
        );
      case EstadoPaso.corriendo:
        return (
          c.superficieElevada,
          c.acento.withAlpha(140),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: c.acento)),
              const SizedBox(width: Esp.x2),
              Text('corriendo…',
                  style: TextStyle(color: c.acento, fontSize: 12)),
            ],
          ),
        );
      case EstadoPaso.hecho:
        return (
          c.exito.withAlpha(14),
          c.exito.withAlpha(90),
          Etiqueta('hecho',
              icono: Symbols.check_circle, color: c.exito),
        );
      case EstadoPaso.fallido:
        return (
          c.error.withAlpha(16),
          c.error.withAlpha(90),
          Etiqueta('fallido', icono: Symbols.error, color: c.error),
        );
    }
  }
}

class _NumeroPaso extends StatelessWidget {
  final int numero;
  final EstadoPaso estado;
  const _NumeroPaso({required this.numero, required this.estado});

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    final hecho = estado == EstadoPaso.hecho;
    final fondo = hecho
        ? c.exito
        : estado == EstadoPaso.corriendo
            ? c.acento
            : c.superficieElevada;
    final texto = hecho
        ? const Icon(Symbols.check, color: Colors.white, size: 20)
        : Text('$numero',
            style: TextStyle(
                color: estado == EstadoPaso.corriendo
                    ? Colors.white
                    : c.textoTenue,
                fontWeight: FontWeight.w700));
    return AnimatedContainer(
      duration: Mov.normal,
      width: 36,
      height: 36,
      decoration: BoxDecoration(color: fondo, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: texto,
    );
  }
}

class _PanelLog extends StatelessWidget {
  final ScrollController scroll;
  final List<String> lineas;
  const _PanelLog({required this.scroll, required this.lineas});

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    return Container(
      height: 180,
      decoration: BoxDecoration(
        color: const Color(0xFF0A0A0C),
        borderRadius: BorderRadius.circular(Rad.medio),
        border: Border.all(color: c.borde.withAlpha(90)),
      ),
      padding: const EdgeInsets.all(Esp.x3),
      child: ListView.builder(
        controller: scroll,
        itemCount: lineas.length,
        itemBuilder: (_, i) => Text(
          lineas[i],
          style: estiloDatos(context,
              tam: 11.5, color: const Color(0xFFD9DADE)),
        ),
      ),
    );
  }
}

class _TarjetaExito extends StatelessWidget {
  final RespaldoRollback r;
  final VoidCallback onAbrir;
  final VoidCallback? onIrAInstalar;
  const _TarjetaExito(
      {required this.r, required this.onAbrir, this.onIrAInstalar});

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Rad.grande),
        gradient: LinearGradient(
          colors: [
            Color.lerp(c.exito, c.superficie, 0.72)!,
            c.superficie,
          ],
        ),
        border: Border.all(color: c.exito.withAlpha(110)),
        boxShadow: c.sombraSuave(nivel: 1.6),
      ),
      padding: const EdgeInsets.all(Esp.x6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Symbols.verified, color: c.exito, fill: 1, size: 32),
              const SizedBox(width: Esp.x3),
              Expanded(
                child: Text('Respaldo guardado',
                    style: context.tipo.titleLarge
                        ?.copyWith(color: c.exito)),
              ),
            ],
          ),
          const SizedBox(height: Esp.x3),
          Text('Carpeta', style: context.tipo.labelSmall),
          const SizedBox(height: Esp.x1),
          InkWell(
            onTap: onAbrir,
            borderRadius: BorderRadius.circular(Rad.chico),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(Symbols.folder_open, color: c.acento, size: 18),
                  const SizedBox(width: Esp.x2),
                  Expanded(
                    child: SelectableText(r.carpeta,
                        style: estiloDatos(context,
                            tam: 12.5, color: c.acento),
                        maxLines: 2),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: Esp.x3),
          Wrap(
            spacing: Esp.x3,
            runSpacing: Esp.x2,
            children: [
              Etiqueta('${r.modelo}  ·  ${r.serie}',
                  icono: Symbols.smartphone, mono: true, color: c.textoTenue),
              if (r.cid != null)
                Etiqueta('CID ${r.cid}',
                    icono: Symbols.key, color: c.textoTenue),
              if (r.firmwareOriginal != null)
                Etiqueta(r.firmwareOriginal!,
                    icono: Symbols.memory, color: c.textoTenue),
              // Un respaldo solo-GDFS (el de la primera instalación por
              // anycid + trampoline) no trae volcado de la NOR: shaFlash va
              // vacío y substring(0, 12) reventaría.
              if (r.shaFlash.length >= 12)
                Etiqueta('sha ${r.shaFlash.substring(0, 12)}…',
                    mono: true, color: c.textoTenue)
              else
                Etiqueta('solo GDFS, sin volcado de la NOR',
                    icono: Symbols.info, color: c.textoTenue),
            ],
          ),
          const SizedBox(height: Esp.x6),
          Row(
            children: [
              FilledButton.icon(
                onPressed: onIrAInstalar,
                icon: const Icon(Symbols.rocket_launch, size: 20),
                label: const Text('Habilitar instalación de senew'),
              ),
              const SizedBox(width: Esp.x3),
              TextButton.icon(
                onPressed: onAbrir,
                icon: const Icon(Symbols.folder_open, size: 18),
                label: const Text('Abrir carpeta'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
