# SPDX-License-Identifier: Apache-2.0
# Real isolated Windows service/monitor status qualification; MSI/setup tests are separate.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$RunDirectory,
    [Parameter(Mandatory=$true)][string]$ProvisioningFile,
    [string]$LegacyPackageDirectory,
    [string]$ResumeEvidenceDirectory,
    [string]$RetainedStateDirectory,
    [ValidatePattern('^e2e(-attempt-[0-9]+)?$')][string]$AttemptName='e2e'
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../../windows/package-tools.ps1')
$run=Get-EdgeLocalDirectory ([IO.Path]::GetFullPath($RunDirectory))
$context=Get-Content -LiteralPath (Join-Path $run 'context.json') -Raw | ConvertFrom-Json
$name=$context.serviceName
if ($name -notmatch '^EdgeCoreMonitorTest-([0-9a-f-]{36})$') { throw 'A GUID qualification service is required.' }
[void][guid]::ParseExact($Matches[1],'D')
$out=Join-Path $run $AttemptName
$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-RunDirectory',$run,'-ProvisioningFile',[IO.Path]::GetFullPath($ProvisioningFile))
    if ($LegacyPackageDirectory) { $args+=@('-LegacyPackageDirectory',[IO.Path]::GetFullPath($LegacyPackageDirectory)) }
    if ($ResumeEvidenceDirectory) { $args+=@('-ResumeEvidenceDirectory',[IO.Path]::GetFullPath($ResumeEvidenceDirectory)) }
    if ($RetainedStateDirectory) { $args+=@('-RetainedStateDirectory',[IO.Path]::GetFullPath($RetainedStateDirectory)) }
    $args+=@('-AttemptName',$AttemptName)
    $child=Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList (ConvertTo-EdgeNativeArguments $args) -Verb RunAs -WindowStyle Hidden -PassThru
    $child.WaitForExit()
    if (Test-Path -LiteralPath (Join-Path $out 'results.json')) { Get-Content -LiteralPath (Join-Path $out 'results.json') }
    if ($child.ExitCode -ne 0) { throw 'Windows status E2E failed; see the retained results and logs.' }
    exit 0
}
if (Test-Path -LiteralPath $out) { throw 'E2E output directory must be new.' }
New-Item -ItemType Directory -Path $out | Out-Null
# Cloud fixtures and state must remain private throughout qualification.
$acl=New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true,$false)
foreach ($sid in @('S-1-5-18','S-1-5-32-544',[Security.Principal.WindowsIdentity]::GetCurrent().User.Value)) {
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(([Security.Principal.SecurityIdentifier]$sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
}
Set-Acl -LiteralPath $out -AclObject $acl
$initial=Join-Path $run ('initial-package/edge-core-'+$context.initialVersion+'-windows-x64')
$upgrade=Join-Path $run ('upgrade-package/edge-core-'+$context.upgradeVersion+'-windows-x64')
$monitor=Join-Path $run 'initial-setup/bundle/monitor/edge-core-monitor.exe'
$probe=Join-Path $run 'monitor-build/windows/Release/monitor-status-e2e.exe'
$fixture=Join-Path $run 'monitor-build/windows/Release/monitor-service-fixture.exe'
$failureExe=Join-Path $run '../windows-x64/bin/Release/windows-update-failure.exe'
$primary=Get-EdgeServiceInfo EdgeCore
$result=[ordered]@{passed=$false; serviceName=$name; checks=@();
    primaryServiceUnchanged=$false; cleanupVerified=$false; error=$null; evidenceDirectory=$out}
$data=Join-Path $out 'pipe-data'; $install=Join-Path $out 'pipe-installation'
$tcpData=Join-Path $out 'tcp-data'; $tcpInstall=Join-Path $out 'tcp-installation'
$monitorProcess=$null; $spoofHttp=$false; $spoofPipe=$false; $fixtureCommand=$null
$shortcut=Join-Path ([Environment]::GetFolderPath('Programs')) 'Edge Core Monitor.lnk'
$shortcutBackup=Join-Path $out 'original-monitor-shortcut.lnk'
$shortcutExisted=Test-Path -LiteralPath $shortcut
if ($shortcutExisted) { Copy-Item -LiteralPath $shortcut -Destination $shortcutBackup }
function Record([string]$Text) {
    $result.checks+=$Text
    ('{0:o} {1}' -f [DateTime]::UtcNow,$Text) | Add-Content -LiteralPath (Join-Path $out 'progress.log')
    Write-Output $Text
}
function Check([bool]$Condition,[string]$Text) { if (-not $Condition) { throw $Text }; Record $Text }
function Free-Port {
    $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
    $listener.Start(); $port=$listener.LocalEndpoint.Port; $listener.Stop(); return $port
}
function Wait-Service([string]$State) {
    $deadline=[DateTime]::UtcNow.AddSeconds(35)
    do { $info=Get-EdgeServiceInfo $name; if ($info -and $info.State -eq $State) { return $info }; Start-Sleep -Milliseconds 200 } while ([DateTime]::UtcNow -lt $deadline)
    throw "Test service did not reach $State."
}
function Wait-Cloud([string]$Identity) {
    $deadline=[DateTime]::UtcNow.AddSeconds(150); $lastError=''
    do {
        if ((Get-EdgeServiceInfo $name).State -ne 'Running') { throw 'Test Edge service exited.' }
        try {
            $status=Read-EdgeStatus $name
            if ($status.status -eq 'connected') {
                if ($Identity -and $status.'internal-id' -ne $Identity) { throw 'Persisted cloud identity changed.' }
                return $status
            }
        } catch { if ($_.Exception.Message -eq 'Persisted cloud identity changed.') { throw }; $lastError=$_.Exception.Message }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "No connected status over the pipe within 150 seconds. $lastError"
}
function Wait-LegacyCloud([string]$Identity) {
    $deadline=[DateTime]::UtcNow.AddSeconds(150)
    do {
        try { $status=Read-LegacyEdgeHttpStatus $name $http; if ($status.status -eq 'connected' -and $status.'internal-id' -eq $Identity) { return } } catch { }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Legacy release did not reconnect the retained identity over its verified HTTP listener.'
}
function Probe([string[]]$Arguments,[string]$Case) {
    & $probe @Arguments *> (Join-Path $out ($Case+'.log'))
    if ($LASTEXITCODE -ne 0) { throw "Native monitor probe failed: $Case. See its log." }
}
function Wait-Ui([string]$State,[string]$Case) {
    $deadline=[DateTime]::UtcNow.AddSeconds(20)
    do {
        if ($monitorProcess.HasExited) { throw 'The native monitor exited.' }
        # Windows PowerShell turns native stderr into terminating errors under
        # Stop. A window/status that is still starting must remain retryable.
        $savedPreference=$ErrorActionPreference
        try {
            $ErrorActionPreference='Continue'
            & $probe --ui $monitorProcess.Id $State *> (Join-Path $out ($Case+'.log'))
            $probeExit=$LASTEXITCODE
        } finally { $ErrorActionPreference=$savedPreference }
        if ($probeExit -eq 0) { return }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Native monitor UI did not reach $State. See $Case.log."
}
function Remove-TestService {
    $info=Get-EdgeServiceInfo $name
    if (-not $info) { return }
    if ($info.PathName -eq $fixtureCommand) {
        if ($info.State -ne 'Stopped') { Stop-Service $name; [void](Wait-Service 'Stopped') }
        [void](Invoke-EdgeServiceControl @('delete',$name))
    } else {
        if (-not $info.PathName.Contains($out+'\') -or $info.PathName -notmatch ('--service-name\s+'+[regex]::Escape($name)+'(\s|$)')) { throw 'Refusing cleanup of an unrelated service.' }
        & (Join-Path $initial 'scripts/install-service.ps1') -Action Uninstall -ServiceName $name
    }
    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    do { if (-not (Get-EdgeServiceInfo $name)) { return }; Start-Sleep -Milliseconds 200 } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Test service remained registered.'
}
if (-not ('StatusSpoofFixtures' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.IO.Pipes;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
public static class StatusSpoofFixtures {
    static TcpListener http;
    static Thread httpThread, pipeThread;
    static NamedPipeServerStream pipe;
    static volatile bool stopHttp, stopPipe;
    static int requests;
    public static int Requests { get { return requests; } }
    public static void StartHttp(int port) {
        stopHttp=false; requests=0;
        http=new TcpListener(IPAddress.Loopback,port); http.Start();
        httpThread=new Thread(() => {
            while (!stopHttp) {
                try {
                    using (var client=http.AcceptTcpClient()) {
                        var stream=client.GetStream(); stream.ReadTimeout=2000;
                        byte[] request=new byte[4096]; stream.Read(request,0,request.Length);
                        Interlocked.Increment(ref requests);
                        string body="{\"status\":\"connected\",\"internal-id\":\"ffffffffffffffffffffffffffffffff\"}";
                        byte[] reply=Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "+body.Length+"\r\nConnection: close\r\n\r\n"+body);
                        stream.Write(reply,0,reply.Length);
                    }
                } catch { if (stopHttp) break; }
            }
        }); httpThread.IsBackground=true; httpThread.Start();
    }
    public static void StopHttp() { stopHttp=true; if(http!=null)http.Stop(); if(httpThread!=null)httpThread.Join(3000); }
    public static void StartPipe(uint claimedPid) {
        stopPipe=false;
        pipe=new NamedPipeServerStream("IzumaEdgeCoreStatus",PipeDirection.InOut,1,PipeTransmissionMode.Byte,PipeOptions.Asynchronous);
        pipeThread=new Thread(() => {
            while (!stopPipe) {
                try {
                    pipe.WaitForConnection();
                    byte[] body=Encoding.UTF8.GetBytes("{\"status\":\"connected\",\"internal-id\":\"ffffffffffffffffffffffffffffffff\",\"connectivity\":{\"processId\":"+claimedPid+"}}");
                    byte[] header={0,0,(byte)(body.Length>>8),(byte)body.Length};
                    pipe.Write(header,0,header.Length); pipe.Write(body,0,body.Length); pipe.ReadByte();
                } catch { if(stopPipe)break; }
                try { pipe.Disconnect(); } catch { }
            }
        }); pipeThread.IsBackground=true; pipeThread.Start();
    }
    public static void StopPipe() { stopPipe=true; if(pipe!=null)pipe.Dispose(); if(pipeThread!=null)pipeThread.Join(3000); }
}
'@
}
$http=Free-Port; do { $pt=Free-Port } while ($pt -eq $http)
try {
    Check (-not (Get-EdgeServiceInfo $name)) 'Qualification service absent initially'
    & (Join-Path $PSScriptRoot 'test-status-client.ps1') -PackageToolsPath (Join-Path $initial 'scripts/package-tools.ps1')
    Record 'Packaged legacy status client passes strict-mode compatibility and process identity guards'
    & (Join-Path $PSScriptRoot 'test-package.ps1') -PackageDirectory $initial -OutputDirectory (Join-Path $out 'package-integrity')
    & (Join-Path $PSScriptRoot 'test-installer-bundle.ps1') -BundleDirectory (Join-Path $run 'initial-setup/bundle') -OutputDirectory (Join-Path $out 'bundle-integrity')
    Record 'Packaged core/scripts and combined installer bundle integrity tests passed'
    if ($ResumeEvidenceDirectory) {
        $previous=Get-EdgeLocalDirectory ([IO.Path]::GetFullPath($ResumeEvidenceDirectory))
        $previousResult=Get-Content -LiteralPath (Join-Path $previous 'results.json') -Raw | ConvertFrom-Json
        if ($previousResult.serviceName -ne $name -or -not $previousResult.cleanupVerified -or -not $previousResult.primaryServiceUnchanged) {
            throw 'Resume requires cleaned-up evidence for this exact qualification service.'
        }
        # Reuse only the stopped qualification identity to avoid creating a
        # second cloud device while retrying the live monitor checks.
        New-Item -ItemType Directory -Path $data | Out-Null
        Copy-Item -LiteralPath (Join-Path $previous 'pipe-data/state') -Destination $data -Recurse
        $provisioningArguments=@{}
    } else {
        $provisioningArguments=@{ProvisioningFile=$ProvisioningFile}
        if ($RetainedStateDirectory) {
            $retained=Get-EdgeLocalDirectory ([IO.Path]::GetFullPath($RetainedStateDirectory))
            if (-not (Test-Path -LiteralPath (Join-Path $retained 'mcc_config'))) { throw 'Retained test state has no persisted identity.' }
            New-Item -ItemType Directory -Path $data | Out-Null
            Copy-Item -LiteralPath $retained -Destination (Join-Path $data 'state') -Recurse
            $provisioningArguments=@{}
        }
    }
    & (Join-Path $initial 'scripts/install-package.ps1') -PackageDirectory $initial -ServiceName $name -InstallRoot $install -DataDirectory $data @provisioningArguments -HttpPort $http -ProtocolPort $pt -AllowUnsigned -Start
    $info=Get-EdgeServiceInfo $name
    Wait-EdgeServiceReady $name $info.PathName $http
    $status=Wait-Cloud ''; $identity=$status.'internal-id'
    Check ($info.StartName -eq 'NT AUTHORITY\LocalService' -and (Invoke-EdgeServiceControl @('qsidtype',$name)) -match 'RESTRICTED') 'Actual rebuilt Edge runs under restricted LocalService and connects to the cloud'
    Check ($status.connectivity.processId -eq $info.ProcessId -and $status.connectivity.listeners.statusPipe.listening -and
        -not $status.connectivity.listeners.http.enabled -and -not $status.connectivity.listeners.http.listening) 'Pipe status matches SCM PID and reports TCP status disabled by default'
    Check (-not @([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object Port -eq $http).Count) 'The default Windows service opens no TCP status listener'
    Probe @('--live-pipe','disabled') 'ordinary-user-pipe-default'
    Record 'Ordinary interactive user reads the genuine service pipe and monitor Details reports disabled TCP status'
    [StatusSpoofFixtures]::StartHttp($http); $spoofHttp=$true
    $fake=Invoke-RestMethod -Uri "http://127.0.0.1:$http/status" -TimeoutSec 3
    Check ($fake.'internal-id' -eq 'ffffffffffffffffffffffffffffffff') 'Spoof HTTP fixture is reachable on the configured TCP status port'
    $monitorArgs=@('--tray','--no-notifications','--port',"$http",'--config',(Join-Path $out 'monitor.ini'),'--diagnostics',(Join-Path $out 'monitor.log'))
    $monitorProcess=Start-Process -FilePath $monitor -ArgumentList (ConvertTo-EdgeNativeArguments $monitorArgs) -WindowStyle Hidden -PassThru
    Wait-Ui 'disabled' 'gui-default'
    Start-Sleep -Seconds 4
    Check ([StatusSpoofFixtures]::Requests -eq 1) 'Native monitor polls the service pipe and ignores reachable spoof HTTP status'
    Stop-Service $name; [void](Wait-Service 'Stopped'); Wait-Ui 'stopped' 'gui-service-stopped'
    Check ([StatusSpoofFixtures]::Requests -eq 1) 'Stopped service is shown unavailable despite spoof HTTP claiming connected'
    Start-Service $name; [void](Wait-Cloud $identity); Wait-Ui 'disabled' 'gui-service-recovered'
    Record 'Native monitor recovers genuine connected status after the service restarts'
    [StatusSpoofFixtures]::StopHttp(); $spoofHttp=$false
    $upgradeRelease=Join-Path $install ('releases/'+$context.upgradeVersion)
    & (Join-Path $upgrade 'scripts/update-service.ps1') -ServiceName $name -PackageDirectory $upgrade -ReleaseDirectory $upgradeRelease -AllowUnsigned -RequireCloud
    [void](Wait-Cloud $identity); Wait-Ui 'disabled' 'gui-upgraded'
    $current=Get-EdgeServiceInfo $name; $currentCommand=$current.PathName
    Check ($current.PathName.StartsWith('"'+(Join-Path $upgradeRelease 'edge-core.exe')+'"')) 'Package upgrade passes pipe readiness with TCP off and retains cloud identity'
    $failurePackage=Join-Path $out 'failure-package'
    Copy-Item -LiteralPath $upgrade -Destination $failurePackage -Recurse
    Copy-Item -LiteralPath $failureExe -Destination (Join-Path $failurePackage 'bin/edge-core.exe') -Force
    $manifestPath=Join-Path $failurePackage 'package.json'; $manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $upgradeVersion=[version]$context.upgradeVersion
    $manifest.version='{0}.{1}.{2}' -f $upgradeVersion.Major,$upgradeVersion.Minor,($upgradeVersion.Build+1)
    $entry=$manifest.files | Where-Object path -eq 'bin/edge-core.exe'
    $entry.bytes=(Get-Item -LiteralPath $failureExe).Length; $entry.sha256=(Get-FileHash -LiteralPath $failureExe -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($manifestPath,($manifest | ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false)))
    Remove-Item -LiteralPath (Join-Path $failurePackage 'package.cat')
    New-FileCatalog -Path $failurePackage -CatalogFilePath (Join-Path $failurePackage 'package.cat') -CatalogVersion 2 | Out-Null
    $rolledBack=$false
    try { & (Join-Path $upgrade 'scripts/update-service.ps1') -ServiceName $name -PackageDirectory $failurePackage -ReleaseDirectory (Join-Path $install 'releases/failed-candidate') -AllowUnsigned -RequireCloud }
    catch { $rolledBack=$_.Exception.Message -like 'Upgrade failed and previous binary path was restored*' }
    $journal=Get-Content -LiteralPath (Join-Path $data 'service-update.json') -Raw | ConvertFrom-Json
    Check ($rolledBack -and $journal.stage -eq 'RolledBack' -and (Get-EdgeServiceInfo $name).PathName -eq $currentCommand) 'Actual candidate startup failure rolls back the binary path and completes pipe readiness'
    [void](Wait-Cloud $identity); Wait-Ui 'disabled' 'gui-rolled-back'
    Record 'Rollback reconnects the same cloud identity and the native monitor recovers'
    $uninstallTimer=[Diagnostics.Stopwatch]::StartNew()
    Remove-TestService
    Check ($uninstallTimer.Elapsed.TotalSeconds -lt 20) 'Uninstall after rollback completes despite pending SCM failure recovery'
    Check (Test-Path -LiteralPath (Join-Path $data 'state/mcc_config')) 'Uninstall retains test identity state'
    New-Item -ItemType Directory -Path $tcpData | Out-Null
    Copy-Item -LiteralPath (Join-Path $data 'state') -Destination $tcpData -Recurse
    & (Join-Path $initial 'scripts/install-package.ps1') -PackageDirectory $initial -ServiceName $name -InstallRoot $tcpInstall -DataDirectory $tcpData -EnableTcpStatus -HttpPort $http -ProtocolPort $pt -AllowUnsigned -Start
    $status=Wait-Cloud $identity; $info=Get-EdgeServiceInfo $name
    $tcp=Invoke-RestMethod -Uri "http://127.0.0.1:$http/status" -TimeoutSec 3
    Check ($status.connectivity.listeners.http.enabled -and $status.connectivity.listeners.http.listening -and
        $status.connectivity.listeners.http.address -eq "127.0.0.1:$http" -and $tcp.connectivity.processId -eq $info.ProcessId -and $tcp.'internal-id' -eq $identity) 'Explicit installer TCP opt-in opens the genuine loopback status endpoint with the retained identity'
    Probe @('--live-pipe','enabled') 'ordinary-user-pipe-tcp-enabled'; Wait-Ui 'enabled' 'gui-tcp-enabled'
    Record 'Monitor continues using the pipe and enables its TCP status button when TCP is listening'
    $runtimePath=Join-Path $tcpData 'config/status-runtime.json'
    $runtime=Get-Content -LiteralPath $runtimePath -Raw | ConvertFrom-Json; $runtime.status.tcpEnabled=$false
    $runtime | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $runtimePath -Encoding UTF8
    Stop-Service $name; [void](Wait-Service 'Stopped'); Start-Service $name; [void](Wait-Cloud $identity)
    Probe @('--live-pipe','disabled') 'ordinary-user-pipe-tcp-disabled'; Wait-Ui 'disabled' 'gui-tcp-disabled'
    Check (-not @([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object Port -eq $http).Count) 'Turning TCP status off closes its listener and the native monitor remains connected'
    Remove-TestService
    if ($LegacyPackageDirectory) {
        $legacyInstall=Join-Path $out 'legacy-installation'
        & (Join-Path $LegacyPackageDirectory 'scripts/install-package.ps1') -PackageDirectory $LegacyPackageDirectory -ServiceName $name -InstallRoot $legacyInstall -DataDirectory $tcpData -HttpPort $http -ProtocolPort $pt -AllowUnsigned -Start
        Wait-LegacyCloud $identity
        $legacyCommand=(Get-EdgeServiceInfo $name).PathName
        $legacyRollback=$false
        try { & (Join-Path $upgrade 'scripts/update-service.ps1') -ServiceName $name -PackageDirectory $failurePackage -ReleaseDirectory (Join-Path $legacyInstall 'releases/failed-candidate') -AllowUnsigned -RequireCloud }
        catch {
            $_ | Out-String | Set-Content -LiteralPath (Join-Path $out 'legacy-rollback-error.log')
            $legacyRollback=$_.Exception.Message -like 'Upgrade failed and previous binary path was restored*'
        }
        Check ($legacyRollback -and (Get-EdgeServiceInfo $name).PathName -eq $legacyCommand) 'A failed upgrade restores an older HTTP-only release using process-owner-verified legacy readiness'
        Wait-LegacyCloud $identity
        & (Join-Path $upgrade 'scripts/update-service.ps1') -ServiceName $name -PackageDirectory $upgrade -ReleaseDirectory (Join-Path $legacyInstall ('releases/'+$context.upgradeVersion)) -AllowUnsigned -RequireCloud
        [void](Wait-Cloud $identity); Wait-Ui 'disabled' 'gui-legacy-migrated'
        Record 'Older HTTP-only release upgrades to pipe status with TCP off and the same cloud identity'
        Remove-TestService
    }
    $fixtureDir=Join-Path $out 'spoof-fixture'; New-Item -ItemType Directory -Path $fixtureDir | Out-Null
    $fixtureExe=Join-Path $fixtureDir 'monitor-service-fixture.exe'; Copy-Item -LiteralPath $fixture -Destination $fixtureExe
    $fixtureCommand='"'+$fixtureExe+'" '+$name
    [void](Invoke-EdgeServiceControl @('create',$name,'type=','own','start=','demand','obj=','NT AUTHORITY\LocalService','binPath=',$fixtureCommand))
    [void](Invoke-EdgeServiceControl @('sidtype',$name,'restricted')); Protect-EdgeRelease $fixtureDir $name
    Start-Service $name; $info=Wait-Service 'Running'
    [StatusSpoofFixtures]::StartPipe([uint32]$info.ProcessId); $spoofPipe=$true
    Probe @('--reject-pipe') 'monitor-spoof-pipe-rejected'
    Start-Sleep -Milliseconds 500
    $rejected=$false; try { [void](Read-EdgeStatus $name) } catch { $rejected=$_.Exception.Message -match 'Status pipe server is not the EdgeCore service' }
    Check $rejected 'Monitor and installer reject a pipe owned by another process even when it claims the service PID'
    Remove-TestService
    & (Join-Path $initial 'scripts/install-package.ps1') -PackageDirectory $initial -ServiceName $name -InstallRoot $tcpInstall -DataDirectory $tcpData -HttpPort $http -ProtocolPort $pt -AllowUnsigned
    [void](Invoke-EdgeServiceControl @('failure',$name,'reset=','0','actions=','none/0'))
    $failedStart=$false; try { Start-Service $name } catch { $failedStart=$true }
    $info=Wait-Service 'Stopped'
    Check ($failedStart -and ($info.ExitCode -ne 0 -or $info.ServiceSpecificExitCode -ne 0)) 'Edge service fails startup when another process preclaims the status pipe'
    [StatusSpoofFixtures]::StopPipe(); $spoofPipe=$false
    Start-Service $name; [void](Wait-Cloud $identity); Wait-Ui 'disabled' 'gui-pipe-collision-recovered'
    Record 'Removing the spoof pipe restores genuine service startup and monitor status'
    $result.passed=$true
} catch {
    $result.error=$_.Exception.Message
    $_ | Out-String | Set-Content -LiteralPath (Join-Path $out 'failure.log')
} finally {
    $cleanupErrors=@()
    try {
        if ($spoofHttp) { [StatusSpoofFixtures]::StopHttp() }
        if ($spoofPipe) { [StatusSpoofFixtures]::StopPipe() }
    } catch { $cleanupErrors+=$_.Exception.Message }
    try {
        if ($monitorProcess -and -not $monitorProcess.HasExited) {
            Probe @('--close-ui',[string]$monitorProcess.Id) 'monitor-close'
            if (-not $monitorProcess.WaitForExit(30000)) { throw 'Owned monitor did not close cleanly.' }
        }
    } catch { $cleanupErrors+=$_.Exception.Message }
    try {
        if ($monitorProcess) {
            if ($shortcutExisted) { Copy-Item -LiteralPath $shortcutBackup -Destination $shortcut -Force }
            elseif (Test-Path -LiteralPath $shortcut) {
                $shell=New-Object -ComObject WScript.Shell
                if ($shell.CreateShortcut($shortcut).TargetPath -eq $monitor) { Remove-Item -LiteralPath $shortcut }
            }
        }
    } catch { $cleanupErrors+=$_.Exception.Message }
    # Service cleanup and primary-service verification must still run if a
    # GUI or fixture cleanup operation fails.
    try {
        Remove-TestService
        Check (-not (Get-EdgeServiceInfo $name)) 'All temporary status qualification services removed'
        $after=Get-EdgeServiceInfo EdgeCore
        $result.primaryServiceUnchanged=if ($primary) { $after -and $after.PathName -eq $primary.PathName -and $after.ProcessId -eq $primary.ProcessId -and $after.State -eq $primary.State } else { -not $after }
        Check $result.primaryServiceUnchanged 'Existing EdgeCore service retains its original process, configuration and state'
    } catch { $cleanupErrors+=$_.Exception.Message }
    $result.cleanupVerified=$cleanupErrors.Count -eq 0
    if ($cleanupErrors.Count) { $result.passed=$false; $result.error+=' Cleanup: '+($cleanupErrors -join '; ') }
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $out 'results.json') -Encoding UTF8
}
if (-not $result.passed) { throw $result.error }
Write-Output 'Windows status end-to-end qualification passed.'
