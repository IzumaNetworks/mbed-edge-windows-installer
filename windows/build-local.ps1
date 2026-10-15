# SPDX-License-Identifier: Apache-2.0
# Build an unsigned, isolated qualification MSI; does not install a service.
[CmdletBinding()]
param(
    [ValidateSet('Auto','2022','2026')][string]$VisualStudioVersion='Auto',
    [switch]$ValidateBothToolchains,
    [Parameter(Mandatory=$true)][string]$OpenSSLRoot,
    [Parameter(Mandatory=$true)][string]$OpenSSLSourceDirectory,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [string]$EdgeRepositoryDirectory,
    [string]$MonitorRepositoryDirectory,
    [string]$CMakePath='cmake',
    [string]$WixCommand='wix',
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version='0.21.1031',
    [guid]$QualificationId=[guid]::NewGuid()
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$CMakePath=(Get-Command $CMakePath -ErrorAction Stop).Source
$repository=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent $repository
if (-not $EdgeRepositoryDirectory) { $EdgeRepositoryDirectory=Join-Path $workspace 'mbed-edge' }
if (-not $MonitorRepositoryDirectory) { $MonitorRepositoryDirectory=Join-Path $workspace 'edge-core-monitor' }
$EdgeRepositoryDirectory=(Resolve-Path -LiteralPath $EdgeRepositoryDirectory).Path
$MonitorRepositoryDirectory=(Resolve-Path -LiteralPath $MonitorRepositoryDirectory).Path
$OpenSSLRoot=(Resolve-Path -LiteralPath $OpenSSLRoot).Path
$OpenSSLSourceDirectory=(Resolve-Path -LiteralPath $OpenSSLSourceDirectory).Path
if ($VisualStudioVersion -eq 'Auto') {
    $vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    $vsVersion=& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -version '[17.0,19.0)' -property installationVersion
    if (-not $vsVersion) { throw 'Install Visual Studio 2022 or 2026 C++ Build Tools.' }
    $VisualStudioVersion=if (([version]$vsVersion).Major -eq 18) { '2026' } else { '2022' }
}
$generator=if ($VisualStudioVersion -eq '2022') { 'Visual Studio 17 2022' } else { 'Visual Studio 18 2026' }
$edgeBuild=Join-Path $EdgeRepositoryDirectory "build/windows-vs$VisualStudioVersion"
$qualificationService='EdgeCoreMonitorTest-'+$QualificationId.ToString('D')
$monitorBuild=Join-Path $MonitorRepositoryDirectory "build/windows-vs$VisualStudioVersion-$qualificationService"
$out=[IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $out) { throw 'OutputDirectory must be new.' }
New-Item -ItemType Directory -Path $out | Out-Null
function Invoke-BuildScript {
    param([string]$Script,[hashtable]$Arguments)
    $global:LASTEXITCODE=0
    & $Script @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Build failed ($LASTEXITCODE): $Script" }
}
$toolchains=if ($ValidateBothToolchains) { @('2022','2026') } else { @($VisualStudioVersion) }
foreach ($toolchain in $toolchains) {
    $testGenerator=if ($toolchain -eq '2022') { 'Visual Studio 17 2022' } else { 'Visual Studio 18 2026' }
    $edgeArguments=@{BuildDirectory=(Join-Path $EdgeRepositoryDirectory "build/windows-vs$toolchain");
        Configuration='Release';CMakePath=$CMakePath;CMakeGenerator=$testGenerator;OpenSSLRoot=$OpenSSLRoot;
        TestTemporaryDirectory=(Join-Path $workspace 'edge-tests-temp');
        CMakeArgument=@('-DCMAKE_POLICY_VERSION_MINIMUM=3.5','-DEDGE_WINDOWS_TESTS=ON','-DEDGE_WINDOWS_TARGET_BUILD=17763')}
    Invoke-BuildScript (Join-Path $EdgeRepositoryDirectory 'build-windows.ps1') $edgeArguments
    $edgeArguments.CoreTests=$true
    Invoke-BuildScript (Join-Path $EdgeRepositoryDirectory 'build-windows.ps1') $edgeArguments
    Invoke-BuildScript (Join-Path $MonitorRepositoryDirectory 'windows/build.ps1') @{
        BuildDirectory=(Join-Path $MonitorRepositoryDirectory "build/windows-vs$toolchain-$qualificationService");
        Configuration='Release';CMakePath=$CMakePath;CMakeGenerator=$testGenerator;
        QualificationServiceName=$qualificationService}
}
$packageOutput=Join-Path $out 'core-package'
Invoke-BuildScript (Join-Path $PSScriptRoot 'build-package.ps1') @{
    BuildDirectory=$edgeBuild;EdgeRepositoryDirectory=$EdgeRepositoryDirectory;Version=$Version;
    OutputDirectory=$packageOutput;VisualCppDeployment='app-local';OpenSSLSourceDirectory=$OpenSSLSourceDirectory}
$package=Join-Path $packageOutput "edge-core-$Version-windows-x64"
$bundleOutput=Join-Path $out 'bundle-stage'
Invoke-BuildScript (Join-Path $PSScriptRoot 'prepare-msi-bundle.ps1') @{
    CorePackageDirectory=$package;MonitorRepositoryDirectory=$MonitorRepositoryDirectory;
    MonitorExecutable=(Join-Path $monitorBuild 'bin/Release/edge-core-monitor.exe');
    ControlExecutable=(Join-Path $monitorBuild 'bin/Release/izuma-edge-ctl.exe');
    OutputDirectory=$bundleOutput;AllowUnsigned=$true;ExpectedServiceName=$qualificationService}
Invoke-BuildScript (Join-Path $PSScriptRoot 'build-msi.ps1') @{
    BundleDirectory=(Join-Path $bundleOutput 'bundle');OutputDirectory=(Join-Path $out 'msi');
    CMakePath=$CMakePath;CMakeGenerator=$generator;WixCommand=$WixCommand;
    AllowUnsigned=$true;QualificationId=$QualificationId.ToString('D')}
@{version=$Version;artifact=(Get-Content (Join-Path $out 'msi/msi-result.json') -Raw | ConvertFrom-Json).msi;
    packagingToolchain=$VisualStudioVersion;validatedToolchains=@($toolchains);minimumWindowsBuild=17763;
    qualification=$true;serviceName=$qualificationService} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $out 'windows-installer-result.json') -Encoding UTF8
Write-Output "Built unified Windows qualification MSI: $out/windows-installer-result.json"
