# How It Works

## The three scripts

| Script | Runs on | Runs under | Job |
|---|---|---|---|
| `FleetDeploy/Invoke-AccessConnectorUpgrade.ps1` | Your admin machine | PowerShell 7 | Reads the fleet file, asks for passwords, copies files to each connector, starts the helper, enforces the one-at-a-time order and the health gate, writes the summary |
| `FleetDeploy/Invoke-ConnectorUpgradeLocal.ps1` | Each connector | Windows PowerShell 5.1, elevated | Records the state before, runs the wrapper, restores the Kerberos certificate, runs the optional patch, checks health, cleans the vendor log, returns a result |
| `Silent Install/Install-AccessConnector.ps1` | Each connector | Windows PowerShell 5.1 | Pre-flight checks, stops the services, runs the vendor installer silently, starts the services, checks the Kerberos keytab, writes an audit log |

The split exists because the connector side must work with what Windows Server already has (PowerShell 5.1), while the admin side can run anywhere PowerShell 7 does.

## What happens in a run

### On the admin machine

1. The fleet file is chosen and read. Tenants and connectors are filtered by `-Tenant` and `-Connector`.
2. Every file the run needs is checked under the staging folder. A missing file stops the run before any connector is contacted.
3. The plan is printed: fleet file, order, installer, and each connector.
4. Unless `-DryRun` or `-Yes`, you type `YES` to continue.
5. Passwords are asked once per tenant at hidden prompts.
6. For each connector in turn: copy the payload, start the helper, relay its output, collect its result.
7. After each connector the health gate decides whether the run goes on.
8. A summary, a CSV and (SSH modes) the connector's logs are written to the central log folder.

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
| `job.json` | What to install: file names, services, service account name, syslog, flags. No passwords. |
| `Run-Upgrade.cmd` | Lets you run the same job by hand on the connector |

When the folder is created it is locked so that only Administrators and SYSTEM can read or change it, because the scripts in it run with high privilege.

### On the connector

1. **Refuse if unsafe.** If the server's PowerShell module-logging policy would write command parameters (and so the passwords) to the event log, nothing is started.
2. **State before.** Installed version, each connector service and its state, the Java processes, keytab size, free disk space, pending reboot.
3. **Kerberos sign-in check.** For a tenant with Kerberos Auth, the helper tests whether the sign-in it is running under can query Active Directory. If it cannot, it refuses (`Blocked`) rather than leave the connector with an empty keytab. This is why the main script starts the helper as a scheduled task under a domain admin account for these connectors.
4. **Keytab copy.** A usable keytab is copied to a private folder first, because the installer removes it.
5. **Install.** The wrapper runs its pre-flight checks. On a dry run it stops there. Otherwise it stops the connector services, runs the vendor installer silently (with `REBOOT=ReallySuppress`, so the server is never restarted by surprise) and starts the services.
6. **Vendor log cleaned.** The vendor installer records the passwords it was given in its own MSI log, base64-encoded. The helper replaces every such value with asterisks straight away.
7. **Kerberos certificate.** For Kerberos Auth with a `Pfx`: the helper looks at the certificate the service is actually serving. If it is not the PFX certificate (after an upgrade it never is; see Engineering Notes), it installs the PFX certificate with the vendor's own maintenance script and checks again.
8. **Optional patch.** When the job asks for it, the vendor `Java4shellPatch.bat` is run.
9. **Health check.** Up to four minutes are allowed for the services to come up. Then every item in the table below is checked.
10. **Result.** A result is written to `Logs\result.json` and returned to the main script.

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

## Why Kerberos Auth connectors run under a scheduled task

The vendor's Kerberos set-up script (`setupKerberos.ps1`) creates or resets an Active Directory account and writes the keytab. It needs a full domain sign-in. An SSH key sign-in or a normal remoting session is a network sign-in: on the connector it has no credentials to present to a domain controller, so the script fails and leaves an empty keytab.

A scheduled task with a stored password is a full sign-in. So for Kerberos Auth tenants the helper:

1. writes the passwords for the task into a file protected with Windows machine-scope data protection, readable by Administrators and SYSTEM only;
2. registers a one-time task named `AccessConnectorUpgrade-RunAs` under the domain admin account;
3. starts it and relays its console output as it is written;
4. the task deletes the secrets file as soon as it has read it, and deletes itself (and with it the stored account password) when the work ends, even if your connection drops.

If the account name or password is wrong, the task fails to start and nothing is changed.

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

## Files left on a connector

| Path | Contents |
|---|---|
| `C:\ProgramData\AccessConnectorUpdate\` | The staged payload, `job.json`, `Run-Upgrade.cmd` |
| `...\Logs\` | Audit log, error log, wrapper audit log, vendor MSI log (cleaned), `result.json`, task console logs |
| `...\KeytabBackup\` | Copies of keytabs taken before an install or repair |
| `...\CertBackup\change_<stamp>\` | Copy of the Kerberos Auth configuration taken before each certificate change |

The folder is readable by Administrators and SYSTEM only. Nothing in it is removed automatically.
