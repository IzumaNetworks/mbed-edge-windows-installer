# SPDX-License-Identifier: Apache-2.0
# One command for the full GitHub build/sign/package/download chain.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [Parameter(Mandatory=$true)][string]$CoreRef,
    [Parameter(Mandatory=$true)][string]$InstallerRef,
    [Parameter(Mandatory=$true)][string]$MonitorRef,
    [switch]$BuildCoreInInstaller,
    [string]$OutputDirectory,
    [switch]$PlanOnly
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'package-tools.ps1')
$parsed=[version]$Version
if ($parsed.Major -gt 255 -or $parsed.Minor -gt 255 -or $parsed.Build -gt 65535) { throw 'MSI version must fit 255.255.65535.' }
foreach ($ref in @($CoreRef,$InstallerRef,$MonitorRef)) {
    if ([string]::IsNullOrWhiteSpace($ref) -or $ref -match '[\r\n]') { throw 'Supply a published source ref for each repository.' }
}
if (-not $OutputDirectory) { $OutputDirectory=Join-Path $PSScriptRoot ('../build/release-'+$Version) }
$out=Get-EdgeLocalDirectory ([IO.Path]::GetFullPath($OutputDirectory))
$requestId=[guid]::NewGuid().ToString('D')
$coreRepo='PelionIoT/mbed-edge'; $installerRepo='IzumaNetworks/mbed-edge-windows-installer'
$plan=[ordered]@{
    version=$Version; releaseId=$requestId; outputDirectory=$out
    core=@{repository=$coreRepo;workflow='windows-release.yml';ref=$CoreRef;inputs=@{version=$Version;release_id=$requestId}}
    installer=@{repository=$installerRepo;workflow='windows-msi.yml';ref=$InstallerRef;inputs=@{monitor_ref=$MonitorRef;release_id=$requestId}}
    artifact='izuma-edge-windows-x64-signed'
    buildsRunOn='GitHub Actions Windows runners'
    buildCoreInInstaller=[bool]$BuildCoreInInstaller
}
if ($BuildCoreInInstaller) {
    $plan.installer.inputs.core_ref=$CoreRef
    $plan.installer.inputs.version=$Version
}
if ($PlanOnly) { $plan | ConvertTo-Json -Depth 6; return }
$gh=(Get-Command gh -ErrorAction Stop).Source
if (Test-Path -LiteralPath $out) { throw 'OutputDirectory must be new; previous releases and run records are retained.' }

function Invoke-Gh {
    param([string[]]$Arguments,[string]$InputJson)
    if ($InputJson) {
        # A JSON file avoids Windows PowerShell's console-dependent stdin BOM.
        $inputPath=Join-Path $out ('gh-input-'+[guid]::NewGuid().ToString('N')+'.json')
        [IO.File]::WriteAllText($inputPath,$InputJson,[Text.UTF8Encoding]::new($false))
        $inputIndex=[Array]::IndexOf($Arguments,'--input')
        if ($inputIndex -lt 0 -or $Arguments[$inputIndex+1] -ne '-') { throw 'JSON dispatch requires --input -.' }
        $Arguments[$inputIndex+1]=$inputPath
    }
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$gh; $info.Arguments=ConvertTo-EdgeNativeArguments $Arguments
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $process=New-Object Diagnostics.Process; $process.StartInfo=$info
    try {
        [void]$process.Start()
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "GitHub command failed ($($process.ExitCode)): $($stderr.Result)" }
        return $stdout.Result
    } finally { $process.Dispose() }
}
function Start-ReleaseWorkflow {
    param($Definition,[string]$Title)
    $body=@{ref=$Definition.ref;inputs=$Definition.inputs} | ConvertTo-Json -Depth 5 -Compress
    [void](Invoke-Gh @('api','--method','POST',"repos/$($Definition.repository)/actions/workflows/$($Definition.workflow)/dispatches",'--input','-') $body)
    # A unique run title correlates this dispatch even when other releases start.
    for ($attempt=0; $attempt -lt 40; $attempt++) {
        $runs=(Invoke-Gh @('api',"repos/$($Definition.repository)/actions/workflows/$($Definition.workflow)/runs?event=workflow_dispatch&per_page=100")) | ConvertFrom-Json
        $match=@($runs.workflow_runs | Where-Object display_title -eq $Title)
        if ($match.Count -gt 1) { throw 'Duplicate release request ID; inspect GitHub runs.' }
        if ($match.Count -eq 1) { return $match[0] }
        Start-Sleep -Seconds 3
    }
    throw "Dispatch succeeded but its run is not visible yet. Find release ID $requestId in GitHub before retrying."
}
function Watch-ReleaseWorkflow {
    param([string]$Repository,$Run)
    Write-Host $Run.html_url
    & $gh run watch ([string]$Run.id) --repo $Repository --exit-status
    if ($LASTEXITCODE -ne 0) { throw "Workflow did not succeed: $($Run.html_url)" }
}
# Fail before dispatch when workflows have not been registered on default branches.
$workflows=if ($BuildCoreInInstaller) { @($plan.installer) } else { @($plan.core,$plan.installer) }
foreach ($definition in $workflows) {
    $workflow=(Invoke-Gh @('api',"repos/$($definition.repository)/actions/workflows/$($definition.workflow)")) | ConvertFrom-Json
    if ($workflow.state -ne 'active') { throw "Enable $($definition.workflow) in $($definition.repository)." }
}
New-Item -ItemType Directory -Path $out | Out-Null
$record=[ordered]@{request=$plan;coreRunId=$null;installerRunId=$null;complete=$false;error=$null}
$recordPath=Join-Path $out 'release-runs.json'
function Save-Record { $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $recordPath -Encoding UTF8 }
Save-Record
try {
    if (-not $BuildCoreInInstaller) {
        Write-Host 'Building, testing and signing Edge Core on GitHub...'
        $core=Start-ReleaseWorkflow $plan.core "Signed Windows core $Version ($requestId)"
        $record.coreRunId=$core.id; Save-Record
        Watch-ReleaseWorkflow $coreRepo $core
        $plan.installer.inputs.core_run_id=[string]$core.id
        Save-Record
    }
    Write-Host 'Building/testing the monitor and CLI, signing all contents, and creating/signing the self-contained MSI...'
    $msi=Start-ReleaseWorkflow $plan.installer "Signed Windows MSI ($requestId)"
    $record.installerRunId=$msi.id; Save-Record
    if ($BuildCoreInInstaller) { $record.coreRunId=$msi.id; Save-Record }
    Watch-ReleaseWorkflow $installerRepo $msi
    $artifacts=Join-Path $out 'artifacts'
    [void](Invoke-Gh @('run','download',[string]$msi.id,'--repo',$installerRepo,'--name',$plan.artifact,'--dir',$artifacts))
    foreach ($name in @('edge-core.exe','edge-core-monitor.exe','izuma-edge-ctl.exe','signatures.json','source.json','SHA256SUMS.txt')) {
        if (-not (Test-Path -LiteralPath (Join-Path $artifacts $name) -PathType Leaf)) { throw "Missing release artifact: $name" }
    }
    $msis=@(Get-ChildItem -LiteralPath $artifacts -Filter "izuma-edge-$Version-windows-x64.msi" -File)
    if ($msis.Count -ne 1) { throw 'Missing expected signed MSI.' }
    if (Test-Path -LiteralPath (Join-Path $artifacts "izuma-edge-$Version-windows-x64-setup.exe")) { throw 'MSI-only releases must not contain a setup EXE wrapper.' }
    $record.complete=$true; Save-Record
    Write-Host "Signed release downloaded to $artifacts"
} catch {
    $record.error=$_.Exception.Message; Save-Record
    throw
}
