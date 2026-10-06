# SPDX-License-Identifier: Apache-2.0
# Run elevated on a disposable Windows qualification host. No cloud credentials.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$InitialResult,
    [Parameter(Mandatory=$true)][string]$UpgradeResult,
    [Parameter(Mandatory=$true)][string]$OutputDirectory
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../../windows/package-tools.ps1')
. (Join-Path $PSScriptRoot '../../windows/service-tools.ps1')
$first=Get-Content -LiteralPath $InitialResult -Raw | ConvertFrom-Json
$next=Get-Content -LiteralPath $UpgradeResult -Raw | ConvertFrom-Json
if ($first.serviceName -notmatch '^EdgeCoreMonitorTest-([0-9a-f-]{36})$' -or
    $first.serviceName -ne $next.serviceName -or $first.upgradeCode -ne $next.upgradeCode -or
    -not $first.qualification -or -not $next.qualification) { throw 'Only matching isolated qualification MSIs may be tested.' }
$id=$Matches[1]
$out=Get-EdgeLocalDirectory ([IO.Path]::GetFullPath($OutputDirectory))
$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-InitialResult',$InitialResult,'-UpgradeResult',$UpgradeResult,'-OutputDirectory',$out)
    $child=Start-Process -FilePath "$env:SystemRoot/System32/WindowsPowerShell/v1.0/powershell.exe" -ArgumentList (ConvertTo-EdgeNativeArguments $arguments) -Verb RunAs -WindowStyle Hidden -PassThru
    $child.WaitForExit()
    if ($child.ExitCode -ne 0) { throw "Elevated MSI qualification failed ($($child.ExitCode)); inspect results.json." }
    Get-Content -LiteralPath (Join-Path $out 'results.json')
    exit 0
}
if (Test-Path -LiteralPath $out) { throw 'OutputDirectory must be new.' }
New-Item -ItemType Directory -Path $out | Out-Null
$app=Join-Path $env:ProgramFiles ('Izuma/EdgeSetup-qualification-'+$id)
$data=Join-Path $env:ProgramData ('Izuma/EdgeCore-qualification-'+$id)
$name=$first.serviceName
$result=[ordered]@{passed=$false;checks=@();error=$null;serviceName=$name}
function Check { param([bool]$Condition,[string]$Text); if (-not $Condition) { throw $Text }; $result.checks+=$Text; $Text | Add-Content -LiteralPath (Join-Path $out 'progress.log') }
function Msi {
    param([string]$Action,[string]$File,[string]$Case,[string[]]$Extra=@(),[switch]$Fail)
    # msiexec has its own parser: quoting switches opens its hidden help dialog.
    # Quote only paths; these qualification properties contain no spaces.
    if ($Action -notin @('/i','/x') -or ($Extra | Where-Object { $_ -notmatch '^[A-Z]+=(0|1|invalid)$' })) { throw 'Invalid qualification arguments.' }
    $arguments=$Action+' "'+$File+'" /qn /norestart /l*v "'+(Join-Path $out ($Case+'.log'))+'" '+($Extra -join ' ')
    $process=Start-Process -FilePath "$env:SystemRoot/System32/msiexec.exe" -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru
    if ($Fail) { Check ($process.ExitCode -eq 1603) "$Case rejected with MSI installation failure" }
    elseif ($process.ExitCode -notin @(0,3010)) { throw "$Case failed ($($process.ExitCode)); inspect MSI and deployment logs." }
}
try {
    Check (-not (Get-Service $name -ErrorAction SilentlyContinue)) 'Qualification service absent before install'
    Msi '/i' $first.msi 'invalid-option' @('STARTSERVICE=invalid') -Fail
    Check (-not (Get-Service $name -ErrorAction SilentlyContinue)) 'Invalid options do not create a service'
    Msi '/i' $first.msi 'install' @('INSTALLMONITOR=0','STARTSERVICE=0')
    $service=Get-EdgeServiceInfo $name
    Check ($service.State -eq 'Stopped' -and $service.StartName -eq 'NT AUTHORITY\LocalService') 'MSI installs a stopped restricted LocalService service without credentials'
    Check ((Invoke-EdgeServiceControl @('qsidtype',$name)) -match 'RESTRICTED') 'Service SID remains restricted'
    $deployment=Get-Content -LiteralPath (Join-Path $app 'deployment.json') -Raw | ConvertFrom-Json
    Check ($deployment.installMonitor -eq 0 -and (Test-Path -LiteralPath $deployment.ctlExecutable)) 'Headless MSI includes the native command-line helper'
    $sentinel=Join-Path $data 'state/msi-qualification-sentinel.txt'
    'No private credentials; retained-state qualification sentinel.' | Set-Content -LiteralPath $sentinel
    $hash=(Get-FileHash -LiteralPath $sentinel).Hash
    $oldCommand=$service.PathName
    $corruptDirectory=Join-Path $app ('monitor/'+$next.version)
    New-Item -ItemType Directory -Path $corruptDirectory -Force | Out-Null
    $corrupt=Join-Path $corruptDirectory 'edge-core-monitor.exe'
    'Deliberate monitor staging failure after service activation.' | Set-Content -LiteralPath $corrupt
    Msi '/i' $next.msi 'upgrade-rollback' @('INSTALLMONITOR=1') -Fail
    Check ((Get-Content -LiteralPath (Join-Path $app 'deployment.log') -Raw) -match 'Existing monitor release differs') 'Upgrade reaches the deliberate monitor failure after core activation'
    $coreUpdate=Get-Content -LiteralPath (Join-Path $data 'service-update.json') -Raw | ConvertFrom-Json
    Check ($coreUpdate.version -eq $next.version -and $coreUpdate.stage -eq 'RolledBack') 'Core upgrade journal records rollback of the activated version'
    Check ((Get-EdgeServiceInfo $name).PathName -eq $oldCommand) 'Failed MSI upgrade rolls back the core service path'
    Check ((Get-Content -LiteralPath (Join-Path $app 'msi-owner.json') -Raw | ConvertFrom-Json).version -eq $first.version) 'Failed upgrade restores MSI deployment ownership'
    Remove-Item -LiteralPath $corrupt
    Msi '/i' $next.msi 'upgrade' @('INSTALLMONITOR=0')
    Check ((Get-Content -LiteralPath (Join-Path $app 'deployment.json') -Raw | ConvertFrom-Json).version -eq $next.version) 'Major upgrade activates the new version'
    Check ((Get-FileHash -LiteralPath $sentinel).Hash -eq $hash) 'Upgrade retains device state'
    Msi '/i' $first.msi 'downgrade' -Fail
    Check ((Get-Content -LiteralPath (Join-Path $app 'deployment.json') -Raw | ConvertFrom-Json).version -eq $next.version) 'Downgrade rejection leaves the installed version unchanged'
    Msi '/x' $next.msi 'uninstall'
    Check (-not (Get-Service $name -ErrorAction SilentlyContinue)) 'MSI uninstall removes the owned service'
    Check ((Get-FileHash -LiteralPath $sentinel).Hash -eq $hash) 'MSI uninstall retains device state'
    $result.passed=$true
} catch { $result.error=$_.Exception.Message }
finally {
    if (Get-Service $name -ErrorAction SilentlyContinue) {
        try { Msi '/x' $next.msi 'cleanup-new' } catch { }
        if (Get-Service $name -ErrorAction SilentlyContinue) { try { Msi '/x' $first.msi 'cleanup-old' } catch { } }
    }
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $out 'results.json') -Encoding UTF8
}
if (-not $result.passed) { throw $result.error }
$result.checks
