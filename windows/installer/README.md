# Izuma Edge Windows setup

`build-installer.ps1` produces a native **x64 setup EXE** containing the Release
BYOC/OpenSSL EdgeCore service, its offline Visual C++ prerequisite, and the
separate native Edge Core Monitor. Nothing is downloaded on the target machine.
This is an Inno Setup installer; the command line below uses setup switches,
not `msiexec` properties.

The wizard requires administrator approval, offers the monitor as a **selected
optional component**, accepts an external CBOR or JSON provisioning file, and
offers monitor sign-in startup and service-control policy choices. Installation
does not run the GUI as administrator or in session 0. By default the monitor
starts as each user's normal account at the next sign-in. Users can also launch
**Edge Core** from the Start menu. Existing per-user tray and notification
preferences are preserved.

## Build

Use Windows PowerShell 5.1 and [Inno Setup 7.1+](https://jrsoftware.org/isdl.php)
on the build host. `InnoCompiler` points to `ISCC.exe`. The compiler can be
installed in portable mode on the build host; it is not a target prerequisite.
Build the core package with `windows/build-package.ps1`, then:

```powershell
.\windows\build-installer.ps1 `
  -CorePackageDirectory D:\packages\edge-core-0.21.1003-windows-x64 `
  -MonitorRepositoryDirectory D:\work\edge-core-monitor `
  -InnoCompiler D:\tools\inno\ISCC.exe `
  -OutputDirectory D:\packages\izuma-edge-0.21.1003 `
  -AllowUnsigned
```

Only the monitor Release executable, policy script, and license are included
from that repository. Both core and monitor are checked for native AMD64 PE
headers. The combined payload has a SHA-256/size manifest and Windows catalog;
the existing core package retains its independent manifest and catalog.
Credentials, source trees, tests and development executables are excluded.

`-AllowUnsigned` is an explicit **qualification build** choice. Without it,
the input core catalog must be signed by `-SignerThumbprint`, and a trusted
build-host `-SignToolCommand` is required to sign the combined catalog, setup
and uninstaller. The command uses Inno's literal `$f` file placeholder. Release
signing is not qualified yet because no release signing certificate is available.
Unsigned installers must be delivered using independently trusted content
hashes; their internal catalog checks establish integrity, not publisher trust.

## Silent installation

Run as administrator or SYSTEM from Intune, SCCM or 64-bit PowerShell. Standard
[Inno silent options](https://jrsoftware.org/ishelp/topic_setupcmdline.htm) apply.
The installer itself never restarts Windows and returns **3010** if the bundled
VC++ prerequisite requests a reboot. Other setup failures return nonzero codes.

```powershell
# Offline factory installation, no credentials and no initial service start.
.\izuma-edge-0.21.1003-windows-x64.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /STARTSERVICE=0

# Server Core/headless installation with no monitor.
.\izuma-edge-0.21.1003-windows-x64.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /INSTALLMONITOR=0 /STARTSERVICE=0

# Provision and start with an external bundle. JSON DER sidecars stay adjacent
# to the supplied JSON until import; they are copied to protected service config.
.\izuma-edge-0.21.1003-windows-x64.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART '/PROVISIONING=D:\factory\device.cbor' /STARTSERVICE=1
```

| Switch | Fresh installation default | Meaning |
| --- | --- | --- |
| `/INSTALLMONITOR=0` or `1` | `1` | Omit or install monitor |
| `/MONITORUSERCONTROL=0` or `1` | `0` | Administrators only, or explicitly allow interactive local users Start/Stop |
| `/MONITORSTARTUP=0` or `1` | `1` | Monitor starts at user sign-in |
| `/STARTSERVICE=0` or `1` | `0`, or `1` when `/PROVISIONING` is supplied | Start after installation; upgrade preserves current running/stopped state |
| `/PROVISIONING=<absolute file>` | blank | External CBOR/JSON input on fresh install; prohibited during upgrades |
| `/PROVISIONINGMODE=auto`, `developer`, `production`, `deferred` | `auto` | Auto selects developer when a file is supplied, otherwise deferred; production requires an explicit selection and file |

Fresh installation without credentials or retained state configures **manual
startup**, so an ordinary reboot does not start an unprovisioned client. After
file provisioning, startup is **delayed automatic**. The native service uses restricted LocalService and the existing
private data ACLs. Standard users can query status; the optional Start/Stop grant
updates both the protected HKLM policy and SCM DACL. Deselecting the monitor
revokes that grant. Service-control policy replaces custom SCM permission grants.

## Developer and production file provisioning

The wizard offers developer file provisioning, production file provisioning,
and retaining identity/provisioning later. Both file choices use the same
BYOC/OpenSSL runtime and FCC/KCM importer. The mode records operator intent;
setup cannot certify that a supplied certificate is suitable for production.
Developer cloud registration was tested previously; actual production credentials,
FCU output compatibility, tenant CA setup and claiming still need qualification.

Example production file installation:

```powershell
.\izuma-edge-0.21.1005-windows-x64.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /PROVISIONINGMODE=production '/PROVISIONING=D:\factory\machine-000123.cbor' /STARTSERVICE=0
```

Supply a unique factory-issued bundle for each machine. Setup stages it under
`%ProgramData%\Izuma\EdgeCore\config\bundle-<GUID>` with access for administrators,
SYSTEM and the restricted EdgeCore service SID. JSON uses scheme `0.0.1` and
local DER sidecars; setup copies and rewrites those references. Optional JSON
`RoTFilePath` is copied and rewritten to a protected absolute path. CBOR is
copied unchanged: any embedded external file references must already point to
valid protected locations on the target. The existing FCC runtime validates
bundle semantics and credentials when it starts; staging alone is not validation
of a certificate/key pair or successful cloud enrollment. CBOR is limited to
16 MiB and JSON to 1 MiB. No credential values are printed.

For software installed without an identity, run the installed first-provisioning
command as administrator or SYSTEM:

```powershell
& 'C:\Program Files\Izuma\EdgeSetup\scripts\provision-service.ps1' `
  -ProvisioningFile D:\factory\machine-000123.cbor -ProvisioningMode production
# For developer credentials, use -ProvisioningMode developer instead.
Start-Service EdgeCore
Get-Service EdgeCore
```

The Edge Core Monitor reads local status through the Windows named pipe.
The TCP `/status` endpoint is disabled by default. For a scripted new install,
pass `-EnableTcpStatus` to `install-package.ps1`; this writes a protected runtime
JSON with `"status": {"tcpEnabled": true}`. An installed service can opt in by
adding the same setting to its protected runtime JSON and using `--config`.
Installer readiness and cloud qualification also use the status pipe.

This command requires a stopped, owned service and empty private state. It
refuses existing CBOR/JSON arguments, any import journal, and any retained state,
including unsuccessful earlier client initialization. It does not reset identity.
The command securely stages the bundle, journals activation, adds the runtime
argument and enables delayed automatic startup. Omit `-Start` to stage entirely
offline; add `-Start` for bounded local readiness, which does not guarantee cloud
connectivity. Bootstrap connects to the cloud when outbound connectivity is
available. An interrupted or failed start retains input/state and its journal;
do not delete retained state to make this command accept a second bundle.

Factory-server enrollment and Windows TPM/device-generated keys are subsequent
phases in the [production plan](../production-packaging-plan.md). Never clone
provisioned state into a Windows golden image. Ordinary upgrades and uninstall
retain the identity; deliberate reprovision/reset is a separate future operation.

## Upgrade, detection and uninstall

Rerun a newer setup EXE without `/PROVISIONING`. It retains device state, service
arguments, running/stopped state, monitor component choice and monitor options.
Same-version maintenance can change monitor selection and policy if the payload
hashes still match. Downgrades are rejected. An earlier script-installed EdgeCore
can be adopted if its ownership markers, version and active command match the
expected protected directories. Monitor selection defaults to enabled on adoption.
When the monitor is deselected during maintenance, its sign-in/Start menu
integration is removed and user service-control rights are revoked. Previously
staged monitor releases remain until full uninstall, allowing rollback.

Setup registers **Izuma Edge** in Windows Apps/Programs and Features. Intune/SCCM
can detect the x64 uninstall key
`HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Izuma.Edge.Windows_is1`
and its `DisplayVersion`. Component-aware detection can read
`C:\Program Files\Izuma\EdgeSetup\deployment.json` (`installMonitor`,
`monitorStartup`, `monitorUserControl`, `version`) without reading device secrets.
Logs are `deployment.log` in that directory and the setup `/LOG=<file>` output.

Silent removal:

```powershell
& 'C:\Program Files\Izuma\EdgeSetup\unins000.exe' /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
```

Removal stops and unregisters the owned service and removes monitor integration,
policy, installer-owned monitor binaries and maintenance scripts. Core releases,
private provisioning, state and logs are retained. Per-user preferences and the
monitor's own per-user notification shortcut are retained. Reinstallation stages
new core binaries rather than overwriting retained releases. Close a running
monitor before uninstall; setup does not force-terminate user processes.

The service updater keeps its existing durable journal and rollback behavior.
The combined deployment adds a protected journal and restores service activation,
SCM policy and prior monitor integration when its apply operation fails. An
interrupted deployment must be inspected and rolled back by an administrator
using `scripts/deploy.ps1 -RequestFile <app>\deployment-request.json -Action Rollback`
before retrying; no automatic power-loss recovery is claimed.

## Qualification

`test/windows-core/test-installer-bundle.ps1` checks valid payloads, unsigned
production rejection and tampering. `test/windows-core/test-installer.ps1`
accepts two setups built with the same `-QualificationId <GUID>` and increasing
versions. Their AppId, service and protected directories are isolated from the
real EdgeCore install. It tests silent offline factory install, default monitor
inclusion, explicit omission, permissions, preserved selections, upgrade,
downgrade rejection, combined service/monitor rollback after a staging failure,
uninstall and retained state. No credentials/cloud are used.

Before repository extraction and the first-file provisioning changes, the 25 deployment checks passed on Windows 10 Pro 22H2 x64 (19045.6466) on
October 2, 2026. Evidence: `build/windows-installer-qualification-results-7/results.json`.
This includes an actual activated-core rollback after monitor staging failure,
not just preflight rejection. The factory service's initial SCM exit code was
1077 (never started); upgrade succeeded while retaining its stopped state.
All GUID services and monitor policy keys were removed. After qualification,
the existing EdgeCore was still running its original release in the same
process and its status endpoint reported connected.

This first installer still needs signed-release validation, clean-image VC++
prerequisite installation/reboot-return qualification, actual Intune/SCCM
deployment, interactive wizard QA, Windows 11/Server/Desktop/Core qualification,
running-monitor upgrade/uninstall handling and interrupted-upgrade recovery.

`test/windows-core/test-provisioning.ps1` in this installer repository qualifies file handoff with a GUID
installer. Its fixtures contain no real credentials, and it never starts the
service. It checks developer CBOR, production JSON/DER/RoT staging, ACLs, deferred
installation, first provisioning, automatic startup configuration and rejection
of identity replacement. These staging checks do not qualify production cloud
enrollment.


The extracted repository and first-file provisioning changes passed
qualification on Windows 10 Pro 22H2 x64 (19045.6466) on October 2, 2026.
Native setup builds, 12 credential-free input checks, 6 combined-bundle integrity
checks and 7 package integrity checks passed. Evidence is under this
repository's build/provisioning-input-1, build/bundle-qualification-final and
build/package-qualification-final.

The administrator run of test-release.ps1 passed all 23 provisioning checks
and 25 installer lifecycle checks against setup versions 0.21.1005 and
0.21.1006. Evidence is in build/release-qualification-1/results.json and its
provisioning and installer subdirectories. This includes protected CBOR and
JSON/DER/RoT staging, deferred first provisioning, prevention of identity
replacement, optional monitor installation, service-control permissions,
upgrade, activated-core rollback, downgrade rejection and uninstall.
The temporary service and monitor policy were removed; credential-free fixture
data is retained. The existing EdgeCore service kept its original
process/configuration and remained connected. The provisioning fixtures were
never started and do not qualify production cloud enrollment.

The unsigned ordinary installer is under build/izuma-edge-0.21.1006.
