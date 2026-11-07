// Los componentes de esta versión de SENUS, con sus huellas. CADA HUELLA SE MIDIÓ
// sobre el fichero bajado de su origen oficial, y cuadró con la que publica el
// proyecto cuando publica una. Cambiar una versión exige volver a medir.
//
// Decisión y medidas: docs/servicios_dictado_musica.md.

import 'dart:ffi' show Abi;
import 'dart:io';

import 'componentes.dart';

const idDictado = 'dictado';
const idMusica = 'musica';

/// Lo que dice X-Dictado-Modelo.
const nombreModeloDictado = 'small-q8';

const modeloDictado = 'ggml-small-q8_0.bin';
const vadDictado = 'ggml-silero-v6.2.0.bin';
const ayudanteDictado = 'senus_dictado';

/// Ruta del asset y huella del ayudante (tool/ayudante_dictado/compilar_macos.sh).
const assetAyudanteMacos = 'assets/servicios/macos/senus_dictado';
const shaAyudanteMacos = 'b9363c9e1c9d93913d76678f27e2cdbe36c49b8b365975241721e5c77b3d7f46';
const tamAyudanteMacos = 7149392;

const assetLetra = 'assets/servicios/letra_telefono.bin';

const carpetaYtDlp = 'yt-dlp';
const carpetaDeno = 'deno';
const carpetaFfmpeg = 'ffmpeg';

const rutaYtDlp = '$carpetaYtDlp/yt-dlp_macos';
const rutaDeno = '$carpetaDeno/deno';
const rutaFfmpeg = '$carpetaFfmpeg/ffmpeg';

// Windows (6-nov-2026): lo que dejan los zips de musicaWindows.
const rutaYtDlpWindows = '$carpetaYtDlp/yt-dlp.exe';
const rutaDenoWindows = '$carpetaDeno/deno.exe';
const rutaFfmpegWindows = '$carpetaFfmpeg/ffmpeg-9.0.2-essentials_build/bin/ffmpeg.exe';

/// Lo que dice /estado.
const versionesMusica = 'yt-dlp 2026.10.26, deno 2.9.8, ffmpeg 9.0.2';

const dictadoMacos = Componente(
  id: idDictado,
  version: 'whisper-1.9.5-small-q8',
  licencias: 'whisper.cpp (MIT), modelo small de OpenAI (MIT), Silero VAD (MIT)',
  archivos: [
    ArchivoComponente(
      origen: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-small-q8_0.bin',
      sha256: '49c8fb02b65e6049d5fa6c04f81f53b867b5ec9540406812c643f177317f779f',
      tam: 264464607,
      tipo: TipoArchivo.directo,
      destino: modeloDictado,
      tamInstalado: 264464607,
    ),
    ArchivoComponente(
      origen: 'https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v6.2.0.bin',
      sha256: '2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987',
      tam: 885098,
      tipo: TipoArchivo.directo,
      destino: vadDictado,
      tamInstalado: 885098,
    ),
    ArchivoComponente(
      origen: assetAyudanteMacos,
      sha256: shaAyudanteMacos,
      tam: tamAyudanteMacos,
      tipo: TipoArchivo.empotrado,
      destino: ayudanteDictado,
      tamInstalado: tamAyudanteMacos,
    ),
  ],
);

const musicaMacos = Componente(
  id: idMusica,
  version: 'ytdlp-2026.10.26-deno-2.9.8-ffmpeg-9.0.2',
  licencias: 'yt-dlp (Unlicense; el ejecutable reúne otras, _internal/THIRD_PARTY_LICENSES.txt), '
      'Deno (MIT), FFmpeg (GPL v3 en este compilado)',
  archivos: [
    // La versión en carpeta, no el ejecutable de un fichero: ese tarda ~12 s en
    // cada arranque, porque macOS revisa lo que desempaqueta cada vez [medido].
    ArchivoComponente(
      origen: 'https://github.com/yt-dlp/yt-dlp/releases/download/2026.10.26/yt-dlp_macos.zip',
      sha256: '20d98fa608998eff87d1d35a6e9fb65e4b874639a6cc89addc19da3becde3ef1',
      tam: 54165284,
      tipo: TipoArchivo.zip,
      destino: carpetaYtDlp,
      arbolSha256: '0ee38c623b5fb39e442903b5da7ef91a207303139c7872f943d1d8f43e9d2ce7',
      tamInstalado: 129401729,
    ),
    ArchivoComponente(
      origen: 'https://github.com/denoland/deno/releases/download/v2.9.8/deno-aarch64-apple-darwin.zip',
      sha256: '9f0bf660393da2eaff044cdc7444cb08c73f235849b61d224d825a194ce7c98e',
      tam: 38770795,
      tipo: TipoArchivo.zip,
      destino: carpetaDeno,
      arbolSha256: '9e8d186b562f8a690f59a160a8c61feedcda1a581b8657c65860a1bb173269c5',
      tamInstalado: 81512928,
    ),
    // FFmpeg no publica binarios: este es el compilado de Martin Riedl, firmado
    // por él y con el sha256 publicado junto al zip.
    ArchivoComponente(
      origen: 'https://ffmpeg.martin-riedl.de/download/macos/arm64/1789931890_9.0.2/ffmpeg.zip',
      sha256: 'c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924',
      tam: 28395699,
      tipo: TipoArchivo.zip,
      destino: carpetaFfmpeg,
      arbolSha256: 'a16fb6da7a392a49b5fa43d9f7810665e5c49faa89b62a39ae6724f36ba3acc0',
      tamInstalado: 66332880,
    ),
  ],
);

/// Música en Windows x64 (6-nov-2026). Las mismas versiones que en la Mac. Medidos
/// el 6-nov en la PC Windows: cada zip cuadró con el sha256 que publica su proyecto,
/// las huellas del árbol se calcularon como huellaArbol sobre lo que deja
/// descomprimirZip, y los tres ejecutables arrancan (Windows Defender no los para).
const musicaWindows = Componente(
  id: idMusica,
  version: 'ytdlp-2026.10.26-deno-2.9.8-ffmpeg-9.0.2-win64',
  licencias: 'yt-dlp (Unlicense; el ejecutable reúne otras, _internal/THIRD_PARTY_LICENSES.txt), '
      'Deno (MIT), FFmpeg (GPL v3 en este compilado)',
  archivos: [
    // La versión en carpeta, como en la Mac: el ejecutable de un fichero se
    // desempaqueta entero en cada arranque.
    ArchivoComponente(
      origen: 'https://github.com/yt-dlp/yt-dlp/releases/download/2026.10.26/yt-dlp_win.zip',
      sha256: 'fd51b212cf8380c7a52ee08c0d6be7f3c59b2f2c832eaf7b45acfae6eab57419',
      tam: 23885596,
      tipo: TipoArchivo.zip,
      destino: carpetaYtDlp,
      arbolSha256: '385e5ee98b7dc02eb8ae2289c68b95e156a5f5c5ecf5f3690c034ea13508e6f3',
      tamInstalado: 41340247,
    ),
    ArchivoComponente(
      origen: 'https://github.com/denoland/deno/releases/download/v2.9.8/deno-x86_64-pc-windows-msvc.zip',
      sha256: 'cba84b26e0df5ae7f74fc66b86a95b866872a86292ebd84fa1e959927edd93bf',
      tam: 42917472,
      tipo: TipoArchivo.zip,
      destino: carpetaDeno,
      arbolSha256: '358623b255009bb9dfc42f75d96334d138febf2b73f10ea18e27cb1fcae379fd',
      tamInstalado: 98081568,
    ),
    // FFmpeg no publica binarios: este es el «essentials» de gyan.dev, el que
    // enlaza ffmpeg.org para Windows, de su carpeta de paquetes con versión fija y
    // con el sha256 publicado junto al zip.
    ArchivoComponente(
      origen: 'https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-9.0.2-essentials_build.zip',
      sha256: '60f467265b1e312373dbcd92200c2618a74850f98d3d078e94296bb3fa2047ba',
      tam: 114768076,
      tipo: TipoArchivo.zip,
      destino: carpetaFfmpeg,
      arbolSha256: '6b0421871140e9e5b401e5304427cb6964afdfe63adddce4bff24b26f5ba3f7a',
      tamInstalado: 329221735,
    ),
  ],
);

/// Las herramientas de Música de este computador, por la ruta que dejan sus zips.
({String ytDlp, String deno, String ffmpeg}) rutasMusica({bool? windows}) => (windows ?? Platform.isWindows)
    ? (ytDlp: rutaYtDlpWindows, deno: rutaDenoWindows, ffmpeg: rutaFfmpegWindows)
    : (ytDlp: rutaYtDlp, deno: rutaDeno, ffmpeg: rutaFfmpeg);

/// Lo que se puede instalar en este computador.
List<Componente> catalogoDePlataforma({Abi? abi}) {
  final a = abi ?? Abi.current();
  if (bloqueoDePlataforma(abi: a) != null) return const [];
  if (a == Abi.windowsX64) return const [musicaWindows];
  return const [dictadoMacos, musicaMacos];
}

/// Por qué no se puede nada aquí, o null si algo se puede.
ComponenteNoDisponible? bloqueoDePlataforma({Abi? abi}) {
  final a = abi ?? Abi.current();
  if (a == Abi.macosArm64 || a == Abi.windowsX64) return null;
  if (a == Abi.macosX64) {
    return const ComponenteNoDisponible('Por ahora, solo en Mac con chip de Apple.');
  }
  if (a == Abi.windowsArm64) {
    return const ComponenteNoDisponible('En Windows, por ahora solo en equipos de 64 bits x64 (Intel o AMD).');
  }
  return const ComponenteNoDisponible('En este sistema aún no está disponible.');
}

/// Por qué no se puede [id] aquí, o null si se puede. Lo de toda la plataforma va
/// primero; en Windows x64, Música sí y el dictado todavía no.
ComponenteNoDisponible? bloqueoDeComponente(String id, {Abi? abi}) {
  final a = abi ?? Abi.current();
  final todo = bloqueoDePlataforma(abi: a);
  if (todo != null) return todo;
  if (a == Abi.windowsX64 && id == idDictado) {
    return const ComponenteNoDisponible('En Windows aún no está disponible: falta compilar el ayudante de dictado.');
  }
  return null;
}
