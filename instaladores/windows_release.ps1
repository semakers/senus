# Construye y empaqueta SENUS para Windows (el mismo ciclo que tools/windows_release.ps1
# de Nairda): build -> verificar el contenido -> preparar seftool -> Inno Setup.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File instaladores\windows_release.ps1 `
#       [-Repo C:\dev\senus] [-SeftoolDir C:\dev\seftool-senew] [-Version 0.1.0]
#
# Sale en instaladores\dist\senus-<version>-setup.exe

param(
  [string]$Repo = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)),
  [string]$SeftoolDir = 'C:\dev\seftool-senew',
  [string]$Version = ''
)
$ErrorActionPreference = 'Stop'
$Flutter = 'C:\flutter\bin\flutter.bat'
$Iscc = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
$App = Join-Path $Repo 'app'
$Release = Join-Path $App 'build\windows\x64\runner\Release'
$Stage = Join-Path $App 'build\windows\instalador\seftool'

function Paso($t) { Write-Output ""; Write-Output "== $t" }

if (-not $Version) {
  $m = Select-String -Path (Join-Path $App 'pubspec.yaml') -Pattern '^version:\s*([0-9][^\s+]*)' | Select-Object -First 1
  $Version = $m.Matches[0].Groups[1].Value
}
Write-Output "SENUS $Version"

Paso 'construyendo la app (flutter build windows --release)'
$inicio = Get-Date
# Se borra el app.so del Release: si después del build está, lo puso ESTE build (el «install» de CMake lo
# copia conservando la fecha del intermedio, así que la fecha no sirve para saberlo).
Remove-Item (Join-Path $Release 'data\app.so') -ErrorAction SilentlyContinue
Push-Location $App
try {
  & $Flutter pub get
  if ($LASTEXITCODE -ne 0) { throw "flutter pub get fallo ($LASTEXITCODE)" }
  & $Flutter build windows --release
  if ($LASTEXITCODE -ne 0) { throw "flutter build windows fallo ($LASTEXITCODE)" }
} finally { Pop-Location }

# Que el build CORRIO de verdad (no el Release\ de la vez anterior).
if (-not (Test-Path (Join-Path $Release 'data\app.so'))) {
  throw 'data\app.so no esta: el build no corrio'
}

Paso 'preparando seftool'
foreach ($f in 'seftool.exe', 'loader') {
  if (-not (Test-Path (Join-Path $SeftoolDir $f))) { throw "falta $SeftoolDir\$f (compila seftool con win\build.sh)" }
}
if (Test-Path $Stage) { Remove-Item $Stage -Recurse -Force }
New-Item -ItemType Directory -Path $Stage | Out-Null
Copy-Item (Join-Path $SeftoolDir 'seftool.exe') $Stage
Copy-Item (Join-Path $SeftoolDir 'loader') (Join-Path $Stage 'loader') -Recurse
# 2020_prologue es del plugin jdflasher (otro proyecto) y solo lo usa --jdflasher, que SENUS no
# llama: no se reparte. El resto de loader\ y rest\ es lo que reparte el seftool original.
Remove-Item (Join-Path $Stage 'loader\2020_prologue') -ErrorAction SilentlyContinue
Copy-Item (Join-Path $SeftoolDir 'LICENSE') (Join-Path $Stage 'LICENSE-seftool.txt')
if (Test-Path (Join-Path $SeftoolDir 'rest')) {
  Copy-Item (Join-Path $SeftoolDir 'rest') (Join-Path $Stage 'rest') -Recurse
}

Paso 'licencias'
# La de SENUS y las de terceros, a la vista en la carpeta de instalación (también van dentro de la app).
$Lic = Join-Path $Release 'licencias'
if (Test-Path $Lic) { Remove-Item $Lic -Recurse -Force }
Copy-Item (Join-Path $App 'assets\licencias') $Lic -Recurse
Copy-Item (Join-Path $App 'assets\fuentes\Inter-OFL.txt') $Lic
Copy-Item (Join-Path $App 'assets\fuentes\JetBrainsMono-OFL.txt') $Lic

Paso 'verificando el contenido del build'
# Lo que, si falta, deja un SENUS que arranca pero no sirve para instalar.
$criticos = @(
  'senus_app.exe',                  # la app
  'flutter_windows.dll',
  'libusb-1.0.dll',                 # sin ella SENUS no habla USB con el telefono
  'data\app.so',
  'data\flutter_assets\assets\instalador\w580\MANIFIESTO.json',
  'data\flutter_assets\assets\instalador\w580\DB2020.zip',
  'data\flutter_assets\assets\instalador\w580\sistema_44180000.bin',
  'data\flutter_assets\assets\instalador\w580\bl.bin',
  'data\flutter_assets\assets\instalador\w580\R8BE001_CXC1123362_GENERIC_LA.zip',
  'licencias\AVISOS.txt',
  'licencias\SENUS-GPL-3.0.txt'
)
$faltan = @()
foreach ($f in $criticos) {
  if (Test-Path (Join-Path $Release $f)) { Write-Output "  OK    $f" }
  else { Write-Output "  FALTA $f"; $faltan += $f }
}
foreach ($f in 'seftool.exe', 'loader') {
  if (Test-Path (Join-Path $Stage $f)) { Write-Output "  OK    seftool\$f" }
  else { Write-Output "  FALTA seftool\$f"; $faltan += "seftool\$f" }
}
# El instalador del driver USB es opcional (sin el, SENUS explica como usar Zadig),
# pero conviene que se vea.
if (Test-Path (Join-Path $Release 'herramientas\wdi-simple.exe')) {
  Write-Output '  OK    herramientas\wdi-simple.exe (instalacion del driver USB con un clic)'
} else {
  Write-Output '  AVISO herramientas\wdi-simple.exe no esta: SENUS pedira usar Zadig para el driver'
}
if ($faltan.Count -gt 0) { throw ("faltan piezas criticas: " + ($faltan -join ', ')) }

Paso 'empaquetando con Inno Setup'
if (-not (Test-Path $Iscc)) { throw "no encuentro ISCC.exe en $Iscc" }
& $Iscc "/DAppVersion=$Version" (Join-Path $Repo 'instaladores\senus_windows.iss')
if ($LASTEXITCODE -ne 0) { throw "Inno Setup fallo (codigo $LASTEXITCODE)" }

$out = Join-Path $Repo "instaladores\dist\senus-$Version-setup.exe"
if (-not (Test-Path $out)) { throw 'no se genero el instalador' }
$i = Get-Item $out
$sha = (Get-FileHash $out -Algorithm SHA256).Hash.ToLower()
Write-Output ""
Write-Output ("LISTO: {0}  ({1:N1} MB)" -f $out, ($i.Length / 1MB))
Write-Output "sha256 $sha"
