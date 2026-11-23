# Command Reference

Everything here can also be shown on screen with `-Help`.

## Invoke-AccessConnectorUpgrade.ps1

The script you run, from the `FleetDeploy` folder, with PowerShell 7 or later. Under Windows PowerShell 5.1 it stops at once and says to use `pwsh`.

```powershell
pwsh ./Invoke-AccessConnectorUpgrade.ps1 [-Mode <mode>] [-Tenant <names>] [-Connector <hosts>] [options]
```

### Modes

| Mode | Changes connectors? | What it does |
|---|---|---|
| `SSH` (default) | Yes | Copies the payload over SSH and runs the install. Connectors without Kerberos Auth: the installer runs as the SSH account. Kerberos Auth connectors: it runs as a one-time scheduled task under a domain admin account you are asked for. |
| `WinRM` | Yes | The same over PowerShell remoting from Windows, with a domain credential per tenant. Kerberos Auth connectors use the scheduled task with that sign-in, or run directly with `-Authentication CredSSP`. |
| `Stage` | Copies files only | Copies everything over SSH and writes `Run-Upgrade.cmd` in the staging folder on each connector. You then sign in to the connector and run it, or schedule it. No passwords are asked. |
| `Verify` | No (copies the helper script only) | Reports version, services, patch state, keytab and served certificate for each connector, over SSH. |
| `RepairKeytab` | Yes, Kerberos only | Runs the vendor `setupKerberos.ps1` as a one-time scheduled task under a domain admin account, then restarts the Kerberos Auth service. Connectors whose keytab already holds keys are left alone. With `-DryRun` it only tests the sign-in. |
| `RepairCertificate` | Yes, Kerberos only | Puts the PFX certificate named in the fleet file on the Kerberos Auth service using the vendor `installKerberosAuthService.bat -updateConfiguration`, restarts that service and confirms the certificate is served. Asks for the PFX password only. With `-DryRun` it tests the PFX and its password and changes nothing. |

`Verify`, `Stage`, `RepairKeytab` and `RepairCertificate` always use SSH. The two repair modes always work on one connector at a time.

### Selecting what to act on

| Parameter | Meaning |
|---|---|
| `-FleetConfig <path>` | Fleet file by full path. Overrides the automatic choice. |
| `-Fleet <name>` | Use `fleet.<name>.psd1` beside the script. |
| `-Tenant <names>` | Only these fleet entries (connector groups), by `Name`. Comma-separated. Fleet order is kept. |
| `-Connector <hosts>` | Only these connector hosts. Comma-separated. Each still gets the settings of the entry it is listed in. |

With neither `-FleetConfig` nor `-Fleet`, the first of these that exists beside the script is used: `fleet.<this computer name>.psd1`, `fleet.<this computer domain>.psd1`, `fleet.psd1`. The plan shown before any change names the file in use and why.

### What to do

| Parameter | Meaning |
|---|---|
| `-DryRun` | Copy the payload and run the pre-flight checks only. Nothing is installed. The checks always run, also on a connector that a real run would skip (already on the installer's version) or refuse (newer than the installer); the result then says so. With `RepairKeytab`: test the sign-in only. With `RepairCertificate`: test the PFX and password only. |
| `-ForceReinstall` | Connector already on the installer's version: uninstall it, then install fresh. Without this, a same-version connector is skipped. |
| `-Reapply` | `RepairCertificate` only: install the PFX certificate even when the connector already serves it, or when the certificate does not name the connector. |
| `-SkipJavaPatch` | Do not run the Java4Shell patch even when the fleet file names its folder. |
| `-SkipDomainCheck` | Kerberos Auth connectors only: upgrade even when the sign-in used on the connector cannot query Active Directory. The keytab is then left empty until it is rebuilt (`-Mode RepairKeytab`). |

### How to connect

| Parameter | Meaning |
|---|---|
| `-SshUser <name>` | SSH account for every connector in this run. Default: `SshUser` per connector in the fleet file, else `administrator`. |
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
| `-Yes` | Do not ask for the `YES` confirmation. Needed when the run is not interactive. |

### Logging

| Parameter | Meaning |
|---|---|
| `-AuditLog <path>` | Append-only audit log: one `key=value` line per run. A file or a folder. |
| `-ErrorLog <path>` | Error log: the detail of each failure. A file or a folder. |
| `-Help` | Show the built-in help. |

### Switches that do not apply

When a switch has no effect in the chosen mode, the tool says so before it starts (for example `[ignored] -Reapply applies only to -Mode RepairCertificate`). A clean command line prints nothing.

### Output

- A line per connector as it finishes, and a summary grouped by tenant.
- `ConnectorUpgrade_<yyyyMMdd_HHmmss>.csv` in the central log folder (`CentralLogRoot` in the fleet file): Tenant, Connector, Status, From, To, InstallerExit, PatchExit, Message.
- SSH modes: each connector's `Logs` folder copied to `<central log folder>\<tenant>_<connector>_<stamp>\`.
- Exit code 0 when every selected connector ended `Success` or `DryRunPassed`; otherwise 1.

### Statuses

| Status | Meaning |
|---|---|
| `Success` | Installed (or repaired) and every check passed |
| `DryRunPassed` | Pre-flight checks passed; nothing was installed. A message under it says when a real run would skip the connector. |
| `DryRunFailed` | A pre-flight check failed, or a real run would refuse the connector (installed version newer than the installer); nothing was installed |
| `Blocked` | Refused before any change; the message gives the reason |
| `Failed` | The installer returned a failure code |
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
