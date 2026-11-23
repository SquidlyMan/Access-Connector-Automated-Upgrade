# Command Reference

Everything here can also be shown on screen with `-Help`.

## Invoke-AccessConnectorUpgrade.ps1

The script you run, from the `FleetDeploy` folder, with PowerShell 7 or later. Under Windows PowerShell 5.1 it stops at once and says to use `pwsh`.

```powershell
pwsh ./Invoke-AccessConnectorUpgrade.ps1 [-Mode <mode>] [-Tenant <names>] [-Connector <hosts>] [options]

# Write the fleet file from a spreadsheet (contacts no connector)
pwsh ./Invoke-AccessConnectorUpgrade.ps1 -ImportFleet <file> [-DryRun] [-Fleet <name> | -FleetConfig <path>] [-Yes]
```

### Modes

| Mode | Changes connectors? | What it does |
|---|---|---|
| `SSH` (default) | Yes | Copies the payload over SSH and runs the install. Connectors without Kerberos Auth: the installer runs as the SSH account. Kerberos Auth connectors: it runs as a one-time scheduled task under a domain admin account you are asked for. |
| `WinRM` | Yes | The same over PowerShell remoting from Windows, with a domain credential per tenant. Kerberos Auth connectors use the scheduled task with that sign-in, or run directly with `-Authentication CredSSP`. |
| `Stage` | Copies files only | Copies everything over SSH and writes `Run-Upgrade.cmd` in the staging folder on each connector. You then sign in to the connector and run it, or schedule it. No passwords are asked. |
| `Verify` | No (copies the helper script only) | Reports version, services, patch state, keytab and served certificate for each connector, over SSH. |
| `Discover` | No (copies nothing) | Reads each connector's current settings over SSH with one short read-only script on standard input, and writes a draft spreadsheet (CSV) in the columns `-ImportFleet` reads. For building a fleet file from connectors already installed. See the Fleet File Reference, "Discovering existing connectors". |
| `RepairKeytab` | Yes, Kerberos only | Runs the vendor `setupKerberos.ps1` as a one-time scheduled task under a domain admin account, then restarts the Kerberos Auth service. Connectors whose keytab already holds keys are left alone. With `-DryRun` it only tests the sign-in. |
| `RepairCertificate` | Yes, Kerberos only | Puts the PFX certificate named in the fleet file on the Kerberos Auth service using the vendor `installKerberosAuthService.bat -updateConfiguration`, restarts that service and confirms the certificate is served. Asks for the PFX password only. With `-DryRun` it tests the PFX and its password and changes nothing. |

`Verify`, `Discover`, `Stage`, `RepairKeytab` and `RepairCertificate` always use SSH. The two repair modes always work on one connector at a time.

### Selecting what to act on

| Parameter | Meaning |
|---|---|
| `-FleetConfig <path>` | Fleet file by path; a relative path is taken from the current folder. Overrides the automatic choice. For a run, a file that does not exist stops it (`Fleet file not found: <path>`). With `-ImportFleet`: the file written, which may be new. |
| `-Fleet <name>` | Use `fleet.<name>.psd1` beside the script. With `-ImportFleet`: the file written. Given together with `-FleetConfig`, it is named as ignored (`[ignored] -Fleet: -FleetConfig names the file directly.`). |
| `-Tenant <names>` | Only these fleet entries (connector groups), by `Name`. Comma-separated. Fleet order is kept. A name not in the fleet file stops the run. |
| `-Connector <hosts>` | Only these connector hosts. Comma-separated. Each still gets the settings of the entry it is listed in. With `-Mode Discover`: the hosts to read (below). |

With neither `-FleetConfig` nor `-Fleet`, the first of these that exists beside the script is used: `fleet.<this computer name>.psd1`, `fleet.<this computer domain>.psd1`, `fleet.psd1`. The plan shown before any change names the file in use and why, for example `fleet.psd1  (chosen by the default file)` or `fleet.lab.psd1  (chosen by -Fleet lab)`; with `-FleetConfig` it says `(chosen by -FleetConfig)`. `-ImportFleet` does not make this choice: without `-FleetConfig` or `-Fleet` it writes `fleet.psd1`, and says so when a run would pick another file.

With `-Mode Discover` the hosts are chosen like this:

| Given | Hosts read |
|---|---|
| `-Connector <hosts>` | Those hosts. They need not be in a fleet file. A host that is in the fleet file in use is matched with its entry, whatever group it is in. `-Tenant` has no effect and is named as ignored. |
| `-Tenant <names>`, no `-Connector` | Every connector of those groups in the fleet file in use |
| Neither | Every connector in the fleet file in use |

A missing fleet file is allowed only with `-Connector` and neither `-Fleet` nor `-FleetConfig`; the plan then says `none: hosts named with -Connector`. A fleet file named with `-Fleet` or `-FleetConfig` that does not exist stops the run.

### Building the fleet file

| Parameter | Meaning |
|---|---|
| `-ImportFleet <file>` | Read a spreadsheet (`.xlsx`, `.csv`, `.txt` or `.tsv`) with one row per connector, check it, and write the fleet file named by `-FleetConfig` or `-Fleet`, else `fleet.psd1` beside the script. Contacts no connector and does nothing else. An empty value stops at once. The target is turned into a full path; a `-FleetConfig` that names a folder, or a file in a folder that does not exist, stops with nothing written. An existing fleet file keeps its top-level settings and is first copied to `<file>.bak-<yyyyMMdd_HHmmss>` (with `-1`, `-2` and so on added when that name is taken; a copy is never overwritten). One that holds groups is replaced only after you type `YES` (or with `-Yes`); one that holds none, such as the file a partial Discover starts, without asking. Notes, shown in the dry run too, name the groups of the existing file that the spreadsheet does not hold and the settings it sets that the spreadsheet leaves blank. With `-DryRun`: check and show what would be written; write nothing. At the end it gives the next commands, naming the file written. The columns and rules are in the Fleet File Reference, "Building the fleet file from a spreadsheet". |
| `-ExportCsv <path>` | `-Mode Discover` only: the file or folder to write the draft spreadsheet in. A folder (one that exists, a path ending in `/` or `\`, or a path with no file extension) gets the default file name in it. A relative path is taken from the current folder. Default `fleet.discovered_<yyyyMMdd_HHmmss>.csv` beside the script. An empty value stops at once (`-ExportCsv needs a file name.`). Before any connector is read, the run stops if the file exists already (it is never overwritten). A folder that does not exist is made, as for `-AuditLog` and `-ErrorLog`. |

### What to do

| Parameter | Meaning |
|---|---|
| `-DryRun` | Copy the payload and run the pre-flight checks only. Nothing is installed. The checks always run, also on a connector that a real run would skip (already on the installer's version) or refuse (newer than the installer); the result then says so. With `RepairKeytab`: test the sign-in only. With `RepairCertificate`: test the PFX and password only. With `-ImportFleet`: check the spreadsheet and show the groups, connectors, settings, warnings and problems, and the file that would be written; write nothing. |
| `-ForceReinstall` | Connector already on the installer's version: uninstall it, then install fresh. Without this, a same-version connector is skipped. |
| `-Reapply` | `RepairCertificate` only: install the PFX certificate even when the connector already serves it, or when the certificate does not name the connector. |
| `-SkipJavaPatch` | Do not run the Java4Shell patch even when the fleet file names its folder. |
| `-SkipDomainCheck` | Kerberos Auth connectors only: upgrade even when the sign-in used on the connector cannot query Active Directory. The keytab is then left empty until it is rebuilt (`-Mode RepairKeytab`). |

### How to connect

| Parameter | Meaning |
|---|---|
| `-SshUser <name>` | SSH account for every connector in this run. Default: `SshUser` per connector in the fleet file, else `administrator`. With `-Mode Discover` it is also written to the `SshUser` column. |
| `-SshKey <path>` | SSH private key file. Default: your SSH configuration or agent. |
| `-RemoteStageDir <path>` | Folder used on each connector. Default `C:\ProgramData\AccessConnectorUpdate`. |
| `-Credential <cred>` | WinRM only: one credential for every tenant. Default: asked per tenant. |
| `-RunAsCredential <cred>` | Kerberos Auth connectors: the domain admin account the install runs under. Default: asked per tenant in SSH mode; WinRM mode reuses its sign-in. |
| `-Authentication <type>` | WinRM only: `Negotiate` (default), `Kerberos`, `CredSSP` or `Default`. |

### Order and failure handling

| Parameter | Meaning |
|---|---|
| (default) | One connector at a time, tenants top to bottom. A failure stops everything not yet started. |
| `-ParallelTenants` | Tenants side by side, still one connector at a time inside each. |
| `-Parallel` | Every selected connector at once. Each tenant is fully offline while it runs, and one failure cannot stop the others. |
| `-ContinueOtherTenants` | After a failure, stop that tenant but carry on with the others. |
| `-Yes` | Do not ask for the `YES` confirmation. Needed when the run is not interactive. With `-ImportFleet`: replace an existing fleet file that holds groups without asking (the backup copy is still made); one with no groups needs no `-Yes`. |

### Logging

| Parameter | Meaning |
|---|---|
| `-AuditLog <path>` | Append-only audit log: one `key=value` line per run (time, user, machine, script, version, mode, dry run, outcome, the stage reached, the number of connectors, the duration and a short detail). A file or a folder. An import is recorded as `mode=ImportFleet` with `stage=import` or `stage=import-dryrun`; a discovery as `mode=Discover` with `stage=discover`, and `outcome=FAILED` when any connector was not reached. |
| `-ErrorLog <path>` | Error log: the detail of each failure. A file or a folder. |
| `-Help` | Show the built-in help. |

### Switches that do not apply

When a switch has no effect in the chosen mode, the tool says so before it starts (for example `[ignored] -Reapply applies only to -Mode RepairCertificate`). A clean command line prints nothing.

The same goes for `-ImportFleet` and `-Mode Discover`:

| With | Named as having no effect |
|---|---|
| `-ImportFleet` | `-Mode`, `-Tenant`, `-Connector`, `-ForceReinstall`, `-Reapply`, `-SkipJavaPatch`, `-SkipDomainCheck`, `-SshUser`, `-SshKey`, `-RemoteStageDir`, `-Credential`, `-RunAsCredential`, `-Authentication`, `-Parallel`, `-ParallelTenants`, `-ContinueOtherTenants`, `-ExportCsv`; and `-Fleet` when `-FleetConfig` is given. `-DryRun`, `-Yes`, `-AuditLog` and `-ErrorLog` apply. |
| `-Mode Discover` | `-DryRun`, `-ForceReinstall`, `-SkipJavaPatch`, `-SkipDomainCheck`, `-Yes`, `-ContinueOtherTenants`, `-Parallel`, `-ParallelTenants`, `-RunAsCredential`, `-RemoteStageDir`, and (as in every mode but WinRM) `-Credential` and `-Authentication`; `-Tenant` when `-Connector` is given; and `-Fleet` when `-FleetConfig` is given. |

`-ExportCsv` applies only to `-Mode Discover`.

### Output

- A line per connector as it finishes, and a summary grouped by tenant.
- `ConnectorUpgrade_<yyyyMMdd_HHmmss>.csv` in the central log folder (`CentralLogRoot` in the fleet file): Tenant, Connector, Status, From, To, InstallerExit, PatchExit, Message.
- SSH modes: each connector's `Logs` folder copied to `<central log folder>\<tenant>_<connector>_<stamp>\`.
- `-ImportFleet`: the fleet file, and `<fleet file>.bak-<yyyyMMdd_HHmmss>` (or `...-1`, `...-2`) when it replaced one, even one with no groups. Nothing is written when there is a problem or with `-DryRun`. Then the next commands, `-Mode Verify` and `-Tenant <first group> -DryRun`, with `-FleetConfig '<full path>'` or `-Fleet <name>` when the file written needs naming.
- `-Mode Discover`: the draft spreadsheet, `fleet.discovered_<yyyyMMdd_HHmmss>.csv` beside the script, or in the folder or as the file named with `-ExportCsv`: UTF-8 with a byte-order mark, comma-separated, one row per connector (including those not reached), in the columns `-ImportFleet` reads. Then the next commands, `-ImportFleet <file> -DryRun` and without `-DryRun`, with the fleet file to write. After a full read of a fleet file: that file, as `-Fleet <name>` when `-Fleet` was used, else `-FleetConfig '<full path>'`. After a partial read, when `-Tenant` or `-Connector` left out some of the fleet file's connectors (naming all of them is a full read): Discover also writes a new fleet file `fleet.discovered_<yyyyMMdd_HHmmss>.psd1` in that file's folder, holding the original's top-level settings and no groups, and the commands name it (`-FleetConfig '<full path>'`). A warning says how many connectors were left out, names the new file, and says that importing the draft into the original would replace the whole file and drop the groups the draft does not hold. Importing into the new file needs no `YES` and keeps those settings. With no fleet file: neither.
- A run that needs a prompt answered (a password or an account) but has no terminal, because its input is redirected or it was started with `pwsh -NonInteractive`, stops at the first prompt, before any connector is contacted, with exit code 1, an error-log and an audit entry: `A prompt needs an answer, but this run has no terminal to type it in: <prompt>. Run it from an interactive terminal (passwords are only ever asked at prompts), or use -Mode Stage. Nothing was changed.` The `or use -Mode Stage` part is given only in the SSH and WinRM modes; at the `Type YES` prompt the message says `Add -Yes to confirm without a prompt` instead. A scheduler that gives the run a console without redirecting its input is not detected, so start scheduled runs with `pwsh -NonInteractive`.
- Exit code 0 when every selected connector ended `Success` or `DryRunPassed`; otherwise 1. `-ImportFleet`: 0 when the file was written or the dry run found no problem; otherwise 1. `-Mode Discover`: 0 when every connector was read; 1 when any was not reached (the spreadsheet is still written).

### Statuses

| Status | Meaning |
|---|---|
| `Success` | Installed (or repaired) and every check passed |
| `DryRunPassed` | Pre-flight checks passed; nothing was installed. A message under it says when a real run would skip the connector. |
| `DryRunFailed` | A pre-flight check failed, or a real run would refuse the connector (installed version newer than the installer); nothing was installed |
| `Blocked` | Refused before any change; the message gives the reason |
| `Failed` | The install script ended with an error: the vendor installer failed, a check in a real run stopped it, an uninstall during `-ForceReinstall` failed, or a check after the install failed (the tool carries on past that, and reports `Unhealthy`, only when `ExpectVersionPrefix` is set and the install moved the connector onto that version). The message gives the exit code; `AccessConnector_Audit_*.log` says which. Services that were running before are started again |
| `Unhealthy` | The install finished but a check afterwards did not pass |
| `Skipped` | Not attempted because an earlier connector failed |
| `Error` | The connector could not be reached, the task could not be started, or no result came back |

### Verify output

```
[12:01:07] [OK   ] TENANT1        connector1.example.local
                   v26.10.0.0 | services 4/4 up | java flag 4/4
                   keytab ok | certificate ok ('CN=connector.example.local' from
                   'CN=Example Issuing CA', to 2027-07-25)
```

| Part | Meaning |
|---|---|
| `v...` | Installed connector version |
| `services n/m up` | Connector services running; any that are not are named |
| `java flag n/m` | Connector Java processes running with the Java4Shell patch flag |
| `keytab` | `ok`, `EMPTY (n bytes)` or `none`. Kerberos Auth connectors only. |
| `certificate` | `ok`, `SELF-SIGNED by the installer`, `DOES NOT NAME THIS SERVER`, `EXPIRED` or `NOT READABLE`. Kerberos Auth connectors only. |

The line is red when a service is down, the keytab is empty, or (for a tenant with a `Pfx`) the certificate is not a proper one; yellow when nothing is installed or a Java process lacks the patch flag.

## Invoke-ConnectorUpgradeLocal.ps1

The helper. It runs on the connector under Windows PowerShell 5.1, elevated. The main script copies and starts it for you; you run it yourself only after `-Mode Stage`, normally through `Run-Upgrade.cmd`.

| Parameter | Meaning |
|---|---|
| `-Prompt` | Ask for the passwords at hidden prompts. Use when running by hand. |
| `-Schedule "yyyy-MM-dd HH:mm"` | With `-Prompt`: register a one-time scheduled task for that local time under the signed-in account instead of running now. |
| `-VerifyOnly` | Change nothing; report state. |
| `-RepairKeytab` | Run the vendor `setupKerberos.ps1`, then restart the Kerberos Auth service. Needs a domain admin sign-in. `-CheckOnly` tests the sign-in only. |
| `-RepairCertificate -CertFile <name>` | Put the PFX staged in this folder on the Kerberos Auth service. `-CheckOnly` tests only; `-Reapply` forces. |
| `-RunAsUser <account>` / `-RunAsPassword <secure>` | Do the work in a one-time scheduled task under this account and show its output here. |
| `-SkipDomainCheck` | As above. |
| `-JobFile <path>` | Job file. Default `job.json` beside the script. |
| `-AuditLog`, `-ErrorLog` | Default: the `Logs` folder beside the script. |
| `-SecretsFromStdin`, `-SecretsFile`, `-RunAsTask`, the four `-...Password` parameters | Used by the main script to hand over passwords. Not for hand use. `-SecretsFromStdin` reads four base64 lines (configuration, PFX, service account, proxy; empty where not needed), then with `-RunAsTask` two more (account and password for the task). |

Examples, on the connector:

```powershell
# After -Mode Stage: run now, signed in as a domain admin, typing the passwords
C:\ProgramData\AccessConnectorUpdate\Run-Upgrade.cmd

# Schedule it for tonight under the signed-in account
powershell -ExecutionPolicy Bypass -File C:\ProgramData\AccessConnectorUpdate\Invoke-ConnectorUpgradeLocal.ps1 -Prompt -Schedule "2027-01-15 22:30"

# Report state only
powershell -ExecutionPolicy Bypass -File C:\ProgramData\AccessConnectorUpdate\Invoke-ConnectorUpgradeLocal.ps1 -VerifyOnly
```

## Install-AccessConnector.ps1

The wrapper around the vendor installer. The helper calls it; it can also be used on its own on a single server. It builds the silent install command, runs pre-flight checks, stops and starts the services, and writes an audit log beside the MSI log.

Parameters the fleet tool sets from the fleet file: `-InstallerPath`, `-ConfigFilePath`, `-Services`, `-TrustStoreCertsPath`, `-SslCertPath`, `-ServiceAccount`, `-SyslogHost`, `-InstallerVersion`, `-ForceReinstall`, `-DryRun`, `-InstallDir`, `-EnableFips`, `-DirectorySyncPort`, `-UserAuthPort`, `-KerberosAuthPort`, `-VirtualAppPort`, `-ProxyHost`, `-ProxyPort`, `-ProxyUser`, `-NonProxyHosts`, and the four password parameters (configuration file, PFX, service account, proxy). The helper also passes `-ExtraMsiProperties REBOOT=ReallySuppress`, and `-ValidateServiceAccount` when it runs under a domain sign-in.

Parameters only for running the wrapper by hand: `-ShowInstallerUI`, `-SkipKeytab`, `-ExtraMsiProperties`.

After a successful install with Kerberos Auth, the wrapper compares the certificate the service serves with the PFX. After a fresh install a mismatch makes it exit 1. After an upgrade it is a warning, because the vendor installer never carries the PFX through an upgrade; the fleet tool puts it back afterwards.

Run `Get-Help '.\Install-AccessConnector.ps1' -Full` or `-Help` for its own documentation.
