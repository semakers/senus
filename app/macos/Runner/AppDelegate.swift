import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  // Solo hay internet con SENUS abierta: nada se queda en segundo plano.
  override func applicationWillTerminate(_ notification: Notification) {
    PuenteBluetoothCanal.apagarTodo()
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
