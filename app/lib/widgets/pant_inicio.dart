// V2 — Inicio del teléfono. Tarjeta protagonista con modelo y versión de
// senew, uso de Memoria y Tarjeta, y accesos a Catálogo, Apps y Respaldo.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../datos/telefono.dart';
import '../tema/senus_tema.dart';
import 'comunes.dart';

class PantInicio extends StatelessWidget {
  final Telefono telefono;
  final VoidCallback? onApps;
  final VoidCallback? onRespaldo;
  final VoidCallback? onCatalogo;
  final VoidCallback? onVersion;
  const PantInicio({
    super.key,
    required this.telefono,
    this.onApps,
    this.onRespaldo,
    this.onCatalogo,
    this.onVersion,
  });

  @override
  Widget build(BuildContext context) {
    final mem = telefono.memoria;
    final tar = telefono.tarjeta;
    return LayoutBuilder(builder: (context, lim) {
      final ancho = lim.maxWidth > 760;
      final almacenes = [
        _FichaAlmacen(
          icono: Symbols.memory,
          titulo: 'Memoria',
          almacen: mem,
          leyendo: mem == null,
          vacio: 'leyendo…',
        ),
        _FichaAlmacen(
          icono: Symbols.sd_card,
          titulo: 'Tarjeta / NAND',
          almacen: tar,
          leyendo: false,
          vacio: 'No hay tarjeta en este teléfono',
        ),
      ];
      final accesos = [
        _Acceso(
          icono: Symbols.storefront,
          titulo: 'Catálogo',
          texto: 'Apps .sen listas para instalar',
          onTap: onCatalogo,
        ),
        _Acceso(
          icono: Symbols.apps,
          titulo: 'Apps',
          texto: 'Todo lo que hay en el teléfono',
          onTap: onApps,
        ),
        _Acceso(
          icono: Symbols.settings_backup_restore,
          titulo: 'Respaldo',
          texto: 'Copia y restaura tus archivos',
          onTap: onRespaldo,
        ),
      ];
      return ListView(
        padding: const EdgeInsets.fromLTRB(Esp.x8, Esp.x8, Esp.x8, Esp.x8),
        children: [
          EntradaSuave(child: _Protagonista(telefono: telefono)),
          if (!telefono.canalGestion) ...[
            const SizedBox(height: Esp.x4),
            FranjaAviso(
              'Este senew no tiene canal de gestión: desde SENUS no se ven sus '
              'ajustes ni las apps de fábrica. Actualízalo.',
              accion: onVersion == null
                  ? null
                  : TextButton(
                      onPressed: onVersion, child: const Text('Ver versión')),
            ),
          ],
          const SizedBox(height: Esp.x6),
          Padding(
            padding: const EdgeInsets.only(left: Esp.x1, bottom: Esp.x3),
            child: Text('ALMACENAMIENTO', style: context.tipo.labelSmall),
          ),
          _filaOColumna(ancho, [
            for (var i = 0; i < almacenes.length; i++)
              EntradaSuave(retraso: escalon(i + 1), child: almacenes[i]),
          ]),
          const SizedBox(height: Esp.x6),
          Padding(
            padding: const EdgeInsets.only(left: Esp.x1, bottom: Esp.x3),
            child: Text('ACCIONES', style: context.tipo.labelSmall),
          ),
          _filaOColumna(ancho, [
            for (var i = 0; i < accesos.length; i++)
              EntradaSuave(retraso: escalon(i + 3), child: accesos[i]),
          ]),
        ],
      );
    });
  }

  Widget _filaOColumna(bool fila, List<Widget> hijos) {
    if (!fila) {
      return Column(children: [
        for (var i = 0; i < hijos.length; i++) ...[
          if (i > 0) const SizedBox(height: Esp.x4),
          hijos[i],
        ],
      ]);
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < hijos.length; i++) ...[
            if (i > 0) const SizedBox(width: Esp.x4),
            Expanded(child: hijos[i]),
          ],
        ],
      ),
    );
  }
}

class _Protagonista extends StatelessWidget {
  final Telefono telefono;
  const _Protagonista({required this.telefono});

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    final modelo = telefono.modelo == Modelo.desconocido
        ? 'Modelo desconocido'
        : '${telefono.modelo.name.toUpperCase()}i';
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Rad.enorme),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(c.superficie, c.acento, 0.10)!,
            c.superficie,
          ],
        ),
        border: Border.all(color: c.acento.withAlpha(60)),
        boxShadow: [...c.sombraSuave(nivel: 1.4), ...c.resplandor(intensidad: 0.4)],
      ),
      padding: const EdgeInsets.all(Esp.x8),
      child: Row(
        children: [
          const _SiluetaTelefono(alto: 168),
          const SizedBox(width: Esp.x8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Etiqueta('Conectado por USB', icono: Symbols.check_circle, color: c.exito),
                const SizedBox(height: Esp.x3),
                Text(telefono.nombreAmigo,
                    style: context.tipo.headlineLarge,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: Esp.x1),
                Text('$modelo  ·  ${telefono.soc}',
                    style: context.tipo.titleMedium?.copyWith(
                        color: c.textoTenue, fontWeight: FontWeight.w500)),
                const SizedBox(height: Esp.x6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text('senew',
                        style: context.tipo.titleMedium?.copyWith(color: c.textoTenue)),
                    const SizedBox(width: Esp.x2),
                    Text(telefono.gestion?.version ?? telefono.versionSenew,
                        style: estiloDatos(context,
                            tam: 28, color: c.acento, peso: FontWeight.w500)),
                  ],
                ),
                if (telefono.serie.isNotEmpty) ...[
                  const SizedBox(height: Esp.x3),
                  SelectableText('S/N  ${telefono.serie}', style: estiloDatos(context, tam: 11)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FichaAlmacen extends StatelessWidget {
  final IconData icono;
  final String titulo;
  final Almacen? almacen;
  final bool leyendo;
  final String vacio;
  const _FichaAlmacen({
    required this.icono,
    required this.titulo,
    required this.almacen,
    required this.leyendo,
    required this.vacio,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    final a = almacen;
    Widget cuerpo;
    if (a == null && leyendo) {
      cuerpo = const Brillo(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Hueso(ancho: 90, alto: 26),
            SizedBox(height: Esp.x4),
            Hueso(alto: 8),
            SizedBox(height: Esp.x3),
            Hueso(ancho: 160, alto: 10),
          ],
        ),
      );
    } else if (a == null) {
      cuerpo = Text(vacio, style: context.tipo.bodyMedium?.copyWith(color: c.textoTenue));
    } else {
      final usados = a.bytesTotales - a.bytesLibres;
      final f = a.bytesTotales == 0 ? 0.0 : usados / a.bytesTotales;
      cuerpo = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text('${(f * 100).round()}',
                  style: context.tipo.displaySmall?.copyWith(fontWeight: FontWeight.w300)),
              Text(' % usado', style: context.tipo.bodySmall),
              const Spacer(),
              if (a.soloLectura)
                Etiqueta('solo lectura', icono: Symbols.lock, color: c.aviso),
            ],
          ),
          const SizedBox(height: Esp.x3),
          BarraUso(fraccion: f),
          const SizedBox(height: Esp.x3),
          Text('${enMiB(a.bytesLibres)} libres de ${enMiB(a.bytesTotales)}',
              style: estiloDatos(context, tam: 12)),
        ],
      );
    }
    return Superficie(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icono, size: 20, color: c.acento),
              const SizedBox(width: Esp.x2),
              Text(titulo, style: context.tipo.titleMedium),
            ],
          ),
          const SizedBox(height: Esp.x4),
          cuerpo,
        ],
      ),
    );
  }
}

class _Acceso extends StatelessWidget {
  final IconData icono;
  final String titulo;
  final String texto;
  final VoidCallback? onTap;
  const _Acceso({required this.icono, required this.titulo, required this.texto, this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    return Superficie(
      onTap: onTap,
      relleno: const EdgeInsets.all(Esp.x4),
      child: Row(
        children: [
          TejaIcono(icono, tam: 40),
          const SizedBox(width: Esp.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(titulo, style: context.tipo.titleMedium),
                Text(texto,
                    style: context.tipo.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          Icon(Symbols.chevron_right, color: c.textoTenue, size: 20),
        ],
      ),
    );
  }
}

/// Un W580 dibujado: cuerpo grafito, pantalla con el menú encendido, aro de
/// navegación y las luces laterales naranjas.
class _SiluetaTelefono extends StatelessWidget {
  final double alto;
  const _SiluetaTelefono({required this.alto});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: alto * 0.46,
      height: alto,
      child: CustomPaint(painter: _PintorSilueta(acento: context.col.acento)),
    );
  }
}

class _PintorSilueta extends CustomPainter {
  final Color acento;
  _PintorSilueta({required this.acento});

  @override
  void paint(Canvas canvas, Size s) {
    final w = s.width, h = s.height;
    final cuerpo = RRect.fromRectAndRadius(Offset.zero & s, Radius.circular(w * 0.2));
    // Sombra.
    canvas.drawRRect(
      cuerpo.shift(const Offset(0, 6)),
      Paint()
        ..color = Colors.black.withAlpha(90)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );
    // Luces laterales.
    final luz = Paint()
      ..color = acento
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    for (final x in [-1.0, w - 2.0]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x, h * 0.18, 3, h * 0.5), const Radius.circular(2)),
        luz,
      );
    }
    canvas.drawRRect(
      cuerpo,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF3C3F45), Color(0xFF1B1C20)],
        ).createShader(Offset.zero & s),
    );
    // Altavoz.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(w / 2, h * 0.055), width: w * 0.3, height: 3),
          const Radius.circular(2)),
      Paint()..color = const Color(0xFF0E0F11),
    );
    // Pantalla.
    final pant = Rect.fromLTWH(w * 0.1, h * 0.1, w * 0.8, h * 0.44);
    canvas.drawRRect(RRect.fromRectAndRadius(pant, const Radius.circular(4)),
        Paint()..color = const Color(0xFF0A0A0B));
    canvas.drawRRect(
      RRect.fromRectAndRadius(pant.deflate(2), const Radius.circular(3)),
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0, -0.2),
          radius: 0.9,
          colors: [acento.withAlpha(110), const Color(0xFF16100A)],
        ).createShader(pant),
    );
    // Rejilla de iconos del menú.
    final ic = Paint()..color = Colors.white.withAlpha(110);
    final lado = pant.width * 0.17;
    for (var f = 0; f < 3; f++) {
      for (var col = 0; col < 3; col++) {
        final cx = pant.left + pant.width * (0.22 + col * 0.28);
        final cy = pant.top + pant.height * (0.24 + f * 0.26);
        final sel = f == 1 && col == 1;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromCenter(center: Offset(cx, cy), width: lado, height: lado),
              const Radius.circular(2)),
          sel ? (Paint()..color = acento) : ic,
        );
      }
    }
    // Aro de navegación.
    final centroAro = Offset(w / 2, h * 0.68);
    canvas.drawCircle(centroAro, w * 0.17, Paint()..color = const Color(0xFF101114));
    canvas.drawCircle(
      centroAro,
      w * 0.17,
      Paint()
        ..color = acento.withAlpha(160)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    canvas.drawCircle(centroAro, w * 0.07, Paint()..color = const Color(0xFF2A2C31));
    // Teclas.
    final tecla = Paint()..color = const Color(0xFF2A2C31);
    for (var f = 0; f < 2; f++) {
      for (var col = 0; col < 3; col++) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(w * (0.14 + col * 0.26), h * (0.82 + f * 0.07), w * 0.2, h * 0.045),
              const Radius.circular(2)),
          tecla,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PintorSilueta old) => old.acento != acento;
}
