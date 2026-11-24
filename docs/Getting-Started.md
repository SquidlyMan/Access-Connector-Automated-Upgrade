# Getting Started

Access Connector Automated Upgrade installs, upgrades and repairs Omnissa Access Connectors from one command. It works with any connector version: the version installed is whichever installer file you name in the fleet file.

This guide takes you from nothing to a first upgrade in any environment. It starts with a quick start: what to have ready and the steps in order, each with the section that explains it in full. Sections 1 to 13 then cover the two ways the tool can reach a connector (SSH and WinRM), how to stand up SSH on a Windows server, the fleet file, the first run, clean installs on new servers, and how to choose which connector services are installed. Section 14 gives worked examples for different networks, directory layouts and kinds of deployment, and section 15 lists what the tool does not do, with what to do instead.

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

## Quick start

This is the whole job in nine steps. Each step says how you can tell it worked, and which section explains it in full. You can follow the steps in order without reading the rest of the guide first; go to the named section whenever a step needs more detail or does not work. The words this guide uses are explained at the end of the quick start.

### What to have ready

| You need | Where it comes from | When |
|---|---|---|
| A computer to run the tool from, called the **admin machine** | Your own Mac, Linux or Windows computer, or a management server. It needs PowerShell 7 (step 1). | Always |
| A list of your connector servers, and the tenant each one belongs to | Your own records, or the Access console | Always |
| The connector installer `.exe` for the version you want | Omnissa's download site | Always |
| Each tenant's configuration file (`es-config.json`) and its password | The Access console | Always |
| An account that is an administrator on each connector server | Your server team | Always |
| The Kerberos certificate file (a `.pfx`) and its password | Your certificate authority | Connectors that run Kerberos Auth |
| The service account name and its password | Active Directory | Connectors that run Kerberos Auth or Virtual App |
| A domain admin account and its password | Active Directory | Connectors that run Kerberos Auth. Over WinRM, every tenant also needs a domain account that is an administrator on its connectors (the sign-in to them); for Kerberos Auth it must be a domain admin |

You never type a password into a file. The tool asks for each one, with the typing hidden, while it runs.

### The steps

1. **Install PowerShell 7 on the admin machine.** The tool's `Prerequisites` folder has a script for it: put the tool in its folder first (step 2), then run the script from there. On Windows, double-click `Prerequisites\Install-PowerShell7.cmd`: it asks for administrator rights, installs or updates PowerShell 7, and waits for a key so that you can read the result. On a Mac, run the second command in Terminal; it asks for your password for the install step only:

```
Prerequisites\Install-PowerShell7.cmd
bash Prerequisites/install-powershell7-macos.sh
```

Each one installs Microsoft's own package after checking it against the SHA-256 published with the release and checking that Microsoft signed it, and changes nothing when PowerShell 7 is already current. Run the Windows one at the console or by Remote Desktop: it refuses to run over SSH (section 13). Both scripts are new and have been tested offline only. Instead of them you can use Homebrew on a Mac (the first command) or winget on Windows (the second):

```
brew install --cask powershell
winget install --id Microsoft.PowerShell --source winget
```

On Linux, follow Microsoft's instructions for your distribution. **It worked when** `pwsh --version` shows 7 or later. The connector servers need nothing extra: they already have the Windows PowerShell 5.1 that the tool uses there. (Section 2)

2. **Put the tool in a folder.** Unzip the tool's ZIP file, or clone its repository, into a folder on the admin machine or on a file share it can reach. This folder is the **staging folder**. On Windows, unblock a downloaded ZIP before you unzip it (section 6), or PowerShell refuses to run the scripts. **It worked when** the folder holds `FleetDeploy`, `Silent Install`, `Prerequisites`, `Installers`, `Configs`, `ChildCerts` and `TrustedCerts`. (Section 6)

3. **Add your files to it.** The installer goes in `Installers`, each tenant's `es-config.json` in `Configs`, the Kerberos `.pfx` in `ChildCerts`, and any CA certificates the connectors must trust in `TrustedCerts`. If your connector version needs Omnissa's Java4Shell patch, unzip it into `Installers\Java4shellPatch` (section 6, step 5). **It worked when** every file is in its folder. (Section 6)

4. **Open a way in to each connector.** Choose one route (section 3 compares them):
- **SSH** (recommended): every part of the tool works over it, from any admin machine. Make one SSH key on the admin machine (section 4.3), then turn on OpenSSH Server on each connector and let that key in. `Prerequisites\Install-OpenSSHServer.ps1` does the connector's part in one step: run it elevated on each connector with your public key, or on several connectors at once from a Windows admin machine (section 4, "The quick way"). For every connector in one organizational unit (OU), `Deploy-OpenSSH-GPO.ps1` does it through Group Policy (Implementation Guide, section 4). **It worked when** `ssh administrator@connector1.example.local hostname` prints the server's name without asking for a password (section 4.6).
- **WinRM**: from a Windows admin machine only, when SSH is not allowed. Upgrades and clean installs work; the report, discovery and repair modes do not (section 5). **It worked when** `Test-WSMan connector1.example.local` answers.

5. **Tell the tool about your connectors: the fleet file.** Open a terminal, go to the `FleetDeploy` folder and type `pwsh` (on Windows, `pwsh -ExecutionPolicy Bypass` if your policy blocks scripts run from a share; for a downloaded ZIP, see section 6). Type this step's commands, and those of the later steps, at its prompt. Then, depending on your starting point:
- **Connectors already installed, SSH open:** let the tool read them into a spreadsheet. It changes nothing on them. Then open the spreadsheet it writes and fill in anything its `Notes` column says is missing (section 7.2):

```
./Invoke-AccessConnectorUpgrade.ps1 -Mode Discover `
    -Connector connector1.example.local,connector2.example.local
```

- **New servers, or no SSH:** copy `fleet.example.xlsx` to `fleet.xlsx` and fill in one row per connector (section 7.1).
- **If you prefer a text file:** copy `fleet.example.psd1` to `fleet.psd1` and edit it (section 7).

Then let the tool check the spreadsheet and write the fleet file from it. The first command only checks; the second one writes. If Discover wrote your spreadsheet, use the two commands it showed, with the name of the file you saved (section 7.2, step 4).

```
./Invoke-AccessConnectorUpgrade.ps1 -ImportFleet ./fleet.xlsx -DryRun
./Invoke-AccessConnectorUpgrade.ps1 -ImportFleet ./fleet.xlsx
```

**It worked when** the first command lists every group and connector with no problems, and the second one says it wrote the fleet file. (Sections 7, 7.1, 7.2)

Then make the fleet file's `JavaPatchDir` line match step 3: on (no `#` in front of it) when your version needs the Java4Shell patch, commented out (a `#` in front) when it does not. A fleet file written by the import has the line commented out; `fleet.example.psd1` has it on. A run stops before it contacts anything when the line is on and the patch is not in its folder.

6. **Look before you change anything** (SSH only; over WinRM, skip this step). This shows each connector's version and services:

```
./Invoke-AccessConnectorUpgrade.ps1 -Mode Verify
```

**It worked when** every connector you listed has a line. Verify installs nothing and changes no connector setting. It does write a little on each connector: it creates `C:\ProgramData\AccessConnectorUpdate` if it is missing, locks it to Administrators and SYSTEM, copies the tool's helper script into it, and adds a line to the tool's log there. (Section 8.1)

7. **Rehearse on one tenant.** A dry run copies the files and runs every check it can, but installs nothing. Over SSH it first checks that it can sign in to each connector, before it asks for any password. Over WinRM, add `-Mode WinRM` to this command and the next one.

```
./Invoke-AccessConnectorUpgrade.ps1 -Tenant TENANT1 -DryRun
```

**It worked when** every connector shows `DryRunPassed`. The checks: the PFX opens with its password, the domain admin account can start the work on the connector, the configuration file is valid and, for Kerberos Auth connectors, the service account password works. Some passwords can be checked only for the right form: the configuration file's always, and the service account's on connectors without Kerberos Auth. Whether they are correct shows in the real run. (Section 8.2)

8. **Do the real run on that tenant.**

```
./Invoke-AccessConnectorUpgrade.ps1 -Tenant TENANT1
```

The tool shows its plan, checks the sign-in to each connector (over SSH, as in step 7), asks you to type `YES`, then asks for the passwords. It does the connectors one at a time, about ten minutes each, so a tenant with two or more connectors stays online. If a connector is not healthy afterwards, the tool stops before the next one. **It worked when** the summary shows `Success` for every connector. (Sections 8.3 and 12)

9. **Check, then do the rest.** Run step 6 again to see the new versions. The summary and the logs are in `FleetDeploy/FleetLogs`. Then repeat steps 7 and 8 for each other tenant, or leave out `-Tenant` to do every tenant in the fleet file, top to bottom. (Section 12)

If a step stops with a message you do not understand, see section 13. Section 14 has worked examples for other set-ups: connectors in another network, several domains, a night-time change window, new servers, and more.

### Words used in this guide

| Word | Meaning |
|---|---|
| Admin machine | The computer you run the tool on. It reaches the connectors over the network. |
| Connector | A Windows server that runs the Omnissa Access Connector. |
| Tenant | Your Omnissa Access service, in the cloud or on your own servers. Each connector belongs to one tenant. |
| Connector group | One entry in the fleet file: a set of connectors with the same settings. Usually all the connectors of one tenant (section 11). |
| Staging folder | The folder that holds the tool and the files it installs (section 6). |
| Fleet file | `fleet.psd1` in `FleetDeploy`: the list of your connector groups, their connectors, and which files and settings each group uses (section 7). |
| Configuration file | The tenant's `es-config.json`, from the Access console. It tells the connector which tenant it belongs to. |
| Service account | The Active Directory account that the Kerberos Auth and Virtual App services use. |
| PFX | A certificate file with its private key. The Kerberos Auth service uses it for its secure (HTTPS) connections. |
| Keytab | The Kerberos key store that the Kerberos Auth service needs. It is rebuilt during a Kerberos Auth upgrade (section 9). |
| Dry run | A rehearsal: everything is copied and checked, and nothing is installed (`-DryRun`). |

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
| Admin machine | macOS, Linux or Windows with PowerShell 7 or later (`pwsh`). The tool will not start under Windows PowerShell 5.1. WinRM mode needs a Windows admin machine. The connector servers themselves need only the Windows PowerShell 5.1 that Windows Server includes, over WinRM or SSH. If you use a connector server as the admin machine, install PowerShell 7 on it as well. The `Prerequisites` folder has scripts that install or update PowerShell 7 on Windows and on macOS (quick start, step 1). |
| Reach to the connectors | SSH with key sign-in (port 22), or PowerShell remoting (WinRM, port 5985; the tool does not use WinRM over HTTPS). With WinRM, SSH is not needed for upgrades and clean installs. `-Mode Verify`, `-Mode Discover`, `-Mode Stage` and the two repair modes always use SSH. `Prerequisites\Install-OpenSSHServer.ps1` sets up SSH on a connector in one step (section 4). |
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
| Set-up work | Enable OpenSSH Server on each connector (one script, section 4) | Usually none on domain-joined servers | Same as SSH |

**Recommendation:** use SSH if you can. Every mode works over it, and it is the route with the most testing. Use WinRM when policy does not allow SSH on the servers; you can still upgrade and clean install, but you lose the report, discovery and repair modes. You can mix the two: WinRM for upgrades and SSH on a few servers for the repair modes.

## 4. Stand up SSH on a Windows server

Do this once on each connector: with one script (the quick way, below) or by hand (4.1 to 4.7). Either way, the key is made on the admin machine (4.3) and the sign-in is tested from there (4.6).

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
- **Many servers at once.** The server steps are the same on every connector. `Install-OpenSSHServer.ps1` does them on several connectors in one command from a Windows admin machine (the quick way, below). For every connector in one OU, `Prerequisites\Deploy-OpenSSH-GPO.ps1` makes a Group Policy object that runs that script on each one at its next restart (Implementation Guide, section 4). Your configuration tool can push it too.

### The quick way: one script per connector

`Prerequisites\Install-OpenSSHServer.ps1` does 4.1, 4.2, 4.4 and 4.5 on the connector in one step. Make the key on the admin machine first (4.3). Copy the script to the connector, then run it there in an elevated Windows PowerShell window, with your public key between the quotes and the network your admin machines connect from. If Windows refuses to run it, unblock it first (section 6).

```
.\Install-OpenSSHServer.ps1 'ssh-ed25519 AAAA...your public key...' `
    -AllowFrom 10.0.0.0/24
```

Add `-WhatIf` to see what it would change, with nothing changed. Run it on one connector first and test the sign-in from the admin machine (4.6) before you do the others.

From a Windows admin machine it can do several connectors in one command, with no Remote Desktop: PowerShell remoting takes the script, the key and the networks to each connector, and each one sends back a result line. Run it with an account that is an administrator on the connectors:

```
$key = Get-Content $HOME\.ssh\connector_ed25519.pub
$servers = 'connector1.example.local', 'connector2.example.local'
Invoke-Command -ComputerName $servers -ArgumentList $key, '10.0.0.0/24' `
    -FilePath .\Install-OpenSSHServer.ps1 |
    Format-Table PSComputerName, Result, PasswordSignIn, HostKey
```

What it does. It changes only what is not already right, so it is safe to run again:

- Installs OpenSSH Server if it is missing, from Windows Update or WSUS, or with `-Source` from Features on Demand media (14.6). Sets sshd to start with Windows and starts it (4.1).
- Adds each public key to `C:\ProgramData\ssh\administrators_authorized_keys`, keeping the keys already there, and limits that file to Administrators and SYSTEM (4.4).
- With `-AllowFrom`, limits the OpenSSH firewall rules to those networks, and names any other rule that still lets port 22 in from any address (4.2). Without `-AllowFrom` it adds, enables or changes no firewall rule.
- Turns password sign-in off only when a key that sshd can read is in the file, the file is limited as above, and nothing in `sshd_config` stops administrators from signing in with that key (4.5). Otherwise it leaves password sign-in as it is and says why. It never turns password sign-in back on.
- Checks the new `sshd_config` with `sshd -t` before using it, keeps the old one as `sshd_config.bak-<date>`, and puts it back if sshd does not come back after the restart.
- Puts right host key files whose permissions stop sshd from starting (section 13).
- Ends with the connector's host key fingerprint, to compare at your first connection (4.6).

What it does not do:

- Anything on the admin machine: making the key (4.3), testing the sign-in (4.6) and the SSH settings file (4.7) are yours to do.
- Remove a key. It only adds keys; to take one out, delete its line from the key file (14.31).
- Change the OpenSSH default shell, unless you ask with `-DefaultShell`. The tool does not need it changed.
- Open port 22 in another firewall, such as an endpoint-protection product's own (section 13).
- Run inside an SSH session that comes from an address outside `-AllowFrom`: it refuses, because the next sign-in from there would be refused.

It needs Windows Server 2019 or later (or Windows 10 1809 or later) and an elevated 64-bit Windows PowerShell 5.1. On older Windows, install Win32-OpenSSH first; the script then configures it. `-Help` lists every option, including `-KeepPasswordSignIn`, `-Banner` and `-LoginAlert`. The script is new: it has been tested offline only, not yet on a Windows server (Validation Record).

### The steps, by hand

Do this once on each connector. It takes about five minutes. Run the commands in an elevated Windows PowerShell window on the connector, except 4.3, 4.6 and 4.7, which run on the admin machine.

### 4.1 Install and start OpenSSH Server

```
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
```

On Windows Server 2025 the component is already present and the first line simply reports that. On Windows Server 2019 and 2022 it is downloaded from Windows Update; a server with no internet access needs the Features on Demand media or your WSUS to supply it. On a server the first line is usually quick; on Windows 10 and 11 it can take more than an hour. Do not restart the computer while it runs: a restart stops the install.

### 4.2 Check the firewall rule

The installation creates an inbound rule for port 22. Confirm one is enabled:

```
Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP*' | Format-Table Name, Enabled
```

That rule lets port 22 in from any address. Windows lets a connection in when any enabled rule allows it, so a narrower rule added beside it limits nothing. To limit SSH to your admin machine or management subnet, change the existing rule, then check it. Make sure the admin machine is inside the network you name, or the tool is shut out too:

```
Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP*' |
    Set-NetFirewallRule -RemoteAddress 10.0.0.0/24
Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP*' |
    Get-NetFirewallAddressFilter | Format-Table RemoteAddress
```

If no rule is enabled at all, create one that is limited from the start:

```
New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP-Mgmt' `
    -DisplayName 'OpenSSH Server (management)' `
    -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow `
    -RemoteAddress 10.0.0.0/24
```

Replace `10.0.0.0/24` with your own management network.

Windows Firewall may not be the only firewall on the server. An endpoint-protection product with a firewall of its own can drop port 22 while these rules let it in, and while ping still answers. If ssh then times out, add an inbound rule in that product for `C:\Windows\System32\OpenSSH\sshd.exe` (section 13).

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

A key without a passphrase also works, but then the file itself is the only protection: anyone who can copy it can sign in to every connector. The tool never asks for an SSH password. If the key is refused, the tool says so with SSH's own reason and a hint (section 13), and an upgrade, a dry run or a repair stops before it asks for anything. Show the public half with:

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

`Install-OpenSSHServer.ps1` shows the same fingerprint at its end, and writes it as `hostKey=` in its audit log on the connector, `C:\ProgramData\ssh\logs\Install-OpenSSHServer-audit.log`: that is where to read it after a Group Policy deployment.

Answer `yes` only when they match. SSH then remembers the key and refuses the server if it ever changes. The tool accepts a host it has never seen without asking, so connecting once by hand like this before the first run is how every host key gets checked.

If a connector's host key changes later (a rebuilt server, say), SSH refuses it, and the tool's message says "Host key verification failed". Remove the old key on the admin machine, then connect once by hand as above and check the new one:

```
ssh-keygen -R connector1.example.local
```

### 4.7 Tell SSH which key to use (optional)

To save typing `-SshKey` on every command, add the key to the SSH configuration file on the admin machine (`~/.ssh/config`; on Windows `%USERPROFILE%\.ssh\config`):

```
Host *.example.local
    IdentityFile ~/.ssh/connector_ed25519
```

The commands in this guide assume you have done this. If you have not, add `-SshKey ~/.ssh/connector_ed25519` to each one.

If your SSH agent holds several keys, ssh offers them in turn, and a connector can stop it with "Too many authentication failures" before the right one. Add the line `IdentitiesOnly yes` under the same `Host` line: ssh then offers only the key named there.

> **Which account?** Any account in the connector's local Administrators group works. The built-in local `administrator` was used in testing. Name a different account per connector with `SshUser` in the fleet file, or for a whole run with `-SshUser`.

> **Default shell.** You do not need to change the OpenSSH default shell. The tool starts Windows PowerShell 5.1 by name. Testing was done on servers whose default shell had been set to PowerShell 7; the stock default (cmd.exe) is expected to work but has not been tested. Where the default shell is PowerShell 7, do not upgrade PowerShell 7 over SSH: the upgrade ends the session and can stop half-way (section 13).

## 5. Or use WinRM (PowerShell remoting)

Use this route from a Windows admin machine when SSH is not an option. Upgrades and clean installs over WinRM need no SSH at all: no OpenSSH Server on the connectors, no SSH client or key on the admin machine. Section 4 can be skipped. Only `-Mode Verify`, `-Mode Discover`, `-Mode Stage`, `-Mode RepairKeytab` and `-Mode RepairCertificate` need SSH.

1. Install PowerShell 7 on the admin machine.
2. Be ready to type a domain account that is an administrator on the connectors. The tool never uses the account you are signed in to Windows with: it asks once per connector group, under the heading "Domain admin sign-in for tenant <name> connectors", or takes `-Credential`. For a group with Kerberos Auth this account must be a domain admin, because the upgrade runs under it (5.2).
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
| `-Mode Verify` | Report every connector's version, services, patch flag, keytab and certificate from the admin machine, changing nothing | Read the result of each WinRM run (it ends with the same state line). On a connector, `Invoke-ConnectorUpgradeLocal.ps1 -VerifyOnly` in the staging folder prints the same facts on one line: the version, each service and its state, the Java patch flag count and the keytab size in bytes. The certificate check appears only in the `RESULT_JSON` line after it. |
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

Unzip the tool's ZIP file, or clone its repository, and use that folder as the staging folder. It already has the layout:

```
<staging folder>/
    FleetDeploy/        the tool, your fleet file, and the FleetLogs folder
    Silent Install/     Install-AccessConnector.ps1 (runs the vendor installer)
    Prerequisites/      set-up scripts: PowerShell 7, OpenSSH Server (section 4)
    Installers/         the connector installer .exe (you add this)
    Configs/            one es-config .json per tenant (you add these)
    ChildCerts/         the Kerberos PFX (Kerberos connectors only)
    TrustedCerts/       CA certificates to trust (optional)
```

**A downloaded ZIP on Windows.** Windows marks a ZIP file that came from the internet or from an e-mail, and every file you unzip from it. PowerShell then refuses to run the scripts, with "... is not digitally signed. You cannot run this script on the current system". Before you unzip it, unblock the ZIP: right-click it, choose Properties, tick Unblock and click OK, or in PowerShell:

```
Unblock-File .\Access-Connector-Automated-Upgrade-<version>.zip
```

If it is already unzipped, unblock the files instead, in PowerShell in the unzipped folder:

```
Get-ChildItem -Recurse -File | Unblock-File
```

Starting PowerShell as `pwsh -ExecutionPolicy Bypass` also works, for that window only. macOS and Linux do not block the scripts.

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

Each connector gets one line: installed version, services running, and for Kerberos connectors the keytab and the certificate served. A line is red when something needs attention: a service down, the keytab empty or missing, or, for a group with a `Pfx`, the wrong certificate. Any red line makes the exit code 1 (14.26). This proves that sign-in works and the fleet file is right. Verify asks for no password. It installs nothing and changes no connector setting, but it does write a little on each connector: it creates `C:\ProgramData\AccessConnectorUpdate` if it is missing, locks it to Administrators and SYSTEM, copies the helper script into it, and adds a line to the tool's log there. So do not run it against a connector while another run is working on it. For a look that writes nothing at all, use `-Mode Discover` (section 7.2).

### 8.2 Dry run: rehearse one tenant

```
./Invoke-AccessConnectorUpgrade.ps1 -Tenant TENANT1 -DryRun
```

This copies the files and runs every pre-flight check: the PFX opens with the password you typed, the configuration file is valid, the domain admin account can start the task and, for Kerberos Auth groups, the service account password works against the domain. Nothing is installed. Two passwords can be checked only for the right form: the configuration file's, and the service account's in a group without Kerberos Auth (Virtual App only, say). A wrong one shows only in the real run, on the first connector. Fix anything it reports and repeat until it says `DryRunPassed`.

The checks run on every connector, also one that is already on the installer's version. A real run would skip such a connector, and the dry run says so in a note: "A real run would SKIP this connector". Add `-ForceReinstall` if you want it reinstalled.

### 8.3 The real run

```
./Invoke-AccessConnectorUpgrade.ps1 -Tenant TENANT1
```

The tool shows the plan, checks that it can sign in to each connector over SSH, asks you to type `YES`, then asks for the passwords once per tenant. Allow roughly ten minutes per connector, during which that connector's services are down. The run ends with a summary and writes a CSV and the connectors' logs to `FleetDeploy\FleetLogs`.

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

- Write accounts as `DOMAIN\name`, for example `EXAMPLE\svc-access`.
- Every question comes before anything is copied to or changed on a connector. Just before the first one, an SSH run signs in to every selected connector to check that it can. If one fails, the run stops there, before it asks anything, and names SSH's own reason, with a hint when it suggests one (section 13).
- Over SSH, a wrong domain admin password stops the run at the first Kerberos Auth connector, with nothing changed: it is tried once, not once per connector (with `-ContinueOtherTenants`, the other groups go on). Over WinRM, where that account is also the sign-in to the connectors, a sign-in that a connector refuses stops the run at that connector too, in a dry run as well, so a wrong password is not tried on every connector. Rehearse on one connector first, with `-Connector`.
- For a Kerberos Auth group, the dry run's service account check is a real sign-in attempt against the domain. A wrong password counts towards that account's lockout, so retype it with care rather than running again and again.

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

The exit code is 0 when every selected connector succeeded and 1 otherwise, so a scheduler can tell. `-Mode Verify` ends with 1 when a connector could not be read or has a red line (14.26).

| Status | Meaning |
|---|---|
| `Success` | Installed and healthy |
| `DryRunPassed` / `DryRunFailed` | Result of the pre-flight checks; nothing installed |
| `Blocked` | Refused before anything was changed; the message says why |
| `Failed` | The install script ended with an error: the installer failed, or a check stopped it (read `AccessConnector_Audit_*.log` in the connector's logs). Services that were running before are started again |
| `Unhealthy` | Installed, but a check afterwards did not pass; the message says which |
| `Skipped` | Not attempted because an earlier connector failed |
| `Error` | The tool could not reach the connector, the connector refused the WinRM sign-in, the task could not be started under the account given, or no result came back |

## 13. If something goes wrong

| What you see | What to do |
|---|---|
| "... is not digitally signed. You cannot run this script on the current system" | Windows blocked the scripts of a downloaded ZIP. Unblock them (section 6), or start PowerShell as `pwsh -ExecutionPolicy Bypass`. |
| `ssh ... Permission denied` or a password prompt in your own test | The key is not accepted. Recheck section 4.4 and the `icacls` line. |
| "The SSH sign-in check failed on ... connector(s)" | The run stopped before it asked anything; nothing was changed. The line above it, one per connector, says why, with a hint when SSH's reason suggests one (next rows). Fix the sign-in, or leave those connectors out: the message names the others for `-Connector`. |
| "cannot reach <host> over SSH: ... Permission denied (publickey)" | The key was not accepted. Name it with `-SshKey`, or add it to the SSH settings file (section 4.7). Test by hand with `ssh administrator@<host> hostname` (section 4.6). |
| "cannot reach <host> over SSH: ... Host key verification failed" | The connector's host key has changed (a rebuilt server, say). Remove the old one with `ssh-keygen -R <host>`, then connect once by hand and check the new one (section 4.6). |
| "cannot reach <host> over SSH: ... Connection timed out" (or refused, or no route to host) | Port 22 is not reachable from the admin machine: a firewall, or OpenSSH Server not running (sections 4.1, 4.2). When the connector answers ping and sshd is running, look at its endpoint-protection product: one with a firewall of its own can drop port 22 without a trace in Windows Firewall. Add an inbound rule there for `C:\Windows\System32\OpenSSH\sshd.exe`. A name that does not resolve says "Could not resolve hostname". |
| "cannot reach <host> over SSH: ... Too many authentication failures" | ssh offered several keys, from an agent say, and the connector stopped before the right one. Name the key with `-SshKey`, and add `IdentitiesOnly yes` to the SSH settings file (section 4.7). |
| "signed in to <host> over SSH, but could not create C:\ProgramData\AccessConnectorUpdate" (or, from the sign-in check, "could not run Windows PowerShell there") | SSH works, but the account is not an administrator on that connector, or Windows PowerShell did not start there; the message ends with the connector's own error. Use an account in its local Administrators group. |
| "Could not sign in to <host> over WinRM as <account>" | The connector refused the account: a wrong name or password, an account that is locked out or disabled, or not an administrator there. That group stops there, and the whole run unless `-ContinueOtherTenants`, in a dry run too. Retype it as `DOMAIN\name`. |
| "Files this run needs are missing" | A file named in the fleet file is not in the staging folder. The message lists each one, and names another copy of the folder if one has them. |
| `DryRunFailed` | Read the lines above it: a wrong PFX or service account password, or an invalid configuration file. Nothing was changed. |
| "Could not start the task as ..." | The domain admin account name or password was wrong. Nothing was changed. |
| "cannot query Active Directory" | A Kerberos connector was run without a domain admin account. Run it again and give the account at the prompt. |
| `keytab EMPTY` in Verify | Run `-Mode RepairKeytab`. |
| Certificate shown as `SELF-SIGNED by the installer` | Run `-Mode RepairCertificate`. |
| "writes PowerShell command parameters to its event log" | The server's module logging policy would record the passwords. Turn it off for that server while the run happens. |
| An SSH session ended while PowerShell 7 was being upgraded, or `Install-PowerShell7.ps1` says "This run is inside an SSH session" | Upgrading PowerShell 7 over SSH ends the session when the OpenSSH default shell is pwsh, and can stop the install half-way. So the script refuses to install over SSH; `-CheckOnly` still works there. Run it at the console, by Remote Desktop or over WinRM. The tool itself is not affected: it starts Windows PowerShell by name. |
| Installing OpenSSH Server (`Add-WindowsCapability`) seems to hang | On Windows 10 and 11 it can take more than an hour; on a server it is usually quick. Let it finish, and do not restart meanwhile: a restart stops the install. With no internet access, use `-Source` (14.6). |
| sshd does not start, or stops at once; `sshd -T` or `sshd.exe -ddd` says "no hostkeys available", and the event logs show nothing | The host key files have permissions that sshd refuses. After an `ssh-keygen -A` typed in an elevated window, they can hold an entry for that admin account which `icacls /inheritance:r` does not remove. (Not elevated, `ssh-keygen -A` fails without a message.) For each `C:\ProgramData\ssh\ssh_host_*_key` file: `icacls <file> /setowner "NT AUTHORITY\SYSTEM"`, then `icacls <file> /remove "<that account>"`, then `icacls <file> /inheritance:r /grant SYSTEM:F /grant Administrators:F`; then `Restart-Service sshd`. `Install-OpenSSHServer.ps1` makes the same repair. |
| A connector has no sshd after `Deploy-OpenSSH-GPO.ps1` | The startup script runs only while a computer starts: restart it (`gpupdate` alone does not run it). Then, elevated on that connector, `gpresult /r /scope computer` must list the GPO under Applied Group Policy Objects (Implementation Guide, section 4). |

More cases are in `docs/Troubleshooting.md`.

## 14. Use cases

Every site is different: the network between the admin machine and the connectors, the domains, how many tenants and connectors there are, and how changes are run. This section gives worked examples. Each one starts from a set-up (**You have**) and a goal (**You want**), gives the steps with the commands, then what to watch out for. **Tested** says what real runs have proven for that route and what is only built. Most of those runs used earlier versions of the tool; `docs/Validation-Record.md` has the full record.

Find the cases closest to yours in the tables below. Several can apply at once: connectors in a DMZ (14.4) that run Kerberos Auth behind a load balancer (14.11), for example. Commands are typed at the `pwsh` prompt in the `FleetDeploy` folder, as in section 8, unless a step says to run them on the connector.

**Reaching the connectors**

| You have | You want | See |
|---|---|---|
| A choice of computers to run the tool from | The one that needs least set-up | 14.1 |
| A policy that forbids SSH on the servers | Upgrades over WinRM, knowing what you lose | 14.2 |
| SSH on some connectors, only WinRM on others | Each server done over the route it allows | 14.3 |
| Connectors in a DMZ or another network segment | Only what the tool needs opened in the firewall | 14.4 |
| Connectors reachable only through a jump host | To run the tool from your own machine | 14.5 |
| Connectors with no internet access | To prepare and upgrade them without downloads | 14.6 |
| Connectors that reach the internet through a web proxy | The proxy set on every install and upgrade | 14.7 |
| Short access to the connectors, or a night window with nobody at the keyboard | The upgrade to run on each server by itself | 14.8 |

**Domains, accounts and certificates**

| You have | You want | See |
|---|---|---|
| Two forests with no trust, one admin machine | Both looked after without mixing files or accounts | 14.9 |
| A Windows admin machine in each forest | The right fleet file chosen without typing its name | 14.10 |
| Kerberos Auth connectors behind a load balancer | One certificate that passes the checks on every connector | 14.11 |
| Kerberos Auth on only some connectors of a tenant | The Kerberos extras only where they are needed | 14.12 |
| A rule against signing in as the built-in administrator | The tool to use another administrator account | 14.13 |
| A rule that the domain admin password is typed only on the server | The upgrade without giving the tool that account | 14.14 |
| A connector server that is not in the domain | To install and upgrade it with the same tool | 14.15 |

**Kinds of deployment**

| You have | You want | See |
|---|---|---|
| Connectors already installed, never run with this tool | A fleet file from what is installed, then the first upgrade | 14.16 |
| A new tenant and new servers, nothing installed | Every connector installed fresh | 14.17 |
| A fleet file in use, and a new connector version | The routine upgrade to that version | 14.18 |
| Many tenants and a short change window | Tenants done side by side, knowing the risk | 14.19 |
| A tenant with only one connector | The downtime known, and a way back | 14.20 |
| A new server, for more capacity or to replace an old one | It installed with its group's settings, the old one retired | 14.21 |
| A connector on the right version that is broken, or needs other services | It reinstalled fresh | 14.22 |
| Groups that must stay on different versions for a while | Each group on its own installer, with the Java4Shell patch where needed | 14.23 |
| FIPS mode, other ports or another install folder | Those settings kept, or changed safely | 14.24 |
| An upgrade that failed, or a version you want to back out of | To know the state, then fix it or go back | 14.25 |

**Running it day to day**

| You have | You want | See |
|---|---|---|
| Connectors to report on | Their state, once or every night, with nothing installed | 14.26 |
| The fleet kept in Excel | To change it and import it again | 14.27 |
| A change process that asks for a record | The evidence, from the tool's own files | 14.28 |
| A Kerberos Auth connector upgraded by hand, and Kerberos sign-in broken | It working again without a reinstall | 14.29 |
| A Kerberos certificate that is about to expire | The renewed one on every connector | 14.30 |
| Several admins and one staging folder | Nobody in another's way, and the tool updated for everyone | 14.31 |

### 14.1 Choosing the admin machine

**You have:** a Mac, a Linux machine, a Windows PC or server, or one of the connector servers, any of which could run the tool.

**You want:** the machine that needs the least set-up and has the most testing behind it.

1. Pick a machine that reaches every connector on TCP port 22 (SSH). A Windows machine can use TCP port 5985 (WinRM) instead (14.2). The tool connects only to the connectors and reads the staging folder. It downloads nothing, so the admin machine needs no internet access.
2. Install PowerShell 7 on it (quick start, step 1). On Windows, `Prerequisites\Install-PowerShell7.cmd` installs or updates it; on a Mac, `Prerequisites/install-powershell7-macos.sh`. Run either again at any time to update it: they change nothing when it is current. Without internet access, see 14.6.
3. For SSH, check that the SSH client is there. macOS has it, and on Linux it is the OpenSSH client package. On Windows it is the optional feature OpenSSH Client, which the second command adds in an elevated Windows PowerShell window:

```
Get-Command ssh, scp
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
```

4. Put the staging folder where this machine can read it: on its own disk, or on a file share it has mounted. The connectors never read it; every file is copied to them (section 6).
5. Set up key sign-in (section 4) and test one connector by hand (section 4.6). Once the fleet file is written (section 7), check that the tool reaches every connector in it:

```
./Invoke-AccessConnectorUpgrade.ps1 -Mode Verify
```

**Watch out:**

- A connector server can be the admin machine once PowerShell 7 is installed on it. Install or update it there at the console or by Remote Desktop: `Install-PowerShell7.ps1` refuses to run over SSH (section 13). If that server is also in the fleet file, the tool reaches it through its own SSH server, like any other connector. That has not been tried: do that connector last, on its own with `-Connector`, or from another machine.
- On Linux, the message that names another copy of the staging folder finds only copies listed as full paths under `StagingFolders` in the fleet file. On macOS it also looks under `/Volumes`, and on Windows on every drive.

**Tested:** every SSH mode, from a Mac. WinRM upgrades, from a Windows machine. Not yet proven: the SSH modes from a Windows or Linux admin machine, and a connector server running the tool against itself. The PowerShell 7 scripts in `Prerequisites` have been tested offline only.

### 14.2 SSH is not allowed on the connector servers

**You have:** a Windows admin machine, connectors that are domain members with PowerShell remoting (WinRM) on, which is the Windows Server default, and a policy that forbids OpenSSH Server on them.

**You want:** to upgrade and clean install them without SSH, and to know what you give up.

1. Install PowerShell 7 on the admin machine. WinRM mode needs no SSH client, key or OpenSSH Server (section 5).
2. Check that each connector answers on TCP port 5985. If it does not, run `Enable-PSRemoting -Force` in an elevated PowerShell window on that connector.

```
Test-WSMan connector1.example.local
```

3. Write the fleet file by hand or from the spreadsheet template (section 7 or 7.1). Discover cannot read the connectors for you, because it needs SSH.
4. Rehearse, then run, one tenant at a time. After the passwords, the tool asks for the sign-in to that tenant's connectors, headed "Domain admin sign-in for tenant TENANT1 connectors". For a group without Kerberos Auth, a domain account that is an administrator on the connectors is enough. For a Kerberos Auth group it must be a domain admin, because the upgrade runs under it.

```
./Invoke-AccessConnectorUpgrade.ps1 -Mode WinRM -Tenant TENANT1 -DryRun
./Invoke-AccessConnectorUpgrade.ps1 -Mode WinRM -Tenant TENANT1
```

5. Check the result in the summary and in the CSV file in `FleetDeploy\FleetLogs`. There is no `-Mode Verify` without SSH.

**Watch out:**

- Without SSH you lose Verify, Discover, Stage, both repair modes and the copy of each connector's logs (section 5.1). To keep the repair modes for Kerberos Auth, allow SSH on those servers only (14.3).
- The tool has no setting for WinRM over HTTPS (port 5986): it always uses port 5985. PowerShell remoting still encrypts what it carries, the passwords included.
- The tool changes no WinRM setting on the admin machine. A server outside the domain, or one named by its IP address, needs Windows' own remoting settings (such as TrustedHosts), which the tool neither sets nor checks.
- To type the sign-in once for every tenant instead of once per tenant, add `-Credential (Get-Credential)`.
- A sign-in that a connector refuses ("Could not sign in to <host> over WinRM as ...") stops the run at that connector, in a dry run too, so a wrong password is not tried on every connector (section 13).

**Tested:** WinRM upgrades of three connectors without Kerberos Auth, one at a time. Not yet proven: Kerberos Auth connectors over WinRM (section 5.2), and any WinRM run with version 1.4.0 of the tool or later.

### 14.3 Some connectors allow SSH, others only WinRM

**You have:** OpenSSH Server allowed on some connectors (for example the ones that run Kerberos Auth) but not on others, and a Windows admin machine with PowerShell 7 and the SSH client.

**You want:** one fleet file, each server upgraded over the route it allows, and the report and repair modes where SSH is open.

1. `-Mode` sets the route for a whole run; the fleet file has no route setting per connector. So put the WinRM-only connectors in a connector group of their own, with the same `ConfigFile` as the rest of their tenant and a `Name` of its own (section 11.2):

```
@{
  # no SSH on these servers: run this group with -Mode WinRM
  Name       = 'TENANT1-WINRM'
  ConfigFile = 'Configs\tenant1-es-config.json'
  Services   = 'DirectorySyncService,UserAuthService'
  # ... Installer and the other settings ...
  Connectors = @( @{ Host = 'connector3.example.local' } )
}
```

2. Rehearse and run each group by name, one after the other. Never run the two at the same time: they serve one tenant.

```
./Invoke-AccessConnectorUpgrade.ps1 -Tenant TENANT1 -DryRun
./Invoke-AccessConnectorUpgrade.ps1 -Tenant TENANT1
./Invoke-AccessConnectorUpgrade.ps1 -Mode WinRM -Tenant TENANT1-WINRM -DryRun
./Invoke-AccessConnectorUpgrade.ps1 -Mode WinRM -Tenant TENANT1-WINRM
```

3. Afterwards, Verify the SSH group (`-Mode Verify -Tenant TENANT1`). For the WinRM group, read its summary.

**Watch out:**

- Always name the group with `-Tenant`. An SSH run of every group stops at its sign-in check, before it asks anything, because the WinRM-only connectors do not answer over SSH ("cannot reach ... over SSH"). A WinRM run of every group would also take the SSH group's Kerberos Auth connectors over WinRM, which is not proven.
- The repair modes reach only the SSH group.
- SSH modes from a Windows admin machine are not yet proven. The proven pair is a Mac for the SSH group and a Windows machine for the WinRM group; both can work from one staging folder on a share.

**Tested:** each route on its own (14.1, 14.2). Not yet run: both routes for one fleet file.

### 14.4 Connectors in a DMZ or another network segment

**You have:** the admin machine and the staging folder on the internal network, and connectors in a DMZ (a network zone between the internal network and the internet) or in another server segment, with a firewall between them.

**You want:** to open only what the tool needs, and to know what the connectors need for themselves.

1. Allow one port from the admin machine, or your management subnet, to each connector: TCP 22 for SSH, or TCP 5985 for WinRM. Everything the tool does goes over that port: its commands, the file copies and, over SSH, the logs it brings back. It needs no file share, ping or other port to the connectors.
2. On each connector, limit SSH to that network. The rule that OpenSSH Server creates lets port 22 in from any address, and a narrower rule added beside it limits nothing, so change the existing rule (section 4.2). Make sure the admin machine is inside the network you name, or the tool is shut out too.

```
Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP*' |
    Set-NetFirewallRule -RemoteAddress 10.0.0.0/24
```

`Install-OpenSSHServer.ps1 -AllowFrom 10.0.0.0/24` does the same as part of its run (section 4, the quick way), and names any other enabled rule that still lets port 22 in from any address. Through Group Policy, `Deploy-OpenSSH-GPO.ps1` refuses to run without `-AllowFrom` (unless `-AllowFromAnyAddress` is given) and passes it on to every connector in the OU.

3. If SSH listens on another port, put that in the SSH settings file on the admin machine (section 4.7). The fleet file has no place for a port:

```
Host *.example.local
    Port 2222
    IdentityFile ~/.ssh/connector_ed25519
```

4. Connect once by hand to check each host key (section 4.6), then run Verify.
5. Make sure the connectors' own paths are open. The tool tests none of them, except that for Kerberos Auth it checks that the sign-in can query Active Directory. They are: out to the Access tenant, directly or through a web proxy (14.7); to the syslog server, if `Syslog` is set; to Active Directory and the other servers your connector services use, as Omnissa documents; and, for Kerberos Auth, in from users' browsers to each connector by its own name, on port 443 or the `KerberosAuthPort` you set.

**Watch out:**

- The health pages and the Kerberos certificate are checked on the connector itself, so they need no rule from the admin machine.
- When a connection fails, the message gives SSH's own reason, and a hint for the usual ones. "Connection timed out" or "No route to host" means that the firewall does not let the port through from the admin machine.
- The tool trusts a connector's host key the first time it sees one, so check each one by hand before the first run.
- Two other firewalls can overrule the rule. When Group Policy manages a firewall profile and ignores local rules, set the limit in that policy; `Install-OpenSSHServer.ps1` says so when it sees this. An endpoint-protection product's own firewall can drop port 22 while ping still answers (section 13).
- Each SSH connection must open within 15 seconds. The tool sends a keep-alive every 30 seconds, which keeps a long upgrade open through a firewall that drops idle connections.

**Tested:** SSH and WinRM in the lab. No run is recorded across a DMZ firewall or with SSH on another port. The tool passes no port or settings file to `ssh`, so the port comes from OpenSSH's own settings file.

### 14.5 Connectors reachable only through a jump host

**You have:** a jump host (a server you sign in to first, which can reach the connectors when your admin machine cannot), reached with SSH.

**You want:** to run the tool from your own machine, through the jump host.

1. Make sure you can sign in to the jump host with a key and no prompt, with the key loaded in your SSH agent (section 4.3).
2. Describe the route in the SSH settings file on the admin machine. The tool names no settings file, so `ssh` and `scp` read this one, and nothing in the tool turns the route off:

```
Host jump.example.local
    User <your account on the jump host>
    IdentityFile ~/.ssh/connector_ed25519
    BatchMode yes

Host *.example.local !jump.example.local
    ProxyJump jump.example.local
    IdentityFile ~/.ssh/connector_ed25519
```

3. Connect once by hand to the jump host, then through it to each connector, and check each host key (section 4.6). The first command needs `-o BatchMode=no`, or SSH cannot ask about a host key it has not seen:

```
ssh -o BatchMode=no jump.example.local hostname
ssh administrator@connector1.example.local hostname
```

4. Use the tool as usual.

**Watch out:**

- The tool's own SSH options (no password prompts, a 15-second connect timeout, keep-alives, the key named with `-SshKey`) apply only to the connection to the connector, not to the hop. That is why the jump host's entry sets `BatchMode` and the key itself.
- `User` in the file does not change the account used on the connectors: the tool always names that account (`SshUser`, `-SshUser`, else `administrator`).
- Do not set `RemoteCommand` or `RequestTTY` for the connectors in the file. The tool sends its own command, and the passwords on the session's input.
- WinRM cannot go through an SSH jump host. Another way: make the jump host the admin machine, if it can run PowerShell 7 (14.1).

**Tested:** not yet run. The tool has no jump-host code of its own: it passes no settings file to `ssh` or `scp`, so they follow the route in yours.

### 14.6 Connector servers with no internet access

**You have:** connectors that cannot reach the internet or Windows Update.

**You want:** to prepare and upgrade them without downloading anything on them.

1. Stand up SSH as in section 4, with one change on Windows Server 2019 and 2022: install OpenSSH Server from your Features on Demand media (the Windows media for optional features) or your WSUS. In the command, `D:\` stands for the folder on that media that holds its `.cab` files. Windows Server 2025 already has the component. With WinRM there is nothing to install.

```
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 `
    -Source D:\ -LimitAccess
```

`Install-OpenSSHServer.ps1` takes the same folder (section 4, the quick way). Through Group Policy, give `Deploy-OpenSSH-GPO.ps1` a share that the computer accounts can read, as `-PayloadParameters @{ Source = '\\fileserver.example.local\FoD' }` (Implementation Guide, section 4).

```
.\Install-OpenSSHServer.ps1 'ssh-ed25519 AAAA...your public key...' `
    -Source D:\ -LimitAccess
```

2. If the admin machine has no internet access either, install PowerShell 7 on it from a package you copy there. On a computer that has access, download from Microsoft's PowerShell releases page on GitHub the MSI for the admin machine's processor and the `hashes.sha256` of the same release, into one folder. Then, in an elevated Command Prompt on the admin machine, run the command below. It checks the package's Microsoft signature and, with `hashes.sha256` beside it, its SHA-256. The macOS script needs internet access.

```
Prerequisites\Install-PowerShell7.cmd -MsiSource D:\Packages\PowerShell
```

3. Put everything in the staging folder: the installer, the configuration files, the PFX, the CA certificates and, if your version needs it, the Java4Shell patch (section 6). The tool copies it all to each connector, and its scripts download nothing there.
4. Rehearse and run as usual (section 8).
5. The connector service itself must still reach its Access tenant. With a cloud tenant, open the path Omnissa documents, or use a web proxy (14.7). The tool does not test this path.

**Watch out:**

- A dry run proves the passwords and the files, not the connector's path to its tenant.
- For Kerberos Auth, the keytab step needs the Windows features RSAT-AD-PowerShell and RSAT-ADDS-Tools. Before the change, check on each connector that both are installed: `Get-WindowsFeature RSAT-AD-PowerShell, RSAT-ADDS-Tools`.
- The `-Source` folder must hold the Features on Demand of the server's exact Windows build.

**Tested:** the tool's own steps are the proven SSH-mode steps, and none of them downloads anything. No lab connector was without internet access, so an install on such a server is not proven. The scripts' `-Source` and `-MsiSource` have not run on a real computer; the offline tests cover `-MsiSource`.

### 14.7 Connectors that reach the internet through a web proxy

**You have:** connectors whose only way out to the Access cloud tenant is an outbound web proxy, for example `proxy.example.local` on port 3128, perhaps with a proxy account.

**You want:** the proxy set the same way on every install and upgrade of a group.

1. Add the proxy to the group's fleet entry, or fill in the `ProxyHost`, `ProxyPort`, `ProxyUser` and `NonProxyHosts` columns of the spreadsheet (section 7.1). `ProxyHost` turns the proxy on. `NonProxyHosts` lists the hosts the connector reaches directly, separated by `|`.

```
  ProxyHost     = 'proxy.example.local'
  ProxyPort     = 3128
  # ProxyUser     = '<proxy account>'   # its password is asked at run time
  # NonProxyHosts = '<host>|<host>'
```

2. Rehearse. The settings are checked before any connector is contacted, and the plan shows them on its Settings line. Then run. With `ProxyUser`, the proxy password is asked with the others; it must not contain a double quote.
3. For connectors that already use a proxy, `-Mode Discover` reads their proxy settings into its draft (section 7.2).

**Watch out:**

- These settings are for the connector's own traffic. The tool's SSH or WinRM connection does not use the proxy.
- Keep the proxy in the fleet entry for as long as the connectors use it. Omnissa asks for custom settings to be given again at every upgrade, and a setting left out gets the installer's default.
- With a proxy account (`ProxyUser`), the Kerberos certificate step and `-Mode RepairCertificate` refuse the connector, because the vendor script would clear the stored proxy password. A Kerberos Auth upgrade then ends `Unhealthy`: put the certificate back with the installer's Add/Remove Services.
- A misspelt setting, such as `ProxyHots`, is only named in a note and then ignored. Read the notes above the plan.

**Tested:** built, not proven. No connector has been installed with a proxy. The checks and the plan line were exercised offline.

### 14.8 Run the upgrade later on the server: short access, or a night window

**You have:** SSH to the connectors only for short periods (a VPN that drops, a firewall opened in office hours, a slow link), or a change window at night with nobody at the keyboard.

**You want:** everything copied while you can reach the connectors, then the upgrade run on each server by itself.

The simplest route, if someone can be there for the first few minutes: start a normal run from an admin machine that stays on and awake all night. After `YES` and the passwords it needs nobody, and it keeps the health gate: it stops before the next connector when one is not healthy. A scheduler on the admin machine cannot start it, because the passwords are only ever asked at prompts (section 8.3). Otherwise:

1. While SSH works, stage the group. Everything is copied to each connector and `Run-Upgrade.cmd` is written there. No password is asked. (Staged with `-DryRun`, the job only runs the checks; stage again without it before the change.)

```
./Invoke-AccessConnectorUpgrade.ps1 -Mode Stage -Tenant TENANT1
```

2. To run it by hand: sign in to each connector, one at a time per tenant, as a domain admin for Kerberos Auth (any administrator otherwise), and start this from a Command Prompt opened with Run as administrator. It asks for the passwords there.

```
C:\ProgramData\AccessConnectorUpdate\Run-Upgrade.cmd
```

3. To run it at a set time instead: on each connector, in a Windows PowerShell window (not PowerShell 7) opened with Run as administrator, schedule it for a time on the connector's own clock. You type the passwords now, then your own Windows password, which Task Scheduler keeps so that it can run the job as you. The job deletes itself, and with it your Windows password, when its run ends; a job that has not run 12 hours after its time is deleted by Task Scheduler. A time that has already passed on that clock is refused, and so is a new time while an earlier scheduled job on that connector is still running; nothing is written then.

```
powershell -ExecutionPolicy Bypass -File `
    C:\ProgramData\AccessConnectorUpdate\Invoke-ConnectorUpgradeLocal.ps1 `
    -Prompt -Schedule "2027-01-15 22:30"
```

4. Afterwards, check from the admin machine. Each connector also writes its result to `C:\ProgramData\AccessConnectorUpdate\Logs\result.json`, and the job's screen output to `task-console_<date>_<time>.log` beside it.

```
./Invoke-AccessConnectorUpgrade.ps1 -Mode Verify -Tenant TENANT1
```

5. To cancel a scheduled job before it runs, delete it on that connector in the same kind of window, and delete `C:\ProgramData\AccessConnectorUpdate\secrets.dat`, which holds the passwords you typed, encrypted for your account:

```
Unregister-ScheduledTask -TaskName AccessConnectorUpgrade -Confirm:$false
```

**Watch out:**

- There is no health gate between scheduled jobs: each one runs on its own, even if the one before failed. Schedule one connector per group per night and Verify it before you schedule the next, or leave a wide gap: a connector took 9 to 18 minutes in testing.
- When you schedule, only an empty password is caught. A dry run from the admin machine beforehand checks what you type there, not what you type on the connector, so type carefully. A wrong PFX password stops the job before any service is stopped; a wrong configuration file password is found only by the installer.
- After you schedule, run no upgrade, dry run or Stage against that connector until the job has run: they replace the job file it reads. Do not update the tool in between.
- The job deletes itself as soon as its run ends, whatever the result, so Task Scheduler no longer shows it afterwards: read the result in the logs (step 4).
- A job that never ran (the connector was off at that time, say) is deleted by Task Scheduler 12 hours after its time, but its `secrets.dat` stays on the connector: delete it (step 5).
- The logs stay on each connector in `C:\ProgramData\AccessConnectorUpdate\Logs`. Nothing is copied to `FleetLogs`.
- Stage needs SSH. With WinRM only, have someone start the WinRM run at the start of the window.

**Tested:** Stage, then `Run-Upgrade.cmd` run by hand as a domain admin, on one connector with all four services and a usable keytab afterwards. Not yet run: `-Schedule` (and with it the job deleting itself), and a staged dry-run job.

### 14.9 Two forests with no trust, one admin machine

**You have:** two Active Directory forests with no trust between them, `example.local` (EXAMPLE) and `example2.local` (EXAMPLE2), each with its own connectors and its own file share, and one Mac or Linux admin machine that reaches every connector on port 22.

**You want:** both forests looked after from that machine, without mixing their files or their accounts.

1. Put one copy of the staging folder on each forest's share, each holding only its own forest's configuration files and PFX files. Keep the scripts at the same version in both copies, and update both together (Implementation Guide, sections 3 and 10).
2. Mount both shares on the admin machine, each with an account of its own forest.
3. Authorise the same SSH key for the local administrator on every connector of both forests (section 4.4). A key sign-in as a local account does not use Active Directory, so it works across forests without a trust. One line in the SSH settings file covers both: `Host *.example.local *.example2.local`.
4. In each copy's `FleetDeploy`, write a fleet file named after its forest, `fleet.example.local.psd1` and `fleet.example2.local.psd1`. Each lists only that forest's groups, each with a service account of that forest.
5. Work on each forest from its own copy's `FleetDeploy` folder, with `-Fleet` on every command: a Mac or Linux machine does not choose the file by domain. At the domain admin prompt, type that forest's account.

```
./Invoke-AccessConnectorUpgrade.ps1 -Fleet example.local -Mode Verify
./Invoke-AccessConnectorUpgrade.ps1 -Fleet example.local -Tenant TENANT1 -DryRun
./Invoke-AccessConnectorUpgrade.ps1 -Fleet example.local -Tenant TENANT1
```

Then the same from the other copy, with `-Fleet example2.local` and that forest's groups.

**Watch out:**

- Never put connectors of both forests in one group: the service account, the PFX and the domain admin are set once per group.
- Do not use `-RunAsCredential` for a run that covers both forests: it gives one account to every group. Type each forest's account at its group's prompt.
- Simpler, if no Windows admin machine will choose the file by its domain: name each copy's file `fleet.psd1`, and leave out `-Fleet`.
- Discover matches a PFX by name only against the `ChildCerts` of the copy it runs from, so read each forest's connectors from its own copy.

**Tested:** the lab has two forests with no trust, one Mac admin machine and one staging copy per forest. Proven there: Verify and Discover on all ten connectors, dry runs, and `-Fleet` choosing the fleet file. Not yet run: a Linux admin machine.

### 14.10 One Windows admin machine in each forest

**You have:** two or more forests or domains with no trust, and in each one a Windows admin machine joined to that domain that can read that domain's share.

**You want:** each forest's team to run the tool from its own machine, with the right fleet file chosen without anyone typing its name.

1. Put one copy of the staging folder on each forest's share, with only that forest's files.
2. Name the fleet file after the domain as Windows gives it: `fleet.example.local.psd1`. Every admin machine joined to `example.local` then picks it. The tool looks for `fleet.<computer name>.psd1` first, then `fleet.<domain>.psd1`, then `fleet.psd1`. These two commands show the names a machine uses:

```
[Environment]::MachineName
(Get-CimInstance Win32_ComputerSystem).Domain
```

3. If you build the file from a spreadsheet, name it in the import: without `-Fleet`, the import writes `fleet.psd1`.

```
./Invoke-AccessConnectorUpgrade.ps1 -ImportFleet ./fleet.xlsx `
    -Fleet example.local -DryRun
```

4. Rehearse, and check the plan line: "Fleet file: fleet.example.local.psd1 (chosen by this computer's domain, example.local)". Over SSH every mode works; over WinRM, add `-Mode WinRM` (14.2).

**Watch out:**

- The domain file is chosen only on Windows, or where the `USERDNSDOMAIN` variable is set. A Mac or Linux machine needs `-Fleet` (14.9).
- On a Windows machine in a workgroup, Windows gives the workgroup's name as the domain, so the domain's file is never picked there. Use `-Fleet`.
- Over WinRM the tool never uses the account you are signed in with: it always asks, or takes `-Credential`.

**Tested:** built, not proven: the choice by computer name or domain has not run on Windows. WinRM upgrades from a Windows machine are proven for connectors without Kerberos Auth.

### 14.11 Kerberos Auth connectors behind a load balancer

**You have:** two or more Kerberos Auth connectors in one group, behind a load balancer.

**You want:** one certificate that works on every connector, passes the tool's checks, and is put back after each upgrade.

1. Get one certificate whose subject alternative names (the DNS names it is valid for) include the full name of every Kerberos Auth connector in the group, such as `connector1.example.local` and `connector2.example.local`. A wildcard name, `*.example.local`, also passes the check; it covers one name level. Add the load balancer's name too if your design needs it: the tool checks only each connector's own name. During a Kerberos sign-in the browser is sent to the connector's own name and sees this certificate, so have it issued by an authority the browsers trust.
2. Export it as a PFX with its private key and the issuer's certificate. Give it a password of plain keyboard characters without `%`, `^` or `"`, and a file name of letters, digits, dots, dashes and underscores. Name the file after one of its names (`connector1.example.local.pfx`) so that Discover can recognise it.
3. Put it in `ChildCerts` and name it in the group's `Pfx`. One PFX serves the whole group.
4. Set the load balancer to pass TLS through to the connectors rather than end it there (Engineering Notes, "Kerberos redirects go to the connector's own name").
5. On connectors that already run Kerberos Auth, check the PFX first. This dry run opens it, shows its names, and refuses it on any connector it does not name. Then put it on, or leave that to the next upgrade, which puts it back anyway (section 9). Verify should then show `certificate ok` on each connector.

```
./Invoke-AccessConnectorUpgrade.ps1 -Mode RepairCertificate `
    -Tenant TENANT1 -DryRun
./Invoke-AccessConnectorUpgrade.ps1 -Mode RepairCertificate -Tenant TENANT1
./Invoke-AccessConnectorUpgrade.ps1 -Mode Verify -Tenant TENANT1
```

**Watch out:**

- A certificate that names only the load balancer fails: Verify shows "DOES NOT NAME THIS SERVER", the repair refuses it, and an upgrade ends `Unhealthy`. Do not force it on with `-Reapply`.
- The name checked is the connector's own full name as it looks itself up in DNS, not the `Host` in the fleet file.
- On a clean install the installer puts the PFX on the service itself, and a certificate that does not name the server gets only a warning. Run Verify after every install.
- If your authority issues one name per certificate, give each connector a group of its own, with its own `Pfx` and the same `ConfigFile` (section 11.3).
- How the Access console's Kerberos settings should name a load balancer is Omnissa's design: the tool neither checks nor changes it.

**Tested:** `-Mode RepairCertificate` on five connectors and a test connector, with Kerberos sign-in through them afterwards. Not recorded: a load balancer in front of them. Built, not proven: the put-back inside a real upgrade.

### 14.12 Kerberos Auth on only some connectors of a tenant

**You have:** one tenant whose connectors 1 and 2 run Kerberos Auth, while connectors 3 and 4 run only Directory Sync and User Auth.

**You want:** them all upgraded, with the certificate, the service account and the domain admin only where Kerberos Auth runs.

1. Make two groups with their own `Name` and the same `ConfigFile` (section 11.2). Only the Kerberos group gets `Pfx` and `ServiceAccount`. (A group with Virtual App needs `ServiceAccount` too.)
2. Rehearse and run both in one command. Groups run one after another, one connector at a time, so the tenant never has two connectors down. The configuration file password is asked per group; the PFX, service account and domain admin only for `TENANT1-KERB`.

```
./Invoke-AccessConnectorUpgrade.ps1 -Tenant TENANT1-KERB,TENANT1-SYNC -DryRun
./Invoke-AccessConnectorUpgrade.ps1 -Tenant TENANT1-KERB,TENANT1-SYNC
```

3. The repair modes act on Kerberos groups only: they leave the other group out and say so.
4. To take Kerberos Auth off a connector later, move it to the other group and reinstall it (14.22).

**Watch out:**

- Do not use `-ParallelTenants` across the two groups unless you accept one connector from each being down at the same time.
- Only servers that run Kerberos Auth or Virtual App must be in the domain (section 10).
- Over WinRM, every group asks for a sign-in, not only the Kerberos group.

**Tested:** a Kerberos Auth group upgraded through the scheduled task (two connectors), a forced reinstall that removed Kerberos Auth (two connectors), and both repair modes. Not recorded: two groups of one tenant in one run.

### 14.13 Signing in with an account other than the built-in administrator

**You have:** a policy that renames or disables the built-in local Administrator, or wants a named account in the server logs, and an account such as `EXAMPLE\admin` in each connector's local Administrators group.

**You want:** the tool to sign in with that account.

1. Authorise your key for it exactly as in section 4.4: that one key file is read for members of the local Administrators group.
2. Test by hand. Quote the name so that the backslash is kept:

```
ssh 'EXAMPLE\admin@connector1.example.local' hostname
```

3. Tell the tool: `SshUser` on each connector in the fleet file (or the spreadsheet's `SshUser` column), or `-SshUser` for a whole run, which wins over the fleet file. Verify then proves the account's rights as well, because it creates and locks its folder on the connector.

```
./Invoke-AccessConnectorUpgrade.ps1 -Mode Verify -SshUser 'EXAMPLE\admin'
```

**Watch out:**

- An SSH key sign-in carries no password that the connector could pass on to a domain controller. So Kerberos Auth groups still ask for a domain admin for the scheduled task, even when you sign in as one.
- A domain account that is an administrator only through a domain group (such as Domain Admins) has not been tested with the key file.
- In the spreadsheet, a forward slash (`EXAMPLE/admin`), a space, a quote or a colon in `SshUser` is refused.

**Tested:** built, not proven. Only the built-in local administrator has signed in in real runs; the rest was checked offline.

### 14.14 The domain admin password may be typed only on the server

**You have:** Kerberos Auth connectors, and a rule that a domain admin password may not be typed into a tool on another machine, or a person running the tool who has no such account.

**You want:** the upgrade, with the keytab rebuilt, without giving the tool a domain admin account.

1. Stage the tenant. No password is asked:

```
./Invoke-AccessConnectorUpgrade.ps1 -Mode Stage -Tenant TENANT1
```

2. On the first connector, a domain admin signs in at the console or by Remote Desktop and starts `Run-Upgrade.cmd` from a Command Prompt opened with Run as administrator (14.8, step 2). The passwords are typed there. Because this is a full sign-in, the vendor's Kerberos set-up can reach Active Directory.
3. Wait for the result line holding `"Status":"Success"` before you start the next connector of the tenant. In this route, keeping one connector online is up to you.
4. Back on the admin machine, Verify the tenant.

**Watch out:**

- A local administrator sign-in is refused for a Kerberos Auth connector ("cannot query Active Directory"), with nothing changed.
- A Remote Desktop sign-in in Restricted Admin mode reaches the network as the server, not as you. The helper's check would pass, but the vendor set-up could not update the connector's account. Use an ordinary sign-in. (Not tested.)
- `-Mode RepairCertificate` needs no domain admin, so it can still run over SSH as usual.
- To rebuild an empty keytab the same way, run the helper on the connector with `-RepairKeytab`, signed in there as a domain admin (section 5.1). Not tested by hand.
- To run it at a set time instead, the domain admin schedules it on the server as in 14.8, step 3. The job runs under that account, and deletes itself, with the account's password that Task Scheduler keeps, when its run ends.

**Tested:** Stage, then `Run-Upgrade.cmd` signed in as a domain admin, on one connector with four services and a usable keytab afterwards. Not yet run: a scheduled job (`-Schedule`).

### 14.15 A connector server that is not in the domain

**You have:** connector servers outside the domain, for example stand-alone servers in a separate zone, that run only Directory Sync and User Auth.

**You want:** to install and upgrade them with the same tool.

1. Keep them in a group whose `Services` hold only `DirectorySyncService` and `UserAuthService`. Such a group needs no `ServiceAccount`, no `Pfx` and no domain admin.
2. Stand up SSH on each server and authorise your key for its local administrator (section 4).
3. Rehearse, then run (section 8). The only password asked is the configuration file's.

**Watch out:**

- Kerberos Auth and Virtual App need the server in the domain (section 10).
- Use SSH. WinRM to a server outside the domain needs remoting settings on the admin machine that the tool does not make, and it has not been tested.
- Check Omnissa's requirements for running these services on a server outside the domain.

**Tested:** built, not proven. Every lab connector was a domain member.

### 14.16 Connectors already installed, first time with this tool

**You have:** connectors installed by hand or by another tool, on an older version, with SSH open to them (section 4) and no fleet file.

**You want:** a fleet file that matches what is installed, then the first upgrade, one tenant at a time, with each tenant online throughout.

1. Read Omnissa's release notes for the new version: the versions it upgrades from, whether a new `es-config.json` is needed, and which Access service versions it works with. The tool does not check this.
2. Prepare the staging folder so that Discover can fill in more for you. Keep only the new installer in `Installers`: Discover then fills in `Installer`, and `InstallerVersion` from a version number in the file name. Name each `es-config.json` after its tenant's host name, such as `Configs\tenant1.us1.example.com-es-config.json`, and the PFX after one of its certificate's names. Discover reads only these file names; it never opens the files.
3. Read the connectors into a draft spreadsheet. Nothing is changed on them, and no password is asked:

```
./Invoke-AccessConnectorUpgrade.ps1 -Mode Discover `
    -Connector connector1.example.local,connector2.example.local
```

4. Open the draft, fill in what its `Notes` column asks for, and check the `Group` names: a name ending in `-2` marks a connector whose settings differ from the rest of its group. Save it as `fleet.xlsx`, format the version columns as Text, and type `ExpectVersionPrefix`, such as `26.10`. Then check and import it (section 7.2):

```
./Invoke-AccessConnectorUpgrade.ps1 -ImportFleet ./fleet.xlsx -DryRun
./Invoke-AccessConnectorUpgrade.ps1 -ImportFleet ./fleet.xlsx
```

5. If a note said "Java4Shell patch flag present", open the new `fleet.psd1` and remove the `#` in front of `JavaPatchDir`.
6. Take a snapshot or backup of each connector's virtual machine. The tool copies the keytab and the Kerberos Auth configuration before it changes them, but it does not snapshot the server.
7. Verify every connector and fix anything shown in red. The tool checks a connector after its own upgrade; it does not check the tenant's other connectors before it takes one down.
8. Rehearse the first tenant, then upgrade one of its connectors on its own. While that connector is down, sign in through Access to confirm that the tenant works on its other connector. When it is back, check the Access console and sign in again.

```
./Invoke-AccessConnectorUpgrade.ps1 -Tenant TENANT1 -DryRun
./Invoke-AccessConnectorUpgrade.ps1 -Tenant TENANT1 `
    -Connector connector1.example.local
```

9. Then the rest of that tenant, and the next tenant the same way:

```
./Invoke-AccessConnectorUpgrade.ps1 -Tenant TENANT1 `
    -Connector connector2.example.local
```

**Watch out:**

- The dry run cannot prove the configuration file's password: a wrong one shows on the first connector of the real run. Doing that connector on its own keeps the rest of the tenant online.
- Set `ExpectVersionPrefix`. Besides checking the version, it lets the tool carry on with the certificate step and its checks when the installer finished but a later check of the install script failed. Without it, that connector ends `Failed` and those steps are skipped.
- Running `-Tenant TENANT1` alone after step 8 goes over connector1 again: the installer step skips it, but the certificate step and the checks run on it again. Name the remaining connectors with `-Connector` to leave it alone.
- Hand edits to the connector's service files, such as Java memory settings, are not carried through an upgrade. Note them first.
- A connector that Discover could not reach gets a row with no `Group`, which the import refuses. Fix the connection and run Discover again, or fill the row in by hand.

**Tested:** Discover on ten connectors, and its drafts imported back, matching the hand-written fleet files. Upgrades one connector at a time, over SSH and over WinRM. The template saved by Microsoft Excel for Mac as a new workbook imported with the same result as the template itself (14.27). Not yet: a Discover draft saved as a workbook by Excel, an upgrade from a fleet file written by `-ImportFleet`, the certificate step inside a real upgrade, and Discover filling `Installer` with no fleet file (offline tests only).

### 14.17 A new tenant and new servers, nothing installed yet

**You have:** a new Access tenant and its `es-config.json`, and new Windows servers built to Omnissa's requirements, with no connector on them.

**You want:** every connector installed fresh with the same settings.

1. Join the servers to the domain if they will run Kerberos Auth or Virtual App, and install Windows updates and restart them: the tool warns when a restart is pending. Stand up SSH (section 4), or check WinRM (section 5). For SSH, `Install-OpenSSHServer.ps1` does the server's part on each new server, or on all of them in one command from a Windows admin machine (section 4, the quick way). If the new servers' computer accounts are in one OU, you can link `Deploy-OpenSSH-GPO.ps1`'s GPO to it before that restart instead: the restart then sets up SSH as well (Implementation Guide, section 4). Either way, check each host key (section 4.6).
2. Copy `fleet.example.xlsx` to `fleet.xlsx` and fill in one row per server, with the group settings on the group's first row (section 7.1). Check it, then import it.
3. Rehearse on the first server only. Verify shows it as "no connector services installed" until it is installed.

```
./Invoke-AccessConnectorUpgrade.ps1 -Tenant TENANT3 -DryRun `
    -Connector connector7.example.local
```

4. Install it. The tool reports "No connector services are registered on this server yet" and installs fresh (section 10). For Kerberos Auth, the install runs under the domain admin you type, so that the vendor set-up can create the server's Active Directory account and keytab.

```
./Invoke-AccessConnectorUpgrade.ps1 -Tenant TENANT3 `
    -Connector connector7.example.local
```

5. Check it in Verify and in the Access console. Then do the next server the same way, or the rest of the group in one run with `-Tenant TENANT3`.

**Watch out:**

- Kerberos Auth: the PFX must name every server (14.11). A Kerberos Auth group with no `Pfx` gets the installer's self-signed certificate, and the plan notes this.
- On a clean install, a certificate that does not name the server gets only a warning. Run Verify after every install.

**Tested:** clean installs over SSH on two servers. They ran Kerberos Auth and were installed from a local administrator sign-in, before the scheduled-task route existed, so their keytabs were rebuilt afterwards with `-Mode RepairKeytab`. Not yet proven: a clean install through the scheduled task under a domain admin, and a clean install over WinRM.

### 14.18 The next connector release, with a fleet file in use

**You have:** a fleet file the tool has used before, and a new connector installer.

**You want:** the routine upgrade to the new version.

1. Read the release notes (14.16, step 1). Put the installer in `Installers` and, if the version needs it, the Java4Shell patch in `Installers\Java4shellPatch`, with `JavaPatchDir` set in the fleet file.
2. Point each group at the new installer: change `Installer`, `InstallerVersion` and `ExpectVersionPrefix`. If you keep the fleet in Excel, change the workbook and import it again (14.27).
3. Verify, rehearse each tenant, then upgrade it, as in section 8. The plan shows the installer each connector gets: check it before you type `YES`.

```
./Invoke-AccessConnectorUpgrade.ps1 -Mode Verify
./Invoke-AccessConnectorUpgrade.ps1 -Tenant TENANT1 -DryRun
./Invoke-AccessConnectorUpgrade.ps1 -Tenant TENANT1
```

**Watch out:**

- The tool has no version-specific logic apart from the Java4Shell patch step. Before it changes a Kerberos certificate, it checks that the vendor scripts take one the way it expects, and refuses otherwise.
- A version the tool has not installed before is a first for it: read the Validation Record for the versions proven so far, and rehearse on one connector first.

**Tested:** upgrades from 24.12.0.0 and 26.05.0.0 to 26.10.0.0, with the patch step.

### 14.19 Many tenants and a short change window

**You have:** several tenants, each with its own group of two or more connectors, and a change window too short to do every connector one after another.

**You want:** the tenants done side by side to save time, knowing exactly when a tenant could be left with no connector.

1. A day or more before the window, dry run every group in one command. A connector that ends `DryRunFailed` stops only the rest of its own group. A domain admin account that cannot start the work on a connector ("Could not start the task as ..."), or over WinRM a sign-in that a connector refuses, stops the whole run, unless you add `-ContinueOtherTenants` as here; then one run shows the first problem of each group. A connector that SSH cannot sign in to stops the run at its sign-in check, before any question, even with `-ContinueOtherTenants`: fix it, or leave it out with `-Connector`. The installer copied now is not copied again by the real run.

```
./Invoke-AccessConnectorUpgrade.ps1 -DryRun -ContinueOtherTenants
```

2. Look for groups of the same Access tenant: they have the same `ConfigFile`. Side by side, one connector from each could be down together, so do those groups in a plain run instead.
3. In the window, do the first connector of each tenant side by side, check each tenant by hand, then do the rest. With `-ParallelTenants`, the next connector of every group starts at the same time; the tool waits for all of them before it starts the next ones.

```
./Invoke-AccessConnectorUpgrade.ps1 -ParallelTenants `
    -Connector connector1.example.local,connector3.example.local
./Invoke-AccessConnectorUpgrade.ps1 -ParallelTenants `
    -Connector connector2.example.local,connector4.example.local
```

4. If a connector fails, nothing new starts in any group; the ones already running finish. With `-ContinueOtherTenants` only the group that failed stops: use it only when no other group of the same tenant is in the run.

**Watch out:**

- `-Parallel` starts every selected connector at once: each tenant is offline until its connectors finish, and one failure stops nothing, except over WinRM a sign-in that a connector refuses: the connectors not yet started are then left alone. Keep it for labs, and for tenants with one connector each.
- Two connectors of one tenant can also be down together when one was already down before the run, or when two runs are started at once (by two people, or from two staging folders): nothing links separate runs.
- Each set of connectors takes as long as its slowest one: 9 to 18 minutes per connector in testing.

**Tested:** built, not proven. Neither `-ParallelTenants` nor `-Parallel` has been through a real run.

### 14.20 A tenant with only one connector

**You have:** a tenant served by a single connector.

**You want:** the upgrade with its downtime known and planned, and a way back.

1. Know the downtime: while the connector upgrades, nothing serves the tenant. Allow about ten minutes (9 to 18 in testing), and more for `-ForceReinstall`. Agree a window and tell the users.
2. Take a snapshot or backup of the server just before the window.
3. Dry run before the window. The installer it copies is not copied again in the window.
4. Run it in the window, then check it: Verify, the Access console, and a sign-in.

```
./Invoke-AccessConnectorUpgrade.ps1 -Tenant TENANT2 -DryRun
./Invoke-AccessConnectorUpgrade.ps1 -Tenant TENANT2
./Invoke-AccessConnectorUpgrade.ps1 -Mode Verify -Tenant TENANT2
```

5. To avoid this downtime next time, add a second connector (14.21).

**Watch out:**

- If the installer asks for a restart, the server is not restarted for you and the run ends `Unhealthy`. Restart it in the window, then Verify, and run `-Mode RepairKeytab` if the keytab is empty.
- Kerberos Auth: a keytab repair stops Kerberos sign-in for about a minute, and a certificate repair for a few minutes. With one connector, that is an outage too.
- If the vendor installer fails, the tool starts the services that were running before; what then serves depends on the installer's own roll-back. No installer failure has happened in testing.

**Tested:** the upgrade itself is the proven one-at-a-time path. A single connector adds only the downtime, which the tool cannot avoid.

### 14.21 A new server: more capacity, or replacing an old one

**You have:** a tenant in the fleet file, and a new Windows server for one more connector: for more capacity, or to take over from an old server that will be retired.

**You want:** the connector installed fresh with its group's settings and, for a replacement, the old server retired while the tenant stays online.

1. Build the server to Omnissa's requirements, join it to the domain if it will run Kerberos Auth or Virtual App, then install Windows updates and restart it. Open SSH with `Install-OpenSSHServer.ps1` (section 4, the quick way), or through the GPO of `Deploy-OpenSSH-GPO.ps1` if the server's account is in an OU it is linked to (14.17), and check its host key (section 4.6). Or check WinRM.
2. Kerberos Auth: the group's PFX must name the new server as well (14.11). If a load balancer is in front, add the server to it.
3. Add the server to its group's `Connectors`, or to a group of its own with the same `ConfigFile` if it needs other services (section 11.3).
4. Rehearse and install on that server only (section 10). Then check it in Verify, in the Access console, and with a sign-in through it.

```
./Invoke-AccessConnectorUpgrade.ps1 -Tenant TENANT1 -DryRun `
    -Connector connector3.example.local
./Invoke-AccessConnectorUpgrade.ps1 -Tenant TENANT1 `
    -Connector connector3.example.local
```

5. Replacing a server: only when the new one is healthy, retire the old one. The tool has no mode for this, so do it yourself:
- Take the old server out of any load balancer, and its line out of the fleet file.
- Uninstall the Access Connector on it (Windows Settings, Apps).
- Remove it from the Access console as Omnissa documents.
- For Kerberos Auth, disable the Active Directory user account named after the old server, unless a new server of the same name takes over.
- Delete `C:\ProgramData\AccessConnectorUpdate` on it, which still holds the installer, the `es-config.json`, the PFX and copies of the keytab, or wipe the server.

**Watch out:**

- A new server with the same name as the old one: retire the old one first (the tenant has one connector fewer during the swap), and leave its Active Directory account enabled, because the vendor set-up resets that account rather than making a new one. SSH refuses the new server until you remove the old host key with `ssh-keygen -R <host>` and check the new one (section 4.6).
- `-Connector` limits the run to that server. It still gets its group's settings and installer, which can be newer than what the group's other connectors have.

**Tested:** clean installs over SSH on two servers (14.17). Retiring a server is done by hand, outside the tool.

### 14.22 Reinstall at the same version: repair a connector or change its services

**You have:** a connector already on its group's installer version that is broken and not fixed by the repair modes, or one that needs a setting the installer takes only when it installs, such as a different set of services.

**You want:** that one connector uninstalled and installed fresh from its fleet entry, while the tenant's other connectors keep serving.

1. Confirm that it is on its group's installer version: `-ForceReinstall` uninstalls only then. With a newer installer, the run is an ordinary upgrade; upgrade first, then come back to this.
2. To change its services, move the connector to a group with the services you want and the same `ConfigFile`, and take it out of its old group (section 11.5). Check that the plan lists it once.
3. A fresh install takes everything from the fleet entry. Run Discover on the connector: its "differs from fleet entry" note names each setting it could read on the connector that differs from the entry, and so would change. It does not compare the installer, a configuration file or PFX it could not match by file name, or the trusted certificates themselves: check those yourself. Because it reads only part of the fleet, it also starts a new fleet file with no groups beside yours, which you can delete.

```
./Invoke-AccessConnectorUpgrade.ps1 -Mode Discover `
    -Connector connector3.example.local
```

4. Take a snapshot or backup. Rehearse, then reinstall; with `-DryRun` nothing is uninstalled. Afterwards, refresh the Access console's Connectors page: the connector registers again.

```
./Invoke-AccessConnectorUpgrade.ps1 -Tenant TENANT1-SYNC -DryRun `
    -ForceReinstall -Connector connector3.example.local
./Invoke-AccessConnectorUpgrade.ps1 -Tenant TENANT1-SYNC -ForceReinstall `
    -Connector connector3.example.local
```

5. After removing Kerberos Auth, disable the Active Directory user account named after the connector. After adding it, the group needs `Pfx` and `ServiceAccount`, the server must be in the domain, and a domain admin is asked at run time.

**Watch out:**

- Always name the connector with `-Connector`: `-ForceReinstall` acts on every selected connector that is already on the version.
- The plan and the `YES` warning do not say that `-ForceReinstall` is on. Check the command before you type `YES`.
- A connector listed in two groups of a hand-written fleet file is done twice, once with each group's services. The spreadsheet import refuses that.
- Without `-ForceReinstall`, a connector already on the version is skipped: a service you removed from `Services` stays installed, and the run still ends `Success`.
- Never remove one service with `msiexec ... REMOVE=...`: it fails and blanks saved settings (Engineering Notes).
- If the fresh install fails after the uninstall, the server has no connector left. Fix the cause and run the same command again: it is then a clean install.

**Tested:** a forced reinstall at the same version that removed Kerberos Auth, on two connectors. Not yet: a forced reinstall that installs Kerberos Auth or adds a service, one over WinRM, and a failure after the uninstall.

### 14.23 Groups on different versions, and the Java4Shell patch

**You have:** groups that must be on different connector versions for a while, for example a test tenant that gets each new version weeks before production, and versions that need Omnissa's Java4Shell patch (HW-283446).

**You want:** each group on its own installer, in the order you choose, with the patch where its version needs it.

1. Put each installer in `Installers`, and give each group its own `Installer`, `InstallerVersion` and `ExpectVersionPrefix`. `InstallerVersion` tells the tool the installer's version, which it compares with the installed one to decide whether to upgrade, skip or refuse.
2. Run each group on its own, test first. Groups run in fleet-file order whatever order you type after `-Tenant`, so separate commands keep the order yours.
3. `JavaPatchDir` is one setting for the whole fleet file. When one group's version needs the patch and another's does not, keep them in two fleet files, such as `fleet.test.psd1` and `fleet.prod.psd1`, and choose one with `-Fleet`. Or keep one file and run the group that does not need the patch with `-SkipJavaPatch`.

```
./Invoke-AccessConnectorUpgrade.ps1 -Fleet test -Tenant TENANT1 -DryRun
./Invoke-AccessConnectorUpgrade.ps1 -Fleet prod -Tenant TENANT2 -DryRun
```

4. A connector already on a version that needs the patch, but without it (Verify shows `java flag 2/4`, say): run its group's normal command again. The installer step skips it, and the patch and the checks still run.

**Watch out:**

- `-SkipJavaPatch` on a version that needs the patch makes the tool warn that the connector may be left without it.
- The patch step is built for `Java4shellPatch.bat` and its flag. A different patch for a future version would need a change to the tool.
- Discover leaves `Installer` blank when `Installers` holds more than one installer, unless the connector is already in the fleet file.
- An on-premises Access service can be too old for a new connector. Check the release notes.

**Tested:** upgrades to 26.10.0.0 with the patch step, and `-Fleet` choosing the fleet file. Not yet: groups going to different versions, `-SkipJavaPatch`, and a run that only applies the patch.

### 14.24 FIPS mode, other ports or another install folder

**You have:** connectors installed with settings other than the installer's defaults: FIPS mode (for FedRAMP tenants, fixed when the connector is installed), service ports other than 8080, 8090, 443 and 8008, or an install folder on another drive.

**You want:** upgrades and new installs that keep those settings, and a safe way to change one of them.

1. Put the settings in the group's fleet entry: `InstallDir`, `EnableFips` and the four port settings. They apply to every connector of the group, on a clean install and on every upgrade: a setting left out gets the installer's default, also on an upgrade.

```
  InstallDir        = 'D:\Program Files'   # D:\Program Files\Access Connector
  EnableFips        = $true
  DirectorySyncPort = 9080
```

2. For connectors already installed, let Discover read them: it fills in `InstallDir`, `EnableFips` and each port that is not the default. Connectors with different settings go in different groups.
3. Rehearse. The settings are checked before any connector is contacted, and the plan shows them on its Settings line. On each connector, a run is refused when its FIPS setting differs from the one it was installed with, and nothing is changed; a different `InstallDir` brings only a warning.
4. To change FIPS mode or move the install folder: wait until the connector is on its installer's version, change the fleet entry, and reinstall it with `-ForceReinstall` (14.22). A changed port reaches a connector only when the installer runs: at an upgrade, or with `-ForceReinstall`.

**Watch out:**

- `-ForceReinstall` skips the FIPS refusal, so change FIPS mode only on a connector that is already on its installer's version.
- Kerberos Auth in FIPS mode: the certificate step and `-Mode RepairCertificate` refuse the connector, and a Kerberos Auth upgrade ends `Unhealthy`. Put the certificate back with the installer's Add/Remove Services. A fresh install is not affected.
- After changing the Kerberos Auth port, change the firewall rules and any load balancer to match: it is the connector's only inbound port.

**Tested:** built, not proven. No connector has been installed with any of these settings. The checks and the plan line were exercised offline; the settings the tool reads back from a connector were confirmed on a real one.

### 14.25 An upgrade that failed, or a version you want to back out of

**You have:** a run that ended `Failed`, `Unhealthy`, `Blocked` or `Error` for a connector, or a new version you do not want to keep.

**You want:** to know what state things are in, then fix it or go back.

1. Read the summary. `Blocked` and `DryRunFailed` mean nothing was changed. In a real run the tool stops at that connector: the tenant's other connectors were not started and are still on the old version, and by default no other tenant was started either.
2. Look at the connector, and read its logs in `FleetDeploy/FleetLogs/<tenant>_<connector>_<date>_<time>`: first `AccessConnector_Audit_*.log` (the install script's checks and the installer's exit code), then `AccessConnector_MSI_*.log` (the vendor installer's own log).

```
./Invoke-AccessConnectorUpgrade.ps1 -Mode Verify `
    -Connector connector1.example.local
```

3. Fix what the message names: an empty keytab with `-Mode RepairKeytab`, the wrong certificate with `-Mode RepairCertificate`, and "the installer needs this server restarted" by restarting the server, then Verify (section 13 and `docs/Troubleshooting.md`).
4. When the connector is healthy, run the tenant again. A connector already on the new version is skipped by the installer step.
5. Going back to the previous version: the tool never installs an older version over a newer one, and `-ForceReinstall` does not help. Restore the snapshot or backup you took before the change. Or uninstall the connector by hand, point its group (or a group of its own) at the previous installer, and clean install that server only with `-Connector`, after checking that the tenant accepts that version.

**Watch out:**

- "the connector returned no result" means the connection dropped or the helper was stopped: the work may still be running there. Check `result.json` on the connector before you run again, and never start a second run against the same connector.
- Keep the `KeytabBackup` and `CertBackup` folders in `C:\ProgramData\AccessConnectorUpdate` while you may still need to go back. Once the vendor Kerberos set-up has run again, rebuild the keytab with `-Mode RepairKeytab` rather than copying an old one back.
- `Failed` means the install script ended with an error: the installer failed, a pre-flight check stopped it, a downgrade was refused, an uninstall failed, or a check after the install failed. (The tool carries on past a failed check, and reports `Unhealthy` with the reason, only when `ExpectVersionPrefix` is set and the install moved the connector onto that version.) Its audit log says which.

**Tested:** dry runs catching wrong passwords and missing files, a wrong domain admin password failing with nothing changed, and both repair modes. Not yet: a real run stopped at an unhealthy connector, the restart of services after a failed install, and going back by a clean install of the previous version.

### 14.26 See every connector's state, change nothing

**You have:** connectors you reach over SSH, and a fleet file or just a list of their names.

**You want:** a report of each one (version, services, keytab, certificate) for a review or an audit, or after Windows patching: once, or every night, with nothing installed.

1. Run Verify (section 8.1). Each connector gets one line. It is green when healthy; red when a service is down, the keytab is empty or missing, or (for a group with a `Pfx`) the certificate is wrong or has expired; yellow when nothing is installed or a Java process lacks the Java4Shell patch flag. A red line makes the exit code 1, and the error log (`-ErrorLog`) names what is red on each connector. Add `-Tenant` or `-Connector` to narrow it. Verify needs a fleet file, but not the installer or the configuration files. With only a list of names, use Discover (step 4).
2. To keep the report, put `pwsh` in front and send the output to a file: `>` then catches every line, as plain text.

```
pwsh ./Invoke-AccessConnectorUpgrade.ps1 -Mode Verify > ./verify-report.txt
```

3. Every night: have a scheduler run this line in the `FleetDeploy` folder, through a shell (as cron does), because `>` is the shell's. Its exit code is 1 when a line is red or a connector could not be read, so the scheduler can raise an alert; the file says which. Search it for `[ERROR]` (red lines) and `[WARN ]` (yellow lines). Verify asks no questions; `-NonInteractive` makes a run stop instead of waiting if anything ever does.

```
pwsh -NonInteractive ./Invoke-AccessConnectorUpgrade.ps1 -Mode Verify > verify.txt
```

4. For the settings rather than the health, use Discover. It writes nothing on the connectors and asks no password, and with `-Connector` it needs no fleet file. Its draft lists each connector's services, service account, syslog target, ports, proxy, install folder and FIPS mode, with the installed version and the tenant in `Notes` (section 7.2). It does not show the keytab, or whether the services are running.

**Watch out:**

- Verify is not strictly read-only. On each connector it creates `C:\ProgramData\AccessConnectorUpdate` if it is missing, locks it to Administrators and SYSTEM, copies the helper script into it, and adds a line to the tool's own log there. It installs and changes nothing else. Do not run it while another run is using that connector.
- A yellow line keeps exit code 0, so a scheduler that looks only at the exit code does not see it: search the output for `[WARN ]` as well.
- Verify marks a certificate only once it has expired. Read the `to <date>` on each line to plan a renewal (14.30).
- A scheduler cannot type an SSH key passphrase. Its account needs an SSH agent that holds the key, or a key of its own with no passphrase that only it can read (section 4.3). Connect once by hand as that account, to check each host key.
- On a connector version that does not use the Java4Shell patch, every line is yellow (`java flag 0/<n>`): search for `[ERROR]` only.

**Tested:** Verify on all ten lab connectors, many times, matching independent checks, and Discover on all ten. Not yet: Verify from a real scheduler, and Verify with 1.5.1 against a connector: its first SSH step now goes through a new transport, and its exit code 1 on a red line is new; both have run in the offline tests only.

### 14.27 The fleet kept in Excel: change it and import it again

**You have:** `fleet.xlsx` in `FleetDeploy`, and the `fleet.psd1` written from it.

**You want:** to add or remove a connector, change a group's settings or point a group at a new installer, with the workbook as the one place where the fleet is changed.

1. Change the workbook. Keep `Fleet` as the first sheet. A group setting has one value: if a later row of the group repeats it, change it there too, or blank it. For a new installer, change `Installer`, `InstallerVersion` and `ExpectVersionPrefix` in cells formatted as Text. To remove a connector, delete its row.
2. Check it. Nothing is written and no connector is contacted. Read every note: they name the groups and connectors the new file would not have, the settings the current file has that the workbook leaves blank, and any files not yet in the staging folder.

```
./Invoke-AccessConnectorUpgrade.ps1 -ImportFleet ./fleet.xlsx -DryRun
```

3. Write it. Because `fleet.psd1` already holds groups, you type `YES`, and the old file is kept as `fleet.psd1.bak-<date>_<time>`. From a script, add `-Yes`. To undo an import, copy the backup back over `fleet.psd1`.

```
./Invoke-AccessConnectorUpgrade.ps1 -ImportFleet ./fleet.xlsx
```

4. Verify and rehearse the group you changed (section 8).

**Watch out:**

- Change the workbook, not the groups in `fleet.psd1`. Every import replaces all the groups with the workbook's, so a group changed only in `fleet.psd1` is lost at the next import (it is still in the backup).
- `StagingRoot`, `StagingFolders`, `CentralLogRoot`, `InstallScript` and `JavaPatchDir` have no column. Edit them in `fleet.psd1`; each import keeps them.
- Excel turns `26.10` in an ordinary cell into `26.1`. The template's `Fleet` sheet is formatted as Text; a workbook saved from Discover's CSV file is not, so format its version columns as Text before you type in them.
- Backup copies are never deleted. Remove old ones yourself.

**Tested:** Discover's drafts imported into scratch copies of the hand-written fleet files, which hold groups, with every setting the same apart from `ExpectVersionPrefix` (blank by design, and named by the import's note on settings the workbook leaves blank) and one real difference on a connector; and a file with no groups replaced without `YES`, with a copy kept. Offline only: the note naming the groups and connectors the workbook does not hold. In Microsoft Excel for Mac (16.115.1), the template opened with no repair prompt and kept its Text format (`26.10` typed into an empty `ExpectVersionPrefix` cell stayed `26.10`), and a copy saved by Excel imported with exactly the same plan as the template. Not yet: Excel for Windows, and a fleet file written by the import used for a real run.

### 14.28 Evidence for change control

**You have:** a change process that asks who ran what, when, against which connectors and with what result, and the state before and after.

**You want:** that record, from the tool's own files.

1. Save the state before the change:

```
pwsh ./Invoke-AccessConnectorUpgrade.ps1 -Mode Verify -AuditLog ./logs/ `
    > ./verify-before.txt
```

2. Rehearse and run the change with `-AuditLog` and `-ErrorLog` on every command. Given a folder, the tool writes `connector-fleet-audit.log` and `connector-fleet-errors.log` in it. The audit log gets one line per run: the time, the user, the admin machine, the tool version, the mode, whether it was a dry run, the outcome, the number of connectors and the duration. For an upgrade, a dry run or a repair, the line also names the groups and says how many connectors failed; for Verify, how many could not be read and how many had a red line.

```
./Invoke-AccessConnectorUpgrade.ps1 -Tenant TENANT1 `
    -AuditLog ./logs/ -ErrorLog ./logs/
```

3. Save the state after the change, as in step 1, to `verify-after.txt`.
4. Collect the two Verify files; the audit and error logs; `FleetLogs/ConnectorUpgrade_<date>_<time>.csv` (tenant, connector, status, version before and after, exit codes, message); and each `FleetLogs/<group>_<connector>_<date>_<time>/` folder, which is a copy of that connector's logs with the passwords masked.
5. Add the commands you typed. The audit line names the mode and the outcome, not the switches.

**Watch out:**

- `-AuditLog` and `-ErrorLog` have no default. Without them, neither file is written.
- A run cut short by Ctrl+C or a closed window writes no audit line and no CSV file: note it yourself.
- Logs are copied back only by SSH runs. WinRM, staged and scheduled runs leave them on each connector.
- These files hold site details such as host, tenant and account names. The audit log is only ever added to, but the tool does not protect it: if it is your formal record, limit who can write to its folder.

**Tested:** connector logs copied back with no recorded password left in them, on every upgrade since the cleaning was added. The audit and error log lines were checked offline.

### 14.29 A Kerberos Auth connector was upgraded by hand, and Kerberos sign-in broke

**You have:** a Kerberos Auth connector that someone upgraded outside the tool. Since then, browsers warn about its certificate, or Kerberos sign-in through it fails. The Access console may still show it as healthy.

**You want:** Kerberos sign-in working again without a reinstall, and the fleet file in line with what is installed.

1. Look at it. After a silent upgrade the installer serves a self-signed certificate of its own instead of your PFX certificate. The keytab is empty as well if the upgrade ran from a sign-in that could not reach Active Directory.

```
./Invoke-AccessConnectorUpgrade.ps1 -Mode Verify -Tenant TENANT1 `
    -Connector connector2.example.local
```

2. If it shows `keytab EMPTY`: rehearse, then run `-Mode RepairKeytab` for that connector. It asks for a domain admin (section 9).
3. If it shows `certificate SELF-SIGNED`: rehearse, then run `-Mode RepairCertificate`. Only the PFX password is asked, and only the Kerberos Auth service stops, for a few minutes.

```
./Invoke-AccessConnectorUpgrade.ps1 -Mode RepairCertificate -Tenant TENANT1 `
    -Connector connector2.example.local -DryRun
```

4. Verify again: the line should show `keytab ok` and `certificate ok`. Then sign in through that connector with Kerberos.
5. If the hand upgrade installed a newer version than the group's installer, put that installer in `Installers` and change `Installer`, `InstallerVersion` and `ExpectVersionPrefix`. Otherwise the next run of the group stops at that connector, because the tool never installs an older version over a newer one.

**Watch out:**

- Trust Verify, not the console: the Access console has shown Kerberos Auth as active on connectors whose keytab was empty.
- A keytab repair resets the password of the connector's Active Directory account. Kerberos sign-in through it stops for about a minute.
- The certificate repair refuses connectors in FIPS mode or with a proxy account (14.7, 14.24).
- A verbose installer log kept by whoever upgraded by hand can hold the passwords. The tool cleans only the logs in its own folder: find any others and delete them.

**Tested:** `-Mode RepairKeytab` on four connectors and `-Mode RepairCertificate` on five plus a test connector, with Kerberos sign-in through them afterwards. The faults there came from silent upgrades and from clean installs run under a local administrator. Not yet: a run refusing a connector newer than its installer (step 5).

### 14.30 A Kerberos certificate is about to expire

**You have:** Kerberos Auth connectors serving your PFX certificate, its end date coming up, and a renewed PFX that names every connector it is used on.

**You want:** the new certificate on every Kerberos Auth connector, one at a time, with no reinstall.

1. See the end dates: each Kerberos Auth connector's Verify line ends with `to <date>`.
2. Put the new PFX in `ChildCerts`. With the same file name, replace the old file, and keep the old one outside the staging folder until you are done. With a new name, change the group's `Pfx` (in the workbook, then import it, if you keep the fleet in Excel). Later upgrades then use the new PFX too.
3. Rehearse. For each connector the tool shows the certificate served now, the new PFX's end date and names, and whether a real run would change it.

```
./Invoke-AccessConnectorUpgrade.ps1 -Mode RepairCertificate -Tenant TENANT1 `
    -DryRun
```

4. Put it on, then check that every connector shows the new end date, and test a Kerberos sign-in. On each connector in turn, only the Kerberos Auth service stops, for a few minutes. If one does not end well, its configuration is put back and the run stops there.

```
./Invoke-AccessConnectorUpgrade.ps1 -Mode RepairCertificate -Tenant TENANT1
./Invoke-AccessConnectorUpgrade.ps1 -Mode Verify -Tenant TENANT1
```

**Watch out:**

- The rehearsal notes a PFX that expires within 30 days, and refuses one that has expired or is not valid yet.
- When other groups use the same PFX, leave out `-Tenant`: every Kerberos Auth group with a `Pfx` is then done, one connector at a time.

**Tested:** `-Mode RepairCertificate` and its dry run on six connectors, with Kerberos sign-in afterwards. The certificate replaced there was the installer's self-signed one. Replacing a valid older PFX certificate takes the same path, but no such run is recorded.

### 14.31 Several admins share one staging folder

**You have:** one staging folder on a file share, used by more than one admin from more than one admin machine (a Mac and a Windows PC, say).

**You want:** everyone on the same tool and fleet without getting in each other's way, a record of who ran what, and the tool updated once for everyone.

1. Leave `StagingRoot` out of the fleet file. The tool then uses the folder above `FleetDeploy`, so the same file works from `/Volumes/...` on a Mac and from `\\server\share\...` on Windows.
2. Give each admin machine its own SSH key, authorise every public key on every connector (section 4.4 adds one line per key), and check each host key once from each machine (section 4.6). `Install-OpenSSHServer.ps1` takes several keys in one run (`-PublicKey` with a list, or `-PublicKeyFile` with one key per line) and only adds them, so a key authorised earlier stays; `Deploy-OpenSSH-GPO.ps1` does the same for every connector in an OU.
3. Agree who runs which group, and when. Everyone adds `-AuditLog` and `-ErrorLog` naming the same folder, so one audit log shows every run, with its user and machine.
4. To update the tool, pick a time when nobody is running it. In a clone of the repository, `git pull`: fleet files, workbooks, installers, configuration files, certificates and logs are not tracked, so a pull leaves them alone. Otherwise copy over the two `FleetDeploy` scripts and `Silent Install\Install-AccessConnector.ps1`, keeping the old ones (Implementation Guide, section 10). Then check that both `FleetDeploy` scripts show the same version in `-Help`, and read `CHANGELOG.md`.

**Watch out:**

- There is no lock between admin machines, and the audit line is written only when a run ends. Two admins must never run against the same connector at the same time.
- Both `FleetDeploy` scripts must be the same version. Update every copy of the staging folder at the same time, and not while a scheduled job (14.8) is still waiting on a connector.
- When an admin or an admin machine leaves, delete its key's line from `C:\ProgramData\ssh\administrators_authorized_keys` on every connector. Neither script removes a key, and a key taken out of the GPO stays trusted on the connectors that already ran it. `Deploy-OpenSSH-GPO.ps1 -Help` (UNDOING IT) has a command to run on each connector.

**Tested:** the fleet file chosen with `-Fleet` and by default, and Verify from both staging copies after an update. Not yet: SSH modes from a Windows machine, several admins at once, and updating by `git pull`.

## 15. What the tool does not do

These come up when planning a roll-out. Each has a way around it.

| Situation | Why | Do this instead |
|---|---|---|
| WinRM over HTTPS (port 5986), or WinRM from a Mac or Linux machine | WinRM mode opens ordinary remoting sessions on port 5985, and runs only on Windows | Allow port 5985 (remoting encrypts what it carries), or use SSH |
| Verify, Discover, Stage, the repair modes or the copy of logs over WinRM | They are built on SSH | Open SSH on at least the Kerberos Auth connectors (14.3), or use the routes on the server in section 5.1 |
| A port, jump host or other SSH option for a connector in the fleet file | A connector entry holds only `Host` and `SshUser` | Put them in the SSH settings file on the admin machine (14.4, 14.5) |
| Choosing SSH or WinRM per connector | `-Mode` applies to the whole run | One group per route, each run with `-Tenant` (14.3) |
| Connectors that allow neither SSH nor WinRM | Every mode that contacts a connector needs one of them | Copy the files to the server yourself and run `Install-AccessConnector.ps1` there by hand (Command Reference). That route is outside the tool's testing. |
| An upgrade started by a scheduler on the admin machine, or passwords kept for later runs | Passwords are only ever asked at prompts; a run with no terminal stops at the first one, with nothing changed | Stage, then `-Schedule` on each connector, which keeps them encrypted there until the job runs; the job then deletes itself, and Task Scheduler's copy of your Windows password with it (14.8) |
| Going back to an older version | The tool never installs an older version over a newer one | Restore the snapshot, or uninstall by hand and clean install the older version (14.25) |
| A snapshot before the change, or an automatic roll-back | The tool copies the keytab and the Kerberos configuration and restarts services after a failed install, but does not snapshot the server or undo an upgrade | Snapshot or back up the server before the window |
| Retiring a connector | There is no uninstall-only mode, and the tool never changes the Access console | Do it by hand (14.21, step 5) |
| Adding or removing one service on an installed connector | The vendor installer has no working silent way | Change `Services`, then `-ForceReinstall` that connector (14.22) |
| Changing services, FIPS mode or the install folder in the same run as an upgrade | `-ForceReinstall` uninstalls only at the same version | Upgrade first, then reinstall (14.22, 14.24) |
| Changing the service account, or its password, on an installed connector | No mode changes it in place, and the installer has no silent reconfigure | `-ForceReinstall` one connector at a time, typing the new password (not yet proven for this), or the installer's own modify flow on the server |
| Checking that a version suits the tenant's Access service | The tool installs whatever installer the fleet file names | Read Omnissa's release notes |
| Seeing that a connector's installed services differ from its fleet entry | Neither the plan nor Verify compares them | `-Mode Discover -Connector <host>` and its "differs from fleet entry" note |
| Kerberos Auth or Virtual App on a server outside the domain | The Kerberos set-up must create the server's account in Active Directory | Join the server to the domain first, or leave those services off it |
| A different Kerberos certificate for each connector of one group | `Pfx` is a group setting | One group per connector, with the same `ConfigFile` (14.11) |
| The Kerberos certificate step on connectors in FIPS mode or with a proxy account | The vendor script would clear the stored proxy password, and FIPS mode is untested with it | The installer's Add/Remove Services on the server |
| A warning before the Kerberos certificate expires | Verify marks a certificate only once it has expired | Read the dates in Verify; the repair's dry run notes a PFX that expires within 30 days (14.30) |
| A lock between two admins' runs | Nothing links separate runs | Agree who runs which group, and when (14.31) |
| Removing an SSH key from many connectors | The tool never changes the connectors' SSH set-up, and the scripts in `Prerequisites` only add keys, also through Group Policy | Delete the key's line from `C:\ProgramData\ssh\administrators_authorized_keys` on each connector (14.31); `Deploy-OpenSSH-GPO.ps1 -Help` (UNDOING IT) has a command for it |
| Removing the staged files from a connector after a run | There is no clean-up option yet | Delete them by hand if your policy requires it; keep `KeytabBackup` and `CertBackup` while you may need to go back |
| A health report that a monitoring tool can read | Verify gives text and an exit code: 1 when a connector could not be read or has a red line, 0 otherwise, yellow lines included. There is no structured report | Use the exit code; save the output and search it for the detail (14.26) |

## 16. Where to read more

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
| The scripts in `Prerequisites` | PowerShell 7 for the admin machine, OpenSSH Server for the connectors: each script explains itself with `-Help` (the macOS one with `--help`) |

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
