#!/usr/bin/env python3
"""Mete PuenteBluetooth.swift y PuenteBluetoothCanal.swift en un project.pbxproj.

Hace falta en las copias de la Mac, cuyo `Runner.xcodeproj` difiere del del repo por
CocoaPods y no se sincroniza. Sin esto, `MainFlutterWindow.swift` no compila. Se
puede repetir: si ya están, no hace nada.

  anadir_puente_bt_a_xcode.py RUTA/macos/Runner.xcodeproj/project.pbxproj
"""
import sys

FICHEROS = [
    ('PuenteBluetooth.swift', '5E4A7B002EB0000100A1B2C3', '5E4A7B012EB0000100A1B2C3'),
    ('PuenteBluetoothCanal.swift', '5E4A7B022EB0000100A1B2C3', '5E4A7B032EB0000100A1B2C3'),
]
VENTANA = 'MainFlutterWindow.swift'


def tras_linea(s, marca, nuevas):
    """Inserta `nuevas` tras la línea que contiene `marca`, que debe ser única."""
    if s.count(marca) != 1:
        sys.exit('no encuentro una sola línea con: ' + marca)
    fin = s.index('\n', s.index(marca)) + 1
    return s[:fin] + nuevas + s[fin:]


def main():
    ruta = sys.argv[1]
    with open(ruta, encoding='utf-8') as f:
        s = f.read()
    if FICHEROS[0][0] in s:
        print('ya estaba')
        return
    compila, referencia, grupo, fuentes = '', '', '', ''
    for nombre, ref, comp in FICHEROS:
        compila += ('\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };\n'
                    % (comp, nombre, ref, nombre))
        referencia += ('\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; '
                       'path = %s; sourceTree = "<group>"; };\n' % (ref, nombre, nombre))
        grupo += '\t\t\t\t%s /* %s */,\n' % (ref, nombre)
        fuentes += '\t\t\t\t%s /* %s in Sources */,\n' % (comp, nombre)
    s = tras_linea(s, '/* %s in Sources */ = {isa = PBXBuildFile' % VENTANA, compila)
    s = tras_linea(s, '/* %s */ = {isa = PBXFileReference' % VENTANA, referencia)
    s = tras_linea(s, '/* %s */,' % VENTANA, grupo)
    s = tras_linea(s, '/* %s in Sources */,' % VENTANA, fuentes)
    with open(ruta, 'w', encoding='utf-8') as f:
        f.write(s)
    print('añadidos')


if __name__ == '__main__':
    main()
