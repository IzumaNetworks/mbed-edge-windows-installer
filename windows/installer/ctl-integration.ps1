# SPDX-License-Identifier: Apache-2.0
# Preserve unrelated machine PATH entries, including their unexpanded values.
function Get-EdgeCtlPathValue {
    param([string]$Value,[string]$AppRoot,[string]$Directory)
    if ($AppRoot.Contains(';') -or $Directory.Contains(';')) { throw 'Control helper paths cannot contain a PATH separator.' }
    $prefix=$AppRoot.TrimEnd('\')+'\ctl\'
    if ($Directory -and $Directory -notmatch ('^'+[regex]::Escape($prefix)+'\d+\.\d+\.\d+$')) { throw 'Control helper PATH entry is outside its owned versioned directory.' }
    $entries=@()
    if ($Value) {
        foreach ($entry in $Value.Split(';')) {
            $expanded=[Environment]::ExpandEnvironmentVariables($entry.Trim().Trim('"')).TrimEnd('\')
            if ($expanded -notmatch ('^'+[regex]::Escape($prefix)+'\d+\.\d+\.\d+$')) { $entries+=$entry }
        }
    }
    if ($Directory) { $entries+=$Directory }
    return $entries -join ';'
}
function Set-EdgeCtlIntegration {
    param([string]$AppRoot,[string]$Directory)
    $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
    try {
        $key=$base.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment',$true)
        if (-not $key) { throw 'Machine environment key is unavailable.' }
        try {
            $old=[string]$key.GetValue('Path','',[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $value=Get-EdgeCtlPathValue $old $AppRoot $Directory
            if ($value -eq $old) { return }
            $kind=[Microsoft.Win32.RegistryValueKind]::ExpandString
            if ($key.GetValueNames() -contains 'Path') { $kind=$key.GetValueKind('Path') }
            if ($kind -notin @([Microsoft.Win32.RegistryValueKind]::String,[Microsoft.Win32.RegistryValueKind]::ExpandString)) { throw 'Machine PATH must be a string.' }
            $key.SetValue('Path',$value,$kind)
        } finally { $key.Dispose() }
    } finally { $base.Dispose() }
    if (-not ('Izuma.EdgeEnvironmentChange' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Izuma {
    public static class EdgeEnvironmentChange {
        [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern IntPtr SendMessageTimeout(IntPtr window, uint message, UIntPtr wparam, string lparam, uint flags, uint timeout, out UIntPtr result);
        public static void Notify() {
            UIntPtr result;
            SendMessageTimeout(new IntPtr(0xffff), 0x001a, UIntPtr.Zero, "Environment", 2, 1000, out result);
        }
    }
}
'@
    }
    [Izuma.EdgeEnvironmentChange]::Notify()
}
