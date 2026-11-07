// Qué es un componente de los servicios locales de SENUS: lo que se baja, de
// dónde y con qué huella. Las huellas se fijan aquí, en el código: nada que no
// case con ellas se ejecuta (gestor_componentes.dart).

/// Cómo llega un archivo al disco.
enum TipoArchivo {
  /// Un fichero suelto que se guarda tal cual (un modelo).
  directo,

  /// Un .zip que se descomprime en una carpeta; se comprueba el zip y también
  /// el árbol que queda en el disco.
  zip,

  /// Va dentro de SENUS (assets): se copia a la carpeta de soporte.
  empotrado,
}

class ArchivoComponente {
  /// De dónde sale: la URL oficial, o la ruta del asset si es [TipoArchivo.empotrado].
  final String origen;

  /// sha256 de lo descargado (o del asset).
  final String sha256;

  /// Bytes de lo descargado.
  final int tam;

  final TipoArchivo tipo;

  /// Nombre dentro de la carpeta del componente: fichero, o subcarpeta del zip.
  final String destino;

  /// Solo zip: la huella del árbol descomprimido ([huellaArbol]).
  final String? arbolSha256;

  /// Bytes que ocupa ya instalado.
  final int tamInstalado;

  const ArchivoComponente({
    required this.origen,
    required this.sha256,
    required this.tam,
    required this.tipo,
    required this.destino,
    this.arbolSha256,
    required this.tamInstalado,
  });
}

class Componente {
  final String id;

  /// Versión del conjunto: cambiarla instala en otra carpeta.
  final String version;

  final List<ArchivoComponente> archivos;

  /// De dónde sale y bajo qué licencia, para mostrarlo si hace falta.
  final String licencias;

  const Componente({
    required this.id,
    required this.version,
    required this.archivos,
    required this.licencias,
  });

  int get bytesDescarga => archivos.where((a) => a.tipo != TipoArchivo.empotrado).fold(0, (s, a) => s + a.tam);

  int get bytesInstalado => archivos.fold(0, (s, a) => s + a.tamInstalado);
}

/// Qué impide usar un componente en esta plataforma.
class ComponenteNoDisponible {
  final String porque;
  const ComponenteNoDisponible(this.porque);
}
