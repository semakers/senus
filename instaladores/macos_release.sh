#!/bin/sh
# SENUS para macOS de punta a punta: compilar, meter libusb + seftool universales, firmar, notarizar, grapar,
# y hacer SENUS.dmg (firmado, notarizado y grapado). Necesita el llavero abierto: lánzalo en la sesión gráfica,
#   osascript -e 'tell application "Terminal" to do script "sh …/macos_release.sh …; exit"'
#
#   instaladores/macos_release.sh <repo senus> <fuente seftool-senew> <deps libusb/zlib> <identidad> <dir salida>
# Variables: NOTARY_KEY (ruta .p8), NOTARY_KEY_ID, NOTARY_ISSUER (o fichero en NOTARY_ISSUER_FILE).
set -eu
REPO=$1; SEF=$2; DEPS=$3; ID=$4; OUT=$5
LOG=$OUT/release.log
mkdir -p "$OUT"
exec >"$LOG" 2>&1
export PATH=/usr/local/bin:/opt/homebrew/bin:$HOME/.gem/ruby/2.6.0/bin:$PATH LANG=en_US.UTF-8
: "${FLUTTER:=flutter}"
ISSUER=${NOTARY_ISSUER:-$(cat "$NOTARY_ISSUER_FILE")}
notarizar() { xcrun notarytool submit "$1" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$ISSUER" --wait; }

echo "== compilar"
(cd "$REPO/app" && $FLUTTER pub get >/dev/null && $FLUTTER build macos --release)
echo "== libusb y seftool universales"
sh "$REPO/instaladores/macos_universal.sh" "$DEPS" "$SEF" "$OUT/univ"
echo "== armar SENUS.app"
APP=$OUT/SENUS.app
rm -rf "$APP"
ditto "$REPO/app/build/macos/Build/Products/Release/SENUS.app" "$APP"
cp "$OUT/univ/libusb-1.0.0.dylib" "$APP/Contents/Frameworks/"
mkdir -p "$APP/Contents/Resources/seftool"
cp "$OUT/univ/seftool" "$APP/Contents/Resources/seftool/"
cp -R "$SEF/loader" "$SEF/rest" "$APP/Contents/Resources/seftool/"
rm -f "$APP/Contents/Resources/seftool/loader/2020_prologue"
cp "$SEF/LICENSE" "$APP/Contents/Resources/seftool/LICENSE-seftool.txt"
echo "== firmar la app"
sh "$REPO/instaladores/macos_firmar.sh" "$APP" "$ID" "$REPO/app/macos/Runner/Release.entitlements" "$OUT/firma.log"
cat "$OUT/firma.log" | tail -3
echo "== notarizar la app"
rm -f "$OUT/SENUS-app.zip"
ditto -c -k --keepParent "$APP" "$OUT/SENUS-app.zip"
notarizar "$OUT/SENUS-app.zip"
xcrun stapler staple "$APP"
spctl -a -vvv -t exec "$APP"
echo "== dmg"
D=$OUT/dmg
rm -rf "$D" "$OUT/SENUS.dmg"
mkdir "$D"
ditto "$APP" "$D/SENUS.app"
ln -s /Applications "$D/Aplicaciones"
cp "$REPO/app/assets/licencias/AVISOS.txt" "$D/Léeme - avisos.txt"
hdiutil create -volname SENUS -srcfolder "$D" -ov -format UDZO -fs HFS+ "$OUT/SENUS.dmg"
codesign --force --timestamp --sign "$ID" "$OUT/SENUS.dmg"
notarizar "$OUT/SENUS.dmg"
xcrun stapler staple "$OUT/SENUS.dmg"
spctl -a -vvv -t open --context context:primary-signature "$OUT/SENUS.dmg"
shasum -a 256 "$OUT/SENUS.dmg"
echo RELEASE_OK
