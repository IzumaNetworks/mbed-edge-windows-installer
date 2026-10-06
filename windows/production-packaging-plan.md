# Izuma Edge production packaging plan

The production Windows installer must offer an optional **Edge Core Monitor**
component from the separate `edge-core-monitor` repository (`windows/`). The
component is **selected by default**. Operators can install Izuma Edge without
the monitor; EdgeCore's Windows service and cloud connectivity must work in
either configuration.

The signed x64 MSI is authored by `build-msi.ps1`; `prepare-msi-bundle.ps1`
stages the common payload. It installs Microsoft-signed VC++ runtime DLLs with
Edge Core in the protected application directory, so one MSI installs all
dependencies. No setup EXE or shared runtime installer is required. See the
[MSI deployment guide](installer/MSI.md). Runtime servicing is part of our releases.

Installer behavior:

- Interactive installation presents a checked **Install Edge Core Monitor**
  option.
- Silent/offline installation exposes the same choice to Intune, SCCM and
  PowerShell. Setup property: `INSTALLMONITOR=1` (default), or
  `INSTALLMONITOR=0` to omit it. Upgrades retain the previous selection.
- The offline release bundle includes the versioned monitor payload, so
  selecting the component does not require an internet download.
- The monitor runs under the signed-in user's normal identity in an interactive
  desktop session. Installation must not launch it in service session 0.
  Server Core/headless deployment can omit the component.
- A separate protected service-control policy defaults to administrators-only,
  while all users can inspect status. Setup property
  `MONITORUSERCONTROL=0` is the default; `MONITORUSERCONTROL=1` explicitly grants
  local interactive users Start/Stop. The installer must apply the monitor
  repository's policy tool to both HKLM policy and the EdgeCore service DACL,
  and install the action helper in a directory writable only by administrators.
- Installing the component and showing its tray icon are separate choices.
  Installed users retain independent tray-visibility and disconnect/recovery
  notification preferences. `MONITORSTARTUP=1` (default) starts the monitor
  under each user's normal account at sign-in; `0` disables sign-in startup.
- Upgrades preserve component selection and per-user preferences. Uninstall
  removes the monitor's binaries and its installer-owned integration while
  following the service's existing identity/data retention policy.

Qualification must cover default inclusion, explicit omission, silent/offline
Intune/SCCM/PowerShell deployment, upgrade with either selection, and service
operation with the monitor absent. Validate desktop and Server Core scenarios
separately. The single MSI now includes private runtime DLLs. The release workflow
qualifies runtime absence, repair and retained-state reinstall; inspect that run
for its result. MSI upgrade/rollback has separate qualification evidence.
Other Windows editions still need qualification.

## Provisioning phases

All provisioning flows are required. Keep a common, credential-free installer
and shared OpenSSL backend; reuse cloud-client FCC/KCM and PAL where applicable.
The first phase is external file provisioning, followed by factory-server
enrollment and Windows hardware-backed key support.

| Phase | Flow | Windows implementation/qualification |
| --- | --- | --- |
| 1 | Developer CBOR/JSON | Runtime importer and developer cloud connectivity tested; protected setup staging passed credential-free fixture qualification. |
| 1 | Production per-machine CBOR/JSON | Same importer and protected setup staging; real production FCU output, CA trust, enrollment/claiming and cloud bootstrap still require qualification. |
| 1 | Software install, provision later | Manual startup until an administrator/SYSTEM supplies the first bundle with `provision-service.ps1`; then delayed automatic startup. First-provisioning activation and identity-replacement rejection passed fixture qualification. |
| 2 | FCU/FCC/PEP factory-server enrollment | Port the factory client/transport and enrollment orchestration to native Windows; retain offline/local-factory operation and later cloud bootstrap. |
| 3 | Device-generated keys/TPM | Implement Windows TPM integration through appropriate platform/HAL interfaces; integrate CSR issuance, cloud key renewal and factory enrollment. Linux Parsec support is not Windows support. |

Developer/production selections record operator intent; they do not turn a
developer certificate into a production credential. No tenant key or device
identity is embedded in the common payload. Production qualification needs
actual per-device credentials and a production-capable test tenant. Verify FCU
file format compatibility instead of treating arbitrary `.bin` output as CBOR.
Device-generated keys require enrollment exchanges rather than the file-only
flow. See [Izuma factory injection documentation](https://developer2.izumanetworks.com/docs/device-management-provision/1.3/ft-demo/injecting-the-configuration-onto-the-device.html)
and [PEP provisioning](https://developer.izumanetworks.com/docs/device-management-edge/2.6/provisioning/index.html).

Identity replacement/factory reset must be a distinct, deliberate administrator
operation with cloud ownership implications. The first-phase command refuses
any existing provisioning argument, import journal or nonempty retained state.
It never uses `--reset-storage`. Interrupted first provisioning retains its
journal and staged input for administrator diagnosis; automatic recovery and
explicit reset remain follow-up work. Upgrades and ordinary uninstall continue
to retain identity. Golden images must be captured before provisioning; never
clone an imported identity or private state onto another machine.
