# Cómo se hacen los instaladores de SENUS / How the SENUS installers are built

## Windows (`senus-setup.exe`)

En una PC con Windows 10/11 x64, Flutter (`C:\flutter`), Inno Setup 6 y seftool compilado
(`win/build.sh` del fork `seftool-senew`, en MSYS2 MINGW64):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File instaladores\windows_release.ps1 `
    -Repo C:\ruta\a\senus -SeftoolDir C:\ruta\a\seftool-senew
```

Hace `flutter build windows --release`, prepara `seftool\` (binario, `loader\`, `rest\` y su
licencia; sin `loader\2020_prologue`), copia `licencias\` junto al `.exe`, comprueba que no falte
nada crítico y empaqueta con `senus_windows.iss`. Sale en `instaladores\dist\senus-<versión>-setup.exe`.
El asistente enseña `app/assets/licencias/AVISOS.txt` (licencias y aviso de riesgo) antes de instalar.

## macOS (`SENUS.dmg`)

En una Mac con Xcode, Flutter y CocoaPods:

1. `flutter build macos --release` en `app/` → `SENUS.app` universal (Apple Silicon e Intel).
2. `instaladores/macos_universal.sh <deps> <seftool-senew> <salida>` compila libusb 1.0.27 (dylib) y
   seftool (con libusb estática) para arm64 + x86_64. `<deps>` lleva `libusb-1.0.27/` y `zlib-1.3.1/`.
3. Copia `libusb-1.0.0.dylib` a `SENUS.app/Contents/Frameworks/` y seftool + `loader/` + `rest/` +
   su licencia a `SENUS.app/Contents/Resources/seftool/` (SENUS lo copia a
   `~/Library/Application Support/SENUS/seftool` para poder escribir sus volcados).
4. `instaladores/macos_firmar.sh <SENUS.app> <identidad Developer ID> app/macos/Runner/Release.entitlements <registro>`
   firma de dentro hacia fuera con *hardened runtime* y sello de tiempo. Necesita el llavero abierto
   (en la sesión gráfica, no por SSH).
5. Notarizar (`xcrun notarytool submit … --wait`), `xcrun stapler staple SENUS.app`, crear el `.dmg`
   con `hdiutil create`, firmarlo, notarizarlo y graparlo también.

El ayudante de dictado (`app/assets/servicios/macos/senus_dictado`) es solo arm64: en Macs Intel los
servicios locales (dictado, música y videos) salen como no disponibles; instalar senew y las apps sí funciona.

---

**English, in short:** `windows_release.ps1` builds and packages the Windows installer with Inno Setup;
on macOS build the app with Flutter, build universal libusb + seftool with `macos_universal.sh`, copy
them into the bundle, sign with `macos_firmar.sh` (Developer ID, hardened runtime), notarize, staple and
wrap it in a signed, notarized `SENUS.dmg`.
