// Pantalla «Instalar senew» — PRIMERA instalación en un W580 de fábrica.
//
// El flujo que se probó en silicio el 2026-10-30 (anycid + trampoline + BL
// installer), con UN solo paso manual: abrir «Juegos → eXploit» en el
// teléfono. Todo lo demás es automático por USB. La lógica vive en
// `datos/instalador_anycid.dart`; aquí solo se pintan sus eventos.
//
//   Identificar → Respaldar el GDFS → Subir el instalador → [Juegos → eXploit]
//   → Grabar senew (main + bootloader) → Esperar a senew
//
// REGLA DE ROLLBACK: sin respaldo del GDFS de ESTE aparato no se sube nada; si
// no existe, se hace aquí (dos lecturas con sha256). Al final se enseña dónde
// queda y cómo se vuelve atrás.
//
// Solo macOS. En Windows y Linux la pantalla dice «próximamente» y no deja
// empezar. El flujo heredado (executor.b propio, 6 pasos manuales) vive en
// `pant_instalar_inicial_legado.dart` y solo sale con SENUS_FLUJO_LEGADO=1.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../datos/artefactos_bundle.dart';
import '../datos/artefactos_instalador.dart';
import '../datos/instalador_anycid.dart';
import '../datos/instalador_driver.dart';
import '../datos/respaldo_rollback.dart';
import '../datos/seftool.dart';
import '../datos/telefono.dart';
import '../datos/transporte_bl.dart';
import '../tema/senus_tema.dart';
import 'comunes.dart';

class PantInstalarInicial extends StatefulWidget {
  final Telefono telefono;

  /// Los siguientes se inyectan en las pruebas; null = los de verdad.
  final AlmacenRespaldos? almacen;
  final FuenteArtefactos? fuente;
  final Seftool Function()? fabricaSeftool;
  final TransporteBl Function(int pid)? fabricaBl;
  final String? sistema;
  final Map<String, String>? env;

  /// Instalador del driver USB de Windows. Null → el de verdad.
  final InstaladorDriverUsb? instaladorDriver;

  /// Qué pasa con el botón «Ir a Fábrica».
  final VoidCallback? onIrAFabrica;

  const PantInstalarInicial({
    super.key,
    required this.telefono,
    this.almacen,
    this.fuente,
    this.fabricaSeftool,
    this.fabricaBl,
    this.sistema,
    this.env,
    this.instaladorDriver,
    this.onIrAFabrica,
  });

  @override
  State<PantInstalarInicial> createState() => _PantInstalarInicialState();
}

class _PantInstalarInicialState extends State<PantInstalarInicial> {
  late final AlmacenRespaldos _almacen;
  late final GatePlataforma _gate;

  ArtefactosW580? _art;
  String? _errorArtefactos;

  // Casillas.
  bool _confirmaPantalla = false;
  bool _aceptaNoVerificado = false;

  // Estado de la corrida.
  final Map<FaseInstalador, EstadoFase> _estado = {};
  final Map<FaseInstalador, String> _notas = {};
  final List<String> _log = [];
  FaseInstalador? _faseActual;
  double? _progreso;
  bool _corriendo = false;
  bool _cancelando = false;
  EventoInstalador? _fallo;
  ResumenInstalacion? _resumen;
  CancelacionInstalador? _cancel;
  StreamSubscription<EventoInstalador>? _sub;
  PausaInstalador? _pausaAbierta;

  @override
  void initState() {
    super.initState();
    _almacen = widget.almacen ?? AlmacenRespaldos.predeterminado();
    _gate = GatePlataforma.evaluar(sistema: widget.sistema, env: widget.env);
    _cargarArtefactos();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _cancel?.cancelar();
    final p = _pausaAbierta;
    if (p != null && !p.respuesta.isCompleted) p.respuesta.complete(false);
    super.dispose();
  }

  Future<void> _cargarArtefactos() async {
    try {
      final a = await ArtefactosW580.cargar(
          widget.fuente ?? const FuenteArtefactosBundle());
      if (!mounted) return;
      setState(() => _art = a);
    } on ArtefactosError catch (e) {
      if (!mounted) return;
      setState(() => _errorArtefactos = '${e.motivo}\n${e.remedio ?? ''}'.trim());
    }
  }

  /// ¿El aparato conectado entra en este flujo? Mirada previa con lo que ya
  /// sabe la pantalla de conexión (el paquete regional lo resuelve seftool
  /// después). null = sí.
  String? _noEntra() {
    final t = widget.telefono;
    if (!t.esDeFabrica) {
      return 'Este teléfono ya corre senew. Esta pantalla es para la primera '
          'instalación, en un W580 de fábrica con su firmware original.';
    }
    final a = _art;
    if (a == null) return null;
    final r = evaluarAplicabilidad(
      modelo: t.modelo == Modelo.desconocido ? 'W580' : t.modelo.name,
      cid: t.cid ?? '52',
      color: t.color ?? 'RED',
      firmware: t.firmwareOriginal ?? 'R8BE001',
      paquete: null,
      artefactos: a,
      exigirPaquete: false,
    );
    return r.aplica ? null : r.motivo;
  }

  // ---------------------------------------------------------------------- //

  void _empezar() {
    if (_corriendo) return;
    final cancel = CancelacionInstalador();
    _cancel = cancel;
    setState(() {
      _corriendo = true;
      _cancelando = false;
      _fallo = null;
      _resumen = null;
      _estado.clear();
      _notas.clear();
      _log.clear();
      _faseActual = null;
      _progreso = null;
    });
    final ins = InstaladorAnycid(
      telefono: widget.telefono,
      fabricaSeftool: widget.fabricaSeftool ??
          () => Seftool(
                raiz: Seftool.raizPredeterminada,
                puerto: Seftool.autodetectarPuerto() ?? '',
              ),
      almacen: _almacen,
      fuente: widget.fuente ?? const FuenteArtefactosBundle(),
      artefactos: _art,
      fabricaBl: widget.fabricaBl,
      cancelacion: cancel,
      confirmaPantalla: _confirmaPantalla,
      aceptaNoVerificado: _aceptaNoVerificado,
      sistema: widget.sistema,
      env: widget.env,
    );
    _sub = ins.correr().listen(
      _alEvento,
      onError: (Object e) {
        if (!mounted) return;
        setState(() => _fallo = EventoInstalador.fallo(
            _faseActual, 'Error inesperado: $e',
            remedio: 'Si ya se estaba grabando, no apagues el teléfono: '
                'desconecta y vuelve a enchufar el cable y reintenta.'));
      },
      onDone: () {
        if (!mounted) return;
        setState(() {
          _corriendo = false;
          _cancelando = false;
        });
      },
    );
  }

  void _alEvento(EventoInstalador e) {
    if (!mounted) return;
    setState(() {
      if (e.log != null) {
        _log.add(e.log!);
        if (_log.length > 3000) _log.removeRange(0, 500);
      }
      final f = e.fase;
      if (f != null) {
        if (e.estado != null) {
          _estado[f] = e.estado!;
          _faseActual = f;
          _progreso = null;
        }
        if (e.nota != null) _notas[f] = e.nota!;
        if (e.estado == null && e.nota != null) _progreso = e.progreso;
      }
      if (e.error != null) _fallo = e;
      if (e.resumen != null) _resumen = e.resumen;
    });
    final p = e.pausa;
    if (p != null) _mostrarPausa(p);
  }

  Future<void> _mostrarPausa(PausaInstalador p) async {
    _pausaAbierta = p;
    final seguir = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _DialogoPausa(
        pausa: p,
        instalarDriver: p.accionDriver == null
            ? null
            : () => _instalarDriver(p.accionDriver!),
      ),
    );
    if (!p.respuesta.isCompleted) p.respuesta.complete(seguir == true);
    _pausaAbierta = null;
  }

  void _onLog(String l) {
    if (!mounted) return;
    setState(() => _log.add(l));
  }

  /// «Instalar driver USB»: lo hace [InstaladorDriverUsb] (UAC de Windows) y
  /// deja el resultado en el registro. Devuelve el mensaje para la pantalla.
  Future<ResultadoDriver> _instalarDriver(AccionDriver a) async {
    final inst = widget.instaladorDriver ?? InstaladorDriverUsb();
    final r = await inst.instalar(a, alLog: _onLog);
    _onLog(r.ok ? '✓ ${r.mensaje}' : '✗ ${r.mensaje}');
    return r;
  }

  void _cancelar() {
    _cancel?.cancelar();
    setState(() => _cancelando = true);
  }

  Future<void> _abrirCarpeta(String ruta) async {
    try {
      if (Platform.isMacOS) {
        await Process.run('open', [ruta]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [ruta]);
      } else if (Platform.isWindows) {
        await Process.run('explorer', [ruta]);
      }
    } catch (_) {}
  }

  // ---------------------------------------------------------------------- //
  // UI
  // ---------------------------------------------------------------------- //

  @override
  Widget build(BuildContext context) {
    final noEntra = _gate.permitida ? _noEntra() : null;
    final puedeEmpezar = _gate.permitida &&
        noEntra == null &&
        _art != null &&
        _confirmaPantalla &&
        !_corriendo;
    return Column(
      children: [
        CabeceraPantalla(
          titulo: 'Instalar senew',
          subtitulo: 'Primera instalación en un W580 de fábrica · '
              'un solo paso manual',
          acciones: [
            if (widget.onIrAFabrica != null)
              OutlinedButton.icon(
                onPressed: _corriendo ? null : widget.onIrAFabrica,
                icon: const Icon(Symbols.arrow_back),
                label: const Text('Ir a Fábrica'),
              ),
            if (_corriendo)
              OutlinedButton.icon(
                onPressed: _cancelando ? null : _cancelar,
                icon: const Icon(Symbols.close),
                label: Text(_cancelando ? 'Cancelando…' : 'Cancelar'),
              )
            else
              FilledButton.icon(
                key: const ValueKey('empezar'),
                onPressed: puedeEmpezar ? _empezar : null,
                icon: const Icon(Symbols.play_arrow),
                label: Text(_fallo != null || _resumen != null
                    ? 'Repetir'
                    : 'Empezar'),
              ),
          ],
        ),
        Expanded(
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                      Esp.x8, Esp.x2, Esp.x4, Esp.x8),
                  children: _cuerpo(noEntra),
                ),
              ),
              Expanded(flex: 4, child: _panelLog()),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _cuerpo(String? noEntra) {
    final c = context.col;
    if (!_gate.permitida) {
      return [
        EstadoVacio(
          icono: Symbols.schedule,
          titulo: 'Próximamente',
          texto: _gate.motivo!,
        ),
      ];
    }
    return [
      if (_errorArtefactos != null) ...[
        AvisoError('El instalador empotrado no es válido, así que no se '
            'puede empezar:\n$_errorArtefactos'),
        const SizedBox(height: Esp.x4),
      ],
      if (noEntra != null) ...[
        AvisoError(noEntra),
        const SizedBox(height: Esp.x4),
      ],
      if (_resumen != null) ..._tarjetaListo(_resumen!),
      if (_fallo != null) ..._tarjetaFallo(_fallo!),
      if (_resumen == null && !_corriendo) _intro(),
      if (!_corriendo && _resumen == null) ..._casillas(),
      const SizedBox(height: Esp.x2),
      if (_faseActual == FaseInstalador.esperarExploit &&
          _estado[FaseInstalador.esperarExploit] == EstadoFase.corriendo)
        _instruccionExploit(c),
      for (final f in FaseInstalador.values) _tarjetaFase(f, c),
    ];
  }

  Widget _intro() {
    final c = context.col;
    final a = _art;
    return Superficie(
      relleno: const EdgeInsets.all(Esp.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Qué va a pasar', style: context.tipo.titleSmall),
          const SizedBox(height: Esp.x2),
          Text(
            '1. SENUS comprueba que tienes un respaldo del GDFS de ESTE '
            'teléfono y, si no, lo hace ahora.\n'
            '2. Sube el instalador al teléfono por USB.\n'
            '3. Tú abres «Juegos → eXploit» en el teléfono (el único paso '
            'manual).\n'
            '4. SENUS graba senew y su bootloader (~45 s). No desconectes.\n'
            '5. El teléfono arranca con senew.',
            style: context.tipo.bodyMedium?.copyWith(color: c.textoTenue),
          ),
          if (a != null) ...[
            const SizedBox(height: Esp.x3),
            Text(
              'Instalador empotrado: ${a.sha256Por.length} ficheros · senew '
              '${(a.main.length / 1048576).toStringAsFixed(2)} MiB · '
              '${a.paquetesR8be001.length} paquetes regionales',
              style: estiloDatos(context, tam: 11),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _casillas() {
    return [
      const SizedBox(height: Esp.x3),
      CheckboxListTile(
        key: const ValueKey('casillaPantalla'),
        value: _confirmaPantalla,
        onChanged: (v) => setState(() => _confirmaPantalla = v == true),
        controlAffinity: ListTileControlAffinity.leading,
        contentPadding: EdgeInsets.zero,
        title: const Text('Mi teléfono tiene pantalla y SIM'),
        subtitle: const Text('Hay que abrir un juego en el teléfono: sin '
            'pantalla no se puede.'),
      ),
      CheckboxListTile(
        key: const ValueKey('casillaNoVerificado'),
        value: _aceptaNoVerificado,
        onChanged: (v) => setState(() => _aceptaNoVerificado = v == true),
        controlAffinity: ListTileControlAffinity.leading,
        contentPadding: EdgeInsets.zero,
        title: const Text('Permitir un paquete regional no probado'),
        subtitle: Text('Solo ${_art?.paqueteVerificado ?? 'el GENERIC_LA'} se '
            'ha verificado en un teléfono real.'),
      ),
    ];
  }

  /// El único paso manual, en grande.
  Widget _instruccionExploit(SenusColores c) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Esp.x3),
      child: Container(
        padding: const EdgeInsets.all(Esp.x6),
        decoration: BoxDecoration(
          color: c.acento.withAlpha(30),
          borderRadius: BorderRadius.circular(Rad.medio),
          border: Border.all(color: c.acento),
        ),
        child: Row(
          children: [
            Icon(Symbols.smartphone, color: c.acento, size: 36),
            const SizedBox(width: Esp.x4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Ahora, en el teléfono',
                      style: context.tipo.titleMedium),
                  const SizedBox(height: Esp.x1),
                  Text(
                    'Enciéndelo con SIM, abre Juegos → eXploit y córrelo.\n'
                    'SENUS sigue solo en cuanto el teléfono reaparezca.',
                    style: context.tipo.bodyLarge,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tarjetaFase(FaseInstalador f, SenusColores c) {
    final e = _estado[f];
    final icono = switch (e) {
      null => Symbols.radio_button_unchecked,
      EstadoFase.corriendo => Symbols.autorenew,
      EstadoFase.hecha => Symbols.check_circle,
      EstadoFase.aviso => Symbols.warning,
      EstadoFase.fallida => Symbols.error,
    };
    final color = switch (e) {
      null => c.textoTenue,
      EstadoFase.corriendo => c.acento,
      EstadoFase.hecha => c.exito,
      EstadoFase.aviso => c.aviso,
      EstadoFase.fallida => c.error,
    };
    final nota = _notas[f];
    final activa = e == EstadoFase.corriendo;
    return Padding(
      padding: const EdgeInsets.only(bottom: Esp.x2),
      child: Container(
        padding: const EdgeInsets.all(Esp.x3),
        decoration: BoxDecoration(
          color: c.superficieElevada,
          borderRadius: BorderRadius.circular(Rad.medio),
          border: Border.all(color: activa ? c.acento : c.borde),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icono, color: color),
                const SizedBox(width: Esp.x3),
                Expanded(
                  child: Text(nombreFase(f),
                      style: context.tipo.bodyMedium?.copyWith(
                          color: e == null ? c.textoTenue : c.texto,
                          fontWeight: activa ? FontWeight.w600 : null)),
                ),
              ],
            ),
            if (nota != null && nota.isNotEmpty) ...[
              const SizedBox(height: Esp.x1),
              Padding(
                padding: const EdgeInsets.only(left: 36),
                child: Text(nota, style: estiloDatos(context, tam: 11)),
              ),
            ],
            if (activa) ...[
              const SizedBox(height: Esp.x2),
              Padding(
                padding: const EdgeInsets.only(left: 36),
                child: LinearProgressIndicator(value: _progreso),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _tarjetaFallo(EventoInstalador e) {
    final c = context.col;
    return [
      AvisoError([
        if (e.cancelado) 'Cancelado.' else 'No se pudo completar.',
        if (e.error != null) e.error!,
        if (e.remedio != null && e.remedio!.isNotEmpty) '\n${e.remedio!}',
      ].join('\n')),
      if (e.accionDriver != null) ...[
        const SizedBox(height: Esp.x3),
        _BotonInstalarDriver(
          onInstalar: () => _instalarDriver(e.accionDriver!),
        ),
      ],
      if (e.sinBootloader) ...[
        const SizedBox(height: Esp.x3),
        Container(
          padding: const EdgeInsets.all(Esp.x4),
          decoration: BoxDecoration(
            color: c.aviso.withAlpha(30),
            borderRadius: BorderRadius.circular(Rad.medio),
            border: Border.all(color: c.aviso),
          ),
          child: Text(
            'NO apagues ni desconectes el teléfono. Puede estar sin '
            'bootloader en la memoria hasta que termine de grabarse; el '
            'instalador sigue vivo en su RAM. Vuelve a ejecutar «Juegos → '
            'eXploit» con el cable puesto y pulsa Repetir.',
            style: context.tipo.bodyMedium,
          ),
        ),
      ],
      const SizedBox(height: Esp.x4),
    ];
  }

  List<Widget> _tarjetaListo(ResumenInstalacion r) {
    final c = context.col;
    return [
      Container(
        padding: const EdgeInsets.all(Esp.x6),
        decoration: BoxDecoration(
          color: c.exito.withAlpha(26),
          borderRadius: BorderRadius.circular(Rad.medio),
          border: Border.all(color: c.exito.withAlpha(110)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Symbols.check_circle, color: c.exito, size: 28, fill: 1),
              const SizedBox(width: Esp.x3),
              Expanded(
                child: Text(
                  r.senewEnElBus
                      ? '¡Listo! senew ya corre en tu W580.'
                      : '¡Listo! senew quedó grabado y verificado.',
                  style: context.tipo.titleMedium,
                ),
              ),
            ]),
            if (!r.senewEnElBus) ...[
              const SizedBox(height: Esp.x2),
              Text(
                'Todavía no lo veo en el USB: mira la pantalla del teléfono y, '
                'si no arrancó, apágalo y enciéndelo.',
                style: context.tipo.bodyMedium,
              ),
            ],
            const SizedBox(height: Esp.x4),
            SelectableText(r.textoRollback,
                style: estiloDatos(context, tam: 12)),
            const SizedBox(height: Esp.x3),
            Wrap(spacing: Esp.x2, children: [
              OutlinedButton.icon(
                onPressed: () => _abrirCarpeta(r.respaldo.carpeta),
                icon: const Icon(Symbols.folder_open),
                label: const Text('Abrir el respaldo'),
              ),
              if (widget.onIrAFabrica != null)
                OutlinedButton.icon(
                  onPressed: widget.onIrAFabrica,
                  icon: const Icon(Symbols.precision_manufacturing),
                  label: const Text('Ir a Fábrica'),
                ),
            ]),
          ],
        ),
      ),
      const SizedBox(height: Esp.x4),
    ];
  }

  Widget _panelLog() {
    final c = context.col;
    return Container(
      margin: const EdgeInsets.fromLTRB(Esp.x4, Esp.x2, Esp.x8, Esp.x8),
      padding: const EdgeInsets.all(Esp.x4),
      decoration: BoxDecoration(
        color: c.superficieElevada,
        borderRadius: BorderRadius.circular(Esp.x3),
        border: Border.all(color: c.borde),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Registro',
              style: context.tipo.titleMedium?.copyWith(color: c.textoTenue)),
          const SizedBox(height: Esp.x3),
          Expanded(
            child: ListView.builder(
              reverse: true,
              itemCount: _log.length,
              itemBuilder: (_, i) => Text(_log[_log.length - 1 - i],
                  style: estiloDatos(context, tam: 11)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Botón «Instalar driver USB» con su estado: muestra qué pasó debajo.
class _BotonInstalarDriver extends StatefulWidget {
  final Future<ResultadoDriver> Function() onInstalar;
  const _BotonInstalarDriver({required this.onInstalar});

  @override
  State<_BotonInstalarDriver> createState() => _BotonInstalarDriverState();
}

class _BotonInstalarDriverState extends State<_BotonInstalarDriver> {
  bool _ocupado = false;
  ResultadoDriver? _resultado;

  Future<void> _pulsar() async {
    setState(() {
      _ocupado = true;
      _resultado = null;
    });
    final r = await widget.onInstalar();
    if (!mounted) return;
    setState(() {
      _ocupado = false;
      _resultado = r;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        FilledButton.icon(
          key: const ValueKey('instalarDriver'),
          onPressed: _ocupado ? null : _pulsar,
          icon: _ocupado
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Symbols.usb),
          label: Text(_ocupado ? 'Instalando…' : 'Instalar driver USB'),
        ),
        if (_resultado != null) ...[
          const SizedBox(height: Esp.x2),
          Text(
            _resultado!.mensaje,
            style: context.tipo.bodySmall?.copyWith(
                color: _resultado!.ok ? c.exito : c.error),
          ),
        ],
      ],
    );
  }
}

/// El diálogo de las pausas humanas; si la pausa trae un aparato sin driver,
/// añade el botón de instalarlo.
class _DialogoPausa extends StatelessWidget {
  final PausaInstalador pausa;
  final Future<ResultadoDriver> Function()? instalarDriver;
  const _DialogoPausa({required this.pausa, required this.instalarDriver});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(pausa.titulo),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(pausa.detalle),
            if (instalarDriver != null) ...[
              const SizedBox(height: Esp.x4),
              _BotonInstalarDriver(onInstalar: instalarDriver!),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar')),
        FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Continuar')),
      ],
    );
  }
}
