// Conexión: SENUS como puente a internet del teléfono. Encender el servidor
// Bluetooth, emparejar por el cable y ver quién está conectado. Solo hay internet
// con SENUS abierta. Debajo va lo que le pasen en `seccionServicios`: el dictado y
// la música.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../conexion/puente_nativo.dart';
import '../conexion/servicio_conexion.dart';
import '../datos/telefono.dart';
import '../mtp/canal_gestion.dart';
import '../mtp/sesion_mtp.dart';
import '../tema/senus_tema.dart';
import 'comunes.dart';

class PantConexion extends StatefulWidget {
  final ServicioConexion conexion;

  /// El teléfono por USB. Null si no hay cable: el puente sigue vivo y se puede
  /// mirar, pero no emparejar.
  final Telefono? telefono;
  final SesionMtp? sesion;

  /// La sección de dictado y música, si la hay.
  final Widget? seccionServicios;

  /// Volver a la pantalla de conectar, cuando no hay menú.
  final VoidCallback? onVolver;

  const PantConexion({
    super.key,
    required this.conexion,
    this.telefono,
    this.sesion,
    this.seccionServicios,
    this.onVolver,
  });

  @override
  State<PantConexion> createState() => _PantConexionState();
}

class _PantConexionState extends State<PantConexion> {
  @override
  void initState() {
    super.initState();
    widget.conexion.iniciar();
  }

  ServicioConexion get _s => widget.conexion;

  bool get _hayCanal =>
      widget.sesion != null && (widget.telefono?.canalGestion ?? false);

  /// Por qué no se puede emparejar ahora; null si se puede.
  String? get _porQueNo {
    if (widget.sesion == null) {
      return 'Conecta el teléfono por el cable USB para emparejarlo.';
    }
    if (!_hayCanal) {
      return 'Este senew no tiene canal de gestión: actualízalo primero.';
    }
    if (!_s.encendido) return 'Enciende antes el servidor Bluetooth.';
    return null;
  }

  Future<void> _emparejar() async {
    final s = widget.sesion;
    if (s == null) return;
    try {
      await _s.emparejar(CanalGestion(s));
    } on FalloEmparejar {
      // Ya está en `errorEmparejar`, y la tarjeta lo enseña.
    }
  }

  Future<void> _olvidar(String dir) async {
    final si = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('¿Olvidar este teléfono?'),
        content: Text('$dir ya no podrá salir a internet por este computador '
            'hasta que lo vuelvas a emparejar.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Olvidar')),
        ],
      ),
    );
    if (si != true) return;
    final delSistema = await _s.olvidar(dir);
    if (!mounted) return;
    avisar(
        context,
        delSistema
            ? 'Olvidado.'
            : 'Fuera de la lista. Si sigue en Ajustes de Bluetooth, quítalo '
                'también de ahí.');
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _s,
      builder: (context, _) {
        final bt = _s.bt;
        return ListView(
          padding: const EdgeInsets.only(bottom: Esp.x8),
          children: [
            CabeceraPantalla(
              titulo: 'Conexión',
              subtitulo: bt?.direccion ?? 'Internet para el teléfono',
              acciones: [
                if (widget.onVolver != null)
                  TextButton.icon(
                    onPressed: widget.onVolver,
                    icon: const Icon(Symbols.arrow_back, size: 18),
                    label: const Text('Volver'),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Esp.x8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _cuerpo(bt),
              ),
            ),
          ],
        );
      },
    );
  }

  List<Widget> _cuerpo(EstadoBt? bt) {
    if (bt == null) return const [Center(child: CircularProgressIndicator())];
    if (!bt.disponible) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Esp.x8),
          child: EstadoVacio(
            icono: Symbols.bluetooth_disabled,
            titulo: 'Sin puente en esta máquina',
            texto: bt.motivo,
          ),
        ),
      ];
    }
    final hueco = widget.seccionServicios;
    return [
      if (_s.error != null) ...[
        AvisoError(_s.error!),
        const SizedBox(height: Esp.x4),
      ],
      if (bt.permiso == PermisoBt.denegado ||
          bt.permiso == PermisoBt.restringido) ...[
        const FranjaAviso('SENUS no tiene permiso de Bluetooth. Actívalo en '
            'Ajustes del Sistema → Privacidad y seguridad → Bluetooth.'),
        const SizedBox(height: Esp.x4),
      ],
      _Servidor(s: _s, bt: bt),
      const SizedBox(height: Esp.x4),
      _Telefonos(s: _s),
      const SizedBox(height: Esp.x4),
      _Emparejar(s: _s, porQueNo: _porQueNo, onEmparejar: _emparejar),
      if (_s.permitidos.isNotEmpty) ...[
        const SizedBox(height: Esp.x4),
        _Permitidos(s: _s, onOlvidar: _olvidar),
      ],
      if (hueco != null) ...[const SizedBox(height: Esp.x4), hueco],
    ];
  }
}

class _Servidor extends StatelessWidget {
  final ServicioConexion s;
  final EstadoBt bt;
  const _Servidor({required this.s, required this.bt});

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    final enc = s.encendido;
    final yendo = s.estado == EstadoServidor.encendiendo;
    return Superficie(
      child: Row(
        children: [
          TejaIcono(enc ? Symbols.bluetooth_connected : Symbols.bluetooth),
          const SizedBox(width: Esp.x4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Flexible(
                    child: Text('Servidor Bluetooth',
                        style: context.tipo.titleMedium),
                  ),
                  const SizedBox(width: Esp.x2),
                  Etiqueta(
                    enc ? 'Encendido' : (yendo ? 'Encendiendo…' : 'Apagado'),
                    color: enc ? c.exito : null,
                  ),
                ]),
                const SizedBox(height: 2),
                Text(
                  enc
                      ? 'Tu teléfono sale a internet por este computador mientras '
                          'SENUS esté abierta.'
                      : 'Solo hay internet con SENUS abierta: al cerrarla se apaga.',
                  style: context.tipo.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(width: Esp.x4),
          if (enc)
            OutlinedButton.icon(
              key: const ValueKey('apagarServidor'),
              onPressed: s.emparejando ? null : s.apagar,
              icon: const Icon(Symbols.power_settings_new, size: 18),
              label: const Text('Apagar'),
            )
          else
            Pulsable(
              activo: !yendo,
              child: FilledButton.icon(
                key: const ValueKey('encenderServidor'),
                onPressed: yendo ? null : s.encender,
                icon: const Icon(Symbols.power_settings_new, size: 18),
                label: const Text('Encender'),
              ),
            ),
        ],
      ),
    );
  }
}

class _Telefonos extends StatelessWidget {
  final ServicioConexion s;
  const _Telefonos({required this.s});

  static String _vel(double b) =>
      '${(b / 1024).toStringAsFixed(b < 10240 ? 1 : 0)} KB/s';

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    final l = s.telefonos;
    return Superficie(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text('Teléfono conectado', style: context.tipo.titleMedium),
            ),
            if (l.isNotEmpty) ...[
              Etiqueta(_vel(s.velBaja),
                  key: const ValueKey('velBaja'),
                  icono: Symbols.arrow_downward,
                  mono: true,
                  color: c.acento),
              const SizedBox(width: Esp.x2),
              Etiqueta(_vel(s.velSube),
                  key: const ValueKey('velSube'),
                  icono: Symbols.arrow_upward,
                  mono: true),
            ],
          ]),
          const SizedBox(height: Esp.x2),
          if (l.isEmpty)
            Text(
                s.encendido
                    ? 'Ninguno. SENUS llama al teléfono cuando una app suya necesita red.'
                    : 'Ninguno: el servidor está apagado.',
                style: context.tipo.bodySmall)
          else
            for (final t in l)
              Padding(
                padding: const EdgeInsets.only(top: Esp.x1),
                child: Row(children: [
                  Icon(Symbols.smartphone,
                      size: 18, color: t.saludado ? c.exito : c.textoTenue),
                  const SizedBox(width: Esp.x2),
                  Expanded(
                    child: Text(
                      t.nombre.isEmpty ? t.direccion : t.nombre,
                      style: context.tipo.bodyMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(t.direccion, style: estiloDatos(context, tam: 11)),
                ]),
              ),
        ],
      ),
    );
  }
}

class _Emparejar extends StatelessWidget {
  final ServicioConexion s;
  final String? porQueNo;
  final VoidCallback onEmparejar;
  const _Emparejar(
      {required this.s, required this.porQueNo, required this.onEmparejar});

  @override
  Widget build(BuildContext context) {
    final puede = porQueNo == null && !s.emparejando;
    final fase = s.faseEmparejar;
    final pin = s.pinEmparejar;
    final err = s.errorEmparejar;
    return Superficie(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            const TejaIcono(Symbols.cable),
            const SizedBox(width: Esp.x4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Emparejar por el cable',
                      style: context.tipo.titleMedium),
                  const SizedBox(height: 2),
                  Text(
                    porQueNo ??
                        'Al acabar, quitas el cable y el teléfono sale a '
                            'internet por este computador.',
                    style: context.tipo.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: Esp.x4),
            Pulsable(
              activo: puede,
              child: FilledButton.icon(
                key: const ValueKey('emparejar'),
                onPressed: puede ? onEmparejar : null,
                icon: const Icon(Symbols.link, size: 18),
                label: const Text('Emparejar'),
              ),
            ),
          ]),
          if (fase != null) ...[
            const SizedBox(height: Esp.x4),
            const LinearProgressIndicator(minHeight: 2),
            const SizedBox(height: Esp.x2),
            Text(fase, style: context.tipo.bodyMedium),
            if (pin != null) ...[
              const SizedBox(height: Esp.x1),
              Text('Si este computador te pide un PIN, escribe $pin.',
                  style: context.tipo.bodySmall),
            ],
          ],
          if (s.listoEmparejar && fase == null) ...[
            const SizedBox(height: Esp.x4),
            Row(children: [
              Icon(Symbols.check_circle,
                  color: context.col.exito, fill: 1, size: 20),
              const SizedBox(width: Esp.x2),
              Expanded(
                child: Text('Puente listo: ya puedes quitar el cable',
                    style: context.tipo.titleSmall),
              ),
            ]),
          ],
          if (err != null && fase == null) ...[
            const SizedBox(height: Esp.x4),
            AvisoError(err),
          ],
        ],
      ),
    );
  }
}

class _Permitidos extends StatelessWidget {
  final ServicioConexion s;
  final ValueChanged<String> onOlvidar;
  const _Permitidos({required this.s, required this.onOlvidar});

  @override
  Widget build(BuildContext context) {
    return Superficie(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Teléfonos emparejados', style: context.tipo.titleMedium),
          const SizedBox(height: Esp.x2),
          for (final d in s.permitidos)
            Row(children: [
              Expanded(
                child: Text(d, style: estiloDatos(context, tam: 12.5)),
              ),
              TextButton(
                key: ValueKey('olvidar$d'),
                onPressed: () => onOlvidar(d),
                child: const Text('Olvidar'),
              ),
            ]),
        ],
      ),
    );
  }
}
