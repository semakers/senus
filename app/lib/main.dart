// SENUS — puerta de la app. Elige pantalla y aplica tema.
// Menú LATERAL con Inicio, Catálogo, Apps, Ajustes del teléfono, Versión,
// Respaldo, Conexión, Fábrica y Ajustes de SENUS; el teléfono conectado abajo. Tema
// oscuro por omisión, claro opcional.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'widgets/pant_conectar.dart';
import 'widgets/pant_inicio.dart';
import 'widgets/pant_apps.dart';
import 'widgets/pant_respaldo.dart';
import 'widgets/pant_catalogo.dart';
import 'widgets/pant_fabrica.dart';
import 'widgets/pant_instalar_senew.dart';
import 'widgets/pant_instalar_inicial.dart';
import 'widgets/pant_instalar_inicial_legado.dart';
import 'widgets/pant_ajustes.dart';
import 'widgets/pant_ajustes_telefono.dart';
import 'widgets/pant_conexion.dart';
import 'widgets/pant_recuperacion.dart';
import 'widgets/pant_version.dart';
import 'widgets/comunes.dart';
import 'conexion/servicio_conexion.dart';
import 'datos/instalador_anycid.dart' show FlagsInstalacion;
import 'datos/licencias_terceros.dart';
import 'datos/telefono.dart';
import 'datos/transporte_bl.dart' show pidBlPropio;
import 'mtp/sesion_mtp.dart';
import 'servicios/arranque_servicios.dart';
import 'servicios/seccion_servicios.dart';
import 'tema/senus_tema.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  registrarLicenciasTerceros();
  runApp(const SenusApp(seccionConexion: SeccionServicios()));
  // El dictado y la música escuchan mientras SENUS esté abierta. Sus hijos se van
  // solos con ella: el ayudante al cerrarse su stdin y ffmpeg al romperse su tubería.
  unawaited(iniciarServiciosSenus());
}

class SenusApp extends StatefulWidget {
  /// Para las pruebas: arranca ya conectada, sin pasar por el USB.
  final ConexionViva? conexionInicial;
  final ContextoActualizacion? contexto;

  /// Para las pruebas: el puente sin Bluetooth de verdad.
  final ServicioConexion? conexion;

  /// La sección de dictado y música del apartado Conexión.
  final Widget? seccionConexion;

  const SenusApp({
    super.key,
    this.conexionInicial,
    this.contexto,
    this.conexion,
    this.seccionConexion,
  });

  @override
  State<SenusApp> createState() => _SenusAppState();
}

class _SenusAppState extends State<SenusApp> {
  // Estado global simple: el teléfono activo. null hasta que V1 lo elija.
  Telefono? _activo;
  SesionMtp? _sesion;

  // Ventana actual.
  _Pestana _pestana = _Pestana.inicio;

  // Una actualización en marcha: el menú no se puede usar.
  bool _ocupado = false;

  // El puente vive aquí y no en su pantalla: el teléfono sigue con internet al
  // quitar el cable. Se crea al abrir el apartado y muere con la app.
  ServicioConexion? _conexion;
  ServicioConexion get _puente =>
      _conexion ??= widget.conexion ?? ServicioConexion.deEstaMaquina();

  // Conexión abierta desde la pantalla de conectar, sin teléfono por USB.
  bool _conexionSinCable = false;

  @override
  void dispose() {
    _conexion?.dispose();
    super.dispose();
  }

  void _ponerOcupado(bool v) {
    if (mounted) setState(() => _ocupado = v);
  }

  // Oscuro por omisión; la elección se guarda en el directorio de la app.
  ThemeMode _modo = ThemeMode.dark;

  @override
  void initState() {
    super.initState();
    _activo = widget.conexionInicial?.telefono;
    _sesion = widget.conexionInicial?.sesion;
    if (_activo?.enRecuperacion ?? false) _pestana = _Pestana.recuperacion;
    _leerModo();
  }

  Future<File> _ficheroModo() async =>
      File(p.join((await getApplicationSupportDirectory()).path, 'tema.txt'));

  Future<void> _leerModo() async {
    try {
      final f = await _ficheroModo();
      if (!await f.exists()) return;
      final v = (await f.readAsString()).trim();
      if (!mounted) return;
      setState(() => _modo = v == 'claro' ? ThemeMode.light : ThemeMode.dark);
    } catch (_) {}
  }

  Future<void> _cambiarModo(ThemeMode m) async {
    setState(() => _modo = m);
    try {
      final f = await _ficheroModo();
      await f.parent.create(recursive: true);
      await f.writeAsString(m == ThemeMode.light ? 'claro' : 'oscuro');
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SENUS',
      debugShowCheckedModeBanner: false,
      theme: temaSenus(Brightness.light),
      darkTheme: temaSenus(Brightness.dark),
      themeMode: _modo,
      themeAnimationDuration: Mov.lento,
      themeAnimationCurve: Curves.easeInOut,
      home: AnimatedSwitcher(
        duration: Mov.lento,
        switchInCurve: Mov.curva,
        switchOutCurve: Curves.easeIn,
        child: _construir(),
      ),
    );
  }

  Widget _construir() {
    final tel = _activo;
    if (tel == null) {
      if (_conexionSinCable) {
        return Scaffold(
          key: const ValueKey('conexionSinCable'),
          body: PantConexion(
            conexion: _puente,
            seccionServicios: widget.seccionConexion,
            onVolver: () => setState(() => _conexionSinCable = false),
          ),
        );
      }
      return PantConectar(
        key: const ValueKey('conectar'),
        modo: _modo,
        onModo: _cambiarModo,
        onConexion: () => setState(() => _conexionSinCable = true),
        onConectado: (c) => setState(() {
          _conexionSinCable = false;
          _activo = c.telefono;
          _sesion = c.sesion;
          // Un aparato DE FÁBRICA no tiene apps ni memoria que enseñar: lo
          // que toca es INSTALAR senew (el flujo nuevo respalda primero, por
          // la regla de rollback). Si el flujo nuevo no lo cubre (CID53,
          // W600/W810), queda Fábrica con sus caminos heredados.
          _pestana = c.telefono.enRecuperacion
              ? _Pestana.recuperacion
              : !c.telefono.esDeFabrica
                  ? _Pestana.inicio
                  : (_entraEnFlujoNuevo(c.telefono)
                      ? _Pestana.instalarInicial
                      : _Pestana.fabrica);
        }),
        // «Mi W580 todavía no tiene senew»: derecho a instalarlo.
        onInstalarSenew: () => setState(() {
          _activo = Telefono.fabricaSinIdentificar;
          _sesion = null;
          _pestana = _Pestana.instalarInicial;
        }),
      );
    }
    return Scaffold(
      key: const ValueKey('principal'),
      body: Row(
        children: [
          _MenuLateral(
            pestana: _pestana,
            telefono: tel,
            bloqueado: _ocupado,
            onCambio: (p) => setState(() => _pestana = p),
            onDesconectar: _desconectar,
          ),
          // El fondo lo pone el Scaffold (aquí `context` está por encima del
          // MaterialApp y no ve el tema).
          Expanded(
            child: AnimatedSwitcher(
                duration: Mov.normal,
                switchInCurve: Mov.curva,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (hijo, a) => FadeTransition(
                  opacity: a,
                  child: SlideTransition(
                    position: Tween(begin: const Offset(0, 0.015), end: Offset.zero).animate(a),
                    child: hijo,
                  ),
                ),
                layoutBuilder: (actual, previos) => Stack(
                  alignment: Alignment.topLeft,
                  children: [...previos, if (actual != null) actual],
                ),
                child: KeyedSubtree(key: ValueKey(_pestana), child: _cuerpo(tel)),
              ),
          ),
        ],
      ),
    );
  }

  /// ¿Este aparato va por el flujo nuevo de primera instalación? Con
  /// SENUS_FLUJO_LEGADO=1 no: salen los caminos de antes.
  static bool _entraEnFlujoNuevo(Telefono t) =>
      !FlagsInstalacion.flujoLegado() && t.entraEnInstalacionInicial;

  Future<void> _desconectar() async {
    final s = _sesion;
    if (s != null) {
      try { await s.cerrar(); } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _activo = null;
      _sesion = null;
      _pestana = _Pestana.inicio;
    });
  }

  /// Tras actualizar o recuperar, senew volvió con una sesión nueva.
  void _sesionNueva(SesionMtp s, Telefono t) {
    if (!mounted) return;
    setState(() {
      _sesion = s;
      _activo = t;
      _pestana = _Pestana.version;
    });
  }

  Widget _cuerpo(Telefono tel) {
    final s = _sesion;
    switch (_pestana) {
      case _Pestana.inicio:
        return PantInicio(
          telefono: tel,
          onApps: () => setState(() => _pestana = _Pestana.apps),
          onRespaldo: () => setState(() => _pestana = _Pestana.respaldo),
          onCatalogo: () => setState(() => _pestana = _Pestana.catalogo),
          onVersion: () => setState(() => _pestana = _Pestana.version),
        );
      case _Pestana.catalogo:
        return PantCatalogo(telefono: tel, sesion: s);
      case _Pestana.apps:
        return PantApps(
          telefono: tel,
          sesion: s,
          onVersion: () => setState(() => _pestana = _Pestana.version),
        );
      case _Pestana.ajustesTelefono:
        return PantAjustesTelefono(
          telefono: tel,
          sesion: s,
          onVersion: () => setState(() => _pestana = _Pestana.version),
        );
      case _Pestana.version:
        return PantVersion(
          telefono: tel,
          sesion: s,
          contexto: widget.contexto,
          onOcupado: _ponerOcupado,
          onSesionNueva: _sesionNueva,
          onRecuperar: () => setState(() {
            _activo = Telefono.enBootloader(pidBlPropio);
            _sesion = null;
            _pestana = _Pestana.recuperacion;
          }),
          onReconectar: _desconectar,
        );
      case _Pestana.recuperacion:
        return PantRecuperacion(
          telefono: tel,
          contexto: widget.contexto,
          onOcupado: _ponerOcupado,
          onSesionNueva: _sesionNueva,
        );
      case _Pestana.respaldo:
        return PantRespaldo(telefono: tel, sesion: s);
      case _Pestana.conexion:
        return PantConexion(
          conexion: _puente,
          telefono: tel,
          sesion: s,
          seccionServicios: widget.seccionConexion,
        );
      case _Pestana.fabrica:
        return PantFabrica(
          telefono: tel,
          onIrAInstalar: () => setState(() => _pestana = _entraEnFlujoNuevo(tel)
              ? _Pestana.instalarInicial
              : _Pestana.instalar),
        );
      case _Pestana.instalar:
        return PantInstalarSenew(
          telefono: tel,
          onIrAFabrica: () => setState(() => _pestana = _Pestana.fabrica),
        );
      case _Pestana.instalarInicial:
        // Primera instalación en un W580 de fábrica: anycid + trampoline + BL
        // installer, con UN paso manual (Juegos → eXploit). El flujo anterior
        // (executor.b propio y ritual de 6 pasos) sigue en el repo detrás de
        // SENUS_FLUJO_LEGADO=1; «Instalar senew» conserva el camino para lo
        // que el flujo nuevo no cubre (CID53, W600/W810).
        if (FlagsInstalacion.flujoLegado()) {
          return PantInstalarInicialLegado(
            telefono: tel,
            onIrAFabrica: () => setState(() => _pestana = _Pestana.fabrica),
          );
        }
        return PantInstalarInicial(
          telefono: tel,
          onIrAFabrica: () => setState(() => _pestana = _Pestana.fabrica),
        );
      case _Pestana.ajustes:
        return PantAjustes(modo: _modo, onModo: _cambiarModo);
    }
  }
}

enum _Pestana {
  inicio,
  catalogo,
  apps,
  ajustesTelefono,
  version,
  recuperacion,
  respaldo,
  conexion,
  fabrica,
  instalar,
  instalarInicial,
  ajustes,
}

class _MenuLateral extends StatelessWidget {
  final _Pestana pestana;
  final Telefono telefono;
  final bool bloqueado;
  final ValueChanged<_Pestana> onCambio;
  final VoidCallback onDesconectar;
  const _MenuLateral({
    required this.pestana,
    required this.telefono,
    required this.bloqueado,
    required this.onCambio,
    required this.onDesconectar,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    // En un aparato DE FÁBRICA no hay sesión MTP: Catálogo, Apps y Respaldo
    // no tienen con quién hablar, así que no se ofrecen. Quedan las
    // herramientas, que es justo el camino de la regla de rollback.
    final principales = telefono.enRecuperacion
        ? const <_Entrada>[
            _Entrada(_Pestana.recuperacion, Symbols.healing, 'Recuperación'),
          ]
        : telefono.esDeFabrica
            ? const <_Entrada>[]
            : const <_Entrada>[
                _Entrada(_Pestana.inicio, Symbols.smartphone, 'Inicio'),
                _Entrada(_Pestana.catalogo, Symbols.storefront, 'Catálogo'),
                _Entrada(_Pestana.apps, Symbols.apps, 'Apps'),
                _Entrada(_Pestana.ajustesTelefono, Symbols.tune, 'Ajustes'),
                _Entrada(_Pestana.version, Symbols.system_update, 'Versión'),
                _Entrada(_Pestana.respaldo, Symbols.settings_backup_restore,
                    'Respaldo'),
                _Entrada(_Pestana.conexion, Symbols.bluetooth, 'Conexión'),
              ];
    final legado = FlagsInstalacion.flujoLegado();
    // El flujo nuevo (W580 de fábrica CID52) va PRIMERO y se llama como la
    // persona lo busca: «Instalar senew». Lo heredado solo sale si el flujo
    // nuevo no cubre el aparato, o con SENUS_FLUJO_LEGADO=1.
    final nuevo = !legado && telefono.entraEnInstalacionInicial;
    final secundarias = <_Entrada>[
      if (nuevo)
        const _Entrada(_Pestana.instalarInicial, Symbols.rocket_launch,
            'Instalar senew'),
      const _Entrada(
          _Pestana.fabrica, Symbols.precision_manufacturing, 'Fábrica'),
      if (!nuevo && !telefono.enRecuperacion)
        const _Entrada(_Pestana.instalar, Symbols.rocket_launch,
            'Instalar senew'),
      if (legado && telefono.esDeFabrica)
        const _Entrada(_Pestana.instalarInicial, Symbols.alt_route,
            'Instalación inicial (heredada)'),
      const _Entrada(_Pestana.ajustes, Symbols.contrast, 'Ajustes de SENUS'),
    ];
    return Container(
      width: 248,
      decoration: BoxDecoration(
        color: c.superficie,
        border: Border(right: BorderSide(color: c.borde)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(Esp.x6, Esp.x8, Esp.x6, Esp.x8),
            child: MarcaSenus(),
          ),
          // En una ventana baja el menú se desplaza; el teléfono sigue abajo.
          Expanded(
            child: AbsorbPointer(
              absorbing: bloqueado,
              child: Opacity(
                opacity: bloqueado ? 0.45 : 1,
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    for (final e in principales)
                      _ItemMenu(entrada: e, elegido: pestana == e.pest, onTap: () => onCambio(e.pest)),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(Esp.x6, Esp.x6, Esp.x6, Esp.x2),
                      child: Text(telefono.esDeFabrica ? 'APARATO DE FÁBRICA' : 'HERRAMIENTAS',
                          style: context.tipo.labelSmall),
                    ),
                    for (final e in secundarias)
                      _ItemMenu(entrada: e, elegido: pestana == e.pest, onTap: () => onCambio(e.pest)),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(Esp.x4),
            child: AbsorbPointer(
              absorbing: bloqueado,
              child: _ChipTelefono(telefono: telefono, onDesconectar: onDesconectar),
            ),
          ),
        ],
      ),
    );
  }
}

class _ItemMenu extends StatefulWidget {
  final _Entrada entrada;
  final bool elegido;
  final VoidCallback onTap;
  const _ItemMenu({required this.entrada, required this.elegido, required this.onTap});

  @override
  State<_ItemMenu> createState() => _ItemMenuState();
}

class _ItemMenuState extends State<_ItemMenu> {
  bool _encima = false;

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    final sel = widget.elegido;
    final fondo = sel
        ? c.acentoApagado
        : (_encima ? c.superficieElevada : Colors.transparent);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Esp.x3, vertical: 2),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _encima = true),
        onExit: (_) => setState(() => _encima = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Pulsable(
            child: AnimatedContainer(
              duration: Mov.normal,
              curve: Mov.curva,
              height: 44,
              decoration: BoxDecoration(
                color: fondo,
                borderRadius: BorderRadius.circular(Rad.medio),
              ),
              child: Row(
                children: [
                  // La barrita naranja del elemento elegido.
                  AnimatedContainer(
                    duration: Mov.normal,
                    curve: Mov.curva,
                    width: 3,
                    height: sel ? 20 : 0,
                    margin: const EdgeInsets.only(left: Esp.x1, right: Esp.x3 - 1),
                    decoration: BoxDecoration(
                      color: c.acento,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Icon(widget.entrada.icono,
                      size: 21,
                      fill: sel ? 1 : 0,
                      weight: sel ? 500 : 400,
                      color: sel ? c.acento : c.textoTenue),
                  const SizedBox(width: Esp.x3),
                  Expanded(
                    child: Text(
                      widget.entrada.etiqueta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.tipo.bodyMedium?.copyWith(
                        fontWeight: sel ? FontWeight.w600 : FontWeight.w500,
                        color: sel ? c.texto : c.textoTenue,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// El teléfono conectado, abajo del menú.
class _ChipTelefono extends StatelessWidget {
  final Telefono telefono;
  final VoidCallback onDesconectar;
  const _ChipTelefono({required this.telefono, required this.onDesconectar});

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    return Container(
      padding: const EdgeInsets.fromLTRB(Esp.x3, Esp.x3, Esp.x1, Esp.x3),
      decoration: BoxDecoration(
        color: c.superficieElevada,
        borderRadius: BorderRadius.circular(Rad.medio),
        boxShadow: c.sombraSuave(nivel: 0.6),
      ),
      child: Row(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              const TejaIcono(Symbols.smartphone, tam: 36),
              Positioned(
                right: -2,
                bottom: -2,
                child: Container(
                  width: 11,
                  height: 11,
                  decoration: BoxDecoration(
                    color: c.exito,
                    shape: BoxShape.circle,
                    border: Border.all(color: c.superficieElevada, width: 2),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: Esp.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(telefono.nombreAmigo,
                    style: context.tipo.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                Text(
                    telefono.enRecuperacion
                        ? 'bootloader'
                        : 'senew ${telefono.gestion?.version ?? telefono.versionSenew}',
                    style: estiloDatos(context, tam: 11)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Symbols.link_off, size: 20),
            tooltip: 'Desconectar',
            onPressed: onDesconectar,
          ),
        ],
      ),
    );
  }
}

class _Entrada {
  final _Pestana pest;
  final IconData icono;
  final String etiqueta;
  const _Entrada(this.pest, this.icono, this.etiqueta);
}
