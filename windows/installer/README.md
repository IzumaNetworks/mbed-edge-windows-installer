# Izuma Edge Windows setup

Use the signed `izuma-edge-VERSION-windows-x64-setup.exe` for a single offline
installation of the Microsoft x64 VC++ runtime, Edge Core, optional monitor and
required CLI. The native WiX bundle embeds our MSI and Microsoft's original
signed redistributable. [Build, signing, branding, upgrades and silent options](MSI.md)
are documented in the MSI guide.

Only this MSI-based deployment path is supported for new installations.
Upgrades retain device identity/state, monitor selection and settings, and the
Core service's running state. Failed upgrades restore the prior deployment;
downgrades are rejected. Uninstall retains private state for recovery.

## Developer and production file provisioning

On first installation, supply an external per-device CBOR/JSON provisioning
file and select `PROVISIONINGMODE=developer` or `production`. These choices
record intent and use the common OpenSSL/FCC/KCM importer. Actual production
FCU output, tenant CA setup and enrollment still require separate qualification.

```powershell
.\izuma-edge-VERSION-windows-x64-setup.exe /quiet /norestart /log install.log PROVISIONINGMODE=production 'PROVISIONING=D:\factory\machine-000123.cbor' STARTSERVICE=0
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
