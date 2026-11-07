#!/usr/bin/env python3
"""Arma los iconos de SENUS a partir de los PNG que dibuja
`tool/generar_iconos_test.dart` (build/iconos/icono_<tam>.png).

  windows/runner/resources/app_icon.ico                     multi-tamaño (PNG dentro)
  macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_<tam>.png

El .ico lleva cada tamaño dibujado por separado (16, 24, 32, 48, 64, 128, 256), no
uno reducido: es lo que hace que se vea nítido en la barra de tareas y en el
Explorador. Las entradas son PNG, válidas desde Windows Vista.

Uso (desde app/):  python3 -I tool/generar_iconos.py
"""
import os
import shutil
import struct
import sys

AQUI = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PNG = os.path.join(AQUI, 'build', 'iconos')
ICO = os.path.join(AQUI, 'windows', 'runner', 'resources', 'app_icon.ico')
MAC = os.path.join(AQUI, 'macos', 'Runner', 'Assets.xcassets', 'AppIcon.appiconset')
TAM_ICO = [16, 24, 32, 48, 64, 128, 256]
TAM_MAC = [16, 32, 64, 128, 256, 512, 1024]  # los nombres que ya cita Contents.json


def png(tam):
    ruta = os.path.join(PNG, f'icono_{tam}.png')
    if not os.path.isfile(ruta):
        sys.exit(f'falta {ruta}: corre antes `flutter test tool/generar_iconos_test.dart`')
    with open(ruta, 'rb') as f:
        b = f.read()
    if b[:8] != b'\x89PNG\r\n\x1a\n':
        sys.exit(f'{ruta} no es un PNG')
    w, h = struct.unpack('>II', b[16:24])
    if (w, h) != (tam, tam):
        sys.exit(f'{ruta} mide {w}x{h}, no {tam}x{tam}')
    return b


def escribir_ico():
    datos = [(t, png(t)) for t in TAM_ICO]
    cab = struct.pack('<HHH', 0, 1, len(datos))
    offset = 6 + 16 * len(datos)
    entradas, cuerpo = b'', b''
    for t, b in datos:
        entradas += struct.pack('<BBBBHHII', 0 if t == 256 else t, 0 if t == 256 else t,
                                0, 0, 1, 32, len(b), offset)
        cuerpo += b
        offset += len(b)
    with open(ICO, 'wb') as f:
        f.write(cab + entradas + cuerpo)
    print(f'{ICO}: {len(datos)} tamaños, {os.path.getsize(ICO)} B')


def escribir_mac():
    for t in TAM_MAC:
        shutil.copyfile(os.path.join(PNG, f'icono_{t}.png'), os.path.join(MAC, f'app_icon_{t}.png'))
        png(t)
    print(f'{MAC}: {len(TAM_MAC)} PNG')


if __name__ == '__main__':
    escribir_ico()
    escribir_mac()
