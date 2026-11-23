<#
.SYNOPSIS
    Silent install wrapper for the Omnissa Access Connector, with pre-flight
    validation and an audit trail.

.DESCRIPTION
    Builds and runs the Access Connector silent install command with a single
    parameterized call. Supply everything up front via switches for unattended
    runs, or omit the passwords and get secure prompts. Secrets are held as
    SecureString and converted to plaintext only where the installer requires it
    on the command line.

    Runs through Start-Process (never cmd.exe), so service account passwords
    containing cmd metacharacters ( & % ( ) ) pass cleanly - the failure mode a
    .bat/.cmd hits silently on Kerberos Auth installs.

    Pre-flight checks (run in both -DryRun and real installs):
      - PFX  : loads the Kerberos SSL PFX with the supplied password. A true,
               reliable offline correctness check - wrong password fails here.
      - Config: confirms es-config.json is valid JSON, is a real es-config
               (tenant + passwordHash present), the passwordHash is well-formed,
               and the supplied config password meets Omnissa's documented rules.
               It does NOT verify the password against the stored hash: the hash
               is an application-specific salted/peppered scheme with no published
               algorithm, so it cannot be reproduced offline. A rules violation is
               flagged as a definite wrong password; a rules pass is only a hint.
               The installer remains the sole authority on password correctness,
               and the output/audit log say so explicitly.

    -DryRun runs pre-flight and prints the constructed command, then stops. A
    real run aborts before launching the installer if pre-flight hard-fails.
    A dry run ALWAYS runs the pre-flight checks, also for a connector that a
    real run would skip (already on the installer's version) or refuse (newer
    than the installer), and then says so in a "DRY RUN note" line.

    Audit trail: every run writes a timestamped audit log to the log folder
    (see -LogPath), alongside the MSI verbose log. Errors are written to the
    screen and the audit log.

    Version handling: the installed connector version (from the uninstall
    registry) is compared to the installer version (from -InstallerVersion, or
    the installer filename, or file metadata). Older installed -> upgrade; same
    version -> skip by default (this installer has no supported silent
    reconfigure; a plain same-version run is a no-op, and forcing REINSTALL is
    destructive - it deletes and recreates the services and leaves them stopped);
    same version with -ForceReinstall -> uninstall then fresh-install, which
    reapplies certs/creds and lets the installer start the services; newer
    installed -> stop and log, no downgrade.

    Service control: the four connector services (AccessDirectorySyncService,
    AccessKerberosAuthService, AccessUserAuthService, AccessVirtualAppService)
    are explicitly stopped before the installer runs and started afterward, with
    per-service pass/fail logged. On a reboot-pending exit code, the explicit
    start is skipped (services start after the reboot).

    Paths: all path parameters are resolved to absolute before the installer
    runs. MSI custom actions execute as SYSTEM from C:\WINDOWS\Installer, so a
    relative path would resolve there and silently fail - the es-config import
    and truststore load in particular.

    Kerberos verification: after a successful install with KerberosAuthService,
    the script verifies three things - (1) krb5.keytab exists and is non-empty,
    (2) krb5-setup.log carries no failure signatures ('Password set failed' is
    the PowerShell 7 empty-password symptom; a non-zero RESULT code is a ktpass
    failure), and (3) the certificate the eks service actually presents on its
    port matches the provided PFX by thumbprint (catching the case where the
    installer's self-signed cert is active instead). If the keytab is missing,
    empty, or /eks/health reports it missing, the script generates it by running
    the UNMODIFIED vendor setupKerberos.ps1 under Windows PowerShell 5.1 (the
    engine it was written for - it fails under PowerShell 7), restarts the
    Kerberos service, and re-probes /eks/health expecting 'true'. When the
    first probe already returns 'true', the Kerberos service is restarted once
    and re-verified, confirming it comes back healthy from a clean start with
    the keytab and certificate loaded. Requires
    domain rights (create machine account, ktpass, setspn). Only the lines the
    vendor script added to krb5-setup.log during this run are judged (it
    appends on every run). The served certificate is read by a TLS handshake of
    its own, which works under Windows PowerShell 5.1. A mismatch after a fresh
    install is an error. After an UPGRADE it is expected: the installer does not
    carry a PFX through an upgrade and serves a certificate of its own, so it is
    reported as a warning; put the PFX back with the fleet tool's
    -Mode RepairCertificate (its upgrades do this by themselves).
    Suppress the whole step with -SkipKeytab.

    Conditional by design:
      - Service account (IS_NET_API_LOGON_*) is added only when Kerberos Auth
        or Virtual App is selected.
      - The Kerberos SSL PFX is added only when -SslCertPath is supplied.

    Note on the installer: passwords land on the process argument list at run
    time (a documented installer limitation - all silent passwords go on the
    command line). Run on a trusted host.

    Run with -Help for a per-item usage summary.

.PARAMETER Help
    Print the usage summary (what to type for each item) and exit.

.PARAMETER InstallerPath
    Full path or UNC to the versioned Access Connector installer .exe. Pick the
    build here - version selection is nothing more than pointing at a different exe.

.PARAMETER ConfigFilePath
    Path to the es-config.json downloaded from the Access console for this connector.

.PARAMETER Services
    Comma-separated list of enterprise services to install. Valid values:
    DirectorySyncService, UserAuthService, KerberosAuthService, VirtualAppService.

.PARAMETER ConfigFilePassword
    SecureString password for es-config.json. Omit to be prompted (masked).
    Allowed characters: letters, digits, and  @ ! , # $ { } ( ) _ + . < > ? *

.PARAMETER SslCertPassword
    SecureString password for the Kerberos SSL PFX. Omit to be prompted when
    -SslCertPath is supplied.

.PARAMETER ServiceAccountPassword
    SecureString password for the domain service account. Omit to be prompted when
    -ServiceAccount is supplied. Allowed characters: letters, digits, and
    ! ( & % @ / = ? * , . #

.PARAMETER ProxyPassword
    SecureString password for an authenticated proxy. Omit to be prompted when
    -ProxyUser is supplied.

.PARAMETER InstallDir
    Installation directory. Defaults to C:\Program Files\ when omitted.

.PARAMETER TrustStoreCertsPath
    Folder of CA certs (PEM/CER) to load into the connector truststore. Every cert
    in the folder is uploaded - keep identity PFX files out of this folder.

.PARAMETER SslCertPath
    Path to the Kerberos Auth SSL identity cert in PFX format. Only relevant with
    KerberosAuthService.

.PARAMETER ServiceAccount
    Domain account to run Kerberos Auth / Virtual App, format DOMAIN\user.

.PARAMETER EnableFips
    Install in FIPS mode (Omnissa Access FedRAMP tenants only). Cannot be changed
    after install.

.PARAMETER DirectorySyncPort
    Directory Sync service port. Default 8080.

.PARAMETER UserAuthPort
    User Auth service port. Default 8090.

.PARAMETER KerberosAuthPort
    Kerberos Auth service port. Default 443. This is the only inbound port.

.PARAMETER VirtualAppPort
    Virtual App service port. Default 8008.

.PARAMETER ProxyHost
    Proxy server FQDN or IP. Adding this enables the proxy.

.PARAMETER ProxyPort
    Proxy server port.

.PARAMETER ProxyUser
    Proxy username. Adding this switches the proxy to Basic (authenticated).

.PARAMETER NonProxyHosts
    Hosts to reach directly, pipe-delimited, e.g. host1|host2.

.PARAMETER SyslogHost
    Syslog target(s), host:port, comma-separated for multiple.

.PARAMETER LogPath
    FOLDER for the audit log and the MSI verbose log. Both are written here with
    timestamped names. Defaults to the current working folder. The folder is
    created if it does not exist.

.PARAMETER ShowInstallerUI
    Show the basic MSI progress UI (/qb) during the install instead of fully
    silent (/qn). The basic UI has no interactive prompts, so the run stays
    unattended. No effect under -DryRun (nothing is executed).

.PARAMETER ValidateServiceAccount
    Additionally perform a live Active Directory bind to confirm the service
    account credentials authenticate (equivalent of the PFX check, for the
    domain account). Requires a reachable DC. Runs in -DryRun and real installs.
    CAUTION: this is a real authentication attempt - a wrong password on
    repeated runs can contribute to account lockout. Offline format and
    password-rule checks always run without this switch.

.PARAMETER InstallerVersion
    Override the installer version used by the version gate (e.g., 26.05.0.0).
    If omitted, it is derived from the installer filename, then file metadata.
    Compared against the installed version: older installed -> upgrade, same ->
    reconfigure/repair, newer installed -> stop and log.

.PARAMETER ForceReinstall
    For a same-version box, uninstall the existing connector and then fresh-
    install, which reapplies certs/creds and lets the installer start the
    services. Without it, a same-version run is skipped (a plain rerun is a
    no-op, and REINSTALL is destructive for this installer). The connector
    re-registers with the Access console on reinstall, so refresh the
    Connectors page afterward.

.PARAMETER ExtraMsiProperties
    A string of additional MSI properties appended verbatim to the installer's
    /v" ... " argument blob (e.g. "AWUPLOADCERT=1"). Intended for testing
    wizard-only internal InstallShield properties that the UI sequence sets but
    silent mode skips. Quote values with spaces yourself. Shown in the audit log.

.PARAMETER SkipKeytab
    Skip the post-install Kerberos verification and remediation step (keytab
    check, krb5-setup.log check, served-certificate compare, and keytab
    generation via the vendor script under Windows PowerShell 5.1).

.PARAMETER DryRun
    Run pre-flight checks, write the audit log, print the constructed command
    (passwords masked), then exit without installing.

.EXAMPLE
    # Directory Sync + User Auth, CA chain into the truststore, prompt for the config password
    .\Install-AccessConnector.ps1 `
        -InstallerPath "C:\TEMP\Workspace-ONE-Access-Connector-Installer-24.12.0.0.exe" `
        -ConfigFilePath "C:\TEMP\es-config.json" `
        -Services DirectorySyncService,UserAuthService `
        -TrustStoreCertsPath "C:\TEMP\TrustedCerts"

.EXAMPLE
    # Full connector with Kerberos - PFX + service account, prompt for all three passwords
    .\Install-AccessConnector.ps1 `
        -InstallerPath "C:\TEMP\Access-Connector-Installer-376-26.05.exe" `
        -ConfigFilePath "C:\TEMP\es-config.json" `
        -Services DirectorySyncService,UserAuthService,KerberosAuthService,VirtualAppService `
        -TrustStoreCertsPath "C:\TEMP\TrustedCerts" `
        -SslCertPath "C:\TEMP\ChildCerts\connector.example.local.pfx" `
        -ServiceAccount "EXAMPLE\svc-access" `
        -DryRun

.EXAMPLE
    # All four services, default install path and ports, truststore + Kerberos PFX + service
    # account, syslog on, no Citrix, no proxy. Passwords omitted, so all three are prompted
    # securely at run time (config file, PFX, service account).
    .\Install-AccessConnector.ps1 `
        -InstallerPath "C:\TEMP\Access-Connector-Installer-376-26.05.exe" `
        -ConfigFilePath "C:\TEMP\es-config.json" `
        -Services DirectorySyncService,UserAuthService,KerberosAuthService,VirtualAppService `
        -TrustStoreCertsPath "C:\TEMP\TrustedCerts" `
        -SslCertPath "C:\TEMP\ChildCerts\connector.pfx" `
        -ServiceAccount "DOMAIN\ServiceAccount" `
        -SyslogHost "syslog.example.com:514"
#>

[CmdletBinding(DefaultParameterSetName='Install')]
param(
    [Parameter(Mandatory, ParameterSetName='Help')]
    [switch]$Help,

    [Parameter(Mandatory, ParameterSetName='Install')]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$InstallerPath,

    [Parameter(Mandatory, ParameterSetName='Install')]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ConfigFilePath,

    [Parameter(Mandatory, ParameterSetName='Install')]
    [ValidateSet('DirectorySyncService','UserAuthService','KerberosAuthService','VirtualAppService')]
    [string[]]$Services,

    # Passwords - omit any of these to be prompted securely
    [securestring]$ConfigFilePassword,
    [securestring]$SslCertPassword,
    [securestring]$ServiceAccountPassword,
    [securestring]$ProxyPassword,

    [string]$InstallDir,
    [string]$TrustStoreCertsPath,

    # Kerberos Auth SSL identity cert (PFX). Only relevant with KerberosAuthService.
    [string]$SslCertPath,

    # Domain account for Kerberos Auth / Virtual App, format DOMAIN\user
    [string]$ServiceAccount,

    [switch]$EnableFips,

    [int]$DirectorySyncPort,
    [int]$UserAuthPort,
    [int]$KerberosAuthPort,
    [int]$VirtualAppPort,

    [string]$ProxyHost,
    [int]$ProxyPort,
    [string]$ProxyUser,
    [string]$NonProxyHosts,     # host1|host2

    [string]$SyslogHost,        # host:port  or  host:port,host:port

    # FOLDER for audit log + MSI verbose log. Default = working folder.
    [string]$LogPath = (Get-Location).Path,

    # Show the basic MSI progress UI (/qb) instead of fully silent (/qn)
    [switch]$ShowInstallerUI,

    # Live AD bind to verify the service account credentials (opt-in)
    [switch]$ValidateServiceAccount,

    # Override the installer version for the version gate (e.g., 26.05.0.0).
    # If omitted, it is derived from the installer filename, then file metadata.
    [string]$InstallerVersion,

    # Same-version reapply: uninstall the existing connector, then fresh-install.
    # A plain same-version run is a no-op, and this installer has no supported
    # silent reconfigure. Fresh install reapplies certs/creds and starts services.
    [switch]$ForceReinstall,

    # Extra MSI properties appended verbatim to the /v" ... " blob, e.g.
    # "AWUPLOADCERT=1" - for testing wizard-only internal properties in silent mode.
    [string]$ExtraMsiProperties,

    # Skip the post-install Kerberos keytab generation/verification step.
    [switch]$SkipKeytab,

    [switch]$DryRun
)

# --- usage ---------------------------------------------------------------

function Show-Usage {
@"

Install-AccessConnector.ps1  -  Omnissa Access Connector silent install

USAGE
  .\Install-AccessConnector.ps1 -InstallerPath <exe> -ConfigFilePath <json> -Services <list> [options]
  .\Install-AccessConnector.ps1 -Help
  .\Install-AccessConnector.ps1 ... -DryRun

REQUIRED
  -InstallerPath <path>     Full path/UNC to the versioned installer .exe (pick the build here)
  -ConfigFilePath <path>    Path to es-config.json from the Access console
  -Services <list>          Comma-separated, any of:
                              DirectorySyncService, UserAuthService,
                              KerberosAuthService, VirtualAppService

PASSWORDS (SecureString - leave off to be prompted, input is masked)
  -ConfigFilePassword       es-config.json password
                              allowed: A-Z a-z 0-9  @ ! , # `$ { } ( ) _ + . < > ? *
  -SslCertPassword          Kerberos SSL PFX password (only with -SslCertPath)
  -ServiceAccountPassword   Domain account password (only with -ServiceAccount)
                              allowed: A-Z a-z 0-9  ! ( & % @ / = ? * , . #
  -ProxyPassword            Proxy password (only with -ProxyUser)

CERTIFICATES
  -TrustStoreCertsPath <folder>  Folder of CA certs (PEM/CER) - loads ALL of them; no identity PFX here
  -SslCertPath <path.pfx>        Kerberos Auth identity cert, PFX (Kerberos only)

SERVICE ACCOUNT (Kerberos Auth / Virtual App)
  -ServiceAccount DOMAIN\user    Domain account to run those services

OPTIONS
  -InstallDir <path>        Install location (default C:\Program Files\)
  -EnableFips               FIPS mode (FedRAMP tenants only, permanent)
  -DirectorySyncPort <n>    default 8080
  -UserAuthPort <n>         default 8090
  -KerberosAuthPort <n>     default 443  (only inbound port)
  -VirtualAppPort <n>       default 8008
  -ProxyHost <fqdn|ip>      enables proxy;  -ProxyPort <n>
  -ProxyUser <name>         switches proxy to authenticated (Basic)
  -NonProxyHosts host1|host2
  -SyslogHost host:port[,host:port]
  -InstallerVersion <ver>   override the installer version for the version gate
  -ForceReinstall           same version: uninstall + fresh install (reapply certs/creds)
  -ExtraMsiProperties <str> extra MSI props appended verbatim (e.g. "AWUPLOADCERT=1")
  -SkipKeytab               skip post-install Kerberos verification (keytab +
                              setup-log + served-cert checks and remediation)
  -LogPath <folder>         FOLDER for the audit log + MSI verbose log
                              (default: working folder; created if missing)
  -ShowInstallerUI          show the basic MSI progress UI (/qb) instead of silent (/qn)
  -ValidateServiceAccount   live AD bind to verify the service account password
                              (real auth attempt - wrong password can lock the account)
  -DryRun                   run pre-flight, write audit log, print command, exit
                              (always runs pre-flight; notes when a real run
                              would skip or refuse this connector)
  -Help                     this summary

VERSION HANDLING (installed vs installer)
  older installed  -> upgrade
  same version     -> skip (no-op); -ForceReinstall does uninstall + fresh install
                      (a -DryRun still runs pre-flight and notes the skip)
  newer installed  -> stop and log (no downgrade)

SERVICES (stopped before install, started after)
  AccessDirectorySyncService, AccessKerberosAuthService,
  AccessUserAuthService, AccessVirtualAppService

PRE-FLIGHT (runs in -DryRun and real installs)
  PFX      verified with its password (true offline check)
  Config   JSON validity + es-config structure + passwordHash shape + password
             complexity gate. Does NOT verify the password against the stored
             hash (no published algorithm) - installer is the sole authority.
  Account  DOMAIN\user format + Kerberos-allowed password chars (offline);
             add -ValidateServiceAccount for a live AD credential bind

NOTES
  * Version selection = point -InstallerPath at a different exe.
  * -ServiceAccount and -SslCertPath apply only when Kerberos Auth or Virtual App is selected.
  * More detail:  Get-Help .\Install-AccessConnector.ps1 -Detailed

"@ | Write-Host
}

if ($PSCmdlet.ParameterSetName -eq 'Help') { Show-Usage; return }

# --- audit + console logging ---------------------------------------------

function Add-AuditRaw {
    param([string]$Text)
    if ($script:AuditLogPath) { try { Add-Content -Path $script:AuditLogPath -Value $Text -ErrorAction Stop } catch { } }
    Write-Host $Text
}

function Write-Audit {
    param(
        [ValidateSet('INFO','OK','WARN','ERROR')][string]$Level='INFO',
        [Parameter(Mandatory)][string]$Message
    )
    $line = "[{0}] [{1,-5}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($script:AuditLogPath) { try { Add-Content -Path $script:AuditLogPath -Value $line -ErrorAction Stop } catch { } }
    $color = switch ($Level) { 'ERROR' {'Red'} 'WARN' {'Yellow'} 'OK' {'Green'} default {'Gray'} }
    Write-Host $line -ForegroundColor $color
}

# --- helpers -------------------------------------------------------------

$DQ = [char]34   # avoids PowerShell quote-escaping pain in the /v" ... " blob

function ConvertTo-Plain {
    param([securestring]$Secure)
    if (-not $Secure) { return $null }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try   { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# Wrap only values containing whitespace in escaped quotes for the MSI /v blob.
function Protect-Value {
    param([string]$Value)
    if ($Value -match '\s') { "\$DQ$Value\$DQ" } else { $Value }
}

# PFX pre-flight - loads the PFX with its password. Uses the SecureString overload
# so the password is not turned into plaintext for the check itself.
function Test-Pfx {
    param([string]$Path,[securestring]$Password)
    $r = [pscustomobject]@{ Ok=$false; Message='' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $r.Message = "file not found: $Path"; return $r
    }
    if (-not $Password) { $Password = (New-Object System.Security.SecureString) }
    $cert = $null
    try {
        $flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
        $cert  = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new([string]$Path, $Password, $flags)
        $r.Ok  = $true
        $r.Message = "opened OK - Subject '$($cert.Subject)', Thumbprint $($cert.Thumbprint), NotAfter $($cert.NotAfter.ToString('yyyy-MM-dd'))"
    }
    catch [System.Security.Cryptography.CryptographicException] {
        $r.Message = "password rejected or file unreadable: $($_.Exception.Message)"
    }
    catch {
        $r.Message = "load error: $($_.Exception.Message)"
    }
    finally { if ($cert) { $cert.Dispose() } }
    return $r
}

# Config pre-flight - JSON validity, es-config structure, password-hash SHAPE,
# and a password COMPLEXITY gate. It does NOT verify the password against the
# stored hash. The hash ("version:iterations:salt:salt2:digest", 73-byte digest)
# is an application-specific salted/peppered scheme with no published algorithm,
# so it cannot be reproduced offline - the installer is the only authority on
# whether the password is actually correct. What this DOES catch: a corrupt or
# wrong file, an edited/truncated hash, and a password that cannot possibly be
# correct because it violates Omnissa's documented complexity rules.
function Test-ConfigFile {
    param([string]$Path,[string]$Password)
    $r = [pscustomobject]@{ Ok=$false; HardFail=$true; Messages=@(); Notes=@() }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $r.Messages += "file not found: $Path"; return $r
    }
    try {
        $raw  = Get-Content -Raw -LiteralPath $Path -ErrorAction Stop
        $json = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $r.Messages += "not valid JSON (corrupt or wrong file): $($_.Exception.Message)"; return $r
    }

    $hasTenant = [bool]($json.tenantURL -or $json.tenantId -or ($raw -match '(?i)tenant'))
    $hashVal   = "$($json.passwordHash)"
    $hasHash   = -not [string]::IsNullOrEmpty($hashVal)
    if (-not $hasTenant) { $r.Messages += "no tenant field found - may not be an es-config.json" }
    if (-not $hasHash)   { $r.Messages += "no passwordHash field found - may not be an es-config.json" }

    # passwordHash SHAPE check (catches a truncated/edited hash). Not a password check.
    $shapeOk = $false
    if ($hasHash) {
        if ($hashVal -match '^\d+:\d+:[0-9a-fA-F]{16,}:[0-9a-fA-F]{16,}:[0-9a-fA-F]{32,}$') {
            $shapeOk = $true
            $r.Notes += "passwordHash shape OK (version:iterations:salt:salt2:digest)."
        } else {
            $r.Messages += "passwordHash is present but malformed (unexpected shape) - file may be edited or corrupt"
        }
    }

    # Password COMPLEXITY gate - a violation means the password cannot be correct,
    # since Omnissa enforces these rules when it generates the file. A pass here is
    # only a format hint; it is NOT proof the password matches the stored hash.
    $complexityFail = $false
    if ([string]::IsNullOrEmpty($Password)) {
        $r.Messages += "no config password supplied"
        $complexityFail = $true
    } else {
        $issues = @()
        if ($Password.Length -lt 14)                                       { $issues += "under 14 characters" }
        if ($Password -notmatch '[0-9]')                                   { $issues += "no digit" }
        if ($Password -notmatch '[A-Z]')                                   { $issues += "no uppercase" }
        if ($Password -notmatch '[@!,#\$\{\}\(\)_\+\.\<\>\?\*]')           { $issues += "no allowed special character" }
        if ($Password -match    '[^A-Za-z0-9@!,#\$\{\}\(\)_\+\.\<\>\?\*]') { $issues += "contains a disallowed character" }
        if ($issues.Count) {
            $r.Messages += "config password CANNOT be correct - it violates the documented rules ($($issues -join ', '))"
            $complexityFail = $true
        } else {
            $r.Notes += "config password meets documented complexity rules (format hint only - NOT proof it is the correct password)."
        }
    }

    $structuralOk = ($hasTenant -and $hasHash -and $shapeOk)
    $r.Ok       = ($structuralOk -and -not $complexityFail)
    $r.HardFail = (-not $structuralOk -or $complexityFail)
    return $r
}

# Service account pre-flight - DOMAIN\user format + Kerberos-allowed password
# chars (offline). With -Live, also binds to AD to confirm the credentials
# authenticate. CAUTION: a live check with a wrong password is a real auth
# attempt and, repeated, can contribute to account lockout.
function Test-ServiceAccount {
    param([string]$Account,[string]$Password,[switch]$Live)
    $r = [pscustomobject]@{ Ok=$true; HardFail=$false; Messages=@() }

    if ($Account -notmatch '^[^\\/@]+\\[^\\/@]+$') {
        $r.Messages += "username is not in DOMAIN\user format: '$Account'"
        $r.Ok = $false; $r.HardFail = $true
    }

    if ([string]::IsNullOrEmpty($Password)) {
        $r.Messages += "no service account password supplied"
    } elseif ($Password -match '[^A-Za-z0-9!\(\)&%@/=\?\*,\.#]') {
        $r.Messages += "password contains characters outside the Kerberos-allowed set (install may fail silently)"
    }

    if ($Live -and $Account -match '\\') {
        $domain, $user = $Account -split '\\', 2
        try {
            Add-Type -AssemblyName System.DirectoryServices.AccountManagement -ErrorAction Stop
            $ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext('Domain', $domain)
            try {
                if ($ctx.ValidateCredentials($user, $Password)) {
                    $r.Messages += "credentials validated against domain '$domain'"
                } else {
                    $r.Messages += "domain '$domain' rejected the credentials for '$Account' (wrong username or password)"
                    $r.Ok = $false; $r.HardFail = $true
                }
            } finally { $ctx.Dispose() }
        } catch {
            $r.Messages += "live credential check could not run (no DC reachable or AccountManagement unavailable): $($_.Exception.Message) - deferred to installer"
        }
    } elseif (-not $Live) {
        $r.Messages += "live AD credential check not requested (add -ValidateServiceAccount to authenticate against the domain)"
    }

    return $r
}

# --- version detection + service control ---------------------------------

$ConnectorServices = @(
    'AccessDirectorySyncService',
    'AccessKerberosAuthService',
    'AccessUserAuthService',
    'AccessVirtualAppService'
)

# Normalize a version string to a 4-part [version] (drops leading zeros, pads).
function ConvertTo-NormVersion {
    param([string]$Value)
    if (-not $Value) { return $null }
    $m = [regex]::Match($Value, '\d+(\.\d+){0,3}')
    if (-not $m.Success) { return $null }
    $parts = @($m.Value.Split('.') | ForEach-Object { [int]$_ })
    while ($parts.Count -lt 4) { $parts += 0 }
    return [version]("{0}.{1}.{2}.{3}" -f $parts[0],$parts[1],$parts[2],$parts[3])
}

# Installer version: explicit override > filename version token > file metadata.
function Get-InstallerVersion {
    param([string]$Path,[string]$Override)
    if ($Override) { return (ConvertTo-NormVersion $Override) }
    $name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $mm = [regex]::Matches($name, '\d+\.\d+(\.\d+){0,2}')
    if ($mm.Count) { return (ConvertTo-NormVersion $mm[$mm.Count-1].Value) }
    try {
        $vi = (Get-Item -LiteralPath $Path).VersionInfo
        foreach ($c in @($vi.ProductVersion,$vi.FileVersion)) {
            $nv = ConvertTo-NormVersion $c
            if ($nv -and $nv.Major -gt 0) { return $nv }
        }
    } catch { }
    return $null
}

# Installed connector (highest match) from the uninstall registry keys.
function Get-InstalledConnectorVersion {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $found = @()
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($p.DisplayName -and $p.DisplayName -match '(?i)(access connector|identity manager connector)') {
                $found += [pscustomobject]@{
                    Name        = $p.DisplayName
                    Version     = $p.DisplayVersion
                    Norm        = (ConvertTo-NormVersion $p.DisplayVersion)
                    ProductCode = $_.PSChildName
                    Uninstall   = $p.UninstallString
                }
            }
        }
    }
    return $found
}

# Stop the connector services that exist (installer also stops them, but stopping
# first avoids file locks; sometimes the installer's own stop/start is unreliable).
function Stop-ConnectorServices {
    foreach ($n in $ConnectorServices) {
        $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
        if (-not $svc) { continue }
        if ($svc.Status -eq 'Stopped') { Write-Audit -Level INFO -Message "Service $n already stopped."; continue }
        try {
            Stop-Service -Name $n -Force -ErrorAction Stop
            Write-Audit -Level OK -Message "Stopped service $n."
        } catch {
            Write-Audit -Level ERROR -Message "Failed to stop service ${n}: $($_.Exception.Message)"
        }
    }
}

# Start the connector services that exist. Returns the names that failed to start.
function Start-ConnectorServices {
    $failed = @()
    foreach ($n in $ConnectorServices) {
        $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
        if (-not $svc) { continue }
        if ($svc.Status -eq 'Running') { Write-Audit -Level INFO -Message "Service $n already running."; continue }
        try {
            Start-Service -Name $n -ErrorAction Stop
            Write-Audit -Level OK -Message "Started service $n."
        } catch {
            Write-Audit -Level ERROR -Message "Failed to start service ${n}: $($_.Exception.Message)"
            $failed += $n
        }
    }
    return $failed
}

# Uninstall the installed connector via its MSI ProductCode. Used only by the
# -ForceReinstall same-version reapply path (a fresh install then follows).
function Uninstall-Connector {
    param([string]$ProductCode,[string]$UninstallLog)
    if (-not $ProductCode) { throw "No ProductCode found for the installed connector - cannot uninstall." }
    $ui  = if ($ShowInstallerUI) { '/qb' } else { '/qn' }
    $dq  = [char]34
    $a   = "/x $ProductCode $ui /norestart /l*v $dq$UninstallLog$dq"
    $p   = Start-Process -FilePath 'msiexec.exe' -ArgumentList $a -Wait -PassThru -NoNewWindow
    return $p.ExitCode
}

# --- resolve all paths to absolute ---------------------------------------
# MSI deferred custom actions run as SYSTEM with CWD = C:\WINDOWS\Installer,
# so relative paths (..\Configs, ..\TrustedCerts) silently resolve THERE and
# fail - the es-config import and truststore load get the wrong location and
# the install "succeeds" while applying nothing. Resolve everything to absolute
# against the caller's current directory first.
function Resolve-FullPath {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}
$InstallerPath  = Resolve-FullPath $InstallerPath
$ConfigFilePath = Resolve-FullPath $ConfigFilePath
$LogPath        = Resolve-FullPath $LogPath
if ($SslCertPath)         { $SslCertPath         = Resolve-FullPath $SslCertPath }
if ($TrustStoreCertsPath) { $TrustStoreCertsPath = Resolve-FullPath $TrustStoreCertsPath }
if ($InstallDir)          { $InstallDir          = Resolve-FullPath $InstallDir
    # 'D:\Apps\' would end in \" inside the installer's quoted argument; 'D:\' stays as it is
    if ($InstallDir.Length -gt 3) { $InstallDir = $InstallDir.TrimEnd('\') } }

# Locate the connector install root by finding the vendor keytab script under it.
function Get-ConnectorRoot {
    param([string]$InstallDir)
    $candidates = @()
    if ($InstallDir) { $candidates += (Join-Path $InstallDir 'Access Connector') }
    $candidates += 'C:\Program Files\Access Connector'
    try {
        $svc = Get-CimInstance Win32_Service -Filter "Name='AccessKerberosAuthService'" -ErrorAction SilentlyContinue
        if ($svc.PathName) {
            $exe  = ($svc.PathName -replace '^"','' -replace '".*$','')
            $root = ($exe -replace '(?i)\\Kerberos Auth Service\\.*$','')
            if ($root) { $candidates += $root }
        }
    } catch { }
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $c 'Support\scripts\setupKerberos.ps1')) { return $c }
    }
    return $null
}

# Generate the Kerberos keytab by running the UNMODIFIED vendor setupKerberos.ps1
# under Windows PowerShell 5.1. The vendor script uses [System.Web.Security.
# Membership]::GeneratePassword(), which does not exist in PowerShell 7 (.NET
# Core) - under 7 the password comes back empty and ktpass writes a bad keytab.
# 5.1 is always present on a connector host, so we invoke it explicitly and leave
# the signed vendor script untouched (it would be overwritten on upgrade anyway).
function Invoke-KeytabSetup {
    param([string]$ConnectorRoot,[string]$LogFolder,[string]$Stamp)
    $r = [pscustomobject]@{ Ok=$false; Message='' }
    $confDir  = Join-Path $ConnectorRoot 'Kerberos Auth Service\conf'
    $vendorPs = Join-Path $ConnectorRoot 'Support\scripts\setupKerberos.ps1'
    $keytab   = Join-Path $confDir 'krb5.keytab'
    $ps51     = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    if (-not (Test-Path -LiteralPath $vendorPs)) { $r.Message = "vendor script not found: $vendorPs"; return $r }
    if (-not (Test-Path -LiteralPath $ps51))     { $r.Message = "Windows PowerShell 5.1 not found at $ps51"; return $r }

    # Write a tiny runner and invoke via -File to avoid quoting issues with spaces.
    $runner = Join-Path $LogFolder "run-keytab_$Stamp.ps1"
    $outLog = Join-Path $LogFolder "keytab-console_$Stamp.log"
    $body = @"
`$ErrorActionPreference = 'Continue'
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    try { Import-Module ServerManager -ErrorAction Stop; Add-WindowsFeature RSAT-AD-PowerShell -ErrorAction Stop | Out-Null }
    catch { Write-Output "WARN: could not add RSAT-AD-PowerShell: `$(`$_.Exception.Message)" }
}
`$env:KERBEROS_AUTH_SVC_CONF_DIR = '$confDir'
& '$vendorPs' -confDir '$confDir'
exit `$LASTEXITCODE
"@
    Set-Content -LiteralPath $runner -Value $body -Encoding ASCII
    $logFrom = Get-SetupLogLength -ConnectorRoot $ConnectorRoot

    Start-Process -FilePath $ps51 `
                  -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$runner`"" `
                  -Wait -NoNewWindow `
                  -RedirectStandardOutput $outLog -RedirectStandardError "$outLog.err" | Out-Null

    Start-Sleep -Milliseconds 500
    $item = Get-Item -LiteralPath $keytab -ErrorAction SilentlyContinue
    # The vendor script blanks the keytab first (6 bytes); a usable one is a few hundred bytes.
    if ($item -and $item.Length -ge 32) {
        $added = [string](Get-SetupLogText -ConnectorRoot $ConnectorRoot -From $logFrom)
        if ($added -match 'Password set failed') {
            $r.Message = "keytab written ($($item.Length) bytes) but krb5-setup.log shows 'Password set failed' - likely a bad keytab (wrong PowerShell edition?). Console: $outLog"
        } else {
            $r.Ok = $true
            $r.Message = "keytab generated ($($item.Length) bytes). Console: $outLog"
        }
    } else {
        $r.Message = "keytab still missing or empty after the run. Console: $outLog / $outLog.err"
    }
    return $r
}

# The SHA-1 thumbprint of the certificate the service on localhost:<Port> presents, read with a
# TLS 1.2 handshake of its own and a hash of the raw certificate bytes. '' when it cannot be read.
function Get-ServedThumbprint {
    param([int]$Port = 443, [int]$TimeoutMs = 15000)
    $tcp = $null; $ssl = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect('localhost', $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return '' }
        $tcp.EndConnect($iar)
        $tcp.ReceiveTimeout = $TimeoutMs; $tcp.SendTimeout = $TimeoutMs
        $any = [System.Net.Security.RemoteCertificateValidationCallback]{ $true }
        $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false, $any)
        $ssl.AuthenticateAsClient('localhost', $null, [System.Security.Authentication.SslProtocols]::Tls12, $false)
        if ($null -eq $ssl.RemoteCertificate) { return '' }
        $der = $ssl.RemoteCertificate.GetRawCertData()
        $sha = [System.Security.Cryptography.SHA1]::Create()
        try { $t = ([System.BitConverter]::ToString($sha.ComputeHash($der))).Replace('-', '') } finally { $sha.Dispose() }
        if ($t -notmatch '^[0-9A-F]{40}$') { return '' }
        return $t
    } catch { return '' }
    finally { if ($ssl) { try { $ssl.Dispose() } catch { } }; if ($tcp) { try { $tcp.Close() } catch { } } }
}

# The text of krb5-setup.log from character $From on: what the vendor script added since then.
# The vendor script appends on every run, so older runs must not be judged again.
function Get-SetupLogText {
    param([string]$ConnectorRoot, [int]$From = 0)
    $log = Join-Path $ConnectorRoot 'Kerberos Auth Service\conf\krb5-setup.log'
    if (-not (Test-Path -LiteralPath $log)) { return $null }
    $all = [string](Get-Content -Raw -LiteralPath $log -ErrorAction SilentlyContinue)
    if ($From -gt 0 -and $all.Length -ge $From) { return $all.Substring($From) }
    return $all
}
function Get-SetupLogLength {
    param([string]$ConnectorRoot)
    $t = Get-SetupLogText -ConnectorRoot $ConnectorRoot
    if ($null -eq $t) { return 0 }
    return $t.Length
}

# Probe the eks health endpoint locally and capture the certificate the service
# actually presents. Body 'true' = healthy; 'Keytab file is missing' = keytab
# problem. Comparing the served cert's thumbprint against the provided PFX is
# the definitive check for "is MY cert loaded" vs the installer's self-signed.
function Test-EksHealth {
    param([string]$ConnectorRoot,[string]$ExpectedThumbprint)
    $r = [pscustomobject]@{ Reachable=$false; Healthy=$false; Body=''; ServedThumbprint=''; CertMatch=$null; Message='' }
    $props = Join-Path $ConnectorRoot 'Kerberos Auth Service\conf\application.properties'
    $port = '443'
    if (Test-Path -LiteralPath $props) {
        $txt = Get-Content -Raw -LiteralPath $props
        if ($txt -match '(?m)^eks\.http\.server\.port=(\d+)') { $port = $Matches[1] }
    }
    try {
        $req = [System.Net.HttpWebRequest]::Create("https://localhost:$port/eks/health/")
        $req.Timeout = 15000
        $req.ServerCertificateValidationCallback = [System.Net.Security.RemoteCertificateValidationCallback]{ $true }
        try { $resp = $req.GetResponse() }
        catch [System.Net.WebException] { if ($_.Exception.Response) { $resp = $_.Exception.Response } else { throw } }
        $r.Reachable = $true
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $r.Body = $sr.ReadToEnd().Trim()
        $sr.Dispose(); $resp.Close()
        # The certificate cannot be taken from the callback above: on Windows PowerShell 5.1 the
        # object handed to it is emptied once it returns. Read it with a handshake of its own.
        $r.ServedThumbprint = Get-ServedThumbprint -Port ([int]$port)
        $r.Healthy = ($r.Body -eq 'true')
        if ($ExpectedThumbprint -and $r.ServedThumbprint) {
            $r.CertMatch = ($r.ServedThumbprint -eq $ExpectedThumbprint)
        }
    } catch { $r.Message = $_.Exception.Message }
    return $r
}

# Inspect krb5-setup.log for the two failure signatures we have actually hit:
# 'Password set failed' (PowerShell 7 empty-password keytab) and a non-zero
# RESULT exit code. Absence of the log with a keytab present means the keytab
# was made outside the vendor script - noted, not failed.
function Test-KeytabSetupLog {
    param([string]$ConnectorRoot, [int]$From = 0)
    # Judges only what the vendor script wrote from character $From on (this run). When this run
    # wrote nothing, the newest RESULT line in the log is judged instead, and the message says so.
    $r = [pscustomobject]@{ Exists=$false; Ok=$false; Message='' }
    $all = Get-SetupLogText -ConnectorRoot $ConnectorRoot
    if ($null -eq $all) { $r.Message = "krb5-setup.log not present"; return $r }
    $r.Exists = $true
    $txt = Get-SetupLogText -ConnectorRoot $ConnectorRoot -From $From
    $scope = 'in this run'
    if (-not ([string]$txt).Trim()) {
        # nothing new: judge the newest entry only, which starts after the RESULT line before it
        $scope = 'in its newest entry (nothing was added in this run)'
        $all_r = [regex]::Matches($all, '(?m)^RESULT: exit code (-?\d+)[ \t]*\r?$')
        $txt = $all
        if ($all_r.Count -ge 2) { $prev = $all_r[$all_r.Count - 2]; $txt = $all.Substring($prev.Index + $prev.Length) }
    }
    $results = [regex]::Matches($txt, '(?m)^RESULT: exit code (-?\d+)[ \t]*\r?$')
    $last = if ($results.Count) { $results[$results.Count - 1].Groups[1].Value } else { $null }
    $pwFail = ($txt -match 'Password set failed')
    if ($pwFail) {
        $r.Message = "krb5-setup.log shows 'Password set failed' $scope - the keytab was written with a bad or empty password (PowerShell 7 symptom)"
    } elseif ($null -ne $last -and $last -ne '0') {
        $r.Message = "krb5-setup.log RESULT exit code is $last $scope"
    } else {
        $r.Ok = $true
        $r.Message = "krb5-setup.log shows no failure signatures $scope"
    }
    return $r
}

# --- resolve log folder + init audit (before main try, so we can log) ----

try {
    if (-not (Test-Path -LiteralPath $LogPath)) {
        New-Item -ItemType Directory -Path $LogPath -Force -ErrorAction Stop | Out-Null
        $logFolderCreated = $true
    } elseif (-not (Test-Path -LiteralPath $LogPath -PathType Container)) {
        Write-Error "-LogPath must be a folder. A file path was supplied: $LogPath"
        exit 2
    }
} catch {
    Write-Error "Unable to create log folder '$LogPath': $($_.Exception.Message)"
    exit 2
}

$stamp               = Get-Date -Format 'yyyyMMdd_HHmmss'
$script:AuditLogPath = Join-Path $LogPath "AccessConnector_Audit_$stamp.log"
$MsiLogPath          = Join-Path $LogPath "AccessConnector_MSI_$stamp.log"

# --- main -----------------------------------------------------------------

$exitCode = 0
# The local health checks speak TLS 1.2; Windows PowerShell 5.1 may not offer it by default.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
try {
    $needServiceAccount = ($Services -contains 'KerberosAuthService') -or ($Services -contains 'VirtualAppService')
    $mode = if ($DryRun) { 'DryRun (pre-flight only - installer NOT executed)' } else { 'Install' }
    $portSummary = if ($DirectorySyncPort -or $UserAuthPort -or $KerberosAuthPort -or $VirtualAppPort) {
        "custom (DS=$DirectorySyncPort UA=$UserAuthPort KAS=$KerberosAuthPort VA=$VirtualAppPort)"
    } else { 'default (8080/8090/443/8008)' }

    # -- version detection + action decision -------------------------------
    $installerVer  = Get-InstallerVersion -Path $InstallerPath -Override $InstallerVersion
    $installedInfo = Get-InstalledConnectorVersion | Sort-Object Norm -Descending | Select-Object -First 1
    $installedVer  = if ($installedInfo) { $installedInfo.Norm } else { $null }
    $installerVerStr = if ($installerVer)  { $installerVer.ToString() } else { 'unknown' }
    $installedVerStr = if ($installedInfo) { "$($installedInfo.Version) [$($installedInfo.Name)]" } else { 'not installed' }

    $blocked = $false; $skip = $false; $doUninstallFirst = $false; $isUpgrade = $false
    if (-not $installedInfo) {
        $installAction = 'Fresh install'
    } elseif (-not $installerVer -or -not $installedVer) {
        $installAction = 'Install (version gate skipped - version undetermined; pass -InstallerVersion)'
    } else {
        $c = $installerVer.CompareTo($installedVer)
        if ($c -gt 0) {
            $isUpgrade = $true
            $installAction = "Upgrade ($installedVer -> $installerVer)"
        } elseif ($c -eq 0) {
            if ($ForceReinstall) {
                $installAction = "Force reinstall: uninstall + fresh install (same version $installerVer)"
                $doUninstallFirst = $true
            } else {
                $installAction = "Skip - already at $installerVer. Silent reconfigure is not supported by this installer; use -ForceReinstall (uninstall + fresh install) or the installer's modify flow to change certs/creds."
                $skip = $true
            }
        } else {
            $installAction = "BLOCKED - installed ($installedVer) is newer than installer ($installerVer)"
            $blocked = $true
        }
    }

    $header = @"
========================= Omnissa Access Connector Install =========================
 Timestamp         : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
 Run by            : $env:USERDOMAIN\$env:USERNAME
 Computer          : $env:COMPUTERNAME
 Mode              : $mode
 Audit log         : $script:AuditLogPath
 MSI log           : $MsiLogPath
------------------------------------------------------------------------------------
 Installer         : $InstallerPath
 Config file       : $ConfigFilePath
 Services          : $($Services -join ', ')
 Install dir       : $(if($InstallDir){$InstallDir}else{'default (C:\Program Files\)'})
 Truststore folder : $(if($TrustStoreCertsPath){$TrustStoreCertsPath}else{'(none)'})
 Kerberos PFX      : $(if($SslCertPath){$SslCertPath}else{'(none)'})
 Service account   : $(if($ServiceAccount){$ServiceAccount}else{'(none)'})
 Syslog            : $(if($SyslogHost){$SyslogHost}else{'(disabled)'})
 Proxy             : $(if($ProxyHost){$ProxyHost}else{'(disabled)'})
 FIPS              : $(if($EnableFips){'Enabled'}else{'Disabled'})
 Ports             : $portSummary
 Installer UI      : $(if($ShowInstallerUI){'Basic progress (/qb)'}else{'Silent (/qn)'})
 Svc acct check    : $(if($ValidateServiceAccount){'Live AD bind + offline'}else{'Offline only (format + password rules)'})
 Installed version : $installedVerStr
 Installer version : $installerVerStr
 Planned action    : $installAction
====================================================================================
"@
    Add-AuditRaw $header
    if ($logFolderCreated) { Write-Audit -Level INFO -Message "Created log folder: $LogPath" }

    # A dry run always runs the pre-flight checks, so it proves the passwords and files even for a
    # connector that a real run would skip or refuse; it then says what a real run would do.
    $realRunNote = ''
    if ($blocked) {
        $realRunNote = "A real run would STOP here: the installed version ($installedVer) is newer than the installer ($installerVer), and the connector is not downgraded."
        if ($DryRun) { Write-Audit -Level WARN -Message "$realRunNote The dry run carries on with the pre-flight checks." }
        else { Write-Audit -Level ERROR -Message "Installed version is newer than the installer - stopping. The connector will not be downgraded. No services were stopped and nothing was installed." }
        $exitCode = 1
    }
    elseif ($skip) {
        $realRunNote = "A real run would SKIP this connector: it is already at $installerVer and -ForceReinstall is not set, so nothing would be installed. Add -ForceReinstall to uninstall it and install it fresh."
        if ($DryRun) { Write-Audit -Level WARN -Message "$realRunNote The dry run carries on with the pre-flight checks." }
        else { Write-Audit -Level INFO -Message "Same version already installed and -ForceReinstall not set - nothing to do. No services were touched. For cert/cred changes, use -ForceReinstall or the installer's modify flow." }
        $exitCode = 0
    }

    if ($DryRun -or (-not $blocked -and -not $skip)) {

    # -- prompt for any missing secrets ------------------------------------
    if (-not $ConfigFilePassword) {
        $ConfigFilePassword = Read-Host -AsSecureString "Configuration file (es-config.json) password"
    }
    if ($SslCertPath -and -not $SslCertPassword) {
        $SslCertPassword = Read-Host -AsSecureString "Kerberos SSL PFX password"
    }
    if ($ServiceAccount -and -not $ServiceAccountPassword) {
        $ServiceAccountPassword = Read-Host -AsSecureString "Service account password for $ServiceAccount"
    }
    if ($ProxyUser -and -not $ProxyPassword) {
        $ProxyPassword = Read-Host -AsSecureString "Proxy password for $ProxyUser"
    }

    if ($ServiceAccount -and -not $needServiceAccount) {
        Write-Audit -Level WARN -Message "Service account supplied but neither Kerberos Auth nor Virtual App is selected - it will be ignored."
    }
    if ($needServiceAccount -and -not $ServiceAccount) {
        Write-Audit -Level WARN -Message "Kerberos Auth or Virtual App selected without -ServiceAccount - Kerberos initialization will fail post-install until a domain account is set."
    }

    # -- resolve plaintext where the installer needs it --------------------
    $cfgPw   = ConvertTo-Plain $ConfigFilePassword
    $pfxPw   = if ($SslCertPath)   { ConvertTo-Plain $SslCertPassword }        else { $null }
    $svcPw   = if ($ServiceAccount){ ConvertTo-Plain $ServiceAccountPassword } else { $null }
    $proxyPw = if ($ProxyUser)     { ConvertTo-Plain $ProxyPassword }          else { $null }

    # -- PRE-FLIGHT --------------------------------------------------------
    Write-Audit -Level INFO -Message "Running pre-flight checks..."
    $preflightOk = $true

    if ($SslCertPath) {
        $pfx = Test-Pfx -Path $SslCertPath -Password $SslCertPassword
        if ($pfx.Ok) { Write-Audit -Level OK -Message "PFX pre-flight passed - $($pfx.Message)" }
        else { Write-Audit -Level ERROR -Message "PFX pre-flight FAILED - $($pfx.Message)"; $preflightOk = $false }
    } else {
        Write-Audit -Level INFO -Message "PFX pre-flight skipped (no -SslCertPath)."
    }

    $cfg = Test-ConfigFile -Path $ConfigFilePath -Password $cfgPw
    foreach ($n in $cfg.Notes)    { Write-Audit -Level INFO -Message "Config: $n" }
    foreach ($m in $cfg.Messages) { Write-Audit -Level WARN -Message "Config: $m" }
    if ($cfg.Ok) {
        Write-Audit -Level OK -Message "Config file pre-flight passed (valid es-config JSON, hash shape OK, password meets complexity rules)."
    } else {
        Write-Audit -Level ERROR -Message "Config file pre-flight FAILED - see the warnings above."
    }
    if ($cfg.HardFail) { $preflightOk = $false }
    Write-Audit -Level WARN -Message "Config PASSWORD correctness is NOT verified here. The stored hash uses an application-specific salted/peppered scheme with no published algorithm - only the installer can confirm the password is right."

    if ($TrustStoreCertsPath) {
        if (-not (Test-Path -LiteralPath $TrustStoreCertsPath -PathType Container)) {
            Write-Audit -Level ERROR -Message "Truststore folder not found: $TrustStoreCertsPath"
            $preflightOk = $false
        } else {
            $tsCerts = @(Get-ChildItem -LiteralPath $TrustStoreCertsPath -File -ErrorAction SilentlyContinue |
                         Where-Object { $_.Extension -match '(?i)^\.(pem|cer|crt)$' })
            if ($tsCerts.Count -eq 0) {
                Write-Audit -Level WARN -Message "Truststore folder has no .pem/.cer/.crt files: $TrustStoreCertsPath"
            } else {
                Write-Audit -Level OK -Message "Truststore folder OK ($($tsCerts.Count) cert file(s)): $TrustStoreCertsPath"
            }
        }
    }

    if ($ServiceAccount -and $needServiceAccount) {
        $sa = Test-ServiceAccount -Account $ServiceAccount -Password $svcPw -Live:$ValidateServiceAccount
        foreach ($m in $sa.Messages) { Write-Audit -Level WARN -Message "Service account: $m" }
        if ($sa.Ok) {
            Write-Audit -Level OK -Message "Service account pre-flight passed."
        } else {
            Write-Audit -Level ERROR -Message "Service account pre-flight FAILED."
            if ($sa.HardFail) { $preflightOk = $false }
        }
    } elseif ($ServiceAccount) {
        Write-Audit -Level INFO -Message "Service account supplied but not required by the selected services - skipping service account pre-flight."
    } else {
        Write-Audit -Level INFO -Message "Service account pre-flight skipped (no -ServiceAccount)."
    }

    if ($ProxyUser) {
        if ([string]::IsNullOrEmpty($proxyPw)) { Write-Audit -Level ERROR -Message "Proxy pre-flight FAILED - no proxy password supplied for $ProxyUser."; $preflightOk = $false }
        elseif ($proxyPw -match '"') { Write-Audit -Level ERROR -Message "Proxy pre-flight FAILED - the proxy password contains a double quote, which the installer's command line cannot carry."; $preflightOk = $false }
    }
    if (($ProxyPort -or $ProxyUser -or $NonProxyHosts) -and -not $ProxyHost) { Write-Audit -Level ERROR -Message "Proxy pre-flight FAILED - -ProxyPort, -ProxyUser or -NonProxyHosts given without -ProxyHost."; $preflightOk = $false }

    # -- build the property list (real + masked for display) ---------------
    $props   = [System.Collections.Generic.List[string]]::new()
    $display = [System.Collections.Generic.List[string]]::new()

    function Add-Prop {
        param([string]$Name,[string]$Value,[switch]$Secret)
        $real = "$Name=$(Protect-Value $Value)"
        $props.Add($real)
        if ($Secret) { $display.Add("$Name=***") } else { $display.Add($real) }
    }

    Add-Prop 'ADDLOCAL' ($Services -join ',')
    Add-Prop 'WS1_CONFIG_FILE_PATH' $ConfigFilePath
    Add-Prop 'WS1_CONFIG_FILE_PASSWORD' $cfgPw -Secret

    if ($InstallDir) { Add-Prop 'INSTALLDIR' $InstallDir; Add-Prop 'TARGETDIR' $InstallDir }
    if ($EnableFips) { Add-Prop 'WS1_ENABLE_FIPS' '1' }
    if ($TrustStoreCertsPath) { Add-Prop 'WS1_TRUSTSTORE_CERTS_PATH' $TrustStoreCertsPath }

    if ($DirectorySyncPort) { Add-Prop 'WS1_DIRECTORY_SYNC_PORT' "$DirectorySyncPort" }
    if ($UserAuthPort)      { Add-Prop 'WS1_USER_AUTH_PORT'       "$UserAuthPort" }
    if ($KerberosAuthPort)  { Add-Prop 'WS1_KERBEROS_AUTH_PORT'   "$KerberosAuthPort" }
    if ($VirtualAppPort)    { Add-Prop 'WS1_APP_SYNC_PORT'        "$VirtualAppPort" }

    if ($SslCertPath) {
        Add-Prop 'WS1_ADD_SSL_CERT'      '1'
        Add-Prop 'WS1_CERT_TYPE'         'pfx'
        Add-Prop 'WS1_SSL_CERT'          $SslCertPath
        Add-Prop 'WS1_SSL_CERT_PASSWORD' $pfxPw -Secret
    }

    if ($ServiceAccount -and $needServiceAccount) {
        Add-Prop 'IS_NET_API_LOGON_USERNAME' $ServiceAccount
        Add-Prop 'IS_NET_API_LOGON_PASSWORD' $svcPw -Secret
    }

    if ($ProxyHost) {
        Add-Prop 'WS1_IS_PROXY_ENABLED' '1'
        Add-Prop 'WS1_PROXY_HOSTNAME'   $ProxyHost
        if ($ProxyPort)     { Add-Prop 'WS1_PROXY_PORT'       "$ProxyPort" }
        if ($NonProxyHosts) { Add-Prop 'WS1_NON_PROXY_HOSTS'  $NonProxyHosts }
        if ($ProxyUser) {
            Add-Prop 'WS1_IS_PROXY_AUTHENTICATED' '2'
            Add-Prop 'WS1_PROXY_USERNAME'         $ProxyUser
            Add-Prop 'WS1_PROXY_PASSWORD'         $proxyPw -Secret
        }
    }

    if ($SyslogHost) {
        Add-Prop 'WS1_IS_SYSLOG_ENABLED' '1'
        Add-Prop 'WS1_SYSLOG_HOSTNAME'   $SyslogHost
    }

    if ($ExtraMsiProperties) {
        Write-Audit -Level WARN -Message "Appending extra MSI properties verbatim (shown in the command below): $ExtraMsiProperties"
        $props.Add($ExtraMsiProperties)
        $display.Add($ExtraMsiProperties)
    }

    $uiLevel          = if ($ShowInstallerUI) { '/qb' } else { '/qn' }
    $inner            = "$uiLevel " + ($props   -join ' ') + " /l*v " + (Protect-Value $MsiLogPath)
    $innerDisplay     = "$uiLevel " + ($display -join ' ') + " /l*v " + (Protect-Value $MsiLogPath)
    $argString        = "/s /v$DQ$inner$DQ"
    $argStringDisplay = "/s /v$DQ$innerDisplay$DQ"

    Write-Audit -Level INFO -Message "Constructed command (passwords masked):"
    Add-AuditRaw "  $InstallerPath $argStringDisplay"

    # -- execute or dry run ------------------------------------------------
    if ($DryRun) {
        if ($preflightOk -and $blocked) {
            Write-Audit -Level ERROR -Message "DRY RUN complete - pre-flight passed, but $realRunNote Installer NOT executed; services not touched."
            Write-Audit -Level WARN -Message "DRY RUN note: $realRunNote"
            $exitCode = 1
        } elseif ($preflightOk) {
            Write-Audit -Level OK -Message "DRY RUN complete - pre-flight passed. Planned action: $($installAction.TrimEnd('.')). Installer NOT executed; services not touched."
            if ($realRunNote) { Write-Audit -Level WARN -Message "DRY RUN note: $realRunNote" }
            $exitCode = 0
        } else {
            Write-Audit -Level ERROR -Message "DRY RUN complete - pre-flight FAILED. Fix the issues above before a real run."
            if ($realRunNote) { Write-Audit -Level WARN -Message "DRY RUN note: $realRunNote" }
            $exitCode = 1
        }
    }
    elseif (-not $preflightOk) {
        Write-Audit -Level ERROR -Message "Aborting install - pre-flight failed. No installer was executed; services not touched."
        $exitCode = 1
    }
    else {
        Write-Audit -Level INFO -Message "Action: $installAction"

        $proceedInstall = $true
        if ($doUninstallFirst) {
            $uninstLog = Join-Path $LogPath "AccessConnector_Uninstall_$stamp.log"
            Write-Audit -Level WARN -Message "Force reinstall - uninstalling the existing connector first (ProductCode $($installedInfo.ProductCode)). It re-registers with the Access console on reinstall; refresh the Connectors page afterward."
            Write-Audit -Level INFO -Message "Stopping connector services before uninstall..."
            Stop-ConnectorServices
            $uxc = Uninstall-Connector -ProductCode $installedInfo.ProductCode -UninstallLog $uninstLog
            if ($uxc -in 0,3010,1641) {
                Write-Audit -Level OK -Message "Uninstall completed (exit $uxc). Log: $uninstLog"
            } else {
                Write-Audit -Level ERROR -Message "Uninstall FAILED (exit $uxc) - aborting before reinstall. Log: $uninstLog"
                $exitCode = $uxc; $proceedInstall = $false
            }
        } else {
            Write-Audit -Level INFO -Message "Stopping connector services before install..."
            Stop-ConnectorServices
        }

        if ($proceedInstall) {
            # Where krb5-setup.log ends now, so only what this install adds to it is judged later.
            $setupLogFrom = 0
            $rootBefore = Get-ConnectorRoot -InstallDir $InstallDir
            if ($rootBefore) { $setupLogFrom = Get-SetupLogLength -ConnectorRoot $rootBefore }
            Write-Audit -Level INFO -Message "Starting installer..."
            $proc = Start-Process -FilePath $InstallerPath -ArgumentList $argString -Wait -PassThru -NoNewWindow
            $exitCode = $proc.ExitCode
            switch ($exitCode) {
                0    { Write-Audit -Level OK    -Message "Installer succeeded (exit 0)." }
                3010 { Write-Audit -Level OK    -Message "Installer succeeded, reboot required (exit 3010)." }
                1641 { Write-Audit -Level OK    -Message "Installer succeeded, reboot initiated (exit 1641)." }
                default { Write-Audit -Level ERROR -Message "Installer FAILED or returned unexpected code $exitCode. See MSI log: $MsiLogPath" }
            }

            if ($exitCode -eq 0) {
                Write-Audit -Level INFO -Message "Ensuring connector services are started..."
                $startFailed = @(Start-ConnectorServices)
                if ($startFailed.Count) {
                    Write-Audit -Level ERROR -Message "Service(s) failed to start: $($startFailed -join ', '). Check <InstallDir>\Access Connector\<Service>\logs and Event Viewer > Application."
                    $exitCode = 1
                }

                if (($Services -contains 'KerberosAuthService') -and -not $SkipKeytab) {
                    $connRoot = Get-ConnectorRoot -InstallDir $InstallDir
                    if (-not $connRoot) {
                        Write-Audit -Level WARN -Message "Kerberos selected but could not locate the connector install root - skipping Kerberos verification. If /eks/health reports 'Keytab file is missing', run setupKerberos.ps1 under Windows PowerShell 5.1."
                    } else {
                        Write-Audit -Level INFO -Message "Verifying Kerberos Auth Service (keytab, setup log, served certificate)..."

                        # Expected thumbprint from the provided PFX, for the served-cert compare
                        $expectedThumb = $null
                        if ($SslCertPath) {
                            try {
                                $flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
                                $pfxCert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new([string]$SslCertPath, $SslCertPassword, $flags)
                                $expectedThumb = $pfxCert.Thumbprint
                                $pfxCert.Dispose()
                            } catch { Write-Audit -Level WARN -Message "Could not reopen the PFX for the cert compare: $($_.Exception.Message)" }
                        }

                        # 1) keytab file check
                        $keytabPath = Join-Path $connRoot 'Kerberos Auth Service\conf\krb5.keytab'
                        $ktItem = Get-Item -LiteralPath $keytabPath -ErrorAction SilentlyContinue
                        $keytabOk = ($ktItem -and $ktItem.Length -ge 32)   # under 32 bytes = blanked, no keys
                        if ($keytabOk) { Write-Audit -Level OK   -Message "Keytab present and non-empty ($($ktItem.Length) bytes): $keytabPath" }
                        else           { Write-Audit -Level WARN -Message "Keytab missing or empty: $keytabPath" }

                        # 2) krb5-setup.log content check
                        $slog = Test-KeytabSetupLog -ConnectorRoot $connRoot -From $setupLogFrom
                        if ($slog.Exists -and $slog.Ok)      { Write-Audit -Level OK   -Message "Setup log: $($slog.Message)" }
                        elseif ($slog.Exists)                { Write-Audit -Level WARN -Message "Setup log: $($slog.Message)"; $keytabOk = $false }
                        elseif ($keytabOk)                   { Write-Audit -Level INFO -Message "Setup log: $($slog.Message) (keytab exists - likely generated outside the vendor script)" }
                        else                                 { Write-Audit -Level INFO -Message "Setup log: $($slog.Message)" }

                        # 3) live health + served-cert check
                        $eks = Test-EksHealth -ConnectorRoot $connRoot -ExpectedThumbprint $expectedThumb
                        if ($eks.Reachable) {
                            if ($eks.Healthy) { Write-Audit -Level OK   -Message "/eks/health returned 'true'." }
                            else              { Write-Audit -Level WARN -Message "/eks/health returned: '$($eks.Body)'" }
                            if ($null -ne $eks.CertMatch) {
                                if ($eks.CertMatch) { Write-Audit -Level OK -Message "Served certificate matches the provided PFX (thumbprint $($eks.ServedThumbprint))." }
                                elseif ($isUpgrade) { Write-Audit -Level WARN -Message "Served certificate does not match the provided PFX (served $($eks.ServedThumbprint), expected $expectedThumb). Expected after an upgrade: the installer does not carry a PFX through an upgrade and serves a certificate of its own. Put the PFX back with Invoke-AccessConnectorUpgrade.ps1 -Mode RepairCertificate (its upgrades do this by themselves)." }
                                else { Write-Audit -Level ERROR -Message "Served certificate does NOT match the provided PFX after a fresh install (served $($eks.ServedThumbprint), expected $expectedThumb) - the service is presenting a different certificate. Check the PFX, or put it on the service with Invoke-AccessConnectorUpgrade.ps1 -Mode RepairCertificate."; $exitCode = 1 }
                            } elseif ($expectedThumb -and -not $eks.ServedThumbprint) {
                                Write-Audit -Level WARN -Message "Could not read the certificate the Kerberos service presents, so it was not compared with the PFX."
                            } elseif ($eks.ServedThumbprint) {
                                Write-Audit -Level INFO -Message "Served certificate thumbprint: $($eks.ServedThumbprint) (no PFX supplied to compare)."
                            }
                        } else {
                            Write-Audit -Level WARN -Message "Could not reach /eks/health locally: $($eks.Message)"
                        }

                        # Healthy on first probe -> restart the service and confirm it
                        # comes back healthy from a clean start with keytab + cert loaded.
                        if ($eks.Reachable -and $eks.Healthy) {
                            try {
                                Restart-Service -Name 'AccessKerberosAuthService' -Force -ErrorAction Stop
                                Write-Audit -Level INFO -Message "Health confirmed - restarted AccessKerberosAuthService for a clean start; re-verifying..."
                                Start-Sleep -Seconds 20
                                $eksR = Test-EksHealth -ConnectorRoot $connRoot -ExpectedThumbprint $expectedThumb
                                if ($eksR.Reachable -and $eksR.Healthy) { Write-Audit -Level OK -Message "/eks/health returns 'true' after restart - Kerberos Auth Service verified healthy." }
                                elseif ($eksR.Reachable) { Write-Audit -Level WARN -Message "/eks/health after restart returned: '$($eksR.Body)' - the service may still be initializing; re-check shortly, and see eks-service.log if it persists." }
                                else { Write-Audit -Level WARN -Message "Could not re-probe /eks/health after restart: $($eksR.Message) - the service may still be starting." }
                            } catch {
                                Write-Audit -Level WARN -Message "Health confirmed but could not restart AccessKerberosAuthService: $($_.Exception.Message)"
                            }
                        }

                        # 4) remediate keytab if needed, then re-probe
                        if (-not $keytabOk -or ($eks.Reachable -and -not $eks.Healthy -and $eks.Body -match '(?i)keytab')) {
                            Write-Audit -Level INFO -Message "Generating the keytab via the vendor setupKerberos.ps1 under Windows PowerShell 5.1 (PowerShell 7 lacks System.Web, which breaks the keytab's password step)..."
                            $kt = Invoke-KeytabSetup -ConnectorRoot $connRoot -LogFolder $LogPath -Stamp $stamp
                            if ($kt.Ok) {
                                Write-Audit -Level OK -Message "Keytab OK - $($kt.Message)"
                                try {
                                    Restart-Service -Name 'AccessKerberosAuthService' -Force -ErrorAction Stop
                                    Write-Audit -Level OK -Message "Restarted AccessKerberosAuthService to load the new keytab."
                                    Start-Sleep -Seconds 20
                                    $eks2 = Test-EksHealth -ConnectorRoot $connRoot -ExpectedThumbprint $expectedThumb
                                    if ($eks2.Reachable -and $eks2.Healthy) { Write-Audit -Level OK -Message "/eks/health now returns 'true' - Kerberos Auth Service is healthy." }
                                    elseif ($eks2.Reachable) { Write-Audit -Level WARN -Message "/eks/health still returns: '$($eks2.Body)' - the service may need more time; re-check, and see eks-service.log if it persists." }
                                    else { Write-Audit -Level WARN -Message "Could not re-probe /eks/health: $($eks2.Message)" }
                                } catch {
                                    Write-Audit -Level WARN -Message "Keytab generated but could not restart AccessKerberosAuthService: $($_.Exception.Message). Restart it manually and check /eks/health."
                                }
                            } else {
                                Write-Audit -Level ERROR -Message "Keytab generation did not complete - $($kt.Message)"
                                $exitCode = 1
                            }
                        }
                    }
                }

                Write-Audit -Level INFO -Message "Verify Active state on the Connectors page in the Access console:"
                foreach ($s in $Services) { Write-Audit -Level INFO -Message "  - $s" }
            }
            elseif ($exitCode -in 3010,1641) {
                Write-Audit -Level WARN -Message "Reboot pending - skipping explicit service start. Services should start after the reboot; re-check status afterward."
            }
        }
    }
    }
}
catch {
    Write-Audit -Level ERROR -Message "Unhandled error: $($_.Exception.Message)"
    if ($_.ScriptStackTrace) { Write-Audit -Level ERROR -Message $_.ScriptStackTrace }
    $exitCode = 1
}
finally {
    $result = switch ($exitCode) {
        0    { 'SUCCESS' }
        3010 { 'SUCCESS (reboot required)' }
        1641 { 'SUCCESS (reboot initiated)' }
        default { 'FAILED' }
    }
    Add-AuditRaw "------------------------------------------------------------------------------------"
    Add-AuditRaw " Result   : $result (exit $exitCode)"
    Add-AuditRaw " Ended    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Add-AuditRaw " Audit log: $script:AuditLogPath"
    Add-AuditRaw "===================================================================================="
}

exit $exitCode
