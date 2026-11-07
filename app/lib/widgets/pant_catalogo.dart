// V — Catálogo: la tienda, contra el backend. Enseña lo que dice el índice
// firmado; la verificación está toda en `backend_semakers.dart`. Sin red, lo
// último verificado. Instalar y actualizar suben por MTP y relee del teléfono
// comparando sha256 (`ServicioApps.instalar`). Un juego con datos va a la
// tarjeta, con su barra de progreso, y desde aquí también se quita.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../datos/app_sen.dart';
import '../datos/apps_telefono.dart';
import '../datos/backend_semakers.dart';
import '../datos/indice_semakers.dart';
import '../datos/servicios_senus.dart';
import '../datos/telefono.dart';
import '../mtp/sesion_mtp.dart';
import '../mtp/transporte.dart' show TransporteError;
import '../tema/senus_tema.dart';
import 'comunes.dart';
import 'icono_sen.dart';

class PantCatalogo extends StatefulWidget {
  final Telefono telefono;
  final SesionMtp? sesion;

  /// Para las pruebas. Sin él, el de esta compilación.
  final ClienteBackend? backend;
  const PantCatalogo(
      {super.key, required this.telefono, required this.sesion, this.backend});

  @override
  State<PantCatalogo> createState() => _PantCatalogoState();
}

class _PantCatalogoState extends State<PantCatalogo> {
  List<AppIndice> _items = const [];
  List<AppSen> _instaladas = const [];
  bool _cargando = true;
  String? _error;
  String? _avisoRed;
  int? _secuencia;
  ClienteBackend? _backend;
  final Set<String> _instalando = <String>{};
  final Set<String> _recien = <String>{};

  // Los juegos: sus datos según el manifiesto, lo que hay en su carpeta de la
  // tarjeta, si hay tarjeta, y el avance de lo que se está instalando.
  final Map<String, DatosJuego?> _datos = {};
  final Map<String, Map<String, int>?> _enTarjeta = {};
  bool _hayTarjeta = true;
  final Map<String, ProgresoInstalacion> _progreso = {};

  @override
  void initState() {
    super.initState();
    _cargarCatalogo();
  }

  Future<void> _cargarCatalogo() async {
    setState(() {
      _cargando = true;
      _error = null;
      _avisoRed = null;
    });
    try {
      final b = _backend ??= widget.backend ?? await backendPredeterminado();
      final r = await b.indice();
      await _leerInstaladas(r.indice.apps);
      if (!mounted) return;
      setState(() {
        _items = r.indice.apps;
        _secuencia = r.indice.secuencia;
        _avisoRed = r.rechazo != null
            ? 'El servidor dio algo que no pasa la verificación y no se aceptó: '
                '${r.rechazo}\nSe enseña lo último verificado.'
            : (r.sinRed
                ? 'Sin conexión con el servidor: esto es lo último verificado.'
                : null);
      });
    } on SinRed catch (e) {
      _falla('No se pudo hablar con el servidor y no hay nada guardado.\n$e');
    } on ErrorVerificacion catch (e) {
      _falla('El catálogo no se puede usar: $e');
    } catch (e) {
      _falla('Error leyendo el catálogo: $e');
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  void _falla(String m) {
    if (!mounted) return;
    setState(() {
      _items = const [];
      _error = m;
    });
  }

  Future<void> _leerInstaladas([List<AppIndice>? items]) async {
    final s = widget.sesion;
    if (s == null) return;
    final serv = ServicioApps(s, widget.telefono);
    try {
      _instaladas = await serv.listar();
    } on TransporteError {
      _instaladas = const [];
      return;
    }
    final juegos = (items ?? _items).where((a) => a.esJuego).toList();
    if (juegos.isEmpty) return;
    try {
      _hayTarjeta = await serv.tarjetaActual() != null;
    } on TransporteError {
      return;
    }
    for (final j in juegos) {
      // Sin su manifiesto no se sabe qué datos lleva: se mira solo el .sen.
      DatosJuego? d;
      try {
        d = await _backend?.datosDe(j);
      } on SinRed {
        d = null;
      } on ErrorVerificacion {
        d = null;
      }
      _datos[j.id] = d;
      try {
        _enTarjeta[j.id] =
            d == null || !_hayTarjeta ? null : await serv.datosEnTarjeta(d);
      } on ErrorInstalarApp {
        _enTarjeta[j.id] = null;
      } on TransporteError {
        _enTarjeta[j.id] = null;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CabeceraPantalla(
          titulo: 'Catálogo',
          subtitulo: _secuencia == null
              ? 'Tienda de Semakers'
              : 'Tienda de Semakers  ·  índice firmado n.º $_secuencia',
          acciones: [
            if (!_cargando)
              Etiqueta('${_items.length} apps', mono: true, color: context.col.acento),
            IconButton(
              onPressed: _cargando ? null : _cargarCatalogo,
              icon: const Icon(Symbols.refresh),
              tooltip: 'Recargar',
            ),
          ],
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(Esp.x8, 0, Esp.x8, Esp.x4),
            child: AvisoError(_error!),
          ),
        if (_avisoRed != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(Esp.x8, 0, Esp.x8, Esp.x4),
            child: FranjaAviso(_avisoRed!),
          ),
        Expanded(child: _rejilla()),
      ],
    );
  }

  static const _rejillaDelegado = SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: 240,
    mainAxisExtent: 324, // cabe la explicación de una app tapada
    crossAxisSpacing: Esp.x4,
    mainAxisSpacing: Esp.x4,
  );
  static const _rellenoRejilla = EdgeInsets.fromLTRB(Esp.x8, Esp.x2, Esp.x8, Esp.x8);

  Widget _rejilla() {
    if (_cargando) {
      return Brillo(
        child: GridView.builder(
          padding: _rellenoRejilla,
          gridDelegate: _rejillaDelegado,
          itemCount: 8,
          itemBuilder: (_, __) => const _TarjetaHueso(),
        ),
      );
    }
    if (_items.isEmpty) {
      return const EstadoVacio(
        icono: Symbols.storefront,
        titulo: 'No hay apps en el catálogo',
        texto: 'Cuando el índice firmado traiga apps, salen aquí.',
      );
    }
    return GridView.builder(
      padding: _rellenoRejilla,
      gridDelegate: _rejillaDelegado,
      itemCount: _items.length,
      itemBuilder: (c, i) {
        final a = _items[i];
        final st = situacionCatalogo(a, _instaladas,
            datos: _datos[a.id],
            enTarjeta: _enTarjeta[a.id],
            hayTarjeta: _hayTarjeta);
        return EntradaSuave(
          retraso: escalon(i),
          child: _Tarjeta(
            item: a,
            situacion: st,
            instalando: _instalando.contains(a.id),
            progreso: _progreso[a.id],
            destello: _recien.contains(a.id),
            onInstalar: () => st.estado == EstadoCatalogo.tapada
                ? _resolver(a, st)
                : _instalar(a),
            onQuitar: a.esJuego && st.hayAlgoQueQuitar ? () => _quitar(a) : null,
          ),
        );
      },
    );
  }

  Future<void> _instalar(AppIndice a) async {
    final s = widget.sesion;
    final b = _backend;
    if (s == null || b == null) {
      _snack('No hay sesión MTP activa.', bien: false);
      return;
    }
    setState(() => _instalando.add(a.id));
    try {
      await ServicioApps(s, widget.telefono).instalar(b, a,
          alProgreso: (p) {
        if (mounted) setState(() => _progreso[a.id] = p);
      });
      await _leerInstaladas();
      if (!mounted) return;
      setState(() => _recien.add(a.id));
      _snack(a.esJuego
          ? 'Instalado y comprobado en la tarjeta: ${a.nombre}'
          : 'Instalada y comprobada: ${a.nombre}');
    } on ErrorVerificacion catch (e) {
      _snack('No se instaló nada: $e', bien: false);
    } on SinRed catch (e) {
      _snack('No se instaló nada: $e', bien: false);
    } on ErrorInstalarApp catch (e) {
      // Lo que quedó a medias se ve como «Incompleto».
      if (a.esJuego) await _leerInstaladas();
      _snack(e.motivo, bien: false);
    } on TransporteError catch (e) {
      _snack(
          a.esJuego
              ? 'Se perdió la conexión: ${e.motivo}. El juego no queda en '
                  '«Juegos»; al volver a conectar, «Reinstalar» lo termina.'
              : 'Se perdió la conexión: ${e.motivo}',
          bien: false);
    } finally {
      if (mounted) {
        setState(() {
          _instalando.remove(a.id);
          _progreso.remove(a.id);
        });
      }
    }
  }

  /// Quitar un juego de la tarjeta: se pregunta, porque borra sus datos.
  Future<void> _quitar(AppIndice a) async {
    final s = widget.sesion;
    final b = _backend;
    if (s == null || b == null) return;
    final d = _datos[a.id];
    if (!await confirmarQuitarJuego(context, a, d)) return;
    setState(() => _instalando.add(a.id));
    try {
      await ServicioApps(s, widget.telefono).quitarJuego(b, a);
      await _leerInstaladas();
      if (!mounted) return;
      _snack('Quitado de la tarjeta: ${a.nombre}');
    } on ErrorVerificacion catch (e) {
      _snack('No se quitó nada: $e', bien: false);
    } on SinRed catch (e) {
      _snack('No se quitó nada: sin el catálogo no se sabe qué datos lleva. $e',
          bien: false);
    } on ErrorInstalarApp catch (e) {
      await _leerInstaladas();
      _snack(e.motivo, bien: false);
    } on TransporteError catch (e) {
      _snack('Se perdió la conexión: ${e.motivo}', bien: false);
    } finally {
      if (mounted) setState(() => _instalando.remove(a.id));
    }
  }

  /// Una app tapada: se pide confirmación porque quita algo de la tarjeta.
  Future<void> _resolver(AppIndice a, SituacionCatalogo st) async {
    final s = widget.sesion;
    final b = _backend;
    if (s == null || b == null || !st.sePuedeResolver) return;
    if (!await confirmarQuitarTapa(context, a.nombre, st)) return;
    setState(() => _instalando.add(a.id));
    try {
      await ServicioApps(s, widget.telefono).resolverTapada(b, a, st);
      await _leerInstaladas();
      if (!mounted) return;
      setState(() => _recien.add(a.id));
      _snack('Listo: ya manda la copia de la Memoria de ${a.nombre}');
    } on ErrorVerificacion catch (e) {
      _snack('No se tocó nada: $e', bien: false);
    } on SinRed catch (e) {
      _snack('No se tocó nada: $e', bien: false);
    } on ErrorInstalarApp catch (e) {
      await _leerInstaladas();
      _snack(e.motivo, bien: false);
    } on TransporteError catch (e) {
      _snack('Se perdió la conexión: ${e.motivo}', bien: false);
    } finally {
      if (mounted) setState(() => _instalando.remove(a.id));
    }
  }

  void _snack(String texto, {bool bien = true}) {
    if (!mounted) return;
    avisar(context, texto, bien: bien);
  }
}

/// Pregunta antes de quitar un juego de la tarjeta.
Future<bool> confirmarQuitarJuego(
    BuildContext context, AppIndice a, DatosJuego? d) async {
  final c = context.col;
  final datos = d == null
      ? ''
      : ' y la carpeta /juegos/${d.carpeta} con sus ${d.archivos.length} '
          'datos (${textoBytes(d.bytes)})';
  final si = await showDialog<bool>(
    context: context,
    builder: (x) => AlertDialog(
      icon: Icon(Symbols.delete, color: c.acento),
      title: Text('Quitar ${a.nombre}'),
      content: Text('Se borran de la tarjeta ${a.fichero}$datos. Nada más de '
          'la tarjeta se toca. Para volver a tenerlo, se instala otra vez.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(x, false),
            child: const Text('Cancelar')),
        FilledButton(
            onPressed: () => Navigator.pop(x, true),
            child: const Text('Quitar')),
      ],
    ),
  );
  return si ?? false;
}

/// Pregunta antes de quitar lo que tapa a una app. La usan Catálogo y Apps.
Future<bool> confirmarQuitarTapa(
    BuildContext context, String nombre, SituacionCatalogo st) async {
  final c = context.col;
  final si = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      icon: Icon(Symbols.layers, color: c.acento),
      title: Text(st.accion),
      content: Text('${st.explicacion}.\n\nSe quita «${st.rival!.nombre}» de la '
          'tarjeta y queda ${nombre.isEmpty ? 'la app' : '«$nombre»'} en la '
          'Memoria. Lo de la tarjeta no se puede deshacer.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Cancelar')),
        FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Quitar')),
      ],
    ),
  );
  return si ?? false;
}

/// Esqueleto de tarjeta mientras se lee el catálogo.
class _TarjetaHueso extends StatelessWidget {
  const _TarjetaHueso();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(Esp.x4),
      decoration: BoxDecoration(
        color: context.col.superficie,
        borderRadius: BorderRadius.circular(Rad.grande),
      ),
      child: const Column(
        children: [
          SizedBox(height: Esp.x2),
          Hueso(ancho: 88, alto: 88, radio: Rad.grande),
          SizedBox(height: Esp.x4),
          Hueso(ancho: 120, alto: 14),
          SizedBox(height: Esp.x2),
          Hueso(ancho: 80, alto: 10),
          Spacer(),
          Hueso(alto: 40, radio: Rad.medio),
        ],
      ),
    );
  }
}

class _Tarjeta extends StatefulWidget {
  final AppIndice item;
  final SituacionCatalogo situacion;
  final bool instalando;
  final ProgresoInstalacion? progreso;
  final bool destello;
  final VoidCallback onInstalar;
  final VoidCallback? onQuitar;
  const _Tarjeta(
      {required this.item,
      required this.situacion,
      required this.instalando,
      this.progreso,
      required this.destello,
      required this.onInstalar,
      this.onQuitar});

  @override
  State<_Tarjeta> createState() => _TarjetaState();
}

class _TarjetaState extends State<_Tarjeta> with SingleTickerProviderStateMixin {
  // Destello al terminar de instalar: la tarjeta se ilumina y se apaga.
  late final AnimationController _destello =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void didUpdateWidget(covariant _Tarjeta old) {
    super.didUpdateWidget(old);
    if (!old.destello && widget.destello) _destello.forward(from: 0);
  }

  @override
  void dispose() {
    _destello.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final col = context.col;
    final a = widget.item;
    final c = a.cabecera;
    return AnimatedBuilder(
      animation: _destello,
      builder: (_, hijo) {
        final v = math.sin(_destello.value * math.pi);
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Rad.grande),
            boxShadow: [
              BoxShadow(
                color: col.exito.withAlpha((90 * v).round()),
                blurRadius: 28 * v,
                spreadRadius: 2 * v,
              ),
            ],
          ),
          child: hijo,
        );
      },
      child: Superficie(
        relleno: const EdgeInsets.all(Esp.x4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: Esp.x2),
            Center(
              child: Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(Rad.grande + 4),
                  boxShadow: col.resplandor(intensidad: 0.7),
                ),
                // El icono 16x12 del índice, escalado; si la app no trae,
                // el genérico del sistema que pide (icono_gen), como en el menú.
                child: FittedBox(child: IconoSen(cab: c)),
              ),
            ),
            const SizedBox(height: Esp.x4),
            Text(
              a.nombre,
              textAlign: TextAlign.center,
              style: context.tipo.titleMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: Esp.x1),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (c.rotuloPerfil.isNotEmpty) ...[
                  Etiqueta(c.rotuloPerfil,
                      icono: c.perfil == 2 ? Symbols.sports_esports : Symbols.widgets),
                  const SizedBox(width: Esp.x2),
                ],
                // Un juego: el .sen y sus datos, lo que ocupará en la tarjeta.
                Text(
                    a.esJuego
                        ? textoBytes(a.tamTotal)
                        : '${(a.tam / 1024).toStringAsFixed(1)} KiB',
                    style: estiloDatos(context, tam: 11)),
              ],
            ),
            const SizedBox(height: Esp.x1),
            Text('v${a.versionTexto}  ·  ${a.autor}',
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: estiloDatos(context, tam: 11)),
            if (widget.situacion.estado == EstadoCatalogo.tapada ||
                widget.situacion.estado == EstadoCatalogo.incompleto) ...[
              const SizedBox(height: Esp.x1),
              Text(widget.situacion.explicacion,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: context.tipo.bodySmall?.copyWith(color: col.aviso)),
            ],
            const Spacer(),
            Row(
              children: [
                Expanded(
                  child: Tooltip(
                    message: a.descripcion.isEmpty ? a.fichero : a.descripcion,
                    child: _BotonInstalar(
                      instalando: widget.instalando,
                      progreso: widget.progreso,
                      situacion: widget.situacion,
                      onInstalar: widget.onInstalar,
                    ),
                  ),
                ),
                if (widget.onQuitar != null && !widget.instalando) ...[
                  const SizedBox(width: Esp.x1),
                  IconButton(
                    onPressed: widget.onQuitar,
                    icon: Icon(Symbols.delete, color: col.textoTenue, size: 20),
                    tooltip: 'Quitar de la tarjeta',
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Instalar → Instalando… → Instalada ✓, o Actualizar si el catálogo trae una
/// versión más nueva. Lo instalado se puede volver a pulsar para reinstalar.
class _BotonInstalar extends StatelessWidget {
  final bool instalando;
  final ProgresoInstalacion? progreso;
  final SituacionCatalogo situacion;
  final VoidCallback onInstalar;
  const _BotonInstalar(
      {required this.instalando,
      this.progreso,
      required this.situacion,
      required this.onInstalar});

  EstadoCatalogo get estado => situacion.estado;

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    // Nunca un botón que no cambie nada: si no se puede resolver, no hay botón.
    if (estado == EstadoCatalogo.tapada && !situacion.sePuedeResolver) {
      return const SizedBox(height: 40);
    }
    // Sin tarjeta, o a un sitio que no se conoce: lo dice, sin botón.
    if (!instalando &&
        (estado == EstadoCatalogo.sinTarjeta ||
            estado == EstadoCatalogo.noSoportada)) {
      return Container(
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: c.superficieElevada,
          borderRadius: BorderRadius.circular(Rad.medio),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
                estado == EstadoCatalogo.sinTarjeta
                    ? Symbols.sd_card_alert
                    : Symbols.block,
                size: 18,
                color: c.aviso),
            const SizedBox(width: Esp.x2),
            Flexible(
              child: Text(
                  estado == EstadoCatalogo.sinTarjeta
                      ? situacion.explicacion
                      : 'Necesita otra SENUS',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.tipo.labelLarge?.copyWith(color: c.aviso)),
            ),
          ],
        ),
      );
    }
    final String clave;
    final Widget contenido;
    final instalada =
        estado == EstadoCatalogo.alDia || estado == EstadoCatalogo.masNueva;
    final p = progreso;
    if (instalando && p != null && p.total > 0) {
      // Un juego tarda minutos: el paso y cuánto va, por bytes del total.
      clave = 'progreso';
      final f = p.fraccion ?? 0;
      contenido = Stack(
        children: [
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Esp.x2),
              child: Text('${p.paso}  ${(f * 100).floor()} %',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.tipo.labelMedium?.copyWith(color: c.acento)),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Rad.medio),
              child: LinearProgressIndicator(
                  value: f, minHeight: 3, color: c.acento),
            ),
          ),
        ],
      );
    } else if (instalando) {
      clave = 'instalando';
      contenido = Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: c.acento),
          ),
          const SizedBox(width: Esp.x2),
          Text('Instalando…', style: context.tipo.labelLarge?.copyWith(color: c.acento)),
        ],
      );
    } else if (instalada) {
      clave = 'instalada';
      contenido = Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 520),
            curve: Curves.elasticOut,
            builder: (_, v, hijo) => Transform.scale(scale: v, child: hijo),
            child: Icon(Symbols.check_circle, color: c.exito, fill: 1, size: 18),
          ),
          const SizedBox(width: Esp.x2),
          Text(estado == EstadoCatalogo.masNueva ? 'Tienes una más nueva' : 'Instalada',
              style: context.tipo.labelLarge?.copyWith(color: c.exito)),
        ],
      );
    } else {
      final actualizar = estado == EstadoCatalogo.hayActualizacion;
      final tapada = estado == EstadoCatalogo.tapada;
      final incompleto = estado == EstadoCatalogo.incompleto;
      clave = tapada
          ? 'tapada'
          : (incompleto ? 'incompleto' : (actualizar ? 'actualizar' : 'idle'));
      contenido = Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
              tapada
                  ? Symbols.layers_clear
                  : incompleto
                      ? Symbols.build
                      : (actualizar ? Symbols.update : Symbols.download),
              size: 18,
              color: c.sobreAcento,
              weight: 600),
          const SizedBox(width: Esp.x2),
          Flexible(
            child: Text(
                tapada || incompleto
                    ? situacion.accion
                    : (actualizar ? 'Actualizar' : 'Instalar'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.tipo.labelLarge?.copyWith(color: c.sobreAcento)),
          ),
        ],
      );
    }
    final fondo = instalando
        ? c.acentoApagado
        : instalada
            ? c.exito.withAlpha(30)
            : c.acento;
    return Pulsable(
      activo: !instalando,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: instalando ? null : onInstalar,
          borderRadius: BorderRadius.circular(Rad.medio),
          child: AnimatedContainer(
            duration: Mov.normal,
            curve: Mov.curva,
            height: 40,
            decoration: BoxDecoration(
              color: fondo,
              borderRadius: BorderRadius.circular(Rad.medio),
            ),
            child: AnimatedSwitcher(
              duration: Mov.normal,
              transitionBuilder: (h, a) => FadeTransition(
                opacity: a,
                child: ScaleTransition(scale: Tween(begin: 0.85, end: 1.0).animate(a), child: h),
              ),
              child: KeyedSubtree(key: ValueKey(clave), child: contenido),
            ),
          ),
        ),
      ),
    );
  }
}
