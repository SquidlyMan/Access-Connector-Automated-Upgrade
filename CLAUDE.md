# Access Connector Automated Upgrade

Fleet tool that installs, upgrades and repairs Omnissa Access Connectors over SSH or WinRM. Start with `README.md`; the design is in `docs/How-It-Works.md` and the hard-won facts are in `docs/Engineering-Notes.md`.

**If `HANDOFF.md` exists in this folder, read it before doing anything.** It holds the current state, the site this copy is used against, and the owner's standing rules. It is not in version control.

## Layout

| Path | What |
|---|---|
| `FleetDeploy/Invoke-AccessConnectorUpgrade.ps1` | Orchestrator. PowerShell 7. Runs on the admin machine. |
| `FleetDeploy/Invoke-ConnectorUpgradeLocal.ps1` | Helper. Windows PowerShell 5.1. Runs on each connector. |
| `Silent Install/Install-AccessConnector.ps1` | Wrapper around the vendor installer. Windows PowerShell 5.1. |
| `docs/Getting-Started.md` | Source of `Getting-Started.docx` and `.pdf` |
| `tools/` | `check_scripts.sh` (offline checks), `build_getting_started.py` (Word build) |

## Rules for this repository

- **Version-neutral.** Never tie the tool, its name, help text or documents to one connector version. The version installed is whichever installer the fleet file names.
- **No site details in the repository.** No real host names, tenant names, domains, IP addresses, account names or share paths. Use `TENANT1`, `connector1.example.local`, `EXAMPLE\svc-access`. Site fleet files, installers, tenant configuration files, PFX files and logs are git-ignored; keep it that way.
- **No secrets anywhere.** Never print, log or commit a password, key, token or the contents of an `es-config.json`. Never print the `Adding AW... property` lines of an `AccessConnector_MSI_*.log`; count them instead.
- **Connector-side scripts are ASCII-only and Windows PowerShell 5.1 compatible** (no ternary, no `&&`/`||`, no `?.`). The orchestrator may use PowerShell 7 features.
- **State only what is proven.** `docs/Validation-Record.md` separates what a real run has proven from what is only built. Keep it honest when you change anything.
- **Both scripts in `FleetDeploy` carry the same version** and are released together. Help-text-only and document-only changes are a patch version.
- Follow the owner's Omnissa PowerShell standards for these scripts: colour help wrapped at 78 columns with worked examples, the disclaimer (red in `-Help`, yellow notice on every run), append-only audit log and error log switches, secrets masked everywhere, and switch conflicts reported before work starts.

## Before every commit

```bash
sh tools/check_scripts.sh
```

It parses the three scripts, checks for PowerShell 7-only constructs and non-ASCII bytes, checks the help width and that the two versions match. It never runs the scripts against anything.

After editing `docs/Getting-Started.md` (keep lines inside code blocks at 82 characters or fewer, or they wrap in Word):

```bash
python3 tools/build_getting_started.py
soffice --headless --convert-to pdf --outdir docs docs/Getting-Started.docx
```

## Changing a script

1. Edit, then `sh tools/check_scripts.sh`.
2. Bump `$script:Version` in both `FleetDeploy` scripts; add a `CHANGELOG.md` entry.
3. Update the documents the change touches, including `docs/Validation-Record.md` (a new code path starts as "built, not proven").
4. Real runs against connectors are the owner's to start. He types every password. Do not run an install, repair or stage mode yourself unless he tells you to in that session.

## Testing without a connector

A scratch copy of the layout with empty placeholder files and hosts ending `.invalid` exercises fleet-file reading, selection, the plan and the missing-file messages (`-Mode Verify` or `-Mode Stage` print the plan, then fail to connect). Never test with real passwords; never put a test password on a command line.
