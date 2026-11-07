// Modelo del paquete de respaldo .zip (ver DISENO.md §5).

class EntradaRespaldo {
  final String ruta;    // dentro del zip, p. ej. "memoria/mis_archivos/foto.jpg"
  final int bytes;
  final String sha256;
  final DateTime? modificado;

  const EntradaRespaldo({
    required this.ruta,
    required this.bytes,
    required this.sha256,
    required this.modificado,
  });
}

class ManifiestoRespaldo {
  final String versionSenus;    // "1.0"
  final DateTime fecha;
  final String modelo;          // "W580"
  final String soc;             // "DB2020"
  final String serie;
  final String nombreAmigo;
  final String senewVersionBcd; // "0.19"
  final List<EntradaRespaldo> contenido;
  final List<String> notas;

  const ManifiestoRespaldo({
    required this.versionSenus,
    required this.fecha,
    required this.modelo,
    required this.soc,
    required this.serie,
    required this.nombreAmigo,
    required this.senewVersionBcd,
    required this.contenido,
    required this.notas,
  });
}
