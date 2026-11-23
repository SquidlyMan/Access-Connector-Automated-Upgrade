# Security

How the tool handles passwords, keys and files, and what you should do yourself.

## What is never stored

- No password is written to the fleet file, to `job.json`, to a spreadsheet the tool writes, to any log of this tool, or to a command line of this tool.
- Passwords are asked at hidden prompts each time you run it. There is no saved-password option.
- The repository's `.gitignore` keeps installers, tenant configuration files, PFX files, site fleet files, site spreadsheets in `FleetDeploy` and logs out of version control. Of the spreadsheets, only the two templates (`fleet.example.xlsx`, `fleet.example.csv`) are tracked.

## The path a password takes

| Step | Where the password is | Protection |
|---|---|---|
| You type it | Admin machine memory | Hidden prompt; held as a SecureString; registered for masking so it is replaced by asterisks in anything printed or logged |
| SSH mode: sent to the connector | Standard input of the remote process, inside the encrypted SSH session | Not on any command line; not in shell history |
| WinRM mode: sent to the connector | A SecureString parameter inside the remoting session | Encrypted by the remoting protocol |
| Kerberos Auth connectors: handed to the scheduled task | A file in the locked staging folder, encrypted with Windows machine-scope data protection (DPAPI) | Readable by Administrators and SYSTEM only; deleted by the task as soon as it is read, and again by the parent process afterwards |
| The domain admin account password for the task | Held by Windows Task Scheduler | Only while the task exists. The task deletes itself when the work ends. |
| `-Schedule` on the helper (Stage mode): the passwords, and the Windows password of the account that schedules | The passwords in `secrets.dat` in the locked staging folder, encrypted for that account (DPAPI); the Windows password held by Task Scheduler with the task `AccessConnectorUpgrade` | The job deletes `secrets.dat` when it reads it. The task does **not** delete itself: remove it once it has run (`Unregister-ScheduledTask -TaskName AccessConnectorUpgrade -Confirm:$false`), and if the job never runs, delete `secrets.dat` too |
| Given to the vendor installer | The vendor installer's command line on the connector | **Vendor limitation.** Visible to other administrators on that server while the installer runs. |
| Recorded by the vendor installer | Its own MSI log, base64-encoded | **Vendor behaviour.** The tool replaces those values with asterisks immediately after every install, on the connector and in any copy brought back. A copy that cannot be checked is not kept. |
| Proxy password (when `ProxyUser` is set) | Asked, held and handed over exactly like the passwords above | The same; the vendor installer receives it on its command line and may record it in its log, which is cleaned in the same way |
| Certificate repair | Standard input of a command prompt, then an environment variable inside the vendor script's own process | Not on any command line |

## Refusals that protect passwords

- **PowerShell module logging.** If a connector's policy records command parameters in the event log, the helper refuses to start, because the passwords would be recorded there. Turn the policy off for that server for the duration of the run.
- **Empty passwords.** An empty password stops the run before any service is touched.
- **Awkward characters.** A PFX password or path containing `%`, `^`, `"` or non-printable characters is refused for certificate repair, because the vendor's batch files would silently alter it.

## SSH

- Sign-in is by key only. The tool runs `ssh` and `scp` in batch mode, so it never falls back to asking for a password.
- A host seen for the first time has its host key accepted and remembered (`StrictHostKeyChecking=accept-new`). A host whose key later changes is refused. If you want every host key checked by hand first, connect to each connector once yourself before the first run.
- Your private key stays on the admin machine. Protect it with a passphrase and an SSH agent, or with file permissions.
- On the connector, restrict port 22 to your management network and turn off password sign-in (Getting Started, section 4).

## The staging folder on each connector

- `C:\ProgramData\AccessConnectorUpdate` is locked to Administrators and SYSTEM when it is created, and again before a scheduled task is started from it.
- The lock is applied only to a folder with that name, never to an arbitrary folder someone copied the scripts into.
- The staged files remain after the run: the installer, the tenant configuration file, and the PFX for Kerberos Auth connectors. The PFX is protected by its own password and by the folder's permissions. Remove the files afterwards if your policy requires it.
- Keytab copies and configuration copies taken before changes are kept in `KeytabBackup` and `CertBackup` under the same folder.

## The staging folder on the admin side

The share or folder you run from holds tenant configuration files and PFX files. Limit who can read it. The PFX and configuration passwords are not in it; keep it that way (no password text files).

## Spreadsheets

The spreadsheets used with `-ImportFleet`, and the drafts `-Mode Discover` writes, hold site details: host names, group and tenant names, account names, file names. They never hold passwords.

- A column whose header looks like a password column (it contains `pass`, `pwd`, `secret`, `token` or `credential`) is refused, so a password typed into the sheet stops the import instead of reaching the fleet file. The values in that column are never printed.
- Keep your spreadsheets in `FleetDeploy` beside the fleet file, and limit who can read them in the same way. There, the repository's `.gitignore` keeps every spreadsheet except the two templates out of version control; a copy saved anywhere else is not covered. Do not add them to another repository.
- The import writes the fleet file, a dated backup of the one it replaces (`<file>.bak-<yyyyMMdd_HHmmss>`, never overwritten), and the tool's usual log lines. It asks for no password and writes none.

## Discovery

`-Mode Discover` sends back an allow-list of settings and nothing else. It signs in with your SSH key, asks for no password, copies nothing to the connector and writes nothing there. Its script runs on the connector under Windows PowerShell 5.1, fed on standard input.

Some of the files it looks in also hold secrets. The rule is that a secret is never kept, compared or sent back, not that the file is never opened: `install.properties` is read line by line, and a line is kept only when its name is on the list.

This is everything the script sends back:

| Source on the connector | Kept and sent back | Never kept or sent back |
|---|---|---|
| Windows | The computer name and its DNS name | |
| The installer's uninstall entries | The installed version and install location of the entry named `Access Connector` (each entry's display name is read to find it) | Every other value of those entries |
| The four connector services | For each one installed: its name, its state and the account it runs as | The service's program path, which is used on the connector only to find the install folder |
| The install folder | The folder the connector was found in (from the uninstall entry or a service's program path; else the default) | |
| `HKLM\SOFTWARE\Omnissa\Access Connector` | `WS1_SYSLOG_HOSTNAME`, `IS_NET_API_LOGON_USERNAME`, `InstallDir`, `WS1_INSTALLED_SERVICES`, each read by name | Every other value, which is not read at all: the key's values are never listed, and no value whose name contains `PASS` is read. |
| `Support\scripts\install.properties` | The lines named `INSTALL_DIR`, `TENANT_URL`, `TRUST_CERTS`, `SYSLOG_CONFIGURATIONS`, `PROXY_HOST`, `PROXY_PORT`, `PROXY_USER`, `NON_PROXY_HOSTS`, `FIPS_ENABLED`, `DIRECTORY_SYNC_SVC_PORT`, `USER_AUTH_SVC_PORT`, `KERBEROS_AUTH_SVC_PORT`, `VIRTUAL_APP_SYNC_SVC_PORT` | The value of every other line, including the client secrets (`*_CLIENT_SECRET`) and the PFX password (`SSL_CERT_PASS`) held in the same file. Each line's name is checked first, and a line not on the list is passed over: its value is never kept, compared or sent back. |
| The four service definition files (`<service>.xml`) | Whether the Java4Shell patch flag (`UseBASE64Intrinsics`) is present in any of them | The rest of each file |
| Kerberos Auth `conf\application.properties` | The port number on the `eks.http.server.port` line (443 when there is none) | Every other line, including the keystore's encrypted password, is passed over |
| The Kerberos Auth certificate, when the service is running | The certificate it serves, read by a TLS handshake on the connector to its own port: the port, the subject, the DNS names, the issuer, the end date and whether it is the installer's self-signed one; or, when the handshake fails, its error message | The private key, the keystore and the keytab are not read |
| Anything that could not be read | A short message per item: the item's name and the error's message, the message cut to 200 characters | |

On the admin machine it matches the file names in `Installers`, `Configs`, `ChildCerts` and `TrustedCerts`. It never opens an es-config file or a PFX.

The script sent to the connector holds no secrets and returns a single line of JSON. If a connector's PowerShell logging policy records scripts, that record holds nothing secret either.

The draft spreadsheet it writes holds what was sent back, the file names matched and, for a connector in the fleet file, values taken from its entry. It holds no password or secret; keep it like the fleet file (above). After a partial read, Discover also writes a new fleet file beside the fleet file in use, holding only that file's top-level settings (staging, log and patch folder paths and the wrapper's path) and no groups; it holds no password or secret either.

## Accounts and rights

| Account | Used for | Rights needed |
|---|---|---|
| SSH or WinRM sign-in | Copying files and starting the helper | Local administrator on the connector |
| Domain admin (asked for at run time) | Kerberos Auth connectors only: runs the install so the vendor set-up can create or reset the connector's Active Directory account and write the keytab | What the vendor `setupKerberos.ps1` needs; a domain admin was used in testing |
| Service account (`ServiceAccount`) | The account the Kerberos Auth and Virtual App services run as | As Omnissa documents for those services |

## What the tool changes in Active Directory

Only through the unmodified vendor `setupKerberos.ps1`, during an install of Kerberos Auth or a keytab repair: it creates a user account named after the connector if none exists, resets that account's password and maps the connector's service principal name to it. Remember this if Kerberos Auth is ever removed from a connector: the account stays and should be disabled.

## Logs

- The audit log (`-AuditLog`) is append-only: one line per run with the time, user, machine, mode and outcome. It never holds a password.
- Error messages are passed through the same masking as screen output before they are written.
- The summary CSV holds tenant, connector, status, versions and exit codes.

## Reporting a security problem

Open a private security advisory on the repository, or contact the repository owner directly. Do not put passwords, keys, configuration files or unredacted logs in an issue.
