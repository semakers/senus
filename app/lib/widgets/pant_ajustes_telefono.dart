// Ajustes del teléfono: los 26 campos, en grupos con nombres para personas. Los
// rangos los dice el firmware. Se aplica con un botón; después se relee y se
// compara, y lo que no se aplicó se enseña con lo que el teléfono dijo.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../datos/ajustes_senew.dart';
import '../datos/telefono.dart';
import '../mtp/canal_gestion.dart';
import '../mtp/sesion_mtp.dart';
import '../mtp/transporte.dart' show TransporteError;
import '../tema/senus_tema.dart';
import 'comunes.dart';

class PantAjustesTelefono extends StatefulWidget {
  final Telefono telefono;
  final SesionMtp? sesion;
  final VoidCallback? onVersion;

  /// Para las pruebas: la hora del computador.
  final DateTime Function() ahora;

  const PantAjustesTelefono({
    super.key,
    required this.telefono,
    required this.sesion,
    this.onVersion,
    this.ahora = DateTime.now,
  });

  @override
  State<PantAjustesTelefono> createState() => _PantAjustesTelefonoState();
}

class _PantAjustesTelefonoState extends State<PantAjustesTelefono> {
  List<AjusteLeido> _ajustes = const [];
  final Map<int, Object> _cambios = {};
  bool _cargando = true;
  bool _trabajando = false;
  String? _error;
  ResultadoAjustes? _resultado;

  ServicioAjustes? get _servicio {
    final s = widget.sesion;
    if (s == null || !widget.telefono.canalGestion) return null;
    return ServicioAjustes(CanalGestion(s));
  }

  @override
  void initState() {
    super.initState();
    _leer();
  }

  /// [conservar]: no tira lo que la persona lleva cambiado sin aplicar.
  Future<void> _leer({bool conservar = false}) async {
    final s = _servicio;
    if (s == null) {
      setState(() => _cargando = false);
      return;
    }
    setState(() {
      _cargando = true;
      _error = null;
    });
    try {
      final l = await s.leer();
      if (!mounted) return;
      setState(() {
        _ajustes = l;
        if (!conservar) _cambios.clear();
      });
    } on CanalError catch (e) {
      if (mounted) setState(() => _error = 'No se pudieron leer: $e');
    } on CanalMalFormado catch (e) {
      if (mounted) setState(() => _error = '$e');
    } on TransporteError catch (e) {
      if (mounted) setState(() => _error = 'Se perdió la conexión: ${e.motivo}');
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  Object _valor(AjusteLeido a) => _cambios[a.clave] ?? a.valor;

  void _cambiar(AjusteLeido a, Object v) {
    setState(() {
      _resultado = null;
      if (v == a.valor) {
        _cambios.remove(a.clave);
      } else {
        _cambios[a.clave] = v;
      }
    });
  }

  Future<void> _aplicar() async {
    final s = _servicio;
    if (s == null || _cambios.isEmpty) return;
    final porClave = {for (final a in _ajustes) a.clave: a};
    final lista = [
      for (final e in _cambios.entries)
        AjustePoner(e.key, porClave[e.key]!.tipo, e.value)
    ];
    setState(() => _trabajando = true);
    try {
      final r = await s.aplicar(lista, _ajustes);
      if (!mounted) return;
      setState(() {
        _resultado = r;
        _ajustes = r.releidos;
        _cambios.clear();
      });
    } on CanalError catch (e) {
      _avisar('$e', bien: false);
    } on CanalMalFormado catch (e) {
      _avisar('$e', bien: false);
    } on TransporteError catch (e) {
      _avisar('Se perdió la conexión: ${e.motivo}', bien: false);
    } finally {
      if (mounted) setState(() => _trabajando = false);
    }
  }

  Future<void> _ponerHora() async {
    final s = _servicio;
    if (s == null) return;
    setState(() => _trabajando = true);
    try {
      final ahora = widget.ahora();
      await s.ponerHora(ahora);
      _avisar('Hora puesta: ${ahora.toString().substring(0, 19)}');
      await _leer(conservar: true); // la zona pudo cambiar
    } on CanalError catch (e) {
      _avisar('$e', bien: false);
    } on TransporteError catch (e) {
      _avisar('Se perdió la conexión: ${e.motivo}', bien: false);
    } finally {
      if (mounted) setState(() => _trabajando = false);
    }
  }

  void _avisar(String t, {bool bien = true}) {
    if (mounted) avisar(context, t, bien: bien);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.telefono.canalGestion) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const CabeceraPantalla(titulo: 'Ajustes del teléfono'),
          const Expanded(
            child: EstadoVacio(
              icono: Symbols.system_update,
              titulo: 'Hay que actualizar senew',
              texto: 'Este senew no tiene canal de gestión: sus ajustes solo '
                  'se cambian en el teléfono.',
            ),
          ),
          if (widget.onVersion != null)
            Padding(
              padding: const EdgeInsets.only(bottom: Esp.x8),
              child: Center(
                child: FilledButton(
                    onPressed: widget.onVersion,
                    child: const Text('Ver versión')),
              ),
            ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CabeceraPantalla(
          titulo: 'Ajustes del teléfono',
          subtitulo: '${_ajustes.length} ajustes, leídos del teléfono',
          acciones: [
            IconButton(
              onPressed: _cargando || _trabajando ? null : _leer,
              icon: const Icon(Symbols.refresh),
              tooltip: 'Volver a leer',
            ),
            if (_cambios.isNotEmpty)
              TextButton(
                onPressed: _trabajando
                    ? null
                    : () => setState(() {
                          _cambios.clear();
                          _resultado = null;
                        }),
                child: const Text('Deshacer'),
              ),
            Pulsable(
              activo: _cambios.isNotEmpty && !_trabajando,
              child: FilledButton.icon(
                onPressed: _cambios.isEmpty || _trabajando ? null : _aplicar,
                icon: const Icon(Symbols.check, size: 20),
                label: Text(_cambios.isEmpty
                    ? 'Sin cambios'
                    : 'Aplicar ${_cambios.length}'),
              ),
            ),
          ],
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(Esp.x8, 0, Esp.x8, Esp.x4),
            child: AvisoError(_error!),
          ),
        if (_resultado != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(Esp.x8, 0, Esp.x8, Esp.x4),
            child: _Resultado(_resultado!),
          ),
        AnimatedContainer(
          duration: Mov.normal,
          height: _trabajando ? 2 : 0,
          margin: const EdgeInsets.symmetric(horizontal: Esp.x8),
          child: _trabajando ? const LinearProgressIndicator(minHeight: 2) : null,
        ),
        Expanded(child: _lista()),
      ],
    );
  }

  Widget _lista() {
    if (_cargando) {
      return const Center(child: CircularProgressIndicator());
    }
    final grupos = <GrupoAjuste, List<AjusteLeido>>{};
    for (final a in _ajustes) {
      (grupos[defDe(a.clave)?.grupo ?? GrupoAjuste.otros] ??= []).add(a);
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(Esp.x8, Esp.x2, Esp.x8, Esp.x8),
      children: [
        for (final g in GrupoAjuste.values)
          if (grupos[g] != null) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(Esp.x1, Esp.x4, 0, Esp.x2),
              child: Text(g.nombre.toUpperCase(), style: context.tipo.labelSmall),
            ),
            Superficie(
              relleno: const EdgeInsets.symmetric(
                  horizontal: Esp.x4, vertical: Esp.x2),
              child: Column(
                children: [
                  if (g == GrupoAjuste.relojAlarma)
                    _FilaHora(
                        ocupado: _trabajando,
                        ahora: widget.ahora,
                        onPoner: _ponerHora),
                  for (final a in _ordenados(g, grupos[g]!))
                    _FilaAjuste(
                      key: ValueKey(a.clave),
                      ajuste: a,
                      valor: _valor(a),
                      cambiado: _cambios.containsKey(a.clave),
                      activo: !_trabajando,
                      onCambio: (v) => _cambiar(a, v),
                    ),
                ],
              ),
            ),
          ],
      ],
    );
  }

  /// En el orden de `defsAjustes`; las desconocidas, por clave.
  List<AjusteLeido> _ordenados(GrupoAjuste g, List<AjusteLeido> l) {
    if (g == GrupoAjuste.otros) {
      return [...l]..sort((a, b) => a.clave.compareTo(b.clave));
    }
    int pos(AjusteLeido a) => defsAjustes.indexWhere((d) => d.clave == a.clave);
    return [...l]..sort((a, b) => pos(a).compareTo(pos(b)));
  }
}

class _Resultado extends StatelessWidget {
  final ResultadoAjustes r;
  const _Resultado(this.r);

  String _texto(Object? v, int clave) {
    if (v == null) return '(el teléfono ya no lo lista)';
    if (v is bool) return v ? 'sí' : 'no';
    final o = defDe(clave)?.opciones ?? const {};
    return v is int ? (o[v] ?? '$v') : '«$v»';
  }

  @override
  Widget build(BuildContext context) {
    final lineas = <String>[
      if (r.respuesta.fueraDeRango > 0)
        '${r.respuesta.fueraDeRango} fuera de rango',
      if (r.respuesta.desconocidas > 0)
        '${r.respuesta.desconocidas} que este senew no conoce',
      for (final d in r.noAplicadas)
        '${d.nombre}: se pidió ${_texto(d.pedido, d.clave)} y el teléfono '
            'tiene ${_texto(d.leido, d.clave)}',
      for (final d in r.corregidos)
        '${d.nombre} cambió solo: de ${_texto(d.pedido, d.clave)} a '
            '${_texto(d.leido, d.clave)}',
    ];
    if (r.todoBien && r.corregidos.isEmpty) {
      return FranjaAviso(textoAplicados(r.aplicadas.length, frase: true));
    }
    final cab = r.todoBien
        ? textoAplicados(r.aplicadas.length)
        : 'No se aplicó todo (${r.aplicadas.length} de '
            '${r.aplicadas.length + r.noAplicadas.length}):';
    final texto = '$cab\n${lineas.join('\n')}';
    return r.todoBien ? FranjaAviso(texto) : AvisoError(texto);
  }
}

class _FilaHora extends StatelessWidget {
  final bool ocupado;
  final DateTime Function() ahora;
  final VoidCallback onPoner;
  const _FilaHora(
      {required this.ocupado, required this.ahora, required this.onPoner});

  @override
  Widget build(BuildContext context) {
    final t = ahora();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Esp.x2),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Hora del teléfono', style: context.tipo.titleSmall),
                Text('Pone la del computador: '
                    '${t.toString().substring(0, 16)}, '
                    '${textoZona(t.timeZoneOffset.inMinutes)}',
                    style: context.tipo.bodySmall),
              ],
            ),
          ),
          OutlinedButton.icon(
            onPressed: ocupado ? null : onPoner,
            icon: const Icon(Symbols.schedule, size: 18),
            label: const Text('Poner la hora'),
          ),
        ],
      ),
    );
  }
}

class _FilaAjuste extends StatelessWidget {
  final AjusteLeido ajuste;
  final Object valor;
  final bool cambiado;
  final bool activo;
  final ValueChanged<Object> onCambio;
  const _FilaAjuste({
    super.key,
    required this.ajuste,
    required this.valor,
    required this.cambiado,
    required this.activo,
    required this.onCambio,
  });

  DefAjuste? get _def => defDe(ajuste.clave);

  ModoEdicion get _modo {
    if (ajuste.esBool) return ModoEdicion.interruptor;
    if (ajuste.esTexto) return ModoEdicion.texto;
    return _def?.modo ?? ModoEdicion.deslizador;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    final d = _def;
    final nombre = d?.nombre ?? 'Clave 0x${ajuste.clave.toRadixString(16)}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Esp.x2),
      child: Row(
        children: [
          AnimatedContainer(
            duration: Mov.normal,
            width: 3,
            height: 22,
            margin: const EdgeInsets.only(right: Esp.x3),
            decoration: BoxDecoration(
              color: cambiado ? c.acento : Colors.transparent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            flex: 5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(nombre, style: context.tipo.titleSmall),
                if (d?.ayuda != null)
                  Text(d!.ayuda!, style: context.tipo.bodySmall),
              ],
            ),
          ),
          const SizedBox(width: Esp.x4),
          Expanded(
            flex: 6,
            child: Align(
                alignment: Alignment.centerRight, child: _control(context)),
          ),
        ],
      ),
    );
  }

  Widget _control(BuildContext context) {
    switch (_modo) {
      case ModoEdicion.interruptor:
        return Switch(
          value: valor is bool ? valor as bool : valor != 0,
          onChanged: activo ? (v) => onCambio(v) : null,
        );
      case ModoEdicion.opciones:
        return _opciones();
      case ModoEdicion.zona:
        return _zona(context);
      case ModoEdicion.texto:
        return _CampoTexto(
          valor: valor is String ? valor as String : '',
          max: ajuste.max,
          activo: activo,
          onCambio: onCambio,
        );
      case ModoEdicion.deslizador:
        return _deslizador(context);
    }
  }

  /// Las opciones que el firmware admite, y el valor actual aunque no tenga
  /// nombre: nunca se enseña otro valor del que hay.
  Widget _opciones() {
    final actual = valor as int;
    final nombres = _def?.opciones ?? const <int, String>{};
    final validos = <int>{
      for (final k in nombres.keys)
        if (k >= ajuste.min && k <= ajuste.max) k,
      actual,
    }.toList()
      ..sort();
    return DropdownButton<int>(
      value: actual,
      isExpanded: true,
      onChanged: activo ? (v) => onCambio(v!) : null,
      items: [
        for (final v in validos)
          DropdownMenuItem(value: v, child: Text(nombres[v] ?? '$v')),
      ],
    );
  }

  Widget _zona(BuildContext context) {
    final v = valor as int;
    void paso(int d) => onCambio((v + d).clamp(ajuste.min, ajuste.max));
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const ValueKey('zonaMenos'),
          tooltip: '-15 min',
          icon: const Icon(Symbols.remove),
          onPressed: activo && v > ajuste.min ? () => paso(-15) : null,
        ),
        SizedBox(
          width: 84,
          child: Text(textoZona(v),
              textAlign: TextAlign.center, style: estiloDatos(context, tam: 13)),
        ),
        IconButton(
          tooltip: '+15 min',
          icon: const Icon(Symbols.add),
          onPressed: activo && v < ajuste.max ? () => paso(15) : null,
        ),
      ],
    );
  }

  Widget _deslizador(BuildContext context) {
    final v = (valor as int).clamp(ajuste.min, ajuste.max);
    final unidad = _def?.unidad ?? '';
    return Row(
      children: [
        Expanded(
          child: Slider(
            value: v.toDouble(),
            min: ajuste.min.toDouble(),
            max: ajuste.max.toDouble(),
            divisions: ajuste.max > ajuste.min ? ajuste.max - ajuste.min : null,
            label: '$v$unidad',
            onChanged: activo ? (x) => onCambio(x.round()) : null,
          ),
        ),
        SizedBox(
          width: 56,
          child: Text('$v$unidad',
              textAlign: TextAlign.right, style: estiloDatos(context, tam: 13)),
        ),
      ],
    );
  }
}

class _CampoTexto extends StatefulWidget {
  final String valor;
  final int max;
  final bool activo;
  final ValueChanged<Object> onCambio;
  const _CampoTexto(
      {required this.valor,
      required this.max,
      required this.activo,
      required this.onCambio});

  @override
  State<_CampoTexto> createState() => _CampoTextoState();
}

class _CampoTextoState extends State<_CampoTexto> {
  late final TextEditingController _c =
      TextEditingController(text: widget.valor);

  @override
  void didUpdateWidget(covariant _CampoTexto old) {
    super.didUpdateWidget(old);
    if (widget.valor != _c.text) _c.text = widget.valor;
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _c,
      enabled: widget.activo,
      maxLength: widget.max,
      decoration: const InputDecoration(isDense: true, counterText: ''),
      onChanged: widget.onCambio,
    );
  }
}
