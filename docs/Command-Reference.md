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
| `-Parallel` | Every selected connector at once. Each tenant is fully offline while it runs, and one failure cannot stop the others, with one exception: over WinRM, a sign-in that a connector refuses is known before the next connector is started, so the connectors not yet started are left alone (the ones already started finish). `-ContinueOtherTenants` is ignored. |
| `-ContinueOtherTenants` | After a failure, stop that tenant but carry on with the others. |
| `-Yes` | Do not ask for the `YES` confirmation. Needed when the run is not interactive. With `-ImportFleet`: replace an existing fleet file that holds groups without asking (the backup copy is still made); one with no groups needs no `-Yes`. |

### Logging

| Parameter | Meaning |
|---|---|
| `-AuditLog <path>` | Append-only audit log: one `key=value` line per run (time, user, machine, script, version, mode, dry run, outcome, the stage reached, the number of connectors, the duration and a short detail). A file or a folder. An import is recorded as `mode=ImportFleet` with `stage=import` or `stage=import-dryrun`; a discovery as `mode=Discover` with `stage=discover`, and `outcome=FAILED` when any connector was not reached; a Verify with `stage=verify`, `outcome=FAILED` when any connector could not be read or is red, and `detail="notRead=<n> red=<n>"`; a run stopped by the SSH sign-in check with `stage=signin`. |
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
- An upgrade or dry run over SSH, `-Mode RepairKeytab` and `-Mode RepairCertificate` first check the SSH sign-in on every selected connector, right after the plan and before `YES` and any prompt (a trivial Windows PowerShell command, at most 120 seconds per connector): `SSH sign-in checked on <n> connector(s).` When one fails, each failing connector gets a line with SSH's own reason, and a hint when the reason suggests one (`cannot reach <host> over SSH: <reason>. Hint: ...`), or, when SSH signed in but the command failed there, `signed in to <host> over SSH, but could not run Windows PowerShell there: <error>`, and the run stops with exit code 1, an error-log entry per connector and an audit entry with `stage=signin`: `The SSH sign-in check failed on <n> of <m> connector(s): <hosts>. Nothing was changed and no password was asked. Fix the sign-in and run again, or leave those connectors out with -Connector (for the others: -Connector <hosts>).` WinRM, Stage, Verify, Discover and `-ImportFleet` make no such check.
- The first SSH step on a connector (making the staging folder) names what failed: `cannot reach <host> over SSH: <SSH's own reason>`, with the same hints, or `signed in to <host> over SSH, but could not create <folder>: <the connector's error>`. When the step (or the sign-in check) did answer but ssh still failed afterwards, because the session dropped (or, for the sign-in check, which has a 120-second limit, did not end in time), the message says so: `signed in to <host> over SSH and the step answered, but ssh then ended with exit code <n>: <reason>`, or, from the sign-in check, `... but the session did not end within 120 seconds`. Discover's `<host>: not reached: <reason>` line gets the hint too. In the hint's test command the account is in single quotes when it holds a backslash (`ssh 'EXAMPLE\admin@connector1.example.local' hostname`), so that zsh and bash keep it. For `Permission denied` the hint names both causes, because SSH gives the same answer for an account that does not exist on the connector and for a key it does not accept, and ends with the test command and nothing after it, so that it can be copied as shown (since 1.5.2; 1.5.1 blamed only the key and put a full stop after `hostname`): `the connector refused the sign-in for <user>: the account does not exist there, or its key was not accepted; SSH does not say which. Check the account name (SshUser in the fleet file, or -SshUser) and that its key is authorised on the connector (Getting Started 4.4); name the key with -SshKey <file>, or with an IdentityFile line for these hosts in the SSH settings file (Getting Started 4.7). An 'Invalid user' line in the connector's OpenSSH/Operational event log means the account does not exist. Test by hand: ssh <user>@<host> hostname`. With `-SshKey` the middle part reads `and that the public key of <key> is authorised for it on the connector (Getting Started 4.4).`, and the command is `ssh -i <key> <user>@<host> hostname`.
- A run that needs a prompt answered (a password or an account) but has no terminal, because its input is redirected or it was started with `pwsh -NonInteractive`, stops at the first prompt, before anything is copied to a connector (after the sign-in check above), with exit code 1, an error-log and an audit entry: `A prompt needs an answer, but this run has no terminal to type it in: <prompt>. Run it from an interactive terminal (passwords are only ever asked at prompts), or use -Mode Stage. Nothing was changed.` The `or use -Mode Stage` part is given only in the SSH and WinRM modes; at the `Type YES` prompt the message says `Add -Yes to confirm without a prompt` instead. A scheduler that gives the run a console without redirecting its input is not detected, so start scheduled runs with `pwsh -NonInteractive`.
- Exit code 0 when every selected connector ended `Success` or `DryRunPassed`; otherwise 1. `-ImportFleet`: 0 when the file was written or the dry run found no problem; otherwise 1. `-Mode Discover`: 0 when every connector was read; 1 when any was not reached (the spreadsheet is still written). `-Mode Verify`: 1 when any connector could not be read or its line is red (below); yellow lines keep 0.
- WinRM: when a connector refuses the sign-in (access denied, a logon failure, a wrong user name or password, an account locked out, disabled or with an expired password, or, since 1.5.2, error `0x8009030e`, `A specified logon session does not exist`, which Negotiate gives for an account that does not exist), its line says `Could not sign in to <host> over WinRM as <user>: <reason>`, and that tenant stops and, unless `-ContinueOtherTenants`, the run, also in a dry run. The refusal is known before the next connector is started, so with `-Parallel` too the connectors not yet started are not tried (`-Parallel` ignores `-ContinueOtherTenants`); with `-ParallelTenants` the same holds for the other groups' connectors of the same set. A connector that cannot be reached gets `Error`, as before: a dry run goes on to the next connector; a real run stops that tenant and, unless `-ContinueOtherTenants`, the run.

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
| `Error` | The connector could not be reached, the sign-in was refused (WinRM), the task could not be started, or no result came back |

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

The line is red when a service is down, the keytab is empty or missing, or (for a tenant with a `Pfx`) the certificate is not a proper one; yellow when nothing is installed or a Java process lacks the patch flag. A red line makes the exit code 1 and adds an error-log entry naming what is red, `<host> (<group>): red in Verify: <items>`; yellow lines do not change the exit code. The audit line says `notRead=<n> red=<n>`.

## Invoke-ConnectorUpgradeLocal.ps1

The helper. It runs on the connector under Windows PowerShell 5.1, elevated. The main script copies and starts it for you; you run it yourself only after `-Mode Stage`, normally through `Run-Upgrade.cmd`.

| Parameter | Meaning |
|---|---|
| `-Prompt` | Ask for the passwords at hidden prompts. Use when running by hand. |
| `-Schedule "yyyy-MM-dd HH:mm"` | With `-Prompt`: register a one-time scheduled task, `AccessConnectorUpgrade`, for that local time instead of running now. Since 1.5.2 it asks for the account the job runs as, `Account the scheduled job runs as (DOMAIN\user); Enter for <signed-in account>`, or takes `-RunAsUser` (with `-RunAsPassword`, or the password is asked), and registers the task under that account with highest privileges, so the account must be an administrator of the server (1.5.1 always used the signed-in account). A job with the Kerberos Auth service needs a domain account (its keytab step queries and changes Active Directory): a local one (no domain part, a `user@domain` name included, `.\user`, `\user`, `<this computer>\user`, `NT AUTHORITY\` or `BUILTIN\`) is refused before its password is asked, and the signed-in account is offered at Enter only when it would pass. Built-in service accounts (SYSTEM, LocalSystem, Local Service, Network Service) are always refused. `-SkipDomainCheck` does not relax this. Before the password prompt it says `The job will run as <account>. Task Scheduler keeps the Windows password of <account> until the task deletes itself: when the run ends, or at <time + 12 h> if it has not run by then.` The task deletes itself, and with it that password, when the run ends; if it has not run 12 hours after that time, Task Scheduler deletes it. The passwords for the job go to `secrets.dat`, encrypted for this server (machine-scope data protection, since 1.5.2) and limited to Administrators and SYSTEM before anything is written in it, so `-Schedule` works in an SSH session signed in by key (`ssh -t`) as well as at the console; the job deletes it when it reads it. Its console output goes to `Logs\task-console_<yyyyMMdd_HHmm>.log`, the result to `Logs\result.json`. The task's run gets the `-SkipDomainCheck`, `-AuditLog` and `-ErrorLog` given here (the logs as full paths), and the job file by its full path. Refused with exit code 1 and nothing written (`Not scheduled: <why>. Nothing was written.`): a time that has already passed on the server's clock, a time given while a task named `AccessConnectorUpgrade` is running (an earlier scheduled run, which would delete the new task when it ends), an account the job cannot use, and an empty password; the time and the running task are checked again after the password prompt. A later step that fails says which (`Could not protect the passwords for the scheduled task (machine-scope data protection): ...`, `Could not write the secrets file <path>: ...`, `Could not register the scheduled task as <account>: ...`) and removes `secrets.dat` again. A `secrets.dat` left by an earlier `-Schedule`, whose task may still be pending, is moved aside before the new one is made, put back when a step fails (the message then says `The secrets.dat of an earlier -Schedule was put back, ...`, and the earlier task still runs as booked), and deleted only once the new task has replaced the earlier one. Not with `-RunAsTask`, which starts the work at once: refused before anything is asked. |
| `-VerifyOnly` | Change nothing; report state. |
| `-RepairKeytab` | Run the vendor `setupKerberos.ps1`, then restart the Kerberos Auth service. Needs a domain admin sign-in. `-CheckOnly` tests the sign-in only. |
| `-RepairCertificate -CertFile <name>` | Put the PFX staged in this folder on the Kerberos Auth service. `-CheckOnly` tests only; `-Reapply` forces. |
| `-RunAsUser <account>` / `-RunAsPassword <secure>` | Do the work in a one-time scheduled task under this account and show its output here. With `-Schedule` (since 1.5.2): the account the scheduled job runs as; its password is asked unless `-RunAsPassword` is given. |
| `-SkipDomainCheck` | As above. |
| `-JobFile <path>` | Job file. Default `job.json` beside the script. |
| `-AuditLog`, `-ErrorLog` | Default: the `Logs` folder beside the script. When given, a task this script registers (the run-as task, `-Schedule`) passes them on to its run as full paths. |
| `-SecretsFromStdin`, `-SecretsFile`, `-RunAsTask`, the four `-...Password` parameters | Used by the main script and by the tasks it registers to hand over passwords. Not for hand use. `-SecretsFromStdin` reads four base64 lines (configuration, PFX, service account, proxy; empty where not needed), then with `-RunAsTask` two more (account and password for the task). `-SecretsFile`: the file written by `-Schedule` or by the run-as task, deleted when read; one written by `-Schedule` of 1.5.1 (encrypted for the user) is still read. |

Examples, on the connector:

```powershell
# After -Mode Stage: run now, signed in as a domain admin, typing the passwords
C:\ProgramData\AccessConnectorUpdate\Run-Upgrade.cmd

# Schedule it for tonight; asks for the account the job runs as
powershell -ExecutionPolicy Bypass -File C:\ProgramData\AccessConnectorUpdate\Invoke-ConnectorUpgradeLocal.ps1 -Prompt -Schedule "2027-01-15 22:30"

# The same, over ssh -t, under a domain admin (Kerberos Auth)
powershell -ExecutionPolicy Bypass -File C:\ProgramData\AccessConnectorUpdate\Invoke-ConnectorUpgradeLocal.ps1 -Prompt -Schedule "2027-01-15 22:30" -RunAsUser EXAMPLE\admin

# Report state only
powershell -ExecutionPolicy Bypass -File C:\ProgramData\AccessConnectorUpdate\Invoke-ConnectorUpgradeLocal.ps1 -VerifyOnly
```

## Install-AccessConnector.ps1

The wrapper around the vendor installer. The helper calls it; it can also be used on its own on a single server. It builds the silent install command, runs pre-flight checks, stops and starts the services, and writes an audit log beside the MSI log.

Parameters the fleet tool sets from the fleet file: `-InstallerPath`, `-ConfigFilePath`, `-Services`, `-TrustStoreCertsPath`, `-SslCertPath`, `-ServiceAccount`, `-SyslogHost`, `-InstallerVersion`, `-ForceReinstall`, `-DryRun`, `-InstallDir`, `-EnableFips`, `-DirectorySyncPort`, `-UserAuthPort`, `-KerberosAuthPort`, `-VirtualAppPort`, `-ProxyHost`, `-ProxyPort`, `-ProxyUser`, `-NonProxyHosts`, and the four password parameters (configuration file, PFX, service account, proxy). The helper also passes `-ExtraMsiProperties REBOOT=ReallySuppress`, and `-ValidateServiceAccount` when it runs under a domain sign-in.

Parameters only for running the wrapper by hand: `-ShowInstallerUI`, `-SkipKeytab`, `-ExtraMsiProperties`.

After a successful install with Kerberos Auth, the wrapper compares the certificate the service serves with the PFX. After a fresh install a mismatch makes it exit 1. After an upgrade it is a warning, because the vendor installer never carries the PFX through an upgrade; the fleet tool puts it back afterwards.

Run `Get-Help '.\Install-AccessConnector.ps1' -Full` or `-Help` for its own documentation.

## The set-up scripts in Prerequisites

Each has its own version and its own `-Help` (`--help` for the macOS one), which lists every parameter. What changed in 1.5.2:

- `Install-OpenSSHServer.ps1` 1.0.1. On a first install, the rule `OpenSSH-Server-In-TCP` that the install adds lets TCP 22 in from any address. With `-AllowFrom` it is limited to those networks at once, before sshd first starts; a rule that cannot be limited is disabled until the firewall step, which tries again; one that can be neither limited nor disabled stops the run before sshd starts. Without `-AllowFrom` it stays open to any address, and the run warns. `-WhatIf` no longer prints `What if: ... Set Alias` lines from loading modules before the first step.
- `Install-PowerShell7.ps1` 1.0.1. New `-NoPause`, for `Install-PowerShell7.cmd`, which passes it on: the script itself never waits and does nothing with it. The MSI's SHA-256 is checked against the release's `hashes.sha256`; for a release found through the GitHub releases API whose `hashes.sha256` cannot be read or does not list the MSI, against the digest GitHub records for the file; with neither, nothing is downloaded or installed. The release lookup through that API works under Windows PowerShell 5.1 (1.0.0 stopped with `Argument types do not match`).
- `Install-PowerShell7.cmd` 1.0.1. Waits for a key when the script does not succeed (an exit code other than 0, 3010 or 1641), or could not be started; after 0 it ends at once, double-clicked or not. After 3010 or 1641 (installed, a restart is needed) it says `[WARN] PowerShell 7 is installed. Restart Windows to finish the installation.` and waits for a key when started without arguments (double-clicked), so that the notice is seen. Never waits as SYSTEM or with `-NoPause` (found by its first four characters, so `-NoPa` and `-NoPause:$true` count too). Since `-NoPause` exists, `-No` alone is ambiguous (in 1.0.0 it meant `-NoMicrosoftUpdate`). Passes the exit code back. A deployment tool should still start the `.ps1` directly; `Install-PowerShell7.cmd ... -NoPause` is the alternative.
