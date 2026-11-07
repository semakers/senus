#!/usr/bin/env python3
"""Genera assets/servicios/letra_telefono.bin desde la `para_telefono` de bt/musica_yt/servicio.py y test/fixtures/servicios/letra_oro.json.

  python generar_letra_telefono.py RUTA/bt/musica_yt/servicio.py SALIDA.bin ORO.json     (con anyascii instalado)

Para cada código de Unicode que no esté en la letra del teléfono guarda lo que da Python con ese carácter solo; además, las composiciones
NFC de dos códigos. La tabla no copia datos de la Roboto: solo lo que escribe `para_telefono`. anyascii es ISC."""
import gzip, importlib.util, json, random, struct, sys, unicodedata

spec = importlib.util.spec_from_file_location('w580_musica', sys.argv[1])
# el módulo importa cosas del servicio que aquí no hacen falta; basta su biblioteca estándar
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
P = m.PERMITIDOS
mapas = []
for c in range(0x80, 0x110000):
    if 0xD800 <= c < 0xE000: continue
    ch = chr(c)
    if ch in P: continue
    # el mismo cuerpo del bucle de para_telefono, carácter a carácter
    base = ''.join(x for x in unicodedata.normalize('NFKD', ch) if not unicodedata.combining(x))
    if base and all(x in P for x in base):
        t = base
    else:
        from anyascii import anyascii
        t = ''.join(x for x in anyascii(ch) if x in P)
        nombre = unicodedata.name(ch, '')
        if t and nombre.startswith(('CJK', 'HIRAGANA', 'KATAKANA', 'HANGUL')):
            t = ' ' + t + ' '
    if t:
        b = t.encode('utf-8')
        assert len(b) < 256
        mapas.append((c, b))
pares = []
for c in range(0x80, 0x110000):
    if 0xD800 <= c < 0xE000: continue
    d = unicodedata.normalize('NFD', chr(c))
    r = unicodedata.decomposition(chr(c))
    if not r or r.startswith('<'): continue
    p = [int(x, 16) for x in r.split()]
    if len(p) == 2 and unicodedata.normalize('NFC', chr(p[0]) + chr(p[1])) == chr(c):
        pares.append((p[0], p[1], c))
out = bytearray(struct.pack('<I', len(mapas)))
for c, b in mapas:
    out += struct.pack('<IB', c, len(b)) + b
out += struct.pack('<I', len(pares))
for a, b, c in pares:
    out += struct.pack('<III', a, b, c)
g = gzip.compress(bytes(out), 9, mtime=0)
open(sys.argv[2], 'wb').write(g)
print(len(mapas), 'mapas', len(pares), 'pares', len(out), 'B ->', len(g), 'B')

casos = ['Motörhead', 'Сплин', '米津玄師', '“comillas” tipográficas', 'a\tb\nc', 'Beyoncé', 'Sigur Rós', 'ÄÖÜ äöü ß', 'Ñandú', '¿Qué? ¡Sí!',
         'é ñ ö', 'Ｆｕｌｌ', 'ﬁn', 'Лев Толстой', 'ελληνικά', '日本語のテキスト', '한국어 노래', 'مرحبا', 'שלום', 'देवनागरी', '😀 emoji', '← → ↑ ↓ ✓ • · …',
         'x' * 200, 'ñ' * 100, 'Ñ' * 49, 'a' + '…' * 40, '   espacios   raros   ', '', 'Tiësto & Björk', 'Mötley Crüe – Dr. Feelgood', 'Café Tacvba']
r = random.Random(1)
trozos = [(0x20, 0x250), (0x370, 0x500), (0x3040, 0x3100), (0x4E00, 0x5200), (0xAC00, 0xAD00), (0x2000, 0x2100), (0x1F300, 0x1F400)]
for i in range(400):
    a, b = r.choice(trozos)
    casos.append(''.join(chr(r.randrange(a, b)) for _ in range(r.randrange(1, 30))))
oro = [{'s': s, 'max': x, 'r': m.para_telefono(s, x)} for s in casos for x in (96, 64, 16)]
json.dump(oro, open(sys.argv[3], 'w'), ensure_ascii=False)
print(len(oro), 'casos de oro')
