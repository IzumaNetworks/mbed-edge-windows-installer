# SPDX-License-Identifier: Apache-2.0
# Called by setup/uninstall under administrator or SYSTEM. No downloads/reboots.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RequestFile,[ValidateSet('Apply','Complete','Rollback','Uninstall')][string]$Action)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'bundle-tools.ps1')
. (Join-Path $PSScriptRoot 'service-tools.ps1')
. (Join-Path $PSScriptRoot 'ctl-integration.ps1')
Assert-EdgeAdministrator
$request=Get-Content -LiteralPath $RequestFile -Raw -Encoding UTF8 | ConvertFrom-Json
if ($Action) { $request.action=$Action }
if ($request.serviceName -notmatch '^(EdgeCore|EdgeCoreMonitorTest-[0-9a-f-]{36})$' -or
    $request.action -notin @('Apply','Complete','Rollback','Uninstall')) { throw 'Invalid installer request.' }
$app=Get-EdgeLocalDirectory $request.appRoot
$data=Get-EdgeLocalDirectory $request.dataDirectory
$install=Get-EdgeLocalDirectory $request.installRoot
foreach ($pair in @(@($app,$data),@($app,$install),@($data,$install))) {
    if ($pair[0] -eq $pair[1] -or $pair[0].StartsWith($pair[1]+'\',[StringComparison]::OrdinalIgnoreCase) -or $pair[1].StartsWith($pair[0]+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Setup, binary and private data roots must be separate.' }
}
$name=$request.serviceName
$journalPath=Join-Path $app 'deployment-transaction.json'
$markerPath=Join-Path $app 'deployment.json'
$ownerPath=Join-Path $app 'setup-owner.json'
$policyPath="SOFTWARE\Izuma\EdgeCoreMonitor\Services\$name"
$runName='IzumaEdgeCoreMonitor'; $shortcutName='Edge Core.lnk'
if ($name -ne 'EdgeCore') { $runName+='-'+$name; $shortcutName=$name+'.lnk' }
$shortcut=Join-Path ([Environment]::GetFolderPath('CommonPrograms')) ('Izuma Edge\'+$shortcutName)
$releaseMarker=Join-Path $data 'service-release.json'
$installationMarker=Join-Path $data 'service-install.json'
function Save-Json { param([string]$Path,$Value); $Value | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath ($Path+'.pending') -Encoding UTF8; Move-Item -LiteralPath ($Path+'.pending') -Destination $Path -Force }
function Protect-SetupDirectory {
    param([string]$Path)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    $acl=New-Object Security.AccessControl.DirectorySecurity
    $acl.SetOwner([Security.Principal.SecurityIdentifier]'S-1-5-32-544')
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($grant in @(@('S-1-5-18','FullControl'),@('S-1-5-32-544','FullControl'),@('S-1-5-11','ReadAndExecute'))) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(([Security.Principal.SecurityIdentifier]$grant[0]),$grant[1],'ContainerInherit,ObjectInherit','None','Allow')))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Protect-SetupFile {
    param([string]$Path)
    $file=Get-Item -LiteralPath $Path -Force
    if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Setup executable/script must be a regular file.' }
    $acl=New-Object Security.AccessControl.FileSecurity
    $acl.SetOwner([Security.Principal.SecurityIdentifier]'S-1-5-32-544')
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($grant in @(@('S-1-5-18','FullControl'),@('S-1-5-32-544','FullControl'),@('S-1-5-11','ReadAndExecute'))) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(([Security.Principal.SecurityIdentifier]$grant[0]),$grant[1],'Allow')))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Run-Helper {
    param([string]$Script,[string[]]$Arguments)
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $info.Arguments=ConvertTo-EdgeNativeArguments (@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$Script)+$Arguments)
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $process=New-Object Diagnostics.Process; $process.StartInfo=$info
    try {
        [void]$process.Start()
        $output=$process.StandardOutput.ReadToEnd(); $errors=$process.StandardError.ReadToEnd(); $process.WaitForExit()
        Add-Content -LiteralPath (Join-Path $app 'deployment.log') -Value ($output+$errors)
        if ($process.ExitCode -notin @(0,3010)) { throw "Deployment helper failed ($($process.ExitCode)). See deployment.log in the setup directory." }
        return $process.ExitCode
    } finally { $process.Dispose() }
}
function Set-Integration {
    param([string]$Executable,[bool]$Startup,[ValidateRange(0,65535)][int]$Port=8080)
    # Zero disables Core's optional HTTP listener; the monitor uses its named pipe.
    # The monitor's CLI accepts positive HTTP ports only, so omit that override.
    $portArgument=''; if ($Port -gt 0) { $portArgument=' --port '+$Port }
    $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
    try {
        $run=$base.CreateSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Run')
        try {
            if ($Executable -and $Startup) { $run.SetValue($runName,'"'+$Executable+'"'+$portArgument,[Microsoft.Win32.RegistryValueKind]::String) }
            else { $run.DeleteValue($runName,$false) }
        } finally { $run.Dispose() }
    } finally { $base.Dispose() }
    if ($Executable) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $shortcut) -Force | Out-Null
        $shell=New-Object -ComObject WScript.Shell
        $link=$shell.CreateShortcut($shortcut); $link.TargetPath=$Executable; $link.Arguments='--show'+$portArgument; $link.WorkingDirectory=Split-Path -Parent $Executable; $link.Save()
    } elseif (Test-Path -LiteralPath $shortcut) { Remove-Item -LiteralPath $shortcut }
}
function Get-PolicyValue {
    $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
    try { $key=$base.OpenSubKey($policyPath); if (-not $key) { return $null }; try { return $key.GetValue('AllowStandardUserControl',$null) } finally { $key.Dispose() } } finally { $base.Dispose() }
}
function Restore-Policy {
    param($Transaction)
    if (Get-Service $name -ErrorAction SilentlyContinue) { [void](Invoke-EdgeServiceControl @('sdset',$name,$Transaction.oldDacl)) }
    $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
    try {
        if ($null -eq $Transaction.oldPolicy) { $base.DeleteSubKey($policyPath,$false) }
        else { $key=$base.CreateSubKey($policyPath); try { $key.SetValue('AllowStandardUserControl',[int]$Transaction.oldPolicy,[Microsoft.Win32.RegistryValueKind]::DWord) } finally { $key.Dispose() } }
    } finally { $base.Dispose() }
}
function Rollback-Deployment {
    param($Transaction)
    if ($Transaction.serviceName -ne $name -or $Transaction.appRoot -ne $app) { throw 'Deployment transaction ownership mismatch.' }
    if ($Transaction.coreAction -eq 'Install' -and (Get-Service $name -ErrorAction SilentlyContinue)) {
        [void](Run-Helper (Join-Path $PSScriptRoot 'install-service.ps1') @('-Action','Uninstall','-ServiceName',$name))
    } elseif ($Transaction.coreAction -eq 'Upgrade' -and (Test-Path -LiteralPath (Join-Path $data 'service-update.json'))) {
        $update=Get-Content -LiteralPath (Join-Path $data 'service-update.json') -Raw | ConvertFrom-Json
        if ($update.version -eq $Transaction.targetVersion) {
            [void](Run-Helper (Join-Path $PSScriptRoot 'update-service.ps1') @('-Action','Rollback','-ServiceName',$name))
        }
    }
    Restore-Policy $Transaction
    $oldCtl=''
    if ($Transaction.oldDeployment -and $Transaction.oldDeployment.PSObject.Properties.Name -contains 'ctlDirectory') { $oldCtl=$Transaction.oldDeployment.ctlDirectory }
    Set-EdgeCtlIntegration $app $oldCtl
    if ($Transaction.oldDeployment) {
        $oldPort=8080
        if ($Transaction.oldDeployment.PSObject.Properties.Name -contains 'monitorHttpPort') { $oldPort=[int]$Transaction.oldDeployment.monitorHttpPort }
        Set-Integration $Transaction.oldDeployment.monitorExecutable ([bool]$Transaction.oldDeployment.monitorStartup) $oldPort
        Save-Json $markerPath $Transaction.oldDeployment
    } else {
        Set-Integration '' $false
        if (Test-Path -LiteralPath $markerPath) { Remove-Item -LiteralPath $markerPath }
    }
    $Transaction.stage='RolledBack'; Save-Json $journalPath $Transaction
}
if ($request.action -ne 'Apply') {
    if ($request.action -eq 'Uninstall') {
        $owned=Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
        if ($owned.serviceName -ne $name -or $owned.appRoot -ne $app -or $owned.dataDirectory -ne $data -or $owned.installRoot -ne $install) { throw 'Uninstall ownership mismatch.' }
        # The native helper verifies the SCM command before stopping/removing it.
        [void](Run-Helper (Join-Path $PSScriptRoot 'install-service.ps1') @('-Action','Uninstall','-ServiceName',$name))
        Set-Integration '' $false
        Set-EdgeCtlIntegration $app ''
        $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
        try { $base.DeleteSubKey($policyPath,$false) } finally { $base.Dispose() }
        # Service state/config/logs and core releases are deliberately retained.
        return
    }
    $transaction=Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
    if ($request.action -eq 'Rollback') {
        if ($transaction.stage -ne 'Complete') { Rollback-Deployment $transaction }
    } else { $transaction.stage='Complete'; Save-Json $journalPath $transaction }
    return
}
$bundle=Get-EdgeLocalDirectory $request.bundleDirectory
$bundleSigner=$request.signerThumbprint
if ($request.PSObject.Properties.Name -contains 'bundleSignerThumbprint') { $bundleSigner=$request.bundleSignerThumbprint }
$manifest=Test-EdgeInstallerBundle $bundle -AllowUnsigned:([bool]$request.allowUnsigned) -SignerThumbprint $bundleSigner -CoreSignerThumbprint $request.signerThumbprint
if ($request.installMonitor -notin @(0,1) -or $request.monitorUserControl -notin @(0,1) -or $request.monitorStartup -notin @(0,1) -or $request.startService -notin @(0,1)) { throw 'Installer options must be 0 or 1.' }
if ($request.provisioningMode -notin @('developer','production','deferred') -or
    (($request.provisioningMode -eq 'deferred') -ne (-not [bool]$request.provisioningFile))) { throw 'Provisioning mode and file selection do not match.' }
if ([int]$request.httpPort -lt 0 -or [int]$request.httpPort -gt 65535 -or [int]$request.protocolPort -lt 1 -or [int]$request.protocolPort -gt 65535) { throw 'Invalid service ports.' }
if (Test-Path -LiteralPath $app) {
    foreach ($member in Get-ChildItem -LiteralPath $app -Recurse -Force) {
        if ($member.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse point in setup directory.' }
    }
    # An older uninstaller may leave empty directories it did not create.
    # Refuse any retained file without an owner marker; empty directories are
    # safe to reuse after the reparse checks and ACL reset.
    if (-not (Test-Path -LiteralPath $ownerPath) -and (Get-ChildItem -LiteralPath $app -Force -Recurse -File | Select-Object -First 1)) { throw 'Setup directory is not owned by Izuma Edge.' }
    if (Test-Path -LiteralPath $ownerPath) {
        $owner=Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json
        if ($owner.serviceName -ne $name -or $owner.appRoot -ne $app) { throw 'Setup owner marker mismatch.' }
    }
}
$old=$null
if (Test-Path -LiteralPath $markerPath) {
    $old=Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
    if ($old.serviceName -ne $name -or $old.appRoot -ne $app -or $old.dataDirectory -ne $data -or $old.installRoot -ne $install) { throw 'Existing setup ownership mismatch.' }
    if ([version]$manifest.version -lt [version]$old.version) { throw 'Installer downgrade is not allowed.' }
}
if (Test-Path -LiteralPath $journalPath) {
    $unfinished=Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
    if ($unfinished.stage -notin @('Complete','RolledBack')) { throw 'An interrupted deployment needs Rollback using this setup helper and the original request before retrying.' }
}
$service=Get-EdgeServiceInfo $name
$coreAction='Install'; $oldDacl=''
if ($service) {
    if ($request.provisioningFile) { throw 'An existing service retains provisioning. Do not supply new credentials during upgrade.' }
    $registered=Get-Content -LiteralPath $installationMarker -Raw | ConvertFrom-Json
    $active=Get-Content -LiteralPath $releaseMarker -Raw | ConvertFrom-Json
    if ($registered.serviceName -ne $name -or $service.StartName -ne 'NT AUTHORITY\LocalService' -or
        $active.directory -ne $registered.installDirectory -or -not $active.directory.StartsWith($install+'\releases\',[StringComparison]::OrdinalIgnoreCase) -or
        -not $service.PathName.StartsWith(('"'+$active.directory+'\edge-core.exe" --service --service-name '+$name+' '),[StringComparison]::OrdinalIgnoreCase)) { throw 'Existing Edge service does not belong to the requested installation.' }
    if ([version]$manifest.version -lt [version]$active.version) { throw 'Core downgrade is not allowed.' }
    $coreAction='Upgrade'
    if ([version]$manifest.version -eq [version]$active.version) {
        foreach ($entry in $manifest.files | Where-Object {$_.path -like 'core/bin/*'}) {
            if ((Get-FileHash -LiteralPath (Join-Path $active.directory ([IO.Path]::GetFileName($entry.path))) -Algorithm SHA256).Hash -ne $entry.sha256) { throw 'Same-version binaries differ; use a newer version.' }
        }
        $coreAction='Keep'
    }
    $oldDacl=(Invoke-EdgeServiceControl @('sdshow',$name)).Trim()
    $http=[regex]::Match($service.PathName,'--http-port\s+(\d+)(\s|$)')
    if (-not $http.Success) { throw 'Existing service has no local status port setting.' }
    $request.httpPort=[int]$http.Groups[1].Value
}
if ($coreAction -eq 'Install' -and $request.startService -and -not $request.provisioningFile -and -not (Test-Path -LiteralPath (Join-Path $data 'state'))) { throw 'Supply provisioning or select factory installation without starting the service.' }
Protect-SetupDirectory $app
Save-Json $ownerPath @{schema=1;serviceName=$name;appRoot=$app}
Protect-SetupDirectory (Join-Path $app 'scripts')
foreach ($helper in Get-ChildItem -LiteralPath (Join-Path $bundle 'scripts') -File) {
    $target=Join-Path $app ('scripts/'+$helper.Name)
    if (Test-Path -LiteralPath $target) { Protect-SetupFile $target }
    Copy-Item -LiteralPath $helper.FullName -Destination $target -Force
    Protect-SetupFile $target
}
Copy-Item -LiteralPath $RequestFile -Destination (Join-Path $app 'deployment-request.json') -Force
$lock=[IO.File]::Open((Join-Path $app 'deployment.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try {
    $transaction=[ordered]@{schema=1; serviceName=$name; appRoot=$app; stage='Prepared'; coreAction=$coreAction; targetVersion=$manifest.version; oldDacl=$oldDacl; oldPolicy=(Get-PolicyValue); oldDeployment=$old}
    Save-Json $journalPath $transaction
    try {
        $trust=@('-AllowUnsigned'); if (-not $request.allowUnsigned) { $trust=@('-SignerThumbprint',$request.signerThumbprint) }
        $reboot=0
        if ($coreAction -eq 'Install') {
            $args=@('-PackageDirectory',(Join-Path $bundle 'core'),'-ServiceName',$name,'-InstallRoot',$install,'-DataDirectory',$data,'-HttpPort',"$($request.httpPort)",'-ProtocolPort',"$($request.protocolPort)")+$trust
            if ($request.provisioningFile) { $args+=@('-ProvisioningFile',$request.provisioningFile,'-ProvisioningMode',$request.provisioningMode) }
            if ($request.startService) { $args+='-Start' }
            $reboot=Run-Helper (Join-Path $PSScriptRoot 'install-package.ps1') $args
        } elseif ($coreAction -eq 'Upgrade') {
            $candidate=Join-Path $install ('releases/'+$manifest.version)
            if (Test-Path -LiteralPath $candidate) { $candidate+='-attempt-'+[guid]::NewGuid().ToString('D') }
            $reboot=Run-Helper (Join-Path $PSScriptRoot 'update-service.ps1') (@('-ServiceName',$name,'-PackageDirectory',(Join-Path $bundle 'core'),'-ReleaseDirectory',$candidate)+$trust)
        }
        Protect-SetupDirectory (Join-Path $app 'ctl')
        $ctlDir=Join-Path $app ('ctl/'+$manifest.version)
        Protect-SetupDirectory $ctlDir
        $ctlExe=Join-Path $ctlDir 'izuma-edge-ctl.exe'
        if (Test-Path -LiteralPath $ctlExe) {
            Protect-SetupFile $ctlExe
            if ((Get-FileHash -LiteralPath $ctlExe -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath (Join-Path $bundle 'ctl/izuma-edge-ctl.exe')).Hash) { throw 'Existing command-line release differs.' }
        } else { Copy-Item -LiteralPath (Join-Path $bundle 'ctl/izuma-edge-ctl.exe') -Destination $ctlExe }
        Protect-SetupFile $ctlExe
        $monitorExe=''
        if ($request.installMonitor) {
            Protect-SetupDirectory (Join-Path $app 'monitor')
            $monitorDir=Join-Path $app ('monitor/'+$manifest.version)
            Protect-SetupDirectory $monitorDir
            $monitorExe=Join-Path $monitorDir 'edge-core-monitor.exe'
            if (Test-Path -LiteralPath $monitorExe) {
                Protect-SetupFile $monitorExe
                if ((Get-FileHash -LiteralPath $monitorExe -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath (Join-Path $bundle 'monitor/edge-core-monitor.exe')).Hash) { throw 'Existing monitor release differs.' }
            } else { Copy-Item -LiteralPath (Join-Path $bundle 'monitor/edge-core-monitor.exe') -Destination $monitorExe }
            Protect-SetupFile $monitorExe
        }
        $mode='AdministratorsOnly'; if ($request.installMonitor -and $request.monitorUserControl) { $mode='AllLocalUsers' }
        [void](Run-Helper (Join-Path $bundle 'monitor/set-service-control-policy.ps1') @('-Mode',$mode,'-ServiceName',$name))
        Set-Integration $monitorExe ([bool]($request.installMonitor -and $request.monitorStartup)) ([int]$request.httpPort)
        Set-EdgeCtlIntegration $app $ctlDir
        $deployment=@{schema=1; serviceName=$name; appRoot=$app; installRoot=$install; dataDirectory=$data; version=$manifest.version;
            installMonitor=[int]$request.installMonitor; monitorUserControl=[int]($request.installMonitor -and $request.monitorUserControl); monitorStartup=[int]($request.installMonitor -and $request.monitorStartup); monitorExecutable=$monitorExe; monitorHttpPort=[int]$request.httpPort; ctlExecutable=$ctlExe; ctlDirectory=$ctlDir; rebootRequired=($reboot -eq 3010)}
        Save-Json $markerPath $deployment
        $transaction.stage='Applied'; Save-Json $journalPath $transaction
        exit $reboot
    } catch {
        $failure=$_.Exception.Message
        try { Rollback-Deployment ([pscustomobject]$transaction) } catch { throw "Deployment failed: $failure Rollback failed: $($_.Exception.Message). Retain the setup transaction for recovery." }
        throw "Deployment failed and previous service configuration restored: $failure"
    }
} finally { $lock.Dispose() }
