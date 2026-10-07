# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$BundleDirectory,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [string]$WixCommand='wix',
    [string]$CMakePath='cmake',
    [string]$BrandingDirectory,
    [switch]$AllowUnsigned,
    [switch]$PrepareOnly,
    [ValidatePattern('^[0-9a-f-]{36}$')][string]$QualificationId
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if (-not $BrandingDirectory) { $BrandingDirectory=Join-Path $PSScriptRoot 'installer' }
. (Join-Path $PSScriptRoot 'package-tools.ps1')
$bundle=(Resolve-Path -LiteralPath $BundleDirectory).Path
. (Join-Path $bundle 'scripts/bundle-tools.ps1')
$coreSigner=''; $bundleSigner=''
if (-not $AllowUnsigned) {
    foreach ($catalog in @('core/package.cat','bundle.cat')) {
        $signature=Get-AuthenticodeSignature -LiteralPath (Join-Path $bundle $catalog)
        if ($signature.Status -ne 'Valid' -or -not $signature.TimeStamperCertificate) { throw "A valid timestamped signature is required on $catalog." }
        if ($catalog -eq 'bundle.cat') { $bundleSigner=$signature.SignerCertificate.Thumbprint }
        else { $coreSigner=$signature.SignerCertificate.Thumbprint }
    }
}
$manifest=Test-EdgeInstallerBundle $bundle -AllowUnsigned:$AllowUnsigned -SignerThumbprint $bundleSigner -CoreSignerThumbprint $coreSigner
$coreManifest=Get-Content -LiteralPath (Join-Path $bundle 'core/package.json') -Raw | ConvertFrom-Json
if ((Get-EdgeVisualCppDeployment $coreManifest) -ne 'app-local') { throw 'Build the MSI payload with -VisualCppDeployment app-local so it includes the runtime directly.' }
$version=[version]$manifest.version
if ($version.Major -gt 255 -or $version.Minor -gt 255 -or $version.Build -gt 65535) { throw 'MSI version must fit 255.255.65535.' }
$out=Get-EdgeLocalDirectory ([IO.Path]::GetFullPath($OutputDirectory))
if (Test-Path -LiteralPath $out) { throw 'OutputDirectory must be new.' }
if (-not $PrepareOnly -and -not $AllowUnsigned) { throw 'Use -PrepareOnly, sign the custom action, compile the generated WiX source, then sign and verify the MSI.' }
$service='EdgeCore'; $suffix=''; $family='Izuma.Edge.Msi'; $product='Izuma Edge'
if ($AllowUnsigned -and -not $QualificationId) { throw 'Unsigned MSIs require an isolated -QualificationId.' }
if ($QualificationId) {
    [void][guid]::ParseExact($QualificationId,'D')
    $service='EdgeCoreMonitorTest-'+$QualificationId
    $suffix='-qualification-'+$QualificationId; $family+='.'+$QualificationId
    $product+=' qualification '+$QualificationId
}
if (-not (Test-Path -LiteralPath (Join-Path $bundle 'core/bin/edge-provision.exe') -PathType Leaf)) { throw 'The MSI requires a Core package containing the native developer converter.' }
New-Item -ItemType Directory -Path $out | Out-Null
function Id {
    param([string]$Value)
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Guid-For { param([string]$Value); $hex=Id $Value; return ([guid]::ParseExact($hex.Substring(0,32),'N')).ToString('D') }
function X { param([string]$Value); return [Security.SecurityElement]::Escape($Value) }
function Invoke-CMake {
    param([string[]]$Arguments)
    & $CMakePath -E env --unset=Path --unset=PATH "Path=$env:PATH" MSBUILDDISABLENODEREUSE=1 $CMakePath @Arguments
    if ($LASTEXITCODE -ne 0) { throw 'MSI custom action compilation failed.' }
}
$native=Join-Path $out 'native'
Invoke-CMake @('-S',(Join-Path $PSScriptRoot 'installer/msi'),'-B',$native,'-G','Visual Studio 17 2022','-A','x64',"-DEDGE_SERVICE_NAME=$service","-DEDGE_FOLDER_SUFFIX=$suffix","-DEDGE_VERSION=$($manifest.version)","-DEDGE_UNSIGNED=$([int][bool]$AllowUnsigned)","-DEDGE_CORE_SIGNER=$coreSigner","-DEDGE_BUNDLE_SIGNER=$bundleSigner")
Invoke-CMake @('--build',$native,'--config','Release','--parallel','2')
$dll=Join-Path $native 'Release/edge_msi_actions.dll'
$wizard=Join-Path $native 'Release/edge-provisioning-wizard.exe'
$wizardGuid=Guid-For ($family+'/'+$manifest.version+'/provisioning-wizard')
$upgrade=Guid-For $family
$componentRefs=New-Object Collections.Generic.List[string]
$directoryXml=New-Object Text.StringBuilder
function Write-Directory {
    param([string]$Directory,[string]$Relative)
    foreach ($file in Get-ChildItem -LiteralPath $Directory -File | Sort-Object Name) {
        $relativeFile=($Relative+'/'+$file.Name).TrimStart('/')
        $id='C_'+(Id ($manifest.version+'/'+$relativeFile)).Substring(0,24)
        $guid=Guid-For ($family+'/'+$manifest.version+'/'+$relativeFile)
        $componentRefs.Add($id)
        [void]$directoryXml.AppendLine('<Component Id="'+$id+'" Guid="'+$guid+'" Bitness="always64"><File Source="'+(X $file.FullName)+'" KeyPath="yes" /></Component>')
    }
    foreach ($childDirectory in Get-ChildItem -LiteralPath $Directory -Directory | Sort-Object Name) {
        $relativeChild=($Relative+'/'+$childDirectory.Name).TrimStart('/')
        [void]$directoryXml.AppendLine('<Directory Id="D_'+(Id $relativeChild).Substring(0,24)+'" Name="'+(X $childDirectory.Name)+'">')
        Write-Directory $childDirectory.FullName $relativeChild
        [void]$directoryXml.AppendLine('</Directory>')
    }
}
Write-Directory $bundle ''
$refs=($componentRefs | ForEach-Object {'<ComponentRef Id="'+$_+'" />'}) -join "`n"
$monitorGuid=Guid-For ($family+'/monitor-feature')
$name='izuma-edge-'+$manifest.version+'-windows-x64'+$suffix
$license=Get-Content -LiteralPath (Join-Path $bundle 'core/licenses/edge.txt') -Raw
$rtf='{\rtf1\ansi '+$license.Replace('\','\\').Replace('{','\{').Replace('}','\}').Replace("`r",'').Replace("`n",'\par ')+'}'
$licensePath=Join-Path $out 'license.rtf'
[IO.File]::WriteAllText($licensePath,$rtf,[Text.Encoding]::ASCII)
# Keep the supplied PNGs unchanged. Windows 10+ MSI bitmap controls support PNG.
# Separate dialog artwork uses the overridable WiX UI localization resource IDs.
Add-Type -AssemblyName System.Drawing
$brandingXml=@(); $brandingAssets=@()
foreach ($entry in @(@('banner.png',493,58,'WixUI_Bmp_Banner'),@('welcome.png',493,312,'WixUI_Bmp_Dialog'),@('finish.png',493,312,'EdgeFinishBmp'))) {
    $asset=(Resolve-Path -LiteralPath (Join-Path $BrandingDirectory $entry[0])).Path
    $file=Get-Item -LiteralPath $asset
    if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Branding must be regular PNG files.' }
    $image=[Drawing.Image]::FromFile($asset)
    try {
        if ($image.Width -ne $entry[1] -or $image.Height -ne $entry[2] -or $image.RawFormat.Guid -ne [Drawing.Imaging.ImageFormat]::Png.Guid) { throw "Invalid installer artwork: $($entry[0]); expected PNG $($entry[1]) x $($entry[2])." }
    } finally { $image.Dispose() }
    $brandingAssets+=@{name=$entry[0];path=$asset;binary=$entry[3];width=$entry[1];height=$entry[2];sha256=(Get-FileHash -LiteralPath $asset -Algorithm SHA256).Hash.ToLowerInvariant()}
}
$brandingXml+='<WixVariable Id="WixUIBannerBmp" Value="'+(X $brandingAssets[0].path)+'" />'
$brandingXml+='<WixVariable Id="WixUIDialogBmp" Value="'+(X $brandingAssets[1].path)+'" />'
$brandingXml+='<Binary Id="EdgeFinishBmp" SourceFile="'+(X $brandingAssets[2].path)+'" />'
$localization=Join-Path $out 'branding.wxl'
[IO.File]::WriteAllText($localization,'<WixLocalization Culture="en-US" xmlns="http://wixtoolset.org/schemas/v4/wxl"><String Id="ExitDialogBitmap" Value="EdgeFinishBmp" /></WixLocalization>',[Text.UTF8Encoding]::new($false))
$icon=Join-Path $BrandingDirectory 'installer.ico'
if (Test-Path -LiteralPath $icon) { $brandingXml+='<Icon Id="InstallerIcon" SourceFile="'+(X ([IO.Path]::GetFullPath($icon)))+'" /><Property Id="ARPPRODUCTICON" Value="InstallerIcon" />' }
$source=@"
<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs" xmlns:ui="http://wixtoolset.org/schemas/v4/wxs/ui">
  <Package Name="$(X $product)" Manufacturer="Izuma Networks" Version="$($manifest.version)" UpgradeCode="$upgrade" Scope="perMachine" InstallerVersion="500" Compressed="yes">
    <MajorUpgrade Schedule="afterInstallExecute" DowngradeErrorMessage="A newer Izuma Edge version is already installed." MigrateFeatures="yes" />
    <MediaTemplate EmbedCab="yes" />
    <Property Id="ARPNOMODIFY" Value="1" />
    <Property Id="REBOOT" Value="ReallySuppress" />
    <Property Id="PROVISIONING" Secure="yes" Hidden="yes" />
    <Property Id="PROVISIONINGMODE" Secure="yes" />
    <Property Id="INSTALLMONITOR" Secure="yes" />
    <Property Id="MONITORUSERCONTROL" Secure="yes" />
    <Property Id="MONITORSTARTUP" Secure="yes" />
    <Property Id="STARTSERVICE" Secure="yes" />
    <Property Id="EdgeApply" Hidden="yes" />
    <Property Id="EdgeRollback" Hidden="yes" />
    <Property Id="EdgeCommit" Hidden="yes" />
    <Property Id="EdgeUninstall" Hidden="yes" />
    <Property Id="EdgeUndoUninstall" Hidden="yes" />
    <Property Id="EdgeCommitUninstall" Hidden="yes" />
    <Launch Condition="Privileged" Message="Administrator privileges are required." />
    <Launch Condition="NOT DISABLEROLLBACK" Message="Windows Installer rollback must be enabled for Izuma Edge deployment." />
    <StandardDirectory Id="ProgramFiles64Folder">
      <Directory Id="IZUMADIR" Name="Izuma">
        <Directory Id="MSIHELPERSDIR" Name="EdgeMsiHelpers$suffix">
          <Directory Id="WIZARDDIR" Name="$($manifest.version)">
            <Component Id="ProvisioningWizard" Guid="$wizardGuid" Bitness="always64">
              <File Id="ProvisioningWizardExe" Source="$(X $wizard)" KeyPath="yes" />
            </Component>
          </Directory>
        </Directory>
        <Directory Id="MSICACHEDIR" Name="EdgeMsiPayload$suffix">
          <Directory Id="PAYLOADDIR" Name="$($manifest.version)">
            $directoryXml
            <Component Id="MonitorSelection" Guid="$monitorGuid" Bitness="always64">
              <RegistryValue Root="HKLM" Key="Software\Izuma\EdgeMsi\$family" Name="Monitor" Type="integer" Value="1" KeyPath="yes" />
            </Component>
          </Directory>
        </Directory>
      </Directory>
    </StandardDirectory>
    <Feature Id="Core" Title="Edge Core service and command-line control" Level="1" AllowAbsent="no">
      <ComponentRef Id="ProvisioningWizard" />
      $refs
      <Feature Id="Monitor" Title="Edge Core tray monitor" Description="Install the optional monitor and start it at user sign-in." Level="1">
        <ComponentRef Id="MonitorSelection" />
      </Feature>
    </Feature>
    <ui:WixUI Id="WixUI_FeatureTree" />
    <WixVariable Id="WixUILicenseRtf" Value="$(X $licensePath)" />
    $($brandingXml -join "`n")
    <Binary Id="EdgeActions" SourceFile="$(X $dll)" />
    <CustomAction Id="EdgePrepare" BinaryRef="EdgeActions" DllEntry="Prepare" Execute="immediate" Return="check" />
    <CustomAction Id="EdgeShowProvisioningWizard" BinaryRef="EdgeActions" DllEntry="ShowProvisioningWizard" Execute="immediate" Return="check" />
    <Property Id="WixUnelevatedShellExecTarget" Value="[ProgramFiles64Folder]Izuma\EdgeSetup$suffix\monitor\$($manifest.version)\edge-core-monitor.exe" />
    <CustomAction Id="EdgeLaunchMonitor" BinaryRef="Wix4UtilCA_X64" DllEntry="WixUnelevatedShellExec" Execute="immediate" Return="ignore" />
    <CustomAction Id="EdgeRollback" BinaryRef="EdgeActions" DllEntry="Rollback" Execute="rollback" Impersonate="no" Return="check" HideTarget="yes" />
    <CustomAction Id="EdgeApply" BinaryRef="EdgeActions" DllEntry="Apply" Execute="deferred" Impersonate="no" Return="check" HideTarget="yes" />
    <CustomAction Id="EdgeCommit" BinaryRef="EdgeActions" DllEntry="Commit" Execute="commit" Impersonate="no" Return="check" HideTarget="yes" />
    <CustomAction Id="EdgeUndoUninstall" BinaryRef="EdgeActions" DllEntry="UndoUninstall" Execute="rollback" Impersonate="no" Return="check" HideTarget="yes" />
    <CustomAction Id="EdgeUninstall" BinaryRef="EdgeActions" DllEntry="Uninstall" Execute="deferred" Impersonate="no" Return="check" HideTarget="yes" />
    <CustomAction Id="EdgeCommitUninstall" BinaryRef="EdgeActions" DllEntry="CommitUninstall" Execute="commit" Impersonate="no" Return="check" HideTarget="yes" />
    <InstallUISequence>
      <Custom Action="EdgeShowProvisioningWizard" After="ExecuteAction" Condition="UILevel &gt;= 5 AND NOT REMOVE=&quot;ALL&quot; AND NOT UPGRADINGPRODUCTCODE" />
      <Custom Action="EdgeLaunchMonitor" After="EdgeShowProvisioningWizard" Condition="UILevel &gt;= 5 AND NOT REMOVE=&quot;ALL&quot; AND NOT UPGRADINGPRODUCTCODE AND (INSTALLMONITOR=&quot;1&quot; OR (INSTALLMONITOR&lt;&gt;&quot;0&quot; AND (&amp;Monitor=3 OR (!Monitor=3 AND &amp;Monitor=-1))))" />
    </InstallUISequence>
    <InstallExecuteSequence>
      <Custom Action="EdgePrepare" After="CostFinalize" Condition="NOT UPGRADINGPRODUCTCODE" />
      <Custom Action="EdgeUndoUninstall" Before="EdgeUninstall" Condition="REMOVE=&quot;ALL&quot; AND NOT UPGRADINGPRODUCTCODE" />
      <Custom Action="EdgeUninstall" Before="RemoveFiles" Condition="REMOVE=&quot;ALL&quot; AND NOT UPGRADINGPRODUCTCODE" />
      <Custom Action="EdgeCommitUninstall" After="EdgeUninstall" Condition="REMOVE=&quot;ALL&quot; AND NOT UPGRADINGPRODUCTCODE" />
      <Custom Action="EdgeRollback" Before="EdgeApply" Condition="NOT REMOVE=&quot;ALL&quot;" />
      <Custom Action="EdgeApply" After="InstallFiles" Condition="NOT REMOVE=&quot;ALL&quot;" />
      <Custom Action="EdgeCommit" After="EdgeApply" Condition="NOT REMOVE=&quot;ALL&quot;" />
    </InstallExecuteSequence>
  </Package>
</Wix>
"@
$wxs=Join-Path $out 'izuma-edge.wxs'
[IO.File]::WriteAllText($wxs,$source,(New-Object Text.UTF8Encoding($false)))
$msi=Join-Path $out ($name+'.msi')
@{version=$manifest.version;msi=$msi;wixSource=$wxs;customAction=$dll;provisioningWizard=$wizard;serviceName=$service;upgradeCode=$upgrade;coreSignerThumbprint=$coreSigner;bundleSignerThumbprint=$bundleSigner;qualification=[bool]$AllowUnsigned;localization=$localization;branding=$brandingAssets} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $out 'msi-result.json') -Encoding UTF8
if (-not $PrepareOnly) {
    & $WixCommand build $wxs -arch x64 -ext WixToolset.UI.wixext -ext WixToolset.Util.wixext -loc $localization -out $msi
    if ($LASTEXITCODE -ne 0) { throw 'WiX MSI compilation failed.' }
    Write-Output "Built unsigned qualification MSI: $msi"
} else { Write-Output "Prepared $wxs. Sign $dll before WiX compilation; sign the MSI after compilation." }
