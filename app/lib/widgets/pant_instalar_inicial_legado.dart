// ⚠ FLUJO LEGADO — solo se ofrece con SENUS_FLUJO_LEGADO=1.
//
// Es la pantalla del executor.b PROPIO + ritual de 6 pasos (sacar la pila…).
// El 2026-10-30 se comprobó que el AMS rechaza un executor.b modificado
// («Aplicación no válida»); lo que funciona es el flujo anycid + trampoline de
// `pant_instalar_inicial.dart` / `datos/instalador_anycid.dart`, con UN solo
// paso manual. Esto se conserva por si el flujo nuevo no cubriera algún CID52
// R8BE001 (documento técnico §13); no se mantiene.
//
// Pantalla «Instalación inicial de senew» — el flujo nuevo, cableado contra
// `instalacion_inicial.dart`.
//
// Diferencia con `pant_instalar_senew.dart`: la pantalla heredada pelea con
// el fork SEMC para escribir en la NOR vía anycid+bflash o anycid+payload;
// esta usa NUESTRO installer (executor + bootloader propio con PID 0x0003)
// y, una vez el BL está en bus, escribe sistema.bin y w6fs_*.bin con
// WIPE/WRITE/CRC. Al terminar, polling de 1209:0001 para confirmar que
// senew normal arrancó.
//
// Pasos (ver `PasoInstalacion`):
//   0 identificar     — seftool identify (se delega en el respaldo de abajo)
//   1 respaldo        — EjecutorRespaldo (regla inviolable)
//   2 subirExecutor   — seftool upload-anycid con el zip del installer
//   3 ritualUsuario   — pantallas guiadas, el humano confirma cada paso
//   4 esperarInstaller — polling USB 1209:0003 (2 min)
//   5 enviarMain      — WRITE 0x44180000 (barra de progreso)
//   6 enviarW6fs      — WRITE a la dirección del w6fs_XXXXXXXX.bin
//   7 salir           — BL salta a senew
//   8 esperarSenew    — polling 1209:0001 (1 min)
//   9 copiarApps      — PantCatalogo embebida (opcional, hoy TODO)
//
// Diseño: lista vertical de tarjetas-paso, con «Siguiente» cuando toca al
// usuario y con barra de progreso para los pasos del BL. Al terminar, la
// tarjeta de «senew instalado» con la ruta del respaldo (regla rollback).

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path/path.dart' as p;

import '../datos/instalacion_inicial.dart';
import '../datos/respaldo_rollback.dart';
import '../datos/seftool.dart';
import '../datos/telefono.dart';
import '../datos/transporte_bl.dart';
import '../tema/senus_tema.dart';
import 'comunes.dart';

/// Estado de un paso para pintar su tarjeta.
enum _EstadoPaso { pendiente, enEspera, corriendo, hecho, fallido }

class PantInstalarInicialLegado extends StatefulWidget {
  final Telefono telefono;

  /// Almacén. Null → el predeterminado.
  final AlmacenRespaldos? almacen;

  /// Carpeta base de los paquetes del installer. Null → `./anycid/senew_installer`
  /// dentro de la raíz de SENUS. Los tests inyectan una temporal.
  final String? carpetaAnycidInstaller;

  /// Carpeta base del `senew-w580/build` donde buscar hitos
  /// `aparato_sis*`. Null → `$HOME/dev/w580/sistema`.
  final String? raizSistema;

  /// Fábrica inyectable para los tests: devuelve un transporte BL por PID.
  final TransporteBl Function(int pid)? fabricaBl;

  /// Fábrica inyectable del Seftool. Null → el real.
  final Seftool Function()? fabricaSeftool;

  /// Qué pasa cuando el usuario pulsa el botón de volver a Fábrica.
  final VoidCallback? onIrAFabrica;

  const PantInstalarInicialLegado({
    super.key,
    required this.telefono,
    this.almacen,
    this.carpetaAnycidInstaller,
    this.raizSistema,
    this.fabricaBl,
    this.fabricaSeftool,
    this.onIrAFabrica,
  });

  @override
  State<PantInstalarInicialLegado> createState() =>
      _PantInstalarInicialLegadoState();
}

class _PantInstalarInicialLegadoState
    extends State<PantInstalarInicialLegado> {
  late final AlmacenRespaldos _almacen;
  late InstalacionInicial _ins;

  // Estado por paso.
  final Map<PasoInstalacion, _EstadoPaso> _estado = {
    for (final p in PasoInstalacion.values) p: _EstadoPaso.pendiente,
  };
  final List<String> _log = [];
  double? _progreso;
  String _nota = '';
  bool _corriendo = false;

  RespaldoRollback? _respaldo;
  HitoAparato? _hito;

  @override
  void initState() {
    super.initState();
    _almacen = widget.almacen ?? AlmacenRespaldos.predeterminado();
    _ins = InstalacionInicial(
      fabricaBl: widget.fabricaBl,
      alLogSeftool: _onLog,
    );
  }

  void _onLog(String l) {
    if (!mounted) return;
    setState(() => _log.add(l));
  }

  void _marcar(PasoInstalacion p, _EstadoPaso e, {String? nota, double? prog}) {
    if (!mounted) return;
    setState(() {
      _estado[p] = e;
      if (nota != null) _nota = nota;
      _progreso = prog;
    });
  }

  // ---------------------------------------------------------------------- //
  // Lanzador del flujo completo. Cada paso llama al siguiente SOLO si el
  // anterior terminó bien. Un fallo congela la lista con el motivo.
  // ---------------------------------------------------------------------- //

  Future<void> _lanzar() async {
    if (_corriendo) return;
    setState(() {
      _corriendo = true;
      _log.clear();
      _nota = '';
      _progreso = null;
      for (final p in PasoInstalacion.values) {
        _estado[p] = _EstadoPaso.pendiente;
      }
    });

    try {
      // 0) identificar + 1) respaldo — se delegan en EjecutorRespaldo.
      //    Si ya hay respaldo para este (modelo, serial), se salta; si no,
      //    corre el respaldo entero. En esta primera versión mostramos un
      //    aviso para que el usuario vaya a la pantalla de Fábrica.
      _marcar(PasoInstalacion.identificar, _EstadoPaso.corriendo);
      final existente = await _almacen.buscar(
          widget.telefono.modelo == Modelo.desconocido
              ? 'W580'
              : widget.telefono.modelo.name.toUpperCase(),
          widget.telefono.idRespaldo);
      if (existente == null) {
        _marcar(PasoInstalacion.identificar, _EstadoPaso.fallido,
            nota:
                'No hay respaldo para este aparato: abre Fábrica y haz el '
                'respaldo primero (REGLA INVIOLABLE).');
        return;
      }
      _respaldo = existente;
      _marcar(PasoInstalacion.identificar, _EstadoPaso.hecho,
          nota: 'Aparato: ${existente.modelo} IMEI ${existente.serie}');
      _marcar(PasoInstalacion.respaldo, _EstadoPaso.hecho,
          nota: 'Respaldo: ${existente.carpeta}');

      // 2) subir el executor del installer.
      _marcar(PasoInstalacion.subirExecutor, _EstadoPaso.corriendo);
      final sef = (widget.fabricaSeftool ?? _seftoolPorOmision)();
      final carpeta = widget.carpetaAnycidInstaller ?? _carpetaInstallerPorOmision();
      try {
        await _ins.subirExecutor(sef, existente.serie, carpeta);
      } on InstalacionInicialError catch (e) {
        _marcar(PasoInstalacion.subirExecutor, _EstadoPaso.fallido,
            nota: '${e.motivo}\n${e.remedio ?? ''}');
        return;
      } on SeftoolError catch (e) {
        _marcar(PasoInstalacion.subirExecutor, _EstadoPaso.fallido,
            nota: '${e.motivo}\n${e.remedio ?? ''}');
        return;
      }
      _marcar(PasoInstalacion.subirExecutor, _EstadoPaso.hecho,
          nota: 'Installer subido al teléfono');

      // 3) ritual del usuario: 6 pasos manuales, confirmados por botón.
      _marcar(PasoInstalacion.ritualUsuario, _EstadoPaso.corriendo);
      final ok = await _dialogoRitual();
      if (!ok) {
        _marcar(PasoInstalacion.ritualUsuario, _EstadoPaso.fallido,
            nota: 'Cancelado por el usuario.');
        return;
      }
      _marcar(PasoInstalacion.ritualUsuario, _EstadoPaso.hecho);

      // 4) esperar al installer (hasta 2 min).
      _marcar(PasoInstalacion.esperarInstaller, _EstadoPaso.corriendo,
          nota: 'Esperando al bootloader del installer…');
      try {
        await _ins.esperarPuenteInstaller();
      } on InstalacionInicialError catch (e) {
        _marcar(PasoInstalacion.esperarInstaller, _EstadoPaso.fallido,
            nota: '${e.motivo}\n${e.remedio ?? ''}');
        return;
      }
      _marcar(PasoInstalacion.esperarInstaller, _EstadoPaso.hecho,
          nota: 'BL en bus: VID:PID 1209:0003');

      // Localizar el último hito del aparato.
      final raiz = widget.raizSistema ?? _raizSistemaPorOmision();
      final hitos = await listarHitosAparato(raiz);
      if (hitos.isEmpty) {
        _marcar(PasoInstalacion.enviarMain, _EstadoPaso.fallido,
            nota: 'No hay compilación de aparato en $raiz/build/. '
                'Compila con `make aparato` en senew-w580.');
        return;
      }
      _hito = hitos.first;

      // 5) enviar main (barra de progreso).
      _marcar(PasoInstalacion.enviarMain, _EstadoPaso.corriendo,
          nota: 'Enviando ${p.basename(_hito!.sistemaBin.path)} '
              'a 0x${_hito!.direccionMain.toRadixString(16).toUpperCase()}');
      final datosMain = await _hito!.sistemaBin.readAsBytes();
      try {
        await _ins.enviarMain(
          Uint8List.fromList(datosMain),
          direccion: _hito!.direccionMain,
          onProgreso: (h, t) => _marcar(
              PasoInstalacion.enviarMain, _EstadoPaso.corriendo,
              prog: h / t),
        );
      } on InstalacionInicialError catch (e) {
        _marcar(PasoInstalacion.enviarMain, _EstadoPaso.fallido,
            nota: '${e.motivo}\n${e.remedio ?? ''}');
        return;
      }
      _marcar(PasoInstalacion.enviarMain, _EstadoPaso.hecho,
          nota: '${datosMain.length} B grabados', prog: 1.0);

      // 6) enviar W6FS.
      _marcar(PasoInstalacion.enviarW6fs, _EstadoPaso.corriendo,
          nota: 'Enviando ${p.basename(_hito!.w6fsBin.path)} '
              'a 0x${_hito!.direccionW6fs.toRadixString(16).toUpperCase()}');
      final datosFs = await _hito!.w6fsBin.readAsBytes();
      try {
        await _ins.enviarW6fs(
          Uint8List.fromList(datosFs),
          direccion: _hito!.direccionW6fs,
          onProgreso: (h, t) => _marcar(
              PasoInstalacion.enviarW6fs, _EstadoPaso.corriendo,
              prog: h / t),
        );
      } on InstalacionInicialError catch (e) {
        _marcar(PasoInstalacion.enviarW6fs, _EstadoPaso.fallido,
            nota: '${e.motivo}\n${e.remedio ?? ''}');
        return;
      }
      _marcar(PasoInstalacion.enviarW6fs, _EstadoPaso.hecho,
          nota: '${datosFs.length} B grabados', prog: 1.0);

      // 7) SALIR.
      _marcar(PasoInstalacion.salir, _EstadoPaso.corriendo);
      try {
        await _ins.salir();
      } on InstalacionInicialError catch (e) {
        _marcar(PasoInstalacion.salir, _EstadoPaso.fallido,
            nota: '${e.motivo}\n${e.remedio ?? ''}');
        return;
      }
      _marcar(PasoInstalacion.salir, _EstadoPaso.hecho);

      // 8) esperar a senew.
      _marcar(PasoInstalacion.esperarSenew, _EstadoPaso.corriendo,
          nota: 'Apaga y vuelve a encender el teléfono si no arranca solo.');
      final llego = await _ins.esperarSenewNormal();
      if (!llego) {
        _marcar(PasoInstalacion.esperarSenew, _EstadoPaso.fallido,
            nota: 'Senew no apareció en 1 min. Comprueba que el teléfono '
                'arrancó y que el cable sigue puesto.');
        return;
      }
      _marcar(PasoInstalacion.esperarSenew, _EstadoPaso.hecho,
          nota: 'Senew normal en el bus (1209:0001)');

      // 9) copiar apps — opcional. En esta primera versión la saltamos y
      //    sugerimos abrir la pantalla de Apps/Catálogo.
      // TODO: embeber una variante compacta de PantCatalogo que ofrezca
      // multiselección y lo copie con SesionMtp.enviarObjeto.
      _marcar(PasoInstalacion.copiarApps, _EstadoPaso.hecho,
          nota: 'Omitido en esta versión. Abre «Apps» para copiarlas.');
    } finally {
      if (mounted) setState(() => _corriendo = false);
    }
  }

  Seftool _seftoolPorOmision() => Seftool(
        raiz: Seftool.raizPredeterminada,
        puerto: Seftool.autodetectarPuerto() ?? '',
      );

  String _carpetaInstallerPorOmision() {
    // En producción, los paquetes del installer viven junto a SENUS:
    // anycid/senew_installer/<modelo>/
    final hogar = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    final mod = (_respaldo?.modelo ?? 'W580').toLowerCase();
    return p.join(hogar, 'dev', 'senus', 'anycid', 'senew_installer', mod);
  }

  String _raizSistemaPorOmision() {
    final hogar = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    return p.join(hogar, 'dev', 'w580', 'sistema');
  }

  // ---------------------------------------------------------------------- //
  // Diálogo guiado del ritual (6 instrucciones). Devuelve true si el usuario
  // llegó al final; false si canceló en cualquier punto.
  // ---------------------------------------------------------------------- //

  Future<bool> _dialogoRitual() async {
    const pasos = [
      ('El teléfono se apagó. Desconecta el cable.',
          'Después de upload-anycid el aparato suele quedarse apagado. Quita '
          'el cable DCU-60.'),
      ('Enciende el teléfono.',
          'Mantén la tecla C pulsada mientras pulsas Encendido para que '
          'arranque entero (no en modo servicio).'),
      ('Abre «Senew Installer».',
          'Menú → Juegos → «Senew Installer» → pulsa Seleccionar.'),
      ('El teléfono se apagará solo.',
          'Es parte del flujo del installer. Saca la pila y vuelve a '
          'ponerla.'),
      ('Enciende el teléfono SIN enchufar el cable.',
          'Pulsa Encendido con el cable fuera. Verás el logo «Senew '
          'Installer» en pantalla.'),
      ('Enchufa el cable DCU-60.',
          'Con «Senew Installer» en pantalla, enchufa el cable. SENUS '
          'detectará el bootloader en segundos.'),
    ];
    for (var i = 0; i < pasos.length; i++) {
      final titulo = pasos[i].$1;
      final detalle = pasos[i].$2;
      final seguir = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: Text('Paso ${i + 1}/${pasos.length}: $titulo'),
          content: Text(detalle),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancelar')),
            FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Siguiente')),
          ],
        ),
      );
      if (seguir != true) return false;
    }
    return true;
  }

  // ---------------------------------------------------------------------- //
  // UI
  // ---------------------------------------------------------------------- //

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    return Column(
      children: [
        CabeceraPantalla(
          titulo: 'Instalación inicial de senew',
          subtitulo:
              'Flujo nuevo: executor del installer + bootloader propio + '
              'main + W6FS. Pensado para un W580 recién salido de la caja.',
          acciones: [
            if (widget.onIrAFabrica != null)
              OutlinedButton.icon(
                onPressed: widget.onIrAFabrica,
                icon: const Icon(Symbols.arrow_back),
                label: const Text('Ir a Fábrica'),
              ),
            const SizedBox(width: Esp.x2),
            FilledButton.icon(
              onPressed: _corriendo ? null : _lanzar,
              icon: const Icon(Symbols.play_arrow),
              label: Text(_corriendo ? 'En marcha…' : 'Empezar'),
            ),
          ],
        ),
        if (_progreso != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Esp.x8),
            child: LinearProgressIndicator(value: _progreso),
          ),
        if (_nota.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(Esp.x8, Esp.x3, Esp.x8, 0),
            child: Text(_nota, style: estiloDatos(context, tam: 12)),
          ),
        Expanded(
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                      Esp.x8, Esp.x4, Esp.x4, Esp.x8),
                  children: [
                    for (final paso in PasoInstalacion.values)
                      _tarjetaPaso(paso, c),
                  ],
                ),
              ),
              Expanded(
                flex: 4,
                child: Container(
                  margin: const EdgeInsets.fromLTRB(
                      Esp.x4, Esp.x4, Esp.x8, Esp.x8),
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
                          style: context.tipo.titleMedium
                              ?.copyWith(color: c.textoTenue)),
                      const SizedBox(height: Esp.x3),
                      Expanded(
                        child: ListView.builder(
                          reverse: true,
                          itemCount: _log.length,
                          itemBuilder: (_, i) => Text(
                              _log[_log.length - 1 - i],
                              style: estiloDatos(context, tam: 11)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _tarjetaPaso(PasoInstalacion paso, SenusColores c) {
    final estado = _estado[paso]!;
    final icono = switch (estado) {
      _EstadoPaso.pendiente => Symbols.radio_button_unchecked,
      _EstadoPaso.enEspera => Symbols.schedule,
      _EstadoPaso.corriendo => Symbols.autorenew,
      _EstadoPaso.hecho => Symbols.check_circle,
      _EstadoPaso.fallido => Symbols.error,
    };
    final color = switch (estado) {
      _EstadoPaso.pendiente => c.textoTenue,
      _EstadoPaso.enEspera => c.textoTenue,
      _EstadoPaso.corriendo => c.acento,
      _EstadoPaso.hecho => c.exito,
      _EstadoPaso.fallido => c.error,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: Esp.x2),
      child: Container(
        padding: const EdgeInsets.all(Esp.x3),
        decoration: BoxDecoration(
          color: c.superficieElevada,
          borderRadius: BorderRadius.circular(Esp.x2),
          border: Border.all(color: c.borde),
        ),
        child: Row(
          children: [
            Icon(icono, color: color),
            const SizedBox(width: Esp.x3),
            Expanded(
                child: Text(nombrePaso(paso),
                    style: context.tipo.bodyMedium?.copyWith(color: color))),
          ],
        ),
      ),
    );
  }
}
