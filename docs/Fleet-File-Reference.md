# Fleet File Reference

The fleet file is a PowerShell data file (`.psd1`) in the `FleetDeploy` folder. It lists the tenants, their connectors and the files to install. It holds no passwords.

There are two ways to write it:

- **By hand:** copy `FleetDeploy/fleet.example.psd1` and edit it. The settings are described below.
- **From a spreadsheet:** fill in one row per connector in Excel or a CSV file and let `-ImportFleet` check it and write the fleet file. See [Building the fleet file from a spreadsheet](#building-the-fleet-file-from-a-spreadsheet). For connectors that are already installed, `-Mode Discover` writes a first draft of that spreadsheet: see [Discovering existing connectors](#discovering-existing-connectors).

## Which file is used

First match wins:

1. `-FleetConfig <path>` (a relative path is taken from the current folder)
2. `-Fleet <name>`, which means `fleet.<name>.psd1` beside the script
3. `fleet.<this computer name>.psd1`
4. `fleet.<this computer domain>.psd1` (Windows, or where `USERDNSDOMAIN` is set)
5. `fleet.psd1`

This lets one shared folder serve several admin machines or domains: give each its own file and the right one is picked up automatically. The plan printed at the start of every run names the file in use and why.

## Top-level settings

| Setting | Required | Meaning |
|---|---|---|
| `StagingRoot` | No | Folder that holds the installer, configuration files, certificates and the `Silent Install` folder. Default: the parent of the `FleetDeploy` folder. Leaving it out lets the same file work from macOS (`/Volumes/...`) and Windows (`\\server\share\...`). |
| `StagingFolders` | No | Other places a copy of the staging folder may live. Used only to give a helpful message when a tenant's files are missing from the copy you ran from. An entry without a drive or server is tried below every mounted volume (macOS) or drive (Windows); a full path is tried as written. |
| `CentralLogRoot` | No | Where the summary CSV and copied logs go. A relative path is relative to the staging root. Default: `FleetLogs` beside the script. |
| `InstallScript` | Yes for installs | Path to `Install-AccessConnector.ps1`, relative to the staging root. Normally `'Silent Install\Install-AccessConnector.ps1'`. |
| `JavaPatchDir` | No | Folder holding the vendor `Java4shellPatch.bat` (Omnissa HW-283446, for connector 26.05 and 26.10). When set, the patch is run after each install and the health check requires every connector Java process to carry the patch flag. Leave it out for versions that do not need the patch. |
| `Tenants` | Yes | The list of tenant entries. |

All relative paths use the staging root. Backslashes are fine on every platform.

## Tenant entries are connector groups

Each entry in `Tenants` is a **connector group**: a set of connectors that get the same installer, configuration file, services and certificate. The list is called `Tenants` because the usual case is one group per Access tenant, but an Access tenant can have as many groups as you need, and a group can hold a single connector.

| You want | Fleet file |
|---|---|
| The same services on every connector of a tenant | One entry listing all of them |
| A few connectors with different services | A second entry with the same `ConfigFile`, its own `Name` and `Services`, listing those connectors |
| One connector with different services | An entry of its own, with that one connector in `Connectors` |
| To act on one server without changing any of this | `-Connector <host>` on the command line. It limits the run; the services still come from the server's entry. |

Rules:

- `Name` must be different for every entry. It is what `-Tenant` selects.
- List each connector in one entry only.
- Entries of the same Access tenant use the same `ConfigFile`. An entry with Kerberos Auth also needs `Pfx` and `ServiceAccount`; one without it should leave `Pfx` out.
- Entries run top to bottom and connectors one at a time inside each, so a plain run never has two connectors down together. `-ParallelTenants` runs entries side by side, including two entries of the same Access tenant.
- To change the services on an installed connector, put it in an entry with the services you want and run with `-ForceReinstall`.

A worked example is in Getting Started, section 11.

## Tenant entry settings

| Setting | Required | Meaning |
|---|---|---|
| `Name` | Yes | Your label for this connector group. Must be unique in the file. Used with `-Tenant`, on screen and in log names. Need not match the Access tenant name. |
| `Installer` | Yes | The connector installer to run. This sets the version that is installed. |
| `InstallerVersion` | No | The version of that installer, for example `'26.10.0.0'`. Passed to the wrapper's version gate. When left out, the wrapper reads the version from the installer's file name or file properties. |
| `ExpectVersionPrefix` | No | Health check: the run is `Unhealthy` unless the installed version starts with this, for example `'26.10'`. |
| `ConfigFile` | Yes | The tenant's `es-config.json`. |
| `Services` | Yes | Comma-separated list of services to install: `DirectorySyncService`, `UserAuthService`, `KerberosAuthService`, `VirtualAppService`. |
| `ServiceAccount` | With Kerberos Auth or Virtual App | The domain account those services run as, `DOMAIN\name`. Its password is asked at run time. |
| `Pfx` | With Kerberos Auth | The PFX the Kerberos Auth service presents. One file for all connectors in the entry, so its certificate must name each of them. Without it the installer makes a self-signed certificate. |
| `TrustStore` | No | Folder of CA certificates. Only `.pem`, `.cer` and `.crt` files are copied. |
| `Syslog` | No | Syslog target as `host:port`. |
| `ForceReinstall` | No | `$true` makes every run of this entry uninstall and reinstall a connector already on the installer's version. Usually left `$false` and given on the command line when wanted. |
| `Connectors` | Yes | The servers, in the order they are done. |

### Installer settings (optional)

Leave any of these out to get the installer's default. They apply to every connector in the entry, on a clean install and on an upgrade (the vendor asks for custom settings to be supplied again at upgrade time).

| Setting | Meaning |
|---|---|
| `InstallDir` | Folder the connector is installed under, as a full Windows path, for example `'D:\Program Files'`. The connector goes in `<InstallDir>\Access Connector`. Default `C:\Program Files`. An installed connector is not moved by an upgrade; the run warns when this names a different folder. |
| `EnableFips` | `$true` installs in FIPS mode (Omnissa Access FedRAMP tenants only). FIPS mode cannot be changed after install, so a run whose setting differs from the installed connector's is refused (`Blocked`). |
| `DirectorySyncPort` | Directory Sync port. Default 8080. |
| `UserAuthPort` | User Auth port. Default 8090. |
| `KerberosAuthPort` | Kerberos Auth port, the only inbound one. Default 443. |
| `VirtualAppPort` | Virtual App port. Default 8008. |
| `ProxyHost` | Outbound proxy name or address. Setting it turns the proxy on. |
| `ProxyPort` | Proxy port. Needs `ProxyHost`. |
| `ProxyUser` | Proxy account; makes the proxy authenticated. Needs `ProxyHost`. Its password is asked at run time and must not contain a double quote. |
| `NonProxyHosts` | Hosts reached directly, separated by `\|`, for example `'host1.example.local\|host2.example.local'`. Needs `ProxyHost`. |

Known limitation: `-Mode RepairCertificate`, and the certificate step at the end of an upgrade, refuse connectors in FIPS mode or with a proxy account (`ProxyUser`), because the vendor script they use would clear the stored proxy password. For those connectors, a Kerberos upgrade ends `Unhealthy` with a message saying the certificate was not changed; put the certificate back with the installer's Add/Remove Services.

### Connector settings

| Setting | Required | Meaning |
|---|---|---|
| `Host` | Yes | The server's DNS name, as you would type it for SSH or remoting. |
| `SshUser` | No | SSH account for this server. Default `administrator`. `-SshUser` on the command line overrides it for the whole run. |

## Rules of thumb

- **Order matters.** Tenants run top to bottom and connectors top to bottom. Put the connector you can best afford to lose first.
- **Two connectors per tenant** means one stays online during the run.
- **Different services for one connector or a few:** give them an entry of their own with the same `ConfigFile` and a different `Name` and `Services`. See "Tenant entries are connector groups" above.
- **A new connector version:** add the installer, change `Installer`, `InstallerVersion` and `ExpectVersionPrefix`. Nothing else changes.
- **Several domains or shares:** one fleet file per domain (`fleet.<domain>.psd1`), each in the copy of the staging folder that holds that domain's files, and list the copies under `StagingFolders`.

## Checks made on the fleet file

Before anything is contacted, the tool confirms that:

- every tenant named with `-Tenant` exists;
- at least one connector is selected;
- `Installer`, `ConfigFile` and `Services` are present for each selected tenant;
- every file and folder named exists under the staging root (`Installer`, `ConfigFile`, `TrustStore`, `Pfx`, `InstallScript`, and `Java4shellPatch.bat` when `JavaPatchDir` is set);
- the installer settings are valid: ports are numbers from 1 to 65535 and no two services share one, `EnableFips` is `$true` or `$false`, `InstallDir` is a full Windows path, the proxy settings have a `ProxyHost` and hold no spaces or double quotes.

A setting the tool does not know (a misspelling such as `ProxyHots`) is named in a note before the plan, and ignored.

If files are missing, the message lists each one. When another copy of the staging folder has them, it names that copy and the `cd` command to use.

A tenant that installs Kerberos Auth without a `Pfx` gets a note that the installer will use a self-signed certificate.

## Building the fleet file from a spreadsheet

`-ImportFleet <file>` reads a spreadsheet with one row per connector, checks it, and writes the fleet file from it. No connector is contacted and nothing else runs. Excel is not needed on the admin machine: an `.xlsx` file is read directly.

```powershell
# Check the spreadsheet and show what would be written. Nothing is written.
pwsh ./Invoke-AccessConnectorUpgrade.ps1 -ImportFleet ./fleet.xlsx -DryRun

# Write the fleet file
pwsh ./Invoke-AccessConnectorUpgrade.ps1 -ImportFleet ./fleet.xlsx
```

An empty value (`-ImportFleet ''`, or a variable that holds nothing) stops at once with `-ImportFleet needs the name of a spreadsheet file (.xlsx, .csv, .txt or .tsv).`, and nothing else runs. A file that does not exist stops with `Spreadsheet not found: <file>`.

Start from one of the templates in `FleetDeploy`, or from the draft that `-Mode Discover` writes (next section):

| Template | Notes |
|---|---|
| `fleet.example.xlsx` | Three sheets: `Fleet` (the rows, first), `Columns` (what each column means) and `Read me`. Every cell of `Fleet` is formatted as Text, so Excel keeps `26.10` as typed. The import reads the first sheet that is not hidden, so keep `Fleet` first. |
| `fleet.example.csv` | The same rows as a CSV file. Excel does not keep a Text format in a CSV file: once you have opened it in Excel, carry on in an `.xlsx` copy. |

The example rows mean the same as the two groups in `fleet.example.psd1`. Replace them with your own and save your copy under a name of its own, for example `fleet.xlsx` in `FleetDeploy`, not over the template: `fleet.example.xlsx` and `fleet.example.csv` are part of the repository. Your copy holds site details (see [Security](Security.md)).

### File types

| File | How it is read |
|---|---|
| `.xlsx` | The first worksheet in the workbook's own order (the leftmost tab) that is not hidden, whatever its name. Hidden sheets in front of it are passed over and named in a note (`hidden sheet(s) before it passed over: '<name>'`), and the plan says which sheet was read, for example `(xlsx, sheet 'Fleet' of 3)`. The header is the first row that is not empty. Text, formula results (the value Excel last calculated), `TRUE`/`FALSE` and numbers are read. Cells are placed by their own references, so empty rows and columns in between do no harm. A cell merged down one column (a group name over several rows, say) gives its value to each row of the merge. A cell holding an Excel error (`#REF!`, `#N/A` and so on) in a column the import reads is a problem. Dates are not expected; a number is passed through as written. A workbook saved with a password cannot be read. |
| `.csv`, `.txt`, `.tsv` | The encoding comes from the byte-order mark (UTF-8, UTF-16 LE or UTF-16 BE). Without one, UTF-16 is recognised by its zero bytes; otherwise the file is read as UTF-8, or as Windows-1252 when it is not valid UTF-8. The delimiter comes from a `sep=` first line when there is one (Excel's way of naming it), else from the header line: a tab if it has one, otherwise whichever of `;` and `,` it holds more of (comma on a tie). Lines may end in CRLF, LF or CR. Quoted fields may hold the delimiter, doubled quotes and line breaks. A cell holding an Excel error value as text (`#N/A`, `#REF!`, `#VALUE!`, `#DIV/0!`, `#NAME?`, `#NUM!`, `#NULL!`, `#SPILL!`, `#CALC!` and the other error values of newer Excel versions) in a column the import reads is a problem, as in an `.xlsx` file. A file with one of these extensions that is really a workbook is a problem that says so. |
| `.xls` and anything else | Refused: save it as `.xlsx` or `.csv`. |

### Columns

The templates and `-Mode Discover` use this order. The import finds columns by their header, so the order in your sheet does not matter.

```
Group, Host, SshUser, Installer, InstallerVersion, ExpectVersionPrefix, ConfigFile, Services,
ServiceAccount, Pfx, TrustStore, Syslog, ForceReinstall, InstallDir, EnableFips,
DirectorySyncPort, UserAuthPort, KerberosAuthPort, VirtualAppPort, ProxyHost, ProxyPort,
ProxyUser, NonProxyHosts, Notes
```

| Column | Applies to | Required | Notes |
|---|---|---|---|
| `Group` | The group | Yes, on every row | The connector group (fleet entry) the row belongs to. Becomes the entry's `Name`, which `-Tenant` selects. Letters, digits, `.`, `_` and `-`, starting with a letter or digit. The header `Name` or `Tenant` is also accepted. |
| `Host` | The connector | Yes, on every row | The server's DNS name or IPv4 address: letters, digits, `.`, `_` and `-`, starting with a letter or digit. The header `Connector` or `Server` is also accepted. |
| `SshUser` | The connector | No | As `SshUser` in the fleet file. Blank means `administrator`. No spaces, quotes, colons or slashes. |
| `Installer`, `ConfigFile`, `Services` | The group | Yes | As in the fleet file. |
| `ServiceAccount` | The group | With Kerberos Auth or Virtual App | `DOMAIN\name`. |
| `InstallerVersion`, `ExpectVersionPrefix`, `Pfx`, `TrustStore`, `Syslog`, `ForceReinstall` | The group | No | As in the fleet file. |
| `InstallDir`, `EnableFips`, the four `...Port` columns, `ProxyHost`, `ProxyPort`, `ProxyUser`, `NonProxyHosts` | The group | No | The optional installer settings, as in the fleet file. |
| `Notes` | The connector | No | Ignored by the import. For your own notes; `-Mode Discover` fills it. |

Headers:

- Case, spaces, underscores, hyphens and dots are ignored: `Service Account`, `service_account` and `SERVICEACCOUNT` all mean `ServiceAccount`.
- Ignored columns: `Notes`, any column whose header starts with `#` (use these for columns of your own), and a column with no header and no values.
- Any other header the tool does not know is a problem that names it, so a misspelt column is never dropped without a word.
- A header that looks like a password column (it contains `pass`, `pwd`, `secret`, `token` or `credential`) is a problem: "columns that hold passwords are refused; passwords are asked at run time". The values in that column are never shown.

### Rows and groups

- Each row is one connector. Rows with the same `Group` make one connector group. Groups are written in the order they first appear, and connectors in row order, which is the order a run does them in.
- Group names are compared without regard to case. A later row with `tenant1` joins the group `TENANT1`; it keeps the spelling of its first row, and a warning says so: `row <n> Group: 'tenant1' is taken as 'TENANT1' (row <m>); group names are not case-sensitive`.
- **A group setting is given once.** The first value in the group counts; the group's later rows may leave the cell blank or repeat the same value. A later row with a different value is a problem that names the group, the column, both values and both rows. Two values that mean the same (`yes` and `TRUE`, two spellings of one service list, `/` and `\` in a path, any case) are not a conflict. Connectors that need different settings go in groups of their own.
- Each group needs `Installer`, `ConfigFile` and `Services`, and `ServiceAccount` as well when `Services` includes Kerberos Auth or Virtual App.
- Blank rows are skipped. A row with values but no `Host` is a problem, and so is a `Host` that appears twice (in any case).
- Row numbers in messages are the spreadsheet's own. In a CSV file the header is row 1; in an `.xlsx` file they are the row numbers Excel shows.

An example. `connector2` takes every group setting from the row above it:

| Group | Host | Installer | ConfigFile | Services | ServiceAccount | Pfx |
|---|---|---|---|---|---|---|
| TENANT1 | connector1.example.local | Installers\Access-Connector-Installer.exe | Configs\tenant1-es-config.json | DirectorySync, UserAuth, KerberosAuth | EXAMPLE\svc-access | ChildCerts\connector.example.local.pfx |
| TENANT1 | connector2.example.local | | | | | |
| TENANT2 | connector3.example.local | Installers\Access-Connector-Installer.exe | Configs\tenant2-es-config.json | DirectorySync, UserAuth | | |

### Values

| Value | Accepted |
|---|---|
| `Services` | Names separated by commas, semicolons, `\|`, spaces or line breaks, so one service per line in the cell (Alt+Enter in Excel) is accepted too. Case does not matter, the word `Service` may be left off, and spaces inside a name are ignored: `DirectorySyncService`, `DirectorySync` and `Directory Sync` are the same; the Windows service name (`AccessDirectorySyncService`) is accepted as well. An unknown name is a problem. Repeats are dropped, and the fleet file lists the services in the order `DirectorySyncService,UserAuthService,KerberosAuthService,VirtualAppService`. |
| `ForceReinstall`, `EnableFips` | `TRUE` or `FALSE`, `yes` or `no`, `y` or `n`, `1` or `0`, `$true` or `$false`, in any case. Blank means not set. Anything else is a problem. |
| The four `...Port` columns, `ProxyPort` | Whole numbers, digits only. The range (1 to 65535) and two services on one port are checked as for a fleet file written by hand. |
| `InstallerVersion` | Two to four numbers separated by dots, such as `26.10.0.0`. |
| `ExpectVersionPrefix` | When `InstallerVersion` is also set, the version must equal the prefix or start with the prefix and a dot (`26.10.0.0` starts with `26.10`). |
| `Installer`, `ConfigFile`, `Pfx`, `TrustStore` | Relative to the staging folder. `/` is turned into `\` and a leading `.\` is removed. A drive letter, a `\\server` path or a leading `\` is a problem ("relative to the staging folder"), and so is a character a Windows path cannot hold (`"`, `*`, `?`, `<`, `>`, `\|`). |
| `ServiceAccount` | `DOMAIN\name`. |
| Any text | Spaces around it are trimmed. A cell holding `="26.10"` (a way of making Excel keep text as typed) is read as `26.10`. A line break is allowed only in `Services`; in any other cell it is a problem ("the cell holds a line break; put the value on one line"). |

### Problems and warnings

A **problem** stops the import, and nothing is written. A **warning** is shown as a `[note]` and the file is still written.

After the spreadsheet's own rules, the result goes through the checks a run makes on a fleet file's installer settings (ports, `EnableFips`, `InstallDir`, proxy settings). What they find is a problem too.

Warnings:

- `Pfx` is set for a group without Kerberos Auth. It is not used.
- `ServiceAccount` is set for a group with neither Kerberos Auth nor Virtual App. It is not used.
- A group installs Kerberos Auth without `Pfx`. The installer will make a self-signed certificate.
- A file or folder a group names (`Installer`, `ConfigFile`, `Pfx`, `TrustStore`) is not in the staging folder yet. These are shown together, as one note that lists each: `[note] Not in the staging folder yet (add them before a run):`. The files can be added later; a run stops until they are there.
- `ExpectVersionPrefix` is set alone and looks like `26.1`, or `InstallerVersion` looks like `26.1`: "Excel may have turned 26.10 into 26.1: format the column as Text and type it again". When `InstallerVersion` is set as well and the two disagree, the same hint comes with a problem instead.
- A `Group` is spelt in another case than on its first row (above).
- In an `.xlsx` file, hidden sheets were passed over (they are named).
- The existing fleet file has top-level settings the tool does not use: `[note] The existing fleet file has setting(s) the tool does not use, which the new file leaves out: <names>`.
- The existing fleet file has groups the spreadsheet does not hold: `[note] Replacing <file> removes <n> group(s) the spreadsheet does not hold: <names>. To keep them, add their rows to the sheet, or import into another file with -Fleet or -FleetConfig.`
- A group the spreadsheet keeps has a setting in the existing fleet file that the spreadsheet leaves blank: `[note] <group>: the current fleet file sets <settings>, which the spreadsheet leaves blank, so the new file will not. Fill the column to keep it.` A true/false setting that is false (`ForceReinstall = $false`, say) is not named. After `-Mode Discover` this names `ExpectVersionPrefix`, which discovery always leaves blank.

### Excel traps, and how the import handles them

| In Excel | What happens | What the import does |
|---|---|---|
| `26.10` typed in a cell formatted as General or Number | Excel stores the number 26.1 | Compares `ExpectVersionPrefix` with `InstallerVersion`, and warns about a lone prefix like `26.1`, with the hint to format the column as Text. The templates' `Fleet` sheet is formatted as Text already. |
| Saving as CSV with regional settings that use the comma as the decimal separator | Excel separates the fields with `;` | Finds the delimiter from the header line, or from a `sep=` first line |
| Saving as plain CSV rather than CSV UTF-8 | The file is in the computer's code page, not UTF-8 | Reads it as Windows-1252 when it is not valid UTF-8 |
| `TRUE` and `FALSE` | Excel writes yes/no values that way | Accepted |
| A whole number in an `.xlsx` cell | Stored as a number | Read without a decimal part (`8080`, not `8080.0`), whatever the admin machine's regional settings |
| `="26.10"` | A formula whose result is the text 26.10 | Read as `26.10` |
| A formula that fails (`#N/A`, `#REF!` and so on) | An `.xlsx` file holds an error cell; a CSV file holds the error's text | A problem naming the row and column: `row <n> <column>: the cell holds the Excel error #N/A; type the value in` |
| Alt+Enter inside a cell | The cell holds a line break | Accepted in `Services` (one service per line); a problem in any other column |
| A hidden sheet in front of `Fleet` | Not visible, but first in the workbook | Passed over and named in a note; the first visible sheet is read |
| A group name in merged cells | Only the top cell of the merge holds the value | Each row of the merge gets it |

### What -DryRun shows

`-ImportFleet <file> -DryRun` reads and checks everything and writes nothing. It shows:

- the spreadsheet and how it was read: the file type, then for an `.xlsx` file the sheet read and how many sheets the workbook has (`xlsx, sheet 'Fleet' of 3`), for a text file the delimiter and the encoding (`csv, delimiter ',', UTF-8 with BOM`);
- the fleet file it would write, as a full path, whether that is a new file or replaces an existing one (which is kept as a copy), and what chose it (`chosen by -FleetConfig`, `-Fleet <name>` or `the default file`);
- how many groups and connectors there are;
- for each group: its name and services; a line with its files and accounts (`installer <file> | config <file> | pfx <file> | account <account> | syslog <host:port> | trust <folder>`, only the ones set, files by name); a line with its installer settings when it has any, as in a run's plan; and its connectors, each with `(ssh as <account>)` when `SshUser` is set;
- the warnings, each as a `[note]`, with the files not yet in the staging folder together in one note; when an existing file would be replaced, these include the groups it would lose and, per group, the settings it would lose (above);
- the problems, if there are any: `The spreadsheet has <n> problem(s). Nothing was written:` and the list.

When there are none it ends `Dry run: the spreadsheet is usable. Nothing was written. Without -DryRun this writes <fleet file>.` Run it until it shows no problems, then run the same command without `-DryRun`.

### Where the fleet file is written

| Given | Written to |
|---|---|
| `-FleetConfig <path>` | That file. A relative path is taken from the current folder. |
| `-Fleet <name>` | `fleet.<name>.psd1` beside the script |
| Neither | `fleet.psd1` beside the script |

- The target is turned into a full path, which the plan shows.
- A `-FleetConfig` that names a folder, or a file in a folder that does not exist, stops the import before anything is read, with nothing written: `-FleetConfig names a folder: <path>. Name the fleet file, for example <path>/fleet.psd1. Nothing was written.` or `The folder for the fleet file does not exist: <folder>. Nothing was written.`
- `-Fleet` given together with `-FleetConfig` is named as ignored (`[ignored] -Fleet: -FleetConfig names the file directly.`); `-FleetConfig` names the file.

The choice by computer name or domain that a run makes is not used here. So when you give neither switch and `fleet.<this computer name>.psd1` or `fleet.<this computer domain>.psd1` exists beside the script, a run without `-Fleet` or `-FleetConfig` would pick that file, not the `fleet.psd1` just written. After writing, the import says so (`[note] A run without -Fleet or -FleetConfig uses <that file> beside this script, not the fleet.psd1 just written. Name the file as below, or rename it.`), and the next commands it shows name the file written with `-FleetConfig '<full path>'`.

The file has the layout and key order of `fleet.example.psd1`: a header comment saying which script and version wrote it, from which spreadsheet and when, and that no passwords belong in it; the top-level settings; then `Tenants`. Only settings with a value are written. It is saved as UTF-8 without a byte-order mark, with Windows line endings.

**When the file is new**, it gets `CentralLogRoot = 'FleetDeploy\FleetLogs'` and `InstallScript = 'Silent Install\Install-AccessConnector.ps1'`, and commented-out examples of `StagingRoot`, `StagingFolders` and `JavaPatchDir`. If your connector version needs the Java4Shell patch, remove the `#` in front of `JavaPatchDir`.

**When the file exists:**

- It must read as a fleet file; one that does not is not replaced (`The fleet file <path> exists but could not be read, so it is not replaced: ...`).
- Its top-level settings (`StagingRoot`, `StagingFolders`, `CentralLogRoot`, `InstallScript`, `JavaPatchDir`) are carried into the new file. Its `StagingRoot`, when set, is also the staging folder the import looks in for the files (otherwise the parent of the `FleetDeploy` folder). When that folder cannot be found, the files are not checked.
- Every group comes from the spreadsheet. A group in the old file that is not in the spreadsheet is not carried over, and neither is a setting of a kept group that the spreadsheet leaves blank. Notes name both before you are asked, and in the dry run (see the warnings above).
- When it holds groups, you are asked to type `YES` before it is replaced. `-Yes` answers for you. A run that is not interactive and has no `-Yes` stops with `Not interactive: add -Yes to confirm replacing the fleet file. Nothing was written.` Anything but `YES` stops with `Not confirmed. Nothing was written.` A file that holds no groups, such as the one a partial Discover starts, is replaced without asking, because there is nothing in it to lose; it is still copied first, as below.
- The old file is then copied to `<file>.bak-<yyyyMMdd_HHmmss>` beside it. If a file of that name exists already (two imports in the same second), `-1`, `-2` and so on is added: `<file>.bak-<yyyyMMdd_HHmmss>-1`. A copy is never overwritten, and never deleted.

The new file is written beside the target under a temporary name (`<file>.importing`) and then moved into place, so a write that fails leaves the old file as it was.

After writing, the tool reads the file back as a run would and compares it with what the spreadsheet said. Any difference is an error (`The written fleet file does not read back as intended: ...`); when a file was replaced, the previous one is put back from the copy, which is kept.

At the end it names the file written and the backup, and gives the next commands: `-Mode Verify`, then `-Tenant <first group> -DryRun`. They carry `-FleetConfig '<full path>'` when the file was named with `-FleetConfig` (or when the note above applies), `-Fleet <name>` when it was named with `-Fleet`, and neither when it is `fleet.psd1` chosen by default.

With `-AuditLog`, an import writes one line with `mode=ImportFleet` and `stage=import` (`stage=import-dryrun` for a dry run), the number of connectors, the spreadsheet and the fleet file written, and the backup's name when one was made. An import that stops writes `outcome=FAILED` with the reason.

## Discovering existing connectors

`-Mode Discover` reads the current settings of connectors that are already installed and writes them as a draft spreadsheet (CSV) in the same columns as the import. You complete it and import it. Nothing is changed on the connectors and nothing is copied to them.

```powershell
# Connectors named on the command line
pwsh ./Invoke-AccessConnectorUpgrade.ps1 -Mode Discover -Connector connector1.example.local,connector2.example.local

# Every connector in the fleet file in use, or only those of some groups
pwsh ./Invoke-AccessConnectorUpgrade.ps1 -Mode Discover
pwsh ./Invoke-AccessConnectorUpgrade.ps1 -Mode Discover -Tenant TENANT1
```

| | |
|---|---|
| Which connectors | With `-Connector`: those hosts. They need not be in a fleet file. A host that is in the fleet file in use is matched with its entry, whatever group it is in, and `-Tenant` has no effect: it is named as ignored (`[ignored] -Tenant: -Connector names the hosts to read. Each is still matched with its fleet entry, whatever group it is in.`). Without `-Connector`: every connector in the fleet file in use, or only those of the groups named with `-Tenant` (an unknown name stops the run). A connector that is in the fleet file has its entry's `Name` suggested as its `Group`, and its entry is compared with what is found. |
| Which fleet file | Chosen as for any run (see [Which file is used](#which-file-is-used)). A missing fleet file is allowed only with `-Connector` and neither `-Fleet` nor `-FleetConfig`; the plan then says `none: hosts named with -Connector`. A fleet file named with `-Fleet` or `-FleetConfig` that does not exist stops the run, `-Connector` or not. The staging folder whose file names are matched is the fleet file's `StagingRoot`, else the parent of the `FleetDeploy` folder. |
| How it connects | SSH, with the same key, account and `-SshUser` rules as the other SSH modes. No password is asked. |
| What it writes | `fleet.discovered_<yyyyMMdd_HHmmss>.csv` beside the script, or the file `-ExportCsv <path>` names. When `-ExportCsv` names a folder (one that exists, a path ending in `/` or `\`, or a path with no file extension), the file gets the dated name in that folder. A relative path is taken from the current folder. Before any connector is read, the run stops if that file exists already (it is never overwritten). A folder that does not exist is made, as for `-AuditLog` and `-ErrorLog`; one that cannot be made stops the run (`The folder for the draft spreadsheet could not be made: <folder> (<reason>). Nothing was read.`). After a partial read (next row) it also writes a new fleet file. |
| On screen | The plan: the fleet file and why it was chosen, what is read, the file to be written, and each host with its group (`(new)` for one not in the fleet file). Then a line per connector with what was found (version, services, tenant, account). Items the script could not read on the connector are added to that line as `not read: ...`, as a warning. A connector that could not be reached is shown as an error, `<host>: not reached: <reason>`, followed by `Hint: ...` when SSH's reason suggests one (a key that was not accepted, a changed host key, a name that does not resolve, a port that is not reachable, too many keys offered); it still gets a row, with an empty `Group` and the reason in `Notes`. At the end: the CSV file, how many rows need values filled in (rows with a `fill:` note or no `Group`), and the next commands. |
| Next commands | `-ImportFleet <the CSV file> -DryRun`, then the same without `-DryRun`, with the fleet file to write. After a full read of a fleet file: that file, `-Fleet <name>` when `-Fleet` was used, else `-FleetConfig '<full path>'`. Importing into it replaces its groups after you type `YES`, keeps the old file as a copy, and names every group, connector and setting it would lose (a group Discover split off as `<entry>-2` is compared with `<entry>`). A read is partial only when `-Tenant` or `-Connector` left some of the fleet file's connectors out; A connector that could not be reached still counts as read: its row says `not reached` and has no `Group`. Do not delete such a row before importing into the whole file: that removes the connector from it (the import's note names it). Fill it in by hand, or run Discover for the whole file again once the connector answers; naming every one of its hosts with `-Connector`, or choosing every group with `-Tenant`, is a full read. After a partial read, Discover itself writes a new fleet file `fleet.discovered_<yyyyMMdd_HHmmss>.psd1` in the fleet file's folder, holding those of the original's top-level settings it sets (`StagingRoot`, `StagingFolders`, `CentralLogRoot`, `InstallScript`, `JavaPatchDir`) and no groups, and the commands name it as `-FleetConfig '<full path>'`, with the warning `Only part of <fleet file> was read (<n> of its connectors left out), so the commands below import this draft into a new fleet file, <new file>, which holds the original's top-level settings and no groups yet. Importing it into <fleet file> would replace that whole file and drop the groups the draft does not hold.` Importing into that new file needs no `YES`, because it holds no groups, and carries its top-level settings over, so the Java4Shell patch folder and a custom staging root are kept. With no fleet file: neither switch (the import then writes `fleet.psd1`). |
| Exit code and audit log | Exit code 1 when any connector was not reached (the CSV file is still written), else 0. With `-AuditLog`: one line with `mode=Discover`, `stage=discover`, the number of connectors, how many were not reached and the file written; `outcome=FAILED` when any was not reached. |

The CSV file is UTF-8 with a byte-order mark (so Excel reads it correctly), comma-separated, with every field quoted, the header in the order above and Windows line endings. Where the regional settings use `;` as the list separator, Excel does not split a comma-separated file when it opens it, and each row lands in one cell: open it with Data > From Text/CSV instead, and choose the comma as the delimiter.

### What is read, and what leaves the connector

The script on the connector looks only at the places below, and sends back only what the second column names. It writes nothing on the connector.

| Where | Sent back | Not sent back |
|---|---|---|
| Windows | The computer name and its DNS name | |
| The installer's uninstall entries | The installed version and install location of the entry named `Access Connector` (each entry's display name is read to find it) | Anything else in those entries |
| The four connector services | Whether each is installed, its name, its state and the account it runs as | The service's program path, which is used on the connector only to find the install folder |
| The install folder | The folder the connector was found in: from the uninstall entry or a service's program path, else the default | |
| `HKLM\SOFTWARE\Omnissa\Access Connector` | `WS1_SYSLOG_HOSTNAME`, `IS_NET_API_LOGON_USERNAME`, `InstallDir` and `WS1_INSTALLED_SERVICES`, each read by name | No other value is read: the key's values are never listed, and no value whose name contains `PASS` is read. |
| `<install folder>\Support\scripts\install.properties` | The lines whose name is `INSTALL_DIR`, `TENANT_URL`, `TRUST_CERTS`, `SYSLOG_CONFIGURATIONS`, `PROXY_HOST`, `PROXY_PORT`, `PROXY_USER`, `NON_PROXY_HOSTS`, `FIPS_ENABLED`, `DIRECTORY_SYNC_SVC_PORT`, `USER_AUTH_SVC_PORT`, `KERBEROS_AUTH_SVC_PORT` or `VIRTUAL_APP_SYNC_SVC_PORT` | The file is read line by line, and each line's name is checked before anything is kept. The value of every other line, the client secrets (`*_CLIENT_SECRET`) and the PFX password (`SSL_CERT_PASS`) that the same file holds included, is never kept, compared or sent back. |
| The four service definition files (`<service>.xml`) | Whether the Java4Shell patch flag (`UseBASE64Intrinsics`) is present | Anything else in them |
| Kerberos Auth `conf\application.properties` | The port number from its `eks.http.server.port` line (443 when there is none) | Every other line, including the keystore's encrypted password, is passed over and not kept |
| The Kerberos Auth service, when it is running | The certificate it serves, read by a TLS handshake on the connector to its own port: the port, subject, DNS names, issuer, end date, and whether it is the installer's self-signed one; or the handshake's error message | The keystore, the private key and the keytab are not read |
| Anything that failed | A short reason per item (the item's name and the error's message, the message cut to 200 characters), which becomes the `not read on the connector` note | |

On the admin machine, the file names in `Installers`, `Configs`, `ChildCerts` and `TrustedCerts` of the staging folder are read. The contents of those files are not: the es-config files are matched by name and never opened.

### How each column is filled

| Column | From |
|---|---|
| `Group` | The fleet entry's `Name`, for a connector listed in the fleet file in use. Otherwise the first part of the tenant's host name in `TENANT_URL`, in capitals, with anything but letters and digits turned into `-` (`https://tenant1.us1.example.com` gives `TENANT1`). Otherwise `GROUP`. Rows that would share a `Group` but differ in any group setting are split, because a group setting can have one value only: the row or rows closest to the fleet entry (fewest columns in their `differs from fleet entry` note) keep the name, and the others get `-2`, `-3` and so on. Among rows that are equally close, and for connectors not in the fleet file, the first in the sheet keeps the name. The rows stay in their order. Settings that differ only in upper and lower case do not split a group, because Windows account and host names ignore case. |
| `Host` | The name the connector was reached by |
| `SshUser` | `-SshUser` if given, else the connector's `SshUser` in the fleet file, else blank |
| `Installer`, `InstallerVersion` | When `Installers` in the staging folder holds exactly one `.exe`: that file, and the last version number in its name, written with four parts. Otherwise blank, or taken from the fleet entry (below), where `InstallerVersion` is also written with four parts (`26.10` becomes `26.10.0.0`), so Excel keeps it as text. |
| `ExpectVersionPrefix` | Always blank, also for a connector in the fleet file, because Excel would turn `26.10` into `26.1` when it opens the CSV file. Type it in a Text-formatted cell of an `.xlsx` copy if you want it. |
| `ConfigFile` | Matched by file name in `Configs` (below). Otherwise blank, or taken from the fleet entry. |
| `Services` | The services installed, in the usual order |
| `ServiceAccount` | Only when Kerberos Auth or Virtual App is installed: the account recorded by the installer (`IS_NET_API_LOGON_USERNAME`), else the account the Kerberos Auth or Virtual App service runs as, when it is `DOMAIN\name` |
| `Pfx` | Only with Kerberos Auth serving a certificate that is not the installer's self-signed one: the one `.pfx` in `ChildCerts` whose name (without `.pfx`) is the certificate's subject or one of its DNS names, in any case. Otherwise blank, or taken from the fleet entry when Kerberos Auth is installed. |
| `TrustStore` | Only when the connector was installed with trusted certificates (`TRUST_CERTS` is not empty). For a connector whose fleet entry sets `TrustStore`, the entry's folder: it wins over the generic `TrustedCerts`. Otherwise `TrustedCerts`, when that folder in the staging folder holds at least one `.pem`, `.cer` or `.crt` file. Otherwise blank. |
| `Syslog` | `WS1_SYSLOG_HOSTNAME`, else `SYSLOG_CONFIGURATIONS` |
| `InstallDir` | `INSTALL_DIR` without its `\Access Connector\` ending; blank when that is `C:\Program Files` (the default) |
| `EnableFips` | `TRUE` when `FIPS_ENABLED` is `true`; otherwise blank |
| The four `...Port` columns | Only a port that differs from the default (8080, 8090, 443, 8008) |
| `ProxyHost`, `ProxyPort`, `ProxyUser`, `NonProxyHosts` | From `install.properties`, when `PROXY_HOST` is not empty |
| `ForceReinstall` | Always blank |

For a connector in the fleet file, a group setting found on the connector that equals the entry's except for upper and lower case is written with the entry's spelling.

#### Matching the es-config file

The connector does not record which es-config file it was installed with, so `ConfigFile` is matched by name against the `.json` files in `Configs`, using the tenant's host name from `TENANT_URL` (for `https://tenant1.us1.example.com`, `tenant1.us1.example.com`). Case does not matter, and no file is opened.

1. A file whose name holds the tenant's full host name, not as part of a longer name: the character before it and the one after it may not be a letter, a digit or a dot (a hyphen or an underscore may be there). `tenant1.us1.example.com-es-config.json` and `es-config_tenant1.us1.example.com.json` match; `dev.tenant1.us1.example.com-es-config.json` does not. Exactly one file must match.
2. Only when no file matches that way: a file whose name holds the tenant's first name part (`tenant1`) as a whole word, such as `tenant1-es-config.json`, and holds no dotted name at all: a dot followed by a letter anywhere in the name other than the `.json` extension (`tenant2.example`, `es-config.old`) rules the file out, so a file named after another tenant's full host name is never taken. Exactly one file must match. `Notes` then says `ConfigFile matched by the tenant's first name part only (tenant1): check it`.

Otherwise `ConfigFile` is blank.

#### What is taken from the fleet entry

For a connector listed in the fleet file in use, a column that discovery left blank is taken from the connector's fleet entry, and `Notes` says `taken from fleet entry <Name>: <columns>`:

| Column | Taken when it is blank and |
|---|---|
| `Installer` | always |
| `InstallerVersion` | the row's `Installer` is the entry's `Installer`. Written with four parts (`26.10` becomes `26.10.0.0`). |
| `ConfigFile` | always |
| `Pfx` | Kerberos Auth is installed |
| `TrustStore` | the connector was installed with trusted certificates (`TRUST_CERTS` is not empty). An entry's own `TrustStore` is used even when `TrustedCerts` in the staging folder holds certificates. |

`ExpectVersionPrefix` is never taken (see above). Every other column comes from the connector only; where it differs from the entry, the `differs from fleet entry` note says so.

### The Notes column

What was found and what to do, joined with `; `, in this order:

| Note | Meaning |
|---|---|
| `installed <version>` | The version on the connector |
| `no Access Connector found` | No uninstall entry and no connector service was found |
| `tenant <host>` | The Access tenant it is registered with |
| `fill: <columns>` | Required columns that are still blank: `Installer`, `ConfigFile`, `Services`, and `ServiceAccount` when Kerberos Auth or Virtual App is installed. The import refuses the row until they are filled in. Optional columns are never listed here. |
| `set Pfx if a PFX is used: without one the installer makes a self-signed certificate` | Kerberos Auth is installed and no PFX was matched or taken from the fleet entry. Left out when the self-signed note below is given. |
| `the connector trusts extra CA certificates: set TrustStore` | The connector was installed with trusted certificates, but `TrustStore` could not be filled |
| `ConfigFile matched by the tenant's first name part only (<label>): check it` | The es-config file was found by step 2 of the match above |
| `not read on the connector: <item>: <reason>` | Items the script on the connector could not read, each with its reason, joined with ` / ` |
| `taken from fleet entry <Name>: <columns>` | These columns came from the connector's fleet entry, not from the connector or the staging folder |
| `Java4Shell patch flag present: set JavaPatchDir in the fleet file` | The connector carries the patch; set `JavaPatchDir` so that upgrades apply it again. Left out when the fleet file in use sets `JavaPatchDir` already: the file the next commands import into keeps it (that fleet file after a full read, the new file after a partial one). |
| `Kerberos Auth serves the installer's self-signed certificate: set Pfx, then run -Mode RepairCertificate` | The PFX certificate is not on the service, so `Pfx` cannot be matched by it |
| `Kerberos Auth certificate not read: <reason>` | The TLS handshake to the Kerberos Auth service did not succeed |
| `Kerberos Auth is not running, so its certificate was not read` | As it says |
| `differs from fleet entry <Name>: <columns>` | What the connector has is not what its fleet entry says, in these columns. Compared: `Services`, `ServiceAccount`, `ConfigFile`, `Pfx`, `TrustStore` (whether one is used), `Syslog`, `InstallDir`, `EnableFips`, the ports and the proxy settings, each only when the connector showed it. Differences of upper and lower case do not count. Decide which is right. |
| `not reached: <reason>` | The connector could not be read. The row has only `Host`, `SshUser` and this note; `Group` is blank. |

### What you still fill in

- **`Installer`**, when `Installers` holds no installer or more than one and the connector is not in the fleet file, and `InstallerVersion` with it if you use it.
- **`ConfigFile`**, when no single es-config file in `Configs` matches the tenant by name (see above) and the connector is not in the fleet file. Check a file matched by the tenant's first name part only.
- **`Pfx`**, for Kerberos Auth groups, when the certificate served is the installer's own, the service was not running, or no single PFX in `ChildCerts` is named after the certificate, and the fleet entry gives none. The connector does not record which PFX it was installed with.
- **`TrustStore`**, when a note says the connector trusts extra CA certificates.
- **`ExpectVersionPrefix`**, if you want the version health check.
- **The `Group` names**: check them, especially any with `-2` or `-3` added, and rename them as you like.
- **Rows marked `not reached`**: fix the connection and run Discover again, or fill the row in by hand (its values are in the fleet file). Deleting the row removes that connector from the fleet file the draft is imported into; the import's note names it.
- **`JavaPatchDir`** in the fleet file, when a note says the patch flag is present.

Then import the file, with `-DryRun` first, as the commands at the end of the run show:

```powershell
pwsh ./Invoke-AccessConnectorUpgrade.ps1 -ImportFleet ./fleet.discovered_20270115_093000.csv -DryRun
```

The commands also carry `-FleetConfig` or `-Fleet` for the fleet file to write (see Next commands, above); keep that part when you change the file name.

To add `ExpectVersionPrefix` or another version, save the file as an `.xlsx` workbook in Excel, format that column as Text, then type the values, and import the workbook: the same commands with its name in place of the CSV file's. In a CSV file Excel turns `26.10` into `26.1` again each time it opens the file.
