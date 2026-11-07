// El canal de plataforma del puente Bluetooth. El otro extremo es
// `lib/conexion/puente_nativo.dart`: `senus/puente_bt` para las órdenes y
// `senus/puente_bt/eventos` para lo que pasa. Solo traduce.

import FlutterMacOS
import Foundation

final class PuenteBluetoothCanal: NSObject, FlutterStreamHandler, PuenteBluetoothAvisos {
  private static var compartido: PuenteBluetoothCanal?

  private let puente = PuenteBluetooth()
  private var sumidero: FlutterEventSink?

  static func registrar(_ mensajero: FlutterBinaryMessenger) {
    let c = PuenteBluetoothCanal()
    compartido = c
    c.puente.avisos = c
    FlutterMethodChannel(name: "senus/puente_bt", binaryMessenger: mensajero)
      .setMethodCallHandler(c.atender)
    FlutterEventChannel(name: "senus/puente_bt/eventos", binaryMessenger: mensajero)
      .setStreamHandler(c)
  }

  /// Al cerrar SENUS: el puente vive con la app.
  static func apagarTodo() {
    compartido?.puente.apagar()
  }

  private static func error(_ e: Error) -> FlutterError {
    let codigo: String
    switch e {
    case FalloBluetooth.sinAdaptador: codigo = "sin_adaptador"
    case FalloBluetooth.sinPermiso: codigo = "sin_permiso"
    case FalloBluetooth.apagado: codigo = "apagado"
    case FalloBluetooth.sdp: codigo = "sdp"
    case FalloBluetooth.escucha: codigo = "escucha"
    case FalloBluetooth.direccionMala: codigo = "direccion"
    case FalloBluetooth.canalMalo: codigo = "canal"
    default: codigo = "desconocido"
    }
    return FlutterError(code: codigo, message: "\(e)", details: nil)
  }

  private func atender(_ llamada: FlutterMethodCall, _ resultado: @escaping FlutterResult) {
    let a = llamada.arguments as? [String: Any] ?? [:]
    switch llamada.method {
    case "consultar":
      // Con permiso ya dado, el estado de la radio llega por CoreBluetooth y tarda
      // una vuelta. Sin él no se abre el diálogo: eso solo lo hace `encender`.
      if puente.consultar()["permiso"] as? String == "concedido" {
        puente.prepararPermiso { [puente] in resultado(puente.consultar()) }
      } else {
        resultado(puente.consultar())
      }
    case "encender":
      puente.prepararPermiso { [puente] in
        do {
          let c = try puente.encender(
            nombre: a["nombre"] as? String ?? "SENUS",
            canalPreferido: a["canal"] as? Int ?? 10)
          resultado(c)
        } catch {
          resultado(PuenteBluetoothCanal.error(error))
        }
      }
    case "apagar":
      puente.apagar()
      resultado(nil)
    case "armarEmparejamiento":
      do {
        try puente.armarEmparejamiento(
          direccion: a["direccion"] as? String ?? "",
          pin: a["pin"] as? String ?? "")
        resultado(nil)
      } catch {
        resultado(PuenteBluetoothCanal.error(error))
      }
    case "vigilar":
      do {
        try puente.vigilar(
          direcciones: a["direcciones"] as? [String] ?? [],
          canal: a["canal"] as? Int ?? 0)
        resultado(nil)
      } catch {
        resultado(PuenteBluetoothCanal.error(error))
      }
    case "desarmarEmparejamiento":
      puente.desarmarEmparejamiento()
      resultado(nil)
    case "olvidar":
      resultado(puente.olvidar(direccion: a["direccion"] as? String ?? ""))
    case "escribir":
      guard let id = a["id"] as? Int, let d = a["datos"] as? FlutterStandardTypedData else {
        resultado(FlutterError(code: "argumentos", message: "escribir", details: nil))
        return
      }
      puente.escribir(id: id, datos: d.data) { codigo in
        if codigo == 0 {
          resultado(nil)
        } else {
          resultado(
            FlutterError(code: "escritura", message: "IOReturn \(codigo)", details: nil))
        }
      }
    case "cortar":
      puente.cortar(id: a["id"] as? Int ?? 0)
      resultado(nil)
    default:
      resultado(FlutterMethodNotImplemented)
    }
  }

  // MARK: FlutterStreamHandler

  func onListen(withArguments _: Any?, eventSink: @escaping FlutterEventSink) -> FlutterError? {
    sumidero = eventSink
    return nil
  }

  func onCancel(withArguments _: Any?) -> FlutterError? {
    sumidero = nil
    return nil
  }

  // MARK: PuenteBluetoothAvisos

  func conectado(id: Int, direccion: String, emparejado: Bool, mtu: Int) {
    sumidero?([
      "e": "conectado", "id": id, "direccion": direccion, "emparejado": emparejado, "mtu": mtu,
    ])
  }

  func datos(id: Int, bytes: Data) {
    sumidero?(["e": "datos", "id": id, "datos": FlutterStandardTypedData(bytes: bytes)])
  }

  func cerrado(id: Int) {
    sumidero?(["e": "cerrado", "id": id])
  }

  func emparejamiento(direccion: String, estado: String, codigo: Int) {
    sumidero?(["e": "emparejamiento", "direccion": direccion, "estado": estado, "codigo": codigo])
  }

  func registro(_ texto: String) {
    sumidero?(["e": "registro", "texto": texto])
  }
}
