#!/usr/bin/env python3
"""Empotra en SENUS los artefactos del instalador anycid+trampoline del W580.

SENUS CONSUME estos ficheros, no los produce: este guion solo los COPIA tal cual
desde donde nacen y deja `app/assets/instalador/w580/MANIFIESTO.json` con el
sha256, el tamaño y el origen de cada uno. No abre, no recomprime ni toca el
contenido de ninguno.

Quién los produce:
  DB2020.zip                 senew-w580/herr/bl/empaquetar_db2020.py
                             (sale en build/installer/ y se copia a
                             seftool-senew/anycid/)
  R8BE001_*_GENERIC_*.zip    ORIGINALES de Sony Ericsson, intactos (el AMS valida
                             el cabecero CAFEB00B de su executor.b)
  sistema_44180000.bin       main de senew (sis28h), build/aparato_sis28h/
  bl.bin                     bootloader clásico, build/bl/

Uso (desde la raíz de SENUS):
    python3 -I app/tool/empotrar_instalador_w580.py [--sistema DIR] [--seftool DIR]

Solo copia si TODAS las comprobaciones de abajo pasan; si una falla no deja
nada a medias en assets/.
"""
import argparse
import datetime
import hashlib
import io
import json
import os
import shutil
import sys
import zipfile

RAIZ_SENUS = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DESTINO = os.path.join(RAIZ_SENUS, 'app', 'assets', 'instalador', 'w580')

# Los seis paquetes por región del R8BE001 que trae el fork (uno por CXC).
PAQUETES_R8BE001 = [
    'R8BE001_1201-7587_GENERIC_VI.zip',
    'R8BE001_CXC1123326_GENERIC_LY.zip',
    'R8BE001_CXC1123362_GENERIC_LA.zip',
    'R8BE001_CXC1250374_GENERIC_TH.zip',
    'R8BE001_CXC1250446_GENERIC_FY.zip',
    'R8BE001_CXC1250640_GENERIC_AI.zip',
]
MAGIA_AMS = bytes.fromhex('cafeb00b')
EXECUTOR_B = 'tpa/preset/custom/executor.b'
EXECUTOR_JAR = 'tpa/preset/custom/executor.jar'
CUSTOMIZE = 'tpa/preset/custom/customize_upgrade.xml'


def sha256(b):
    return hashlib.sha256(b).hexdigest()


def leer(ruta):
    with open(ruta, 'rb') as f:
        return f.read()


def comprobar_db2020(b):
    z = zipfile.ZipFile(io.BytesIO(b))
    nombres = z.namelist()
    for n in (EXECUTOR_JAR, CUSTOMIZE):
        if n not in nombres:
            raise SystemExit(f'DB2020.zip: falta {n}')
    if EXECUTOR_B in nombres:
        raise SystemExit(
            'DB2020.zip lleva un executor.b: el .b que valida el AMS es el '
            'ORIGINAL de SE y va en el zip R8BE001, no aquí (trampa pagada el '
            '2026-10-30).')
    jar = zipfile.ZipFile(io.BytesIO(z.read(EXECUTOR_JAR)))
    if 'cid52/db2020.bin' not in jar.namelist():
        raise SystemExit('DB2020.zip: el executor.jar no trae cid52/db2020.bin')
    n = len(jar.read('cid52/db2020.bin'))
    if n <= 0x1B0:
        raise SystemExit(f'DB2020.zip: cid52/db2020.bin mide {n} B, demasiado '
                         'corto para llevar el trampoline y el bl.bin')
    return {'db2020_bin_bytes': n}


def comprobar_r8be001(nombre, b):
    z = zipfile.ZipFile(io.BytesIO(b))
    if EXECUTOR_B not in z.namelist():
        raise SystemExit(f'{nombre}: no trae {EXECUTOR_B}')
    eb = z.read(EXECUTOR_B)
    if eb[:4] != MAGIA_AMS:
        raise SystemExit(f'{nombre}: executor.b sin el cabecero CAFEB00B '
                         f'(trae {eb[:4].hex()}): NO es el original de SE')
    return {'executor_b_bytes': len(eb), 'executor_b_sha256': sha256(eb)}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--sistema', default=os.path.expanduser('senew-w580'))
    ap.add_argument('--seftool', default=os.path.expanduser('seftool-senew'))
    ap.add_argument('--hito', default='aparato_sis28h',
                    help='carpeta de build/ con sistema_44180000.bin')
    a = ap.parse_args()

    fuentes = [('DB2020.zip', os.path.join(a.seftool, 'anycid', 'DB2020.zip'))]
    fuentes += [(n, os.path.join(a.seftool, 'anycid', n)) for n in PAQUETES_R8BE001]
    fuentes += [
        ('sistema_44180000.bin',
         os.path.join(a.sistema, 'build', a.hito, 'sistema_44180000.bin')),
        ('bl.bin', os.path.join(a.sistema, 'build', 'bl', 'bl.bin')),
    ]

    datos, extra = {}, {}
    for nombre, ruta in fuentes:
        if not os.path.isfile(ruta):
            raise SystemExit(f'no existe {ruta}')
        datos[nombre] = leer(ruta)
        if nombre == 'DB2020.zip':
            extra[nombre] = comprobar_db2020(datos[nombre])
        elif nombre in PAQUETES_R8BE001:
            extra[nombre] = comprobar_r8be001(nombre, datos[nombre])
    if len(datos['bl.bin']) != 5600:
        print(f"AVISO: bl.bin mide {len(datos['bl.bin'])} B (el probado en "
              'silicio el 2026-10-30 medía 5600).', file=sys.stderr)

    os.makedirs(DESTINO, exist_ok=True)
    ficheros = {}
    for nombre, ruta in fuentes:
        with open(os.path.join(DESTINO, nombre), 'wb') as f:
            f.write(datos[nombre])
        ficheros[nombre] = {
            'sha256': sha256(datos[nombre]),
            'bytes': len(datos[nombre]),
            'origen': ruta.replace(os.path.expanduser('~'), '~'),
            **extra.get(nombre, {}),
        }
    manifiesto = {
        'formato': 1,
        'generado_utc': datetime.datetime.now(datetime.timezone.utc)
                        .strftime('%Y-%m-%dT%H:%M:%SZ'),
        'aparato': 'W580',
        'flujo': 'anycid + trampoline + BL installer (1209:0003)',
        'verificado_en_silicio': {
            'paquete': 'R8BE001_CXC1123362_GENERIC_LA',
            'cid': 52,
            'fecha': '2026-10-30',
        },
        'ficheros': ficheros,
    }
    with open(os.path.join(DESTINO, 'MANIFIESTO.json'), 'w') as f:
        json.dump(manifiesto, f, indent=2, ensure_ascii=False)
        f.write('\n')
    total = sum(v['bytes'] for v in ficheros.values())
    print(f'{len(ficheros)} ficheros ({total} B) en {DESTINO}')
    for n, v in ficheros.items():
        print(f"  {v['sha256'][:16]}…  {v['bytes']:>8}  {n}")


if __name__ == '__main__':
    main()
