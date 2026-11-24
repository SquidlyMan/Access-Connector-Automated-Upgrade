# Troubleshooting

Start with `-Mode Verify`: it shows what each connector looks like now and changes nothing. Then find the message you got below.

Logs to read, in order:

1. The screen output of the run (the helper's lines are relayed as they happen).
2. `FleetDeploy\FleetLogs\<tenant>_<connector>_<stamp>\` on the admin side (SSH modes), or `C:\ProgramData\AccessConnectorUpdate\Logs` on the connector:
   - `connector-upgrade-audit.log` and `connector-upgrade-errors.log`: the helper's own record;
   - `AccessConnector_Audit_<stamp>.log`: the wrapper's record, including each pre-flight check;
   - `AccessConnector_MSI_<stamp>.log`: the vendor installer's verbose log;
   - `task-console_<stamp>.log`: output of a scheduled task: the run-as task of Kerberos Auth connectors, or a job scheduled with the helper's `-Schedule`;
   - `result.json`: the result of the last install.

## Before anything is changed

| Message | Cause | Fix |
|---|---|---|
| `No fleet file found in ...` | None of the fleet file names looked for exists beside the script. With `-Fleet <name>`, only `fleet.<name>.psd1` is looked for. | Copy `fleet.example.psd1` to `fleet.psd1`, build one from a spreadsheet with `-ImportFleet`, or use `-Fleet` or `-FleetConfig`. `-Mode Discover -Connector <hosts>` needs no fleet file, as long as neither `-Fleet` nor `-FleetConfig` is given. |
| `Fleet file not found: <path>` | `-FleetConfig` names a file that does not exist. A relative path is taken from the current folder. | Correct the path |
| `Unknown tenant(s): ...` | `-Tenant` does not match a `Name` in the fleet file in use | Check the plan line that names the fleet file; you may be reading a different file than you think |
| `No connectors selected` | `-Connector` matched nothing, or the mode left every tenant out (repair modes skip tenants without Kerberos Auth) | Check spelling; use the exact `Host` value |
| `Files this run needs are missing under ...` | A file in the fleet file is not in the staging folder you ran from | Add the file. If the message names another copy of the folder, run from there. |
| `ssh was not found on the PATH` | No OpenSSH client | Install the OpenSSH client (Windows: optional feature; macOS and Linux have it) |
| `-Mode WinRM needs Windows` | WinRM mode started from macOS or Linux | Use SSH mode |
| `Not interactive: add -Yes` | Run with input redirected (a scheduler that redirects it, say) | Add `-Yes`. Passwords are still asked at prompts, so such a run then stops at the first one (next row) |
| `The SSH sign-in check failed on <n> of <m> connector(s): <hosts>. Nothing was changed and no password was asked. ...` | An upgrade or dry run over SSH, `-Mode RepairKeytab` and `-Mode RepairCertificate` sign in to every selected connector before they ask anything (since 1.5.1). Above this line, each connector that failed has its own: `cannot reach <host> over SSH: <SSH's own reason>. Hint: ...`, or `signed in to <host> over SSH, but could not run Windows PowerShell there: <error>`. Exit code 1, an error-log entry per connector, and an audit entry with `stage=signin`. | Follow the hint ("Connecting", below). To go on without those connectors, name the others with `-Connector`: the message lists them. |
| `A prompt needs an answer, but this run has no terminal to type it in: <prompt>. ... Nothing was changed.` | The run needs a password or an account typed in, and it has no terminal: it was started with its input redirected, or with `pwsh -NonInteractive`. It stops with exit code 1 before anything is copied to a connector (an SSH run makes its sign-in check, the row above, first). In the SSH and WinRM modes the message also says `or use -Mode Stage`; at the `Type YES` prompt it says `Add -Yes to confirm without a prompt`. A scheduler that gives the run a console without redirecting its input is not detected: start scheduled runs with `pwsh -NonInteractive`. (In 1.4.1 a run with its input redirected ended silently with exit code 0 at the first password prompt.) | Run it from an interactive terminal, without `-NonInteractive`. For a change window with nobody present, use `-Mode Stage` (Implementation Guide, "Unattended") |
| `Empty ... password ... Nothing was changed` | Enter was pressed at a password prompt | Run again |
| `Fleet file settings are not valid. Nothing was contacted` | A port, `EnableFips`, `InstallDir` or proxy setting is wrong; each one is listed | Correct the fleet entry |
| `[note] ...: unknown fleet setting(s) ignored` | A setting the tool does not know, usually a misspelling | Correct the spelling (Fleet File Reference) |
| `This script needs PowerShell 7 or later (pwsh)` | Started under Windows PowerShell 5.1 | Install PowerShell 7 and start it with `pwsh` |
| `proxy password ... contains a double quote` | The installer's command line cannot carry it | Change the proxy account's password |
| `-ImportFleet needs the name of a spreadsheet file (.xlsx, .csv, .txt or .tsv).` | `-ImportFleet` was given an empty value, for example from a variable that holds nothing | Give the spreadsheet's file name. Nothing else ran. |
| `-ExportCsv needs a file name.` | `-ExportCsv` was given an empty value | Give a file name, or leave `-ExportCsv` out for the default |

## Building the fleet file from a spreadsheet (-ImportFleet)

Nothing is written while the spreadsheet has a problem, so a failed import leaves the fleet file as it was. Run with `-DryRun` until it shows no problems. Row numbers are the spreadsheet's own: in a CSV file the header is row 1; in an `.xlsx` file they are the numbers Excel shows. Messages in `code` are quoted as the tool prints them, with `<...>` standing for the part that varies; the others describe the message.

| Problem or warning | Cause | Fix |
|---|---|---|
| `Spreadsheet not found: <file>` | No file by that name. A relative name is taken from the current folder. | Correct the name, or `cd` to the folder that holds it |
| `-FleetConfig names a folder: <path>. Name the fleet file, for example <path>/fleet.psd1. Nothing was written.` | `-FleetConfig` must name the fleet file itself | Add the file name |
| `The folder for the fleet file does not exist: <folder>. Nothing was written.` | `-FleetConfig` names a file in a folder that is not there | Correct the path, or create the folder |
| `The fleet file <path> exists but could not be read, so it is not replaced: ...` | The existing fleet file is not a valid PowerShell data file | Correct or move it, then import again |
| `[ignored] -Fleet: -FleetConfig names the file directly.` | Both were given | Nothing; the file named with `-FleetConfig` is written. Drop one of them. |
| `[ignored] -<switch> has no effect with -ImportFleet.` | A switch that chooses, reaches or changes connectors was given with the import | Nothing; the import ran without it |
| "save it as .xlsx or .csv" | The file is an old `.xls` workbook or another format | In Excel, Save As Excel Workbook (`.xlsx`) or CSV UTF-8 |
| `<file> is an Excel workbook, not text: give it the .xlsx extension, or save it as .csv` | A workbook was saved or renamed with a `.csv`, `.txt` or `.tsv` name | Rename it to `.xlsx`, or save it from Excel as CSV |
| "it is not a readable .xlsx workbook" | The file is an older `.xls` renamed, or a workbook saved with a password | Save it as `.xlsx` without a password, or as `.csv` |
| The values come from the wrong sheet | Only the first sheet that is not hidden is read, in the workbook's own order. The plan line says which, for example `(xlsx, sheet 'Fleet' of 3)`. | Move the sheet with the rows to the first (leftmost) tab |
| `only the first sheet of the workbook, '<name>', is read, and it holds no connector rows; the workbook has <n> sheets: put the rows on the first one, or move their sheet to the front` | The rows are on another sheet | Move that sheet to the front |
| `[note] hidden sheet(s) before it passed over: '<name>'` | The workbook has hidden sheets in front of the one read | Nothing, if the sheet named in the plan is the right one. Otherwise unhide and reorder the sheets. |
| A column is named as unknown | A header the tool does not know, usually a misspelling | Correct the header (Fleet File Reference lists them). For a column of your own, start its header with `#`. |
| "columns that hold passwords are refused; passwords are asked at run time" | A header contains `pass`, `pwd`, `secret`, `token` or `credential` | Delete the column. Passwords never go in the spreadsheet; the tool asks for them at run time. |
| No `Group` or no `Host` column | One of the two required columns is missing or misnamed | Add it. `Name` or `Tenant` is accepted for `Group`; `Connector` or `Server` for `Host`. |
| A row has values but no `Host` | A connector row without its server name, or notes typed below the table | Add the host, or move the text to a `#` column or `Notes` |
| `row <n> <column>: the cell holds the Excel error <error>; type the value in` | The cell holds an Excel error value (`#N/A`, `#REF!` and so on): an error cell in an `.xlsx` file, or the error's text in a CSV file. Often a formula that refers to a deleted cell or another workbook. | Type the value itself into the cell |
| `row <n> <column>: the cell holds a line break; put the value on one line` | Alt+Enter was pressed in a cell, or text was pasted with a line break. Only `Services` may hold line breaks (one service per line). | Put the value on one line |
| Warning: `row <n> Group: '<name>' is taken as '<Name>' (row <m>); group names are not case-sensitive` | The same group is spelt in two cases | Nothing, if they are the same group; spell them alike to drop the warning. Otherwise give the group another name. |
| A host appears twice | The same connector is in two rows (the comparison ignores case) | A connector belongs to one group only. Delete one row. |
| A `Group` name is not valid | It holds a space or another character outside letters, digits, `.`, `_` and `-`, or does not start with a letter or digit | Rename the group |
| Two different values for one group setting | A later row of the group has a different value in a group column; the message names the group, the column, both values and both rows | Make them the same, blank the later one, or give the connectors that differ a group of their own |
| A required value is missing | A group has no `Installer`, `ConfigFile` or `Services`, or no `ServiceAccount` while it installs Kerberos Auth or Virtual App | Fill it in on any row of the group |
| A service name is unknown | `Services` holds a name that is not one of the four | Use `DirectorySync`, `UserAuth`, `KerberosAuth`, `VirtualApp` (with or without `Service`) |
| A yes/no value is not understood | `ForceReinstall` or `EnableFips` holds something other than `TRUE`/`FALSE`, `yes`/`no`, `y`/`n`, `1`/`0` | Correct it, or leave it blank |
| A port is not a whole number | A port column holds anything but digits | Type the number only |
| `InstallerVersion` is not a version | It is not two to four numbers separated by dots | Correct it, for example `26.10.0.0` |
| "Excel may have turned 26.10 into 26.1: format the column as Text and type it again" | Excel stored a version as a number. A problem when `InstallerVersion` does not start with `ExpectVersionPrefix`; a warning when the prefix alone looks like `26.1`. | Format the column as Text, type the value again, and save as `.xlsx` |
| A path must be "relative to the staging folder" | `Installer`, `ConfigFile`, `Pfx` or `TrustStore` starts with a drive letter, `\\server` or `\` | Give the path from the staging folder, for example `Installers\Access-Connector-Installer.exe` |
| A `ServiceAccount` is not `DOMAIN\name` | The domain part is missing, or the name is in another form | Write it as `DOMAIN\name` |
| A port, proxy, `InstallDir` or `EnableFips` problem | The same checks as for a fleet file written by hand | As in "Before anything is changed" above |
| Accented letters look wrong | The file was saved in an encoding the tool could not tell from its content | Save it from Excel as CSV UTF-8, or as `.xlsx` |
| Warning: `Pfx` is set but the group has no Kerberos Auth | The PFX is used only by Kerberos Auth | Blank `Pfx` for that group, or add `KerberosAuth` to `Services` |
| Warning: Kerberos Auth without `Pfx` | The installer will make a self-signed certificate | Add the PFX to `ChildCerts` and name it in `Pfx` |
| `[note] Not in the staging folder yet (add them before a run):` and a list | Files the groups name are not there yet. The fleet file is still written. | Add the files before the first run; a run stops until they are there |
| `[note] The existing fleet file has setting(s) the tool does not use, which the new file leaves out: <names>` | The old fleet file has top-level settings the tool does not know | Nothing, if they were not wanted. They are still in the backup copy. |
| `The spreadsheet has <n> problem(s). Nothing was written:` | One or more problems above | Correct each one listed, then run with `-DryRun` again |
| `Not interactive: add -Yes to confirm replacing the fleet file. Nothing was written.` | An existing fleet file that holds groups would be replaced, and there is no one to type `YES`. (A file with no groups, such as the one a partial Discover starts, is replaced without asking.) | Run it interactively, or add `-Yes` |
| `Not confirmed. Nothing was written.` | Something other than `YES` was typed | Run again and type `YES` |
| `The fleet file could not be written: ...` | The folder is read-only, the disk is full, or the file is locked | Correct the cause. The message says whether the previous file is unchanged or kept as its backup copy. |
| `The written fleet file does not read back as intended: ...` | The fleet file on disk is not what the spreadsheet said | Report it, with the spreadsheet's layout but not its values. When a file was replaced, the previous one was put back, and it is still kept as `<fleet file>.bak-<yyyyMMdd_HHmmss>`. |
| `[note] A run without -Fleet or -FleetConfig uses fleet.<name>.psd1 beside this script, not the fleet.psd1 just written. Name the file as below, or rename it.` | `fleet.<this computer name>.psd1` or `fleet.<this computer domain>.psd1` is beside the script, and a run picks it before `fleet.psd1` | Use the commands shown, which name the file written with `-FleetConfig`. Or import with `-FleetConfig` or `-Fleet` naming the file a run picks. |
| `[note] Replacing <file> removes <n> group(s) the spreadsheet does not hold: <names>. To keep them, add their rows to the sheet, or import into another file with -Fleet or -FleetConfig.` | The import writes every group from the spreadsheet and keeps none of the old ones | Add the groups' rows to the spreadsheet and import again, or import into another file. After a replacement they are still in the backup copy. |
| `[note] <group>: the current fleet file sets <settings>, which the spreadsheet leaves blank, so the new file will not. Fill the column to keep it.` | The existing fleet file sets something for that group that the spreadsheet leaves blank. After `-Mode Discover` this is usually `ExpectVersionPrefix`, which discovery always leaves blank. | Fill the column in the spreadsheet (format a version column as Text first) and run the dry run again, or go on if the setting is not wanted |

## Discovering existing connectors (-Mode Discover)

Messages in `code` are quoted as the tool prints them, with `<...>` standing for the part that varies.

| You see | Cause | Fix |
|---|---|---|
| `[ignored] -Tenant: -Connector names the hosts to read. Each is still matched with its fleet entry, whatever group it is in.` | `-Tenant` and `-Connector` were both given | Nothing; the hosts named are read. Leave out `-Connector` to read whole groups with `-Tenant`. |
| `[ignored] -<switch> has no effect with -Mode Discover.` | A switch that installs, repairs, runs in parallel or confirms a change was given | Nothing; Discover only reads |
| `No fleet file found in <folder>. Looked for: fleet.<name>.psd1` | `-Fleet <name>` was given and that file does not exist. Discover needs no fleet file only when neither `-Fleet` nor `-FleetConfig` is given. | Correct the name, or leave out `-Fleet` and name the hosts with `-Connector` |
| `No connectors to discover. Name them with -Connector, or check -Tenant against the fleet file.` | The fleet file in use has no connectors in the groups chosen | Name the hosts with `-Connector` |
| `The folder for the draft spreadsheet could not be made: <folder> (<reason>). Nothing was read.` | `-ExportCsv` names a file in a folder that is not there, and the folder could not be created (no permission, a read-only volume, or a file of that name in the way). A relative path is taken from the current folder. A folder that can be made is made, as for `-AuditLog` and `-ErrorLog`. | Correct the path, or name a folder you can write to |
| `Only part of <fleet file> was read (<n> of its connectors left out), so the commands below import this draft into a new fleet file, <new file>, which holds the original's top-level settings and no groups yet. Importing it into <fleet file> would replace that whole file and drop the groups the draft does not hold.` | `-Tenant` or `-Connector` left out some of the fleet file's connectors. (Naming every one of its hosts with `-Connector`, or every group with `-Tenant`, is a full read and gives no warning.) Discover has written `fleet.discovered_<yyyyMMdd_HHmmss>.psd1` beside the fleet file, with those of `StagingRoot`, `StagingFolders`, `CentralLogRoot`, `InstallScript` and `JavaPatchDir` that the original sets, and the next commands import into it. | Nothing, if a separate file is what you want: the import into it needs no `YES` and keeps those settings. For one fleet file, add the other groups' rows to the sheet and import it with `-FleetConfig` naming the fleet file, or run Discover again without `-Tenant` and `-Connector`. |
| `The new fleet file for this draft could not be started: <file> (<reason>). The draft is written: <draft>` | After a partial read, the new fleet file could not be written beside the fleet file (the folder is read-only, say). Exit code 1. | Make the folder writable and run Discover again. Or import the draft with `-FleetConfig` naming another file; a new file gets the default top-level settings, not the original's. |
| Excel shows each row of the draft in one cell | The regional settings use `;` as the list separator, so Excel does not split a comma-separated file when it opens it | Open it with Data > From Text/CSV and choose Comma as the delimiter |
| `The output file already exists and is not overwritten: <path>. Name another with -ExportCsv.` | Discover never overwrites a file. This is checked before any connector is read. | Name another with `-ExportCsv`, or move the old one |
| `ssh was not found on the PATH.` or `SSH key not found: <path>` | As for the other SSH modes | Install the OpenSSH client, or correct `-SshKey` |
| `<host>: not reached: <reason>` on screen, with a hint when SSH's reason suggests one (also in the error log; not in `Notes`); `not reached: <reason>` in `Notes`, `Group` blank; exit code 1 | SSH sign-in to that connector failed (the reason is SSH's own message), or the read did not return: `no answer within 120 seconds`, `the connector returned no discovery result`, `ssh ended with exit code <n> and no result`, `the discovery result could not be read` | As in "Connecting" below. Then run Discover again, or fill the row in by hand (its values are in the fleet file). Deleting the row removes that connector from the fleet file the draft is imported into; the import's note names it. The import refuses a row with no `Group`. |
| `not read: ...` on a host's line (a warning), `not read on the connector: ...` in `Notes` | The connector was reached, but some items could not be read there; each is named with its reason | Read the reason. The row is still written; fill in or check the columns that item would have given. |
| `The spreadsheet could not be written: ...` | The output file could not be created (the folder is read-only, or the disk is full) | Correct the cause and run again; nothing was changed on the connectors |
| `Installer` blank | `Installers` in the staging folder holds no `.exe` or more than one, so the tool cannot tell which one you want, and the connector is not in the fleet file | Fill in the installer to use |
| `ConfigFile` blank | No single `.json` file in `Configs` is named after the tenant's full host name or, failing that, its first name part in a name with no other dotted name (Fleet File Reference, "Matching the es-config file"), and the connector is not in the fleet file. The connector does not record which es-config file it was installed with (`ES_CONFIG_FILE` is empty after an install), and the tool never opens es-config files to look. | Fill it in. Naming each es-config file after its tenant's host name, for example `tenant1.us1.example.com-es-config.json`, lets Discover match it next time. |
| Note `ConfigFile matched by the tenant's first name part only (<label>): check it` | No file is named after the tenant's full host name; one file has its first name part as a word | Check it is that tenant's file |
| `Pfx` blank on a Kerberos Auth row; note `set Pfx if a PFX is used: without one the installer makes a self-signed certificate` | The service was not running, or no single PFX in `ChildCerts` is named after the certificate it serves, and the fleet entry gives none. The connector does not record which PFX it was installed with (`SSL_CERT` is empty after an install). | Fill in the PFX, or leave it blank if the connector is meant to use the installer's own certificate |
| Note `Kerberos Auth serves the installer's self-signed certificate: set Pfx, then run -Mode RepairCertificate` | The PFX certificate is not on the service, usually after an upgrade | Fill in the PFX, then run `-Mode RepairCertificate` once the fleet file is written |
| Note `Kerberos Auth is not running, so its certificate was not read`, or `Kerberos Auth certificate not read: <reason>` | The certificate could not be read, so `Pfx` could not be matched | Start the service and run Discover again for that host, or fill in `Pfx` |
| `TrustStore` blank; note `the connector trusts extra CA certificates: set TrustStore` | The connector was installed with trusted certificates, but `TrustedCerts` in the staging folder holds no `.pem`, `.cer` or `.crt` file and the fleet entry gives none | Add the certificates and fill it in |
| `TrustStore` blank, no note | The connector was installed without trusted certificates | Nothing, unless it needs them |
| `ServiceAccount` blank with Kerberos Auth or Virtual App | The installer recorded no account and the service does not run as a `DOMAIN\name` account | Fill it in |
| Note `taken from fleet entry <Name>: <columns>` | The connector is in the fleet file, and these columns could not be found from the connector or the staging folder | Check them; they are what the fleet file says now |
| `ExpectVersionPrefix` blank | Always left blank: Excel would turn `26.10` into `26.1` | Optional. Format the column as Text in an `.xlsx` copy, then type it. |
| A `Group` name ends in `-2`, `-3` | Connectors that would share a group have different group settings (services, ports, account, syslog target and so on). Upper and lower case do not count. The rows closest to the fleet entry (fewest columns in their `differs from fleet entry` note) keep its name, so the connector that differs more is the one with `-2`. | Look at the rows and their `differs from fleet entry` notes: correct a connector that is wrong (a value mistyped at installation shows up this way), or keep the groups apart and rename them |
| Note `differs from fleet entry <Name>: <columns>` | The connector does not match its fleet entry in those columns | Decide which is right. Change the spreadsheet, or put the connector right with a run (for services, `-ForceReinstall`). |
| Note `Java4Shell patch flag present: set JavaPatchDir in the fleet file` | The connector carries the vendor patch | After the import, set `JavaPatchDir` in the fleet file so that upgrades apply it again |
| Note `Java4Shell patch flag present` missing although the patch is on the connector | The fleet file in use sets `JavaPatchDir` already, so there is nothing to ask | Nothing. The file the next commands import into keeps that `JavaPatchDir`: after a full read it is that fleet file, whose top-level settings the import carries over; after a partial read it is the new `fleet.discovered_<yyyyMMdd_HHmmss>.psd1`, which Discover starts with the original's top-level settings, `JavaPatchDir` among them. If you import into another file instead, set `JavaPatchDir` there. |
| `Group` is `GROUP` | The connector reported no tenant URL and is not in the fleet file | Rename it |
| Note `no Access Connector found` | No connector is installed on that server | Fill in the row by hand for a clean install, or delete it |

## Connecting

| Message | Cause | Fix |
|---|---|---|
| `cannot reach <host> over SSH: <SSH's own reason>`, ending in `Hint: ...` when the reason suggests one | ssh could not connect or sign in. Since 1.5.1 the message gives SSH's own reason (in 1.5.0 it read `cannot reach <host> over SSH or create C:\ProgramData\AccessConnectorUpdate` and gave none). It comes from the sign-in check before the prompts, or from the first step of Verify, Stage and the runs. | Follow the hint; the rows below cover each reason. Test by hand: `ssh <user>@<host> hostname`, with `-i <key>` if you use `-SshKey`. Red lines beginning `ssh (<host>):` come from later steps. |
| `signed in to <host> over SSH, but could not create C:\ProgramData\AccessConnectorUpdate: <error>` | SSH works, but the staging folder could not be made. The error is the connector's own, for example `New-Item : Access to the path ... is denied.` when the SSH account is not an administrator there, or a message that Windows PowerShell could not be started. | Sign in with an account in the connector's local Administrators group (`SshUser` in the fleet file, or `-SshUser`) |
| `signed in to <host> over SSH and the step answered, but ssh then ended with exit code <n>: <reason>`, or `... but the session did not end within <n> seconds` | SSH signed in and the step (the folder step, or the sign-in check) did its work and said so, but the session then ended badly: the network dropped it (`client_loop: send disconnect: Broken pipe`, say), or, for the sign-in check, it did not end within its 120 seconds. Since 1.5.1; in 1.5.0 the folder step reported this as `cannot reach <host> over SSH or create C:\ProgramData\AccessConnectorUpdate`. | Run again. If it repeats, look at the network between the admin machine and the connector, and at the connector's OpenSSH Server event log |
| `Permission denied (publickey)`; hint `the key was not accepted` | ssh did not offer the right key, or the connector does not accept it | Name the key with `-SshKey`, or add an `IdentityFile` line for the connectors to the SSH settings file (Getting Started section 4.7). If the key is offered and still refused, add its public key to `C:\ProgramData\ssh\administrators_authorized_keys` and re-run the `icacls` command from section 4.4. Test with `ssh <user>@<host> hostname`. |
| `Host key verification failed`, or `REMOTE HOST IDENTIFICATION HAS CHANGED`; hint `the connector's host key changed` | The server's host key changed since it was first seen (a rebuilt server, or something else answering under its name) | Confirm the rebuild, remove the old entry with `ssh-keygen -R <host>`, then connect once by hand and check the new key (Getting Started section 4.6) |
| `Could not resolve hostname`; hint `the name does not resolve from this machine` | DNS on the admin machine does not know the name | Correct `Host` in the fleet file, or the admin machine's DNS settings |
| `Connection timed out`, `Operation timed out`, `Connection refused` or `No route to host`; hint `port 22 is not reachable from this machine` (or the port SSH names) | A firewall between the admin machine and the connector, or OpenSSH Server not running on it. When the connector answers ping and sshd is running, it can be an endpoint-protection product on the connector: one with a firewall of its own can drop port 22 while Windows Firewall lets it in. | Getting Started sections 4.1 and 4.2: start `sshd`, and allow port 22 from the admin machine. In an endpoint-protection product, add an inbound rule for `C:\Windows\System32\OpenSSH\sshd.exe` |
| `Too many authentication failures`; hint `too many keys were offered` | ssh offered several keys (from an agent, say) and the connector stopped before the right one | Name the key with `-SshKey`, and set `IdentitiesOnly yes` for the connectors in the SSH settings file (Getting Started section 4.7) |
| `scp to <host>:... failed` | Disk full on the connector, or the SFTP subsystem is disabled in `sshd_config` | Free space; make sure `Subsystem sftp sftp-server.exe` is present |
| `installer hash mismatch on <host> after copy` | The copy was cut short or altered | Run again; check disk space and antivirus quarantine on the connector |
| WinRM: `Could not sign in to <host> over WinRM as <user>: <reason>` | The connector refused the sign-in: a wrong user name or password, an account that is not an administrator there (`Access is denied.`), or one that is locked out, disabled or has an expired password. Since 1.5.1 this stops the tenant and, unless `-ContinueOtherTenants`, the run, also in a dry run, so the same password is not tried on every connector. It is known before the next connector is started, so with `-Parallel` too the connectors not yet started are left alone (`-Parallel` ignores `-ContinueOtherTenants`). | Retype the account as `DOMAIN\name` with its password; check that it is an administrator on the connectors (a domain admin for Kerberos Auth groups) |
| WinRM: `New-PSSession` cannot connect | Remoting not enabled, the name does not resolve, or a firewall. Such a connector gets `Error`; a dry run goes on to the next one, a real run stops as after any failure. | `Test-WSMan <host>`; `Enable-PSRemoting -Force` on the connector |

## Pre-flight and dry run

| Message | Cause | Fix |
|---|---|---|
| `DryRunFailed`, `pre-flight exit ...` | A pre-flight check in the wrapper failed | Read the lines above it and `AccessConnector_Audit_*.log`: PFX password wrong, configuration file invalid, service account password wrong |
| PFX check fails | Wrong PFX password, or the file is not a PFX with a private key | Retype; open the PFX on your own machine to confirm |
| Configuration password "rules" warning | The password typed does not meet Omnissa's documented rules for that password, so it cannot be the right one | Retype. A password that passes the rules is still only confirmed by the installer itself. |
| `Could not start the task as <account>` | The domain admin account name or password is wrong, or the account may not run scheduled tasks | Retype as `DOMAIN\name`. Nothing was changed. The tenant's other connectors are not tried, to avoid repeated bad sign-ins. |
| `this sign-in (...) cannot query Active Directory` | A Kerberos Auth connector was run without the scheduled-task route | Give a domain admin account when asked. With `-Mode Stage`, run `Run-Upgrade.cmd` signed in as a domain admin. |
| `a built-in service account cannot rebuild the Kerberos keytab` | The helper was started as SYSTEM for a Kerberos Auth connector | Use a domain admin account |
| `this server writes PowerShell command parameters to its event log` | Module logging policy is on | Exempt the server for the run |
| `this connector is installed in FIPS mode; set EnableFips = $true` | The fleet entry does not ask for FIPS mode, but the connector has it | Add `EnableFips = $true` to the entry |
| `the fleet entry asks for FIPS mode, but this connector is installed without it` | FIPS mode cannot be changed after install | Remove `EnableFips`, or reinstall in FIPS mode as the message says |
| `a task named AccessConnectorUpgrade-RunAs is already running` | An earlier run is still working on that connector | Wait for it. Check `task-console_*.log` on the connector. |
| Helper `-Schedule`: `Could not register the scheduled task: the time given, <time>, has already passed on this server's clock (now <time>)` | The time is in the past on the connector's own clock (a wrong day, say). A one-time task with a past start time would never run. Nothing was written. (Since 1.5.1.) | Give a time still to come, on the connector's clock |
| Helper `-Schedule`: `Could not register the scheduled task: a task named AccessConnectorUpgrade is running on this server now ...` | An earlier scheduled run is still working. When it ends it deletes the task of that name, so it would delete the new one too. Nothing was written. (Since 1.5.1.) | Schedule again when that run has ended (its result is in `Logs\result.json`) |
| Helper: `-Schedule cannot be used with -RunAsUser or -RunAsTask` | The run-as task starts the work at once, so the time would be ignored. Refused before anything is asked. (Since 1.5.1.) | Sign in as the account the job is to run under, then use `-Prompt -Schedule` |

## During and after the install

| Message | Cause | Fix |
|---|---|---|
| `Failed`, `installer exit <code>` | The vendor installer failed | Read `AccessConnector_MSI_*.log` (search for `Return value 3`). The services that were running before have been started again; confirm with `-Mode Verify`. |
| `Unhealthy: only n of m services running` | A service did not start within four minutes | Check the service's own log under the connector's install folder; start it; run `-Mode Verify` |
| `Unhealthy: installed version is X, expected Y*` | `ExpectVersionPrefix` does not match the installer, or the install did not take | Correct the fleet file, or read the MSI log |
| `Unhealthy: Kerberos keytab missing or empty` | The vendor Kerberos set-up could not reach Active Directory or failed | `-Mode RepairKeytab` |
| `Unhealthy: the Kerberos service serves '...' not the PFX certificate` | The certificate step could not complete | `-Mode RepairCertificate` |
| `Unhealthy: the installer needs this server restarted` | Windows Installer asked for a reboot (exit 3010 or 1641) | Restart the server in your own time, then `-Mode Verify` |
| `the installer finished, but Install-AccessConnector.ps1 reported a problem afterwards` | The connector is on the new version but one of the wrapper's checks afterwards failed | Read `AccessConnector_Audit_*.log`; the tool has carried on with its own checks |
| `the connector returned no result` | The connection dropped, or the helper was stopped | The work may still be running on the connector. Check `result.json` and the task console log there before running again. |
| `the task is still running after 120 minutes` | The scheduled task has not finished | It was left running. Check `task-console_*.log` on the connector. |
| `The fleet entry names the install folder ..., but this connector is installed in ...` (warning) | `InstallDir` differs from where the connector is | An upgrade stays where it is. Correct `InstallDir`, or move it with `-ForceReinstall` |
| Wrapper audit log: `Served certificate does not match the provided PFX ... Expected after an upgrade` | Normal after an upgrade | The fleet tool puts the PFX back itself. Run by hand: `-Mode RepairCertificate` |
| Dry run: `note - A real run would SKIP this connector` | The connector is already on the installer's version. The passwords were still checked | Nothing, if no change is wanted. Add `-ForceReinstall` to reinstall |
| Same-version connector: nothing seems to happen | A connector already on the installer's version is skipped by design | Add `-ForceReinstall` if a reinstall is what you want |

## Verify shows something wrong

A red line (a service down, the keytab empty or missing, or, for a group with a `Pfx`, a certificate that is not a proper one) makes Verify end with exit code 1, and the error log names what is red on each such connector: `<host> (<group>): red in Verify: ...`. Yellow lines keep exit code 0.

| Verify shows | Meaning | Fix |
|---|---|---|
| `no connector services installed` | No connector on this server | A normal run will clean install it |
| `services 3/4 up (KerberosAuth=Stopped)` | A service is down | Start it; read its log |
| `java flag 2/4` | Some Java processes lack the patch flag | Re-run the upgrade, or run the vendor patch script and restart the services |
| `keytab EMPTY (6 bytes)` | The keytab file has no keys | `-Mode RepairKeytab` |
| `certificate SELF-SIGNED by the installer` | The vendor installer's own certificate is being served | `-Mode RepairCertificate` |
| `certificate DOES NOT NAME THIS SERVER` | The PFX certificate lacks this connector's name | Issue a certificate that names every connector it is used on. If Kerberos Auth is not meant to be on this connector, remove it (`Services` plus `-ForceReinstall`). |
| `certificate EXPIRED` | Past its end date | New PFX, then `-Mode RepairCertificate` |
| `certificate not checked` | The Kerberos Auth service is not running, or the helper on the connector is an older version | Start the service; run Verify again (it copies the current helper) |

## Kerberos specifics

- **The Access console can show Kerberos Auth as active while the keytab is empty.** Console health does not prove the keytab. Trust `-Mode Verify`.
- **A browser privacy warning at `https://<connector>/eks/...`** means the Kerberos Auth service is serving a certificate the browser does not trust, typically the installer's self-signed one after an upgrade. The Kerberos sign-in redirect goes to the connector's own name. Run `-Mode RepairCertificate`.
- **A yellow warning on Kerberos Auth in the Access console** with "No subject alternative DNS name matching ..." means the certificate served does not name that connector.
- **A keytab repair resets the password** of the Active Directory account named after the connector. Kerberos sign-in through that connector stops for about a minute while its service restarts.
- **A certificate repair** stops only the Kerberos Auth service, for a few minutes.

## Certificate repair outcomes

The exact wording on screen varies; these are the situations.

| Situation | Meaning |
|---|---|
| `already serving the PFX certificate; not changed` | Nothing to do. `-Reapply` forces it. |
| The PFX certificate does not name this server | Refused, to avoid installing a certificate clients will reject. `-Reapply` overrides. |
| PFX password or path contains `%`, `^` or `"` | The vendor batch files would alter it. Change the password or rename the file. |
| Refused: FIPS mode, or a proxy user is configured | These configurations are outside what the repair has been built for |
| An earlier certificate change was interrupted | A marker from a previous run was found. The message says what state the service is in. Run the repair again. |
| The original configuration was put back | A check after the change failed, so the copy taken before was restored. The connector is as it was. The message says which check failed. |

## Setting up PowerShell 7 and OpenSSH Server (Prerequisites)

The scripts in `Prerequisites` have not yet run on Windows or macOS (Validation Record). Each one can keep an audit log and an error log: `Install-OpenSSHServer.ps1` in `C:\ProgramData\ssh\logs` on the server by default, `Install-PowerShell7.ps1` in `%ProgramData%\PS7Deploy` by default, the other two where their log switches say (`-AuditLog` and `-ErrorLog`; `--audit-log` and `--error-log` on macOS).

| What you see | Cause | Fix |
|---|---|---|
| An SSH session to a server ended while PowerShell 7 was being upgraded there, and PowerShell 7 may be half-installed | The OpenSSH default shell is pwsh. The upgrade stops `pwsh.exe`, which ends the session and can stop the install with it, half-way | Install it again with `Install-PowerShell7.ps1` at the console, by Remote Desktop or over WinRM. It refuses every SSH session, also one that starts Windows PowerShell. An install by hand (msiexec) can run from an SSH session that starts Windows PowerShell (`ssh <server> powershell`). The tool is not affected: it starts Windows PowerShell by name |
| `This run is inside an SSH session (<why>), so PowerShell 7 is not installed or updated: ...` from `Install-PowerShell7.ps1` | `SSH_CONNECTION` or `SSH_CLIENT` is set, or sshd is among its parent processes. For the reason in the row above, it installs nothing over SSH, also when PowerShell 7 is already current; exit code 1 | Run it at the console, by Remote Desktop, or through WinRM (`Enter-PSSession`, `Invoke-Command`). `-CheckOnly` works over SSH |
| `Not a parameter of this script: <words>.` from `Install-PowerShell7.ps1` | A word it does not know (`checkonly`, or `/CheckOnly` as cmd.exe programs write switches), or a path with a space and no quotes. Nothing was done, and no log was written | Name each parameter with a dash, as `-Help` lists them, and quote a path with spaces |
| `... is not a usable path, it holds a quote` from `Install-PowerShell7.ps1` | A quoted folder that ends in a backslash (`"D:\IT Logs\"`): Windows reads `\"` as part of the name, and the rest of the command line joins it | Write the folder without the last backslash, or with two (`"D:\IT Logs\\"`) |
| Installing OpenSSH Server (`Add-WindowsCapability`, or `Install-OpenSSHServer.ps1` at "Installing the Windows capability") seems to hang | It can take more than an hour on Windows 10 and 11; on a server it is usually quick | Let it finish. Do not restart the computer meanwhile: a restart stops the install. With no internet access or a WSUS that does not supply it, use `-Source` (Getting Started 14.6) |
| sshd does not start, or stops at once. In an elevated window, `sshd -T` or `sshd.exe -ddd` (in `C:\Windows\System32\OpenSSH`) says `no hostkeys available`; the event logs show nothing | The host key files have permissions sshd refuses. After an `ssh-keygen -A` typed in an elevated window, they can carry an entry for that admin account, which `icacls /inheritance:r` does not remove. (Typed in a window that is not elevated, `ssh-keygen -A` fails without a message.) | Fix each `ssh_host_*_key` file as below, then `Restart-Service sshd`. `Install-OpenSSHServer.ps1` makes the same repair when it checks the host keys |
| `This run is inside an SSH session from <address>, which is outside -AllowFrom (...)` from `Install-OpenSSHServer.ps1` | The firewall limit would shut out the session it runs in, at its next sign-in | Add that address, or its network, to `-AllowFrom`; or run the script at the console or over WinRM |
| `Password sign-in stays on: <reason>` in the summary of `Install-OpenSSHServer.ps1` | It turns password sign-in off only when a key sshd can read is in `administrators_authorized_keys`, the file is limited to Administrators and SYSTEM, and nothing in `sshd_config` stops administrators from signing in with a key. The reason names the one that failed | Put that right (give a key with `-PublicKey` or `-PublicKeyFile`, or change the `sshd_config` line it names), then run it again |
| `Group Policy manages the <profile> firewall profile and ignores local rules` from `Install-OpenSSHServer.ps1` | The local OpenSSH rules have no effect in that profile. With `-AllowFrom` the run fails, because the limit is not in force | Set the limit for port 22 in that Group Policy |
| `-AllowFrom is required. Without it, every computer where this GPO installs OpenSSH Server accepts TCP 22 from ANY address ...` from `Deploy-OpenSSH-GPO.ps1` | No networks were given | Give the networks the admins and the tool connect from, or add `-AllowFromAnyAddress` if any address is really meant |
| `-TargetOU '<ou>' is the domain root ...`, `<n> domain controller(s) are under -TargetOU ...`, or `'<name>' is linked to another OU as well ...` from `Deploy-OpenSSH-GPO.ps1` | The GPO would reach more computers than one OU of connectors | Give an OU that holds only the connectors, and one `-GpoName` per OU. Add `-AllowDomainRoot`, `-AllowDomainControllers` or `-AllowOtherLinks` only if that is really meant |
| `Not confirmed. Nothing was changed.` or `This run has no terminal to type YES in ...` from `Deploy-OpenSSH-GPO.ps1` | Only `YES`, in capitals, goes on; a run with no terminal cannot be asked | Type `YES`, or add `-Yes` for an unattended run |
| A connector has no sshd after `Deploy-OpenSSH-GPO.ps1` | A computer startup script runs only while the computer starts; `gpupdate` alone does not run it | Restart the connector. Then, elevated on it, run `gpresult /r /scope computer`. The GPO must be listed under Applied Group Policy Objects. Filtered out as Not Applied (Empty): its computer version is 0, so run the script again. Denied (Security): the GPO's security filtering leaves the computer out. Not listed: the computer is not in `-TargetOU`, or has not read its policy since. Listed, but no log in `C:\ProgramData\ssh\logs`: the startup wrapper ran nothing. Either its files had not reached that domain controller yet, and a later restart catches up, or its settings file could not be read or names no key: run `Deploy-OpenSSH-GPO.ps1` again |

To repair a host key file that sshd refuses, in an elevated Windows PowerShell window on the server, for each `ssh_host_*_key` file (without `.pub`). `EXAMPLE\admin` stands for the account that ran `ssh-keygen -A`, which `icacls <file>` shows among the file's permissions:

```
$f = 'C:\ProgramData\ssh\ssh_host_ed25519_key'
icacls $f /setowner "NT AUTHORITY\SYSTEM"
icacls $f /remove "EXAMPLE\admin"
icacls $f /inheritance:r /grant SYSTEM:F /grant Administrators:F
Restart-Service sshd
```

## Things not to do

- Do not run a silent `msiexec /i {product code} REMOVE=KerberosAuthService /qn` to remove a service. It fails and blanks settings the connector saved at install time. Use `Services` plus `-ForceReinstall`.
- Do not delete `C:\ProgramData\AccessConnectorUpdate\KeytabBackup` or `CertBackup` while you might still need to go back.
- Do not print or paste the `Adding AW... property` lines of an `AccessConnector_MSI_*.log` that the tool has not cleaned. They can hold encoded passwords.
- Do not run two runs against the same connector at once, and do not replace the scripts in a staging folder during a run.
- Do not upgrade PowerShell 7 over an SSH session that starts pwsh. It ends the session and can stop the install half-way.
- Do not restart a computer while it installs OpenSSH Server. The restart stops the install.
