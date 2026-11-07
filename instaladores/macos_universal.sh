#!/bin/sh
# libusb (dylib, para la app) y seftool (con libusb estática) UNIVERSALES (arm64 + x86_64), para que
# SENUS.app sirva también en Macs Intel.
#   instaladores/macos_universal.sh <deps> <fuente-de-seftool> <salida>
# <deps> = carpeta con libusb-1.0.27/ y zlib-1.3.1/ (las de mac/build.sh de seftool).
set -eu
D=$1; R=$2; O=$3
U=$D/libusb-1.0.27/libusb
M=$D/zlib-1.3.1/contrib/minizip
A="-arch arm64 -arch x86_64 -mmacosx-version-min=12.0 -O2"
SRC="$U/core.c $U/descriptor.c $U/hotplug.c $U/io.c $U/strerror.c $U/sync.c $U/os/darwin_usb.c $U/os/events_posix.c $U/os/threads_posix.c"
mkdir -p "$O/obj" "$O/inc"
cd "$O/obj"
rm -f ./*.o
# shellcheck disable=SC2086
clang -dynamiclib $A -I"$D/libusb-1.0.27/Xcode" -I"$U" $SRC -lobjc -framework IOKit -framework CoreFoundation \
	-framework Security -install_name @rpath/libusb-1.0.0.dylib -o "$O/libusb-1.0.0.dylib"
# shellcheck disable=SC2086
clang -c $A -I"$D/libusb-1.0.27/Xcode" -I"$U" $SRC
ar rcs "$O/libusb.a" ./*.o
ln -sfn "$M" "$O/inc/minizip"
# shellcheck disable=SC2046,SC2086
clang -std=gnu99 $A -w -I"$R/mac" -I"$O/inc" -I"$U" -I"$R/src" -I"$R/src/core" -I"$R/src/utils" \
	-I"$R/src/emp/common" -I"$R/src/eric/common" -I"$R/src/senew" $(find "$R/src" -name '*.c') "$R/mac/sp_usb.c" \
	"$M/unzip.c" "$M/ioapi.c" "$O/libusb.a" -lz -lobjc -framework IOKit -framework CoreFoundation -framework Security \
	-o "$O/seftool"
lipo -archs "$O/libusb-1.0.0.dylib"
lipo -archs "$O/seftool"
