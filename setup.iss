; Inno Setup — Reup Video installer (backend + Flutter desktop)

#define AppName      "Reup Video"
#define AppVersion   "2.1.21"
#define AppPublisher "ReupVideo"
#define BackendExe   "ReupVideo.exe"
#define FlutterExe   "reup_flutter.exe"
#define FlutterDir   "flutter_ui\build\windows\x64\runner\Release"

[Setup]
AppId={{8F4A2C1D-3E7B-4F9A-B2D6-1C5E8A0F3D7B}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
AllowNoIcons=yes
OutputDir=dist\installer
OutputBaseFilename=Setup_ReupVideo_{#AppVersion}
SetupIconFile=assets\icon.ico
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
UninstallDisplayIcon={app}\{#BackendExe}
UninstallDisplayName={#AppName}
ShowLanguageDialog=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Tao shortcut tren Desktop"; GroupDescription: "Shortcut:"

[Files]
; Backend (PyInstaller single exe)
Source: "dist\{#BackendExe}"; DestDir: "{app}"; Flags: ignoreversion

; Flutter desktop app + all required DLLs and assets
Source: "{#FlutterDir}\{#FlutterExe}";   DestDir: "{app}"; Flags: ignoreversion
Source: "{#FlutterDir}\*.dll";            DestDir: "{app}"; Flags: ignoreversion
Source: "{#FlutterDir}\plugins\*";        DestDir: "{app}\plugins"; Flags: ignoreversion recursesubdirs skipifsourcedoesntexist
Source: "{#FlutterDir}\data\*";           DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs

[Icons]
; Shortcut points to backend launcher (which starts Flutter)
Name: "{group}\{#AppName}";              Filename: "{app}\{#BackendExe}"; IconFilename: "{app}\{#BackendExe}"
Name: "{group}\Gỡ cài đặt {#AppName}";  Filename: "{uninstallexe}"
Name: "{userdesktop}\{#AppName}";       Filename: "{app}\{#BackendExe}"; IconFilename: "{app}\{#BackendExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#BackendExe}"; \
  Description: "Khởi chạy {#AppName}"; \
  Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{userappdata}\ReupVideo"
