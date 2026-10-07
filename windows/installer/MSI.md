# Self-contained MSI release and Azure signing

`windows/build-msi.ps1` packages the existing service deployment into a native
x64, per-machine WiX MSI. The tray monitor is optional and selected by default;
`izuma-edge-ctl.exe` and the portable native `edge-provision.exe` converter are
always installed. In full desktop UI, a post-install wizard reports an existing
identity or offers production bundle selection, developer C credential file
selection, and **Don't provision right now**. The selected tray monitor then
starts in the desktop user's session without elevation. Silent and basic-UI
installs launch neither the wizard nor the monitor. When the HTTP status listener
is disabled, startup and shortcut commands omit the HTTP port override; monitor
status continues to use the trusted named pipe. Software-only installation leaves
EdgeCore stopped until device provisioning is supplied. A fresh desktop install
with a retained identity starts Core automatically and reports that it is reused.

Download and launch **`izuma-edge-VERSION-windows-x64.msi`**. This one signed MSI
contains Edge Core, the optional monitor, required CLI and unmodified
Microsoft-signed x64 Visual C++ runtime DLLs. It installs the runtime beside
Edge Core in its protected versioned release directory. No shared VC++ runtime
installation, external setup EXE, nested installer or network download is needed.
Windows 10 and later provide the Universal CRT as an operating-system component.

This uses [Microsoft's app-local runtime deployment](https://learn.microsoft.com/en-us/cpp/windows/choosing-a-deployment-method).
Runtime DLLs retain their Microsoft signatures and are covered by our signed
package catalogs. We must ship updated runtime DLLs in subsequent releases when
Microsoft supplies security fixes; Windows Update does not service private copies.
Redistributable files remain subject to the Visual Studio redistribution terms.

```powershell
msiexec /i izuma-edge-VERSION-windows-x64.msi /qn /norestart /l*v install.log INSTALLMONITOR=0
# Exit codes 0 and 3010 indicate success; 3010 means a reboot is required.
```

For desktop installation, open the MSI normally and choose the tray monitor in
the feature tree. Silent options are `INSTALLMONITOR`, `MONITORUSERCONTROL`,
`MONITORSTARTUP`, and `STARTSERVICE`, each `0` or `1`. Defaults are monitor on,
standard-user control off, monitor startup on, and service stopped. Upgrades and
repairs preserve existing control and monitor startup choices unless an option
is explicitly supplied, and preserve the service's running state. `STARTSERVICE`
controls first installation; explicit `STARTSERVICE=0` also suppresses startup
in the desktop wizard. The monitor feature selection also survives upgrades.

Optional first-install provisioning uses `PROVISIONING="C:\path\device.cbor"`
and `PROVISIONINGMODE=developer` or `production`; the default is `deferred` with
no provisioning file. Inputs are data, never shell command fragments. Credentials
are never embedded in the MSI or GitHub artifact. Silent and basic-UI installs
skip the wizard. See [the provisioning flow and headless commands](msi/README.md)
for developer file conversion, later provisioning, and retained-identity behavior.

## Installer branding

The build requires these PNG files in `windows/installer/`, or an explicit
`-BrandingDirectory`. It validates dimensions and embeds the original files.
Welcome and finish use separate artwork. PSD source files remain in the repository
and are not embedded in the MSI. Branding template ZIPs are no longer release assets.

| File | Size | Use |
| --- | --- | --- |
| `banner.png` | 493 x 58 pixels | Banner on interior MSI dialogs |
| `welcome.png` | 493 x 312 pixels | Welcome and maintenance background |
| `finish.png` | 493 x 312 pixels | Successful completion background |
| `installer.ico` (optional) | Include 16, 32, 48 and 256 pixel images | Installer/Programs and Features icon |

Export backgrounds as opaque PNGs with white text areas. See the
[WiX UI graphics specification](https://docs.firegiant.com/wix/tools/wixext/wixui/).
The existing welcome, finish and banner template PNG sizes remain applicable.

Major upgrades deploy the new service release before removing the old MSI
payload. A failure rolls back the service path, deployment record and integration.
Downgrades are rejected. Uninstall removes the service, shortcut, startup entry
and command-line PATH integration while retaining device state, logs and core
releases for recovery. New deployments use this MSI-based installer; subsequent
versions use the same upgrade family. Installations without MSI ownership are
not adopted automatically.

## One-time Azure and GitHub configuration

The confirmed Azure account and Public Trust certificate profile are both
`izumaedgesigning`, in East US (`https://eus.codesigning.azure.net/`). The issued
leaf certificate's thumbprint and serial are diagnostic values. Artifact Signing
rotates its leaf certificates, so the workflows use the profile name and verify
the publisher subject and timestamp. Catalog thumbprints are obtained from each
release and embedded separately for its core and bundle catalogs.

1. In Microsoft Entra ID, create an App registration, for example
   `izuma-edge-github-signing`, for this tenant. Record its **Application (client)
   ID**, **Directory (tenant) ID**, and the subscription ID containing the signing
   account. No client secret or downloadable private key is needed.
2. Read each repository's current GitHub identity prefix:

   ```powershell
   gh api repos/OWNER/REPOSITORY/actions/oidc/customization/sub --jq .sub_claim_prefix
   ```

   Append `:environment:windows-signing` to that exact prefix. In the app's
   **Certificates & secrets > Federated credentials > Add credential**, choose
   **Other issuer** and enter the issuer, subject and audience below. Create one
   credential for each repository. These are the verified current subjects:

   | Organization | Repository | Environment | Subject |
   | --- | --- | --- | --- |
   | PelionIoT | mbed-edge | windows-signing | `repo:PelionIoT/mbed-edge:environment:windows-signing` |
   | IzumaNetworks | mbed-edge-windows-installer | windows-signing | `repo:IzumaNetworks@109173172/mbed-edge-windows-installer@1402134158:environment:windows-signing` |

   Issuer: `https://token.actions.githubusercontent.com`; audience:
   `api://AzureADTokenExchange`.

   GitHub's [immutable subject format](https://docs.github.com/en/actions/reference/security/oidc#immutable-subject-claims)
   includes owner and repository IDs for newer repositories. Azure must match
   the exact subject GitHub issues, including these IDs when present. Check the
   prefix again if a repository is renamed or transferred.
3. On the Artifact Signing account, open **Access control (IAM) > Add role
   assignment**, choose **Artifact Signing Certificate Profile Signer**, and
   select the app's service principal. This signing role is separate from the
   Identity Verifier role used for identity validation. To restrict it to this
   certificate profile, an administrator can use:

   ```powershell
   az role assignment create --assignee-object-id SERVICE_PRINCIPAL_OBJECT_ID --assignee-principal-type ServicePrincipal --role "Artifact Signing Certificate Profile Signer" --scope "/subscriptions/SUBSCRIPTION_ID/resourceGroups/IzumaEdge/providers/Microsoft.CodeSigning/codeSigningAccounts/izumaedgesigning/certificateProfiles/izumaedgesigning"
   ```

4. In **both** GitHub repositories, create the `windows-signing` environment
   before running either workflow. Configure permitted release branches and
   required reviewers as supported by the organization's GitHub plan. Azure's
   environment credential trusts this environment, so its protections control
   which source may receive the organization's signature.
5. Add these environment variables in both repositories:

   | Variable | Value |
   | --- | --- |
   | `AZURE_CLIENT_ID` | Application (client) ID |
   | `AZURE_TENANT_ID` | Directory (tenant) ID |
   | `AZURE_SUBSCRIPTION_ID` | Subscription ID |
   | `AZURE_SIGNING_ACCOUNT` | `izumaedgesigning` |
   | `AZURE_SIGNING_PROFILE` | `izumaedgesigning` |
   | `AZURE_SIGNING_ENDPOINT` | `https://eus.codesigning.azure.net/` |
   | `AZURE_SIGNER_SUBJECT` | Exact X.509 Subject of the validated Public Trust publisher |

   The subject must include the full distinguished name, rather than just the
   company display name. Download the public certificate from the profile and
   inspect its Subject, or read it from a successfully signed test file:
   `(Get-AuthenticodeSignature .\signed-test.exe).SignerCertificate.Subject`.
   These IDs and settings are configuration, not private credentials. `gh` can
   set an environment variable with `gh variable set NAME --env windows-signing
   --repo OWNER/REPO --body VALUE`.
6. In the installer repository's Actions repository secrets, or its
   `windows-signing` environment secrets, add these GitHub
   secrets, directly in GitHub rather than in source or chat:

   | Secret | Access |
   | --- | --- |
   | `CROSS_REPO_READ_TOKEN` | Fine-grained token with Contents read for private `IzumaNetworks/edge-core-monitor` |
   | `CORE_ARTIFACT_READ_TOKEN` | Fine-grained token with Actions read for `PelionIoT/mbed-edge` |

   Use separate tokens because the repositories belong to different organization
   resource owners. `CORE_ARTIFACT_READ_TOKEN` is needed when downloading a
   separate Core workflow artifact. The installer's `GITHUB_TOKEN` is scoped to its own repository
   and cannot authorize the cross-repository artifact download. These tokens are
   unrelated to Azure signing. GitHub documents the
   [artifact download permission](https://docs.github.com/en/rest/actions/artifacts#download-an-artifact).

Microsoft documents the [signing role and profile scope](https://learn.microsoft.com/en-us/azure/artifact-signing/tutorial-assign-roles)
and [GitHub OIDC connection](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect).

## Release workflow

`windows/build-release.ps1` is the single entry point for the complete build.
It waits for the workflows to succeed and downloads the final signed artifacts.
Use `-BuildCoreInInstaller` to build everything in the installer's single manual
workflow. Builds and signing run on GitHub's Windows runners;
your local machine needs an authenticated `gh` CLI and Windows PowerShell 5.1+.

```powershell
.\windows\build-release.ps1 -Version RELEASE_VERSION -CoreRef CORE_RELEASE_BRANCH -InstallerRef INSTALLER_RELEASE_BRANCH -MonitorRef MONITOR_COMMIT -BuildCoreInInstaller -OutputDirectory C:\releases\izuma-edge-RELEASE_VERSION
```

Add `-PlanOnly` to inspect the inputs without starting builds. Core and installer
refs are published branches or tags; the monitor ref can also be a commit.
The full build mode does not require the separate Core workflow
to be registered. In the Actions UI, leave `core_run_id` empty and supply
`core_ref`, `version`, and `monitor_ref` for the same full build.
Omit `-BuildCoreInInstaller` to run the registered Core and installer workflows
in order instead.
The command builds/tests Edge Core and its dependencies, signs Core and its DLLs,
builds/tests and signs the monitor and CLI, signs catalogs and the MSI custom
action, creates/signs the installer, and downloads the resulting release. Azure
OIDC configuration above must be complete. Workflow files must first be present
on the repositories' default branches so GitHub registers their dispatch events.
The selected release refs must contain the matching workflow and helper changes.
The full installer workflow checks Azure login and verifies a signed temporary
catalog before compilation. It caches the pinned OpenSSL SDK by compiler version
and build-script hash immediately after the SDK builds.

Each invocation has a unique identifier in its run titles, so simultaneous
releases cannot select one another's runs. If either workflow fails, the command
stops and retains `release-runs.json` with the run IDs and error. A failed Core
workflow never triggers MSI signing. Actions upload the artifacts automatically;
this command does not create a GitHub Release.

First commit and publish the workflow changes to reviewed release branches.
Run `.github/workflows/windows-release.yml` in `PelionIoT/mbed-edge`, with a
three-part release version within MSI limits (`255.255.65535`). It builds a pinned
OpenSSL SDK, builds/tests Edge Core, signs the five runtime EXE/DLL files, verifies
their publisher and timestamps, and uploads `edge-core-windows-x64-signed`.
Its intermediate artifact is explicitly named `windows-runtime-unsigned`.

Run `.github/workflows/windows-msi.yml` in this repository with the successful
core workflow's run ID and a reviewed monitor commit or tag. It downloads the
signed runtime using `gh`, verifies source provenance, builds/tests and signs
the monitor and CLI, signs both catalogs, signs the native custom-action DLL,
compiles/signs the self-contained MSI with its private runtime DLLs.
Signature and embedded-payload verification must pass before the final
`izuma-edge-windows-x64-signed` artifact is uploaded. That artifact contains:

- Signed MSI and standalone signed `edge-core.exe`, `edge-core-monitor.exe` and
  `izuma-edge-ctl.exe`.
- Signed core package ZIP with its catalog and runtime dependencies.
- Original Microsoft-signed VC++ runtime DLLs inside the MSI and Core package.
- Signature report, source commits and SHA-256 checksums.

Example commands after those branches are published:

```powershell
gh workflow run windows-release.yml --repo PelionIoT/mbed-edge --ref CORE_RELEASE_BRANCH -f version=RELEASE_VERSION
gh run list --repo PelionIoT/mbed-edge --workflow windows-release.yml
gh run watch CORE_RUN_ID --repo PelionIoT/mbed-edge --exit-status
gh workflow run windows-msi.yml --repo IzumaNetworks/mbed-edge-windows-installer --ref INSTALLER_RELEASE_BRANCH -f core_run_id=CORE_RUN_ID -f monitor_ref=MONITOR_COMMIT
gh run watch MSI_RUN_ID --repo IzumaNetworks/mbed-edge-windows-installer --exit-status
gh run download MSI_RUN_ID --repo IzumaNetworks/mbed-edge-windows-installer --name izuma-edge-windows-x64-signed --dir release
```

Actions uploads use `actions/upload-artifact`; `gh` triggers, watches and downloads
those runs. For a GitHub Release asset, use `gh release upload EXISTING_TAG
release\*.msi release\edge-core.exe --repo OWNER/REPO` after verifying the results.

## Local build and qualification

Build the core package and the monitor with the existing helpers. Prepare the
bundle using `windows/prepare-msi-bundle.ps1`; sign `core/package.cat`
before preparing that bundle, then sign `bundle.cat`. Prepare the MSI with
`windows/build-msi.ps1 -PrepareOnly`, sign the DLL reported in `msi-result.json`,
compile the generated WiX source with WiX/UI extension 6.0.2, and sign the final
MSI.
The workflow expresses this exact signing order. Signing a catalog or
executable after hashing it into a bundle invalidates the bundle.

Build the Core package with `-VisualCppDeployment app-local` for MSI delivery.
For credential-free qualification, use `-AllowUnsigned` on bundle preparation,
and `-AllowUnsigned -QualificationId GUID` on MSI preparation. The GUID is
mandatory for unsigned MSIs; it separates service names, installation roots,
product names and upgrade families from production. Build two increasing
versions with the same GUID, then run elevated:

```powershell
.\test\windows-core\test-msi.ps1 -InitialResult C:\qualification\initial\msi-result.json -UpgradeResult C:\qualification\upgrade\msi-result.json -OutputDirectory C:\qualification\results
```

The test covers option rejection, headless installation, restricted LocalService,
CLI inclusion, failure after core activation with rollback, major upgrade,
downgrade rejection, uninstall and retained state. It never starts a credentialed
core service. It creates an isolated qualification service and removes it at the
end; MSI logs and the retained test state support diagnosis.

Local qualification on Windows 10 Pro x64 passed all 17 MSI checks using versions
`0.21.1022` and `0.21.1023` on October 5, 2026. This included failure after core
activation, restoration of the previous MSI ownership record, upgrade, downgrade
rejection, and successful uninstall with retained state. Both the prototype and
final qualification services were removed. This was an unsigned, credential-free
lifecycle test; a real Azure signing run and additional Windows editions remain
to be qualified. The release orchestration's credential-free checks also passed,
including concurrent-run correlation and stopping before MSI dispatch when Core
fails.
