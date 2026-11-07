// El W580 de las pruebas, en Dart: habla MTP (con y sin canal), el BL por EP0 y
// el puente, con una NOR de verdad: un WRITE sobre una región sin borrar falla
// como en `bl_nor.c`, y al arrancar se toma la decisión de `bl_arranque.S`. Eso
// es lo que deja medir la regla: si los vectores están y el main no está entero,
// el teléfono arranca un main a medias y [arrancoMedioMain] lo delata.
//
// Es [simulado]: no prueba nada del silicio. Solo que SENUS hace lo que debe
// contra el contrato.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as cripto;
import 'package:senus_app/datos/actualizacion_senew.dart';
import 'package:senus_app/datos/cliente_puente.dart';
import 'package:senus_app/datos/transporte_bl.dart';
import 'package:senus_app/mtp/canal_datos.dart';
import 'package:senus_app/mtp/codificacion.dart';
import 'package:senus_app/mtp/operaciones.dart';
import 'package:senus_app/mtp/sesion_mtp.dart';
import 'package:senus_app/mtp/transporte.dart' hide vidSenew;

const int tamNor = blMainFin - blMainIni;

/// Un main que el teléfono sabe arrancar.
class ImagenConocida {
  final int build;
  final String version;
  final bool canal;
  final bool puente;
  final String? idPuente;
  final Uint8List bytes;
  ImagenConocida(this.bytes, this.build, this.version,
      {this.canal = true, this.puente = false, this.idPuente});
}

/// Un main creíble: vectores, reset en +0xB0 y un relleno que depende del build.
Uint8List mainDePrueba(int build, {int tam = 0x4000}) {
  final b = Uint8List(tam);
  final v = ByteData.sublistView(b);
  for (var i = 0; i < 8; i++) {
    v.setUint32(i * 4, 0xE59FF018, Endian.little);
  }
  v.setUint32(0x20, blMainIni + 0xB0, Endian.little);
  for (var i = 0x40; i < tam; i++) {
    b[i] = (i * 7 + build) & 0xFF;
  }
  return b;
}

enum EstadoTel { senew, bl, colgado, apagado }

/// Un objeto del almacenamiento.
class Objeto {
  final int handle;
  final int almacen;
  final int padre; // handleRaiz si cuelga de la raíz
  final String nombre;
  final bool carpeta;
  Uint8List datos;
  Objeto(this.handle, this.almacen, this.padre, this.nombre, this.carpeta,
      this.datos);
}

/// Un ajuste del firmware simulado.
class AjSim {
  final int clave, tipo, min, max;
  Object valor;
  AjSim(this.clave, this.tipo, this.min, this.max, this.valor);
}

/// Los 26, con los rangos del firmware de hoy.
List<AjSim> ajustesDeFabrica() => [
      AjSim(0x01, 2, 0, 4, 0),
      AjSim(0x02, 1, 0, 1, false),
      AjSim(0x03, 1, 0, 1, false),
      AjSim(0x04, 2, 0, 23, 7),
      AjSim(0x05, 2, 0, 59, 0),
      AjSim(0x06, 3, -720, 840, -360),
      AjSim(0x07, 2, 10, 100, 50),
      AjSim(0x08, 2, 0, 120, 15),
      AjSim(0x09, 2, 0, 120, 30),
      AjSim(0x0A, 1, 0, 1, false),
      AjSim(0x0B, 1, 0, 1, false),
      AjSim(0x0C, 2, 0, 5, 4),
      AjSim(0x0D, 1, 0, 1, true),
      AjSim(0x0E, 1, 0, 1, true),
      AjSim(0x0F, 2, 0, 2, 0),
      AjSim(0x10, 2, 0, 4, 1),
      AjSim(0x11, 2, 0, 2, 0),
      AjSim(0x12, 2, 1, 5, 3),
      AjSim(0x13, 2, 0, 7, 0),
      AjSim(0x14, 1, 0, 1, true),
      AjSim(0x15, 2, 0, 9, 0),
      AjSim(0x16, 1, 0, 1, true),
      AjSim(0x17, 1, 0, 1, false),
      AjSim(0x18, 1, 0, 1, true),
      AjSim(0x19, 2, 0, 10, 0),
      AjSim(0x1A, 4, 0, 99, ''),
    ];

class TelefonoSimulado {
  /// El tramo del main: 9 bloques.
  final Uint8List nor = Uint8List(tamNor)..fillRange(0, tamNor, 0xFF);
  final List<ImagenConocida> imagenes = [];

  EstadoTel estado = EstadoTel.apagado;
  ImagenConocida? corriendo;
  bool bandera = false;
  int entradaBl = 0;
  bool blInstaller = false; // 1209:0003 sin main

  /// El USB está físicamente conectado.
  bool cable = true;

  /// Lo que el teléfono dice saber de sí mismo.
  String idAparato = '';
  int bateria = 80;
  bool cargando = false;
  int blVersion = 1;

  /// Respuesta de la persona en el teléfono.
  bool diceSiAlBl = true;
  bool sinRespuestaAlBl = false;
  bool permisoMtp = true;

  // ---- Lo que registra la simulación, para las comprobaciones.
  final List<int> escrituras = []; // direcciones de los WRITE
  final List<int> wipes = [];
  int salidas = 0;

  /// Arrancó con vectores válidos sobre un main que no está entero.
  bool arrancoMedioMain = false;

  // ---- Inyección de fallos.
  /// Cuenta las operaciones del BL; al llegar a [corteEn], corta.
  int operacionesBl = 0;
  int? corteEn;
  bool corteDePila = false; // true: se va la batería. false: se va el cable.
  bool corteTrasEjecutar = false; // corta justo DESPUÉS de hacer la operación

  /// Las primeras pasadas (de WIPE a WIPE) graban un bit cambiado: CRC mal.
  int pasadasMalas = 0;
  bool _pasadaMala = false;

  /// Igual, pero solo el WRITE de la región 0.
  int region0Mala = 0;

  /// Al guardar por MTP, un byte cambia.
  bool corromperAlGuardar = false;

  /// Si se pone, [corromperAlGuardar] solo toca el fichero con este nombre.
  String? corromperSolo;

  /// Corta el cable cuando, subiendo el fichero [cortarSubidaDe], han llegado
  /// [cortarTrasBytes] bytes de sus datos. Como en `api/mtp.c`, de un fichero
  /// cortado no queda nada.
  String? cortarSubidaDe;
  int cortarTrasBytes = 0;

  /// Bytes de SendObject que llegaron, para ver qué se subió de verdad.
  int bytesSubidos = 0;
  final List<String> subidos = [];
  final List<String> borrados = [];

  /// Lo que se escribió por MTP, en orden: «carpeta x», «subido x», «borrado x».
  final List<String> registro = [];

  // ---- La tarjeta: capacidad y protección (StorageInfo de `api/mtp.c`).
  int tarjetaCapacidad = 64 << 20;
  bool tarjetaSoloLectura = false;

  int get tarjetaLibre {
    var usado = 0;
    for (final o in objetos.values) {
      if (o.almacen == storageTarjeta) usado += o.datos.length;
    }
    return tarjetaCapacidad - usado < 0 ? 0 : tarjetaCapacidad - usado;
  }

  /// DeleteObject contesta bien y no borra nada.
  bool borradoSinEfecto = false;

  /// El main arrancado nunca levanta el USB.
  bool cuelgaAlArrancar = false;

  /// Al arrancar se apaga: un OK en «Encendido». Vuelve con [reconectar].
  bool seApagaAlArrancar = false;

  /// Cuántas órdenes `SEN_RELOJ` llegaron al teléfono.
  int relojesRecibidos = 0;

  /// La siguiente GetDeviceInfo corta la conexión.
  bool cortarAlLeerDeviceInfo = false;

  /// `SEN_ENTRAR_BL` contesta R_OP_NO: un sistema sin BL.
  bool sinBl = false;

  /// `SEN_ENTRAR_BL` contesta R_GENERAL.
  bool fallarEntrarBl = false;

  /// `SEN_VINCULAR` contesta R_GENERAL: el almacén falló.
  bool falloAlmacen = false;

  // ---- Bluetooth: `SEN_BT_ESTADO` y `SEN_BT_EMPAREJAR`.
  BtEstado btEstado = BtEstado(
    encendido: true,
    puenteConectado: false,
    redLista: false,
    fallo: 0,
    puenteAddr: Uint8List(6),
  );

  /// La dirección que da `SEN_INFO`; ceros = no se sabe.
  List<int> bdAddr = const [1, 2, 3, 4, 5, 6];

  /// Lo último que llegó por `SEN_BT_EMPAREJAR`, entero.
  Uint8List? emparejarRecibido;

  /// Se llama con la orden ya aceptada: lo que haría el hilo de la interfaz.
  void Function(List<int> addr, String pin)? alEmparejar;

  /// Veces que `SEN_BT_EMPAREJAR` contesta R_OCUPADO: una app en pantalla.
  int ocupadoEmparejar = 0;

  /// `SEN_BT_EMPAREJAR` contesta R_OP_NO: un senew anterior a 0.29.1.
  bool sinEmparejar = false;

  /// `SEN_INFO` devuelve basura.
  bool senInfoRoto = false;

  /// BL_R_ID falla una vez.
  bool idFalla = false;

  /// El n.º de PUT (desde 1) se queda sin estado estas veces (`bl_usb.c`).
  int? putAtascado;
  int vecesAtascado = 1;
  int puts = 0;
  Duration? plazoPut;

  /// BL_R_ID dice esta entrada, sea cual sea la real.
  int? entradaFalsa;

  /// BL_R_GET devuelve un byte cambiado.
  bool lecturaMala = false;

  /// Esta clave dice que se aplica y no se aplica.
  int? ajusteQueNoSeGuarda;

  /// Se llama al atender cada página de `SEN_APPS`.
  void Function(int desde)? alPaginar;

  // ---- Almacenamiento.
  int _sigHandle = 100;
  final Map<int, Objeto> objetos = {};
  bool hayTarjeta = false;
  final List<SenApp> appsFabrica = [];

  // ---- Ajustes.
  final List<AjSim> ajustes = ajustesDeFabrica();
  int ajustesPendientes = 0;
  int ocupadoAjustes = 0;
  int utcPuesto = 0;
  int zonaPuesta = 0;

  TelefonoSimulado() {
    crearCarpeta(storageMemoria, 'apps');
  }

  ImagenConocida anadirImagen(ImagenConocida i) {
    imagenes.add(i);
    return i;
  }

  /// Graba una imagen en la NOR y la arranca.
  void instalarYArrancar(ImagenConocida i) {
    nor.fillRange(0, tamNor, 0xFF);
    nor.setRange(0, i.bytes.length, i.bytes);
    if (!imagenes.contains(i)) imagenes.add(i);
    arrancar();
  }

  Objeto crearCarpeta(int almacen, String nombre, {int padre = handleRaiz}) {
    final o =
        Objeto(_sigHandle++, almacen, padre, nombre, true, Uint8List(0));
    objetos[o.handle] = o;
    return o;
  }

  Objeto crearFichero(int almacen, int padre, String nombre, Uint8List datos,
      {int? handle}) {
    final o = Objeto(handle ?? _sigHandle++, almacen, padre, nombre, false, datos);
    objetos[o.handle] = o;
    return o;
  }

  int nuevoHandle() => _sigHandle++;

  /// El hijo de esa carpeta con ese nombre, sin mirar mayúsculas (FAT).
  Objeto? hijo(int almacen, int padre, String nombre) {
    final n = nombre.toLowerCase();
    for (final o in objetos.values) {
      if (o.almacen == almacen && o.padre == padre && o.nombre.toLowerCase() == n) {
        return o;
      }
    }
    return null;
  }

  /// Borra un objeto y, si es carpeta, todo lo que cuelga de ella.
  void borrarRecursivo(int handle) {
    for (final h in [
      for (final o in objetos.values)
        if (o.padre == handle) o.handle
    ]) {
      borrarRecursivo(h);
    }
    final o = objetos.remove(handle);
    if (o != null) {
      borrados.add(o.nombre);
      registro.add('borrado ${o.nombre}');
    }
  }

  Objeto? carpeta(int almacen, String nombre) {
    for (final o in objetos.values) {
      if (o.almacen == almacen && o.carpeta && o.nombre == nombre) return o;
    }
    return null;
  }

  // ---- Arranque: la decisión de bl_arranque.S.

  bool get _vectores {
    final v = ByteData.sublistView(nor);
    final reset = v.getUint32(0x20, Endian.little);
    return v.getUint32(0, Endian.little) == 0xE59FF018 &&
        reset >= blMainIni &&
        reset < blMainFin;
  }

  bool get mainEntero => _imagenEnNor() != null;

  ImagenConocida? _imagenEnNor() {
    for (final i in imagenes) {
      var igual = true;
      for (var k = 0; k < i.bytes.length; k++) {
        if (nor[k] != i.bytes[k]) {
          igual = false;
          break;
        }
      }
      if (!igual) continue;
      for (var k = i.bytes.length; k < tamNor; k++) {
        if (nor[k] != 0xFF) {
          igual = false;
          break;
        }
      }
      if (igual) return i;
    }
    return null;
  }

  void arrancar() {
    if (bandera) {
      estado = EstadoTel.bl;
      entradaBl = 1;
      corriendo = null;
      return;
    }
    if (!_vectores) {
      estado = EstadoTel.bl;
      entradaBl = 2;
      corriendo = null;
      return;
    }
    final i = _imagenEnNor();
    if (i == null) {
      arrancoMedioMain = true;
      estado = EstadoTel.colgado;
      corriendo = null;
      return;
    }
    if (cuelgaAlArrancar) {
      estado = EstadoTel.colgado;
      corriendo = null;
      return;
    }
    if (seApagaAlArrancar) {
      seApagaAlArrancar = false;
      estado = EstadoTel.apagado;
      corriendo = null;
      return;
    }
    estado = EstadoTel.senew;
    corriendo = i;
  }

  void entrarAlBlPorBandera() {
    bandera = true;
    arrancar();
  }

  int get pidBl =>
      entradaBl == 2 && blInstaller ? pidBlInstaller : pidBlPropio;

  /// Vuelve el USB, y la batería si se fue.
  void reconectar() {
    cable = true;
    if (estado == EstadoTel.apagado) arrancar();
  }

  Never _corte() {
    // SALIR ya en marcha: el BL sale aunque nadie lea el RES (bl_main.c).
    if (_pendienteSalir) {
      _pendienteSalir = false;
      estado = EstadoTel.apagado;
      arrancar();
    }
    if (corteDePila) {
      cable = true;
      bandera = false;
      arrancar();
    } else {
      cable = false;
    }
    corteEn = null;
    throw TransporteError('corte simulado');
  }

  void _contarBl() {
    operacionesBl++;
    if (corteEn != null && operacionesBl == corteEn && !corteTrasEjecutar) {
      _corte();
    }
  }

  void _trasEjecutar() {
    if (corteEn != null && operacionesBl == corteEn && corteTrasEjecutar) {
      _corte();
    }
  }

  // ---- El BL (bl_main.c, bl_nor.c, bl_usb.c).
  final Uint8List _buf = Uint8List(blBufTam);
  final List<int> _arg = [0, 0, 0, 0];
  int _opSeq = 0, _opCodigo = 0, _opR0 = 0;

  void blControlOut(int req, int val, int idx, Uint8List d) {
    if (estado != EstadoTel.bl || !cable) {
      throw TransporteError('BL ausente');
    }
    if (req == blRPut) {
      puts++;
      if (puts == putAtascado && vecesAtascado > 0) {
        vecesAtascado--;
        puts--; // la repetición es el mismo PUT
        throw TransporteError('PUT sin estado: plazo agotado');
      }
      if (val + d.length > blBufTam) throw TransporteError('STALL PUT');
      _buf.setRange(val, val + d.length, d);
      return;
    }
    if (req >= blRArg0 && req <= blRArg3) {
      _arg[req - blRArg0] = (val & 0xFFFF) | ((idx & 0xFFFF) << 16);
      return;
    }
    if (req == blRGo) {
      _contarBl();
      _opSeq = (val >> 8) & 0xFF;
      _ejecutar(val & 0xFF);
      _trasEjecutar();
      return;
    }
    throw TransporteError('STALL req 0x${req.toRadixString(16)}');
  }

  void _ejecutar(int op) {
    _opCodigo = 0;
    _opR0 = 0;
    switch (op) {
      case blOpNada:
        return;
      case blOpWipe:
        _pasadaMala = pasadasMalas > 0;
        if (_pasadaMala) pasadasMalas--;
        for (var b = 0; b < tamNor ~/ blBloque; b++) {
          wipes.add(b);
          nor.fillRange(b * blBloque, (b + 1) * blBloque, 0xFF);
          if (corteEn != null &&
              corteEnBloque == b &&
              operacionesBl == corteEn) {
            corteEnBloque = null;
            _corte();
          }
        }
        _opR0 = 9;
        return;
      case blOpWrite:
        final dir = _arg[0], n = _arg[1];
        if ((dir & (blRegion - 1)) != 0 ||
            (n & (blRegion - 1)) != 0 ||
            n == 0 ||
            n > blBufTam) {
          _opCodigo = -2;
          return;
        }
        if (dir < blMainIni || dir + n > blMainFin) {
          _opCodigo = -3;
          return;
        }
        final off = dir - blMainIni;
        for (var r = 0; r < n; r += blRegion) {
          for (var k = 0; k < blRegion; k++) {
            if (nor[off + r + k] != 0xFF) {
              _opCodigo = -4; // BL_E_NO_BLANCO
              _opR0 = dir + r;
              return;
            }
          }
        }
        escrituras.add(dir);
        nor.setRange(off, off + n, _buf);
        if (_pasadaMala) nor[off + 8] ^= 0x10;
        if (dir == blMainIni && region0Mala > 0) {
          region0Mala--;
          nor[0x100] ^= 0x10;
        }
        _opR0 = crc32DeDatos(Uint8List.sublistView(nor, off, off + n));
        return;
      case blOpCrc:
        final dir = _arg[0], n = _arg[1];
        final off = dir - blMainIni;
        _opR0 = crc32DeDatos(Uint8List.sublistView(nor, off, off + n));
        return;
      case blOpSalir:
        salidas++;
        bandera = false;
        _pendienteSalir = true;
        return;
      default:
        _opCodigo = -1;
    }
  }

  bool _pendienteSalir = false;
  int? corteEnBloque;

  Uint8List blControlIn(int req, int val, int idx, int n) {
    if (estado != EstadoTel.bl || !cable) {
      throw TransporteError('BL ausente');
    }
    switch (req) {
      case blRId:
        if (idFalla) {
          idFalla = false;
          cable = false;
          throw TransporteError('corte simulado');
        }
        final b = ByteData(64);
        for (var i = 0; i < 4; i++) {
          b.setUint8(i, 'SNBL'.codeUnitAt(i));
        }
        b.setUint16(4, blVersion, Endian.little);
        b.setUint16(6, entradaFalsa ?? entradaBl, Endian.little);
        return b.buffer.asUint8List().sublist(0, n);
      case blRRes:
        final b = ByteData(32);
        b.setUint8(0, blStHecho);
        b.setUint8(1, _opSeq);
        b.setInt32(4, _opCodigo, Endian.little);
        b.setUint32(8, _opR0, Endian.little);
        final r = b.buffer.asUint8List().sublist(0, n);
        // bl_main.c contesta y SOLO DESPUÉS sale.
        if (_pendienteSalir) {
          _pendienteSalir = false;
          estado = EstadoTel.apagado;
          arrancar();
        }
        return r;
      case blRGet:
        if (n > 64) throw TransporteError('STALL GET');
        final dir = val | (idx << 16);
        final off = dir - blMainIni;
        if (off < 0 || off + n > tamNor) throw TransporteError('STALL GET');
        final r = Uint8List.fromList(nor.sublist(off, off + n));
        if (lecturaMala) r[0] ^= 1;
        return r;
      default:
        throw TransporteError('STALL req 0x${req.toRadixString(16)}');
    }
  }

  // ---- El puente: solo si la imagen lo lleva.
  final List<int> _puArg = List<int>.filled(6, 0);
  int _puSeq = 0, _puEstado = 0;
  bool vetoCarga = false, cargaFuera = false;
  DateTime? banderaPuestaEn;
  final List<String> puenteOrdenes = [];

  Uint8List puControlIn(int req, int val, int idx, int n) {
    final img = corriendo;
    if (estado != EstadoTel.senew || !cable) throw TransporteError('sin senew');
    if (img == null || !img.puente) throw TransporteError('STALL');
    switch (req) {
      case puRId:
        final b = Uint8List(60);
        b.setRange(0, 4, ascii.encode('PUEN'));
        b.setRange(32, 32 + img.idPuente!.length, latin1.encode(img.idPuente!));
        return b;
      case puRRes:
        final b = ByteData(48);
        b.setUint8(0, _puEstado);
        b.setUint8(1, _puSeq);
        return b.buffer.asUint8List();
      default:
        throw TransporteError('STALL');
    }
  }

  void puControlOut(int req, int val, int idx, Uint8List d) {
    final img = corriendo;
    if (estado != EstadoTel.senew || !cable) throw TransporteError('sin senew');
    if (img == null || !img.puente) throw TransporteError('STALL');
    if (req >= puRArg0 && req < puRArg0 + 6) {
      _puArg[req - puRArg0] = (val & 0xFFFF) | ((idx & 0xFFFF) << 16);
      return;
    }
    if (req != puRGo) throw TransporteError('STALL');
    final op = val & 0xFF;
    _puSeq = (val >> 8) & 0xFF;
    _puEstado = puStHecho;
    final e = entradaPuente(img.idPuente!);
    if (op == puOpPoke) {
      final dir = _puArg[0];
      puenteOrdenes.add('poke ${dir.toRadixString(16)}');
      if (dir == e?.cargaVeto) vetoCarga = true;
      if (dir == blBandera) banderaPuestaEn = DateTime.now();
      if (dir == blBandera &&
          _puArg[1] == (4 | (2 << 8)) &&
          _puArg[2] == blMagia &&
          _puArg[3] == (~blMagia & 0xFFFFFFFF)) {
        bandera = true;
      }
      return;
    }
    if (op == puOpLlamar) {
      final fn = _puArg[0];
      puenteOrdenes.add('llamar ${fn.toRadixString(16)}');
      if (fn == e?.hwCargaFuera) cargaFuera = true;
      if (fn == e?.reinicioCaliente) {
        if (!bandera) throw StateError('reinicio_caliente sin la bandera');
        arrancar();
        throw TransporteError('el USB se fue');
      }
      return;
    }
    throw TransporteError('orden de puente no permitida: $op');
  }

  // ---- MTP.
  bool sesionAbierta = false;

  List<int> get _ops => [
        opDeviceInfo, opOpenSession, opCloseSession, opStorageIds,
        opStorageInfo, opObjectHandles, opObjectInfo, opGetObject,
        opDeleteObject, opSendObjectInfo, opSendObject, opDevPropValue,
        opGetPartialObject,
        if (corriendo?.canal ?? false) ...[
          opSenInfo, opSenAjLeer, opSenAjPoner, opSenReloj, opSenVincular,
          opSenEntrarBl, opSenBtEstado, opSenBtEmparejar, opSenApps,
        ],
      ];

  Uint8List deviceInfo() {
    final b = BytesBuilder();
    void u16(int v) => b.add((ByteData(2)..setUint16(0, v, Endian.little))
        .buffer
        .asUint8List());
    void u32(int v) => b.add((ByteData(4)..setUint32(0, v, Endian.little))
        .buffer
        .asUint8List());
    void arr(List<int> l) {
      u32(l.length);
      l.forEach(u16);
    }

    u16(100);
    u32(6);
    u16(100);
    b.add(cadenaMtp(''));
    u16(0);
    arr(_ops);
    arr(const []);
    arr(const [dpNombreAmigo]);
    arr(const []);
    arr(const []);
    b.add(cadenaMtp('Semakers'));
    b.add(cadenaMtp('W580'));
    final img = corriendo!;
    b.add(cadenaMtp(img.canal ? '${img.version}+${img.build}' : 'S10'));
    b.add(cadenaMtp('W580S10000001'));
    return b.toBytes();
  }

  SenInfo senInfo() {
    final img = corriendo!;
    return SenInfo(
      build: img.build,
      apiMayor: 1,
      apiMenor: 11,
      blVersion: blVersion,
      bateriaPct: bateria,
      banderas: (hayTarjeta ? 1 : 0) |
          (cargando ? 2 : 0) |
          (img.puente ? 4 : 0) |
          (idAparato.isNotEmpty ? 0x10 : 0),
      bdAddr: Uint8List.fromList(bdAddr),
      version: img.version,
      modelo: 'w580',
      soc: 'DB2020',
      compilacion: 'Oct 31 2026 23:50:01',
      idAparato: idAparato,
      ajustesVersion: 9,
    );
  }

  /// Todas las apps, como las recorre el firmware.
  List<SenApp> senApps() {
    SenApp? deFichero(Objeto o, int origen) {
      final d = o.datos;
      // Solo entra lo que tiene la cabecera bien (§6 del contrato).
      if (d.length < 128 || d[0] != 0x57) return null;
      final v = ByteData.sublistView(d);
      final filas = [
        for (var i = 0; i < 12; i++) v.getUint16(58 + i * 2, Endian.little)
      ];
      final fin = d.sublist(82, 112).indexOf(0);
      return SenApp(
        origen: origen,
        banderas: 0,
        perfil: d[7],
        iconoGen: d[56],
        iconoAn: d[57],
        apiMayor: v.getUint16(8, Endian.little),
        apiMenor: v.getUint16(10, Endian.little),
        verApp: v.getUint32(52, Endian.little),
        tam: d.length,
        iconoFilas: filas,
        nombre: utf8.decode(d.sublist(82, 82 + (fin < 0 ? 30 : fin))),
        fichero: o.nombre,
      );
    }

    // El orden y el bit de tapada de `ap_uno` (shell/gestion_sis.c): /apps,
    // /tarjeta/apps, Memoria, /tarjeta/juegos; una copia nueva en la Memoria tapa
    // a la de fábrica, una copia de fábrica en la tarjeta no vale, y si dos se
    // llaman igual, sale la primera.
    final out = <SenApp>[];
    final mem = carpeta(storageMemoria, 'apps');
    final enMemoria = <String>{
      for (final o in objetos.values)
        if (o.padre == mem?.handle && !o.carpeta) o.nombre
    };
    final deFabrica = {for (final f in appsFabrica) f.fichero};
    void poner(SenApp a, {bool tapa = false}) {
      final repetida =
          out.any((x) => !x.tapada && x.nombre == a.nombre);
      out.add(SenApp(
        origen: a.origen,
        banderas: a.banderas | (tapa || repetida ? 2 : 0),
        perfil: a.perfil,
        iconoGen: a.iconoGen,
        iconoAn: a.iconoAn,
        apiMayor: a.apiMayor,
        apiMenor: a.apiMenor,
        verApp: a.verApp,
        tam: a.tam,
        iconoFilas: a.iconoFilas,
        nombre: a.nombre,
        fichero: a.fichero,
      ));
    }

    for (final f in appsFabrica) {
      poner(
          SenApp(
            origen: 0,
            banderas: 1,
            perfil: f.perfil,
            iconoGen: f.iconoGen,
            iconoAn: f.iconoAn,
            apiMayor: f.apiMayor,
            apiMenor: f.apiMenor,
            verApp: f.verApp,
            tam: f.tam,
            iconoFilas: f.iconoFilas,
            nombre: f.nombre,
            fichero: f.fichero,
          ),
          tapa: enMemoria.contains(f.fichero));
    }
    // FAT no distingue mayúsculas: «/tarjeta/juegos» abre también «JUEGOS».
    final ta = hayTarjeta ? hijo(storageTarjeta, handleRaiz, 'apps') : null;
    final tj = hayTarjeta ? hijo(storageTarjeta, handleRaiz, 'juegos') : null;
    void recorrer(int? padre, int origen, {bool copiaFabrica = false}) {
      if (padre == null) return;
      for (final o in objetos.values) {
        if (o.padre != padre || o.carpeta) continue;
        final a = deFichero(o, origen);
        if (a != null) {
          poner(a, tapa: copiaFabrica && deFabrica.contains(o.nombre));
        }
      }
    }

    recorrer(ta?.handle, 2, copiaFabrica: true);
    recorrer(mem?.handle, 1);
    recorrer(tj?.handle, 3);
    return out.length > 64 ? out.sublist(0, 64) : out;
  }

  (int, int, int) ponerAjustes(Uint8List d) {
    final v = ByteData.sublistView(d);
    if (d.length < 4 || v.getUint16(0, Endian.little) != 1) {
      return (-1, 0, 0);
    }
    final n = v.getUint16(2, Endian.little);
    // Primero se valida el dataset entero: truncado, no se aplica nada.
    var off = 4;
    for (var i = 0; i < n; i++) {
      if (off + 4 > d.length) return (-1, 0, 0);
      final l = d[off + 3];
      if (off + 4 + l > d.length) return (-1, 0, 0);
      off += 4 + l;
    }
    if (off != d.length) return (-1, 0, 0); // bytes de más
    if (ocupadoAjustes > 0) {
      ocupadoAjustes--;
      return (-2, 0, 0);
    }
    var aplicadas = 0, fuera = 0, desconocidas = 0;
    off = 4;
    for (var i = 0; i < n; i++) {
      final clave = v.getUint16(off, Endian.little);
      final tipo = d[off + 2], l = d[off + 3];
      final val = Uint8List.sublistView(d, off + 4, off + 4 + l);
      off += 4 + l;
      AjSim? a;
      for (final x in ajustes) {
        if (x.clave == clave) a = x;
      }
      if (a == null) {
        desconocidas++;
        continue;
      }
      if (a.tipo != tipo) {
        fuera++;
        continue;
      }
      if (clave == ajusteQueNoSeGuarda) {
        aplicadas++;
        continue;
      }
      if (tipo == tipoAjTexto) {
        if (l > a.max) {
          fuera++;
          continue;
        }
        a.valor = utf8.decode(val);
      } else if (tipo == tipoAjBool) {
        a.valor = val[0] != 0;
      } else {
        final x = tipo == tipoAjI16
            ? ByteData.sublistView(val).getInt16(0, Endian.little)
            : val[0];
        if (x < a.min || x > a.max) {
          fuera++;
          continue;
        }
        a.valor = x;
      }
      aplicadas++;
    }
    // Como al cargar: atenuar_s ≤ apagar_s.
    final at = ajustes.firstWhere((x) => x.clave == 0x08);
    final ap = ajustes.firstWhere((x) => x.clave == 0x09);
    if ((ap.valor as int) != 0 && (at.valor as int) > (ap.valor as int)) {
      at.valor = ap.valor;
    }
    ocupadoAjustes = ajustesPendientes;
    return (aplicadas, fuera, desconocidas);
  }
}

/// Transporte MTP contra el teléfono simulado: atiende cada contenedor.
class TransporteMtpSimulado implements TransporteMtp {
  final TelefonoSimulado tel;
  TransporteMtpSimulado(this.tel);

  final List<Uint8List> _salida = [];
  int _ocupadoBl = 0;
  Contenedor? _ordenConDatos;
  Objeto? _pendiente;
  bool _abierto = false;

  /// Un contenedor de datos puede llegar en varios bulk OUT: se junta por la
  /// longitud de su cabecera, como hace el teléfono.
  BytesBuilder? _rx;
  int _rxLargo = 0;

  /// Cuántas veces se contestó R_OCUPADO a OpenSession.
  int ocupadosAbrir = 0;

  void _exigir() {
    if (!_abierto || !tel.cable || tel.estado != EstadoTel.senew) {
      throw TransporteError('el teléfono no está');
    }
  }

  @override
  String get nombre => 'simulado';
  @override
  int get mps => 64;
  @override
  Future<List<DispositivoVisto>> enumerar() async =>
      tel.estado == EstadoTel.senew && tel.cable
          ? [DispositivoVisto(id: 0, vid: 0x1209, pid: 1, bcdDevice: 0x19)]
          : [];
  @override
  Future<void> abrir(DispositivoVisto d) async {
    _abierto = true;
    _exigir();
  }

  @override
  Future<void> cerrar() async {
    _abierto = false;
    if (_tras != null) {
      final f = _tras!;
      _tras = null;
      f();
    }
  }

  void Function()? _tras;

  void _resp(int tx, int cod, [List<int> p = const []]) {
    final b = BytesBuilder();
    final cab = ByteData(12 + p.length * 4)
      ..setUint32(0, 12 + p.length * 4, Endian.little)
      ..setUint16(4, tipoResp, Endian.little)
      ..setUint16(6, cod, Endian.little)
      ..setUint32(8, tx, Endian.little);
    for (var i = 0; i < p.length; i++) {
      cab.setUint32(12 + i * 4, p[i], Endian.little);
    }
    b.add(cab.buffer.asUint8List());
    _salida.add(b.toBytes());
  }

  void _datos(int tx, int op, Uint8List d) {
    _salida.add(Contenedor(
            tipo: tipoDatos, codigo: op, idTransaccion: tx, datos: d)
        .empaquetar());
  }

  @override
  Future<int> bulkOut(Uint8List datos,
      {Duration timeout = const Duration(seconds: 5)}) async {
    _exigir();
    if (datos.isEmpty) return 0; // ZLP
    final rx = _rx;
    if (rx != null) {
      rx.add(Uint8List.fromList(datos));
      _exigirPaquetesEnteros(datos.length, rx.length);
      _cortarSiToca(rx.length);
      if (rx.length >= _rxLargo) _datosCompletos();
      return datos.length;
    }
    final bd = ByteData.sublistView(datos);
    final tipo = bd.getUint16(4, Endian.little);
    final cod = bd.getUint16(6, Endian.little);
    final tx = bd.getUint32(8, Endian.little);
    if (tipo == tipoOrden) {
      final c = Contenedor.desempaquetarCabecera(datos);
      if (cod == opSendObjectInfo ||
          cod == opSendObject ||
          cod == opSenAjPoner ||
          cod == opSenReloj ||
          cod == opSenVincular ||
          cod == opSenBtEmparejar) {
        _ordenConDatos = c;
        return datos.length;
      }
      _atender(c, tx);
    } else if (tipo == tipoDatos) {
      _rxLargo = bd.getUint32(0, Endian.little);
      _rx = BytesBuilder()..add(Uint8List.fromList(datos));
      _exigirPaquetesEnteros(datos.length, datos.length);
      _cortarSiToca(datos.length);
      if (datos.length >= _rxLargo) _datosCompletos();
    }
    return datos.length;
  }

  void _datosCompletos() {
    final todo = _rx!.takeBytes();
    _rx = null;
    final c = _ordenConDatos!;
    _ordenConDatos = null;
    final tx = ByteData.sublistView(todo).getUint32(8, Endian.little);
    _atenderDatos(c, tx, Uint8List.sublistView(todo, 12, _rxLargo));
  }

  /// Un bulk OUT que no es múltiplo del paquete acaba en uno corto, y en USB
  /// eso cierra la transferencia: a mitad de un contenedor, el teléfono lo
  /// vería partido. Solo el último trozo puede serlo.
  void _exigirPaquetesEnteros(int trozo, int llegados) {
    if (trozo % mps != 0 && llegados < _rxLargo) {
      _rx = null;
      _ordenConDatos = null;
      throw TransporteError(
          'paquete corto a mitad de un contenedor ($trozo B, van $llegados de $_rxLargo)');
    }
  }

  /// El cable se va a mitad de los datos de un fichero.
  void _cortarSiToca(int llegados) {
    final q = _pendiente, nombre = tel.cortarSubidaDe;
    if (q == null || nombre == null) return;
    if (_ordenConDatos?.codigo != opSendObject) return;
    if (q.nombre.toLowerCase() != nombre.toLowerCase()) return;
    if (llegados - 12 < tel.cortarTrasBytes) return;
    tel.cortarSubidaDe = null;
    tel.cable = false;
    _rx = null;
    _ordenConDatos = null;
    _pendiente = null;
    throw TransporteError('corte simulado a mitad de $nombre');
  }

  @override
  Future<Uint8List> bulkIn(int maxLen,
      {Duration timeout = const Duration(seconds: 5)}) async {
    _exigir();
    if (_salida.isEmpty) throw TransporteError('timeout: nada que leer');
    final s = _salida.first;
    if (s.length <= maxLen) {
      _salida.removeAt(0);
      return s;
    }
    final r = s.sublist(0, maxLen);
    _salida[0] = s.sublist(maxLen);
    return r;
  }

  void _atender(Contenedor c, int tx) {
    final t = tel;
    final p = c.parametros;
    int par(int i) => i < p.length ? p[i] : 0;
    // Cualquier otra orden entre SendObjectInfo y SendObject tira lo pendiente.
    if (c.codigo != opSendObject) _pendiente = null;
    if (c.codigo == opOpenSession) {
      if (!t.permisoMtp) {
        ocupadosAbrir++;
        return _resp(tx, rDenegado);
      }
      t.sesionAbierta = true;
      return _resp(tx, rOk);
    }
    if (c.codigo == opDeviceInfo) {
      if (t.cortarAlLeerDeviceInfo) {
        t.cortarAlLeerDeviceInfo = false;
        t.cable = false;
        throw TransporteError('corte simulado');
      }
      _datos(tx, c.codigo, t.deviceInfo());
      return _resp(tx, rOk);
    }
    if (c.codigo == opCloseSession) {
      t.sesionAbierta = false;
      return _resp(tx, rOk);
    }
    if (!t.sesionAbierta) return _resp(tx, rSinSesion);
    switch (c.codigo) {
      case opDevPropValue:
        _datos(tx, c.codigo, cadenaMtp('W580 sistema propio'));
        return _resp(tx, rOk);
      case opStorageIds:
        final ids = [storageMemoria, if (t.hayTarjeta) storageTarjeta];
        final d = ByteData(4 + ids.length * 4)
          ..setUint32(0, ids.length, Endian.little);
        for (var i = 0; i < ids.length; i++) {
          d.setUint32(4 + i * 4, ids[i], Endian.little);
        }
        _datos(tx, c.codigo, d.buffer.asUint8List());
        return _resp(tx, rOk);
      case opStorageInfo:
        final d = BytesBuilder();
        if (par(0) == storageTarjeta) {
          if (!t.hayTarjeta) return _resp(tx, rStorageMal);
          final f = ByteData(26)
            ..setUint16(0, 4, Endian.little)
            ..setUint16(4, t.tarjetaSoloLectura ? 1 : 0, Endian.little)
            ..setUint64(6, t.tarjetaCapacidad, Endian.little)
            ..setUint64(14, t.tarjetaSoloLectura ? 0 : t.tarjetaLibre, Endian.little);
          d.add(f.buffer.asUint8List());
          d.add(cadenaMtp('Tarjeta'));
          _datos(tx, c.codigo, d.toBytes());
          return _resp(tx, rOk);
        }
        final f = ByteData(26)
          ..setUint16(0, 3, Endian.little)
          ..setUint64(6, 8 << 20, Endian.little)
          ..setUint64(14, 4 << 20, Endian.little);
        d.add(f.buffer.asUint8List());
        d.add(cadenaMtp('Memoria'));
        _datos(tx, c.codigo, d.toBytes());
        return _resp(tx, rOk);
      case opObjectHandles:
        final alm = par(0), padre = par(2);
        // Padre 0: TODOS los de ese almacén (PTP §10.5.6).
        final hs = t.objetos.values
            .where((o) => o.almacen == alm && (padre == 0 || o.padre == padre))
            .map((o) => o.handle)
            .toList();
        final d = ByteData(4 + hs.length * 4)
          ..setUint32(0, hs.length, Endian.little);
        for (var i = 0; i < hs.length; i++) {
          d.setUint32(4 + i * 4, hs[i], Endian.little);
        }
        _datos(tx, c.codigo, d.buffer.asUint8List());
        return _resp(tx, rOk);
      case opObjectInfo:
        final o = t.objetos[par(0)];
        if (o == null) return _resp(tx, rHandleMal);
        final f = ByteData(52)
          ..setUint32(0, o.almacen, Endian.little)
          ..setUint16(4, o.carpeta ? fmtCarpeta : fmtIndef, Endian.little)
          ..setUint32(8, o.datos.length, Endian.little)
          ..setUint32(36, o.padre, Endian.little);
        final b = BytesBuilder()
          ..add(f.buffer.asUint8List())
          ..add(cadenaMtp(o.nombre))
          ..add(cadenaMtp(''))
          ..add(cadenaMtp('20261031T120000'))
          ..addByte(0);
        _datos(tx, c.codigo, b.toBytes());
        return _resp(tx, rOk);
      case opGetObject:
        final o = t.objetos[par(0)];
        if (o == null) return _resp(tx, rHandleMal);
        _datos(tx, c.codigo, o.datos);
        return _resp(tx, rOk);
      case opGetPartialObject:
        final o = t.objetos[par(0)];
        if (o == null) return _resp(tx, rHandleMal);
        final de = par(1), n = par(2);
        final fin = de + n > o.datos.length ? o.datos.length : de + n;
        _datos(tx, c.codigo, o.datos.sublist(de, fin));
        return _resp(tx, rOk);
      case opDeleteObject:
        final o = t.objetos[par(0)];
        if (o == null) return _resp(tx, rHandleMal);
        if (o.almacen == storageMemoria &&
            o.carpeta &&
            o.padre == handleRaiz &&
            o.nombre == 'apps') {
          return _resp(tx, rProtegido);
        }
        if (o.almacen == storageTarjeta && t.tarjetaSoloLectura) {
          return _resp(tx, rSoloLectura);
        }
        // Como `borrar_paso` de api/mtp.c: una carpeta, con todo lo de dentro.
        if (!t.borradoSinEfecto) t.borrarRecursivo(o.handle);
        return _resp(tx, rOk);
      case opSenInfo:
        if (!(t.corriendo?.canal ?? false)) return _resp(tx, rOpNo);
        _datos(tx, c.codigo, t.senInfoRoto ? Uint8List(9) : t.senInfo().aBytes());
        return _resp(tx, rOk);
      case opSenAjLeer:
        if (t.ocupadoAjustes > 0) {
          t.ocupadoAjustes--;
          return _resp(tx, rOcupado);
        }
        _datos(
            tx,
            c.codigo,
            empaquetarAjustesLeidos([
              for (final a in t.ajustes)
                AjusteLeido(
                    clave: a.clave,
                    tipo: a.tipo,
                    min: a.min,
                    max: a.max,
                    valor: a.valor)
            ]));
        return _resp(tx, rOk);
      case opSenApps:
        t.alPaginar?.call(par(0));
        final todas = t.senApps();
        final de = par(0);
        final hasta = de + 7 > todas.length ? todas.length : de + 7;
        final b = BytesBuilder();
        final cab = ByteData(8)
          ..setUint16(0, 1, Endian.little)
          ..setUint16(2, todas.length, Endian.little)
          ..setUint16(4, hasta - de, Endian.little)
          ..setUint16(6, 128, Endian.little);
        b.add(cab.buffer.asUint8List());
        for (var i = de; i < hasta; i++) {
          b.add(todas[i].aBytes());
        }
        _datos(tx, c.codigo, b.toBytes());
        return _resp(tx, rOk);
      case opSenBtEstado:
        _datos(tx, c.codigo, t.btEstado.aBytes());
        return _resp(tx, rOk);
      case opSenEntrarBl:
        if (t.sinBl) return _resp(tx, rOpNo);
        if (t.fallarEntrarBl) return _resp(tx, rGeneral);
        if (t.ocupadoAjustes > 0) {
          t.ocupadoAjustes--;
          return _resp(tx, rOcupado);
        }
        if (t.sinRespuestaAlBl) return _resp(tx, rOcupado);
        if (_ocupadoBl == 0) {
          _ocupadoBl = 1;
          return _resp(tx, rOcupado);
        }
        _ocupadoBl = 0;
        if (!t.diceSiAlBl) return _resp(tx, rDenegado);
        _resp(tx, rOk);
        // Al menos 150 ms después, y solo cuando el host soltó el USB.
        _tras = () {
          t.sesionAbierta = false;
          t.entrarAlBlPorBandera();
        };
        return;
      default:
        return _resp(tx, rOpNo);
    }
  }

  void _atenderDatos(Contenedor c, int tx, Uint8List d) {
    final t = tel;
    switch (c.codigo) {
      case opSendObjectInfo:
        final bd = ByteData.sublistView(d);
        final fmt = bd.getUint16(4, Endian.little);
        final tam = bd.getUint32(8, Endian.little);
        final (nombre, _) = leerCadenaMtp(d, 52);
        final alm = c.parametros[0], padre = c.parametros[1];
        final tj = alm == storageTarjeta;
        if (tj && !t.hayTarjeta) return _resp(tx, rStorageMal);
        if (tj && t.tarjetaSoloLectura) return _resp(tx, rSoloLectura);
        // En la Memoria, un fichero en la raíz no lo ve el teléfono.
        if (!tj && padre == handleRaiz && fmt != fmtCarpeta) {
          return _resp(tx, rGeneral);
        }
        if (padre != handleRaiz) {
          final pa = t.objetos[padre];
          if (pa == null || !pa.carpeta || pa.almacen != alm) {
            return _resp(tx, 0x201A); // R_PADRE_MAL
          }
        }
        final ya = t.hijo(alm, padre, nombre);
        if (fmt == fmtCarpeta) {
          if (ya != null) return _resp(tx, rGeneral); // ya hay algo así
          final o = t.crearCarpeta(alm, nombre, padre: padre);
          t.registro.add('carpeta $nombre');
          return _resp(tx, rOk, [alm, padre, o.handle]);
        }
        if (ya != null && ya.carpeta) return _resp(tx, rDenegado);
        if (tj && tam > t.tarjetaLibre) return _resp(tx, rLlena);
        // MTP pisa de forma atómica: la copia vieja vale hasta el final.
        final h = ya?.handle ?? t.nuevoHandle();
        _pendiente = Objeto(h, alm, padre, nombre, false, Uint8List(tam));
        return _resp(tx, rOk, [alm, padre, h]);
      case opSendObject:
        final q = _pendiente;
        if (q == null) return _resp(tx, rGeneral);
        _pendiente = null;
        t.bytesSubidos += d.length;
        if (d.length != q.datos.length) return _resp(tx, 0x2007); // R_INCOMPLETA
        final datos = Uint8List.fromList(d);
        final corromper = t.corromperAlGuardar &&
            (t.corromperSolo == null ||
                t.corromperSolo!.toLowerCase() == q.nombre.toLowerCase());
        if (corromper && datos.isNotEmpty) {
          datos[datos.length ~/ 2] ^= 0xFF;
        }
        final ya = t.hijo(q.almacen, q.padre, q.nombre);
        if (ya != null) t.objetos.remove(ya.handle);
        t.crearFichero(q.almacen, q.padre, q.nombre, datos, handle: q.handle);
        t.subidos.add(q.nombre);
        t.registro.add('subido ${q.nombre}');
        return _resp(tx, rOk);
      case opSenAjPoner:
        final (a, f, u) = t.ponerAjustes(d);
        if (a == -2) return _resp(tx, rOcupado);
        if (a < 0) return _resp(tx, rParamMal);
        return _resp(tx, rOk, [a, f, u]);
      case opSenReloj:
        t.relojesRecibidos++;
        final v = ByteData.sublistView(d);
        if (d.length != 8) return _resp(tx, rParamMal);
        final utc = v.getUint32(0, Endian.little);
        final zona = v.getInt16(4, Endian.little);
        final anio = DateTime.fromMillisecondsSinceEpoch(utc * 1000, isUtc: true).year;
        if (anio < 2000 || anio > 2099 || zona < -720 || zona > 840) {
          return _resp(tx, rParamMal);
        }
        if (t.ocupadoAjustes > 0) {
          t.ocupadoAjustes--;
          return _resp(tx, rOcupado);
        }
        t.utcPuesto = utc;
        t.zonaPuesta = zona;
        return _resp(tx, rOk);
      case opSenVincular:
        if (d.length != 16) return _resp(tx, rParamMal);
        final fin = d.indexOf(0);
        final id = ascii.decode(d.sublist(0, fin < 0 ? d.length : fin));
        if (!idVincularValido(id)) return _resp(tx, rParamMal);
        if (fin >= 0 && d.sublist(fin).any((b) => b != 0)) {
          return _resp(tx, rParamMal);
        }
        if (t.falloAlmacen) return _resp(tx, rGeneral);
        t.idAparato = id;
        return _resp(tx, rOk);
      case opSenBtEmparejar:
        if (t.sinEmparejar) return _resp(tx, rOpNo);
        final n = d.length == 24 ? d[6] : 0;
        if (n < 1 || n > 16 || d[23] != 0) return _resp(tx, rParamMal);
        if (d.sublist(7 + n, 23).any((b) => b != 0)) {
          return _resp(tx, rParamMal);
        }
        if (t.ocupadoEmparejar > 0) {
          t.ocupadoEmparejar--;
          return _resp(tx, rOcupado);
        }
        t.emparejarRecibido = Uint8List.fromList(d);
        _resp(tx, rOk);
        t.alEmparejar?.call(d.sublist(0, 6), ascii.decode(d.sublist(7, 7 + n)));
        return;
      default:
        return _resp(tx, rOpNo);
    }
  }
}

/// EP0 del BL.
class TransporteBlSimulado implements TransporteBl {
  final TelefonoSimulado tel;
  TransporteBlSimulado(this.tel);
  @override
  String get nombre => 'BL simulado';
  @override
  int get vidFiltro => vidSenew;
  @override
  int get pidFiltro => tel.pidBl;
  @override
  Future<List<DispositivoVisto>> enumerar() async => const [];
  @override
  Future<void> abrir(DispositivoVisto d) async {}
  @override
  Future<void> cerrar() async {}
  @override
  Future<void> controlOut(int bRequest, int wValue, int wIndex, Uint8List data,
      {Duration timeout = const Duration(seconds: 30)}) async {
    if (bRequest == blRPut) tel.plazoPut = timeout;
    tel.blControlOut(bRequest, wValue, wIndex, data);
  }
  @override
  Future<Uint8List> controlIn(int bRequest, int wValue, int wIndex, int wLength,
          {Duration timeout = const Duration(seconds: 30)}) async =>
      tel.blControlIn(bRequest, wValue, wIndex, wLength);
}

/// EP0 de senew en marcha: el puente.
class TransporteEp0Simulado implements TransporteBl {
  final TelefonoSimulado tel;
  TransporteEp0Simulado(this.tel);
  @override
  String get nombre => 'EP0 senew simulado';
  @override
  int get vidFiltro => vidSenew;
  @override
  int get pidFiltro => pidSenewNormal;
  @override
  Future<List<DispositivoVisto>> enumerar() async => const [];
  @override
  Future<void> abrir(DispositivoVisto d) async {}
  @override
  Future<void> cerrar() async {}
  @override
  Future<void> controlOut(int bRequest, int wValue, int wIndex, Uint8List data,
          {Duration timeout = const Duration(seconds: 30)}) async =>
      tel.puControlOut(bRequest, wValue, wIndex, data);
  @override
  Future<Uint8List> controlIn(int bRequest, int wValue, int wIndex, int wLength,
          {Duration timeout = const Duration(seconds: 30)}) async =>
      tel.puControlIn(bRequest, wValue, wIndex, wLength);
}

/// Los puertos contra el teléfono simulado: sin esperas de verdad.
class PuertosSimulados implements PuertosUsb {
  final TelefonoSimulado tel;
  PuertosSimulados(this.tel);

  /// Se llama al empezar a esperar a senew.
  Future<void> Function()? alEsperarSenew;

  /// Se llama tras abrir una sesión en [esperarSenew].
  void Function()? alConectar;

  /// Abre una sesión como haría la pantalla de conexión.
  Future<SesionMtp> conectar() async {
    final t = TransporteMtpSimulado(tel);
    await t.abrir((await t.enumerar()).first);
    final s = SesionMtp(t);
    final r = await s.abrir();
    if (!r.bien) throw StateError('no abrió: ${r.mensaje}');
    return s;
  }

  @override
  Future<SesionMtp?> esperarSenew(Duration plazo) async {
    await alEsperarSenew?.call();
    if (tel.estado != EstadoTel.senew || !tel.cable) return null;
    final s = await conectar();
    alConectar?.call();
    return s;
  }

  @override
  Future<TransporteBl?> esperarBl(Duration plazo) async =>
      tel.estado == EstadoTel.bl && tel.cable
          ? TransporteBlSimulado(tel)
          : null;

  @override
  Future<TransporteBl?> abrirEp0Senew(Duration plazo) async =>
      tel.estado == EstadoTel.senew && tel.cable
          ? TransporteEp0Simulado(tel)
          : null;
}

String sha(List<int> b) => cripto.sha256.convert(b).toString();
