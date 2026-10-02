# SPDX-License-Identifier: Apache-2.0
# One administrator prompt for the isolated provisioning and setup checks.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$InitialResult,
    [Parameter(Mandatory=$true)][string]$UpgradeResult,
    [Parameter(Mandatory=$true)][string]$OutputDirectory
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../../windows/package-tools.ps1')
$out=Get-EdgeLocalDirectory ([IO.Path]::GetFullPath($OutputDirectory))
$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-InitialResult',$InitialResult,'-UpgradeResult',$UpgradeResult,'-OutputDirectory',$out)
    $child=Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList (ConvertTo-EdgeNativeArguments $args) -Verb RunAs -WindowStyle Hidden -PassThru
    $child.WaitForExit()
    if ($child.ExitCode -ne 0) { throw 'Release qualification failed; see results.json and case logs.' }
    Get-Content -LiteralPath (Join-Path $out 'results.json'); exit 0
}
if (Test-Path -LiteralPath $out) { throw 'Output directory must be new.' }
New-Item -ItemType Directory -Path $out | Out-Null
$before=Get-EdgeServiceInfo EdgeCore
$result=[ordered]@{passed=$false; provisioningChecks=0; installerChecks=0; primaryServiceUnchanged=$null; primaryServiceStatus=$null; error=$null}
try {
    & (Join-Path $PSScriptRoot 'test-provisioning.ps1') -InstallerResult $InitialResult -OutputDirectory (Join-Path $out 'provisioning')
    $provision=Get-Content -LiteralPath (Join-Path $out 'provisioning/results.json') -Raw | ConvertFrom-Json
    if (-not $provision.passed -or -not $provision.cleanupVerified) { throw 'Provisioning test did not pass and clean up.' }
    $result.provisioningChecks=$provision.checks.Count
    & (Join-Path $PSScriptRoot 'test-installer.ps1') -InitialResult $InitialResult -UpgradeResult $UpgradeResult -OutputDirectory (Join-Path $out 'installer')
    $installer=Get-Content -LiteralPath (Join-Path $out 'installer/results.json') -Raw | ConvertFrom-Json
    if (-not $installer.passed -or -not $installer.cleanupVerified) { throw 'Installer test did not pass and clean up.' }
    $result.installerChecks=$installer.checks.Count
    $after=Get-EdgeServiceInfo EdgeCore
    if ($before) {
        $result.primaryServiceUnchanged=$after -and $after.PathName -eq $before.PathName -and $after.ProcessId -eq $before.ProcessId -and $after.State -eq $before.State
        if (-not $result.primaryServiceUnchanged) { throw 'Primary service configuration/process changed.' }
        $http=[regex]::Match($after.PathName,'--http-port\s+(\d+)(\s|$)')
        if ($http.Success -and [int]$http.Groups[1].Value -ne 0) {
            try { $result.primaryServiceStatus=(Invoke-RestMethod -Uri ('http://127.0.0.1:'+$http.Groups[1].Value+'/status') -TimeoutSec 5).status } catch { $result.primaryServiceStatus='unavailable' }
        }
    } else { $result.primaryServiceUnchanged=-not $after }
    $result.passed=$true
} catch { $result.error=$_.Exception.Message }
finally { $result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $out 'results.json') -Encoding UTF8 }
if (-not $result.passed) { throw $result.error }
