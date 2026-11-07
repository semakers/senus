// El puente Bluetooth de SENUS en macOS. SENUS LLAMA al teléfono: mientras quiere
// red, senew (0.29.3) se pone conectable y ofrece un RFCOMM en un canal fijo, y
// `vigilar` lo abre desde aquí. Medido el 4-nov en macOS 26.5.1: una app no puede
// ser servidor Bluetooth clásico (el registro SDP se publica, pero el sistema no lo
// anuncia y nadie abre su canal) ni ve los enlaces que abre el teléfono; sí puede
// llamar (`openRFCOMMChannelAsync`, enlace a los ~6 s). El servidor SDP de antes
// sigue encendido: no estorba, y «servidor encendido» sigue siendo eso.
//
// Esto solo mueve bytes y dice qué pasa. La sesión W5RED, la lista de permitidos
// y las decisiones viven en Dart (`lib/conexion/`). No importa FlutterMacOS, para
// poder compilarlo solo con `tool/medir_bt_mac` y medir sin abrir la app.
//
// IOBluetooth entrega sus avisos en el bucle del hilo que lo llamó: todo esto corre
// en el hilo principal.

import CoreBluetooth
import Foundation
import IOBluetooth

protocol PuenteBluetoothAvisos: AnyObject {
  func conectado(id: Int, direccion: String, emparejado: Bool, mtu: Int)
  func datos(id: Int, bytes: Data)
  func cerrado(id: Int)
  func emparejamiento(direccion: String, estado: String, codigo: Int)
  func registro(_ texto: String)
}

enum FalloBluetooth: Error {
  case sinAdaptador
  case sinPermiso
  case apagado
  case sdp(String)
  case escucha
  case direccionMala
  case canalMalo
  case noConectado
  case escritura(Int)
}

/// Un trozo que cabe en el MTU. Su memoria debe vivir hasta `WriteComplete`.
private final class Fragmento {
  let datos: UnsafeMutableRawPointer
  let n: Int
  /// Se llama al confirmarse el ÚLTIMO trozo de una escritura.
  let alAcabar: ((Int) -> Void)?

  init(_ d: Data, alAcabar: ((Int) -> Void)?) {
    n = d.count
    datos = UnsafeMutableRawPointer.allocate(byteCount: max(n, 1), alignment: 1)
    d.copyBytes(to: datos.assumingMemoryBound(to: UInt8.self), count: n)
    self.alAcabar = alAcabar
  }

  deinit { datos.deallocate() }
}

private final class Conexion {
  let id: Int
  let canal: IOBluetoothRFCOMMChannel
  /// «AA:BB:…», para no volver a llamar a quien ya tiene canal.
  let direccion: String
  var cola: [Fragmento] = []
  var enVuelo = 0
  init(id: Int, canal: IOBluetoothRFCOMMChannel, direccion: String) {
    self.id = id
    self.canal = canal
    self.direccion = direccion
  }
}

/// Una llamada al teléfono que aún no ha contestado.
private final class Intento {
  let desde = Date()
  /// Lo da `openRFCOMMChannelAsync` al volver; nil hasta entonces.
  var canal: IOBluetoothRFCOMMChannel?
}

final class PuenteBluetooth: NSObject, IOBluetoothRFCOMMChannelDelegate, IOBluetoothDevicePairDelegate,
  CBCentralManagerDelegate
{
  /// Escrituras sin confirmar por canal. Sin medir contra el teléfono: una sola
  /// limitaría a una trama por vuelta del bucle, y muchas ocultan el freno de
  /// créditos a la sesión W5RED.
  static let maxEnVuelo = 4

  /// Cada cuánto se llama a quien no tiene canal, y cuánto se espera una llamada.
  /// Un page sin respuesta dura ~5 s: con el teléfono sin red, esto pagina casi
  /// sin pausa. [sin medir su efecto en los demás aparatos Bluetooth de la Mac]
  static let pausaVigilar: TimeInterval = 3
  static let plazoIntento: TimeInterval = 15

  /// Emparejar: cada cuánto se reintenta y cuánto se espera a que acabe uno.
  static let pausaPar: TimeInterval = 4
  static let plazoPar: TimeInterval = 15

  weak var avisos: PuenteBluetoothAvisos?

  private var registroSdp: IOBluetoothSDPServiceRecord?
  private var avisoCanal: IOBluetoothUserNotification?
  private var canalRfcomm: BluetoothRFCOMMChannelID = 0
  private var conexiones: [ObjectIdentifier: Conexion] = [:]
  private var sigId = 1

  // A quién se llama, y por qué canal suyo.
  private var vigiladas: [String] = []
  private var canalTelefono: BluetoothRFCOMMChannelID = 0
  private var intentos: [String: Intento] = [:]
  private var relojVigilar: Timer?
  /// El último fallo dicho por dirección: solo se registra cuando cambia.
  private var ultimoFallo: [String: Int] = [:]

  // Emparejamiento armado: se llama al teléfono hasta que quede emparejado.
  private var armado: (direccion: String, pin: String)?
  private var avisoEnlace: IOBluetoothUserNotification?
  private var par: IOBluetoothDevicePair?
  private var parDesde: Date?
  private var vigiaPar: Timer?

  // Sin permiso de Bluetooth, IOBluetooth no avisa: da la radio por apagada y no
  // publica nada. CoreBluetooth es quien distingue los dos casos y quien abre el
  // diálogo del sistema la primera vez.
  private var gestor: CBCentralManager?
  private var esperandoEstado: [() -> Void] = []

  // MARK: Adaptador

  private static func textoPermiso() -> String {
    switch CBCentralManager.authorization {
    case .allowedAlways: return "concedido"
    case .denied: return "denegado"
    case .restricted: return "restringido"
    case .notDetermined: return "sin_decidir"
    @unknown default: return "sin_decidir"
    }
  }

  /// Abre el diálogo de permiso si hace falta y avisa cuando se sabe el estado.
  func prepararPermiso(_ hecho: @escaping () -> Void) {
    if let g = gestor, g.state != .unknown, g.state != .resetting {
      hecho()
      return
    }
    esperandoEstado.append(hecho)
    if gestor == nil {
      gestor = CBCentralManager(
        delegate: self, queue: .main,
        options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    if central.state == .unknown || central.state == .resetting { return }
    let l = esperandoEstado
    esperandoEstado = []
    for f in l {
      f()
    }
  }

  /// Qué hay en esta máquina. No enciende nada ni pide permiso. Hasta tener
  /// permiso no se toca IOBluetooth: medido en macOS 26.5, su primera llamada clava
  /// el hilo principal mientras el diálogo del sistema no se conteste.
  func consultar() -> [String: Any] {
    let permiso = PuenteBluetooth.textoPermiso()
    let estado = gestor?.state
    let hay = estado != .unsupported
    guard permiso == "concedido", hay,
      let h = IOBluetoothHostController.default(),
      let dir = h.addressAsString(), !dir.isEmpty
    else {
      return ["hay": hay, "permiso": permiso, "encendido": false, "servidor": false]
    }
    return [
      "hay": true,
      "permiso": permiso,
      "encendido": estado == .poweredOn,
      "direccion": PuenteBluetooth.normalizar(dir),
      "servidor": registroSdp != nil,
    ]
  }

  /// «aa-bb-cc-dd-ee-ff» → «AA:BB:CC:DD:EE:FF».
  static func normalizar(_ d: String) -> String {
    return d.replacingOccurrences(of: "-", with: ":").uppercased()
  }

  /// «AA:BB:CC:DD:EE:FF», sin tocar IOBluetooth (que sin permiso clava el hilo).
  static func esDireccion(_ d: String) -> Bool {
    let p = d.split(separator: ":", omittingEmptySubsequences: false)
    return p.count == 6 && p.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isHexDigit) }
  }

  // MARK: Servidor

  private static func uuid16(_ v: UInt16) -> Data {
    return Data([UInt8(v >> 8), UInt8(v & 0xFF)])
  }

  private static func entero(_ v: Int, bytes: Int) -> [String: Any] {
    return ["DataElementType": 1, "DataElementSize": bytes, "DataElementValue": v]
  }

  /// El registro SDP. El canal que se pide es una preferencia: el sistema da el
  /// que esté libre y lo escribe en el registro publicado.
  private static func diccionarioSdp(nombre: String, canal: Int) -> [String: Any] {
    return [
      "0001 - ServiceClassIDList": [uuid16(0x1101)],
      "0004 - ProtocolDescriptorList": [
        [uuid16(0x0100)],
        [uuid16(0x0003), entero(canal, bytes: 1)],
      ],
      "0005 - BrowseGroupList*": [uuid16(0x1002)],
      "0006 - LanguageBaseAttributeIDList*": [
        entero(0x656E, bytes: 2), entero(0x006A, bytes: 2), entero(0x0100, bytes: 2),
      ],
      "0009 - BluetoothProfileDescriptorList": [
        [uuid16(0x1101), entero(0x0102, bytes: 2)]
      ],
      "0100 - ServiceName*": nombre,
    ]
  }

  /// Publica el servicio y se pone a escuchar. Devuelve el canal RFCOMM.
  @discardableResult
  func encender(nombre: String, canalPreferido: Int) throws -> Int {
    if registroSdp != nil { return Int(canalRfcomm) }
    if CBCentralManager.authorization == .denied || CBCentralManager.authorization == .restricted {
      throw FalloBluetooth.sinPermiso
    }
    // Hay que haber pasado por `prepararPermiso`.
    switch gestor?.state {
    case .poweredOn: break
    case .unsupported: throw FalloBluetooth.sinAdaptador
    case .unauthorized: throw FalloBluetooth.sinPermiso
    default: throw FalloBluetooth.apagado
    }
    let dic = PuenteBluetooth.diccionarioSdp(nombre: nombre, canal: canalPreferido)
    guard let rec = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: dic) else {
      throw FalloBluetooth.sdp("el sistema no publicó el registro")
    }
    var canal: BluetoothRFCOMMChannelID = 0
    let r = rec.getRFCOMMChannelID(&canal)
    if r != kIOReturnSuccess || canal == 0 {
      rec.remove()
      throw FalloBluetooth.sdp("el registro no trae canal RFCOMM (0x\(String(UInt32(bitPattern: r), radix: 16)))")
    }
    guard
      let av = IOBluetoothRFCOMMChannel.register(
        forChannelOpenNotifications: self,
        selector: #selector(canalAbierto(_:canal:)),
        withChannelID: canal,
        direction: kIOBluetoothUserNotificationChannelDirectionIncoming)
    else {
      rec.remove()
      throw FalloBluetooth.escucha
    }
    registroSdp = rec
    avisoCanal = av
    canalRfcomm = canal
    avisos?.registro("SDP publicado: Serial Port en el canal RFCOMM \(canal)")
    reprogramarVigilancia()
    return Int(canal)
  }

  /// Quita el servicio y corta lo que haya. Al cerrar SENUS, el proceso muere con
  /// él, y esto solo adelanta lo que haría el sistema.
  func apagar() {
    desarmarEmparejamiento()
    pararVigilancia()
    avisoCanal?.unregister()
    avisoCanal = nil
    registroSdp?.remove()
    registroSdp = nil
    canalRfcomm = 0
    for c in Array(conexiones.values) {
      c.canal.close()
    }
  }

  @objc private func canalAbierto(
    _ aviso: IOBluetoothUserNotification!, canal: IOBluetoothRFCOMMChannel!
  ) {
    guard let canal = canal, canal.isIncoming() else { return }
    // Lo primero en un servidor (ejemplo RFCOMM de Apple): sin delegado se pierden datos.
    guard canal.setDelegate(self) == kIOReturnSuccess else {
      avisos?.registro("no pude ser delegado del canal entrante: lo cierro")
      canal.close()
      return
    }
    alta(canal, direccion: PuenteBluetooth.normalizar(canal.getDevice()?.addressString ?? "?"))
  }

  /// Un canal abierto, venga de donde venga: desde aquí sale igual hacia Dart.
  private func alta(_ canal: IOBluetoothRFCOMMChannel, direccion dir: String) {
    let id = sigId
    sigId += 1
    conexiones[ObjectIdentifier(canal)] = Conexion(id: id, canal: canal, direccion: dir)
    avisos?.conectado(
      id: id, direccion: dir, emparejado: canal.getDevice()?.isPaired() ?? false,
      mtu: Int(canal.getMTU()))
  }

  // MARK: Llamar al teléfono

  /// A quién llamar mientras el servidor esté encendido, y a qué canal RFCOMM suyo.
  /// Sustituye la lista anterior: a quien sale de ella se le deja de llamar. Sin
  /// diálogos: si el teléfono no espera, el intento caduca en silencio.
  func vigilar(direcciones: [String], canal: Int) throws {
    guard (1...30).contains(canal) else { throw FalloBluetooth.canalMalo }
    var l: [String] = []
    for d in direcciones {
      let n = PuenteBluetooth.normalizar(d)
      if !PuenteBluetooth.esDireccion(n) {
        avisos?.registro("vigilar: «\(d)» no es una dirección; se salta")
      } else if !l.contains(n) {
        l.append(n)
      }
    }
    let otroCanal = BluetoothRFCOMMChannelID(canal) != canalTelefono
    vigiladas = l
    canalTelefono = BluetoothRFCOMMChannelID(canal)
    for (dir, i) in intentos where otroCanal || !l.contains(dir) {
      olvidarIntento(dir, i)
    }
    ultimoFallo = ultimoFallo.filter { l.contains($0.key) }
    reprogramarVigilancia()
  }

  private func reprogramarVigilancia() {
    guard registroSdp != nil, !vigiladas.isEmpty else {
      relojVigilar?.invalidate()
      relojVigilar = nil
      return
    }
    if relojVigilar == nil {
      relojVigilar = Timer.scheduledTimer(
        withTimeInterval: PuenteBluetooth.pausaVigilar, repeats: true
      ) { [weak self] _ in
        self?.vueltaVigilar()
      }
    }
    vueltaVigilar()
  }

  private func pararVigilancia() {
    relojVigilar?.invalidate()
    relojVigilar = nil
    for (dir, i) in intentos {
      olvidarIntento(dir, i)
    }
    vigiladas = []
    ultimoFallo = [:]
  }

  private func olvidarIntento(_ dir: String, _ i: Intento) {
    intentos[dir] = nil
    i.canal?.close()
  }

  /// Una vuelta: caduca lo que no contesta y llama a quien no tiene canal ni
  /// llamada en curso. Quien no está emparejado con esta Mac no se llama (macOS
  /// sacaría su diálogo de PIN), salvo el que se está emparejando por el cable.
  private func vueltaVigilar() {
    guard registroSdp != nil else { return }
    let ahora = Date()
    for (dir, i) in intentos where ahora.timeIntervalSince(i.desde) >= PuenteBluetooth.plazoIntento {
      anotarFallo(dir, Int(kIOReturnTimeout))
      olvidarIntento(dir, i)
    }
    for dir in vigiladas {
      if intentos[dir] != nil || conexiones.values.contains(where: { $0.direccion == dir }) {
        continue
      }
      guard let d = dispositivo(dir) else { continue }
      if !d.isPaired() && armado?.direccion != dir {
        anotarFallo(dir, Int(kIOReturnNotPermitted))
        continue
      }
      llamar(dir, d)
    }
  }

  private func llamar(_ dir: String, _ d: IOBluetoothDevice) {
    let i = Intento()
    intentos[dir] = i
    var canal: IOBluetoothRFCOMMChannel?
    let r = d.openRFCOMMChannelAsync(&canal, withChannelID: canalTelefono, delegate: self)
    // Si contestó dentro de la misma llamada, ya está resuelto.
    guard intentos[dir] === i else { return }
    if r != kIOReturnSuccess {
      intentos[dir] = nil
      anotarFallo(dir, Int(r))
      return
    }
    i.canal = canal
  }

  /// Solo al cambiar: con el teléfono sin red, fallaría en cada vuelta.
  private func anotarFallo(_ dir: String, _ codigo: Int) {
    if ultimoFallo[dir] == codigo { return }
    ultimoFallo[dir] = codigo
    let que: String
    switch codigo {
    case Int(kIOReturnTimeout): que = "no contestó en \(Int(PuenteBluetooth.plazoIntento)) s"
    case Int(kIOReturnNotPermitted): que = "no está emparejado con este computador: no se le llama"
    default: que = "la llamada falló (0x\(String(UInt32(bitPattern: Int32(truncatingIfNeeded: codigo)), radix: 16)))"
    }
    avisos?.registro("\(dir): \(que); se reintenta mientras esté en la lista")
  }

  func rfcommChannelOpenComplete(_ canal: IOBluetoothRFCOMMChannel!, status: IOReturn) {
    guard let canal = canal else { return }
    // Los que abre el teléfono llegan por `canalAbierto`.
    if conexiones[ObjectIdentifier(canal)] != nil || canal.isIncoming() { return }
    let dir = PuenteBluetooth.normalizar(canal.getDevice()?.addressString ?? "?")
    guard let i = intentos[dir], i.canal == nil || i.canal === canal else {
      // De un intento ya caducado: no se queda abierto a medias.
      if status == kIOReturnSuccess { canal.close() }
      return
    }
    intentos[dir] = nil
    if status != kIOReturnSuccess {
      anotarFallo(dir, Int(status))
      return
    }
    ultimoFallo[dir] = nil
    avisos?.registro("\(dir): contestó en el canal RFCOMM \(canalTelefono)")
    alta(canal, direccion: dir)
  }

  // MARK: Datos

  /// Trocea por el MTU y completa cuando el último trozo está en el hardware.
  func escribir(id: Int, datos: Data, hecho: @escaping (Int) -> Void) {
    guard let c = conexiones.values.first(where: { $0.id == id }) else {
      hecho(Int(kIOReturnNotOpen))
      return
    }
    if datos.isEmpty {
      hecho(0)
      return
    }
    let mtu = max(Int(c.canal.getMTU()), 16)
    var i = datos.startIndex
    while i < datos.endIndex {
      let f = min(i + mtu, datos.endIndex)
      c.cola.append(Fragmento(datos.subdata(in: i..<f), alAcabar: f == datos.endIndex ? hecho : nil))
      i = f
    }
    bombear(c)
  }

  private func bombear(_ c: Conexion) {
    while c.enVuelo < PuenteBluetooth.maxEnVuelo, let f = c.cola.first {
      // Sin créditos: `rfcommChannelFlowControlChanged` o `QueueSpaceAvailable` siguen.
      if c.canal.isTransmissionPaused() { return }
      let ref = Unmanaged.passRetained(f)
      let r = c.canal.writeAsync(f.datos, length: UInt16(f.n), refcon: ref.toOpaque())
      if r == kIOReturnNoResources || r == kIOReturnBusy {
        ref.release()
        return
      }
      if r != kIOReturnSuccess {
        ref.release()
        fallarCola(c, Int(r))
        return
      }
      c.cola.removeFirst()
      c.enVuelo += 1
    }
  }

  private func fallarCola(_ c: Conexion, _ codigo: Int) {
    let cola = c.cola
    c.cola = []
    for f in cola {
      f.alAcabar?(codigo)
    }
  }

  func cortar(id: Int) {
    conexiones.values.first(where: { $0.id == id })?.canal.close()
  }

  func rfcommChannelData(
    _ canal: IOBluetoothRFCOMMChannel!, data: UnsafeMutableRawPointer!, length: Int
  ) {
    guard let c = conexiones[ObjectIdentifier(canal)] else { return }
    avisos?.datos(id: c.id, bytes: Data(bytes: data, count: length))
  }

  func rfcommChannelWriteComplete(
    _ canal: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status: IOReturn
  ) {
    let f = Unmanaged<Fragmento>.fromOpaque(refcon).takeRetainedValue()
    guard let c = conexiones[ObjectIdentifier(canal)] else {
      f.alAcabar?(Int(kIOReturnNotOpen))
      return
    }
    c.enVuelo -= 1
    if status != kIOReturnSuccess {
      f.alAcabar?(Int(status))
      fallarCola(c, Int(status))
      return
    }
    f.alAcabar?(0)
    bombear(c)
  }

  func rfcommChannelQueueSpaceAvailable(_ canal: IOBluetoothRFCOMMChannel!) {
    if let c = conexiones[ObjectIdentifier(canal)] { bombear(c) }
  }

  func rfcommChannelFlowControlChanged(_ canal: IOBluetoothRFCOMMChannel!) {
    if let c = conexiones[ObjectIdentifier(canal)] { bombear(c) }
  }

  func rfcommChannelClosed(_ canal: IOBluetoothRFCOMMChannel!) {
    guard let c = conexiones.removeValue(forKey: ObjectIdentifier(canal)) else { return }
    fallarCola(c, Int(kIOReturnNotOpen))
    avisos?.cerrado(id: c.id)
  }

  // MARK: Emparejar

  /// Empareja con el teléfono que se acaba de mandar por el cable. Ahora llama esta
  /// Mac: mientras esté armado y sin emparejar, `IOBluetoothDevicePair` arranca solo
  /// cada `pausaPar` (uno a la vez), y `vigilar` lo deja llamar aunque aún no esté
  /// emparejado. Los avisos de enlace de antes siguen: también llegan del enlace que
  /// abre esta Mac (medido el 4-nov), y entonces se empareja sobre él. Un intento
  /// que falla no es el final: se avisa «reintento» y sigue; el final lo pone Dart con
  /// su plazo y con lo que diga el teléfono por el cable. [sin probar en silicio]
  func armarEmparejamiento(direccion: String, pin: String) throws {
    desarmarEmparejamiento()
    let dir = PuenteBluetooth.normalizar(direccion)
    guard IOBluetoothDevice(addressString: dir.replacingOccurrences(of: ":", with: "-")) != nil else {
      throw FalloBluetooth.direccionMala
    }
    armado = (dir, pin)
    avisoEnlace = IOBluetoothDevice.register(
      forConnectNotifications: self, selector: #selector(enlaceNuevo(_:dispositivo:)))
    // Cada segundo: si la persona contestó el PIN en un diálogo del sistema nadie
    // avisa a esta app, y toca arrancar el siguiente intento.
    vigiaPar = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      self?.vigilarPar()
    }
    if let d = dispositivo(dir), d.isConnected() {
      enlaceNuevo(nil, dispositivo: d)
    }
    avisos?.emparejamiento(direccion: dir, estado: "armado", codigo: 0)
  }

  func desarmarEmparejamiento() {
    vigiaPar?.invalidate()
    vigiaPar = nil
    avisoEnlace?.unregister()
    avisoEnlace = nil
    armado = nil
    par?.delegate = nil
    par = nil
    parDesde = nil
  }

  @objc private func enlaceNuevo(
    _ aviso: IOBluetoothUserNotification!, dispositivo: IOBluetoothDevice!
  ) {
    guard let a = armado, let d = dispositivo,
      PuenteBluetooth.normalizar(d.addressString ?? "") == a.direccion
    else { return }
    if d.isPaired() {
      avisos?.emparejamiento(direccion: a.direccion, estado: "ya", codigo: 0)
      return
    }
    avisos?.emparejamiento(direccion: a.direccion, estado: "enlace", codigo: 0)
    arrancarPar(d)
  }

  private func dispositivo(_ direccion: String) -> IOBluetoothDevice? {
    return IOBluetoothDevice(addressString: direccion.replacingOccurrences(of: ":", with: "-"))
  }

  private func vigilarPar() {
    guard let a = armado, let d = dispositivo(a.direccion) else { return }
    if d.isPaired() {
      vigiaPar?.invalidate()
      vigiaPar = nil
      avisos?.emparejamiento(direccion: a.direccion, estado: "ya", codigo: 0)
      vueltaVigilar()  // ya se le puede llamar: sin esperar a la vuelta
      return
    }
    let ahora = Date()
    if par != nil, let t = parDesde, ahora.timeIntervalSince(t) >= PuenteBluetooth.plazoPar {
      // Sin `stop()`: también corta el enlace, y puede haber un canal abierto en él.
      par?.delegate = nil
      par = nil
      avisos?.emparejamiento(
        direccion: a.direccion, estado: "reintento", codigo: Int(kIOReturnTimeout))
    }
    if par == nil, parDesde.map({ ahora.timeIntervalSince($0) >= PuenteBluetooth.pausaPar }) ?? true {
      arrancarPar(d)
    }
  }

  private func arrancarPar(_ d: IOBluetoothDevice) {
    guard par == nil, let p = IOBluetoothDevicePair(device: d) else { return }
    p.delegate = self
    par = p
    parDesde = Date()
    let r = p.start()
    if r != kIOReturnSuccess, par === p {
      p.delegate = nil
      par = nil
      avisos?.emparejamiento(
        direccion: armado?.direccion ?? "?", estado: "reintento", codigo: Int(r))
    }
  }

  func devicePairingPINCodeRequest(_ sender: Any!) {
    guard let p = sender as? IOBluetoothDevicePair, let a = armado else { return }
    var codigo = BluetoothPINCode()
    let bytes = Array(a.pin.utf8.prefix(16))
    withUnsafeMutableBytes(of: &codigo) { m in
      for (i, b) in bytes.enumerated() {
        m[i] = b
      }
    }
    p.replyPINCode(bytes.count, pinCode: &codigo)
    avisos?.emparejamiento(direccion: a.direccion, estado: "pin", codigo: 0)
  }

  func devicePairingFinished(_ sender: Any!, error: IOReturn) {
    // Uno que se dio por perdido no pisa al que corre ahora.
    if let p = sender as? IOBluetoothDevicePair, let actual = par, p !== actual { return }
    let dir = armado?.direccion ?? "?"
    par?.delegate = nil
    par = nil
    if error == kIOReturnSuccess {
      vigiaPar?.invalidate()
      vigiaPar = nil
      avisos?.emparejamiento(direccion: dir, estado: "hecho", codigo: 0)
      vueltaVigilar()
    } else {
      // La vigía arranca el siguiente a su hora.
      avisos?.emparejamiento(direccion: dir, estado: "reintento", codigo: Int(error))
    }
  }

  /// Sin API pública para quitar un emparejamiento: `remove` es privado. Si no
  /// responde, queda en Ajustes de Bluetooth y la lista de permitidos ya lo cierra.
  func olvidar(direccion: String) -> Bool {
    let sel = Selector(("remove"))
    guard
      let d = IOBluetoothDevice(
        addressString: PuenteBluetooth.normalizar(direccion).replacingOccurrences(of: ":", with: "-")),
      d.isPaired(), d.responds(to: sel)
    else { return false }
    d.perform(sel)
    return true
  }
}
