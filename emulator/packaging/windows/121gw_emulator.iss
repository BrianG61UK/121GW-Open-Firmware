; Inno Setup script of the 121GW emulator installer.
;   ISCC /DAppVersion=1.2.3 /DSourceDir=<dist\121gw-emulator> /DOutputDir=<dir> /DLicenseFile=<LICENSE> packaging\windows\121gw_emulator.iss
; Installs per user (no administrator rights) into %LOCALAPPDATA%\Programs, adds a Start menu entry and an uninstaller.
; The program is the official embeddable CPython running app\launcher.py in a console window (the server log); closing
; the window stops the emulator.
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #error SourceDir (the application folder: python\ app\ LICENSE) is required
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
Name: "{group}\121GW Emulator"; Filename: "{app}\python\python.exe"; Parameters: """{app}\app\launcher.py"""; WorkingDir: "{app}"; IconFilename: "{app}\app\121gw-emulator.ico"
Name: "{group}\Uninstall 121GW Emulator"; Filename: "{uninstallexe}"

[Run]
Filename: "{app}\python\python.exe"; Parameters: """{app}\app\launcher.py"""; Description: "Start the 121GW emulator now"; Flags: postinstall nowait skipifsilent
