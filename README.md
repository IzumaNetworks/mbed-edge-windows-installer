# Izuma Edge Windows installer

Native x64 Windows packaging and deployment for Izuma Edge Core and its optional
tray monitor. This repository owns package creation, self-contained WiX MSI authoring,
restricted Windows service installation, upgrades/rollback, first file
provisioning and deployment qualification.

The application, Windows service adapter and OpenSSL/PAL implementation belong
in [mbed-edge](https://github.com/PelionIoT/mbed-edge). The monitor belongs in
[edge-core-monitor](https://github.com/IzumaNetworks/edge-core-monitor). This
installer consumes their compiled Release outputs; it does not copy their
source or embed any device identity.

## Build

Download `izuma-edge-VERSION-windows-x64.msi` for one offline installation of
Core, monitor, CLI and the included Microsoft runtime DLLs. No setup EXE wrapper
or shared runtime installation is needed. Follow the
[MSI and Azure signing guide](windows/installer/MSI.md).

`windows/build-release.ps1` runs the complete manual GitHub build, test, sign,
MSI and artifact-download chain; `-PlanOnly` displays its inputs. Local builds use
64-bit Windows PowerShell 5.1, WiX 6.0.2, Visual Studio 2022 or 2026 C++ tools,
native Release BYOC/OpenSSL Core and
monitor/CLI outputs, Visual Studio's original signed x64 redistributable CRT DLLs,
and OpenSSL license source. Build the Core package with `-VisualCppDeployment app-local`,
then use `prepare-msi-bundle.ps1` and `build-msi.ps1`. Follow the signing order in
the guide. Release workflows remain manual (`workflow_dispatch`).

See [setup and silent deployment](windows/installer/README.md),
[package/updater details](windows/README.md),
[all provisioning phases](windows/production-packaging-plan.md) and
[qualification](test/windows-core/README.md).

For a complete local build with native tests and one unsigned qualification MSI,
run the following with a previously built OpenSSL SDK and WiX 6.0.2:

```powershell
.\windows\build-local.ps1 -ValidateBothToolchains `
  -OpenSSLRoot ..\mbed-edge\build\openssl\install `
  -OpenSSLSourceDirectory ..\mbed-edge\build\openssl\openssl-3.5.9 `
  -OutputDirectory .\build\windows\0.21.1031
```

This produces one Windows installer version containing Core, monitor, CLI,
wizard and runtime dependencies. Visual Studio is a build-host choice; users
receive the same installer product for Windows 10 and later. The default `Auto`
selects the newest installed supported compiler for packaging. Use
`-VisualStudioVersion 2022` or `2026` to select it explicitly.
`-ValidateBothToolchains` builds and tests both compilers, then packages the
selected compiler's outputs once. `windows-installer-result.json` identifies
the single delivery artifact and records the compiler validation results.

The helper uses separate internal build caches for each compiler and retains
the Windows 10 build 17763 target. The individual MSI helper accepts
`-CMakeGenerator 'Visual Studio 17 2022'` or `'Visual Studio 18 2026'`;
its default is automatic detection.
For 2026, use CMake with the 2026 generator (validated with 4.4.4). Packaging
discovers either VC143 or VC145 Microsoft-signed app-local runtime DLLs.
Building on Windows 11 does not qualify execution on Windows 10; that still
requires running the final artifacts on a Windows 10 machine.

Unsigned qualification builds bind the monitor and CLI to the same isolated
service name as the MSI and wizard. Reuse `-QualificationId` and increase
`-Version` to upgrade an installed test deployment while retaining its identity.
Bundle creation verifies the CLI's compiled service binding before packaging;
the MSI builder rejects an unverified or mismatched qualification bundle.

The monitor is optional and selected by default. File provisioning supports
developer bundles and factory-issued per-machine bundles through the same
OpenSSL/FCC/KCM runtime path. Software-only installation stays manual until
first provisioning. Existing identity cannot be replaced by an upgrade or the
first-provisioning command. Production file enrollment still needs real-tenant
qualification; factory-server enrollment and native Windows TPM support remain
planned work.

Supported release targets are Windows 10 Pro, 11 Pro and Server 2019/2022/2025
x64, including Server Core without the monitor. Qualification to date is on
Windows 10 Pro 22H2 x64; the other editions and IoT LTSC need their own testing.
