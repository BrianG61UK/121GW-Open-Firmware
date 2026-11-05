; Inno Setup script of the 121GW Companion installer.
;   ISCC /DAppVersion=1.2.3 /DSourceDir=<dist\121gw-companion> /DOutputDir=<dir> /DLicenseFile=<LICENSE> /DThirdParty=<THIRD_PARTY_LICENSES.txt> packaging\windows\121gw_companion.iss
; Installs the PyInstaller one-folder output (Python, bleak with its WinRT backend, pywebview, the page) for all users in
; Program Files (administrator rights, asked by Windows), with a Start menu entry and an optional desktop icon.  The
; program writes nothing into its folder: settings, cache and recordings are per user (meter121/paths.py).  Without
; administrator rights, "/CURRENTUSER" on the command line installs for the current user only (%LOCALAPPDATA%\Programs).
; A per-user copy left by an installer of 1.2.1 or before is removed first, so the program is not installed twice.
; The window is a Microsoft Edge WebView2 window (part of Windows 11 and current Windows 10); without it the program
; opens in the default browser.

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
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=commandline
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

[Code]
// Installers of 1.2.1 and before installed for the current user only (HKCU uninstall entry, %LOCALAPPDATA%\Programs).  An
// all-users install removes such a copy of the same user first (silently, with its own uninstaller), so only one
// copy is left.  A different administrator account that elevates the setup has another HKCU and does not see it.
const
  UninstKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{9B3D1E64-7C21-4F0A-8E6B-121C0A9A0C01}_is1';

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Cmd: String;
  Code: Integer;
begin
  Result := '';
  if IsAdminInstallMode and RegQueryStringValue(HKCU, UninstKey, 'UninstallString', Cmd) then
  begin
    Cmd := RemoveQuotes(Cmd);
    if FileExists(Cmd) then
      if not Exec(Cmd, '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART', '', SW_HIDE, ewWaitUntilTerminated, Code) or (Code <> 0) then
        Result := 'The earlier per-user copy of the 121GW Companion could not be removed (' + Cmd + '). Uninstall it in ' +
                  'Settings > Apps, then run this setup again.';
  end;
end;
