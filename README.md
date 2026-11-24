# Access Connector Automated Upgrade

Install, upgrade and repair Omnissa Access Connectors from one command, one connector at a time per tenant, with checks before and after every change.

The tool is not tied to a connector version. It installs whichever installer file your fleet file names, so the same scripts handle the next release, a clean install on a new server, or a same-version reinstall.

> **Unsupported.** This is not an Omnissa product and is not covered by Omnissa support. It is provided "as is", with no warranty. Use it at your own risk and test it in a lab first. Each script shows the full disclaimer with `-Help`.

## What it does

- **Upgrades** existing connectors to the version of the installer you name.
- **Clean installs** a connector on a server that has none, with the same command.
- **Reinstalls** at the same version with `-ForceReinstall` (uninstall, then fresh install).
- **Installs the services you choose**, for a single connector or a group of connectors: Directory Sync, User Auth, Kerberos Auth, Virtual App.
- **Keeps tenants online**: connectors in a tenant are done one at a time, and the run stops if one does not come back healthy.
- **Reaches connectors over SSH or WinRM**, from macOS, Linux or Windows.
- **Handles Kerberos Auth properly**: runs the install under a domain admin account so the keytab is rebuilt, checks the keytab, and puts your PFX certificate back after an upgrade (the vendor installer replaces it with a self-signed one).
- **Repairs** an empty keytab (`-Mode RepairKeytab`) or a wrong certificate (`-Mode RepairCertificate`) without reinstalling.
- **Reports** the state of every connector (`-Mode Verify`), installing nothing and changing no connector setting (it only stages its helper on each), with exit code 1 when a connector could not be read or has a red line.
- **Checks the SSH sign-in first**: before it asks for anything, an upgrade, dry run or repair over SSH signs in to every selected connector and stops if one fails, with SSH's own reason and, when that reason suggests one, a hint.
- **Rehearses** with `-DryRun`: copies the files and runs every pre-flight check on every connector, installs nothing, and says when a real run would skip a connector.
- **Carries the installer settings** from the fleet file: install folder, FIPS mode, service ports and an outbound proxy.
- **Builds the fleet file from a spreadsheet** (`-ImportFleet`): one row per connector in an Excel workbook or a CSV file, checked before anything is written. An existing fleet file is kept as a dated copy. Templates are in `FleetDeploy`.
- **Discovers connectors already installed** (`-Mode Discover`): reads their current settings over SSH, copying and changing nothing, into a draft spreadsheet for the import.
- **Protects passwords**: asked at hidden prompts, never stored, masked in all output, and removed from the vendor installer's own log after each install.
- **Comes with set-up scripts** (`Prerequisites`, built but not yet run on Windows or macOS): PowerShell 7 for a Windows or macOS admin machine, and OpenSSH Server with key-only sign-in for one connector, or for every connector in an organizational unit (OU) through Group Policy.

## Quick start

1. Read [docs/Getting-Started.md](docs/Getting-Started.md) (also as [Word](docs/Getting-Started.docx) and [PDF](docs/Getting-Started.pdf)).
2. Clone this repository to the machine or share you will run it from.
3. Install PowerShell 7 on the admin machine: on Windows, double-click `Prerequisites\Install-PowerShell7.cmd`; on a Mac, run `bash Prerequisites/install-powershell7-macos.sh`. Homebrew or winget work too (Getting Started, quick start step 1).
4. Open SSH on each connector, with one SSH key made on the admin machine: `Prerequisites\Install-OpenSSHServer.ps1` with your public key, run elevated on the connector or through `Invoke-Command` from a Windows admin machine; for every connector in an OU, `Prerequisites\Deploy-OpenSSH-GPO.ps1` (Getting Started, section 4). Or use WinRM (section 5).
5. Add your installer to `Installers`, your `es-config.json` files to `Configs`, and (for Kerberos Auth) your PFX to `ChildCerts`.
6. Copy `FleetDeploy/fleet.example.psd1` to `FleetDeploy/fleet.psd1` and list your tenants and connectors. Or fill in a copy of `FleetDeploy/fleet.example.xlsx`, saved under a name of your own such as `fleet.xlsx`, and let the tool write the fleet file from it; for connectors already installed, `-Mode Discover` drafts that spreadsheet for you (Getting Started, section 7).
7. From the `FleetDeploy` folder:

```powershell
# If you used a spreadsheet: check it, then write fleet.psd1 from it
pwsh ./Invoke-AccessConnectorUpgrade.ps1 -ImportFleet ./fleet.xlsx -DryRun
pwsh ./Invoke-AccessConnectorUpgrade.ps1 -ImportFleet ./fleet.xlsx

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
| `Discover` | Read each connector's settings into a draft spreadsheet for `-ImportFleet`; copy and change nothing | SSH |
| `RepairKeytab` | Rebuild an empty Kerberos keytab | SSH |
| `RepairCertificate` | Put the PFX certificate on the Kerberos Auth service | SSH |

## Repository layout

The repository is laid out as the staging folder the tool expects, so a clone is ready to use once you add your own files.

| Path | Contents |
|---|---|
| `FleetDeploy/Invoke-AccessConnectorUpgrade.ps1` | The script you run (PowerShell 7) |
| `FleetDeploy/Invoke-ConnectorUpgradeLocal.ps1` | Helper that runs on each connector (Windows PowerShell 5.1) |
| `FleetDeploy/fleet.example.psd1` | Example fleet file |
| `FleetDeploy/fleet.example.xlsx`, `FleetDeploy/fleet.example.csv` | Spreadsheet templates for `-ImportFleet`, with the same example rows |
| `Silent Install/Install-AccessConnector.ps1` | Wrapper around the vendor installer: pre-flight checks, silent install, audit log |
| `Prerequisites/Install-PowerShell7.ps1`, `Install-PowerShell7.cmd` | Installs or updates PowerShell 7 on a Windows admin machine (Windows PowerShell 5.1; double-click the `.cmd`) |
| `Prerequisites/install-powershell7-macos.sh` | Installs or updates PowerShell 7 on a macOS admin machine |
| `Prerequisites/Install-OpenSSHServer.ps1` | Sets up OpenSSH Server with key-only sign-in on one connector (Windows PowerShell 5.1), on the server or through `Invoke-Command` |
| `Prerequisites/Deploy-OpenSSH-GPO.ps1` | Runs `Install-OpenSSHServer.ps1` on every computer of one OU, as a Group Policy computer startup script |
| `Installers/`, `Configs/`, `ChildCerts/`, `TrustedCerts/` | Where your installer, tenant files and certificates go (not stored in the repository) |
| `docs/` | Documentation |
| `tools/` | Offline checks and test suites of the scripts, and the builders of the Word guide and the spreadsheet templates |
| `legacy/` | The earlier WinRM-only fleet updater, for reference |

## Documentation

| Document | Contents |
|---|---|
| [Getting Started](docs/Getting-Started.md) ([Word](docs/Getting-Started.docx), [PDF](docs/Getting-Started.pdf)) | From nothing to a first upgrade: a quick start (what to have ready, then nine steps), SSH or WinRM, SSH on Windows Server (one script per connector, or by hand), fleet file (by hand, from a spreadsheet, or discovered from installed connectors), first run, clean installs, choosing services; then 31 worked use cases for different networks, domains and kinds of deployment, and what the tool does not do |
| [Implementation Guide](docs/Implementation-Guide.md) | Planning a roll-out, several domains or shares, change windows, scheduling, operations |
| [Command Reference](docs/Command-Reference.md) | Every mode, parameter, status and output |
| [Fleet File Reference](docs/Fleet-File-Reference.md) | Every fleet file setting; building the file from a spreadsheet; discovering existing connectors |
| [How It Works](docs/How-It-Works.md) | The three scripts, what happens on a connector, the health checks |
| [Security](docs/Security.md) | How passwords, keys and files are handled |
| [Troubleshooting](docs/Troubleshooting.md) | Problems and fixes |
| [Engineering Notes](docs/Engineering-Notes.md) | What was learned about the vendor installer, and what not to do |
| [Validation Record](docs/Validation-Record.md) | What has been proven in testing and what has not |
| [Changelog](CHANGELOG.md) | Version history |
| [Roadmap](ROADMAP.md) | Known gaps and planned work |

## Requirements

- **Admin machine:** PowerShell 7 or later (`pwsh`); the tool refuses to start under Windows PowerShell 5.1. `Prerequisites` has installers for Windows and macOS. SSH modes need `ssh` and `scp` on the PATH; `-Mode Discover` needs `ssh` only, and `-ImportFleet` neither. WinRM mode needs Windows.
- **Connectors:** Windows Server with Windows PowerShell 5.1, and either OpenSSH Server with key sign-in (`Prerequisites/Install-OpenSSHServer.ps1` sets it up) or PowerShell remoting.
- **Files:** the Omnissa Access Connector installer, each tenant's `es-config.json`, and for Kerberos Auth a PFX.
- **Accounts:** an administrator on each connector; for Kerberos Auth connectors a domain admin account, typed at run time.

## Status

Version 1.5.1. The tool has upgraded, clean installed and repaired connectors in a lab of ten connectors across four tenants and two Active Directory forests. Some paths are built but not yet proven by a real run; they are listed plainly in the [Validation Record](docs/Validation-Record.md). Read it before relying on a path it marks as unproven.

The set-up scripts in `Prerequisites` are built and checked offline, and have not yet run on Windows or macOS. They carry their own versions: 1.0.0 for the three PowerShell scripts, 2.1.0 for the macOS one, which continues the author's earlier 2.0.1. They are rewritten from the author's earlier scripts, which were used in the lab: OpenSSH Server with key-only sign-in was deployed by a Group Policy startup script in one forest and by hand in the other, and PowerShell 7 was deployed to servers by Group Policy. The rewritten versions were checked with offline simulations on macOS, with stand-ins for Windows, Group Policy, Active Directory, sudo and the installers (Validation Record).

What 1.5.1 adds has been tested offline only, and not yet run against a connector: SSH failures name SSH's own reason with a hint, an SSH sign-in check before anything is asked, a WinRM sign-in that a connector refuses stops the run (dry runs and `-Parallel` too), Verify's exit code 1 on a red line, and a `-Schedule` task that deletes itself, keeps the switches it was given and refuses a time that has passed. The rest of what is said below about 1.5.0 still holds.

Of what 1.5.0 adds: with the final 1.5.0 build, `-Mode Discover` has read all ten lab connectors, read-only, over SSH from a macOS admin machine, and every row of its drafts was complete. Imported back with `-ImportFleet` into scratch copies of the hand-written fleet files, every connector had the same settings as those files, with two exceptions: `ExpectVersionPrefix`, which discovery leaves blank by design and the import's dry run named for every group, and one connector's syslog host name, which had been mistyped on that connector when it was installed (a real difference: that connector was given a group of its own, `<entry>-2`, and the other connector of its entry kept the entry's name). A partial read, of one group of a fleet file with two, started a new fleet file with the original's top-level settings, and the import shown wrote the group into it without `-Yes`, with those settings kept. Dry runs with 1.5.0 from both lab staging copies passed on four connectors, with every prompt working normally and the 1.4.1 would-skip note in the summary. In Microsoft Excel for Mac, the spreadsheet template opened with no repair prompt and kept its Text format, and a copy saved by Excel itself imported with exactly the same plan as the template. Not yet run: a workbook saved by Excel for Windows, a CSV file saved by Excel, anything on a Windows admin machine, discovery of a connector with a proxy, custom ports, a non-default install folder or FIPS mode, case-only grouping on real connectors, the stop at a prompt with no terminal from a real scheduler, and a fleet file written by the import used for an upgrade.

## Licence

MIT. See [LICENSE](LICENSE). The licence and the disclaimer both say the same thing: no warranty, and no liability for the author or for Omnissa.

## Getting help with a script

```powershell
pwsh ./FleetDeploy/Invoke-AccessConnectorUpgrade.ps1 -Help
```

Each script in `Prerequisites` has `-Help` as well (`--help` for the macOS one).

## Checking the scripts

```bash
sh tools/check_scripts.sh
```

Needs `pwsh`, `python3` and `bash`. It:

- parses the three scripts and the three PowerShell scripts in `Prerequisites`, and fails on non-ASCII bytes in any of them, and on PowerShell 7-only constructs (the ternary operator, `&&`, `||`, `??`, `??=`, `?.`, `?[]`) in all of them but the orchestrator. It finds the constructs by the syntax tree, so one inside a `"...$(...)..."` string is found too. In a `Prerequisites` script it also checks the code a single-quoted here-string carries, which runs under Windows PowerShell 5.1 later (the startup wrapper of `Deploy-OpenSSH-GPO.ps1`, the login-alert task of `Install-OpenSSHServer.ps1`);
- checks that `Install-PowerShell7.cmd` is ASCII with CRLF line ends throughout, and that `install-powershell7-macos.sh` is ASCII and passes `bash -n` under `/bin/bash` (and `shellcheck` at warning level, when it is installed);
- checks the help width of the two `FleetDeploy` scripts and of the four `Prerequisites` scripts, that the two `FleetDeploy` versions match, and that `fleet.example.psd1` parses;
- runs the offline test suites and prints any case that did not pass: `tools/test_fleet_import.ps1` (57 cases), `tools/test_fleet_discover.ps1` (45) and `tools/test_fleet_e2e.ps1` (44) for the tool; `tools/test_prereq_openssh.ps1` (96), `tools/test_prereq_gpo_keys.ps1` (27), `tools/test_prereq_powershell7.sh` (109) and, on macOS only, `tools/test_prereq_macos.sh` (102) for the `Prerequisites` scripts. On Windows only the end-to-end suite's unit cases run, and the discovery suite's transport cases are skipped, because their stand-ins for ssh and scp are shell scripts; the `Prerequisites` suites have been run on macOS only;
- checks that the committed templates `fleet.example.csv` and `fleet.example.xlsx` are exactly what a fresh `python3 tools/build_fleet_template.py` makes, and dry-runs `-ImportFleet` on each.

It ends with `ALL CHECKS PASSED` or `CHECKS FAILED`, after about three minutes on the author's Mac, nearly two of them for the `Prerequisites` suites. It never contacts a connector, domain controller or share, and it never runs a `Prerequisites` script for real: the suites work in temporary folders with stand-ins for ssh and scp, Windows, Group Policy, the network, sudo and the installers, and remove those folders when they finish, as `check_scripts.sh` removes its own. The Validation Record says what each suite covers.

## Rebuilding the spreadsheet templates

```bash
python3 tools/build_fleet_template.py        # standard library only
```

Writes `FleetDeploy/fleet.example.csv` and `FleetDeploy/fleet.example.xlsx` from one definition of the example rows. The output is the same, byte for byte, each time; `tools/check_scripts.sh` fails when the committed templates are not what the script makes now.

## Rebuilding the Word and PDF guide

`docs/Getting-Started.md` is the source. After editing it:

```bash
python3 tools/build_getting_started.py        # needs: pip install python-docx
soffice --headless --convert-to pdf --outdir docs docs/Getting-Started.docx
```
