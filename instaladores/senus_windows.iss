; Instalador de SENUS para Windows (Inno Setup 6). Mismo método que el de Nairda
; (nairda_robot_programming/installers/desktop_script.iss).
;
; Compilar (lo hace instaladores\windows_release.ps1, que antes construye la app y
; prepara seftool):
;     ISCC.exe /DAppVersion=0.1.0 instaladores\senus_windows.iss
;
; [Files] va POR COMODÍN sobre todo el Release, excluyendo solo artefactos de
; enlazado: así cada plugin nuevo de Flutter o cada DLL de más se empaqueta sola.
; (Es la lección del instalador de Nairda: la lista a mano se queda caduca sin que
; nadie lo note y la app falla en casa de quien la instala.)
;
; INSTALACIÓN POR USUARIO (PrivilegesRequired=lowest): SENUS se instala en
; %LOCALAPPDATA%\Programs\SENUS, sin pedir permisos de administrador. Es lo que
; hace falta porque seftool escribe sus volcados en <carpeta>\seftool\backup, y
; en «Archivos de programa» un usuario normal no puede escribir. El único momento
; en que SENUS pide permisos es cuando instala el driver USB del teléfono
; (aviso de Windows, a petición de la persona).

#define MyAppName "SENUS"
#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#define MyAppPublisher "semakers"
#define MyAppURL "https://semakers.com"
#define MyAppExeName "senus_app.exe"

; Raíz del repo, deducida de la ubicación de este script (instaladores\..).
#define RepoRoot AddBackslash(ExtractFilePath(ExtractFilePath(SourcePath)))
#define ReleaseDir RepoRoot + "app\build\windows\x64\runner\Release"
; seftool.exe + loader\ + rest\, que deja preparados windows_release.ps1.
#define SeftoolDir RepoRoot + "app\build\windows\instalador\seftool"

[Setup]
; La identidad de SENUS ante Windows. NO CAMBIARLO: si cambia, las instalaciones
; existentes no se actualizan sino que aparecen duplicadas en «Aplicaciones».
AppId={{0488F7B3-2935-42C1-BF41-F64B895E2FBF}
AppName={#MyAppName}
AppVersion={#AppVersion}
VersionInfoVersion={#AppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DisableProgramGroupPage=yes
OutputDir={#RepoRoot}instaladores\dist
OutputBaseFilename=senus-{#AppVersion}-setup
SetupIconFile={#RepoRoot}app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; Antes de instalar: la licencia, los programas de terceros y el aviso de que es un proyecto nuevo
; que se usa bajo el propio riesgo (la persona lo acepta para seguir).
LicenseFile={#RepoRoot}app\assets\licencias\AVISOS.txt
PrivilegesRequired=lowest

; Solo x64 (la app y libusb-1.0.dll son de 64 bits).
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64

; Cierra SENUS si está abierta al actualizar, en vez de fallar al sobrescribir el
; .exe.
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; La app entera. Excluidos: artefactos de enlazado, símbolos y restos de depuración.
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; \
  Excludes: "*.lib,*.exp,*.pdb,*.log"; \
  Flags: ignoreversion recursesubdirs createallsubdirs

; seftool y lo que necesita para correr (loader\ con los cargadores firmados, rest\
; con los firmwares de restauración). SENUS lo busca en <carpeta>\seftool.
Source: "{#SeftoolDir}\*"; DestDir: "{app}\seftool"; \
  Flags: ignoreversion recursesubdirs createallsubdirs

[Dirs]
; seftool escribe aquí los volcados del GDFS que hace SENUS al respaldar.
Name: "{app}\seftool\backup"

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

; NOTA SOBRE LA DESINSTALACIÓN: se quita lo que instaló este instalador y nada
; más. Los RESPALDOS DE ROLLBACK de los teléfonos viven en
; %USERPROFILE%\senus\respaldos (fuera de la carpeta de la app) y los volcados
; de seftool en {app}\seftool\backup (que tampoco se borra si tiene ficheros):
; son la única forma de volver al firmware original y NUNCA se tocan.
