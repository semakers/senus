// Mide en esta Mac lo que `puente-bluetooth-en-senus` marca como «sin medir» y se
// puede saber sin teléfono: si hay Bluetooth, si macOS pide permiso, si una app sin
// firmar publica un SDP y qué canal RFCOMM le dan. Empareja con nada. Usa el mismo
// PuenteBluetooth.swift que la app.
//
// Por SSH el proceso responsable es sshd y macOS niega el Bluetooth sin preguntar:
// esto vale si se lanza como app, con `compilar.sh` (que arma MedirBt.app) y `open`.

import CoreBluetooth
import Foundation
import IOBluetooth

final class Avisos: PuenteBluetoothAvisos {
  func conectado(id: Int, direccion: String, emparejado: Bool, mtu: Int) {
    print("conectado \(id) \(direccion) emparejado=\(emparejado) mtu=\(mtu)")
  }
  func datos(id: Int, bytes: Data) { print("datos \(id): \(bytes.count) B") }
  func cerrado(id: Int) { print("cerrado \(id)") }
  func emparejamiento(direccion: String, estado: String, codigo: Int) {
    print("emparejamiento \(direccion) \(estado) \(codigo)")
  }
  func registro(_ texto: String) { print("registro: \(texto)") }
}

setbuf(stdout, nil)
let segundos = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 3 : 3
let avisos = Avisos()
let p = PuenteBluetooth()
p.avisos = avisos
print("consultar: \(p.consultar())")
var listo = false
p.prepararPermiso { listo = true }
let plazo = Date(timeIntervalSinceNow: 20)
while !listo && Date() < plazo {
  RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
}
print("permiso resuelto: \(listo); consultar: \(p.consultar())")
do {
  let c = try p.encender(nombre: "SENUS W5RED", canalPreferido: 10)
  print("publicado en el canal RFCOMM \(c)")
  print("consultar: \(p.consultar())")
  RunLoop.main.run(until: Date(timeIntervalSinceNow: segundos))
  p.apagar()
  print("retirado; consultar: \(p.consultar())")
} catch {
  print("FALLO al encender: \(error)")
  exit(1)
}
exit(0)
