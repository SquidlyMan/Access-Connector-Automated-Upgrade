# Access Connector Automated Upgrade

Install, upgrade and repair Omnissa Access Connectors from one command, one connector at a time per tenant, with checks before and after every change.

The tool is not tied to a connector version. It installs whichever installer file your fleet file names, so the same scripts handle the next release, a clean install on a new server, or a same-version reinstall.

> **Unsupported.** This is not an Omnissa product and is not covered by Omnissa support. It is provided "as is", with no warranty. Use it at your own risk and test it in a lab first. Each script shows the full disclaimer with `-Help`.

## What it does

- **Upgrades** existing connectors to the version of the installer you name.
- **Clean installs** a connector on a server that has none, with the same command.
- **Reinstalls** at the same version with `-ForceReinstall` (uninstall, then fresh install).
- **Installs the services you choose** per tenant entry: Directory Sync, User Auth, Kerberos Auth, Virtual App.
- **Keeps tenants online**: connectors in a tenant are done one at a time, and the run stops if one does not come back healthy.
- **Reaches connectors over SSH or WinRM**, from macOS, Linux or Windows.
- **Handles Kerberos Auth properly**: runs the install under a domain admin account so the keytab is rebuilt, checks the keytab, and puts your PFX certificate back after an upgrade (the vendor installer replaces it with a self-signed one).
- **Repairs** an empty keytab (`-Mode RepairKeytab`) or a wrong certificate (`-Mode RepairCertificate`) without reinstalling.
- **Reports** the state of every connector without changing anything (`-Mode Verify`).
- **Rehearses** with `-DryRun`: copies the files and runs every pre-flight check, installs nothing.
- **Protects passwords**: asked at hidden prompts, never stored, masked in all output, and removed from the vendor installer's own log after each install.

## Quick start

1. Read [docs/Getting-Started.md](docs/Getting-Started.md) (also as [Word](docs/Getting-Started.docx) and [PDF](docs/Getting-Started.pdf)).
2. Clone this repository to the machine or share you will run it from.
3. Add your installer to `Installers`, your `es-config.json` files to `Configs`, and (for Kerberos Auth) your PFX to `ChildCerts`.
4. Copy `FleetDeploy/fleet.example.psd1` to `FleetDeploy/fleet.psd1` and list your tenants and connectors.
5. From the `FleetDeploy` folder:

```powershell
# Look at every connector; change nothing
pwsh ./Invoke-AccessConnectorUpgrade.ps1 -Mode Verify -SshKey ~/.ssh/connector_ed25519

# Rehearse one tenant; nothing is installed
pwsh ./Invoke-AccessConnectorUpgrade.ps1 -Tenant TENANT1 -DryRun -SshKey ~/.ssh/connector_ed25519

# Upgrade (or clean install) that tenant
pwsh ./Invoke-AccessConnectorUpgrade.ps1 -Tenant TENANT1 -SshKey ~/.ssh/connector_ed25519
```

From Windows over PowerShell remoting instead of SSH:

```powershell
pwsh -ExecutionPolicy Bypass -File .\Invoke-AccessConnectorUpgrade.ps1 -Mode WinRM -Tenant TENANT1 -DryRun
```

## Modes

| Mode | What it does | Transport |
|---|---|---|
| `SSH` (default) | Upgrade or clean install | SSH |
| `WinRM` | Upgrade or clean install | PowerShell remoting, from Windows |
| `Stage` | Copy everything and write `Run-Upgrade.cmd` on each connector for you to run or schedule there | SSH |
| `Verify` | Report version, services, keytab and certificate; change nothing | SSH |
| `RepairKeytab` | Rebuild an empty Kerberos keytab | SSH |
| `RepairCertificate` | Put the PFX certificate on the Kerberos Auth service | SSH |

## Repository layout

The repository is laid out as the staging folder the tool expects, so a clone is ready to use once you add your own files.

| Path | Contents |
|---|---|
| `FleetDeploy/Invoke-AccessConnectorUpgrade.ps1` | The script you run (PowerShell 7) |
| `FleetDeploy/Invoke-ConnectorUpgradeLocal.ps1` | Helper that runs on each connector (Windows PowerShell 5.1) |
| `FleetDeploy/fleet.example.psd1` | Example fleet file |
| `Silent Install/Install-AccessConnector.ps1` | Wrapper around the vendor installer: pre-flight checks, silent install, audit log |
| `Installers/`, `Configs/`, `ChildCerts/`, `TrustedCerts/` | Where your installer, tenant files and certificates go (not stored in the repository) |
| `docs/` | Documentation |
| `legacy/` | The earlier WinRM-only fleet updater, for reference |

## Documentation

| Document | Contents |
|---|---|
| [Getting Started](docs/Getting-Started.md) ([Word](docs/Getting-Started.docx), [PDF](docs/Getting-Started.pdf)) | From nothing to a first upgrade: SSH or WinRM, SSH on Windows Server, fleet file, first run, clean installs, choosing services |
| [Implementation Guide](docs/Implementation-Guide.md) | Planning a roll-out, several domains or shares, change windows, scheduling, operations |
| [Command Reference](docs/Command-Reference.md) | Every mode, parameter, status and output |
| [Fleet File Reference](docs/Fleet-File-Reference.md) | Every fleet file setting |
| [How It Works](docs/How-It-Works.md) | The three scripts, what happens on a connector, the health checks |
| [Security](docs/Security.md) | How passwords, keys and files are handled |
| [Troubleshooting](docs/Troubleshooting.md) | Problems and fixes |
| [Engineering Notes](docs/Engineering-Notes.md) | What was learned about the vendor installer, and what not to do |
| [Validation Record](docs/Validation-Record.md) | What has been proven in testing and what has not |
| [Changelog](CHANGELOG.md) | Version history |
| [Roadmap](ROADMAP.md) | Known gaps and planned work |

## Requirements

- **Admin machine:** PowerShell 7. SSH modes need `ssh` and `scp` on the PATH. WinRM mode needs Windows.
- **Connectors:** Windows Server with Windows PowerShell 5.1, and either OpenSSH Server with key sign-in or PowerShell remoting.
- **Files:** the Omnissa Access Connector installer, each tenant's `es-config.json`, and for Kerberos Auth a PFX.
- **Accounts:** an administrator on each connector; for Kerberos Auth connectors a domain admin account, typed at run time.

## Status

Version 1.3.1. The tool has upgraded, clean installed and repaired connectors in a lab of ten connectors across four tenants and two Active Directory forests. Some paths are built but not yet proven by a real run; they are listed plainly in the [Validation Record](docs/Validation-Record.md). Read it before relying on a path it marks as unproven.

## Getting help with a script

```powershell
pwsh ./FleetDeploy/Invoke-AccessConnectorUpgrade.ps1 -Help
```

## Rebuilding the Word and PDF guide

`docs/Getting-Started.md` is the source. After editing it:

```bash
python3 tools/build_getting_started.py        # needs: pip install python-docx
soffice --headless --convert-to pdf --outdir docs docs/Getting-Started.docx
```
