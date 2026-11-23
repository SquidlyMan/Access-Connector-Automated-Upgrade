# Getting Started

Access Connector Automated Upgrade installs, upgrades and repairs Omnissa Access Connectors from one command. It works with any connector version: the version installed is whichever installer file you name in the fleet file.

This guide takes you from nothing to a first upgrade in any environment. It covers the two ways the tool can reach a connector (SSH and WinRM), how to stand up SSH on a Windows server, clean installs on new servers, and how to choose which connector services are installed.

<!-- disclaimer -->
> [!CAUTION]
> **LEGAL DISCLAIMER - UNSUPPORTED, USE AT YOUR OWN RISK**
>
> This script is an UNSUPPORTED utility. It is NOT an Omnissa product or offering, and it is not covered by any Omnissa support, maintenance, or service-level agreement.
>
> It is provided "AS IS" and "AS AVAILABLE", WITHOUT WARRANTY OF ANY KIND, express or implied, including but not limited to the implied warranties of merchantability, fitness for a particular purpose, title, and non-infringement.
>
> YOU USE IT ENTIRELY AT YOUR OWN RISK. You are solely responsible for validating its behaviour, for safeguarding the credentials you supply to it, and for any effect it has on your environment or data.
>
> TO THE MAXIMUM EXTENT PERMITTED BY LAW, NEITHER OMNISSA NOR THE AUTHOR SHALL BE LIABLE FOR ANY CLAIM, LOSS, OR DAMAGES WHATSOEVER - direct, indirect, incidental, special, exemplary, or consequential (including loss of data, revenue, or profits) - arising from or in connection with the use of, or inability to use, this script.
>
> Use of the Omnissa products is governed by your agreement with Omnissa; customers assume all responsibility for automated changes to them.
<!-- /disclaimer -->

Test the tool in a lab before you use it on production connectors. Each script also shows this disclaimer with `-Help`.

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
| Write the fleet file from a spreadsheet | `-ImportFleet <file>` (section 7.1) |
| Read installed connectors into a spreadsheet | `-Mode Discover` (section 7.2) |
| Rehearse without installing | `-DryRun` |
| Fix an empty Kerberos keytab | `-Mode RepairKeytab` |
| Fix the Kerberos certificate | `-Mode RepairCertificate` |

## 2. What you need

| Item | Detail |
|---|---|
| Admin machine | macOS, Linux or Windows with PowerShell 7 or later (`pwsh`). The tool will not start under Windows PowerShell 5.1. WinRM mode needs a Windows admin machine. The connector servers themselves need only the Windows PowerShell 5.1 that Windows Server includes, over WinRM or SSH. If you use a connector server as the admin machine, install PowerShell 7 on it as well. |
| Reach to the connectors | SSH with key sign-in (port 22), or PowerShell remoting (WinRM, ports 5985/5986). With WinRM, SSH is not needed for upgrades and clean installs. `-Mode Verify`, `-Mode Discover`, `-Mode Stage` and the two repair modes always use SSH. |
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
| Verify, Discover, RepairKeytab, RepairCertificate | Yes | No, these use SSH | No |
| Logs copied back to one folder | Yes | No, they stay on the connector | No |
| Set-up work | Enable OpenSSH Server on each connector | Usually none on domain-joined servers | Same as SSH |

**Recommendation:** use SSH if you can. Every mode works over it, and it is the route with the most testing. Use WinRM when policy does not allow SSH on the servers; you can still upgrade and clean install, but you lose the report, discovery and repair modes. You can mix the two: WinRM for upgrades and SSH on a few servers for the repair modes.

## 4. Stand up SSH on a Windows server

### Why SSH, and why a key

SSH is the route that works from any admin machine (macOS, Linux or Windows) and the only one that offers every mode: upgrades, clean installs, `-Mode Verify`, `-Mode Discover`, `-Mode Stage` and both repair modes. It also brings each connector's logs back to one folder. OpenSSH Server is part of Windows Server, so nothing from outside Microsoft is installed on the connectors.

The tool signs in to the connectors with an **SSH key**, never with a password. A key pair has two halves:

- The **private key** stays on your admin machine and never leaves it.
- The **public key** is copied to each connector. It is not secret: it can only check a sign-in, not make one.

When the tool connects, the connector checks that the admin machine holds the private key that matches. Nothing that could be replayed crosses the network, and no password is typed, stored or sent for the SSH sign-in. The passwords the installer needs (configuration file, PFX, service account) are a separate matter; the tool asks for those at hidden prompts each run.

### How it is made secure

| Measure | What it protects against | Where |
|---|---|---|
| Key sign-in only, password sign-in turned off | Password guessing against the connector | 4.4, 4.5 |
| The key file on the connector readable only by Administrators and SYSTEM | Someone adding their own key | 4.4 |
| A passphrase on the private key | A copied key file being used by someone else | 4.3 |
| Port 22 open only to your admin machines or management network | Connection attempts from anywhere else | 4.2 |
| The tool never falls back to a password (`BatchMode`) | A run stopping at a prompt, or a password typed into the wrong place | Built in |
| Each connector's host key is remembered on first contact and checked on every later one | Another machine answering in the connector's place | Built in; see the note in 4.6 |

### How it is made seamless

- **One key for every connector.** Generate it once (4.3) and authorise the same public key on each connector (4.4).
- **An SSH agent holds the unlocked key.** You type the passphrase once per session (macOS can keep it in the Keychain), and every connection after that, including the dozens a run makes, signs in without a prompt.
- **An SSH configuration entry names the key** (4.7), so you do not have to add `-SshKey` to every command.
- **Many servers at once.** The four steps below are the same on every connector, so they can be pushed with Group Policy, your configuration tool or a one-off remoting loop instead of being typed on each server.

### The steps

Do this once on each connector. It takes about five minutes. Run the commands in an elevated Windows PowerShell window on the connector, except 4.3, 4.6 and 4.7, which run on the admin machine.

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

Give the key a passphrase when asked, and load it into your SSH agent so you type the passphrase once rather than on every connection:

```
# macOS: also keeps the passphrase in the Keychain
ssh-add --apple-use-keychain ~/.ssh/connector_ed25519

# Linux
ssh-add ~/.ssh/connector_ed25519

# Windows (elevated PowerShell, once): start the agent, then add the key
Set-Service ssh-agent -StartupType Automatic; Start-Service ssh-agent
ssh-add $HOME\.ssh\connector_ed25519
```

A key without a passphrase also works, but then the file itself is the only protection: anyone who can copy it can sign in to every connector. The tool never asks for an SSH password: if the key is refused, the run stops. Show the public half with:

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

**The host key.** The first time you connect, SSH shows the connector's host key fingerprint and asks whether to trust it. To be sure you are talking to the real server, compare it with the fingerprint shown on the connector itself:

```
ssh-keygen -lf C:\ProgramData\ssh\ssh_host_ed25519_key.pub
```

Answer `yes` only when they match. SSH then remembers the key and refuses the server if it ever changes. The tool accepts a host it has never seen without asking, so connecting once by hand like this before the first run is how every host key gets checked.

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

Use this route from a Windows admin machine when SSH is not an option. Upgrades and clean installs over WinRM need no SSH at all: no OpenSSH Server on the connectors, no SSH client or key on the admin machine. Section 4 can be skipped. Only `-Mode Verify`, `-Mode Discover`, `-Mode Stage`, `-Mode RepairKeytab` and `-Mode RepairCertificate` need SSH.

1. Install PowerShell 7 on the admin machine.
2. Sign in to the admin machine with, or be ready to type, a domain account that is an administrator on the connectors.
3. Confirm remoting answers on each connector. It is on by default on Windows Server:

```
Test-WSMan connector1.example.local
```

If that fails, run `Enable-PSRemoting -Force` in an elevated PowerShell window on the connector and check that the firewall allows port 5985 from the admin machine.

Then add `-Mode WinRM` to the upgrade commands in this guide. The tool asks for the domain sign-in once per tenant.

### 5.1 What you cannot do without SSH

When the connectors have no SSH, these parts of the tool are **not available**:

| Not available without SSH | What it would have done | What you can do instead |
|---|---|---|
| `-Mode Verify` | Report every connector's version, services, patch flag, keytab and certificate from the admin machine, changing nothing | Read the result of each WinRM run (it ends with the same state line). On a connector, `Invoke-ConnectorUpgradeLocal.ps1 -VerifyOnly` in the staging folder prints the same report. |
| `-Mode Discover` | Read every connector's current settings into a draft spreadsheet for the fleet file (section 7.2) | Write the spreadsheet or the fleet file by hand (section 7) |
| `-Mode RepairKeytab` | Rebuild an empty Kerberos keytab, run as a domain admin through a scheduled task | Run the helper on the connector with `-RepairKeytab`, signed in there as a domain admin |
| `-Mode RepairCertificate` | Put the PFX certificate back on the Kerberos Auth service | Run the helper on the connector with `-RepairCertificate -Prompt -CertFile <pfx>` |
| `-Mode Stage` | Copy everything to the connectors and write `Run-Upgrade.cmd`, for an upgrade you start or schedule on the server later (`-Schedule`) | Run the upgrade over WinRM at the time you want, or copy the files yourself |
| Logs copied back | Each connector's logs collected in `FleetDeploy\FleetLogs` beside the summary | The logs stay on each connector in `C:\ProgramData\AccessConnectorUpdate\Logs` |

The "instead" routes need a sign-in on the connector itself, which this tool exists to avoid, and they have not been tested from a remoting session. If you need the report and repair modes, open SSH on at least the connectors that run Kerberos Auth; the two routes can be mixed.

Everything else works over WinRM: building the fleet file from a spreadsheet (`-ImportFleet` contacts no connector), upgrades, clean installs, `-ForceReinstall` (including changing the services), `-DryRun`, one connector at a time with the health gate, `-ParallelTenants` and `-Parallel`, the summary on screen and in the CSV, the keytab check and the certificate step at the end of a Kerberos Auth upgrade, and the cleaning of the installer's log on the connector.

### 5.2 Kerberos Auth connectors over WinRM

Kerberos Auth connectors are upgraded through a one-time scheduled task under the sign-in you give, or directly with `-Authentication CredSSP` if you have CredSSP set up. Neither has been proven in testing yet; WinRM mode has been proven on connectors without Kerberos Auth.

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

You can write the fleet file by hand, as below, or fill in a spreadsheet and let the tool write it (7.1). For connectors that are already installed, the tool can read their settings into that spreadsheet for you (7.2).

To write it by hand: in `FleetDeploy`, copy `fleet.example.psd1` to `fleet.psd1` and edit it. Each entry describes one connector group: usually all the connectors of a tenant, but see section 11 for giving one connector or a few of them different services.

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

### 7.1 Or fill in a spreadsheet

If you would rather keep the fleet in Excel, fill in a spreadsheet with one row per connector and let the tool write the fleet file from it. The tool checks the spreadsheet before it writes anything, and contacts no connector while it does this. Excel is not needed on the admin machine.

1. In `FleetDeploy`, copy `fleet.example.xlsx` to `fleet.xlsx`, or another name of your own. Fill in the copy, not the template: the templates are part of the tool's repository. (`fleet.example.csv` holds the same rows as a CSV file, if you prefer one.)
2. On the `Fleet` sheet, replace the example rows with one row per connector. The `Columns` sheet explains each column.
3. Save it. In a terminal in the `FleetDeploy` folder, check it. Nothing is written:

```
pwsh ./Invoke-AccessConnectorUpgrade.ps1 -ImportFleet ./fleet.xlsx -DryRun
```

4. It shows the groups and connectors it found, and lists any problems. Correct them in the spreadsheet and repeat until it shows none. Then write the fleet file:

```
pwsh ./Invoke-AccessConnectorUpgrade.ps1 -ImportFleet ./fleet.xlsx
```

The columns are the fleet file settings above, one row per connector:

| Column | Set for | Meaning |
|---|---|---|
| `Group` | Each connector | The connector group it belongs to: the `Name` above. Rows with the same `Group` make one group. |
| `Host`, `SshUser` | Each connector | As in `Connectors` above |
| `Installer`, `ConfigFile`, `Services` | The group | Required |
| `ServiceAccount`, `Pfx` | The group | As above: `ServiceAccount` with Kerberos Auth or Virtual App, `Pfx` with Kerberos Auth |
| The other settings above | The group | Optional |
| `Notes` | Each connector | Ignored by the tool; for your own notes |

Things to know:

- **Group settings once per group.** Fill them in on the group's first row. Its other rows can leave them blank or repeat them; a different value on a later row is a problem.
- **Several services in one cell.** Separate them with commas, or put one per line (Alt+Enter). A line break in any other cell is a problem.
- **The first sheet is read.** The import reads the first sheet that is not hidden, so keep `Fleet` first. The check names the sheet it read.
- **No passwords.** A column that looks as if it holds passwords is refused. Passwords are asked at run time, as always.
- **Versions in Excel.** Excel turns `26.10` typed into an ordinary cell into `26.1`. The template's `Fleet` sheet is formatted as Text, so this does not happen there. Keep working in the `.xlsx` file: a CSV file loses that format when Excel opens it. The import warns when a version looks damaged.
- **Where the fleet file goes.** It is written as `fleet.psd1` beside the script, as `fleet.<name>.psd1` with `-Fleet <name>`, or to the file `-FleetConfig <path>` names. If that file is there already and holds groups, you are asked to type `YES`. Either way, the old file is kept beside it as `fleet.psd1.bak-<date>_<time>` (a copy is never overwritten), and its top-level settings (`StagingRoot`, `StagingFolders`, `CentralLogRoot`, `InstallScript`, `JavaPatchDir`) are carried over. The groups all come from the spreadsheet. A note, also in the dry run, names any group of the old file that the spreadsheet does not hold, and any setting the old file sets for a group that the spreadsheet leaves blank, because the new file will not have them.
- **Java4Shell patch.** A new fleet file has the `JavaPatchDir` line commented out. If your connector version needs the patch (section 6, step 5), open `fleet.psd1` and remove the `#` in front of that line.
- The import ends by giving the next commands: `-Mode Verify`, then a dry run (section 8). They name the file written whenever a run would not pick it by itself. When that is because a `fleet.<this computer name>.psd1` or `fleet.<this computer domain>.psd1` is also there, a note says so.

The full rules (accepted spellings, how a CSV file is read, every check) are in `docs/Fleet-File-Reference.md`, under "Building the fleet file from a spreadsheet".

### 7.2 Connectors already installed: let Discover start the sheet

If your connectors are already installed, `-Mode Discover` reads their current settings and writes them as a spreadsheet in the same columns, ready for 7.1. It only reads: it changes nothing on the connectors and copies nothing to them. It uses SSH (section 4) and asks for no password.

Name the connectors with `-Connector`; no fleet file is needed for this. A backtick at the end of a line continues the command in PowerShell; in another shell, type the command on one line.

```
pwsh ./Invoke-AccessConnectorUpgrade.ps1 -Mode Discover `
    -Connector connector1.example.local,connector2.example.local
```

Once you have a fleet file, leave out `-Connector` to read every connector in it, or add `-Tenant` to read only some groups. With `-Connector`, `-Tenant` has no effect; a host you name that is in the fleet file is still matched with its entry.

It shows a line for each connector and writes `fleet.discovered_<date>_<time>.csv` in `FleetDeploy`. `-ExportCsv <path>` names another file, or a folder to write that file in: one that exists, or a path with no file extension or ending in `/` (made when it is not there); an existing file is never overwritten. A connector it cannot reach still gets a row, with the reason in `Notes`. At the end it says how many rows still need values, and shows two commands that import the file. Then:

1. Open the CSV file in Excel. If your regional settings use `;` as the list separator, Excel puts each whole row in one cell: open the file with Data > From Text/CSV instead, and choose Comma as the delimiter. The `Notes` column says what was found on each connector, and `fill:` names the columns that still need a value.
2. Fill in the blanks. The usual ones are `Installer`, when `Installers` holds more than one installer; `ConfigFile`, when no single file in `Configs` is named after the tenant's host name; and `Pfx`, when the connector serves the installer's self-signed certificate (the note then says to run `-Mode RepairCertificate` afterwards). For a connector that is already in the fleet file, the tool fills these from its entry when it can, and the note says which. Check the `Group` names and change them as you like. A name ending in `-2` or `-3` marks a connector whose settings differ from the rest of its group; the connectors closest to the fleet entry keep its name, and the `differs from fleet entry` note says what differs.
3. Save it as an Excel workbook, for example `fleet.xlsx`. Before you type a version such as `ExpectVersionPrefix`, format that column as Text. (You can also save it as a CSV file again and import that, if you type no version: in a CSV file Excel turns `26.10` into `26.1`.)
4. Import it as in 7.1, steps 3 and 4: `-DryRun` first, then without. Use the two commands Discover showed, with the name of the file you saved in place of the draft's name. Keep the rest of each command as shown: it names the fleet file to write. For example:

```
pwsh ./Invoke-AccessConnectorUpgrade.ps1 -ImportFleet ./fleet.xlsx `
    -FleetConfig '<the path Discover showed>' -DryRun
```

Which fleet file those commands write:

- **Discover read a whole fleet file** (every connector in it, also when you named each one with `-Connector` or every group with `-Tenant`): that file. Replacing it asks for `YES`, keeps the old file as a copy, and a note names every group, connector and setting the new file would not have (a group Discover split off as `<entry>-2` is compared with `<entry>`). If the fleet file sets `ExpectVersionPrefix`, that note names it, because Discover always leaves it blank: type it in at step 3 to keep it. A connector that could not be reached still counts as read: fill its row in by hand rather than deleting it, or the import removes it from the file.
- **Discover read only part of a fleet file** (`-Tenant` or `-Connector` left some of its connectors out): a new file, `fleet.discovered_<date>_<time>.psd1` beside it, which Discover writes itself, with the original's top-level settings (such as `StagingRoot` and `JavaPatchDir`) and no groups. A warning says how many connectors were left out and names the file. Importing part of the fleet into the original would replace the whole file and drop the groups the draft does not hold. Importing into the new file needs no `YES`, and keeps those settings. To keep one fleet file instead, add the other groups' rows to the sheet and import it with `-FleetConfig` naming the original.
- **There was no fleet file:** `fleet.psd1`.

Discover sends back only the settings it needs. It never keeps or sends back the passwords and secrets the connector holds, even where they sit in the same file as a setting it reads. What it reads, and how each column is filled, is in `docs/Fleet-File-Reference.md`, under "Discovering existing connectors".

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

To start a run in one line from another shell or a scheduler, put `pwsh` in front (on Windows, `pwsh -ExecutionPolicy Bypass -File`; from a scheduler, add `-NonInteractive` so that a run stops at a prompt instead of waiting):

```
pwsh ./Invoke-AccessConnectorUpgrade.ps1 -Tenant TENANT1 -DryRun
```

Passwords are only ever asked at prompts. A run started with no terminal to type them in (with its input redirected, or with `pwsh -NonInteractive`) stops at the first prompt with exit code 1 and changes nothing. When you schedule a run, start it with `pwsh -NonInteractive` so that it stops instead of waiting: "A prompt needs an answer, but this run has no terminal to type it in". For a change window with nobody at the keyboard, use Stage mode: see `docs/Implementation-Guide.md`, under "Unattended".

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

<!-- disclaimer -->
> [!CAUTION]
> **LEGAL DISCLAIMER - UNSUPPORTED, USE AT YOUR OWN RISK**
>
> This script is an UNSUPPORTED utility. It is NOT an Omnissa product or offering, and it is not covered by any Omnissa support, maintenance, or service-level agreement.
>
> It is provided "AS IS" and "AS AVAILABLE", WITHOUT WARRANTY OF ANY KIND, express or implied, including but not limited to the implied warranties of merchantability, fitness for a particular purpose, title, and non-infringement.
>
> YOU USE IT ENTIRELY AT YOUR OWN RISK. You are solely responsible for validating its behaviour, for safeguarding the credentials you supply to it, and for any effect it has on your environment or data.
>
> TO THE MAXIMUM EXTENT PERMITTED BY LAW, NEITHER OMNISSA NOR THE AUTHOR SHALL BE LIABLE FOR ANY CLAIM, LOSS, OR DAMAGES WHATSOEVER - direct, indirect, incidental, special, exemplary, or consequential (including loss of data, revenue, or profits) - arising from or in connection with the use of, or inability to use, this script.
>
> Use of the Omnissa products is governed by your agreement with Omnissa; customers assume all responsibility for automated changes to them.
<!-- /disclaimer -->
