# Contrato del canal de gestión MTP (senew ↔ SENUS)

Fuente única de verdad entre el firmware (`sistema/api/mtp.c`) y el cliente (`app/lib/mtp/`). Concreta el §4.2 del diseño. Todo es
little-endian. Si algo de esto resulta imposible, se cambia **aquí primero** y se anota al final en «Cambios».

Motivo de lo que difiere del diseño: una operación MTP con datos de salida no puede devolver datos, solo 3 parámetros en la respuesta;
y `m.dat` y `m.ent` son de 1024 B.

## 1. Reglas comunes

- Se detecta por `OperationsSupported` de `GetDeviceInfo`: si trae `0x9400`, hay canal. Si no (sis28h), SENUS degrada: lista por MTP y
  pide actualizar.
- Todas exigen sesión abierta, y por tanto el «Sí» en el teléfono. Sin sesión: `R_SIN_SESION` (0x2003).
- Respuestas: `R_OK` 0x2001, `R_OCUPADO` 0x2019 (reintenta), `R_DENEGADO` 0x200F (el usuario dijo «No»), `R_PARAM_MAL` 0x201D (dataset
  mal formado; no se aplicó nada), `R_OP_NO` 0x2005 (no implementada).
- Los textos son ASCII/UTF-8 terminados en NUL, salvo el tipo 4, que lleva `largo`.

| Código | Orden | Datos | Parámetros |
|---|---|---|---|
| 0x9400 | `SEN_INFO` | entrada | — |
| 0x9401 | `SEN_AJ_LEER` | entrada | — |
| 0x9402 | `SEN_AJ_PONER` | salida | — ; respuesta: aplicadas, fuera de rango, desconocidas |
| 0x9403 | `SEN_RELOJ` | salida | — |
| 0x9404 | `SEN_VINCULAR` | salida | — |
| 0x9405 | `SEN_ENTRAR_BL` | ninguna | — |
| 0x9406 | `SEN_BT_ESTADO` | entrada | — |
| 0x9407 | `SEN_BT_EMPAREJAR` | salida | Ver §4. Desde senew 0.29.1 |
| 0x9408 | `SEN_APPS` | entrada | p1 = desde |

## 2. `SEN_INFO`: 128 bytes fijos

| Despl. | Tipo | Campo |
|---|---|---|
| 0 | u16 | `formato` = 1 |
| 2 | u16 | `tam` = 128 |
| 4 | u32 | `build` |
| 8 | u16 | `api_mayor` |
| 10 | u16 | `api_menor` |
| 12 | u16 | `bl_version`; 0 = no se sabe. La fuente real es `BL_R_ID` |
| 14 | u8 | `bateria_pct`, 0..100; 0xFF = no se sabe |
| 15 | u8 | `banderas`: bit0 tarjeta, bit1 cargando, bit2 puente compilado, bit3 arranque vigilado activo, bit4 id vinculado |
| 16 | u8[6] | `bd_addr`; todo 0 = no se sabe |
| 22 | u16 | reserva, 0 |
| 24 | char[16] | `version`, p. ej. «0.29.0» |
| 40 | char[8] | `modelo`, «w580» |
| 48 | char[8] | `soc`, «DB2020» |
| 56 | char[24] | `compilacion`, «Oct 31 2026 23:50:01» |
| 80 | char[16] | `id_aparato`: el IMEI vinculado, o vacío |
| 96 | u32 | `ajustes_version` (`AJ_VERSION`) |
| 100 | u8[28] | reserva, 0 |

## 3. Ajustes

Claves **estables**: no se renumeran nunca. Los rangos no se fijan aquí: los dice el firmware, porque dependen de `N_TEMAS` y compañía.

Tipos: 1 bool (largo 1), 2 u8 (largo 1), 3 i16 (largo 2), 4 texto (largo = bytes sin NUL; `max` = capacidad).

| Clave | Campo | Tipo | | Clave | Campo | Tipo |
|---|---|---|---|---|---|---|
| 0x0001 | `tema` | 2 | | 0x000E | `pasos` | 1 |
| 0x0002 | `hora12` | 1 | | 0x000F | `pasos_ahorro` | 2 |
| 0x0003 | `alarma_on` | 1 | | 0x0010 | `menu_estilo` | 2 |
| 0x0004 | `alarma_h` | 2 | | 0x0011 | `menu_efecto` | 2 |
| 0x0005 | `alarma_m` | 2 | | 0x0012 | `menu_intensidad` | 2 |
| 0x0006 | `zona_min` | 3 | | 0x0013 | `menu_ejes` | 2 |
| 0x0007 | `brillo` | 2 | | 0x0014 | `luces` | 1 |
| 0x0008 | `atenuar_s` | 2 | | 0x0015 | `luces_color` | 2 |
| 0x0009 | `apagar_s` | 2 | | 0x0016 | `luces_latido` | 1 |
| 0x000A | `bloqueo_auto` | 1 | | 0x0017 | `menu_propio` | 1 |
| 0x000B | `tapa_apaga` | 1 | | 0x0018 | `giro` | 1 |
| 0x000C | `volumen` | 2 | | 0x0019 | `medios_color` | 2 |
| 0x000D | `tono_teclas` | 1 | | 0x001A | `fondo` | 4 |

**`SEN_AJ_LEER`:** `u16 formato=1, u16 n`, y n veces `{ u16 clave, u8 tipo, u8 largo, i16 min, i16 max, u8 valor[largo] }`.
Mientras haya cambios sin aplicar contesta `R_OCUPADO`.

**`SEN_AJ_PONER`:** `u16 formato=1, u16 n`, y n veces `{ u16 clave, u8 tipo, u8 largo, u8 valor[largo] }`.
- Cada clave es independiente: una fuera de rango no impide las demás.
- Una clave desconocida se ignora y se cuenta. Un tipo o largo que no cuadra cuenta como fuera de rango.
- Dataset truncado o `formato` distinto: `R_PARAM_MAL` y no se aplica nada.
- Respuesta `R_OK` con p1 = aplicadas, p2 = fuera de rango, p3 = desconocidas.
- El manejador MTP solo valida y encola. El hilo de la interfaz aplica (`sh_poner_tema`, `sh_poner_fondo`, …) y guarda.
- SENUS **siempre relee** con `SEN_AJ_LEER` y compara: es la única confirmación por clave. El firmware puede ajustar valores
  relacionados (`atenuar_s` ≤ `apagar_s`, como al cargar).

## 4. Reloj, vínculo y Bluetooth

**`SEN_RELOJ`:** `u32 utc_unix, i16 zona_min, u16 reserva`. Pone `hw_rtc_poner` y `aj.zona_min`.

**`SEN_VINCULAR`:** `char id[16]`: 14 o 15 dígitos y NUL (el W580 de Adrián tiene 14). Otra cosa: `R_PARAM_MAL`. Se guarda en `NV_APARATO`
= 0x0502. SENUS solo lo llama si `id_aparato` está vacío o difiere.

**`SEN_BT_ESTADO`:** 12 bytes: `u8 encendido, u8 puente_conectado, u8 red_lista, u8 fallo, u8 puente_addr[6], u16 reserva`.

**`SEN_BT_EMPAREJAR` (0x9407):** datos de salida, 24 bytes: `u8 addr[6]` (la dirección Bluetooth del computador, en el mismo orden que `bd_addr`),
`u8 pin_n` (1..16), `char pin[16]` (ASCII, ceros detrás), `u8 reserva` = 0. Otra forma: `R_PARAM_MAL`. Si hay una app en pantalla: `R_OCUPADO`.
Solo valida y encola; el hilo de la interfaz guarda con `sh_red_poner_puente`, pone el PIN y llama con `sh_red_conectar(addr, SH_BT_SISTEMA)`. El
resultado se lee sondeando `SEN_BT_ESTADO` hasta `red_lista` = 1, o `fallo` distinto de 0. Con el teléfono emparejado, el puente queda guardado en
`NV_RED` y senew lo usa sin cable. Si no hay Bluetooth en esa placa: `R_OP_NO`. Sustituye a «reservada» en la tabla del §1, y `SEN_INFO.bd_addr` debe dar
la dirección real aunque el Bluetooth esté apagado si se puede leer del almacén `NV_BT`.

## 5. `SEN_ENTRAR_BL`

Sin datos. La primera llamada abre en el teléfono «¿Actualizar el sistema?» y contesta `R_OCUPADO`. SENUS reintenta cada 500 ms, hasta 60 s.

- «Sí»: `R_OK`. Al menos 150 ms después, para que la respuesta salga: suelta el USB, `hw_carga_fuera`, bandera `BLOA` y
  `reinicio_caliente`. **Nunca `hw_reiniciar`**: cae al bootrom.
- «No»: `R_DENEGADO` una vez, y queda como al principio.

## 6. `SEN_APPS`

**Hace falta porque `/apps` de fábrica no se ve por MTP.** p1 = índice desde el que listar.
Respuesta: `u16 formato=1, u16 total, u16 n, u16 tam_entrada=128`, y n ≤ 7 entradas `SenApp`. Mientras se recorre: `R_OCUPADO`.

| Despl. | Tipo | Campo |
|---|---|---|
| 0 | u8 | `origen`: 0 fábrica (`/apps` del W6FS), 1 `/memoria/apps`, 2 `/tarjeta/apps`, 3 `/tarjeta/juegos` |
| 1 | u8 | `banderas`: bit0 protegida (no se borra), bit1 tapada (otra copia manda) |
| 2 | u8 | `perfil` |
| 3 | u8 | `icono_gen` |
| 4 | u8 | `icono_an` |
| 5 | u8 | reserva |
| 6 | u16 | `api_mayor` |
| 8 | u16 | `api_menor` |
| 10 | u16 | reserva |
| 12 | u32 | `ver_app` |
| 16 | u32 | `tam` |
| 20 | u16[12] | `icono` |
| 44 | char[30] | `nombre` de la cabecera |
| 74 | char[54] | `fichero`, p. ej. «musica.sen» |

Instalar y borrar siguen siendo MTP estándar: `/apps` de la storage Memoria y las carpetas de la Tarjeta. Una app de origen 0 no se
borra. `DeleteObject` sobre lo protegido contesta `R_PROTEGIDO`.

## 7. Versión e identidad

- `DeviceVersion` = «0.29.0+290» (`version`+`build`). Constantes `SENEW_VERSION` y `SENEW_BUILD`, una sola definición.
- Serie MTP y `iSerialNumber`, con id vinculado: `USB_TEXTO_MODELO` + «S1» + 24 hexadecimales de un hash del id. El IMEI no va en claro.
  Sin vincular: la fija de hoy.

## 8. Compilaciones

| Nombre | `DEFS` | Para qué |
|---|---|---|
| Primera al teléfono | Canal **y** `-DPUENTE`, sin arranque vigilado | Conserva otra puerta al BL. Se añade a la tabla del §4.4 |
| Pública | Canal, sin `-DPUENTE` | Solo emulador hasta que `SEN_ENTRAR_BL` haya funcionado en el aparato |
| `-DARRANQUE_VIGILADO` | Opcional, apagada por omisión | Hasta medirlo en silicio: un perro armado que dispare mal puede dejar el teléfono en bucle |

Cada compilación deja `senus_tabla.json` con `{ id_puente, carga_veto, hw_carga_fuera, reinicio_caliente }` si lleva puente.

## Cambios

- 2026-10-31: primera versión.
- 2026-11-01 (agente A, firmware): aclaraciones. No cambia ningún byte ni ningún código de operación:
  - `SEN_AJ_PONER` y `SEN_RELOJ` también contestan `R_OCUPADO` si hay cambios sin aplicar, y `SEN_ENTRAR_BL` igual.
  - `SEN_AJ_PONER`: bytes de más tras la última entrada son `R_PARAM_MAL`.
  - `SEN_RELOJ`: fuera de 2000..2099, zona fuera de -720..840 o un dataset que no sea de 8 bytes: `R_PARAM_MAL`.
  - `SEN_VINCULAR`: 16 bytes exactos, con ceros detrás del NUL. Si el almacén falla: `R_GENERAL`.
  - `SEN_APPS`: hasta 64 entradas. Entra toda `.sen` con la cabecera bien, también si pide una API más nueva. No entran las retiradas del W6FS ni las de `/usuario`.
  - Serie: tres pasadas de FNV-1a sobre los dígitos (`api/gestion.c`). `DeleteObject` de la carpeta `/apps` contesta `R_PROTEGIDO`.
  - `R_OP_NO` en `SEN_ENTRAR_BL`: un sistema sin BL (W600, W810).
- 2026-11-01 (supervisor): `SEN_BT_EMPAREJAR` definida para el apartado Conexión de SENUS.
- 2026-11-01 (agente F, firmware): `SEN_BT_EMPAREJAR` implementada en senew 0.29.1. No cambia ningún byte ni ningún código de operación. Aclaraciones:
  - `bd_addr`, `addr` y `puente_addr` van con el byte más significativo primero, como se escriben: «DC:A6:32:12:34:56» es `addr[0]` = 0xDC.
  - `SEN_INFO.bd_addr` no enciende nada. Da la de `NV_BT`; sin ella, una aleatoria `02:53:4E:xx:xx:xx`, elegida al leerla, estable hasta reiniciar y fija al emparejar: es con la que el chip llamará. Por eso se relee cada vez, justo antes de emparejar. Ceros solo sin radio.
  - `SEN_BT_EMPAREJAR`: se comprueba en este orden: `R_OP_NO` sin radio; `R_PARAM_MAL`; `R_OCUPADO` con una app abierta o con cambios sin aplicar. También son `R_PARAM_MAL` las direcciones 00:00:… y FF:FF:…, un PIN fuera de 0x20..0x7E y lo que no sean ceros detrás del PIN. `R_OK` solo dice que entró en la cola.
  - Desde `R_OK` hasta aplicarla, `SEN_BT_ESTADO` da `red_lista` = 0, `fallo` = 0 y `puente_addr` = la nueva: un fallo viejo no se toma por la respuesta.
  - `fallo` en `SEN_BT_ESTADO`: 0 bien, 1 sin radio, 2 no hay puente elegido, 3 la radio no arrancó, 4 el puente no contesta o rechazó el PIN, 5 contestó y no es W5RED, 6 se cortó, 7 Bluetooth ocupado por un robot, 8 no se pudo guardar el puente (nuevo; solo con esta orden, y entonces no llama).
  - Si la red está viva con OTRO puente, se corta y se llama al nuevo: `red_lista` = 1 siempre se refiere al `puente_addr` que se lee. Sus dueños (la música) siguen y se suman al puente nuevo. Al mismo puente no se reconecta ni se escribe la NOR.
  - La llamada intenta hasta 3 veces. Si todas fallan, `fallo` = 4 y la radio se apaga. **`NV_RED` queda con el puente nuevo aunque la llamada falle**: es el orden que pide el §4.
  - Con `red_lista` = 1 la red queda retenida: sigue sin cable, y deja de haber reposo profundo mientras dure. Se suelta sola si se cae (`fallo` = 6, radio apagada), y la aparta un robot o salir de Ajustes, Bluetooth; el puente sigue guardado.
  - `NV_RED` pasa a 8 bytes con bandera «llamar al arrancar»: una llamada por arranque, a los 8 s, solo con el puente puesto por esta orden. Los de 7 bytes (los de Ajustes y los de antes) siguen siendo bajo demanda.
