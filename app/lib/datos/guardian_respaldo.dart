// La regla de rollback para actualizar: sin los dos GDFS de ESE aparato,
// releídos del disco y cotejados, no se toca el firmware. Esto no confía en lo
// que diga el índice de respaldos: vuelve a leer los ficheros.

import 'dart:io';

import 'indice_semakers.dart' show sha256De;
import 'respaldo_rollback.dart';

class SinRespaldoValido implements Exception {
  final String motivo;
  const SinRespaldoValido(this.motivo);
  @override
  String toString() => motivo;
}

class GuardianRespaldo {
  final AlmacenRespaldos almacen;
  GuardianRespaldo(this.almacen);

  Future<String?> _problema(RespaldoRollback r) async {
    if (r.simulado) return 'es un respaldo simulado';
    final a = File(r.rutaGdfsA), b = File(r.rutaGdfsB);
    if (!await a.exists() || !await b.exists()) return 'le falta un GDFS';
    final da = await a.readAsBytes(), db = await b.readAsBytes();
    if (da.isEmpty || db.isEmpty) return 'tiene un GDFS vacío';
    final sa = sha256De(da), sb = sha256De(db);
    final ea = await r.shaGdfsAResuelto(), eb = await r.shaGdfsBResuelto();
    if (ea == null || eb == null) return 'no tiene sha256 con qué cotejar';
    if (sa != ea) return 'el GDFS A cambió en el disco';
    if (sb != eb) return 'el GDFS B cambió en el disco';
    if (sa != sb) return 'los dos GDFS no coinciden entre sí';
    return null;
  }

  /// Devuelve un respaldo verificado de ese aparato, el más reciente que pase.
  /// Si no hay ninguno, lanza con el motivo.
  Future<RespaldoRollback> exigir(String modelo, String imei) async {
    if (imei.isEmpty) {
      throw const SinRespaldoValido('No se sabe qué aparato es.');
    }
    final todos = (await almacen.listar())
        .where((r) => r.modelo == modelo && r.serie == imei)
        .toList()
      ..sort((x, y) => y.fecha.compareTo(x.fecha));
    if (todos.isEmpty) {
      throw SinRespaldoValido(
          'No hay respaldo del aparato $imei en ${almacen.rutaBase}.');
    }
    final motivos = <String>[];
    for (final r in todos) {
      final p = await _problema(r);
      if (p == null) return r;
      motivos.add('${r.carpeta}: $p');
    }
    throw SinRespaldoValido(
        'Ningún respaldo del aparato $imei pasa la comprobación.\n'
        '${motivos.join('\n')}');
  }
}
