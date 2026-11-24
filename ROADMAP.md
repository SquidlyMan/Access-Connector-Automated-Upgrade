# Roadmap

Known gaps and planned work, most useful first. Item 3 under Next is tracked as issue 3 on the repository.

## Next

### 1. Service selection for a connector or group of connectors (done)

Services are chosen per connector group (one fleet entry), and a group can hold a single connector. This is documented in Getting Started section 11 and in the Fleet File Reference. Issue 1 is closed.

Small follow-ups, not scheduled: have Verify and the plan show installed services against wanted services and say when a forced reinstall is needed; print a reminder to disable the connector's Active Directory account when Kerberos Auth is removed.

### 2. Carry the remaining installer settings through the fleet file (done in 1.4.0)

Install folder, FIPS mode, service ports and outbound proxy are fleet-file settings; the proxy password is asked at run time. Issue 2. Not yet proven by a real run (Validation Record).

### 3. Prove the unproven paths

From the Validation Record: the certificate step inside a real upgrade (needs the next connector release: a forced reinstall is a fresh install, where the installer keeps the PFX), WinRM with Kerberos Auth connectors, `-Parallel`, `-ParallelTenants`, `-Schedule`, SSH modes from Windows and Linux admin machines, cmd.exe as the SSH default shell, the 1.4.0 installer settings, the 1.4.0 wrapper checks, and the rest of the 1.5.0 spreadsheet import and discovery (`-Mode Discover` has read all ten lab connectors read-only with the final build, its drafts imported back gave the hand-written fleet files' settings, a partial read started a new fleet file that the import then filled, and the template saved by Microsoft Excel for Mac imported unchanged; still to run: a workbook saved by Excel for Windows and a CSV file saved by Excel, anything on a Windows admin machine, discovery of a connector with a proxy, custom ports, a non-default install folder or FIPS mode, case-only grouping on real connectors, the stop at a prompt with no terminal on a real scheduler, and a fleet file written by the import used for a real run), and the rest of what 1.5.1 adds (Verify through the new SSH transport, the SSH sign-in check before the prompts and a refused sign-in with SSH's reason and hint ran on the lab connectors on 2026-11-24): the other hints, the stop on a WinRM sign-in the connector refuses, Verify's exit code 1 on a red line, and the `-Schedule` task that deletes itself, with its refusals and the switches its run is given. Also the first real runs of the four set-up scripts in `Prerequisites` (1.5.1), each on one machine first: PowerShell 7 installed and updated on a Windows and on a macOS admin machine, OpenSSH Server installed on a server that does not have it, with `-AllowFrom` and through `Invoke-Command` (on 2026-11-24 `Install-OpenSSHServer.ps1` turned password sign-in off on nine servers that already ran OpenSSH Server), and the Group Policy deployment to a test OU.

### 4. Fleet file from a spreadsheet, and discovery of existing connectors (done in 1.5.0)

`-ImportFleet` writes the fleet file from an Excel workbook or a CSV file with one row per connector, after checking it. `-Mode Discover` reads installed connectors over SSH, read-only, into a draft spreadsheet in the same columns. Templates in `FleetDeploy`. Offline tests in three suites. With the final build, Discover read the ten lab connectors with every draft row complete, and its drafts imported back gave the same settings as the hand-written fleet files, apart from `ExpectVersionPrefix` (left blank by design; the import named it for every group) and one syslog host name mistyped on a connector at its installation (that connector was drafted as `<entry>-2`, and the other connector of its entry kept the entry's name). A partial read started a new fleet file with the original's top-level settings, and importing into it needed no `-Yes`. What is still unproven is in item 3 and the Validation Record.

## Later

- **WinRM parity:** Verify, RepairKeytab and RepairCertificate over WinRM; logs copied back in WinRM mode.
- **Discovery over WinRM:** `-Mode Discover` from a Windows admin machine where the connectors have no SSH.
- **Generic post-install step:** the patch step is tied to the Java4Shell patch and its flag. Make it a named script and an optional check, so a future vendor patch needs no code change.
- **Compatibility pre-check:** warn when the installer version is not listed as a supported upgrade from the installed version.
- **Clean-up option:** remove the staged installer, configuration file and PFX from the connector after a successful run.
- **Certificate expiry warning** in Verify, a set number of days ahead.
- **Tests:** three offline suites now cover the spreadsheet import and discovery (1.5.0) and, since 1.5.1, the SSH sign-in check and messages, the WinRM sign-in stop, Verify's exit code and the helper's `-Schedule`; four more (1.5.1) cover the `Prerequisites` scripts; `tools/check_scripts.sh` runs them all. The 144-check Group Policy simulation of `Deploy-OpenSSH-GPO.ps1` ran in a scratch folder and is not in the repository, because it takes more than a minute; a faster version of it belongs in `tools/`. Extend them to the rest of what needs no connector: fleet-file parsing, the plan, missing-file messages, log cleaning. Give the end-to-end suite and the discovery suite's transport cases stand-ins for ssh and scp that also work on Windows; today only the end-to-end suite's unit cases run there.
- **Continuous integration:** a GitHub Actions run of the offline tests and `tools/check_scripts.sh` on every push.
