# SPDX-License-Identifier: Apache-2.0
# First provisioning only. Never resets storage or replaces an existing identity.
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9_.-]{1,80}$')][string]$ServiceName='EdgeCore',
    [string]$DataDirectory=(Join-Path $env:ProgramData 'Izuma/EdgeCore'),
    [Parameter(Mandatory=$true)][string]$ProvisioningFile,
    [ValidateSet('developer','production')][string]$ProvisioningMode='developer',
    [switch]$Start
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'provisioning-tools.ps1')
Assert-EdgeAdministrator
function Save-ProvisioningJournal {
    param($Record,[string]$Path)
    [IO.File]::WriteAllText(($Path+'.pending'),($Record | ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath ($Path+'.pending') -Destination $Path -Force
}
$data=Get-EdgeLocalDirectory $DataDirectory
$owner=Get-Content -LiteralPath (Join-Path $data 'service-install.json') -Raw | ConvertFrom-Json
$service=Get-EdgeServiceInfo $ServiceName
if (-not $service -or $owner.serviceName -ne $ServiceName -or $service.StartName -ne 'NT AUTHORITY\LocalService' -or
    -not $service.PathName.StartsWith(('"'+$owner.installDirectory+'\edge-core.exe" --service --service-name '+$ServiceName+' '),[StringComparison]::OrdinalIgnoreCase) -or
    -not $service.PathName.Contains('--data-dir "'+(Join-Path $data 'state')+'"')) { throw 'Service and data directory ownership do not match.' }
foreach ($member in Get-ChildItem -LiteralPath $data -Force -Recurse) {
    if ($member.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse point in private service data.' }
}
$lock=[IO.File]::Open((Join-Path $data 'provisioning.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try {
    $service=Get-EdgeServiceInfo $ServiceName
    $state=Get-EdgeLocalDirectory (Join-Path $data 'state')
    $journal=Join-Path $data 'provisioning-import.json'
    if ($service.State -ne 'Stopped') { throw 'Stop the unprovisioned service before supplying its first identity.' }
    if ($service.PathName -match '--(cbor|json)-conf\b|--reset-storage\b' -or (Test-Path -LiteralPath $journal) -or (Test-Path -LiteralPath ($journal+'.pending')) -or
        (Get-ChildItem -LiteralPath $state -Force -Recurse | Select-Object -First 1)) {
        throw 'Provisioning or retained state already exists. First provisioning cannot replace it; identity reset is a separate operation.'
    }
    $inputBundle=Read-EdgeProvisioningInput $ProvisioningFile
    $sid=(New-Object Security.Principal.NTAccount('NT SERVICE',$ServiceName)).Translate([Security.Principal.SecurityIdentifier])
    $stage=Get-EdgeLocalDirectory (Join-Path $data ('config/bundle-'+[guid]::NewGuid().ToString('D')))
    $path=Write-EdgeProvisioningInput $inputBundle $stage $sid $ProvisioningMode
    $option='--cbor-conf'; if ($inputBundle.extension -eq '.json') { $option='--json-conf' }
    $command=$service.PathName+' '+$option+' "'+$path+'"'
    $record=@{schema=1; serviceName=$ServiceName; requestedMode=$ProvisioningMode; stage='Prepared';
        directory=$stage; previousCommand=$service.PathName; command=$command; cloudQualified=$false}
    Save-ProvisioningJournal $record $journal
    # A startup race cannot lead to replacing identity: the first-provision
    # guard is repeated immediately before SCM activation.
    if ((Get-EdgeServiceInfo $ServiceName).State -ne 'Stopped' -or
        (Get-ChildItem -LiteralPath $state -Force -Recurse | Select-Object -First 1)) { throw 'Service started during provisioning. Retain the provisioning journal for administrator recovery.' }
    [void](Invoke-EdgeServiceControl @('config',$ServiceName,'binPath=',$command,'start=','delayed-auto'))
    $record.stage='Configured'; Save-ProvisioningJournal $record $journal
    if ($Start) {
        Start-Service $ServiceName
        $http=[regex]::Match($command,'--http-port\s+(\d+)(\s|$)')
        if (-not $http.Success) { throw 'Configured service has no status port.' }
        Wait-EdgeServiceReady $ServiceName $command ([int]$http.Groups[1].Value)
        $record.stage='Started'; Save-ProvisioningJournal $record $journal
    }
    Write-Output "First $ProvisioningMode bundle configured for $ServiceName. Cloud bootstrap occurs when connectivity is available; this does not certify production credentials."
} finally { $lock.Dispose() }
