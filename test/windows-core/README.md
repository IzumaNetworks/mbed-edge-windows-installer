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
