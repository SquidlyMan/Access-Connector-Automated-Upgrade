# Access Connector Automated Upgrade

Fleet tool that installs, upgrades and repairs Omnissa Access Connectors over SSH or WinRM. Start with `README.md`; the design is in `docs/How-It-Works.md` and the hard-won facts are in `docs/Engineering-Notes.md`.

**If `HANDOFF.md` exists in this folder, read it before doing anything.** It holds the current state, the site this copy is used against, and the owner's standing rules. It is not in version control.

## Layout

| Path | What |
|---|---|
| `FleetDeploy/Invoke-AccessConnectorUpgrade.ps1` | Orchestrator. PowerShell 7. Runs on the admin machine. |
| `FleetDeploy/Invoke-ConnectorUpgradeLocal.ps1` | Helper. Windows PowerShell 5.1. Runs on each connector. |
| `Silent Install/Install-AccessConnector.ps1` | Wrapper around the vendor installer. Windows PowerShell 5.1. |
| `FleetDeploy/fleet.example.psd1`, `fleet.example.csv`, `fleet.example.xlsx` | Example fleet file and the spreadsheet templates for `-ImportFleet` (the two templates are built by `tools/build_fleet_template.py`; do not edit them by hand) |
| `Prerequisites/` | Set-up scripts, apart from the tool and with their own versions: `Install-PowerShell7.ps1` and its launcher `Install-PowerShell7.cmd` (PowerShell 7 on a Windows admin machine), `install-powershell7-macos.sh` (PowerShell 7 on a macOS admin machine), `Install-OpenSSHServer.ps1` (OpenSSH Server with key-only sign-in on one connector), `Deploy-OpenSSH-GPO.ps1` (that script as a Group Policy computer startup script for one OU). Built, not yet run on Windows or macOS. |
| `docs/Getting-Started.md` | Source of `Getting-Started.docx` and `.pdf` |
| `tools/` | `check_scripts.sh` (offline checks), `build_getting_started.py` (Word build), `build_fleet_template.py` (spreadsheet templates), `test_fleet_import.ps1`, `test_fleet_discover.ps1`, `test_fleet_e2e.ps1` (offline test suites of the tool), `test_prereq_openssh.ps1`, `test_prereq_gpo_keys.ps1`, `test_prereq_powershell7.sh`, `test_prereq_macos.sh` (offline test suites of the `Prerequisites` scripts; the last runs on macOS only) |

## Rules for this repository

- **Version-neutral.** Never tie the tool, its name, help text or documents to one connector version. The version installed is whichever installer the fleet file names.
- **No site details in the repository.** No real host names, tenant names, domains, IP addresses, account names or share paths. Use `TENANT1`, `connector1.example.local`, `EXAMPLE\svc-access`. Site fleet files, installers, tenant configuration files, PFX files and logs are git-ignored; keep it that way.
- **No secrets anywhere.** Never print, log or commit a password, key, token or the contents of an `es-config.json`. Never print the `Adding AW... property` lines of an `AccessConnector_MSI_*.log`; count them instead.
- **Connector-side scripts are ASCII-only and Windows PowerShell 5.1 compatible** (no ternary, no `&&`/`||`, no `?.`). This includes `$script:DiscoverRemoteScript` in the orchestrator, which runs on each connector from standard input (`powershell -Command -`) and must stay read-only and allow-list only: it may never keep or send a value of `install.properties` or `application.properties` other than the allow-listed lines. The orchestrator may use PowerShell 7 features.
- **State only what is proven.** `docs/Validation-Record.md` separates what a real run has proven from what is only built. Keep it honest when you change anything.
- **Both scripts in `FleetDeploy` carry the same version** and are released together. Help-text-only and document-only changes are a patch version.
- **The `Prerequisites` scripts** follow the same standards, with these rules. The three `.ps1` scripts run under Windows PowerShell 5.1: ASCII-only, no PowerShell 7-only syntax, and the same for the code they carry in a here-string to run later (`$script:LauncherText`, the GPO startup wrapper; `$script:AlertCode`, the login-alert task). `Install-PowerShell7.cmd` keeps CRLF line ends and stays ASCII. `install-powershell7-macos.sh` runs under the stock macOS `/bin/bash` 3.2 (no `declare -A`, `mapfile`, `${v,,}` or other bash 4 features) and is ASCII-only. Each carries its own version, not the tool's: 1.0.1 for `Install-OpenSSHServer.ps1` and `Install-PowerShell7.ps1` (the `.cmd` goes with its `.ps1`), 1.0.0 for `Deploy-OpenSSH-GPO.ps1`, 2.1.1 for the `.sh` (`SCRIPT_VERSION`), which continues the author's earlier 2.0.1. `Deploy-OpenSSH-GPO.ps1` checks keys and `-AllowFrom` with `Install-OpenSSHServer.ps1`'s own functions, taken from its syntax tree at run time, and refuses a payload whose check functions call any command but each other, `Add-Warning`, `New-Object`, `Where-Object`, `ForEach-Object`, `Test-Path` and `Resolve-Path` (by name), or use any variable but their own, the payload's parameters `$PublicKey`, `$PublicKeyFile` and `$AllowFrom`, `$env:` variables, `$script:KeyTypes` and `$script:PrivateKeyText`: keep those functions self-contained (an ordinary cmdlet such as `Get-Item` or `Select-Object` added to one gets the payload refused), and run `tools/test_prereq_gpo_keys.ps1` after changing either script.
- Follow the owner's Omnissa PowerShell standards for these scripts: colour help wrapped at 78 columns with worked examples, the disclaimer (red in `-Help`, yellow notice on every run), append-only audit log and error log switches, secrets masked everywhere, and switch conflicts reported before work starts.

## Before every commit

```bash
sh tools/check_scripts.sh
```

It parses the three scripts and the three `Prerequisites` PowerShell scripts, checks for PowerShell 7-only constructs (in the `Prerequisites` scripts also in the code their here-strings carry) and non-ASCII bytes, checks that the `.cmd` is ASCII with CRLF line ends and the `.sh` is ASCII and passes `bash -n` under `/bin/bash` (and `shellcheck` when installed), checks the help width of six scripts and that the two `FleetDeploy` versions match, runs the seven offline test suites (the macOS installer's on macOS only), checks that the committed spreadsheet templates equal a fresh build, and dry-runs `-ImportFleet` on both. It takes about three minutes. It contacts no connector, domain controller or share and runs no `Prerequisites` script for real: the suites use temporary folders and stand-ins for `ssh`, Windows, Group Policy, sudo and the installers.

After changing the example rows or the instruction text in `tools/build_fleet_template.py`:

```bash
python3 tools/build_fleet_template.py
```

After editing `docs/Getting-Started.md` (keep lines inside code blocks at 82 characters or fewer, or they wrap in Word):

```bash
python3 tools/build_getting_started.py
soffice --headless --convert-to pdf --outdir docs docs/Getting-Started.docx
```

## Changing a script

1. Edit, then `sh tools/check_scripts.sh`.
2. Bump `$script:Version` in both `FleetDeploy` scripts; add a `CHANGELOG.md` entry. A `Prerequisites` script bumps only its own version (`$script:Version`, or `SCRIPT_VERSION` in the `.sh`), with a line in the `CHANGELOG.md` entry of the release it ships in.
3. Update the documents the change touches, including `docs/Validation-Record.md` (a new code path starts as "built, not proven").
4. Real runs against connectors are the owner's to start. He types every password. Do not run an install, repair or stage mode yourself unless he tells you to in that session. The same holds for the `Prerequisites` scripts, which change servers, Group Policy and the admin machine: run only their `-Help` (`--help` for the `.sh`) and the offline suites.

## Testing without a connector

A scratch copy of the layout with empty placeholder files and hosts ending `.invalid` exercises fleet-file reading, selection, the plan and the missing-file messages (`-Mode Verify` or `-Mode Stage` print the plan, then fail to connect). Never test with real passwords; never put a test password on a command line.
