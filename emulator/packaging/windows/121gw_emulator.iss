; Inno Setup script of the 121GW emulator installer.
;   ISCC /DAppVersion=1.2.3 /DSourceDir=<dist\121gw-emulator> /DOutputDir=<dir> /DLicenseFile=<LICENSE> packaging\windows\121gw_emulator.iss
; Installs for all users into Program Files (administrator rights, asked by Windows), adds a Start menu entry and an
; uninstaller.  The program writes nothing into its folder: downloaded firmware goes to %LOCALAPPDATA%\121GW-Emulator
; (emu/fetch.py), an uploaded image to the temporary folder (app.py load_app).  Without administrator rights,
; "/CURRENTUSER" on the command line installs for the current user only (%LOCALAPPDATA%\Programs).  A per-user copy
; left by an installer of v1.0.7 or before is removed first, so the program is not installed twice.
; The program is the official embeddable CPython running app\launcher.py without a console (pythonw.exe): the front panel
; opens in its own window (pywebview with Microsoft Edge WebView2), closing it stops the emulator; without the WebView2
; runtime the panel opens in the default browser and its Quit button stops the emulator.  A start-up error is shown in a
; message box.  Start menu entry and (ticked by default) a desktop icon.
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
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=commandline
LicenseFile={#LicenseFile}
OutputDir={#OutputDir}
OutputBaseFilename=121GW-Open-Firmware-Emulator-{#AppVersion}-windows-x64
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayName=121GW Emulator
WizardStyle=modern

[Tasks]
Name: "desktopicon"; Description: "Create a desktop icon"; GroupDescription: "Additional icons:"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\121GW Emulator"; Filename: "{app}\python\pythonw.exe"; Parameters: """{app}\app\launcher.py"""; WorkingDir: "{app}"; IconFilename: "{app}\app\121gw-emulator.ico"
Name: "{autodesktop}\121GW Emulator"; Filename: "{app}\python\pythonw.exe"; Parameters: """{app}\app\launcher.py"""; WorkingDir: "{app}"; IconFilename: "{app}\app\121gw-emulator.ico"; Tasks: desktopicon
Name: "{group}\Uninstall 121GW Emulator"; Filename: "{uninstallexe}"

[Run]
Filename: "{app}\python\pythonw.exe"; Parameters: """{app}\app\launcher.py"""; Description: "Start the 121GW emulator now"; Flags: postinstall nowait skipifsilent

[Code]
// Installers of v1.0.7 and before installed for the current user only (HKCU uninstall entry, %LOCALAPPDATA%\Programs).
// An all-users install removes such a copy of the same user first (silently, with its own uninstaller), so only one
// copy is left.  A different administrator account that elevates the setup has another HKCU and does not see it.
const
  UninstKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{6E0A2E58-3B0B-4C3F-9E4E-121C0DE0EE01}_is1';

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
        Result := 'The earlier per-user copy of the 121GW Emulator could not be removed (' + Cmd + '). Uninstall it in ' +
                  'Settings > Apps, then run this setup again.';
  end;
end;
