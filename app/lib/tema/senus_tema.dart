// SENUS — sistema de diseño. Tokens de color, tipografía, espaciado, radios y
// sombras, y los dos ThemeData (oscuro por omisión, claro opcional).
//
// La estética hereda la de los W580/W600 originales: naranja ámbar #FF7800
// sobre grafito, como el menú «Walkman» y como senew (dis_material3.c, semilla
// #FF7800, oscuro por defecto).

import 'package:flutter/material.dart';

/// Escala de espaciado: 4, 8, 12, 16, 24, 32, 48.
abstract final class Esp {
  static const double x1 = 4;
  static const double x2 = 8;
  static const double x3 = 12;
  static const double x4 = 16;
  static const double x6 = 24;
  static const double x8 = 32;
  static const double x12 = 48;
}

/// Radios de esquina.
abstract final class Rad {
  static const double chico = 8;
  static const double medio = 12;
  static const double grande = 16;
  static const double enorme = 24;
}

/// Duraciones y curvas de las animaciones.
abstract final class Mov {
  static const rapido = Duration(milliseconds: 140);
  static const normal = Duration(milliseconds: 260);
  static const lento = Duration(milliseconds: 420);
  static const curva = Curves.easeOutCubic;
}

/// Familias tipográficas (assets/fuentes, OFL).
abstract final class Fuente {
  static const texto = 'Inter';
  static const datos = 'JetBrainsMono';
}

/// Los diez tokens de color de SENUS. Viven en el tema como extensión para que
/// cambien (y se interpolen) con el modo claro/oscuro.
@immutable
class SenusColores extends ThemeExtension<SenusColores> {
  final Color fondo;
  final Color superficie;
  final Color superficieElevada;
  final Color acento;
  final Color acentoApagado;
  final Color texto;
  final Color textoTenue;
  final Color error;
  final Color exito;
  final Color aviso;

  /// Derivados: línea fina y color de sombra.
  final Color borde;
  final Color sombra;

  const SenusColores({
    required this.fondo,
    required this.superficie,
    required this.superficieElevada,
    required this.acento,
    required this.acentoApagado,
    required this.texto,
    required this.textoTenue,
    required this.error,
    required this.exito,
    required this.aviso,
    required this.borde,
    required this.sombra,
  });

  static const acentoSE = Color(0xFFFF7800);

  /// Grafito: el cuerpo de un W580 con la luz apagada.
  static const oscuro = SenusColores(
    fondo: Color(0xFF121315),
    superficie: Color(0xFF1B1C1F),
    superficieElevada: Color(0xFF25272B),
    acento: acentoSE,
    acentoApagado: Color(0xFF3A2513),
    texto: Color(0xFFF3F0EB),
    textoTenue: Color(0xFF9C978F),
    error: Color(0xFFFF6B5E),
    exito: Color(0xFF52C98E),
    aviso: Color(0xFFF5B841),
    borde: Color(0xFF2F3135),
    sombra: Color(0xFF000000),
  );

  /// Papel cálido: la caja blanca del teléfono.
  static const claro = SenusColores(
    fondo: Color(0xFFF5F3F0),
    superficie: Color(0xFFFFFFFF),
    superficieElevada: Color(0xFFFFFFFF),
    acento: acentoSE,
    acentoApagado: Color(0xFFFFE8D3),
    texto: Color(0xFF1C1B19),
    textoTenue: Color(0xFF6E6961),
    error: Color(0xFFD23C30),
    exito: Color(0xFF1E9A62),
    aviso: Color(0xFFB57C00),
    borde: Color(0xFFE6E1DA),
    sombra: Color(0xFF5A3A1A),
  );

  /// Texto encima del acento: oscuro, como las etiquetas del menú Walkman.
  Color get sobreAcento => const Color(0xFF1A0E00);

  /// Sombra suave de dos capas para superficies elevadas.
  List<BoxShadow> sombraSuave({double nivel = 1}) => [
        BoxShadow(
          color: sombra.withAlpha((sombra == const Color(0xFF000000) ? 70 : 18) * nivel ~/ 1),
          blurRadius: 18 * nivel,
          offset: Offset(0, 6 * nivel),
        ),
        BoxShadow(
          color: sombra.withAlpha((sombra == const Color(0xFF000000) ? 40 : 10) * nivel ~/ 1),
          blurRadius: 3,
          offset: const Offset(0, 1),
        ),
      ];

  /// Resplandor naranja, para el elemento protagonista.
  List<BoxShadow> resplandor({double intensidad = 1}) => [
        BoxShadow(
          color: acento.withAlpha((60 * intensidad).round().clamp(0, 255)),
          blurRadius: 28,
          spreadRadius: -4,
          offset: const Offset(0, 8),
        ),
      ];

  @override
  SenusColores copyWith({
    Color? fondo,
    Color? superficie,
    Color? superficieElevada,
    Color? acento,
    Color? acentoApagado,
    Color? texto,
    Color? textoTenue,
    Color? error,
    Color? exito,
    Color? aviso,
    Color? borde,
    Color? sombra,
  }) =>
      SenusColores(
        fondo: fondo ?? this.fondo,
        superficie: superficie ?? this.superficie,
        superficieElevada: superficieElevada ?? this.superficieElevada,
        acento: acento ?? this.acento,
        acentoApagado: acentoApagado ?? this.acentoApagado,
        texto: texto ?? this.texto,
        textoTenue: textoTenue ?? this.textoTenue,
        error: error ?? this.error,
        exito: exito ?? this.exito,
        aviso: aviso ?? this.aviso,
        borde: borde ?? this.borde,
        sombra: sombra ?? this.sombra,
      );

  @override
  SenusColores lerp(covariant SenusColores? other, double t) {
    final o = other;
    if (o == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return SenusColores(
      fondo: l(fondo, o.fondo),
      superficie: l(superficie, o.superficie),
      superficieElevada: l(superficieElevada, o.superficieElevada),
      acento: l(acento, o.acento),
      acentoApagado: l(acentoApagado, o.acentoApagado),
      texto: l(texto, o.texto),
      textoTenue: l(textoTenue, o.textoTenue),
      error: l(error, o.error),
      exito: l(exito, o.exito),
      aviso: l(aviso, o.aviso),
      borde: l(borde, o.borde),
      sombra: l(sombra, o.sombra),
    );
  }
}

extension SenusContexto on BuildContext {
  SenusColores get col => Theme.of(this).extension<SenusColores>()!;
  TextTheme get tipo => Theme.of(this).textTheme;
}

/// Estilo para datos (versiones, seriales, tamaños, rutas).
TextStyle estiloDatos(BuildContext c, {double tam = 13, Color? color, FontWeight? peso}) =>
    TextStyle(
      fontFamily: Fuente.datos,
      fontSize: tam,
      height: 1.35,
      color: color ?? c.col.textoTenue,
      fontWeight: peso ?? FontWeight.w400,
      letterSpacing: 0,
    );

ThemeData temaSenus(Brightness brillo) {
  final c = brillo == Brightness.dark ? SenusColores.oscuro : SenusColores.claro;
  final esquema = ColorScheme.fromSeed(
    seedColor: SenusColores.acentoSE,
    brightness: brillo,
  ).copyWith(
    primary: c.acento,
    onPrimary: c.sobreAcento,
    primaryContainer: c.acentoApagado,
    onPrimaryContainer: brillo == Brightness.dark ? const Color(0xFFFFB27A) : const Color(0xFF7A3500),
    secondary: c.acento,
    onSecondary: c.sobreAcento,
    secondaryContainer: c.acentoApagado,
    onSecondaryContainer: c.texto,
    surface: c.superficie,
    onSurface: c.texto,
    onSurfaceVariant: c.textoTenue,
    surfaceContainerLowest: c.fondo,
    surfaceContainerLow: c.fondo,
    surfaceContainer: c.superficie,
    surfaceContainerHigh: c.superficieElevada,
    surfaceContainerHighest: c.superficieElevada,
    outline: c.textoTenue,
    outlineVariant: c.borde,
    error: c.error,
    onError: Colors.white,
    errorContainer: c.error.withAlpha(36),
    onErrorContainer: c.error,
    shadow: c.sombra,
  );

  // Jerarquía tipográfica: display ligera (como el reloj del teléfono),
  // títulos firmes, cuerpo legible.
  TextStyle t(double tam, FontWeight w, {double alto = 1.3, double esp = 0, Color? color}) =>
      TextStyle(
        fontFamily: Fuente.texto,
        fontSize: tam,
        fontWeight: w,
        height: alto,
        letterSpacing: esp,
        color: color ?? c.texto,
      );
  final tipos = TextTheme(
    displayLarge: t(56, FontWeight.w300, alto: 1.05, esp: -1.5),
    displayMedium: t(44, FontWeight.w300, alto: 1.1, esp: -1),
    displaySmall: t(34, FontWeight.w400, alto: 1.15, esp: -0.5),
    headlineLarge: t(30, FontWeight.w600, alto: 1.2, esp: -0.5),
    headlineMedium: t(26, FontWeight.w600, alto: 1.2, esp: -0.4),
    headlineSmall: t(22, FontWeight.w600, alto: 1.25, esp: -0.3),
    titleLarge: t(19, FontWeight.w600, esp: -0.2),
    titleMedium: t(15, FontWeight.w600, esp: -0.1),
    titleSmall: t(13, FontWeight.w600),
    bodyLarge: t(15, FontWeight.w400, alto: 1.5),
    bodyMedium: t(14, FontWeight.w400, alto: 1.5),
    bodySmall: t(12, FontWeight.w400, alto: 1.45, color: c.textoTenue),
    labelLarge: t(14, FontWeight.w600, esp: 0.1),
    labelMedium: t(12, FontWeight.w500, esp: 0.2),
    labelSmall: t(11, FontWeight.w600, esp: 0.8, color: c.textoTenue),
  );

  final formaBoton = RoundedRectangleBorder(borderRadius: BorderRadius.circular(Rad.medio));
  const rellenoBoton = EdgeInsets.symmetric(horizontal: Esp.x6, vertical: Esp.x4);

  return ThemeData(
    useMaterial3: true,
    brightness: brillo,
    colorScheme: esquema,
    fontFamily: Fuente.texto,
    textTheme: tipos,
    scaffoldBackgroundColor: c.fondo,
    canvasColor: c.fondo,
    dividerColor: c.borde,
    splashFactory: InkSparkle.splashFactory,
    visualDensity: VisualDensity.standard,
    extensions: [c],
    dividerTheme: DividerThemeData(color: c.borde, thickness: 1, space: 1),
    iconTheme: IconThemeData(color: c.texto, size: 22),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.acento,
        foregroundColor: c.sobreAcento,
        disabledBackgroundColor: c.superficieElevada,
        disabledForegroundColor: c.textoTenue,
        padding: rellenoBoton,
        shape: formaBoton,
        textStyle: tipos.labelLarge,
        elevation: 0,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.texto,
        padding: rellenoBoton,
        shape: formaBoton,
        side: BorderSide(color: c.borde, width: 1.2),
        textStyle: tipos.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: c.acento,
        padding: const EdgeInsets.symmetric(horizontal: Esp.x4, vertical: Esp.x3),
        shape: formaBoton,
        textStyle: tipos.labelLarge,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: c.textoTenue,
        hoverColor: c.acento.withAlpha(24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Rad.chico)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: c.superficieElevada,
      contentTextStyle: tipos.bodyMedium,
      actionTextColor: c.acento,
      elevation: 2,
      width: 520,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Rad.medio),
        side: BorderSide(color: c.borde),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: c.superficieElevada,
        borderRadius: BorderRadius.circular(Rad.chico),
        border: Border.all(color: c.borde),
        boxShadow: c.sombraSuave(),
      ),
      textStyle: tipos.bodySmall?.copyWith(color: c.texto),
      waitDuration: const Duration(milliseconds: 400),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: c.acento,
      linearTrackColor: c.acentoApagado,
      circularTrackColor: Colors.transparent,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(c.textoTenue.withAlpha(80)),
      radius: const Radius.circular(8),
      thickness: const WidgetStatePropertyAll(6),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        side: WidgetStatePropertyAll(BorderSide(color: c.borde)),
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? c.acentoApagado : Colors.transparent,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? c.acento : c.texto,
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: Esp.x4, vertical: Esp.x3),
        ),
      ),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.macOS: FadeUpwardsPageTransitionsBuilder(),
      TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
      TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
    }),
  );
}
