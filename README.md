# Izuma Edge Windows installer

Native x64 Windows packaging and deployment for Izuma Edge Core and its optional
tray monitor. This repository owns package creation, WiX MSI and offline setup authoring,
restricted Windows service installation, upgrades/rollback, first file
provisioning and deployment qualification.

The application, Windows service adapter and OpenSSL/PAL implementation belong
in [mbed-edge](https://github.com/PelionIoT/mbed-edge). The monitor belongs in
[edge-core-monitor](https://github.com/IzumaNetworks/edge-core-monitor). This
installer consumes their compiled Release outputs; it does not copy their
source or embed any device identity.

## Build

For signed offline setup/MSI releases and GitHub artifacts, follow the
[MSI and Azure signing guide](windows/installer/MSI.md). It includes the Azure
OIDC setup for the `izumaedgesigning` account and certificate profile, the
embedded Visual C++ prerequisite, installer branding sizes, silent setup/MSI
options and `gh` release commands. Download `izuma-edge-VERSION-windows-x64-setup.exe`
for one installer launch that installs the runtime, Core, monitor and CLI offline.
`windows/build-release.ps1` runs the complete GitHub build, test, sign, setup/MSI and
artifact-download chain in one command; use `-PlanOnly` to inspect its inputs.

Local builds use 64-bit Windows PowerShell 5.1, WiX 6.0.2, a native Release
BYOC/OpenSSL build of Edge Core, the monitor and CLI Release executables, the
original Microsoft-signed x64 VC++ redistributable, and OpenSSL license source.
`windows/prepare-msi-bundle.ps1` stages the combined payload;
`windows/build-msi.ps1` authors the MSI, and `windows/build-setup.ps1` embeds the
MSI and runtime in the native WiX setup. Follow the signing order in the guide.
Only the MSI-based installation path is supported. Release workflows remain
manual (`workflow_dispatch`). Target machines need no compiler, Python, Git
checkout or internet download to install.

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
