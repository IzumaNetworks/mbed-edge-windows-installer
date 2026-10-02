# SPDX-License-Identifier: Apache-2.0
# Credential-free preflight validation. No elevation or services required.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../../windows/provisioning-tools.ps1')
$out=Get-EdgeLocalDirectory ([IO.Path]::GetFullPath($OutputDirectory))
if (Test-Path -LiteralPath $out) { throw 'Output directory must be new.' }
New-Item -ItemType Directory -Path $out | Out-Null
$result=[ordered]@{passed=$false; checks=@(); error=$null}
function Check { param([bool]$Value,[string]$Text); if (-not $Value) { throw $Text }; $result.checks+=$Text }
function Reject { param([string]$File,[string]$Text); $failed=$false; try { [void](Read-EdgeProvisioningInput $File) } catch { $failed=$true }; Check $failed $Text }
try {
    $cbor=Join-Path $out 'fixture.cbor'
    [IO.File]::WriteAllBytes($cbor,[byte[]](0xa0))
    Check ((Read-EdgeProvisioningInput $cbor).extension -eq '.cbor') 'Nonempty CBOR staged as opaque runtime input; FCC semantics are checked when the client starts'
    $der=Join-Path $out 'fixture.der'; [IO.File]::WriteAllBytes($der,[byte[]](0x30,0x00))
    $rot=Join-Path $out 'root.bin'; [IO.File]::WriteAllBytes($rot,(New-Object byte[] 16))
    $json=Join-Path $out 'fixture.json'
    $bundle=@{SchemeVersion='0.0.1'; Certificates=@(@{Name='fixture'; Format='der'; Data='fixture.der'}); Keys=@(); ConfigParams=@(); RoTFilePath='root.bin'}
    $bundle | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $json
    $plan=Read-EdgeProvisioningInput $json
    Check ($plan.files.Count -eq 2 -and $plan.json.Certificates[0].Data -eq 'Certificates-0.der') 'JSON DER and optional RoT references resolved without any service operation'
    $empty=Join-Path $out 'empty.cbor'; [IO.File]::WriteAllBytes($empty,(New-Object byte[] 0))
    Reject $empty 'Empty input rejected'
    Reject 'relative.cbor' 'Relative source path rejected'
    Reject '\\server\share\fixture.cbor' 'UNC source path rejected'
    Reject ($cbor+':stream') 'Alternate data stream rejected'
    $bad=Join-Path $out 'bad.json'
    '{"SchemeVersion":"9.0.0"}' | Set-Content -LiteralPath $bad
    Reject $bad 'Unknown scheme version rejected'
    '{"SchemeVersion":"0.0.1","Unexpected":1}' | Set-Content -LiteralPath $bad
    Reject $bad 'Unsupported JSON field rejected'
    '{"SchemeVersion":"0.0.1","Certificates":{}}' | Set-Content -LiteralPath $bad
    Reject $bad 'Non-array certificate group rejected'
    $bundle.Certificates[0].Data='missing.der'
    $bundle | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $bad
    Reject $bad 'Missing DER sidecar rejected'
    $bundle.Certificates[0].Data='fixture.der'; $bundle.Certificates[0].Format='pem'
    $bundle | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $bad
    Reject $bad 'Unsupported sidecar format rejected'
    '{"SchemeVersion":"0.0.1"}' | Set-Content -LiteralPath $bad
    Check ((Read-EdgeProvisioningInput $bad).files.Count -eq 0) 'Absent optional groups handled under strict PowerShell mode'
    $result.passed=$true
} catch { $result.error=$_.Exception.Message }
finally { $result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $out 'results.json') }
if (-not $result.passed) { throw $result.error }
$result.checks
