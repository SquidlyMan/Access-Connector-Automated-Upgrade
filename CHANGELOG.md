# Changelog

Versions are those of `Invoke-AccessConnectorUpgrade.ps1` and `Invoke-ConnectorUpgradeLocal.ps1`, which are released together.

## 1.4.1 - 2026-11-22

- **A dry run always runs the pre-flight checks.** Before, on a connector already on the installer's version, the wrapper decided to skip before its checks and the dry run reported `DryRunPassed` without testing any password. Now the PFX, configuration file and service account checks run every time.
- The dry run says what a real run would do: a connector a real run would skip gets `DryRunPassed` with the note "A real run would SKIP this connector..." on screen, in the summary and in the CSV message; one a real run would refuse (installed version newer than the installer) gets `DryRunFailed` with the reason, after the checks.
- Help text of the orchestrator (`-DryRun`) and the wrapper updated to match.

## 1.4.0 - 2026-11-22

- **Installer settings through the fleet file** (issue 2): `InstallDir`, `EnableFips`, `DirectorySyncPort`, `UserAuthPort`, `KerberosAuthPort`, `VirtualAppPort`, `ProxyHost`, `ProxyPort`, `ProxyUser` and `NonProxyHosts` per fleet entry, passed to the wrapper through `job.json`. When `ProxyUser` is set the proxy password is asked at run time with the others and handed over like them (standard input, WinRM parameter, protected task file, `-Prompt`, `-Schedule`).
- The settings are checked before any connector is contacted (port numbers, duplicate ports, a full Windows path for `InstallDir`, proxy settings without `ProxyHost`, spaces or quotes) and shown in the plan. An unknown setting in a fleet entry is named in a note, so a misspelling is not dropped silently.
- The helper refuses (`Blocked`) a job whose FIPS setting differs from the installed connector's, because FIPS mode cannot be changed after install. It warns when `InstallDir` names a different folder than the one the connector is in.
- The helper finds a connector installed outside `C:\Program Files` from the installer record, the job or the service paths.
- The helper reads four secret lines on standard input instead of three (configuration, PFX, service account, proxy). Both scripts are released together, and the orchestrator copies the helper on every run.
- `Install-AccessConnector.ps1`: the served-certificate check now reads the certificate with a TLS handshake of its own, so it works under Windows PowerShell 5.1 (before, it silently never compared). After an upgrade a mismatch is a warning, because the vendor installer never carries the PFX through an upgrade; after a fresh install it is an error.
- `Install-AccessConnector.ps1`: the keytab-log check judges only what `setupKerberos.ps1` added to `krb5-setup.log` during this run, and the newest `RESULT` line (before, it read the first `RESULT` line of the whole log and any old `Password set failed`). It also turns on TLS 1.2 for its health checks, refuses a proxy password containing a double quote, and drops a trailing backslash from `-InstallDir`.
- The orchestrator checks for PowerShell 7 before anything else, `-Help` included, and says how to start it with `pwsh`.
- MIT licence (`LICENSE`); the help's ABOUT section says so.

## 1.3.1 - 2026-11-22

Help text only. No change to what the scripts do.

- Help, examples and comments no longer name a connector version, a lab or lab tenants. Examples use `TENANT1`, `TENANT2`, `connector.example.local` and `~/.ssh/connector_ed25519`.
- Synopsis now says the version installed is that of the installer named in the fleet file, and that the Java4Shell patch runs only when the fleet file names its folder.
- `Install-AccessConnector.ps1`: two example lines changed to example names.
- New generic `fleet.example.psd1` for the current fleet-file layout.
- First release in this repository, with full documentation.
- Documentation: how to choose services for a single connector or a group of connectors (one fleet entry per connector group).

## 1.3.0 - 2026-11-22

- New `-Mode RepairCertificate` (helper: `-RepairCertificate -CertFile -Reapply`): puts the PFX certificate on the Kerberos Auth service with the vendor maintenance script, after copying the service configuration, and puts the copy back if the result is not right. Asks for the PFX password only.
- Upgrades of Kerberos Auth connectors now end by checking the certificate served and putting the PFX certificate back. The vendor installer does not carry it through an upgrade.
- `-Mode Verify` shows the certificate served and marks a self-signed, misnamed, expired or unreadable one.
- The final health check fails if the Kerberos Auth service serves anything other than the PFX certificate.
- Interrupted certificate changes are detected through a marker file.

## 1.2.3 - 2026-11-22

Screen output and messages only.

- Lines wrapped to 78 columns with hanging indents; blank lines around framed blocks; dates dropped from relayed timestamps.
- Summary grouped by tenant; state shown as `services 4/4 up`.
- "Files missing" error names another copy of the staging folder that has the files, with the `cd` command. Needs `StagingFolders` in the fleet file.
- The temporary `job.json` is written in a folder of its own, so two sessions staging at once cannot collide.

## 1.2.2 - 2026-11-22

- The vendor installer's MSI log is cleaned of recorded passwords after every install, on the connector and in copies brought back.
- After a failed install, services that were running before are started again and, when the Kerberos set-up did not run, the keytab copy is put back.
- The helper refuses to start when the server's PowerShell module-logging policy would record passwords.
- SSH's own error messages are shown in red.

## 1.2.1 - 2026-11-21

- `RepairKeytab` skips connectors whose keytab already holds keys, judges success by the vendor exit code and log rather than size alone, and always works one connector at a time.
- A failed dry run stops that tenant's other connectors.
- The staging folder on the connector is locked to Administrators and SYSTEM when created.

## 1.2.0 - 2026-11-21

- Kerberos Auth connectors: the upgrade runs on the connector as a one-time scheduled task under a domain admin account, so the keytab can be rebuilt without anyone signing in to the server. The task removes itself.
- New `-Mode RepairKeytab`.
- New `-RunAsCredential` and `-SkipDomainCheck`.
- `Install-AccessConnector.ps1`: a keytab under 32 bytes counts as not present.

## 1.1.0 - 2026-11-21

- Colour scheme for prompts, information, warnings and errors.
- The helper refuses to upgrade a Kerberos Auth connector from a sign-in that cannot query Active Directory.
- A keytab under 32 bytes makes the result `Unhealthy`; Verify shows `keytab EMPTY`.
- WinRM mode asks for its credential with the tool's own prompt.

## 1.0.x - 2026-11-21

- First version: `SSH`, `WinRM`, `Stage` and `Verify` modes; one connector at a time per tenant with a health gate; Java4Shell patch step; summary CSV and logs copied back.
- `-Parallel` and `-ParallelTenants`.
- Fleet file chosen by `-FleetConfig`, `-Fleet`, computer name, domain name or default.
- The installer copy is skipped when a file with the same SHA-256 hash is already on the connector.
- Services already stopped before the run are noted and the run continues.

## Earlier

- `Silent Install/Install-AccessConnector.ps1` (July 2026): the single-server silent install wrapper the fleet tool is built on.
- `legacy/Update-AccessConnectorFleet.ps1` (July 2026): the earlier WinRM-only fleet updater.
