# SPDX-License-Identifier: Apache-2.0
# Build an offline native Burn bundle. Signing is deliberately a separate step:
# sign the detached engine, reattach it, then sign the complete setup executable.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$MsiResult,
    [Parameter(Mandatory=$true)][string]$CorePackageDirectory,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [string]$WixCommand='wix',
    [string]$BalExtension='WixToolset.BootstrapperApplications.wixext',
    [string]$UtilExtension='WixToolset.Util.wixext',
    [string]$ExpectedSignerSubject,
    [string]$BrandingDirectory,
    [switch]$AllowUnsigned
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if (-not $BrandingDirectory) { $BrandingDirectory=Join-Path $PSScriptRoot 'installer/branding' }
$metadata=Get-Content -LiteralPath $MsiResult -Raw | ConvertFrom-Json
$core=(Resolve-Path -LiteralPath $CorePackageDirectory).Path
$manifest=Get-Content -LiteralPath (Join-Path $core 'package.json') -Raw | ConvertFrom-Json
$msi=(Resolve-Path -LiteralPath $metadata.msi).Path
if ($metadata.version -cne $manifest.version -or $manifest.architecture -cne 'x64') { throw 'The MSI and x64 Core package must have the same version.' }
$version=[version]$metadata.version
$required=[version]$manifest.visualCppVersion
$qualification=[bool]$metadata.qualification
if ($AllowUnsigned -ne $qualification) { throw 'Unsigned setup builds require an isolated qualification MSI.' }
$family='Izuma.Edge.Setup'; $product='Izuma Edge'; $suffix=''
if ($qualification) {
    if ($metadata.serviceName -notmatch '^EdgeCoreMonitorTest-([0-9a-f-]{36})$') { throw 'Qualification service identity is invalid.' }
    $qualificationId=[guid]::ParseExact($Matches[1],'D').ToString('D')
    $family+='.'+$qualificationId; $product+=' qualification '+$qualificationId; $suffix='-qualification-'+$qualificationId
} else {
    if (-not $ExpectedSignerSubject) { throw 'ExpectedSignerSubject is required for a production setup.' }
    $signature=Get-AuthenticodeSignature -LiteralPath $msi
    if ($signature.Status -ne 'Valid' -or -not $signature.TimeStamperCertificate -or $signature.SignerCertificate.Subject -cne $ExpectedSignerSubject) { throw 'The MSI must have the expected valid timestamped publisher signature.' }
}
$redist=(Resolve-Path -LiteralPath (Join-Path $core 'prerequisites/vc_redist.x64.exe')).Path
$redistSignature=Get-AuthenticodeSignature -LiteralPath $redist
if ($redistSignature.Status -ne 'Valid' -or $redistSignature.SignerCertificate.Subject -notmatch '(^|, )O=Microsoft Corporation(,|$)') { throw 'Use the original Microsoft-signed VC++ x64 redistributable.' }
$redistVersion=[version](Get-Item -LiteralPath $redist).VersionInfo.ProductVersion
if ($redistVersion -lt $required) { throw 'The embedded VC++ redistributable is older than the Core requirement.' }
$out=[IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $out) { throw 'OutputDirectory must be new.' }
New-Item -ItemType Directory -Path $out | Out-Null
function X { param([string]$Value); return [Security.SecurityElement]::Escape($Value) }
$sha=[Security.Cryptography.SHA256]::Create()
try { $hash=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($family))).Replace('-','') }
finally { $sha.Dispose() }
$upgrade=[guid]::ParseExact($hash.Substring(0,32),'N').ToString('D')
# Search REG_DWORD components rather than comparing the v-prefixed Version REG_SZ.
# A newer installed runtime satisfies the requirement and must not be downgraded.
$detected="VcInstalled = 1 AND (VcMajor > $($required.Major) OR (VcMajor = $($required.Major) AND (VcMinor > $($required.Minor) OR (VcMinor = $($required.Minor) AND (VcBuild > $($required.Build) OR (VcBuild = $($required.Build) AND VcRevision >= $($required.Revision)))))))"
$searches=@(); $variables=@()
foreach ($entry in @(@('VcInstalled','Installed'),@('VcMajor','Major'),@('VcMinor','Minor'),@('VcBuild','Bld'),@('VcRevision','Rbld'))) {
    $variables+='<Variable Name="'+$entry[0]+'" Type="numeric" Value="0" />'
    $searches+='<util:RegistrySearch Id="Search'+$entry[0]+'" Variable="'+$entry[0]+'" Root="HKLM" Key="SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64" Value="'+$entry[1]+'" Result="value" Bitness="always64" />'
}
$properties=@()
foreach ($name in @('INSTALLMONITOR','MONITORUSERCONTROL','MONITORSTARTUP','STARTSERVICE','PROVISIONINGMODE','PROVISIONING')) {
    $hidden=if ($name -eq 'PROVISIONING') { ' Hidden="yes"' } else { '' }
    $variables+='<Variable Name="'+$name+'" Type="string" Value=""'+$hidden+' bal:Overridable="yes" />'
    $properties+='<MsiProperty Name="'+$name+'" Value="['+$name+']" />'
}
$splash=Join-Path $BrandingDirectory 'splash.bmp'
if (-not (Test-Path -LiteralPath $splash)) {
    # A native splash gives Windows a foreground owner for elevation/MSI UI.
    Add-Type -AssemblyName System.Drawing
    $splash=Join-Path $out 'splash.bmp'
    $bitmap=New-Object Drawing.Bitmap(493,312)
    $graphics=[Drawing.Graphics]::FromImage($bitmap)
    $font=New-Object Drawing.Font('Segoe UI',24)
    try {
        $graphics.Clear([Drawing.Color]::White)
        $graphics.DrawString('Izuma Edge',$font,[Drawing.Brushes]::Black,[single]30,[single]125)
        $bitmap.Save($splash,[Drawing.Imaging.ImageFormat]::Bmp)
    } finally { $font.Dispose(); $graphics.Dispose(); $bitmap.Dispose() }
}
$logo=Join-Path $BrandingDirectory 'logo.png'
$logoAttribute=if (Test-Path -LiteralPath $logo) { ' LogoFile="'+(X ([IO.Path]::GetFullPath($logo)))+'"' } else { '' }
$icon=Join-Path $BrandingDirectory 'installer.ico'
$iconAttribute=if (Test-Path -LiteralPath $icon) { ' IconSourceFile="'+(X ([IO.Path]::GetFullPath($icon)))+'"' } else { '' }
$name='izuma-edge-'+$metadata.version+'-windows-x64'+$suffix+'-setup'
$unsigned=Join-Path $out ($name+'-unsigned.exe')
$engine=Join-Path $out 'engine.exe'
$final=Join-Path $out ($name+'.exe')
$source=@"
<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs" xmlns:bal="http://wixtoolset.org/schemas/v4/wxs/bal" xmlns:util="http://wixtoolset.org/schemas/v4/wxs/util">
  <Bundle Name="$(X $product)" Manufacturer="Izuma Networks" Version="$version" UpgradeCode="$upgrade" Compressed="yes" SplashScreenSourceFile="$(X ([IO.Path]::GetFullPath($splash)))"$iconAttribute>
    <BootstrapperApplication><bal:WixInternalUIBootstrapperApplication Theme="standard"$logoAttribute /></BootstrapperApplication>
    $($variables -join "`n")
    $($searches -join "`n")
    <Chain>
      <ExePackage Id="VisualCppX64" SourceFile="$(X $redist)" Compressed="yes" Permanent="yes" PerMachine="yes" Vital="yes" DetectCondition="$(X $detected)" InstallArguments="/install /quiet /norestart" RepairArguments="/repair /quiet /norestart" bal:PrereqPackage="yes">
        <ExitCode Value="0" Behavior="success" />
        <ExitCode Value="3010" Behavior="scheduleReboot" />
        <ExitCode Value="1641" Behavior="forceReboot" />
      </ExePackage>
      <MsiPackage Id="EdgeMsi" SourceFile="$(X $msi)" Compressed="yes" Vital="yes" bal:PrimaryPackageType="default">
        $($properties -join "`n")
      </MsiPackage>
    </Chain>
  </Bundle>
</Wix>
"@
$wxs=Join-Path $out 'izuma-edge-setup.wxs'
[IO.File]::WriteAllText($wxs,$source,[Text.UTF8Encoding]::new($false))
& $WixCommand build $wxs -arch x64 -ext $BalExtension -ext $UtilExtension -out $unsigned
if ($LASTEXITCODE -ne 0) { throw 'Offline setup bundle compilation failed.' }
& $WixCommand burn detach $unsigned -engine $engine
if ($LASTEXITCODE -ne 0) { throw 'Burn engine extraction failed.' }
@{version=$metadata.version;bundle=$final;unsignedBundle=$unsigned;engine=$engine;wixSource=$wxs;upgradeCode=$upgrade;serviceName=$metadata.serviceName;qualification=$qualification;visualCppVersion=$redistVersion.ToString();requiredVisualCppVersion=$required.ToString();msiSha256=(Get-FileHash -LiteralPath $msi).Hash.ToLowerInvariant();redistSha256=(Get-FileHash -LiteralPath $redist).Hash.ToLowerInvariant()} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $out 'setup-result.json') -Encoding UTF8
Write-Output "Prepared offline setup: sign $engine, reattach to $final, then sign $final."
