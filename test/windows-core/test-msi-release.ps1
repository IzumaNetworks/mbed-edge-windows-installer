# SPDX-License-Identifier: Apache-2.0
# Qualify the actual signed MSI and its private runtime on a disposable runner.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$MsiPath,
    [Parameter(Mandatory=$true)][string]$CorePackageDirectory,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [string]$DeveloperFixturePath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') { throw 'Production MSI qualification and shared-runtime removal require a disposable GitHub-hosted runner.' }
. (Join-Path $PSScriptRoot '../../windows/package-tools.ps1')
Assert-EdgeAdministrator
if (Get-Service EdgeCore -ErrorAction SilentlyContinue) { throw 'Runner must not have an EdgeCore service.' }
$msi=(Resolve-Path -LiteralPath $MsiPath).Path
$core=(Resolve-Path -LiteralPath $CorePackageDirectory).Path
$out=Get-EdgeLocalDirectory ([IO.Path]::GetFullPath($OutputDirectory))
if (Test-Path -LiteralPath $out) { throw 'OutputDirectory must be new.' }
New-Item -ItemType Directory -Path $out | Out-Null
$manifest=Get-Content -LiteralPath (Join-Path $core 'package.json') -Raw | ConvertFrom-Json
if ((Get-EdgeVisualCppDeployment $manifest) -ne 'app-local') { throw 'The released MSI must include its app-local runtime.' }
$result=[ordered]@{passed=$false;checks=@();error=$null;version=$manifest.version;sharedRuntimeRemoved=$false}
$runtimeKey='HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'
$monitorProcess=$null
$monitorExecutable=$null
function Stop-TestMonitor {
    if (-not $script:monitorProcess) { return }
    try {
        $shutdown=Start-Process -FilePath $script:monitorExecutable -ArgumentList '--exit' -WindowStyle Hidden -PassThru -Wait
        $shutdown.Dispose()
        if (-not $script:monitorProcess.WaitForExit(10000)) { Stop-Process -Id $script:monitorProcess.Id -Force }
    } finally { $script:monitorProcess.Dispose(); $script:monitorProcess=$null }
}
function Check([bool]$Condition,[string]$Text) { if (-not $Condition) { throw $Text }; $result.checks+=$Text; $Text | Add-Content -LiteralPath (Join-Path $out 'progress.log') }
function Msi([string]$Action,[string]$Case) {
    $arguments=$Action+' "'+$msi+'" /qn /norestart /l*v "'+(Join-Path $out ($Case+'.log'))+'"'
    if ($Action -ne '/x') { $arguments+=' STARTSERVICE=0' }
    $process=Start-Process "$env:SystemRoot/System32/msiexec.exe" -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru
    try { if ($process.ExitCode -notin @(0,3010)) { throw "$Case failed ($($process.ExitCode)); inspect the MSI log." } } finally { $process.Dispose() }
}
function Converter([string]$InputFile,[string]$OutputFile,[string]$LogName) {
    # Capture stderr as data; PS 5.1 must not turn an expected rejection into
    # a terminating NativeCommandError before its exit code can be checked.
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$converter
    $info.Arguments=ConvertTo-EdgeNativeArguments @('convert-developer','--input',$InputFile,'--output',$OutputFile)
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $process=New-Object Diagnostics.Process; $process.StartInfo=$info
    try {
        [void]$process.Start()
        $stdout=$process.StandardOutput.ReadToEnd(); $stderr=$process.StandardError.ReadToEnd(); $process.WaitForExit()
        [IO.File]::WriteAllText((Join-Path $out $LogName),($stdout+$stderr))
        return $process.ExitCode
    } finally { $process.Dispose() }
}

function Runtime-Detected {
    $runtime=Get-ItemProperty -LiteralPath $runtimeKey -ErrorAction SilentlyContinue
    return [bool]($runtime -and $runtime.PSObject.Properties['Installed'] -and $runtime.Installed)
}
function Wizard([string[]]$Arguments) {
    $helper=Join-Path $env:ProgramFiles ('Izuma/EdgeMsiHelpers/'+$manifest.version+'/edge-provisioning-wizard.exe')
    $process=Start-Process -FilePath $helper -ArgumentList (ConvertTo-EdgeNativeArguments $Arguments) -WindowStyle Hidden -Wait -PassThru
    try { return $process.ExitCode } finally { $process.Dispose() }
}
try {
    # Build a static-runtime process before removing the developer runtime.
    & cmake -E env --unset=Path --unset=PATH "Path=$env:PATH" MSBUILDDISABLENODEREUSE=1 cmake -S (Join-Path $PSScriptRoot 'runtime-probe') -B (Join-Path $out 'probe-build') -G 'Visual Studio 17 2022' -A x64
    if ($LASTEXITCODE) { throw 'Runtime probe configuration failed.' }
    & cmake -E env --unset=Path --unset=PATH "Path=$env:PATH" MSBUILDDISABLENODEREUSE=1 cmake --build (Join-Path $out 'probe-build') --config Release --parallel 2
    if ($LASTEXITCODE) { throw 'Runtime probe compilation failed.' }
    $probe=Join-Path $out 'probe-build/Release/edge-runtime-probe.exe'
    $entries=@(foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        Get-ChildItem -LiteralPath $root | ForEach-Object { Get-ItemProperty -LiteralPath $_.PSPath }
    })
    foreach ($bundle in @($entries | Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -match '^Microsoft Visual C\+\+ .*Redistributable \(x64\) - 14\.' -and $_.PSObject.Properties['BundleCachePath'] })) {
        $signature=Get-AuthenticodeSignature -LiteralPath $bundle.BundleCachePath
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|, )O=Microsoft Corporation(,|$)') { throw 'Runtime uninstaller is not Microsoft-signed.' }
        $process=Start-Process $bundle.BundleCachePath -ArgumentList '/uninstall /quiet /norestart' -WindowStyle Hidden -Wait -PassThru
        try { if ($process.ExitCode -notin @(0,3010)) { throw 'Runner runtime bundle removal failed.' } } finally { $process.Dispose() }
    }
    $products=@($entries | Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -match '^Microsoft Visual C\+\+ .* X64 (Minimum|Additional) Runtime - 14\.' })
    foreach ($product in $products) {
        if ($product.PSChildName -notmatch '^\{[0-9a-fA-F-]{36}\}$') { throw 'Invalid runtime product identity.' }
        $process=Start-Process "$env:SystemRoot/System32/msiexec.exe" -ArgumentList ('/x '+$product.PSChildName+' /qn /norestart /l*v "'+(Join-Path $out ('remove-'+$product.PSChildName+'.log'))+'"') -WindowStyle Hidden -Wait -PassThru
        try { if ($process.ExitCode -notin @(0,3010,1605)) { throw 'Runner runtime MSI removal failed.' } } finally { $process.Dispose() }
    }
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class ReleaseRuntimeState {
    [DllImport("msi.dll", CharSet=CharSet.Unicode)] public static extern int MsiQueryProductState(string product);
}
'@
    $states=@($products | ForEach-Object { [pscustomobject]@{name=$_.DisplayName;id=$_.PSChildName;state=[ReleaseRuntimeState]::MsiQueryProductState($_.PSChildName)} })
    $states | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $out 'runtime-product-states.json') -Encoding UTF8
    Check (@($states | Where-Object state -notin @(-1,2)).Count -eq 0) 'Windows Installer confirms shared x64 release runtime products are absent'
    if (Runtime-Detected) { Remove-ItemProperty -LiteralPath $runtimeKey -Name Installed }
    Check (-not (Runtime-Detected)) 'Shared runtime registration is absent before installing the single MSI'
    $result.sharedRuntimeRemoved=$true
    Msi '/i' 'install-runtime-absent'
    $service=Get-EdgeServiceInfo EdgeCore
    Check ($service.State -eq 'Stopped' -and $service.StartName -eq 'NT AUTHORITY\LocalService') 'Single MSI installs a stopped restricted LocalService service'
    $app=Join-Path $env:ProgramFiles 'Izuma/EdgeSetup'
    $data=Join-Path $env:ProgramData 'Izuma/EdgeCore'
    $deployment=Get-Content -LiteralPath (Join-Path $app 'deployment.json') -Raw | ConvertFrom-Json
    Check ($deployment.version -eq $manifest.version -and $deployment.installMonitor -eq 1 -and (Test-Path -LiteralPath $deployment.ctlExecutable)) 'MSI includes the monitor and required CLI'
    Check ((Wizard @('--inspect')) -eq 0) 'Native provisioning inspection identifies a fresh empty installation without UI'
    Check (-not @(Get-Process -Name edge-core-monitor -ErrorAction SilentlyContinue).Count) 'Silent MSI installation does not launch a desktop monitor'
    $startup=(Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name IzumaEdgeCoreMonitor).IzumaEdgeCoreMonitor
    Check ($startup -eq ('"'+$deployment.monitorExecutable+'"')) 'Named-pipe-only monitor startup omits the invalid zero HTTP port'
    $shell=New-Object -ComObject WScript.Shell
    $shortcut=$shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Izuma Edge/Edge Core.lnk'))
    Check ($shortcut.TargetPath -eq $deployment.monitorExecutable -and $shortcut.Arguments -eq '--show') 'The installed monitor shortcut has valid arguments with HTTP disabled'
    $installer=New-Object -ComObject WindowsInstaller.Installer
    $database=$installer.OpenDatabase($msi,0)
    $view=$database.OpenView('SELECT `Condition`, `Sequence` FROM `InstallUISequence` WHERE `Action` = ''EdgeLaunchMonitor''')
    $view.Execute(); $launch=$view.Fetch(); $view.Close()
    Check ($null -ne $launch -and $launch.StringData(1).Contains('UILevel >= 5') -and $launch.StringData(1).Contains('INSTALLMONITOR') -and $launch.StringData(1).Contains('Monitor=3')) 'The compiled MSI gates monitor launch on full UI and monitor selection'
    $view=$database.OpenView('SELECT `Sequence` FROM `InstallUISequence` WHERE `Action` = ''EdgeShowProvisioningWizard''')
    $view.Execute(); $provisioning=$view.Fetch(); $view.Close()
    Check ($launch.IntegerData(2) -gt $provisioning.IntegerData(1)) 'The compiled MSI launches the monitor after the provisioning step'
    $view=$database.OpenView('SELECT `Target` FROM `CustomAction` WHERE `Action` = ''EdgeLaunchMonitor''')
    $view.Execute(); $action=$view.Fetch(); $view.Close()
    Check ($action.StringData(1) -eq 'WixUnelevatedShellExec') 'The compiled MSI uses the desktop user token to launch its monitor'
    $monitorExecutable=$deployment.monitorExecutable
    $monitorLog=Join-Path $out 'monitor-startup.log'
    $monitorProcess=Start-Process -FilePath $deployment.monitorExecutable -ArgumentList ('--diagnostics "'+$monitorLog+'"') -WindowStyle Hidden -PassThru
    $deadline=[DateTime]::UtcNow.AddSeconds(15)
    do { if ((Test-Path -LiteralPath $monitorLog) -and (Get-Content -LiteralPath $monitorLog -Raw).Contains('tray=1')) { break }; Start-Sleep -Milliseconds 200 } while ([DateTime]::UtcNow -lt $deadline)
    Check ((Test-Path -LiteralPath $monitorLog) -and -not $monitorProcess.HasExited -and (Get-Content -LiteralPath $monitorLog -Raw).Contains('tray=1')) 'The installed monitor starts with its normal startup arguments and enables the tray'
    $release=Get-Content -LiteralPath (Join-Path $data 'service-release.json') -Raw | ConvertFrom-Json
    foreach ($name in $manifest.visualCppDlls) {
        Check ((Get-FileHash -LiteralPath (Join-Path $release.directory $name)).Hash -eq (Get-FileHash -LiteralPath (Join-Path $core ('bin/'+$name))).Hash) "MSI deploys original Microsoft runtime DLL: $name"
    }
    & $probe $release.directory *> (Join-Path $out 'runtime-probe.log')
    Check ($LASTEXITCODE -eq 0) 'Native loader resolves CRT, libevent and OpenSSL from the installed private directory'
    Check (-not (Runtime-Detected)) 'MSI succeeds without installing a shared runtime or launching its redistributable'
    $converter=Join-Path $release.directory 'edge-provision.exe'
    Check ((Test-Path -LiteralPath $converter) -and (Get-AuthenticodeSignature -LiteralPath $converter).Status -eq 'Valid') 'MSI deploys the signed portable native converter with its private runtime'
    if ($DeveloperFixturePath) {
        $input=Join-Path $out ('arbitrary developer filename caf'+[char]0x00e9+'.c')
        Copy-Item -LiteralPath $DeveloperFixturePath -Destination $input
        $bundle=Join-Path $out 'synthetic.cbor'
        $exit=Converter $input $bundle 'converter.log'
        Check ($exit -eq 0 -and (Test-Path -LiteralPath $bundle)) 'Installed native converter accepts an arbitrary Unicode developer credential filename'
        $bundleHash=(Get-FileHash -LiteralPath $bundle).Hash
        $exit=Converter $input $bundle 'converter-overwrite.log'
        Check ($exit -ne 0 -and (Get-FileHash -LiteralPath $bundle).Hash -eq $bundleHash) 'Native conversion refuses to overwrite an existing bundle'
        $acl=Get-Acl -LiteralPath $bundle
        Check ($acl.AreAccessRulesProtected -and -not ($acl.Access | Where-Object {$_.IdentityReference.Value -match 'Users$|Everyone|Authenticated Users'})) 'Converted private key material has a protected private ACL'
        $bad=Join-Path $out 'malformed.c'; 'This is not a credential file' | Set-Content -LiteralPath $bad
        Check ((Wizard @('--developer',$bad)) -ne 0 -and (Wizard @('--inspect')) -eq 0) 'Invalid developer input leaves the fresh service unprovisioned'
        Check ((Wizard @('--developer',$input)) -eq 0) 'Native wizard backend converts developer credentials, imports the bundle, and starts the service'
        $servicePid=(Get-EdgeServiceInfo EdgeCore).ProcessId
        $deadline=[DateTime]::UtcNow.AddSeconds(15)
        do {
            $monitorStatus=Get-Content -LiteralPath $monitorLog -Raw
            if ($monitorStatus.Contains('processId='+$servicePid+' tcpStatusEnabled=0 tcpStatusListening=0')) { break }
            Start-Sleep -Milliseconds 200
        } while ([DateTime]::UtcNow -lt $deadline)
        Check ($monitorStatus.Contains('processId='+$servicePid+' tcpStatusEnabled=0 tcpStatusListening=0')) 'The running monitor reads the installed service status through its named pipe with HTTP disabled'
        Stop-Service EdgeCore
        Check ((Wizard @('--inspect')) -in @(10,11)) 'Native wizard detects the imported identity or configured bundle'
        $command=(Get-EdgeServiceInfo EdgeCore).PathName
        Check ((Wizard @('--production',$bundle)) -ne 0 -and (Get-EdgeServiceInfo EdgeCore).PathName -eq $command) 'Provisioning refuses to replace a configured identity'
    }
    Stop-TestMonitor
    $sentinel=Join-Path $data 'state/msi-runtime-state-sentinel.txt'
    'Credential-free retained identity sentinel.' | Set-Content -LiteralPath $sentinel
    $stateHash=(Get-FileHash -LiteralPath $sentinel).Hash
    if (-not $DeveloperFixturePath) { Check ((Wizard @('--inspect')) -eq 12) 'Unrecognized retained state is preserved rather than treated as an empty identity' }
    Msi '/fa' 'repair'
    Check ((Get-FileHash -LiteralPath $sentinel).Hash -eq $stateHash) 'Repair preserves retained device state'
    Msi '/x' 'uninstall'
    Check (-not (Get-Service EdgeCore -ErrorAction SilentlyContinue)) 'MSI uninstall removes the owned service'
    Check ((Get-FileHash -LiteralPath $sentinel).Hash -eq $stateHash) 'Uninstall preserves device state'
    Msi '/i' 'reinstall-retained-state'
    Check ((Get-FileHash -LiteralPath $sentinel).Hash -eq $stateHash) 'MSI reinstalls with retained identity and no provisioning file'
    $release=Get-Content -LiteralPath (Join-Path $data 'service-release.json') -Raw | ConvertFrom-Json
    & $probe $release.directory *> (Join-Path $out 'runtime-probe-reinstalled.log')
    Check ($LASTEXITCODE -eq 0) 'Reinstalled Core dependencies still use the MSI-provided private runtime'
    Msi '/x' 'final-uninstall'
    Check (-not (Runtime-Detected)) 'Install, repair and reinstall never require the shared redistributable'
    $result.passed=$true
} catch { $result.error=$_.Exception.Message }
finally {
    Stop-TestMonitor
    if (Get-Service EdgeCore -ErrorAction SilentlyContinue) { try { Msi '/x' 'cleanup' } catch { } }
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $out 'results.json') -Encoding UTF8
}
if (-not $result.passed) { throw $result.error }
$result.checks
