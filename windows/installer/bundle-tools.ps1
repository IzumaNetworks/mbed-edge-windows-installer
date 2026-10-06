# SPDX-License-Identifier: Apache-2.0
. (Join-Path $PSScriptRoot 'package-tools.ps1')
function Test-EdgeInstallerBundle {
    param([string]$Directory, [switch]$AllowUnsigned, [string]$SignerThumbprint, [string]$CoreSignerThumbprint)
    $root=Get-EdgeLocalDirectory $Directory
    $manifest=Get-Content -LiteralPath (Join-Path $root 'bundle.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.schema -ne 1 -or $manifest.product -ne 'Izuma Edge' -or $manifest.version -notmatch '^\d+\.\d+\.\d+$') { throw 'Unsupported installer bundle.' }
    $expected=@('bundle.json','bundle.cat')
    foreach ($entry in $manifest.files) {
        if ($entry.path -notmatch '^(core/(bin|scripts|licenses|prerequisites)/[A-Za-z0-9_.-]+|core/package\.(json|cat)|monitor/(edge-core-monitor.exe|set-service-control-policy.ps1|LICENSE)|ctl/izuma-edge-ctl.exe|scripts/[A-Za-z0-9_.-]+)$' -or
            $entry.path -in $expected -or $entry.sha256 -notmatch '^[a-f0-9]{64}$') { throw 'Invalid installer member.' }
        $expected+=$entry.path
        $file=Get-Item -LiteralPath (Join-Path $root $entry.path) -Force
        if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            $file.Length -ne $entry.bytes -or (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne $entry.sha256) { throw 'Installer member integrity check failed.' }
    }
    foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -Force) {
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Installer bundle contains a reparse point.' }
        if (-not $file.PSIsContainer -and $file.FullName.Substring($root.Length+1).Replace('\','/') -notin $expected) { throw 'Unexpected installer member.' }
    }
    foreach ($name in @('monitor/edge-core-monitor.exe','monitor/set-service-control-policy.ps1','monitor/LICENSE','ctl/izuma-edge-ctl.exe','scripts/deploy.ps1','scripts/bundle-tools.ps1','scripts/ctl-integration.ps1','scripts/package-tools.ps1','scripts/provisioning-tools.ps1','scripts/provision-service.ps1')) {
        if ($name -notin $expected) { throw "Missing installer member: $name" }
    }
    Assert-EdgeNativeImage (Join-Path $root 'monitor/edge-core-monitor.exe')
    Assert-EdgeNativeImage (Join-Path $root 'ctl/izuma-edge-ctl.exe')
    if (-not $CoreSignerThumbprint) { $CoreSignerThumbprint=$SignerThumbprint }
    $core=Test-EdgePackage (Join-Path $root 'core') -AllowUnsigned:$AllowUnsigned -SignerThumbprint $CoreSignerThumbprint
    if ($core.version -ne $manifest.version) { throw 'Core and installer versions differ.' }
    $catalog=Join-Path $root 'bundle.cat'
    if ((Test-FileCatalog -Path $root -CatalogFilePath $catalog) -ne 'Valid') { throw 'Installer bundle catalog check failed.' }
    if (-not $AllowUnsigned) {
        $signature=Get-AuthenticodeSignature -LiteralPath $catalog
        if ($SignerThumbprint -notmatch '^[a-fA-F0-9]{40}$' -or $signature.Status -ne 'Valid' -or $signature.SignerCertificate.Thumbprint -ne $SignerThumbprint) { throw 'Installer bundle requires the configured release signature.' }
    }
    return $manifest
}
