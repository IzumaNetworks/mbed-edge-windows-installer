# Windows deployment qualification

Run these tests with Windows PowerShell 5.1 from this repository. Installer
lifecycle tests require increasing MSI versions with the same qualification
GUID so they cannot change the primary EdgeCore service.

- `test-msi.ps1` tests restricted LocalService, required CLI, failed-upgrade
  rollback, major upgrade, downgrade rejection, uninstall and retained state.
- `test-msi-release.ps1` qualifies the actual signed single MSI after removing the shared x64 release runtime on a disposable self-hosted Windows runner. The VM image must have the machine environment setting `IZUMA_EDGE_MSI_DISPOSABLE=1`; see [runner requirements](../../.github/SELF_HOSTED_RUNNERS.md). It verifies private DLL loading, repair, uninstall and reinstall with retained state.
- `test-installer-bundle.ps1` and `test-package.ps1` validate payload integrity
  and reject tampering and unsigned production catalogs.
- `test-unified-msi.ps1` reads the compiled MSI and verifies a single delivery
  artifact and product version containing Core, converter, monitor, CLI, wizard
  and runtime DLLs. It queries the packaged CLI read-only and matches its compiled
  service identity to the bundle, MSI and delivery manifest. `-RequireBothToolchains` also checks that the same delivery
  result records successful 2022 and 2026 compiler validation. It does not install.
- `test-provisioning-input.ps1` validates credential-free CBOR/JSON staging
  inputs; `test-ctl-path.ps1` validates owned PATH changes without changing the
  machine. `test-release-orchestration.ps1` uses a local GitHub CLI fixture.

```powershell
.\test\windows-core\test-msi.ps1 -InitialResult D:\qualification\initial\msi-result.json -UpgradeResult D:\qualification\upgrade\msi-result.json -OutputDirectory D:\qualification\msi-test
.\test\windows-core\test-msi-release.ps1 -MsiPath D:\qualification\izuma-edge-VERSION-windows-x64.msi -CorePackageDirectory D:\qualification\edge-core-VERSION-windows-x64 -OutputDirectory D:\qualification\msi-test
```

Isolated MSI upgrade/rollback qualification passed 17 checks on Windows 10.
The MSI now embeds private Microsoft runtime DLLs. Its signed production lifecycle qualification runs in the manual release workflow; inspect that run for the result.
Full production enrollment and other target Windows editions need separate
qualification. Historical qualification evidence remains in ignored build paths.

## Service and monitor status qualification

`test-package-service.ps1` exercises real-cloud package upgrade/rollback with
explicit private provisioning and Edge's native startup-failure fixture.
`test-status-client.ps1` verifies strict-mode HTTP compatibility and rejects
status from a different process. It needs no administrator access.

`test-status-e2e.ps1` tests a GUID-isolated restricted service and native monitor,
ordinary-user named-pipe access, TCP status off/on, recovery, package upgrades,
rollback and spoof status rejection. It runs independently of installer tests.
Optional `-LegacyPackageDirectory` tests the older HTTP-only Core protocol;
this is service protocol compatibility, independent of installer format.

Prepare `RunDirectory/context.json` with `serviceName` (`EdgeCoreMonitorTest-GUID`),
`initialVersion` and `upgradeVersion`. Put package builds in `initial-package`
and `upgrade-package`, a prepared payload in `initial-setup/bundle`, and the
GUID-targeted monitor/probe build in `monitor-build`. The startup-failure fixture
must be in the adjacent `windows-x64` build directory. Supply private provisioning
explicitly. The primary service configuration is checked before and after the
run; test services and monitors are removed and private state remains protected.

For retries, `-ResumeEvidenceDirectory` requires cleaned-up evidence with the
same GUID; it reuses only stopped test identity. `-RetainedStateDirectory` can
reuse stopped test state with a new GUID. Neither modifies the source state.

```powershell
.\test\windows-core\test-status-e2e.ps1 -RunDirectory D:\work\mbed-edge\build\windows-status-e2e-run -ProvisioningFile D:\factory\private-bundle\provisioning.cbor
```
