# Post-install provisioning

The single MSI installs Core, the optional monitor, the command-line helpers,
and the app-local runtime. In full interactive UI it then opens the native
provisioning wizard before the MSI finish screen. It may request administrator
access to inspect private service identity storage. Canceling provisioning
does not undo the completed installation.

The wizard checks the installed service and its fixed private data directory:

* Existing bootstrap or operational certificate/key files and endpoint: tell
  the user the existing device identity was found and will continue to be used.
* A configured bundle or import journal: preserve it and report pending provisioning.
* Unknown retained state, unavailable storage, or a running unprovisioned
  service: preserve state and report that administrator attention is needed.
* Empty stopped service: offer production bundle (`.cbor` or `.json`), developer
  C credentials (any filename), or **Don't provision right now**.

Developer conversion calls the signed portable C `edge-provision` command.
No Python, C compiler, or scripting interpreter performs conversion. Temporary
converted credentials are written under an administrator-only directory and
removed after import. The existing first-provision service helper stages the
bundle with a service-specific ACL, rechecks stopped/empty state under its
exclusive provisioning lock, and starts the service. Cloud registration still
requires accepted credentials and connectivity.

Silent `/qn` and basic `/qb` installs do not run the wizard. They retain the
existing `PROVISIONING=<absolute bundle path>` and
`PROVISIONINGMODE=developer|production` properties. For a C credential file,
use `edge-provision convert-developer` to prepare CBOR first, or invoke the
installed wizard backend explicitly from an administrator process:

```
"C:\Program Files\Izuma\EdgeMsiHelpers\<version>\edge-provisioning-wizard.exe" --developer "C:\private\credentials.c"
"C:\Program Files\Izuma\EdgeMsiHelpers\<version>\edge-provisioning-wizard.exe" --production "C:\private\bundle.cbor"
```

Run the executable without arguments to revisit the wizard later. `--inspect`
is read-only, has no UI, and returns 0 (empty), 10 (identity files present),
11 (bundle configured), 12 (retained state needs attention), or 13 (unavailable).
Identity detection checks known ESFS file names; it does not authenticate
against the cloud or validate the contents of retained encrypted storage.
