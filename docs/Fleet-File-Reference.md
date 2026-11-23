# Fleet File Reference

The fleet file is a PowerShell data file (`.psd1`) in the `FleetDeploy` folder. It lists the tenants, their connectors and the files to install. It holds no passwords.

Start from `FleetDeploy/fleet.example.psd1`.

## Which file is used

First match wins:

1. `-FleetConfig <path>`
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
- every file and folder named exists under the staging root (`Installer`, `ConfigFile`, `TrustStore`, `Pfx`, `InstallScript`, and `Java4shellPatch.bat` when `JavaPatchDir` is set).

If files are missing, the message lists each one. When another copy of the staging folder has them, it names that copy and the `cd` command to use.

A tenant that installs Kerberos Auth without a `Pfx` gets a note that the installer will use a self-signed certificate.
