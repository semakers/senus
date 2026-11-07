// El puente Bluetooth de SENUS en Windows: el mismo contrato que el de macOS
// (macos/Runner/PuenteBluetooth*.swift) por los mismos canales, `senus/puente_bt`
// para las órdenes y `senus/puente_bt/eventos` para lo que pasa. El otro extremo es
// lib/conexion/puente_nativo.dart. Esto solo mueve bytes y dice qué pasa; la sesión
// W5RED, la lista de permitidos y las decisiones viven en Dart.
//
// Lo que cambia respecto a la Mac: en Windows una app de escritorio SÍ puede ser
// servidor RFCOMM con su registro SDP (WSASetService), así que el teléfono puede
// llamarnos a nosotros; `vigilar` (llamar al canal del teléfono) sigue ahí igual. El
// PIN lo contesta un callback (BluetoothRegisterForAuthenticationEx), sin diálogo.
//
// Todo el estado vive en el hilo de la ventana. Los hilos de trabajo (aceptar, leer,
// escribir, llamar, emparejar, el reloj) no lo tocan: dejan una función en la cola y
// avisan a la ventana con kMensaje; FlutterWindow llama a Drenar().

#ifndef RUNNER_PUENTE_BLUETOOTH_H_
#define RUNNER_PUENTE_BLUETOOTH_H_

#include <windows.h>

#include <flutter/binary_messenger.h>

#include <memory>

class PuenteBluetoothImpl;

class PuenteBluetooth {
 public:
  static constexpr UINT kMensaje = WM_APP + 0x42;

  PuenteBluetooth(flutter::BinaryMessenger* mensajero, HWND ventana);
  ~PuenteBluetooth();

  // En el hilo de la ventana, al llegar kMensaje.
  void Drenar();

  // Al cerrar SENUS: el puente vive con la app.
  void Apagar();

 private:
  std::unique_ptr<PuenteBluetoothImpl> impl_;
};

#endif  // RUNNER_PUENTE_BLUETOOTH_H_
