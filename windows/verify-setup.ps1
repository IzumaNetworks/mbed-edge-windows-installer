# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$SetupResult,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [string]$WixCommand='wix',
    [string]$ExpectedSignerSubject,
    [switch]$AllowUnsigned
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$setup=Get-Content -LiteralPath $SetupResult -Raw | ConvertFrom-Json
if ($AllowUnsigned -ne [bool]$setup.qualification) { throw 'Unsigned verification requires a qualification setup.' }
if (-not $AllowUnsigned -and -not $ExpectedSignerSubject) { throw 'ExpectedSignerSubject is required.' }
$out=[IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $out) { throw 'OutputDirectory must be new.' }
New-Item -ItemType Directory -Path $out | Out-Null
& $WixCommand burn extract $setup.bundle -o (Join-Path $out 'payloads') -oba (Join-Path $out 'bootstrapper')
if ($LASTEXITCODE -ne 0) { throw 'Setup payload extraction failed.' }
$payloads=@(Get-ChildItem -LiteralPath (Join-Path $out 'payloads') -File -Recurse)
if ($payloads.Count -ne 2) { throw 'The offline setup must embed exactly the MSI and VC++ installer.' }
$msi=@($payloads | Where-Object { (Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant() -ceq $setup.msiSha256 })
$redist=@($payloads | Where-Object { (Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant() -ceq $setup.redistSha256 })
if ($msi.Count -ne 1 -or $redist.Count -ne 1) { throw 'Embedded payload hashes differ from the verified source installers.' }
$redistSignature=Get-AuthenticodeSignature -LiteralPath $redist[0].FullName
if ($redistSignature.Status -ne 'Valid' -or $redistSignature.SignerCertificate.Subject -notmatch '(^|, )O=Microsoft Corporation(,|$)') { throw 'The embedded redistributable must retain its Microsoft signature.' }
$engine=Join-Path $out 'engine.exe'
& $WixCommand burn detach $setup.bundle -engine $engine
if ($LASTEXITCODE -ne 0) { throw 'Final setup engine extraction failed.' }
if (-not $AllowUnsigned) {
    foreach ($path in @($setup.bundle,$engine,$msi[0].FullName)) {
        $signature=Get-AuthenticodeSignature -LiteralPath $path
        if ($signature.Status -ne 'Valid' -or -not $signature.TimeStamperCertificate -or $signature.SignerCertificate.Subject -cne $ExpectedSignerSubject) { throw "Unexpected or invalid timestamped signature: $path" }
    }
}
@{passed=$true;version=$setup.version;embeddedPayloads=2;msiSha256=$setup.msiSha256;redistSha256=$setup.redistSha256;qualification=[bool]$setup.qualification} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $out 'results.json') -Encoding UTF8
Write-Output 'Verified embedded MSI, original Microsoft runtime, and setup/engine signatures.'
