# SPDX-License-Identifier: Apache-2.0
# Build-host packaging only. No certificate/identity input is accepted.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$BuildDirectory,
    [Parameter(Mandatory=$true)][string]$EdgeRepositoryDirectory,
    [Parameter(Mandatory=$true)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [string]$VisualCppRedistributable,
    [ValidateSet('shared','app-local')][string]$VisualCppDeployment='shared',
    [string]$VisualCppRuntimeDirectory,
    [Parameter(Mandatory=$true)][string]$OpenSSLSourceDirectory
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'package-tools.ps1')
$build=(Resolve-Path -LiteralPath $BuildDirectory).Path
$cache=Get-Content -LiteralPath (Join-Path $build 'CMakeCache.txt') -Raw
foreach ($option in @('BYOC_MODE:BOOL=ON','DEVELOPER_MODE:BOOL=OFF','MBED_CLOUD_CLIENT_USE_OPENSSL:BOOL=ON')) {
    if ($cache -notmatch ('(?m)^'+[regex]::Escape($option)+'\r?$')) { throw "Packaging requires $option." }
}
[void][version]$Version
$out=Get-EdgeLocalDirectory ([IO.Path]::GetFullPath($OutputDirectory))
if (Test-Path -LiteralPath $out) { throw 'OutputDirectory must be new.' }
$runtimeDlls=@(); $runtimeVersion=$null; $redist=$null
if ($VisualCppDeployment -eq 'app-local') {
    $runtimeDirectory=Get-EdgeVisualCppRuntimeDirectory $VisualCppRuntimeDirectory
    $runtimeDlls=@(Get-ChildItem -LiteralPath $runtimeDirectory -File -Filter '*.dll')
    $runtimeVersion=Assert-EdgeVisualCppRuntimeDll (Join-Path $runtimeDirectory 'vcruntime140.dll')
    foreach ($file in $runtimeDlls) { [void](Assert-EdgeVisualCppRuntimeDll $file.FullName $runtimeVersion) }
} else {
    if (-not $VisualCppRedistributable) { throw 'Shared runtime packages require the original Microsoft redistributable.' }
    $redist=(Resolve-Path -LiteralPath $VisualCppRedistributable).Path
    $signature=Get-AuthenticodeSignature -LiteralPath $redist
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw 'Use the original Microsoft-signed x64 Visual C++ Redistributable.' }
    $runtimeVersion=[version](Get-Item -LiteralPath $redist).VersionInfo.ProductVersion
}
$repo=(Resolve-Path -LiteralPath $EdgeRepositoryDirectory).Path
$stage=Join-Path $out ('edge-core-'+$Version+'-windows-x64')
foreach ($directory in @('bin','scripts','licenses','prerequisites')) {
    New-Item -ItemType Directory -Path (Join-Path $stage $directory) -Force | Out-Null
}
$binary=Join-Path $build 'bin/Release'
foreach ($name in @('edge-core.exe','event.dll','event_core.dll')) {
    Copy-Item -LiteralPath (Join-Path $binary $name) -Destination (Join-Path $stage 'bin')
}
foreach ($pattern in @('libcrypto-3*.dll','libssl-3*.dll')) {
    $files=@(Get-ChildItem -LiteralPath $binary -Filter $pattern -File)
    if ($files.Count -ne 1) { throw "Expected one $pattern in Release output." }
    Copy-Item -LiteralPath $files[0].FullName -Destination (Join-Path $stage 'bin')
}
foreach ($name in @('install-service.ps1','service-tools.ps1','package-tools.ps1','visual-cpp-tools.ps1','install-package.ps1','update-service.ps1','provisioning-tools.ps1','provision-service.ps1')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $stage 'scripts')
}
if ($VisualCppDeployment -eq 'app-local') {
    foreach ($file in $runtimeDlls) { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $stage ('bin/'+$file.Name)) }
} else { Copy-Item -LiteralPath $redist -Destination (Join-Path $stage 'prerequisites/vc_redist.x64.exe') }
$licenses=@{
    'edge.txt'=(Join-Path $repo 'LICENSE'); 'cloud-client.txt'=(Join-Path $repo 'lib/mbed-cloud-client/LICENSE')
    'libevent.txt'=(Join-Path $repo 'lib/libevent/libevent/LICENSE'); 'libwebsockets.txt'=(Join-Path $repo 'lib/libwebsockets/libwebsockets/LICENSE')
    'jansson.txt'=(Join-Path $repo 'lib/jansson/jansson/LICENSE'); 'tinycbor.txt'=(Join-Path $repo 'lib/mbed-cloud-client/tinycbor/LICENSE')
    'openssl.txt'=(Join-Path $OpenSSLSourceDirectory 'LICENSE.txt')
}
foreach ($name in $licenses.Keys) { Copy-Item -LiteralPath $licenses[$name] -Destination (Join-Path $stage "licenses/$name") }
$manifest=[ordered]@{schema=1; product='Izuma Edge Core'; version=$Version; architecture='x64';
    profile='BYOC/OpenSSL/Release'; createdUtc=[DateTime]::UtcNow.ToString('o');
    visualCppVersion=$runtimeVersion.ToString(); visualCppDeployment=$VisualCppDeployment; files=@()}
if ($VisualCppDeployment -eq 'app-local') { $manifest.visualCppDlls=@($runtimeDlls.Name) }
foreach ($file in Get-ChildItem -LiteralPath $stage -File -Recurse | Sort-Object FullName) {
    $manifest.files += [ordered]@{path=$file.FullName.Substring($stage.Length+1).Replace('\','/'); bytes=$file.Length;
        sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
}
$utf8=New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $stage 'package.json'),($manifest | ConvertTo-Json -Depth 5),$utf8)
New-FileCatalog -Path $stage -CatalogFilePath (Join-Path $stage 'package.cat') -CatalogVersion 2 | Out-Null
[void](Test-EdgePackage -Directory $stage -AllowUnsigned)
$archive=Join-Path $out ('edge-core-'+$Version+'-windows-x64.zip')
Compress-Archive -LiteralPath $stage -DestinationPath $archive -CompressionLevel Optimal
@{directory=$stage; archive=$archive; sha256=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash;
    signed=$false; version=$Version} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $out 'package-result.json')
Write-Output "Created unsigned qualification package: $archive"
