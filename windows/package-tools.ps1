# SPDX-License-Identifier: Apache-2.0
# Shared offline package validation; Windows PowerShell 5.1+.
. (Join-Path $PSScriptRoot 'service-tools.ps1')
. (Join-Path $PSScriptRoot 'visual-cpp-tools.ps1')
function Assert-EdgeAdministrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Use an elevated Windows PowerShell prompt.'
    }
    if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit PowerShell for this x64 package.' }
}
function Get-EdgeLocalDirectory {
    param([string]$Path)
    if ($Path -notmatch '^[A-Za-z]:[\\/]') { throw 'Use absolute local drive directories.' }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    if ($full.Length -le 3) { throw 'Do not use a drive root.' }
    for ($current=$full; $current; $current=[IO.Path]::GetDirectoryName($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'A package directory or ancestor is a file/reparse point.'
            }
        }
    }
    return $full
}
function Assert-EdgeNativeImage {
    param([string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $reader = New-Object IO.BinaryReader($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5a4d) { throw 'Missing DOS header.' }
        $stream.Position=0x3c; $header=$reader.ReadUInt32()
        if ($header -gt $stream.Length-264) { throw 'Invalid PE offset.' }
        $stream.Position=$header
        if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x8664) { throw 'Expected x64 PE image.' }
        $optional=$header+24; $stream.Position=$optional
        if ($reader.ReadUInt16() -ne 0x20b) { throw 'Expected PE32+ image.' }
        $stream.Position=$optional+112+14*8
        if ($reader.ReadUInt32() -ne 0) { throw 'Managed CLR images cannot be packaged as native edge-core.' }
    } finally { $reader.Dispose(); $stream.Dispose() }
}
function Test-EdgePackage {
    param([string]$Directory,[switch]$AllowUnsigned,[string]$SignerThumbprint)
    $root = Get-EdgeLocalDirectory $Directory
    $manifest = Get-Content -LiteralPath (Join-Path $root 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.schema -ne 1 -or $manifest.product -ne 'Izuma Edge Core' -or
        $manifest.architecture -ne 'x64' -or $manifest.profile -ne 'BYOC/OpenSSL/Release' -or
        $manifest.version -notmatch '^\d+\.\d+\.\d+$' -or -not $manifest.files.Count) {
        throw 'Unsupported package manifest.'
    }
    [void][version]$manifest.version
    $names=@(); $expected=@('package.json','package.cat')
    foreach ($entry in $manifest.files) {
        if ($entry.path -notmatch '^(bin|scripts|licenses|prerequisites)/[A-Za-z0-9_.-]+$' -or
            $entry.path -in $names -or $entry.sha256 -notmatch '^[a-fA-F0-9]{64}$') {
            throw 'Invalid or duplicate package member.'
        }
        $names += $entry.path; $expected += $entry.path
        $file=Get-Item -LiteralPath (Join-Path $root $entry.path) -Force
        if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            $file.Length -ne $entry.bytes -or (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne $entry.sha256) {
            throw 'Package member failed integrity validation.'
        }
    }
    foreach ($member in Get-ChildItem -LiteralPath $root -Force -Recurse) {
        if ($member.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse point in package.' }
        if (-not $member.PSIsContainer) {
            $relative=$member.FullName.Substring($root.Length+1).Replace('\','/')
            if ($relative -notin $expected) { throw 'Unexpected file in package.' }
        }
    }
    foreach ($required in @('bin/edge-core.exe','bin/event.dll','bin/event_core.dll',
            'scripts/install-service.ps1','scripts/service-tools.ps1','scripts/package-tools.ps1',
            'scripts/install-package.ps1','scripts/update-service.ps1')) {
        if ($required -notin $names) { throw "Missing package member: $required" }
    }
    if ((Get-EdgeVisualCppDeployment $manifest) -eq 'app-local') {
        if ('scripts/visual-cpp-tools.ps1' -notin $names) { throw 'App-local runtime validation helper is absent.' }
        Test-EdgeVisualCppRuntime $manifest $root
    } elseif ('prerequisites/vc_redist.x64.exe' -notin $names) { throw 'Shared runtime prerequisite is absent.' }
    foreach ($pattern in @('^bin/libcrypto-3[^/]*\.dll$','^bin/libssl-3[^/]*\.dll$')) {
        if (@($names | Where-Object {$_ -match $pattern}).Count -ne 1) { throw 'Expected one OpenSSL 3 TLS and crypto DLL.' }
    }
    Assert-EdgeNativeImage (Join-Path $root 'bin/edge-core.exe')
    $catalog=Join-Path $root 'package.cat'
    if ((Test-FileCatalog -Path $root -CatalogFilePath $catalog) -ne 'Valid') { throw 'Package catalog validation failed.' }
    $signature=Get-AuthenticodeSignature -LiteralPath $catalog
    if (-not $AllowUnsigned) {
        if ($SignerThumbprint -notmatch '^[a-fA-F0-9]{40}$' -or $signature.Status -ne 'Valid' -or
            $signature.SignerCertificate.Thumbprint -ne $SignerThumbprint) {
            throw 'A valid catalog signed by the configured release certificate is required. Use -AllowUnsigned only for qualification.'
        }
    }
    return $manifest
}
function Protect-EdgeRelease {
    param([string]$Directory,[string]$ServiceName)
    $account=New-Object Security.Principal.NTAccount('NT SERVICE',$ServiceName)
    $sid=$account.Translate([Security.Principal.SecurityIdentifier])
    $acl=New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    $acl.SetOwner([Security.Principal.SecurityIdentifier]'S-1-5-32-544')
    foreach ($entry in @(@('S-1-5-18','FullControl'),@('S-1-5-32-544','FullControl'),@($sid.Value,'ReadAndExecute'))) {
        $rule=New-Object Security.AccessControl.FileSystemAccessRule(
            ([Security.Principal.SecurityIdentifier]$entry[0]),$entry[1],'ContainerInherit,ObjectInherit','None','Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Directory -AclObject $acl
}
function Initialize-EdgeStatusPipeClient {
    if ('Izuma.EdgeStatusPipeClient' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace Izuma {
    public static class EdgeStatusPipeClient {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(string name, uint access, uint share,
            IntPtr security, uint creation, uint flags, IntPtr templateFile);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetNamedPipeServerProcessId(SafeFileHandle pipe, out uint processId);
        private const uint ClientAccess = (0x00120089u | 0x00120116u) & ~0x00000004u;
        private static int Remaining(DateTime deadline) {
            int milliseconds = (int)Math.Ceiling((deadline - DateTime.UtcNow).TotalMilliseconds);
            if (milliseconds <= 0) throw new TimeoutException("Status pipe operation timed out.");
            return milliseconds;
        }
        private static void ReadExact(FileStream stream, byte[] data, DateTime deadline) {
            int offset = 0;
            while (offset < data.Length) {
                IAsyncResult operation = stream.BeginRead(data, offset, data.Length - offset, null, null);
                if (!operation.AsyncWaitHandle.WaitOne(Remaining(deadline))) {
                    stream.Dispose();
                    throw new TimeoutException("Status pipe read timed out.");
                }
                int amount = stream.EndRead(operation);
                if (amount == 0) throw new EndOfStreamException();
                offset += amount;
            }
        }
        public static string Read(uint expectedPid) {
            DateTime deadline = DateTime.UtcNow.AddSeconds(5);
            using (SafeFileHandle handle = CreateFile(@"\\.\pipe\IzumaEdgeCoreStatus",
                ClientAccess, 0, IntPtr.Zero, 3, 0x40000000u, IntPtr.Zero)) {
                if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                uint serverPid;
                if (!GetNamedPipeServerProcessId(handle, out serverPid) || serverPid != expectedPid)
                    throw new UnauthorizedAccessException("Status pipe server is not the EdgeCore service.");
                using (var stream = new FileStream(handle, FileAccess.ReadWrite, 4096, true)) {
                    byte[] header = new byte[4];
                    ReadExact(stream, header, deadline);
                    uint length = ((uint)header[0] << 24) | ((uint)header[1] << 16) |
                        ((uint)header[2] << 8) | header[3];
                    if (length == 0 || length > 65536) throw new InvalidDataException("Status response length is invalid.");
                    byte[] payload = new byte[(int)length];
                    ReadExact(stream, payload, deadline);
                    IAsyncResult ack = stream.BeginWrite(new byte[] { 6 }, 0, 1, null, null);
                    if (!ack.AsyncWaitHandle.WaitOne(Remaining(deadline))) {
                        stream.Dispose();
                        throw new TimeoutException("Status pipe acknowledgement timed out.");
                    }
                    stream.EndWrite(ack);
                    return new UTF8Encoding(false, true).GetString(payload);
                }
            }
        }
    }
}
'@
}
function Read-EdgeStatus {
    param([string]$ServiceName='EdgeCore')
    $before=Get-EdgeServiceInfo $ServiceName
    if (-not $before -or $before.State -ne 'Running' -or -not $before.ProcessId) { throw 'EdgeCore service is not running.' }
    Initialize-EdgeStatusPipeClient
    $status=[Izuma.EdgeStatusPipeClient]::Read([uint32]$before.ProcessId) | ConvertFrom-Json
    $after=Get-EdgeServiceInfo $ServiceName
    if (-not $after -or $after.State -ne 'Running' -or $after.ProcessId -ne $before.ProcessId -or
        $status.connectivity.processId -ne $before.ProcessId) { throw 'Status pipe process identity mismatch.' }
    return $status
}
function Read-LegacyEdgeHttpStatus {
    param([string]$ServiceName='EdgeCore',[int]$HttpPort)
    if ($HttpPort -lt 1 -or $HttpPort -gt 65535) { throw 'Legacy HTTP status port is unavailable.' }
    $before=Get-EdgeServiceInfo $ServiceName
    if (-not $before -or $before.State -ne 'Running' -or -not $before.ProcessId) { throw 'EdgeCore service is not running.' }
    $owner=Get-NetTCPConnection -LocalPort $HttpPort -State Listen -ErrorAction Stop |
        Where-Object { $_.LocalAddress -eq '127.0.0.1' -and $_.OwningProcess -eq $before.ProcessId }
    if (-not $owner) { throw 'Legacy HTTP status port is not owned by the EdgeCore service.' }
    $status=Invoke-RestMethod -Uri "http://127.0.0.1:$HttpPort/status" -TimeoutSec 3
    # Older releases have no connectivity/PID metadata. Read optional members
    # explicitly so the updater's StrictMode does not reject those responses.
    $reportedPid=$null
    $connectivityProperty=$status.PSObject.Properties['connectivity']
    if ($connectivityProperty -and $connectivityProperty.Value) {
        $pidProperty=$connectivityProperty.Value.PSObject.Properties['processId']
        if ($pidProperty) { $reportedPid=$pidProperty.Value }
    }
    $after=Get-EdgeServiceInfo $ServiceName
    $owner=Get-NetTCPConnection -LocalPort $HttpPort -State Listen -ErrorAction Stop |
        Where-Object { $_.LocalAddress -eq '127.0.0.1' -and $_.OwningProcess -eq $before.ProcessId }
    if (-not $after -or $after.State -ne 'Running' -or $after.ProcessId -ne $before.ProcessId -or -not $owner -or
        ($reportedPid -and $reportedPid -ne $before.ProcessId)) {
        throw 'Legacy HTTP status process identity mismatch.'
    }
    return $status
}
function Wait-EdgeServiceReady {
    param([string]$Name,[string]$Command,[int]$HttpPort,[int]$Seconds=40,[switch]$AllowLegacyHttp)
    $deadline=[DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $service=Get-EdgeServiceInfo $Name
        if ($service.PathName -ne $Command) { throw 'Service command changed during activation.' }
        if ($service.State -eq 'Stopped') { throw "Candidate service stopped: $($service.ExitCode)/$($service.ServiceSpecificExitCode)." }
        if ($service.State -eq 'Running') {
            try { [void](Read-EdgeStatus $Name); return } catch { }
            if ($AllowLegacyHttp) {
                try { [void](Read-LegacyEdgeHttpStatus $Name $HttpPort); return } catch { }
            }
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Local service readiness timed out.'
}
