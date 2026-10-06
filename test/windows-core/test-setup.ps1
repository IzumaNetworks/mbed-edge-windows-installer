# SPDX-License-Identifier: Apache-2.0
# Actual setup lifecycle tests. Runtime removal is restricted to disposable CI.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$SetupResult,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [switch]$RemoveRuntime
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$setup=Get-Content -LiteralPath $SetupResult -Raw | ConvertFrom-Json
$out=[IO.Path]::GetFullPath($OutputDirectory)
$qualification=[bool]$setup.qualification
$suffix=''
if ($qualification) {
    if ($setup.serviceName -notmatch '^EdgeCoreMonitorTest-([0-9a-f-]{36})$') { throw 'Invalid qualification identity.' }
    $suffix='-qualification-'+[guid]::ParseExact($Matches[1],'D').ToString('D')
} elseif ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $setup.serviceName -cne 'EdgeCore') {
    throw 'Production setup tests run only on a disposable GitHub-hosted runner.'
}
if ($RemoveRuntime -and ($qualification -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted')) { throw 'Runtime removal is allowed only for production setup qualification on disposable GitHub-hosted CI.' }
$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if (-not $qualification) { throw 'CI qualification requires an elevated runner.' }
    $arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -SetupResult "'+([IO.Path]::GetFullPath($SetupResult))+'" -OutputDirectory "'+$out+'"'
    $child=Start-Process "$env:SystemRoot/System32/WindowsPowerShell/v1.0/powershell.exe" -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -Wait -PassThru
    if ($child.ExitCode -ne 0) { throw 'Elevated setup qualification failed; inspect results.json.' }
    Get-Content -LiteralPath (Join-Path $out 'results.json')
    exit 0
}
if (Test-Path -LiteralPath $out) { throw 'OutputDirectory must be new.' }
if (Get-Service $setup.serviceName -ErrorAction SilentlyContinue) { throw 'The qualification service must be absent before testing.' }
New-Item -ItemType Directory -Path $out | Out-Null
$app=Join-Path $env:ProgramFiles ('Izuma/EdgeSetup'+$suffix)
$data=Join-Path $env:ProgramData ('Izuma/EdgeCore'+$suffix)
$key='HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'
$result=[ordered]@{passed=$false;checks=@();error=$null;serviceName=$setup.serviceName;runtimeRemoved=$false}
function Check { param([bool]$Condition,[string]$Text); if (-not $Condition) { throw $Text }; $result.checks+=$Text; $Text | Add-Content -LiteralPath (Join-Path $out 'progress.log') }
function Run-Setup {
    param([string]$Case,[switch]$Uninstall)
    $action=if ($Uninstall) { '/uninstall ' } else { '' }
    $arguments=$action+'/quiet /norestart /log "'+(Join-Path $out ($Case+'.log'))+'"'
    if (-not $Uninstall) { $arguments+=' STARTSERVICE=0 INSTALLMONITOR=1' }
    $process=Start-Process -FilePath $setup.bundle -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -notin @(0,3010)) { throw "$Case failed ($($process.ExitCode)); inspect setup and MSI logs." }
}
$restoreRedist=$null
try {
    if ($RemoveRuntime) {
        $restoreRedist=Join-Path (Split-Path -Parent $setup.bundle) 'vc_redist.x64.exe'
        if (-not (Test-Path -LiteralPath $restoreRedist)) { throw 'CI must retain the original redistributable for runner cleanup.' }
        $runtimeProducts=@(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' | ForEach-Object { Get-ItemProperty $_.PSPath } | Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -match '^Microsoft Visual C\+\+ .* X64 (Minimum|Additional) Runtime - 14\.' })
        foreach ($product in $runtimeProducts) {
            if ($product.PSChildName -notmatch '^\{[0-9A-Fa-f-]{36}\}$') { throw 'Expected MSI product identity for CI runtime removal.' }
            $process=Start-Process "$env:SystemRoot/System32/msiexec.exe" -ArgumentList ('/x '+$product.PSChildName+' /qn /norestart') -WindowStyle Hidden -Wait -PassThru
            if ($process.ExitCode -notin @(0,3010,1605)) { throw 'Disposable CI runtime removal failed.' }
        }
        $before=Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        Check (-not $before -or -not $before.Installed) 'VC++ x64 runtime registration absent before the single setup launch'
        $result.runtimeRemoved=$true
    }
    $case=if ($RemoveRuntime) { 'runtime-absent' } else { 'runtime-present' }
    Run-Setup $case
    $runtime=Get-ItemProperty -LiteralPath $key
    Check ($runtime.Installed -eq 1 -and [version]$runtime.Version.TrimStart('v') -ge [version]$setup.requiredVisualCppVersion) 'A sufficient VC++ runtime is installed'
    $deployment=Get-Content -LiteralPath (Join-Path $app 'deployment.json') -Raw | ConvertFrom-Json
    Check ($deployment.version -ceq $setup.version -and $deployment.installMonitor -eq 1 -and (Test-Path -LiteralPath $deployment.ctlExecutable)) 'The one setup launch installs Core, monitor, and command-line control'
    Check ((Get-Service $setup.serviceName).Status -eq 'Stopped') 'Setup forwards STARTSERVICE=0 to the MSI'
    if ($RemoveRuntime) {
        $log=(Get-ChildItem -LiteralPath $out -Filter 'runtime-absent*.log' -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
        Check ($log -match 'Applying execute package: VisualCppX64, action: Install') 'Burn executes the embedded Microsoft runtime installer before the MSI'
    }
    $sentinel=Join-Path $data 'state/setup-qualification-sentinel.txt'
    'Retained-state setup qualification sentinel.' | Set-Content -LiteralPath $sentinel
    $sentinelHash=(Get-FileHash -LiteralPath $sentinel).Hash
    Run-Setup 'uninstall' -Uninstall
    Check (-not (Get-Service $setup.serviceName -ErrorAction SilentlyContinue)) 'Setup uninstall removes the owned Edge service'
    Check ((Get-FileHash -LiteralPath $sentinel).Hash -ceq $sentinelHash) 'Setup uninstall retains device state'
    Check ((Get-ItemProperty -LiteralPath $key).Installed -eq 1) 'Setup uninstall retains the shared Microsoft runtime'
    Run-Setup 'runtime-present-again'
    $log=(Get-ChildItem -LiteralPath $out -Filter 'runtime-present-again*.log' -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
    Check ($log -notmatch 'Applying execute package: VisualCppX64, action: Install' -and $log -match 'VisualCppX64, state: Present') 'A sufficient installed runtime is detected and skipped on reinstall'
    Run-Setup 'final-uninstall' -Uninstall
    Check (-not (Get-Service $setup.serviceName -ErrorAction SilentlyContinue)) 'Reinstall and final uninstall complete through the same setup executable'
    $result.passed=$true
} catch { $result.error=$_.Exception.Message }
finally {
    if (Get-Service $setup.serviceName -ErrorAction SilentlyContinue) { try { Run-Setup 'cleanup-uninstall' -Uninstall } catch { } }
    if ($restoreRedist) { Start-Process -FilePath $restoreRedist -ArgumentList '/install /quiet /norestart' -WindowStyle Hidden -Wait | Out-Null }
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $out 'results.json') -Encoding UTF8
}
if (-not $result.passed) { throw $result.error }
$result.checks
