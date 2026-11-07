# SENUS — the desktop companion of senew

*Español más abajo — [ir a la versión en español](#español).*

> [!WARNING]
> **SENUS and senew are new projects; use them at your own risk.** Installing senew replaces the software of your phone. Back up first (SENUS makes a backup for you before it writes anything), use a charged battery and a good data cable, and expect rough edges. This project is not affiliated with Sony or Sony Ericsson.

**SENUS** (*Sony Ericsson New Update Service*) is a free desktop application for Windows and macOS (Linux builds from source) that installs and maintains **[senew](https://github.com/semakers/senew-w580)**, the open operating system for the **Sony Ericsson W580i**, and manages the apps on the phone:

- **First installation** of senew on a stock phone (guided, with a backup and a rollback path), and **updates** afterwards.
- **Apps**: list, upload (`.sen`) and delete the apps on the phone; a **catalog** with the apps and games published on <https://semakers.com>. Make your own apps with the [senew-sdk](https://github.com/semakers/senew-sdk).
- **Backup and restore** of the phone's data.
- **Connection**: SENUS is the phone's **modem**. It runs the Bluetooth bridge that gives the phone internet through your computer (the apps call their own server; see [apps-con-internet.md](https://github.com/semakers/senew-sdk/blob/main/docs/en/apps-con-internet.md)), and the local **services** the phone can use while SENUS is open: dictation (speech-to-text on your computer), music and videos.
- **Settings** of the phone (lights, sounds, display, clock…) from the computer.

Website, downloads and videos: **<https://semakers.com>**.

## Download

Installers (Windows `setup.exe`, macOS `.dmg`): **<https://github.com/semakers/senus/releases>**.

## Build from source

SENUS is a [Flutter](https://flutter.dev) desktop app (`app/`). Tested with Flutter 3.47.1 (Dart 3.x) on macOS 26 (Apple Silicon) and Windows 10.

```sh
git clone https://github.com/semakers/senus
cd senus/app
flutter pub get
flutter analyze            # static check
flutter test               # unit tests (they need no phone)
flutter run -d macos       # or: -d windows, -d linux
```

### What SENUS needs next to it: seftool

To talk to a **stock** (not yet senew) phone, SENUS drives **[seftool-senew](https://github.com/semakers/seftool-senew)**, our fork of [farid1991/seftool](https://github.com/farid1991/seftool) with changes for the W580i (any-CID, CID 53…). Build seftool for your platform (see its README) and tell SENUS where it is:

```sh
SENUS_SEFTOOL_RAIZ=/path/to/seftool-senew flutter run -d macos
```

The installers (see [`instaladores/LEEME.md`](instaladores/LEEME.md)) bundle seftool with its `loader/` and `rest/` folders. With `SENUS_SEFTOOL_ENSAYO=1` no command is run on the phone: SENUS only logs what it would do (this is how the installer is tested without a phone).

| Folder | What |
|---|---|
| `app/lib/` | The application (Dart): `datos/` (phone, installer, backup, seftool, catalog), `mtp/` (the USB/MTP and management channel to senew), `conexion/` (the Bluetooth bridge, protocol W5RED), `servicios/` (dictation, music, video), `widgets/` (screens), `tema/` |
| `app/macos`, `app/windows`, `app/linux` | The platform runners (the Bluetooth bridge has a native part in Swift and C++) |
| `app/assets/instalador/w580/` | What the first installation uploads (see "Third-party material" below) |
| `app/assets/licencias/` | The licenses and notices of everything SENUS ships |
| `app/tool/` | Helper scripts (embedding the installer, icons, the dictation helper) |
| `instaladores/` | How the Windows and macOS installers are built |
| `docs/` | The management-channel contract between SENUS and senew, and how to validate against a real phone |

## Third-party material

SENUS includes, so that the first installation works: six small `R8BE001_*_GENERIC_*.zip` packages that contain Sony Ericsson's original "executor" file for the W580i (`app/assets/instalador/w580/`), and the community's `DB2020.zip` any-CID package (the same one that ships with [seftool](https://github.com/farid1991/seftool)). They are **not** covered by this repository's license and belong to their owners; they are included only for that purpose. Everything else of Sony Ericsson's (firmware images, dumps, GDFS, file systems) is deliberately **not** in this repository. Libraries and tools (libusb, libwdi, whisper.cpp, fonts) keep their own licenses: see [`app/assets/licencias/AVISOS.txt`](app/assets/licencias/AVISOS.txt).

## License

GPL-3.0 — see [`LICENSE`](LICENSE). The comments in the sources are in Spanish (the project's working language).
*Sony*, *Sony Ericsson*, *W580i* and other names are trademarks of their respective owners and are used only to say which hardware this is about.

---

<a id="español"></a>

# SENUS — el compañero de escritorio de senew

> [!WARNING]
> **SENUS y senew son proyectos nuevos; úsalos bajo tu propio riesgo.** Instalar senew sustituye el software de tu teléfono. Haz copia de seguridad antes (SENUS la hace por ti antes de escribir nada), usa la batería cargada y un buen cable de datos, y cuenta con asperezas. Este proyecto no tiene relación con Sony ni con Sony Ericsson.

**SENUS** (*Sony Ericsson New Update Service*) es una aplicación de escritorio libre para Windows y macOS (en Linux, compilando desde el código) que instala y mantiene **[senew](https://github.com/semakers/senew-w580)**, el sistema operativo abierto del **Sony Ericsson W580i**, y gestiona las apps del teléfono:

- **Primera instalación** de senew en un teléfono de fábrica (guiada, con copia de seguridad y vía de vuelta atrás) y **actualizaciones** después.
- **Apps**: listar, subir (`.sen`) y borrar las apps del teléfono; un **catálogo** con las apps y juegos publicados en <https://semakers.com>. Haz tus propias apps con el [senew-sdk](https://github.com/semakers/senew-sdk).
- **Copia de seguridad y restauración** de los datos del teléfono.
- **Conexión**: SENUS es el **módem** del teléfono. Ejecuta el puente Bluetooth que le da internet a través de tu computador (las apps llaman a su propio servidor; ver [apps-con-internet.md](https://github.com/semakers/senew-sdk/blob/main/docs/es/apps-con-internet.md)) y los **servicios** locales que el teléfono puede usar mientras SENUS está abierta: dictado (voz a texto en tu computador), música y videos.
- **Ajustes** del teléfono (luces, sonidos, pantalla, reloj…) desde el computador.

Web, descargas y videos: **<https://semakers.com>**.

## Descargas

Instaladores (Windows `setup.exe`, macOS `.dmg`): **<https://github.com/semakers/senus/releases>**.

## Compilar desde el código

SENUS es una aplicación de escritorio [Flutter](https://flutter.dev) (`app/`). Probada con Flutter 3.47.1 (Dart 3.x) en macOS 26 (Apple Silicon) y Windows 10.

```sh
git clone https://github.com/semakers/senus
cd senus/app
flutter pub get
flutter analyze            # comprobación estática
flutter test               # pruebas unitarias (no necesitan teléfono)
flutter run -d macos       # o: -d windows, -d linux
```

### Lo que SENUS necesita a su lado: seftool

Para hablar con un teléfono **de fábrica** (que aún no tiene senew), SENUS maneja **[seftool-senew](https://github.com/semakers/seftool-senew)**, nuestro fork de [farid1991/seftool](https://github.com/farid1991/seftool) con cambios para el W580i (any-CID, CID 53…). Compila seftool para tu plataforma (ver su README) y dile a SENUS dónde está:

```sh
SENUS_SEFTOOL_RAIZ=/ruta/a/seftool-senew flutter run -d macos
```

Los instaladores (ver [`instaladores/LEEME.md`](instaladores/LEEME.md)) llevan seftool dentro con sus carpetas `loader/` y `rest/`. Con `SENUS_SEFTOOL_ENSAYO=1` no se ejecuta ninguna orden sobre el teléfono: SENUS solo anota lo que haría (así se prueba el instalador sin teléfono).

| Carpeta | Qué |
|---|---|
| `app/lib/` | La aplicación (Dart): `datos/` (teléfono, instalador, copias, seftool, catálogo), `mtp/` (el canal USB/MTP y de gestión con senew), `conexion/` (el puente Bluetooth, protocolo W5RED), `servicios/` (dictado, música, video), `widgets/` (pantallas), `tema/` |
| `app/macos`, `app/windows`, `app/linux` | Los ejecutores de cada plataforma (el puente Bluetooth tiene una parte nativa en Swift y C++) |
| `app/assets/instalador/w580/` | Lo que sube la primera instalación (ver «Material de terceros») |
| `app/assets/licencias/` | Las licencias y avisos de todo lo que SENUS lleva |
| `app/tool/` | Guiones de ayuda (empotrar el instalador, iconos, el ayudante de dictado) |
| `instaladores/` | Cómo se hacen los instaladores de Windows y macOS |
| `docs/` | El contrato del canal de gestión entre SENUS y senew, y cómo validar con un teléfono real |

## Material de terceros

SENUS incluye, para que la primera instalación funcione: seis paquetes pequeños `R8BE001_*_GENERIC_*.zip` que contienen el «executor» original de Sony Ericsson para el W580i (`app/assets/instalador/w580/`), y el paquete any-CID `DB2020.zip` de la comunidad (el mismo que viene con [seftool](https://github.com/farid1991/seftool)). **No** están cubiertos por la licencia de este repositorio y pertenecen a sus dueños; se incluyen solo con ese fin. Todo lo demás de Sony Ericsson (imágenes de firmware, volcados, GDFS, sistemas de ficheros) **no** está en este repositorio a propósito. Las bibliotecas y herramientas (libusb, libwdi, whisper.cpp, tipografías) conservan sus propias licencias: ver [`app/assets/licencias/AVISOS.txt`](app/assets/licencias/AVISOS.txt).

## Licencia

GPL-3.0 — ver [`LICENSE`](LICENSE). Los comentarios de los fuentes están en español (la lengua de trabajo del proyecto).
*Sony*, *Sony Ericsson*, *W580i* y otros nombres son marcas de sus respectivos dueños y se usan solo para decir de qué aparato se trata.
