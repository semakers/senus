// V3 — Apps. Todas las apps del teléfono, con su origen, icono y versión, y si
// el catálogo trae algo más nuevo. Las de fábrica solo se ven con canal de
// gestión. Quitar solo se ofrece para lo que se puede quitar.

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path/path.dart' as p;

import '../datos/app_sen.dart';
import '../datos/apps_telefono.dart';
import '../datos/backend_semakers.dart';
import '../datos/indice_semakers.dart';
import '../datos/sen_cab.dart';
import '../datos/servicios_senus.dart';
import '../datos/telefono.dart';
import '../mtp/sesion_mtp.dart';
import '../mtp/transporte.dart' show TransporteError;
import '../tema/senus_tema.dart';
import 'comunes.dart';
import 'icono_sen.dart';
import 'pant_catalogo.dart' show confirmarQuitarTapa;

class PantApps extends StatefulWidget {
  final Telefono telefono;
  final SesionMtp? sesion;

  /// Para las pruebas. Sin él, el de esta compilación.
  final ClienteBackend? backend;

  /// Ir a la pantalla de versión de senew.
  final VoidCallback? onVersion;
  const PantApps({
    super.key,
    required this.telefono,
    required this.sesion,
    this.backend,
    this.onVersion,
  });

  @override
  State<PantApps> createState() => _PantAppsState();
}

class _PantAppsState extends State<PantApps> {
  List<AppSen> _apps = const [];
  Map<String, AppIndice> _catalogo = const {};
  ClienteBackend? _backend;
  bool _cargando = true;
  String? _error;
  bool _trabajando = false;

  @override
  void initState() {
    super.initState();
    _refrescar();
  }

  Future<void> _refrescar() async {
    final s = widget.sesion;
    if (s == null) {
      setState(() {
        _apps = const [];
        _cargando = false;
        _error = 'No hay sesión MTP activa.';
      });
      return;
    }
    setState(() {
      _cargando = true;
      _error = null;
    });
    try {
      final r = await ServicioApps(s, widget.telefono).listar();
      if (!mounted) return;
      setState(() => _apps = r);
      await _leerCatalogo();
    } catch (e) {
      if (mounted) setState(() => _error = 'Error: $e');
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  /// El catálogo solo aporta «hay una versión nueva»: si no hay red, la lista
  /// de apps sale igual.
  Future<void> _leerCatalogo() async {
    try {
      final b = _backend ??= widget.backend ?? await backendPredeterminado();
      final r = await b.indice();
      if (!mounted) return;
      setState(
          () => _catalogo = {for (final a in r.indice.apps) a.id: a});
    } on SinRed {
      // Sin red no se sabe si hay actualizaciones; no es un error aquí.
    } on ErrorVerificacion {
      // Un catálogo que no pasa no dice nada de lo instalado.
    }
  }

  /// «Actualizar» sale solo donde cambia algo: en la copia que manda y que la
  /// tienda puede pisar.
  AppIndice? _actualizacion(AppSen a) {
    final c = _catalogo[a.id];
    if (c == null || a.tapada) return null;
    if (a.origen != OrigenApp.memoria && a.origen != OrigenApp.fabrica) return null;
    return situacionCatalogo(c, _apps).estado == EstadoCatalogo.hayActualizacion
        ? c
        : null;
  }

  /// La situación que hay que arreglar, para la copia que tapa.
  SituacionCatalogo? _tapada(AppSen a) {
    final c = _catalogo[a.id];
    if (c == null) return null;
    final s = situacionCatalogo(c, _apps);
    return s.estado == EstadoCatalogo.tapada &&
            s.sePuedeResolver &&
            identical(s.rival, a)
        ? s
        : null;
  }

  Future<void> _resolver(AppSen a, SituacionCatalogo st) async {
    final s = widget.sesion;
    final c = _catalogo[a.id];
    final b = _backend;
    if (s == null || c == null || b == null) return;
    if (!await confirmarQuitarTapa(context, c.nombre, st)) return;
    setState(() => _trabajando = true);
    try {
      await ServicioApps(s, widget.telefono).resolverTapada(b, c, st);
      if (!mounted) return;
      _snack('Listo: ya manda la copia de la Memoria de ${c.nombre}');
      await _refrescar();
    } on ErrorVerificacion catch (e) {
      _snack('No se tocó nada: $e', bien: false);
    } on SinRed catch (e) {
      _snack('No se tocó nada: $e', bien: false);
    } on ErrorInstalarApp catch (e) {
      _snack(e.motivo, bien: false);
      await _refrescar();
    } on TransporteError catch (e) {
      _snack('Se perdió la conexión: ${e.motivo}', bien: false);
    } finally {
      if (mounted) setState(() => _trabajando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final conCanal = widget.telefono.canalGestion;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CabeceraPantalla(
          titulo: 'Apps instaladas',
          subtitulo: conCanal
              ? 'De fábrica, Memoria y Tarjeta'
              : 'Memoria y Tarjeta, lo que se ve por MTP',
          acciones: [
            if (!_cargando)
              Etiqueta('${_apps.length} apps', mono: true, color: context.col.acento),
            IconButton(
              onPressed: _trabajando || _cargando ? null : _refrescar,
              icon: const Icon(Symbols.refresh),
              tooltip: 'Refrescar',
            ),
            Pulsable(
              activo: !_trabajando,
              child: FilledButton.icon(
                onPressed: _trabajando ? null : _subir,
                icon: const Icon(Symbols.upload, size: 20),
                label: const Text('Subir .sen'),
              ),
            ),
          ],
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(Esp.x8, 0, Esp.x8, Esp.x4),
            child: AvisoError(_error!),
          ),
        if (!conCanal)
          Padding(
            padding: const EdgeInsets.fromLTRB(Esp.x8, 0, Esp.x8, Esp.x4),
            child: FranjaAviso(
              'Este senew no tiene canal de gestión: las apps de fábrica no se '
              'ven desde aquí. Actualízalo para ver todas.',
              accion: widget.onVersion == null
                  ? null
                  : TextButton(
                      onPressed: widget.onVersion,
                      child: const Text('Ver versión')),
            ),
          ),
        AnimatedContainer(
          duration: Mov.normal,
          height: _trabajando ? 2 : 0,
          margin: const EdgeInsets.symmetric(horizontal: Esp.x8),
          child: _trabajando ? const LinearProgressIndicator(minHeight: 2) : null,
        ),
        Expanded(child: _lista()),
      ],
    );
  }

  static const _relleno = EdgeInsets.fromLTRB(Esp.x8, Esp.x2, Esp.x8, Esp.x8);

  Widget _lista() {
    if (_cargando) {
      return Brillo(
        child: ListView.separated(
          padding: _relleno,
          itemCount: 5,
          separatorBuilder: (_, __) => const SizedBox(height: Esp.x2),
          itemBuilder: (_, __) => const _FilaHueso(),
        ),
      );
    }
    if (_apps.isEmpty) {
      return const EstadoVacio(
        icono: Symbols.apps,
        titulo: 'No hay apps',
        texto: 'Instala alguna desde el Catálogo o sube un .sen desde tu computadora.',
      );
    }
    return ListView.separated(
      padding: _relleno,
      itemCount: _apps.length,
      separatorBuilder: (_, __) => const SizedBox(height: Esp.x2),
      itemBuilder: (c, i) {
        final a = _apps[i];
        return EntradaSuave(
          retraso: escalon(i),
          child: _FilaApp(
            app: a,
            detalle: _detalle(a),
            ocupado: _trabajando,
            actualizacion: _actualizacion(a),
            tapadaPor: copiaQueLaTapa(_apps, a),
            situacion: _tapada(a),
            onResolver: () {
              final st = _tapada(a);
              if (st != null) _resolver(a, st);
            },
            onBajar: a.handle == 0 ? null : () => _bajar(a),
            onBorrar: () => _borrar(a),
            onActualizar: () => _actualizar(a),
          ),
        );
      },
    );
  }

  String _detalle(AppSen a) {
    // KiB hasta 1 MiB: una app típica pesa unos KiB y «0.01 MiB» no dice nada.
    final tam = a.bytes >= 1024 * 1024
        ? '${(a.bytes / (1024 * 1024)).toStringAsFixed(2)} MiB'
        : '${(a.bytes / 1024).toStringAsFixed(1)} KiB';
    final fecha = a.modificado?.toLocal().toString().substring(0, 16) ?? '';
    final ver = a.verApp == null ? '' : 'v${a.verApp}  ·  ';
    return '$ver$tam${fecha.isNotEmpty ? '  ·  $fecha' : ''}';
  }

  Future<void> _actualizar(AppSen a) async {
    final s = widget.sesion;
    final c = _actualizacion(a);
    final b = _backend;
    if (s == null || c == null || b == null) return;
    setState(() => _trabajando = true);
    try {
      await ServicioApps(s, widget.telefono).instalar(b, c);
      if (!mounted) return;
      _snack('Actualizada y comprobada: ${c.nombre}');
      await _refrescar();
    } on ErrorVerificacion catch (e) {
      _snack('No se instaló nada: $e', bien: false);
    } on SinRed catch (e) {
      _snack('No se instaló nada: $e', bien: false);
    } on ErrorInstalarApp catch (e) {
      _snack(e.motivo, bien: false);
    } on TransporteError catch (e) {
      _snack('Se perdió la conexión: ${e.motivo}', bien: false);
    } finally {
      if (mounted) setState(() => _trabajando = false);
    }
  }

  Future<void> _subir() async {
    final s = widget.sesion;
    if (s == null) return;
    final res = await FilePicker.platform.pickFiles(
      dialogTitle: 'Elige una .sen para subir',
      type: FileType.custom,
      allowedExtensions: const ['sen'],
    );
    if (res == null || res.files.isEmpty) return;
    final path = res.files.single.path;
    if (path == null) return;
    final f = File(path);
    final bytes = await f.readAsBytes();
    final nombre = p.basename(path);
    setState(() => _trabajando = true);
    try {
      final problema = problemaDeSen(bytes);
      if (problema != null) {
        _snack('$nombre no vale: $problema', bien: false);
        return;
      }
      final r = await s.subirAppVerificada(nombre, bytes);
      if (!mounted) return;
      final ok = r.bien;
      _snack(ok ? 'Subida y comprobada: $nombre' : (r.mensaje ?? 'Error al subir'),
          bien: ok);
      if (ok) await _refrescar();
    } catch (e) {
      _snack('Error: $e', bien: false);
    } finally {
      if (mounted) setState(() => _trabajando = false);
    }
  }

  Future<void> _bajar(AppSen a) async {
    final s = widget.sesion;
    if (s == null) return;
    final destino = await FilePicker.platform.saveFile(
      dialogTitle: 'Guardar ${a.nombre} como…',
      fileName: a.nombre,
    );
    if (destino == null) return;
    setState(() => _trabajando = true);
    try {
      final r = await s.bajarApp(a.handle);
      if (!mounted) return;
      if (!r.bien) {
        _snack(r.mensaje ?? 'Error al bajar', bien: false);
        return;
      }
      await File(destino).writeAsBytes(r.valor!);
      _snack('Guardada en $destino');
    } catch (e) {
      _snack('Error: $e', bien: false);
    } finally {
      if (mounted) setState(() => _trabajando = false);
    }
  }

  Future<void> _borrar(AppSen a) async {
    final s = widget.sesion;
    if (s == null) return;
    final si = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        icon: Icon(Symbols.delete, color: context.col.error),
        title: const Text('¿Quitar la app?'),
        content: Text(a.tapada || _hayDeFabrica(a)
            ? '«${a.tituloVisible}» se quita de ${a.origen.rotulo}. Volverá la '
                'versión de fábrica.'
            : '«${a.tituloVisible}» desaparecerá del teléfono. No se puede '
                'deshacer.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancelar')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: context.col.error, foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Quitar')),
        ],
      ),
    );
    if (si != true) return;
    setState(() => _trabajando = true);
    try {
      await ServicioApps(s, widget.telefono).quitar(a);
      if (!mounted) return;
      _snack('Quitada: ${a.tituloVisible}');
      await _refrescar();
    } on ErrorInstalarApp catch (e) {
      _snack(e.motivo, bien: false);
    } catch (e) {
      _snack('Error: $e', bien: false);
    } finally {
      if (mounted) setState(() => _trabajando = false);
    }
  }

  bool _hayDeFabrica(AppSen a) =>
      _apps.any((x) => x.deFabrica && x.id == a.id && !identical(x, a));

  void _snack(String texto, {bool bien = true}) {
    if (!mounted) return;
    avisar(context, texto, bien: bien);
  }
}

class _FilaApp extends StatelessWidget {
  final AppSen app;
  final String detalle;
  final bool ocupado;
  final AppIndice? actualizacion;
  final AppSen? tapadaPor;
  final SituacionCatalogo? situacion;
  final VoidCallback onResolver;
  final VoidCallback? onBajar;
  final VoidCallback onBorrar;
  final VoidCallback onActualizar;
  const _FilaApp({
    required this.app,
    required this.detalle,
    required this.ocupado,
    required this.actualizacion,
    required this.tapadaPor,
    required this.situacion,
    required this.onResolver,
    required this.onBajar,
    required this.onBorrar,
    required this.onActualizar,
  });

  SenCab get _cab => SenCab(
        nombre: app.tituloVisible,
        iconoAn: app.iconoAn,
        iconoFilas:
            app.iconoFilas.length == 12 ? app.iconoFilas : List.filled(12, 0),
        iconoGen: app.iconoGen,
        tamFich: app.bytes,
        perfil: app.perfil,
        apiMayor: app.apiMayor,
        apiMenor: app.apiMenor,
      );

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    final a = app;
    final nueva = actualizacion;
    return Superficie(
      radio: Rad.medio,
      relleno: const EdgeInsets.fromLTRB(Esp.x4, Esp.x3, Esp.x2, Esp.x3),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            height: 40,
            child: FittedBox(child: IconoSen(cab: _cab)),
          ),
          const SizedBox(width: Esp.x4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(a.tituloVisible,
                    style: context.tipo.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: Esp.x1),
                Wrap(
                  spacing: Esp.x2,
                  runSpacing: Esp.x1,
                  children: [
                    Etiqueta(a.origen.rotulo,
                        icono: a.deFabrica ? Symbols.lock : null,
                        color: a.deFabrica ? c.aviso : null),
                    if (a.tapada)
                      Etiqueta(tapadaPor == null
                          ? 'tapada por otra copia'
                          : 'manda la de ${tapadaPor!.origen.rotulo}'),
                    if (nueva != null)
                      Etiqueta('nueva: v${nueva.verApp}',
                          icono: Symbols.update, color: c.acento),
                  ],
                ),
                const SizedBox(height: 2),
                Text('${a.nombre}  ·  $detalle',
                    style: estiloDatos(context, tam: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          if (nueva != null)
            TextButton.icon(
              onPressed: ocupado ? null : onActualizar,
              icon: const Icon(Symbols.update, size: 18),
              label: const Text('Actualizar'),
            ),
          if (situacion != null)
            Flexible(
              child: Tooltip(
                message: situacion!.explicacion,
                child: TextButton.icon(
                  onPressed: ocupado ? null : onResolver,
                  icon: const Icon(Symbols.layers_clear, size: 18),
                  label: Text(situacion!.accion,
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                ),
              ),
            ),
          if (onBajar != null)
            IconButton(
              icon: const Icon(Symbols.download),
              tooltip: 'Bajar a la computadora',
              onPressed: ocupado ? null : onBajar,
            ),
          if (a.sePuedeQuitar)
            IconButton(
              icon: const Icon(Symbols.delete),
              tooltip: 'Quitar del teléfono',
              hoverColor: c.error.withAlpha(30),
              onPressed: ocupado ? null : onBorrar,
            )
          else
            Tooltip(
              message: a.deFabrica
                  ? 'Protegida: es de fábrica, no se puede quitar'
                  : 'Esta app no se puede quitar desde aquí',
              child: Padding(
                padding: const EdgeInsets.all(Esp.x2),
                child: Icon(Symbols.lock, color: c.textoTenue.withAlpha(140), size: 22),
              ),
            ),
        ],
      ),
    );
  }
}

class _FilaHueso extends StatelessWidget {
  const _FilaHueso();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(Esp.x4),
      decoration: BoxDecoration(
        color: context.col.superficie,
        borderRadius: BorderRadius.circular(Rad.medio),
      ),
      child: const Row(
        children: [
          Hueso(ancho: 40, alto: 40, radio: Rad.medio),
          SizedBox(width: Esp.x4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Hueso(ancho: 160, alto: 14),
                SizedBox(height: Esp.x2),
                Hueso(ancho: 110, alto: 10),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
