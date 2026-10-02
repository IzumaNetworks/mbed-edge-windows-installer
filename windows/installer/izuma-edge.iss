; SPDX-License-Identifier: Apache-2.0
; Build through build-installer.ps1 with Inno Setup 7.1+ (native x64 setup).
[Setup]
AppId={#AppId}
AppName=Izuma Edge
AppVersion={#Version}
AppPublisher=Izuma Networks
AppPublisherURL=https://www.izumanetworks.com/
DefaultDirName={autopf}\Izuma\{#AppFolder}
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=admin
SetupArchitecture=x64
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0
WizardStyle=modern
OutputDir={#Output}
OutputBaseFilename={#SetupName}
Compression=lzma2
SolidCompression=yes
LicenseFile={#Bundle}\core\licenses\edge.txt
SetupIconFile={#Icon}
CloseApplications=no
RestartApplications=no
AlwaysRestart=no
RestartIfNeededByRun=no
SetupMutex=Global\{#AppId}.Setup
UninstallDisplayName=Izuma Edge
UninstallDisplayIcon={app}\monitor\{#Version}\edge-core-monitor.exe
#if Unsigned == "0"
SignTool=release
SignedUninstaller=yes
#endif

[Types]
Name: full; Description: "Edge Core with tray monitor"
Name: service; Description: "Edge Core service only"
Name: custom; Description: "Custom installation"; Flags: iscustom

[Components]
Name: core; Description: "Edge Core Windows service (required)"; Types: full service custom; Flags: fixed
Name: monitor; Description: "Edge Core Monitor (optional tray icon)"; Types: full

[Files]
Source: "{#Bundle}\*"; DestDir: "{tmp}\payload"; Flags: dontcopy recursesubdirs createallsubdirs
Source: "{#Bundle}\scripts\*"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#Bundle}\core\licenses\*"; DestDir: "{app}\licenses"; Flags: ignoreversion
Source: "{#Bundle}\monitor\LICENSE"; DestDir: "{app}\licenses"; DestName: "monitor.txt"; Flags: ignoreversion; Components: monitor

[UninstallDelete]
; These directories contain installer-owned executable assets only. Private
; provisioning/state/logs and the core releases are outside {app} and retained.
Type: filesandordirs; Name: "{app}\monitor"
Type: dirifempty; Name: "{app}\scripts"
Type: files; Name: "{app}\deployment.json"
Type: files; Name: "{app}\deployment-transaction.json"
Type: files; Name: "{app}\deployment-request.json"
Type: files; Name: "{app}\deployment.lock"
Type: files; Name: "{app}\deployment.log"
Type: files; Name: "{app}\setup-owner.json"

[Code]
var
  ProvisionModePage: TInputOptionWizardPage;
  ProvisionPage: TInputFileWizardPage;
  OptionsPage: TInputOptionWizardPage;
  RequestPath: String;
  Applied, Completed, RebootRequired, Uninstalling: Boolean;

function JsonString(Value: String): String;
begin
  StringChangeEx(Value, '\', '\\', True);
  StringChangeEx(Value, '"', '\"', True);
  StringChangeEx(Value, #13, '\r', True);
  StringChangeEx(Value, #10, '\n', True);
  Result := '"' + Value + '"';
end;

function OptionValue(Name: String; Checked: Boolean): String;
var Value: String;
begin
  if Checked then Result := '1' else Result := '0';
  Value := ExpandConstant('{param:' + Name + '|}');
  if Value <> '' then Result := Value;
  if (Result <> '0') and (Result <> '1') then RaiseException(Name + ' must be 0 or 1.');
end;

function Request(Action: String): String;
var Monitor: Boolean; Provision, BundlePath, ProvisionMode: String;
begin
  Monitor := False; Provision := ''; BundlePath := ''; ProvisionMode := 'deferred';
  if not Uninstalling then begin
    Monitor := WizardIsComponentSelected('monitor');
    Provision := ProvisionPage.Values[0];
    if ProvisionModePage.SelectedValueIndex = 0 then ProvisionMode := 'developer'
    else if ProvisionModePage.SelectedValueIndex = 1 then ProvisionMode := 'production';
    if (ProvisionMode = 'deferred') and (Provision <> '') then RaiseException('Choose developer or production file provisioning for the selected bundle.');
    if (ProvisionMode <> 'deferred') and (Provision = '') then RaiseException('Select a provisioning file, or choose provisioning later.');
    BundlePath := ExpandConstant('{tmp}\payload');
  end;
  Result := '{"action":' + JsonString(Action) +
    ',"serviceName":' + JsonString('{#ServiceName}') +
    ',"appRoot":' + JsonString(ExpandConstant('{app}')) +
    ',"installRoot":' + JsonString(ExpandConstant('{autopf}\Izuma\{#CoreFolder}')) +
    ',"dataDirectory":' + JsonString(ExpandConstant('{commonappdata}\Izuma\{#CoreFolder}')) +
    ',"bundleDirectory":' + JsonString(BundlePath) +
    ',"provisioningFile":' + JsonString(Provision) +
    ',"provisioningMode":' + JsonString(ProvisionMode) +
    ',"allowUnsigned":{#Unsigned},"signerThumbprint":' + JsonString('{#Signer}') +
    ',"httpPort":' + ExpandConstant('{param:HTTPPORT|8080}') +
    ',"protocolPort":' + ExpandConstant('{param:PROTOCOLPORT|7681}');
  if Uninstalling then Result := Result + '}'
  else Result := Result + ',"installMonitor":' + OptionValue('unused', Monitor) +
    ',"monitorUserControl":' + OptionValue('MONITORUSERCONTROL', OptionsPage.Values[0]) +
    ',"monitorStartup":' + OptionValue('MONITORSTARTUP', OptionsPage.Values[1]) +
    ',"startService":' + OptionValue('STARTSERVICE', OptionsPage.Values[2]) + '}';
end;

function Deploy(Action, Script: String; var Code: Integer): Boolean;
var Parameters: String;
begin
  RequestPath := ExpandConstant('{tmp}\edge-deployment-request.json');
  if not SaveStringToFile(RequestPath, UTF8Encode(Request(Action)), False) then RaiseException('Cannot save setup request.');
  Parameters := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + Script + '" -RequestFile "' + RequestPath + '"';
  Result := ExecAndLogOutput(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Parameters, '', SW_HIDE, ewWaitUntilTerminated, Code, nil);
end;

procedure InitializeWizard;
var Selection, ProvisionMode, ProvisionFile: String;
begin
  Selection := ExpandConstant('{param:INSTALLMONITOR|}');
  if Selection = '' then Selection := GetPreviousData('InstallMonitor', '');
  if Selection = '0' then WizardSelectComponents('core,!monitor')
  else if Selection = '1' then WizardSelectComponents('core,monitor')
  else if Selection <> '' then RaiseException('INSTALLMONITOR must be 0 or 1.');
  ProvisionFile := ExpandConstant('{param:PROVISIONING|}');
  ProvisionMode := Lowercase(ExpandConstant('{param:PROVISIONINGMODE|auto}'));
  if ProvisionMode = 'auto' then begin
    if ProvisionFile <> '' then ProvisionMode := 'developer' else ProvisionMode := 'deferred';
  end;
  ProvisionModePage := CreateInputOptionPage(wpSelectComponents, 'Device identity',
    'Choose how this machine will receive its cloud credentials.',
    'File provisioning works offline. Production credentials must be issued by your factory provisioning system. Upgrades retain existing identity.', True, False);
  ProvisionModePage.Add('Developer credentials from a CBOR or JSON file');
  ProvisionModePage.Add('Production credentials from a per-machine CBOR or JSON file');
  ProvisionModePage.Add('Retain existing identity, or provision later');
  if ProvisionMode = 'developer' then ProvisionModePage.SelectedValueIndex := 0
  else if ProvisionMode = 'production' then ProvisionModePage.SelectedValueIndex := 1
  else if ProvisionMode = 'deferred' then ProvisionModePage.SelectedValueIndex := 2
  else RaiseException('PROVISIONINGMODE must be auto, developer, production or deferred.');
  ProvisionPage := CreateInputFilePage(ProvisionModePage.ID, 'Provisioning file',
    'Select an external provisioning bundle, or leave this blank.',
    'The installer contains no device credentials. Existing installations retain their identity.');
  ProvisionPage.Add('CBOR or JSON provisioning file:', 'Provisioning files|*.cbor;*.json', '.cbor');
  ProvisionPage.Values[0] := ProvisionFile;
  OptionsPage := CreateInputOptionPage(ProvisionPage.ID, 'Service and monitor options',
    'Choose startup behavior and service control access.',
    'Standard users can always view status. Start/Stop requires administrator approval unless explicitly enabled below.', False, False);
  OptionsPage.Add('Allow local users to start and stop Edge Core (monitor installed)');
  OptionsPage.Add('Start the monitor when users sign in (monitor installed)');
  OptionsPage.Add('Start Edge Core after installation (requires provisioning or retained state)');
  OptionsPage.Values[0] := GetPreviousData('MonitorUserControl', '0') = '1';
  OptionsPage.Values[1] := GetPreviousData('MonitorStartup', '1') = '1';
  OptionsPage.Values[2] := ProvisionPage.Values[0] <> '';
end;

procedure CurPageChanged(PageID: Integer);
begin
  if PageID = OptionsPage.ID then begin
    OptionsPage.CheckListBox.ItemEnabled[0] := WizardIsComponentSelected('monitor');
    OptionsPage.CheckListBox.ItemEnabled[1] := WizardIsComponentSelected('monitor');
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var Code: Integer;
begin
  Result := '';
  try
    ExtractTemporaryFiles('{tmp}\payload\*');
    if not Deploy('Apply', ExpandConstant('{tmp}\payload\scripts\deploy.ps1'), Code) then
      Result := 'Could not run the service deployment helper.'
    else if (Code <> 0) and (Code <> 3010) then
      Result := 'Service installation failed. Check deployment.log under ' + ExpandConstant('{app}')
    else begin Applied := True; RebootRequired := Code = 3010; end;
  except
    Result := GetExceptionMessage;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var Code: Integer;
begin
  if CurStep = ssPostInstall then begin
    if not Deploy('Complete', ExpandConstant('{app}\scripts\deploy.ps1'), Code) or (Code <> 0) then
      RaiseException('Could not complete the deployment transaction.');
    Completed := True;
  end;
end;

procedure DeinitializeSetup;
var Code: Integer;
begin
  if Applied and not Completed then begin
    if not Deploy('Rollback', ExpandConstant('{tmp}\payload\scripts\deploy.ps1'), Code) or (Code <> 0) then
      Log('Service rollback failed; retain deployment-transaction.json for administrator recovery.');
  end;
end;

procedure RegisterPreviousData(PreviousDataKey: Integer);
begin
  SetPreviousData(PreviousDataKey, 'InstallMonitor', OptionValue('unused', WizardIsComponentSelected('monitor')));
  SetPreviousData(PreviousDataKey, 'MonitorUserControl', OptionValue('MONITORUSERCONTROL', OptionsPage.Values[0]));
  SetPreviousData(PreviousDataKey, 'MonitorStartup', OptionValue('MONITORSTARTUP', OptionsPage.Values[1]));
end;

function GetCustomSetupExitCode: Integer;
begin
  Result := 0;
  if RebootRequired then Result := 3010;
end;

function InitializeUninstall: Boolean;
var Code: Integer;
begin
  Uninstalling := True;
  Result := Deploy('Uninstall', ExpandConstant('{app}\scripts\deploy.ps1'), Code) and (Code = 0);
  if not Result then Log('Service uninstall failed. Installer files and private data retained.');
end;
