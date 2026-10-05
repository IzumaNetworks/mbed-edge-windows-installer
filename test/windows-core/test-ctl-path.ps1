# SPDX-License-Identifier: Apache-2.0
# Pure PATH transformation tests; never change the registry or machine settings.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../../windows/installer/ctl-integration.ps1')
$app='C:\Program Files\Izuma\EdgeSetup'
$old=$app+'\ctl\0.21.1001'
$next=$app+'\ctl\0.21.1002'
$unrelated='%SystemRoot%\System32;C:\Other App\bin;;C:\Program Files\Izuma\EdgeSetup-other\ctl\0.21.1001'
if ((Get-EdgeCtlPathValue $unrelated $app $next) -cne ($unrelated+';'+$next)) { throw 'Install changed unrelated PATH entries.' }
if ((Get-EdgeCtlPathValue ($unrelated+';'+$old+';'+$next) $app $next) -cne ($unrelated+';'+$next)) { throw 'Upgrade did not replace/deduplicate owned entries.' }
if ((Get-EdgeCtlPathValue ($unrelated+';'+$next) $app $old) -cne ($unrelated+';'+$old)) { throw 'Rollback did not restore the previous owned entry.' }
if ((Get-EdgeCtlPathValue ($unrelated+';"'+$old+'"') $app '') -cne $unrelated) { throw 'Uninstall did not remove only the quoted owned entry.' }
$failed=$false; try { Get-EdgeCtlPathValue $unrelated $app 'C:\Untrusted' | Out-Null } catch { $failed=$true }
if (-not $failed) { throw 'Accepted an unowned helper directory in PATH.' }
$failed=$false; try { Get-EdgeCtlPathValue $unrelated $app ($next+';C:\Untrusted') | Out-Null } catch { $failed=$true }
if (-not $failed) { throw 'Accepted PATH separator injection.' }
'PASS PATH install, upgrade, rollback, uninstall, unrelated-entry preservation and injection rejection.'
