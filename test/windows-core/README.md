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


Current extraction/file-provisioning validation on Windows 10 Pro:
18 installer PowerShell scripts parse; the native x64 setup builds; all 12
test-provisioning-input.ps1 checks, 6 combined-bundle checks and 7 package
checks passed. The test-release.ps1 service checks are prepared and awaiting a
successful Windows administrator prompt. The attempted prompt was cancelled
before service registration. No production cloud enrollment is claimed.
