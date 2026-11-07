// Sesión MTP de alto nivel sobre un TransporteMtp (libusb o socket).
//
// Implementa los opcodes del cable de senew (DISENO.md §4.1):
//   OpenSession, CloseSession, GetDeviceInfo,
//   GetStorageIDs, GetStorageInfo,
//   GetObjectHandles, GetObjectInfo, GetObject,
//   SendObjectInfo, SendObject, DeleteObject, GetPartialObject,
//   GetDevicePropValue(DP_NOMBRE_AMIGO).
// El canal de gestión (0x94xx) va encima, en canal_gestion.dart.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as cripto;

import '../datos/sen_cab.dart';
import '../datos/telefono.dart';
import '../datos/app_sen.dart';
import 'codificacion.dart';
import 'operaciones.dart';
import 'transporte.dart';

/// Resultado tipado: `bien` si cod == rOk y hay valor.
class ResultadoMtp<T> {
  final T? valor;
  final int codigoResp;
  final String? mensaje;
  const ResultadoMtp.ok(this.valor)
      : codigoResp = rOk,
        mensaje = null;
  const ResultadoMtp.error(this.codigoResp, this.mensaje) : valor = null;
  bool get bien => codigoResp == rOk;

  @override
  String toString() => bien ? 'ok($valor)' : 'err(0x${codigoResp.toRadixString(16)}: $mensaje)';
}

/// Un objeto encontrado por GetObjectHandles / GetObjectInfo.
class ObjetoMtp {
  final int handle;
  final int formato;       // 0x3001 carpeta, 0x3000 undefined, etc.
  final int tamano;
  final String nombre;
  final int padre;
  final int almacen;
  final DateTime? creado;
  final DateTime? modificado;
  ObjetoMtp({
    required this.handle,
    required this.formato,
    required this.tamano,
    required this.nombre,
    required this.padre,
    required this.almacen,
    this.creado,
    this.modificado,
  });
  bool get esCarpeta => formato == fmtCarpeta;
}

class SesionMtp {
  final TransporteMtp transporte;
  int _tx = 0;
  int _idSesion = 0;

  /// La cola de transacciones. El USB solo lleva una a la vez y dos pantallas
  /// pueden pedir a la vez: cambiar de pestaña no cancela lo que estaba en
  /// marcha. Sin esto se mezclan las respuestas y la sesión queda inservible.
  Future<void> _cola = Future<void>.value();

  SesionMtp(this.transporte);

  Future<T> _enExclusiva<T>(Future<T> Function() trabajo) async {
    final previo = _cola;
    final hecho = Completer<void>();
    _cola = hecho.future;
    await previo;
    try {
      return await trabajo();
    } finally {
      hecho.complete();
    }
  }

  int get _siguienteTx => ++_tx;

  // ------------------------------------------------------------------ Capa baja
  //
  // El flujo MTP sobre bulk es:
  //   host -> OUT  : Orden (12B + hasta 5 u32)
  //   si hay datos:
  //     host -> OUT : Datos (12B + payload)   para operaciones de envío
  //     host <- IN  : Datos (12B + payload)   para operaciones de recepción
  //   host <- IN   : Respuesta (12B + hasta 5 u32)

  Future<void> _mandarOrden(int opcode, List<int> params) async {
    final c = Contenedor(
      tipo: tipoOrden,
      codigo: opcode,
      idTransaccion: _siguienteTx,
      parametros: params,
      datos: Uint8List(0),
    );
    await transporte.bulkOut(c.empaquetar());
  }

  /// Cada bulk OUT de un contenedor de datos lleva como mucho esto. Es múltiplo
  /// de 512 y de 64: ningún trozo salvo el último acaba en un paquete corto, así
  /// que el teléfono ve un solo contenedor. Un fichero de 17 MB de un tiro no
  /// cabe en el plazo de una transferencia, y con libusb cada llamada bloquea:
  /// a trozos el plazo es por trozo, la interfaz respira y el progreso avanza.
  static const int trozoSalida = 64 << 10;

  Future<void> _mandarDatos(int opcode, Uint8List payload,
      {void Function(int hechos, int total)? alProgreso}) async {
    final c = Contenedor(
      tipo: tipoDatos,
      codigo: opcode,
      idTransaccion: _tx,
      datos: payload,
    );
    final bruto = c.empaquetar();
    for (var i = 0; i < bruto.length; i += trozoSalida) {
      final fin = math.min(i + trozoSalida, bruto.length);
      await transporte.bulkOut(Uint8List.sublistView(bruto, i, fin),
          timeout: const Duration(seconds: 30));
      alProgreso?.call(math.max(0, fin - 12), payload.length);
    }
    // Si el tamaño es múltiplo exacto del MPS, mandamos ZLP (paquete vacío)
    // para marcar fin — pide MTP sobre USB.
    if (bruto.length % transporte.mps == 0) {
      await transporte.bulkOut(Uint8List(0));
    }
  }

  /// Recibe un contenedor completo (de datos o de respuesta).
  Future<Contenedor> _recibirContenedor({Duration tiempo = const Duration(seconds: 10)}) async {
    // En bytes, no en una lista de enteros: un fichero de varios MB son
    // millones de objetos y la relectura se hacía eterna.
    final partes = BytesBuilder(copy: false);
    int? longitudTotal;
    while (true) {
      final paq = await transporte.bulkIn(transporte.mps > 0 ? 16384 : 64, timeout: tiempo);
      partes.add(paq);
      if (longitudTotal == null && partes.length >= 4) {
        final bd = ByteData.sublistView(partes.toBytes(), 0, 4);
        longitudTotal = bd.getUint32(0, Endian.little);
      }
      // Fin: paquete corto, o alcanzamos la longitud declarada.
      final corto = paq.length < transporte.mps;
      final completo = longitudTotal != null && partes.length >= longitudTotal;
      if (corto || completo) break;
    }
    final bruto = partes.takeBytes();
    final cab = Contenedor.desempaquetarCabecera(bruto);
    // Para datos, adjunta el payload a mano (desempaquetarCabecera solo lee params).
    if (cab.tipo == tipoDatos && bruto.length > 12) {
      return Contenedor(
        tipo: cab.tipo,
        codigo: cab.codigo,
        idTransaccion: cab.idTransaccion,
        parametros: const [],
        datos: Uint8List.sublistView(bruto, 12),
      );
    }
    return cab;
  }

  /// Ejecuta una Operación completa: Orden [+ Datos salida] [+ Datos entrada] + Respuesta.
  /// Devuelve (código, params de la respuesta, bytes de los Datos recibidos — vacío si no hay).
  Future<(int, List<int>, Uint8List)> operacion(
    int opcode,
    List<int> params, {
    Uint8List? datosSalida,
    bool esperaDatos = false,
  }) =>
      _enExclusiva(() => _operacion(opcode, params,
          datosSalida: datosSalida, esperaDatos: esperaDatos));

  Future<(int, List<int>, Uint8List)> _operacion(
    int opcode,
    List<int> params, {
    Uint8List? datosSalida,
    bool esperaDatos = false,
  }) async {
    await _mandarOrden(opcode, params);
    if (datosSalida != null) {
      await _mandarDatos(opcode, datosSalida);
    }
    Uint8List datosEntrada = Uint8List(0);
    if (esperaDatos) {
      final c = await _recibirContenedor();
      if (c.tipo == tipoDatos) {
        datosEntrada = c.datos;
      } else if (c.tipo == tipoResp) {
        // Error antes de datos.
        return (c.codigo, c.parametros, datosEntrada);
      }
    }
    final r = await _recibirContenedor();
    if (r.tipo != tipoResp) {
      return (0xFFFF, const <int>[], datosEntrada);
    }
    return (r.codigo, r.parametros, datosEntrada);
  }

  // ------------------------------------------------------------------ API alta

  Future<ResultadoMtp<void>> abrir({Duration tiempoMax = const Duration(seconds: 60)}) async {
    _idSesion = 1;
    final t0 = DateTime.now();
    while (true) {
      final (cod, _, _) = await operacion(opOpenSession, [_idSesion]);
      if (cod == rOk) return const ResultadoMtp.ok(null);
      if (cod == rSesionYa) return const ResultadoMtp.ok(null);
      if (cod != rOcupado) {
        return ResultadoMtp.error(cod, 'OpenSession falló');
      }
      if (DateTime.now().difference(t0) > tiempoMax) {
        return ResultadoMtp.error(cod, 'El teléfono no aceptó la conexión en pantalla');
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }

  Future<void> cerrar() => _enExclusiva(() async {
        if (_idSesion != 0) {
          try { await _operacion(opCloseSession, const []); } catch (_) {}
          _idSesion = 0;
        }
        await transporte.cerrar();
      });

  /// Suelta el USB sin CloseSession: para un teléfono que ya se está yendo.
  Future<void> soltar() async {
    _idSesion = 0;
    try {
      await transporte.cerrar();
    } on TransporteError {
      // Ya no estaba: es lo que se espera.
    }
  }

  /// GetDeviceInfo → Telefono (sin almacenes todavía; esos los pide `almacenes()`).
  Future<ResultadoMtp<Telefono>> info() async {
    final (cod, _, datos) = await operacion(opDeviceInfo, const [], esperaDatos: true);
    if (cod != rOk) return ResultadoMtp.error(cod, 'GetDeviceInfo falló');
    final p = _parsearDeviceInfo(datos);
    if (p == null) {
      return const ResultadoMtp.error(0xFFFF, 'DeviceInfo malformado');
    }
    // Nombre amigo: lo expone el teléfono por DP_NOMBRE_AMIGO; si falla, usamos el Model.
    String nombreAmigo = p.modelo;
    final (cod2, _, datos2) = await operacion(opDevPropValue, [dpNombreAmigo], esperaDatos: true);
    if (cod2 == rOk && datos2.isNotEmpty) {
      // DP_NOMBRE_AMIGO es una cadena MTP suelta.
      try {
        final (s, _) = leerCadenaMtp(datos2, 0);
        if (s.isNotEmpty) nombreAmigo = s;
      } catch (_) {}
    }
    return ResultadoMtp.ok(Telefono(
      modelo: modeloDeNombre(nombreAmigo),
      nombreAmigo: nombreAmigo,
      serie: p.serie,
      versionSenew: p.version,
      almacenes: const [],
      canalGestion: p.operaciones.contains(opSenInfo),
    ));
  }

  /// GetStorageIDs + GetStorageInfo por cada uno → lista de almacenes.
  Future<ResultadoMtp<List<Almacen>>> almacenes() async {
    final (cod, _, datos) = await operacion(opStorageIds, const [], esperaDatos: true);
    if (cod != rOk) return ResultadoMtp.error(cod, 'GetStorageIDs falló');
    if (datos.length < 4) return const ResultadoMtp.ok(<Almacen>[]);
    final bd = ByteData.sublistView(datos);
    final n = bd.getUint32(0, Endian.little);
    final ids = <int>[];
    for (var i = 0; i < n; i++) {
      ids.add(bd.getUint32(4 + i * 4, Endian.little));
    }
    final res = <Almacen>[];
    for (final sid in ids) {
      final (cs, _, dsi) = await operacion(opStorageInfo, [sid], esperaDatos: true);
      if (cs != rOk) continue;
      final info = _parsearStorageInfo(dsi);
      if (info == null) continue;
      final etiq = sid == storageMemoria
          ? 'Memoria'
          : (sid == storageTarjeta ? 'Tarjeta' : (info.descripcion.isNotEmpty ? info.descripcion : 'Almacén'));
      res.add(Almacen(
        id: sid,
        etiqueta: etiq,
        bytesTotales: info.maxBytes,
        bytesLibres: info.libresBytes,
        soloLectura: info.acceso == 1, // 0x0001 read-only (MTP 1.1)
      ));
    }
    return ResultadoMtp.ok(res);
  }

  /// GetObjectHandles(storage, 0, padre).
  Future<ResultadoMtp<List<int>>> _handles(int almacen, int padre, {int formato = 0}) async {
    final (cod, _, d) = await operacion(opObjectHandles, [almacen, formato, padre], esperaDatos: true);
    if (cod != rOk) return ResultadoMtp.error(cod, 'GetObjectHandles falló');
    if (d.length < 4) return const ResultadoMtp.ok(<int>[]);
    final bd = ByteData.sublistView(d);
    final n = bd.getUint32(0, Endian.little);
    final out = <int>[];
    for (var i = 0; i < n; i++) {
      out.add(bd.getUint32(4 + i * 4, Endian.little));
    }
    return ResultadoMtp.ok(out);
  }

  /// GetObjectInfo(handle) → ObjetoMtp.
  Future<ResultadoMtp<ObjetoMtp>> _info(int handle) async {
    final (cod, _, d) = await operacion(opObjectInfo, [handle], esperaDatos: true);
    if (cod != rOk) return ResultadoMtp.error(cod, 'GetObjectInfo falló');
    final o = _parsearObjectInfo(d, handle);
    if (o == null) return const ResultadoMtp.error(0xFFFF, 'ObjectInfo malformado');
    return ResultadoMtp.ok(o);
  }

  /// Lee `n` bytes de un objeto desde `desde` (GetPartialObject).
  Future<ResultadoMtp<Uint8List>> leerParcial(int handle, int desde, int n) async {
    final (cod, _, d) = await operacion(opGetPartialObject, [handle, desde, n],
        esperaDatos: true);
    if (cod != rOk) return ResultadoMtp.error(cod, 'GetPartialObject falló');
    return ResultadoMtp.ok(d);
  }

  /// Las apps de una carpeta por MTP, con su cabecera leída con
  /// GetPartialObject. Si la cabecera no se puede leer, la app sale igual,
  /// con el nombre de fichero y sin versión.
  Future<List<AppSen>> _appsDeCarpeta(
      int almacen, String carpeta, OrigenApp origen) async {
    final h = await handleCarpeta(carpeta, almacen: almacen);
    if (!h.bien || h.valor == null) return const [];
    final l = await listarCarpeta(h.valor!, almacen: almacen);
    if (!l.bien) return const [];
    final out = <AppSen>[];
    for (final o in l.valor!) {
      if (o.esCarpeta || !o.nombre.toLowerCase().endsWith('.sen')) continue;
      SenCab? cab;
      final p = await leerParcial(o.handle, 0, SenCab.tam);
      if (p.bien) cab = SenCab.deBytes(p.valor!);
      out.add(AppSen(
        handle: o.handle,
        nombre: o.nombre,
        bytes: o.tamano,
        modificado: o.modificado,
        origen: origen,
        titulo: cab?.nombre ?? '',
        verApp: cab?.verApp,
        perfil: cab?.perfil ?? 0,
        iconoGen: cab?.iconoGen ?? 0,
        iconoAn: cab?.iconoAn ?? 0,
        iconoFilas: cab?.iconoFilas ?? const [],
        apiMayor: cab?.apiMayor ?? 0,
        apiMenor: cab?.apiMenor ?? 0,
      ));
    }
    return out;
  }

  /// Todas las apps que MTP deja ver: `/apps` de la Memoria y `apps` y `juegos`
  /// de la Tarjeta. Las de fábrica (`/apps` del W6FS) NO se ven por MTP: para
  /// eso hace falta `SEN_APPS`.
  Future<List<AppSen>> listarAppsMtp() async {
    final out = await _appsDeCarpeta(storageMemoria, 'apps', OrigenApp.memoria);
    final (cod, _, d) =
        await operacion(opStorageIds, const [], esperaDatos: true);
    if (cod != rOk || d.length < 4) return out;
    final bd = ByteData.sublistView(d);
    final n = bd.getUint32(0, Endian.little);
    for (var i = 0; i < n && 8 + i * 4 <= d.length; i++) {
      if (bd.getUint32(4 + i * 4, Endian.little) != storageTarjeta) continue;
      out.addAll(
          await _appsDeCarpeta(storageTarjeta, 'apps', OrigenApp.tarjetaApps));
      out.addAll(await _appsDeCarpeta(
          storageTarjeta, 'juegos', OrigenApp.tarjetaJuegos));
    }
    return _conTapadas(out);
  }

  /// Sin canal nadie dice qué copia manda: se aplica el orden del menú
  /// (`/tarjeta/apps` antes que la Memoria, y esta antes que `/tarjeta/juegos`).
  List<AppSen> _conTapadas(List<AppSen> l) {
    int rango(OrigenApp o) => switch (o) {
          OrigenApp.tarjetaApps => 0,
          OrigenApp.memoria => 1,
          _ => 2,
        };
    final vistos = <String, int>{};
    for (final a in l) {
      for (final k in [a.id, if (a.titulo.isNotEmpty) '#${a.titulo}']) {
        final r = rango(a.origen);
        if (r < (vistos[k] ?? 9)) vistos[k] = r;
      }
    }
    bool tapada(AppSen a) {
      final r = rango(a.origen);
      return (vistos[a.id] ?? r) < r ||
          (a.titulo.isNotEmpty && (vistos['#${a.titulo}'] ?? r) < r);
    }

    return [
      for (final a in l)
        tapada(a)
            ? AppSen(
                handle: a.handle,
                nombre: a.nombre,
                bytes: a.bytes,
                modificado: a.modificado,
                origen: a.origen,
                protegida: a.protegida,
                tapada: true,
                titulo: a.titulo,
                verApp: a.verApp,
                perfil: a.perfil,
                iconoGen: a.iconoGen,
                iconoAn: a.iconoAn,
                iconoFilas: a.iconoFilas,
                apiMayor: a.apiMayor,
                apiMenor: a.apiMenor)
            : a
    ];
  }

  /// Lista los objetos directamente contenidos en /apps.
  Future<ResultadoMtp<List<AppSen>>> listarApps() async {
    final almH = await _handles(storageMemoria, handleRaiz);
    if (!almH.bien) return ResultadoMtp.error(almH.codigoResp, almH.mensaje);
    int? apps;
    for (final h in almH.valor!) {
      final oi = await _info(h);
      if (!oi.bien) continue;
      if (oi.valor!.esCarpeta && oi.valor!.nombre == 'apps') {
        apps = h;
        break;
      }
    }
    if (apps == null) return const ResultadoMtp.ok(<AppSen>[]);
    final hAp = await _handles(storageMemoria, apps);
    if (!hAp.bien) return ResultadoMtp.error(hAp.codigoResp, hAp.mensaje);
    final res = <AppSen>[];
    for (final h in hAp.valor!) {
      final oi = await _info(h);
      if (!oi.bien) continue;
      final o = oi.valor!;
      res.add(AppSen(
        handle: o.handle,
        nombre: o.nombre,
        bytes: o.tamano,
        modificado: o.modificado,
      ));
    }
    return ResultadoMtp.ok(res);
  }

  /// SendObjectInfo + SendObject en /apps.
  Future<ResultadoMtp<int>> subirApp(String nombre, Uint8List bytes) async {
    // Localiza handle de /apps.
    final r = await _handles(storageMemoria, handleRaiz);
    if (!r.bien) return ResultadoMtp.error(r.codigoResp, r.mensaje);
    int? apps;
    for (final h in r.valor!) {
      final oi = await _info(h);
      if (oi.bien && oi.valor!.esCarpeta && oi.valor!.nombre == 'apps') {
        apps = h;
        break;
      }
    }
    // Sin la carpeta, el .sen caería en la raíz, donde el teléfono no lo ve.
    if (apps == null) {
      return const ResultadoMtp.error(rGeneral, 'El teléfono no tiene carpeta /apps');
    }
    final oi = _construirObjectInfo(
      storageId: storageMemoria,
      formato: fmtIndef,
      bytes: bytes.length,
      nombre: nombre,
    );
    return _enviar(storageMemoria, apps, oi, bytes);
  }

  /// SendObjectInfo y SendObject van pegados: nada puede colarse entre los dos.
  Future<ResultadoMtp<int>> _enviar(
          int almacen, int padre, Uint8List oi, Uint8List bytes,
          {void Function(int hechos, int total)? alProgreso}) =>
      _enExclusiva(() async {
        final (c1, p1, _) = await _operacion(
            opSendObjectInfo, [almacen, padre],
            datosSalida: oi);
        if (c1 != rOk) return ResultadoMtp.error(c1, 'SendObjectInfo falló');
        final handleNuevo = p1.length >= 3 ? p1[2] : 0;
        await _mandarOrden(opSendObject, const []);
        await _mandarDatos(opSendObject, bytes, alProgreso: alProgreso);
        // La respuesta sale cuando el teléfono ha cerrado el fichero: con uno
        // grande en la tarjeta, la FAT entera por escribir.
        final r = await _recibirContenedor(tiempo: const Duration(seconds: 60));
        final c2 = r.tipo == tipoResp ? r.codigo : 0xFFFF;
        if (c2 != rOk) return ResultadoMtp.error(c2, 'SendObject falló');
        return ResultadoMtp.ok(handleNuevo);
      });

  /// Sube un .sen a /apps y lo RELEE del teléfono comparando sha256. Sin esto,
  /// un fallo a medias del cable no se ve hasta que la app se niega a cargar.
  /// Si no cuadra, la copia mala se borra y el error lo dice.
  Future<ResultadoMtp<int>> subirAppVerificada(
      String nombre, Uint8List bytes) async {
    final r = await subirApp(nombre, bytes);
    if (!r.bien) return r;
    final h = await handleCarpeta('apps');
    if (!h.bien || h.valor == null) {
      return ResultadoMtp.error(h.codigoResp == rOk ? rGeneral : h.codigoResp,
          'No se encontró /apps para releer lo subido');
    }
    final l = await listarCarpeta(h.valor!);
    if (!l.bien) return ResultadoMtp.error(l.codigoResp, l.mensaje);
    final o = l.valor!.where((x) => x.nombre == nombre).toList();
    if (o.isEmpty) {
      return const ResultadoMtp.error(
          rGeneral, 'Lo subido no aparece en /apps: el teléfono no lo guardó');
    }
    final leido = await bajarApp(o.first.handle);
    if (!leido.bien) return ResultadoMtp.error(leido.codigoResp, leido.mensaje);
    final subido = cripto.sha256.convert(bytes).toString();
    final vuelto = cripto.sha256.convert(leido.valor!).toString();
    if (subido != vuelto) {
      final b = await borrarApp(o.first.handle);
      return ResultadoMtp.error(
          rGeneral,
          'Lo que quedó en el teléfono no es lo que se subió '
          '(${leido.valor!.length} B de ${bytes.length}; sha256 distinto). '
          '${b.bien ? 'Se borró la copia mala.' : 'No se pudo borrar la copia mala.'}');
    }
    return ResultadoMtp.ok(o.first.handle);
  }

  Future<ResultadoMtp<Uint8List>> bajarApp(int handle) async {
    final (cod, _, d) = await operacion(opGetObject, [handle], esperaDatos: true);
    if (cod != rOk) return ResultadoMtp.error(cod, 'GetObject falló');
    return ResultadoMtp.ok(d);
  }

  /// Encuentra el handle de una carpeta por nombre colgada de un padre.
  /// Devuelve `null` (sin error) si no está. Útil para localizar /apps,
  /// /mis_archivos, /ajustes antes de leerlos.
  Future<ResultadoMtp<int?>> handleCarpeta(String nombre,
      {int almacen = storageMemoria, int padre = handleRaiz}) async {
    final r = await _handles(almacen, padre);
    if (!r.bien) return ResultadoMtp.error(r.codigoResp, r.mensaje);
    for (final h in r.valor!) {
      final oi = await _info(h);
      if (!oi.bien) continue;
      if (oi.valor!.esCarpeta && oi.valor!.nombre == nombre) {
        return ResultadoMtp.ok(h);
      }
    }
    return const ResultadoMtp.ok(null);
  }

  /// Lista todos los objetos directamente contenidos en una carpeta.
  Future<ResultadoMtp<List<ObjetoMtp>>> listarCarpeta(int handle,
      {int almacen = storageMemoria}) async {
    final r = await _handles(almacen, handle);
    if (!r.bien) return ResultadoMtp.error(r.codigoResp, r.mensaje);
    final out = <ObjetoMtp>[];
    for (final h in r.valor!) {
      final oi = await _info(h);
      if (!oi.bien) continue;
      out.add(oi.valor!);
    }
    return ResultadoMtp.ok(out);
  }

  /// Baja un objeto cualquiera por su handle (lo mismo que bajarApp,
  /// renombrado para los respaldos).
  Future<ResultadoMtp<Uint8List>> bajarObjeto(int handle) => bajarApp(handle);

  /// Envía un objeto a una carpeta dada por handle (equivalente a subirApp
  /// pero con padre configurable). Para respaldos y catálogo.
  Future<ResultadoMtp<int>> enviarObjeto(
    int padre,
    String nombre,
    Uint8List bytes, {
    int almacen = storageMemoria,
    int formato = fmtIndef,
    void Function(int hechos, int total)? alProgreso,
  }) async {
    final oi = _construirObjectInfo(
      storageId: almacen,
      formato: formato,
      bytes: bytes.length,
      nombre: nombre,
    );
    return _enviar(almacen, padre, oi, bytes, alProgreso: alProgreso);
  }

  /// Crea una carpeta: SendObjectInfo de formato 0x3001, sin SendObject. Si ya
  /// hay algo con ese nombre el teléfono contesta R_GENERAL: se mira antes.
  Future<ResultadoMtp<int>> crearCarpeta(String nombre,
          {required int almacen, int padre = handleRaiz}) =>
      _enExclusiva(() async {
        final oi = _construirObjectInfo(
            storageId: almacen, formato: fmtCarpeta, bytes: 0, nombre: nombre);
        final (c, p, _) = await _operacion(opSendObjectInfo, [almacen, padre],
            datosSalida: oi);
        if (c != rOk) {
          return ResultadoMtp.error(
              c, 'El teléfono no creó la carpeta «$nombre»');
        }
        if (p.length < 3 || p[2] == 0) {
          return ResultadoMtp.error(
              rGeneral, 'El teléfono creó «$nombre» y no dio su handle');
        }
        return ResultadoMtp.ok(p[2]);
      });

  /// El hijo de una carpeta con ese nombre, sin mirar mayúsculas: en FAT
  /// «JUEGOS» y «juegos» son lo mismo, y el teléfono no deja crear el otro.
  Future<ResultadoMtp<ObjetoMtp?>> buscarHijo(String nombre,
      {required int almacen, int padre = handleRaiz}) async {
    final l = await listarCarpeta(padre, almacen: almacen);
    if (!l.bien) return ResultadoMtp.error(l.codigoResp, l.mensaje);
    final n = nombre.toLowerCase();
    for (final o in l.valor!) {
      if (o.nombre.toLowerCase() == n) return ResultadoMtp.ok(o);
    }
    return const ResultadoMtp.ok(null);
  }

  /// Cuántos objetos de ese almacén ve MTP (GetObjectHandles con padre 0).
  Future<ResultadoMtp<int>> contarObjetos(int almacen) async {
    final r = await _handles(almacen, 0);
    if (!r.bien) return ResultadoMtp.error(r.codigoResp, r.mensaje);
    return ResultadoMtp.ok(r.valor!.length);
  }

  /// GetObjectInfo de un handle.
  Future<ResultadoMtp<ObjetoMtp>> infoObjeto(int handle) => _info(handle);

  /// La relectura va a trozos de GetPartialObject: cada uno tiene su plazo,
  /// hay progreso y no se junta el fichero entero en memoria.
  static const int trozoLectura = 256 << 10;

  /// El sha256 de lo que guarda el teléfono en ese objeto, leído entero.
  Future<ResultadoMtp<String>> shaDeObjeto(int handle, int tam,
      {void Function(int hechos, int total)? alProgreso}) async {
    final recoge = _RecogeDigest();
    final conv = cripto.sha256.startChunkedConversion(recoge);
    var hechos = 0;
    while (hechos < tam) {
      final n = math.min(trozoLectura, tam - hechos);
      final p = await leerParcial(handle, hechos, n);
      if (!p.bien) return ResultadoMtp.error(p.codigoResp, p.mensaje);
      if (p.valor!.length != n) {
        return ResultadoMtp.error(rGeneral,
            'El teléfono dio ${p.valor!.length} B donde se pidieron $n');
      }
      conv.add(p.valor!);
      hechos += n;
      alProgreso?.call(hechos, tam);
    }
    conv.close();
    return ResultadoMtp.ok(recoge.valor.toString());
  }

  /// Sube un fichero a una carpeta y lo RELEE comparando sha256, como
  /// [subirAppVerificada] pero en cualquier almacén y con progreso: [alProgreso]
  /// cuenta la subida y la relectura, así que el total es el doble del fichero.
  /// Si lo que quedó no es lo subido, se borra y el error lo dice.
  Future<ResultadoMtp<int>> subirVerificado(
      int almacen, int padre, String nombre, Uint8List bytes,
      {void Function(int hechos, int total)? alProgreso}) async {
    final total = bytes.length * 2;
    final r = await enviarObjeto(padre, nombre, bytes,
        almacen: almacen, alProgreso: (h, _) => alProgreso?.call(h, total));
    if (!r.bien) return r;
    final h = r.valor!;
    final oi = h == 0 ? null : await _info(h);
    final o = oi?.valor;
    if (o == null || o.nombre.toLowerCase() != nombre.toLowerCase()) {
      return ResultadoMtp.error(
          rGeneral, 'Lo subido no aparece como «$nombre»: el teléfono no lo guardó');
    }
    String? vuelto;
    if (o.tamano == bytes.length) {
      final s = await shaDeObjeto(h, bytes.length,
          alProgreso: (x, _) => alProgreso?.call(bytes.length + x, total));
      if (!s.bien) return ResultadoMtp.error(s.codigoResp, s.mensaje);
      vuelto = s.valor;
    }
    if (vuelto != cripto.sha256.convert(bytes).toString()) {
      final b = await borrarApp(h);
      return ResultadoMtp.error(
          rGeneral,
          'Lo que quedó en el teléfono no es lo que se subió '
          '(«$nombre», ${o.tamano} B de ${bytes.length}'
          '${vuelto == null ? '' : '; sha256 distinto'}). '
          '${b.bien ? 'Se borró la copia mala.' : 'No se pudo borrar la copia mala.'}');
    }
    return ResultadoMtp.ok(h);
  }

  Future<ResultadoMtp<void>> borrarApp(int handle) async {
    final (cod, _, _) = await operacion(opDeleteObject, [handle, 0]);
    if (cod == rOk) return const ResultadoMtp.ok(null);
    if (cod == rProtegido) {
      return ResultadoMtp.error(cod, 'Esta app es de fábrica y no se puede borrar');
    }
    return ResultadoMtp.error(cod, 'DeleteObject falló');
  }
}

/// Se queda con el resumen de un sha256 por trozos.
class _RecogeDigest implements Sink<cripto.Digest> {
  late cripto.Digest valor;
  @override
  void add(cripto.Digest d) => valor = d;
  @override
  void close() {}
}

// ------------------------------------------------------------- parseadores

class _DeviceInfo {
  final int stdVer;
  final String fabricante, modelo, version, serie;
  final Set<int> operaciones;
  _DeviceInfo(this.stdVer, this.fabricante, this.modelo, this.version, this.serie,
      this.operaciones);
}

_DeviceInfo? _parsearDeviceInfo(Uint8List d) {
  if (d.length < 2) return null;
  final bd = ByteData.sublistView(d);
  var off = 0;
  final std = bd.getUint16(off, Endian.little); off += 2;
  off += 4;                                           // VendorExtensionID u32
  off += 2;                                           // VendorExtensionVersion u16
  final (_, off1) = leerCadenaMtp(d, off); off = off1; // VendorExtensionDesc str
  off += 2;                                           // FunctionalMode u16
  final ops = _leerArrU16(bd, off);                   // OperationsSupported
  off = _saltarArrU16(bd, off);
  off = _saltarArrU16(bd, off);                       // EventsSupported
  off = _saltarArrU16(bd, off);                       // DevicePropertiesSupported
  off = _saltarArrU16(bd, off);                       // CaptureFormats
  off = _saltarArrU16(bd, off);                       // ImageFormats
  final (fab, o1) = leerCadenaMtp(d, off); off = o1;
  final (mod, o2) = leerCadenaMtp(d, off); off = o2;
  final (ver, o3) = leerCadenaMtp(d, off); off = o3;
  final (ser, _) = leerCadenaMtp(d, off);
  return _DeviceInfo(std, fab, mod, ver, ser, ops);
}

Set<int> _leerArrU16(ByteData bd, int off) {
  final n = bd.getUint32(off, Endian.little);
  return {for (var i = 0; i < n; i++) bd.getUint16(off + 4 + i * 2, Endian.little)};
}

int _saltarArrU16(ByteData bd, int off) {
  final n = bd.getUint32(off, Endian.little);
  return off + 4 + n * 2;
}

class _StorageInfo {
  final int tipo, fs, acceso;
  final int maxBytes, libresBytes;
  final String descripcion;
  _StorageInfo(this.tipo, this.fs, this.acceso, this.maxBytes, this.libresBytes, this.descripcion);
}

_StorageInfo? _parsearStorageInfo(Uint8List d) {
  if (d.length < 26) return null;
  final bd = ByteData.sublistView(d);
  var off = 0;
  final tipo = bd.getUint16(off, Endian.little); off += 2;
  final fs = bd.getUint16(off, Endian.little); off += 2;
  final acc = bd.getUint16(off, Endian.little); off += 2;
  final maxC = bd.getUint64(off, Endian.little); off += 8;
  final libB = bd.getUint64(off, Endian.little); off += 8;
  off += 4;                                           // freeInObjects u32
  final (desc, _) = leerCadenaMtp(d, off);
  return _StorageInfo(tipo, fs, acc, maxC, libB, desc);
}

ObjetoMtp? _parsearObjectInfo(Uint8List d, int handle) {
  // Layout de ObjectInfo (MTP 1.1 §5.3.1): 52 bytes fijos + cadenas.
  if (d.length < 52) return null;
  final bd = ByteData.sublistView(d);
  final almacen = bd.getUint32(0, Endian.little);
  final formato = bd.getUint16(4, Endian.little);
  final tamano = bd.getUint32(8, Endian.little);
  final padre = bd.getUint32(36, Endian.little);
  var off = 52;
  final (nombre, o1) = leerCadenaMtp(d, off); off = o1;
  final (sCreado, o2) = leerCadenaMtp(d, off); off = o2;
  final (sModif, _) = leerCadenaMtp(d, off);
  return ObjetoMtp(
    handle: handle,
    formato: formato,
    tamano: tamano,
    nombre: nombre,
    padre: padre,
    almacen: almacen,
    creado: parsearFechaMtp(sCreado),
    modificado: parsearFechaMtp(sModif),
  );
}

Uint8List _construirObjectInfo({
  required int storageId,
  required int formato,
  required int bytes,
  required String nombre,
}) {
  // Mismo layout de ObjectInfo (52 B fijos + 3 cadenas MTP). Padre lo pone
  // el host en el param 2 de SendObjectInfo; aquí dejamos los opcionales a 0.
  final fijo = ByteData(52);
  fijo.setUint32(0, storageId, Endian.little);
  fijo.setUint16(4, formato, Endian.little);
  fijo.setUint16(6, 0, Endian.little);              // ProtectionStatus
  fijo.setUint32(8, bytes, Endian.little);           // ObjectCompressedSize
  // ThumbFormat, ThumbCompressedSize, ThumbPixWidth, ThumbPixHeight (12..27) = 0
  // ImagePixWidth, Height, BitDepth, ParentObject (28..39)
  // AssociationType, AssociationDescription, SequenceNumber (40..51)
  final b = BytesBuilder(copy: false);
  b.add(fijo.buffer.asUint8List());
  b.add(cadenaMtp(nombre));                          // Filename
  b.add(cadenaMtp(''));                              // CaptureDate
  b.add(cadenaMtp(''));                              // ModificationDate
  b.add(Uint8List.fromList([0]));                    // Keywords (cadena vacía)
  return b.toBytes();
}
