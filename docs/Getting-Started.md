# Getting Started

Access Connector Automated Upgrade installs, upgrades and repairs Omnissa Access Connectors from one command. It works with any connector version: the version installed is whichever installer file you name in the fleet file.

This guide takes you from nothing to a first upgrade in any environment. It covers the two ways the tool can reach a connector (SSH and WinRM), how to stand up SSH on a Windows server, clean installs on new servers, and how to choose which connector services are installed.

> **Unsupported.** This tool is not an Omnissa product and is not covered by Omnissa support. It is provided "as is", with no warranty. Test it in a lab before you use it on production connectors. The full disclaimer is shown by `-Help`.

## 1. What the tool does

You run one script, `Invoke-AccessConnectorUpgrade.ps1`, on an admin machine. It reads a fleet file that lists your tenants and their connectors. For each connector it:

1. Copies the installer, the tenant configuration file, the trust certificates and (for Kerberos connectors) the PFX to a locked folder on the connector.
2. Runs a helper script there, which runs the vendor installer silently, with pre-flight checks first.
3. Checks the result: the installed version, every expected service running, a usable Kerberos keytab, and the right certificate on the Kerberos Auth service.
4. Stops if the connector is not healthy, so the next connector in that tenant is left untouched and stays online.

Connectors inside a tenant are done one at a time. A tenant with two or more connectors keeps one online throughout.

| What you want | How |
|---|---|
| Upgrade existing connectors | Point the fleet file at the new installer and run the tool |
| Clean install on a new server | Same command; a server with no connector gets a fresh install |
| Same-version clean reinstall | Add `-ForceReinstall` (uninstalls, then installs fresh) |
| Choose the services | `Services` in the fleet file, per connector or group of connectors |
| See the state, change nothing | `-Mode Verify` |
| Rehearse without installing | `-DryRun` |
| Fix an empty Kerberos keytab | `-Mode RepairKeytab` |
| Fix the Kerberos certificate | `-Mode RepairCertificate` |

## 2. What you need

| Item | Detail |
|---|---|
| Admin machine | macOS, Linux or Windows with PowerShell 7 or later (`pwsh`). The tool will not start under Windows PowerShell 5.1. WinRM mode needs Windows. |
| Reach to the connectors | SSH with key sign-in (port 22), or PowerShell remoting (WinRM, ports 5985/5986) |
| Connector installer | The Omnissa Access Connector installer `.exe` for the version you want |
| Tenant configuration file | The `es-config.json` from the Access console, and its password |
| Service account | Needed when a connector runs Kerberos Auth or Virtual App: the account name and its password |
| Kerberos PFX | Needed for Kerberos Auth: a PFX whose certificate names every connector it is used on, and its password |
| Domain admin account | Needed for Kerberos Auth connectors: the upgrade runs under it so the keytab can be rebuilt |
| CA certificates | Optional: `.pem`, `.cer` or `.crt` files the connector should trust |

The connectors themselves need only what the Omnissa installer needs, plus Windows PowerShell 5.1, which Windows Server already has.

## 3. Choose how the tool reaches your connectors

| | SSH mode (default) | WinRM mode | Stage mode |
|---|---|---|---|
| Admin machine | macOS, Linux or Windows | Windows only | macOS, Linux or Windows |
| Sign-in | SSH key | Domain credential, asked per tenant | SSH key to copy; you run it on the connector |
| Upgrade and clean install | Yes | Yes | Yes, by hand or scheduled on the connector |
| Verify, RepairKeytab, RepairCertificate | Yes | No, these use SSH | No |
| Logs copied back to one folder | Yes | No, they stay on the connector | No |
| Set-up work | Enable OpenSSH Server on each connector | Usually none on domain-joined servers | Same as SSH |

**Recommendation:** use SSH if you can. Every mode works over it, and it is the route with the most testing. Use WinRM when policy does not allow SSH on the servers; you can still upgrade and clean install, but you lose the report and repair modes. You can mix the two: WinRM for upgrades and SSH on a few servers for the repair modes.

## 4. Stand up SSH on a Windows server

Do this once on each connector. It takes about five minutes. Run the commands in an elevated Windows PowerShell window on the connector.

### 4.1 Install and start OpenSSH Server

```
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
```

On Windows Server 2025 the component is already present and the first line simply reports that. On Windows Server 2019 and 2022 it is downloaded from Windows Update; a server with no internet access needs the Features on Demand media or your WSUS to supply it.

### 4.2 Check the firewall rule

The installation creates an inbound rule for port 22. Confirm one is enabled:

```
Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP*' | Format-Table Name, Enabled
```

If none is enabled, create one and limit it to your admin machine or management subnet:

```
New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP-Mgmt' `
    -DisplayName 'OpenSSH Server (management)' `
    -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow `
    -RemoteAddress 10.0.0.0/24
```

Replace `10.0.0.0/24` with your own management network.

### 4.3 Create a key on the admin machine

On the admin machine (not the connector):

```
ssh-keygen -t ed25519 -f ~/.ssh/connector_ed25519 -C "access-connector-upgrade"
```

Give the key a passphrase and load it into your SSH agent, or leave the passphrase empty and protect the file. The tool never asks for an SSH password: if the key is refused, the run stops. Show the public half with:

```
cat ~/.ssh/connector_ed25519.pub
```

### 4.4 Authorise the key on the connector

The tool signs in with an account that is a member of the local Administrators group. For those accounts Windows reads keys from one shared file, not from the user profile. On the connector, paste your public key between the quotes:

```
$key  = 'ssh-ed25519 AAAA...your public key... access-connector-upgrade'
$file = 'C:\ProgramData\ssh\administrators_authorized_keys'
Add-Content -Force -Path $file -Value $key
icacls.exe $file /inheritance:r /grant "*S-1-5-32-544:F" /grant "*S-1-5-18:F"
```

The last line matters. OpenSSH ignores the file unless only Administrators and SYSTEM can access it.

### 4.5 Turn off password sign-in (recommended)

Open `C:\ProgramData\ssh\sshd_config` in Notepad as administrator and make sure these two lines are present and not commented out:

```
PubkeyAuthentication yes
PasswordAuthentication no
```

Then restart the service:

```
Restart-Service sshd
```

### 4.6 Test from the admin machine

```
ssh -i ~/.ssh/connector_ed25519 administrator@connector1.example.local hostname
```

You should see the server name with no password prompt. If you are asked for a password, the key was not accepted: recheck step 4.4, especially the `icacls` line.

### 4.7 Tell SSH which key to use (optional)

To save typing `-SshKey` on every command, add the key to the SSH configuration file on the admin machine (`~/.ssh/config`; on Windows `%USERPROFILE%\.ssh\config`):

```
Host *.example.local
    IdentityFile ~/.ssh/connector_ed25519
```

The commands in this guide assume you have done this. If you have not, add `-SshKey ~/.ssh/connector_ed25519` to each one.

> **Which account?** Any account in the connector's local Administrators group works. The built-in local `administrator` was used in testing. Name a different account per connector with `SshUser` in the fleet file, or for a whole run with `-SshUser`.

> **Default shell.** You do not need to change the OpenSSH default shell. The tool starts Windows PowerShell 5.1 by name. Testing was done on servers whose default shell had been set to PowerShell 7; the stock default (cmd.exe) is expected to work but has not been tested.

## 5. Or use WinRM (PowerShell remoting)

Use this route from a Windows admin machine when SSH is not an option.

1. Install PowerShell 7 on the admin machine.
2. Sign in to the admin machine with, or be ready to type, a domain account that is an administrator on the connectors.
3. Confirm remoting answers on each connector. It is on by default on Windows Server:

```
Test-WSMan connector1.example.local
```

If that fails, run `Enable-PSRemoting -Force` in an elevated PowerShell window on the connector and check that the firewall allows port 5985 from the admin machine.

Then add `-Mode WinRM` to the upgrade commands in this guide. The tool asks for the domain sign-in once per tenant.

What to know about WinRM mode:

- Upgrades and clean installs work. `-Mode Verify`, `-Mode RepairKeytab` and `-Mode RepairCertificate` always use SSH.
- Each connector's logs stay on the connector in `C:\ProgramData\AccessConnectorUpdate\Logs`. They are not copied back.
- Kerberos Auth connectors are upgraded through a one-time scheduled task under the sign-in you give, or directly with `-Authentication CredSSP` if you have CredSSP set up. Neither has been proven in testing yet; WinRM mode has been proven on connectors without Kerberos Auth.

## 6. Build the staging folder

The staging folder holds the tool and the files it installs. It can be a local folder on the admin machine or a file share. It must be readable from the admin machine; the connectors do not need to reach it, because every file is copied to them.

Clone or download this repository and use it as the staging folder. It already has the layout:

```
<staging folder>/
    FleetDeploy/        the tool, your fleet file, and the FleetLogs folder
    Silent Install/     Install-AccessConnector.ps1 (runs the vendor installer)
    Installers/         the connector installer .exe (you add this)
    Configs/            one es-config .json per tenant (you add these)
    ChildCerts/         the Kerberos PFX (Kerberos connectors only)
    TrustedCerts/       CA certificates to trust (optional)
```

Add your own files:

1. Put the connector installer in `Installers`.
2. Put each tenant's `es-config.json` in `Configs`, each with its own file name.
3. For Kerberos connectors, put the PFX in `ChildCerts`.
4. Put any CA certificates the connector must trust in `TrustedCerts`.
5. If your connector version needs the Java4Shell patch (Omnissa HW-283446, for 26.05 and 26.10), unzip it into `Installers\Java4shellPatch`.

No passwords go in any file. They are asked for at hidden prompts when you run the tool.

## 7. Write the fleet file

In `FleetDeploy`, copy `fleet.example.psd1` to `fleet.psd1` and edit it. Each entry describes one connector group: usually all the connectors of a tenant, but see section 11 for giving one connector or a few of them different services.

```
@{
  Name                = 'TENANT1'
  Installer           = 'Installers\Access-Connector-Installer.exe'
  ExpectVersionPrefix = '26.10'
  ConfigFile          = 'Configs\tenant1-es-config.json'
  TrustStore          = 'TrustedCerts'
  Pfx                 = 'ChildCerts\connector.example.local.pfx'
  Services            = 'DirectorySyncService,UserAuthService,KerberosAuthService'
  ServiceAccount      = 'EXAMPLE\svc-access'
  Syslog              = 'syslog.example.local:514'
  Connectors = @(
      @{ Host = 'connector1.example.local'; SshUser = 'administrator' }
      @{ Host = 'connector2.example.local'; SshUser = 'administrator' }
  )
}
```

| Setting | Meaning |
|---|---|
| `Name` | Your label for this connector group. Used with `-Tenant`. |
| `Installer` | The installer to run. This is what sets the version. |
| `ExpectVersionPrefix` | Optional. The run fails its health check unless the installed version starts with this. |
| `ConfigFile` | The tenant's `es-config.json`. |
| `Services` | The connector services to install. See section 11. |
| `Pfx` | Kerberos Auth only. Leave it out when Kerberos Auth is not installed. |
| `ServiceAccount` | Needed when Kerberos Auth or Virtual App is installed. |
| `Syslog`, `TrustStore` | Optional. |
| `InstallDir`, `EnableFips`, the four `...Port` settings, `ProxyHost`, `ProxyPort`, `ProxyUser`, `NonProxyHosts` | Optional installer settings: install folder, FIPS mode, service ports, outbound proxy. Leave them out for the installer defaults. With `ProxyUser` the proxy password is asked at run time. See `docs/Fleet-File-Reference.md`. |
| `Connectors` | The servers, in the order they are done. |

To move to a different connector version later, put the new installer in `Installers` and change `Installer` (and `ExpectVersionPrefix`). Nothing else in the tool is tied to a version. The full list of settings is in `docs/Fleet-File-Reference.md`.

## 8. Your first run

Open a terminal on the admin machine, go to the `FleetDeploy` folder and start PowerShell 7 by typing `pwsh`. On Windows, start it as `pwsh -ExecutionPolicy Bypass` if your policy blocks scripts run from a share. Type the commands below at its prompt, in order. A backtick at the end of a line means the command continues on the next line.

### 8.1 Verify: look, change nothing

```
./Invoke-AccessConnectorUpgrade.ps1 -Mode Verify
```

Each connector gets one line: installed version, services running, and for Kerberos connectors the keytab and the certificate served. This proves that sign-in works and the fleet file is right. (Verify copies the helper script to the connector; it changes nothing else.)

### 8.2 Dry run: rehearse one tenant

```
./Invoke-AccessConnectorUpgrade.ps1 -Tenant TENANT1 -DryRun
```

This copies the files and runs every pre-flight check: the PFX opens with the password you typed, the configuration file is valid, the service account password works, the domain admin account can start the task. Nothing is installed. Fix anything it reports and repeat until it says `DryRunPassed`.

The checks run on every connector, also one that is already on the installer's version. A real run would skip such a connector, and the dry run says so in a note: "A real run would SKIP this connector". Add `-ForceReinstall` if you want it reinstalled.

### 8.3 The real run

```
./Invoke-AccessConnectorUpgrade.ps1 -Tenant TENANT1
```

The tool shows the plan, asks you to type `YES`, then asks for the passwords once per tenant. Allow roughly ten minutes per connector, during which that connector's services are down. The run ends with a summary and writes a CSV and the connectors' logs to `FleetDeploy\FleetLogs`.

If you are using WinRM, add `-Mode WinRM` to the dry run and the real run:

```
./Invoke-AccessConnectorUpgrade.ps1 -Mode WinRM -Tenant TENANT1 -DryRun
./Invoke-AccessConnectorUpgrade.ps1 -Mode WinRM -Tenant TENANT1
```

To start a run in one line from another shell or a scheduler, put `pwsh` in front (on Windows, `pwsh -ExecutionPolicy Bypass -File`):

```
pwsh ./Invoke-AccessConnectorUpgrade.ps1 -Tenant TENANT1 -DryRun
```

### What you are asked for

| Prompt | When |
|---|---|
| Configuration file (es-config) password | Always |
| Kerberos PFX password | When the tenant has a `Pfx` |
| Service account password | When the tenant installs Kerberos Auth or Virtual App |
| Domain admin account and password | Kerberos Auth tenants in SSH mode; every tenant in WinRM mode |
| Proxy password | When the tenant has `ProxyUser` |

Typing is hidden. Passwords are never written to the fleet file, a command line of this tool, or its logs.

## 9. Kerberos Auth connectors

Three things are different when a connector runs the Kerberos Auth service. The tool handles all three; this section explains what you will see.

**The upgrade runs under a domain admin account.** The vendor set-up step that builds the Kerberos keytab has to query Active Directory. A remote sign-in cannot do that, so the tool starts the work on the connector as a one-time scheduled task under the domain admin account you type. The task removes itself when it ends.

**The keytab is checked.** After the install the tool confirms the keytab holds keys. If `-Mode Verify` ever shows `keytab EMPTY`, run:

```
./Invoke-AccessConnectorUpgrade.ps1 -Mode RepairKeytab -Tenant TENANT1
```

**The certificate is put back.** When an existing connector is upgraded, the vendor installer does not keep your PFX certificate; it makes a self-signed one of its own. The tool puts your PFX certificate back at the end of the upgrade and confirms it is the one being served. To do only that step at any time:

```
./Invoke-AccessConnectorUpgrade.ps1 -Mode RepairCertificate -Tenant TENANT1
```

## 10. Clean install on a new server

A clean install uses the same command as an upgrade. When the tool finds no connector on a server it reports "No connector services are registered on this server yet" and carries on with a fresh installation.

1. Build the server to Omnissa's requirements for the connector version, and join it to the domain if it will run Kerberos Auth or Virtual App.
2. Stand up SSH on it (section 4), or confirm WinRM answers (section 5).
3. Add the server to a tenant's `Connectors` list in the fleet file.
4. Run the dry run, then the real run, with `-Connector` to act on that server only:

```
./Invoke-AccessConnectorUpgrade.ps1 -Tenant TENANT1 -DryRun `
    -Connector connector3.example.local

./Invoke-AccessConnectorUpgrade.ps1 -Tenant TENANT1 `
    -Connector connector3.example.local
```

To wipe and reinstall a connector that is already on the version you want, add `-ForceReinstall` to the same commands. The tool uninstalls the connector, then installs it fresh with the settings in the fleet file. This is also how you remove a service from a connector (section 11).

## 11. Choose which services are installed

Services are chosen per **connector group**. A connector group is one entry in the fleet file's `Tenants` list: a `Name`, the settings for those connectors, and the list of connectors they apply to. A group can hold one connector or many.

Set `Services` in the group's entry. Use any combination of these four names, separated by commas:

| Name | Service |
|---|---|
| `DirectorySyncService` | Directory Sync |
| `UserAuthService` | User Auth |
| `KerberosAuthService` | Kerberos Auth (needs `Pfx`, `ServiceAccount` and a domain admin at run time) |
| `VirtualAppService` | Virtual App (needs `ServiceAccount`) |

### 11.1 The same services on every connector of a tenant

One group for the tenant. This is the usual case, and the example in section 7.

### 11.2 Different services for a group of connectors

Make one group per set of services. Groups that belong to the same Access tenant share the same `ConfigFile`; each group needs its own `Name`.

```
@{
  Name       = 'TENANT1-KERB'
  ConfigFile = 'Configs\tenant1-es-config.json'
  Services   = 'DirectorySyncService,UserAuthService,KerberosAuthService'
  Pfx        = 'ChildCerts\connector.example.local.pfx'
  # ... Installer, ServiceAccount and the other settings ...
  Connectors = @(
    @{ Host = 'connector1.example.local' }
    @{ Host = 'connector2.example.local' }
  )
}

@{
  Name       = 'TENANT1-SYNC'
  ConfigFile = 'Configs\tenant1-es-config.json'
  Services   = 'DirectorySyncService,UserAuthService'
  # ... Installer and the other settings; no Pfx, no ServiceAccount ...
  Connectors = @(
    @{ Host = 'connector3.example.local' }
    @{ Host = 'connector4.example.local' }
  )
}
```

Run a group by its name:

```
./Invoke-AccessConnectorUpgrade.ps1 -Tenant TENANT1-SYNC -DryRun
./Invoke-AccessConnectorUpgrade.ps1 -Tenant TENANT1-SYNC
```

### 11.3 Different services for a single connector

The same thing with one connector in the group:

```
@{
  Name       = 'TENANT1-CONN5'
  ConfigFile = 'Configs\tenant1-es-config.json'
  Services   = 'DirectorySyncService'
  # ... Installer and the other settings ...
  Connectors = @( @{ Host = 'connector5.example.local' } )
}
```

List each connector in one group only.

`-Connector` is different: it limits a run to the servers you name, but each server still gets the services of the group it is listed in.

```
./Invoke-AccessConnectorUpgrade.ps1 -Tenant TENANT1-KERB `
    -Connector connector2.example.local
```

### 11.4 Things to know about groups

- Connectors are done one at a time inside a group, and groups run one after another. So a plain run never has two connectors down at once, even when two groups belong to the same Access tenant.
- `-ParallelTenants` runs groups side by side. Do not use it across two groups of the same Access tenant unless you accept one connector from each being down together.
- A run that names no group (`-Tenant` left out) does every group in the fleet file, top to bottom.
- `-Mode RepairKeytab` and `-Mode RepairCertificate` leave out groups that do not install Kerberos Auth, and say so.

### 11.5 Change the services on a connector that is already installed

Move the connector to a group with the services you want (or change that group's `Services`), then run with `-ForceReinstall`:

```
./Invoke-AccessConnectorUpgrade.ps1 -Tenant TENANT1-SYNC -ForceReinstall `
    -Connector connector3.example.local
```

The tool uninstalls the connector and installs it fresh with the new set. The vendor installer cannot add or remove a service silently on an installed connector, so a clean reinstall is the supported automated route. If you removed Kerberos Auth, disable the Active Directory user account named after that connector afterwards; the vendor set-up created it.

## 12. After the run

| Where | What |
|---|---|
| Screen | A line per connector and a summary grouped by tenant |
| `FleetDeploy\FleetLogs\ConnectorUpgrade_<date>_<time>.csv` | Tenant, connector, status, version before and after, exit codes |
| `FleetDeploy\FleetLogs\<tenant>_<connector>_<date>_<time>\` | That connector's logs (SSH mode) |
| `C:\ProgramData\AccessConnectorUpdate\Logs` on the connector | The same logs at the source |
| `-AuditLog <path>` | One appended line per run: who ran what, and the outcome |
| `-ErrorLog <path>` | The detail of each failure |

The exit code is 0 when every selected connector succeeded and 1 otherwise, so a scheduler can tell.

| Status | Meaning |
|---|---|
| `Success` | Installed and healthy |
| `DryRunPassed` / `DryRunFailed` | Result of the pre-flight checks; nothing installed |
| `Blocked` | Refused before anything was changed; the message says why |
| `Failed` | The installer failed; services that were running before are started again |
| `Unhealthy` | Installed, but a check afterwards did not pass; the message says which |
| `Skipped` | Not attempted because an earlier connector failed |
| `Error` | The tool could not reach the connector or got no result back |

## 13. If something goes wrong

| What you see | What to do |
|---|---|
| `ssh ... Permission denied` or a password prompt in your own test | The key is not accepted. Recheck section 4.4 and the `icacls` line. |
| "Files this run needs are missing" | A file named in the fleet file is not in the staging folder. The message lists each one, and names another copy of the folder if one has them. |
| `DryRunFailed` | Read the lines above it: a wrong PFX or service account password, or an invalid configuration file. Nothing was changed. |
| "Could not start the task as ..." | The domain admin account name or password was wrong. Nothing was changed. |
| "cannot query Active Directory" | A Kerberos connector was run without a domain admin account. Run it again and give the account at the prompt. |
| `keytab EMPTY` in Verify | Run `-Mode RepairKeytab`. |
| Certificate shown as `SELF-SIGNED by the installer` | Run `-Mode RepairCertificate`. |
| "writes PowerShell command parameters to its event log" | The server's module logging policy would record the passwords. Turn it off for that server while the run happens. |

More cases are in `docs/Troubleshooting.md`.

## 14. Where to read more

| Document | Contents |
|---|---|
| `README.md` | Overview and quick reference |
| `docs/Implementation-Guide.md` | Planning a roll-out, several domains or shares, scheduling, operations |
| `docs/Command-Reference.md` | Every mode and parameter |
| `docs/Fleet-File-Reference.md` | Every fleet file setting |
| `docs/Security.md` | How passwords and files are handled |
| `docs/Troubleshooting.md` | Problems and fixes |
| `docs/Engineering-Notes.md` | What was learned about the vendor installer |
| `docs/Validation-Record.md` | What has been proven in testing, and what has not |
| `CHANGELOG.md`, `ROADMAP.md` | History and what is planned |
