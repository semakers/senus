// ignore_for_file: library_private_types_in_public_api
// Vinculación FFI mínima a libusb-1.0.
//
// Solo las ~15 funciones que SENUS necesita (enumerar, abrir, claim_interface,
// bulk_transfer, release/close, descriptores). Si libusb no se encuentra, la
// clase expone `disponible == false` y toda la UI debe mostrarlo así en vez
// de reventar (DISENO.md §2.2 y §4.1).
//
// Convención de nombres de la biblioteca por plataforma:
//   Linux   : libusb-1.0.so.0  (fallback: libusb-1.0.so)
//   macOS   : libusb-1.0.0.dylib (Homebrew ARM:  /opt/homebrew/lib/libusb-1.0.0.dylib
//                                 Homebrew Intel: /usr/local/lib/libusb-1.0.0.dylib
//                                 Puerto a mano: /usr/local/lib/libusb-1.0.0.dylib)
//   Windows : libusb-1.0.dll (embebida junto al ejecutable).

import 'dart:ffi';
import 'dart:io' show Platform, File;
import 'package:ffi/ffi.dart';

// Códigos de error libusb (los que miramos).
const int libusbSuccess = 0;
const int libusbErrorIo = -1;
const int libusbErrorInvalidParam = -2;
const int libusbErrorAccess = -3;
const int libusbErrorNoDevice = -4;
const int libusbErrorNotFound = -5;
const int libusbErrorBusy = -6;
const int libusbErrorTimeout = -7;
const int libusbErrorOverflow = -8;
const int libusbErrorPipe = -9;

// Transferencias.
const int libusbEndpointIn = 0x80;
const int libusbEndpointOut = 0x00;
const int libusbTransferTypeBulk = 2;

// --- Estructuras C ---

// libusb_device_descriptor es un POD de 18 bytes.
final class LibusbDeviceDescriptor extends Struct {
  @Uint8() external int bLength;
  @Uint8() external int bDescriptorType;
  @Uint16() external int bcdUSB;
  @Uint8() external int bDeviceClass;
  @Uint8() external int bDeviceSubClass;
  @Uint8() external int bDeviceProtocol;
  @Uint8() external int bMaxPacketSize0;
  @Uint16() external int idVendor;
  @Uint16() external int idProduct;
  @Uint16() external int bcdDevice;
  @Uint8() external int iManufacturer;
  @Uint8() external int iProduct;
  @Uint8() external int iSerialNumber;
  @Uint8() external int bNumConfigurations;
}

// --- Typedefs FFI ---

typedef _CInit = Int32 Function(Pointer<Pointer<Void>>);
typedef _DInit = int Function(Pointer<Pointer<Void>>);

typedef _CExit = Void Function(Pointer<Void>);
typedef _DExit = void Function(Pointer<Void>);

typedef _CGetDeviceList = IntPtr Function(
    Pointer<Void>, Pointer<Pointer<Pointer<Void>>>);
typedef _DGetDeviceList = int Function(
    Pointer<Void>, Pointer<Pointer<Pointer<Void>>>);

typedef _CFreeDeviceList = Void Function(Pointer<Pointer<Void>>, Int32);
typedef _DFreeDeviceList = void Function(Pointer<Pointer<Void>>, int);

typedef _CGetDeviceDescriptor = Int32 Function(
    Pointer<Void>, Pointer<LibusbDeviceDescriptor>);
typedef _DGetDeviceDescriptor = int Function(
    Pointer<Void>, Pointer<LibusbDeviceDescriptor>);

typedef _COpen = Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>);
typedef _DOpen = int Function(Pointer<Void>, Pointer<Pointer<Void>>);

typedef _CClose = Void Function(Pointer<Void>);
typedef _DClose = void Function(Pointer<Void>);

typedef _CClaim = Int32 Function(Pointer<Void>, Int32);
typedef _DClaim = int Function(Pointer<Void>, int);

typedef _CRelease = Int32 Function(Pointer<Void>, Int32);
typedef _DRelease = int Function(Pointer<Void>, int);

typedef _CBulkTransfer = Int32 Function(
    Pointer<Void>, Uint8, Pointer<Uint8>, Int32, Pointer<Int32>, Uint32);
typedef _DBulkTransfer = int Function(
    Pointer<Void>, int, Pointer<Uint8>, int, Pointer<Int32>, int);

// libusb_control_transfer: devuelve bytes transferidos o un libusbError<0.
// bmRequestType (p. ej. 0x40 = OUT vendor-interface, 0xC0 = IN vendor-interface).
// Es la base del protocolo del bootloader propio (pu_bl.py), que vive sobre
// EP0 con vendor requests (0xD0..0xDB).
typedef _CControlTransfer = Int32 Function(
    Pointer<Void>, Uint8, Uint8, Uint16, Uint16, Pointer<Uint8>, Uint16, Uint32);
typedef _DControlTransfer = int Function(
    Pointer<Void>, int, int, int, int, Pointer<Uint8>, int, int);

typedef _CGetStringDescAscii = Int32 Function(
    Pointer<Void>, Uint8, Pointer<Uint8>, Int32);
typedef _DGetStringDescAscii = int Function(
    Pointer<Void>, int, Pointer<Uint8>, int);

typedef _CSetAutoDetachKernelDriver = Int32 Function(Pointer<Void>, Int32);
typedef _DSetAutoDetachKernelDriver = int Function(Pointer<Void>, int);

typedef _CResetDevice = Int32 Function(Pointer<Void>);
typedef _DResetDevice = int Function(Pointer<Void>);

typedef _CSetConfiguration = Int32 Function(Pointer<Void>, Int32);
typedef _DSetConfiguration = int Function(Pointer<Void>, int);

typedef _CStrError = Pointer<Utf8> Function(Int32);
typedef _DStrError = Pointer<Utf8> Function(int);

/// Enlazador perezoso a libusb-1.0 con intento multi-plataforma.
class LibUsb {
  final DynamicLibrary _dl;

  late final _DInit init = _dl
      .lookup<NativeFunction<_CInit>>('libusb_init')
      .asFunction<_DInit>();
  late final _DExit exit = _dl
      .lookup<NativeFunction<_CExit>>('libusb_exit')
      .asFunction<_DExit>();
  late final _DGetDeviceList getDeviceList = _dl
      .lookup<NativeFunction<_CGetDeviceList>>('libusb_get_device_list')
      .asFunction<_DGetDeviceList>();
  late final _DFreeDeviceList freeDeviceList = _dl
      .lookup<NativeFunction<_CFreeDeviceList>>('libusb_free_device_list')
      .asFunction<_DFreeDeviceList>();
  late final _DGetDeviceDescriptor getDeviceDescriptor = _dl
      .lookup<NativeFunction<_CGetDeviceDescriptor>>(
          'libusb_get_device_descriptor')
      .asFunction<_DGetDeviceDescriptor>();
  late final _DOpen open =
      _dl.lookup<NativeFunction<_COpen>>('libusb_open').asFunction<_DOpen>();
  late final _DClose close =
      _dl.lookup<NativeFunction<_CClose>>('libusb_close').asFunction<_DClose>();
  late final _DClaim claimInterface = _dl
      .lookup<NativeFunction<_CClaim>>('libusb_claim_interface')
      .asFunction<_DClaim>();
  late final _DRelease releaseInterface = _dl
      .lookup<NativeFunction<_CRelease>>('libusb_release_interface')
      .asFunction<_DRelease>();
  late final _DBulkTransfer bulkTransfer = _dl
      .lookup<NativeFunction<_CBulkTransfer>>('libusb_bulk_transfer')
      .asFunction<_DBulkTransfer>();
  late final _DControlTransfer controlTransfer = _dl
      .lookup<NativeFunction<_CControlTransfer>>('libusb_control_transfer')
      .asFunction<_DControlTransfer>();
  late final _DGetStringDescAscii getStringDescriptorAscii = _dl
      .lookup<NativeFunction<_CGetStringDescAscii>>(
          'libusb_get_string_descriptor_ascii')
      .asFunction<_DGetStringDescAscii>();
  late final _DResetDevice resetDevice = _dl
      .lookup<NativeFunction<_CResetDevice>>('libusb_reset_device')
      .asFunction<_DResetDevice>();
  // `pu_bl_installer.abrir()` llama a `set_configuration()` (pyusb) antes de
  // hablar con el BL, y es lo que se probó en silicio: aquí lo mismo.
  late final _DSetConfiguration setConfiguration = _dl
      .lookup<NativeFunction<_CSetConfiguration>>('libusb_set_configuration')
      .asFunction<_DSetConfiguration>();
  late final _DStrError strError = _dl
      .lookup<NativeFunction<_CStrError>>('libusb_strerror')
      .asFunction<_DStrError>();

  // Linux-only; nullable: en macOS no existe y se ignora.
  late final _DSetAutoDetachKernelDriver? setAutoDetachKernelDriver = () {
    if (!Platform.isLinux) return null;
    try {
      return _dl
          .lookup<NativeFunction<_CSetAutoDetachKernelDriver>>(
              'libusb_set_auto_detach_kernel_driver')
          .asFunction<_DSetAutoDetachKernelDriver>();
    } catch (_) {
      return null;
    }
  }();

  LibUsb._(this._dl);

  /// Intenta cargar libusb. Devuelve `null` si no está. No lanza.
  static LibUsb? intenta() {
    final rutas = <String>[];
    if (Platform.isLinux) {
      rutas.addAll([
        'libusb-1.0.so.0',
        'libusb-1.0.so',
        '/usr/lib64/libusb-1.0.so.0',
        '/usr/lib/libusb-1.0.so.0',
        '/usr/lib/x86_64-linux-gnu/libusb-1.0.so.0',
        '/usr/lib/aarch64-linux-gnu/libusb-1.0.so.0',
      ]);
    } else if (Platform.isMacOS) {
      // Primero la que va dentro del .app (SENUS.app/Contents/Frameworks), firmada con SENUS: con el
      // «hardened runtime» de la app notarizada, una libusb de Homebrew sin la misma firma no carga.
      final contenido = File(Platform.resolvedExecutable).parent.parent.path;
      rutas.addAll([
        '$contenido/Frameworks/libusb-1.0.0.dylib',
        '/opt/homebrew/lib/libusb-1.0.0.dylib',
        '/usr/local/lib/libusb-1.0.0.dylib',
        'libusb-1.0.0.dylib',
        'libusb-1.0.dylib',
        '/opt/local/lib/libusb-1.0.0.dylib',
      ]);
    } else if (Platform.isWindows) {
      rutas.addAll([
        'libusb-1.0.dll',
      ]);
    }
    for (final r in rutas) {
      try {
        // En rutas absolutas, confirma antes para evitar excepciones ruidosas.
        if (r.startsWith('/') && !File(r).existsSync()) continue;
        final dl = DynamicLibrary.open(r);
        return LibUsb._(dl);
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  /// Trad: devuelve el mensaje de error de libusb (strerror).
  String mensaje(int cod) {
    try {
      final p = strError(cod);
      if (p.address == 0) return 'libusb error $cod';
      return '${p.toDartString()} ($cod)';
    } catch (_) {
      return 'libusb error $cod';
    }
  }
}
