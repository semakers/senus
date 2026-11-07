#!/bin/sh
# Firma SENUS.app con Developer ID (hardened runtime + sello de tiempo), por dentro hacia fuera.
# Lo que va dentro y no pone Flutter: libusb (Contents/Frameworks) y seftool (Contents/Resources/seftool).
#
#   instaladores/macos_firmar.sh <SENUS.app> "<identidad>" <entitlements> <registro>
#
# Por SSH el llavero está bloqueado (errSecInternalComponent): lánzalo en la sesión gráfica, p. ej.
#   osascript -e 'tell application "Terminal" to do script "sh …/macos_firmar.sh …; exit"'
set -eu
APP=$1
ID=$2
ENT=$3
LOG=$4
exec >"$LOG" 2>&1
echo "firmando $APP"

firmar() { codesign --force --options runtime --timestamp --sign "$ID" "$@"; }

# 1. Todo Mach-O suelto que no sea el ejecutable principal ni esté dentro de un .framework
#    (libusb, seftool, el ayudante de dictado que va en los assets…).
find "$APP/Contents" -type f ! -path "*.framework/*" ! -path "$APP/Contents/MacOS/*" | while read -r f; do
	if file -b "$f" | grep -q "Mach-O"; then
		echo "  mach-o  ${f#"$APP"/}"
		firmar "$f"
	fi
done
# El ayudante de dictado vive en App.framework/…/flutter_assets: es Mach-O dentro de un framework.
find "$APP/Contents/Frameworks" -path "*flutter_assets*" -type f | while read -r f; do
	if file -b "$f" | grep -q "Mach-O"; then
		echo "  asset   ${f#"$APP"/}"
		firmar "$f"
	fi
done
# 2. Los frameworks (Flutter, App y plugins).
for fw in "$APP"/Contents/Frameworks/*.framework; do
	echo "  fw      ${fw#"$APP"/}"
	firmar "$fw"
done
# 3. La app, con sus entitlements.
firmar --entitlements "$ENT" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo FIRMA_OK
