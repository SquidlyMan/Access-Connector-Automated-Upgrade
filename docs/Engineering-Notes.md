# Engineering Notes

What was learned about the Omnissa Access Connector installer and its Kerberos pieces while building this tool, and why the tool does what it does. Each note says how it was established. Observations come from connector 26.05 and 26.10 unless stated; other versions may differ.

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

**What the tool does:** immediately after every install the helper replaces those values with asterisks in the logs on the connector, keeping each file's encoding and timestamp. The main script cleans the copies it brings back as well, and discards a copy it cannot check. Logs left by earlier manual installs are cleaned when the helper next runs.

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

## Running things on a connector remotely

- **Long scripts cannot be sent with `-EncodedCommand`.** The Windows command line limit (8191 characters under cmd.exe) is reached quickly. Short commands use `-EncodedCommand`; anything longer is copied as a file and run with `-File`, or piped to `powershell -Command -` on standard input.
- **Scripts fed on standard input run statement by statement,** as if typed. End the input with blank lines so the last block is executed.
- **A PowerShell 5.1 child started from a PowerShell 7 window inherits PowerShell 7's module path** and then fails to load built-in modules. `Run-Upgrade.cmd` clears `PSModulePath` first.
- **`pwsh -File` passes `"A,B"` as one string.** The main script splits comma lists itself.
- **Connector-side scripts are ASCII-only.** Windows PowerShell 5.1 reads a file without a byte-order mark in the system code page, so a single non-ASCII character can break parsing.
- **Remote output arrives with CLIXML progress records mixed in.** Lines beginning `#< CLIXML` or `<Objs ` are dropped.

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

- A dry run really copies files and really runs the pre-flight checks on the connector. It is the right way to prove passwords before a change window.
- `-Mode Verify` copies the helper script to the connector. It is not purely read-only, so do not run it against a connector while another run is using the helper there.
- For exercising the scheduled-task plumbing without a domain account, setting the environment variable `AC_UPGRADE_RUNAS_SYSTEM` makes a **dry run** use the SYSTEM account for the task. It is a test aid and is refused for real runs.
