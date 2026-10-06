# SPDX-License-Identifier: Apache-2.0
# Invoked only by the embedded native MSI custom action, as SYSTEM.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('Apply','Rollback','Commit','Uninstall','UndoUninstall','CommitUninstall')][string]$Action,
    [Parameter(Mandatory=$true)][string]$Parameters
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'package-tools.ps1')
. (Join-Path $PSScriptRoot 'service-tools.ps1')
Assert-EdgeAdministrator
$request=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Parameters)) | ConvertFrom-Json
$app=Get-EdgeLocalDirectory $request.appRoot
$bundle=Get-EdgeLocalDirectory $request.bundleDirectory
$owner=Join-Path $app 'msi-owner.json'
$undo=Join-Path $app 'msi-uninstall-rollback.json'
$requestPath=Join-Path $app 'msi-request.json'
$journal=Join-Path $app 'deployment-transaction.json'
$previousOwner=Join-Path $app 'msi-previous-owner.json'
function Save-Request {
    param($Value)
    $Value | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $requestPath -Encoding UTF8
}
function Invoke-Deployment {
    param([string]$Operation)
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $info.Arguments=ConvertTo-EdgeNativeArguments @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'deploy.ps1'),'-RequestFile',$requestPath,'-Action',$Operation)
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $process=New-Object Diagnostics.Process
    $process.StartInfo=$info
    try {
        [void]$process.Start()
        $stdout=$process.StandardOutput.ReadToEndAsync()
        $stderr=$process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        Add-Content -LiteralPath (Join-Path $app 'deployment.log') -Value ($stdout.Result+$stderr.Result)
        if ($process.ExitCode -ne 0) { throw "Deployment failed ($($process.ExitCode)); inspect deployment.log." }
    } finally { $process.Dispose() }
}
try {
    if ($Action -eq 'Rollback') {
        if (Test-Path -LiteralPath $journal) {
            $transaction=Get-Content -LiteralPath $journal -Raw | ConvertFrom-Json
            if ($transaction.stage -notin @('Complete','RolledBack')) {
                Save-Request $request
                Invoke-Deployment 'Rollback'
            }
        }
        if (Test-Path -LiteralPath $previousOwner) {
            $saved=Get-Content -LiteralPath $previousOwner -Raw | ConvertFrom-Json
            if ($saved.content) { [IO.File]::WriteAllText($owner,[string]$saved.content,(New-Object Text.UTF8Encoding($false))) }
            elseif (Test-Path -LiteralPath $owner) { Remove-Item -LiteralPath $owner }
            Remove-Item -LiteralPath $previousOwner
        }
        return
    }
    if ($Action -eq 'Commit') {
        if (Test-Path -LiteralPath $journal) { Invoke-Deployment 'Complete' }
        if (Test-Path -LiteralPath $previousOwner) { Remove-Item -LiteralPath $previousOwner }
        return
    }
    if ($Action -eq 'Apply') {
        if ((Test-Path -LiteralPath (Join-Path $app 'deployment.json')) -and -not (Test-Path -LiteralPath $owner)) {
            throw 'An EXE-managed deployment is present. Uninstall the EXE first; retained device state can be reused by the MSI.'
        }
        if ((Test-Path -LiteralPath $owner) -and (Get-Service $request.serviceName -ErrorAction SilentlyContinue)) {
            $previous=Get-Content -LiteralPath (Join-Path $app 'deployment.json') -Raw | ConvertFrom-Json
            if (-not $request.monitorUserControlSpecified) { $request.monitorUserControl=[int]$previous.monitorUserControl }
            if (-not $request.monitorStartupSpecified) { $request.monitorStartup=[int]$previous.monitorStartup }
            if (-not $request.startServiceSpecified) { $request.startService=[int]((Get-EdgeServiceInfo $request.serviceName).State -eq 'Running') }
        }
        . (Join-Path $PSScriptRoot 'bundle-tools.ps1')
        $manifest=Test-EdgeInstallerBundle $bundle -AllowUnsigned:([bool]$request.allowUnsigned) -SignerThumbprint $request.bundleSignerThumbprint -CoreSignerThumbprint $request.signerThumbprint
        $core=Get-Content -LiteralPath (Join-Path $bundle 'core/package.json') -Raw | ConvertFrom-Json
        $runtime=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64' -ErrorAction SilentlyContinue
        if (-not $runtime -or -not $runtime.Installed -or [version]$runtime.Version.TrimStart('v') -lt [version]$core.visualCppVersion) {
            throw "Install the Microsoft x64 Visual C++ Redistributable $($core.visualCppVersion) or newer before running this MSI."
        }
        # The native custom action supplies fixed deployment roots. Check parents
        # for reparse points before creating any SYSTEM-writable request files.
        New-Item -ItemType Directory -Path $app -Force | Out-Null
        $acl=New-Object Security.AccessControl.DirectorySecurity
        $acl.SetOwner([Security.Principal.SecurityIdentifier]'S-1-5-32-544')
        $acl.SetAccessRuleProtection($true,$false)
        foreach ($grant in @(@('S-1-5-18','FullControl'),@('S-1-5-32-544','FullControl'),@('S-1-5-11','ReadAndExecute'))) {
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(([Security.Principal.SecurityIdentifier]$grant[0]),$grant[1],'ContainerInherit,ObjectInherit','None','Allow')))
        }
        Set-Acl -LiteralPath $app -AclObject $acl
        if (-not (Test-Path -LiteralPath (Join-Path $app 'setup-owner.json'))) {
            @{schema=1;serviceName=$request.serviceName;appRoot=$app} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $app 'setup-owner.json') -Encoding UTF8
        }
        $oldOwner=$null
        # Get-Content adds provider properties to strings in Windows PowerShell
        # 5.1; ConvertTo-Json serializes those instead of a plain backup string.
        if (Test-Path -LiteralPath $owner) { $oldOwner=[IO.File]::ReadAllText($owner) }
        @{content=$oldOwner} | ConvertTo-Json | Set-Content -LiteralPath $previousOwner -Encoding UTF8
        Save-Request $request
        Invoke-Deployment 'Apply'
        @{schema=1;version=$manifest.version;serviceName=$request.serviceName;bundleDirectory=$bundle} | ConvertTo-Json | Set-Content -LiteralPath $owner -Encoding UTF8
        return
    }
    if ($Action -eq 'Uninstall') {
        if (-not (Test-Path -LiteralPath $owner)) { throw 'Missing MSI deployment ownership record.' }
        $deployment=Get-Content -LiteralPath (Join-Path $app 'deployment.json') -Raw | ConvertFrom-Json
        $service=Get-EdgeServiceInfo $request.serviceName
        $request.provisioningFile=''; $request.provisioningMode='deferred'
        $request.installMonitor=[int]$deployment.installMonitor
        $request.monitorUserControl=[int]$deployment.monitorUserControl
        $request.monitorStartup=[int]$deployment.monitorStartup
        $request.startService=[int]($service -and $service.State -eq 'Running')
        $request | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $undo -Encoding UTF8
        Save-Request $request
        Invoke-Deployment 'Uninstall'
        return
    }
    if ($Action -eq 'UndoUninstall') {
        if (-not (Test-Path -LiteralPath $undo)) { return }
        $previous=Get-Content -LiteralPath $undo -Raw | ConvertFrom-Json
        if (-not (Get-Service $previous.serviceName -ErrorAction SilentlyContinue)) {
            Save-Request $previous
            Invoke-Deployment 'Apply'
            Invoke-Deployment 'Complete'
        }
    }
    # State, releases, ownership records and logs remain for explicit recovery.
    if (Test-Path -LiteralPath $undo) { Remove-Item -LiteralPath $undo }
} catch {
    if (Test-Path -LiteralPath $app) {
        Add-Content -LiteralPath (Join-Path $app 'deployment.log') -Value $_.Exception.Message
    }
    throw
}
