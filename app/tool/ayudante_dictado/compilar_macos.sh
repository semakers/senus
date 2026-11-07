#!/bin/bash
# Compila el ayudante del dictado para macOS arm64 desde el código oficial de
# whisper.cpp, con Metal empotrado y sin dependencias fuera del sistema. El
# resultado va a assets/servicios/macos/senus_dictado y su sha256 se fija en
# lib/servicios/catalogo_componentes.dart (shaAyudanteMacos).
#
#   tool/ayudante_dictado/compilar_macos.sh DIR_FUENTES_WHISPER [DIR_TRABAJO]
#
# DIR_FUENTES_WHISPER: el .tar.gz de la etiqueta v1.9.5 ya descomprimido
#   (sha256 del .tar.gz: ff1a9053feb509ff9d7729703355541ae9690073a6b1c40eb692c962e0dc1720).
# Hace falta cmake en el PATH.
set -euo pipefail
FUENTES=$(cd "$1" && pwd)
AQUI=$(cd "$(dirname "$0")" && pwd)
APP=$(cd "$AQUI/../.." && pwd)
TRABAJO=${2:-$(mktemp -d)}
mkdir -p "$TRABAJO"
cmake -S "$FUENTES" -B "$TRABAJO/w" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_BLAS=OFF -DGGML_ACCELERATE=ON -DGGML_NATIVE=OFF \
  -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF \
  -DWHISPER_COREML=OFF -DWHISPER_OPENVINO=OFF
cmake --build "$TRABAJO/w" --config Release -j 4
LIBS=$(find "$TRABAJO/w" -name '*.a' | tr '\n' ' ')
clang -O2 -arch arm64 -mmacosx-version-min=12.0 -I"$FUENTES/include" -I"$FUENTES/ggml/include" \
  "$AQUI/senus_dictado.c" -c -o "$TRABAJO/senus_dictado.o"
clang++ -arch arm64 -mmacosx-version-min=12.0 "$TRABAJO/senus_dictado.o" $LIBS \
  -framework Foundation -framework Metal -framework MetalKit -framework Accelerate -framework CoreML -o "$TRABAJO/senus_dictado"
strip -x "$TRABAJO/senus_dictado"
codesign --force --sign - "$TRABAJO/senus_dictado"
mkdir -p "$APP/assets/servicios/macos"
cp "$TRABAJO/senus_dictado" "$APP/assets/servicios/macos/senus_dictado"
ls -la "$APP/assets/servicios/macos/senus_dictado"
shasum -a 256 "$APP/assets/servicios/macos/senus_dictado"
