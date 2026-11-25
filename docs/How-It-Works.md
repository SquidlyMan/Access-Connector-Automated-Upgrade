# How It Works

## The three scripts

| Script | Runs on | Runs under | Job |
|---|---|---|---|
| `FleetDeploy/Invoke-AccessConnectorUpgrade.ps1` | Your admin machine | PowerShell 7 | Reads the fleet file, asks for passwords, copies files to each connector, starts the helper, enforces the one-at-a-time order and the health gate, writes the summary. Also writes the fleet file from a spreadsheet (`-ImportFleet`) and reads installed connectors into one (`-Mode Discover`). |
| `FleetDeploy/Invoke-ConnectorUpgradeLocal.ps1` | Each connector | Windows PowerShell 5.1, elevated | Records the state before, runs the wrapper, restores the Kerberos certificate, runs the optional patch, checks health, cleans the vendor log, returns a result |
| `Silent Install/Install-AccessConnector.ps1` | Each connector | Windows PowerShell 5.1 | Pre-flight checks, stops the services, runs the vendor installer silently, starts the services, checks the Kerberos keytab, writes an audit log |

The split exists because the connector side must work with what Windows Server already has (PowerShell 5.1), while the admin side can run anywhere PowerShell 7 does.

## What happens in a run

### On the admin machine

1. The fleet file is chosen and read. Tenants and connectors are filtered by `-Tenant` and `-Connector`.
2. Every file the run needs is checked under the staging folder. A missing file stops the run before any connector is contacted.
3. The plan is printed: fleet file, order, installer, and each connector.
4. Over SSH (an upgrade or dry run, and the two repair modes), the tool signs in to every selected connector with a trivial Windows PowerShell command. If one fails, the run stops here with exit code 1, naming SSH's own reason for each, with a hint when the reason suggests one, before anything is asked or changed.
5. Unless `-DryRun` or `-Yes`, you type `YES` to continue.
6. Passwords are asked once per tenant at hidden prompts.
7. For each connector in turn: copy the payload, start the helper, relay its output, collect its result.
8. After each connector the health gate decides whether the run goes on.
9. A summary, a CSV and (SSH modes) the connector's logs are written to the central log folder.

### The payload

Copied to `C:\ProgramData\AccessConnectorUpdate` on the connector (changeable with `-RemoteStageDir`):

| Item | Notes |
|---|---|
| `Invoke-ConnectorUpgradeLocal.ps1`, `Install-AccessConnector.ps1` | The two connector-side scripts |
| The installer `.exe` | Skipped when a copy with the same SHA-256 hash is already there; verified by hash after copying |
| The tenant's `es-config.json` | |
| The Kerberos PFX | Only when the tenant has a `Pfx` |
| `TrustedCerts\` | `.pem`, `.cer`, `.crt` files only |
| `Java4shellPatch\` | Only when `JavaPatchDir` is set and `-SkipJavaPatch` is not |
| `job.json` | What to install: file names, services, service account name, syslog, install folder, FIPS mode, ports, proxy host, port, user and direct hosts, flags. No passwords. |
| `Run-Upgrade.cmd` | Lets you run the same job by hand on the connector |

When the folder is created it is locked so that only Administrators and SYSTEM can read or change it, because the scripts in it run with high privilege.

### On the connector

1. **Refuse if unsafe.** If the server's PowerShell module-logging policy would write command parameters (and so the passwords) to the event log, nothing is started.
2. **State before.** Installed version, each connector service and its state, the Java processes, keytab size, free disk space, pending reboot.
3. **Kerberos sign-in check.** For a tenant with Kerberos Auth, the helper tests whether the sign-in it is running under can query Active Directory. If it cannot, it refuses (`Blocked`) rather than leave the connector with an empty keytab. This is why the main script starts the helper as a scheduled task under a domain admin account for these connectors.
4. **Settings that cannot change.** On an installed connector, a job asking for a different FIPS mode than the one installed is refused, because FIPS mode cannot be changed after install. A different install folder only gives a warning.
5. **Keytab copy.** A usable keytab is copied to a private folder first, because the installer removes it.
6. **Install.** The wrapper runs its pre-flight checks. On a dry run it stops there. Otherwise it stops the connector services, runs the vendor installer silently (with `REBOOT=ReallySuppress`, so the server is never restarted by surprise) and starts the services.
7. **Vendor log cleaned.** The vendor installer records the passwords it was given in its own MSI log, base64-encoded. The helper replaces every such value with asterisks straight away.
8. **Kerberos certificate.** For Kerberos Auth with a `Pfx`: the helper looks at the certificate the service is actually serving. If it is not the PFX certificate (after an upgrade it never is; see Engineering Notes), it installs the PFX certificate with the vendor's own maintenance script and checks again.
9. **Optional patch.** When the job asks for it, the vendor `Java4shellPatch.bat` is run.
10. **Health check.** Up to four minutes are allowed for the services to come up. Then every item in the table below is checked.
11. **Result.** A result is written to `Logs\result.json` and returned to the main script.

### The health check

| Check | Fails the run when |
|---|---|
| Services | Any service named in `Services` is not running |
| Version | `ExpectVersionPrefix` is set and the installed version does not start with it |
| Java patch flag | The patch was applied and any connector Java process lacks the flag |
| Keytab | Kerberos Auth is installed and the keytab is missing or under 32 bytes (an empty keytab is 6 bytes; a usable one is a few hundred) |
| Certificate | Kerberos Auth with a `Pfx`: the service does not answer, or serves a certificate other than the PFX one |
| Reboot | The installer reports that a restart is required |

Any failure gives the status `Unhealthy` and a message naming each problem.

### The health gate

After each connector:

- `Success`: the run continues.
- Anything else on a real run: that tenant's remaining connectors are not started. By default nothing else is started either; `-ContinueOtherTenants` lets other tenants go on.
- A failed dry run: the same passwords would fail on the tenant's other connectors, so they are not tried.
- A domain admin account that could not start the task: the other connectors are not tried, so a wrong password is not repeated against Active Directory.
- A sign-in that a connector refuses over WinRM (a wrong user name or password, an account that is locked out, disabled or has an expired password, or, since 1.5.2, Negotiate's `0x8009030E`, `A specified logon session does not exist`, which it gives for an account that does not exist): that tenant's other connectors are not tried and, unless `-ContinueOtherTenants`, nothing else is started, in a dry run too. It is known before the next connector is started, so with `-Parallel` too the connectors not yet started are left alone. A connector WinRM cannot reach does not stop a dry run.

## Why Kerberos Auth connectors run under a scheduled task

The vendor's Kerberos set-up script (`setupKerberos.ps1`) creates or resets an Active Directory account and writes the keytab. It needs a full domain sign-in. An SSH key sign-in or a normal remoting session is a network sign-in: on the connector it has no credentials to present to a domain controller, so the script fails and leaves an empty keytab.

A scheduled task with a stored password is a full sign-in. So for Kerberos Auth tenants the helper:

1. writes the passwords for the task into a file protected with Windows machine-scope data protection, readable by Administrators and SYSTEM only;
2. registers a one-time task named `AccessConnectorUpgrade-RunAs` under the domain admin account;
3. starts it and relays its console output as it is written;
4. the task deletes the secrets file as soon as it has read it, and deletes itself (and with it the stored account password) when the work ends, even if your connection drops.

If the account name or password is wrong, the task fails to start and nothing is changed.

### A job scheduled on the connector (`-Schedule`)

After `-Mode Stage`, the helper's `-Prompt -Schedule "<time>"` registers a one-time task, `AccessConnectorUpgrade`, for a later time instead (Getting Started 14.8). Since 1.5.2 it works the same way at the console and in an SSH session signed in by key (`ssh -t`):

1. after the passwords for the job are typed, it checks the time (not passed on the server's clock) and that no task of that name is running, before it asks for the account and before anything is written;
2. it asks for the account the job runs as (or takes `-RunAsUser`) and refuses one the job cannot use: a built-in service account always, and for a job with Kerberos Auth any local account, since the keytab step needs a domain admin. The signed-in account is offered at Enter only when it would pass;
3. it asks that account's Windows password (unless `-RunAsPassword` is given), then checks the time and the running task again;
4. it encrypts the passwords for the job with machine-scope data protection, as the run-as task does, moves aside a `secrets.dat` left by an earlier `-Schedule` (whose task may still be pending), creates `secrets.dat` empty, limits it to Administrators and SYSTEM, and only then writes it;
5. it registers the task under that account with highest privileges, replacing an earlier `AccessConnectorUpgrade` task that has not run yet, with a trigger that expires 12 hours after the start time and is then deleted by Task Scheduler. Only then is the earlier `secrets.dat` deleted.

At the set time the job reads `secrets.dat`, deletes it, then decrypts the passwords, runs the upgrade with no standard input, and deletes the task (and with it the stored Windows password) when the run ends. A step that fails removes the `secrets.dat` it wrote, puts back the earlier one it moved aside (so an earlier task still pending runs as booked), and names the step. In 1.5.1 the task always ran as the signed-in account and the passwords were encrypted for that user, which a session signed in by key cannot do; a `secrets.dat` in that form is still read.

## How a certificate repair works

`-Mode RepairCertificate`, and the certificate step at the end of an upgrade, both do this on the connector:

1. Open the PFX with the password given. Refuse if it cannot be opened, is expired, or does not name this server (unless `-Reapply`).
2. Look at what the Kerberos Auth service serves now, by a TLS handshake to its own port. If it is already the PFX certificate, stop: nothing to do.
3. Copy the service's `conf` folder and service definition to `C:\ProgramData\AccessConnectorUpdate\CertBackup\change_<stamp>` and write a marker file, so an interrupted change can be detected later.
4. Stop the Kerberos Auth service only. The other services keep running.
5. Run the vendor's `Support\installKerberosAuthService.bat -updateConfiguration -sslCert <pfx> -sslCertPass <password>`. This is what the installer's own maintenance mode runs. The command is typed to a command prompt on standard input, so the password is on no command line.
6. Compare the configuration before and after. Any change outside the expected ones (the keystore, its encrypted password, the trust store, the key-pair file) is treated as a problem.
7. Start the service, wait for it to answer, and confirm by a second TLS handshake that the certificate now served is the one in the PFX, and that the health page answers.
8. If any step is not right, put the copied configuration back and start the service again.

## How a keytab repair works

`-Mode RepairKeytab` starts the helper as the scheduled task described above. It then:

1. leaves the connector alone if its keytab already holds keys;
2. copies any existing keytab to a private folder;
3. runs the unmodified vendor `setupKerberos.ps1` (this resets the password of the connector's Active Directory account and writes a new keytab);
4. judges the result by the vendor script's exit code and log, not by file size alone;
5. restarts the Kerberos Auth service.

## Building a fleet file from a spreadsheet

`-ImportFleet` runs entirely on the admin machine, under PowerShell 7. It reads the spreadsheet and the staging folder and writes the fleet file. It contacts no connector and asks for no password.

1. **Read.** An `.xlsx` workbook is opened as the zip archive it is and its first visible worksheet read from the XML inside, so Excel is not needed; hidden sheets in front of it are passed over and named. A CSV file is read with its encoding and delimiter worked out from the file itself.
2. **Convert.** Headers are matched to the known columns, and rows are grouped by `Group`. Each group's settings are taken from its rows (the first value counts; a different later value is a problem), and values are put in fleet-file form: services in their full names and fixed order, yes/no values as `$true`/`$false`, ports as numbers, paths with backslashes.
3. **Check.** The spreadsheet's own rules first (required columns and values, unknown or password-like columns, Excel error values, line breaks outside `Services`, duplicate hosts, versions), then the checks a run makes on a fleet file (known settings, ports, `EnableFips`, `InstallDir`, proxy settings). Files missing from the staging folder are warnings here, not problems, because they can be added before the first run; they are shown together as one note.
4. **Show.** The spreadsheet and how it was read (for a workbook, the sheet), the fleet file to be written as a full path and what chose it, then each group: its services, a line with its files and accounts, a line with its installer settings, and its connectors. Then the warnings and problems. When an existing file would be replaced, the warnings name its groups that the spreadsheet does not hold, and the settings of kept groups that the spreadsheet leaves blank. Any problem stops here with nothing written; so does `-DryRun`.
5. **Write.** An existing fleet file that holds groups is replaced only after `YES` (or `-Yes`); one that holds none, such as the file a partial Discover starts, is replaced without asking. Either way it is first copied to `<file>.bak-<yyyyMMdd_HHmmss>` (with `-1`, `-2` added when that name is taken, so no copy is overwritten). The new file carries over the old file's top-level settings. It is written under a temporary name beside the target and then moved into place.
6. **Read back.** The new file is read as a run would read it and compared with what the spreadsheet said. A difference is an error; when a file was replaced, the previous one is put back from its copy.
7. **Next.** The next commands are shown, naming the file written when a run would not pick it by itself.

## Discovering existing connectors

`-Mode Discover` reads connectors that are already installed and turns what it finds into rows for `-ImportFleet`.

| Step | Runs on | What happens |
|---|---|---|
| 1 | Admin machine | The connectors are taken from `-Connector` (then `-Tenant` has no effect, and each host that is in the fleet file is still matched with its entry), or from the fleet file in use, limited by `-Tenant`. The output file is checked before any connector is read: the file must not exist, and its folder is made when it does not. A folder named with `-ExportCsv` gets the dated file name in it. |
| 2 | Each connector, in turn | One short read-only script is sent over SSH on standard input to `powershell -NoProfile -NonInteractive -Command -`, so it runs under Windows PowerShell 5.1. Unlike `-Mode Verify`, which copies the helper script to the connector first, Discover copies nothing and creates nothing there: no staging folder, no file, no task. The script sends back only the settings on its allow-list (Security, and the Fleet File Reference); in `install.properties`, which also holds secrets, it checks each line's name before it keeps anything. Each item has its own error handler, so a missing item gives an empty value and a short reason rather than a failure. It returns a single line of JSON. |
| 3 | Admin machine | Each answer is turned into a row. The installer, configuration file, PFX and trusted certificates are matched against the file names in the staging folder (`Installers`, `Configs`, `ChildCerts`, `TrustedCerts`); no file there is opened. For a connector listed in the fleet file, what could not be matched is taken from its entry, and the entry is compared with what was found. Connectors of one group whose settings differ (other than in upper and lower case) are split into groups of their own: the rows closest to the fleet entry keep its name, and the others get `-2`, `-3` and so on. The rows stay in their order. |
| 4 | Admin machine | The rows are written to a new CSV file, with notes on what was found and what is left to fill in. When every connector of the fleet file was read, the next commands shown import the draft into that fleet file, named as `-Fleet <name>` when `-Fleet` was used, else by its full path. A connector that could not be reached still counts as read. When `-Tenant` or `-Connector` left some of its connectors out, importing into the original would drop their groups, so Discover writes a new `fleet.discovered_<date>_<time>.psd1` beside it, holding the original's top-level settings and no groups, and the next commands import into that file instead. A warning says how many connectors were left out and names the new file. |

The connector does not record which es-config file or PFX it was installed with (see Engineering Notes), so those two are matched by name: the configuration file by the tenant's host name (or, failing that, its first name part, with a note to check it), the PFX by the certificate the Kerberos Auth service serves.

A connector that cannot be reached is listed on screen and still gets a row, with an empty `Group` and the reason in `Notes`.

## Files left on a connector

| Path | Contents |
|---|---|
| `C:\ProgramData\AccessConnectorUpdate\` | The staged payload, `job.json`, `Run-Upgrade.cmd` |
| `...\Logs\` | Audit log, error log, wrapper audit log, vendor MSI log (cleaned), `result.json`, task console logs |
| `...\KeytabBackup\` | Copies of keytabs taken before an install or repair |
| `...\CertBackup\change_<stamp>\` | Copy of the Kerberos Auth configuration taken before each certificate change |

The folder is readable by Administrators and SYSTEM only. Nothing in it is removed automatically.

`-Mode Discover` writes nothing on a connector. (Windows still records the SSH sign-in, as it does any other.)

## The set-up scripts in Prerequisites

`Install-OpenSSHServer.ps1` works in this order: install, host keys, start sshd, keys, firewall, `sshd_config`, default shell, login alert, restart, host key fingerprint. Before the first step it loads the modules it uses with `-WhatIf` and `-Confirm` off for the load only (since 1.0.1), so that loading them prints nothing under `-WhatIf`. Since 1.0.1, on a first install with `-AllowFrom`, the install step itself limits the install's firewall rule `OpenSSH-Server-In-TCP` (or disables it, or stops the run) before sshd first starts; the firewall step later checks every OpenSSH rule as before.

`Install-PowerShell7.ps1` takes the newest stable release from GitHub. When that release has no MSI for the processor, it asks the GitHub releases API for up to three pages of ten releases and picks the newest stable one that has an MSI. Since 1.0.1 it hands that choice a plain array: under Windows PowerShell 5.1, `@()` around the generic list of `ConvertFrom-Json` objects it collects throws `Argument types do not match`.
