# Guion de validación en el aparato (fase 1)

Antes de ejecutar, repasar DISENO.md §7. Este guion es el papel que acompaña a los tres teléfonos
cuando lleguen a la mesa con senew ya instalado. Nada de aquí se corre sin aparato.

Marcas al final: ESPERADO (lo que debería pasar), MEDIDA (lo que midas con una captura o nota),
VEREDICTO (BIEN/MAL con una línea de por qué).

## 0. Preparación

- SENUS compilado en Linux (release). Un W580i, un W600i, un W810i, todos con senew.
- Un cable USB bueno (de datos). En Windows, driver WinUSB instalado para 1209:0001.
- Dos ficheros de prueba subidos a `/mis_archivos` desde el teléfono (`nota.txt` 1 KiB y una foto
  JPG de ~200 KiB).
- Un fichero `.sen` de prueba (por ejemplo `juego.sen` del banco), en el PC.

## 1. Enumerar los tres aparatos

**Pasos:** Conectar cada teléfono por USB. En SENUS, pantalla «Conectar».
**Esperado:** cada uno aparece una vez con el nombre amistoso correcto
(`W580 sistema propio` / `W600 sistema propio` / `W810 sistema propio`). Al desconectar, desaparece.

## 2. Pantalla «Inicio del teléfono» por aparato

**Pasos:** Elegir el teléfono.
**Esperado:**
- Modelo y SoC acertados (W580/DB2020; W600/DB2010; W810/DB2010).
- Versión senew (bcdDevice del descriptor USB, hoy 0.19).
- **Memoria**: libre/total **cuadran** con lo que dice el propio teléfono en «Mis archivos» ±8 KiB.
- **Tarjeta/NAND**:
  - W580 sin Memory Stick → «no hay».
  - W580 con MS → libre/total cuadra.
  - W600 → la NAND interna como «Tarjeta» con ~225 MiB.
  - W810 → la Memory Stick si la hay. Si el aparato arranca en blanco, V3/V4 deshabilitadas.

## 3. Apps instaladas

**Pasos:** Pestaña Apps.
**Esperado:** Lista completa de `/apps`. Las utilidades de fábrica marcadas (sin botón de borrar).

## 4. Subir una `.sen` al teléfono

**Pasos:** «Subir .sen» → elegir `juego.sen` del PC.
**Esperado:** barra de progreso, luego la nueva app aparece en la lista. En el teléfono,
desbloquear → menú → `juego` sale.

## 5. Bajar una `.sen`

**Pasos:** marcar `juego.sen` → «Bajar».
**Esperado:** fichero local idéntico (SHA-256) al que se subió.

## 6. Borrar una `.sen`

**Pasos:** marcar `juego.sen` → «Borrar» → confirmar.
**Esperado:** desaparece de la lista. En el teléfono, al salir del menú y volver, ya no está.

## 7. Respaldar

**Pasos:** pestaña Respaldo → «Hacer respaldo».
**Esperado:** `senus-respaldo-W580-...zip` con `manifiesto.json`, `device_info.bin`,
`memoria/mis_archivos/nota.txt`, `memoria/mis_archivos/foto.jpg`. Los SHA-256 del manifiesto cuadran.

## 8. Restaurar en el MISMO aparato

**Pasos:** Borrar `nota.txt` y `foto.jpg` del teléfono. En SENUS, Respaldo → «Elegir .zip…» → aceptar.
**Esperado:** los dos ficheros vuelven a `/mis_archivos`; SHA-256 cuadran.

## 9. Restaurar en OTRO aparato

**Pasos:** mismo `.zip` pero con el W600 conectado; marcar «Restaurar en otro aparato».
**Esperado:** sube con éxito, con un aviso al principio por el serial distinto.

## 10. Casos borde

- **Cable fuera a mitad de SendObject grande** (p. ej. .sen de 1 MiB): SENUS marca «no subido»;
  el teléfono NO deja un fichero a medias en `/apps` (el temporal se descarta en el responder).
- **Memoria llena**: subir una `.sen` que no cabe → `R_LLENA`; SENUS avisa «no hay sitio».
- **Tarjeta protegida (W580)**: la 2.ª storage sale como solo lectura; el botón de subir se
  deshabilita para esa storage.
