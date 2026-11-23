@{
    # Fleet definition for Invoke-AccessConnectorUpgrade.ps1.
    # Copy this file to fleet.psd1 (or fleet.<name>.psd1) and edit it.
    # NO PASSWORDS BELONG IN THIS FILE. They are asked for at run time.
    #
    # Which file is used (first match wins):
    #   -FleetConfig <path>, -Fleet <name> (fleet.<name>.psd1),
    #   fleet.<this computer name>.psd1, fleet.<this computer domain>.psd1, fleet.psd1

    # StagingRoot: the folder that holds Installers, Configs, ChildCerts, TrustedCerts
    # and 'Silent Install'. Leave it out to use the parent of this FleetDeploy folder,
    # so the same file works from macOS (/Volumes/...) and Windows (\\server\share\...).
    # All paths below are relative to the staging root.
    # StagingRoot = '\\fileserver.example.local\Deploy\AccessConnector'

    # StagingFolders (optional): where other copies of the staging folder live. When a
    # tenant's files are not in the copy the tool is run from, the error names the copy
    # that has them. A path without a drive or server is tried below every mounted
    # volume (macOS) or drive (Windows).
    # StagingFolders = @(
    #     'Deploy/AccessConnector'
    #     '\\fileserver.example.local\Deploy\AccessConnector'
    # )

    CentralLogRoot = 'FleetDeploy\FleetLogs'                 # summary CSV + logs copied back
    InstallScript  = 'Silent Install\Install-AccessConnector.ps1'

    # JavaPatchDir (optional): folder holding the vendor Java4shellPatch.bat (HW-283446,
    # for connector 26.05 and 26.10). Leave it out for versions that do not need it.
    JavaPatchDir   = 'Installers\Java4shellPatch'

    # Tenants run top to bottom; connectors inside a tenant run one at a time, in the
    # order listed, so a tenant with two or more connectors keeps one online.
    Tenants = @(
        @{
            # A tenant whose connectors run all four services, including Kerberos Auth.
            Name                = 'TENANT1'
            Installer           = 'Installers\Access-Connector-Installer.exe'   # the version to install
            InstallerVersion    = '26.10.0.0'      # optional: version of that installer
            ExpectVersionPrefix = '26.10'          # optional: health check on the installed version
            ConfigFile          = 'Configs\tenant1-es-config.json'
            TrustStore          = 'TrustedCerts'   # optional: folder of .pem/.cer/.crt files
            Pfx                 = 'ChildCerts\connector.example.local.pfx'      # Kerberos only
            Services            = 'DirectorySyncService,UserAuthService,KerberosAuthService,VirtualAppService'
            ServiceAccount      = 'EXAMPLE\svc-access'                          # Kerberos / Virtual App
            Syslog              = 'syslog.example.local:514'                    # optional
            ForceReinstall      = $false           # $true = same version: uninstall, then fresh install
            Connectors = @(
                @{ Host = 'connector1.example.local'; SshUser = 'administrator' }
                @{ Host = 'connector2.example.local'; SshUser = 'administrator' }
            )
        }

        @{
            # A tenant whose connectors run three services and no Kerberos: no Pfx.
            # Two entries may share one ConfigFile when connectors of the same Access
            # tenant need different services; give each entry its own Name.
            Name                = 'TENANT2'
            Installer           = 'Installers\Access-Connector-Installer.exe'
            InstallerVersion    = '26.10.0.0'
            ExpectVersionPrefix = '26.10'
            ConfigFile          = 'Configs\tenant2-es-config.json'
            TrustStore          = 'TrustedCerts'
            Services            = 'DirectorySyncService,UserAuthService,VirtualAppService'
            ServiceAccount      = 'EXAMPLE\svc-access'
            ForceReinstall      = $false
            Connectors = @(
                @{ Host = 'connector3.example.local' }                          # SshUser defaults to administrator
                @{ Host = 'connector4.example.local' }
            )
        }
    )
}
