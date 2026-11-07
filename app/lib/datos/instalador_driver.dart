// El driver USB del teléfono en Windows: detectar si falta, instalarlo con UN
// clic (SENUS pide el permiso de administrador) y comprobar que quedó.
//
// POR QUÉ HACE FALTA. En macOS y Linux libusb abre el teléfono tal cual. En
// Windows, libusb solo puede abrir lo que lleva el driver genérico WinUSB, y el
// «SEMC USB Flash» (0fce:adde, el modo C del W580) llega sin ninguno: el
// Administrador de dispositivos lo marca con el error 28. Sin WinUSB, seftool
// dice «no encuentro 0fce:adde» aunque Windows lo vea. Lo mismo vale, el día
// que se use desde Windows, para el bootloader (1209:0003) y senew (1209:0001).
//
// CÓMO. La instalación NO se hace a mano: la hace `wdi-simple.exe`, la
// herramienta de línea de órdenes de libwdi (la misma biblioteca de Zadig,
// del proyecto libusb). Genera el .inf de WinUSB para ese VID:PID y lo instala.
// SENUS la lanza elevada (aparece el aviso de Windows «¿Permitir que esta app
// haga cambios?» y la persona acepta) y, al terminar, vuelve a mirar si el
// aparato ya lleva WinUSB. Sin `wdi-simple.exe` empaquetado, se dice cómo
// hacerlo con Zadig.
//
// Todo lo que toca el sistema (PowerShell, la elevación) entra por funciones
// inyectables, así que se prueba sin Windows.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Un aparato USB al que hay que ponerle el driver.
class AccionDriver {
  final int vid;
  final int pid;

  /// Nombre que verá Windows en el Administrador de dispositivos.
  final String nombre;
  const AccionDriver(this.vid, this.pid, this.nombre);

  /// Modo C del DB2020: «SEMC USB Flash». Solo existe unos segundos tras
  /// enchufar con la tecla C pulsada.
  static const modoFlash = AccionDriver(0x0fce, 0xadde, 'SEMC USB Flash');

  /// El bootloader que corre el exploit «Juegos → eXploit».
  static const bootloaderInstaller =
      AccionDriver(0x1209, 0x0003, 'senew bootloader');

  /// senew ya arrancado (MTP). Solo se mira si el sistema lo ve.
  static const senew = AccionDriver(0x1209, 0x0001, 'senew');

  String _h(int v) => v.toRadixString(16).padLeft(4, '0');
  String get ids => '${_h(vid)}:${_h(pid)}';

  /// El patrón de InstanceId de Windows: `USB\VID_0FCE&PID_ADDE*`.
  String get patronInstanceId =>
      'USB\\VID_${_h(vid).toUpperCase()}&PID_${_h(pid).toUpperCase()}*';
}

enum EstadoDriver {
  /// Presente y con WinUSB: libusb lo puede abrir.
  listo,

  /// Windows lo ve pero NO lleva WinUSB (sin driver, o con otro).
  sinDriver,

  /// No hay ningún aparato así conectado.
  ausente,
}

/// Lo que devuelve `_elevadoDeVerdad` cuando Windows NO llegó a ejecutar la
/// herramienta (la persona rechazó el aviso de permisos). No puede ser -1, que
/// es un código de libwdi (error de E/S).
const int codigoElevacionRechazada = -1000;

/// Los códigos de salida de libwdi (`enum wdi_error`) en cristiano.
String describirCodigoWdi(int c) => switch (c) {
      -1 => 'error de entrada/salida',
      -2 => 'parámetro inválido',
      -3 => 'acceso denegado (no pudo escribir o instalar)',
      -4 => 'el dispositivo ya no está (se desconectó)',
      -5 => 'no encontró el dispositivo',
      -6 => 'recurso ocupado (otra instalación en curso)',
      -7 => 'se agotó el tiempo',
      -9 => 'hay otra instalación pendiente: reinicia Windows',
      -10 => 'interrumpido',
      -11 => 'falta un recurso',
      -12 => 'no soportado',
      -13 => 'ya existe',
      -14 => 'cancelado por la persona',
      -15 => 'hacen falta permisos de administrador',
      -16 => 'error de WOW64 (32/64 bits)',
      -17 => 'el .inf generado no es válido',
      -18 => 'falta el catálogo (.cat)',
      -19 => 'driver sin firmar: Windows lo rechazó',
      _ => 'error desconocido',
    };

class ResultadoDriver {
  final bool ok;
  final String mensaje;
  const ResultadoDriver(this.ok, this.mensaje);
}

/// PowerShell: devuelve su salida estándar. Inyectable.
typedef EjecutarPowerShell = Future<String> Function(String script);

/// Ejecuta [exe] CON PERMISOS DE ADMINISTRADOR y espera. Devuelve su código de
/// salida, o [codigoElevacionRechazada] si la persona no aceptó el aviso de
/// Windows. Inyectable.
typedef EjecutarElevado = Future<int> Function(String exe, String argumentos);

class InstaladorDriverUsb {
  final bool esWindows;
  final EjecutarPowerShell _ps;
  final EjecutarElevado _elevado;

  /// Ruta de `wdi-simple.exe`, o null si no se encontró.
  final String? herramienta;

  /// Cuánto se espera a que Windows termine de asociar el driver.
  final Duration espera;
  final Duration intervalo;

  /// Carpeta de trabajo de la herramienta (ficheros del driver, el .bat y su
  /// registro). Por omisión, una carpeta propia en el temporal del usuario:
  /// la herramienta elevada arranca en System32 y ahí no puede escribir.
  final Directory trabajo;

  InstaladorDriverUsb({
    bool? esWindows,
    EjecutarPowerShell? ejecutarPowerShell,
    EjecutarElevado? ejecutarElevado,
    String? herramienta,
    this.espera = const Duration(seconds: 25),
    this.intervalo = const Duration(milliseconds: 500),
    Directory? trabajo,
  })  : trabajo = trabajo ??
            Directory(p.join(Directory.systemTemp.path, 'senus-wdi')),
        esWindows = esWindows ?? Platform.isWindows,
        _ps = ejecutarPowerShell ?? _powerShellDeVerdad,
        _elevado = ejecutarElevado ?? _elevadoDeVerdad,
        herramienta = herramienta ?? buscarHerramienta();

  /// `wdi-simple.exe`: primero SENUS_WDI_SIMPLE; luego junto al ejecutable
  /// (`herramientas\wdi-simple.exe`, donde lo deja el empaquetado de Windows).
  static String? buscarHerramienta({Map<String, String>? env, String? exe}) {
    final e = env ?? Platform.environment;
    final puesta = e['SENUS_WDI_SIMPLE'];
    if (puesta != null && puesta.trim().isNotEmpty) {
      return File(puesta.trim()).existsSync() ? puesta.trim() : null;
    }
    final dir = p.dirname(exe ?? Platform.resolvedExecutable);
    for (final rel in const [
      'herramientas/wdi-simple.exe',
      'wdi-simple.exe',
    ]) {
      final f = p.join(dir, rel);
      if (File(f).existsSync()) return f;
    }
    return null;
  }

  // ---------------------------------------------------------------------- //

  /// Los aparatos presentes con ese VID:PID y qué servicio (driver) llevan.
  Future<List<({String id, String? servicio, int problema})>> _presentes(
      AccionDriver a) async {
    final salida = await _ps('''
\$ErrorActionPreference = 'SilentlyContinue'
Get-PnpDevice -PresentOnly | Where-Object { \$_.InstanceId -like '${a.patronInstanceId}' } | ForEach-Object {
  \$svc = (Get-PnpDeviceProperty -InstanceId \$_.InstanceId -KeyName DEVPKEY_Device_Service).Data
  \$prob = (Get-PnpDeviceProperty -InstanceId \$_.InstanceId -KeyName DEVPKEY_Device_ProblemCode).Data
  "\$(\$_.InstanceId)|\$svc|\$prob"
}
''');
    final out = <({String id, String? servicio, int problema})>[];
    for (final l in const LineSplitter().convert(salida)) {
      final t = l.trim();
      if (!t.toUpperCase().startsWith('USB\\VID_')) continue;
      final c = t.split('|');
      out.add((
        id: c[0],
        servicio: c.length > 1 && c[1].trim().isNotEmpty ? c[1].trim() : null,
        problema: c.length > 2 ? (int.tryParse(c[2].trim()) ?? 0) : 0,
      ));
    }
    return out;
  }

  Future<EstadoDriver> estado(AccionDriver a) async {
    if (!esWindows) return EstadoDriver.listo; // no hay nada que instalar
    final v = await _presentes(a);
    if (v.isEmpty) return EstadoDriver.ausente;
    final listo = v.any(
        (d) => (d.servicio ?? '').toLowerCase() == 'winusb' && d.problema == 0);
    return listo ? EstadoDriver.listo : EstadoDriver.sinDriver;
  }

  /// Instala WinUSB para [a] y comprueba que quedó. El aparato TIENE que estar
  /// conectado (el modo C dura poco: hay que ir rápido después de enchufar).
  Future<ResultadoDriver> instalar(AccionDriver a,
      {void Function(String)? alLog}) async {
    void log(String s) => alLog?.call(s);
    if (!esWindows) {
      return const ResultadoDriver(
          true, 'Este sistema no necesita instalar ningún driver.');
    }
    var est = await estado(a);
    if (est == EstadoDriver.listo) {
      return ResultadoDriver(true, '${a.nombre} (${a.ids}) ya lleva WinUSB.');
    }
    if (est == EstadoDriver.ausente) {
      return ResultadoDriver(
          false,
          'No veo ${a.nombre} (${a.ids}) conectado. Enchúfalo (en modo C: '
          'apagado, tecla C pulsada y cable) y vuelve a pulsar «Instalar '
          'driver».');
    }
    final h = herramienta;
    if (h == null) {
      return ResultadoDriver(
          false,
          'Esta copia de SENUS no trae la herramienta de instalación '
          '(wdi-simple.exe). Hazlo a mano con Zadig: Options → List All '
          'Devices, elige «${a.nombre}», pon WinUSB y pulsa Install Driver.');
    }
    // La herramienta se lanza desde un .bat PROPIO: así tiene una carpeta de
    // trabajo escribible (`--dest`; sin ella usa «usb_driver» relativa a donde
    // arranque, que elevada es System32) y deja su salida en un registro que
    // luego se lee (con --silent no cuenta nada, ni por qué falla).
    final dir = Directory(p.join(trabajo.path, '${a._h(a.vid)}_${a._h(a.pid)}'));
    if (dir.existsSync()) {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }
    dir.createSync(recursive: true);
    final registro = File(p.join(dir.path, 'wdi.log'));
    final bat = File(p.join(dir.path, 'instalar_driver.bat'));
    bat.writeAsStringSync('@echo off\r\n'
        'cd /d "${dir.path}"\r\n'
        '"$h" --name "${a.nombre}" --vid 0x${a._h(a.vid)} '
        '--pid 0x${a._h(a.pid)} --type 0 --dest "${p.join(dir.path, 'driver')}" '
        '--log 2 > "${registro.path}" 2>&1\r\n'
        'exit /b %errorlevel%\r\n');
    log('Instalando WinUSB para ${a.nombre} (${a.ids}). Windows va a pedir '
        'permiso de administrador: acéptalo.');
    final codigo = await _elevado('cmd.exe', '/c ""${bat.path}""');
    String registroTexto() {
      try {
        final l = const LineSplitter()
            .convert(registro.readAsStringSync())
            .where((x) => x.trim().isNotEmpty)
            .toList();
        return l.skip(l.length > 12 ? l.length - 12 : 0).join('\n');
      } catch (_) {
        return '';
      }
    }

    if (codigo == codigoElevacionRechazada) {
      return const ResultadoDriver(
          false,
          'No se aceptó el permiso de administrador, así que no se instaló '
          'nada. Pulsa «Instalar driver» otra vez y acepta el aviso de '
          'Windows.');
    }
    if (codigo != 0) {
      final t = registroTexto();
      if (t.isNotEmpty) log('--- salida de wdi-simple:\n$t');
      return ResultadoDriver(
          false,
          'La instalación del driver terminó con error (código $codigo: '
          '${describirCodigoWdi(codigo)}). Comprueba que el teléfono siga en '
          'modo C y vuelve a intentarlo.'
          '${t.isEmpty ? '' : '\n\nÚltimas líneas de la herramienta:\n$t'}');
    }
    // Windows tarda un poco en asociar el driver al aparato.
    final fin = DateTime.now().add(espera);
    while (true) {
      est = await estado(a);
      if (est == EstadoDriver.listo) {
        return ResultadoDriver(
            true, 'Driver instalado: ${a.nombre} (${a.ids}) ya lleva WinUSB.');
      }
      if (est == EstadoDriver.ausente) {
        return const ResultadoDriver(
            false,
            'El driver se instaló, pero el teléfono dejó de verse (el modo C '
            'dura poco). Vuelve a ponerlo en modo C: ya no hará falta '
            'instalarlo otra vez.');
      }
      if (DateTime.now().isAfter(fin)) break;
      await Future<void>.delayed(intervalo);
    }
    return ResultadoDriver(
        false,
        'La herramienta terminó bien pero ${a.nombre} sigue sin WinUSB. '
        'Desenchufa y vuelve a enchufar el teléfono y pulsa «Instalar '
        'driver» otra vez.');
  }
}

// -------------------------------------------------------------------------- //
// Lo que de verdad toca el sistema
// -------------------------------------------------------------------------- //

/// PowerShell con el guion CODIFICADO (`-EncodedCommand`): no hay que pelear
/// con las comillas de cmd ni de Dart.
Future<String> _powerShellDeVerdad(String script) async {
  final bytes = <int>[];
  for (final u in script.codeUnits) {
    bytes
      ..add(u & 0xFF)
      ..add(u >> 8);
  }
  final r = await Process.run('powershell', [
    '-NoProfile',
    '-NonInteractive',
    '-EncodedCommand',
    base64.encode(bytes),
  ]);
  return '${r.stdout}';
}

/// `Start-Process -Verb RunAs -Wait`: Windows enseña su aviso de permisos. Si
/// la persona lo rechaza, PowerShell falla y devolvemos -1.
Future<int> _elevadoDeVerdad(String exe, String argumentos) async {
  String q(String s) => s.replaceAll("'", "''");
  final salida = await _powerShellDeVerdad('''
try {
  \$pr = Start-Process -FilePath '${q(exe)}' -ArgumentList '${q(argumentos)}' -Verb RunAs -Wait -PassThru -ErrorAction Stop
  "SALIDA=\$(\$pr.ExitCode)"
} catch {
  "SALIDA=$codigoElevacionRechazada"
}
''');
  final m = RegExp(r'SALIDA=(-?\d+)').firstMatch(salida);
  return m == null ? codigoElevacionRechazada : int.parse(m.group(1)!);
}
