// Una app .sen del teléfono, de cualquiera de sus cuatro sitios.

/// De dónde sale. Los valores 0..3 son los de `SEN_APPS` (§6 del contrato).
enum OrigenApp {
  fabrica, // `/apps` del W6FS: no se ve por MTP y no se borra
  memoria, // `/memoria/apps`
  tarjetaApps, // `/tarjeta/apps`
  tarjetaJuegos, // `/tarjeta/juegos`
  desconocido;

  static OrigenApp deCodigo(int c) =>
      c >= 0 && c < desconocido.index ? values[c] : desconocido;

  String get rotulo => switch (this) {
        OrigenApp.fabrica => 'De fábrica',
        OrigenApp.memoria => 'Memoria',
        OrigenApp.tarjetaApps => 'Tarjeta',
        OrigenApp.tarjetaJuegos => 'Juegos de la tarjeta',
        OrigenApp.desconocido => 'Otro sitio',
      };
}

class AppSen {
  final int handle;           // handle MTP; 0 si MTP no llega (las de fábrica)
  final String nombre;        // nombre de fichero, p. ej. "juego.sen"
  final int bytes;
  final DateTime? modificado;
  final OrigenApp origen;

  /// Bit 0 de `SEN_APPS`: el teléfono no la deja borrar.
  final bool protegida;

  /// Bit 1 de `SEN_APPS`: hay otra copia que manda sobre esta.
  final bool tapada;

  final String titulo;        // nombre de la cabecera: «Música»
  final int? verApp;          // null si no se pudo leer la cabecera
  final int perfil;           // 1 app, 2 juego
  final int iconoGen;
  final int iconoAn;
  final List<int> iconoFilas;
  final int apiMayor;
  final int apiMenor;

  const AppSen({
    required this.handle,
    required this.nombre,
    required this.bytes,
    this.modificado,
    this.origen = OrigenApp.memoria,
    this.protegida = false,
    this.tapada = false,
    this.titulo = '',
    this.verApp,
    this.perfil = 0,
    this.iconoGen = 0,
    this.iconoAn = 0,
    this.iconoFilas = const [],
    this.apiMayor = 0,
    this.apiMenor = 0,
  });

  /// Las de fábrica viven en el W6FS y no se pueden borrar.
  bool get deFabrica => origen == OrigenApp.fabrica;

  /// El id del catálogo: el nombre de fichero sin `.sen` (la cabecera no trae
  /// id y tres apps se llaman «Música»).
  String get id {
    final n = nombre.toLowerCase();
    return n.endsWith('.sen') ? n.substring(0, n.length - 4) : n;
  }

  String get tituloVisible => titulo.isEmpty ? nombre : titulo;

  /// ¿Se ofrece quitarla? Solo lo que el teléfono deja borrar y MTP alcanza.
  bool get sePuedeQuitar => !deFabrica && !protegida && handle != 0;
}
