// Ajustes — apariencia (oscuro / claro) y «acerca de».

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../datos/version_senus.dart';
import '../tema/senus_tema.dart';
import 'comunes.dart';

class PantAjustes extends StatelessWidget {
  final ThemeMode modo;
  final ValueChanged<ThemeMode> onModo;
  const PantAjustes({super.key, required this.modo, required this.onModo});

  @override
  Widget build(BuildContext context) {
    final c = context.col;
    return ListView(
      children: [
        const CabeceraPantalla(titulo: 'Ajustes', subtitulo: 'SENUS $versionSenus'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Esp.x8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              EntradaSuave(
                child: Superficie(
                  child: Row(
                    children: [
                      const TejaIcono(Symbols.contrast),
                      const SizedBox(width: Esp.x4),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Apariencia', style: context.tipo.titleMedium),
                            const SizedBox(height: 2),
                            Text('Grafito, como el teléfono con la luz apagada; o papel claro.',
                                style: context.tipo.bodySmall),
                          ],
                        ),
                      ),
                      const SizedBox(width: Esp.x4),
                      SegmentedButton<ThemeMode>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(
                            value: ThemeMode.dark,
                            icon: Icon(Symbols.dark_mode, size: 18),
                            label: Text('Oscuro'),
                          ),
                          ButtonSegment(
                            value: ThemeMode.light,
                            icon: Icon(Symbols.light_mode, size: 18),
                            label: Text('Claro'),
                          ),
                        ],
                        selected: {modo == ThemeMode.light ? ThemeMode.light : ThemeMode.dark},
                        onSelectionChanged: (s) => onModo(s.first),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: Esp.x4),
              EntradaSuave(
                retraso: escalon(1),
                child: Superficie(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const LogoSenus(tam: 44),
                      const SizedBox(width: Esp.x4),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Sony Ericsson New Update Service',
                                style: context.tipo.titleMedium),
                            const SizedBox(height: Esp.x1),
                            Text(
                              'Instala y mantiene senew en el W580i. '
                              'Software libre de semakers.',
                              style: context.tipo.bodyMedium?.copyWith(color: c.textoTenue),
                            ),
                            const SizedBox(height: Esp.x2),
                            Text(
                              'Es un proyecto nuevo: se usa bajo tu propio riesgo. '
                              'Sin relación con Sony ni con Sony Ericsson.',
                              style: context.tipo.bodySmall?.copyWith(color: c.textoTenue),
                            ),
                            const SizedBox(height: Esp.x3),
                            Wrap(
                              spacing: Esp.x2,
                              runSpacing: Esp.x2,
                              children: [
                                Etiqueta('v$versionSenus', mono: true, color: c.acento),
                                const Etiqueta('GPL-3.0-or-later', mono: true),
                                const Etiqueta('Inter · JetBrains Mono (OFL)'),
                              ],
                            ),
                            const SizedBox(height: Esp.x3),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton.icon(
                                icon: const Icon(Symbols.license, size: 18),
                                label: const Text('Licencias'),
                                onPressed: () => showLicensePage(
                                  context: context,
                                  applicationName: 'SENUS',
                                  applicationVersion: versionSenus,
                                  applicationLegalese: 'GPL-3.0 · semakers',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
