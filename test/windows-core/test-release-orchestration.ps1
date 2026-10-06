# SPDX-License-Identifier: Apache-2.0
# Credential-free orchestration checks; this executable never contacts GitHub.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../../windows/package-tools.ps1')
$out=Get-EdgeLocalDirectory ([IO.Path]::GetFullPath($OutputDirectory))
if (Test-Path -LiteralPath $out) { throw 'OutputDirectory must be new.' }
New-Item -ItemType Directory -Path $out | Out-Null
$source=@'
using System;
using System.IO;
using System.Collections.Generic;
using System.Web.Script.Serialization;
public class ReleaseGhFixture {
  static JavaScriptSerializer json = new JavaScriptSerializer();
  static Dictionary<string,object> Read(string path) {
    return json.Deserialize<Dictionary<string,object>>(File.ReadAllText(path));
  }
  public static int Main(string[] args) {
    try {
      string root=Environment.GetEnvironmentVariable("EDGE_RELEASE_TEST_ROOT");
      if (args[0]=="api") {
        bool post=Array.IndexOf(args,"POST")>=0;
        string endpoint=Array.Find(args,a=>a.StartsWith("repos/"));
        bool core=endpoint.Contains("windows-release.yml");
        if (core && Path.GetFileName(root)=="single") { Console.Error.WriteLine("Core workflow is not registered in this fixture"); return 1; }
        string input=Path.Combine(root,core?"core-input.json":"msi-input.json");
        if (post) {
          string file=args[Array.IndexOf(args,"--input")+1];
          File.WriteAllText(input,file=="-"?Console.In.ReadToEnd():File.ReadAllText(file)); return 0;
        }
        if (endpoint.Contains("/runs?")) {
          var body=Read(input);
          var inputs=(Dictionary<string,object>)body["inputs"];
          string title=core?"Signed Windows core "+inputs["version"]+" ("+inputs["release_id"]+")":"Signed Windows MSI ("+inputs["release_id"]+")";
          var unrelated=new {id=777,display_title="Unrelated concurrent release",html_url="https://example.invalid/777"};
          var requested=new {id=core?101:202,display_title=title,html_url="https://example.invalid/run"};
          Console.WriteLine(json.Serialize(new {workflow_runs=new object[]{unrelated,requested}}));
          return 0;
        }
        Console.WriteLine("{\"state\":\"active\"}"); return 0;
      }
      if (args[0]=="run" && args[1]=="watch") {
        File.AppendAllText(Path.Combine(root,"watched.txt"),args[2]+"\n");
        return args[2]=="101" && Environment.GetEnvironmentVariable("EDGE_RELEASE_TEST_FAIL_CORE")=="1"?1:0;
      }
      if (args[0]=="run" && args[1]=="download") {
        string dest=args[Array.IndexOf(args,"--dir")+1]; Directory.CreateDirectory(dest);
        string source=File.Exists(Path.Combine(root,"core-input.json"))?"core-input.json":"msi-input.json";
        var inputs=(Dictionary<string,object>)Read(Path.Combine(root,source))["inputs"];
        foreach (string name in new[]{"edge-core.exe","edge-core-monitor.exe","izuma-edge-ctl.exe","signatures.json","source.json","SHA256SUMS.txt","izuma-edge-"+inputs["version"]+"-windows-x64.msi"})
          File.WriteAllText(Path.Combine(dest,name),"Fixture data, not a signed release.");
        return 0;
      }
      throw new Exception("Unexpected fixture invocation");
    } catch(Exception e) { Console.Error.WriteLine(e.Message); return 1; }
  }
}
'@
Add-Type -TypeDefinition $source -ReferencedAssemblies System.Web.Extensions -OutputAssembly (Join-Path $out 'gh.exe') -OutputType ConsoleApplication
$previousPath=$env:PATH
$previousRoot=$env:EDGE_RELEASE_TEST_ROOT
$previousFailure=$env:EDGE_RELEASE_TEST_FAIL_CORE
$checks=@()
try {
    $env:PATH=$out+';'+$previousPath
    $env:EDGE_RELEASE_TEST_ROOT=Join-Path $out 'success'; New-Item -ItemType Directory $env:EDGE_RELEASE_TEST_ROOT | Out-Null
    $env:EDGE_RELEASE_TEST_FAIL_CORE='0'
    $release=Join-Path $PSScriptRoot '../../windows/build-release.ps1'
    & $release -Version 0.21.1024 -CoreRef release/core -InstallerRef release/msi -MonitorRef monitor-v1 -OutputDirectory (Join-Path $out 'download')
    $core=Get-Content (Join-Path $env:EDGE_RELEASE_TEST_ROOT 'core-input.json') -Raw | ConvertFrom-Json
    $msi=Get-Content (Join-Path $env:EDGE_RELEASE_TEST_ROOT 'msi-input.json') -Raw | ConvertFrom-Json
    $record=Get-Content (Join-Path $out 'download/release-runs.json') -Raw | ConvertFrom-Json
    if ($msi.inputs.core_run_id -ne '101' -or $msi.inputs.release_id -ne $core.inputs.release_id -or
        $msi.inputs.monitor_ref -ne 'monitor-v1' -or $core.ref -ne 'release/core' -or $msi.ref -ne 'release/msi' -or
        -not $record.complete -or $record.installerRunId -ne 202) { throw 'Release correlation or source selection failed.' }
    $checks+='A concurrent unrelated run is ignored; the correct successful Core run feeds MSI signing and artifact download'
    $env:EDGE_RELEASE_TEST_ROOT=Join-Path $out 'failure'; New-Item -ItemType Directory $env:EDGE_RELEASE_TEST_ROOT | Out-Null
    $env:EDGE_RELEASE_TEST_FAIL_CORE='1'
    $rejected=$false
    try { & $release -Version 0.21.1024 -CoreRef release/core -InstallerRef release/msi -MonitorRef monitor-v1 -OutputDirectory (Join-Path $out 'failed-release') }
    catch { if ($_.Exception.Message -notlike 'Workflow did not succeed:*') { throw }; $rejected=$true }
    $record=Get-Content (Join-Path $out 'failed-release/release-runs.json') -Raw | ConvertFrom-Json
    if (-not $rejected -or (Test-Path (Join-Path $env:EDGE_RELEASE_TEST_ROOT 'msi-input.json')) -or $record.complete -or $record.coreRunId -ne 101) { throw 'A failed Core workflow did not stop MSI signing.' }
    $checks+='A failed Core run stops the chain before MSI dispatch and retains its diagnostic run record'
    $env:EDGE_RELEASE_TEST_ROOT=Join-Path $out 'single'; New-Item -ItemType Directory $env:EDGE_RELEASE_TEST_ROOT | Out-Null
    $env:EDGE_RELEASE_TEST_FAIL_CORE='0'
    & $release -Version 0.21.1024 -CoreRef release/core -InstallerRef release/msi -MonitorRef monitor-v1 -BuildCoreInInstaller -OutputDirectory (Join-Path $out 'single-download')
    $msi=Get-Content (Join-Path $env:EDGE_RELEASE_TEST_ROOT 'msi-input.json') -Raw | ConvertFrom-Json
    $record=Get-Content (Join-Path $out 'single-download/release-runs.json') -Raw | ConvertFrom-Json
    if ((Test-Path (Join-Path $env:EDGE_RELEASE_TEST_ROOT 'core-input.json')) -or $msi.inputs.core_ref -ne 'release/core' -or
        $msi.inputs.version -ne '0.21.1024' -or $msi.inputs.monitor_ref -ne 'monitor-v1' -or
        -not $record.complete -or $record.coreRunId -ne 202 -or $record.installerRunId -ne 202) { throw 'The full installer workflow did not retain the requested sources and run record.' }
    $checks+='The single-workflow build succeeds even when the separate Core workflow is not registered'
    @{passed=$true;checks=$checks} | ConvertTo-Json | Set-Content (Join-Path $out 'results.json') -Encoding UTF8
    $checks
} finally {
    $env:PATH=$previousPath; $env:EDGE_RELEASE_TEST_ROOT=$previousRoot; $env:EDGE_RELEASE_TEST_FAIL_CORE=$previousFailure
}
