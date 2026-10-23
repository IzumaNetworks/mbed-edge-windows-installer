# Self-hosted GitHub Actions runners

All jobs run only on self-hosted runners. No workflow uses a hosted runner or a
hosted fallback. Releases and requalification remain manual (`workflow_dispatch`).

## Runner pools

| Jobs | Required labels | Prerequisites |
| --- | --- | --- |
| Portable converter on Linux | `self-hosted`, `Linux`, `X64` | Git, Bash, CMake/CTest, a C compiler, OpenSSL 3 development headers and libraries |
| Portable converter on macOS | `self-hosted`, `macOS`, `ARM64` | Git, Bash, Xcode command-line tools, CMake/CTest, Homebrew `openssl@3` |
| MSI build and signing | `self-hosted`, `Windows`, `X64`, `edge-windows-build` | Visual Studio 2022 C++ tools and Windows SDK, CMake/CTest, Git, Perl, GitHub CLI, Azure CLI, Windows PowerShell 5.1 and .NET 8 installation support |
| Signed MSI lifecycle tests | `self-hosted`, `Windows`, `X64`, `edge-msi-disposable` | A fresh disposable Windows VM with administrator access, Visual Studio 2022 C++ tools and SDK, CMake/CTest, Git, GitHub CLI and Windows PowerShell 5.1 |

The workflow installs pinned WiX 6.0.2 and its extensions. The build pool must be
able to download dependencies, Actions artifacts and Azure signing packages.
Existing `windows-signing` environment settings, OIDC trust and repository read
secrets are still required. Linux/macOS qualification is preserved; macOS targets
the ARM64 architecture of the available self-hosted pool.

The build pool must be available to `IzumaNetworks/mbed-edge-windows-installer`.
The standalone Core workflow also needs build capacity available to
`PelionIoT/mbed-edge`; organization runners are not automatically shared across
these organizations. Use correctly scoped registrations or an enterprise runner
group with explicit access to both organizations.

Missing matching runners leave jobs queued. Do not substitute hosted runner
labels to unblock a build.

## Disposable Windows qualification image

The `qualify-msi` and standalone `qualify` jobs uninstall shared Visual C++
runtimes and install, repair and uninstall the real production MSI. They must
never run on a workstation, a persistent build/signing host or a machine with
an existing EdgeCore service or device identity.

Prepare a dedicated VM image, run its agent as administrator and apply only the
`edge-msi-disposable` role label. In an elevated image-preparation PowerShell:

```powershell
[Environment]::SetEnvironmentVariable('IZUMA_EDGE_MSI_DISPOSABLE','1','Machine')
```

The test reads this machine setting directly, checks `GITHUB_ACTIONS=true` and
`RUNNER_ENVIRONMENT=self-hosted`, and verifies that no EdgeCore service exists
before changing the system. A workflow-level `env` value cannot satisfy the
machine-setting guard. The marker is an explicit provisioning acknowledgement;
it does not prove that a VM will be discarded.

Provision a fresh VM for each qualification job, register its agent with
`--ephemeral`, export the workflow logs and destroy the VM afterward. Removing
an ephemeral runner registration alone does not reset its operating system.
Never assign both build and destructive qualification role labels to the same
persistent machine.

## Inventory

Use Settings > Actions > Runners in each repository to include organization
runners shared with the repository. A zero count from the repository REST
endpoint does not establish that shared organization capacity is absent.
Organization-wide REST inventory needs organization runner read permission
(`admin:org` with a classic token).
