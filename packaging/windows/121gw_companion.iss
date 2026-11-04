; Inno Setup script of the 121GW Companion installer.
;   ISCC /DAppVersion=1.2.3 /DSourceDir=<dist\121gw-companion> /DOutputDir=<dir> /DLicenseFile=<LICENSE> /DThirdParty=<THIRD_PARTY_LICENSES.txt> packaging\windows\121gw_companion.iss
; Installs the PyInstaller one-folder output (Python, bleak with its WinRT backend, pywebview, the page) for the current
; user, with a Start menu entry and an optional desktop icon.  The window is a Microsoft Edge WebView2 window (part of
; Windows 11 and current Windows 10); without it the program opens in the default browser.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #error SourceDir (the PyInstaller folder dist\121gw-companion) is required
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif
#ifndef LicenseFile
  #error LicenseFile (the project LICENSE) is required
#endif
#ifndef ThirdParty
  #error ThirdParty (THIRD_PARTY_LICENSES.txt) is required
#endif

[Setup]
AppId={{9B3D1E64-7C21-4F0A-8E6B-121C0A9A0C01}
AppName=121GW Companion
AppVersion={#AppVersion}
AppPublisher=121GW-Open-Firmware
AppPublisherURL=https://github.com/zombu4/121GW-Open-Firmware
DefaultDirName={autopf}\121GW Companion
DefaultGroupName=121GW Companion
PrivilegesRequired=lowest
LicenseFile={#LicenseFile}
OutputDir={#OutputDir}
OutputBaseFilename=121GW-Companion-{#AppVersion}-windows-x64
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayName=121GW Companion
WizardStyle=modern

[Tasks]
Name: "desktopicon"; Description: "Create a desktop icon"; GroupDescription: "Additional icons:"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion
Source: "{#ThirdParty}"; DestDir: "{app}"; DestName: "THIRD_PARTY_LICENSES.txt"; Flags: ignoreversion

[Icons]
Name: "{group}\121GW Companion"; Filename: "{app}\121gw-companion.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\121GW Companion"; Filename: "{app}\121gw-companion.exe"; WorkingDir: "{app}"; Tasks: desktopicon
Name: "{group}\Uninstall 121GW Companion"; Filename: "{uninstallexe}"

[Run]
Filename: "{app}\121gw-companion.exe"; Description: "Start the 121GW Companion now"; Flags: postinstall nowait skipifsilent
