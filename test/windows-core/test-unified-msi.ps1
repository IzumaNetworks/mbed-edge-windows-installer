# SPDX-License-Identifier: Apache-2.0
# Read-only verification of the single Windows delivery artifact.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$InstallerResult,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [switch]$RequireBothToolchains
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$result=Get-Content -LiteralPath $InstallerResult -Raw | ConvertFrom-Json
$artifact=(Resolve-Path -LiteralPath $result.artifact).Path
$out=[IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $out) { throw 'OutputDirectory must be new.' }
New-Item -ItemType Directory -Path $out | Out-Null
$checks=@()
$artifacts=@(Get-ChildItem -LiteralPath (Split-Path -Parent $artifact) -File -Filter '*.msi')
if ($artifacts.Count -ne 1 -or $artifacts[0].FullName -ne $artifact) { throw 'Expected one delivery MSI.' }
$checks+='Exactly one MSI is present in the delivery directory'
if ($RequireBothToolchains) {
    foreach ($toolchain in @('2022','2026')) {
        if ($toolchain -notin @($result.validatedToolchains)) { throw "Missing compiler validation: $toolchain" }
    }
    $checks+='Both compiler validations belong to the same delivery result'
}
$installer=New-Object -ComObject WindowsInstaller.Installer
$database=$installer.OpenDatabase($artifact,0)
function Read-Property([string]$Name) {
    $view=$database.OpenView("SELECT ``Value`` FROM ``Property`` WHERE ``Property`` = '$Name'")
    try { [void]$view.Execute(); $row=$view.Fetch(); if ($row) { return $row.StringData(1) } }
    finally { [void]$view.Close() }
}
if ((Read-Property 'ProductVersion') -ne $result.version) { throw 'MSI version differs from the unified delivery version.' }
$checks+='MSI and delivery manifest use one product version'
$deliveryDirectory=Split-Path -Parent ([IO.Path]::GetFullPath($InstallerResult))
$msiMetadata=Get-Content -LiteralPath (Join-Path $deliveryDirectory 'msi/msi-result.json') -Raw | ConvertFrom-Json
$bundleMetadata=Get-Content -LiteralPath (Join-Path $deliveryDirectory 'bundle-stage/bundle/bundle.json') -Raw | ConvertFrom-Json
if (-not $result.PSObject.Properties['serviceName'] -or
    $result.serviceName -ne $msiMetadata.serviceName -or
    -not $bundleMetadata.PSObject.Properties['serviceName'] -or
    $bundleMetadata.serviceName -ne $msiMetadata.serviceName) {
    throw 'Monitor/CLI bundle, MSI and delivery service identities differ.'
}
$control=Join-Path $deliveryDirectory 'bundle-stage/bundle/ctl/izuma-edge-ctl.exe'
$controlStatus=& $control status --json | ConvertFrom-Json
# A missing/stopped service on the build host is allowed; this is a binding check.
$global:LASTEXITCODE=0
if (-not $controlStatus -or $controlStatus.service -ne $msiMetadata.serviceName) {
    throw 'The packaged CLI/monitor binary targets a different Windows service.'
}
$checks+='Monitor/CLI, MSI and delivery manifest target the same Windows service'
if ((Read-Property 'ProductName') -match 'Visual Studio|VS2022|VS2026' -or
    (Split-Path -Leaf $artifact) -match 'VS2022|VS2026') { throw 'Compiler choice leaked into the installer product name.' }
$checks+='Product and artifact names are independent of the build compiler'
$files=@()
$view=$database.OpenView('SELECT `FileName` FROM `File`')
try {
    [void]$view.Execute()
    while ($row=$view.Fetch()) { $files+=($row.StringData(1) -split '\|')[-1] }
} finally { [void]$view.Close() }
foreach ($name in @('edge-core.exe','edge-provision.exe','edge-core-monitor.exe','izuma-edge-ctl.exe',
    'edge-provisioning-wizard.exe','event.dll','event_core.dll','libcrypto-3-x64.dll','libssl-3-x64.dll',
    'vcruntime140.dll','vcruntime140_1.dll','msvcp140.dll')) {
    if ($name -notin $files) { throw "Unified installer payload is missing $name" }
}
$checks+='One MSI contains Core, converter, monitor, CLI, wizard and runtime dependencies'
if ([int]$result.minimumWindowsBuild -ne 17763) { throw 'Windows 10 minimum target was not retained.' }
$checks+='Delivery retains the Windows 10 build 17763 target'
@{passed=$true;artifact=$artifact;version=$result.version;checks=$checks} |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $out 'results.json') -Encoding UTF8
$checks | Write-Output
