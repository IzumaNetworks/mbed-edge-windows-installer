# SPDX-License-Identifier: Apache-2.0
# Build/validation helpers for unmodified Microsoft-signed app-local runtime DLLs.
function Get-EdgeVisualCppDeployment($Manifest) {
    if (-not $Manifest.PSObject.Properties['visualCppDeployment']) { return 'shared' }
    if ($Manifest.visualCppDeployment -notin @('shared','app-local')) { throw 'Unsupported Visual C++ deployment mode.' }
    return [string]$Manifest.visualCppDeployment
}
function Get-EdgeVisualCppRuntimeDirectory([string]$Directory) {
    if ($Directory) { return Get-EdgeLocalDirectory ((Resolve-Path -LiteralPath $Directory).Path) }
    $vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    $visualStudio=& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or -not $visualStudio) { throw 'Specify the Visual Studio x64 redistributable runtime directory.' }
    $candidates=@(Get-ChildItem -LiteralPath (Join-Path $visualStudio 'VC/Redist/MSVC') -Directory | Where-Object Name -match '^\d+\.\d+\.\d+$' | Sort-Object { [version]$_.Name } -Descending)
    foreach ($candidate in $candidates) {
        foreach ($toolset in @('VC145','VC143')) {
            $path=Join-Path $candidate.FullName ("x64/Microsoft.$toolset.CRT")
            if (Test-Path -LiteralPath $path) { return Get-EdgeLocalDirectory $path }
        }
    }
    throw 'The build host has no Visual Studio x64 redistributable CRT DLLs.'
}
function Assert-EdgeVisualCppRuntimeDll([string]$Path,[version]$MinimumVersion) {
    Assert-EdgeNativeImage $Path
    $signature=Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|, )O=Microsoft Corporation(,|$)') { throw 'App-local runtime DLLs must retain a valid original Microsoft signature.' }
    $version=[version](Get-Item -LiteralPath $Path).VersionInfo.ProductVersion
    if ($MinimumVersion -and $version -lt $MinimumVersion) { throw 'App-local runtime DLL is older than the package runtime version.' }
    return $version
}
function Test-EdgeVisualCppRuntime($Manifest,[string]$Root) {
    if ((Get-EdgeVisualCppDeployment $Manifest) -ne 'app-local') { return }
    $required=@('vcruntime140.dll','vcruntime140_1.dll','msvcp140.dll')
    if (-not $Manifest.PSObject.Properties['visualCppDlls'] -or $Manifest.visualCppDlls.Count -lt $required.Count) { throw 'App-local package has no runtime DLL manifest.' }
    $seen=@()
    foreach ($name in $Manifest.visualCppDlls) {
        if ($name -notmatch '^(vcruntime140(_1|_threads)?|msvcp140(_1|_2|_atomic_wait|_codecvt_ids)?|concrt140|vccorlib140)\.dll$' -or $name -in $seen) { throw 'Invalid or duplicate redistributable runtime DLL.' }
        $seen+=$name
        if ('bin/'+$name -notin @($Manifest.files.path)) { throw 'Runtime DLL is not covered by the package manifest.' }
        [void](Assert-EdgeVisualCppRuntimeDll (Join-Path $Root ('bin/'+$name)) ([version]$Manifest.visualCppVersion))
    }
    foreach ($name in $required) { if ($name -notin $seen) { throw 'Required app-local runtime DLL is absent.' } }
    if ('prerequisites/vc_redist.x64.exe' -in @($Manifest.files.path)) { throw 'App-local package must not contain a separate runtime installer.' }
}
