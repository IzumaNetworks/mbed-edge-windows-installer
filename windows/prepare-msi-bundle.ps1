# SPDX-License-Identifier: Apache-2.0
# Build host only: stage the Core, monitor and CLI payload for WiX MSI authoring.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$CorePackageDirectory,
    [Parameter(Mandatory=$true)][string]$MonitorRepositoryDirectory,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [string]$MonitorExecutable,
    [string]$ControlExecutable,
    [ValidatePattern('^(EdgeCore|EdgeCoreMonitorTest-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$')]
    [string]$ExpectedServiceName='EdgeCore',
    [switch]$AllowUnsigned,
    [string]$SignerThumbprint
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
$monitorVersion=[version](Get-Item -LiteralPath $exe).VersionInfo.FileVersion
if (-not $ControlExecutable) { $ControlExecutable=Join-Path $monitor 'build/bin/Release/izuma-edge-ctl.exe' }
$ctl=(Resolve-Path -LiteralPath $ControlExecutable).Path
Assert-EdgeNativeImage $ctl
# The CLI and GUI share monitor-core's compiled service binding. Query only;
# a missing/stopped service on the build host is valid for this metadata check.
$processInfo=New-Object Diagnostics.ProcessStartInfo
$processInfo.FileName=$ctl; $processInfo.Arguments='status --json'
$processInfo.UseShellExecute=$false; $processInfo.CreateNoWindow=$true
$processInfo.RedirectStandardOutput=$true; $processInfo.RedirectStandardError=$true
$controlProcess=New-Object Diagnostics.Process
$controlProcess.StartInfo=$processInfo
try {
    [void]$controlProcess.Start()
    $controlOutput=$controlProcess.StandardOutput.ReadToEndAsync()
    $controlErrors=$controlProcess.StandardError.ReadToEndAsync()
    if (-not $controlProcess.WaitForExit(15000)) {
        $controlProcess.Kill(); throw 'Control helper service-binding query timed out.'
    }
    $controlStatus=$controlOutput.Result | ConvertFrom-Json
    if (-not $controlStatus -or $controlStatus.service -ne $ExpectedServiceName) {
        throw "Monitor/CLI service binding differs from the installer target $ExpectedServiceName. Rebuild the monitor for this service."
    }
} finally { $controlProcess.Dispose() }
$out=Get-EdgeLocalDirectory ([IO.Path]::GetFullPath($OutputDirectory))
if (Test-Path -LiteralPath $out) { throw 'OutputDirectory must be new.' }
$bundle=Join-Path $out 'bundle'
New-Item -ItemType Directory -Path (Join-Path $bundle 'scripts'),(Join-Path $bundle 'monitor'),(Join-Path $bundle 'ctl') -Force | Out-Null
Copy-Item -LiteralPath $core -Destination (Join-Path $bundle 'core') -Recurse
Copy-Item -LiteralPath $exe -Destination (Join-Path $bundle 'monitor/edge-core-monitor.exe')
Copy-Item -LiteralPath $ctl -Destination (Join-Path $bundle 'ctl/izuma-edge-ctl.exe')
Copy-Item -LiteralPath (Join-Path $monitor 'windows/set-service-control-policy.ps1') -Destination (Join-Path $bundle 'monitor')
Copy-Item -LiteralPath (Join-Path $monitor 'LICENSE') -Destination (Join-Path $bundle 'monitor')
foreach ($name in @('deploy.ps1','bundle-tools.ps1','ctl-integration.ps1')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "installer/$name") -Destination (Join-Path $bundle 'scripts')
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'installer/msi-deploy.ps1') -Destination (Join-Path $bundle 'scripts')
foreach ($name in @('package-tools.ps1','visual-cpp-tools.ps1','service-tools.ps1','install-service.ps1','install-package.ps1','update-service.ps1','provisioning-tools.ps1','provision-service.ps1')) {
    # Maintenance uses this checkout's helpers; validate all of them in the bundle.
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $bundle 'scripts')
}
$metadata=[ordered]@{schema=1; product='Izuma Edge'; version=$manifest.version; architecture='x64'; monitorVersion=$monitorVersion.ToString(); serviceName=$ExpectedServiceName; files=@()}
foreach ($file in Get-ChildItem -LiteralPath $bundle -Recurse -File | Sort-Object FullName) {
    $metadata.files+=@{path=$file.FullName.Substring($bundle.Length+1).Replace('\','/'); bytes=$file.Length; sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
}
$metadata | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $bundle 'bundle.json') -Encoding UTF8
New-FileCatalog -Path $bundle -CatalogFilePath (Join-Path $bundle 'bundle.cat') -CatalogVersion 2 | Out-Null
. (Join-Path $bundle 'scripts/bundle-tools.ps1')
[void](Test-EdgeInstallerBundle $bundle -AllowUnsigned)
Write-Output "Prepared $bundle. Sign bundle.cat before building a production MSI."
