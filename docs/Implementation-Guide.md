# Implementation Guide

How to put the tool into service in an environment and run it as a routine. Read [Getting Started](Getting-Started.md) first; this guide assumes you have done one dry run.

## 1. Plan

### Inventory

For each connector write down:

| Item | Why |
|---|---|
| Server name and domain | Goes in `Connectors` |
| Which Access tenant it belongs to | Decides the `ConfigFile` |
| Which services it runs | Decides `Services`. Connectors with different services go in separate fleet entries (connector groups), even when they belong to the same tenant. |
| Whether Kerberos Auth is really in use there | If not, do not install it. Kerberos Auth brings a certificate, a keytab and an Active Directory account to look after. |
| Service account | `ServiceAccount` |
| Current version | `-Mode Discover` or `-Mode Verify` will tell you |

For connectors that are already installed, `-Mode Discover` fills in most of this for you. It reads each connector's version, services, service account, tenant, syslog target, ports, proxy, install folder and FIPS mode over SSH, changes nothing, and writes a draft spreadsheet in the columns of the fleet file:

```powershell
pwsh ./Invoke-AccessConnectorUpgrade.ps1 -Mode Discover -Connector connector1.example.local,connector2.example.local
```

Complete the blanks the `Notes` column names (usually the installer, the es-config file and, for Kerberos Auth, the PFX), check the group names, and write the fleet file from it with `-ImportFleet <file> -DryRun`, then without `-DryRun`. A server without a connector has no settings to read: fill in its row by hand. With no connectors installed at all, start from the template `FleetDeploy/fleet.example.xlsx` instead. The Fleet File Reference has the rules for both, under "Building the fleet file from a spreadsheet" and "Discovering existing connectors".

If you keep the fleet in the spreadsheet, keep it as the source: change the sheet and import it again, rather than editing the fleet file and the sheet separately. The import replaces every group in the fleet file and keeps a dated copy of the old file; before it does, a note names every group, connector and setting the new file would not have.

`-Mode Verify` against the first fleet file then confirms sign-in to every connector and the state of each.

### Compatibility

Before pointing the fleet file at a new installer, read Omnissa's release notes for that connector version:

- which Access service versions it works with (a connector can be too new for an on-premises Access appliance);
- which versions it can be upgraded from;
- whether a new `es-config.json` must be generated for the upgrade;
- which custom settings have to be supplied again.

The tool installs what you give it. It does not check compatibility with the Access service.

### Settings the tool carries

| Setting | Carried by the tool |
|---|---|
| Services, service account, tenant configuration | Yes |
| Trusted CA certificates | Yes (`TrustStore`) |
| Kerberos certificate | Yes (`Pfx`), and put back after an upgrade |
| Syslog target | Yes (`Syslog`) |
| Outbound proxy, custom ports, install folder, FIPS mode | Yes, since 1.4.0 (`ProxyHost` and the rest; see the Fleet File Reference). Not yet proven by a real run. |
| Java memory or other hand edits to service files | No. Reapply by hand after an upgrade. |

## 2. Choose the route per environment

| Situation | Route |
|---|---|
| Admin machine is a Mac or Linux box | SSH |
| Windows admin machine, SSH allowed on the servers | SSH (all modes available) |
| SSH not allowed on the servers | WinRM for installs; no Verify, Discover or repair modes |
| No remote execution allowed at all | `-Mode Stage` needs SSH to copy; otherwise copy the staging folder's files to the connector yourself and run `Invoke-ConnectorUpgradeLocal.ps1 -Prompt` there with a hand-written `job.json` |
| Change window when nobody is present | `-Mode Stage`, then `-Schedule` on each connector |

Kerberos Auth connectors need a domain admin account at run time on every route.

## 3. Lay out the staging folder

One staging folder per trust boundary. Each holds the tool and that boundary's files:

```
\\fileserver\Deploy\AccessConnector\
    FleetDeploy\
        Invoke-AccessConnectorUpgrade.ps1
        Invoke-ConnectorUpgradeLocal.ps1
        fleet.psd1
        FleetLogs\
    Silent Install\Install-AccessConnector.ps1
    Installers\
    Configs\
    ChildCerts\
    TrustedCerts\
```

Keep the two scripts in `FleetDeploy` and the wrapper identical in every copy. Update all copies together.

### Several domains or forests

Where domains do not trust each other, a file share in one is usually not readable with accounts from the other. Use one copy of the staging folder per domain:

1. Put a copy on a share in each domain, each with that domain's `Configs` and `ChildCerts`.
2. In each copy, name the fleet file after the domain: `fleet.<domain>.psd1`. A machine joined to that domain picks it up automatically; from elsewhere use `-Fleet <domain>`.
3. List every copy under `StagingFolders` in each fleet file. If you run a tenant from the wrong copy, the error then names the right one and the `cd` command to get there.

### Several admin machines

`fleet.<computer name>.psd1` is chosen before the domain and default files, so each admin machine can have its own view of the fleet in the same shared folder.

## 4. Prepare the connectors

- SSH route: stand up OpenSSH Server with key sign-in on each connector (Getting Started, section 4). `Prerequisites\Install-OpenSSHServer.ps1` does the server's part in one step: on the server, or on several servers through `Invoke-Command` from a Windows admin machine (Getting Started, section 4, "The quick way"). For every connector in one OU, use `Deploy-OpenSSH-GPO.ps1` (below), or push the same script with your configuration tool.
- WinRM route: confirm `Test-WSMan <connector>` answers.
- Check each connector has at least 3 GB free on `C:`. The tool warns below that.
- If a PowerShell module-logging policy applies to the connectors, arrange an exception for the run. The tool refuses to start under it.
- If the connectors run an endpoint-protection product with a firewall of its own, open port 22 there as well, for `C:\Windows\System32\OpenSSH\sshd.exe`: it can drop SSH while Windows Firewall lets it in and ping still answers.

### Many connectors: Deploy-OpenSSH-GPO.ps1

`Prerequisites\Deploy-OpenSSH-GPO.ps1` makes one Group Policy object (GPO) that runs `Install-OpenSSHServer.ps1` as a computer startup script, with your public keys and the networks allowed to reach port 22, and links it to one organizational unit (OU). Every computer in that OU, and in the OUs under it, runs it at its next restart.

1. Put the connectors' computer accounts in an OU of their own. The script refuses the domain root unless you add `-AllowDomainRoot` and `-AllowDomainControllers`, an OU with a domain controller in it or under it unless you add `-AllowDomainControllers`, and a container such as `CN=Computers`, which Group Policy cannot be linked to.
2. Run it in Windows PowerShell 5.1 on a domain-joined Windows machine that has the Group Policy Management tools and the Active Directory module (on Windows Server: `Install-WindowsFeature GPMC, RSAT-AD-PowerShell`), with an account that may create GPOs, link them on the OU and write to SYSVOL. Show the plan first; `-WhatIf` changes nothing:

```
$ou = 'OU=Access Connectors,DC=example,DC=local'
.\Deploy-OpenSSH-GPO.ps1 -TargetOU $ou -PublicKeyFile .\connector_ed25519.pub `
    -AllowFrom 10.0.0.0/24 -WhatIf
```

3. Run the same command without `-WhatIf`. It shows the plan again and goes on only when you type `YES` (`-Yes` instead, for a run with nobody at the keyboard). It refuses to run without `-AllowFrom`, unless you add `-AllowFromAnyAddress`: a computer where the GPO installs OpenSSH Server then accepts port 22 from any address, through the install's own firewall rule. Rules limited before stay as they are. It writes the payload, a small startup wrapper and a settings file with the keys and networks into the GPO's own folder in SYSVOL, registers the startup script, checks all of it and links the GPO last. If a step fails, a GPO made in that run is deleted again, so nothing is left linked but empty.
4. Restart the connectors when it suits you: a startup script runs only while a computer starts, and `gpupdate` alone does not run it. One restart is enough on Windows Server. Then, elevated on each connector, `gpresult /r /scope computer` must list the GPO under Applied Group Policy Objects. The payload's own logs are in `C:\ProgramData\ssh\logs` there; its audit log holds the host key fingerprint as `hostKey=` (Getting Started, section 4.6).
5. To change the keys or a setting later, run it again with every setting: a rerun replaces the GPO's settings, and its plan lists what changes. For another OU, give it a GPO of its own with `-GpoName`: the script refuses a GPO that is linked to another OU as well, unless you add `-AllowOtherLinks`.

Keys are only added. A key taken out of the GPO stays trusted on the computers that already ran it, until its line is deleted from `C:\ProgramData\ssh\administrators_authorized_keys` there; `Deploy-OpenSSH-GPO.ps1 -Help` (UNDOING IT) has a command for it. Removing the GPO, or its link, does not remove OpenSSH Server or the keys from a computer that already ran it.

Run `Install-OpenSSHServer.ps1` by hand on one connector first, with the same settings: what only a computer can tell, such as a `-Source` folder that is not there, fails on that computer at every startup. Computers that take their updates from WSUS need Windows Update allowed for Features on Demand by policy, or a Features on Demand share the computer accounts can read, given as `-PayloadParameters @{ Source = '\\fileserver.example.local\FoD' }`.

The script is new and has not yet run against a domain: it has been tested offline only, with fake Group Policy and Active Directory modules (Validation Record).

## 5. Take a safety net

The tool keeps copies of the keytab and of the Kerberos Auth configuration before it changes them, and restarts the services if an install fails. It does not snapshot the server. For production connectors, take a virtual machine snapshot or backup before the change window and remove it once the connector is confirmed healthy.

## 6. Run the change

A sequence that has worked:

1. **Verify everything.** `-Mode Verify`. Fix anything red before you start.
2. **Dry run the tenant.** `-Tenant <name> -DryRun`. This proves every password and file before any service stops.
3. **Upgrade the first connector only.** `-Tenant <name> -Connector <first host>`. Sign in through Access and confirm the tenant still works on the remaining connector while this one is down, and on this one when it is back.
4. **Upgrade the rest of the tenant.** `-Tenant <name>`. Connectors already on the new version are skipped by the installer step.
5. **Verify again.** `-Mode Verify`.
6. **Check the Access console.** Connectors page: each connector and service should show as active on the new version.
7. **Test a sign-in** by each method the connector serves, including a Kerberos sign-in where Kerberos Auth is installed.

Allow about ten minutes per connector. In testing each connector took between nine and eighteen minutes.

### Faster, with more risk

| Switch | Effect |
|---|---|
| `-ParallelTenants` | Fleet entries run side by side, one connector at a time in each. Each multi-connector entry still keeps one online. If an Access tenant is split over two entries (connector groups with different services), one connector from each can be down together. |
| `-Parallel` | Everything at once. Every tenant is offline until its connectors finish and a failure cannot stop the others, except a WinRM sign-in that a connector refuses: the connectors not yet started are then left alone. For labs and for single-connector tenants. |

Neither has been through a real run yet (see the Validation Record).

### Unattended

Add `-Yes` to skip the confirmation. Passwords are still asked at prompts unless you pass credentials as objects (`-Credential`, `-RunAsCredential`); the configuration, PFX and service account passwords are always prompted in SSH and WinRM modes. A run started with no terminal (with its input redirected, or with `pwsh -NonInteractive`; start scheduled runs with `pwsh -NonInteractive`, because a scheduler that gives the run a console is not detected otherwise) cannot answer them: it stops at the first prompt with exit code 1, an error-log and an audit entry, before anything is copied to a connector. (An SSH run checks the SSH sign-in on every selected connector before its first prompt, and stops there, naming SSH's reason, if one fails. In 1.4.1 a run with its input redirected ended silently with exit code 0.) For a change window with nobody present, use Stage mode:

1. `-Mode Stage -Tenant <name>` copies everything and writes `Run-Upgrade.cmd`.
2. On each connector, signed in as a domain admin:

```powershell
powershell -ExecutionPolicy Bypass -File C:\ProgramData\AccessConnectorUpdate\Invoke-ConnectorUpgradeLocal.ps1 -Prompt -Schedule "2027-01-15 22:30"
```

The passwords are typed now and stored encrypted for that account; the task runs at the time given. Stagger the times so two connectors of one tenant do not run together. Check each with `-Mode Verify` afterwards. The task deletes itself, and with it the account's Windows password that Task Scheduler keeps, when the run ends, or 12 hours after the time given if it has not run by then (1.5.1; not yet run on a connector). A time that has already passed on the connector's clock is refused, and so is a new time while an earlier scheduled run there is still running; nothing is written then.

## 7. Clean installs and service changes

- **New server:** add it to the fleet entry and run the normal command with `-Connector <host>`. See Getting Started, section 10.
- **Reinstall a broken connector:** `-ForceReinstall -Connector <host>`.
- **Add or remove a service on an installed connector:** change `Services` in its fleet entry and run with `-ForceReinstall`. Do not try a silent `msiexec ... REMOVE=<feature>`; it fails and damages the connector's saved settings (Engineering Notes).
- **After removing Kerberos Auth:** disable the Active Directory user account named after that connector, which the vendor set-up created.

## 8. Routine operations

| Task | Command |
|---|---|
| Health report | `-Mode Verify` |
| Fleet kept in a spreadsheet | Change the sheet; `-ImportFleet <file> -DryRun`, then without `-DryRun` |
| Next connector release | New installer in `Installers`; update `Installer`, `InstallerVersion`, `ExpectVersionPrefix`; dry run; upgrade |
| Certificate renewal for Kerberos Auth | New PFX in `ChildCerts` (same or new file name in `Pfx`); `-Mode RepairCertificate -DryRun`, then without `-DryRun` |
| Empty keytab | `-Mode RepairKeytab` |
| Audit trail | Run with `-AuditLog <folder>` every time; one line is appended per run |

Verify marks a certificate that has expired, so a scheduled `-Mode Verify` doubles as a certificate check. Since 1.5.1 its exit code is 1 when any connector could not be read or has a red line (a service down, the keytab empty or missing, a wrong certificate for a group with a `Pfx`), and the error log names what is red; a yellow line (nothing installed, a Java process without the patch flag) keeps exit code 0, so look at the output as well.

## 9. Rolling back

The tool does not downgrade a connector. If an upgrade leaves a connector unhealthy:

1. Read the message: it names each failed check. Many have a direct fix (`RepairKeytab`, `RepairCertificate`, a restart).
2. If the installer itself failed, the tool has already restarted the services that were running before. Check with `-Mode Verify`.
3. If the connector cannot be recovered, restore the snapshot or backup from step 5, or uninstall and clean install the previous version by pointing a fleet entry at the previous installer.

Because the run stops at the first unhealthy connector, the tenant's other connectors are still on the old version and still serving.

## 10. Keeping the tool itself up to date

1. Pull the new version of this repository.
2. Copy `FleetDeploy/Invoke-AccessConnectorUpgrade.ps1`, `FleetDeploy/Invoke-ConnectorUpgradeLocal.ps1` and `Silent Install/Install-AccessConnector.ps1` to every staging folder, keeping the previous files as dated backups. Copy the spreadsheet templates (`FleetDeploy/fleet.example.xlsx`, `fleet.example.csv`) as well if you use them.
3. Run `-Help` to confirm the version, then `-Mode Verify`.

Do not update the scripts while a run is in progress.
