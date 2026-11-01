; Inno Setup script of the 121GW emulator installer.
;   ISCC /DAppVersion=1.2.3 /DSourceDir=<dist\121gw-emulator> /DOutputDir=<dir> /DLicenseFile=<LICENSE> packaging\windows\121gw_emulator.iss
; Installs per user (no administrator rights) into %LOCALAPPDATA%\Programs, adds a Start menu entry and an uninstaller.
; The program is a console application: its window shows the server log, closing it stops the emulator.
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #error SourceDir (the PyInstaller one-folder output) is required
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif
#ifndef LicenseFile
  #error LicenseFile (the project LICENSE) is required
#endif

[Setup]
AppId={{6E0A2E58-3B0B-4C3F-9E4E-121C0DE0EE01}
AppName=121GW Emulator
AppVersion={#AppVersion}
AppPublisher=121GW-Open-Firmware
AppPublisherURL=https://github.com/zombu4/121GW-Open-Firmware
DefaultDirName={autopf}\121GW Emulator
DefaultGroupName=121GW Emulator
PrivilegesRequired=lowest
LicenseFile={#LicenseFile}
OutputDir={#OutputDir}
OutputBaseFilename=121GW-Open-Firmware-Emulator-{#AppVersion}-windows-x64
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayName=121GW Emulator
WizardStyle=modern

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\121GW Emulator"; Filename: "{app}\121gw-emulator.exe"; WorkingDir: "{app}"
Name: "{group}\Uninstall 121GW Emulator"; Filename: "{uninstallexe}"

[Run]
Filename: "{app}\121gw-emulator.exe"; Description: "Start the 121GW emulator now"; Flags: postinstall nowait skipifsilent
