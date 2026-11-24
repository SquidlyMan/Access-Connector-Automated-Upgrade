# Engineering Notes

What was learned about the Omnissa Access Connector installer and its Kerberos pieces while building this tool, and why the tool does what it does. Each note says how it was established. Observations come from connector 26.05 and 26.10 unless stated; other versions may differ. The notes on Excel near the end are known Excel behaviour rather than observations of the connector.

## The vendor installer

### An upgrade drops the Kerberos PFX certificate

**Observed** in the MSI verbose log of every upgrade of a connector with Kerberos Auth, and confirmed by reading the certificate served afterwards.

On a silent upgrade the installer's `AWResetCheckBoxProperty` step runs. Its condition is `(Installed OR IS_MAJOR_UPGRADE="Yes") AND (REMOVE<>"ALL" AND UILevel<>5)`. It deletes the `WS1_ADD_SSL_CERT` property (the log line is "Deleting WS1_ADD_SSL_CERT property"), so the PFX passed on the command line is ignored and the installer generates a self-signed certificate whose issuer is "Internal Root CA <timestamp>". On a fresh install the PFX is used.

Omnissa's documentation says to upload certificates again during or after an upgrade; the only documented method after installation is the installer's Add/Remove Services wizard.

**What the tool does:** after every upgrade of a Kerberos Auth connector with a `Pfx`, it reads the certificate actually served and, if it is not the PFX certificate, installs it with the vendor's own maintenance script (next note). `-Mode RepairCertificate` does the same on demand.

### The certificate can be replaced without the wizard

**Established** by reading the vendor scripts and proven by runs on six connectors.

`<install folder>\Support\installKerberosAuthService.bat -updateConfiguration -sslCert <pfx> -sslCertPass <password>` is what the wizard's maintenance mode runs. It calls `install-common.bat`, which deletes the keystore, sets a new keystore password, imports the PFX with a Java command that reads the password from the environment variable `SSL_CERT_PASS`, and deletes `eks.keypair.v1.json`.

Things to know:

- **The exit code is not a verdict.** The script's last step is `KerberosAuthService.exe install`, which fails because the service already exists, so the script ends with exit code -1 after a successful import. The real failure text is `Failed to install the Kerberos Auth Service`. The tool judges by that text, by a timeout, and by reading the served certificate afterwards.
- **`%`, `^` and `"` in the password or path are altered** by the batch files. The tool refuses such values.
- **`eks.keypair.v1.json` changing is normal.** The Kerberos Auth service registers its key pair with the tenant and registers again by itself when the file does not match.
- The script touches only the keystore, its encrypted password in `application.properties`, the trust store and the key-pair file. The keytab, `master.key`, `proxy.json`, the service definition and the service account are untouched. The tool checks this each time and puts the configuration back if anything else changed.

### The installer records passwords in its own log

**Observed.** The verbose MSI log (`AccessConnector_MSI_*.log`) has lines of the form `Adding AW... property. Its value is '...'` that carry the configuration, PFX and service account passwords base64-encoded, repeated about twenty times. Passwords also sit on the installer's command line while it runs (a documented limitation of the silent install).

**What the tool does:** immediately after every install the helper replaces those values with asterisks in the logs on the connector, keeping each file's encoding and timestamp. The main script cleans the copies it brings back as well, and discards a copy it cannot check. Logs that earlier manual installs left in the helper's own `Logs` folder are cleaned when the helper next runs; an installer log kept anywhere else is not, so find and delete it.

When reading an uncleaned MSI log, never print those lines.

### A silent feature removal does not work

**Proven the hard way** on one test connector.

`msiexec /i {product code} REMOVE=KerberosAuthService /qn` returns 1603. Run this way, the installer's `AWImportSetupConfiguration` step fails ("Could not resolve source") and blanks settings saved at install time: `JAVA_HOME` and `SYSLOG_CONFIGURATIONS` in `Support\scripts\install.properties`, and `IS_NET_API_LOGON_USERNAME` and `WS1_SYSLOG_HOSTNAME` under `HKLM\SOFTWARE\Omnissa\Access Connector`. A later step then fails on the empty user name and the rollback is incomplete: the Kerberos Windows service was unregistered while Windows Installer still listed the feature as installed.

The values were restored from a copy taken beforehand, and the connector was then put right with a forced reinstall.

**What the tool does:** it never modifies features in place. To change the services on an installed connector, change `Services` and use `-ForceReinstall`, which runs `msiexec /x {product code} /qn` and then a fresh install. This path is proven.

### A same-version run is a no-op

**From the wrapper's design notes and observed.** The installer has no supported silent reconfigure. Running the same version again does nothing, and forcing `REINSTALL` deletes and recreates the services and leaves them stopped. So the wrapper skips a connector already on the installer's version unless `-ForceReinstall` is given, in which case it uninstalls and installs fresh.

### Custom actions run as SYSTEM from another folder

**From the wrapper's design notes.** MSI custom actions run as SYSTEM from `C:\Windows\Installer`, so a relative path to the configuration file or trust store silently fails. The wrapper turns every path into an absolute one first.

### The installer may ask for a reboot

The helper passes `REBOOT=ReallySuppress` so a silent install never restarts the server by itself. Exit codes 3010 and 1641 are reported as "restart required".

## Kerberos keytab

### A remote sign-in leaves an empty keytab

**Observed** on four connectors upgraded over SSH with a local administrator key before the scheduled-task route existed.

The installer removes the keytab and runs the vendor `Support\scripts\setupKerberos.ps1` to make a new one. That script's first step blanks `krb5.keytab` (leaving a 6-byte file), then it uses the Active Directory module and `ktpass` to create or reset a user account named after the computer and write the keytab, retrying thirty times at five-second intervals. From a network sign-in it cannot contact a domain controller ("Unable to contact the server", "Kerberos setup failed with code 1"), and the 6-byte file stays.

A check of "the file exists and is not empty" passes on that 6-byte file. A usable keytab is a few hundred bytes (334 to 346 bytes in testing).

**What the tool does:** treats a keytab under 32 bytes as missing; refuses to upgrade a Kerberos Auth connector from a sign-in that cannot query Active Directory; runs the work as a scheduled task under a domain admin account; keeps a copy of a usable keytab first; offers `-Mode RepairKeytab`.

### What the vendor Kerberos set-up does in Active Directory

**Observed** in Active Directory after runs.

- It creates a **user** account named after the connector (in `CN=Users`) if none exists, and resets its password.
- It registers `HTTP/<name>` and `HTTP/<fully qualified name>` service principal names on that user.
- It appends to `conf\krb5-setup.log`, one block per run ending with `RESULT: exit code <n>`. A check must look only at what the current run added (both the helper and, since 1.4.0, the wrapper note the log's length before and read from there); an old `Password set failed` stays in the file for good.
- It must run under Windows PowerShell 5.1; it fails under PowerShell 7.

Consequence: if Kerberos Auth is later removed from a connector, that user account and its service principal names remain. Disable the account.

### Console health does not prove the keytab

**Observed.** The Access console showed Kerberos Auth as active and green on connectors whose keytab was 6 bytes. `/eks/health` and the console tell you the service is up, not that Kerberos sign-in will work.

### When the installer runs under a domain admin, it writes the keytab itself

**Observed** on connectors upgraded by a domain admin at the console, and through the scheduled-task route: the keytab was a usable size straight after the install.

## Certificates and health

### Reading the served certificate under Windows PowerShell 5.1

The usual trick of capturing the certificate in a `ServerCertificateValidationCallback` does not work on .NET Framework: the certificate object is reset once the callback returns, so its thumbprint reads as empty and a comparison silently never fires. The wrapper's served-certificate check had this weakness until 1.4.0. Both the helper and (since 1.4.0) the wrapper open a TCP connection, run a TLS 1.2 handshake with `SslStream`, and hash the raw certificate bytes.

With the check working, the wrapper sees the self-signed certificate after every upgrade of a Kerberos Auth connector (previous section). That is reported as a warning after an upgrade and an error after a fresh install, so the wrapper's exit code does not turn every upgrade into a failure.

### Health pages

Each service answers on localhost with the text `true` when healthy:

| Service | URL |
|---|---|
| Directory Sync | `https://localhost:8080/eds/health/` |
| User Auth | `https://localhost:8090/eas/health/` |
| Virtual App | `https://localhost:8008/eis/health/` |
| Kerberos Auth | `https://localhost:443/eks/health/` |

The Kerberos Auth port is read from the service's configuration rather than assumed.

### Kerberos redirects go to the connector's own name

**Observed** in a browser. During a Kerberos sign-in the browser is sent to `https://<connector name>/eks/v4/authenticate`. So the certificate must name each connector itself, not only a load-balancer name, and a load balancer in front of Kerberos Auth should pass TLS through rather than end it.

## Settings the installer saves

**Observed** on a 26.10 connector. `<install folder>\Support\scripts\install.properties` holds the settings given at install time, one `NAME=value` per line, including `INSTALL_DIR` (for example `C:\Program Files\Access Connector\`), the four `*_SVC_PORT` values, `PROXY_HOST`, `PROXY_PORT`, `PROXY_USER`, `NON_PROXY_HOSTS`, `SYSLOG_CONFIGURATIONS` and `FIPS_ENABLED` (`true` or `false`). **It also holds client secrets and the PFX password (`*_CLIENT_SECRET`, `SSL_CERT_PASS`)**: read it by line name, never print it whole. The uninstall registry entry's `InstallLocation` is the folder above, for example `C:\Program Files\`.

The helper reads `FIPS_ENABLED` to refuse a change of FIPS mode on an installed connector, and `PROXY_USER` to refuse a certificate repair.

### What a connector records, and what it does not

**Observed** on a real 26.10 connector, reading names and non-secret values only.

`ES_CONFIG_FILE` and `SSL_CERT` in `install.properties` are **empty** after an install. A connector does not record which es-config file or which PFX it was installed with. So `-Mode Discover` matches them by name instead: the PFX by the certificate the Kerberos Auth service serves (a `.pfx` in `ChildCerts` named after the certificate's subject or one of its DNS names), and the configuration file by the tenant's host name in the file name (or, when no file has the full host name, by the tenant's first name part, with a note to check it). It never opens either file. Both matches have since worked on real staging folders (next section).

Other values seen:

| Where | Name | What it held |
|---|---|---|
| `install.properties` | `TENANT_URL` | The tenant address, for example `https://TENANT1.us1.example.com`, in the case it was typed |
| `install.properties` | `TRUST_CERTS` | A comma-separated list of full paths to the certificate files given at install time, under `C:\ProgramData\AccessConnectorUpdate\TrustedCerts\` (where this tool stages them) |
| `install.properties` | `SYSLOG_CONFIGURATIONS` | `host:port` |
| `install.properties` | `INSTALL_DIR` | `C:\Program Files\Access Connector\` |
| `HKLM\SOFTWARE\Omnissa\Access Connector` | `WS1_SYSLOG_HOSTNAME` | `host:port` |
| `HKLM\SOFTWARE\Omnissa\Access Connector` | `IS_NET_API_LOGON_USERNAME` | The service account name, in the case it was typed at install time (on one connector in lower case, unlike the others) |
| `HKLM\SOFTWARE\Omnissa\Access Connector` | `InstallDir` | `C:\Program Files\`, the folder above the connector's own |
| `HKLM\SOFTWARE\Omnissa\Access Connector` | `WS1_INSTALLED_SERVICES` | Present; Discover reads it with the others |

The Kerberos Auth and Virtual App services run as the service account (`DOMAIN\name`); Directory Sync and User Auth run as `NT AUTHORITY\LocalService`.

Discover reads the registry values by name only: it never lists the key's values and never reads one whose name contains `PASS`. It reads `install.properties` line by line and checks each line's name before it keeps anything, so the client secrets and `SSL_CERT_PASS` in the same file are never kept, compared or sent back.

The values are kept as they were given at install time, typing mistakes included: on one test connector the syslog host name had been mistyped when it was installed, and the registry and `install.properties` still held the mistyped name.

### Discovery on real connectors

**Observed** on 2026-11-23, with the final 1.5.0 build (orchestrator SHA-256 beginning `e6f62f331d1b`), when `-Mode Discover` was run read-only against ten 26.10.0.0 connectors in two forests (four tenants) over SSH from a macOS admin machine, from a scratch copy of the tool.

- **The read script runs under Windows PowerShell 5.1 from standard input.** The SSH command is `powershell -NoProfile -NonInteractive -Command -` and the script is written to its standard input, so nothing is copied to the connector. On these connectors, whose SSH default shell is PowerShell 7, it ran under Windows PowerShell 5.1 and returned its one line of JSON every time. The script is one `& { ... }` block with no blank line inside it, followed by blank lines, because input on standard input runs as if typed and a blank line ends a block.
- **Every row was complete.** Both drafts ended `0 need values filled in`.
- **The es-config file is found by the tenant's name.** Configuration files were matched by the tenant's full host name in the file name and, for one tenant, by its first name part, with the `check it` note.
- **The PFX is found by the served certificate.** On the Kerberos Auth connectors, the certificate the service served named a `.pfx` in the `ChildCerts` of the staging folder used, so `Pfx` was filled without opening any PFX. Each forest's staging folder holds only its own PFX, so from one forest's staging folder the other forest's PFX was taken from the connector's fleet entry and noted.
- **The service account and the syslog target** were read from the connectors.
- **The installer and the trust folder come from the fleet entry.** The staging folders used hold more than one installer, so `Installer` and `InstallerVersion` were taken from each connector's fleet entry and noted (`taken from fleet entry`). `TrustStore` was taken from the fleet entries too: an entry's own `TrustStore` wins over the generic `TrustedCerts` match, which has run in offline tests only. For a connector that is not in a fleet file, the installer columns are left for you to fill in.
- **Imported back,** with `-ImportFleet` into scratch copies of the two hand-written fleet files, every connector had the same settings as those files: installer, installer version, configuration file, PFX, trust folder, services, service account, syslog target, ports, proxy, install folder and FIPS mode. There were two exceptions. `ExpectVersionPrefix` was blank, because discovery leaves it blank by design; the import's dry run named it for every group (`the current fleet file sets ExpectVersionPrefix, which the spreadsheet leaves blank`). And one connector's syslog host name had been mistyped on that connector at its original installation (above): a real difference, noted `differs from fleet entry ...: Syslog`. That connector was drafted as `<entry>-2`, and the other connector of the entry, installed correctly, kept the entry's name, because the row closest to its fleet entry keeps the name.
- **A partial read starts its own fleet file.** With `-Tenant` naming one group of a fleet file that has two, the warning said `Only part of <file> was read (2 of its connectors left out)`, and Discover wrote a new fleet file beside it holding the original's top-level settings (`JavaPatchDir`, `StagingRoot`) and no groups. The import the run showed went into that file without `-Yes`, because a file with no groups has nothing to lose (its copy was still made), and wrote the group with those settings kept.

## Excel and CSV files

**Known Excel behaviour**, which the spreadsheet import (`-ImportFleet`) and `-Mode Discover` were built around. It has not been tried with every Excel version or regional setting.

- **`26.10` becomes `26.1`.** A version typed into a cell formatted as General or Number is stored as a number, and the trailing zero is lost. The same happens to a CSV file each time Excel opens it, quotes or not. So the template's `Fleet` sheet is formatted as Text, the import compares `ExpectVersionPrefix` with `InstallerVersion` and warns about a lone prefix like `26.1`, and Discover leaves `ExpectVersionPrefix` blank and writes `InstallerVersion` with four parts (`26.10.0.0`, which is not a number to Excel), also when it takes the version from a fleet entry that gives it as `26.10`.
- **Semicolons.** Excel separates the fields of a CSV file with the list separator of the regional settings. Where the comma is the decimal separator, that is `;`. The import takes the delimiter from the header line (tab, else the more frequent of `;` and `,`). The other way round, Excel with `;` as its list separator does not split a comma-separated file when it opens it: each row lands in one cell. Data > From Text/CSV, with the comma chosen as the delimiter, opens Discover's draft in columns.
- **The byte-order mark.** Excel reads a CSV file as UTF-8 only when it starts with a UTF-8 byte-order mark; without one it uses the computer's code page. Its "CSV UTF-8" format writes the mark; its plain "CSV" format writes the code page (Windows-1252 in Western settings). So Discover writes its CSV file with the mark, and the import reads a file without one as UTF-8 when it is valid UTF-8, else as Windows-1252.
- **The `="..."` trick.** A field written as `="26.10"` is a formula whose result is the text `26.10`, a known way of making Excel keep a value as typed when it opens a CSV file. The import reads a cell holding it as `26.10`. In an `.xlsx` file a formula cell carries its last result, which is what the import reads.
- **The first sheet.** An `.xlsx` file is a zip archive of XML parts. The first worksheet is the first one listed in `xl/workbook.xml`, which is not necessarily the part named `sheet1.xml`, so the import follows the workbook's own order. A sheet can be hidden (`state="hidden"` or `"veryHidden"` in that list) and still be first; the import passes over hidden sheets and names them. Text is usually held in a shared string table, sometimes as formatted runs; numbers are written with a dot whatever the regional settings.
- **Error values.** A formula that fails shows an error such as `#N/A` or `#REF!`. In an `.xlsx` file that is an error cell (`t="e"`); saved as CSV it becomes the error's text. The import treats both as a problem rather than as a value.
- **Line breaks in a cell.** Alt+Enter puts a line break inside a cell, which a CSV file carries inside a quoted field. The import accepts it in `Services` (one service per line) and refuses it elsewhere.
- **Merged cells.** In a merged range only the top-left cell holds the value. The import gives the value of a cell merged down one column to each row of the merge.

What has been read so far: workbooks made by LibreOffice and by the template builder, a workbook saved by Microsoft Excel for Mac (16.115.1), and CSV files written by the tool and by hand. In that Excel the template opened with no repair prompt, and its `Fleet` sheet kept the Text format: `26.10` typed into an empty `ExpectVersionPrefix` cell stayed `26.10`. The copy Excel saved as a new workbook imported with exactly the same plan as the template. A CSV file saved by Excel, and Excel for Windows, are not yet recorded (Validation Record).

## Running things on a connector remotely

- **Long scripts cannot be sent with `-EncodedCommand`.** The Windows command line limit (8191 characters under cmd.exe) is reached quickly. Short commands use `-EncodedCommand`; anything longer is copied as a file and run with `-File`, or piped to `powershell -Command -` on standard input.
- **Scripts fed on standard input run statement by statement,** as if typed. End the input with blank lines so the last block is executed.
- **A PowerShell 5.1 child started from a PowerShell 7 window inherits PowerShell 7's module path** and then fails to load built-in modules. `Run-Upgrade.cmd` clears `PSModulePath` first.
- **`pwsh -File` passes `"A,B"` as one string.** The main script splits comma lists itself.
- **Connector-side scripts are ASCII-only.** Windows PowerShell 5.1 reads a file without a byte-order mark in the system code page, so a single non-ASCII character can break parsing.
- **Remote output arrives with CLIXML progress records mixed in.** Lines beginning `#< CLIXML` or `<Objs ` are dropped.
- **ssh's exit code tells a failed sign-in from a failed script.** ssh exits with 255 when it could not connect or sign in (its manual page says so), and otherwise with the exit code of the remote command. Its own reason comes on standard error, apart from the script's output; with `-o LogLevel=ERROR` it still prints `Permission denied (publickey).`, `Host key verification failed.`, `Could not resolve hostname ...`, `Connection refused` and the like. Until 1.5.1 the first SSH step threw that text away, so a key that was not offered and a server that was down gave the same message. Since 1.5.1 it is read, shown and turned into a hint.
- **Errors of a script sent with `-EncodedCommand` come back as CLIXML on standard error**: a `#< CLIXML` line, then an `<Objs ...>` line with one `<S S="Error">` element per line of the error message and its position lines. Seen here from PowerShell 7 (line ends written `_x000A_`, colour codes `_x001B_`). Windows PowerShell 5.1 is expected to write the same records with `_x000D__x000A_` line ends, but that has not yet been seen from a connector. Since 1.5.1 the tool decodes them for its messages and leaves out the position lines (`At line:1 char:...`, `+ ...`).
- **A cmdlet error does not stop such a script.** `New-Item` failing (access denied, say) is a non-terminating error: the script goes on and its last line still runs. The folder step used to end with `'ok'` regardless, so a folder that could not be made passed unnoticed until the copy into it failed. Since 1.5.1 it answers `ok` only when its folders are there.

## Setting up OpenSSH Server and PowerShell 7 on Windows

Learned in the lab while SSH and PowerShell 7 were set up on the test servers with the earlier scripts that `Prerequisites` is rewritten from:

- **An SSH session whose default shell is pwsh cannot upgrade PowerShell 7.** The upgrade stops `pwsh.exe`, which ends the session and can stop the install half-way. The tool is not affected, because it starts Windows PowerShell by name. `Install-PowerShell7.ps1` refuses to install over SSH, and `Install-OpenSSHServer.ps1` leaves the default shell alone unless it is asked to change it.
- **`Add-WindowsCapability` for OpenSSH Server can take over an hour on Windows 10 and 11.** On servers it is quick. A restart while it runs stops the install.
- **An endpoint-protection firewall can drop TCP 22 without a trace.** Ping still answers and Windows Firewall lets the port in, but ssh times out. The fix is an inbound rule in that product for `C:\Windows\System32\OpenSSH\sshd.exe`.
- **Host keys made by hand can stop sshd.** `ssh-keygen -A` in a window that is not elevated fails without a message. In an elevated window it works, but the key files can then carry an explicit entry for the admin account that `icacls /inheritance:r` does not remove. sshd refuses such keys and stops; only `sshd -T` or `sshd.exe -ddd` says why (`no hostkeys available`), and the event logs stay empty. The fix: owner SYSTEM, that entry removed, then `/inheritance:r` with full control for SYSTEM and Administrators only, and a restart of sshd (Troubleshooting has the commands). `Install-OpenSSHServer.ps1` makes this repair itself.
- **A Group Policy startup script runs only while a computer starts.** After a deployment by Group Policy nothing happens until each computer restarts, and `gpresult /r /scope computer` on it shows whether the GPO applied. The earlier deployer also met a GPO whose computer version was 0: computers show it as Not Applied (Empty) and skip it without a warning. `Deploy-OpenSSH-GPO.ps1` links its GPO only after it has checked that version.

## PowerShell pitfalls met while writing the tool

- Variable names are not case-sensitive: `$l` and `$L` are the same variable.
- `h` is an alias (`Get-History`); a function with that name is shadowed.
- `$args` is automatic; do not use it as a parameter name.
- `Select-Object -Unique` cannot compare hashtables.
- A regular expression `\s*` can run across a line break; use `[ \t]*` when matching within a line.
- In zsh, an unquoted `$var` holding several options is passed as one word. Use arrays.

## Two staging folders, two layouts

In the test environment two unrelated domains each had their own copy of the staging folder at a different path. Running a tenant from the wrong copy produced a "files missing" error that did not say where the files were. The `StagingFolders` fleet setting and the "another copy of this folder has them" message came from that.

## Dry runs and tests

- A dry run really copies files and really runs the pre-flight checks on the connector. It is the right way to prove passwords before a change window. Until 1.4.1 it did not, on a connector already on the installer's version: the wrapper's same-version skip came before its checks, so `DryRunPassed` there proved nothing about the passwords. Since 1.4.1 the checks run first and the skip is reported as a note.
- `-Mode Verify` copies the helper script to the connector. It is not purely read-only, so do not run it against a connector while another run is using the helper there. `-Mode Discover` copies nothing: its read script goes over SSH on standard input and nothing is written on the connector.
- For exercising the scheduled-task plumbing without a domain account, setting the environment variable `AC_UPGRADE_RUNAS_SYSTEM` makes a **dry run** use the SYSTEM account for the task. It is a test aid and is refused for real runs.
