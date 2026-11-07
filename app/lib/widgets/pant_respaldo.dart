// V4 — Respaldo. .zip con /ajustes + /mis_archivos del teléfono.
//
// Formato del .zip (docs/respaldo_zip.md en espíritu):
//   manifiesto.json       JSON con modelo, versión, SHA-256 por fichero
//   ajustes/<path>        objetos bajo /ajustes (si existe)
//   mis_archivos/<path>   objetos bajo /mis_archivos (si existe)
//
// Restaurar: valida que el manifiesto encaja con el teléfono conectado
// (modelo + versión), lee cada fichero, calcula SHA-256 y lo compara con
// lo del manifiesto; sube uno a uno al teléfono.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../datos/telefono.dart';
import '../mtp/operaciones.dart';
import '../mtp/sesion_mtp.dart';
import '../tema/senus_tema.dart';
import 'comunes.dart';

class PantRespaldo extends StatefulWidget {
  final Telefono telefono;
  final SesionMtp? sesion;
  const PantRespaldo({super.key, required this.telefono, required this.sesion});

  @override
  State<PantRespaldo> createState() => _PantRespaldoState();
}

class _PantRespaldoState extends State<PantRespaldo> {
  bool _trabajando = false;
  double _progreso = 0;
  String _rotulo = '';

  // Últimas copias hechas desde esta computadora (ruta, fecha, entradas).
  List<_CopiaReciente> _recientes = const [];

  @override
  void initState() {
    super.initState();
    _leerRecientes();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    List<Widget> tarjetas(bool estirar) => [
      _TarjetaAccion(
        estirar: estirar,
        icono: Symbols.backup,
        titulo: 'Hacer copia',
        texto: 'Baja los ajustes y «Mis archivos» de la Memoria del teléfono a un '
            'paquete .zip con la fecha de hoy.',
        boton: 'Hacer copia',
        iconoBoton: Symbols.save,
        principal: true,
        onTap: _trabajando ? null : _respaldar,
      ),
      _TarjetaAccion(
        estirar: estirar,
        icono: Symbols.restore,
        titulo: 'Restaurar',
        texto: 'Lee un paquete .zip de SENUS, verifica el manifiesto con SHA-256 y '
            'escribe su contenido en el teléfono.',
        boton: 'Elegir .zip…',
        iconoBoton: Symbols.folder_open,
        principal: false,
        onTap: _trabajando ? null : _restaurar,
      ),
    ];
    return ListView(
      children: [
        const CabeceraPantalla(
          titulo: 'Respaldo',
          subtitulo: '/ajustes  ·  /mis_archivos  →  .zip',
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Esp.x8, 0, Esp.x8, Esp.x8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LayoutBuilder(builder: (context, lim) {
                if (lim.maxWidth < 640) {
                  final t = tarjetas(false);
                  return Column(children: [
                    EntradaSuave(child: t[0]),
                    const SizedBox(height: Esp.x4),
                    EntradaSuave(retraso: escalon(1), child: t[1]),
                  ]);
                }
                final t = tarjetas(true);
                return IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: EntradaSuave(child: t[0])),
                      const SizedBox(width: Esp.x4),
                      Expanded(child: EntradaSuave(retraso: escalon(1), child: t[1])),
                    ],
                  ),
                );
              }),
              AnimatedSize(
                duration: Mov.normal,
                curve: Mov.curva,
                child: _trabajando
                    ? Padding(
                        padding: const EdgeInsets.only(top: Esp.x6),
                        child: _PanelProgreso(rotulo: _rotulo, progreso: _progreso),
                      )
                    : const SizedBox(width: double.infinity),
              ),
              const SizedBox(height: Esp.x6),
              Padding(
                padding: const EdgeInsets.only(left: Esp.x1, bottom: Esp.x3),
                child: Text('ÚLTIMAS COPIAS EN ESTA COMPUTADORA', style: context.tipo.labelSmall),
              ),
              if (_recientes.isEmpty)
                Superficie(
                  relleno: const EdgeInsets.all(Esp.x6),
                  child: Row(
                    children: [
                      Icon(Symbols.inventory_2, color: c.textoTenue),
                      const SizedBox(width: Esp.x3),
                      Expanded(
                        child: Text('Aún no has hecho ninguna copia desde aquí.',
                            style: context.tipo.bodyMedium?.copyWith(color: c.textoTenue)),
                      ),
                    ],
                  ),
                )
              else
                for (var i = 0; i < _recientes.length; i++) ...[
                  if (i > 0) const SizedBox(height: Esp.x2),
                  EntradaSuave(
                    retraso: escalon(i + 2),
                    child: _FilaCopia(
                      copia: _recientes[i],
                      onRestaurar: _trabajando ? null : () => _restaurarDesde(_recientes[i].ruta),
                    ),
                  ),
                ],
            ],
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------ recientes

  Future<File> _ficheroRecientes() async => File(
      '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}respaldos_recientes.json');

  Future<void> _leerRecientes() async {
    try {
      final f = await _ficheroRecientes();
      if (!await f.exists()) return;
      final lista = (jsonDecode(await f.readAsString()) as List)
          .whereType<Map<String, dynamic>>()
          .map(_CopiaReciente.deJson)
          .toList();
      for (final r in lista) {
        r.existe = await File(r.ruta).exists();
      }
      if (mounted) setState(() => _recientes = lista);
    } catch (_) {}
  }

  Future<void> _anotarReciente(String ruta, int entradas, int bytes) async {
    final nueva = _CopiaReciente(
      ruta: ruta,
      fecha: DateTime.now(),
      modelo: widget.telefono.modelo.name.toUpperCase(),
      entradas: entradas,
      bytes: bytes,
    );
    final lista = [nueva, ..._recientes.where((r) => r.ruta != ruta)].take(6).toList();
    if (mounted) setState(() => _recientes = lista);
    try {
      final f = await _ficheroRecientes();
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode([for (final r in lista) r.aJson()]));
    } catch (_) {}
  }

  void _paso(String texto, double v) {
    if (!mounted) return;
    setState(() {
      _rotulo = texto;
      _progreso = v.clamp(0.0, 1.0);
    });
  }

  // ------------------------------------------------------------ respaldar

  Future<void> _respaldar() async {
    final s = widget.sesion;
    if (s == null) {
      _snack('No hay sesión MTP activa.');
      return;
    }
    final fecha = DateTime.now().toIso8601String().substring(0, 10);
    final modelo = widget.telefono.modelo.name.toUpperCase();
    final destino = await FilePicker.platform.saveFile(
      dialogTitle: 'Guardar copia como…',
      fileName: 'respaldo_${modelo}_$fecha.zip',
    );
    if (destino == null) return;

    setState(() {
      _trabajando = true;
      _progreso = 0;
      _rotulo = 'Preparando…';
    });
    try {
      final archive = Archive();
      final manifiesto = <String, dynamic>{
        'formato_senus': 1,
        'modelo': modelo,
        'nombre_amigo': widget.telefono.nombreAmigo,
        'version_senew': widget.telefono.versionSenew,
        'fecha_utc': DateTime.now().toUtc().toIso8601String(),
        'ficheros': <Map<String, dynamic>>[],
      };
      final ficheros = manifiesto['ficheros'] as List<Map<String, dynamic>>;

      final zonas = <(String, int)>[];
      for (final nombre in ['ajustes', 'mis_archivos']) {
        _paso('Buscando /$nombre…', 0.05);
        final h = await s.handleCarpeta(nombre);
        if (h.bien && h.valor != null) {
          zonas.add((nombre, h.valor!));
        }
      }
      if (zonas.isEmpty) {
        _snack('No encontré ni /ajustes ni /mis_archivos en el teléfono.');
        return;
      }

      // Primera pasada: contar objetos para el progreso.
      final todos = <(String, ObjetoMtp)>[]; // (rutaRelativa, ObjetoMtp)
      for (final (raiz, h) in zonas) {
        await _recorrer(s, raiz, h, todos);
      }
      final total = todos.length;

      // Segunda: bajar y meter en el zip.
      for (var i = 0; i < todos.length; i++) {
        final (ruta, obj) = todos[i];
        _paso('Bajando $ruta…', (i + 1) / (total + 1));
        if (obj.esCarpeta) {
          // Carpeta vacía: añadimos entrada de directorio con un marcador .keep.
          archive.addFile(ArchiveFile('$ruta/.keep', 0, Uint8List(0)));
          ficheros.add({'ruta': '$ruta/.keep', 'bytes': 0, 'sha256': _sha256(Uint8List(0))});
          continue;
        }
        final r = await s.bajarObjeto(obj.handle);
        if (!r.bien) {
          ficheros.add({'ruta': ruta, 'bytes': obj.tamano, 'error': r.mensaje});
          continue;
        }
        final datos = r.valor!;
        archive.addFile(ArchiveFile(ruta, datos.length, datos));
        ficheros.add({
          'ruta': ruta,
          'bytes': datos.length,
          'sha256': _sha256(datos),
        });
      }

      _paso('Escribiendo manifiesto…', (total + 1) / (total + 2));
      final manifBytes =
          utf8.encode(const JsonEncoder.withIndent('  ').convert(manifiesto));
      archive.addFile(ArchiveFile('manifiesto.json', manifBytes.length, manifBytes));

      _paso('Comprimiendo .zip…', 0.98);
      final zipBytes = ZipEncoder().encode(archive);
      if (zipBytes == null) {
        _snack('No se pudo codificar el .zip');
        return;
      }
      await File(destino).writeAsBytes(zipBytes);
      _paso('Hecho', 1);
      await _anotarReciente(destino, ficheros.length, zipBytes.length);
      _snack('Copia guardada: $destino (${ficheros.length} entradas)');
    } catch (e) {
      _snack('Error: $e');
    } finally {
      if (mounted) setState(() => _trabajando = false);
    }
  }

  Future<void> _recorrer(
    SesionMtp s,
    String rutaRel,
    int handle,
    List<(String, ObjetoMtp)> acc,
  ) async {
    final r = await s.listarCarpeta(handle);
    if (!r.bien) return;
    if (r.valor!.isEmpty) {
      // Marcador de carpeta vacía: lo añadiremos como .keep.
      return;
    }
    for (final o in r.valor!) {
      final ruta = '$rutaRel/${o.nombre}';
      acc.add((ruta, o));
      if (o.esCarpeta) {
        await _recorrer(s, ruta, o.handle, acc);
      }
    }
  }

  // ------------------------------------------------------------- restaurar

  Future<void> _restaurar() async {
    final s = widget.sesion;
    if (s == null) {
      _snack('No hay sesión MTP activa.');
      return;
    }
    final res = await FilePicker.platform.pickFiles(
      dialogTitle: 'Elige la copia .zip',
      type: FileType.custom,
      allowedExtensions: const ['zip'],
    );
    if (res == null || res.files.isEmpty) return;
    final path = res.files.single.path;
    if (path == null) return;
    await _restaurarDesde(path);
  }

  Future<void> _restaurarDesde(String path) async {
    final s = widget.sesion;
    if (s == null) {
      _snack('No hay sesión MTP activa.');
      return;
    }
    setState(() {
      _trabajando = true;
      _progreso = 0;
      _rotulo = 'Abriendo zip…';
    });
    try {
      final zipBytes = await File(path).readAsBytes();
      final archive = ZipDecoder().decodeBytes(zipBytes);
      final mf = archive.files.firstWhere(
        (f) => f.name == 'manifiesto.json',
        orElse: () => ArchiveFile('', 0, Uint8List(0)),
      );
      if (mf.name.isEmpty) {
        _snack('El .zip no tiene manifiesto.json — no parece una copia de SENUS.');
        return;
      }
      final man = jsonDecode(utf8.decode(mf.content as List<int>))
          as Map<String, dynamic>;
      final modelo = man['modelo']?.toString() ?? '';
      final actual = widget.telefono.modelo.name.toUpperCase();
      if (modelo.isNotEmpty && modelo != actual) {
        final sigue = await _confirmar(
          '¿Restaurar aún así?',
          'La copia es de un $modelo y el teléfono conectado es un $actual. '
              'Puede fallar o pisar ajustes que no entiende.',
        );
        if (sigue != true) return;
      }
      final esperados = <String, String>{
        for (final e in (man['ficheros'] as List? ?? const []))
          if (e is Map && e['sha256'] is String)
            e['ruta'] as String: e['sha256'] as String,
      };

      // Pre-calcular padres: /ajustes y /mis_archivos.
      int? padreAjustes;
      int? padreMisArchivos;
      final hA = await s.handleCarpeta('ajustes');
      if (hA.bien) padreAjustes = hA.valor;
      final hM = await s.handleCarpeta('mis_archivos');
      if (hM.bien) padreMisArchivos = hM.valor;

      final subidos = <String>[];
      final errores = <String>[];
      final total = archive.files.length;
      for (var i = 0; i < archive.files.length; i++) {
        final f = archive.files[i];
        _paso('Restaurando ${f.name}…', (i + 1) / total);
        if (f.name == 'manifiesto.json') continue;
        if (f.name.endsWith('/.keep') || f.isFile == false) continue;
        if (f.name.endsWith('.keep')) continue;

        final partes = f.name.split('/');
        if (partes.length < 2) continue;
        final raiz = partes.first;
        final nombre = partes.last;
        // SENUS fase 1: sólo soportamos ficheros DIRECTAMENTE en /ajustes
        // o /mis_archivos (no subcarpetas). SendObject* no sabe de rutas.
        if (partes.length > 2) {
          errores.add('${f.name}: subcarpetas aún no soportadas');
          continue;
        }
        int? padre;
        if (raiz == 'ajustes') padre = padreAjustes;
        if (raiz == 'mis_archivos') padre = padreMisArchivos;
        if (padre == null) {
          errores.add('${f.name}: /$raiz no existe en el teléfono');
          continue;
        }
        final datos = Uint8List.fromList(f.content as List<int>);
        final sha = _sha256(datos);
        final esperado = esperados[f.name];
        if (esperado != null && esperado != sha) {
          errores.add('${f.name}: SHA-256 no cuadra con el manifiesto');
          continue;
        }
        final r = await s.enviarObjeto(padre, nombre, datos,
            formato: fmtIndef);
        if (r.bien) {
          subidos.add(f.name);
        } else {
          errores.add('${f.name}: ${r.mensaje}');
        }
      }
      _paso('Hecho', 1);
      _snack('Restaurados ${subidos.length}; errores ${errores.length}');
      if (errores.isNotEmpty && mounted) {
        await showDialog<void>(
          context: context,
          builder: (c) => AlertDialog(
            icon: Icon(Symbols.warning, color: context.col.aviso),
            title: const Text('Avisos de la restauración'),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(child: Text(errores.join('\n'))),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(c),
                  child: const Text('Cerrar')),
            ],
          ),
        );
      }
    } catch (e) {
      _snack('Error: $e');
    } finally {
      if (mounted) setState(() => _trabajando = false);
    }
  }

  Future<bool?> _confirmar(String titulo, String texto) => showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          icon: Icon(Symbols.warning, color: context.col.aviso),
          title: Text(titulo),
          content: Text(texto),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('Cancelar')),
            FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('Seguir')),
          ],
        ),
      );

  String _sha256(Uint8List b) => sha256.convert(b).toString();

  void _snack(String texto) {
    if (!mounted) return;
    final bien = !texto.startsWith('Error') && !texto.startsWith('No ') && !texto.startsWith('El .zip');
    avisar(context, texto, bien: bien);
  }
}

// ------------------------------------------------------------------ piezas

class _CopiaReciente {
  final String ruta;
  final DateTime fecha;
  final String modelo;
  final int entradas;
  final int bytes;
  bool existe = true;

  _CopiaReciente({
    required this.ruta,
    required this.fecha,
    required this.modelo,
    required this.entradas,
    required this.bytes,
  });

  static _CopiaReciente deJson(Map<String, dynamic> j) => _CopiaReciente(
        ruta: j['ruta'] as String,
        fecha: DateTime.tryParse(j['fecha'] as String? ?? '') ?? DateTime(2000),
        modelo: j['modelo'] as String? ?? '',
        entradas: j['entradas'] as int? ?? 0,
        bytes: j['bytes'] as int? ?? 0,
      );

  Map<String, dynamic> aJson() => {
        'ruta': ruta,
        'fecha': fecha.toIso8601String(),
        'modelo': modelo,
        'entradas': entradas,
        'bytes': bytes,
      };
}

class _TarjetaAccion extends StatelessWidget {
  final IconData icono;
  final String titulo;
  final String texto;
  final String boton;
  final IconData iconoBoton;
  final bool principal;
  final VoidCallback? onTap;
  // En fila (alturas iguales) el botón baja al fondo; en columna no hay alto
  // acotado y un Spacer reventaría.
  final bool estirar;
  const _TarjetaAccion({
    this.estirar = false,
    required this.icono,
    required this.titulo,
    required this.texto,
    required this.boton,
    required this.iconoBoton,
    required this.principal,
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
          TejaIcono(
            icono,
            tam: 56,
            color: principal ? c.sobreAcento : c.acento,
            fondo: principal ? c.acento : c.acentoApagado,
          ),
          const SizedBox(height: Esp.x4),
          Text(titulo, style: context.tipo.headlineSmall),
          const SizedBox(height: Esp.x2),
          Text(texto, style: context.tipo.bodyMedium?.copyWith(color: c.textoTenue)),
          const SizedBox(height: Esp.x6),
          if (estirar) const Spacer(),
          principal
              ? FilledButton.icon(
                  onPressed: onTap, icon: Icon(iconoBoton, size: 20), label: Text(boton))
              : OutlinedButton.icon(
                  onPressed: onTap, icon: Icon(iconoBoton, size: 20), label: Text(boton)),
        ],
      ),
    );
  }
}

class _PanelProgreso extends StatelessWidget {
  final String rotulo;
  final double progreso;
  const _PanelProgreso({required this.rotulo, required this.progreso});

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
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2.2, color: c.acento),
              ),
              const SizedBox(width: Esp.x3),
              Expanded(
                child: AnimatedSwitcher(
                  duration: Mov.rapido,
                  child: Text(
                    rotulo,
                    key: ValueKey(rotulo),
                    style: estiloDatos(context, tam: 12.5, color: c.texto),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: Esp.x4),
              Text('${(progreso * 100).round()} %',
                  style: estiloDatos(context, tam: 20, color: c.acento, peso: FontWeight.w500)),
            ],
          ),
          const SizedBox(height: Esp.x4),
          BarraUso(fraccion: progreso, alto: 10),
        ],
      ),
    );
  }
}

class _FilaCopia extends StatelessWidget {
  final _CopiaReciente copia;
  final VoidCallback? onRestaurar;
  const _FilaCopia({required this.copia, required this.onRestaurar});

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    final f = copia.fecha.toLocal().toString().substring(0, 16);
    return Opacity(
      opacity: copia.existe ? 1 : 0.5,
      child: Superficie(
        radio: Rad.medio,
        relleno: const EdgeInsets.fromLTRB(Esp.x4, Esp.x3, Esp.x3, Esp.x3),
        child: Row(
          children: [
            const TejaIcono(Symbols.folder_zip, tam: 40),
            const SizedBox(width: Esp.x4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.basename(copia.ruta),
                      style: context.tipo.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(
                    copia.existe
                        ? '$f  ·  ${copia.modelo}  ·  ${copia.entradas} entradas  ·  ${enMiB(copia.bytes, decimales: 2)}'
                        : '$f  ·  ya no está en ${p.dirname(copia.ruta)}',
                    style: estiloDatos(context, tam: 11.5),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: Esp.x2),
            TextButton.icon(
              onPressed: copia.existe ? onRestaurar : null,
              icon: Icon(Symbols.restore, size: 18, color: copia.existe ? c.acento : null),
              label: const Text('Restaurar'),
            ),
          ],
        ),
      ),
    );
  }
}
