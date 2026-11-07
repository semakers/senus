// De una sesión MTP abierta a un [Telefono] completo. Lo usan la pantalla de
// conexión y el flujo de actualización, que vuelve a abrir la sesión al final.

import '../mtp/canal_gestion.dart';
import '../mtp/sesion_mtp.dart';
import 'telefono.dart';

/// GetDeviceInfo, almacenes y, si hay canal, `SEN_INFO`. Un fallo de `SEN_INFO`
/// no tumba la conexión: el teléfono se ve igual, sin esos datos.
Future<ResultadoMtp<Telefono>> leerTelefono(SesionMtp s) async {
  final info = await s.info();
  if (!info.bien) return info;
  var tel = info.valor!;
  final alm = await s.almacenes();
  if (alm.bien) tel = tel.copiarCon(almacenes: alm.valor!);
  if (tel.canalGestion) {
    try {
      tel = tel.copiarCon(gestion: await CanalGestion(s).info());
    } on CanalError catch (_) {
      // Se queda sin `gestion`: la pantalla pide actualizar.
    } on CanalMalFormado catch (_) {
      // Igual: mejor un teléfono a medias que ninguno.
    }
  }
  return ResultadoMtp.ok(tel);
}
