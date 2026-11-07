// La lista de teléfonos que pueden usar el puente: una dirección por línea, como
// `~/.config/w580-puente/permitidos` del puente de Python. Dart puro.

import 'dart:io';

final RegExp _direccion = RegExp(r'^([0-9A-F]{2}:){5}[0-9A-F]{2}$');

/// «aa-bb-cc-dd-ee-ff» o «AA:BB:…» → «AA:BB:CC:DD:EE:FF»; null si no es una.
String? normalizarDireccion(String d) {
  final t = d.trim().toUpperCase().replaceAll('-', ':');
  return _direccion.hasMatch(t) ? t : null;
}

/// Los 6 bytes en el orden de `bd_addr`, el de la dirección escrita.
String direccionDeBytes(List<int> b) => b
    .map((x) => x.toRadixString(16).padLeft(2, '0').toUpperCase())
    .join(':');

List<int> bytesDeDireccion(String d) {
  final t = normalizarDireccion(d);
  if (t == null) throw ArgumentError('Dirección Bluetooth mala: $d');
  return [for (final p in t.split(':')) int.parse(p, radix: 16)];
}

class ListaPermitidos {
  final File fichero;
  final Set<String> _d;
  ListaPermitidos._(this.fichero, this._d);

  static Future<ListaPermitidos> cargar(File f) async {
    final d = <String>{};
    if (await f.exists()) {
      for (final l in await f.readAsLines()) {
        if (l.startsWith('#')) continue;
        final t = normalizarDireccion(l);
        if (t != null) d.add(t);
      }
    }
    return ListaPermitidos._(f, d);
  }

  List<String> get todas => _d.toList()..sort();

  bool contiene(String d) {
    final t = normalizarDireccion(d);
    return t != null && _d.contains(t);
  }

  Future<void> anadir(String d) async {
    final t = normalizarDireccion(d);
    if (t == null) throw ArgumentError('Dirección Bluetooth mala: $d');
    if (_d.add(t)) await _guardar();
  }

  Future<void> quitar(String d) async {
    final t = normalizarDireccion(d);
    if (t != null && _d.remove(t)) await _guardar();
  }

  Future<void> _guardar() async {
    await fichero.parent.create(recursive: true);
    final tmp = File('${fichero.path}.tmp');
    await tmp.writeAsString(
        '# teléfonos que pueden usar el puente de SENUS\n'
        '${_d.map((e) => '$e\n').join()}');
    await tmp.rename(fichero.path);
  }
}
