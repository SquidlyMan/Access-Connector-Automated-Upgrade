# Troubleshooting

Start with `-Mode Verify`: it shows what each connector looks like now and changes nothing. Then find the message you got below.

Logs to read, in order:

1. The screen output of the run (the helper's lines are relayed as they happen).
2. `FleetDeploy\FleetLogs\<tenant>_<connector>_<stamp>\` on the admin side (SSH modes), or `C:\ProgramData\AccessConnectorUpdate\Logs` on the connector:
   - `connector-upgrade-audit.log` and `connector-upgrade-errors.log`: the helper's own record;
   - `AccessConnector_Audit_<stamp>.log`: the wrapper's record, including each pre-flight check;
   - `AccessConnector_MSI_<stamp>.log`: the vendor installer's verbose log;
   - `task-console_<stamp>.log`: output of the scheduled task, for Kerberos Auth connectors;
   - `result.json`: the result of the last install.

## Before anything is changed

| Message | Cause | Fix |
|---|---|---|
| `No fleet file found in ...` | None of the fleet file names looked for exists beside the script | Copy `fleet.example.psd1` to `fleet.psd1`, or use `-Fleet` or `-FleetConfig` |
| `Unknown tenant(s): ...` | `-Tenant` does not match a `Name` in the fleet file in use | Check the plan line that names the fleet file; you may be reading a different file than you think |
| `No connectors selected` | `-Connector` matched nothing, or the mode left every tenant out (repair modes skip tenants without Kerberos Auth) | Check spelling; use the exact `Host` value |
| `Files this run needs are missing under ...` | A file in the fleet file is not in the staging folder you ran from | Add the file. If the message names another copy of the folder, run from there. |
| `ssh was not found on the PATH` | No OpenSSH client | Install the OpenSSH client (Windows: optional feature; macOS and Linux have it) |
| `-Mode WinRM needs Windows` | WinRM mode started from macOS or Linux | Use SSH mode |
| `Not interactive: add -Yes` | Run from a scheduler or with input redirected | Add `-Yes` |
| `Empty ... password ... Nothing was changed` | Enter was pressed at a password prompt | Run again |

## Connecting

| Message | Cause | Fix |
|---|---|---|
| `cannot reach <host> over SSH or create C:\ProgramData\AccessConnectorUpdate` | SSH sign-in failed, or the account is not an administrator | Test by hand: `ssh -i <key> <user>@<host> hostname`. Lines in red beginning `ssh (<host>):` give SSH's own reason. |
| `Permission denied (publickey)` in the red lines | The key is not authorised on the connector | Add the public key to `C:\ProgramData\ssh\administrators_authorized_keys` and re-run the `icacls` command from Getting Started section 4.4 |
| `Host key verification failed` | The server's host key changed since it was first seen (rebuilt server) | Confirm the rebuild, then remove the old entry: `ssh-keygen -R <host>` |
| `scp to <host>:... failed` | Disk full on the connector, or the SFTP subsystem is disabled in `sshd_config` | Free space; make sure `Subsystem sftp sftp-server.exe` is present |
| `installer hash mismatch on <host> after copy` | The copy was cut short or altered | Run again; check disk space and antivirus quarantine on the connector |
| WinRM: `New-PSSession` access denied or cannot connect | Remoting not enabled, firewall, or the credential is not an administrator there | `Test-WSMan <host>`; `Enable-PSRemoting -Force` on the connector |

## Pre-flight and dry run

| Message | Cause | Fix |
|---|---|---|
| `DryRunFailed`, `pre-flight exit ...` | A pre-flight check in the wrapper failed | Read the lines above it and `AccessConnector_Audit_*.log`: PFX password wrong, configuration file invalid, service account password wrong |
| PFX check fails | Wrong PFX password, or the file is not a PFX with a private key | Retype; open the PFX on your own machine to confirm |
| Configuration password "rules" warning | The password typed does not meet Omnissa's documented rules for that password, so it cannot be the right one | Retype. A password that passes the rules is still only confirmed by the installer itself. |
| `Could not start the task as <account>` | The domain admin account name or password is wrong, or the account may not run scheduled tasks | Retype as `DOMAIN\name`. Nothing was changed. The tenant's other connectors are not tried, to avoid repeated bad sign-ins. |
| `this sign-in (...) cannot query Active Directory` | A Kerberos Auth connector was run without the scheduled-task route | Give a domain admin account when asked. With `-Mode Stage`, run `Run-Upgrade.cmd` signed in as a domain admin. |
| `a built-in service account cannot rebuild the Kerberos keytab` | The helper was started as SYSTEM for a Kerberos Auth connector | Use a domain admin account |
| `this server writes PowerShell command parameters to its event log` | Module logging policy is on | Exempt the server for the run |
| `a task named AccessConnectorUpgrade-RunAs is already running` | An earlier run is still working on that connector | Wait for it. Check `task-console_*.log` on the connector. |

## During and after the install

| Message | Cause | Fix |
|---|---|---|
| `Failed`, `installer exit <code>` | The vendor installer failed | Read `AccessConnector_MSI_*.log` (search for `Return value 3`). The services that were running before have been started again; confirm with `-Mode Verify`. |
| `Unhealthy: only n of m services running` | A service did not start within four minutes | Check the service's own log under the connector's install folder; start it; run `-Mode Verify` |
| `Unhealthy: installed version is X, expected Y*` | `ExpectVersionPrefix` does not match the installer, or the install did not take | Correct the fleet file, or read the MSI log |
| `Unhealthy: Kerberos keytab missing or empty` | The vendor Kerberos set-up could not reach Active Directory or failed | `-Mode RepairKeytab` |
| `Unhealthy: the Kerberos service serves '...' not the PFX certificate` | The certificate step could not complete | `-Mode RepairCertificate` |
| `Unhealthy: the installer needs this server restarted` | Windows Installer asked for a reboot (exit 3010 or 1641) | Restart the server in your own time, then `-Mode Verify` |
| `the installer finished, but Install-AccessConnector.ps1 reported a problem afterwards` | The connector is on the new version but one of the wrapper's checks afterwards failed | Read `AccessConnector_Audit_*.log`; the tool has carried on with its own checks |
| `the connector returned no result` | The connection dropped, or the helper was stopped | The work may still be running on the connector. Check `result.json` and the task console log there before running again. |
| `the task is still running after 120 minutes` | The scheduled task has not finished | It was left running. Check `task-console_*.log` on the connector. |
| Same-version connector: nothing seems to happen | A connector already on the installer's version is skipped by design | Add `-ForceReinstall` if a reinstall is what you want |

## Verify shows something wrong

| Verify shows | Meaning | Fix |
|---|---|---|
| `no connector services installed` | No connector on this server | A normal run will clean install it |
| `services 3/4 up (KerberosAuth=Stopped)` | A service is down | Start it; read its log |
| `java flag 2/4` | Some Java processes lack the patch flag | Re-run the upgrade, or run the vendor patch script and restart the services |
| `keytab EMPTY (6 bytes)` | The keytab file has no keys | `-Mode RepairKeytab` |
| `certificate SELF-SIGNED by the installer` | The vendor installer's own certificate is being served | `-Mode RepairCertificate` |
| `certificate DOES NOT NAME THIS SERVER` | The PFX certificate lacks this connector's name | Issue a certificate that names every connector it is used on. If Kerberos Auth is not meant to be on this connector, remove it (`Services` plus `-ForceReinstall`). |
| `certificate EXPIRED` | Past its end date | New PFX, then `-Mode RepairCertificate` |
| `certificate not checked` | The Kerberos Auth service is not running, or the helper on the connector is an older version | Start the service; run Verify again (it copies the current helper) |

## Kerberos specifics

- **The Access console can show Kerberos Auth as active while the keytab is empty.** Console health does not prove the keytab. Trust `-Mode Verify`.
- **A browser privacy warning at `https://<connector>/eks/...`** means the Kerberos Auth service is serving a certificate the browser does not trust, typically the installer's self-signed one after an upgrade. The Kerberos sign-in redirect goes to the connector's own name. Run `-Mode RepairCertificate`.
- **A yellow warning on Kerberos Auth in the Access console** with "No subject alternative DNS name matching ..." means the certificate served does not name that connector.
- **A keytab repair resets the password** of the Active Directory account named after the connector. Kerberos sign-in through that connector stops for about a minute while its service restarts.
- **A certificate repair** stops only the Kerberos Auth service, for a few minutes.

## Certificate repair outcomes

The exact wording on screen varies; these are the situations.

| Situation | Meaning |
|---|---|
| `already serving the PFX certificate; not changed` | Nothing to do. `-Reapply` forces it. |
| The PFX certificate does not name this server | Refused, to avoid installing a certificate clients will reject. `-Reapply` overrides. |
| PFX password or path contains `%`, `^` or `"` | The vendor batch files would alter it. Change the password or rename the file. |
| Refused: FIPS mode, or a proxy user is configured | These configurations are outside what the repair has been built for |
| An earlier certificate change was interrupted | A marker from a previous run was found. The message says what state the service is in. Run the repair again. |
| The original configuration was put back | A check after the change failed, so the copy taken before was restored. The connector is as it was. The message says which check failed. |

## Things not to do

- Do not run a silent `msiexec /i {product code} REMOVE=KerberosAuthService /qn` to remove a service. It fails and blanks settings the connector saved at install time. Use `Services` plus `-ForceReinstall`.
- Do not delete `C:\ProgramData\AccessConnectorUpdate\KeytabBackup` or `CertBackup` while you might still need to go back.
- Do not print or paste the `Adding AW... property` lines of an `AccessConnector_MSI_*.log` that the tool has not cleaned. They can hold encoded passwords.
- Do not run two runs against the same connector at once, and do not replace the scripts in a staging folder during a run.
