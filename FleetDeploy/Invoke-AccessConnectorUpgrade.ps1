<#
.SYNOPSIS
    Automated upgrade of Omnissa Access Connectors, one connector at a time per
    tenant, to the installer version named in the fleet file, with an optional
    Java4Shell patch step (HW-283446) and a health gate.
    Modes: SSH (any OS), WinRM (Windows), Stage (run locally or scheduled),
    Verify (report only), RepairKeytab, RepairCertificate. Run with -Help for
    full usage. Requires PowerShell 7.
#>
[CmdletBinding()]
param(
    [string]$FleetConfig,
    [string]$Fleet,
    [ValidateSet('SSH','WinRM','Stage','Verify','RepairKeytab','RepairCertificate')]
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
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
# 'pwsh -File' passes "A,B" as one string, so split comma lists here.
if ($Tenant)    { $Tenant    = @($Tenant    | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
if ($Connector) { $Connector = @($Connector | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
$script:Version  = '1.3.1'
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
    if (-not $script:ui.Reset -or $Host.Name -ne 'ConsoleHost') {
        if ($Secret) { return (Read-Host -AsSecureString $Prompt) } else { return (Read-Host $Prompt) } }
    Write-Host ($PromptStyle + $Prompt + ': ' + $script:ui.Reset) -NoNewline
    try { [Console]::ForegroundColor = $TypedColor } catch { }
    try { if ($Secret) { return (Read-Host -AsSecureString) } else { return (Read-Host) } }
    finally { try { [Console]::ResetColor() } catch { } }
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
    Write-UiSection 'WHICH FLEET FILE IS USED'
    Write-UiText 'So one shared folder can serve several machines, the fleet file is chosen in this order, first match wins: -FleetConfig; -Fleet <name>; fleet.<this computer name>.psd1; fleet.<this computer domain>.psd1; fleet.psd1. The plan shown before any change names the file in use and why.'
    Write-UiSection 'WHEN A TENANT''S FILES ARE IN ANOTHER COPY OF THE FOLDER'
    Write-UiText 'The installer, config file, certificates and PFX are looked for beside the folder this script is run from. When a tenant''s files are not there, the run stops before anything is contacted and the error names another copy of the folder that has them, with the cd command to use. Other copies are looked for on every mounted volume (macOS) or drive (Windows): at this folder''s own path, and at each path listed under StagingFolders in the fleet file.'
    Write-UiSection 'MODES'
    Write-UiParam 'SSH (default)' 'Runs from macOS, Linux or Windows using ssh and scp with key sign-in. Connectors without the Kerberos service: the installer runs as the SSH account. Kerberos connectors: it runs on the connector as a one-time scheduled task under a domain admin account you are asked for (see -RunAsCredential), because only a full sign-in can rebuild the keytab.'
    Write-UiParam 'WinRM' 'Runs from Windows over PowerShell remoting with a domain credential per tenant. Kerberos connectors use the same scheduled task with that sign-in, or run directly with -Authentication CredSSP.'
    Write-UiParam 'Stage' 'Copies everything and writes Run-Upgrade.cmd on each connector. You then sign in to the connector as a domain admin and run it, or schedule it with -Schedule on the helper. No passwords are asked here.'
    Write-UiParam 'Verify' 'Changes nothing. Reports version, services and patch state for each connector over SSH.'
    Write-UiParam 'RepairKeytab' 'Installs nothing. On each Kerberos connector, over SSH, runs the vendor setupKerberos.ps1 as a one-time scheduled task under a domain admin account, then restarts the Kerberos service. Use it when Verify shows keytab EMPTY. With -DryRun it only tests the sign-in.'
    Write-UiParam 'RepairCertificate' 'Installs nothing. On each Kerberos connector that has a PFX in the fleet file, over SSH, puts the PFX certificate on the Kerberos Auth service with the vendor installKerberosAuthService.bat -updateConfiguration, restarts that service and confirms it serves the certificate. Use it when Verify shows a certificate made by the installer: the vendor installer does not carry a PFX certificate through an upgrade. Asks for the PFX password only. With -DryRun it tests the PFX and its password and changes nothing.'
    Write-UiSection 'PARAMETERS'
    Write-UiParam '-FleetConfig <path>' 'Fleet definition file, by full path. Overrides the automatic choice below.'
    Write-UiParam '-Fleet <name>' 'Use fleet.<name>.psd1 beside this script, for example -Fleet lab.'
    Write-UiParam '-Mode <name>' 'SSH, WinRM, Stage, Verify, RepairKeytab or RepairCertificate.'
    Write-UiParam '-Tenant <names>' 'Only these tenants (fleet order is kept).'
    Write-UiParam '-Connector <hosts>' 'Only these connector hosts.'
    Write-UiParam '-DryRun' 'Stage, then run the installer pre-flight only. Nothing is installed.'
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
    Write-UiParam '-Parallel' 'Upgrade every selected connector at the same time. Fastest, but each tenant is fully offline while it runs and a failure cannot stop the others.'
    Write-UiParam '-ParallelTenants' 'Run tenants side by side, still one connector at a time inside each tenant, so every tenant with two or more connectors keeps one online.'
    Write-UiParam '-ContinueOtherTenants' 'After a failure, stop that tenant but carry on with the others. Default: stop everything.'
    Write-UiParam '-Yes' 'Do not ask for confirmation before changing connectors.'
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
    Write-UiSection 'LOGGING'
    Write-UiText 'Audit log (-AuditLog): one appended key=value line per run saying who ran what and the outcome. Error log (-ErrorLog): the detail of each failure. Passwords are masked everywhere, including in the vendor installer logs copied back from each connector.'
    Write-UiSection 'REQUIREMENTS'
    Write-UiText 'PowerShell 7. SSH and Verify modes need ssh and scp on the PATH and key sign-in to each connector. WinRM mode needs Windows and PowerShell remoting enabled on the connectors. The staging share must be readable from the machine running this script.'
    Write-UiSection 'ABOUT'
    Write-UiText "Version $($script:Version). Created 2026-11-21."
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
function Write-ErrorEntry { param([string]$Message, [string]$Stage, [System.Management.Automation.ErrorRecord]$Record)
    $m = Protect-Text $Message
    Say $m 'ERROR'
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
        script=$script:Name; version=$script:Version; mode=$Mode; dryRun=[bool]$DryRun; outcome=$Outcome }
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
function Invoke-SshPs { param($Conn, [string]$ScriptText)
    # Runs a short Windows PowerShell script on the connector; returns stdout lines.
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("`$ProgressPreference='SilentlyContinue';" + $ScriptText))
    $out = & ssh @(Get-SshBaseArgs) (Get-SshTarget $Conn) "powershell -NoProfile -EncodedCommand $enc" 2>$null
    $code = $LASTEXITCODE
    $lines = @($out | Where-Object { $_ -notmatch '^#< CLIXML|^<Objs ' })
    return [pscustomobject]@{ ExitCode = $code; Lines = $lines } }
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
    }
    $f = Join-Path ([IO.Path]::GetTempPath()) ("acjob_" + [guid]::NewGuid().ToString('N') + '.json')
    Set-Content -LiteralPath $f -Value ($job | ConvertTo-Json) -Encoding utf8
    return $f }
function Send-PayloadSsh { param($Conn, $T, [switch]$RunnerOnly, [string[]]$Also = @())
    # The folder holds scripts that run with high privilege, so only Administrators and SYSTEM may use it.
    $mk = "foreach(`$d in '$RemoteStageDir','$RemoteStageDir\Logs','$RemoteStageDir\TrustedCerts','$RemoteStageDir\Java4shellPatch'){if(-not(Test-Path `$d)){`$null=New-Item -ItemType Directory -Path `$d -Force}}; if((Split-Path -Leaf '$RemoteStageDir') -eq 'AccessConnectorUpdate'){`$null = & icacls.exe '$RemoteStageDir' /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' /Q 2>&1}; 'ok'"
    $r = Invoke-SshPs $Conn $mk
    if ($r.ExitCode -ne 0 -or ($r.Lines -notcontains 'ok')) { throw "cannot reach $($Conn.Host) over SSH or create $RemoteStageDir" }
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

# ====================================================================== main
Initialize-UiStyle
Show-LaunchNotice
if ($Help) { Show-Help; return }

$script:Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:AuditPath = Resolve-LogPath -Value $AuditLog -DefaultName 'connector-fleet-audit.log'
$script:ErrorPath = Resolve-LogPath -Value $ErrorLog -DefaultName 'connector-fleet-errors.log'
$script:HashCache = @{}

if ($PSVersionTable.PSVersion.Major -lt 7) { Stop-Run 'This script needs PowerShell 7 (pwsh).' 'precheck' }
$fleetWhy = 'given with -FleetConfig'
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
    if (-not $FleetConfig) { Stop-Run ("No fleet file found in $($script:Here). Looked for: " + (($cands | ForEach-Object { $_[0] }) -join ', ')) 'precheck' }
}
if (-not (Test-Path -LiteralPath $FleetConfig -PathType Leaf)) { Stop-Run "Fleet file not found: $FleetConfig" 'precheck' }

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
if ($Parallel -and $ContinueOtherTenants) { $warn.Add('[ignored] -ContinueOtherTenants: with -Parallel everything starts together, so there is nothing left to stop.') }
if ($DryRun -and $ForceReinstall) { $warn.Add('[note] -ForceReinstall with -DryRun only changes the planned action shown; nothing is uninstalled.') }
if ($SkipJavaPatch -and -not $DryRun -and $Mode -ne 'Verify') { $warn.Add('[note] -SkipJavaPatch: an upgrade may reset the service XML files, leaving the connector without the Java4Shell patch.') }
foreach ($w in $warn) { Say $w 'WARN' }

# ---- load and validate the fleet
try { $script:FleetData = Import-PowerShellDataFile -LiteralPath $FleetConfig } catch { Stop-Run ("Fleet file could not be read: " + $_.Exception.Message) 'fleet' }
$script:StagingRoot = if ($script:FleetData.StagingRoot) { $script:FleetData.StagingRoot } else { Split-Path -Parent $script:Here }
$centralLog = if ($script:FleetData.CentralLogRoot) { $script:FleetData.CentralLogRoot } else { Join-Path $script:Here 'FleetLogs' }
if (-not [IO.Path]::IsPathRooted($centralLog) -and $centralLog -notmatch '^\\\\') { $centralLog = Join-Path $script:StagingRoot $centralLog }
if (-not (Test-Path -LiteralPath $script:StagingRoot)) { Stop-Run "Staging root not found: $($script:StagingRoot)" 'fleet' }

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
Write-Host ''
for ($i = 0; $i -lt $plan.Count; $i++) {
    $x = $plan[$i]
    $row = '  {0,-14} {1}' -f $x.Tenant.Name, $x.Host
    if ($same.Count -gt 1 -and $doing[$i]) { $row = '  {0,-14} {1,-30} {2}' -f $x.Tenant.Name, $x.Host, $doing[$i] }
    foreach ($l in (Get-HangingLines -Text $row -Hang 17)) { Write-Host ($script:ui.Text + $l + $script:ui.Reset) } }
Write-UiBlank

# =================================================================== VERIFY
if ($Mode -eq 'Verify') {
    $bad = 0
    foreach ($x in $plan) {
        try {
            Send-PayloadSsh -Conn $x -T $x.Tenant -RunnerOnly
            $r = Invoke-SshRunner -Conn $x -RunnerArgs '-VerifyOnly' -StdinLines @()
            if ($r.Result) {
                # Colour only: red when a service is not running, yellow when nothing is installed
                # or a Java process lacks the patch flag, green otherwise. The exit code is unchanged.
                $vs = $r.Result.State; $lvl = 'OK'
                if (@($vs.Services | Where-Object { $_.Status -ne 'Running' }).Count) { $lvl = 'ERROR' }
                elseif (@($vs.Services | Where-Object { $_.Key -eq 'KerberosAuthService' }).Count -and [int]$vs.KeytabBytes -lt 32) { $lvl = 'ERROR' }
                elseif ($x.Tenant.Pfx -and (Test-CertBad $vs.Cert)) { $lvl = 'ERROR' }   # with no Pfx the installer's own certificate is what is meant to be there
                elseif (@($vs.Services).Count -eq 0 -or [int]$vs.JavaWithFlag -lt [int]$vs.JavaCount) { $lvl = 'WARN' }
                Say ("{0,-14} {1}`n{2}" -f $x.Tenant.Name, $x.Host, (Format-State $vs)) $lvl
            } else { $bad++; Write-ErrorEntry "$($x.Host): no result returned" 'verify' }
        } catch { $bad++; Write-ErrorEntry "$($x.Host): $($_.Exception.Message)" 'verify' $_ }
    }
    Write-AuditEntry -Outcome $(if ($bad) { 'FAILED' } else { 'SUCCESS' }) -Stage 'verify' -Rows $plan.Count
    exit ([int]($bad -gt 0))
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
        foreach ($k in @($s.Keys)) { Register-Secret (ConvertTo-PlainText $s[$k]) }
        # An empty password would reach the installer after the services are stopped, so stop here.
        $names = @{ Cfg = 'configuration file'; Pfx = 'Kerberos PFX'; Svc = 'service account' }
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
        $b64 = @(foreach ($k in 'Cfg','Pfx','Svc') { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-PlainText $s[$k]))) })
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
    $session = New-PSSession -ComputerName $X.Host -Credential $creds[$t.Name] -Authentication $Authentication
    try {
        Send-PayloadWinRM -Session $session -T $t -X $X
        $ra = $runAs[$t.Name]; $raUser = $null; $raPw = $null
        if ($ra) { $raUser = [string]$ra.User; $raPw = $ra.Password }
        $job = Invoke-Command -Session $session -AsJob -ArgumentList $RemoteStageDir, $s.Cfg, $s.Pfx, $s.Svc, $raUser, $raPw -ScriptBlock { param($d, $c, $p, $v, $ru, $rp)
            Set-ExecutionPolicy Bypass -Scope Process -Force -ErrorAction SilentlyContinue
            $a = @{ ConfigFilePassword = $c }; if ($p) { $a.SslCertPassword = $p }; if ($v) { $a.ServiceAccountPassword = $v }
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
        catch { $row.Status = 'Error'; $row.Message = Protect-Text $_.Exception.Message; Write-ErrorEntry "$($x.Host): $($_.Exception.Message)" 'upgrade' $_ }
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
            if ($r.Status -in 'Success','DryRunPassed') { Say ("$($x.Host): $($r.Status). " + (Format-State $r.After)) 'OK' }
            else { Write-ErrorEntry "$($x.Host): $($r.Status) - $($r.Message)" 'upgrade' }
        } catch {
            $row.Status = 'Error'; $row.Message = Protect-Text $_.Exception.Message
            Write-ErrorEntry "$($x.Host): $($_.Exception.Message)" 'upgrade' $_
        }
    }
    foreach ($row in $rows) {
        $results.Add($row)
        # HEALTH GATE (a dry run never gates)
        $badSignIn = ([string]$row.Message -like 'Could not start the task as*')
        if ($DryRun -and $Mode -eq 'RepairCertificate') { }
        elseif ($DryRun -and -not $badSignIn -and $row.Status -eq 'DryRunFailed' -and -not $haltedTenants.ContainsKey($row.Tenant)) {
            $haltedTenants[$row.Tenant] = $true
            Say "The dry run failed on $($row.Connector). The same passwords would be used on the other $($row.Tenant) connectors, so they are not tried." 'WARN'
        }
        elseif ($badSignIn -or (-not $DryRun -and $row.Status -notin 'Success','Skipped')) {
            $haltedTenants[$row.Tenant] = $true
            if (-not $ContinueOtherTenants) { $haltAll = $true }
            if ($badSignIn) { Say "Stopping: the task could not be started on $($row.Connector) with the account given, so it is not tried on the other connectors." 'WARN' }
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
