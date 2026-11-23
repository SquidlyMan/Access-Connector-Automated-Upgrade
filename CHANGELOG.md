# Changelog

Versions are those of `Invoke-AccessConnectorUpgrade.ps1` and `Invoke-ConnectorUpgradeLocal.ps1`, which are released together.

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
