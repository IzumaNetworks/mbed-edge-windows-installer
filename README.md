# Izuma Edge Windows installer

Native x64 Windows packaging and deployment for Izuma Edge Core and its optional
tray monitor. This repository owns package creation, MSI and Inno Setup authoring,
restricted Windows service installation, upgrades/rollback, first file
provisioning and deployment qualification.

The application, Windows service adapter and OpenSSL/PAL implementation belong
in [mbed-edge](https://github.com/PelionIoT/mbed-edge). The monitor belongs in
[edge-core-monitor](https://github.com/IzumaNetworks/edge-core-monitor). This
installer consumes their compiled Release outputs; it does not copy their
source or embed any device identity.

## Build

For signed MSI releases and GitHub artifacts, follow the
[MSI and Azure signing guide](windows/installer/MSI.md). It includes the Azure
OIDC setup for the `izumaedgesigning` account and certificate profile, the
Visual C++ prerequisite, silent MSI options and `gh` release commands.
`windows/build-release.ps1` runs the complete GitHub build, test, sign, MSI and
artifact-download chain in one command; use `-PlanOnly` to inspect its inputs.

Use 64-bit Windows PowerShell 5.1, a native Release BYOC/OpenSSL build of Edge
Core, the monitor Release executable, the original Microsoft-signed x64 VC++
redistributable, OpenSSL source for its license, and Inno Setup 7.1+.

```powershell
.\windows\build-package.ps1 `
  -EdgeRepositoryDirectory D:\work\mbed-edge `
  -BuildDirectory D:\work\mbed-edge\build\windows-x64 `
  -Version 0.21.1005 -OutputDirectory D:\packages\edge-core-1005 `
  -VisualCppRedistributable D:\tools\vc_redist.x64.exe `
  -OpenSSLSourceDirectory D:\sources\openssl-3.5.9

.\windows\build-installer.ps1 `
  -CorePackageDirectory D:\packages\edge-core-1005\edge-core-0.21.1005-windows-x64 `
  -MonitorRepositoryDirectory D:\work\edge-core-monitor `
  -InnoCompiler D:\tools\inno\ISCC.exe `
  -OutputDirectory D:\packages\izuma-edge-1005 -AllowUnsigned
```

The versions above are synthetic qualification versions. Unsigned output is
for qualification; production requires release signing. Tools/prerequisites
are supplied on the build host and included offline where appropriate. Target
machines need no compiler, Python, Git checkout or internet download to install.

See [setup and silent deployment](windows/installer/README.md),
[package/updater details](windows/README.md),
[all provisioning phases](windows/production-packaging-plan.md) and
[qualification](test/windows-core/README.md).

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
