#ifndef StageDir
  #define StageDir "..\build\stage"
#endif
#ifndef OutputPath
  #define OutputPath "..\dist"
#endif
#define AppVersion "1.1.4"

[Setup]
AppId={{D7153E66-0FE7-4BCA-9408-619F9FE590B0}
AppName=Zapret4Discord
AppVersion={#AppVersion}
AppPublisher=Zapret4Discord
AppComments=Discord'a özel bağlantı yöneticisi
DefaultDirName={autopf}\Zapret4Discord
DefaultGroupName=Zapret4Discord
DisableProgramGroupPage=yes
DisableDirPage=auto
PrivilegesRequired=admin
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0.19041
OutputDir={#OutputPath}
OutputBaseFilename=Zapret4Discord-Setup-{#AppVersion}-x64
SetupIconFile=..\assets\app.ico
UninstallDisplayIcon={app}\Zapret4Discord.exe
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern dark
SetupLogging=yes
CloseApplications=yes
RestartApplications=no
AppMutex=Local\Zapret4Discord.UI
UninstallDisplayName=Zapret4Discord
VersionInfoVersion=1.1.4.0
VersionInfoDescription=Zapret4Discord Kurulum

[Languages]
Name: "turkish"; MessagesFile: "compiler:Languages\Turkish.isl"

[Messages]
WelcomeLabel2=Discord'a özel bağlantı yöneticisini yükler.%n%nFortiClient VPN hedefleri ve sanal ağ bağdaştırıcıları kapsam dışında tutulur. DNS sunucuları, proxy ve yönlendirme ayarları korunur. Discord için gerekli 11 hosts kaydı doğrulanır; eksikler yedek alınarak eklenir.%n%nMevcut kurulumun varsa, profilin ve açık/kapalı durumun korunur.
FinishedLabel=Zapret4Discord yüklendi.
FinishedLabelNoIcons=Zapret4Discord yüklendi.

[Tasks]
Name: "desktopicon"; Description: "Masaüstü kısayolu oluştur"; GroupDescription: "Kısayollar:"; Flags: unchecked

[Files]
Source: "{#StageDir}\Zapret4Discord.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#StageDir}\Zapret4Discord.exe.config"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#StageDir}\payload\*"; DestDir: "{app}\payload"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#StageDir}\licenses\*"; DestDir: "{app}\licenses"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#StageDir}\THIRD-PARTY-NOTICES.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#StageDir}\KURULUM.txt"; DestDir: "{app}"; Flags: ignoreversion

[InstallDelete]
Type: files; Name: "{app}\docs\ARASTIRMA.md"
Type: files; Name: "{app}\docs\DOGRULAMA.md"
Type: files; Name: "{app}\docs\SEARCH-SOURCES.json"
Type: dirifempty; Name: "{app}\docs"

[Icons]
Name: "{group}\Zapret4Discord"; Filename: "{app}\Zapret4Discord.exe"; WorkingDir: "{app}"
Name: "{group}\Zapret4Discord Kaldır"; Filename: "{uninstallexe}"
Name: "{autodesktop}\Zapret4Discord"; Filename: "{app}\Zapret4Discord.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\Zapret4Discord.exe"; Description: "Zapret4Discord'u aç"; Flags: nowait postinstall skipifsilent runasoriginaluser

[Code]
function CloseManager(): Boolean;
var
  Window: HWND;
  Attempt: Integer;
begin
  Result := True;
  Window := FindWindowByWindowName('Zapret4Discord');
  if Window <> 0 then
  begin
    { New releases explicitly exit; 1.0 understands WM_CLOSE instead. }
    PostMessage(Window, $8002, 0, 0);
    PostMessage(Window, $0010, 0, 0);
  end;
  for Attempt := 1 to 100 do
  begin
    if not CheckForMutexes('Local\Zapret4Discord.UI') then Exit;
    Sleep(100);
  end;
  Result := False;
  SuppressibleMsgBox('Profil kontrolü veya başka bir işlem sürüyor. İşlem tamamlandıktan sonra kurulumu yeniden çalıştırın.', mbError, MB_OK, IDOK);
end;

function InitializeSetup(): Boolean;
var
  Release: Cardinal;
begin
  Result := RegQueryDWordValue(HKLM64, 'SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full', 'Release', Release) and (Release >= 528040);
  if not Result then
    SuppressibleMsgBox('Bu program .NET Framework 4.8 gerektirir. Windows Update üzerinden yükleyip kurulumu yeniden çalıştırın.', mbError, MB_OK, IDOK);
  if Result then Result := CloseManager();
end;

function InitializeUninstall(): Boolean;
begin
  Result := CloseManager();
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
  Params: String;
begin
  if CurStep = ssPostInstall then
  begin
    WizardForm.StatusLabel.Caption := 'Discord''a özel servis hazırlanıyor...';
    Params := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\payload\Manage-DiscordOnly.ps1') + '" -Action Setup';
    if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Params, ExpandConstant('{app}\payload'), SW_HIDE, ewWaitUntilTerminated, ResultCode) then
      RaiseException('Arka plan servisi hazırlanamadı.');
    if ResultCode <> 0 then
      RaiseException('Servis kurulumu tamamlanamadı. C:\ProgramData\ZapretDiscordOnly\logs\management.log dosyasını kontrol edin.');
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ResultCode: Integer;
  ScriptPath: String;
begin
  if CurUninstallStep = usUninstall then
  begin
    ScriptPath := ExpandConstant('{commonappdata}\ZapretDiscordOnly\Manage-DiscordOnly.ps1');
    if FileExists(ScriptPath) then
    begin
      if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + ScriptPath + '" -Action Uninstall', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
        RaiseException('Discord servisi kaldırılamadı.');
      if ResultCode <> 0 then
        RaiseException('Discord servisi kaldırılamadı; günlük dosyasını kontrol edin.');
    end;
  end;
end;
