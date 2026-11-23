# Validation Record

What has been proven by a real run, and what has been built but not yet proven. Last updated 2026-11-22 (version 1.4.0).

"Proven" means the path ran for real against a connector and the result was checked independently afterwards (services, health pages, version, keytab, served certificate, logs), not just that the tool reported success.

## Test environment

- Ten connectors on Windows Server, in two Active Directory forests with no trust between them.
- Four Access tenants: three cloud tenants and one on-premises tenant.
- Admin machines: a Mac (SSH modes) and a Windows host (WinRM mode).
- Connector versions involved: 24.12.0.0, 26.05.0.0 and 26.10.0.0.
- Connectors with all four services including Kerberos Auth, and connectors with three services (no Kerberos Auth).

Server and tenant names are left out of this record on purpose.

## Proven

| Path | Runs | Result |
|---|---|---|
| Upgrade 24.12.0.0 to 26.10.0.0, three services, **WinRM mode**, one at a time | 3 connectors | Success; services running; patch flag on every Java process; about ten minutes each |
| Upgrade 26.05.0.0 to 26.10.0.0, four services with Kerberos Auth, **SSH mode through the scheduled task** under a domain admin | 2 connectors | Success; usable keytab straight after the install; installer logs cleaned |
| Upgrade 26.05.0.0 to 26.10.0.0, four services, **Stage mode** then `Run-Upgrade.cmd` signed in as a domain admin | 1 connector | Success; usable keytab |
| Upgrade 26.05.0.0 to 26.10.0.0, four services, **SSH mode as a local administrator** (before the scheduled-task route existed) | 2 connectors | Upgraded, but left an empty keytab. This is the failure the scheduled-task route and the keytab check were built to prevent. Repaired with `RepairKeytab`. |
| **Clean install** of 26.10.0.0 on servers with no connector, SSH mode | 2 connectors | Installed and running. They were installed with Kerberos Auth from a local-administrator sign-in, before the scheduled-task route existed, so they too had empty keytabs until repaired. |
| **Forced reinstall** at the same version (uninstall, then fresh install), three services, SSH mode. Also used to remove Kerberos Auth by changing `Services`. | 2 connectors | Success; Kerberos Auth service, folder and installer feature gone; other three services healthy; saved settings intact |
| `-Mode RepairKeytab` through the scheduled task under a domain admin | 4 connectors | Usable keytabs written; on two servers the vendor script created the Active Directory account, on two it reset an existing one |
| `-Mode RepairCertificate` | 5 production-role connectors, plus one sandbox test | Each serves the PFX certificate; health `true`; service accounts, keytab and other settings unchanged |
| Certificate put-back routine (restore of the copied configuration) | 1 sandbox test | Original configuration restored in about half a minute; original certificate served again |
| `-Mode Verify` | All ten connectors, many times | Matches independent checks |
| `-DryRun` for upgrades, keytab repair and certificate repair | Many | Catches wrong passwords and missing files with nothing changed |
| A wrong domain admin password | Observed | Fails when the task is started; nothing changed |
| Installer-log cleaning | Every upgrade since it was added | No encoded password left on the connectors or in the copies brought back |
| Missing-files message naming the other copy of the staging folder | Observed | Correct folder and `cd` command shown |
| Fleet file chosen by `-Fleet <name>` and by default (`fleet.psd1`) | Used throughout | Correct file picked; reason shown in the plan |
| End-user **Kerberos sign-in** after `-Mode RepairCertificate` | Confirmed by the operator | Sign-in worked through the repaired connectors |

## Built but not yet proven by a real run

| Path | Status |
|---|---|
| The certificate step **inside** a real upgrade (added in 1.3.0) | The same routine is proven through `RepairCertificate`; it has not yet run at the end of a real upgrade |
| WinRM mode for **Kerberos Auth** connectors (scheduled task, or `-Authentication CredSSP`) | Not run |
| `-Parallel` and `-ParallelTenants` | No real run |
| `-Schedule` on the helper | Not run |
| Fleet file picked automatically by computer name or domain name | Not exercised from a machine where it would apply |
| Restore after a **failed** vendor install (restart of services, keytab copied back) | Built and reviewed; no real installer failure has occurred to exercise it |
| SSH modes from a **Windows or Linux** admin machine | Only macOS was used for SSH modes |
| OpenSSH on the connector with the stock default shell (cmd.exe) | The test connectors use PowerShell 7 as the default shell |
| Connector versions other than those listed above | The code has no version-specific logic apart from the optional patch step, but no other version has been run |
| Installer settings from the fleet file (1.4.0): proxy, custom ports, non-default install folder, FIPS mode | Built. The fleet-file checks, the plan line and the job file were exercised offline with placeholder hosts. No connector has been installed with any of them. The `FIPS_ENABLED` and `INSTALL_DIR` lines the helper reads were confirmed on a real connector (names and non-secret values only). Certificate repair still refuses FIPS mode and proxy-user configurations. |
| Proxy password hand-over (1.4.0): fourth line on standard input, WinRM parameter, protected task file, `-Prompt`, `-Schedule` | Built, not run |
| Helper finding a connector outside `C:\Program Files` (1.4.0) | Built. The service-path pattern was checked against a real connector's service paths; no connector in a non-default folder exists to run it against |
| Wrapper served-certificate check by TLS handshake (1.4.0) | The function was checked offline under PowerShell 7 against a local TLS server (thumbprint matched openssl's). The same method is proven under Windows PowerShell 5.1 in the helper. Not yet run inside the wrapper on a connector |
| Wrapper keytab-log check limited to this run (1.4.0) | Checked offline with made-up logs (earlier failure ignored, newest result judged, failure in this run caught). Not yet run on a connector |
| Orchestrator refusing Windows PowerShell 5.1 (1.4.0) | The check is the first statement after the notice; not run under 5.1 |
| Version 1.4.1 | Dry runs always run the pre-flight checks and note a connector a real run would skip or refuse. Run 2026-11-22 over SSH on four connectors already on the installer's version (one Kerberos group through the scheduled task, one group without Kerberos): the checks ran on each (PFX opened, service account validated against the domain, configuration file checked), the would-skip note was shown, `DryRunPassed`. That first build did not carry the note into the summary (the wrapper's console lines do not reach the helper's pipe under Windows PowerShell 5.1); the helper now reads it from the wrapper's audit log, where it was confirmed present. The summary note itself, and the refusal case (installed version newer than the installer), are not yet run. |
| Version 1.4.0 | Run 2026-11-22: `-Mode Verify` from both staging copies (all connectors OK), and `-DryRun` over SSH for one four-service Kerberos group (through the scheduled task) and one three-service group (direct), both `DryRunPassed`. That proves the four-line secret hand-over, the task route and the new job file on real connectors, and that the FIPS check does not refuse a connector whose setting matches. Those connectors were already on the installer's version, so the wrapper skipped and its pre-flight checks did not run (see Known weaknesses). Not yet run: WinRM mode, a real install, any of the new settings set to a non-default value. |

## Known weaknesses

- Fixed in 1.4.0, not yet proven on a connector: the wrapper's served-certificate comparison never fired under Windows PowerShell 5.1, and its keytab-log check read the first result line of the whole vendor log. The helper's own checks covered both before and still do.
- Fixed in 1.4.1 and proven on four connectors: a dry run against a connector already on the installer's version reported `DryRunPassed` without testing any password, because the wrapper decided to skip before its pre-flight checks (seen on 1.4.0, four connectors). Since 1.4.1 the checks always run and the result notes that a real run would skip.
- The Active Directory reachability test proves read access only, not that the account can create or reset the connector's account.
- WinRM mode does not copy logs back and has no report or repair modes.
- `-Mode Verify` copies the helper to the connector, so it is not strictly read-only.

## How verification was done

After each real run, independently of the tool:

- Windows services and the account each runs as;
- each service's health page;
- the installed product version and the installer's feature states;
- Java processes and the patch flag on each;
- keytab size;
- the certificate served on the Kerberos Auth port, read by a separate TLS handshake from the admin machine and from the connector;
- the installer's saved settings (service account name, syslog target, Java home);
- a count of encoded password values in every installer log on the connector and in every copy (the lines themselves were never printed);
- that no scheduled task or secrets file was left behind.
