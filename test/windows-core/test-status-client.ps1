# SPDX-License-Identifier: Apache-2.0
# Regression checks for strict-mode legacy status and process identity guards.
param([string]$PackageToolsPath=(Join-Path $PSScriptRoot '../../windows/package-tools.ps1'))
$ErrorActionPreference='Stop'
. $PackageToolsPath
Set-StrictMode -Version Latest
$script:fixtureStatus=$null
$script:fixtureOwner=12345
$script:fixtureServiceQueries=0
$script:fixturePidChanged=$false
function Get-EdgeServiceInfo {
    param([string]$Name)
    $script:fixtureServiceQueries++
    $servicePid=12345
    if ($script:fixturePidChanged -and $script:fixtureServiceQueries -gt 1) { $servicePid++ }
    [pscustomobject]@{State='Running'; ProcessId=$servicePid}
}
function Get-NetTCPConnection {
    param([int]$LocalPort,[string]$State,[string]$ErrorAction)
    [pscustomobject]@{LocalAddress='127.0.0.1'; OwningProcess=$script:fixtureOwner}
}
function Invoke-RestMethod {
    param([string]$Uri,[int]$TimeoutSec)
    $script:fixtureStatus
}
function Expect-Rejection {
    param([string]$Message)
    $rejected=$false
    try { [void](Read-LegacyEdgeHttpStatus 'EdgeCoreTest' 8080) }
    catch { $rejected=$_.Exception.Message -eq $Message }
    if (-not $rejected) { throw "Expected rejection: $Message" }
}
$script:fixtureStatus='{"status":"connected","internal-id":"fixture"}' | ConvertFrom-Json
if ((Read-LegacyEdgeHttpStatus 'EdgeCoreTest' 8080).status -ne 'connected') { throw 'Legacy status was rejected' }
Write-Output 'PASS strict-mode legacy response without connectivity metadata'
$script:fixtureStatus='{"status":"connected","connectivity":{}}' | ConvertFrom-Json
[void](Read-LegacyEdgeHttpStatus 'EdgeCoreTest' 8080)
Write-Output 'PASS strict-mode response without optional processId'
$script:fixtureStatus='{"status":"connected","connectivity":{"processId":12346}}' | ConvertFrom-Json
Expect-Rejection 'Legacy HTTP status process identity mismatch.'
Write-Output 'PASS mismatched response PID rejected'
$script:fixtureStatus='{"status":"connected"}' | ConvertFrom-Json
$script:fixtureOwner=12346
Expect-Rejection 'Legacy HTTP status port is not owned by the EdgeCore service.'
Write-Output 'PASS another process listener rejected'
$script:fixtureOwner=12345
$script:fixtureServiceQueries=0
$script:fixturePidChanged=$true
Expect-Rejection 'Legacy HTTP status process identity mismatch.'
Write-Output 'PASS service PID change during HTTP request rejected'
