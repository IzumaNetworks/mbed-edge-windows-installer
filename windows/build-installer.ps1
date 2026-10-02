# SPDX-License-Identifier: Apache-2.0
# Build host only: combine an existing Release BYOC/OpenSSL package and monitor.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$CorePackageDirectory,
    [Parameter(Mandatory=$true)][string]$MonitorRepositoryDirectory,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [Parameter(Mandatory=$true)][string]$InnoCompiler,
    [string]$MonitorExecutable,
    [switch]$AllowUnsigned,
    [string]$SignerThumbprint,
    [string]$SignToolCommand,
    [ValidatePattern('^[0-9a-f-]{36}$')][string]$QualificationId
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'package-tools.ps1')
$core=(Resolve-Path -LiteralPath $CorePackageDirectory).Path
$manifest=Test-EdgePackage $core -AllowUnsigned:$AllowUnsigned -SignerThumbprint $SignerThumbprint
$monitor=(Resolve-Path -LiteralPath $MonitorRepositoryDirectory).Path
if (-not $MonitorExecutable) { $MonitorExecutable=Join-Path $monitor 'build/bin/Release/edge-core-monitor.exe' }
$exe=(Resolve-Path -LiteralPath $MonitorExecutable).Path
Assert-EdgeNativeImage $exe
$out=Get-EdgeLocalDirectory ([IO.Path]::GetFullPath($OutputDirectory))
if (Test-Path -LiteralPath $out) { throw 'OutputDirectory must be new.' }
if (-not $AllowUnsigned -and -not $SignToolCommand) { throw 'Production builds require a signing command for setup and its uninstaller.' }
$bundle=Join-Path $out 'bundle'
New-Item -ItemType Directory -Path (Join-Path $bundle 'scripts'),(Join-Path $bundle 'monitor') -Force | Out-Null
Copy-Item -LiteralPath $core -Destination (Join-Path $bundle 'core') -Recurse
Copy-Item -LiteralPath $exe -Destination (Join-Path $bundle 'monitor/edge-core-monitor.exe')
Copy-Item -LiteralPath (Join-Path $monitor 'windows/set-service-control-policy.ps1') -Destination (Join-Path $bundle 'monitor')
Copy-Item -LiteralPath (Join-Path $monitor 'LICENSE') -Destination (Join-Path $bundle 'monitor')
foreach ($name in @('deploy.ps1','bundle-tools.ps1')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "installer/$name") -Destination (Join-Path $bundle 'scripts')
}
foreach ($name in @('package-tools.ps1','service-tools.ps1','install-service.ps1','install-package.ps1','update-service.ps1','provisioning-tools.ps1','provision-service.ps1')) {
    # Maintenance uses this checkout's helpers; validate all of them in the bundle.
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $bundle 'scripts')
}
$metadata=[ordered]@{schema=1; product='Izuma Edge'; version=$manifest.version; architecture='x64'; monitorVersion='0.1.0'; files=@()}
foreach ($file in Get-ChildItem -LiteralPath $bundle -Recurse -File | Sort-Object FullName) {
    $metadata.files+=@{path=$file.FullName.Substring($bundle.Length+1).Replace('\','/'); bytes=$file.Length; sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
}
$metadata | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $bundle 'bundle.json') -Encoding UTF8
New-FileCatalog -Path $bundle -CatalogFilePath (Join-Path $bundle 'bundle.cat') -CatalogVersion 2 | Out-Null
if (-not $AllowUnsigned) {
    # SignToolCommand is a trusted build-host command, with Inno's $f placeholder.
    $signCommand=$SignToolCommand.Replace('$f',('"'+(Join-Path $bundle 'bundle.cat')+'"'))
    & $env:ComSpec /d /s /c $signCommand
    if ($LASTEXITCODE -ne 0) { throw 'Bundle catalog signing failed.' }
}
. (Join-Path $bundle 'scripts/bundle-tools.ps1')
[void](Test-EdgeInstallerBundle $bundle -AllowUnsigned:$AllowUnsigned -SignerThumbprint $SignerThumbprint)
$appId='Izuma.Edge.Windows'; $serviceName='EdgeCore'; $suffix=''; $coreFolder='EdgeCore'; $appFolder='EdgeSetup'
if ($QualificationId) {
    [void][guid]::ParseExact($QualificationId,'D')
    $appId+='.'+$QualificationId; $serviceName='EdgeCoreMonitorTest-'+$QualificationId
    $suffix='-qualification-'+$QualificationId; $coreFolder+=$suffix; $appFolder+=$suffix
}
$setupName='izuma-edge-'+$manifest.version+'-windows-x64'+$suffix
$arguments=@('/Qp',"/DBundle=$bundle","/DOutput=$out","/DVersion=$($manifest.version)","/DSetupName=$setupName","/DAppId=$appId","/DServiceName=$serviceName","/DCoreFolder=$coreFolder","/DAppFolder=$appFolder","/DIcon=$(Join-Path $monitor 'windows/assets/connected.ico')","/DUnsigned=$([int][bool]$AllowUnsigned)","/DSigner=$SignerThumbprint")
if ($SignToolCommand) { $arguments+='/Srelease='+$SignToolCommand }
& $InnoCompiler @arguments (Join-Path $PSScriptRoot 'installer/izuma-edge.iss')
if ($LASTEXITCODE -ne 0) { throw 'Inno Setup compilation failed.' }
$setup=Join-Path $out ($setupName+'.exe')
Assert-EdgeNativeImage $setup
@{setup=$setup; version=$manifest.version; signed=(-not $AllowUnsigned); sha256=(Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash; serviceName=$serviceName; appId=$appId} |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $out 'installer-result.json') -Encoding UTF8
Write-Output "Built $setup"
