# SPDX-License-Identifier: Apache-2.0
# Shared file provisioning for setup and the post-install factory command.
. (Join-Path $PSScriptRoot 'package-tools.ps1')
function Get-EdgeProvisioningFile {
    param([string]$Path,[long]$MaximumBytes=16777216)
    if ($Path -notmatch '^[A-Za-z]:[\\/]' -or $Path.Substring(2).Contains(':') -or
        $Path.Contains('"') -or $Path.Contains("`r") -or $Path.Contains("`n")) { throw 'Provisioning requires an absolute local file path.' }
    $full=[IO.Path]::GetFullPath($Path)
    [void](Get-EdgeLocalDirectory ([IO.Path]::GetDirectoryName($full)))
    $item=Get-Item -LiteralPath $full -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        $item.Length -eq 0 -or $item.Length -gt $MaximumBytes) { throw 'Provisioning input must be a nonempty regular file within the supported size limit.' }
    return $full
}
function Read-EdgeProvisioningInput {
    param([string]$Path)
    $extension=[IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($extension -notin @('.cbor','.json')) { throw 'Provisioning must be a .cbor or .json file.' }
    $maximum=16777216; if ($extension -eq '.json') { $maximum=1048576 }
    $source=Get-EdgeProvisioningFile $Path $maximum
    $json=$null; $files=@()
    if ($extension -eq '.json') {
        try { $json=Get-Content -LiteralPath $source -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { throw 'Cannot parse provisioning JSON.' }
        if (-not $json -or -not $json.PSObject.Properties['SchemeVersion'] -or $json.SchemeVersion -cne '0.0.1') { throw 'Unsupported provisioning scheme version.' }
        foreach ($property in $json.PSObject.Properties.Name) {
            if ($property -cnotin @('SchemeVersion','Certificates','Keys','ConfigParams','RoTFilePath')) { throw 'Unsupported provisioning JSON field.' }
        }
        foreach ($group in @('Certificates','Keys')) {
            $index=0
            if (-not $json.PSObject.Properties[$group]) { continue }
            if ($json.$group -isnot [array]) { throw 'Provisioning certificate/key groups must be arrays.' }
            foreach ($entry in $json.$group) {
                if (-not $entry -or -not $entry.PSObject.Properties['Data'] -or -not $entry.PSObject.Properties['Format'] -or
                    $entry.Data -isnot [string] -or -not $entry.Data -or $entry.Format -cne 'der') { throw 'JSON certificate/key entries require a local DER file path.' }
                $reference=$entry.Data
                if ($reference -notmatch '^[A-Za-z]:[\\/]') {
                    if ($reference -match '[:]' -or $reference -match '^[\\/]') { throw 'DER paths must be local absolute paths or relative bundle paths.' }
                    $reference=Join-Path ([IO.Path]::GetDirectoryName($source)) $reference
                }
                $file=Get-EdgeProvisioningFile $reference
                $filename="$group-$index.der"
                $files+=@{source=$file; filename=$filename}; $entry.Data=$filename; $index++
            }
        }
        # Preserve the optional file-based RoT without leaving a reference to
        # removable factory media. FCC reads this field as an absolute path.
        if ($json.PSObject.Properties.Name -ccontains 'RoTFilePath') {
            if ($json.RoTFilePath -isnot [string] -or -not $json.RoTFilePath) { throw 'RoTFilePath must be a local file path.' }
            $reference=$json.RoTFilePath
            if ($reference -notmatch '^[A-Za-z]:[\\/]') {
                if ($reference -match '[:]' -or $reference -match '^[\\/]') { throw 'RoTFilePath must be a local file path.' }
                $reference=Join-Path ([IO.Path]::GetDirectoryName($source)) $reference
            }
            $files+=@{source=(Get-EdgeProvisioningFile $reference); filename='root-of-trust.bin'}
        }
    }
    return @{source=$source; extension=$extension; json=$json; files=$files}
}
function Write-EdgeProvisioningInput {
    param($InputBundle,[string]$Directory,[Security.Principal.SecurityIdentifier]$ServiceSid,
          [ValidateSet('developer','production')][string]$Mode='developer')
    $target=Get-EdgeLocalDirectory $Directory
    if (Test-Path -LiteralPath $target) { throw 'Provisioning staging directory must be new.' }
    New-Item -ItemType Directory -Path $target | Out-Null
    # Apply the private ACL before writing any credential bytes.
    $acl=New-Object Security.AccessControl.DirectorySecurity
    $acl.SetOwner([Security.Principal.SecurityIdentifier]'S-1-5-32-544')
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($grant in @(@('S-1-5-18','FullControl'),@('S-1-5-32-544','FullControl'),@($ServiceSid.Value,'ReadAndExecute'))) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(([Security.Principal.SecurityIdentifier]$grant[0]),$grant[1],'ContainerInherit,ObjectInherit','None','Allow')))
    }
    Set-Acl -LiteralPath $target -AclObject $acl
    $path=Join-Path $target ('provisioning'+$InputBundle.extension)
    if ($InputBundle.json) {
        foreach ($file in $InputBundle.files) { Copy-Item -LiteralPath $file.source -Destination (Join-Path $target $file.filename) }
        if ($InputBundle.json.PSObject.Properties.Name -ccontains 'RoTFilePath') { $InputBundle.json.RoTFilePath=Join-Path $target 'root-of-trust.bin' }
        [IO.File]::WriteAllText($path,($InputBundle.json | ConvertTo-Json -Depth 30),(New-Object Text.UTF8Encoding($false)))
    } else { Copy-Item -LiteralPath $InputBundle.source -Destination $path }
    # This is operator intent, not a claim that the certificate is production.
    @{schema=1; requestedMode=$Mode; source='external-file'; stagedUtc=[DateTime]::UtcNow.ToString('o'); cloudQualified=$false} |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $target 'source.json') -Encoding UTF8
    return $path
}
