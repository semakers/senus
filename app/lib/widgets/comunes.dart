// Piezas visuales compartidas por todas las pantallas: logo, superficies
// elevadas, cabeceras, entrada animada, «pulsable», shimmer de carga, barras
// de uso, etiquetas y estados vacíos. Nada aquí sabe de MTP.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../datos/respaldo_rollback.dart' show EventoRespaldo;
import '../tema/senus_tema.dart';

// ---------------------------------------------------------------- logo

/// El sello de SENUS: un disco ámbar con tres anillos de «actualización»,
/// guiño al botón Walkman de los W580/W600.
class LogoSenus extends StatelessWidget {
  final double tam;
  final bool resplandor;
  const LogoSenus({super.key, this.tam = 40, this.resplandor = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: tam,
      height: tam,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: resplandor ? context.col.resplandor(intensidad: 1.6) : null,
      ),
      child: CustomPaint(painter: _PintorLogo()),
    );
  }
}

class _PintorLogo extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide / 2;
    final centro = size.center(Offset.zero);
    final disco = Rect.fromCircle(center: centro, radius: r);
    canvas.drawCircle(
      centro,
      r,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.45, -0.55),
          radius: 1.1,
          colors: [Color(0xFFFFB25C), Color(0xFFFF7800), Color(0xFFD95500)],
          stops: [0, 0.55, 1],
        ).createShader(disco),
    );
    // Tres anillos que se abren hacia la derecha (la «onda» de actualizar).
    final tinta = Paint()
      ..color = const Color(0xFF1A0E00)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 3; i++) {
      final ri = r * (0.30 + i * 0.19);
      tinta.strokeWidth = r * 0.085;
      canvas.drawArc(
        Rect.fromCircle(center: centro, radius: ri),
        -math.pi / 3.2,
        math.pi / 1.6,
        false,
        tinta,
      );
    }
    canvas.drawCircle(centro, r * 0.12, Paint()..color = const Color(0xFF1A0E00));
    // Brillo de plástico arriba a la izquierda.
    canvas.drawArc(
      Rect.fromCircle(center: centro, radius: r * 0.82),
      math.pi * 1.08,
      math.pi * 0.36,
      false,
      Paint()
        ..color = Colors.white.withAlpha(90)
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.07
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _PintorLogo old) => false;
}

/// Logo + palabra «SENUS» + subtítulo.
class MarcaSenus extends StatelessWidget {
  final bool compacta;
  const MarcaSenus({super.key, this.compacta = true});

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    if (compacta) {
      return Row(
        children: [
          const LogoSenus(tam: 34),
          const SizedBox(width: Esp.x3),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('SENUS',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.tipo.titleMedium?.copyWith(
                        letterSpacing: 3, fontWeight: FontWeight.w700, height: 1.1)),
                Text('New Update Service',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.tipo.labelSmall
                        ?.copyWith(letterSpacing: 0.4, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const LogoSenus(tam: 88, resplandor: true),
        const SizedBox(height: Esp.x6),
        Text('SENUS',
            style: context.tipo.displayMedium?.copyWith(
                letterSpacing: 12, fontWeight: FontWeight.w300, color: c.texto)),
        const SizedBox(height: Esp.x2),
        Text('SONY ERICSSON NEW UPDATE SERVICE',
            textAlign: TextAlign.center,
            style: context.tipo.labelSmall?.copyWith(letterSpacing: 2.6)),
      ],
    );
  }
}

// ---------------------------------------------------------------- movimiento

/// Escala ligeramente hacia dentro al pulsar: el «clic» táctil de un botón.
class Pulsable extends StatefulWidget {
  final Widget child;
  final bool activo;
  final double escala;
  const Pulsable({super.key, required this.child, this.activo = true, this.escala = 0.97});

  @override
  State<Pulsable> createState() => _PulsableState();
}

class _PulsableState extends State<Pulsable> {
  bool _abajo = false;

  void _pon(bool v) {
    if (!widget.activo || _abajo == v) return;
    setState(() => _abajo = v);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _pon(true),
      onPointerUp: (_) => _pon(false),
      onPointerCancel: (_) => _pon(false),
      child: AnimatedScale(
        scale: _abajo ? widget.escala : 1,
        duration: Mov.rapido,
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// Entrada corta de fundido + deslizamiento. `retraso` escalona listas.
class EntradaSuave extends StatefulWidget {
  final Widget child;
  final Duration retraso;
  final double desplazamiento;
  const EntradaSuave({
    super.key,
    required this.child,
    this.retraso = Duration.zero,
    this.desplazamiento = 12,
  });

  @override
  State<EntradaSuave> createState() => _EntradaSuaveState();
}

class _EntradaSuaveState extends State<EntradaSuave> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(vsync: this, duration: Mov.normal);
  late final Animation<double> _t = CurvedAnimation(parent: _a, curve: Mov.curva);

  @override
  void initState() {
    super.initState();
    if (widget.retraso == Duration.zero) {
      _a.forward();
    } else {
      Future<void>.delayed(widget.retraso, () {
        if (mounted) _a.forward();
      });
    }
  }

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _t,
      builder: (_, hijo) => Opacity(
        opacity: _t.value,
        child: Transform.translate(
          offset: Offset(0, (1 - _t.value) * widget.desplazamiento),
          child: hijo,
        ),
      ),
      child: widget.child,
    );
  }
}

/// Retraso escalonado para el elemento `i` de una lista (tope a los 8).
Duration escalon(int i) => Duration(milliseconds: 40 * math.min(i, 8));

// ---------------------------------------------------------------- shimmer

/// Barrido de luz sobre los bloques de carga.
class Brillo extends StatefulWidget {
  final Widget child;
  const Brillo({super.key, required this.child});

  @override
  State<Brillo> createState() => _BrilloState();
}

class _BrilloState extends State<Brillo> with SingleTickerProviderStateMixin {
  late final AnimationController _a =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1300))..repeat();

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    final base = c.superficieElevada;
    final luz = Color.lerp(base, c.texto, 0.08)!;
    return AnimatedBuilder(
      animation: _a,
      builder: (_, hijo) => ShaderMask(
        blendMode: BlendMode.srcATop,
        shaderCallback: (r) {
          final x = -1.5 + _a.value * 3;
          return LinearGradient(
            begin: Alignment(x - 1, -0.3),
            end: Alignment(x + 1, 0.3),
            colors: [base, luz, base],
            stops: const [0.35, 0.5, 0.65],
          ).createShader(r);
        },
        child: hijo,
      ),
      child: widget.child,
    );
  }
}

/// Un bloque gris redondeado para esqueletos de carga.
class Hueso extends StatelessWidget {
  final double? ancho;
  final double alto;
  final double radio;
  const Hueso({super.key, this.ancho, this.alto = 12, this.radio = Rad.chico});

  @override
  Widget build(BuildContext context) => Container(
        width: ancho,
        height: alto,
        decoration: BoxDecoration(
          color: context.col.superficieElevada,
          borderRadius: BorderRadius.circular(radio),
        ),
      );
}

// ---------------------------------------------------------------- superficies

/// Superficie elevada: sombra suave en vez de borde plano. Con `onTap`,
/// se ilumina al pasar el ratón y se hunde al pulsar.
class Superficie extends StatefulWidget {
  final Widget child;
  final EdgeInsetsGeometry relleno;
  final VoidCallback? onTap;
  final double radio;
  final bool resaltada;
  final Color? color;
  const Superficie({
    super.key,
    required this.child,
    this.relleno = const EdgeInsets.all(Esp.x6),
    this.onTap,
    this.radio = Rad.grande,
    this.resaltada = false,
    this.color,
  });

  @override
  State<Superficie> createState() => _SuperficieState();
}

class _SuperficieState extends State<Superficie> {
  bool _encima = false;

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    final interactiva = widget.onTap != null;
    final encendida = widget.resaltada || (interactiva && _encima);
    final caja = AnimatedContainer(
      duration: Mov.normal,
      curve: Mov.curva,
      decoration: BoxDecoration(
        color: widget.color ?? c.superficie,
        borderRadius: BorderRadius.circular(widget.radio),
        border: Border.all(
          color: encendida ? c.acento.withAlpha(110) : c.borde.withAlpha(140),
          width: 1,
        ),
        boxShadow: [
          ...c.sombraSuave(nivel: encendida ? 1.5 : 1),
          if (encendida) ...c.resplandor(intensidad: 0.5),
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(widget.radio),
          onTap: widget.onTap,
          onHover: interactiva ? (v) => setState(() => _encima = v) : null,
          hoverColor: Colors.transparent,
          splashColor: c.acento.withAlpha(30),
          highlightColor: Colors.transparent,
          child: Padding(padding: widget.relleno, child: widget.child),
        ),
      ),
    );
    if (!interactiva) return caja;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Pulsable(escala: 0.985, child: caja),
    );
  }
}

/// Un cuadrado redondeado con un icono, en el tono del acento apagado.
class TejaIcono extends StatelessWidget {
  final IconData icono;
  final double tam;
  final Color? color;
  final Color? fondo;
  const TejaIcono(this.icono, {super.key, this.tam = 44, this.color, this.fondo});

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    return Container(
      width: tam,
      height: tam,
      decoration: BoxDecoration(
        color: fondo ?? c.acentoApagado,
        borderRadius: BorderRadius.circular(tam * 0.28),
      ),
      child: Icon(icono, size: tam * 0.52, color: color ?? c.acento, fill: 1, weight: 500),
    );
  }
}

/// Cabecera de cada pantalla: título grande, subtítulo en mono (ruta o dato)
/// y acciones a la derecha.
class CabeceraPantalla extends StatelessWidget {
  final String titulo;
  final String? subtitulo;
  final List<Widget> acciones;
  const CabeceraPantalla({
    super.key,
    required this.titulo,
    this.subtitulo,
    this.acciones = const [],
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Esp.x8, Esp.x8, Esp.x8, Esp.x6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(titulo, style: context.tipo.headlineMedium),
                if (subtitulo != null) ...[
                  const SizedBox(height: Esp.x1),
                  Text(subtitulo!,
                      style: estiloDatos(context, tam: 12),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
              ],
            ),
          ),
          for (final a in acciones) ...[const SizedBox(width: Esp.x3), a],
        ],
      ),
    );
  }
}

/// Barra de uso redondeada. Cambia a «aviso» por encima del 85 %.
class BarraUso extends StatelessWidget {
  final double fraccion;
  final double alto;
  const BarraUso({super.key, required this.fraccion, this.alto = 8});

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    final f = fraccion.clamp(0.0, 1.0);
    final color = f > 0.85 ? c.aviso : c.acento;
    return Container(
      height: alto,
      decoration: BoxDecoration(
        color: c.superficieElevada,
        borderRadius: BorderRadius.circular(alto),
      ),
      alignment: Alignment.centerLeft,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: f),
        duration: Mov.lento,
        curve: Mov.curva,
        builder: (_, v, __) => FractionallySizedBox(
          widthFactor: v,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(alto),
              gradient: LinearGradient(colors: [Color.lerp(color, Colors.white, 0.18)!, color]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Etiqueta pequeña tipo píldora.
class Etiqueta extends StatelessWidget {
  final String texto;
  final IconData? icono;
  final Color? color;
  final bool mono;
  const Etiqueta(this.texto, {super.key, this.icono, this.color, this.mono = false});

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    final col = color ?? c.textoTenue;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Esp.x2 + 2, vertical: 3),
      decoration: BoxDecoration(
        color: col.withAlpha(28),
        borderRadius: BorderRadius.circular(100),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icono != null) ...[
            Icon(icono, size: 13, color: col, fill: 1),
            const SizedBox(width: Esp.x1),
          ],
          // Flexible: en una fila estrecha se corta, no se desborda.
          Flexible(
            child: Text(
              texto,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: mono
                  ? estiloDatos(context, tam: 11.5, color: col, peso: FontWeight.w500)
                  : context.tipo.labelMedium?.copyWith(color: col, height: 1.2),
            ),
          ),
        ],
      ),
    );
  }
}

/// Franja de error con icono, para errores de carga.
class AvisoError extends StatelessWidget {
  final String texto;
  const AvisoError(this.texto, {super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    return EntradaSuave(
      child: Container(
        padding: const EdgeInsets.all(Esp.x4),
        decoration: BoxDecoration(
          color: c.error.withAlpha(26),
          borderRadius: BorderRadius.circular(Rad.medio),
          border: Border.all(color: c.error.withAlpha(70)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Symbols.error, color: c.error, size: 20, fill: 1),
            const SizedBox(width: Esp.x3),
            Expanded(
              child: SelectableText(texto,
                  style: context.tipo.bodyMedium?.copyWith(color: c.texto)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Franja de aviso: algo que hay que saber y que no es un error.
class FranjaAviso extends StatelessWidget {
  final String texto;
  final Widget? accion;

  /// El tono: por omisión el de aviso; el acento para lo que solo informa.
  final Color? color;
  const FranjaAviso(this.texto, {super.key, this.accion, this.color});

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    final tono = color ?? c.aviso;
    return EntradaSuave(
      child: Container(
        padding: const EdgeInsets.all(Esp.x4),
        decoration: BoxDecoration(
          color: tono.withAlpha(26),
          borderRadius: BorderRadius.circular(Rad.medio),
          border: Border.all(color: tono.withAlpha(70)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Symbols.info, color: tono, size: 20, fill: 1),
            const SizedBox(width: Esp.x3),
            Expanded(
              child: SelectableText(texto,
                  style: context.tipo.bodyMedium?.copyWith(color: c.texto)),
            ),
            if (accion != null) ...[const SizedBox(width: Esp.x3), accion!],
          ],
        ),
      ),
    );
  }
}

/// Estado vacío centrado: icono grande, título, explicación.
class EstadoVacio extends StatelessWidget {
  final IconData icono;
  final String titulo;
  final String? texto;
  const EstadoVacio({super.key, required this.icono, required this.titulo, this.texto});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: EntradaSuave(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TejaIcono(icono, tam: 72),
              const SizedBox(height: Esp.x6),
              Text(titulo, style: context.tipo.titleLarge, textAlign: TextAlign.center),
              if (texto != null) ...[
                const SizedBox(height: Esp.x2),
                Text(texto!, style: context.tipo.bodySmall, textAlign: TextAlign.center),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Mensaje flotante con icono de estado.
void avisar(BuildContext context, String texto, {bool bien = true}) {
  final c = context.col;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Row(
        children: [
          Icon(bien ? Symbols.check_circle : Symbols.error,
              color: bien ? c.exito : c.error, fill: 1, size: 20),
          const SizedBox(width: Esp.x3),
          Expanded(child: Text(texto)),
        ],
      ),
    ));
}

/// Diálogo de un paso manual (reconectar el teléfono, abrir «executer»…).
/// Devuelve true si el usuario pulsa Continuar y false si cancela o cierra.
Future<bool> dialogoPausaManual(
    BuildContext context, String titulo, String detalle) async {
  final c = context.col;
  final r = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      icon: Icon(Symbols.pause_circle, color: c.aviso),
      iconColor: c.aviso,
      title: Text(titulo),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 420),
        child: SingleChildScrollView(child: SelectableText(detalle)),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar')),
        FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Symbols.play_arrow, size: 18),
            label: const Text('Continuar')),
      ],
    ),
  );
  return r ?? false;
}

/// Atiende la pausa que emitió un ejecutor: enseña el diálogo y COMPLETA el
/// `Completer` del evento. Pase lo que pase lo completa (con false si algo
/// falla): un `Completer` sin completar deja colgado al ejecutor para siempre.
Future<bool> resolverPausa(BuildContext context, EventoRespaldo ev) async {
  final espera = ev.pausa;
  if (espera == null) return false;
  var seguir = false;
  try {
    seguir = await dialogoPausaManual(
        context, ev.pausaTitulo ?? 'Paso manual', ev.pausaDetalle ?? '');
  } finally {
    if (!espera.isCompleted) espera.complete(seguir);
  }
  return seguir;
}

/// Tamaño legible en MiB.
String enMiB(int bytes, {int decimales = 1}) =>
    '${(bytes / (1024 * 1024)).toStringAsFixed(decimales)} MiB';
