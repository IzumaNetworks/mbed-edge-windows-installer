# SPDX-License-Identifier: Apache-2.0
# Real SCM/setup handoff using credential-free fixtures; never start them.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$InstallerResult,[Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../../windows/package-tools.ps1')
$setup=Get-Content -LiteralPath $InstallerResult -Raw | ConvertFrom-Json
if ($setup.serviceName -notmatch '^EdgeCoreMonitorTest-([0-9a-f-]{36})$') { throw 'A GUID qualification installer is required.' }
$id=$Matches[1]; [void][guid]::ParseExact($id,'D')
$out=Get-EdgeLocalDirectory ([IO.Path]::GetFullPath($OutputDirectory))
$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-InstallerResult',$InstallerResult,'-OutputDirectory',$out)
    $child=Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList (ConvertTo-EdgeNativeArguments $args) -Verb RunAs -WindowStyle Hidden -PassThru
    $child.WaitForExit()
    if ($child.ExitCode -ne 0) { throw 'Elevated provisioning qualification failed; see results.json.' }
    Get-Content -LiteralPath (Join-Path $out 'results.json'); exit 0
}
if (Test-Path -LiteralPath $out) { throw 'Output directory must be new.' }
New-Item -ItemType Directory -Path $out | Out-Null
$name=$setup.serviceName
$app=Join-Path $env:ProgramFiles ('Izuma/EdgeSetup-qualification-'+$id)
$data=Join-Path $env:ProgramData ('Izuma/EdgeCore-qualification-'+$id)
$result=[ordered]@{passed=$false; serviceName=$name; checks=@(); error=$null; cleanupVerified=$false; credentialsUsed=$false; serviceStarted=$false}
function Check { param([bool]$Condition,[string]$Message); if (-not $Condition) { throw $Message }; $result.checks+=$Message; Add-Content -LiteralPath (Join-Path $out 'progress.log') -Value $Message }
function Invoke-Setup { param([string]$Exe,[string[]]$Options,[string]$Case,[switch]$Reject)
    $args=@('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/INSTALLMONITOR=0','/STARTSERVICE=0',('/LOG='+$out+'\'+$Case+'.log'))+$Options
    $process=Start-Process -FilePath $Exe -ArgumentList (ConvertTo-EdgeNativeArguments $args) -WindowStyle Hidden -Wait -PassThru
    if ($Reject) { Check ($process.ExitCode -notin @(0,3010)) "$Case rejected" }
    elseif ($process.ExitCode -notin @(0,3010)) { throw "$Case setup failed ($($process.ExitCode))." }
}
function Uninstall { if (Test-Path -LiteralPath (Join-Path $app 'unins000.exe')) { Invoke-Setup (Join-Path $app 'unins000.exe') @() 'uninstall' } }
function Reject-Provision { param([scriptblock]$Operation,[string]$Message)
    $failed=$false; try { & $Operation | Out-Null } catch { $failed=$true }
    Check $failed $Message
}
try {
    Check (-not (Get-EdgeServiceInfo $name)) 'Isolated qualification service absent initially'
    $cbor=Join-Path $out 'fixture.cbor'
    # Valid CBOR envelope, deliberately without any certificate/key/identity.
    [IO.File]::WriteAllBytes($cbor,([byte[]](0xa1,0x6d)+[Text.Encoding]::UTF8.GetBytes('SchemeVersion')+[byte[]](0x65)+[Text.Encoding]::UTF8.GetBytes('0.0.1')))
    Invoke-Setup $setup.setup @('/PROVISIONINGMODE=production') 'missing-file' -Reject
    Check (-not (Get-EdgeServiceInfo $name)) 'Missing production file creates no service'
    Invoke-Setup $setup.setup @(('/PROVISIONING='+$cbor),'/PROVISIONINGMODE=developer') 'developer-cbor'
    $command=(Get-EdgeServiceInfo $name).PathName
    $match=[regex]::Match($command,'--cbor-conf "([^"]+)"')
    Check $match.Success 'Developer CBOR is passed through the native SCM command'
    $installed=$match.Groups[1].Value
    Check ((Get-FileHash -LiteralPath $installed).Hash -eq (Get-FileHash -LiteralPath $cbor).Hash) 'CBOR bytes preserved during private staging'
    $source=Get-Content -LiteralPath (Join-Path (Split-Path -Parent $installed) 'source.json') -Raw | ConvertFrom-Json
    Check ($source.requestedMode -eq 'developer' -and -not $source.cloudQualified) 'Developer intent recorded without claiming cloud qualification'
    $acl=Get-Acl -LiteralPath (Split-Path -Parent $installed)
    $sid=(New-Object Security.Principal.NTAccount('NT SERVICE',$name)).Translate([Security.Principal.SecurityIdentifier]).Value
    $grants=@($acl.Access | ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value })
    Check ($acl.AreAccessRulesProtected -and $sid -in $grants -and 'S-1-5-11' -notin $grants -and 'S-1-5-19' -notin $grants) 'Private bundle ACL grants only the service SID, administrators and SYSTEM'
    Invoke-Setup $setup.setup @(('/PROVISIONING='+$cbor),'/PROVISIONINGMODE=production') 'upgrade-identity-replacement' -Reject
    Check ((Get-EdgeServiceInfo $name).PathName -eq $command) 'Upgrade rejects new credentials and retains the command'
    Uninstall
    $der=Join-Path $out 'fixture.der'; [IO.File]::WriteAllBytes($der,[byte[]](0x30,0x00))
    $rot=Join-Path $out 'fixture-rot.bin'; [IO.File]::WriteAllBytes($rot,(New-Object byte[] 16))
    $json=Join-Path $out 'fixture.json'
    @{SchemeVersion='0.0.1'; Certificates=@(@{Name='fixture'; Format='der'; Data='fixture.der'}); Keys=@(); ConfigParams=@(); RoTFilePath='fixture-rot.bin'} |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $json -Encoding UTF8
    Invoke-Setup $setup.setup @(('/PROVISIONING='+$json),'/PROVISIONINGMODE=production') 'production-json'
    $match=[regex]::Match((Get-EdgeServiceInfo $name).PathName,'--json-conf "([^"]+)"')
    Check $match.Success 'Production file uses the same runtime JSON importer'
    $installed=$match.Groups[1].Value; $bundle=Get-Content -LiteralPath $installed -Raw | ConvertFrom-Json
    Check ($bundle.Certificates[0].Data -eq 'Certificates-0.der' -and
        (Get-FileHash -LiteralPath (Join-Path (Split-Path -Parent $installed) $bundle.Certificates[0].Data)).Hash -eq (Get-FileHash -LiteralPath $der).Hash) 'JSON DER references are copied and rewritten into protected config'
    Check ($bundle.RoTFilePath.StartsWith((Split-Path -Parent $installed)+'\') -and
        (Get-FileHash -LiteralPath $bundle.RoTFilePath).Hash -eq (Get-FileHash -LiteralPath $rot).Hash) 'Optional file RoT is staged without a removable-media dependency'
    $source=Get-Content -LiteralPath (Join-Path (Split-Path -Parent $installed) 'source.json') -Raw | ConvertFrom-Json
    Check ($source.requestedMode -eq 'production' -and -not $source.cloudQualified) 'Production selection records intent without certifying placeholder credentials'
    Uninstall
    Invoke-Setup $setup.setup @('/PROVISIONINGMODE=deferred') 'deferred'
    Check ((Invoke-EdgeServiceControl @('qc',$name)) -match 'DEMAND_START') 'Unprovisioned installation remains manual until first provisioning'
    $command=(Get-EdgeServiceInfo $name).PathName
    $helper=Join-Path $app 'scripts/provision-service.ps1'
    $empty=Join-Path $out 'empty.cbor'; [IO.File]::WriteAllBytes($empty,(New-Object byte[] 0))
    Reject-Provision { & $helper -ServiceName $name -DataDirectory $data -ProvisioningFile $empty } 'Empty provisioning file rejected before activation'
    $bad=Join-Path $out 'bad.json'; '{"SchemeVersion":"9.0.0"}' | Set-Content -LiteralPath $bad
    Reject-Provision { & $helper -ServiceName $name -DataDirectory $data -ProvisioningFile $bad } 'Unsupported JSON schema rejected before activation'
    $sentinel=Join-Path $data 'state/provisioning-test-sentinel.txt'
    'No credentials: retained-state fixture' | Set-Content -LiteralPath $sentinel
    Reject-Provision { & $helper -ServiceName $name -DataDirectory $data -ProvisioningFile $cbor } 'Any retained state blocks first provisioning'
    Remove-Item -LiteralPath $sentinel
    Check ((Get-EdgeServiceInfo $name).PathName -eq $command -and -not (Test-Path -LiteralPath (Join-Path $data 'provisioning-import.json'))) 'Rejected requests preserve service arguments and create no import journal'
    & $helper -ServiceName $name -DataDirectory $data -ProvisioningFile $cbor -ProvisioningMode production
    $journal=Get-Content -LiteralPath (Join-Path $data 'provisioning-import.json') -Raw | ConvertFrom-Json
    Check ($journal.stage -eq 'Configured' -and $journal.requestedMode -eq 'production' -and (Get-EdgeServiceInfo $name).PathName -eq $journal.command) 'Headless post-install first provisioning activates its durable journal and SCM arguments'
    $startup=Get-ItemProperty -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\'+$name)
    Check ($startup.Start -eq 2 -and $startup.DelayedAutoStart -eq 1) 'First provisioning enables delayed automatic startup'
    $command=(Get-EdgeServiceInfo $name).PathName
    Reject-Provision { & $helper -ServiceName $name -DataDirectory $data -ProvisioningFile $cbor } 'A second provisioning request cannot replace the first identity input'
    Check ((Get-EdgeServiceInfo $name).PathName -eq $command -and (Get-EdgeServiceInfo $name).State -eq 'Stopped') 'Provisioning qualification never starts placeholder credentials'
    $result.passed=$true
} catch { $result.error=$_.Exception.Message; $_ | Out-String | Set-Content -LiteralPath (Join-Path $out 'failure.log') }
finally {
    try { Uninstall; Check (-not (Get-EdgeServiceInfo $name)) 'Temporary service removed'; $result.cleanupVerified=$true }
    catch { $result.passed=$false; $result.error+=' Cleanup: '+$_.Exception.Message }
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $out 'results.json') -Encoding UTF8
}
if (-not $result.passed) { throw $result.error }
