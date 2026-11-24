<#
.SYNOPSIS
    Automated upgrade of Omnissa Access Connectors, one connector at a time per
    tenant, to the installer version named in the fleet file, with an optional
    Java4Shell patch step (HW-283446) and a health gate.
    Modes: SSH (any OS), WinRM (Windows), Stage (run locally or scheduled),
    Verify (report only), RepairKeytab, RepairCertificate, Discover (draft a
    spreadsheet). -ImportFleet turns a spreadsheet into the fleet file. Run
    with -Help for full usage. Requires PowerShell 7.
#>
[CmdletBinding()]
param(
    [string]$FleetConfig,
    [string]$Fleet,
    [ValidateSet('SSH','WinRM','Stage','Verify','RepairKeytab','RepairCertificate','Discover')]
    [string]$Mode = 'SSH',
    [string[]]$Tenant,
    [string[]]$Connector,
    [switch]$DryRun,
    [switch]$ForceReinstall,
    [switch]$Reapply,
    [switch]$SkipJavaPatch,
    [switch]$SkipDomainCheck,
    [string]$SshUser,
    [string]$SshKey,
    [string]$RemoteStageDir = 'C:\ProgramData\AccessConnectorUpdate',
    [System.Management.Automation.PSCredential]$Credential,
    [System.Management.Automation.PSCredential]$RunAsCredential,
    [ValidateSet('Default','Negotiate','Kerberos','CredSSP')]
    [string]$Authentication = 'Negotiate',
    [switch]$Parallel,
    [switch]$ParallelTenants,
    [switch]$ContinueOtherTenants,
    [switch]$Yes,
    [string]$AuditLog,
    [string]$ErrorLog,
    [string]$ImportFleet,
    [string]$ExportCsv,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
# 'pwsh -File' passes "A,B" as one string, so split comma lists here.
if ($Tenant)    { $Tenant    = @($Tenant    | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
if ($Connector) { $Connector = @($Connector | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
$script:Version  = '1.5.1'
$script:UiWidth  = 78
$script:Name     = 'Invoke-AccessConnectorUpgrade.ps1'
$script:Started  = Get-Date
$script:AuditPath = $null
$script:ErrorPath = $null
$script:AuditWritten = $false
$script:SecretValues = [System.Collections.Generic.List[string]]::new()
$script:Supplied = [System.Collections.Generic.HashSet[string]]::new([string[]]$PSBoundParameters.Keys)
# Screen spacing: what the last relayed line was, so blank lines go in once and only where wanted.
$script:Rm = @{ Prev = ''; Blank = $false; InBlock = $false; AtGap = $false }

# ---------------------------------------------------------------- UI helpers
function Initialize-UiStyle {
    $useColor = $true
    if ($env:NO_COLOR) { $useColor = $false }
    try { if ([Console]::IsOutputRedirected) { $useColor = $false } } catch { }
    if ($env:OMNISSA_UI_COLOR) { $useColor = $true }
    $e = [char]27
    $script:ui = @{}
    if ($useColor) {
        $script:ui = @{
            Reset="$e[0m"; Banner="$e[1;97;44m"; Section="$e[1;96;100m"; Legal="$e[1;97;41m"
            Rule="$e[38;5;240m"; Cmd="$e[92m"; Flag="$e[1;93m"; Text="$e[38;5;250m"
            Warn="$e[1;91m"; Notice="$e[1;93m"; Ok="$e[92m"; Info="$e[96m"; Dim="$e[38;5;244m"
            # Notice = bold yellow (the UNSUPPORTED notice); Caution = yellow (warnings);
            # Warn = bold red (alerts and errors); Prompt = purple (questions put to the operator).
            Caution="$e[93m"; Prompt="$e[1;38;5;141m"
        }
    } else { foreach ($k in 'Reset','Banner','Section','Legal','Rule','Cmd','Flag','Text','Warn','Notice','Ok','Info','Dim','Caution','Prompt') { $script:ui[$k] = '' } }
}
function Get-WrappedLines {
    param([string]$Text, [int]$Width = 78, [string]$Indent = '')
    $out = [System.Collections.Generic.List[string]]::new(); $cur = ''
    foreach ($w in ($Text -split '\s+' | Where-Object { $_ })) {
        $cand = if ($cur) { "$cur $w" } else { "$Indent$w" }
        if ($cand.Length -le $Width) { $cur = $cand } else { if ($cur) { $out.Add($cur) }; $cur = "$Indent$w" }
    }
    if ($cur) { $out.Add($cur) }
    return $out
}
function Get-HangingLines {
    # Splits one line of text into lines no wider than $Width. Lines after the first start with
    # $Hang spaces. Runs of spaces inside the text are kept, so padded columns stay aligned. A
    # piece too long for a line (a path, a list with no spaces) is cut after a separator.
    param([string]$Text, [int]$Hang = 0, [int]$Width = $script:UiWidth)
    $out = [System.Collections.Generic.List[string]]::new()
    $t = ([string]$Text -replace "`t", '    ').TrimEnd()
    if ($t.Length -le $Width -or $Width -lt 1) { $out.Add($t); return $out }
    $Hang = [Math]::Max(0, [Math]::Min($Hang, $Width - 24))
    # text indented by nearly the whole width: pull it back so there is room to wrap
    $lw = $t.Length - $t.TrimStart().Length
    if ($lw -gt [Math]::Max(0, $Width - 24)) { $t = (' ' * [Math]::Max(0, $Width - 24)) + $t.TrimStart(); if ($t.Length -le $Width) { $out.Add($t); return $out } }
    $pad = ' ' * $Hang; $seps = [char[]]'\/,;=|'
    $cur = ''; $started = $false
    foreach ($m in [regex]::Matches($t, '(\s*)(\S+)')) {
        $ws = $m.Groups[1].Value; $w = $m.Groups[2].Value; $tok = 0
        if (-not $started) { $cur = $ws + $w; $tok = $ws.Length; $started = $true }
        elseif (($cur.Length + $ws.Length + $w.Length) -le $Width) { $cur += $ws + $w; continue }
        elseif ($w.Length -gt ($Width - $Hang)) { $tok = $cur.Length + $ws.Length; $cur += $ws + $w }
        else { $out.Add($cur.TrimEnd()); $cur = $pad + $w; continue }
        # $cur now ends in a piece that does not fit; $tok is where that piece starts
        while ($cur.Length -gt $Width) {
            $i = $cur.LastIndexOfAny($seps, $Width - 1)
            if ($i -ge ($tok + 3) -and $i -ge $Hang) { $cut = $i + 1 }
            elseif ($tok -gt $Hang -and $cur.Substring(0, $tok).Trim()) {
                # no good place to cut on this line: move the whole piece down and try again
                $out.Add($cur.Substring(0, $tok).TrimEnd()); $cur = $pad + $cur.Substring($tok).TrimStart(); $tok = $Hang; continue }
            else { $cut = $Width }
            if ($cut -gt 1 -and [char]::IsHighSurrogate($cur[$cut - 1])) { $cut-- }
            $out.Add($cur.Substring(0, $cut)); $cur = $pad + $cur.Substring($cut); $tok = $Hang
        }
    }
    if ($cur.Trim()) { $out.Add($cur.TrimEnd()) }
    return $out
}
function Reset-UiSpacing { param([switch]$AtGap) $script:Rm = @{ Prev = ''; Blank = $false; InBlock = $false; AtGap = [bool]$AtGap } }
function Write-UiBlank { if (-not $script:Rm.AtGap) { Write-Host '' }; Reset-UiSpacing -AtGap }
function Write-UiRule { Write-Host ($script:ui.Rule + ('-' * $script:UiWidth) + $script:ui.Reset) }
function Write-UiSection { param([string]$Text, [switch]$Legal)
    if (-not $script:Rm.AtGap) { Write-Host '' }
    Reset-UiSpacing
    $tag = if ($Legal) { $script:ui.Legal } else { $script:ui.Section }
    Write-Host ($tag + ' ' + $Text + ' ' + $script:ui.Reset); Write-UiRule }
function Write-UiText { param([string]$T, [string]$I = '  ')
    Reset-UiSpacing
    foreach ($l in (Get-WrappedLines -Text $T -Width $script:UiWidth -Indent $I)) { Write-Host ($script:ui.Text + $l + $script:ui.Reset) } }
function Write-UiWarn { param([string]$T, [string]$I = '  ')
    Reset-UiSpacing
    foreach ($l in (Get-WrappedLines -Text $T -Width $script:UiWidth -Indent $I)) { Write-Host ($script:ui.Warn + $l + $script:ui.Reset) } }
function Write-UiCaption { param([string]$T) Reset-UiSpacing; Write-Host ($script:ui.Dim + '  ' + $T + $script:ui.Reset) }
function Write-UiCmd { param([string]$T) Reset-UiSpacing; Write-Host ($script:ui.Cmd + '  ' + $T + $script:ui.Reset) }
function Write-UiParam { param([string]$Flag, [string]$Desc)
    $col = 26
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
    Reset-UiSpacing -AtGap
}
function Read-UiTyped { param([string]$Prompt, [string]$PromptStyle, [ConsoleColor]$TypedColor, [switch]$Secret)
    # Shows the prompt in its own colour, then reads a line. What the operator types (or the
    # asterisks standing in for a password) is shown in $TypedColor. Plain when colour is off.
    Reset-UiSpacing
    $noTerm = "A prompt needs an answer, but this run has no terminal to type it in: $($Prompt.Trim()). " + $(if ($Prompt -match 'Type YES') { 'Add -Yes to confirm without a prompt' } else { 'Run it from an interactive terminal (passwords are only ever asked at prompts)' + $(if ($Mode -in 'SSH','WinRM' -and -not $script:Supplied.Contains('ImportFleet')) { ', or use -Mode Stage' } else { '' }) }) + '. Nothing was changed.'
    $redirected = $false; try { $redirected = [Console]::IsInputRedirected } catch { }
    if ($redirected -and $Host.Name -eq 'ConsoleHost') { Stop-Run $noTerm 'secrets' }
    try {
        if (-not $script:ui.Reset -or $Host.Name -ne 'ConsoleHost') {
            if ($Secret) { return (Read-Host -AsSecureString $Prompt) } else { return (Read-Host $Prompt) } }
        Write-Host ($PromptStyle + $Prompt + ': ' + $script:ui.Reset) -NoNewline
        try { [Console]::ForegroundColor = $TypedColor } catch { }
        try { if ($Secret) { return (Read-Host -AsSecureString) } else { return (Read-Host) } }
        finally { try { [Console]::ResetColor() } catch { } }
    } catch [System.Management.Automation.PSInvalidOperationException] { Write-Host ''; Stop-Run $noTerm 'secrets' }   # pwsh -NonInteractive
}
function Read-UiSecret  { param([string]$Prompt) Read-UiTyped -Prompt $Prompt -PromptStyle $script:ui.Prompt -TypedColor DarkGray -Secret }
function Read-UiConfirm { param([string]$Prompt) Read-UiTyped -Prompt $Prompt -PromptStyle $script:ui.Warn -TypedColor White }
function Read-UiCredential { param([string]$Message)
    # Replaces Get-Credential so the account prompt follows the same colours as the others.
    Reset-UiSpacing
    Write-Host ($script:ui.Prompt + '  ' + $Message + $script:ui.Reset)
    $u = ([string](Read-UiTyped -Prompt '    User name (DOMAIN\user)' -PromptStyle $script:ui.Prompt -TypedColor White)).Trim()
    if (-not $u) { Stop-Run 'No user name was entered for the connector sign-in.' 'secrets' }
    $p = Read-UiSecret "    Password for $u"
    if ($p.Length -eq 0) { Stop-Run "Empty password for $u." 'secrets' }
    return [pscredential]::new($u, $p) }
function Write-RemoteLine { param([string]$Line)
    # Output relayed from a connector arrives as plain text. Here it is coloured by what it says,
    # wrapped to the divider width (later lines indented under the text they continue), and
    # spaced: one blank line around each framed block, never two in a row. The logs on the
    # connector and their copies keep the original unwrapped lines.
    $t = ((Protect-Text ([string]$Line)) -replace "`t", '    ').TrimEnd()
    $st = $script:Rm
    if ($t -eq '') { $st.Blank = $true; return }
    $w = $script:UiWidth - 4
    $lead = $t.Length - $t.TrimStart().Length
    $c = $script:ui.Text
    if     ($t -match 'UNSUPPORTED - provided|Omnissa nor the author is liable') { $c = $script:ui.Notice }
    elseif ($t -match '\[(ERROR|FAIL\w*|FATAL)\s*\]')                         { $c = $script:ui.Warn }
    elseif ($t -match '^\s*(ERROR|FATAL)\b|^At \S.*:\d+ char:\d+|^\s*\+ (CategoryInfo|FullyQualifiedErrorId)\s*:') { $c = $script:ui.Warn }
    elseif ($t -match '\[WARN\w*\s*\]')                                       { $c = $script:ui.Caution }
    elseif ($t -match '\[OK\s*\]|^\s*Result\s*:\s*SUCCESS')                  { $c = $script:ui.Ok }
    elseif ($t -match '^\s*Result\s*:')                                       { $c = $script:ui.Warn }
    elseif ($t -match '^\s*={5,} \S.* ={5,}$')                                 { $c = $script:ui.Info }
    elseif ($t -match '^\s*[=-]{20,}$')                                        { $c = $script:ui.Rule }
    $kind = 'text'; $hang = $lead + 2; $gap = $false
    if ($c -eq $script:ui.Notice -and $t -match 'UNSUPPORTED - provided|Omnissa nor the author is liable') {
        $kind = 'notice'; $t = $t.TrimStart(); $hang = 0
    }
    elseif ($t -match '^(\s*)([=-])\2{19,}$') {
        # a divider: never wider than the space there is
        $ch = [string]$Matches[2]
        if ($t.Length -gt $w) { $t = (' ' * $lead) + ($ch * [Math]::Max(20, $w - $lead)) }
        if ($ch -eq '=') {
            if ($st.InBlock) { $kind = 'close'; $st.InBlock = $false } else { $kind = 'open'; $gap = $true; $st.InBlock = $true }
        } else { $kind = 'rule'; if (-not $st.InBlock) { $gap = $true; $st.InBlock = $true } }
    }
    elseif ($t -match '^(\s*)(={5,}) (\S.*?) (={5,})$') {
        # a titled divider opens a block
        $kind = 'banner'; $gap = $true; $st.InBlock = $true
        if ($t.Length -gt $w) {
            $title = [string]$Matches[3]
            $side = [Math]::Max(3, [int][Math]::Floor(($w - $lead - $title.Length - 2) / 2))
            $t = (' ' * $lead) + ('=' * $side) + ' ' + $title + ' ' + ('=' * $side)
        }
    }
    elseif ($t -match '^(\s*)\[(?:\d{4}-\d\d-\d\d[ T])?(\d\d:\d\d:\d\d)(?:[.,]\d+)?\] \[([A-Za-z]+)\s*\] ?(.*)$') {
        # a log line: show the time without the date, and continue under the message
        $kind = 'log'; $st.InBlock = $false
        $p = '{0}[{1}] [{2,-5}] ' -f $Matches[1], $Matches[2], $Matches[3]
        $t = $p + $Matches[4]; $hang = $p.Length
    }
    elseif ($t -match '^(\s*\S[^:]{0,26}: +)\S') { $hang = $Matches[1].Length }   # "Name : value" continues under the value
    if ($kind -eq 'log' -and $st.Prev -eq 'text') { $gap = $true }   # back to timed lines after a tool's own output
    if (($gap -or $st.Blank -or $st.Prev -eq 'close') -and -not $st.AtGap) { Write-Host '' }
    foreach ($l in (Get-HangingLines -Text $t -Hang $hang -Width $w)) { Write-Host ('    ' + $c + $l + $script:ui.Reset) }
    $st.Prev = $kind; $st.Blank = $false; $st.AtGap = $false }
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
    Reset-UiSpacing
    Show-Disclaimer
    Write-UiSection 'SYNOPSIS'
    Write-UiText 'Upgrades Omnissa Access Connectors one at a time per tenant, to the version of the installer named in the fleet file, and stops if a connector is not healthy afterwards. When the fleet file names a patch folder (JavaPatchDir) it also applies the Java4Shell patch (HW-283446) after the install.'
    Write-UiText 'On connectors with the Kerberos Auth service and a PFX, an upgrade ends by putting the PFX certificate back on that service and checking that it is the one served. (The vendor installer does not carry it through an upgrade; it makes a certificate of its own.)'
    Write-UiSection 'DESCRIPTION'
    Write-UiText 'Reads a fleet file (.psd1) listing tenants and their connectors. For each connector it copies the installer, the tenant config file, the trust certificates, the Kerberos PFX and the patch to local disk on the connector, then runs Invoke-ConnectorUpgradeLocal.ps1 there. That helper runs Install-AccessConnector.ps1, the vendor patch script and a health check.'
    Write-UiText 'Passwords are asked once per tenant at hidden prompts. In SSH mode they travel inside the SSH session on standard input; they are never placed on a command line by this script, in the fleet file or in a log. (The vendor installer itself receives them on its own command line on the connector and records them, base64-encoded, in its own log; that is an installer limitation. This tool replaces them with asterisks in that log after every install.)'
    Write-UiText 'Before anything is asked, an upgrade or dry run over SSH and the two repair modes check the SSH sign-in on every selected connector. When one fails, the run stops there with exit code 1: each failing connector is named with SSH''s own reason and, when that reason suggests one, a hint; nothing is changed and no password is asked.'
    Write-UiSection 'INSTALLER SETTINGS FROM THE FLEET FILE'
    Write-UiText 'Besides the services, certificates, service account and syslog target, a fleet entry can set the install folder (InstallDir), FIPS mode (EnableFips), the four service ports (DirectorySyncPort, UserAuthPort, KerberosAuthPort, VirtualAppPort) and an outbound proxy (ProxyHost, ProxyPort, ProxyUser, NonProxyHosts). They are checked before any connector is contacted and shown in the plan. When ProxyUser is set, the proxy password is asked at run time with the others. A misspelt setting is named in a note.'
    Write-UiSection 'BUILDING THE FLEET FILE FROM A SPREADSHEET'
    Write-UiText 'Instead of editing the fleet file by hand, fill in a copy of a template (fleet.example.xlsx or fleet.example.csv beside this script, saved under a name of your own: one row per connector, the Group column names the fleet entry) and convert it with -ImportFleet. It accepts .xlsx (first sheet) and .csv, .txt or .tsv saved by Excel in any regional setting. Every value is checked before anything is written; with -DryRun nothing is written. An existing fleet file is kept as a dated copy, and its top-level settings are carried over. Passwords never go in the spreadsheet: a column that looks like one is refused.'
    Write-UiText 'For connectors that are already installed, -Mode Discover reads their settings over SSH (read-only: nothing is copied to or changed on them) and writes a draft spreadsheet to complete and import. Hosts come from -Connector, or from the fleet file.'
    Write-UiSection 'WHICH FLEET FILE IS USED'
    Write-UiText 'So one shared folder can serve several machines, the fleet file is chosen in this order, first match wins: -FleetConfig; -Fleet <name>; fleet.<this computer name>.psd1; fleet.<this computer domain>.psd1; fleet.psd1. The plan shown before any change names the file in use and why.'
    Write-UiSection 'WHEN A TENANT''S FILES ARE IN ANOTHER COPY OF THE FOLDER'
    Write-UiText 'The installer, config file, certificates and PFX are looked for beside the folder this script is run from. When a tenant''s files are not there, the run stops before anything is contacted and the error names another copy of the folder that has them, with the cd command to use. Other copies are looked for on every mounted volume (macOS) or drive (Windows): at this folder''s own path, and at each path listed under StagingFolders in the fleet file.'
    Write-UiSection 'MODES'
    Write-UiParam 'SSH (default)' 'Runs from macOS, Linux or Windows using ssh and scp with key sign-in. Connectors without the Kerberos service: the installer runs as the SSH account. Kerberos connectors: it runs on the connector as a one-time scheduled task under a domain admin account you are asked for (see -RunAsCredential), because only a full sign-in can rebuild the keytab.'
    Write-UiParam 'WinRM' 'Runs from Windows over PowerShell remoting with a domain credential per tenant. Kerberos connectors use the same scheduled task with that sign-in, or run directly with -Authentication CredSSP. A sign-in that a connector refuses (a wrong user name or password, say) stops that tenant, and the run unless -ContinueOtherTenants, in a dry run too.'
    Write-UiParam 'Stage' 'Copies everything and writes Run-Upgrade.cmd on each connector. You then sign in to the connector as a domain admin and run it, or schedule it with -Schedule on the helper. No passwords are asked here.'
    Write-UiParam 'Verify' 'Changes nothing. Reports version, services and patch state for each connector over SSH.'
    Write-UiParam 'RepairKeytab' 'Installs nothing. On each Kerberos connector, over SSH, runs the vendor setupKerberos.ps1 as a one-time scheduled task under a domain admin account, then restarts the Kerberos service. Use it when Verify shows keytab EMPTY. With -DryRun it only tests the sign-in.'
    Write-UiParam 'Discover' 'Changes nothing and copies nothing to the connectors. Over SSH, reads each connector''s version, services, service account, syslog target, ports, proxy, install folder, FIPS mode, tenant and served Kerberos certificate, and writes a draft spreadsheet (CSV) for -ImportFleet. Only allow-listed settings leave the connector; the value of any other line, the secrets included, is never kept or sent. Hosts: -Connector (then -Tenant has no effect), else the fleet file (-Tenant filters).'
    Write-UiParam 'RepairCertificate' 'Installs nothing. On each Kerberos connector that has a PFX in the fleet file, over SSH, puts the PFX certificate on the Kerberos Auth service with the vendor installKerberosAuthService.bat -updateConfiguration, restarts that service and confirms it serves the certificate. Use it when Verify shows a certificate made by the installer: the vendor installer does not carry a PFX certificate through an upgrade. Asks for the PFX password only. With -DryRun it tests the PFX and its password and changes nothing.'
    Write-UiSection 'PARAMETERS'
    Write-UiParam '-FleetConfig <path>' 'Fleet definition file, by path (a relative path is taken from the current folder). Overrides the automatic choice below.'
    Write-UiParam '-Fleet <name>' 'Use fleet.<name>.psd1 beside this script, for example -Fleet lab.'
    Write-UiParam '-Mode <name>' 'SSH, WinRM, Stage, Verify, RepairKeytab, RepairCertificate or Discover.'
    Write-UiParam '-Tenant <names>' 'Only these tenants (fleet order is kept).'
    Write-UiParam '-Connector <hosts>' 'Only these connector hosts.'
    Write-UiParam '-DryRun' 'Stage, then run the installer pre-flight only. Nothing is installed. The pre-flight always runs, also on a connector a real run would skip (already on the installer version); the result then says that a real run would skip it.'
    Write-UiParam '-ForceReinstall' 'Same version: uninstall then fresh install.'
    Write-UiParam '-Reapply' 'RepairCertificate only: install the PFX certificate even when the connector already serves it, or when the certificate does not name the connector.'
    Write-UiParam '-SkipJavaPatch' 'Do not run the Java4Shell patch after the upgrade, even when the fleet file names its folder.'
    Write-UiParam '-SkipDomainCheck' 'Kerberos connectors only. Upgrade even when the sign-in used on the connector cannot query Active Directory. The upgrade then leaves an empty keytab, and Kerberos sign-in stays broken until setupKerberos.ps1 is run there by a domain admin.'
    Write-UiParam '-SshUser <name>' 'SSH account. Default: per connector in the fleet file, else administrator.'
    Write-UiParam '-SshKey <path>' 'SSH private key file. Default: your ssh configuration or agent.'
    Write-UiParam '-RemoteStageDir <p>' 'Folder on each connector. Default C:\ProgramData\AccessConnectorUpdate.'
    Write-UiParam '-Credential <cred>' 'WinRM only: one credential for every tenant. Default: asked per tenant.'
    Write-UiParam '-RunAsCredential <c>' 'Kerberos connectors: the domain admin account the upgrade runs under on each connector, as a one-time scheduled task, so the Kerberos keytab can be rebuilt. Default: asked per tenant in SSH mode; WinRM mode reuses its sign-in.'
    Write-UiParam '-Authentication <a>' 'WinRM only: Negotiate (default), Kerberos, CredSSP or Default.'
    Write-UiParam '-Parallel' 'Upgrade every selected connector at the same time. Fastest, but each tenant is fully offline while it runs and a failure cannot stop the others, except a WinRM sign-in that a connector refuses: the connectors not yet started are then left alone.'
    Write-UiParam '-ParallelTenants' 'Run tenants side by side, still one connector at a time inside each tenant, so every tenant with two or more connectors keeps one online.'
    Write-UiParam '-ContinueOtherTenants' 'After a failure, stop that tenant but carry on with the others. Default: stop everything.'
    Write-UiParam '-Yes' 'Do not ask for confirmation before changing connectors.'
    Write-UiParam '-ImportFleet <file>' 'Check a spreadsheet (.xlsx, .csv, .txt, .tsv) and write the fleet file from it: -FleetConfig or -Fleet name it, else fleet.psd1. With -DryRun, check only. Replacing a file that holds groups asks for YES (or -Yes); the old one is kept as <file>.bak-<date>.'
    Write-UiParam '-ExportCsv <path>' 'Discover only: file or folder for the draft spreadsheet. Default fleet.discovered_<date>.csv beside this script; a folder gets that name in it. An existing file is never overwritten.'
    Write-UiParam '-AuditLog <path>' 'Append-only audit log. File or folder.'
    Write-UiParam '-ErrorLog <path>' 'Error log. File or folder.'
    Write-UiParam '-Help' 'Show this help.'
    Write-UiSection 'EXAMPLES'
    Write-UiCaption '# Report the current state of every connector (no changes)'
    Write-UiCmd './Invoke-AccessConnectorUpgrade.ps1 -Mode Verify `'
    Write-UiCmd '    -SshKey ~/.ssh/connector_ed25519'
    Write-Host ''
    Write-UiCaption '# Pre-flight one tenant over SSH (nothing installed)'
    Write-UiCmd './Invoke-AccessConnectorUpgrade.ps1 -Tenant TENANT1 -DryRun `'
    Write-UiCmd '    -SshKey ~/.ssh/connector_ed25519'
    Write-Host ''
    Write-UiCaption '# Upgrade one tenant over SSH, with audit and error logs'
    Write-UiCmd './Invoke-AccessConnectorUpgrade.ps1 -Tenant TENANT1 `'
    Write-UiCmd '    -SshKey ~/.ssh/connector_ed25519 -AuditLog ./logs/ -ErrorLog ./logs/'
    Write-Host ''
    Write-UiCaption '# Every connector of one tenant at once (tenant offline meanwhile)'
    Write-UiCmd './Invoke-AccessConnectorUpgrade.ps1 -Tenant TENANT2 -Parallel `'
    Write-UiCmd '    -SshKey ~/.ssh/connector_ed25519'
    Write-Host ''
    Write-UiCaption '# Use a named fleet file (fleet.lab.psd1) and report only'
    Write-UiCmd './Invoke-AccessConnectorUpgrade.ps1 -Fleet lab -Mode Verify'
    Write-Host ''
    Write-UiCaption '# Draft a spreadsheet from connectors already installed (read-only)'
    Write-UiCmd './Invoke-AccessConnectorUpgrade.ps1 -Mode Discover `'
    Write-UiCmd '    -Connector connector1.example.local,connector2.example.local'
    Write-Host ''
    Write-UiCaption '# Check a spreadsheet, then write fleet.psd1 from it'
    Write-UiCmd './Invoke-AccessConnectorUpgrade.ps1 -ImportFleet ./fleet.xlsx -DryRun'
    Write-UiCmd './Invoke-AccessConnectorUpgrade.ps1 -ImportFleet ./fleet.xlsx'
    Write-Host ''
    Write-UiCaption '# Whole fleet from Windows over WinRM with CredSSP'
    Write-UiCmd '.\Invoke-AccessConnectorUpgrade.ps1 -Mode WinRM -Authentication CredSSP'
    Write-Host ''
    Write-UiCaption '# Stage only, then run Run-Upgrade.cmd on each connector yourself'
    Write-UiCmd './Invoke-AccessConnectorUpgrade.ps1 -Mode Stage -Tenant TENANT1'
    Write-Host ''
    Write-UiCaption '# Rebuild an empty Kerberos keytab (asks for a domain admin account)'
    Write-UiCmd './Invoke-AccessConnectorUpgrade.ps1 -Mode RepairKeytab -Tenant TENANT1 `'
    Write-UiCmd '    -SshKey ~/.ssh/connector_ed25519'
    Write-Host ''
    Write-UiCaption '# Put the PFX certificate back on the Kerberos service after an upgrade'
    Write-UiCmd './Invoke-AccessConnectorUpgrade.ps1 -Mode RepairCertificate `'
    Write-UiCmd '    -Tenant TENANT1 -SshKey ~/.ssh/connector_ed25519'
    Write-UiSection 'OUTPUT'
    Write-UiText 'A per-connector line on screen, a summary grouped by tenant, a CSV, and each connector''s logs copied to the central log folder named in the fleet file. Screen output is wrapped to the divider width; the logs keep the original unwrapped lines. Exit code 0 when every selected connector succeeded, otherwise 1.'
    Write-UiText '-ImportFleet writes the fleet file (and keeps a replaced one as <file>.bak-<date>); exit code 0 when it was written, or with -DryRun when the spreadsheet is usable, otherwise 1. -Mode Discover writes the draft spreadsheet; exit code 1 when any host could not be read.'
    Write-UiText '-Mode Verify: exit code 1 when a connector could not be read or its line is red (a service not running, the Kerberos keytab empty or missing, or, for a group with a Pfx, a certificate that is not a proper one), with an error-log entry for each red connector naming what is red. Yellow lines (nothing installed, a Java process without the patch flag) keep exit code 0.'
    Write-UiSection 'LOGGING'
    Write-UiText 'Audit log (-AuditLog): one appended key=value line per run saying who ran what and the outcome. Error log (-ErrorLog): the detail of each failure. Passwords are masked everywhere, including in the vendor installer logs copied back from each connector.'
    Write-UiSection 'REQUIREMENTS'
    Write-UiText 'PowerShell 7 or later (pwsh) on the machine running this script; it refuses to start under Windows PowerShell 5.1. The connectors need only the Windows PowerShell 5.1 that Windows Server has. SSH, Stage, Verify and the repair modes need ssh and scp on the PATH and key sign-in to each connector; Discover needs ssh only. -ImportFleet needs neither. WinRM mode needs Windows and PowerShell remoting enabled on the connectors. The staging share must be readable from the machine running this script.'
    Write-UiSection 'ABOUT'
    Write-UiText "Version $($script:Version). Created 2026-11-21. MIT License; see the LICENSE file."
    Write-UiSection 'DOCUMENTATION'
    Write-UiText 'Omnissa OMSA-2026-0003, KB 6001878, and the Access Connector installation guide (silent mode chapter).'
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
    if (-not $S) { return '' }
    return [System.Net.NetworkCredential]::new('', $S).Password }
function Resolve-LogPath { param([string]$Value, [string]$DefaultName)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $v = $Value.Trim()
    if ((Test-Path -LiteralPath $v -PathType Container) -or $v.EndsWith([IO.Path]::DirectorySeparatorChar) -or $v.EndsWith('/')) { $v = Join-Path $v $DefaultName }
    $dir = Split-Path -Parent $v
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    return $v }
function Say { param([string]$Message, [string]$Level = 'INFO')
    # One timed line, wrapped to the divider width with later lines under the message. A message
    # may hold line breaks; each further line is shown under the message, keeping its own indent.
    $m = Protect-Text $Message
    $c = switch ($Level) { 'OK' { $script:ui.Ok } 'WARN' { $script:ui.Caution } 'ERROR' { $script:ui.Warn } default { $script:ui.Text } }
    # a blank line between output relayed from a connector and this script's own next line
    if (($script:Rm.Prev -or $script:Rm.Blank) -and -not $script:Rm.AtGap) { Write-Host '' }
    Reset-UiSpacing
    $prefix = '[{0}] [{1,-5}] ' -f (Get-Date -Format 'HH:mm:ss'), $Level
    $first = $true
    foreach ($para in (([string]$m).TrimEnd("`r", "`n") -split "`r?`n")) {
        if ($first) { $text = $prefix + $para; $hang = $prefix.Length; $first = $false }
        else {
            if (-not $para.Trim()) { Write-Host ''; continue }
            $lead = $para.Length - $para.TrimStart().Length
            $text = (' ' * $prefix.Length) + $para; $hang = $prefix.Length + $lead + $(if ($lead) { 2 } else { 0 })
        }
        foreach ($l in (Get-HangingLines -Text $text -Hang $hang)) { Write-Host ($c + $l + $script:ui.Reset) }
    }
}
function Write-ErrorEntry { param([string]$Message, [string]$Stage, [System.Management.Automation.ErrorRecord]$Record, [switch]$LogOnly)
    # -LogOnly: the error log only, for a failure the screen already shows in its own way
    $m = Protect-Text $Message
    if (-not $LogOnly) { Say $m 'ERROR' }
    if (-not $script:ErrorPath) { return }
    $stamp = (Get-Date).ToString('o')
    $m = (($m.Trim()) -replace ':\s*\r?\n\s*', ': ') -replace '\s*\r?\n\s*', ' | '   # one line in the log
    $lines = @("$stamp [ERROR]$(if ($Stage) { " [$Stage]" }) $m")
    if ($Record) { $lines += "$stamp [ERROR]   at line $($Record.InvocationInfo.ScriptLineNumber): " + (Protect-Text ([string]$Record.InvocationInfo.Line).Trim()) }
    if (-not (Test-Path -LiteralPath $script:ErrorPath)) { Add-Content -LiteralPath $script:ErrorPath -Encoding utf8 -Value "# $($script:Name) error log - created $stamp" }
    Add-Content -LiteralPath $script:ErrorPath -Value $lines -Encoding utf8 }
function Write-AuditEntry { param([ValidateSet('SUCCESS','FAILED')][string]$Outcome, [string]$Stage, [int]$Rows = -1, [string]$Detail)
    if (-not $script:AuditPath -or $script:AuditWritten) { return }
    $f = [ordered]@{ time=(Get-Date).ToString('o'); user=[Environment]::UserName; host=[Environment]::MachineName
        script=$script:Name; version=$script:Version; mode=$(if ($script:Supplied.Contains('ImportFleet')) { 'ImportFleet' } else { $Mode }); dryRun=[bool]$DryRun; outcome=$Outcome }
    if ($Stage) { $f['stage'] = $Stage }
    if ($Rows -ge 0) { $f['connectors'] = $Rows }
    $f['durationSec'] = [math]::Round(((Get-Date) - $script:Started).TotalSeconds, 1)
    if ($Detail) { $f['detail'] = (Protect-Text ($Detail -replace '\s+', ' ')).Trim() }
    $line = ($f.GetEnumerator() | ForEach-Object { $v = [string]$_.Value
        if ($v -match '[\s"]') { '{0}="{1}"' -f $_.Key, ($v -replace '"', "'") } else { '{0}={1}' -f $_.Key, $v } }) -join ' '
    if (-not (Test-Path -LiteralPath $script:AuditPath)) { Add-Content -LiteralPath $script:AuditPath -Encoding utf8 -Value ("# $($script:Name) audit log - append only - created " + (Get-Date).ToString('o')) }
    Add-Content -LiteralPath $script:AuditPath -Value $line -Encoding utf8
    $script:AuditWritten = $true }
function Stop-Run { param([string]$Message, [string]$Stage)
    Write-ErrorEntry $Message $Stage
    Write-AuditEntry -Outcome FAILED -Stage $Stage -Detail $Message
    exit 1 }

# ----------------------------------------------------------------- transport
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
function Show-SshErrors { param($Task, [string]$HostName)
    # ssh's own messages (cannot connect, key refused) arrive apart from the connector's output.
    if (-not $Task) { return }
    $text = ''
    try { $text = [string]$Task.GetAwaiter().GetResult() } catch { return }
    foreach ($l in ($text -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($l) -or $l -match '^#< CLIXML|^<Objs ') { continue }
        foreach ($wl in (Get-HangingLines -Text (Protect-Text ("ssh ($HostName): " + $l.Trim())) -Hang 4 -Width ($script:UiWidth - 4))) {
            Write-Host ('    ' + $script:ui.Warn + $wl + $script:ui.Reset) }
        Reset-UiSpacing
    }
}
function Get-SshBaseArgs {
    $a = @('-o','LogLevel=ERROR','-o','BatchMode=yes','-o','ConnectTimeout=15','-o','ServerAliveInterval=30','-o','StrictHostKeyChecking=accept-new')
    if ($SshKey) { $a += @('-i', $SshKey) }
    return $a }
function Get-SshTarget { param($Conn) "$($Conn.SshUser)@$($Conn.Host)" }
function ConvertFrom-RemoteErrorText { param([string]$Text)
    # The messages in what ssh passed on from standard error, one per line, trimmed: ssh's own
    # lines as they are, and the text of each error record Windows PowerShell sent as CLIXML (a
    # '#< CLIXML' line, then '<Objs ...>'), without the position lines PowerShell puts under an
    # error. Progress records and terminal colour codes are dropped.
    $esc = [string][char]27
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($l in ([string]$Text -split '\r\n|\r|\n')) {
        $t = ($l -replace "$esc\[[0-9;?]*[A-Za-z]", '').Trim()
        if (-not $t -or $t -eq '#< CLIXML') { continue }
        if ($t -notmatch '^<Objs ') { $out.Add($t); continue }
        foreach ($m in [regex]::Matches($t, '<S S="Error">(.*?)</S>')) {
            $v = [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
            try { $v = [System.Xml.XmlConvert]::DecodeName($v) } catch { }
            foreach ($vl in (($v -replace "$esc\[[0-9;?]*[A-Za-z]", '') -split '\r\n|\r|\n')) {
                $vt = $vl.Trim()
                if ($vt -and $vt -notmatch '^(At line:\d+ char:\d+|At \S.*:\d+ char:\d+|\+( |$))') { $out.Add($vt) }
            }
        }
    }
    return $out.ToArray() }
function Invoke-SshPs { param($Conn, [string]$ScriptText, [int]$TimeoutSec = 0)
    # Runs a short Windows PowerShell script on the connector; nothing is sent on standard input.
    # Returns ExitCode (ssh's own: 255 when ssh could not connect or sign in, otherwise the remote
    # one; $null when ssh could not be run or was stopped), Lines (standard output, CLIXML records
    # dropped, as before), Errors (standard error through ConvertFrom-RemoteErrorText: ssh's own
    # reason, or the remote error) and TimedOut. With -TimeoutSec, ssh is stopped after that long.
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("`$ProgressPreference='SilentlyContinue';" + $ScriptText))
    $res = [pscustomobject]@{ ExitCode = $null; Lines = @(); Errors = @(); TimedOut = $false }
    $p = $null
    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new('ssh')
        foreach ($x in (Get-SshBaseArgs)) { $psi.ArgumentList.Add($x) }
        $psi.ArgumentList.Add((Get-SshTarget $Conn))
        $psi.ArgumentList.Add("powershell -NoProfile -EncodedCommand $enc")
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
        $p = [System.Diagnostics.Process]::Start($psi)
        $outTask = $p.StandardOutput.ReadToEndAsync(); $errTask = $p.StandardError.ReadToEndAsync()
        try { $p.StandardInput.Close() } catch { }
        if ($TimeoutSec -gt 0) {
            if (-not $p.WaitForExit($TimeoutSec * 1000)) { $res.TimedOut = $true; try { $p.Kill($true) } catch { }; try { $null = $p.WaitForExit(5000) } catch { } }
        } else { $p.WaitForExit() }
        $outText = ''; $errText = ''
        try { if ($outTask.Wait(10000)) { $outText = [string]$outTask.Result } } catch { }
        try { if ($errTask.Wait(10000)) { $errText = [string]$errTask.Result } } catch { }
        if (-not $res.TimedOut) { $res.ExitCode = $p.ExitCode }
        # the lines as PowerShell would have captured them: no empty line for the last line break
        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($l in ($outText -split '\r\n|\r|\n')) { $lines.Add($l) }
        if ($lines.Count -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }
        $res.Lines = @($lines | Where-Object { $_ -notmatch '^#< CLIXML|^<Objs ' })
        $errs = @(ConvertFrom-RemoteErrorText $errText)
        if ($res.TimedOut) { $errs = @("no answer within $TimeoutSec seconds") + $errs }
        $res.Errors = $errs
    } catch {
        $res.Errors = @('ssh could not be run: ' + ([string]$_.Exception.Message -replace '\s+', ' ').Trim())
    } finally { if ($p) { try { $p.Dispose() } catch { } } }
    return $res }
function Get-SshHint { param([string]$Reason, [string]$User, [string]$HostName, [string]$KeyFile)
    # A short hint for an SSH failure, chosen from ssh's own reason; '' when none fits. Used by
    # every report of an SSH failure: the first SSH step, the sign-in check before the prompts and
    # -Mode Discover. $KeyFile: the -SshKey of the run, if any.
    $r = [string]$Reason
    $u = if ($User) { $User } else { 'administrator' }
    $k = if ([string]$KeyFile -match '\s') { "'$KeyFile'" } else { [string]$KeyFile }
    # user@host for the test command, in single quotes when a shell would change it: zsh and bash
    # drop the backslash of a domain account (EXAMPLE\admin) that is not quoted
    $t = "$u@$HostName"
    if ($t -match '[\\\s''"]') { $t = "'" + ($t -replace "'", "'\''") + "'" }
    if ($r -match 'Too many authentication failures') {
        if ($KeyFile) { return 'too many keys were offered before the one named with -SshKey: set IdentitiesOnly yes for these hosts in the SSH settings file (Getting Started 4.7).' }
        return 'too many keys were offered: name the key with -SshKey, or set IdentitiesOnly for these hosts.' }
    if ($r -match 'Host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED') {
        return "the connector's host key changed: remove the old one with ssh-keygen -R $HostName and check the new one (Getting Started 4.6)." }
    if ($r -match 'Permission denied') {
        if ($KeyFile) { return "the key $k was not accepted: check that its public key is authorised on the connector (Getting Started 4.4); test by hand with ssh -i $k $t hostname." }
        return "the key was not accepted: name it with -SshKey <file>, or add an IdentityFile line for these hosts to the SSH settings file (Getting Started 4.7); test by hand with ssh $t hostname." }
    if ($r -match 'Could not resolve hostname') { return 'the name does not resolve from this machine.' }
    if ($r -match 'Connection timed out|Operation timed out|Connection refused|No route to host') {
        $port = if ($r -match '\bport (\d+)\b') { $Matches[1] } else { '22' }
        return "port $port is not reachable from this machine (firewall, or OpenSSH Server not running)." }
    return '' }
function Add-SshHint { param([string]$Message, [string]$Hint)
    # '<message>. Hint: <hint>', or the message alone when there is no hint
    if (-not $Hint) { return $Message }
    $m = $Message.TrimEnd()
    return $m + $(if ($m -match '[.!?]$') { '' } else { '.' }) + ' Hint: ' + $Hint }
function Get-SshStepError { param($Conn, $Result, [string]$What, [string]$KeyFile)
    # One line, masked, for an Invoke-SshPs step that did not work, told apart by what came back
    # on standard output:
    # - nothing, and ssh could not be run, ended with exit code 255 or ran out of time: ssh did not
    #   connect or sign in. 'cannot reach <host> over SSH: <ssh's own reason>', with a hint when
    #   the reason suggests one.
    # - the step's own success line ('ok', 'signin-ok'), but ssh still failed (the session dropped
    #   after the script had finished, say): 'signed in to <host> over SSH and the step answered,
    #   but ssh then ended with exit code <n>: <reason>', or '... but the session did not end
    #   within <n> seconds'.
    # - anything else: ssh signed in and the script failed. 'signed in to <host> over SSH, but
    #   could not <What>: <the remote error>'.
    $h = [string]$Conn.Host
    $marks = @('ok', 'signin-ok')
    $lines = @(@($Result.Lines) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    # each line once (a script that fails the same way for each of several folders repeats itself)
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $out = @($lines | Where-Object { $_ -notin $marks -and $seen.Add($_) })
    $errs = @(@($Result.Errors) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -and $seen.Add($_) })
    $answered = @($lines | Where-Object { $_ -in $marks }).Count -gt 0
    $notRun = ($null -eq $Result.ExitCode) -and (-not $Result.TimedOut)
    if ($notRun -or ((($Result.TimedOut) -or ($Result.ExitCode -eq 255)) -and ($lines.Count -eq 0))) {
        $why = $errs -join ' / '
        if (-not $why) { $why = $(if ($null -ne $Result.ExitCode) { "ssh ended with exit code $($Result.ExitCode) and gave no reason" } else { 'ssh gave no reason' }) }
        if ($why.Length -gt 500) { $why = $why.Substring(0, 500) + ' ...' }
        $msg = Add-SshHint "cannot reach $h over SSH: $why" (Get-SshHint -Reason $why -User ([string]$Conn.SshUser) -HostName $h -KeyFile $KeyFile)
    } elseif ($answered) {
        # Invoke-SshPs puts 'no answer within <n> seconds' first after a timeout: not so here
        $limit = ''
        $rest = @(foreach ($e in @($errs + $out)) { if ($e -match '^no answer within (\d+) seconds$') { $limit = $Matches[1] } else { $e } })
        $why = $rest -join ' / '
        if ($why.Length -gt 500) { $why = $why.Substring(0, 500) + ' ...' }
        if ($Result.TimedOut) {
            $msg = "signed in to $h over SSH and the step answered, but the session did not end " + $(if ($limit) { "within $limit seconds" } else { 'in the time allowed' }) + $(if ($why) { ": $why" } else { '' })
        } else {
            $msg = "signed in to $h over SSH and the step answered, but ssh then ended with exit code $($Result.ExitCode)" + $(if ($why) { ": $why" } else { ' and gave no reason' })
        }
    } else {
        $detail = @($errs + $out) -join ' / '
        if ($detail.Length -gt 500) { $detail = $detail.Substring(0, 500) + ' ...' }
        if (-not $detail) { $detail = "the connector did not confirm it (exit code $($Result.ExitCode))" }
        $msg = "signed in to $h over SSH, but could not ${What}: $detail"
    }
    return (Protect-Text $msg) }
function Test-SshSignInCheckNeeded { param([string]$Mode)
    # True for the modes that check the SSH sign-in on every selected connector right after the
    # plan, before YES and before any password or account is asked: the ones that go on to ask
    # (an upgrade or dry run over SSH, and the two repair modes). WinRM signs in its own way;
    # Stage and Verify ask nothing; Discover and -ImportFleet end before this point.
    return ($Mode -in 'SSH','RepairKeytab','RepairCertificate') }
function Test-WinRMSignInRefused { param($Failure)
    # True when a WinRM session (New-PSSession) could not be opened because the connector refused
    # the sign-in: access denied, a logon failure (a wrong user name or password), or an account
    # that is locked out, disabled or has an expired password. False when the connector was not
    # reached (name, network, firewall, WinRM not listening) and for anything else. $Failure is an
    # ErrorRecord, an exception or a message.
    if ($null -eq $Failure) { return $false }
    $codes = @(5, 1326, 1327, 1330, 1331, 1907, 1909)
    $words = 'access is denied|access denied|logon failure|logon attempt failed|user name or password is incorrect|unknown user name or bad password|account is currently locked out|referenced account is currently locked|account is currently disabled|password has expired|password must be changed'
    $texts = [System.Collections.Generic.List[string]]::new()
    $ex = $null
    if ($Failure -is [System.Management.Automation.ErrorRecord]) {
        if ([string]$Failure.FullyQualifiedErrorId -match '^(AccessDenied|LogonFailure)\b') { return $true }
        if ($Failure.ErrorDetails -and $Failure.ErrorDetails.Message) { $texts.Add([string]$Failure.ErrorDetails.Message) }
        $ex = $Failure.Exception
    }
    elseif ($Failure -is [System.Exception]) { $ex = $Failure }
    else { $texts.Add([string]$Failure) }
    for ($i = 0; $ex -and $i -lt 10; $i++) {
        if ($ex -is [System.Management.Automation.Remoting.PSRemotingTransportException] -and ([int]$ex.ErrorCode -in $codes)) { return $true }
        $texts.Add([string]$ex.Message)
        $ex = $ex.InnerException
    }
    foreach ($t in $texts) { if ($t -match $words) { return $true } }
    return $false }
function Get-WinRMSignInReason { param($Failure)
    # The connector's own reason in a failed New-PSSession, without the remoting boilerplate.
    $m = ''
    if ($Failure -is [System.Management.Automation.ErrorRecord]) { $m = $(if ($Failure.ErrorDetails -and $Failure.ErrorDetails.Message) { [string]$Failure.ErrorDetails.Message } else { [string]$Failure.Exception.Message }) }
    elseif ($Failure -is [System.Exception]) { $m = [string]$Failure.Message }
    else { $m = [string]$Failure }
    $m = ($m -replace '\s+', ' ').Trim()
    $m = $m -replace '^\[[^\]]+\]\s*', ''
    $m = $m -replace '^Connecting to remote server \S+ failed with the following error message ?: ?', ''
    $m = $m -replace '\s*For more information, see the about_Remote_Troubleshooting Help topic\.?$', ''
    return $m.Trim() }
function Copy-ScpTo { param($Conn, [string[]]$LocalFiles, [string]$RemoteDir)
    $dest = (Get-SshTarget $Conn) + ':' + ($RemoteDir -replace '\\', '/') + '/'
    & scp -q @(Get-SshBaseArgs) @LocalFiles $dest 2>$null
    if ($LASTEXITCODE -ne 0) { throw "scp to $($Conn.Host):$RemoteDir failed (exit $LASTEXITCODE)" } }
function Copy-ScpFrom { param($Conn, [string]$RemoteDir, [string]$LocalDir)
    $src = (Get-SshTarget $Conn) + ':' + ($RemoteDir -replace '\\', '/')
    & scp -q -r @(Get-SshBaseArgs) $src $LocalDir 2>$null
    return ($LASTEXITCODE -eq 0) }
function Invoke-SshRunner { param($Conn, [string]$RunnerArgs, [string[]]$StdinLines)
    # Runs the helper on the connector, feeding secrets on stdin, echoing output.
    $psi = [System.Diagnostics.ProcessStartInfo]::new('ssh')
    foreach ($x in (Get-SshBaseArgs)) { $psi.ArgumentList.Add($x) }
    $psi.ArgumentList.Add((Get-SshTarget $Conn))
    $psi.ArgumentList.Add("powershell -NoProfile -ExecutionPolicy Bypass -File $RemoteStageDir\Invoke-ConnectorUpgradeLocal.ps1 $RunnerArgs 2>&1")
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
    $p = [System.Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    foreach ($l in $StdinLines) { $p.StandardInput.WriteLine($l) }
    $p.StandardInput.Close()
    $json = $null
    while ($null -ne ($line = $p.StandardOutput.ReadLine())) {
        if ($line -match '^#< CLIXML|^<Objs ') { continue }
        if ($line.StartsWith('RESULT_JSON:')) { $json = $line.Substring(12); continue }
        Write-RemoteLine $line
    }
    $p.WaitForExit()
    Show-SshErrors -Task $errTask -HostName $Conn.Host
    $res = $null
    if ($json) { try { $res = $json | ConvertFrom-Json } catch { } }
    return [pscustomobject]@{ ExitCode = $p.ExitCode; Result = $res } }

# ------------------------------------------------------------ payload + jobs
function Get-Payload { param($T)
    # Local files for one tenant, grouped by remote sub-folder ('' = stage root).
    $root = $script:StagingRoot
    $p = [ordered]@{ '' = [System.Collections.Generic.List[string]]::new() }
    $p[''].Add((Join-Path $script:Here 'Invoke-ConnectorUpgradeLocal.ps1'))
    $p[''].Add((Join-Path $root $script:FleetData.InstallScript))
    $p[''].Add((Join-Path $root $T.ConfigFile))
    if ($T.Pfx) { $p[''].Add((Join-Path $root $T.Pfx)) }
    if ($T.TrustStore) {
        $p['TrustedCerts'] = [System.Collections.Generic.List[string]]::new()
        Get-ChildItem -LiteralPath (Join-Path $root $T.TrustStore) -File | Where-Object { $_.Extension -match '(?i)^\.(pem|cer|crt)$' } | ForEach-Object { $p['TrustedCerts'].Add($_.FullName) }
    }
    if (-not $SkipJavaPatch -and $script:FleetData.JavaPatchDir) {
        $p['Java4shellPatch'] = [System.Collections.Generic.List[string]]::new()
        Get-ChildItem -LiteralPath (Join-Path $root $script:FleetData.JavaPatchDir) -File | ForEach-Object { $p['Java4shellPatch'].Add($_.FullName) }
    }
    return $p }
function New-JobJson { param($T)
    $job = [ordered]@{
        Installer = (Split-Path $T.Installer -Leaf); InstallerVersion = $T.InstallerVersion
        ExpectVersionPrefix = $T.ExpectVersionPrefix
        ConfigFile = (Split-Path $T.ConfigFile -Leaf)
        TrustStore = $(if ($T.TrustStore) { 'TrustedCerts' } else { $null })
        Pfx = $(if ($T.Pfx) { Split-Path $T.Pfx -Leaf } else { $null })
        Services = @($T.Services -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        ServiceAccount = $T.ServiceAccount; Syslog = $T.Syslog
        ForceReinstall = [bool]($ForceReinstall -or $T.ForceReinstall)
        DryRun = [bool]$DryRun; ApplyJavaPatch = [bool](-not $SkipJavaPatch -and $script:FleetData.JavaPatchDir)
        SkipDomainCheck = [bool]$SkipDomainCheck
        # installer settings passed through to Install-AccessConnector.ps1 (null = installer default)
        InstallDir = $(if ($T.InstallDir) { ([string]$T.InstallDir).TrimEnd('\') } else { $null })
        EnableFips = [bool]$T.EnableFips
        DirectorySyncPort = $T.DirectorySyncPort; UserAuthPort = $T.UserAuthPort
        KerberosAuthPort = $T.KerberosAuthPort; VirtualAppPort = $T.VirtualAppPort
        ProxyHost = $T.ProxyHost; ProxyPort = $T.ProxyPort; ProxyUser = $T.ProxyUser; NonProxyHosts = $T.NonProxyHosts
    }
    $f = Join-Path ([IO.Path]::GetTempPath()) ("acjob_" + [guid]::NewGuid().ToString('N') + '.json')
    Set-Content -LiteralPath $f -Value ($job | ConvertTo-Json) -Encoding utf8
    return $f }
function Send-PayloadSsh { param($Conn, $T, [switch]$RunnerOnly, [string[]]$Also = @())
    # The folder holds scripts that run with high privilege, so only Administrators and SYSTEM may use it.
    # 'ok' only when the folders are there: New-Item failing (access denied, say) does not stop the script.
    $mk = "`$dirs='$RemoteStageDir','$RemoteStageDir\Logs','$RemoteStageDir\TrustedCerts','$RemoteStageDir\Java4shellPatch'; foreach(`$d in `$dirs){if(-not(Test-Path `$d)){`$null=New-Item -ItemType Directory -Path `$d -Force}}; if((Split-Path -Leaf '$RemoteStageDir') -eq 'AccessConnectorUpdate'){`$null = & icacls.exe '$RemoteStageDir' /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' /Q 2>&1}; `$miss=@(`$dirs | Where-Object { -not (Test-Path -LiteralPath `$_ -PathType Container) }); if(`$miss.Count){'not made: ' + (`$miss -join ', ')}else{'ok'}"
    $r = Invoke-SshPs $Conn $mk
    if ($r.ExitCode -ne 0 -or ($r.Lines -notcontains 'ok')) { throw (Get-SshStepError -Conn $Conn -Result $r -What "create $RemoteStageDir" -KeyFile $SshKey) }
    if ($RunnerOnly) { Copy-ScpTo $Conn (@((Join-Path $script:Here 'Invoke-ConnectorUpgradeLocal.ps1')) + @($Also)) $RemoteStageDir; return }
    $payload = Get-Payload $T
    foreach ($sub in $payload.Keys) {
        if ($payload[$sub].Count -eq 0) { continue }
        $dir = if ($sub) { "$RemoteStageDir\$sub" } else { $RemoteStageDir }
        Copy-ScpTo $Conn $payload[$sub].ToArray() $dir
    }
    # installer: large, so skip the copy when the same file is already there
    $inst = Join-Path $script:StagingRoot $T.Installer
    $leaf = Split-Path $inst -Leaf
    if (-not $script:HashCache.ContainsKey($inst)) { Say "Hashing $leaf..."; $script:HashCache[$inst] = (Get-FileHash -LiteralPath $inst -Algorithm SHA256).Hash }
    $want = $script:HashCache[$inst]
    $chk = "`$f='$RemoteStageDir\$leaf'; if(Test-Path `$f){(Get-FileHash `$f -Algorithm SHA256).Hash}else{'absent'}"
    $have = (Invoke-SshPs $Conn $chk).Lines | Select-Object -Last 1
    if ($have -eq $want) { Say "$leaf already staged on $($Conn.Host) (hash matches)." }
    else {
        Say "Copying $leaf to $($Conn.Host) ($([math]::Round((Get-Item -LiteralPath $inst).Length/1MB)) MB)..."
        Copy-ScpTo $Conn @($inst) $RemoteStageDir
        $have = (Invoke-SshPs $Conn $chk).Lines | Select-Object -Last 1
        if ($have -ne $want) { throw "installer hash mismatch on $($Conn.Host) after copy" }
    }
    $job = New-JobJson $T
    # The copy must be named job.json, so it goes in a folder of its own: two sessions staging at
    # the same moment would otherwise write the same file and one could send the other's job.
    $tmpDir = Join-Path (Split-Path $job -Parent) ('acjob_' + [guid]::NewGuid().ToString('N'))
    try {
        $null = New-Item -ItemType Directory -Path $tmpDir -Force
        $tmp = Join-Path $tmpDir 'job.json'; Copy-Item -LiteralPath $job -Destination $tmp -Force; Copy-ScpTo $Conn @($tmp) $RemoteStageDir
    }
    finally {
        Remove-Item -LiteralPath $job -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    # Started from a PowerShell 7 window the 5.1 child would inherit PowerShell 7's module path, so clear it.
    $cmd = "Set-Content -LiteralPath '$RemoteStageDir\Run-Upgrade.cmd' -Encoding ascii -Value '@echo off','setlocal','set ""PSModulePath=""','""%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"" -NoProfile -ExecutionPolicy Bypass -File ""%~dp0Invoke-ConnectorUpgradeLocal.ps1"" -Prompt %*','pause'; 'ok'"
    $r = Invoke-SshPs $Conn $cmd
    if ($r.ExitCode -ne 0 -or ($r.Lines -notcontains 'ok')) { throw "could not write Run-Upgrade.cmd on $($Conn.Host)" } }
function Format-State { param($S)
    if (-not $S) { return 'no state returned' }
    # All running: a count is enough. Otherwise name the ones that are not.
    $all = @($S.Services)
    $svc = "services {0}/{1} up" -f @($all | Where-Object { $_.Status -eq 'Running' }).Count, $all.Count
    $down = @($all | Where-Object { $_.Status -ne 'Running' } | ForEach-Object { ($_.Key -replace 'Service$','') + '=' + $_.Status })
    if ($down.Count) { $svc += ' (' + ($down -join ', ') + ')' }
    if ($all.Count -eq 0) { $svc = 'no connector services installed' }
    # A keytab with no keys in it is a few bytes long; a usable one is a few hundred.
    $kt = if ([int]$S.KeytabBytes -ge 32) { 'ok' } elseif ([int]$S.KeytabBytes -ge 0) { "EMPTY ($($S.KeytabBytes) bytes)" } else { 'none' }
    $line = "v{0} | {1} | java flag {2}/{3}" -f $S.InstalledVersion, $svc, $S.JavaWithFlag, $S.JavaCount
    # keytab and certificate matter only where the Kerberos service is installed
    if (-not @($all | Where-Object { $_.Key -eq 'KerberosAuthService' }).Count) { return $line }
    return ($line + "`n" + "keytab $kt | certificate " + (Format-Cert $S.Cert)) }
function Test-CertBad { param($C)
    # True when the Kerberos service serves a certificate that is not a proper one for it.
    return ($C -and ((-not $C.Ok) -or $C.Installer -or (-not $C.NamesServer) -or ($C.NotAfter -and ([string]$C.NotAfter -lt (Get-Date -Format 'yyyy-MM-dd'))))) }
function Format-Cert { param($C)
    if (-not $C) { return 'not checked (service not running, or an older helper)' }
    if (-not $C.Ok) { return "NOT READABLE ($($C.Message))" }
    if ($C.Installer) { return "SELF-SIGNED by the installer ('$($C.Subject)')" }
    if (-not $C.NamesServer) { return "DOES NOT NAME THIS SERVER ('$($C.Subject)' from '$($C.Issuer)')" }
    if ($C.NotAfter -and ([string]$C.NotAfter -lt (Get-Date -Format 'yyyy-MM-dd'))) { return "EXPIRED $($C.NotAfter) ('$($C.Subject)')" }
    return "ok ('$($C.Subject)' from '$($C.Issuer)', to $($C.NotAfter))" }
function Get-VerifyVerdict { param($State, [bool]$HasPfx)
    # -Mode Verify: the colour of a connector's line, and what makes it red. Red (Level ERROR) when
    # a service is not running, when Kerberos Auth is installed and its keytab is empty or missing,
    # or, for a group with a Pfx, when the certificate served is not a proper one. Yellow (WARN)
    # when nothing is installed or a Java process lacks the patch flag. Green (OK) otherwise.
    # A red line makes the run's exit code 1; Red names each red item.
    $svcs = @($State.Services)
    $red = [System.Collections.Generic.List[string]]::new()
    $down = @($svcs | Where-Object { $_.Status -ne 'Running' } | ForEach-Object { ($_.Key -replace 'Service$', '') + '=' + $_.Status })
    if ($down.Count) { $red.Add('not running: ' + ($down -join ', ')) }
    if (@($svcs | Where-Object { $_.Key -eq 'KerberosAuthService' }).Count -and [int]$State.KeytabBytes -lt 32) {
        $red.Add($(if ([int]$State.KeytabBytes -ge 0) { "keytab EMPTY ($($State.KeytabBytes) bytes)" } else { 'keytab missing' })) }
    # with no Pfx the installer's own certificate is what is meant to be there
    if ($HasPfx -and (Test-CertBad $State.Cert)) { $red.Add('certificate ' + (Format-Cert $State.Cert)) }
    $level = if ($red.Count) { 'ERROR' } elseif ($svcs.Count -eq 0 -or [int]$State.JavaWithFlag -lt [int]$State.JavaCount) { 'WARN' } else { 'OK' }
    return [pscustomobject]@{ Level = $level; Red = @($red) } }

$script:TenantKeys = @('Name','Installer','InstallerVersion','ExpectVersionPrefix','ConfigFile','TrustStore','Pfx','Services',
    'ServiceAccount','Syslog','ForceReinstall','Connectors','InstallDir','EnableFips','DirectorySyncPort','UserAuthPort',
    'KerberosAuthPort','VirtualAppPort','ProxyHost','ProxyPort','ProxyUser','NonProxyHosts')
function Get-TenantOptionProblems { param($T)
    # What is wrong with the installer settings of one fleet entry. Nothing is contacted.
    $p = [System.Collections.Generic.List[string]]::new(); $n = $T.Name
    $seen = @{}
    foreach ($k in 'DirectorySyncPort','UserAuthPort','KerberosAuthPort','VirtualAppPort','ProxyPort') {
        if ($null -eq $T[$k] -or [string]$T[$k] -eq '') { continue }
        $v = 0
        if (-not [int]::TryParse([string]$T[$k], [ref]$v) -or $v -lt 1 -or $v -gt 65535) { $p.Add("${n} ${k}: '$($T[$k])' is not a port number (1 to 65535)"); continue }
        if ($k -ne 'ProxyPort') { if ($seen.ContainsKey($v)) { $p.Add("${n} ${k}: port $v is already used by $($seen[$v])") } else { $seen[$v] = $k } }
    }
    if ($null -ne $T.EnableFips -and $T.EnableFips -isnot [bool]) { $p.Add("${n} EnableFips: use `$true or `$false") }
    if ($T.InstallDir -and (([string]$T.InstallDir -notmatch '^[A-Za-z]:\\') -or ([string]$T.InstallDir -match '["%]'))) {
        $p.Add("${n} InstallDir: '$($T.InstallDir)' is not a full Windows path such as 'D:\Program Files' (the connector goes in its Access Connector folder)") }
    foreach ($k in 'ProxyHost','ProxyUser','NonProxyHosts') { if ($T[$k] -and ([string]$T[$k] -match '[\s"]')) { $p.Add("${n} ${k}: spaces and double quotes are not allowed") } }
    if (-not $T.ProxyHost) { foreach ($k in 'ProxyPort','ProxyUser','NonProxyHosts') { if ($T[$k]) { $p.Add("${n} $k is set but ProxyHost is not") } } }
    return ,$p }
function Format-TenantOptions { param($T)
    # The installer settings of one fleet entry, in one line; '' when it uses the installer defaults.
    $parts = @()
    if ($T.InstallDir) { $parts += "install folder $(([string]$T.InstallDir).TrimEnd('\'))\Access Connector" }
    if ($T.EnableFips) { $parts += 'FIPS mode' }
    $ports = @(foreach ($k in @(@('DirectorySyncPort','DS'),@('UserAuthPort','UA'),@('KerberosAuthPort','KA'),@('VirtualAppPort','VA'))) { if ($T[$k[0]]) { "$($k[1])=$($T[$k[0]])" } })
    if ($ports.Count) { $parts += 'ports ' + ($ports -join ' ') }
    if ($T.ProxyHost) {
        $px = 'proxy ' + $T.ProxyHost + $(if ($T.ProxyPort) { ":$($T.ProxyPort)" } else { '' })
        $more = @(); if ($T.ProxyUser) { $more += "user $($T.ProxyUser)" }; if ($T.NonProxyHosts) { $more += "direct to $($T.NonProxyHosts)" }
        if ($more.Count) { $px += ' (' + ($more -join '; ') + ')' }
        $parts += $px
    }
    return ($parts -join ', ') }

function Get-StagingGaps { param([string]$Root, $T)
    # The files tenant $T needs that are not under $Root.
    $gaps = [System.Collections.Generic.List[string]]::new()
    foreach ($k in 'Installer','ConfigFile','TrustStore','Pfx') {
        if ($T[$k] -and -not (Test-Path -LiteralPath (Join-Path $Root $T[$k]))) { $gaps.Add("$($T.Name) ${k}: $($T[$k])") }
    }
    return $gaps
}
function Find-StagedCopy { param($T)
    # Another copy of the staging folder (on another share, say) that holds everything tenant $T
    # needs, or nothing. Tried on every mounted volume (macOS) or drive (Windows): this folder's
    # own path, and each path listed under StagingFolders in the fleet file. Entries there that
    # are full paths are tried as they are. Reads only; never slow enough to matter on the
    # error path it serves.
    $trim = [char[]]'/\'
    $here = [string]$script:StagingRoot
    try { $here = (Resolve-Path -LiteralPath $script:StagingRoot -ErrorAction Stop).ProviderPath } catch { }
    $here = $here.TrimEnd($trim)
    $roots = @()
    try {
        if ($IsMacOS) { $roots = @(Get-ChildItem -LiteralPath '/Volumes' -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) }
        elseif ($IsWindows) { $roots = @([IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady } | ForEach-Object { $_.RootDirectory.FullName }) }
    } catch { }
    $rel = [System.Collections.Generic.List[string]]::new(); $cands = [System.Collections.Generic.List[string]]::new()
    foreach ($v in $roots) {
        $vv = $v.TrimEnd($trim) + [IO.Path]::DirectorySeparatorChar
        if ($here.Length -gt $vv.Length -and $here.StartsWith($vv, [StringComparison]::OrdinalIgnoreCase)) { $rel.Add($here.Substring($vv.Length)); break }
    }
    foreach ($e in @($script:FleetData.StagingFolders)) {
        $e = ([string]$e).Trim(); if (-not $e) { continue }
        if ([IO.Path]::IsPathRooted($e) -or $e -match '^\\\\') { $cands.Add($e) } elseif (-not $rel.Contains($e)) { $rel.Add($e) }
    }
    foreach ($v in $roots) { foreach ($r in $rel) { $cands.Add((Join-Path $v $r)) } }
    foreach ($c in $cands) {
        try {
            if (-not (Test-Path -LiteralPath $c -PathType Container)) { continue }
            $full = (Resolve-Path -LiteralPath $c -ErrorAction Stop).ProviderPath.TrimEnd($trim)
            if ($full -eq $here) { continue }
            if (@(Get-StagingGaps -Root $full -T $T).Count) { continue }
            if (-not $script:FleetData.InstallScript -or -not (Test-Path -LiteralPath (Join-Path $full $script:FleetData.InstallScript))) { continue }
            if (-not $SkipJavaPatch -and $script:FleetData.JavaPatchDir -and -not (Test-Path -LiteralPath (Join-Path $full $script:FleetData.JavaPatchDir 'Java4shellPatch.bat'))) { continue }
            return $full
        } catch { }
    }
    return $null
}

# ------------------------------------------------- spreadsheet import, discovery
# Reading and checking a spreadsheet, and writing the fleet file (-ImportFleet)
# ------------------------------------------------------------ spreadsheet import (-ImportFleet)
# Admin side only (PowerShell 7). Reads a sheet of connectors (.csv, .txt, .tsv or .xlsx), checks it
# by the import rules, turns it into fleet entries, writes the fleet file text and checks what the
# written file reads back as. Nothing here contacts a connector, prints, or stops the run: every
# problem and warning is returned to the caller. The cell values of a column whose header looks
# like a password are never kept, compared, returned or shown.
#
# Use by -ImportFleet:
#   $tbl  = Read-FleetTable -Path $file                             # its Problems/Warnings first
#   $conv = ConvertFrom-FleetRows -Table $tbl -StagingRoot $root    # then these (its own only)
#   any problem: stop, nothing is written
#   $text = ConvertTo-FleetFileText -Tenants $conv.Tenants -TopLevel $top -Source <file name> -Generator <script version> -Stamp <date>
#   write $text as UTF-8 without a BOM (it already has CRLF line ends)
#   $diff = @(Compare-FleetData -Tenants $conv.Tenants -TopLevel $top -Actual (Import-PowerShellDataFile -LiteralPath $target))
# $top is the existing fleet file's top-level settings, or $null for a new file.

$script:FleetColumns = @('Group','Host','SshUser','Installer','InstallerVersion','ExpectVersionPrefix','ConfigFile',
    'Services','ServiceAccount','Pfx','TrustStore','Syslog','ForceReinstall','InstallDir','EnableFips',
    'DirectorySyncPort','UserAuthPort','KerberosAuthPort','VirtualAppPort','ProxyHost','ProxyPort','ProxyUser',
    'NonProxyHosts','Notes')

function Get-FleetImportColumnLetter { param([int]$Number)
    # How a spreadsheet names column $Number: 1 is A, 27 is AA.
    $s = ''; $n = $Number
    while ($n -gt 0) { $m = [int](($n - 1) % 26); $s = [string][char](65 + $m) + $s; $n = [int][math]::Floor(($n - 1) / 26) }
    return $s }

function Get-FleetImportDistance { param([string]$A, [string]$B)
    # Edit distance between two header names, to suggest the column a misspelling was meant to be.
    $prev = [int[]](0..$B.Length)
    for ($i = 1; $i -le $A.Length; $i++) {
        $cur = [int[]]::new($B.Length + 1); $cur[0] = $i
        for ($j = 1; $j -le $B.Length; $j++) {
            $cost = 1; if ($A[$i - 1] -ceq $B[$j - 1]) { $cost = 0 }
            $cur[$j] = [math]::Min([math]::Min($prev[$j] + 1, $cur[$j - 1] + 1), $prev[$j - 1] + $cost)
        }
        $prev = $cur
    }
    return $prev[$B.Length] }

function Get-FleetImportHeaderKey { param([string]$Header)
    # What one header cell means. Kind: Column (Name = canonical column), Ignored (Notes, or a header
    # that starts with #), Password, Empty or Unknown (Hint = the column it was probably meant to be).
    # Case, spaces, underscores, hyphens and dots do not matter.
    $t = ([string]$Header).Replace([string][char]0xFEFF, '').Trim()
    $k = ($t -replace '[\s_.\-]', '').ToLowerInvariant()
    if (-not $t) { return [pscustomobject]@{ Kind = 'Empty'; Name = $null; Hint = $null } }
    # before anything else, so even an ignored '# password' column is refused
    if ($k -match 'pass|pwd|secret|token|credential') { return [pscustomobject]@{ Kind = 'Password'; Name = $null; Hint = $null } }
    if ($t.StartsWith('#')) { return [pscustomobject]@{ Kind = 'Ignored'; Name = $null; Hint = $null } }
    $known = [ordered]@{}
    foreach ($c in $script:FleetColumns) { $known[$c.ToLowerInvariant()] = $c }
    $known['name'] = 'Group'; $known['tenant'] = 'Group'; $known['connector'] = 'Host'; $known['server'] = 'Host'
    if ($known.Contains($k)) {
        if ($known[$k] -eq 'Notes') { return [pscustomobject]@{ Kind = 'Ignored'; Name = 'Notes'; Hint = $null } }
        return [pscustomobject]@{ Kind = 'Column'; Name = $known[$k]; Hint = $null } }
    $best = $null; $bestD = 3
    foreach ($c in $known.Keys) { $d = Get-FleetImportDistance $k $c; if ($d -lt $bestD) { $best = $known[$c]; $bestD = $d } }
    if (-not $best) {
        $long = 0
        foreach ($c in $known.Keys) { if ($c.Length -ge 4 -and $k.Contains($c) -and $c.Length -gt $long) { $best = $known[$c]; $long = $c.Length } }
    }
    return [pscustomobject]@{ Kind = 'Unknown'; Name = $null; Hint = $best } }

function Read-FleetImportBytes { param([string]$Path)
    # The whole file, read even while Excel has it open (Excel keeps it open for writing).
    $share = [IO.FileShare]([int][IO.FileShare]::ReadWrite -bor [int][IO.FileShare]::Delete)
    $fs = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    try { $ms = [IO.MemoryStream]::new(); $fs.CopyTo($ms); return ,$ms.ToArray() } finally { $fs.Dispose() } }

function ConvertFrom-FleetImportBytes { param([byte[]]$Bytes)
    # Text of a delimited file. A byte-order mark decides (UTF-8, UTF-16LE, UTF-16BE); without one,
    # UTF-16 is recognised by its zero bytes, else UTF-8, else Windows-1252 when the bytes are not
    # valid UTF-8 (Excel 'CSV (Comma delimited)' writes the Windows code page).
    $n = $Bytes.Length
    $utf8 = [Text.UTF8Encoding]::new($false)
    if ($n -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        $t = $utf8.GetString($Bytes, 3, $n - 3); return [pscustomobject]@{ Encoding = 'UTF-8 with BOM'; Text = $t } }
    if ($n -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        $t = [Text.Encoding]::Unicode.GetString($Bytes, 2, $n - 2); return [pscustomobject]@{ Encoding = 'UTF-16LE'; Text = $t } }
    if ($n -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) {
        $t = [Text.Encoding]::BigEndianUnicode.GetString($Bytes, 2, $n - 2); return [pscustomobject]@{ Encoding = 'UTF-16BE'; Text = $t } }
    if ($n -ge 4 -and $Bytes[0] -ne 0 -and $Bytes[1] -eq 0 -and $Bytes[2] -ne 0 -and $Bytes[3] -eq 0) {
        $t = [Text.Encoding]::Unicode.GetString($Bytes); return [pscustomobject]@{ Encoding = 'UTF-16LE (no BOM)'; Text = $t } }
    if ($n -ge 4 -and $Bytes[0] -eq 0 -and $Bytes[1] -ne 0 -and $Bytes[2] -eq 0 -and $Bytes[3] -ne 0) {
        $t = [Text.Encoding]::BigEndianUnicode.GetString($Bytes); return [pscustomobject]@{ Encoding = 'UTF-16BE (no BOM)'; Text = $t } }
    try { $t = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes); return [pscustomobject]@{ Encoding = 'UTF-8'; Text = $t } } catch { }
    $enc = $null
    try { $enc = [Text.Encoding]::GetEncoding(1252) } catch { $enc = [Text.Encoding]::Latin1 }
    $t = $enc.GetString($Bytes)
    return [pscustomobject]@{ Encoding = 'Windows-1252'; Text = $t } }

function Get-FleetImportDelimiter { param([string]$Text)
    # From the first line that holds anything (the header): tab when it has one, else the more
    # frequent of ';' and ',' outside quotes, comma on a tie.
    $tab = 0; $semi = 0; $comma = 0; $content = $false; $inQ = $false
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($ch -eq [char]'"') { $inQ = -not $inQ; $content = $true; continue }
        if ($inQ) { continue }
        if ($ch -eq [char]"`r" -or $ch -eq [char]"`n") {
            if ($content) { break }
            $tab = 0; $semi = 0; $comma = 0; continue }
        if ($ch -eq [char]"`t") { $tab++ }
        elseif ($ch -eq [char]';') { $semi++ }
        elseif ($ch -eq [char]',') { $comma++ }
        elseif (-not [char]::IsWhiteSpace($ch)) { $content = $true }
    }
    if ($tab) { return "`t" }
    if ($semi -gt $comma) { return ';' }
    return ',' }

function Split-FleetImportDelimited { param([string]$Text, [char]$Delimiter)
    # Records of delimited text: quoted cells, doubled quotes, delimiters and line breaks inside
    # quotes. A record ends at CRLF, LF or a lone CR. RowNumber counts records from 1, which is the
    # row number a spreadsheet shows (a cell holding a line break does not start a new row).
    $records = [System.Collections.Generic.List[object]]::new()
    $problems = [System.Collections.Generic.List[string]]::new()
    $cells = [System.Collections.Generic.List[string]]::new()
    $sb = [System.Text.StringBuilder]::new()
    $q = [char]'"'
    $specials = [char[]]@($Delimiter, $q, [char]"`r", [char]"`n")
    $row = 1; $inQ = $false; $quoted = $false; $qRow = 0
    $i = 0; $n = $Text.Length
    while ($i -lt $n) {
        if ($inQ) {
            $j = $Text.IndexOf($q, $i)
            if ($j -lt 0) { [void]$sb.Append($Text, $i, $n - $i); $i = $n; break }
            if ($j -gt $i) { [void]$sb.Append($Text, $i, $j - $i) }
            if ($j + 1 -lt $n -and $Text[$j + 1] -eq $q) { [void]$sb.Append($q); $i = $j + 2; continue }
            $inQ = $false; $i = $j + 1; continue
        }
        $j = $Text.IndexOfAny($specials, $i)
        if ($j -lt 0) { [void]$sb.Append($Text, $i, $n - $i); $i = $n; break }
        if ($j -gt $i) { [void]$sb.Append($Text, $i, $j - $i) }
        $ch = $Text[$j]
        if ($ch -eq $q) {
            # a quote opens a quoted cell only at its start (spaces before it are dropped)
            if (-not $quoted -and $sb.ToString().Trim().Length -eq 0) { [void]$sb.Clear(); $inQ = $true; $quoted = $true; $qRow = $row }
            else { [void]$sb.Append($q) }
            $i = $j + 1; continue
        }
        if ($ch -eq $Delimiter) { $cells.Add($sb.ToString()); [void]$sb.Clear(); $quoted = $false; $i = $j + 1; continue }
        $cells.Add($sb.ToString()); [void]$sb.Clear(); $quoted = $false
        $records.Add([pscustomobject]@{ RowNumber = $row; Cells = $cells.ToArray() }); $cells.Clear(); $row++
        if ($ch -eq [char]"`r" -and $j + 1 -lt $n -and $Text[$j + 1] -eq [char]"`n") { $i = $j + 2 } else { $i = $j + 1 }
    }
    if ($inQ) { $problems.Add("row ${qRow}: a quoted cell is not closed (a double quote is missing), so the rest of the file was read as one cell") }
    if ($sb.Length -gt 0 -or $cells.Count -gt 0 -or $quoted) {
        $cells.Add($sb.ToString())
        $records.Add([pscustomobject]@{ RowNumber = $row; Cells = $cells.ToArray() })
    }
    return [pscustomobject]@{ Records = $records.ToArray(); Problems = $problems.ToArray() } }

function Read-FleetImportZipXml { param($Entries, [string]$Name)
    # One XML part of a workbook, or $null when the workbook does not have it. No DTDs, nothing
    # fetched from outside, whitespace kept (a rich-text run may be just a space).
    $e = $Entries[$Name]
    if ($null -eq $e) { return $null }
    $set = [System.Xml.XmlReaderSettings]::new()
    $set.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $set.XmlResolver = $null
    $doc = [System.Xml.XmlDocument]::new(); $doc.PreserveWhitespace = $true; $doc.XmlResolver = $null
    $st = $e.Open()
    try { $rd = [System.Xml.XmlReader]::Create($st, $set); try { $doc.Load($rd) } finally { $rd.Dispose() } } finally { $st.Dispose() }
    return ,$doc }

function Get-FleetImportXlsxText { param($Node)
    # Text of a shared string (<si>) or an inline string (<is>): its own <t>, or the <t> of each
    # rich-text run (<r>). Phonetic guides (<rPh>) are left out; _xHHHH_ escapes are decoded.
    if ($null -eq $Node) { return '' }
    $sb = [System.Text.StringBuilder]::new()
    foreach ($ch in $Node.ChildNodes) {
        if ($ch.LocalName -eq 't') { [void]$sb.Append($ch.InnerText) }
        elseif ($ch.LocalName -eq 'r') { foreach ($rt in $ch.ChildNodes) { if ($rt.LocalName -eq 't') { [void]$sb.Append($rt.InnerText) } } }
    }
    return ($sb.ToString() -replace '_x([0-9A-Fa-f]{4})_', { [string][char][Convert]::ToInt32($_.Groups[1].Value, 16) }) }

function Read-FleetImportXlsx { param([byte[]]$Bytes)
    # Cells of the FIRST worksheet in workbook order (workbook.xml and its relationships, not the
    # part's file name), as records (RowNumber = the real row index; Cells: column A first). Cells
    # are placed by their r reference. Shared strings (plain and rich text), inline strings, cached
    # formula text (t="str"), booleans (TRUE/FALSE) and numbers (invariant culture, at most 15
    # significant digits as Excel shows them, whole numbers without .0). A cell merged down one
    # column gives its value to every row of the merge. Error cells (#REF! ...) are listed.
    $problems = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $records = [System.Collections.Generic.List[object]]::new()
    $errorCells = [System.Collections.Generic.List[object]]::new()
    $sheetName = $null; $sheetCount = 0
    $ms = [IO.MemoryStream]::new($Bytes)
    $zip = $null
    try { $zip = [IO.Compression.ZipArchive]::new($ms, [IO.Compression.ZipArchiveMode]::Read) }
    catch {
        $problems.Add('it is not a readable .xlsx workbook (an older .xls renamed, or a workbook saved with a password?); save it as .xlsx without a password, or as .csv')
        return [pscustomobject]@{ Records = $records.ToArray(); ErrorCells = $errorCells.ToArray(); Problems = $problems.ToArray(); Warnings = $warnings.ToArray(); Sheet = $sheetName; SheetCount = $sheetCount } }
    try {
        $entries = @{}
        foreach ($en in $zip.Entries) { $entries[$en.FullName.Replace('\', '/').TrimStart('/')] = $en }
        $resolve = { param([string]$Dir, [string]$Target)
            # a relationship target as a part name inside the package
            $tg = ([string]$Target).Replace('\', '/')
            if ($tg.StartsWith('/')) { return $tg.TrimStart('/') }
            $parts = [System.Collections.Generic.List[string]]::new()
            $whole = if ($Dir) { $Dir + '/' + $tg } else { $tg }
            foreach ($seg in ($whole -split '/')) {
                if ($seg -eq '..') { if ($parts.Count) { $parts.RemoveAt($parts.Count - 1) } }
                elseif ($seg -and $seg -ne '.') { $parts.Add($seg) }
            }
            return ($parts -join '/') }
        $relsOf = { param([string]$Part)
            # Id -> Type and Target of the relationships of one part ('' = the package itself)
            $dir = ''; $file = $Part
            $cut = $Part.LastIndexOf('/')
            if ($cut -ge 0) { $dir = $Part.Substring(0, $cut); $file = $Part.Substring($cut + 1) }
            $relPath = if ($dir) { $dir + '/_rels/' + $file + '.rels' } else { '_rels/' + $file + '.rels' }
            $map = @{}
            $x = Read-FleetImportZipXml $entries $relPath
            if ($null -ne $x) {
                foreach ($node in $x.DocumentElement.ChildNodes) {
                    if ($node.LocalName -ne 'Relationship') { continue }
                    $map[$node.GetAttribute('Id')] = [pscustomobject]@{ Type = $node.GetAttribute('Type'); Target = (& $resolve $dir $node.GetAttribute('Target')) }
                }
            }
            return $map }
        $wbPath = 'xl/workbook.xml'
        $root = & $relsOf ''
        foreach ($rel in $root.Values) { if ($rel.Type -like '*/officeDocument') { $wbPath = $rel.Target; break } }
        $wb = Read-FleetImportZipXml $entries $wbPath
        if ($null -eq $wb) { $problems.Add('it is not an .xlsx workbook (it has no workbook part); save it as .xlsx or .csv') }
        else {
            $wbRels = & $relsOf $wbPath
            $sheets = @($wb.SelectNodes("//*[local-name()='sheets']/*[local-name()='sheet']"))
            $sheetPath = $null; $hidden = [System.Collections.Generic.List[string]]::new()
            foreach ($sh in $sheets) {
                # the first sheet a user can see: a hidden one is passed over (and named)
                if ($sh.GetAttribute('state') -in 'hidden','veryHidden') { $hidden.Add($sh.GetAttribute('name')); continue }
                $id = $null
                foreach ($at in $sh.Attributes) { if ($at.LocalName -eq 'id' -and $at.NamespaceURI -like '*relationships*') { $id = $at.Value } }
                if ($id -and $wbRels.ContainsKey($id) -and $wbRels[$id].Type -like '*/worksheet') { $sheetPath = $wbRels[$id].Target; $sheetName = $sh.GetAttribute('name'); break }
            }
            $ws = $null
            if ($sheetPath) { $ws = Read-FleetImportZipXml $entries $sheetPath }
            $sheetCount = $sheets.Count
            if ($hidden.Count -and $sheetPath) { $warnings.Add("hidden sheet(s) before it passed over: " + (($hidden | ForEach-Object { "'$_'" }) -join ', ')) }
            if ($null -eq $ws) { $problems.Add('the workbook has no worksheet that could be read') }
            else {
                $sst = [System.Collections.Generic.List[string]]::new()
                $ssPath = $null
                foreach ($rel in $wbRels.Values) { if ($rel.Type -like '*/sharedStrings') { $ssPath = $rel.Target } }
                if (-not $ssPath -and $entries.ContainsKey('xl/sharedStrings.xml')) { $ssPath = 'xl/sharedStrings.xml' }
                if ($ssPath) {
                    $ss = Read-FleetImportZipXml $entries $ssPath
                    if ($null -ne $ss) { foreach ($si in $ss.DocumentElement.ChildNodes) { if ($si.LocalName -eq 'si') { $sst.Add((Get-FleetImportXlsxText $si)) } } }
                }
                $inv = [Globalization.CultureInfo]::InvariantCulture
                $byRow = [System.Collections.Generic.SortedDictionary[int, object]]::new()
                $rowNo = 0
                foreach ($rowNode in $ws.SelectNodes("//*[local-name()='sheetData']/*[local-name()='row']")) {
                    $rv = 0
                    if ([int]::TryParse($rowNode.GetAttribute('r'), [ref]$rv) -and $rv -gt 0) { $rowNo = $rv } else { $rowNo++ }
                    $cells = @{}
                    $col = 0
                    foreach ($c in $rowNode.ChildNodes) {
                        if ($c.LocalName -ne 'c') { continue }
                        $ref = $c.GetAttribute('r')
                        $mt = [regex]::Match($ref, '^([A-Za-z]{1,3})([0-9]+)$')
                        if ($mt.Success) { $col = 0; foreach ($lc in $mt.Groups[1].Value.ToUpperInvariant().ToCharArray()) { $col = $col * 26 + ([int]$lc - 64) } }
                        else { $col++ }
                        $type = $c.GetAttribute('t')
                        $vNode = $null; $isNode = $null
                        foreach ($kid in $c.ChildNodes) { if ($kid.LocalName -eq 'v') { $vNode = $kid } elseif ($kid.LocalName -eq 'is') { $isNode = $kid } }
                        $raw = $null; if ($null -ne $vNode) { $raw = $vNode.InnerText }
                        $text = ''
                        if ($type -eq 'inlineStr') { $text = Get-FleetImportXlsxText $isNode }
                        elseif ($null -eq $raw) { $text = '' }
                        elseif ($type -eq 's') {
                            $ix = -1
                            if ([int]::TryParse($raw, [ref]$ix) -and $ix -ge 0 -and $ix -lt $sst.Count) { $text = $sst[$ix] }
                            else { $problems.Add("cell $(Get-FleetImportColumnLetter $col)${rowNo} refers to a shared string the workbook does not hold") }
                        }
                        elseif ($type -eq 'b') { if ($raw -eq '1') { $text = 'TRUE' } elseif ($raw -eq '0') { $text = 'FALSE' } else { $text = $raw } }
                        elseif ($type -eq 'e') { $text = $raw; $errorCells.Add([pscustomobject]@{ Row = $rowNo; Column = $col; Text = $raw }) }
                        elseif ($type -eq 'str' -or $type -eq 'd') { $text = $raw -replace '_x([0-9A-Fa-f]{4})_', { [string][char][Convert]::ToInt32($_.Groups[1].Value, 16) } }
                        else {
                            $dv = 0.0
                            if ([double]::TryParse($raw, [Globalization.NumberStyles]::Float, $inv, [ref]$dv)) { $text = $dv.ToString('G15', $inv) } else { $text = $raw }
                        }
                        if ($text -ne '') { $cells[$col] = $text }
                    }
                    if ($cells.Count) { $byRow[$rowNo] = $cells }
                }
                # a cell merged down one column (a group name over several rows, say) fills each row
                $lastRow = 0; foreach ($k in $byRow.Keys) { $lastRow = $k }
                foreach ($mc in $ws.SelectNodes("//*[local-name()='mergeCells']/*[local-name()='mergeCell']")) {
                    $mm = [regex]::Match($mc.GetAttribute('ref'), '^([A-Za-z]{1,3})([0-9]+):([A-Za-z]{1,3})([0-9]+)$')
                    if (-not $mm.Success -or $mm.Groups[1].Value -ne $mm.Groups[3].Value) { continue }
                    $mcol = 0; foreach ($lc in $mm.Groups[1].Value.ToUpperInvariant().ToCharArray()) { $mcol = $mcol * 26 + ([int]$lc - 64) }
                    $r1 = [int]$mm.Groups[2].Value; $r2 = [math]::Min([int]$mm.Groups[4].Value, $lastRow)
                    if (-not $byRow.ContainsKey($r1) -or -not $byRow[$r1].ContainsKey($mcol)) { continue }
                    $mv = $byRow[$r1][$mcol]
                    for ($r = $r1 + 1; $r -le $r2; $r++) {
                        if (-not $byRow.ContainsKey($r)) { $byRow[$r] = @{} }
                        if (-not $byRow[$r].ContainsKey($mcol)) { $byRow[$r][$mcol] = $mv }
                    }
                }
                foreach ($rn in @($byRow.Keys)) {
                    $cells = $byRow[$rn]; $max = 0
                    foreach ($k in $cells.Keys) { if ($k -gt $max) { $max = $k } }
                    $arr = [string[]]::new($max)
                    for ($i = 0; $i -lt $max; $i++) { $arr[$i] = '' }
                    foreach ($k in $cells.Keys) { $arr[$k - 1] = [string]$cells[$k] }
                    $records.Add([pscustomobject]@{ RowNumber = [int]$rn; Cells = $arr })
                }
            }
        }
    } finally { if ($zip) { $zip.Dispose() }; $ms.Dispose() }
    return [pscustomobject]@{ Records = $records.ToArray(); ErrorCells = $errorCells.ToArray(); Problems = $problems.ToArray(); Warnings = $warnings.ToArray(); Sheet = $sheetName; SheetCount = $sheetCount } }

function ConvertFrom-FleetImportRecords { param($Records, $ErrorCells, $Problems)
    # Header (the first row that holds anything) and data rows -> canonical columns and, per row,
    # the trimmed value of each column that counts. Adds to the $Problems list it is given.
    $header = $null
    foreach ($rec in @($Records)) { if (@($rec.Cells | Where-Object { ([string]$_).Trim() }).Count) { $header = $rec; break } }
    if ($null -eq $header) {
        $Problems.Add('the sheet is empty: no header row was found')
        return [pscustomobject]@{ Columns = @(); Rows = @() } }
    $data = @($Records | Where-Object { $_.RowNumber -gt $header.RowNumber })
    $width = 0
    for ($i = $header.Cells.Count - 1; $i -ge 0; $i--) { if (([string]$header.Cells[$i]).Trim()) { $width = $i + 1; break } }
    foreach ($rec in $data) { for ($i = $rec.Cells.Count - 1; $i -ge $width; $i--) { if (([string]$rec.Cells[$i]).Trim()) { $width = $i + 1; break } } }
    $map = [object[]]::new($width)
    $where = @{}
    $unknown = 0
    for ($i = 0; $i -lt $width; $i++) {
        $letter = Get-FleetImportColumnLetter ($i + 1)
        $text = ''; if ($i -lt $header.Cells.Count) { $text = ([string]$header.Cells[$i]).Replace([string][char]0xFEFF, '').Trim() }
        $key = Get-FleetImportHeaderKey $text
        if ($key.Kind -eq 'Column') {
            if ($where.ContainsKey($key.Name)) { $Problems.Add("columns $($where[$key.Name]) and $letter are both $($key.Name): keep one of them") }
            else { $where[$key.Name] = $letter; $map[$i] = $key.Name }
        }
        elseif ($key.Kind -eq 'Password') {
            $Problems.Add("column $letter '$text': columns that hold passwords are refused; passwords are asked at run time. Delete the column and save the file again (its cells are not shown or kept)")
        }
        elseif ($key.Kind -eq 'Empty') {
            $hit = 0
            foreach ($rec in $data) { if ($i -lt $rec.Cells.Count -and ([string]$rec.Cells[$i]).Trim()) { $hit = $rec.RowNumber; break } }
            if ($hit) { $Problems.Add("column $letter has no header but holds values (first in row $hit): give it a header, or a header that starts with # to have it ignored") }
        }
        elseif ($key.Kind -eq 'Unknown') {
            $unknown++
            $hint = ''; if ($key.Hint) { $hint = " (did you mean $($key.Hint)?)" }
            $Problems.Add("column $letter '$text' is not a known column$hint; a header that starts with # is ignored")
        }
    }
    if ($unknown) {
        $list = @($script:FleetColumns | Where-Object { $_ -ne 'Notes' }) -join ', '
        $Problems.Add("known columns: $list (Group may also be headed Name or Tenant, Host Connector or Server); Notes and headers that start with # are ignored; case, spaces, dots, dashes and underscores in a header do not matter")
    }
    foreach ($req in 'Group','Host') {
        if (-not $where.ContainsKey($req)) {
            $alias = 'Connector or Server'; if ($req -eq 'Group') { $alias = 'Name or Tenant' }
            $Problems.Add("the header (row $($header.RowNumber)) has no $req column (it may also be headed $alias)")
        }
    }
    foreach ($ec in @($ErrorCells)) {
        if ($null -eq $ec -or $ec.Row -le $header.RowNumber -or $ec.Column -gt $width -or -not $map[$ec.Column - 1]) { continue }
        $Problems.Add("row $($ec.Row) $($map[$ec.Column - 1]): the cell holds the Excel error $($ec.Text); type the value in")
    }
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($rec in $data) {
        $vals = [ordered]@{}; $any = $false
        for ($i = 0; $i -lt $width; $i++) {
            if (-not $map[$i]) { continue }
            $t = ''; if ($i -lt $rec.Cells.Count) { $t = ([string]$rec.Cells[$i]).Trim() }
            # ="26.10": the formula-text trick that stops Excel turning a value into a number
            $fm = [regex]::Match($t, '^="(.*)"$', [System.Text.RegularExpressions.RegexOptions]::Singleline)
            if ($fm.Success) { $t = $fm.Groups[1].Value.Replace('""', '"').Trim() }
            $vals[$map[$i]] = $t
            if ($t) { $any = $true }
        }
        if ($any) { $rows.Add([pscustomobject]@{ RowNumber = [int]$rec.RowNumber; Values = $vals }) }
    }
    return [pscustomobject]@{ Columns = $map; Rows = $rows.ToArray() } }

function Read-FleetTable { param([string]$Path)
    # Reads a sheet of connectors: .csv, .txt or .tsv (delimiter and encoding detected) or .xlsx
    # (first worksheet). Returns Format ('csv' or 'xlsx'), Delimiter and Encoding (text files only),
    # Columns (canonical name per sheet column, $null where the column is ignored), Rows (RowNumber
    # = the spreadsheet row; Values = canonical column -> trimmed text; blank rows left out),
    # Problems and Warnings. Never throws for a bad file; never keeps a password column's cells.
    $problems = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $fmt = $null; $delim = $null; $enc = $null; $cols = @(); $rows = @(); $sheet = $null; $sheets = 0
    $leaf = ''; if ($Path) { $leaf = Split-Path -Leaf $Path }
    try {
        $full = $null
        if ($Path) { try { $full = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath } catch { $full = $null } }
        if (-not $full -or -not (Test-Path -LiteralPath $full -PathType Leaf)) { $problems.Add("'$Path' was not found") }
        else {
            $ext = [IO.Path]::GetExtension($full).ToLowerInvariant()
            if ($ext -eq '.xls') { $problems.Add("${leaf}: an old-format .xls workbook cannot be read; save it as .xlsx or .csv") }
            elseif ($ext -notin '.csv','.txt','.tsv','.xlsx') { $problems.Add("${leaf}: only .csv, .txt, .tsv and .xlsx files can be read; save it as .xlsx or .csv") }
            else {
                $bytes = Read-FleetImportBytes $full
                if ($bytes.Length -eq 0) { $problems.Add("${leaf} is empty") }
                elseif ($ext -eq '.xlsx') {
                    $fmt = 'xlsx'
                    $x = Read-FleetImportXlsx $bytes
                    $sheet = $x.Sheet; $sheets = $x.SheetCount
                    foreach ($p in $x.Problems) { $problems.Add($p) }
                    foreach ($w in $x.Warnings) { $warnings.Add($w) }
                    if ($x.Records.Count -or -not $x.Problems.Count) {
                        $t = ConvertFrom-FleetImportRecords -Records $x.Records -ErrorCells $x.ErrorCells -Problems $problems
                        $cols = $t.Columns; $rows = $t.Rows
                        # the rows may be on another sheet: say which one is read
                        if (-not @($rows).Count -and $x.SheetCount -gt 1) {
                            $problems.Add("only the first sheet of the workbook, '$($x.Sheet)', is read, and it holds no connector rows; the workbook has $($x.SheetCount) sheets: put the rows on the first one, or move their sheet to the front")
                        }
                    }
                }
                else {
                    $zipSig = $bytes.Length -ge 4 -and $bytes[0] -eq 0x50 -and $bytes[1] -eq 0x4B -and $bytes[2] -eq 3 -and $bytes[3] -eq 4
                    $oleSig = $bytes.Length -ge 4 -and $bytes[0] -eq 0xD0 -and $bytes[1] -eq 0xCF -and $bytes[2] -eq 0x11 -and $bytes[3] -eq 0xE0
                    if ($zipSig -or $oleSig) { $problems.Add("${leaf} is an Excel workbook, not text: give it the .xlsx extension, or save it as .csv") }
                    else {
                        $fmt = 'csv'
                        $dec = ConvertFrom-FleetImportBytes $bytes
                        $enc = $dec.Encoding; $text = [string]$dec.Text
                        if ($text.Length -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
                        # 'sep=;' on the first line: Excel's way of naming the delimiter (it hides that line)
                        $sep = [regex]::Match($text, '^sep=([^\r\n])[ \t]*(\r\n|\n|\r|$)')
                        if ($sep.Success) { $delim = $sep.Groups[1].Value; $text = $text.Substring($sep.Length) }
                        else { $delim = Get-FleetImportDelimiter $text }
                        $split = Split-FleetImportDelimited -Text $text -Delimiter ([char]$delim)
                        foreach ($p in $split.Problems) { $problems.Add($p) }
                        # Excel writes an error cell into a text file as its text (#N/A, #REF! ...)
                        $errCells = [System.Collections.Generic.List[object]]::new()
                        foreach ($rec in @($split.Records)) {
                            for ($ci = 0; $ci -lt @($rec.Cells).Count; $ci++) {
                                $ct = ([string]$rec.Cells[$ci]).Trim()
                                if ($ct -match '^#(N/A|REF!|VALUE!|DIV/0!|NAME\?|NUM!|NULL!|SPILL!|CALC!|GETTING_DATA|FIELD!|BLOCKED!|CONNECT!|BUSY!|UNKNOWN!)$') { $errCells.Add([pscustomobject]@{ Row = [int]$rec.RowNumber; Column = $ci + 1; Text = $ct }) }
                            }
                        }
                        $t = ConvertFrom-FleetImportRecords -Records $split.Records -ErrorCells $errCells.ToArray() -Problems $problems
                        $cols = $t.Columns; $rows = $t.Rows
                    }
                }
            }
        }
    } catch { $problems.Add("${leaf} could not be read: $($_.Exception.Message)") }
    return [pscustomobject]@{ Format = $fmt; Delimiter = $delim; Encoding = $enc; Columns = $cols; Rows = $rows; Sheet = $sheet; SheetCount = $sheets
        Problems = [string[]]$problems.ToArray(); Warnings = [string[]]$warnings.ToArray() } }

function ConvertFrom-FleetImportServices { param([string]$Text)
    # Service names from a Services cell, in canonical order without duplicates, and the words that
    # are not a service. Items split on , ; | or line breaks, and within an item on spaces; each name
    # with or without 'Service' or an 'Access' prefix, spaces, case, dots, dashes and underscores
    # ignored ('Directory Sync', 'directorysync', 'DirectorySyncService' are one service).
    $canon = @('DirectorySyncService','UserAuthService','KerberosAuthService','VirtualAppService')
    $map = @{}
    foreach ($c in $canon) { $b = ($c -replace 'Service$', '').ToLowerInvariant(); $map[$b] = $c; $map[$b + 'service'] = $c; $map['access' + $b + 'service'] = $c }
    $found = [System.Collections.Generic.HashSet[string]]::new()
    $unknown = [System.Collections.Generic.List[string]]::new()
    foreach ($piece in ([string]$Text -split '[,;|\r\n]+')) {
        $words = @($piece -split '\s+' | Where-Object { $_ })
        $run = [System.Collections.Generic.List[string]]::new()
        $i = 0
        while ($i -lt $words.Count) {
            $hit = $null; $used = 0
            for ($len = [math]::Min(4, $words.Count - $i); $len -ge 1; $len--) {
                $k = (($words[$i..($i + $len - 1)] -join '') -replace '[_.\-]', '').ToLowerInvariant()
                if ($map.ContainsKey($k)) { $hit = $map[$k]; $used = $len; break }
            }
            if ($hit) {
                if ($run.Count) { $unknown.Add($run -join ' '); $run.Clear() }
                [void]$found.Add($hit); $i += $used
            } else { $run.Add($words[$i]); $i++ }
        }
        if ($run.Count) { $unknown.Add($run -join ' ') }
    }
    return [pscustomobject]@{ Services = [string[]]@($canon | Where-Object { $found.Contains($_) }); Unknown = [string[]]$unknown.ToArray() } }

function ConvertFrom-FleetImportBool { param([string]$Text)
    # $true / $false from TRUE/FALSE, yes/no, y/n, 1/0 or $true/$false (any case); $null otherwise.
    $t = ([string]$Text).Trim()
    if ($t -match '^(true|yes|y|1|\$true)$') { return $true }
    if ($t -match '^(false|no|n|0|\$false)$') { return $false }
    return $null }

function ConvertFrom-FleetImportPath { param([string]$Text)
    # A path below the staging folder: / becomes \, a leading .\ goes. Value, or Problem (the words
    # that follow the quoted cell value in a message) when it is not relative.
    $p = ([string]$Text).Trim().Replace('/', '\')
    if ($p -match '^[A-Za-z]:' -or $p.StartsWith('\')) {
        return [pscustomobject]@{ Value = $null; Problem = 'is not relative to the staging folder; give the path below it, such as Installers\<file> (no drive letter, server or leading \)' } }
    while ($p.StartsWith('.\')) { $p = $p.Substring(2) }
    $p = ($p -replace '\\{2,}', '\').TrimEnd('\')
    if (-not $p) { return [pscustomobject]@{ Value = $null; Problem = 'names no file or folder' } }
    if ($p -match '["*?<>|]') { return [pscustomobject]@{ Value = $null; Problem = 'holds a character a Windows path cannot hold' } }
    return [pscustomobject]@{ Value = $p; Problem = $null } }

function Get-FleetImportVersionHint { param([string]$Prefix)
    # The hint for a version Excel may have turned into a number (26.10 shown as 26.1).
    if ($Prefix -match '^[0-9]+\.[0-9]$') { return "Excel may have turned ${Prefix}0 into ${Prefix}: format the column as Text and type it again" }
    return 'if Excel changed the number, format the column as Text and type it again' }

function Get-FleetImportCompareKey { param([string]$Column, [string]$Value)
    # What a group setting means, so that two rows that say the same thing in different words
    # ('yes' and 'TRUE', two spellings of one service list, / and \) do not count as a conflict.
    $v = ([string]$Value).Trim()
    if ($Column -eq 'Services') { $s = ConvertFrom-FleetImportServices $v; if (-not $s.Unknown.Count) { return ($s.Services -join ',') } }
    elseif ($Column -in 'ForceReinstall','EnableFips') { $b = ConvertFrom-FleetImportBool $v; if ($null -ne $b) { return [string]$b } }
    elseif ($Column -in 'Installer','ConfigFile','Pfx','TrustStore') { $p = ConvertFrom-FleetImportPath $v; if (-not $p.Problem) { return $p.Value.ToLowerInvariant() } }
    elseif ($Column -like '*Port' -and $v -match '^[0-9]+$') { return ('#' + $v.TrimStart('0')) }
    return $v.ToLowerInvariant() }

function ConvertFrom-FleetRows { param($Table, [string]$StagingRoot)
    # The fleet entries a sheet read by Read-FleetTable describes, checked by every import rule.
    # Tenants: one [ordered] entry per Group, in order of first appearance, keys in fleet file order,
    # only keys with values; Connectors in row order. Problems and Warnings are this function's own:
    # the caller adds the table's (Read-FleetTable's) as well. Problems stop an import; warnings do
    # not. With -StagingRoot, files missing under it are warnings (they may be added before a run).
    $problems = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $tenants = [System.Collections.Generic.List[object]]::new()
    $tableBad = [bool]@($Table.Problems | Where-Object { $_ }).Count
    $have = @($Table.Columns | Where-Object { $_ })
    if ($have -notcontains 'Group' -or $have -notcontains 'Host') {
        if (-not $tableBad) { $problems.Add('the sheet needs a Group column and a Host column') }
        return [pscustomobject]@{ Tenants = $tenants; Problems = [string[]]$problems.ToArray(); Warnings = [string[]]$warnings.ToArray() } }
    $rowsIn = @($Table.Rows | Where-Object { $_ })
    if (-not $rowsIn.Count) {
        if (-not $tableBad) { $problems.Add('the sheet holds no connector rows, only a header') }
        return [pscustomobject]@{ Tenants = $tenants; Problems = [string[]]$problems.ToArray(); Warnings = [string[]]$warnings.ToArray() } }
    $nameRx = '^[A-Za-z0-9][A-Za-z0-9._-]*$'
    $groupCols = @($script:FleetColumns | Where-Object { $_ -notin 'Group','Host','SshUser','Notes' })
    $groups = [System.Collections.Generic.List[object]]::new()
    $byName = [System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
    $seen = [System.Collections.Generic.Dictionary[string,int]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($r in $rowsIn) {
        $rn = [int]$r.RowNumber; $v = $r.Values
        $cell = @{}
        foreach ($k in @($v.Keys)) { $cell[[string]$k] = ([string]$v[$k]).Trim() }
        $broken = $false
        foreach ($k in @($cell.Keys)) { if ($k -ne 'Services' -and $cell[$k] -match '[\r\n]') { $problems.Add("row $rn ${k}: the cell holds a line break; put the value on one line"); $broken = $true } }
        $hn = [string]$cell['Host']; $gn = [string]$cell['Group']
        if (-not $hn) { $problems.Add("row ${rn}: the row has values but no Host"); continue }
        if (-not $broken -and $hn -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { $problems.Add("row $rn Host: '$hn' is not a DNS name or IPv4 address") }
        if ($seen.ContainsKey($hn)) { $problems.Add("row $rn Host: $hn is also in row $($seen[$hn]); list each connector once"); continue }
        $seen[$hn] = $rn
        if (-not $gn) { $problems.Add("row $rn Group: empty; give the group (the fleet entry Name) this connector belongs to"); continue }
        if ($gn -notmatch $nameRx) { $problems.Add("row $rn Group: '$gn' may hold only letters, digits, dots, dashes and underscores, and must start with a letter or digit") }
        if ($byName.ContainsKey($gn)) {
            $g = $byName[$gn]
            if ($g.Name -cne $gn) { $warnings.Add("row $rn Group: '$gn' is taken as '$($g.Name)' (row $($g.Rows[0])); group names are not case-sensitive") }
        } else {
            $g = [pscustomobject]@{ Name = $gn; Rows = [System.Collections.Generic.List[int]]::new(); Settings = @{}; Connectors = [System.Collections.Generic.List[object]]::new() }
            $byName[$gn] = $g; $groups.Add($g)
        }
        $g.Rows.Add($rn)
        $conn = [ordered]@{ Host = $hn }
        $su = [string]$cell['SshUser']
        if ($su) {
            if ($su -notmatch '^[A-Za-z0-9_][^\s"'':/]*$') { $problems.Add("row $rn SshUser: '$su' is not an account name (no spaces, quotes, colons or slashes)") }
            $conn['SshUser'] = $su
        }
        $g.Connectors.Add($conn)
        foreach ($col in $groupCols) {
            $val = [string]$cell[$col]
            if (-not $val) { continue }
            if (-not $g.Settings.ContainsKey($col)) { $g.Settings[$col] = [pscustomobject]@{ Value = $val; Row = $rn }; continue }
            $first = $g.Settings[$col]
            if ((Get-FleetImportCompareKey $col $first.Value) -cne (Get-FleetImportCompareKey $col $val)) {
                $problems.Add("group $($g.Name) ${col}: row $($first.Row) says '$($first.Value)' but row $rn says '$val'. A group setting is given once (later rows may leave it blank); for different settings put the connectors in groups of their own")
            }
        }
    }
    $order = @('Installer','InstallerVersion','ExpectVersionPrefix','ConfigFile','TrustStore','Pfx','Services','ServiceAccount',
        'Syslog','ForceReinstall','InstallDir','EnableFips','DirectorySyncPort','UserAuthPort','KerberosAuthPort','VirtualAppPort',
        'ProxyHost','ProxyPort','ProxyUser','NonProxyHosts')
    foreach ($g in $groups) {
        $n = $g.Name; $st = $g.Settings
        $rowsText = "row $($g.Rows[0])"; if ($g.Rows.Count -gt 1) { $rowsText = 'rows ' + ($g.Rows -join ', ') }
        $out = @{}
        foreach ($req in 'Installer','ConfigFile','Services') { if (-not $st.ContainsKey($req)) { $problems.Add("group $n ($rowsText): $req is required and is empty in every row of the group") } }
        # Services first: the rules for ServiceAccount and Pfx depend on them
        $svc = @(); $svcOk = $false
        if ($st.ContainsKey('Services')) {
            $sx = $st['Services']; $ps = ConvertFrom-FleetImportServices $sx.Value
            if ($ps.Unknown.Count) {
                $problems.Add("row $($sx.Row) Services: " + (($ps.Unknown | ForEach-Object { "'$_'" }) -join ', ') + ' is not a service; use DirectorySyncService, UserAuthService, KerberosAuthService or VirtualAppService (the word Service and spaces may be left out)')
            } elseif (-not $ps.Services.Count) { $problems.Add("row $($sx.Row) Services: no service is named") }
            else { $svcOk = $true }
            $svc = @($ps.Services)
            if ($svcOk) { $out['Services'] = $svc -join ',' }
        }
        $kerb = $svc -contains 'KerberosAuthService'; $vapp = $svc -contains 'VirtualAppService'
        foreach ($col in 'Installer','ConfigFile','TrustStore','Pfx') {
            if (-not $st.ContainsKey($col)) { continue }
            $sx = $st[$col]; $pp = ConvertFrom-FleetImportPath $sx.Value
            if ($pp.Problem) { $problems.Add("row $($sx.Row) ${col}: '$($sx.Value)' $($pp.Problem)") } else { $out[$col] = $pp.Value }
        }
        $ver = $null; $pre = $null; $sv = $null; $sp = $null
        if ($st.ContainsKey('InstallerVersion')) {
            $sv = $st['InstallerVersion']
            if ($sv.Value -match '^[0-9]+(\.[0-9]+){1,3}$') { $ver = $sv.Value; $out['InstallerVersion'] = $ver }
            else { $problems.Add("row $($sv.Row) InstallerVersion: '$($sv.Value)' is not a version such as 26.10.0.0") }
        }
        if ($st.ContainsKey('ExpectVersionPrefix')) {
            $sp = $st['ExpectVersionPrefix']
            if ($sp.Value -match '^[0-9]+(\.[0-9]+){0,3}$') { $pre = $sp.Value; $out['ExpectVersionPrefix'] = $pre }
            else { $problems.Add("row $($sp.Row) ExpectVersionPrefix: '$($sp.Value)' is not the start of a version, such as 26.10. " + (Get-FleetImportVersionHint $sp.Value)) }
        }
        if ($ver -and $pre) {
            if (-not ($ver -ceq $pre -or $ver.StartsWith($pre + '.'))) {
                $problems.Add("group $n ExpectVersionPrefix: '$pre' (row $($sp.Row)) does not match InstallerVersion '$ver' (row $($sv.Row)), so the health check would fail on every connector. " + (Get-FleetImportVersionHint $pre))
            }
        } elseif ($pre -and $pre -match '^[0-9]+\.[0-9]$') {
            $warnings.Add("group $n ExpectVersionPrefix: '$pre' (row $($sp.Row)): " + (Get-FleetImportVersionHint $pre))
        }
        if ($ver -and $ver -match '^[0-9]+\.[0-9]$') { $warnings.Add("group $n InstallerVersion: '$ver' (row $($sv.Row)): " + (Get-FleetImportVersionHint $ver)) }
        if ($st.ContainsKey('ServiceAccount')) {
            $sx = $st['ServiceAccount']
            if ($sx.Value -notmatch '^[^\\\s"]+\\[^\\"]+$') { $problems.Add("row $($sx.Row) ServiceAccount: '$($sx.Value)' is not DOMAIN\name, such as EXAMPLE\svc-access") }
            else { $out['ServiceAccount'] = $sx.Value }
            if ($svcOk -and -not $kerb -and -not $vapp) { $warnings.Add("group $n ServiceAccount: not used, because Services has neither KerberosAuthService nor VirtualAppService") }
        } elseif ($kerb -or $vapp) {
            $why = @(); if ($kerb) { $why += 'KerberosAuthService' }; if ($vapp) { $why += 'VirtualAppService' }
            $problems.Add("group $n ($rowsText): ServiceAccount is required with $($why -join ' and '); give it as DOMAIN\name")
        }
        if ($st.ContainsKey('Pfx') -and $svcOk -and -not $kerb) { $warnings.Add("group $n Pfx: not used, because Services has no KerberosAuthService") }
        if ($kerb -and -not $st.ContainsKey('Pfx')) { $warnings.Add("group $n installs KerberosAuthService without a Pfx; the installer will make a self-signed certificate") }
        foreach ($col in 'ForceReinstall','EnableFips') {
            if (-not $st.ContainsKey($col)) { continue }
            $sx = $st[$col]; $b = ConvertFrom-FleetImportBool $sx.Value
            if ($null -eq $b) { $problems.Add("row $($sx.Row) ${col}: '$($sx.Value)' is not TRUE or FALSE (yes/no, y/n and 1/0 are understood too)") } else { $out[$col] = $b }
        }
        foreach ($col in 'DirectorySyncPort','UserAuthPort','KerberosAuthPort','VirtualAppPort','ProxyPort') {
            if (-not $st.ContainsKey($col)) { continue }
            $sx = $st[$col]
            if ($sx.Value -notmatch '^[0-9]+$') { $problems.Add("row $($sx.Row) ${col}: '$($sx.Value)' is not a whole number (a port from 1 to 65535)"); continue }
            $num = 0
            if ([int]::TryParse($sx.Value, [ref]$num)) { $out[$col] = $num } else { $out[$col] = $sx.Value }   # too big: the range check below names it
        }
        foreach ($col in 'Syslog','InstallDir','ProxyHost','ProxyUser','NonProxyHosts') { if ($st.ContainsKey($col)) { $out[$col] = $st[$col].Value } }
        $e = [ordered]@{ Name = $n }
        foreach ($k in $order) { if ($out.ContainsKey($k)) { $e[$k] = $out[$k] } }
        $e['Connectors'] = $g.Connectors.ToArray()
        $known = @($script:TenantKeys)
        foreach ($k in @($e.Keys)) { if ($known -notcontains $k) { $problems.Add("group ${n}: '$k' is not a fleet setting this script knows (the import columns and the fleet settings do not match)") } }
        foreach ($p in @(Get-TenantOptionProblems $e | ForEach-Object { $_ })) { if ($p) { $problems.Add([string]$p) } }
        if ($StagingRoot) {
            foreach ($gap in @(Get-StagingGaps -Root $StagingRoot -T $e | ForEach-Object { $_ })) { if ($gap) { $warnings.Add("not in the staging folder yet (add it before a run): $gap") } }
        }
        $tenants.Add($e)
    }
    return [pscustomobject]@{ Tenants = $tenants; Problems = [string[]]$problems.ToArray(); Warnings = [string[]]$warnings.ToArray() } }

function Get-FleetImportDefaults {
    # Top-level settings of a fleet file made where none existed before.
    return [ordered]@{ CentralLogRoot = 'FleetDeploy\FleetLogs'; InstallScript = 'Silent Install\Install-AccessConnector.ps1' } }

function Get-FleetImportTopKeys {
    # The top-level settings an import carries from the existing fleet file into the new one.
    return @('StagingRoot','StagingFolders','CentralLogRoot','InstallScript','JavaPatchDir') }

function ConvertTo-FleetImportKey { param([string]$Name)
    # A hashtable key as data-file text: bare when it is a plain name, else quoted.
    if ($Name -match '^[A-Za-z_][A-Za-z0-9_]*$') { return $Name }
    return ConvertTo-FleetImportLiteral $Name }

function ConvertTo-FleetImportLiteral { param($Value, [string]$Indent = '')
    # A value as PowerShell data-file text: strings in single quotes with every quote character
    # doubled (including the typographic ones PowerShell also treats as quotes, which Excel's
    # autocorrect types), $true/$false, bare numbers, @( ) and @{ } over several lines.
    $inv = [Globalization.CultureInfo]::InvariantCulture
    if ($null -eq $Value) { return '$null' }
    if ($Value -is [bool]) { if ($Value) { return '$true' }; return '$false' }
    if ($Value -is [string] -or $Value -is [char]) { return "'" + ([string]$Value -replace "['\u2018\u2019\u201A\u201B]", '$0$0') + "'" }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [uint16] -or $Value -is [uint32] -or $Value -is [uint64] -or $Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        return $Value.ToString($inv) }
    if ($Value -is [System.Collections.IDictionary]) {
        $lines = [System.Collections.Generic.List[string]]::new(); $lines.Add('@{')
        foreach ($k in @($Value.Keys)) { $lines.Add("$Indent    " + (ConvertTo-FleetImportKey ([string]$k)) + ' = ' + (ConvertTo-FleetImportLiteral $Value[$k] "$Indent    ")) }
        $lines.Add("$Indent}")
        return ($lines -join "`r`n") }
    if ($Value -is [System.Collections.IEnumerable]) {
        $lines = [System.Collections.Generic.List[string]]::new(); $lines.Add('@(')
        foreach ($item in $Value) { $lines.Add("$Indent    " + (ConvertTo-FleetImportLiteral $item "$Indent    ")) }
        $lines.Add("$Indent)")
        return ($lines -join "`r`n") }
    return "'" + ([string]$Value -replace "['\u2018\u2019\u201A\u201B]", '$0$0') + "'" }

function ConvertTo-FleetFileText { param($Tenants, $TopLevel, [string]$Source, [string]$Generator, [string]$Stamp)
    # The fleet file text for these entries, laid out as fleet.example.psd1, CRLF line ends.
    # $TopLevel: the existing file's settings (of its keys, only StagingRoot, StagingFolders,
    # CentralLogRoot, InstallScript and JavaPatchDir are carried over), or $null for a new file
    # (CentralLogRoot and InstallScript defaults). StagingRoot, StagingFolders and JavaPatchDir are
    # written as commented-out examples when not set. Only entry keys with values are written.
    $clean = { param($s) (([string]$s) -replace '[\x00-\x1F\x7F]', ' ').Trim() }
    $top = $TopLevel; if ($null -eq $top) { $top = Get-FleetImportDefaults }
    $carry = Get-FleetImportTopKeys
    $topKeys = @($top.Keys | ForEach-Object { [string]$_ } | Where-Object { $carry -contains $_ })
    $o = [System.Collections.Generic.List[string]]::new()
    $o.Add('@{')
    $o.Add('    # Fleet definition for Invoke-AccessConnectorUpgrade.ps1.')
    $o.Add("    # Generated by $(& $clean $Generator) from $(& $clean $Source) on $(& $clean $Stamp).")
    $o.Add('    # To change it, edit the spreadsheet and import it again (-ImportFleet), or edit this file.')
    $o.Add('    # NO PASSWORDS BELONG IN THIS FILE. They are asked for at run time.')
    $o.Add('    #')
    $o.Add('    # Which file is used (first match wins):')
    $o.Add('    #   -FleetConfig <path>, -Fleet <name> (fleet.<name>.psd1),')
    $o.Add('    #   fleet.<this computer name>.psd1, fleet.<this computer domain>.psd1, fleet.psd1')
    $o.Add('')
    $o.Add('    # StagingRoot: the folder that holds Installers, Configs, ChildCerts, TrustedCerts')
    $o.Add("    # and 'Silent Install'. Leave it out to use the parent of this FleetDeploy folder,")
    $o.Add('    # so the same file works from macOS (/Volumes/...) and Windows (\\server\share\...).')
    $o.Add('    # All paths below are relative to the staging root.')
    if ($topKeys -contains 'StagingRoot') { $o.Add('    StagingRoot = ' + (ConvertTo-FleetImportLiteral $top['StagingRoot'] '    ')) }
    else { $o.Add("    # StagingRoot = '\\fileserver.example.local\Deploy\AccessConnector'") }
    $o.Add('')
    $o.Add('    # StagingFolders (optional): where other copies of the staging folder live. When a')
    $o.Add("    # tenant's files are not in the copy the tool is run from, the error names the copy")
    $o.Add('    # that has them. A path without a drive or server is tried below every mounted')
    $o.Add('    # volume (macOS) or drive (Windows).')
    if ($topKeys -contains 'StagingFolders') { $o.Add('    StagingFolders = ' + (ConvertTo-FleetImportLiteral $top['StagingFolders'] '    ')) }
    else {
        $o.Add('    # StagingFolders = @(')
        $o.Add("    #     'Deploy/AccessConnector'")
        $o.Add("    #     '\\fileserver.example.local\Deploy\AccessConnector'")
        $o.Add('    # )')
    }
    if ($topKeys -contains 'CentralLogRoot' -or $topKeys -contains 'InstallScript') { $o.Add('') }
    if ($topKeys -contains 'CentralLogRoot') { $o.Add(('    CentralLogRoot = {0,-40} # summary CSV + logs copied back' -f (ConvertTo-FleetImportLiteral $top['CentralLogRoot'] '    '))) }
    if ($topKeys -contains 'InstallScript') { $o.Add('    InstallScript  = ' + (ConvertTo-FleetImportLiteral $top['InstallScript'] '    ')) }
    $o.Add('')
    $o.Add('    # JavaPatchDir (optional): folder holding the vendor Java4shellPatch.bat (HW-283446,')
    $o.Add('    # for connector 26.05 and 26.10). Leave it out for versions that do not need it.')
    if ($topKeys -contains 'JavaPatchDir') { $o.Add('    JavaPatchDir   = ' + (ConvertTo-FleetImportLiteral $top['JavaPatchDir'] '    ')) }
    else { $o.Add("    # JavaPatchDir   = 'Installers\Java4shellPatch'") }
    $o.Add('')
    $o.Add('    # Each entry below is a CONNECTOR GROUP: connectors that get the same installer,')
    $o.Add('    # configuration file, services and certificate. Usually that is every connector of')
    $o.Add('    # a tenant. To give one connector, or a few, different services, put them in an')
    $o.Add('    # entry of their own with the same ConfigFile and a different Name and Services.')
    $o.Add('    # List each connector in one entry only.')
    $o.Add('    #')
    $o.Add('    # Entries run top to bottom; connectors inside an entry run one at a time, in the')
    $o.Add('    # order listed, so an entry with two or more connectors keeps one online.')
    $o.Add('    Tenants = @(')
    $order = @('Name','Installer','InstallerVersion','ExpectVersionPrefix','ConfigFile','TrustStore','Pfx','Services','ServiceAccount',
        'Syslog','ForceReinstall','InstallDir','EnableFips','DirectorySyncPort','UserAuthPort','KerberosAuthPort','VirtualAppPort',
        'ProxyHost','ProxyPort','ProxyUser','NonProxyHosts')
    $firstEntry = $true
    foreach ($t in @($Tenants)) {
        if ($null -eq $t) { continue }
        if (-not $firstEntry) { $o.Add('') }
        $firstEntry = $false
        $tk = @($t.Keys | ForEach-Object { [string]$_ })
        $o.Add('        @{')
        $keys = @($order | Where-Object { $tk -contains $_ }) + @($tk | Where-Object { $_ -notin $order -and $_ -ne 'Connectors' })
        foreach ($k in $keys) {
            if ($null -eq $t[$k] -or ($t[$k] -is [string] -and $t[$k] -eq '')) { continue }
            $o.Add(('            {0,-19} = {1}' -f (ConvertTo-FleetImportKey $k), (ConvertTo-FleetImportLiteral $t[$k] '            ')))
        }
        $o.Add('            Connectors = @(')
        foreach ($c in @($t['Connectors'])) {
            if ($null -eq $c) { continue }
            $ck = @($c.Keys | ForEach-Object { [string]$_ })
            $parts = @()
            foreach ($k in (@(@('Host','SshUser') | Where-Object { $ck -contains $_ }) + @($ck | Where-Object { $_ -notin 'Host','SshUser' }))) {
                if ($null -eq $c[$k] -or ($c[$k] -is [string] -and $c[$k] -eq '')) { continue }
                $parts += (ConvertTo-FleetImportKey $k) + ' = ' + (ConvertTo-FleetImportLiteral $c[$k])
            }
            $o.Add('                @{ ' + ($parts -join '; ') + ' }')
        }
        $o.Add('            )')
        $o.Add('        }')
    }
    $o.Add('    )')
    $o.Add('}')
    return (($o -join "`r`n") + "`r`n") }

function Compare-FleetImportValue { param([string]$Label, $Want, $Have, $Diff)
    # Adds to $Diff each way $Have (read back from the file) differs from $Want (what was meant):
    # kind (text, whole number, true/false, list, table), then value; text compared case-sensitively.
    $kind = { param($x)
        if ($null -eq $x) { return 'nothing' }
        if ($x -is [bool]) { return 'true/false' }
        if ($x -is [string] -or $x -is [char]) { return 'text' }
        if ($x -is [int] -or $x -is [long] -or $x -is [int16] -or $x -is [byte] -or $x -is [sbyte] -or $x -is [uint16] -or $x -is [uint32] -or $x -is [uint64]) { return 'whole number' }
        if ($x -is [double] -or $x -is [single] -or $x -is [decimal]) { return 'number' }
        if ($x -is [System.Collections.IDictionary]) { return 'table' }
        if ($x -is [System.Collections.IEnumerable]) { return 'list' }
        return $x.GetType().Name }
    $kw = & $kind $Want; $kh = & $kind $Have
    if ($kw -ne $kh) { $Diff.Add("${Label}: meant $kw $(ConvertTo-FleetImportLiteral $Want), the file holds $kh $(ConvertTo-FleetImportLiteral $Have)"); return }
    if ($kw -eq 'table') {
        $wk = @($Want.Keys | ForEach-Object { [string]$_ }); $hk = @($Have.Keys | ForEach-Object { [string]$_ })
        # a key meant with no value is not written (ConvertTo-FleetFileText writes only keys with values)
        $wk = @($wk | Where-Object { $hk -contains $_ -or -not ($null -eq $Want[$_] -or ($Want[$_] -is [string] -and $Want[$_] -eq '')) })
        foreach ($k in $wk) { if ($hk -notcontains $k) { $Diff.Add("${Label}.${k}: missing from the file") } else { Compare-FleetImportValue "${Label}.${k}" $Want[$k] $Have[$k] $Diff } }
        foreach ($k in $hk) { if ($wk -notcontains $k) { $Diff.Add("${Label}.${k}: in the file, but not meant to be") } }
        return }
    if ($kw -eq 'list') {
        $w = @($Want); $h = @($Have)
        if ($w.Count -ne $h.Count) { $Diff.Add("${Label}: $($w.Count) item(s) meant, the file holds $($h.Count)"); return }
        for ($i = 0; $i -lt $w.Count; $i++) { Compare-FleetImportValue "${Label}[$i]" $w[$i] $h[$i] $Diff }
        return }
    if ($kw -eq 'text') { if (-not ([string]$Want -ceq [string]$Have)) { $Diff.Add("${Label}: meant $(ConvertTo-FleetImportLiteral $Want), the file holds $(ConvertTo-FleetImportLiteral $Have)") }; return }
    if ($kw -eq 'nothing') { return }
    if ($Want -ne $Have) { $Diff.Add("${Label}: meant $(ConvertTo-FleetImportLiteral $Want), the file holds $(ConvertTo-FleetImportLiteral $Have)") } }

function Compare-FleetData { param($Tenants, $TopLevel, $Actual)
    # The differences between the fleet that was meant (the entries and top-level settings given to
    # ConvertTo-FleetFileText) and what the written file reads back as (Import-PowerShellDataFile).
    # Nothing is returned when the file means exactly what was meant; wrap the call in @( ).
    $diff = [System.Collections.Generic.List[string]]::new()
    if ($Actual -isnot [System.Collections.IDictionary]) { $diff.Add('the file did not read back as a fleet definition'); return $diff.ToArray() }
    $top = $TopLevel; if ($null -eq $top) { $top = Get-FleetImportDefaults }
    $carry = Get-FleetImportTopKeys
    $wk = @($top.Keys | ForEach-Object { [string]$_ } | Where-Object { $carry -contains $_ })
    $hk = @($Actual.Keys | ForEach-Object { [string]$_ } | Where-Object { $_ -ne 'Tenants' })
    foreach ($k in $wk) { if ($hk -notcontains $k) { $diff.Add("${k}: missing from the file") } else { Compare-FleetImportValue $k $top[$k] $Actual[$k] $diff } }
    foreach ($k in $hk) { if ($wk -notcontains $k) { $diff.Add("${k}: in the file, but not meant to be") } }
    if (@($Actual.Keys) -notcontains 'Tenants') { $diff.Add('Tenants: missing from the file') }
    else {
        $want = @($Tenants | Where-Object { $null -ne $_ }); $have = @($Actual['Tenants'])
        if ($want.Count -ne $have.Count) { $diff.Add("Tenants: $($want.Count) entries meant, the file holds $($have.Count)") }
        else { for ($i = 0; $i -lt $want.Count; $i++) { Compare-FleetImportValue "Tenants[$i] $($want[$i]['Name'])" $want[$i] $have[$i] $diff } }
    }
    return $diff.ToArray() }

# Reading existing connectors over SSH into a draft spreadsheet (-Mode Discover)
# ------------------------------------------------------------ discovery (-Mode Discover)
# Spreadsheet columns, in order, shared by -ImportFleet and -Mode Discover. Group names the fleet
# entry; Host, SshUser and Notes belong to one connector; every other column is a group setting.

# The script -Mode Discover runs on each connector. It is fed to 'powershell -NoProfile
# -NonInteractive -Command -' on standard input, so it is Windows PowerShell 5.1 and ASCII only.
# It is read-only: it changes nothing, writes no file, and reads only the items named in it.
# install.properties also holds secrets, so each of its lines is matched by name first and the
# value of any other name is never kept. From application.properties only the port line is used.
# It prints one line: DISCOVER_JSON:<json>.
# Standard input runs as if typed and a blank line ends a block, so the whole script is one block
# with no blank line inside it, and the blank lines after it make it run.
$script:DiscoverRemoteScript = @'
& {
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'
$d = [ordered]@{ Computer = $null; Fqdn = $null; InstalledVersion = $null; InstallLocation = $null; InstallRoot = $null; Services = @(); Registry = [ordered]@{}; Properties = [ordered]@{}; JavaFlag = $false; Cert = $null; Errors = @() }
$fail = { param([string]$Where, $Err)
    $m = ''
    try { $m = ([string]$Err.Exception.Message -replace '\s+', ' ').Trim() } catch { }
    if ($m.Length -gt 200) { $m = $m.Substring(0, 200) }
    $d.Errors += ($Where + ': ' + $m) }
try {
    # ---- this server
    try { $d.Computer = [string]$env:COMPUTERNAME } catch { }
    try { if ($env:COMPUTERNAME) { $d.Fqdn = ([string]([System.Net.Dns]::GetHostEntry($env:COMPUTERNAME)).HostName).ToLower() } } catch { & $fail 'dns' $_ }
    # ---- the 64-bit and 32-bit views of HKLM (opened read-only)
    $hives = @()
    foreach ($rv in @('Registry64', 'Registry32')) {
        try { $hives += [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]$rv) } catch { & $fail ('registry ' + $rv) $_ }
    }
    # ---- version and folder from the uninstall entry named Access Connector (three values only)
    $hit = $false
    foreach ($hv in $hives) {
        if ($hit) { break }
        $un = $null
        try {
            $un = $hv.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
            if ($un) {
                foreach ($sub in $un.GetSubKeyNames()) {
                    $ek = $null
                    try {
                        $ek = $un.OpenSubKey($sub)
                        if ($ek -and ([string]$ek.GetValue('DisplayName') -eq 'Access Connector')) {
                            $d.InstalledVersion = [string]$ek.GetValue('DisplayVersion')
                            $d.InstallLocation = [string]$ek.GetValue('InstallLocation')
                            $hit = $true
                        }
                    } catch { } finally { if ($ek) { $ek.Close() } }
                    if ($hit) { break }
                }
            }
        } catch { & $fail 'uninstall entries' $_ } finally { if ($un) { $un.Close() } }
    }
    # ---- the connector's own registry key: these value names only, each read by name
    $allowR = @('WS1_SYSLOG_HOSTNAME', 'IS_NET_API_LOGON_USERNAME', 'InstallDir', 'WS1_INSTALLED_SERVICES')
    foreach ($hv in $hives) {
        $ak = $null
        try {
            $ak = $hv.OpenSubKey('SOFTWARE\Omnissa\Access Connector')
            if ($ak) {
                foreach ($vn in $allowR) {
                    if ($vn -match 'PASS') { continue }
                    $vv = $ak.GetValue($vn)
                    if ($null -ne $vv) { $d.Registry[$vn] = [string]$vv }
                }
            }
        } catch { & $fail 'connector registry' $_ } finally { if ($ak) { $ak.Close() } }
        if ($d.Registry.Count) { break }
    }
    # ---- the four connector services: state and the account each runs as
    $svcMap = [ordered]@{ DirectorySyncService = 'AccessDirectorySyncService'; UserAuthService = 'AccessUserAuthService'; KerberosAuthService = 'AccessKerberosAuthService'; VirtualAppService = 'AccessVirtualAppService' }
    $folderMap = @{ DirectorySyncService = 'Directory Sync Service'; UserAuthService = 'User Auth Service'; KerberosAuthService = 'Kerberos Auth Service'; VirtualAppService = 'Virtual App Service' }
    $svcList = @(); $imagePaths = @()
    foreach ($key in $svcMap.Keys) {
        $sName = $svcMap[$key]; $state = $null; $account = $null
        try {
            $ci = Get-CimInstance -ClassName Win32_Service -Filter ("Name='" + $sName + "'")
            if ($ci) { $state = [string]$ci.State; $account = [string]$ci.StartName; if ($ci.PathName) { $imagePaths += [string]$ci.PathName } }
        } catch { & $fail ('service ' + $sName) $_ }
        if (-not $state) { try { $gs = Get-Service -Name $sName; if ($gs) { $state = [string]$gs.Status } } catch { } }
        if ($state) { $svcList += [pscustomobject]@{ Key = $key; Name = $sName; Status = $state; StartName = $account } }
    }
    $d.Services = $svcList
    # ---- the install folder: the uninstall entry, a service's program path, else the default
    $root = 'C:\Program Files\Access Connector'
    $cands = @()
    if ($d.InstallLocation) { $cands += (Join-Path $d.InstallLocation 'Access Connector'); $cands += ([string]$d.InstallLocation).TrimEnd('\') }
    foreach ($ip in $imagePaths) { if ($ip -match '^"?(.*?\\Access Connector)\\') { $cands += $Matches[1] } }
    foreach ($c in $cands) { try { if ($c -and ($c -match '\\Access Connector$') -and (Test-Path -LiteralPath (Join-Path $c 'Support'))) { $root = $c; break } } catch { } }
    $d.InstallRoot = $root
    # ---- install.properties: a line is kept only when its NAME is one of these
    $allowP = @('INSTALL_DIR', 'TENANT_URL', 'TRUST_CERTS', 'SYSLOG_CONFIGURATIONS', 'PROXY_HOST', 'PROXY_PORT', 'PROXY_USER', 'NON_PROXY_HOSTS', 'FIPS_ENABLED', 'DIRECTORY_SYNC_SVC_PORT', 'USER_AUTH_SVC_PORT', 'KERBEROS_AUTH_SVC_PORT', 'VIRTUAL_APP_SYNC_SVC_PORT')
    try {
        $pf = Join-Path $root 'Support\scripts\install.properties'
        if (Test-Path -LiteralPath $pf -PathType Leaf) {
            foreach ($ln in @(Get-Content -LiteralPath $pf)) {
                $eq = $ln.IndexOf('=')
                if ($eq -lt 1) { continue }
                $pn = $ln.Substring(0, $eq).Trim().ToUpperInvariant()
                if ($allowP -notcontains $pn) { continue }
                $d.Properties[$pn] = $ln.Substring($eq + 1).Trim()
            }
            $ln = $null
        }
    } catch { & $fail 'install.properties' $_ }
    # ---- the Java4Shell patch flag in the service settings files
    foreach ($key in $folderMap.Keys) {
        try {
            $xf = Join-Path (Join-Path $root $folderMap[$key]) ($key + '.xml')
            if ((Test-Path -LiteralPath $xf -PathType Leaf) -and (Select-String -LiteralPath $xf -Pattern 'UseBASE64Intrinsics' -SimpleMatch -Quiet)) { $d.JavaFlag = $true }
        } catch { & $fail ($key + '.xml') $_ }
    }
    # ---- the certificate Kerberos Auth serves (only while it runs): its own TLS 1.2 handshake
    if (@($svcList | Where-Object { $_.Key -eq 'KerberosAuthService' -and $_.Status -eq 'Running' }).Count) {
        $port = 443
        try {
            $ap = Join-Path $root 'Kerberos Auth Service\conf\application.properties'
            if (Test-Path -LiteralPath $ap -PathType Leaf) {
                foreach ($al in @(Get-Content -LiteralPath $ap)) { if ($al -match '^[ \t]*eks\.http\.server\.port[ \t]*[=:][ \t]*(\d+)[ \t]*$') { $port = [int]$Matches[1] } }
                $al = $null
            }
        } catch { & $fail 'application.properties' $_ }
        $ce = [ordered]@{ Ok = $false; Port = $port; Subject = ''; Names = @(); Issuer = ''; NotAfter = ''; SelfSigned = $false; Message = '' }
        $tcp = $null; $ssl = $null
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $iar = $tcp.BeginConnect('localhost', $port, $null, $null)
            if (-not $iar.AsyncWaitHandle.WaitOne(5000)) { throw ('no answer on port ' + $port + ' within 5 seconds') }
            $tcp.EndConnect($iar)
            $tcp.ReceiveTimeout = 5000; $tcp.SendTimeout = 5000
            # any certificate is accepted: it is only read
            $any = [System.Net.Security.RemoteCertificateValidationCallback]{ $true }
            $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false, $any)
            $ssl.AuthenticateAsClient('localhost', $null, [System.Security.Authentication.SslProtocols]::Tls12, $false)
            if ($null -eq $ssl.RemoteCertificate) { throw 'the service presented no certificate' }
            $der = $ssl.RemoteCertificate.GetRawCertData()
            $c2 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (,$der)
            $ce.Subject = [string]$c2.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
            $ce.Issuer = [string]$c2.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $true)
            $ce.NotAfter = $c2.NotAfter.ToString('yyyy-MM-dd')
            $dns = @()
            foreach ($ext in $c2.Extensions) { if ($ext.Oid.Value -eq '2.5.29.17') { foreach ($mt in [regex]::Matches([string]$ext.Format($false), '(?i)DNS[^=,]*=[ \t]*([^,\s]+)')) { $dns += $mt.Groups[1].Value.ToLower() } } }
            if ((-not $dns.Count) -and $ce.Subject) { $dns += $ce.Subject.ToLower() }
            $ce.Names = $dns
            # the certificate the installer makes for itself is issued by "Internal Root CA <date>"
            $ce.SelfSigned = [bool]($ce.Issuer -match '^Internal Root CA \d')
            $c2.Reset()
            $ce.Ok = $true
        } catch {
            $ce.Message = ([string]$_.Exception.Message -replace '\s+', ' ').Trim()
            if ($_.Exception.InnerException) { $ce.Message += ' / ' + ([string]$_.Exception.InnerException.Message -replace '\s+', ' ').Trim() }
        } finally { if ($ssl) { try { $ssl.Dispose() } catch { } }; if ($tcp) { try { $tcp.Close() } catch { } } }
        $d.Cert = $ce
    }
} catch { & $fail 'discovery' $_ }
# ---- the one line of output; characters outside ASCII are sent as \u escapes
$json = $null
try { $json = ConvertTo-Json -InputObject $d -Compress -Depth 6 } catch { $json = '{"Errors":["the result could not be converted to JSON"]}' }
$json = [regex]::Replace([string]$json, '[^\x00-\x7F]', { param($ch) '\u{0:x4}' -f [int][char]$ch.Value })
[Console]::Out.WriteLine(('DISCOVER' + '_JSON:') + $json)
[Console]::Out.Flush()
}



'@

function Invoke-ConnectorDiscovery { param($Conn, [int]$TimeoutSec = 120)
    # -Mode Discover, one connector: runs $script:DiscoverRemoteScript over SSH. Nothing is copied
    # to the connector; the script goes to Windows PowerShell on standard input. The process is
    # killed after -TimeoutSec. Returns Host, Ok, Data (the parsed findings, or $null) and Error
    # (ssh's own messages, or why there is no result).
    if ($TimeoutSec -lt 1) { $TimeoutSec = 120 }
    $hostName = [string]$Conn.Host
    $user = [string]$Conn.SshUser; if (-not $user) { $user = 'administrator' }
    $res = [pscustomobject]@{ Host = $hostName; Ok = $false; Data = $null; Error = '' }
    $p = $null
    try {
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        $psi = [System.Diagnostics.ProcessStartInfo]::new('ssh')
        foreach ($x in (Get-SshBaseArgs)) { $psi.ArgumentList.Add($x) }
        $psi.ArgumentList.Add((Get-SshTarget ([pscustomobject]@{ Host = $hostName; SshUser = $user })))
        $psi.ArgumentList.Add('powershell -NoProfile -NonInteractive -Command -')
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
        $psi.StandardInputEncoding = $utf8; $psi.StandardOutputEncoding = $utf8; $psi.StandardErrorEncoding = $utf8
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
        $p = [System.Diagnostics.Process]::Start($psi)
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        # LF line ends, and blank lines at the end so the last block runs
        $text = (([string]$script:DiscoverRemoteScript) -replace "`r`n", "`n").TrimEnd() + "`n`n`n"
        $bytes = $utf8.GetBytes($text)
        try {
            $w = $p.StandardInput.BaseStream.WriteAsync($bytes, 0, $bytes.Length)
            $ms = [int][Math]::Max(1000, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            if ($w.Wait($ms)) { $p.StandardInput.BaseStream.Flush(); $p.StandardInput.Close() }
        } catch { }
        $left = [int][Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        $exited = $p.WaitForExit($left)
        if (-not $exited) {
            try { $p.Kill($true) } catch { }
            try { $null = $p.WaitForExit(5000) } catch { }
        }
        $outText = ''; $errText = ''
        try { if ($outTask.Wait(5000)) { $outText = [string]$outTask.Result } } catch { }
        try { if ($errTask.Wait(5000)) { $errText = [string]$errTask.Result } } catch { }
        # the result line; progress records (CLIXML) are dropped
        $cands = @(foreach ($line in ($outText -split "`r?`n")) {
            if ($line -match '^#< CLIXML|^<Objs ') { continue }
            $i = $line.IndexOf('DISCOVER_JSON:')
            if ($i -ge 0) { $line.Substring($i + 14).Trim() }
        })
        $data = $null
        foreach ($j in $cands) { try { $data = $j | ConvertFrom-Json -ErrorAction Stop; if ($null -ne $data) { break } } catch { $data = $null } }
        # ssh's own messages (cannot connect, key refused), without CLIXML records
        $errLines = @(foreach ($l in ($errText -split "`r?`n")) {
            if ([string]::IsNullOrWhiteSpace($l) -or $l -match '^#< CLIXML|^<Objs ') { continue }
            $l.Trim()
        })
        $errShort = $errLines -join ' / '
        if ($errShort.Length -gt 500) { $errShort = $errShort.Substring(0, 500) + ' ...' }
        $code = $null; try { if ($p.HasExited) { $code = $p.ExitCode } } catch { }
        if ($null -ne $data) { $res.Ok = $true; $res.Data = $data }
        elseif (-not $exited) { $res.Error = "no answer within $TimeoutSec seconds" + $(if ($errShort) { " ($errShort)" } else { '' }) }
        elseif ($errShort) { $res.Error = $errShort }
        elseif ($cands.Count) { $res.Error = 'the discovery result could not be read' }
        elseif ($null -ne $code -and $code -ne 0) { $res.Error = "ssh ended with exit code $code and no result" }
        else { $res.Error = 'the connector returned no discovery result' }
    } catch {
        $res.Ok = $false; $res.Data = $null
        $res.Error = 'ssh could not be run: ' + ([string]$_.Exception.Message -replace '\s+', ' ').Trim()
    } finally { if ($p) { try { $p.Dispose() } catch { } } }
    return $res
}

function ConvertTo-DiscoveredRows { param($Results, [string]$StagingRoot, [string]$SshUser)
    # -Mode Discover: what was found on each connector, as spreadsheet rows for -ImportFleet. Each
    # row is an [ordered] dictionary with every column of $script:FleetColumns ('' when blank).
    # -Results: one object per host with Host, SshUser (the fleet connector's, or blank), Ok, Data,
    # Error and Entry (its fleet entry, or $null). In the staging folder only file NAMES are read;
    # no es-config file is opened. Rows come out one at a time in the order of -Results: collect
    # them with @(...).
    $cols = @($script:FleetColumns)
    $groupCols = @($cols | Where-Object { $_ -notin 'Group','Host','SshUser','Notes' })
    $canon = @('DirectorySyncService','UserAuthService','KerberosAuthService','VirtualAppService')
    $portProps = [ordered]@{ DirectorySyncPort = 'DIRECTORY_SYNC_SVC_PORT'; UserAuthPort = 'USER_AUTH_SVC_PORT'; KerberosAuthPort = 'KERBEROS_AUTH_SVC_PORT'; VirtualAppPort = 'VIRTUAL_APP_SYNC_SVC_PORT' }
    $portDefault = @{ DirectorySyncPort = 8080; UserAuthPort = 8090; KerberosAuthPort = 443; VirtualAppPort = 8008 }
    $sep = [string][char]31

    # a property of a parsed object, or a key of a dictionary; $null when absent
    $get = { param($o, [string]$n)
        if ($null -eq $o) { return $null }
        if ($o -is [System.Collections.IDictionary]) { if ($o.Contains($n)) { return $o[$n] }; return $null }
        $pp = $o.PSObject.Properties[$n]; if ($pp) { return $pp.Value }; return $null }
    $str = { param($o, [string]$n) $v = & $get $o $n; if ($null -eq $v) { return '' }; return ([string]$v).Trim() }
    $count = { param($o) if ($null -eq $o) { return 0 }; if ($o -is [System.Collections.IDictionary]) { return $o.Count }; return @($o.PSObject.Properties).Count }
    $isDomainAcct = { param([string]$a) return (($a -match '^[^\\/\s]+\\[^\\/\s]+$') -and ($a -notmatch '^(?i)(\.|BUILTIN|NT AUTHORITY|NT SERVICE)\\')) }
    $normPath = { param([string]$s) $s = ([string]$s).Trim() -replace '/', '\'; if ($s.StartsWith('.\')) { $s = $s.Substring(2) }; return $s.TrimEnd('\') }
    $normSvc = { param([string]$s)
        $set = @{}
        foreach ($tk in ([string]$s -split '[,;|]+')) {
            $t2 = ($tk -replace '[\s_.-]', '').ToLowerInvariant(); if (-not $t2) { continue }
            if (-not $t2.EndsWith('service')) { $t2 += 'service' }
            foreach ($cn in $canon) { if ($cn.ToLowerInvariant() -eq $t2) { $set[$cn] = $true } }
        }
        return (@($canon | Where-Object { $set.ContainsKey($_) }) -join ',') }
    $tenantHostOf = { param([string]$url)
        $u = ([string]$url).Trim(); if (-not $u) { return '' }
        if ($u -match '^[A-Za-z][A-Za-z0-9+.-]*://([^/?#]*)') { $u = $Matches[1] } else { $u = ($u -split '[/?#]')[0] }
        $u = ($u -replace '^.*@', '') -replace ':\d*$', ''
        return $u.Trim().TrimEnd('.').ToLowerInvariant() }
    # file names in one folder of the staging folder (names starting with a dot are left out)
    $listFiles = { param([string]$Sub, [string]$Pattern)
        if (-not $StagingRoot) { return }
        try {
            $dir = Join-Path $StagingRoot $Sub
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return }
            Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^\.' -and $_.Extension -match $Pattern } | ForEach-Object { $_.Name } | Sort-Object
        } catch { } }
    $installers = @(& $listFiles 'Installers' '(?i)^\.exe$')
    $configs = @(& $listFiles 'Configs' '(?i)^\.json$')
    $pfxFiles = @(& $listFiles 'ChildCerts' '(?i)^\.pfx$')
    $trusted = @(& $listFiles 'TrustedCerts' '(?i)^\.(pem|cer|crt)$')
    $installer = ''; $installerVersion = ''
    if ($installers.Count -eq 1) {
        $installer = 'Installers\' + $installers[0]
        $tok = @([regex]::Matches([IO.Path]::GetFileNameWithoutExtension($installers[0]), '\d+\.\d+(\.\d+){0,2}') | ForEach-Object { $_.Value })
        if ($tok.Count) { $vp = @($tok[-1] -split '\.'); while ($vp.Count -lt 4) { $vp += '0' }; $installerVersion = $vp -join '.' }
    }

    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($r in @($Results)) {
        if ($null -eq $r) { continue }
        $row = [ordered]@{}; foreach ($c in $cols) { $row[$c] = '' }
        $hostName = & $str $r 'Host'
        $entry = & $get $r 'Entry'
        $row['Host'] = $hostName
        # SshUser: -SshUser, else the fleet connector's, else blank
        $u = ''
        if ($SshUser) { $u = $SshUser }
        else {
            $u = & $str $r 'SshUser'
            if (-not $u -and $entry) { foreach ($fc in @(& $get $entry 'Connectors')) { if ((& $str $fc 'Host') -eq $hostName) { $u = & $str $fc 'SshUser'; break } } }
        }
        $row['SshUser'] = $u
        $data = & $get $r 'Data'
        if (-not [bool](& $get $r 'Ok') -or $null -eq $data) {
            $why = ((& $str $r 'Error') -replace '\s+', ' ').Trim(); if (-not $why) { $why = 'no answer' }
            $row['Notes'] = 'not reached: ' + $why
            $items.Add([pscustomobject]@{ Row = $row; Base = ''; Diff = 0; Sig = '' }); continue
        }
        $props = & $get $data 'Properties'
        $reg = & $get $data 'Registry'
        $propsKnown = (& $count $props) -gt 0
        $regKnown = (& $count $reg) -gt 0
        $found = @(& $get $data 'Services')

        # Services: the installed ones, in the usual order
        $have = @{}
        foreach ($s in $found) { $k = & $str $s 'Key'; foreach ($cn in $canon) { if ($k -eq $cn) { $have[$cn] = $true } } }
        if (-not $have.Count) { foreach ($cn in @((& $normSvc (& $str $reg 'WS1_INSTALLED_SERVICES')) -split ',')) { if ($cn) { $have[$cn] = $true } } }
        $svc = @($canon | Where-Object { $have.ContainsKey($_) })
        $row['Services'] = $svc -join ','
        $kerb = $svc -contains 'KerberosAuthService'
        $needAcct = $kerb -or ($svc -contains 'VirtualAppService')

        # ServiceAccount: the one the installer recorded, else the account Kerberos Auth or Virtual App runs as
        if ($needAcct) {
            $regAcct = & $str $reg 'IS_NET_API_LOGON_USERNAME'
            $startAcct = ''
            foreach ($want in 'KerberosAuthService','VirtualAppService') {
                foreach ($s in $found) { if ((& $str $s 'Key') -eq $want) { $a = & $str $s 'StartName'; if (-not $startAcct -and (& $isDomainAcct $a)) { $startAcct = $a } } }
            }
            if ($regAcct -and (& $isDomainAcct $regAcct)) { $row['ServiceAccount'] = $regAcct }
            elseif ($startAcct) { $row['ServiceAccount'] = $startAcct }
            elseif ($regAcct) { $row['ServiceAccount'] = $regAcct }
        }

        # files in the staging folder, matched by name only
        $row['Installer'] = $installer; $row['InstallerVersion'] = $installerVersion
        $tenantHost = & $tenantHostOf (& $str $props 'TENANT_URL')
        $cfgGuess = ''
        if ($tenantHost) {
            # the tenant's full host name, not part of a longer name (dev.tenant1... is not tenant1...)
            $hx = [regex]::Escape($tenantHost)
            $hits = @($configs | Where-Object { $_ -match "(?i)(^|[^a-z0-9.])$hx(?=\.json$|[^a-z0-9.]|$)" })
            # else the tenant's first name part as a whole word (tenant1-es-config.json for
            # tenant1.example.com), only in a name that holds no other host name, and said so
            if (-not $hits.Count) {
                $label = ($tenantHost -split '\.')[0]
                if ($label) {
                    $lx = [regex]::Escape($label)
                    $hits = @($configs | Where-Object { $_ -match "(?i)(^|[^a-z0-9])$lx([^a-z0-9]|$)" -and ([IO.Path]::GetFileNameWithoutExtension($_) -notmatch '[A-Za-z0-9-]\.[A-Za-z]') })
                    if ($hits.Count -eq 1) { $cfgGuess = $label }
                }
            }
            if ($hits.Count -eq 1) { $row['ConfigFile'] = 'Configs\' + $hits[0] }
        }
        $cert = & $get $data 'Cert'
        $certOk = ($null -ne $cert) -and ((& $get $cert 'Ok') -eq $true)
        $selfSigned = $certOk -and ((& $get $cert 'SelfSigned') -eq $true)
        if ($kerb -and $certOk -and -not $selfSigned) {
            $names = @(@(& $str $cert 'Subject') + @(@(& $get $cert 'Names') | ForEach-Object { ([string]$_).Trim() }) | Where-Object { $_ })
            $hits = @($pfxFiles | Where-Object { $names -contains [IO.Path]::GetFileNameWithoutExtension($_) })
            if ($hits.Count -eq 1) { $row['Pfx'] = 'ChildCerts\' + $hits[0] }
        }
        if ((& $str $props 'TRUST_CERTS') -and $trusted.Count -and -not ($entry -and (& $str $entry 'TrustStore'))) { $row['TrustStore'] = 'TrustedCerts' }

        # installer settings the connector was installed with
        $sys = & $str $reg 'WS1_SYSLOG_HOSTNAME'; if (-not $sys) { $sys = & $str $props 'SYSLOG_CONFIGURATIONS' }
        $row['Syslog'] = $sys
        $dir = & $str $props 'INSTALL_DIR'
        if (-not $dir) { $dir = & $str $reg 'InstallDir' }
        if (-not $dir) { $dir = & $str $data 'InstallLocation' }
        if ($dir -match '\\\\|\\:') { $dir = ($dir -replace '\\\\', '\') -replace '\\:', ':' }
        $dir = ($dir.TrimEnd('\', '/') -replace '(?i)[\\/]+Access Connector$', '').TrimEnd('\', '/')
        if ($dir -match '^[A-Za-z]:$') { $dir += '\' }
        if ($dir -ieq 'C:\Program Files') { $dir = '' }
        $row['InstallDir'] = $dir
        if ((& $str $props 'FIPS_ENABLED') -eq 'true') { $row['EnableFips'] = 'TRUE' }
        foreach ($pc in $portProps.Keys) {
            $v = & $str $props $portProps[$pc]; if (-not $v) { continue }
            $n = 0
            if ([int]::TryParse($v, [ref]$n)) { if ($n -ne $portDefault[$pc]) { $row[$pc] = [string]$n } } else { $row[$pc] = $v }
        }
        if (& $str $props 'PROXY_HOST') {
            $row['ProxyHost'] = & $str $props 'PROXY_HOST'; $row['ProxyPort'] = & $str $props 'PROXY_PORT'
            $row['ProxyUser'] = & $str $props 'PROXY_USER'; $row['NonProxyHosts'] = & $str $props 'NON_PROXY_HOSTS'
        }

        # Group: the fleet entry's name, else the tenant's first name part, else GROUP
        $base = ''
        if ($entry) { $base = & $str $entry 'Name' }
        if (-not $base -and $tenantHost) { $base = ((($tenantHost -split '\.')[0]).ToUpperInvariant() -replace '[^A-Z0-9]', '-').Trim('-') }
        if (-not $base) { $base = 'GROUP' }

        # A host listed in the fleet file: files that could not be matched are taken from its entry
        $fromEntry = @()
        if ($entry) {
            foreach ($k in 'Installer','InstallerVersion','ConfigFile','Pfx','TrustStore') {
                if ($row[$k]) { continue }
                if ($k -eq 'Pfx' -and -not $kerb) { continue }
                if ($k -eq 'TrustStore' -and -not (& $str $props 'TRUST_CERTS')) { continue }
                if ($k -eq 'InstallerVersion' -and $row['Installer'] -and $row['Installer'] -ne (& $normPath (& $str $entry 'Installer'))) { continue }
                $v = & $str $entry $k
                if ($k -in 'Installer','ConfigFile','Pfx','TrustStore') { $v = & $normPath $v }
                if ($k -eq 'InstallerVersion' -and $v -match '^\d+(\.\d+){1,3}$') { $vp = @($v -split '\.'); while ($vp.Count -lt 4) { $vp += '0' }; $v = $vp -join '.' }
                if ($v) { $row[$k] = $v; $fromEntry += $k }
            }
        }

        # Notes
        $nDiff = 0
        $notes = [System.Collections.Generic.List[string]]::new()
        $ver = & $str $data 'InstalledVersion'
        if ($ver) { $notes.Add("installed $ver") } elseif (-not $svc.Count) { $notes.Add('no Access Connector found') }
        if ($tenantHost) { $notes.Add("tenant $tenantHost") }
        $fill = @(foreach ($k in 'Installer','ConfigFile','Services') { if (-not $row[$k]) { $k } })
        if ($needAcct -and -not $row['ServiceAccount']) { $fill += 'ServiceAccount' }
        if ($fill.Count) { $notes.Add('fill: ' + ($fill -join ', ')) }
        if ($kerb -and -not $row['Pfx'] -and -not $selfSigned) { $notes.Add('set Pfx if a PFX is used: without one the installer makes a self-signed certificate') }
        if ((& $str $props 'TRUST_CERTS') -and -not $row['TrustStore']) { $notes.Add('the connector trusts extra CA certificates: set TrustStore') }
        if ($cfgGuess -and -not ($fromEntry -contains 'ConfigFile')) { $notes.Add("ConfigFile matched by the tenant's first name part only ($cfgGuess): check it") }
        $errs = @(@(& $get $data 'Errors') | ForEach-Object { ([string]$_ -replace '\s+', ' ').Trim() } | Where-Object { $_ })
        if ($errs.Count) { $notes.Add('not read on the connector: ' + ($errs -join ' / ')) }
        if ($fromEntry.Count) { $notes.Add("taken from fleet entry $(& $str $entry 'Name'): " + ($fromEntry -join ', ')) }
        if ((& $get $data 'JavaFlag') -eq $true) { $notes.Add('Java4Shell patch flag present: set JavaPatchDir in the fleet file') }
        if ($kerb -and $selfSigned) { $notes.Add("Kerberos Auth serves the installer's self-signed certificate: set Pfx, then run -Mode RepairCertificate") }
        elseif ($kerb -and $null -ne $cert -and -not $certOk) {
            $why = ((& $str $cert 'Message') -replace '\s+', ' ').Trim(); if (-not $why) { $why = 'no reason given' }
            $notes.Add("Kerberos Auth certificate not read: $why") }
        elseif ($kerb -and $null -eq $cert) { $notes.Add('Kerberos Auth is not running, so its certificate was not read') }

        # differences from the fleet entry the host is listed in (only what the connector showed)
        if ($entry) {
            $diff = @{}
            $ev = { param([string]$n) & $str $entry $n }
            if ($row['Services'] -and ((& $normSvc (& $ev 'Services')) -cne $row['Services'])) { $diff['Services'] = $true }
            if ($row['ServiceAccount'] -and ($row['ServiceAccount'] -ne (& $ev 'ServiceAccount'))) { $diff['ServiceAccount'] = $true }
            if ($row['ConfigFile'] -and ($row['ConfigFile'] -ne (& $normPath (& $ev 'ConfigFile')))) { $diff['ConfigFile'] = $true }
            if ($row['Pfx'] -and ($row['Pfx'] -ne (& $normPath (& $ev 'Pfx')))) { $diff['Pfx'] = $true }
            if ($propsKnown -and ([bool](& $str $props 'TRUST_CERTS') -ne [bool](& $ev 'TrustStore'))) { $diff['TrustStore'] = $true }
            if (($propsKnown -or $regKnown) -and ($row['Syslog'] -ne (& $ev 'Syslog'))) { $diff['Syslog'] = $true }
            if ($propsKnown -and (& $str $props 'INSTALL_DIR')) {
                $ed = (& $ev 'InstallDir').TrimEnd('\', '/'); if ($ed -match '^[A-Za-z]:$') { $ed += '\' }; if ($ed -ieq 'C:\Program Files') { $ed = '' }
                if ($row['InstallDir'] -ne $ed) { $diff['InstallDir'] = $true }
            }
            if (& $str $props 'FIPS_ENABLED') { if ([bool]$row['EnableFips'] -ne ((& $get $entry 'EnableFips') -eq $true)) { $diff['EnableFips'] = $true } }
            foreach ($pc in $portProps.Keys) {
                if (-not (& $str $props $portProps[$pc])) { continue }
                $mine = $row[$pc]; if (-not $mine) { $mine = [string]$portDefault[$pc] }
                $theirs = & $ev $pc; if (-not $theirs) { $theirs = [string]$portDefault[$pc] }
                if ($mine -ne $theirs) { $diff[$pc] = $true }
            }
            if ($propsKnown) { foreach ($pc in 'ProxyHost','ProxyPort','ProxyUser','NonProxyHosts') { if ($row[$pc] -ne (& $ev $pc)) { $diff[$pc] = $true } } }
            $dc = @($groupCols | Where-Object { $diff.ContainsKey($_) })
            if ($dc.Count) { $notes.Add("differs from fleet entry $(& $str $entry 'Name'): " + ($dc -join ', ')) }
            $nDiff = $dc.Count
        }
        $row['Notes'] = $notes -join '; '
        if ($entry) { foreach ($c in $groupCols) { $ev2 = & $str $entry $c; if ($row[$c] -and $ev2 -and ($row[$c] -ieq $ev2) -and ($row[$c] -cne $ev2)) { $row[$c] = $ev2 } } }
        $items.Add([pscustomobject]@{ Row = $row; Base = $base; Diff = $nDiff; Sig = (@($groupCols | ForEach-Object { ([string]$row[$_]).ToLowerInvariant() }) -join $sep) })
    }

    # Rows that would share a Group but differ in any group setting: -2, -3 ... (see the ordering below)
    $used = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($it in $items) { if ($it.Base) { $null = $used.Add($it.Base) } }
    $seen = @{}
    # the rows closest to their fleet entry claim its name; rows that differ more take -2, -3 ...
    $order = @($items | Sort-Object -Property Diff -Stable)
    foreach ($it in $order) {
        if (-not $it.Base) { continue }
        if (-not $seen.ContainsKey($it.Base)) { $seen[$it.Base] = [System.Collections.Generic.List[object]]::new() }
        $list = $seen[$it.Base]
        $hit = $null; foreach ($x in $list) { if ($x.Sig -ceq $it.Sig) { $hit = $x; break } }
        if (-not $hit) {
            $name = $it.Base
            if ($list.Count) { $n = $list.Count + 1; do { $name = "$($it.Base)-$n"; $n++ } while ($used.Contains($name)); $null = $used.Add($name) }
            $hit = [pscustomobject]@{ Sig = $it.Sig; Name = $name }; $list.Add($hit)
        }
        $it.Row['Group'] = $hit.Name
    }
    foreach ($it in $items) { $it.Row }
}

function Export-DiscoveredCsv { param($Rows, [string]$Path)
    # Writes the rows as a spreadsheet Excel opens as it is: UTF-8 with a byte-order mark, comma
    # between fields, every field in double quotes (a quote inside is doubled), CRLF line ends,
    # the header in $script:FleetColumns order. An existing file is never replaced (it throws).
    # Returns the full path written.
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'No path was given for the spreadsheet.' }
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (Test-Path -LiteralPath $full) { throw "The file already exists and is not overwritten: $full" }
    $dir = Split-Path -Parent $full
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) { throw "The folder does not exist: $dir" }
    $cols = @($script:FleetColumns)
    $q = { param($v) '"' + ([string]$v).Replace('"', '""') + '"' }
    $flat = [System.Collections.Generic.List[object]]::new()
    foreach ($x in @($Rows)) {
        if ($null -eq $x) { continue }
        if ($x -is [System.Collections.IDictionary] -or $x -is [System.Management.Automation.PSCustomObject]) { $flat.Add($x) }
        elseif ($x -is [System.Collections.IEnumerable] -and $x -isnot [string]) { foreach ($y in $x) { if ($null -ne $y) { $flat.Add($y) } } }
        else { $flat.Add($x) }
    }
    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.Append((@($cols | ForEach-Object { & $q $_ }) -join ',')).Append("`r`n")
    foreach ($r in $flat) {
        $cells = foreach ($c in $cols) {
            $v = $null
            if ($r -is [System.Collections.IDictionary]) { if ($r.Contains($c)) { $v = $r[$c] } }
            else { $pp = $r.PSObject.Properties[$c]; if ($pp) { $v = $pp.Value } }
            & $q $v
        }
        $null = $sb.Append(($cells -join ',')).Append("`r`n")
    }
    $enc = [System.Text.UTF8Encoding]::new($true)
    $fs = [System.IO.FileStream]::new($full, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $pre = $enc.GetPreamble(); $fs.Write($pre, 0, $pre.Length)
        $b = $enc.GetBytes($sb.ToString()); $fs.Write($b, 0, $b.Length)
    } finally { $fs.Dispose() }
    return $full
}

# The two entry points
function Invoke-FleetImport {
    # -ImportFleet: spreadsheet (csv, txt, tsv, xlsx) -> checked -> fleet file. Contacts no connector.
    $src = $ImportFleet
    foreach ($n in 'Mode','Tenant','Connector','ForceReinstall','Reapply','SkipJavaPatch','SkipDomainCheck','SshUser','SshKey','RemoteStageDir','Credential','RunAsCredential','Authentication','Parallel','ParallelTenants','ContinueOtherTenants','ExportCsv') {
        if ($script:Supplied.Contains($n)) { Say "[ignored] -$n has no effect with -ImportFleet." 'WARN' } }
    if ($Fleet -and $script:Supplied.Contains('FleetConfig')) { Say '[ignored] -Fleet: -FleetConfig names the file directly.' 'WARN' }
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { Stop-Run "Spreadsheet not found: $src" 'import' }
    $src = (Resolve-Path -LiteralPath $src).ProviderPath
    # where the fleet file goes: the same names a run would use, as a full path (the temporary file
    # is written with .NET, which does not know PowerShell's current folder)
    if ($FleetConfig) { $target = $FleetConfig; $why = '-FleetConfig' }
    elseif ($Fleet) { $target = Join-Path $script:Here "fleet.$Fleet.psd1"; $why = "-Fleet $Fleet" }
    else { $target = Join-Path $script:Here 'fleet.psd1'; $why = 'the default file' }
    $target = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($target)
    if (Test-Path -LiteralPath $target -PathType Container) { Stop-Run "-FleetConfig names a folder: $target. Name the fleet file, for example $(Join-Path $target 'fleet.psd1'). Nothing was written." 'import' }
    $tdir = Split-Path -Parent $target
    if ($tdir -and -not (Test-Path -LiteralPath $tdir -PathType Container)) { Stop-Run "The folder for the fleet file does not exist: $tdir. Nothing was written." 'import' }
    # A run without -Fleet or -FleetConfig prefers fleet.<computer>.psd1 and fleet.<domain>.psd1 to
    # fleet.psd1, so the commands shown at the end must name the file written when one of those exists.
    $shadow = @()
    if (-not $FleetConfig -and -not $Fleet) {
        $dn = $null
        if ($IsWindows) { try { $dn = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).Domain } catch { } }
        if (-not $dn) { $dn = $env:USERDNSDOMAIN }
        $shadow = @(@("fleet.$([Environment]::MachineName).psd1", $(if ($dn) { "fleet.$dn.psd1" })) | Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $script:Here $_) -PathType Leaf) })
    }
    $exists = Test-Path -LiteralPath $target -PathType Leaf
    $top = $null
    if ($exists) {
        try { $old = Import-PowerShellDataFile -LiteralPath $target } catch { Stop-Run ("The fleet file $target exists but could not be read, so it is not replaced: " + $_.Exception.Message) 'import' }
        $top = [ordered]@{}
        $oldNames = @(@($old.Tenants) | ForEach-Object { [string]$_.Name } | Where-Object { $_ })
        $oldByName = @{}; foreach ($ot in @($old.Tenants)) { if ($ot.Name) { $oldByName[[string]$ot.Name] = $ot } }
        foreach ($k in 'StagingRoot','StagingFolders','CentralLogRoot','InstallScript','JavaPatchDir') { if ($old.ContainsKey($k)) { $top[$k] = $old[$k] } }
        $drop = @($old.Keys | Where-Object { $_ -notin 'StagingRoot','StagingFolders','CentralLogRoot','InstallScript','JavaPatchDir','Tenants' })
        if ($drop.Count) { Say ("[note] The existing fleet file has setting(s) the tool does not use, which the new file leaves out: " + ($drop -join ', ')) 'WARN' }
    }
    $root = if ($top -and $top.StagingRoot) { [string]$top.StagingRoot } else { Split-Path -Parent $script:Here }
    if (-not (Test-Path -LiteralPath $root)) { $root = $null }

    $table = Read-FleetTable -Path $src
    $problems = [System.Collections.Generic.List[string]]::new(); $warnings = [System.Collections.Generic.List[string]]::new()
    foreach ($x in @($table.Problems)) { if ($x) { $problems.Add([string]$x) } }
    foreach ($x in @($table.Warnings)) { if ($x) { $warnings.Add([string]$x) } }
    $conv = $null
    if (-not $problems.Count) {
        $conv = ConvertFrom-FleetRows -Table $table -StagingRoot $root
        foreach ($x in @($conv.Problems)) { if ($x) { $problems.Add([string]$x) } }
        foreach ($x in @($conv.Warnings)) { if ($x) { $warnings.Add([string]$x) } }
    }
    $groups = @(if ($conv) { $conv.Tenants })
    $nConn = 0; foreach ($g in $groups) { $nConn += @($g.Connectors).Count }

    Write-UiSection ('IMPORT - fleet file from a spreadsheet' + $(if ($DryRun) { ' (DRY RUN)' } else { '' }))
    $line = { param([string]$Label, [string]$Value)
        foreach ($l in (Get-HangingLines -Text ('  {0,-11}: {1}' -f $Label, $Value) -Hang 15)) { Write-Host ($script:ui.Dim + $l + $script:ui.Reset) } }
    $how = [string]$table.Format; if ($table.Sheet) { $how += ", sheet '$($table.Sheet)'" + $(if ($table.SheetCount -gt 1) { " of $($table.SheetCount)" } else { '' }) }; if ($table.Delimiter) { $how += ", delimiter '" + $(if ($table.Delimiter -eq "`t") { 'tab' } else { [string]$table.Delimiter }) + "'" }; if ($table.Encoding) { $how += ", $($table.Encoding)" }
    & $line 'Spreadsheet' "$src  ($how)"
    & $line 'Fleet file' ("$target  (" + $(if ($exists) { "replaces the existing file, which is kept as a copy" } else { 'new file' }) + "; chosen by $why)")
    & $line 'Contents' ("{0} group(s), {1} connector(s)" -f $groups.Count, $nConn)
    foreach ($g in $groups) {
        Write-Host ''
        $o = Format-TenantOptions $g
        foreach ($l in (Get-HangingLines -Text ('  {0}  ({1})' -f $g.Name, ([string]$g.Services -replace 'Service(?=,|$)', '')) -Hang 4)) { Write-Host ($script:ui.Text + $l + $script:ui.Reset) }
        $files = @(foreach ($k in @(@('Installer','installer'), @('ConfigFile','config'), @('Pfx','pfx'), @('ServiceAccount','account'), @('Syslog','syslog'), @('TrustStore','trust'))) { if ($g[$k[0]]) { "$($k[1]) " + $(if ($k[0] -in 'Installer','ConfigFile','Pfx') { Split-Path ([string]$g[$k[0]]) -Leaf } else { [string]$g[$k[0]] }) } })
        if ($files.Count) { foreach ($l in (Get-HangingLines -Text ('    ' + ($files -join ' | ')) -Hang 6)) { Write-Host ($script:ui.Dim + $l + $script:ui.Reset) } }
        if ($o) { foreach ($l in (Get-HangingLines -Text ('    ' + $o) -Hang 6)) { Write-Host ($script:ui.Dim + $l + $script:ui.Reset) } }
        foreach ($c in @($g.Connectors)) { Write-Host ($script:ui.Text + '    ' + $c.Host + $(if ($c.SshUser) { "  (ssh as $($c.SshUser))" } else { '' }) + $script:ui.Reset) }
    }
    Write-UiBlank
    # files not there yet are one note, not one each
    $gapRx = '^not in the staging folder yet \(add it before a run\): '
    $gaps = @($warnings | Where-Object { $_ -match $gapRx } | ForEach-Object { $_ -replace $gapRx, '' })
    foreach ($w in @($warnings | Where-Object { $_ -notmatch $gapRx })) { Say "[note] $w" 'WARN' }
    if ($gaps.Count) { Say ("[note] Not in the staging folder yet (add them before a run):`n" + (($gaps | ForEach-Object { "  $_" }) -join "`n")) 'WARN' }
    if ($exists -and $groups.Count) {
        $gone = @($oldNames | Where-Object { $_ -notin @($groups | ForEach-Object { [string]$_.Name }) })
        if ($gone.Count) { Say ("[note] Replacing $(Split-Path -Leaf $target) removes $($gone.Count) group(s) the spreadsheet does not hold: " + ($gone -join ', ') + '. To keep them, add their rows to the sheet, or import into another file with -Fleet or -FleetConfig.') 'WARN' }
        # connectors of the current file that the sheet does not hold (a 'not reached' row deleted, say)
        $newHosts = @(foreach ($g in $groups) { foreach ($c in @($g.Connectors)) { ([string]$c.Host).ToLower() } })
        $lostHosts = @(foreach ($ot in @($old.Tenants)) { if ([string]$ot.Name -in $gone) { continue }; foreach ($c in @($ot.Connectors)) { if (([string]$c.Host).ToLower() -notin $newHosts) { "$($c.Host) ($($ot.Name))" } } })
        if ($lostHosts.Count) { Say ("[note] Replacing $(Split-Path -Leaf $target) removes $($lostHosts.Count) connector(s) the spreadsheet does not hold: " + ($lostHosts -join ', ') + '. To keep them, add their rows to the sheet.') 'WARN' }
        # settings a group has in the current file that the sheet leaves blank (ExpectVersionPrefix after
        # Discover, say); a group Discover split off as <name>-2 is compared with <name>
        foreach ($g in $groups) {
            $ot = $oldByName[[string]$g.Name]
            if (-not $ot -and [string]$g.Name -match '^(.+)-\d+$') { $ot = $oldByName[$Matches[1]] }
            if (-not $ot) { continue }
            $lost = @($ot.Keys | Where-Object { $_ -notin 'Name','Connectors' -and $null -ne $ot[$_] -and [string]$ot[$_] -ne '' -and -not ($ot[$_] -is [bool] -and -not $ot[$_]) -and -not $g.Contains($_) })
            if ($lost.Count) { Say ("[note] $($g.Name): the current fleet file sets " + ($lost -join ', ') + ', which the spreadsheet leaves blank, so the new file will not. Fill the column to keep it.') 'WARN' }
        }
    }
    if ($problems.Count) {
        Stop-Run ("The spreadsheet has $($problems.Count) problem(s). Nothing was written:`n" + (($problems | ForEach-Object { "  $_" }) -join "`n")) 'import'
    }
    if ($DryRun) {
        Say "Dry run: the spreadsheet is usable. Nothing was written. Without -DryRun this writes $target." 'OK'
        Write-AuditEntry -Outcome SUCCESS -Stage 'import-dryrun' -Rows $nConn -Detail "source=$(Split-Path $src -Leaf) target=$target"
        exit 0
    }
    if ($exists -and @($oldNames).Count -and -not $Yes) {
        $interactive = $true; try { if ([Console]::IsInputRedirected) { $interactive = $false } } catch { }
        if (-not $interactive) { Stop-Run 'Not interactive: add -Yes to confirm replacing the fleet file. Nothing was written.' 'import' }
        Write-UiWarn "This replaces $target. The current file is kept beside it as a dated copy."
        $a = Read-UiConfirm '  Type YES to continue'
        if ($a -cne 'YES') { Stop-Run 'Not confirmed. Nothing was written.' 'import' }
    }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $text = ConvertTo-FleetFileText -Tenants $groups -TopLevel $top -Source (Split-Path $src -Leaf) -Generator "$($script:Name) $($script:Version)" -Stamp (Get-Date -Format 'yyyy-MM-dd HH:mm')
    $backup = $null
    try {
        if ($exists) {
            # never replace an earlier copy (two imports in one second would otherwise share a name)
            $backup = "$target.bak-$stamp"; $n = 1
            while (Test-Path -LiteralPath $backup) { $backup = "$target.bak-$stamp-$n"; $n++ }
            [IO.File]::Copy($target, $backup, $false)
            if (-not (Test-Path -LiteralPath $backup -PathType Leaf)) { throw "the copy $backup was not made" }
        }
        # written beside the target first, then moved into place, so a failed write leaves the old file
        $tmp = "$target.importing"
        [IO.File]::WriteAllText($tmp, $text, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination $target -Force -ErrorAction Stop
    } catch { Stop-Run ("The fleet file could not be written: " + $_.Exception.Message + $(if ($backup) { ". The previous file is unchanged or kept as $backup." } else { '' })) 'import' }
    # read it back: it must mean exactly what the spreadsheet said
    $diff = @()
    try { $back = Import-PowerShellDataFile -LiteralPath $target; $diff = @(Compare-FleetData -Tenants $groups -TopLevel $top -Actual $back) }
    catch { $diff = @("it cannot be read: " + $_.Exception.Message) }
    if ($diff.Count) {
        $msg = "The written fleet file does not read back as intended: " + ($diff -join '; ')
        if ($backup) { try { Copy-Item -LiteralPath $backup -Destination $target -Force -ErrorAction Stop; $msg += ". The previous file was put back (and is still kept as $backup)." } catch { $msg += ". The previous file is kept as $backup; put it back by hand." } }
        Stop-Run $msg 'import'
    }
    Say ("Fleet file written: $target ({0} group(s), {1} connector(s))." -f $groups.Count, $nConn) 'OK'
    if ($backup) { Say "The previous fleet file is kept as $backup." }
    Write-UiText 'Next, check it against the connectors (nothing is changed), then rehearse:'
    if ($shadow.Count) { Say ("[note] A run without -Fleet or -FleetConfig uses $($shadow[0]) beside this script, not the fleet.psd1 just written. Name the file as below, or rename it.") 'WARN' }
    $fl = if ($FleetConfig -or $shadow.Count) { " -FleetConfig '$target'" } elseif ($Fleet) { " -Fleet $Fleet" } else { '' }
    Write-UiCmd "pwsh ./$($script:Name)$fl -Mode Verify"
    if ($groups.Count) { Write-UiCmd "pwsh ./$($script:Name)$fl -Tenant $($groups[0].Name) -DryRun" }
    Write-AuditEntry -Outcome SUCCESS -Stage 'import' -Rows $nConn -Detail ("source=$(Split-Path $src -Leaf) target=$target" + $(if ($backup) { " backup=$(Split-Path $backup -Leaf)" } else { '' }))
    exit 0
}

function Invoke-FleetDiscover { param([string]$FleetFile, [string]$FleetWhy)
    # -Mode Discover: read existing connectors' settings over SSH into a draft spreadsheet. Read-only:
    # nothing is copied to or changed on the connectors.
    foreach ($exe in 'ssh') { if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { Stop-Run "$exe was not found on the PATH." 'precheck' } }
    if ($SshKey -and -not (Test-Path -LiteralPath $SshKey)) { Stop-Run "SSH key not found: $SshKey" 'precheck' }
    $allEntries = @($script:FleetData.Tenants)
    $entries = $allEntries
    if ($Tenant -and $Connector) { Say '[ignored] -Tenant: -Connector names the hosts to read. Each is still matched with its fleet entry, whatever group it is in.' 'WARN' }
    elseif ($Tenant) {
        $unknown = @($Tenant | Where-Object { $_ -notin $entries.Name }); if ($unknown) { Stop-Run ("Unknown tenant(s): " + ($unknown -join ', ')) 'fleet' }
        $entries = @($entries | Where-Object { $_.Name -in $Tenant })
    }
    # host -> fleet entry and connector (any entry), for the Group name and the comparison
    $known = @{}
    foreach ($t in $allEntries) { foreach ($c in @($t.Connectors)) { if (-not $known.ContainsKey(([string]$c.Host).ToLower())) { $known[([string]$c.Host).ToLower()] = @{ Entry = $t; Conn = $c } } } }
    $targets = [System.Collections.Generic.List[object]]::new()
    if ($Connector) { foreach ($h in $Connector) { $k = $known[$h.ToLower()]; $targets.Add([pscustomobject]@{ Host = $h; Entry = $(if ($k) { $k.Entry } else { $null }); FleetUser = $(if ($k) { [string]$k.Conn.SshUser } else { '' }) }) } }
    else { foreach ($t in $entries) { foreach ($c in @($t.Connectors)) { $targets.Add([pscustomobject]@{ Host = [string]$c.Host; Entry = $t; FleetUser = [string]$c.SshUser }) } } }
    if (-not $targets.Count) { Stop-Run 'No connectors to discover. Name them with -Connector, or check -Tenant against the fleet file.' 'fleet' }
    $draftName = "fleet.discovered_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss')
    if ($ExportCsv) {
        $out = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ExportCsv)
        # a folder (existing, or written with a trailing slash) gets a dated file name in it
        if ((Test-Path -LiteralPath $out -PathType Container) -or $ExportCsv.EndsWith('/') -or $ExportCsv.EndsWith('\') -or (-not (Test-Path -LiteralPath $out) -and -not [IO.Path]::GetExtension($out))) { $out = Join-Path $out $draftName }
    }
    else { $out = Join-Path $script:Here $draftName }
    if (Test-Path -LiteralPath $out) { Stop-Run "The output file already exists and is not overwritten: $out. Name another with -ExportCsv." 'discover' }
    $od = Split-Path -Parent $out
    if ($od -and -not (Test-Path -LiteralPath $od -PathType Container)) {
        try { $null = New-Item -ItemType Directory -Path $od -Force -ErrorAction Stop } catch { Stop-Run "The folder for the draft spreadsheet could not be made: $od ($($_.Exception.Message)). Nothing was read." 'discover' } }

    Write-UiSection 'PLAN - mode Discover (read-only)'
    $line = { param([string]$Label, [string]$Value)
        foreach ($l in (Get-HangingLines -Text ('  {0,-10}: {1}' -f $Label, $Value) -Hang 14)) { Write-Host ($script:ui.Dim + $l + $script:ui.Reset) } }
    & $line 'Fleet file' $(if ($FleetFile) { "$(Split-Path $FleetFile -Leaf)  (chosen by $FleetWhy)" } else { $FleetWhy })
    & $line 'Reads' 'version, services, service account, syslog, ports, proxy, install folder, FIPS mode, tenant and the Kerberos certificate served. Nothing is copied to or changed on the connectors.'
    & $line 'Writes' $out
    Write-Host ''
    foreach ($x in $targets) { Write-Host ($script:ui.Text + ('  {0,-14} {1}' -f $(if ($x.Entry) { $x.Entry.Name } else { '(new)' }), $x.Host) + $script:ui.Reset) }
    Write-UiBlank

    $results = [System.Collections.Generic.List[object]]::new(); $bad = 0
    foreach ($x in $targets) {
        $u = if ($SshUser) { $SshUser } elseif ($x.FleetUser) { $x.FleetUser } else { 'administrator' }
        $r = Invoke-ConnectorDiscovery -Conn ([pscustomobject]@{ Host = $x.Host; SshUser = $u })
        $results.Add([pscustomobject]@{ Host = $x.Host; SshUser = $(if ($SshUser) { $SshUser } else { $x.FleetUser }); Ok = $r.Ok; Data = $r.Data; Error = $r.Error; Entry = $x.Entry })
        if ($r.Ok -and $r.Data) {
            $d = $r.Data
            $svc = @(@($d.Services) | ForEach-Object { ([string]$_.Key) -replace 'Service$', '' }) -join ','
            $tenantHost = ''; try { if ($d.Properties.TENANT_URL) { $tenantHost = ([uri][string]$d.Properties.TENANT_URL).Host } } catch { }
            $acct = [string]$d.Registry.IS_NET_API_LOGON_USERNAME
            $parts = @(if ($d.InstalledVersion) { "v$($d.InstalledVersion)" }; if ($svc) { $svc } else { 'no Access Connector found' })
            if ($tenantHost) { $parts += "tenant $tenantHost" }; if ($acct) { $parts += "account $acct" }
            $errs = @(@($d.Errors) | Where-Object { $_ })
            if ($errs.Count) { Say ("{0}`n{1}`nnot read: {2}" -f $x.Host, ($parts -join ' | '), ($errs -join ' / ')) 'WARN' }
            else { Say ("{0}`n{1}" -f $x.Host, ($parts -join ' | ')) 'OK' }
        } else {
            $bad++
            $why = if ($r.Error) { [string]$r.Error } else { 'no result' }
            Write-ErrorEntry (Add-SshHint "$($x.Host): not reached: $why" (Get-SshHint -Reason $why -User $u -HostName $x.Host -KeyFile $SshKey)) 'discover'
        }
    }
    $root = $script:StagingRoot
    $rows = @(ConvertTo-DiscoveredRows -Results $results -StagingRoot $root -SshUser $SshUser)
    # the fleet file in use already names the patch folder: that note has nothing to ask
    if ($script:FleetData.JavaPatchDir) { foreach ($rw in $rows) { $rw['Notes'] = ((@(([string]$rw['Notes']) -split '; ') | Where-Object { $_ -notlike 'Java4Shell patch flag present*' }) -join '; ') } }
    try { $null = Export-DiscoveredCsv -Rows $rows -Path $out } catch { Stop-Run ("The spreadsheet could not be written: " + $_.Exception.Message) 'discover' }
    $todo = @($rows | Where-Object { -not $_['Group'] -or [string]$_['Notes'] -match '(^|; )fill: ' }).Count
    Write-UiSection 'DRAFT SPREADSHEET'
    Write-UiText "Written: $out"
    Write-UiText ("{0} row(s); {1} need values filled in (see the Notes column). It holds site details but no passwords: keep it out of version control and share it as you would the fleet file." -f $rows.Count, $todo)
    Write-UiText 'Next: open it in Excel, fill the blanks (Installer, ConfigFile and Pfx when they could not be matched), check the Group names, then check it and write the fleet file:'
    $shown = if ((Split-Path -Parent $out) -eq $script:Here) { './' + (Split-Path -Leaf $out) } else { $out }
    if ($shown -match '\s') { $shown = "'$shown'" }
    # write back into the fleet file the hosts came from
    $readHosts = @($targets | ForEach-Object { ([string]$_.Host).ToLower() })
    $leftOut = @(foreach ($t in $allEntries) { foreach ($c in @($t.Connectors)) { if (([string]$c.Host).ToLower() -notin $readHosts) { $c.Host } } })
    $partial = $FleetFile -and $leftOut.Count
    if ($partial) {
        # only some of the fleet file was read: importing into it would drop every group not in the
        # draft. So the draft goes to a new file, started here with the original's top-level settings
        # (staging root, patch folder ...) and no groups; the import carries those settings over.
        $srcFull = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($FleetFile)
        $newFile = Join-Path (Split-Path -Parent $srcFull) ("fleet.discovered_{0}.psd1" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        $topKeys = [ordered]@{}; foreach ($k in 'StagingRoot','StagingFolders','CentralLogRoot','InstallScript','JavaPatchDir') { if ($script:FleetData.ContainsKey($k)) { $topKeys[$k] = $script:FleetData[$k] } }
        try {
            $skel = ConvertTo-FleetFileText -Tenants @() -TopLevel $topKeys -Source (Split-Path -Leaf $srcFull) -Generator "$($script:Name) $($script:Version)" -Stamp (Get-Date -Format 'yyyy-MM-dd HH:mm')
            [IO.File]::WriteAllText($newFile, $skel, [Text.UTF8Encoding]::new($false))
            $null = Import-PowerShellDataFile -LiteralPath $newFile
        } catch { Stop-Run ("The new fleet file for this draft could not be started: $newFile ($($_.Exception.Message)). The draft is written: $out") 'discover' }
        Write-UiWarn ("Only part of $(Split-Path -Leaf $FleetFile) was read ($($leftOut.Count) of its connectors left out), so the commands below import this draft into a new fleet file, $(Split-Path -Leaf $newFile), which holds the original's top-level settings and no groups yet. Importing it into $(Split-Path -Leaf $FleetFile) would replace that whole file and drop the groups the draft does not hold.")
        $fl = " -FleetConfig '$newFile'"
    }
    elseif ($Fleet -and -not $script:Supplied.Contains('FleetConfig')) { $fl = " -Fleet $Fleet" }
    elseif ($FleetFile) { $fl = " -FleetConfig '$($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($FleetFile))'" }
    else { $fl = '' }
    Write-UiCmd "pwsh ./$($script:Name) -ImportFleet $shown$fl -DryRun"
    Write-UiCmd "pwsh ./$($script:Name) -ImportFleet $shown$fl"
    Write-AuditEntry -Outcome $(if ($bad) { 'FAILED' } else { 'SUCCESS' }) -Stage 'discover' -Rows $targets.Count -Detail ("notReached=$bad output=$(Split-Path $out -Leaf)")
    exit ([int]($bad -gt 0))
}

# ====================================================================== main
Initialize-UiStyle
Show-LaunchNotice
# PowerShell 7 or later, before anything else (help included). Windows PowerShell 5.1 lacks what
# this script uses to run ssh and to tell the platforms apart.
if ($PSVersionTable.PSVersion.Major -lt 7) { Stop-Run ("This script needs PowerShell 7 or later (pwsh). It was started in PowerShell $($PSVersionTable.PSVersion). Install PowerShell 7 and run it with pwsh, for example: pwsh -File .\$($script:Name) -Help") 'precheck' }
if ($Help) { Show-Help; return }

$script:Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:AuditPath = Resolve-LogPath -Value $AuditLog -DefaultName 'connector-fleet-audit.log'
$script:ErrorPath = Resolve-LogPath -Value $ErrorLog -DefaultName 'connector-fleet-errors.log'
$script:HashCache = @{}

# A spreadsheet to turn into a fleet file: no connector is contacted, nothing else runs.
if ($script:Supplied.Contains('ImportFleet')) {
    if ([string]::IsNullOrWhiteSpace($ImportFleet)) { Stop-Run '-ImportFleet needs the name of a spreadsheet file (.xlsx, .csv, .txt or .tsv).' 'import' }
    Invoke-FleetImport
}
if ($script:Supplied.Contains('ExportCsv') -and [string]::IsNullOrWhiteSpace($ExportCsv)) { Stop-Run '-ExportCsv needs a file name.' 'precheck' }

$fleetWhy = '-FleetConfig'
if (-not $FleetConfig) {
    $cands = [System.Collections.Generic.List[object]]::new()
    if ($Fleet) { $cands.Add(@("fleet.$Fleet.psd1", "-Fleet $Fleet")) }
    else {
        $hn = [Environment]::MachineName
        $dn = $null
        if ($IsWindows) { try { $dn = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).Domain } catch { } }
        if (-not $dn) { $dn = $env:USERDNSDOMAIN }
        $cands.Add(@("fleet.$hn.psd1", "this computer's name, $hn"))
        if ($dn) { $cands.Add(@("fleet.$dn.psd1", "this computer's domain, $dn")) }
        $cands.Add(@('fleet.psd1', 'the default file'))
    }
    foreach ($c in $cands) { $fp = Join-Path $script:Here $c[0]; if (Test-Path -LiteralPath $fp -PathType Leaf) { $FleetConfig = $fp; $fleetWhy = $c[1]; break } }
    # Discovery of hosts named with -Connector needs no fleet file yet: it is how a first one is made.
    if (-not $FleetConfig -and -not ($Mode -eq 'Discover' -and $Connector -and -not $Fleet)) { Stop-Run ("No fleet file found in $($script:Here). Looked for: " + (($cands | ForEach-Object { $_[0] }) -join ', ')) 'precheck' }
}
if ($FleetConfig -and -not (Test-Path -LiteralPath $FleetConfig -PathType Leaf)) { Stop-Run "Fleet file not found: $FleetConfig" 'precheck' }

# ---- switch dependencies and conflicts (silent when clean)
$warn = [System.Collections.Generic.List[string]]::new()
if ($Mode -notin 'WinRM','RepairKeytab') { foreach ($n in 'Credential','Authentication') { if ($script:Supplied.Contains($n)) { $warn.Add("[ignored] -$n applies only to -Mode WinRM.") } } }
if ($Mode -ne 'RepairCertificate' -and $script:Supplied.Contains('Reapply')) { $warn.Add('[ignored] -Reapply applies only to -Mode RepairCertificate.') }
if ($Mode -eq 'RepairCertificate') { foreach ($n in 'ForceReinstall','SkipJavaPatch','SkipDomainCheck','Parallel','ParallelTenants','RunAsCredential') { if ($script:Supplied.Contains($n)) { $warn.Add("[ignored] -$n has no effect with -Mode RepairCertificate.") } } }
if ($Mode -eq 'RepairKeytab') { foreach ($n in 'ForceReinstall','SkipJavaPatch','SkipDomainCheck','Parallel','ParallelTenants','Credential','Authentication') { if ($script:Supplied.Contains($n)) { $warn.Add("[ignored] -$n has no effect with -Mode RepairKeytab.") } } }
if ($Mode -eq 'WinRM')  { foreach ($n in 'SshUser','SshKey') { if ($script:Supplied.Contains($n)) { $warn.Add("[ignored] -$n applies only to SSH, Stage and Verify modes.") } } }
if ($Mode -in 'Verify','Stage') { if ($script:Supplied.Contains('RunAsCredential')) { $warn.Add("[ignored] -RunAsCredential has no effect with -Mode $Mode.") } }
if ($SkipDomainCheck -and $script:Supplied.Contains('RunAsCredential')) { $warn.Add('[ignored] -RunAsCredential: -SkipDomainCheck upgrades from the remote sign-in directly.') }
if ($Mode -eq 'Verify') { foreach ($n in 'DryRun','ForceReinstall','SkipJavaPatch','SkipDomainCheck','Yes','ContinueOtherTenants') { if ($script:Supplied.Contains($n)) { $warn.Add("[ignored] -$n has no effect with -Mode Verify.") } } }
if ($Mode -eq 'Stage')  { foreach ($n in 'Yes','ContinueOtherTenants') { if ($script:Supplied.Contains($n)) { $warn.Add("[ignored] -$n has no effect with -Mode Stage.") } }
    if ($DryRun) { $warn.Add('[note] -DryRun with -Mode Stage writes a dry-run job; Run-Upgrade.cmd will then only pre-flight.') } }
if ($Mode -in 'Verify','Stage') { foreach ($n in 'Parallel','ParallelTenants') { if ($script:Supplied.Contains($n)) { $warn.Add("[ignored] -$n has no effect with -Mode $Mode.") } } }
if ($Fleet -and $script:Supplied.Contains('FleetConfig')) { $warn.Add('[ignored] -Fleet: -FleetConfig names the file directly.') }
if ($Parallel -and $ParallelTenants) { $warn.Add('[ignored] -ParallelTenants: -Parallel already runs every selected connector at once.') }
if ($Parallel -and $ContinueOtherTenants) { $warn.Add('[ignored] -ContinueOtherTenants: with -Parallel everything starts together, so there is nothing left to stop; a WinRM sign-in that a connector refuses stops every connector not yet started.') }
if ($DryRun -and $ForceReinstall) { $warn.Add('[note] -ForceReinstall with -DryRun only changes the planned action shown; nothing is uninstalled.') }
if ($Mode -eq 'Discover') { foreach ($n in 'DryRun','ForceReinstall','SkipJavaPatch','SkipDomainCheck','Yes','ContinueOtherTenants','Parallel','ParallelTenants','RunAsCredential','RemoteStageDir') { if ($script:Supplied.Contains($n)) { $warn.Add("[ignored] -$n has no effect with -Mode Discover.") } } }
if ($Mode -ne 'Discover' -and $script:Supplied.Contains('ExportCsv')) { $warn.Add('[ignored] -ExportCsv applies only to -Mode Discover.') }
if ($SkipJavaPatch -and -not $DryRun -and $Mode -notin 'Verify','Discover') { $warn.Add('[note] -SkipJavaPatch: an upgrade may reset the service XML files, leaving the connector without the Java4Shell patch.') }
foreach ($w in $warn) { Say $w 'WARN' }

# ---- load and validate the fleet
if ($FleetConfig) { try { $script:FleetData = Import-PowerShellDataFile -LiteralPath $FleetConfig } catch { Stop-Run ("Fleet file could not be read: " + $_.Exception.Message) 'fleet' } }
else { $script:FleetData = @{ Tenants = @() }; $fleetWhy = 'none: hosts named with -Connector' }
$script:StagingRoot = if ($script:FleetData.StagingRoot) { $script:FleetData.StagingRoot } else { Split-Path -Parent $script:Here }
$centralLog = if ($script:FleetData.CentralLogRoot) { $script:FleetData.CentralLogRoot } else { Join-Path $script:Here 'FleetLogs' }
if (-not [IO.Path]::IsPathRooted($centralLog) -and $centralLog -notmatch '^\\\\') { $centralLog = Join-Path $script:StagingRoot $centralLog }
if (-not (Test-Path -LiteralPath $script:StagingRoot)) { Stop-Run "Staging root not found: $($script:StagingRoot)" 'fleet' }

# Read the settings of existing connectors into a draft spreadsheet; nothing else runs.
if ($Mode -eq 'Discover') { Invoke-FleetDiscover -FleetFile $FleetConfig -FleetWhy $fleetWhy }

$tenants = @($script:FleetData.Tenants)
if ($Tenant) { $unknown = @($Tenant | Where-Object { $_ -notin $tenants.Name }); if ($unknown) { Stop-Run ("Unknown tenant(s): " + ($unknown -join ', ')) 'fleet' }
    $tenants = @($tenants | Where-Object { $_.Name -in $Tenant }) }
$plan = [System.Collections.Generic.List[object]]::new()
foreach ($t in $tenants) {
    foreach ($c in @($t.Connectors)) {
        if ($Connector -and $c.Host -notin $Connector) { continue }
        $u = if ($SshUser) { $SshUser } elseif ($c.SshUser) { $c.SshUser } else { 'administrator' }
        $plan.Add([pscustomobject]@{ Tenant = $t; Host = $c.Host; SshUser = $u })
    }
}
# One entry per selected tenant, in fleet order. (Select-Object -Unique cannot compare hashtables.)
$planTenants = [System.Collections.Generic.List[object]]::new()
foreach ($x in $plan) { if ($planTenants.Name -notcontains $x.Tenant.Name) { $planTenants.Add($x.Tenant) } }
if ($Mode -eq 'RepairKeytab') {
    # only connectors that have the Kerberos service
    $skipped = @($planTenants | Where-Object { $_.Services -notmatch 'KerberosAuthService' } | ForEach-Object { $_.Name })
    if ($skipped.Count) { Say ("[note] No Kerberos service, left out: " + ($skipped -join ', ')) 'WARN' }
    $keep = @($plan | Where-Object { $_.Tenant.Services -match 'KerberosAuthService' })
    $plan.Clear(); foreach ($x in $keep) { $plan.Add($x) }
    $keepT = @($planTenants | Where-Object { $_.Services -match 'KerberosAuthService' })
    $planTenants.Clear(); foreach ($x in $keepT) { $planTenants.Add($x) }
    if (-not (Test-Path -LiteralPath (Join-Path $script:Here 'Invoke-ConnectorUpgradeLocal.ps1'))) { Stop-Run 'Invoke-ConnectorUpgradeLocal.ps1 was not found beside this script.' 'fleet' }
}
if ($Mode -eq 'RepairCertificate') {
    # only connectors that have the Kerberos service and a PFX to put on it
    $want = { param($t) ($t.Services -match 'KerberosAuthService') -and $t.Pfx }
    $skipped = @($planTenants | Where-Object { -not (& $want $_) } | ForEach-Object { $_.Name })
    if ($skipped.Count) { Say ("[note] No Kerberos service or no Pfx in the fleet file, left out: " + ($skipped -join ', ')) 'WARN' }
    $keep = @($plan | Where-Object { & $want $_.Tenant })
    $plan.Clear(); foreach ($x in $keep) { $plan.Add($x) }
    $keepT = @($planTenants | Where-Object { & $want $_ })
    $planTenants.Clear(); foreach ($x in $keepT) { $planTenants.Add($x) }
    if (-not (Test-Path -LiteralPath (Join-Path $script:Here 'Invoke-ConnectorUpgradeLocal.ps1'))) { Stop-Run 'Invoke-ConnectorUpgradeLocal.ps1 was not found beside this script.' 'fleet' }
    foreach ($t in $planTenants) { if ((Split-Path ([string]$t.Pfx) -Leaf) -notmatch '^[A-Za-z0-9._-]+$') { Stop-Run "The PFX file name for $($t.Name) may hold only letters, digits, dot, dash and underscore for this mode." 'fleet' } }
}
if ($plan.Count -eq 0) { Stop-Run 'No connectors selected. Check -Tenant / -Connector against the fleet file.' 'fleet' }
# A misspelt setting would otherwise be dropped without a word (a proxy that is never set, say).
foreach ($t in $planTenants) {
    $odd = @($t.Keys | Where-Object { $_ -notin $script:TenantKeys })
    if ($odd.Count) { Say "[note] $($t.Name): unknown fleet setting(s) ignored: $($odd -join ', '). Check the spelling against docs/Fleet-File-Reference.md." 'WARN' }
}
if ($Mode -in 'SSH','WinRM','Stage') {
    $optBad = @(foreach ($t in $planTenants) { Get-TenantOptionProblems $t | ForEach-Object { $_ } })
    if ($optBad.Count) { Stop-Run ("Fleet file settings are not valid. Nothing was contacted:`n" + (($optBad | ForEach-Object { "  $_" }) -join "`n")) 'fleet' }
}

if ($Mode -notin 'Verify','RepairKeytab') {
    $missing = [System.Collections.Generic.List[string]]::new()
    $certOnly = ($Mode -eq 'RepairCertificate')
    if ($certOnly) { }
    elseif (-not $script:FleetData.InstallScript -or -not (Test-Path -LiteralPath (Join-Path $script:StagingRoot $script:FleetData.InstallScript))) { $missing.Add("InstallScript: $($script:FleetData.InstallScript)") }
    if (-not (Test-Path -LiteralPath (Join-Path $script:Here 'Invoke-ConnectorUpgradeLocal.ps1'))) { $missing.Add('Invoke-ConnectorUpgradeLocal.ps1 (beside this script)') }
    if (-not $certOnly -and -not $SkipJavaPatch -and $script:FleetData.JavaPatchDir -and -not (Test-Path -LiteralPath (Join-Path $script:StagingRoot $script:FleetData.JavaPatchDir 'Java4shellPatch.bat'))) { $missing.Add("JavaPatchDir: $($script:FleetData.JavaPatchDir)\Java4shellPatch.bat") }
    $shared = $missing.Count      # items every tenant needs
    $short = [System.Collections.Generic.List[object]]::new()
    foreach ($t in $planTenants) {
        $gaps = @(Get-StagingGaps -Root $script:StagingRoot -T $t)
        if ($certOnly) { $gaps = @($gaps | Where-Object { $_ -like "$($t.Name) Pfx:*" }) }
        if ($gaps.Count) { $short.Add($t); foreach ($g in $gaps) { $missing.Add($g) } }
        if (-not $certOnly -and (-not $t.Installer -or -not $t.ConfigFile -or -not $t.Services)) { $missing.Add("$($t.Name): Installer, ConfigFile and Services are required") }
        if (($t.Services -match 'KerberosAuthService') -and -not $t.Pfx) { Say "[note] $($t.Name) installs KerberosAuthService without a Pfx; the installer will use a self-signed certificate." 'WARN' }
    }
    if ($missing.Count) {
        $msg = "Files this run needs are missing under $($script:StagingRoot):`n" + (($missing | ForEach-Object { "  $_" }) -join "`n")
        Write-ErrorEntry $msg 'fleet'
        Write-AuditEntry -Outcome FAILED -Stage 'fleet' -Detail ("Files this run needs are missing under $($script:StagingRoot): " + ($missing -join ' | '))
        # Another copy of this folder may hold them (each share has its own). Say which, and how to get there.
        $byRoot = [ordered]@{}
        foreach ($t in $(if ($shared) { @($planTenants) } else { @($short) })) {
            $alt = Find-StagedCopy -T $t
            if ($alt) { if (-not $byRoot.Contains($alt)) { $byRoot[$alt] = [System.Collections.Generic.List[string]]::new() }; $byRoot[$alt].Add([string]$t.Name) }
        }
        foreach ($alt in @($byRoot.Keys)) {
            $names = $byRoot[$alt] -join ', '
            $dir = Join-Path $alt (Split-Path $script:Here -Leaf)
            Write-Host ''
            if ((Test-Path -LiteralPath (Join-Path $dir $script:Name) -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $dir 'Invoke-ConnectorUpgradeLocal.ps1') -PathType Leaf)) {
                # does that copy also hold the files of the other tenants in this run?
                $rest = @($planTenants | Where-Object { $_.Name -notin $byRoot[$alt] -and @(Get-StagingGaps -Root $alt -T $_).Count })
                if ($rest.Count) { Write-UiText "Everything $names needs is in another copy of this folder. Run it from there for $(if ($byRoot[$alt].Count -gt 1) { 'those tenants' } else { 'that tenant' }) only (-Tenant $($byRoot[$alt] -join ',')):" }
                else { Write-UiText "Everything $names needs is in another copy of this folder. Run the same command from there:" }
                Write-Host ''
                Write-UiCmd ('cd ' + $(if ($dir -match '\s') { "'" + $dir + "'" } else { $dir }))
            } else {
                Write-UiText "Everything $names needs is under this folder instead:"
                Write-Host ''
                Write-UiCmd $alt
            }
        }
        if ($byRoot.Count) { Write-Host '' }
        exit 1
    }
}
if ($Mode -in 'SSH','Stage','Verify','RepairKeytab','RepairCertificate') {
    foreach ($exe in 'ssh','scp') { if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { Stop-Run "$exe was not found on the PATH." 'precheck' } }
    if ($SshKey -and -not (Test-Path -LiteralPath $SshKey)) { Stop-Run "SSH key not found: $SshKey" 'precheck' }
}
if ($Mode -eq 'WinRM' -and -not $IsWindows) { Stop-Run '-Mode WinRM needs Windows. Use -Mode SSH from this system.' 'precheck' }
if (($Mode -in 'SSH','WinRM') -and ($plan.Tenant.Services -match 'KerberosAuthService')) {
    if ($SkipDomainCheck) { Say '[note] -SkipDomainCheck: Kerberos connectors will be upgraded even if the keytab cannot be rebuilt. Run setupKerberos.ps1 on each one afterwards, signed in as a domain admin.' 'WARN' }
    elseif (-not ($Mode -eq 'WinRM' -and $Authentication -eq 'CredSSP')) { Say 'Kerberos connectors selected: on each one the upgrade runs as a one-time scheduled task under a domain admin account, so the Kerberos keytab can be rebuilt.' } }

# ---- show the plan
Write-UiSection ("PLAN - mode $Mode" + $(if ($DryRun) { ' (DRY RUN)' } else { '' }))
$planLine = { param([string]$Label, [string]$Value)
    foreach ($l in (Get-HangingLines -Text ('  {0,-10}: {1}' -f $Label, $Value) -Hang 14)) { Write-Host ($script:ui.Dim + $l + $script:ui.Reset) } }
& $planLine 'Fleet file' "$(Split-Path $FleetConfig -Leaf)  (chosen by $fleetWhy)"
if ($Mode -in 'SSH','WinRM') { & $planLine 'Order' $(if ($Parallel) { 'all selected connectors at the same time (-Parallel)' } elseif ($ParallelTenants) { 'tenants side by side, one connector at a time in each (-ParallelTenants)' } else { 'one connector at a time' }) }
# What is done to each connector: said once when it is the same for all of them.
$doing = @(foreach ($x in $plan) {
    if ($Mode -eq 'RepairKeytab') { $(if ($DryRun) { 'keytab check only' } else { 'keytab repair (only where it is empty)' }) }
    elseif ($Mode -eq 'RepairCertificate') { $(if ($DryRun) { 'check only: ' } else { 'Kerberos certificate from ' }) + [string](Split-Path ([string]$x.Tenant.Pfx) -Leaf) }
    elseif ($Mode -eq 'Verify') { '' } else { [string](Split-Path ([string]$x.Tenant.Installer) -Leaf) } })
$same = @($doing | Select-Object -Unique)
if ($same.Count -eq 1 -and $same[0]) { & $planLine $(if ($Mode -in 'RepairKeytab','RepairCertificate') { 'Action' } else { 'Installer' }) $same[0] }
if ($Mode -in 'SSH','WinRM','Stage') {
    foreach ($t in $planTenants) { $o = Format-TenantOptions $t; if ($o) { & $planLine 'Settings' "$($t.Name): $o" } }
}
Write-Host ''
for ($i = 0; $i -lt $plan.Count; $i++) {
    $x = $plan[$i]
    $row = '  {0,-14} {1}' -f $x.Tenant.Name, $x.Host
    if ($same.Count -gt 1 -and $doing[$i]) { $row = '  {0,-14} {1,-30} {2}' -f $x.Tenant.Name, $x.Host, $doing[$i] }
    foreach ($l in (Get-HangingLines -Text $row -Hang 17)) { Write-Host ($script:ui.Text + $l + $script:ui.Reset) } }
Write-UiBlank

# =================================================================== VERIFY
if ($Mode -eq 'Verify') {
    $bad = 0; $redCount = 0
    foreach ($x in $plan) {
        try {
            Send-PayloadSsh -Conn $x -T $x.Tenant -RunnerOnly
            $r = Invoke-SshRunner -Conn $x -RunnerArgs '-VerifyOnly' -StdinLines @()
            if ($r.Result) {
                # Red when a service is not running, the keytab is empty or missing, or (with a
                # Pfx) the certificate is wrong; yellow when nothing is installed or a Java process
                # lacks the patch flag; green otherwise. A red line makes the exit code 1.
                $vs = $r.Result.State
                $v = Get-VerifyVerdict -State $vs -HasPfx ([bool]$x.Tenant.Pfx)
                Say ("{0,-14} {1}`n{2}" -f $x.Tenant.Name, $x.Host, (Format-State $vs)) $v.Level
                if ($v.Level -eq 'ERROR') { $redCount++; Write-ErrorEntry ("$($x.Host) ($($x.Tenant.Name)): red in Verify: " + (@($v.Red) -join '; ')) 'verify' -LogOnly }
            } else { $bad++; Write-ErrorEntry "$($x.Host): no result returned" 'verify' }
        } catch { $bad++; Write-ErrorEntry "$($x.Host): $($_.Exception.Message)" 'verify' $_ }
    }
    Write-AuditEntry -Outcome $(if ($bad -or $redCount) { 'FAILED' } else { 'SUCCESS' }) -Stage 'verify' -Rows $plan.Count -Detail "notRead=$bad red=$redCount"
    exit ([int](($bad + $redCount) -gt 0))
}

# ==================================================================== STAGE
if ($Mode -eq 'Stage') {
    $bad = 0
    foreach ($x in $plan) {
        try { Send-PayloadSsh -Conn $x -T $x.Tenant; Say "$($x.Host): staged in $RemoteStageDir" 'OK' }
        catch { $bad++; Write-ErrorEntry "$($x.Host): $($_.Exception.Message)" 'stage' $_ }
    }
    Write-UiSection 'NEXT STEPS ON EACH CONNECTOR'
    Write-UiText 'Sign in as a domain admin, one connector at a time per tenant, and run:'
    Write-UiCmd "$RemoteStageDir\Run-Upgrade.cmd"
    Write-UiText 'or, to schedule it under your signed-in account:'
    Write-UiCmd "powershell -ExecutionPolicy Bypass -File $RemoteStageDir\Invoke-ConnectorUpgradeLocal.ps1 -Prompt -Schedule `"yyyy-MM-dd HH:mm`""
    Write-UiText 'Afterwards check every connector with: -Mode Verify'
    Write-AuditEntry -Outcome $(if ($bad) { 'FAILED' } else { 'SUCCESS' }) -Stage 'stage' -Rows $plan.Count
    exit ([int]($bad -gt 0))
}

# ========================================================== SSH / WinRM run
# SSH sign-in check, before YES and before any password or account is asked: a run that cannot
# sign in to a connector stops here, with ssh's own reason and a hint, with nothing typed or changed.
if (Test-SshSignInCheckNeeded $Mode) {
    Say "Checking the SSH sign-in on $($plan.Count) connector(s)..."
    $signInBad = [System.Collections.Generic.List[string]]::new(); $signInGood = [System.Collections.Generic.List[string]]::new()
    foreach ($x in $plan) {
        $r = Invoke-SshPs -Conn $x -ScriptText "'signin-ok'" -TimeoutSec 120
        if ($r.ExitCode -eq 0 -and ($r.Lines -contains 'signin-ok')) { if (-not $signInGood.Contains([string]$x.Host)) { $signInGood.Add([string]$x.Host) }; continue }
        $signInBad.Add([string]$x.Host)
        Write-ErrorEntry (Get-SshStepError -Conn $x -Result $r -What 'run Windows PowerShell there' -KeyFile $SshKey) 'signin'
    }
    if ($signInBad.Count) {
        $others = @($signInGood | Where-Object { $_ -notin $signInBad })
        Stop-Run ("The SSH sign-in check failed on $($signInBad.Count) of $($plan.Count) connector(s): $($signInBad -join ', '). Nothing was changed and no password was asked. Fix the sign-in and run again, or leave those connectors out with -Connector" + $(if ($others.Count) { " (for the others: -Connector $($others -join ','))." } else { '.' })) 'signin'
    }
    Say "SSH sign-in checked on $($plan.Count) connector(s)." 'OK'
}
$interactive = $true
try { if ([Console]::IsInputRedirected) { $interactive = $false } } catch { }
if (-not $DryRun -and -not $Yes) {
    if (-not $interactive) { Stop-Run 'Not interactive: add -Yes to confirm changing the connectors.' 'confirm' }
    if ($Mode -eq 'RepairKeytab') { Write-UiWarn 'On each connector the Kerberos AD account password is reset and a new keytab is written. Kerberos sign-in through that connector stops for about a minute while its service restarts.' }
    elseif ($Mode -eq 'RepairCertificate') { Write-UiWarn 'On each connector the Kerberos Auth service is stopped, given the certificate from the PFX and started again. Kerberos sign-in through that connector stops for a few minutes. The other services keep running.' }
    else { Write-UiWarn 'Each connector''s services stop for roughly 10 minutes while it upgrades.' }
    if ($Parallel -and $Mode -notin 'RepairKeytab','RepairCertificate') { Write-UiWarn '-Parallel: ALL selected connectors upgrade at the same time. Each tenant is fully offline until its connectors finish, and one failure cannot stop the others.' }
    $a = Read-UiConfirm '  Type YES to continue'
    if ($a -cne 'YES') { Stop-Run 'Not confirmed. Nothing was changed.' 'confirm' }
}

# secrets, once per tenant
$secrets = @{}; $creds = @{}; $runAs = @{}
foreach ($t in $planTenants) {
    Write-UiBlank
    $s = @{}
    if ($Mode -eq 'RepairCertificate') {
        Write-Host ($script:ui.Prompt + "  Password for tenant $($t.Name):" + $script:ui.Reset)
        $s = @{ Pfx = Read-UiSecret "    Kerberos PFX password ($(Split-Path $t.Pfx -Leaf))" }
        Register-Secret (ConvertTo-PlainText $s.Pfx)
        if ($s.Pfx.Length -eq 0) { Stop-Run "Empty Kerberos PFX password for $($t.Name). Nothing was changed." 'secrets' }
    }
    elseif ($Mode -ne 'RepairKeytab') {
        Write-Host ($script:ui.Prompt + "  Passwords for tenant $($t.Name):" + $script:ui.Reset)
        $s = @{ Cfg = Read-UiSecret '    Configuration file (es-config) password' }
        if ($t.Pfx) { $s.Pfx = Read-UiSecret "    Kerberos PFX password ($(Split-Path $t.Pfx -Leaf))" }
        if ($t.ServiceAccount -and ($t.Services -match 'KerberosAuthService|VirtualAppService')) { $s.Svc = Read-UiSecret "    Service account password ($($t.ServiceAccount))" }
        if ($t.ProxyHost -and $t.ProxyUser) { $s.Proxy = Read-UiSecret "    Proxy password ($($t.ProxyUser))" }
        foreach ($k in @($s.Keys)) { Register-Secret (ConvertTo-PlainText $s[$k]) }
        # An empty password would reach the installer after the services are stopped, so stop here.
        $names = @{ Cfg = 'configuration file'; Pfx = 'Kerberos PFX'; Svc = 'service account'; Proxy = 'proxy' }
        if ($s.Proxy -and (ConvertTo-PlainText $s.Proxy) -match '"') { Stop-Run "The proxy password for $($t.Name) contains a double quote, which the installer's command line cannot carry. Nothing was changed." 'secrets' }
        foreach ($k in @($s.Keys)) { if ($s[$k].Length -eq 0) { Stop-Run "Empty $($names[$k]) password for $($t.Name). Nothing was changed." 'secrets' } }
    }
    $secrets[$t.Name] = $s
    if ($Mode -eq 'WinRM') { $creds[$t.Name] = if ($Credential) { $Credential } else { Read-UiCredential "Domain admin sign-in for tenant $($t.Name) connectors:" } }
    # Kerberos connectors: the vendor setup that rebuilds the keytab after an upgrade must query
    # Active Directory, which a remote sign-in cannot. So the upgrade is started on the connector
    # as a one-time scheduled task under a domain admin account. (CredSSP and -SkipDomainCheck
    # go directly instead.)
    if (($Mode -eq 'RepairKeytab') -or (($Mode -ne 'RepairCertificate') -and ($t.Services -match 'KerberosAuthService') -and -not $SkipDomainCheck -and -not ($Mode -eq 'WinRM' -and $Authentication -eq 'CredSSP'))) {
        if ($env:AC_UPGRADE_RUNAS_SYSTEM -and $DryRun) {
            Say '[note] Test aid AC_UPGRADE_RUNAS_SYSTEM is set: this dry run uses the SYSTEM account for the task.' 'WARN' 
            # test aid, dry run only: exercises the task plumbing as SYSTEM with no account password
            $runAs[$t.Name] = @{ User = 'SYSTEM'; Password = $null }
        } else {
            $what = if ($Mode -eq 'RepairKeytab') { 'keytab repair' } else { 'upgrade' }
            $rc = if ($RunAsCredential) { $RunAsCredential } elseif ($Mode -eq 'WinRM') { $creds[$t.Name] } else { Read-UiCredential "Domain admin that runs the $what on the $($t.Name) connectors:" }
            Register-Secret $rc.GetNetworkCredential().Password
            $runAs[$t.Name] = @{ User = $rc.UserName; Password = $rc.Password }
        }
    }
}

$results = [System.Collections.Generic.List[object]]::new()
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$haltedTenants = @{}; $haltAll = $false

function Send-PayloadWinRM { param($Session, $T, $X)
    Invoke-Command -Session $Session -ArgumentList $RemoteStageDir -ScriptBlock { param($d)
        foreach ($p in $d, "$d\Logs", "$d\TrustedCerts", "$d\Java4shellPatch") { if (-not (Test-Path $p)) { $null = New-Item -ItemType Directory -Path $p -Force } } }
    $payload = Get-Payload $T
    foreach ($sub in $payload.Keys) { foreach ($f in $payload[$sub]) {
        $d = if ($sub) { Join-Path $RemoteStageDir $sub } else { $RemoteStageDir }
        Copy-Item -ToSession $Session -Force -LiteralPath $f -Destination (Join-Path $d (Split-Path $f -Leaf)) } }
    # installer: large, so skip the copy when the same file is already there
    $inst = Join-Path $script:StagingRoot $T.Installer
    $leaf = Split-Path $inst -Leaf
    $remoteInst = Join-Path $RemoteStageDir $leaf
    if (-not $script:HashCache.ContainsKey($inst)) { Say "Hashing $leaf..."; $script:HashCache[$inst] = (Get-FileHash -LiteralPath $inst -Algorithm SHA256).Hash }
    $want = $script:HashCache[$inst]
    $hashBlock = { param($f) if (Test-Path -LiteralPath $f) { (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash } else { 'absent' } }
    $have = Invoke-Command -Session $Session -ArgumentList $remoteInst -ScriptBlock $hashBlock
    if ($have -eq $want) { Say "$leaf already staged on $($X.Host) (hash matches)." }
    else {
        Say "Copying $leaf to $($X.Host) ($([math]::Round((Get-Item -LiteralPath $inst).Length/1MB)) MB)..."
        Copy-Item -ToSession $Session -Force -LiteralPath $inst -Destination $remoteInst
        $have = Invoke-Command -Session $Session -ArgumentList $remoteInst -ScriptBlock $hashBlock
        if ($have -ne $want) { throw "installer hash mismatch on $($X.Host) after copy" }
    }
    $job = New-JobJson $T
    try { Copy-Item -ToSession $Session -Force -LiteralPath $job -Destination (Join-Path $RemoteStageDir 'job.json') } finally { Remove-Item -LiteralPath $job -Force -ErrorAction SilentlyContinue }
}

function Start-ConnectorRun { param($X, [bool]$Async)
    # Stages the payload and launches the helper on the connector. Returns a handle.
    $t = $X.Tenant; $s = $secrets[$t.Name]
    if ($Mode -in 'SSH','RepairKeytab','RepairCertificate') {
        if ($Mode -eq 'RepairKeytab') { Send-PayloadSsh -Conn $X -T $t -RunnerOnly }
        elseif ($Mode -eq 'RepairCertificate') { Send-PayloadSsh -Conn $X -T $t -RunnerOnly -Also @((Join-Path $script:StagingRoot $t.Pfx)) }
        else { Send-PayloadSsh -Conn $X -T $t }
        # four lines, always in this order (an empty one where a password is not needed)
        $b64 = @(foreach ($k in 'Cfg','Pfx','Svc','Proxy') { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-PlainText $s[$k]))) })
        $ra = $runAs[$t.Name]; $extra = ''
        if ($ra) {
            $b64 += [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$ra.User))
            $b64 += [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-PlainText $ra.Password)))
            $extra = ' -RunAsTask'
        }
        if ($Mode -eq 'RepairKeytab') { $extra = ' -RepairKeytab' + $(if ($DryRun) { ' -CheckOnly' } else { '' }) + $extra }
        if ($Mode -eq 'RepairCertificate') { $extra = ' -RepairCertificate -CertFile ' + (Split-Path ([string]$t.Pfx) -Leaf) + $(if ($DryRun) { ' -CheckOnly' } else { '' }) + $(if ($Reapply) { ' -Reapply' } else { '' }) }
        $psi = [System.Diagnostics.ProcessStartInfo]::new('ssh')
        foreach ($a in (Get-SshBaseArgs)) { $psi.ArgumentList.Add($a) }
        $psi.ArgumentList.Add((Get-SshTarget $X))
        $psi.ArgumentList.Add("powershell -NoProfile -ExecutionPolicy Bypass -File $RemoteStageDir\Invoke-ConnectorUpgradeLocal.ps1 -SecretsFromStdin$extra 2>&1")
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
        $p = [System.Diagnostics.Process]::Start($psi)
        $errTask = $p.StandardError.ReadToEndAsync()
        foreach ($l in $b64) { $p.StandardInput.WriteLine($l) }
        $p.StandardInput.Close()
        if ($Mode -eq 'RepairKeytab') { Say "Keytab repair started on $($X.Host)..." }
        elseif ($Mode -eq 'RepairCertificate') { Say "Certificate $(if ($DryRun) { 'check' } else { 'repair' }) started on $($X.Host)..." }
        else { Say "Upgrade started on $($X.Host) (this takes several minutes)..." }
        $h = @{ X = $X; Proc = $p; Task = $null; Err = $errTask }
        # several at once: drain each output pipe in the background so none can block
        if ($Async) { $h.Task = $p.StandardOutput.ReadToEndAsync() }
        return $h
    }
    # A sign-in the connector refuses is named as such: the health gate then stops the tenant (and
    # the run), in a dry run too, so a wrong password is not tried on every connector.
    $cred = $creds[$t.Name]
    try { $session = New-PSSession -ComputerName $X.Host -Credential $cred -Authentication $Authentication -ErrorAction Stop }
    catch {
        if (Test-WinRMSignInRefused $_) { throw (Protect-Text ("Could not sign in to $($X.Host) over WinRM as $($cred.UserName): " + (Get-WinRMSignInReason $_))) }
        throw
    }
    try {
        Send-PayloadWinRM -Session $session -T $t -X $X
        $ra = $runAs[$t.Name]; $raUser = $null; $raPw = $null
        if ($ra) { $raUser = [string]$ra.User; $raPw = $ra.Password }
        $job = Invoke-Command -Session $session -AsJob -ArgumentList $RemoteStageDir, $s.Cfg, $s.Pfx, $s.Svc, $raUser, $raPw, $s.Proxy -ScriptBlock { param($d, $c, $p, $v, $ru, $rp, $xp)
            Set-ExecutionPolicy Bypass -Scope Process -Force -ErrorAction SilentlyContinue
            $a = @{ ConfigFilePassword = $c }; if ($p) { $a.SslCertPassword = $p }; if ($v) { $a.ServiceAccountPassword = $v }; if ($xp) { $a.ProxyPassword = $xp }
            if ($ru) { $a.RunAsUser = $ru; if ($rp) { $a.RunAsPassword = $rp } }
            & (Join-Path $d 'Invoke-ConnectorUpgradeLocal.ps1') @a *>&1 | ForEach-Object { [string]$_ } }
    } catch { Remove-PSSession $session -ErrorAction SilentlyContinue; throw }
    Say "Upgrade started on $($X.Host) (this takes several minutes)..."
    return @{ X = $X; Session = $session; Job = $job }
}

function Complete-ConnectorRun { param($H)
    # Waits for one connector, shows its output and returns the helper's result object.
    $state = @{ R = $null }
    $show = { param($line)
        if ($null -eq $line -or $line -match '^#< CLIXML|^<Objs ') { return }
        if ($line.StartsWith('RESULT_JSON:')) { try { $state.R = $line.Substring(12) | ConvertFrom-Json } catch { } ; return }
        Write-RemoteLine $line }
    if ($H.Proc) {
        if ($H.Task) { $H.Proc.WaitForExit(); foreach ($l in ($H.Task.Result -split "`r?`n")) { & $show $l } }
        else { while ($null -ne ($l = $H.Proc.StandardOutput.ReadLine())) { & $show $l }; $H.Proc.WaitForExit() }
        Show-SshErrors -Task $H.Err -HostName $H.X.Host
        $dest = Join-Path $centralLog ("{0}_{1}_{2}" -f $H.X.Tenant.Name, $H.X.Host, $stamp)
        if (-not (Test-Path -LiteralPath $centralLog)) { $null = New-Item -ItemType Directory -Path $centralLog -Force }
        if (-not (Copy-ScpFrom -Conn $H.X -RemoteDir "$RemoteStageDir\Logs" -LocalDir $dest)) { Say "Could not copy logs back from $($H.X.Host)." 'WARN' }
        else {
            # The helper cleans the installer log on the connector. Clean the copies here as well,
            # in case the helper was cut short before it got that far.
            $cleaned = 0
            foreach ($lf in @(Get-ChildItem -LiteralPath $dest -Recurse -File -Filter '*.log' -ErrorAction SilentlyContinue)) {
                $c = Protect-InstallerLog -Path $lf.FullName -Known @($script:SecretValues)
                if ($c -gt 0) { $cleaned += $c }
                elseif ($c -lt 0) {
                    # never keep a copy that could not be checked; the original stays on the connector
                    Remove-Item -LiteralPath $lf.FullName -Force -ErrorAction SilentlyContinue
                    Write-ErrorEntry "$($lf.Name) from $($H.X.Host) could not be checked for recorded passwords, so its copy was not kept here. The original is in $RemoteStageDir\Logs on the connector." 'logs'
                }
            }
            if ($cleaned) { Say "Replaced $cleaned recorded password value(s) in the copied installer log(s) with asterisks." 'WARN' }
        }
    } else {
        try { Receive-Job -Job $H.Job -Wait -AutoRemoveJob -ErrorAction Continue | ForEach-Object { foreach ($pl in ([string]$_ -split "`r?`n")) { & $show $pl } } }
        finally { Remove-PSSession $H.Session -ErrorAction SilentlyContinue }
    }
    return $state.R
}

# Batches: connectors in one batch run together; batches run one after another.
$batches = [System.Collections.Generic.List[object]]::new()
if ($Parallel -and $Mode -notin 'RepairKeytab','RepairCertificate') { $batches.Add(@($plan)) }
elseif ($ParallelTenants -and $Mode -notin 'RepairKeytab','RepairCertificate') {
    $groups = @(foreach ($pt in $planTenants) { ,@($plan | Where-Object { $_.Tenant.Name -eq $pt.Name }) })
    $depth = ($groups | ForEach-Object { $_.Count } | Measure-Object -Maximum).Maximum
    for ($i = 0; $i -lt $depth; $i++) { $batches.Add(@($groups | Where-Object { $_.Count -gt $i } | ForEach-Object { $_[$i] })) }
}
else { foreach ($x in $plan) { $batches.Add(@($x)) } }

foreach ($batch in $batches) {
    $async = (@($batch).Count -gt 1)
    $running = [System.Collections.Generic.List[object]]::new()
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($x in @($batch)) {
        $t = $x.Tenant
        $row = [pscustomobject]@{ Tenant=$t.Name; Connector=$x.Host; Status='Skipped'; From=''; To=''; InstallerExit=''; PatchExit=''; Message='' }
        $rows.Add($row)
        if ($haltAll -or $haltedTenants.ContainsKey($t.Name)) { $row.Message = 'not attempted - an earlier connector failed'; continue }
        Write-UiSection "$($t.Name) / $($x.Host)"
        try { $running.Add(@{ H = (Start-ConnectorRun -X $x -Async $async); Row = $row }) }
        catch {
            $row.Status = 'Error'; $row.Message = Protect-Text $_.Exception.Message; Write-ErrorEntry "$($x.Host): $($_.Exception.Message)" 'upgrade' $_
            # A sign-in the connector refused is known before the next connector is started, so it
            # stops them here, also when they were to start together (-Parallel, which ignores
            # -ContinueOtherTenants): the same account would be tried on each. The health gate
            # below says so, once.
            if ([string]$row.Message -like 'Could not sign in to * over WinRM as *') { $haltedTenants[$t.Name] = $true; if ($Parallel -or -not $ContinueOtherTenants) { $haltAll = $true } }
        }
    }
    if ($async -and $running.Count) { Say "$($running.Count) connectors are upgrading at the same time. Their output is shown as each one is collected." }
    foreach ($e in $running) {
        $x = $e.H.X; $row = $e.Row
        if ($async) { Write-UiSection "RESULT - $($row.Tenant) / $($x.Host)" }
        try {
            $r = Complete-ConnectorRun -H $e.H
            if (-not $r) { throw 'the connector returned no result (see the output above)' }
            $row.Status = $r.Status; $row.InstallerExit = $r.InstallerExit; $row.PatchExit = $r.PatchExit; $row.Message = $r.Message
            if ($r.Before) { $row.From = $r.Before.InstalledVersion }; if ($r.After) { $row.To = $r.After.InstalledVersion }
            if ($r.Status -in 'Success','DryRunPassed') {
                Say ("$($x.Host): $($r.Status). " + (Format-State $r.After)) 'OK'
                if ($r.Status -eq 'DryRunPassed' -and $r.Message) { Say ("$($x.Host): note - " + $r.Message) 'WARN' }
            }
            else { Write-ErrorEntry "$($x.Host): $($r.Status) - $($r.Message)" 'upgrade' }
        } catch {
            $row.Status = 'Error'; $row.Message = Protect-Text $_.Exception.Message
            Write-ErrorEntry "$($x.Host): $($_.Exception.Message)" 'upgrade' $_
        }
    }
    foreach ($row in $rows) {
        $results.Add($row)
        # HEALTH GATE (a dry run gates only on a failed check and on a refused sign-in)
        $badTask = ([string]$row.Message -like 'Could not start the task as*')
        $badWinRM = ([string]$row.Message -like 'Could not sign in to * over WinRM as *')
        $badSignIn = $badTask -or $badWinRM
        if ($DryRun -and $Mode -eq 'RepairCertificate') { }
        elseif ($DryRun -and -not $badSignIn -and $row.Status -eq 'DryRunFailed' -and -not $haltedTenants.ContainsKey($row.Tenant)) {
            $haltedTenants[$row.Tenant] = $true
            Say "The dry run failed on $($row.Connector). The same passwords would be used on the other $($row.Tenant) connectors, so they are not tried." 'WARN'
        }
        elseif ($badSignIn -or (-not $DryRun -and $row.Status -notin 'Success','Skipped')) {
            $haltedTenants[$row.Tenant] = $true
            if (-not $ContinueOtherTenants) { $haltAll = $true }
            if ($badWinRM) { Say "Stopping: $($row.Connector) refused the WinRM sign-in with the account given, so it is not tried on the other $(if ($haltAll) { '' } else { "$($row.Tenant) " })connectors." 'WARN' }
            elseif ($badTask) { Say "Stopping: the task could not be started on $($row.Connector) with the account given, so it is not tried on the other connectors." 'WARN' }
            else { Say "Stopping: $($row.Connector) did not finish healthy. Connectors not yet started are left untouched." 'WARN' }
        }
    }
}

Write-UiSection 'SUMMARY'
# Grouped by tenant, in plan order: connector, result, version before -> after; any message below.
$hw = 9; $sw = 7
foreach ($row in $results) { $hw = [Math]::Max($hw, ([string]$row.Connector).Length); $sw = [Math]::Max($sw, ([string]$row.Status).Length) }
$hw = [Math]::Min($hw, 34)
$firstTenant = $true
foreach ($pt in $planTenants) {
    $mine = @($results | Where-Object { $_.Tenant -eq $pt.Name })
    if (-not $mine.Count) { continue }
    if (-not $firstTenant) { Write-Host '' }; $firstTenant = $false
    Write-Host ($script:ui.Text + '  ' + $pt.Name + $script:ui.Reset)
    foreach ($row in $mine) {
        $c = if ($row.Status -in 'Success','DryRunPassed') { $script:ui.Ok } elseif ($row.Status -eq 'Skipped') { $script:ui.Caution } else { $script:ui.Warn }
        $ver = if ($row.From -or $row.To) { "$($row.From) -> $($row.To)" } else { '' }
        $line = '    {0}  {1}  {2}' -f ([string]$row.Connector).PadRight($hw), ([string]$row.Status).PadRight($sw), $ver
        foreach ($l in (Get-HangingLines -Text $line -Hang 6)) { Write-Host ($c + $l + $script:ui.Reset) }
        if ($row.Message) { foreach ($l in (Get-HangingLines -Text ('      ' + (Protect-Text ([string]$row.Message))) -Hang 6)) { Write-Host ($c + $l + $script:ui.Reset) } }
    }
}
Write-Host ''
try {
    if (-not (Test-Path -LiteralPath $centralLog)) { $null = New-Item -ItemType Directory -Path $centralLog -Force }
    $csv = Join-Path $centralLog "ConnectorUpgrade_$stamp.csv"
    $results | Export-Csv -LiteralPath $csv -NoTypeInformation
    Write-UiText 'Summary CSV and connector logs:'
    foreach ($l in (Get-HangingLines -Text ('    ' + $centralLog) -Hang 4)) { Write-Host ($script:ui.Text + $l + $script:ui.Reset) }
} catch { Say ("Could not write the summary CSV: " + $_.Exception.Message) 'WARN' }
$failed = @($results | Where-Object { $_.Status -notin 'Success','DryRunPassed' }).Count
Write-AuditEntry -Outcome $(if ($failed) { 'FAILED' } else { 'SUCCESS' }) -Stage $(if ($DryRun) { 'dryrun' } elseif ($Mode -eq 'RepairKeytab') { 'repairkeytab' } elseif ($Mode -eq 'RepairCertificate') { 'repaircertificate' } else { 'upgrade' }) -Rows $results.Count -Detail ("failed=$failed tenants=" + (($plan.Tenant.Name | Select-Object -Unique) -join ','))
exit ([int]($failed -gt 0))
