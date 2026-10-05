# Windows deployment qualification

These PowerShell tests exercise package integrity, the native setup EXE,
restricted service identity, upgrade/rollback and first file provisioning.
Run from this repository. Build two increasing package/setup versions with the
same `-QualificationId <GUID>` for installer lifecycle tests. The GUID tests
never use the real EdgeCore service.

Run `test-provisioning.ps1` before `test-installer.ps1` because the latter leaves
a private-state sentinel that must block later first provisioning:

```powershell
.\test\windows-core\test-provisioning.ps1 `
  -InstallerResult D:\packages\installer-initial\installer-result.json `
  -OutputDirectory D:\work\mbed-edge-windows-installer\build\provisioning-test

.\test\windows-core\test-installer.ps1 `
  -InitialResult D:\packages\installer-initial\installer-result.json `
  -UpgradeResult D:\packages\installer-upgrade\installer-result.json `
  -OutputDirectory D:\work\mbed-edge-windows-installer\build\installer-test

.\test\windows-core\test-installer-bundle.ps1 `
  -BundleDirectory D:\packages\installer-initial\bundle `
  -OutputDirectory D:\work\mbed-edge-windows-installer\build\bundle-test

.\test\windows-core\test-package.ps1 `
  -PackageDirectory D:\packages\edge-core-1005\edge-core-0.21.1005-windows-x64 `
  -OutputDirectory D:\work\mbed-edge-windows-installer\build\package-test
```

Deployment/provisioning tests request administrator approval. Integrity tests
do not. Provisioning fixtures contain no actual credentials and are never
started; they qualify staging and activation, not production cloud enrollment.
Results/protected data are retained and GUID services/policy are removed in
cleanup. Real production credentials, claim/enrollment behavior, signed delivery,
Intune/SCCM and other Windows editions remain separate qualification.

`test-package-service.ps1` exercises real-cloud package upgrade and rollback
with explicitly supplied private provisioning and Edge's native
`windows-update-failure.exe` test fixture. Native service lifecycle/boot tests
remain in the Edge repository and accept `-InstallerRepositoryDirectory`.

`test-status-client.ps1` checks legacy HTTP responses under the updater's
strict PowerShell mode, including missing optional PID metadata, a mismatched
response PID, a listener owned by another process and a changing service PID.
It uses local fixtures and requires no administrator access. The end-to-end
suite also runs it against the packaged helper.

`test-status-e2e.ps1` qualifies the Windows status-pipe change with real cloud
connectivity. It runs the native setup lifecycle checks, then a real restricted
LocalService and the native monitor, verifies ordinary interactive-user pipe
access and TCP status off/on, exercises service stop/recovery and package
upgrade/rollback, and rejects spoof HTTP and pipe sources. An optional
`-LegacyPackageDirectory` also tests migration and rollback from an older
HTTP-only release. The primary EdgeCore process/configuration is checked before
and after the run, and temporary services and the monitor are removed.

Prepare `RunDirectory` with `context.json` containing `serviceName` (a GUID
`EdgeCoreMonitorTest-...` name), `initialVersion`, and `upgradeVersion`.
Put the two package builds in `initial-package` and `upgrade-package`, and
the two setup builds in `initial-setup` and `upgrade-setup`. Build the monitor
into `monitor-build` with CMake `MONITOR_QUALIFICATION_SERVICE` equal to that
GUID service name, and include that monitor executable in both qualification
setups. The normal monitor build continues to target EdgeCore. This run expects
the core build's native startup-failure fixture in the adjacent `windows-x64`
build directory. Supply the existing private CBOR provisioning file; evidence
and retained test state are protected by Windows ACLs.

For a retry, use a new `-AttemptName e2e-attempt-2` evidence directory and
`-ResumeEvidenceDirectory` pointing to a prior cleaned-up attempt with a
passing native setup lifecycle. This reuses its stopped cloud identity and
installer lifecycle evidence. For a new qualification GUID/package build,
`-RetainedStateDirectory` may instead reuse a stopped test service's state
while rerunning the complete native setup lifecycle. These options never
modify the source state or the primary EdgeCore service.

```powershell
.\test\windows-core\test-status-e2e.ps1 `
  -RunDirectory D:\work\mbed-edge\build\windows-status-e2e-run `
  -ProvisioningFile D:\factory\private-bundle\provisioning.cbor `
  -LegacyPackageDirectory D:\packages\previous-release
```

Prior qualification (before extraction) passed 25 installer deployment checks,
6 bundle integrity checks and 7 package integrity checks on Windows 10 Pro
22H2 x64. Historical evidence is under `D:\work\mbed-edge\build`; new evidence
is under this repository's ignored `build` directory.

For one administrator prompt, `test-release.ps1` runs first provisioning then
installer lifecycle qualification and verifies the real EdgeCore service keeps
its original process/configuration. Supply `-InitialResult`, `-UpgradeResult`
and a new `-OutputDirectory`. No real credentials or cloud device creation are
used by that run.


Current extraction/file-provisioning validation passed on Windows 10 Pro
22H2 x64 (19045.6466) on October 2, 2026. All 18 installer PowerShell scripts
parse and the native x64 setup builds. The 12 provisioning-input checks,
6 combined-bundle checks and 7 package checks passed.

The administrator run of test-release.ps1 passed all 23 provisioning checks
and 25 installer lifecycle checks using setup versions 0.21.1005 and 0.21.1006.
Evidence is in build/release-qualification-1/results.json and its provisioning
and installer subdirectories. The temporary service and monitor policy were
removed. The existing EdgeCore service retained its process/configuration and
remained connected. Credential-free fixture data is intentionally retained.
These results qualify file staging and deployment; production cloud enrollment
still requires real production credentials and a separate test.

## Windows status-pipe qualification on October 4, 2026

The full status-change end-to-end suite passed with unsigned Release packages
0.21.1016 and 0.21.1017. Evidence is in
`D:\work\mbed-edge\build\windows-status-e2e-20261004-211411\e2e-attempt-1\results.json`.
All 27 top-level checks, 23 provisioning checks, 25 native installer lifecycle
checks, 7 package checks, 6 bundle checks and 5 legacy-client regression checks
passed. The core Release CTest suite passed 13/13 and the monitor suite 2/2.

The live restricted LocalService retained its real cloud identity through
restart, upgrade, rollback and migration from the older HTTP-only 0.21.1005
release. Ordinary interactive-user pipe access, TCP off by default, explicit
TCP opt-in, monitor Details/button state and disabling TCP again passed.
The native monitor ignored spoof HTTP status; both monitor and installer
rejected another process's pipe even when its payload claimed the service PID.
The core rejected a preclaimed pipe at startup and recovered after its removal.

The suite found and verified fixes for a queued SCM recovery restart racing
with uninstall, and strict-mode handling of older HTTP responses without
optional PID metadata. Legacy HTTP still requires the real service to own the
loopback listener before and after the request.

The qualification monitor uses the production GUI/backend with a GUID service
name compiled solely for test isolation. Cloud checks reused a stopped test
identity. All temporary services and the monitor were removed, the original
shortcut was restored, the elevated test runner was stopped, and the existing
EdgeCore process/configuration remained unchanged. Private state is retained
with protected ACLs. This run did not repeat Linux runtime, machine-reboot,
production-signing or clean-machine prerequisite qualification.
