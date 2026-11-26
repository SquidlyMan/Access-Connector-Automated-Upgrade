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
| `-Schedule` on the helper (Stage mode): the passwords, and the Windows password of the account the job runs as | The passwords in `secrets.dat` in the locked staging folder, encrypted with Windows machine-scope data protection (DPAPI) since 1.5.2 (1.5.1 encrypted them for the signed-in user, which a session signed in by SSH key cannot do). The Windows password of the account the job runs as (asked, or `-RunAsUser`; a domain admin for a job with Kerberos Auth) held by Task Scheduler with the task `AccessConnectorUpgrade` | Machine scope means that any process on the server that can read `secrets.dat` can decrypt it, so the protection is the file itself: it is created empty and limited to Administrators and SYSTEM (inheritance removed) before the passwords are written in it, the job deletes it when it reads it, and it is removed again if a later step of `-Schedule` fails. The task deletes itself, and with it the stored Windows password, when the run ends; if it has not run 12 hours after its start time, Task Scheduler deletes it. Until then Task Scheduler holds that password, for a Kerberos Auth job a domain admin's. A job that never runs leaves `secrets.dat` behind: delete it. To cancel before the time: `Unregister-ScheduledTask -TaskName AccessConnectorUpgrade -Confirm:$false`, and delete `secrets.dat`. Proven at the console with 1.5.1 (the task deleted itself and `secrets.dat` was gone); the 1.5.2 changes are built, not yet run on a connector |
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

## The set-up scripts in Prerequisites

These scripts are built and tested offline. They have run in the lab in part, the PowerShell scripts as 1.0.0 and the macOS one as 2.1.0: `Install-OpenSSHServer.ps1` on ten servers that already had OpenSSH Server, `Deploy-OpenSSH-GPO.ps1` against one domain, `install-powershell7-macos.sh` with `--dry-run`, and `Install-PowerShell7.ps1` once with `-CheckOnly`; the 1.0.1 versions and the macOS one's 2.1.1, which changes nothing it does, have not yet run (Validation Record). What follows is what their code does. None of them takes or writes a password, key passphrase or token. On macOS, sudo asks for your password for the install step, and the script never sees it. On Windows, the elevation prompt that `Install-PowerShell7.cmd` asks for is Windows' own.

**`Install-OpenSSHServer.ps1`** (one server):

- **Key-only sign-in is never turned on without a key.** Password sign-in is turned off only when `administrators_authorized_keys` holds at least one key that sshd reads from the file as it is on disk, only Administrators and SYSTEM can reach the file, `sshd_config` points administrators at it, and nothing in `sshd_config` that applies to administrators turns key sign-in off for them or asks them for more than a key. Otherwise it stays as it is, and the summary says why. The script never turns password sign-in back on.
- **The key file and the host keys are locked.** The key file is limited to Administrators and SYSTEM (by their well-known SIDs, so it works in any Windows language), as OpenSSH requires. Private host keys that anyone else can reach, which sshd refuses, are reset to SYSTEM and Administrators, an owner and an entry by name included. Keys already in the file are kept; keys are only added.
- **Port 22 is limited only where you say so.** With `-AllowFrom`, the OpenSSH firewall rules are limited to those networks, and a rule the script enables or adds is limited first. On a server where the run installs OpenSSH Server, the install adds its own rule, `OpenSSH-Server-In-TCP`, which lets port 22 in from any address. Since 1.0.1, with `-AllowFrom`, that rule is limited right after the install, before sshd first starts; if it cannot be limited it is disabled until the firewall step, which tries again; if it can be neither limited nor disabled, the run stops before sshd starts. sshd still first starts with the Windows default `sshd_config`, so password sign-in is on until the `sshd_config` step, but only reachable from the `-AllowFrom` networks. Writing the keys and `sshd_config` before that first start is not done, because sshd makes `sshd_config` on its first start. Without `-AllowFrom`, the install's rule stays open to any address, with password sign-in on until the `sshd_config` step, and the run warns about it. (1.0.0 left the rule open to any address until the firewall step, with `-AllowFrom` too.) Built and tested offline; no first install has yet run on a server. The rules Windows enforces are read back afterwards, and other enabled rules that still let port 22 in from any address are named. Without `-AllowFrom`, no rule is added, enabled or changed. A run inside an SSH session that comes from outside `-AllowFrom` is refused, because its next sign-in would be.
- **A bad `sshd_config` is not used.** The new file is tested with `sshd -t` first; the old one is kept as `sshd_config.bak-<date>` and put back if sshd does not come back after the restart.
- **Private keys are refused and never shown.** Text that holds a private key, given as a key or as `-AllowFrom`, is refused without being printed or logged. Keys are shown and logged by fingerprint and comment only.
- `-Banner` and `-LoginAlert` are opt-in. The login-alert task never runs text from an event, so a user name chosen by whoever connects cannot become a command.

**`Deploy-OpenSSH-GPO.ps1`** (many servers, through Group Policy):

- **It reaches only the OU you name, and the OUs under it.** The GPO is linked only to `-TargetOU`, so it applies to every computer in that OU and in the OUs below it. The domain root, an OU with a domain controller in it or under it, and a GPO already linked to another OU are refused unless you add `-AllowDomainRoot`, `-AllowDomainControllers` or `-AllowOtherLinks`. A GPO of the same name that the script did not make is never touched.
- **Nothing changes before you type `YES`.** The plan comes first, with the computers the GPO will reach and the payload's SHA-256; only `YES`, in capitals, goes on (`-Yes` for an unattended run; a run with no terminal is refused without it). `-WhatIf` shows the plan and stops.
- **Port 22 is limited by default.** A run without `-AllowFrom` is refused, unless `-AllowFromAnyAddress` says that a computer where the GPO installs OpenSSH Server may accept port 22 from any address. With `-AllowFrom`, the payload (1.0.1) limits the install's rule before sshd first starts, or disables it, or stops before sshd starts (see `Install-OpenSSHServer.ps1` above); with `-AllowFromAnyAddress` the rule stays open to any address and password sign-in is on until the `sshd_config` step.
- **No empty GPO is left linked.** The GPO is linked last, after its files and its startup script registration are checked. If a step fails, a GPO made in that run is deleted again.
- **Keys are only added, never removed.** A key taken out of the GPO stays trusted on every computer that already ran it, until its line is deleted there (`-Help`, UNDOING IT). Removing the GPO does not remove the keys either.
- **The keys are checked by the payload's own functions**, taken from the payload file that is copied into the GPO, so the deployer accepts exactly what every computer will accept. Those functions run on the machine that runs the deployer, as the whole payload runs as SYSTEM on every computer in the OU: give it only a payload you trust.
- The GPO's files in SYSVOL, the settings file with the public keys and networks among them, can usually be read by every user of the domain, like other GPO files. They hold no secret.

**`Install-PowerShell7.ps1` and `install-powershell7-macos.sh`** (the admin machine):

- Both install Microsoft's own package. A downloaded package is installed only after its SHA-256 matches the hash published with the release and its signature is Microsoft's (on macOS: Developer ID Installer: Microsoft Corporation, Team ID UBF8T346G9, issued by Apple). That hash is Microsoft's `hashes.sha256`. On Windows, for a release found through the GitHub API whose `hashes.sha256` cannot be read or does not list the MSI, it is the SHA-256 digest GitHub records for the MSI. With neither, the package is not installed. A package that fails a check is not installed. On Windows, a pre-staged MSI (`-MsiSource`) is copied to a local folder and checked there: its signature always, its SHA-256 when the release's `hashes.sha256` sits beside it.
- `Install-PowerShell7.cmd` bypasses the execution policy for its own process only; the computer's policy is not changed, and a policy set by Group Policy still applies. `Install-PowerShell7.ps1` installs and updates nothing inside an SSH session, a first install included; `-CheckOnly` works there.
- The macOS script uses sudo for the install step only, and downloads, checks and installs the package in a private temporary folder (mode 700) that is removed when the run ends. Run as root, it refuses a cache, log or answer file that another user could change.

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
