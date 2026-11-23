# Security

How the tool handles passwords, keys and files, and what you should do yourself.

## What is never stored

- No password is written to the fleet file, to `job.json`, to any log of this tool, or to a command line of this tool.
- Passwords are asked at hidden prompts each time you run it. There is no saved-password option.
- The repository's `.gitignore` keeps installers, tenant configuration files, PFX files, site fleet files and logs out of version control.

## The path a password takes

| Step | Where the password is | Protection |
|---|---|---|
| You type it | Admin machine memory | Hidden prompt; held as a SecureString; registered for masking so it is replaced by asterisks in anything printed or logged |
| SSH mode: sent to the connector | Standard input of the remote process, inside the encrypted SSH session | Not on any command line; not in shell history |
| WinRM mode: sent to the connector | A SecureString parameter inside the remoting session | Encrypted by the remoting protocol |
| Kerberos Auth connectors: handed to the scheduled task | A file in the locked staging folder, encrypted with Windows machine-scope data protection (DPAPI) | Readable by Administrators and SYSTEM only; deleted by the task as soon as it is read, and again by the parent process afterwards |
| The domain admin account password for the task | Held by Windows Task Scheduler | Only while the task exists. The task deletes itself when the work ends. |
| Given to the vendor installer | The vendor installer's command line on the connector | **Vendor limitation.** Visible to other administrators on that server while the installer runs. |
| Recorded by the vendor installer | Its own MSI log, base64-encoded | **Vendor behaviour.** The tool replaces those values with asterisks immediately after every install, on the connector and in any copy brought back. A copy that cannot be checked is not kept. |
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
