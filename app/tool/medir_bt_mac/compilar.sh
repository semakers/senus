#!/bin/sh
# Arma MedirBt.app (firma ad hoc) en la carpeta SALIDA. Hace falta app, y no un
# binario suelto, para que macOS la trate como responsable del permiso de Bluetooth.
# Lanzar: open -n -W --stdout S --stderr S SALIDA/MedirBt.app --args 3
set -e
aqui=$(cd "$(dirname "$0")" && pwd)
app="$1/MedirBt.app"
mkdir -p "$app/Contents/MacOS"
cp "$aqui/Info.plist" "$app/Contents/Info.plist"
swiftc -O -framework IOBluetooth -framework CoreBluetooth \
  "$aqui/main.swift" "$aqui/../../macos/Runner/PuenteBluetooth.swift" \
  -o "$app/Contents/MacOS/medir_bt"
codesign --force --sign - "$app"
