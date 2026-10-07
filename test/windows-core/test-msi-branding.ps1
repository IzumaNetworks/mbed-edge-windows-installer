# SPDX-License-Identifier: Apache-2.0
# Read-only verification of the compiled MSI's artwork and dialog resource references.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$MsiPath,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [string]$BrandingDirectory=(Join-Path $PSScriptRoot '../../windows/installer')
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$msi=(Resolve-Path -LiteralPath $MsiPath).Path
$out=[IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $out) { throw 'OutputDirectory must be new.' }
New-Item -ItemType Directory -Path $out | Out-Null
if (-not ('Izuma.MsiBrandingRead' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
namespace Izuma {
    public static class MsiBrandingRead {
        [DllImport("msi.dll", CharSet=CharSet.Unicode)]
        static extern uint MsiOpenDatabase(string path, IntPtr mode, out uint database);
        [DllImport("msi.dll", CharSet=CharSet.Unicode)]
        static extern uint MsiDatabaseOpenView(uint database, string sql, out uint view);
        [DllImport("msi.dll")]
        static extern uint MsiViewExecute(uint view, uint record);
        [DllImport("msi.dll")]
        static extern uint MsiViewFetch(uint view, out uint record);
        [DllImport("msi.dll")]
        static extern uint MsiRecordReadStream(uint record, uint field, byte[] data, ref uint size);
        [DllImport("msi.dll")]
        static extern uint MsiCloseHandle(uint handle);
        static void Check(uint error) { if (error!=0) throw new InvalidOperationException("MSI read failed ("+error+")."); }
        public static void Extract(string path, string binary, string output) {
            uint database=0,view=0,record=0;
            try {
                Check(MsiOpenDatabase(path,IntPtr.Zero,out database));
                Check(MsiDatabaseOpenView(database,"SELECT `Data` FROM `Binary` WHERE `Name` = '"+binary+"'",out view));
                Check(MsiViewExecute(view,0));
                Check(MsiViewFetch(view,out record));
                using (var stream=new FileStream(output,FileMode.CreateNew,FileAccess.Write)) {
                    var buffer=new byte[8192];
                    for (;;) {
                        uint size=(uint)buffer.Length;
                        Check(MsiRecordReadStream(record,1,buffer,ref size));
                        if (size==0) break;
                        stream.Write(buffer,0,(int)size);
                    }
                }
            } finally { if (record!=0) MsiCloseHandle(record); if (view!=0) MsiCloseHandle(view); if (database!=0) MsiCloseHandle(database); }
        }
    }
}
'@
}
$installer=New-Object -ComObject WindowsInstaller.Installer
$database=$installer.OpenDatabase($msi,0)
$checks=@()
foreach ($entry in @(@('welcome.png','WixUI_Bmp_Dialog','WelcomeDlg','Bitmap'),@('finish.png','EdgeFinishBmp','ExitDialog','Bitmap'),@('banner.png','WixUI_Bmp_Banner','LicenseAgreementDlg','BannerBitmap'))) {
    $view=$database.OpenView('SELECT `Text` FROM `Control` WHERE `Dialog_` = '''+$entry[2]+''' AND `Control` = '''+$entry[3]+'''')
    $view.Execute(); $record=$view.Fetch(); $view.Close()
    if (-not $record -or $record.StringData(1) -cne $entry[1]) { throw "Incorrect dialog artwork reference: $($entry[2])" }
    $file=Join-Path $out $entry[0]
    [Izuma.MsiBrandingRead]::Extract($msi,$entry[1],$file)
    $source=Join-Path $BrandingDirectory $entry[0]
    if ((Get-FileHash -LiteralPath $file).Hash -cne (Get-FileHash -LiteralPath $source).Hash) { throw "Compiled MSI artwork differs from source: $($entry[0])" }
    $checks+="The compiled $($entry[2]) dialog references and embeds the original $($entry[0])"
}
@{passed=$true;checks=$checks} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $out 'results.json') -Encoding UTF8
$checks
