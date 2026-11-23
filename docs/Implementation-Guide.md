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
| Current version | `-Mode Verify` will tell you |

`-Mode Verify` against a first draft of the fleet file is the quickest way to fill most of this in.

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
| SSH not allowed on the servers | WinRM for installs; no Verify or repair modes |
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

- SSH route: stand up OpenSSH Server with key sign-in on each connector (Getting Started, section 4). For many servers, push the same four steps with Group Policy, your configuration tool, or a one-off remoting loop.
- WinRM route: confirm `Test-WSMan <connector>` answers.
- Check each connector has at least 3 GB free on `C:`. The tool warns below that.
- If a PowerShell module-logging policy applies to the connectors, arrange an exception for the run. The tool refuses to start under it.

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
| `-Parallel` | Everything at once. Every tenant is offline until its connectors finish and a failure cannot stop the others. For labs and for single-connector tenants. |

Neither has been through a real run yet (see the Validation Record).

### Unattended

Add `-Yes` to skip the confirmation. Passwords are still asked at prompts unless you pass credentials as objects (`-Credential`, `-RunAsCredential`); the configuration, PFX and service account passwords are always prompted in SSH and WinRM modes. For a change window with nobody present, use Stage mode:

1. `-Mode Stage -Tenant <name>` copies everything and writes `Run-Upgrade.cmd`.
2. On each connector, signed in as a domain admin:

```powershell
powershell -ExecutionPolicy Bypass -File C:\ProgramData\AccessConnectorUpdate\Invoke-ConnectorUpgradeLocal.ps1 -Prompt -Schedule "2027-01-15 22:30"
```

The passwords are typed now and stored encrypted for that account; the task runs at the time given. Stagger the times so two connectors of one tenant do not run together. Check each with `-Mode Verify` afterwards.

## 7. Clean installs and service changes

- **New server:** add it to the fleet entry and run the normal command with `-Connector <host>`. See Getting Started, section 10.
- **Reinstall a broken connector:** `-ForceReinstall -Connector <host>`.
- **Add or remove a service on an installed connector:** change `Services` in its fleet entry and run with `-ForceReinstall`. Do not try a silent `msiexec ... REMOVE=<feature>`; it fails and damages the connector's saved settings (Engineering Notes).
- **After removing Kerberos Auth:** disable the Active Directory user account named after that connector, which the vendor set-up created.

## 8. Routine operations

| Task | Command |
|---|---|
| Health report | `-Mode Verify` |
| Next connector release | New installer in `Installers`; update `Installer`, `InstallerVersion`, `ExpectVersionPrefix`; dry run; upgrade |
| Certificate renewal for Kerberos Auth | New PFX in `ChildCerts` (same or new file name in `Pfx`); `-Mode RepairCertificate -DryRun`, then without `-DryRun` |
| Empty keytab | `-Mode RepairKeytab` |
| Audit trail | Run with `-AuditLog <folder>` every time; one line is appended per run |

Verify marks a certificate that has expired, so a scheduled `-Mode Verify` doubles as a certificate check. Its exit code is 1 only when a connector could not be read, so look at the output, not just the code.

## 9. Rolling back

The tool does not downgrade a connector. If an upgrade leaves a connector unhealthy:

1. Read the message: it names each failed check. Many have a direct fix (`RepairKeytab`, `RepairCertificate`, a restart).
2. If the installer itself failed, the tool has already restarted the services that were running before. Check with `-Mode Verify`.
3. If the connector cannot be recovered, restore the snapshot or backup from step 5, or uninstall and clean install the previous version by pointing a fleet entry at the previous installer.

Because the run stops at the first unhealthy connector, the tenant's other connectors are still on the old version and still serving.

## 10. Keeping the tool itself up to date

1. Pull the new version of this repository.
2. Copy `FleetDeploy/Invoke-AccessConnectorUpgrade.ps1`, `FleetDeploy/Invoke-ConnectorUpgradeLocal.ps1` and `Silent Install/Install-AccessConnector.ps1` to every staging folder, keeping the previous files as dated backups.
3. Run `-Help` to confirm the version, then `-Mode Verify`.

Do not update the scripts while a run is in progress.
