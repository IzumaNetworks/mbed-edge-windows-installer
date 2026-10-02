# SPDX-License-Identifier: Apache-2.0
# Offline/credential-free setup qualification, with a compiled-in GUID service.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$InitialResult,
    [Parameter(Mandatory=$true)][string]$UpgradeResult,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [string]$RecoverMonitorResults
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../../windows/package-tools.ps1')
. (Join-Path $PSScriptRoot '../../windows/service-tools.ps1')
$first=Get-Content -LiteralPath $InitialResult -Raw | ConvertFrom-Json
$next=Get-Content -LiteralPath $UpgradeResult -Raw | ConvertFrom-Json
if ($first.serviceName -notmatch '^EdgeCoreMonitorTest-([0-9a-f-]{36})$' -or $first.serviceName -ne $next.serviceName -or $first.appId -ne $next.appId) { throw 'Only matching GUID qualification installers may be tested.' }
$id=$Matches[1]; [void][guid]::ParseExact($id,'D')
$out=Get-EdgeLocalDirectory ([IO.Path]::GetFullPath($OutputDirectory))
$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-InitialResult',$InitialResult,'-UpgradeResult',$UpgradeResult,'-OutputDirectory',$out)
    if ($RecoverMonitorResults) { $args+=@('-RecoverMonitorResults',$RecoverMonitorResults) }
    $child=Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList (ConvertTo-EdgeNativeArguments $args) -Verb RunAs -WindowStyle Hidden -PassThru
    $child.WaitForExit()
    if ($child.ExitCode -ne 0) { throw "Elevated installer qualification failed ($($child.ExitCode)); see results.json if created." }
    Get-Content -LiteralPath (Join-Path $out 'results.json')
    exit 0
}
if (Test-Path -LiteralPath $out) { throw 'OutputDirectory must be new.' }
New-Item -ItemType Directory -Path $out | Out-Null
$name=$first.serviceName
$app=Join-Path $env:ProgramFiles ('Izuma\EdgeSetup-qualification-'+$id)
$data=Join-Path $env:ProgramData ('Izuma\EdgeCore-qualification-'+$id)
$install=Join-Path $env:ProgramFiles ('Izuma\EdgeCore-qualification-'+$id)
$marker=Join-Path $app 'deployment.json'
$uninstaller=Join-Path $app 'unins000.exe'
$policy='HKLM:\SOFTWARE\Izuma\EdgeCoreMonitor\Services\'+$name
$run='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$runName='IzumaEdgeCoreMonitor-'+$name
$result=[ordered]@{passed=$false; serviceName=$name; checks=@(); error=$null; cleanupVerified=$false; retainedData=$data}
function Check { param([bool]$Condition,[string]$Text); if (-not $Condition) { throw $Text }; $result.checks+=$Text; $Text | Add-Content -LiteralPath (Join-Path $out 'progress.log') }
function Setup { param([string]$Executable,[string[]]$Extra,[string]$Case,[switch]$Fail)
    $args=@('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',('/LOG='+$out+'\'+$Case+'.log'))+$Extra
    $process=Start-Process -FilePath $Executable -ArgumentList (ConvertTo-EdgeNativeArguments $args) -WindowStyle Hidden -Wait -PassThru
    $helperLog=Join-Path $app 'deployment.log'
    if (Test-Path -LiteralPath $helperLog) { Copy-Item -LiteralPath $helperLog -Destination (Join-Path $out ($Case+'-deployment.log')) -Force }
    if ($Fail) { Check ($process.ExitCode -notin @(0,3010)) "$Case rejected with a non-success exit code" }
    elseif ($process.ExitCode -notin @(0,3010)) { throw "$Case failed: $($process.ExitCode). See setup/deployment logs." }
}
function Uninstall {
    if (Test-Path -LiteralPath $uninstaller) { Setup $uninstaller @() 'uninstall' }
}
try {
    if ($RecoverMonitorResults) {
        $monitorRepo=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent ([IO.Path]::GetFullPath($RecoverMonitorResults))))
        & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File (Join-Path $monitorRepo 'windows/tests/test-service-control.ps1') -BinaryDirectory (Join-Path $monitorRepo 'build/windows/Debug') -OutputDirectory (Join-Path $out 'monitor-recovery') -RecoverResults $RecoverMonitorResults
        Check ($LASTEXITCODE -eq 0) 'Previously stopped monitor fixture removed after verifying its native SCM identity'
    }
    Check (-not (Get-Service $name -ErrorAction SilentlyContinue)) 'Test service absent before qualification'
    Setup $first.setup @('/INSTALLMONITOR=0','/STARTSERVICE=0') 'service-only'
    $deployment=Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
    Check ($deployment.installMonitor -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $app 'monitor'))) 'Silent service-only install omits the monitor executable'
    $service=Get-EdgeServiceInfo $name
    $result.factoryExitCode=$service.ExitCode
    Check ($service.StartName -eq 'NT AUTHORITY\LocalService' -and $service.State -eq 'Stopped') 'Factory installation creates native LocalService service without requiring credentials or network'
    Check ((Invoke-EdgeServiceControl @('qsidtype',$name)) -match 'RESTRICTED') 'Service SID remains restricted'
    Check ((Get-ItemProperty -LiteralPath $policy).AllowStandardUserControl -eq 0) 'Service-only installation grants standard users no Start/Stop access'
    'Retained identity sentinel (no real credentials)' | Set-Content -LiteralPath (Join-Path $data 'state/qualification-sentinel.txt')
    $oldCommand=(Get-EdgeServiceInfo $name).PathName
    $corruptDirectory=Join-Path $app ('monitor/'+$next.version)
    # Force a monitor staging error after service activation, exercising the
    # combined transaction rather than just a preflight validation failure.
    New-Item -ItemType Directory -Path $corruptDirectory -Force | Out-Null
    $corruptFile=Join-Path $corruptDirectory 'edge-core-monitor.exe'
    'Credential-free failure injection' | Set-Content -LiteralPath $corruptFile
    Setup $next.setup @('/INSTALLMONITOR=1','/STARTSERVICE=0') 'combined-rollback' -Fail
    $update=Get-Content -LiteralPath (Join-Path $data 'service-update.json') -Raw | ConvertFrom-Json
    $activationLog=Get-Content -LiteralPath (Join-Path $out 'combined-rollback-deployment.log') -Raw
    Check ($update.version -eq $next.version -and $update.stage -eq 'RolledBack' -and $activationLog -match [regex]::Escape("Upgraded $name to $($next.version).")) 'Failure injection reached core activation and completed its rollback journal'
    Check ((Get-EdgeServiceInfo $name).PathName -eq $oldCommand -and (Get-Content -LiteralPath (Join-Path $data 'service-release.json') -Raw | ConvertFrom-Json).version -eq $first.version) 'Monitor staging failure rolls back the activated core path and version'
    Check ((Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json).installMonitor -eq 0 -and (Get-ItemProperty -LiteralPath $policy).AllowStandardUserControl -eq 0) 'Combined rollback restores component selection and service-control policy'
    $corruptDirectory=Get-EdgeLocalDirectory $corruptDirectory
    if (-not $corruptDirectory.StartsWith($app+'\monitor\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Failure fixture is outside the monitor release directory.' }
    Remove-Item -LiteralPath $corruptFile
    Remove-Item -LiteralPath $corruptDirectory
    Setup $next.setup @('/STARTSERVICE=0') 'upgrade-service-only'
    $deployment=Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
    Check ($deployment.version -eq $next.version -and $deployment.installMonitor -eq 0) 'Upgrade preserves service-only component selection'
    Check (Test-Path -LiteralPath (Join-Path $data 'state/qualification-sentinel.txt')) 'Upgrade retains private service state'
    Uninstall
    Check (-not (Get-Service $name -ErrorAction SilentlyContinue)) 'Uninstaller removes the owned service'
    Check (Test-Path -LiteralPath (Join-Path $data 'state/qualification-sentinel.txt')) 'Uninstaller retains private service state'
    # Use the newer version after removing its ARP entry: defaults must include monitor.
    Setup $next.setup @('/STARTSERVICE=0') 'default-monitor'
    $deployment=Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
    Check ($deployment.installMonitor -eq 1 -and (Test-Path -LiteralPath $deployment.monitorExecutable)) 'Fresh setup selects and installs the optional monitor by default'
    Check ($deployment.monitorStartup -eq 1 -and (Get-ItemProperty -LiteralPath $run).$runName -eq ('"'+$deployment.monitorExecutable+'" --port 8080')) 'Default monitor starts in user sessions through HKLM Run'
    Check ((Get-ItemProperty -LiteralPath $policy).AllowStandardUserControl -eq 0) 'Default monitor policy permits only administrators to control the service'
    $acl=Get-Acl -LiteralPath (Split-Path -Parent $deployment.monitorExecutable)
    $users=@($acl.Access | Where-Object {$_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-11'})
    $allowed=[Security.AccessControl.FileSystemRights]::ReadAndExecute -bor [Security.AccessControl.FileSystemRights]::Synchronize
    Check ($acl.AreAccessRulesProtected -and $users.Count -eq 1 -and [int]$users[0].FileSystemRights -eq [int]$allowed) 'Monitor helper directory denies standard-user binary replacement'
    Setup $next.setup @('/MONITORUSERCONTROL=1','/MONITORSTARTUP=0','/STARTSERVICE=0') 'user-control'
    Check ((Get-ItemProperty -LiteralPath $policy).AllowStandardUserControl -eq 1 -and (Invoke-EdgeServiceControl @('sdshow',$name)) -match '\(A;;RPWP;;;IU\)') 'Explicit user-control choice updates both protected policy and SCM Start/Stop rights'
    Check ($null -eq (Get-ItemProperty -LiteralPath $run -Name $runName -ErrorAction SilentlyContinue)) 'Sign-in startup can be disabled independently of installing monitor'
    Setup $next.setup @('/STARTSERVICE=0') 'preserve-options'
    $deployment=Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
    Check ($deployment.monitorUserControl -eq 1 -and $deployment.monitorStartup -eq 0) 'Maintenance preserves monitor policy and sign-in choices'
    Setup $first.setup @('/STARTSERVICE=0') 'downgrade' -Fail
    Check ((Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json).version -eq $next.version) 'Downgrade rejection preserves active service and deployment version'
    Setup $next.setup @('/INSTALLMONITOR=0','/STARTSERVICE=0') 'remove-monitor'
    $deployment=Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
    Check ($deployment.installMonitor -eq 0 -and (Get-ItemProperty -LiteralPath $policy).AllowStandardUserControl -eq 0) 'Deselecting monitor removes integration and revokes standard-user service control'
    $result.passed=$true
} catch { $result.error=$_.Exception.Message; $_ | Out-String | Set-Content -LiteralPath (Join-Path $out 'failure.log') }
finally {
    try {
        Uninstall
        Check (-not (Get-Service $name -ErrorAction SilentlyContinue)) 'Temporary service removed after qualification'
        Check (-not (Test-Path -LiteralPath $policy)) 'Temporary monitor policy removed after qualification'
        $result.cleanupVerified=$true
    } catch { $result.passed=$false; $result.error+=' Cleanup: '+$_.Exception.Message }
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $out 'results.json') -Encoding UTF8
}
if (-not $result.passed) { throw $result.error }
