# SPDX-License-Identifier: Apache-2.0
# Read-only validation plus mutations of disposable package copies. No services.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$BundleDirectory,[Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$source=(Resolve-Path -LiteralPath $BundleDirectory).Path
. (Join-Path $source 'scripts/bundle-tools.ps1')
$out=Get-EdgeLocalDirectory ([IO.Path]::GetFullPath($OutputDirectory))
if (Test-Path -LiteralPath $out) { throw 'OutputDirectory must be new.' }
New-Item -ItemType Directory -Path $out | Out-Null
$result=[ordered]@{passed=$false;checks=@();error=$null}
function Case-Copy { param([string]$Name); $directory=Join-Path $out $Name; Copy-Item -LiteralPath $source -Destination $directory -Recurse; return $directory }
function Rejected { param([string]$Path,[string]$Text); $failed=$false; try { [void](Test-EdgeInstallerBundle $Path -AllowUnsigned) } catch { $failed=$true }; if (-not $failed) { throw $Text }; $result.checks+=$Text }
try {
    [void](Test-EdgeInstallerBundle $source -AllowUnsigned)
    $result.checks+='Intact native x64 core/monitor bundle accepted for qualification'
    $failed=$false; try { [void](Test-EdgeInstallerBundle $source) } catch { $failed=$true }
    if (-not $failed) { throw 'Unsigned production bundle accepted.' }
    $result.checks+='Unsigned production deployment rejected'
    $directory=Case-Copy 'monitor-tamper'
    $file=Join-Path $directory 'monitor/edge-core-monitor.exe'
    $bytes=[IO.File]::ReadAllBytes($file); $bytes[$bytes.Length-1]=$bytes[$bytes.Length-1] -bxor 1; [IO.File]::WriteAllBytes($file,$bytes)
    Rejected $directory 'Modified privileged monitor helper rejected'
    $directory=Case-Copy 'policy-tamper'
    Add-Content -LiteralPath (Join-Path $directory 'monitor/set-service-control-policy.ps1') -Value '# modified'
    Rejected $directory 'Modified service-control policy helper rejected'
    $directory=Case-Copy 'unexpected-provisioning'
    'No credentials: unexpected fixture file' | Set-Content -LiteralPath (Join-Path $directory 'provisioning.cbor')
    Rejected $directory 'Unlisted provisioning payload rejected'
    $directory=Case-Copy 'manifest-tamper'
    $path=Join-Path $directory 'bundle.json'; $metadata=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json; $metadata.version='0.21.9999'
    $metadata | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding UTF8
    Rejected $directory 'Modified installer version metadata rejected'
    $result.passed=$true
} catch { $result.error=$_.Exception.Message }
finally { $result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $out 'results.json') -Encoding UTF8 }
if (-not $result.passed) { throw $result.error }
$result.checks
