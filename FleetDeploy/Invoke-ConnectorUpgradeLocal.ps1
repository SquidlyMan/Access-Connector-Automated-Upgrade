<#
.SYNOPSIS
    Runs ON an Access Connector server. Upgrades the connector with
    Install-AccessConnector.ps1 to the staged installer version, applies the
    Java4Shell patch (HW-283446) when the job asks for it and checks health.
    Called by Invoke-AccessConnectorUpgrade.ps1 (SSH and WinRM modes), or run
    by hand / as a scheduled task (Stage mode).

    Run with -Help for usage. Windows PowerShell 5.1 compatible.
#>
[CmdletBinding()]
param(
    [string]$JobFile,
    [switch]$SecretsFromStdin,
    [switch]$Prompt,
    [string]$SecretsFile,
    [securestring]$ConfigFilePassword,
    [securestring]$SslCertPassword,
    [securestring]$ServiceAccountPassword,
    [securestring]$ProxyPassword,
    [string]$Schedule,
    [switch]$VerifyOnly,
    [switch]$SkipDomainCheck,
    [switch]$RunAsTask,
    [string]$RunAsUser,
    [securestring]$RunAsPassword,
    [switch]$RepairKeytab,
    [switch]$RepairCertificate,
    [string]$CertFile,
    [switch]$Reapply,
    [switch]$CheckOnly,
    [string]$AuditLog,
    [string]$ErrorLog,
    [switch]$Help
)

$script:Version  = '1.5.1'
$script:UiWidth  = 78
$script:Name     = 'Invoke-ConnectorUpgradeLocal.ps1'
$script:Started  = Get-Date
$script:AuditPath = $null
$script:ErrorPath = $null
$script:AuditWritten = $false
$script:SecretValues = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------- UI helpers
function Initialize-UiStyle {
    $useColor = $true
    if ($env:NO_COLOR) { $useColor = $false }
    try { if ([Console]::IsOutputRedirected) { $useColor = $false } } catch { }
    try { if (-not $Host.UI.SupportsVirtualTerminal) { $useColor = $false } } catch { }
    if ($env:OMNISSA_UI_COLOR) { $useColor = $true }
    $e = [char]27
    $script:ui = @{}
    $keys = 'Reset','Banner','Section','Legal','Rule','Cmd','Flag','Text','Warn','Notice','Ok','Info','Caution','Prompt'
    if ($useColor) {
        $script:ui = @{
            Reset="$e[0m"; Banner="$e[1;97;44m"; Section="$e[1;96;100m"; Legal="$e[1;97;41m"
            Rule="$e[38;5;240m"; Cmd="$e[92m"; Flag="$e[1;93m"; Text="$e[38;5;250m"
            Warn="$e[1;91m"; Notice="$e[1;93m"; Ok="$e[92m"; Info="$e[96m"
            # Notice = bold yellow (the UNSUPPORTED notice); Caution = yellow (warnings);
            # Warn = bold red (alerts and errors); Prompt = purple (questions put to the operator).
            Caution="$e[93m"; Prompt="$e[1;38;5;141m"
        }
    } else { foreach ($k in $keys) { $script:ui[$k] = '' } }
}
function Get-WrappedLines {
    param([string]$Text, [int]$Width = 78, [string]$Indent = '')
    $out = New-Object System.Collections.Generic.List[string]; $cur = ''
    foreach ($w in ($Text -split '\s+' | Where-Object { $_ })) {
        if ($cur) { $cand = "$cur $w" } else { $cand = "$Indent$w" }
        if ($cand.Length -le $Width) { $cur = $cand }
        else { if ($cur) { $out.Add($cur) }; $cur = "$Indent$w" }
    }
    if ($cur) { $out.Add($cur) }
    return $out
}
function Write-UiRule { Write-Host ($script:ui.Rule + ('-' * $script:UiWidth) + $script:ui.Reset) }
function Write-UiSection { param([string]$Text, [switch]$Legal)
    Write-Host ''
    if ($Legal) { $tag = $script:ui.Legal } else { $tag = $script:ui.Section }
    Write-Host ($tag + ' ' + $Text + ' ' + $script:ui.Reset); Write-UiRule }
function Write-UiText { param([string]$T, [string]$I = '  ')
    foreach ($l in (Get-WrappedLines -Text $T -Width $script:UiWidth -Indent $I)) { Write-Host ($script:ui.Text + $l + $script:ui.Reset) } }
function Write-UiWarn { param([string]$T, [string]$I = '  ')
    foreach ($l in (Get-WrappedLines -Text $T -Width $script:UiWidth -Indent $I)) { Write-Host ($script:ui.Warn + $l + $script:ui.Reset) } }
function Write-UiCmd { param([string]$T) Write-Host ($script:ui.Cmd + '  ' + $T + $script:ui.Reset) }
function Write-UiParam { param([string]$Flag, [string]$Desc)
    $col = 24
    $lines = @(Get-WrappedLines -Text $Desc -Width ($script:UiWidth - $col))
    $pad = "  $Flag".PadRight($col); $first = $true
    foreach ($l in $lines) {
        if ($first) { Write-Host ($script:ui.Flag + $pad + $script:ui.Reset + $script:ui.Text + $l + $script:ui.Reset); $first = $false }
        else { Write-Host ($script:ui.Text + (' ' * $col) + $l + $script:ui.Reset) }
    }
}
function Show-LaunchNotice {
    Write-Host ''
    Write-Host ($script:ui.Notice + '  UNSUPPORTED - provided "AS IS", NO WARRANTY. Use at your own risk. Neither' + $script:ui.Reset)
    Write-Host ($script:ui.Notice + '  Omnissa nor the author is liable for any damages. Full text: -Help' + $script:ui.Reset)
    Write-Host ''
}
function Read-UiSecret { param([string]$Prompt)
    # Prompt in the prompt colour; the asterisks standing in for the password are gray.
    # On anything but a colour console this is exactly the plain Read-Host call.
    if (-not $script:ui.Reset -or $Host.Name -ne 'ConsoleHost') { return (Read-Host -AsSecureString $Prompt) }
    Write-Host ($script:ui.Prompt + $Prompt + ': ' + $script:ui.Reset) -NoNewline
    try { [Console]::ForegroundColor = [ConsoleColor]::DarkGray } catch { }
    try { return (Read-Host -AsSecureString) }
    finally { try { [Console]::ResetColor() } catch { } }
}
function Show-Disclaimer {
    Write-UiSection 'LEGAL DISCLAIMER - UNSUPPORTED, USE AT YOUR OWN RISK' -Legal
    Write-UiWarn 'This script is an UNSUPPORTED utility. It is NOT an Omnissa product or offering, and it is not covered by any Omnissa support, maintenance, or service-level agreement.'
    Write-UiWarn 'It is provided "AS IS" and "AS AVAILABLE", WITHOUT WARRANTY OF ANY KIND, express or implied, including but not limited to the implied warranties of merchantability, fitness for a particular purpose, title, and non-infringement.'
    Write-UiWarn 'YOU USE IT ENTIRELY AT YOUR OWN RISK. You are solely responsible for validating its behaviour, for safeguarding the credentials you supply to it, and for any effect it has on your environment or data.'
    Write-UiWarn 'TO THE MAXIMUM EXTENT PERMITTED BY LAW, NEITHER OMNISSA NOR THE AUTHOR SHALL BE LIABLE FOR ANY CLAIM, LOSS, OR DAMAGES WHATSOEVER - direct, indirect, incidental, special, exemplary, or consequential (including loss of data, revenue, or profits) - arising from or in connection with the use of, or inability to use, this script.'
    Write-UiWarn 'Use of the Omnissa products is governed by your agreement with Omnissa; customers assume all responsibility for automated changes to them.'
}
function Show-Help {
    Write-Host ($script:ui.Banner + (" $($script:Name)  v$($script:Version) ").PadRight($script:UiWidth) + $script:ui.Reset)
    Show-Disclaimer
    Write-UiSection 'SYNOPSIS'
    Write-UiText 'Runs on an Access Connector server: upgrades the connector to the staged installer version, applies the Java4Shell patch (HW-283446) when the job asks for it, and checks health.'
    Write-UiText 'After an upgrade of a connector with the Kerberos Auth service and a PFX, it also puts the PFX certificate back: the vendor installer does not carry it through an upgrade and makes a certificate of its own instead.'
    Write-UiSection 'DESCRIPTION'
    Write-UiText 'Reads a job file written by Invoke-AccessConnectorUpgrade.ps1, runs Install-AccessConnector.ps1 from the same folder against locally staged files, then runs the vendor Java4shellPatch.bat and confirms the connector services are running with -XX:-UseBASE64Intrinsics active.'
    Write-UiText 'The job file can also carry installer settings from the fleet file (install folder, FIPS mode, service ports, outbound proxy); they are passed to Install-AccessConnector.ps1 unchanged. A connector already installed with a different FIPS setting is refused: FIPS mode cannot be changed after install.'
    Write-UiText 'Secrets arrive on standard input (SSH mode), as SecureString parameters (WinRM mode), from hidden prompts (-Prompt) or from a file encrypted for the current user (scheduled task).'
    Write-UiSection 'PARAMETERS'
    Write-UiParam '-JobFile <path>' 'Job JSON staged beside this script. Default: job.json in this script folder.'
    Write-UiParam '-Prompt' 'Ask for the passwords at hidden prompts. Use when run by hand.'
    Write-UiParam '-SecretsFromStdin' 'Read four base64 lines (config, PFX, service account, proxy; empty where not needed) from standard input. Used by SSH mode.'
    Write-UiParam '-Schedule <when>' 'With -Prompt: register a one-time scheduled task for the given local time (yyyy-MM-dd HH:mm) under the signed-in account, instead of running now. The task deletes itself, and with it the stored Windows password, when the run ends, or 12 hours after that time if it has not run by then. Its output goes to Logs\task-console_<yyyyMMdd_HHmm>.log. Refused, with nothing written: a time that has passed, and a time given while an earlier scheduled run is still running. Not with -RunAsUser or -RunAsTask.'
    Write-UiParam '-SecretsFile <path>' 'Secrets file written by -Schedule. Deleted after use.'
    Write-UiParam '-...Password <s>' 'Four SecureString parameters, -ConfigFilePassword, -SslCertPassword, -ServiceAccountPassword and -ProxyPassword, carry the passwords when another script calls this one (WinRM mode).'
    Write-UiParam '-VerifyOnly' 'Change nothing; report version, services and patch state.'
    Write-UiParam '-SkipDomainCheck' 'Kerberos connectors only. Upgrade even when this sign-in cannot query Active Directory. The keytab is then left empty until setupKerberos.ps1 is run by a domain admin.'
    Write-UiParam '-RunAsUser <acct>' 'Do the work in a one-time scheduled task under this account (a domain admin) and show its output here. Used by the SSH and WinRM modes for Kerberos connectors, because only a full sign-in can rebuild the keytab. With -RunAsPassword, or -RunAsTask to read both from standard input after the three secrets.'
    Write-UiParam '-RunAsPassword <s>' 'SecureString password for -RunAsUser. It is stored by Task Scheduler only while the task exists; the task removes itself when the work ends.'
    Write-UiParam '-RunAsTask' 'With -SecretsFromStdin: read the -RunAsUser account and its password as two more base64 lines, after the four secrets.'
    Write-UiParam '-CheckOnly' 'With -RepairKeytab: test the sign-in and change nothing. With -RepairCertificate: test the PFX and its password and change nothing.'
    Write-UiParam '-RepairCertificate' 'Do not install anything. Put the certificate from the PFX named by -CertFile on the Kerberos Auth service, using the vendor installKerberosAuthService.bat -updateConfiguration, restart that service and confirm it serves the certificate. The service configuration is copied first and put back if the result is not right. Needs the PFX password (-Prompt, -SecretsFromStdin or -SslCertPassword).'
    Write-UiParam '-CertFile <name>' 'With -RepairCertificate: the PFX file, staged in this script folder.'
    Write-UiParam '-Reapply' 'With -RepairCertificate: install the PFX certificate even when the service already serves it, or when the certificate does not name this server.'
    Write-UiParam '-RepairKeytab' 'Do not install anything. Run the vendor setupKerberos.ps1 to write a new Kerberos keytab (this resets the connector AD account password), then restart the Kerberos service. Needs a domain admin sign-in, so use it with -RunAsUser from a remote session. Add -CheckOnly to test the sign-in and change nothing.'
    Write-UiParam '-AuditLog <path>' 'Append-only audit log. File or folder. Default: Logs folder beside this script.'
    Write-UiParam '-ErrorLog <path>' 'Error log. File or folder. Default: Logs folder beside this script.'
    Write-UiParam '-Help' 'Show this help.'
    Write-UiSection 'EXAMPLES'
    Write-Host ($script:ui.Text + '  # Run now, signed in as a domain admin, typing the passwords' + $script:ui.Reset)
    Write-UiCmd 'powershell -ep Bypass -File .\Invoke-ConnectorUpgradeLocal.ps1 -Prompt'
    Write-Host ''
    Write-Host ($script:ui.Text + '  # Schedule for tonight under the signed-in account' + $script:ui.Reset)
    Write-UiCmd '.\Invoke-ConnectorUpgradeLocal.ps1 -Prompt -Schedule "2026-11-21 22:30"'
    Write-Host ''
    Write-Host ($script:ui.Text + '  # Report state only' + $script:ui.Reset)
    Write-UiCmd '.\Invoke-ConnectorUpgradeLocal.ps1 -VerifyOnly'
    Write-Host ''
    Write-Host ($script:ui.Text + '  # Put the PFX certificate back on the Kerberos service' + $script:ui.Reset)
    Write-UiCmd '.\Invoke-ConnectorUpgradeLocal.ps1 -RepairCertificate -Prompt `'
    Write-UiCmd '    -CertFile connector.example.local.pfx'
    Write-Host ''
    Write-Host ($script:ui.Text + '  # With explicit logs' + $script:ui.Reset)
    Write-UiCmd '.\Invoke-ConnectorUpgradeLocal.ps1 -Prompt -AuditLog C:\Logs\ `'
    Write-UiCmd '    -ErrorLog C:\Logs\'
    Write-UiSection 'OUTPUT'
    Write-UiText 'Progress on screen, a result.json in the Logs folder, and a final line starting RESULT_JSON: that the orchestrator parses. Exit code 0 = success, 1 = failed.'
    Write-UiSection 'LOGGING'
    Write-UiText 'Audit log: one key=value line per run, appended, never truncated. Error log: detail of each failure. Neither contains passwords.'
    Write-UiText 'The vendor installer records the passwords it was given, base64-encoded, in its own AccessConnector_MSI log. After every install this script replaces them with asterisks in the logs in its Logs folder.'
    Write-UiSection 'REQUIREMENTS'
    Write-UiText 'Windows PowerShell 5.1, an elevated session, and the staged payload in this folder. A domain admin sign-in is needed only if the Kerberos keytab must be rebuilt.'
    Write-UiSection 'ABOUT'
    Write-UiText "Version $($script:Version). Created 2026-11-21. MIT License; see the LICENSE file."
    Write-UiSection 'DOCUMENTATION'
    Write-UiText 'Omnissa KB 6001878 (CVE-2026-114938 impact) and the Access Connector installation guide.'
    Write-Host ''
}

# ------------------------------------------------------------ secrets + logs
function Register-Secret { param([string]$Value)
    if (-not [string]::IsNullOrWhiteSpace($Value) -and $Value.Length -ge 6 -and -not $script:SecretValues.Contains($Value)) { $script:SecretValues.Add($Value) } }
function Protect-Text { param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    foreach ($sv in $script:SecretValues) { if ($sv) { $Text = $Text.Replace($sv, '********') } }
    return $Text }
function ConvertTo-PlainText { param([securestring]$S)
    if (-not $S) { return $null }
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($S)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) } }
function Resolve-LogPath { param([string]$Value, [string]$DefaultName)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $v = $Value.Trim()
    if ((Test-Path -LiteralPath $v -PathType Container) -or $v.EndsWith('\') -or $v.EndsWith('/')) { $v = Join-Path $v $DefaultName }
    $dir = Split-Path -Parent $v
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    return $v }
function Say { param([string]$Message, [string]$Level = 'INFO')
    $m = Protect-Text $Message
    $c = $script:ui.Text
    if ($Level -eq 'OK') { $c = $script:ui.Ok } elseif ($Level -eq 'WARN') { $c = $script:ui.Caution } elseif ($Level -eq 'ERROR') { $c = $script:ui.Warn }
    Write-Host ($c + ('[{0}] [{1,-5}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $m) + $script:ui.Reset) }
function Write-ErrorEntry { param([string]$Message, [string]$Stage)
    $m = Protect-Text $Message
    Say $m 'ERROR'
    if (-not $script:ErrorPath) { return }
    $stamp = (Get-Date).ToString('o')
    if (-not (Test-Path -LiteralPath $script:ErrorPath)) { Add-Content -LiteralPath $script:ErrorPath -Encoding utf8 -Value ("# $($script:Name) error log - created $stamp") }
    $st = ''; if ($Stage) { $st = " [$Stage]" }
    Add-Content -LiteralPath $script:ErrorPath -Encoding utf8 -Value "$stamp [ERROR]$st $m" }
function Write-AuditEntry { param([string]$Outcome, [string]$Stage, [string]$Detail)
    if (-not $script:AuditPath -or $script:AuditWritten) { return }
    $f = [ordered]@{ time=(Get-Date).ToString('o'); user=[Environment]::UserName; host=[Environment]::MachineName
        script=$script:Name; version=$script:Version; outcome=$Outcome }
    if ($Stage) { $f['stage'] = $Stage }
    $f['durationSec'] = [math]::Round(((Get-Date) - $script:Started).TotalSeconds, 1)
    if ($Detail) { $f['detail'] = (Protect-Text ($Detail -replace '\s+', ' ')).Trim() }
    $line = ($f.GetEnumerator() | ForEach-Object { $v = [string]$_.Value
        if ($v -match '[\s"]') { '{0}="{1}"' -f $_.Key, ($v -replace '"', "'") } else { '{0}={1}' -f $_.Key, $v } }) -join ' '
    if (-not (Test-Path -LiteralPath $script:AuditPath)) { Add-Content -LiteralPath $script:AuditPath -Encoding utf8 -Value ("# $($script:Name) audit log - append only - created " + (Get-Date).ToString('o')) }
    Add-Content -LiteralPath $script:AuditPath -Value $line -Encoding utf8
    $script:AuditWritten = $true }

# ------------------------------------------------------------- state checks
function Get-ConnectorState {
    $svcMap = @{ DirectorySyncService='AccessDirectorySyncService'; UserAuthService='AccessUserAuthService'
                 KerberosAuthService='AccessKerberosAuthService'; VirtualAppService='AccessVirtualAppService' }
    $folderMap = @{ DirectorySyncService='Directory Sync Service'; UserAuthService='User Auth Service'
                    KerberosAuthService='Kerberos Auth Service'; VirtualAppService='Virtual App Service' }
    $pkg = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
           Where-Object { $_.DisplayName -eq 'Access Connector' } | Select-Object -First 1
    # Where the connector is installed: the installer's record, the folder the job names, the
    # folder a connector service runs from, then the default.
    $root = 'C:\Program Files\Access Connector'
    $cands = @()
    if ($pkg -and $pkg.InstallLocation) { $cands += (Join-Path $pkg.InstallLocation 'Access Connector'); $cands += ([string]$pkg.InstallLocation).TrimEnd('\') }
    if ($script:JobInstallDir) { $cands += (Join-Path $script:JobInstallDir 'Access Connector') }
    foreach ($sv in @(Get-CimInstance Win32_Service -Filter "Name LIKE 'Access%Service'" -ErrorAction SilentlyContinue)) {
        if ($sv.Name -in $svcMap.Values -and [string]$sv.PathName -match '^"?(.*?\\Access Connector)\\') { $cands += $Matches[1] }
    }
    foreach ($c in $cands) { if ($c -and ($c -match '\\Access Connector$') -and (Test-Path -LiteralPath (Join-Path $c 'Support'))) { $root = $c; break } }
    $services = @(); $xml = @()
    foreach ($k in $svcMap.Keys) {
        $s = Get-Service -Name $svcMap[$k] -ErrorAction SilentlyContinue
        if ($s) { $services += [pscustomobject]@{ Key=$k; Name=$s.Name; Status=[string]$s.Status } }
        $f = Join-Path (Join-Path $root $folderMap[$k]) ($k + '.xml')
        if (Test-Path -LiteralPath $f) { $xml += [pscustomobject]@{ Key=$k; Flag=[bool](Select-String -LiteralPath $f -Pattern 'UseBASE64Intrinsics' -Quiet) } }
    }
    $java = @(Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'Access Connector' })
    $ver = ''; if ($pkg) { $ver = [string]$pkg.DisplayVersion }
    $keytab = Join-Path $root 'Kerberos Auth Service\conf\krb5.keytab'
    # the certificate the Kerberos service serves right now (only when that service is running)
    $cert = $null
    if (@($services | Where-Object { $_.Key -eq 'KerberosAuthService' -and $_.Status -eq 'Running' }).Count) {
        $sc = Get-ServedCertificate -Port (Get-EksPort $root) -TimeoutMs 5000
        $cert = [pscustomobject]@{ Ok=$sc.Ok; Thumbprint=$sc.Thumbprint; Subject=$sc.Subject; Issuer=$sc.Issuer; NotAfter=$sc.NotAfter
            Installer=$sc.Installer; NamesServer=(Test-NameCoversServer -Names $sc.Names -Fqdn (Get-ServerFqdn)); Message=$sc.Message }
    }
    [pscustomobject]@{
        Computer = $env:COMPUTERNAME; InstalledVersion = $ver; InstallRoot = $root
        Services = $services; Xml = $xml
        JavaCount = $java.Count
        JavaWithFlag = @($java | Where-Object { $_.CommandLine -match 'UseBASE64Intrinsics' }).Count
        KeytabBytes = $(if (Test-Path -LiteralPath $keytab) { (Get-Item -LiteralPath $keytab).Length } else { -1 })
        Cert = $cert
        FreeGB = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
        RebootPending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
        WhoAmI = (whoami)
    }
}
function Test-DomainReach {
    # True when this session can query Active Directory as the signed-in account. It runs what
    # the vendor setupKerberos.ps1 runs first (Get-ADDomain, which needs AD Web Services), and
    # falls back to an LDAP search when the ActiveDirectory module is not installed yet.
    # A local account, or a remote session that cannot pass its sign-in on, cannot.
    $script:DomainReachDetail = ''
    try {
        if (Get-Module -ListAvailable -Name ActiveDirectory) {
            Import-Module ActiveDirectory -ErrorAction Stop -WarningAction SilentlyContinue
            $null = Get-ADDomain -ErrorAction Stop
            return $true
        }
        $s = New-Object System.DirectoryServices.DirectorySearcher
        $s.Filter = '(objectClass=domainDNS)'; $s.SizeLimit = 1; $s.ClientTimeout = [TimeSpan]::FromSeconds(15)
        if ($s.FindOne()) { return $true }
        $script:DomainReachDetail = 'the directory search returned nothing'
        return $false
    } catch { $script:DomainReachDetail = ([string]$_.Exception.Message -replace '\s+', ' ').Trim(); return $false }
}
function Get-PrivateFolder { param([string]$Here, [string]$Name = 'KeytabBackup', [switch]$Strict)
    # A folder beside this script that only Administrators and SYSTEM can read. With -Strict it
    # throws when that protection could not be set (the folder then holds copies of private keys).
    $base = Join-Path $Here $Name
    $isNew = -not (Test-Path -LiteralPath $base)
    if ($isNew) { $null = New-Item -ItemType Directory -Path $base -Force }
    if ($isNew -or $Strict) {
        $ok = $false; $keep = $global:LASTEXITCODE
        try { $null = & icacls.exe $base /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' 2>&1; $ok = ($LASTEXITCODE -eq 0) } catch { }
        $global:LASTEXITCODE = $keep
        if ($Strict -and -not $ok) { throw "could not restrict $base to Administrators and SYSTEM" }
    }
    return $base }
function Backup-Keytab { param([string]$Root, [string]$Here)
    # Keeps a copy of a usable keytab before anything replaces it. Returns the folder it was
    # copied to, or $null when there was no usable keytab to keep.
    try {
        $conf = Join-Path $Root 'Kerberos Auth Service\conf'
        $kt = Get-Item -LiteralPath (Join-Path $conf 'krb5.keytab') -ErrorAction SilentlyContinue
        if (-not $kt -or $kt.Length -lt 32) { return $null }
        $dest = Join-Path (Get-PrivateFolder $Here) (Get-Date -Format 'yyyyMMdd_HHmmss')
        $null = New-Item -ItemType Directory -Path $dest -Force -ErrorAction Stop
        Copy-Item -LiteralPath $kt.FullName -Destination $dest -Force -ErrorAction Stop
        $copy = Get-Item -LiteralPath (Join-Path $dest 'krb5.keytab') -ErrorAction Stop
        if ($copy.Length -ne $kt.Length) { return $null }
        return $dest
    } catch { return $null }
}
function Invoke-KeytabRepair { param([string]$Here, [string]$LogDir, [bool]$Check)
    # Runs in a domain admin sign-in. Writes a new Kerberos keytab with the vendor script
    # (which resets the connector's AD account password) and restarts the Kerberos service.
    # Returns the process exit code.
    $result = [ordered]@{ Status='Pending'; Computer=$env:COMPUTERNAME; Before=$null; After=$null; InstallerExit=$null; PatchExit=$null; Message=''; DryRun=$Check }
    $before = Get-ConnectorState; $result.Before = $before; $result.After = $before
    $root = $before.InstallRoot
    $conf = Join-Path $root 'Kerberos Auth Service\conf'
    $vendor = Join-Path $root 'Support\scripts\setupKerberos.ps1'
    $account = ([string]$env:COMPUTERNAME).ToLower()
    Say ("Keytab repair on {0}, running as {1}. The keytab is {2} bytes now." -f $env:COMPUTERNAME, $before.WhoAmI, $before.KeytabBytes)
    $problems = @()
    if (-not @($before.Services | Where-Object { $_.Key -eq 'KerberosAuthService' }).Count) { $problems += 'the Kerberos Auth service is not installed on this server' }
    if (-not (Test-Path -LiteralPath $vendor)) { $problems += "the vendor script was not found: $vendor" }
    if (-not (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\ktpass.exe'))) { $problems += 'ktpass.exe is not on this server (Windows feature RSAT-ADDS-Tools)' }
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) { $problems += 'the ActiveDirectory PowerShell module is not installed (Windows feature RSAT-AD-PowerShell)' }
    if (-not $Check -and $before.WhoAmI -match '(?i)^nt authority\\') { $problems += 'a built-in service account cannot reset the AD account password; use a domain admin account' }
    if (-not $problems.Count) {
        if (Test-DomainReach) {
            Say 'This sign-in can query Active Directory.' 'OK'
            # Reading the directory is not the same as being allowed to reset a password in it.
            $sids = @([Security.Principal.WindowsIdentity]::GetCurrent().Groups | ForEach-Object { $_.Value })
            # (not said for the built-in account test aid, which only ever checks)
            if ($before.WhoAmI -notmatch '(?i)^nt authority\\' -and -not @($sids | Where-Object { $_ -match '-(512|519)$' -or $_ -eq 'S-1-5-32-548' }).Count) {
                Say 'This account is not in Domain Admins, Enterprise Admins or Account Operators. Active Directory may refuse the password reset.' 'WARN'
            }
            try {
                $u = Get-ADUser -Identity $account -Properties PasswordLastSet -ErrorAction Stop
                Say ("AD account '{0}' exists; its password was last set {1}. The repair resets it." -f $u.SamAccountName, $u.PasswordLastSet)
            } catch { Say ("AD account '{0}' was not found; the vendor script creates it." -f $account) 'WARN' }
        } else { $problems += "this sign-in ($($before.WhoAmI)) cannot query Active Directory: $($script:DomainReachDetail)" }
    }
    if ($problems.Count) {
        $result.Status = $(if ($Check) { 'DryRunFailed' } else { 'Blocked' }); $result.Message = ($problems -join '; ')
        Write-ErrorEntry ("Keytab repair not started: " + $result.Message + ". Nothing was changed.") 'keytab'
        Write-Result -Result ([pscustomobject]$result) -LogDir $null
        Write-AuditEntry 'FAILED' 'keytab' $result.Message
        return 1
    }
    if ($Check) {
        $result.Status = 'DryRunPassed'
        if ($before.KeytabBytes -ge 32) { Say ("Check only: the keytab already holds keys ({0} bytes), so a real run would leave this server alone. Nothing was changed." -f $before.KeytabBytes) 'OK' }
        else { Say 'Check only: the keytab is empty and the repair can run from this sign-in. Nothing was changed.' 'OK' }
        Write-Result -Result ([pscustomobject]$result) -LogDir $null
        Write-AuditEntry 'SUCCESS' 'keytab' 'check only'
        return 0
    }

    if ($before.KeytabBytes -ge 32) {
        # A repair resets the AD account password. A keytab that already holds keys is left alone.
        $result.Status = 'Success'; $result.Message = "keytab already usable ($($before.KeytabBytes) bytes); not changed"
        Say ("The keytab on this server already holds keys ({0} bytes). Nothing was changed." -f $before.KeytabBytes) 'OK'
        Write-Result -Result ([pscustomobject]$result) -LogDir $null
        Write-AuditEntry 'SUCCESS' 'keytab' $result.Message
        return 0
    }
    $setupLog = Join-Path $conf 'krb5-setup.log'
    $logBefore = 0
    if (Test-Path -LiteralPath $setupLog) { try { $logBefore = ([string](Get-Content -Raw -LiteralPath $setupLog)).Length } catch { } }
    $work = Get-PrivateFolder $Here
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $runner = Join-Path $work "run-keytab_$stamp.ps1"
    $out = Join-Path $work "keytab-console_$stamp.log"
    $empty = Join-Path $work "empty_$stamp.txt"
    Set-Content -LiteralPath $empty -Value '' -Encoding ASCII
    Set-Content -LiteralPath $runner -Encoding ASCII -Value @(
        "`$ErrorActionPreference = 'Continue'",
        "`$env:KERBEROS_AUTH_SVC_CONF_DIR = '$conf'",
        "& '$vendor' -confDir '$conf'",
        "exit `$LASTEXITCODE")
    $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Say 'Running the vendor setupKerberos.ps1 (resets the AD account password and writes a new keytab)...'
    $code = $null
    try {
        $p = Start-Process -FilePath $ps51 -ArgumentList ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $runner) -PassThru -NoNewWindow -RedirectStandardInput $empty -RedirectStandardOutput $out -RedirectStandardError "$out.err"
        $null = $p.Handle
        if ($p.WaitForExit(600000)) { $code = $p.ExitCode }
        else { try { $p.Kill() } catch { }; $problems += 'the vendor script did not finish within 10 minutes and was stopped' }
    } catch { $problems += ('the vendor script could not be started: ' + $_.Exception.Message) }
    Remove-Item -LiteralPath $runner, $empty -Force -ErrorAction SilentlyContinue

    # What the vendor script added to its own log in this run, without lines that could print
    # key material or a password.
    $added = ''
    if (Test-Path -LiteralPath $setupLog) {
        try { $all = [string](Get-Content -Raw -LiteralPath $setupLog); if ($all.Length -gt $logBefore) { $added = $all.Substring($logBefore) } else { $added = $all } } catch { }
    }
    $safe = { param($l) ($l -notmatch '(?i)keylength|0x[0-9a-f]{12}|[-/]pass') }
    @($added -split "`r?`n") | Where-Object { $_ -match 'RESULT|ERROR|exit code|[Ff]ailed' -and (& $safe $_) } | Select-Object -Last 8 | ForEach-Object { Say ('  vendor log: ' + ([string]$_).Trim()) }
    $after = Get-ConnectorState
    # Judge the vendor run by what it reported, not only by the size of the file it left.
    if ($null -ne $code -and $code -ne 0) { $problems += "the vendor script ended with exit code $code" }
    if ($added -match 'Password set failed') { $problems += "the vendor log reports 'Password set failed' (the keytab would not match the AD account)" }
    if ($after.KeytabBytes -lt 32) { $problems += "the keytab is still empty ($($after.KeytabBytes) bytes)" }
    if ($problems.Count) {
        # show the end of the vendor script's own console output, which often names the cause
        foreach ($f in $out, "$out.err") {
            if (Test-Path -LiteralPath $f) { Get-Content -LiteralPath $f -Tail 6 | Where-Object { $_ -and (& $safe $_) } | ForEach-Object { Say ('  vendor output: ' + ([string]$_).Trim()) 'WARN' } }
        }
        $problems += "see $out, $out.err and $setupLog on this server"
    } else {
        Say ("New keytab written: {0} bytes (vendor script exit code {1})." -f $after.KeytabBytes, $code) 'OK'
        try { Restart-Service -Name AccessKerberosAuthService -Force -ErrorAction Stop; Say 'Restarted AccessKerberosAuthService to load the new keytab.' 'OK' }
        catch { $problems += ('could not restart AccessKerberosAuthService: ' + $_.Exception.Message) }
        $until = (Get-Date).AddSeconds(90)
        do { Start-Sleep -Seconds 3; $svc = Get-Service -Name AccessKerberosAuthService -ErrorAction SilentlyContinue } while ($svc -and $svc.Status -ne 'Running' -and (Get-Date) -lt $until)
        if (-not $svc -or $svc.Status -ne 'Running') { $problems += 'AccessKerberosAuthService is not running after the restart' }
        $after = Get-ConnectorState
    }
    $result.After = $after
    if ($problems.Count) {
        $result.Status = 'Unhealthy'; $result.Message = ($problems -join '; ')
        Write-ErrorEntry ("Keytab repair failed: " + $result.Message) 'keytab'
        Write-Result -Result ([pscustomobject]$result) -LogDir $null
        Write-AuditEntry 'FAILED' 'keytab' $result.Message
        return 1
    }
    $result.Status = 'Success'
    Say ("Keytab repaired: {0} bytes; AccessKerberosAuthService is running." -f $after.KeytabBytes) 'OK'
    Write-Result -Result ([pscustomobject]$result) -LogDir $null
    Write-AuditEntry 'SUCCESS' 'keytab' ("keytab bytes " + $after.KeytabBytes)
    return 0
}
function Get-EksPort { param([string]$Root)
    # The port the Kerberos Auth service listens on (443 unless its settings say otherwise).
    $port = 443
    try {
        $t = [string](Get-Content -Raw -LiteralPath (Join-Path $Root 'Kerberos Auth Service\conf\application.properties') -ErrorAction Stop)
        if ($t -match '(?m)^\s*eks\.http\.server\.port\s*=\s*(\d+)') { $port = [int]$Matches[1] }
    } catch { }
    return $port }
function Get-ServerFqdn {
    try { return ([string]([System.Net.Dns]::GetHostEntry($env:COMPUTERNAME)).HostName).ToLower() } catch { return ([string]$env:COMPUTERNAME).ToLower() } }
function Get-CertNames { param($Cert)
    # The DNS names a certificate is valid for. When it lists alternative names, only those count
    # (that is how the Kerberos service's own check, and browsers, read it); otherwise its common name.
    $names = @()
    foreach ($e in $Cert.Extensions) {
        if ($e.Oid.Value -eq '2.5.29.17') { foreach ($m in [regex]::Matches([string]$e.Format($false), '(?i)DNS[^=,]*=\s*([^,\s]+)')) { $names += $m.Groups[1].Value.ToLower() } }
    }
    if (-not $names.Count) {
        $cn = [string]$Cert.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
        if ($cn) { $names += $cn.ToLower() }
    }
    return $names }
function Test-NameCoversServer { param([string[]]$Names, [string]$Fqdn)
    foreach ($n in @($Names)) {
        if (-not $n) { continue }
        if ($n -eq $Fqdn) { return $true }
        if ($n.StartsWith('*.') -and $Fqdn.Contains('.') -and ($Fqdn.Substring($Fqdn.IndexOf('.')) -eq $n.Substring(1))) { return $true }
    }
    return $false }
function Get-ServedCertificate { param([int]$Port = 443, [int]$TimeoutMs = 15000)
    # The certificate the Kerberos Auth service presents on this server, read with a TLS handshake
    # of its own. (Taking it from a web request's validation callback does not work on Windows
    # PowerShell: the object handed to the callback is emptied as soon as the callback returns.)
    $r = [pscustomobject]@{ Ok=$false; Thumbprint=''; Subject=''; Issuer=''; NotAfter=''; Names=@(); Installer=$false; Message='' }
    $tcp = $null; $ssl = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect('localhost', $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { throw "no answer on port $Port within $([int]($TimeoutMs / 1000)) seconds" }
        $tcp.EndConnect($iar)
        $tcp.ReceiveTimeout = $TimeoutMs; $tcp.SendTimeout = $TimeoutMs
        $any = [System.Net.Security.RemoteCertificateValidationCallback]{ $true }
        $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false, $any)
        $ssl.AuthenticateAsClient('localhost', $null, [System.Security.Authentication.SslProtocols]::Tls12, $false)
        if ($null -eq $ssl.RemoteCertificate) { throw 'the service presented no certificate' }
        $der = $ssl.RemoteCertificate.GetRawCertData()
        $sha = [System.Security.Cryptography.SHA1]::Create()
        try { $r.Thumbprint = ([System.BitConverter]::ToString($sha.ComputeHash($der))).Replace('-', '') } finally { $sha.Dispose() }
        $c2 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (,$der)
        $r.Subject = [string]$c2.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
        $r.Issuer  = [string]$c2.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $true)
        $r.NotAfter = $c2.NotAfter.ToString('yyyy-MM-dd')
        $r.Names = @(Get-CertNames $c2)
        # the certificate the installer makes for itself is issued by "Internal Root CA <date and time>"
        $r.Installer = [bool]($r.Issuer -match '^Internal Root CA \d')
        $c2.Reset()
        if ($r.Thumbprint -notmatch '^[0-9A-F]{40}$') { throw 'the certificate could not be read' }
        $r.Ok = $true
    } catch {
        $r.Message = ([string]$_.Exception.Message -replace '\s+', ' ').Trim()
        if ($_.Exception.InnerException) { $r.Message += ' / ' + ([string]$_.Exception.InnerException.Message -replace '\s+', ' ').Trim() }
    } finally { if ($ssl) { try { $ssl.Dispose() } catch { } }; if ($tcp) { try { $tcp.Close() } catch { } } }
    return $r }
function Wait-ServedCertificate { param([int]$Port, [int]$Seconds = 180)
    # Waits for the service to answer after a start or restart, then returns what it serves.
    $until = (Get-Date).AddSeconds($Seconds); $s = $null
    do { $s = Get-ServedCertificate -Port $Port; if ($s.Ok) { break }; Start-Sleep -Seconds 5 } while ((Get-Date) -lt $until)
    return $s }
function Get-EksHealth { param([int]$Port)
    # The text the service's own health page returns ('true' when healthy).
    try {
        $req = [System.Net.HttpWebRequest]::Create("https://localhost:$Port/eks/health/")
        $req.Timeout = 15000
        $req.ServerCertificateValidationCallback = [System.Net.Security.RemoteCertificateValidationCallback]{ $true }
        $resp = $null
        try { $resp = $req.GetResponse() } catch [System.Net.WebException] { if ($_.Exception.Response) { $resp = $_.Exception.Response } else { throw } }
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $b = ([string]$sr.ReadToEnd()).Trim(); $sr.Dispose(); $resp.Close()
        return $b
    } catch { return ('no answer: ' + ([string]$_.Exception.Message -replace '\s+', ' ').Trim()) } }
function Read-PfxInfo { param([string]$Path, [securestring]$Password)
    # Opens the PFX in memory only (nothing is added to a Windows certificate store).
    $r = [pscustomobject]@{ Ok=$false; Thumbprint=''; Subject=''; Issuer=''; NotBefore=$null; NotAfter=$null; Names=@(); Count=0; Message='' }
    $col = $null
    try {
        $flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
        $col = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
        $col.Import($Path, (ConvertTo-PlainText $Password), $flags)
        $r.Count = $col.Count
        $leaf = $null
        foreach ($c in $col) { if ($c.HasPrivateKey) { $leaf = $c; break } }
        if (-not $leaf) { throw 'the file holds no certificate with a private key' }
        $r.Thumbprint = [string]$leaf.Thumbprint
        $r.Subject = [string]$leaf.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
        $r.Issuer  = [string]$leaf.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $true)
        $r.NotBefore = $leaf.NotBefore; $r.NotAfter = $leaf.NotAfter
        $r.Names = @(Get-CertNames $leaf)
        $r.Ok = $true
    } catch { $r.Message = ([string]$_.Exception.Message -replace '\s+', ' ').Trim() }
    finally { if ($col) { foreach ($c in $col) { try { $c.Reset() } catch { } } } }
    return $r }
function Test-CertificatePlan { param([string]$Root, [string]$PfxPath, [securestring]$Password, [bool]$Reapply, [int]$WaitSeconds = 60)
    # Everything that can be checked before the certificate is changed. Changes nothing.
    $o = [pscustomobject]@{ Problems=@(); Warnings=@(); Pfx=$null; Served=$null; Current=$false; NamesServer=$true; HealthBefore=''; Fqdn=(Get-ServerFqdn) }
    $bat = Join-Path $Root 'Support\installKerberosAuthService.bat'
    $common = Join-Path $Root 'Support\install-common.bat'
    if (-not (Get-Service -Name AccessKerberosAuthService -ErrorAction SilentlyContinue)) { $o.Problems += 'the Kerberos Auth service is not installed on this server'; return $o }
    if (-not (Test-Path -LiteralPath $PfxPath -PathType Leaf)) { $o.Problems += "the PFX file was not found: $PfxPath"; return $o }
    if (-not $Password -or $Password.Length -eq 0) { $o.Problems += 'no PFX password was given'; return $o }
    $pfx = Read-PfxInfo -Path $PfxPath -Password $Password
    $o.Pfx = $pfx
    if (-not $pfx.Ok) { $o.Problems += "the PFX could not be opened with that password ($($pfx.Message))"; return $o }
    $port = Get-EksPort $Root
    $o.Served = Wait-ServedCertificate -Port $port -Seconds $WaitSeconds
    if ($o.Served.Ok) { $o.HealthBefore = Get-EksHealth -Port $port }
    if ($o.Served.Ok -and $o.Served.Thumbprint -eq $pfx.Thumbprint) { $o.Current = $true }
    $o.NamesServer = [bool](Test-NameCoversServer -Names $pfx.Names -Fqdn $o.Fqdn)
    $nameText = "the PFX certificate does not name this server ($($o.Fqdn)); it names: " + (@($pfx.Names) -join ', ')
    $now = Get-Date
    if ($pfx.NotAfter -lt $now) { $o.Problems += "the PFX certificate expired on $($pfx.NotAfter.ToString('yyyy-MM-dd'))" }
    elseif ($pfx.NotAfter -lt $now.AddDays(30)) { $o.Warnings += "the PFX certificate expires on $($pfx.NotAfter.ToString('yyyy-MM-dd'))" }
    if ($pfx.NotBefore -gt $now) { $o.Problems += "the PFX certificate is not valid until $($pfx.NotBefore.ToString('yyyy-MM-dd'))" }
    if ($pfx.Count -lt 2) { $o.Warnings += 'the PFX holds only the server certificate, not the certificate of the authority that issued it' }
    if ($o.Current -and -not $Reapply) {
        # nothing will be changed, so what follows only matters as a note
        if (-not $o.NamesServer) { $o.Warnings += $nameText + '. The service''s own health check fails with it and the Access console shows a warning.' }
        return $o
    }
    # ---- from here on: checks for a change that is about to be made
    if (-not (Test-Path -LiteralPath $bat) -or -not (Test-Path -LiteralPath $common)) { $o.Problems += "the vendor scripts were not found under $Root\Support" }
    else {
        # this relies on how the vendor scripts of this connector version take a certificate
        $t1 = [string](Get-Content -Raw -LiteralPath $bat); $t2 = [string](Get-Content -Raw -LiteralPath $common)
        if ($t1 -notmatch '-updateConfiguration' -or $t2 -notmatch '-sslCertPass' -or $t2 -notmatch 'ImportCertCmd') { $o.Problems += 'the vendor install scripts on this server do not take a certificate the way this tool expects (another connector version?)' }
    }
    $props = Join-Path $Root 'Support\scripts\install.properties'
    if ((Test-Path -LiteralPath $props) -and ([string](Get-Content -Raw -LiteralPath $props) -match '(?mi)^[ \t]*FIPS_ENABLED[ \t]*=[ \t]*true')) { $o.Problems += 'this connector runs in FIPS mode, which this tool has not been tested with' }
    if ((Test-Path -LiteralPath $props) -and ([string](Get-Content -Raw -LiteralPath $props) -match '(?mi)^[ \t]*PROXY_USER[ \t]*=[ \t]*\S')) { $o.Problems += 'this connector uses a proxy with a user name; the vendor script would clear the stored proxy password, so use the installer''s Add/Remove Services instead' }
    if (-not $o.NamesServer) {
        if ($Reapply) { $o.Warnings += $nameText + ' (continuing because -Reapply was given; the service''s own health check will fail with it, so that check is not applied)' }
        else { $o.Problems += $nameText + '. With it the service''s own health check fails and the Access console shows a warning.' }
    }
    # The vendor script receives the password and the file name as text typed to cmd.exe. Only plain
    # printable characters arrive unchanged, and %, ^ and the double quote are changed on the way.
    # (It deletes the current certificate before importing, so a changed password must be caught here.)
    $plain = ConvertTo-PlainText $Password
    if ($plain -match '[^\x20-\x7E]' -or $plain -match '[%^"]') { $o.Problems += 'the PFX password contains a character the vendor script cannot pass on unchanged (%, ^, a double quote, or a character outside plain printable text); export the PFX again with a password without those' }
    $plain = $null
    if ($PfxPath -match '[^\x20-\x7E]' -or $PfxPath -match '[%^"!]') { $o.Problems += "the PFX path contains a character the vendor script cannot take: $PfxPath" }
    if (-not $o.Served.Ok) { $o.Warnings += "the Kerberos service does not answer on port $port now ($($o.Served.Message))" }
    elseif ($o.HealthBefore -ne 'true') { $o.Warnings += "the service health page returns '$($o.HealthBefore)' before the change, so it is not used to judge the result" }
    return $o }
function Invoke-VendorCertImport { param([string]$Root, [string]$PfxPath, [securestring]$Password)
    # Runs the vendor installKerberosAuthService.bat -updateConfiguration (what the installer's own
    # maintenance mode runs). The command is typed to cmd.exe on its standard input, so the password
    # is not on any process command line; the vendor script hands it to its Java tool in a variable.
    $bat = Join-Path $Root 'Support\installKerberosAuthService.bat'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $psi.Arguments = '/d /q /v:off /k'
    $psi.WorkingDirectory = Join-Path $Root 'Support'
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
    # One line, so nothing the vendor script starts can swallow a later one. %^errorlevel% is read
    # by "call" after the script has ended. Written as plain bytes (no byte-order mark).
    $plain = ConvertTo-PlainText $Password
    $line = '"{0}" -updateConfiguration -sslCert "{1}" -sslCertPass "{2}" & call echo __VENDOR_EXIT__=%^errorlevel%& exit' -f $bat, $PfxPath, $plain
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($line + "`r`n")
    $line = $null
    $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length); $p.StandardInput.BaseStream.Flush()
    [Array]::Clear($bytes, 0, $bytes.Length)
    $p.StandardInput.Close()
    $r = @{ Code = $null; TimedOut = $false; Failed = $false; Text = '' }
    if (-not $p.WaitForExit(600000)) {
        # stop cmd.exe and everything it started, so nothing keeps writing in the service folder
        try { $null = & (Join-Path $env:SystemRoot 'System32\taskkill.exe') /PID $p.Id /T /F 2>&1 } catch { }
        try { if (-not $p.HasExited) { $p.Kill() } } catch { }
        $r.TimedOut = $true; $plain = $null; return $r
    }
    $p.WaitForExit()
    $text = ([string]$so.Result) + "`r`n" + ([string]$se.Result)
    # mask the password itself whatever its length, then everything else this script knows as a secret
    if ($plain -and $plain.Length -ge 4) { $text = $text.Replace($plain, '********') } elseif ($plain) { $text = '(output not kept: the password is too short to mask reliably)' + $(if ($text -match '__VENDOR_EXIT__=(-?\d+)') { "`r`n__VENDOR_EXIT__=" + $Matches[1] } else { '' }) + $(if ($text -match 'Failed to install the Kerberos Auth Service') { "`r`nFailed to install the Kerberos Auth Service" } else { '' }) }
    $plain = $null
    $r.Text = Protect-Text $text
    if ($r.Text -match '__VENDOR_EXIT__=(-?\d+)') { $r.Code = [int]$Matches[1] }
    # The vendor script prints this whenever its configuration step (which holds the import) fails.
    # Its exit code is NOT a sign of failure: with -updateConfiguration the last thing it runs is
    # the service wrapper's "install", which reports an error because the service already exists.
    $r.Failed = [bool]($r.Text -match 'Failed to install the Kerberos Auth Service')
    return $r }
function Get-FolderPrint { param([string]$Dir)
    # name -> "length:sha256" for every file below a folder (logs left out)
    $map = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($Dir.Length).TrimStart('\')
        if ($rel -match '^(logs|temp|tmp)\\') { continue }
        $h = ''
        try { $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256 -ErrorAction Stop).Hash } catch { $h = 'unreadable' }
        $map[$rel.ToLower()] = "$($f.Length):$h"
    }
    return $map }
function Get-PropertyMap { param([string]$File)
    $map = @{}
    foreach ($l in @(Get-Content -LiteralPath $File -ErrorAction SilentlyContinue)) {
        if ($l -match '^\s*[#!]' -or $l -notmatch '=') { continue }
        $k = $l.Substring(0, $l.IndexOf('=')).Trim(); if ($k) { $map[$k] = $l.Substring($l.IndexOf('=') + 1).Trim() }
    }
    return $map }
function Stop-KerberosService {
    # Stops the service and waits until Windows reports it stopped. Returns '' or what went wrong.
    try { Stop-Service -Name AccessKerberosAuthService -Force -ErrorAction Stop } catch { $first = $_.Exception.Message }
    $until = (Get-Date).AddSeconds(90)
    do { $svc = Get-Service -Name AccessKerberosAuthService -ErrorAction SilentlyContinue; if ($svc -and $svc.Status -eq 'Stopped') { return '' }; Start-Sleep -Seconds 2 } while ((Get-Date) -lt $until)
    if ($first) { return [string]$first }
    return "the service is still $($svc.Status) after 90 seconds" }
function Start-KerberosService {
    try { Start-Service -Name AccessKerberosAuthService -ErrorAction Stop } catch { $first = $_.Exception.Message }
    $until = (Get-Date).AddSeconds(120)
    do { $svc = Get-Service -Name AccessKerberosAuthService -ErrorAction SilentlyContinue; if ($svc -and $svc.Status -eq 'Running') { return '' }; Start-Sleep -Seconds 3 } while ((Get-Date) -lt $until)
    if ($first) { return [string]$first }
    return "the service is $($svc.Status) after 120 seconds" }
function Restore-KerberosConf { param([string]$Root, [string]$Backup, $ServedBefore)
    # Puts a copied configuration back: stops the service, moves aside files that were not there
    # before, copies the saved files over, checks them, and starts the service. Returns a note.
    $svcDir = Join-Path $Root 'Kerberos Auth Service'
    $conf = Join-Path $svcDir 'conf'
    $saved = Join-Path $Backup 'conf'
    $notes = @(); $bad = $false
    $e = Stop-KerberosService
    if ($e) { return [pscustomobject]@{ Ok=$false; Note="the previous configuration was NOT put back, because the service could not be stopped ($e); it is in $Backup" } }
    try {
        # files the failed change created are moved next to the copy, not deleted
        $have = Get-FolderPrint $saved
        $aside = Join-Path $Backup 'created-by-the-failed-change'
        foreach ($f in @(Get-ChildItem -LiteralPath $conf -Recurse -File -Force -ErrorAction SilentlyContinue)) {
            $rel = $f.FullName.Substring($conf.Length).TrimStart('\')
            if (-not $have.ContainsKey($rel.ToLower())) {
                $dest = Join-Path $aside $rel; $dd = Split-Path -Parent $dest
                if (-not (Test-Path -LiteralPath $dd)) { $null = New-Item -ItemType Directory -Path $dd -Force }
                Move-Item -LiteralPath $f.FullName -Destination $dest -Force -ErrorAction Stop
            }
        }
        Copy-Item -Path (Join-Path $saved '*') -Destination $conf -Recurse -Force -ErrorAction Stop
        $xml = Join-Path $Backup 'KerberosAuthService.xml'
        if (Test-Path -LiteralPath $xml) { Copy-Item -LiteralPath $xml -Destination (Join-Path $svcDir 'KerberosAuthService.xml') -Force -ErrorAction Stop }
        $now = Get-FolderPrint $conf
        $diff = @($have.Keys | Where-Object { $now[$_] -ne $have[$_] })
        if ($diff.Count) { $bad = $true; $notes += ("after copying back, these files still differ from the copy: " + ($diff -join ', ')) }
    } catch { $bad = $true; $notes += ("copying the previous configuration back failed: " + $_.Exception.Message) }
    $e = Start-KerberosService
    if ($e) { $bad = $true; $notes += "the service did not start afterwards ($e)" }
    else {
        $back = Wait-ServedCertificate -Port (Get-EksPort $Root) -Seconds 180
        if (-not $back.Ok) { $bad = $true; $notes += "the service does not answer on its port yet ($($back.Message))" }
        elseif ($ServedBefore -and $ServedBefore.Ok -and $back.Thumbprint -ne $ServedBefore.Thumbprint) { $bad = $true; $notes += "the service serves '$($back.Subject)' issued by '$($back.Issuer)', not what it served before" }
        else { $notes += "the service serves '$($back.Subject)' issued by '$($back.Issuer)' again" }
    }
    if ($bad) { return [pscustomobject]@{ Ok=$false; Note=('the previous configuration could not be fully put back: ' + ($notes -join '; ') + "; the copy is in $Backup") } }
    return [pscustomobject]@{ Ok=$true; Note=('the previous configuration was put back; ' + ($notes -join '; ')) } }
function Resume-InterruptedCertChange { param([string]$Here, [string]$Root, [bool]$Fix)
    # A certificate change that was cut short (a dropped session) leaves a marker file naming the
    # copy of the configuration. Reports it; with $Fix, puts the copy back.
    $marker = Join-Path $Here 'cert-change-in-progress.json'
    if (-not (Test-Path -LiteralPath $marker)) { return }
    $m = $null; try { $m = Get-Content -Raw -LiteralPath $marker | ConvertFrom-Json } catch { }
    if (-not $m -or -not $m.Backup -or -not (Test-Path -LiteralPath (Join-Path ([string]$m.Backup) 'conf'))) {
        Say "A certificate change on this server was cut short earlier, but its record ($marker) cannot be used. Check the Kerberos Auth service by hand." 'WARN'; return }
    Say ("A certificate change started {0} on this server did not finish. The configuration from before it is in {1}." -f $m.Started, $m.Backup) 'WARN'
    if (-not $Fix) { return }
    $r = Restore-KerberosConf -Root $Root -Backup ([string]$m.Backup) -ServedBefore $null
    if ($r.Ok) { Say ('Unfinished change undone: ' + $r.Note + '.') 'OK'; Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue }
    else { Say ('Unfinished change: ' + $r.Note + '.') 'WARN' } }
function Set-KerberosCertificate { param([string]$Root, [string]$PfxPath, [securestring]$Password, [string]$Here, $Plan)
    # Puts the PFX certificate on the Kerberos Auth service with the vendor's own script. The
    # service's conf folder is copied first and put back if the result is not right.
    $o = [pscustomobject]@{ Ok=$false; Message=''; Served=$null; Restored=$false; Backup=$null }
    $svcName = 'AccessKerberosAuthService'
    $svcDir = Join-Path $Root 'Kerberos Auth Service'
    $conf = Join-Path $svcDir 'conf'
    $port = Get-EksPort $Root
    $pfx = $Plan.Pfx
    $acctBefore = [string](Get-CimInstance Win32_Service -Filter "Name='$svcName'" -ErrorAction SilentlyContinue).StartName
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $work = $null
    try { $work = Get-PrivateFolder $Here 'CertBackup' -Strict } catch { $o.Message = 'no private folder for the copy of the configuration could be made, so nothing was changed: ' + $_.Exception.Message; return $o }
    $bk = Join-Path $work "change_$stamp"
    if (Test-Path -LiteralPath $bk) { $o.Message = "the folder for the copy already exists ($bk), so nothing was changed; run again"; return $o }
    $printBefore = $null
    try {
        $null = New-Item -ItemType Directory -Path $bk -Force -ErrorAction Stop
        Copy-Item -LiteralPath $conf -Destination (Join-Path $bk 'conf') -Recurse -Force -ErrorAction Stop
        $xml = Join-Path $svcDir 'KerberosAuthService.xml'
        if (Test-Path -LiteralPath $xml) { Copy-Item -LiteralPath $xml -Destination $bk -Force -ErrorAction Stop }
        $printBefore = Get-FolderPrint $svcDir
        $saved = Get-FolderPrint (Join-Path $bk 'conf')
        $confNow = Get-FolderPrint $conf
        $miss = @($confNow.Keys | Where-Object { $saved[$_] -ne $confNow[$_] })
        if ($miss.Count) { throw ("the copy does not match for: " + ($miss -join ', ')) }
    } catch { $o.Message = 'the service configuration could not be copied before the change, so nothing was changed: ' + $_.Exception.Message; return $o }
    $o.Backup = $bk
    Say ("The Kerberos service configuration ({0} files) was copied to {1}" -f $confNow.Count, $bk)
    $propsBefore = Get-PropertyMap (Join-Path $conf 'application.properties')

    $e = Stop-KerberosService
    if ($e) {
        $e2 = Start-KerberosService
        $o.Message = "could not stop ${svcName} ($e), so nothing was changed" + $(if ($e2) { "; it is not running now ($e2)" } else { '' }); return $o
    }
    Say "Stopped $svcName."
    # from here until the end a cut-short run leaves this marker, and the next run puts the copy back
    $marker = Join-Path $Here 'cert-change-in-progress.json'
    try { Set-Content -LiteralPath $marker -Encoding ASCII -Value (([pscustomobject]@{ Started=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Backup=$bk }) | ConvertTo-Json -Compress) } catch { }

    $problems = @(); $fatal = $false
    Say 'Running the vendor installKerberosAuthService.bat -updateConfiguration with the PFX...'
    $run = $null
    try { $run = Invoke-VendorCertImport -Root $Root -PfxPath $PfxPath -Password $Password }
    catch { $problems += ('the vendor script could not be started: ' + $_.Exception.Message); $fatal = $true }
    $out = Join-Path $work "cert-console_$stamp.log"
    if ($run) {
        try { Set-Content -LiteralPath $out -Value ([string]$run.Text) -Encoding utf8 } catch { }
        if ($run.TimedOut) { $problems += 'the vendor script did not finish within 10 minutes and was stopped'; $fatal = $true }
        elseif ($null -eq $run.Code) { $problems += 'the vendor script did not run to its end'; $fatal = $true }
        elseif ($run.Failed) { $problems += "the vendor script reported 'Failed to install the Kerberos Auth Service'"; $fatal = $true }
        elseif ($run.Code -ne 0) { Say ("The vendor script ended with exit code {0}. That code comes from its last step, which re-registers the Windows service that already exists; the result is judged by what the service serves." -f $run.Code) }
        if ($fatal) { @(([string]$run.Text) -split "`r?`n") | Where-Object { $_.Trim() -and $_ -notmatch '__VENDOR_EXIT__|(?i)passw' } | Select-Object -Last 8 | ForEach-Object { Say ('  vendor output: ' + ([string]$_).Trim()) 'WARN' } }
    }

    $served = $null
    if (-not $fatal) {
        # what the vendor script changed besides the certificate (it rewrites several settings)
        $propsAfter = Get-PropertyMap (Join-Path $conf 'application.properties')
        $keys = @(@($propsBefore.Keys) + @($propsAfter.Keys) | Sort-Object -Unique | Where-Object { $_ -ne 'eks.keystore.password.encrypted' -and ([string]$propsBefore[$_]) -ne ([string]$propsAfter[$_]) })
        if ($keys.Count) { $problems += ("the vendor script changed other settings of the service: " + ($keys -join ', ')) }
        $printMid = Get-FolderPrint $svcDir
        foreach ($f in 'conf\proxy.json', 'conf\master.key', 'conf\krb5.keytab', 'kerberosauthservice.xml') {
            if ($printBefore.ContainsKey($f) -and $printMid[$f] -ne $printBefore[$f]) { $problems += "the vendor script changed $f" }
        }
        $touched = @(@($printBefore.Keys) + @($printMid.Keys) | Sort-Object -Unique | Where-Object { $printBefore[$_] -ne $printMid[$_] })
        if ($touched.Count) { Say ("Files the vendor script changed, added or removed: " + ($touched -join ', ')) }

        $e = Start-KerberosService
        if ($e) { $problems += "$svcName did not start after the change ($e)" } else { Say "Started $svcName." }
        $served = Wait-ServedCertificate -Port $port -Seconds 180
        $o.Served = $served
        if (-not $served.Ok) { $problems += "the service does not answer on port $port after the change ($($served.Message))" }
        elseif ($served.Thumbprint -ne $pfx.Thumbprint) { $problems += "the service serves a different certificate than the PFX (it serves '$($served.Subject)' issued by '$($served.Issuer)')" }
        elseif ($Plan.HealthBefore -eq 'true' -and $Plan.NamesServer) {
            # the health page needs the service fully up; give it up to three minutes
            $until = (Get-Date).AddSeconds(180); $h = ''
            do { $h = Get-EksHealth -Port $port; if ($h -eq 'true') { break }; Start-Sleep -Seconds 5 } while ((Get-Date) -lt $until)
            if ($h -ne 'true') { $problems += "the service health page returns '$h' instead of 'true'" }
        }
        $acctAfter = [string](Get-CimInstance Win32_Service -Filter "Name='$svcName'" -ErrorAction SilentlyContinue).StartName
        if ($acctBefore -and $acctAfter -ne $acctBefore) { $problems += "the service now runs as '$acctAfter' instead of '$acctBefore' (set it back in Services)" }
    }

    if (-not $problems.Count) {
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
        $o.Ok = $true
        $o.Message = "serving '$($served.Subject)' issued by '$($served.Issuer)', valid to $($served.NotAfter)"
        return $o
    }
    # ---- not right: put the copied configuration back
    Say ('The certificate change did not end well: ' + ($problems -join '; ') + '. Putting the previous configuration back...') 'WARN'
    $back = Restore-KerberosConf -Root $Root -Backup $bk -ServedBefore $Plan.Served
    $o.Restored = [bool]$back.Ok
    if ($back.Ok) { Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue }
    $o.Message = ($problems -join '; ') + '; ' + $back.Note + "; vendor output: $out"
    return $o }
function Invoke-CertificateRepair { param([string]$Here, [string]$LogDir, [bool]$Check, [string]$PfxPath, [securestring]$Password, [bool]$Reapply)
    # Installs nothing. Puts the PFX certificate on the Kerberos Auth service of this server and
    # proves it by reading the certificate the service then serves. Returns the process exit code.
    $result = [ordered]@{ Status='Pending'; Computer=$env:COMPUTERNAME; Before=$null; After=$null; InstallerExit=$null; PatchExit=$null; Message=''; DryRun=$Check }
    $before = Get-ConnectorState; $result.Before = $before; $result.After = $before
    $root = $before.InstallRoot
    Say ("Kerberos certificate on {0}, running as {1}." -f $env:COMPUTERNAME, $before.WhoAmI)
    Resume-InterruptedCertChange -Here $Here -Root $root -Fix (-not $Check)
    $plan = Test-CertificatePlan -Root $root -PfxPath $PfxPath -Password $Password -Reapply $Reapply
    if ($plan.Served -and $plan.Served.Ok) { Say ("Serving now: '{0}' issued by '{1}', valid to {2}{3}." -f $plan.Served.Subject, $plan.Served.Issuer, $plan.Served.NotAfter, $(if ($plan.Served.Installer) { ' (the installer''s own certificate)' } else { '' })) }
    if ($plan.Pfx -and $plan.Pfx.Ok) { Say ("PFX: '{0}' issued by '{1}', valid to {2}; names: {3}." -f $plan.Pfx.Subject, $plan.Pfx.Issuer, $plan.Pfx.NotAfter.ToString('yyyy-MM-dd'), (@($plan.Pfx.Names) -join ', ')) }
    foreach ($w in $plan.Warnings) { Say ('Note: ' + $w) 'WARN' }
    if ($plan.Problems.Count) {
        $result.Status = $(if ($Check) { 'DryRunFailed' } else { 'Blocked' }); $result.Message = ($plan.Problems -join '; ')
        Write-ErrorEntry ("Certificate not changed: " + $result.Message + ". Nothing was changed.") 'certificate'
        Write-Result -Result ([pscustomobject]$result) -LogDir $null
        Write-AuditEntry 'FAILED' 'certificate' $result.Message
        return 1
    }
    if ($plan.Current -and -not $Reapply) {
        $result.Status = $(if ($Check) { 'DryRunPassed' } else { 'Success' }); $result.Message = 'already serving the PFX certificate; not changed'
        Say 'The service already serves the PFX certificate. Nothing was changed.' 'OK'
        Write-Result -Result ([pscustomobject]$result) -LogDir $null
        Write-AuditEntry 'SUCCESS' 'certificate' $result.Message
        return 0
    }
    if ($Check) {
        $result.Status = 'DryRunPassed'
        Say 'Check only: the PFX opens with that password and a real run would put its certificate on the service. Nothing was changed.' 'OK'
        Write-Result -Result ([pscustomobject]$result) -LogDir $null
        Write-AuditEntry 'SUCCESS' 'certificate' 'check only'
        return 0
    }
    $set = Set-KerberosCertificate -Root $root -PfxPath $PfxPath -Password $Password -Here $Here -Plan $plan
    $result.After = Get-ConnectorState
    if (-not $set.Ok) {
        $result.Status = 'Unhealthy'; $result.Message = $set.Message
        Write-ErrorEntry ("Certificate change failed: " + $set.Message) 'certificate'
        Write-Result -Result ([pscustomobject]$result) -LogDir $null
        Write-AuditEntry 'FAILED' 'certificate' $set.Message
        return 1
    }
    $result.Status = 'Success'; $result.Message = $set.Message
    Say ("Certificate installed: " + $set.Message + ".") 'OK'
    Write-Result -Result ([pscustomobject]$result) -LogDir $null
    Write-AuditEntry 'SUCCESS' 'certificate' $set.Message
    return 0
}
function Protect-InstallerLog { param([string]$Path, [string[]]$Known = @(), [switch]$CountOnly)
    # The vendor installer writes the passwords it was given into its own log, base64-encoded, in
    # the lines that set up its custom actions. This replaces every copy of those values with
    # asterisks and keeps the file's encoding and date. Returns how many were replaced (or found,
    # with -CountOnly); -1 when the file could not be handled, in which case it is left as it was.
    $tmp = $null
    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -lt 4) { return 0 }
        if ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
            $enc = [Text.Encoding]::Unicode
            $txt = $enc.GetString($bytes)
            # only rewrite a file that comes back byte for byte the same
            if (-not [System.Linq.Enumerable]::SequenceEqual([byte[]]$enc.GetBytes($txt), [byte[]]$bytes)) { return -1 }
        } else {
            # one byte = one character, both ways, whatever the file's real code page is
            $enc = [Text.Encoding]::GetEncoding(28591)
            $txt = $enc.GetString($bytes)
        }
        $vals = New-Object System.Collections.Generic.List[string]
        foreach ($m in [regex]::Matches($txt, "Adding AW\w+ property\. Its value is '([^']*)'")) {
            foreach ($f in $m.Groups[1].Value.Split(';')) {
                if ($f -notmatch '^[A-Za-z0-9+/]{6,}={0,2}$' -or ($f.Length % 4)) { continue }
                try { $d = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($f)) } catch { continue }
                # a real value decodes to ordinary text; a name that merely looks encoded does not
                if ($d.Length -ge 4 -and $d -notmatch '[^\x20-\x7E]' -and $d -notmatch '^[A-Za-z]:\\' -and -not $vals.Contains($f)) { $vals.Add($f) }
            }
        }
        $plain = New-Object System.Collections.Generic.List[string]
        foreach ($k in $Known) {
            if (-not $k -or $k.Length -lt 6) { continue }
            if (-not $plain.Contains($k)) { $plain.Add($k) }
            foreach ($v in [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($k)), [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($k))) { if (-not $vals.Contains($v)) { $vals.Add($v) } }
        }
        $n = 0
        foreach ($v in @($vals | Sort-Object -Property Length -Descending)) {
            $c = [regex]::Matches($txt, [regex]::Escape($v)).Count
            if ($c) { $n += $c; if (-not $CountOnly) { $txt = $txt.Replace($v, '********') } }
        }
        # the password as typed: only where it stands as a value (after = ; or a quote), so a
        # password that is also an ordinary word does not blank that word throughout the log
        foreach ($v in @($plain | Sort-Object -Property Length -Descending)) {
            $rx = '(?<=[=;''"])' + [regex]::Escape($v) + '(?![A-Za-z0-9])'
            $c = [regex]::Matches($txt, $rx).Count
            if ($c) { $n += $c; if (-not $CountOnly) { $txt = [regex]::Replace($txt, $rx, '********') } }
        }
        if ($n -and -not $CountOnly) {
            $when = (Get-Item -LiteralPath $Path).LastWriteTime
            # write beside the log and swap it in, so a failed write cannot damage the original
            $tmp = $Path + '.cleaning'
            [IO.File]::WriteAllBytes($tmp, $enc.GetBytes($txt))
            try { [IO.File]::Replace($tmp, $Path, [NullString]::Value) }
            catch { [IO.File]::Copy($tmp, $Path, $true); [IO.File]::Delete($tmp) }
            $tmp = $null
            try { (Get-Item -LiteralPath $Path).LastWriteTime = $when } catch { }
        }
        return $n
    } catch {
        if ($tmp) { try { [IO.File]::Delete($tmp) } catch { } }
        return -1
    }
}
function Protect-LogFolder { param([string]$Dir)
    # Cleans every log in the folder. Never stops the run; a file that cannot be handled is named.
    $known = @($script:SecretValues)
    $n = 0
    foreach ($f in @(Get-ChildItem -LiteralPath $Dir -File -Filter '*.log' -ErrorAction SilentlyContinue)) {
        # task-console_* is this script's own output, still being written, and already masked
        if ($f.Name -like 'task-console_*') { continue }
        $c = Protect-InstallerLog -Path $f.FullName -Known $known
        if ($c -gt 0) { $n += $c } elseif ($c -lt 0) { Say "Could not check $($f.Name) for recorded passwords; it was left as it is." 'WARN' }
    }
    if ($n) { Say "Replaced $n recorded password value(s) in the installer log(s) with asterisks." }
}
function Test-ParameterLogging {
    # True when Windows PowerShell is set by policy to write the parameters of the commands this
    # script uses into the event log (module logging). The passwords would be among them.
    $mods = 'Microsoft.PowerShell.Security', 'Microsoft.PowerShell.Management', 'ScheduledTasks'
    foreach ($hive in 'HKLM:', 'HKCU:') {
        $k = "$hive\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging"
        try {
            if ([int](Get-ItemProperty -LiteralPath $k -ErrorAction Stop).EnableModuleLogging -ne 1) { continue }
            foreach ($pattern in @((Get-Item -LiteralPath "$k\ModuleNames" -ErrorAction Stop).Property)) {
                foreach ($m in $mods) { if ($m -like $pattern) { return $true } }
            }
        } catch { }
    }
    return $false }
function Restore-AfterFailedInstall { param($Before, [string]$KeytabCopy, [datetime]$Since)
    # Install-AccessConnector.ps1 stops the connector services before the installer runs and
    # starts them again only after a successful install. After a failed one, put back what was
    # there before, so the connector is not left offline. Returns notes for the result message.
    $notes = @()
    try {
        $now = Get-ConnectorState
        # The keytab: only when the version did not change, the keytab is now unusable, a copy was
        # taken in this run, and the vendor Kerberos setup has not run since (it would have reset
        # the AD account password, and the old keytab would no longer match it).
        if ($KeytabCopy -and $now.InstalledVersion -eq $Before.InstalledVersion -and $now.KeytabBytes -lt 32) {
            $conf = Join-Path $now.InstallRoot 'Kerberos Auth Service\conf'
            $sl = Get-Item -LiteralPath (Join-Path $conf 'krb5-setup.log') -ErrorAction SilentlyContinue
            if ($sl -and $sl.LastWriteTime -ge $Since) {
                $notes += 'the keytab is empty and was NOT put back, because the Kerberos setup ran during the failed install: use -Mode RepairKeytab'
            } elseif (Test-Path -LiteralPath $conf) {
                try {
                    Copy-Item -LiteralPath (Join-Path $KeytabCopy 'krb5.keytab') -Destination (Join-Path $conf 'krb5.keytab') -Force -ErrorAction Stop
                    $notes += 'the Kerberos keytab copied before the install was put back'
                } catch { $notes += ('the Kerberos keytab could not be put back: ' + $_.Exception.Message) }
            }
        }
        $want = @($Before.Services | Where-Object { $_.Status -eq 'Running' } | ForEach-Object { $_.Name })
        $down = @($now.Services | Where-Object { $_.Name -in $want -and $_.Status -ne 'Running' })
        if ($down.Count) {
            Say ("Starting the service(s) that were running before the install: " + (($down | ForEach-Object { $_.Name }) -join ', '))
            foreach ($s in $down) {
                # started without waiting, so a service stuck in 'starting' cannot hold up the result
                try { (Get-Service -Name $s.Name -ErrorAction Stop).Start() } catch { Say ("Could not start $($s.Name): " + $_.Exception.Message) 'WARN' }
            }
            $until = (Get-Date).AddMinutes(3)
            do {
                Start-Sleep -Seconds 5
                $now = Get-ConnectorState
                $up = @($now.Services | Where-Object { $_.Name -in $want -and $_.Status -eq 'Running' }).Count
            } while ($up -lt $want.Count -and (Get-Date) -lt $until)
            $notes += "$up of the $($want.Count) services that were running before are running again"
        }
    } catch { $notes += ('could not put the services back: ' + $_.Exception.Message) }
    return $notes
}
function Protect-MachineText { param([string]$Plain)
    # Machine-scope protection: only code running on this server can read it back.
    Add-Type -AssemblyName System.Security
    $b = [System.Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($Plain), $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    return [Convert]::ToBase64String($b) }
function Unprotect-MachineText { param([string]$Cipher)
    Add-Type -AssemblyName System.Security
    $b = [System.Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($Cipher), $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    return [Text.Encoding]::UTF8.GetString($b) }
function Write-Result { param($Result, [string]$LogDir)
    $json = $Result | ConvertTo-Json -Depth 6 -Compress
    $json = Protect-Text $json
    if ($LogDir) { try { Set-Content -LiteralPath (Join-Path $LogDir 'result.json') -Value $json -Encoding utf8 } catch { } }
    Write-Host ('RESULT_JSON:' + $json)
}
function Get-TaskCommand { param([string]$ScriptPath, [string]$JobFile, [string]$SecretsFile, [string]$Extra, [switch]$SkipDomainCheck, [string]$AuditLog, [string]$ErrorLog)
    # The command a one-time task runs (the run-as task, -Schedule): this script again under
    # Windows PowerShell, -NonInteractive (anything that would ask a question fails at once instead
    # of waiting where nobody can answer), the job and secrets files when given, $Extra (such as
    # ' -RepairKeytab'), and the switches of this run that the task needs. Every path must be a
    # full path: a task starts in System32.
    $c = 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $ScriptPath + '"'
    if ($JobFile) { $c += ' -JobFile "' + $JobFile + '"' }
    if ($SecretsFile) { $c += ' -SecretsFile "' + $SecretsFile + '"' }
    if ($Extra) { $c += $Extra }
    if ($SkipDomainCheck) { $c += ' -SkipDomainCheck' }
    if ($AuditLog) { $c += ' -AuditLog "' + $AuditLog + '"' }
    if ($ErrorLog) { $c += ' -ErrorLog "' + $ErrorLog + '"' }
    return $c
}
function Get-SelfDeletingTaskArgument { param([string]$Inner, [string]$ConsoleLog, [string]$TaskName)
    # The cmd.exe argument of a one-time task: run $Inner with no standard input and its output in
    # $ConsoleLog, then delete the task by name, and with it the Windows password Task Scheduler
    # keeps for it, however the run ended. The run-as task and -Schedule both use this.
    return ('/s /c "' + $Inner + ' < NUL > "' + $ConsoleLog + '" 2>&1 & schtasks.exe /Delete /TN "' + $TaskName + '" /F >NUL 2>&1"')
}
function Get-ScheduleProblem { param([datetime]$When, [string]$Text, [string]$TaskName)
    # Why -Schedule must not register its task now, or '' when it may. A time that has passed: a
    # one-time task whose start time is past never runs. A task of that name that is running: an
    # earlier scheduled run, which deletes the task by name when it ends, and so would delete the
    # new registration too, leaving its secrets.dat behind.
    $now = Get-Date
    if ($When -le $now) { return ("the time given, $Text, has already passed on this server's clock (now " + $now.ToString('yyyy-MM-dd HH:mm') + ')') }
    $old = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($old -and [string]$old.State -eq 'Running') { return "a task named $TaskName is running on this server now (an earlier scheduled run is still working); schedule again when it has ended" }
    return ''
}

# ====================================================================== main
Initialize-UiStyle
Show-LaunchNotice
if ($Help) { Show-Help; return }

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
$logDir = Join-Path $here 'Logs'
if (-not (Test-Path -LiteralPath $logDir)) { $null = New-Item -ItemType Directory -Path $logDir -Force }
if (-not $AuditLog) { $AuditLog = $logDir + '\' }
if (-not $ErrorLog) { $ErrorLog = $logDir + '\' }
$script:AuditPath = Resolve-LogPath -Value $AuditLog -DefaultName 'connector-upgrade-audit.log'
$script:ErrorPath = Resolve-LogPath -Value $ErrorLog -DefaultName 'connector-upgrade-errors.log'
# The log switches given, as full paths, for a task that runs this script again (Get-TaskCommand).
# Without them, the task would write to the Logs folder beside this script.
$script:TaskAuditLog = ''; $script:TaskErrorLog = ''
try {
    if ($PSBoundParameters.ContainsKey('AuditLog') -and $script:AuditPath) { $script:TaskAuditLog = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($script:AuditPath) }
    if ($PSBoundParameters.ContainsKey('ErrorLog') -and $script:ErrorPath) { $script:TaskErrorLog = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($script:ErrorPath) }
} catch { }

# switch conflicts
$modes = @($SecretsFromStdin.IsPresent, $Prompt.IsPresent, [bool]$SecretsFile, [bool]$ConfigFilePassword) | Where-Object { $_ }
if ($VerifyOnly) {
    foreach ($n in 'SecretsFromStdin','Prompt','SecretsFile','Schedule','JobFile') { if ($PSBoundParameters.ContainsKey($n)) { Say "[ignored] -$n has no effect with -VerifyOnly." 'WARN' } }
} elseif ($RepairCertificate) {
    # only the PFX password is needed, and the work runs in this sign-in (no Active Directory access is needed)
    foreach ($n in 'SecretsFile','Schedule','JobFile','RunAsTask','RunAsUser','RunAsPassword') { if ($PSBoundParameters.ContainsKey($n)) { Say "[ignored] -$n has no effect with -RepairCertificate." 'WARN' } }
    if ($RepairKeytab) { Write-ErrorEntry 'Use -RepairCertificate or -RepairKeytab, not both.' 'args'; Write-AuditEntry 'FAILED' 'args'; exit 1 }
    if (-not $CertFile) { Write-ErrorEntry '-RepairCertificate needs -CertFile <name of the PFX in this folder>.' 'args'; Write-AuditEntry 'FAILED' 'args'; exit 1 }
    if (-not ($SecretsFromStdin -or $Prompt -or $SslCertPassword)) { Write-ErrorEntry 'No source for the PFX password. Use -Prompt when running by hand (see -Help).' 'args'; Write-AuditEntry 'FAILED' 'args'; exit 1 }
} elseif ($RepairKeytab) {
    # no install secrets are needed; standard input is read only for the run-as account
    foreach ($n in 'Prompt','SecretsFile','Schedule','JobFile') { if ($PSBoundParameters.ContainsKey($n)) { Say "[ignored] -$n has no effect with -RepairKeytab." 'WARN' } }
} else {
    if ($CheckOnly) { Say '[ignored] -CheckOnly applies only to -RepairKeytab and -RepairCertificate. A dry run of an upgrade is set in the job file.' 'WARN' }
    foreach ($n in 'CertFile','Reapply') { if ($PSBoundParameters.ContainsKey($n)) { Say "[ignored] -$n applies only to -RepairCertificate." 'WARN' } }
    if ($modes.Count -gt 1) { Write-ErrorEntry 'Use only one of -SecretsFromStdin, -Prompt, -SecretsFile or the password parameters.' 'args'; Write-AuditEntry 'FAILED' 'args'; exit 1 }
    if ($modes.Count -eq 0) { Write-ErrorEntry 'No secret source given. Use -Prompt when running by hand (see -Help).' 'args'; Write-AuditEntry 'FAILED' 'args'; exit 1 }
    if ($Schedule -and -not $Prompt) { Write-ErrorEntry '-Schedule needs -Prompt (the passwords are collected now and stored for the task).' 'args'; Write-AuditEntry 'FAILED' 'args'; exit 1 }
    if ($Schedule -and ($RunAsUser -or $RunAsTask)) { Write-ErrorEntry '-Schedule cannot be used with -RunAsUser or -RunAsTask: the run-as task starts the work now. Sign in as the account the job is to run under and use -Prompt -Schedule.' 'args'; Write-AuditEntry 'FAILED' 'args'; exit 1 }
}

$isAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($VerifyOnly) {
    $st = Get-ConnectorState
    Resume-InterruptedCertChange -Here $here -Root $st.InstallRoot -Fix $false
    Say ("Version {0}; services: {1}; java with flag {2}/{3}; keytab bytes {4}" -f $st.InstalledVersion, (($st.Services | ForEach-Object { $_.Key + '=' + $_.Status }) -join ', '), $st.JavaWithFlag, $st.JavaCount, $st.KeytabBytes)
    # no result.json here: it would replace the record of the last upgrade
    Write-Result -Result ([pscustomobject]@{ Status='Verified'; State=$st }) -LogDir $null
    Write-AuditEntry 'SUCCESS' 'verify' ("version=" + $st.InstalledVersion)
    exit 0
}

if (-not $isAdmin) { Write-ErrorEntry 'This must run elevated (Run as Administrator).' 'precheck'; Write-AuditEntry 'FAILED' 'precheck'; exit 1 }
# Installer logs left by an earlier run may still hold recorded passwords. Clean them first.
Protect-LogFolder $logDir
if ($RepairKeytab -or $RepairCertificate) {
    # a keytab or certificate repair installs nothing, so it has no job file
    $job = [pscustomobject]@{ Services = @('KerberosAuthService'); DryRun = [bool]$CheckOnly; Pfx = $null; ServiceAccount = $null }
    if ($RepairCertificate) { $job.Pfx = Split-Path ([string]$CertFile) -Leaf }
} else {
    if (-not $JobFile) { $JobFile = Join-Path $here 'job.json' }
    if (-not (Test-Path -LiteralPath $JobFile)) { Write-ErrorEntry "Job file not found: $JobFile" 'precheck'; Write-AuditEntry 'FAILED' 'precheck'; exit 1 }
    # a full path, for a task that runs this script again: a task starts in System32
    $JobFile = (Resolve-Path -LiteralPath $JobFile).ProviderPath
    $job = Get-Content -Raw -LiteralPath $JobFile | ConvertFrom-Json
}
$needSvc = [bool](@($job.Services) | Where-Object { $_ -in 'KerberosAuthService','VirtualAppService' })
$needProxy = [bool]($job.ProxyHost -and $job.ProxyUser)
if ($job.InstallDir) { $script:JobInstallDir = [string]$job.InstallDir }

# ---- a server that records command parameters would record the passwords
$takesSecrets = (-not $RepairKeytab) -or $RunAsTask -or $RunAsUser
if ($takesSecrets -and (Test-ParameterLogging)) {
    $msg = 'this server writes PowerShell command parameters to its event log (the module logging policy), so the passwords given to this script would be recorded there'
    if ($SecretsFile) { Remove-Item -LiteralPath $SecretsFile -Force -ErrorAction SilentlyContinue }
    Write-ErrorEntry ("Not started: $msg. Nothing was changed. Turn that policy off for this server while the upgrade runs.") 'precheck'
    Write-Result -Result ([pscustomobject]@{ Status=$(if ($job.DryRun) { 'DryRunFailed' } else { 'Blocked' }); Computer=$env:COMPUTERNAME; Before=$null; After=$null; InstallerExit=$null; PatchExit=$null; Message=$msg }) -LogDir $null
    Write-AuditEntry 'FAILED' 'precheck' $msg
    exit 1
}

# ---- collect secrets
try {
    if ($SecretsFromStdin) {
        $vals = @()
        for ($i = 0; $i -lt 4; $i++) { $l = [Console]::In.ReadLine(); if ($null -eq $l) { $l = '' }
            $vals += [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($l.Trim())) }
        if ($vals[0]) { $ConfigFilePassword     = ConvertTo-SecureString $vals[0] -AsPlainText -Force }
        if ($vals[1]) { $SslCertPassword        = ConvertTo-SecureString $vals[1] -AsPlainText -Force }
        if ($vals[2]) { $ServiceAccountPassword = ConvertTo-SecureString $vals[2] -AsPlainText -Force }
        if ($vals[3]) { $ProxyPassword          = ConvertTo-SecureString $vals[3] -AsPlainText -Force }
        $vals = $null
        if ($RunAsTask) {
            # two more lines: the account for the task and its password
            $ru = [Console]::In.ReadLine(); $rp = [Console]::In.ReadLine()
            if ($ru) { $RunAsUser = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ru.Trim())) }
            if ($rp) { $rpPlain = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($rp.Trim()))
                if ($rpPlain) { $RunAsPassword = ConvertTo-SecureString $rpPlain -AsPlainText -Force }; $rpPlain = $null }
        }
    } elseif ($Prompt -and $RepairCertificate) {
        $SslCertPassword = Read-UiSecret 'Kerberos SSL PFX password'
    } elseif ($Prompt -and -not $RepairKeytab) {
        $ConfigFilePassword = Read-UiSecret 'Configuration file (es-config) password'
        if ($job.Pfx) { $SslCertPassword = Read-UiSecret 'Kerberos SSL PFX password' }
        if ($needSvc -and $job.ServiceAccount) { $ServiceAccountPassword = Read-UiSecret ("Service account password for " + $job.ServiceAccount) }
        if ($needProxy) { $ProxyPassword = Read-UiSecret ("Proxy password for " + $job.ProxyUser) }
    } elseif ($SecretsFile -and -not $RepairKeytab -and -not $RepairCertificate) {
        $sf = Get-Content -Raw -LiteralPath $SecretsFile | ConvertFrom-Json
        Remove-Item -LiteralPath $SecretsFile -Force -ErrorAction SilentlyContinue
        if ($sf.Scope -eq 'Machine') {
            # written by -RunAsUser on this server for a task that runs under another account
            if ($sf.Cfg) { $ConfigFilePassword     = ConvertTo-SecureString (Unprotect-MachineText $sf.Cfg) -AsPlainText -Force }
            if ($sf.Pfx) { $SslCertPassword        = ConvertTo-SecureString (Unprotect-MachineText $sf.Pfx) -AsPlainText -Force }
            if ($sf.Svc) { $ServiceAccountPassword = ConvertTo-SecureString (Unprotect-MachineText $sf.Svc) -AsPlainText -Force }
            if ($sf.Proxy) { $ProxyPassword        = ConvertTo-SecureString (Unprotect-MachineText $sf.Proxy) -AsPlainText -Force }
        } else {
            if ($sf.Cfg) { $ConfigFilePassword     = ConvertTo-SecureString $sf.Cfg }
            if ($sf.Pfx) { $SslCertPassword        = ConvertTo-SecureString $sf.Pfx }
            if ($sf.Svc) { $ServiceAccountPassword = ConvertTo-SecureString $sf.Svc }
            if ($sf.Proxy) { $ProxyPassword        = ConvertTo-SecureString $sf.Proxy }
        }
    }
} catch { Write-ErrorEntry ("Could not read the secrets: " + $_.Exception.Message) 'secrets'; Write-AuditEntry 'FAILED' 'secrets'; exit 1 }
foreach ($s in @($ConfigFilePassword, $SslCertPassword, $ServiceAccountPassword, $ProxyPassword)) { if ($s) { Register-Secret (ConvertTo-PlainText $s) } }
if ($RepairCertificate) {
    if (-not $SslCertPassword -or $SslCertPassword.Length -eq 0) { Write-ErrorEntry 'Empty PFX password. Nothing was changed.' 'secrets'; Write-AuditEntry 'FAILED' 'secrets'; exit 1 }
} elseif (-not $RepairKeytab) {
    # An empty password must stop here: the installer would run with it after the services are stopped.
    $emptyOnes = @()
    if (-not $ConfigFilePassword -or $ConfigFilePassword.Length -eq 0) { $emptyOnes += 'configuration file' }
    if ($job.Pfx -and (-not $SslCertPassword -or $SslCertPassword.Length -eq 0)) { $emptyOnes += 'Kerberos PFX' }
    if ($needSvc -and $job.ServiceAccount -and (-not $ServiceAccountPassword -or $ServiceAccountPassword.Length -eq 0)) { $emptyOnes += 'service account' }
    if ($needProxy -and (-not $ProxyPassword -or $ProxyPassword.Length -eq 0)) { $emptyOnes += 'proxy' }
    if ($emptyOnes.Count) { Write-ErrorEntry ('Empty password: ' + ($emptyOnes -join ', ') + '. Nothing was changed.') 'secrets'; Write-AuditEntry 'FAILED' 'secrets'; exit 1 }
}

# ---- run as a one-time scheduled task under another account
# A remote sign-in (ssh key, WinRM) cannot query Active Directory, so the vendor Kerberos setup
# cannot rebuild the keytab from it. A scheduled task with a stored password is a full sign-in.
# This process starts the task, shows its output as it is written, and returns its result.
if (($RunAsTask -or $RunAsUser) -and -not $RepairCertificate) {
    $taskName = 'AccessConnectorUpgrade-RunAs'
    $sfPath = Join-Path $here ('secrets-runas_' + [guid]::NewGuid().ToString('N') + '.dat')
    $conLog = Join-Path $logDir ("task-console_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    # built-in service accounts: allowed for a dry run or a check only (test aid)
    $asSystem = ([string]$RunAsUser -match '(?i)^(nt authority\\)?(system|localsystem|local service|network service)$')
    $runPlain = $null; $madeSecrets = $false; $madeTask = $false
    $startError = $null
    try {
        if (-not $RunAsUser) { throw 'no account was given for the task' }
        if ($asSystem -and -not ($job.DryRun -or ($RepairKeytab -and $CheckOnly))) { throw 'a built-in service account is allowed for a dry run only' }
        if ($asSystem) { $RunAsUser = 'SYSTEM' }
        else {
            $runPlain = ConvertTo-PlainText $RunAsPassword
            if (-not $runPlain) { throw "no password was given for $RunAsUser" }
            Register-Secret $runPlain
        }
        $old = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($old -and [string]$old.State -eq 'Running') { throw "a task named $taskName is already running on this server (an earlier run is still working); nothing was started" }
        if ($old) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop }
        # The scripts in this folder are about to run under a privileged account, so make sure
        # only Administrators and SYSTEM can change or read anything in it.
        # Done only for the tool's own staging folder, never for an arbitrary folder someone copied the script to.
        if ((Split-Path -Leaf $here) -eq 'AccessConnectorUpdate') {
            $null = & icacls.exe $here /setowner '*S-1-5-32-544' /T /C /Q 2>&1
            $ownExit = $LASTEXITCODE
            $null = & icacls.exe $here /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' /Q 2>&1
            if ($LASTEXITCODE -ne 0 -or $ownExit -ne 0) { throw "could not restrict access to $here (icacls exit $ownExit / $LASTEXITCODE)" }
        } else { Say "This folder is not named AccessConnectorUpdate, so its permissions are left as they are. Make sure only administrators can write to $here." 'WARN' }
        # -NonInteractive and an empty standard input: anything that tries to ask a question fails
        # at once instead of waiting where nobody can answer.
        if ($RepairKeytab) {
            $inner = Get-TaskCommand -ScriptPath $MyInvocation.MyCommand.Path -Extra $(if ($CheckOnly) { ' -RepairKeytab -CheckOnly' } else { ' -RepairKeytab' }) -AuditLog $script:TaskAuditLog -ErrorLog $script:TaskErrorLog
        } else {
            # Secrets for the task: machine-scope protected, readable by Administrators and SYSTEM
            # only, and deleted by the task as soon as it has read them.
            Set-Content -LiteralPath $sfPath -Value '' -Encoding ascii -ErrorAction Stop
            $madeSecrets = $true
            $null = & icacls.exe $sfPath /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' /Q 2>&1
            if ($LASTEXITCODE -ne 0) { throw "could not restrict access to the secrets file (icacls exit $LASTEXITCODE)" }
            $o = @{ Scope = 'Machine'; Cfg = (Protect-MachineText (ConvertTo-PlainText $ConfigFilePassword)) }
            if ($SslCertPassword)        { $o.Pfx = Protect-MachineText (ConvertTo-PlainText $SslCertPassword) }
            if ($ServiceAccountPassword) { $o.Svc = Protect-MachineText (ConvertTo-PlainText $ServiceAccountPassword) }
            if ($ProxyPassword)          { $o.Proxy = Protect-MachineText (ConvertTo-PlainText $ProxyPassword) }
            Set-Content -LiteralPath $sfPath -Value ($o | ConvertTo-Json) -Encoding ascii -ErrorAction Stop
            $inner = Get-TaskCommand -ScriptPath $MyInvocation.MyCommand.Path -JobFile $JobFile -SecretsFile $sfPath -SkipDomainCheck:$SkipDomainCheck -AuditLog $script:TaskAuditLog -ErrorLog $script:TaskErrorLog
        }
        # The task removes itself, and with it the stored password, as soon as the work ends. That
        # way cleanup does not depend on this process surviving a dropped connection or Ctrl+C.
        $action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument (Get-SelfDeletingTaskArgument -Inner $inner -ConsoleLog $conLog -TaskName $taskName)
        if ($asSystem) {
            $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force -ErrorAction Stop | Out-Null
        } else {
            Register-ScheduledTask -TaskName $taskName -Action $action -User $RunAsUser -Password $runPlain -RunLevel Highest -Force -ErrorAction Stop | Out-Null
        }
        $madeTask = $true
        $runPlain = $null
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
    } catch { $startError = $_ }
    if ($startError) {
        $runPlain = $null
        # remove only what this run created
        if ($madeSecrets) { Remove-Item -LiteralPath $sfPath -Force -ErrorAction SilentlyContinue }
        if ($madeTask) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue }
        $msg = Protect-Text ("Could not start the task as $RunAsUser" + ': ' + (([string]$startError.Exception.Message) -replace '\s+', ' ').Trim())
        Write-ErrorEntry $msg 'runas'
        Write-Result -Result ([pscustomobject]@{ Status='Error'; Computer=$env:COMPUTERNAME; Before=$null; After=$null; InstallerExit=$null; PatchExit=$null; Message=$msg }) -LogDir $null
        Write-AuditEntry 'FAILED' 'runas' $msg
        exit 1
    }

    Say "The work is running on this server as a scheduled task under $RunAsUser. Its output follows."
    $script:RunAsSawResult = $false; $script:RunAsStatus = ''
    $relay = { param($line)
        if ($line -match 'UNSUPPORTED - provided|Omnissa nor the author is liable') { return }
        if ($line.StartsWith('RESULT_JSON:')) {
            $script:RunAsSawResult = $true
            try { $script:RunAsStatus = [string]($line.Substring(12) | ConvertFrom-Json).Status } catch { }
        }
        Write-Host (Protect-Text $line) }
    $enc = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
    $offset = [long]0; $carry = ''; $seenRunning = $false; $timedOut = $false; $idleSamples = 0
    $started = Get-Date; $deadline = $started.AddMinutes(120)
    while ($true) {
        $state = [string](Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue).State
        if ($state -eq 'Running' -or (Test-Path -LiteralPath $conLog)) { $seenRunning = $true }
        # two samples in a row that are not Running, so one failed query cannot end the wait early
        if ($seenRunning -and $state -ne 'Running') { $idleSamples++ } else { $idleSamples = 0 }
        $finished = ($idleSamples -ge 2) -or ((-not $seenRunning) -and ((Get-Date) - $started).TotalSeconds -gt 90)
        if (Test-Path -LiteralPath $conLog) {
            $fs = $null
            try {
                $fs = [IO.File]::Open($conLog, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                if ($fs.Length -gt $offset) {
                    $null = $fs.Seek($offset, [IO.SeekOrigin]::Begin)
                    $buf = New-Object byte[] ([int]($fs.Length - $offset))
                    $n = $fs.Read($buf, 0, $buf.Length); $offset += $n
                    $parts = ($carry + $enc.GetString($buf, 0, $n)) -split "`r?`n"
                    $carry = $parts[$parts.Count - 1]
                    for ($i = 0; $i -lt ($parts.Count - 1); $i++) { & $relay $parts[$i] }
                }
            } catch { } finally { if ($fs) { $fs.Close() } }
        }
        if ($finished) { break }
        if ((Get-Date) -gt $deadline) { $timedOut = $true; break }
        Start-Sleep -Seconds 2
    }
    if ($carry) { & $relay $carry }

    if ($timedOut) {
        $msg = "the task is still running after 120 minutes and was left running (it removes itself when it ends); check $conLog on this server"
        Write-ErrorEntry $msg 'runas'
        Write-Result -Result ([pscustomobject]@{ Status='Error'; Computer=$env:COMPUTERNAME; Before=$null; After=$null; InstallerExit=$null; PatchExit=$null; Message=$msg }) -LogDir $null
        Write-AuditEntry 'FAILED' 'runas' $msg
        exit 1
    }
    # The task removes itself when it ends; this covers the case where that did not happen.
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $sfPath -Force -ErrorAction SilentlyContinue
    if (-not $script:RunAsSawResult) {
        # the result line can be missed if the console log could not be read; use the saved result
        $rj = Join-Path $logDir 'result.json'
        if ((Test-Path -LiteralPath $rj) -and (Get-Item -LiteralPath $rj).LastWriteTime -ge $started) {
            try { & $relay ('RESULT_JSON:' + ((Get-Content -Raw -LiteralPath $rj) -replace '\s+$', '')) } catch { }
        }
    }
    if (-not $script:RunAsSawResult) {
        $msg = "the task as $RunAsUser ended without a result; see $conLog on this server"
        Write-ErrorEntry $msg 'runas'
        Write-Result -Result ([pscustomobject]@{ Status='Error'; Computer=$env:COMPUTERNAME; Before=$null; After=$null; InstallerExit=$null; PatchExit=$null; Message=$msg }) -LogDir $null
        Write-AuditEntry 'FAILED' 'runas' $msg
        exit 1
    }
    $ok = ($script:RunAsStatus -in 'Success','DryRunPassed')
    if ($ok) { Write-AuditEntry 'SUCCESS' 'runas' ("task as $RunAsUser, status " + $script:RunAsStatus) }
    else     { Write-AuditEntry 'FAILED'  'runas' ("task as $RunAsUser, status " + $script:RunAsStatus) }
    exit ([int](-not $ok))
}

# ---- keytab repair only (this sign-in must be a domain admin; remote callers arrive here inside the task)
if ($RepairKeytab) { exit (Invoke-KeytabRepair -Here $here -LogDir $logDir -Check ([bool]$CheckOnly)) }

# ---- certificate repair only (any elevated sign-in will do)
if ($RepairCertificate) { exit (Invoke-CertificateRepair -Here $here -LogDir $logDir -Check ([bool]$CheckOnly) -PfxPath (Join-Path $here $job.Pfx) -Password $SslCertPassword -Reapply ([bool]$Reapply)) }

# ---- schedule instead of running now
if ($Schedule) {
    $taskName = 'AccessConnectorUpgrade'
    try {
        $when = [datetime]::ParseExact($Schedule, 'yyyy-MM-dd HH:mm', $null)
        # Refused before anything is written: a time that has passed, or a task of this name that
        # is running now (Get-ScheduleProblem). Checked again after the password prompt below.
        $why = Get-ScheduleProblem -When $when -Text $Schedule -TaskName $taskName
        if ($why) { throw $why }
        $acct = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $acctPw = Read-UiSecret "Windows password for $acct (stored by Task Scheduler to run the task)"
        $plain = ConvertTo-PlainText $acctPw; Register-Secret $plain
        $why = Get-ScheduleProblem -When $when -Text $Schedule -TaskName $taskName
        if ($why) { throw $why }
        $sfPath = Join-Path $here 'secrets.dat'
        $o = @{ Cfg = (ConvertFrom-SecureString $ConfigFilePassword) }
        if ($SslCertPassword) { $o.Pfx = ConvertFrom-SecureString $SslCertPassword }
        if ($ServiceAccountPassword) { $o.Svc = ConvertFrom-SecureString $ServiceAccountPassword }
        if ($ProxyPassword) { $o.Proxy = ConvertFrom-SecureString $ProxyPassword }
        Set-Content -LiteralPath $sfPath -Value ($o | ConvertTo-Json) -Encoding utf8
        $conLog = Join-Path $logDir ("task-console_{0}.log" -f $when.ToString('yyyyMMdd_HHmm'))
        # As the run-as task does: the task deletes itself, and with it the stored Windows password,
        # as soon as the run ends. -NonInteractive and an empty standard input make anything that
        # would ask a question fail at once, so the run always ends and the delete always comes.
        # -SkipDomainCheck and the log switches given here are passed on to the run.
        $inner = Get-TaskCommand -ScriptPath $MyInvocation.MyCommand.Path -JobFile $JobFile -SecretsFile $sfPath -SkipDomainCheck:$SkipDomainCheck -AuditLog $script:TaskAuditLog -ErrorLog $script:TaskErrorLog
        $action  = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument (Get-SelfDeletingTaskArgument -Inner $inner -ConsoleLog $conLog -TaskName $taskName)
        $trigger = New-ScheduledTaskTrigger -Once -At $when
        # And if it never runs (the server is off at that time, say), Task Scheduler deletes it
        # once the trigger has expired, 12 hours after the start time: far longer than a run takes.
        $expires = $when.AddHours(12)
        $trigger.EndBoundary = $expires.ToString('s')
        $settings = New-ScheduledTaskSettingsSet -DeleteExpiredTaskAfter (New-TimeSpan -Seconds 1)
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -User $acct -Password $plain -RunLevel Highest -Force -ErrorAction Stop | Out-Null
        $plain = $null
        Say ("Scheduled task '$taskName' registered for $Schedule as $acct. It deletes itself, and with it your stored Windows password, when the run ends, or at " + $expires.ToString('yyyy-MM-dd HH:mm') + " if it has not run by then. Result will be in $logDir\result.json, its output in $conLog.") 'OK'
        Write-AuditEntry 'SUCCESS' 'schedule' ("when=$Schedule expires=" + $expires.ToString('yyyy-MM-dd HH:mm'))
        exit 0
    } catch { Write-ErrorEntry ("Could not register the scheduled task: " + $_.Exception.Message) 'schedule'; Write-AuditEntry 'FAILED' 'schedule'; exit 1 }
}

# ---- run
$result = [ordered]@{ Status='Pending'; Computer=$env:COMPUTERNAME; Before=$null; After=$null; InstallerExit=$null; PatchExit=$null; Message=''; DryRun=[bool]$job.DryRun }
$before = Get-ConnectorState
$result.Before = $before
Say ("Before: version {0}, running as {1}, free C: {2} GB" -f $before.InstalledVersion, $before.WhoAmI, $before.FreeGB)
# Services that are already stopped (for example after a cancelled manual install) are not an
# error: note them and continue. The upgrade stops the rest and starts them all afterwards.
$stoppedBefore = @($before.Services | Where-Object { $_.Status -ne 'Running' })
if ($before.Services.Count -eq 0) { Say 'No connector services are registered on this server yet - continuing.' 'WARN' }
foreach ($sv in $stoppedBefore) { Say ("Service {0} is already {1} - continuing." -f $sv.Name, $sv.Status.ToLower()) 'WARN' }
if ($before.FreeGB -lt 3) { Say 'Less than 3 GB free on C:. The installer may fail.' 'WARN' }
if ($before.RebootPending) { Say 'A Windows reboot is pending on this server.' 'WARN' }

# ---- Kerberos: refuse to upgrade from a sign-in that cannot rebuild the keytab
$domainOk = $false
$asLocalSystem = ($before.WhoAmI -match '(?i)^nt authority\\')
if ('KerberosAuthService' -in @($job.Services)) {
    if ($asLocalSystem -and -not $job.DryRun) {
        $result.Status = 'Blocked'; $result.Message = 'a built-in service account cannot rebuild the Kerberos keytab; use a domain admin account'
        $result.After = $before
        Write-ErrorEntry ("Not upgraded: " + $result.Message + ". Nothing was changed.") 'precheck'
        Write-Result -Result ([pscustomobject]$result) -LogDir $logDir
        Write-AuditEntry 'FAILED' 'precheck' $result.Message
        exit 1
    }
    if (Test-DomainReach) { $domainOk = $true; Say 'This sign-in can query Active Directory, which the Kerberos keytab step needs.' 'OK' }
    elseif ($SkipDomainCheck -or $job.SkipDomainCheck) {
        Say 'This sign-in cannot query Active Directory. -SkipDomainCheck is set, so the upgrade continues; the keytab will be empty until setupKerberos.ps1 is run here by a domain admin.' 'WARN'
    } else {
        $result.Status = $(if ($job.DryRun) { 'DryRunFailed' } else { 'Blocked' })
        $result.Message = "this sign-in ($($before.WhoAmI)) cannot query Active Directory, so the Kerberos keytab could not be rebuilt after the upgrade ($($script:DomainReachDetail))"
        $result.After = $before
        Write-ErrorEntry ("Not upgraded: " + $result.Message + ". Nothing was changed. Use -Mode Stage and run Run-Upgrade.cmd here signed in as a domain admin, or add -SkipDomainCheck and rebuild the keytab by hand afterwards.") 'precheck'
        Write-Result -Result ([pscustomobject]$result) -LogDir $logDir
        Write-AuditEntry 'FAILED' 'precheck' $result.Message
        exit 1
    }
}

# ---- FIPS mode cannot be changed on an installed connector. Refuse a job that asks for the other
# setting, unless the connector is uninstalled first (-ForceReinstall), or none is installed yet.
if ($before.InstalledVersion -and -not $job.ForceReinstall) {
    $props = Join-Path $before.InstallRoot 'Support\scripts\install.properties'
    if (Test-Path -LiteralPath $props) {
        $fipsNow = [bool]([string](Get-Content -Raw -LiteralPath $props) -match '(?mi)^[ \t]*FIPS_ENABLED[ \t]*=[ \t]*true')
        if ($fipsNow -ne [bool]$job.EnableFips) {
            $result.Status = $(if ($job.DryRun) { 'DryRunFailed' } else { 'Blocked' })
            $result.Message = $(if ($fipsNow) { 'this connector is installed in FIPS mode; set EnableFips = $true in its fleet entry' } else { 'the fleet entry asks for FIPS mode, but this connector is installed without it, and FIPS mode cannot be changed after install; to change it, upgrade it first with EnableFips = $false, then run with -ForceReinstall (uninstall, then fresh install)' })
            $result.After = $before
            Write-ErrorEntry ("Not upgraded: " + $result.Message + ". Nothing was changed.") 'precheck'
            Write-Result -Result ([pscustomobject]$result) -LogDir $logDir
            Write-AuditEntry 'FAILED' 'precheck' $result.Message
            exit 1
        }
    }
}
if ($before.InstalledVersion -and $job.InstallDir) {
    $wantRoot = Join-Path ([string]$job.InstallDir) 'Access Connector'
    if ($wantRoot.TrimEnd('\') -ne ([string]$before.InstallRoot).TrimEnd('\')) { Say ("The fleet entry names the install folder {0}, but this connector is installed in {1}. An upgrade normally stays where it is; use -ForceReinstall to move it." -f $wantRoot, $before.InstallRoot) 'WARN' }
}

# The installer removes the keytab. Keep a copy of a usable one first.
$ktCopy = $null
if (('KerberosAuthService' -in @($job.Services)) -and -not $job.DryRun) {
    $ktCopy = Backup-Keytab -Root $before.InstallRoot -Here $here
    if ($ktCopy) { Say "The current Kerberos keytab ($($before.KeytabBytes) bytes) was copied to $ktCopy" }
}

$installScript = Join-Path $here 'Install-AccessConnector.ps1'
$installStarted = Get-Date
if (-not (Test-Path -LiteralPath $installScript)) { Write-ErrorEntry "Install-AccessConnector.ps1 not found in $here" 'precheck'; Write-AuditEntry 'FAILED' 'precheck'; exit 1 }

$splat = @{
    InstallerPath      = Join-Path $here $job.Installer
    ConfigFilePath     = Join-Path $here $job.ConfigFile
    Services           = @($job.Services)
    ConfigFilePassword = $ConfigFilePassword
    LogPath            = $logDir
}
if ($job.TrustStore)       { $splat.TrustStoreCertsPath = Join-Path $here $job.TrustStore }
if ($job.Pfx)              { $splat.SslCertPath = Join-Path $here $job.Pfx; $splat.SslCertPassword = $SslCertPassword }
if ($job.ServiceAccount)   { $splat.ServiceAccount = $job.ServiceAccount; if ($ServiceAccountPassword) { $splat.ServiceAccountPassword = $ServiceAccountPassword } }
if ($job.Syslog)           { $splat.SyslogHost = $job.Syslog }
if ($job.InstallerVersion) { $splat.InstallerVersion = $job.InstallerVersion }
if ($job.ForceReinstall)   { $splat.ForceReinstall = $true }
# installer settings from the fleet file
if ($job.InstallDir)       { $splat.InstallDir = [string]$job.InstallDir }
if ($job.EnableFips)       { $splat.EnableFips = $true }
foreach ($k in 'DirectorySyncPort','UserAuthPort','KerberosAuthPort','VirtualAppPort','ProxyPort') { if ($job.$k) { $splat[$k] = [int]$job.$k } }
foreach ($k in 'ProxyHost','ProxyUser','NonProxyHosts') { if ($job.$k) { $splat[$k] = [string]$job.$k } }
if ($needProxy)            { $splat.ProxyPassword = $ProxyPassword }
if ($job.DryRun)           { $splat.DryRun = $true }
# A silent install may otherwise restart the server by itself when Windows Installer wants a reboot.
$splat.ExtraMsiProperties = 'REBOOT=ReallySuppress'
# With a domain sign-in, have the pre-flight really test the service account password (one sign-in
# attempt), so a typing mistake stops before the services are touched. Not for the SYSTEM test aid.
if ($domainOk -and $needSvc -and $job.ServiceAccount -and -not $asLocalSystem) { $splat.ValidateServiceAccount = $true }

Say ("Running Install-AccessConnector.ps1 (installer {0}{1})..." -f $job.Installer, $(if ($job.DryRun) { ', DRY RUN' } else { '' }))
$global:LASTEXITCODE = $null
$script:RealRunNote = ''
try {
    & $installScript @splat 2>&1 | ForEach-Object {
        $relayStyle = $script:ui.Text; if ($_ -is [System.Management.Automation.ErrorRecord]) { $relayStyle = $script:ui.Warn }
        Write-Host ($relayStyle + (Protect-Text ([string]$_)) + $script:ui.Reset) }
    $result.InstallerExit = $LASTEXITCODE
    $ktLogs = @(Get-ChildItem -LiteralPath $logDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'keytab-console_*' -or $_.Name -like 'run-keytab_*' })
    if ($ktLogs.Count) { $pf = Get-PrivateFolder $here; foreach ($k in $ktLogs) { Move-Item -LiteralPath $k.FullName -Destination $pf -Force -ErrorAction SilentlyContinue } }
} catch {
    $result.InstallerExit = -1
    Write-ErrorEntry ("Install-AccessConnector.ps1 threw: " + $_.Exception.Message) 'install'
}
# The vendor installer records the passwords it was given in its own log. Clean that now, before
# anything copies the Logs folder.
Protect-LogFolder $logDir
$okCodes = 0, 3010, 1641
$installOk = ($result.InstallerExit -in $okCodes)
# Install-AccessConnector.ps1 also returns non-zero when the installer itself succeeded but one of
# its checks afterwards did not (a service slow to start, the keytab step). The connector is then
# already upgraded, so the patch and the health check below must still run.
$postInstallProblem = $null
if (-not $installOk -and -not $job.DryRun -and $job.ExpectVersionPrefix) {
    $mid = Get-ConnectorState
    $want = [string]$job.ExpectVersionPrefix
    if (([string]$mid.InstalledVersion).StartsWith($want) -and -not ([string]$before.InstalledVersion).StartsWith($want)) {
        $postInstallProblem = "the installer finished, but Install-AccessConnector.ps1 reported a problem afterwards (exit $($result.InstallerExit)); see its AccessConnector_Audit log"
        Say ("The connector is now on {0}, but Install-AccessConnector.ps1 exited {1}. Continuing with the patch and the health check." -f $mid.InstalledVersion, $result.InstallerExit) 'WARN'
        $installOk = $true
    }
}

if ($job.DryRun) {
    # The wrapper's dry run says when a real run would skip or refuse this connector. Its lines go
    # to the console with Write-Host, which the pipe above does not receive under Windows
    # PowerShell 5.1, so read the note from the wrapper's own audit log of this run.
    try {
        $wal = @(Get-ChildItem -LiteralPath $logDir -Filter 'AccessConnector_Audit_*.log' -File -ErrorAction Stop | Where-Object { $_.LastWriteTime -ge $installStarted } | Sort-Object LastWriteTime)
        if ($wal.Count) {
            $hit = @(Select-String -LiteralPath $wal[$wal.Count - 1].FullName -Pattern 'DRY RUN note: (.+)$') | Select-Object -Last 1
            if ($hit) { $script:RealRunNote = $hit.Matches[0].Groups[1].Value.Trim() }
        }
    } catch { }
    if ($installOk) { $result.Status = 'DryRunPassed'; if ($script:RealRunNote) { $result.Message = $script:RealRunNote } } else { $result.Status = 'DryRunFailed'; $result.Message = "pre-flight exit $($result.InstallerExit)" + $(if ($script:RealRunNote) { '; ' + $script:RealRunNote } else { '' }) }
    $result.After = Get-ConnectorState
    Write-Result -Result ([pscustomobject]$result) -LogDir $logDir
    if ($installOk) { Write-AuditEntry 'SUCCESS' 'dryrun' } else { Write-AuditEntry 'FAILED' 'dryrun' $result.Message }
    exit ([int](-not $installOk))
}

if (-not $installOk) {
    $result.Status = 'Failed'; $result.Message = "installer exit $($result.InstallerExit)"
    Write-ErrorEntry ("Installer failed with exit code " + $result.InstallerExit + ". See the audit and MSI logs in $logDir.") 'install'
    $put = @(Restore-AfterFailedInstall -Before $before -KeytabCopy $ktCopy -Since $installStarted)
    foreach ($note in $put) { Say ("After the failed install: " + $note) 'WARN' }
    if ($put.Count) { $result.Message += '; ' + ($put -join '; ') }
    $result.After = Get-ConnectorState
    Write-Result -Result ([pscustomobject]$result) -LogDir $logDir
    Write-AuditEntry 'FAILED' 'install' $result.Message
    exit 1
}
Say "Installer finished (exit $($result.InstallerExit))." 'OK'

# ---- Kerberos certificate
# An upgrade does not carry a PFX certificate over: the vendor installer drops that setting and
# makes a certificate of its own. Put the PFX certificate back with the vendor's maintenance script.
$certProblem = $null; $pfxThumb = $null
if (('KerberosAuthService' -in @($job.Services)) -and $job.Pfx -and $SslCertPassword) {
    $certRoot = (Get-ConnectorState).InstallRoot
    $certPath = Join-Path $here $job.Pfx
    Resume-InterruptedCertChange -Here $here -Root $certRoot -Fix $false
    # the service may still be starting after the install: give it three minutes to answer
    $plan = Test-CertificatePlan -Root $certRoot -PfxPath $certPath -Password $SslCertPassword -Reapply $false -WaitSeconds 180
    if ($plan.Pfx -and $plan.Pfx.Ok) { $pfxThumb = $plan.Pfx.Thumbprint }
    foreach ($w in $plan.Warnings) { Say ('Kerberos certificate: ' + $w) 'WARN' }
    if ($plan.Problems.Count) { $certProblem = 'Kerberos certificate: ' + ($plan.Problems -join '; '); Say $certProblem 'WARN' }
    elseif ($plan.Current) { Say ("The Kerberos service serves the PFX certificate ('{0}', valid to {1})." -f $plan.Served.Subject, $plan.Served.NotAfter) 'OK' }
    elseif (-not ($plan.Served -and $plan.Served.Ok)) {
        # no answer, so there is no telling what it serves: change nothing and say so
        $certProblem = "Kerberos certificate: the service did not answer on its port within 3 minutes after the install, so its certificate was not checked or changed; run -Mode RepairCertificate when it is up"
        Say $certProblem 'WARN'
    }
    else {
        Say ("After the install the Kerberos service serves '{0}' issued by '{1}', not the PFX certificate. Installing the PFX certificate..." -f $plan.Served.Subject, $plan.Served.Issuer) 'WARN'
        $set = Set-KerberosCertificate -Root $certRoot -PfxPath $certPath -Password $SslCertPassword -Here $here -Plan $plan
        if ($set.Ok) { Say ('Kerberos certificate installed: ' + $set.Message + '.') 'OK' }
        else { $certProblem = 'Kerberos certificate: ' + $set.Message; Say $certProblem 'WARN' }
    }
}

# ---- Java4Shell patch
if ($job.ApplyJavaPatch) {
    $bat = Join-Path $here 'Java4shellPatch\Java4shellPatch.bat'
    $state = Get-ConnectorState
    if (-not (Test-Path -LiteralPath $bat)) {
        Say 'Java4shellPatch.bat is not staged; patch skipped.' 'WARN'; $result.PatchExit = -2
    } else {
        Say 'Applying the Java4Shell patch (vendor Java4shellPatch.bat)...'
        $p = Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c ""{0}" "{1}""' -f $bat, $state.InstallRoot) -Wait -PassThru -NoNewWindow
        $result.PatchExit = $p.ExitCode
        if ($p.ExitCode -eq 0) { Say 'Patch script finished (exit 0).' 'OK' } else { Write-ErrorEntry "Java4shellPatch.bat exit code $($p.ExitCode)." 'patch' }
    }
}

# ---- health: wait up to 4 minutes for the expected services
$svcMap = @{ DirectorySyncService='AccessDirectorySyncService'; UserAuthService='AccessUserAuthService'; KerberosAuthService='AccessKerberosAuthService'; VirtualAppService='AccessVirtualAppService' }
$expected = @($job.Services | ForEach-Object { $svcMap[$_] })
$deadline = (Get-Date).AddMinutes(4); $after = $null
do {
    Start-Sleep -Seconds 10
    $after = Get-ConnectorState
    $running = @($after.Services | Where-Object { $_.Status -eq 'Running' -and $_.Name -in $expected }).Count
    $flagsOk = (-not $job.ApplyJavaPatch) -or ($after.JavaCount -ge $expected.Count -and $after.JavaWithFlag -eq $after.JavaCount)
} while (($running -lt $expected.Count -or -not $flagsOk) -and (Get-Date) -lt $deadline)
$result.After = $after

$problems = @()
if ($postInstallProblem) { $problems += $postInstallProblem }
if ($running -lt $expected.Count) { $problems += "only $running of $($expected.Count) services running" }
if ($job.ApplyJavaPatch -and -not $flagsOk) { $problems += "java processes with flag $($after.JavaWithFlag)/$($after.JavaCount)" }
if ($job.ExpectVersionPrefix -and -not ([string]$after.InstalledVersion).StartsWith([string]$job.ExpectVersionPrefix)) { $problems += "installed version is $($after.InstalledVersion), expected $($job.ExpectVersionPrefix)*" }
# A keytab with no keys in it is a few bytes long; a usable one is a few hundred.
if (('KerberosAuthService' -in @($job.Services)) -and $after.KeytabBytes -lt 32) { $problems += "Kerberos keytab missing or empty ($($after.KeytabBytes) bytes): run setupKerberos.ps1 on this server signed in as a domain admin" }
# The patch above restarted the services: check what the Kerberos service serves at the very end.
if ($certProblem) { $problems += $certProblem }
elseif ($pfxThumb) {
    $fin = Wait-ServedCertificate -Port (Get-EksPort $after.InstallRoot) -Seconds 90
    if (-not $fin.Ok) { $problems += "the Kerberos service does not answer on its port ($($fin.Message))" }
    elseif ($fin.Thumbprint -ne $pfxThumb) { $problems += "the Kerberos service serves '$($fin.Subject)' issued by '$($fin.Issuer)', not the PFX certificate: use -Mode RepairCertificate" }
    # the state above was read before this last look: refresh only the certificate in it
    try { $after.Cert = (Get-ConnectorState).Cert } catch { }
}
if ($result.InstallerExit -in 3010, 1641) {
    Say 'The installer reports a reboot is required.' 'WARN'
    $problems += 'the installer needs this server restarted: restart it, then run -Mode Verify (and -Mode RepairKeytab if the keytab is empty)'
}

if ($problems.Count) {
    $result.Status = 'Unhealthy'; $result.Message = ($problems -join '; ')
    Write-ErrorEntry ("Post-upgrade check failed: " + $result.Message) 'health'
    Write-Result -Result ([pscustomobject]$result) -LogDir $logDir
    Write-AuditEntry 'FAILED' 'health' $result.Message
    exit 1
}
$result.Status = 'Success'
Say ("After: version {0}; {1} services running; java with flag {2}/{3}" -f $after.InstalledVersion, $running, $after.JavaWithFlag, $after.JavaCount) 'OK'
Write-Result -Result ([pscustomobject]$result) -LogDir $logDir
Write-AuditEntry 'SUCCESS' 'upgrade' ("from=" + $before.InstalledVersion + " to=" + $after.InstalledVersion)
exit 0
