<#
.SYNOPSIS
    Installs or updates PowerShell 7 on a Windows computer from Microsoft's
    MSI package and says at the end which version is installed. Meant for the
    admin machine that runs Invoke-AccessConnectorUpgrade.ps1; the connectors
    themselves do not need PowerShell 7. Runs under Windows PowerShell 5.1.

    Idempotent: when the installed version is current it changes nothing.
    Not over SSH: inside an SSH session it installs nothing (-CheckOnly works).
    Run with -Help for full usage, or double-click Install-PowerShell7.cmd.
#>
#Requires -Version 5.1
# Every parameter is named. A positional -MsiSource took any stray word (cmd.exe's /?, or
# /CheckOnly) as a package path that does not exist, and the run then downloaded and installed.
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$MsiSource,
    [switch]$CheckOnly,
    [switch]$EnablePSRemoting,
    [switch]$NoMicrosoftUpdate,
    [string]$LogRoot,
    [string]$AuditLog,
    [string]$ErrorLog,

    # Retry behaviour - startup and logon runs race the network stack.
    [int]$MaxAttempts        = 4,
    [int]$RetryDelaySeconds  = 10,
    [int]$NetworkWaitSeconds = 30,
    [switch]$Help,

    # Whatever is not one of the parameters above (a word, a cmd.exe-style /Switch, a misspelt
    # -Parameter) lands here and is refused after the notice, before anything is done.
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Unexpected
)

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1: drawing a progress bar slows web requests to a crawl.
$ProgressPreference = 'SilentlyContinue'
$script:Version   = '1.0.0'
$script:Name      = 'Install-PowerShell7.ps1'
$script:UiWidth   = 78
$script:Started   = Get-Date
$script:Stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:UserAgent = 'Install-PowerShell7/' + $script:Version
$script:Supplied  = @($PSBoundParameters.Keys)
$script:RunLog    = $null
$script:AuditPath = $null
$script:ErrorPath = $null
$script:AuditWritten = $false
$script:WorkDir   = $null
$script:Exe       = $null    # this computer's pwsh.exe, once known; a failed run reads it again
$script:PwshDir   = $null    # ...and its folder
# What the audit line reports: the version before, the package chosen, the version after.
$script:AuditBefore = 'none'; $script:AuditPackage = ''; $script:AuditAfter = ''; $script:AuditArch = ''

# ---------------------------------------------------------------- UI helpers
function Initialize-UiStyle {
    # ANSI colour only on a terminal that understands it; plain text when the output is
    # redirected or NO_COLOR is set, so logs and files never hold escape codes.
    $useColor = $true
    if ($env:NO_COLOR) { $useColor = $false }
    try { if ([Console]::IsOutputRedirected) { $useColor = $false } } catch { }
    try { if (-not $Host.UI.SupportsVirtualTerminal) { $useColor = $false } } catch { }
    if ($env:OMNISSA_UI_COLOR) { $useColor = $true }
    $e = [char]27
    $script:ui = @{}
    $keys = 'Reset','Banner','Section','Legal','Rule','Cmd','Flag','Text','Warn','Notice','Ok','Info','Dim','Caution'
    if ($useColor) {
        $script:ui = @{
            Reset="$e[0m"; Banner="$e[1;97;44m"; Section="$e[1;96;100m"; Legal="$e[1;97;41m"
            Rule="$e[38;5;240m"; Cmd="$e[92m"; Flag="$e[1;93m"; Text="$e[38;5;250m"
            Warn="$e[1;91m"; Notice="$e[1;93m"; Ok="$e[92m"; Info="$e[96m"; Dim="$e[38;5;244m"
            # Notice = bold yellow (the UNSUPPORTED notice); Caution = yellow (warnings);
            # Warn = bold red (alerts and errors).
            Caution="$e[93m"
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
function Get-HangingLines {
    # Wraps one message to the divider width: the first line starts with $Prefix, later
    # lines are indented to the same depth so they continue under the message.
    param([string]$Prefix, [string]$Text, [int]$Width = $script:UiWidth)
    $out = New-Object System.Collections.Generic.List[string]
    $pad = ' ' * $Prefix.Length; $cur = $Prefix; $empty = $true
    foreach ($w in ($Text -split '\s+' | Where-Object { $_ })) {
        if ($empty) { $cur = $cur + $w; $empty = $false; continue }
        if (($cur.Length + 1 + $w.Length) -le $Width) { $cur = $cur + ' ' + $w }
        else { $out.Add($cur); $cur = $pad + $w }
    }
    $out.Add($cur)
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
function Write-UiCaption { param([string]$T) Write-Host ($script:ui.Dim + '  ' + $T + $script:ui.Reset) }
function Write-UiCmd { param([string]$T) Write-Host ($script:ui.Cmd + '  ' + $T + $script:ui.Reset) }
function Write-UiParam { param([string]$Flag, [string]$Desc)
    $col = 27
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
function Show-Disclaimer {
    Write-UiSection 'LEGAL DISCLAIMER - UNSUPPORTED, USE AT YOUR OWN RISK' -Legal
    Write-UiWarn 'This script is an UNSUPPORTED utility. It is NOT an Omnissa product or offering, and it is not covered by any Omnissa support, maintenance, or service-level agreement.'
    Write-UiWarn 'It is provided "AS IS" and "AS AVAILABLE", WITHOUT WARRANTY OF ANY KIND, express or implied, including but not limited to the implied warranties of merchantability, fitness for a particular purpose, title, and non-infringement.'
    Write-UiWarn 'YOU USE IT ENTIRELY AT YOUR OWN RISK. You are solely responsible for validating its behaviour, for safeguarding the credentials you supply to it, and for any effect it has on your environment or data.'
    Write-UiWarn 'TO THE MAXIMUM EXTENT PERMITTED BY LAW, NEITHER OMNISSA NOR THE AUTHOR SHALL BE LIABLE FOR ANY CLAIM, LOSS, OR DAMAGES WHATSOEVER - direct, indirect, incidental, special, exemplary, or consequential (including loss of data, revenue, or profits) - arising from or in connection with the use of, or inability to use, this script.'
    Write-UiWarn 'PowerShell is Microsoft software, licensed by Microsoft on its own terms. This script only finds, checks and runs Microsoft''s own installer; you remain responsible for complying with those terms and with your organisation''s software policies.'
}
function Show-Help {
    Write-Host ($script:ui.Banner + (" $($script:Name)  v$($script:Version) ").PadRight($script:UiWidth) + $script:ui.Reset)
    Show-Disclaimer
    Write-UiSection 'SYNOPSIS'
    Write-UiText 'Installs or updates PowerShell 7 on a Windows computer from Microsoft''s MSI package, and says at the end what it did and which version is installed. It is meant for the admin machine that runs Invoke-AccessConnectorUpgrade.ps1: the connectors themselves do not need PowerShell 7. It runs under the Windows PowerShell 5.1 that Windows already has.'
    Write-UiSection 'DESCRIPTION'
    Write-UiText 'Finds the newest stable PowerShell 7 release that has an MSI for this computer''s processor (x64, Arm64 or x86). It asks Microsoft''s stable-release link (aka.ms/powershell-release?tag=stable) first, which does not count against the GitHub API rate limit, and the GitHub releases API when that fails or when that release has no MSI. Releases published as MSIX only, previews and drafts are skipped.'
    Write-UiText 'When the installed version is the same or newer, it changes nothing. Otherwise it downloads the MSI, checks its SHA-256 against the hashes.sha256 file Microsoft publishes with the release and checks that the package is signed by Microsoft, and refuses to install on any mismatch. It then installs silently, retrying while another installation holds Windows Installer, and checks pwsh.exe afterwards.'
    Write-UiText 'With -MsiSource it uses a package you copied beforehand, for a computer without Internet access or to save downloads: an MSI file, or a folder holding PowerShell-<version>-win-<arch>.msi (the highest version there is used). The package is copied to a local folder first; its signature is checked, and its SHA-256 too when the hashes.sha256 of the same release sits beside it. When no usable MSI is found there, the script downloads one instead.'
    Write-UiText 'Install settings: pwsh on the PATH, the event log manifest registered, "Open here" and "Run with PowerShell 7" in the Explorer menus, telemetry off, updates through Microsoft Update (unless -NoMicrosoftUpdate) and the PowerShell 7 remoting endpoints off (unless -EnablePSRemoting).'
    Write-UiSection 'PARAMETERS'
    Write-UiParam '-MsiSource <path>' 'An MSI file, or a folder (local, or a share) holding PowerShell-<version>-win-<arch>.msi and, ideally, the hashes.sha256 of that release. Nothing is downloaded unless no usable MSI is found there.'
    Write-UiParam '-CheckOnly' 'Change nothing: report the installed version and the newest one available (or the one in -MsiSource). Needs no elevation, and works over SSH.'
    Write-UiParam '-EnablePSRemoting' 'Turn on the PowerShell 7 remoting endpoints (the installer''s ENABLE_PSREMOTING=1). Off by default. Applies only when something is installed.'
    Write-UiParam '-NoMicrosoftUpdate' 'Do not opt in to updates through Microsoft Update (USE_MU=0, ENABLE_MU=0). By default, as in Microsoft''s installer, PowerShell 7 is kept current through Microsoft Update, WSUS or Configuration Manager, and the computer is opted in to Microsoft Update.'
    Write-UiParam '-LogRoot <folder>' 'Folder for the run log and the msiexec log. Default: PS7Deploy in %ProgramData%.'
    Write-UiParam '-AuditLog <path>' 'Append-only audit log. File or folder. Default: Install-PowerShell7-audit.log in -LogRoot.'
    Write-UiParam '-ErrorLog <path>' 'Error log. File or folder. Default: Install-PowerShell7-errors.log in -LogRoot.'
    Write-UiParam '-MaxAttempts <n>' 'Tries for each web request, and for msiexec while another installation is running (1618). 1 to 20. Default 4.'
    Write-UiParam '-RetryDelaySeconds <n>' 'Pause before the second try; it grows with each try, and is three times longer when GitHub limits the request rate (HTTP 403 or 429). 0 to 600. Default 10.'
    Write-UiParam '-NetworkWaitSeconds <n>' 'Before downloading, wait up to this long for github.com to resolve (useful in a startup script). 0 = do not wait. Not used behind a proxy. Default 30.'
    Write-UiParam '-Help' 'Show this help.'
    Write-UiSection 'EXAMPLES'
    Write-UiCaption '# Install or update: double-click the launcher, or run it from cmd.exe'
    Write-UiCmd 'Install-PowerShell7.cmd'
    Write-Host ''
    Write-UiCaption '# The same from Windows PowerShell opened with Run as administrator'
    Write-UiCmd 'powershell -ExecutionPolicy Bypass -File .\Install-PowerShell7.ps1'
    Write-Host ''
    Write-UiCaption '# Check for an update (changes nothing, no elevation, works over SSH too)'
    Write-UiCmd '.\Install-PowerShell7.cmd -CheckOnly'
    Write-Host ''
    Write-UiCaption '# Offline, in an elevated window: a folder with the MSI and hashes.sha256'
    Write-UiCmd '.\Install-PowerShell7.cmd -MsiSource D:\Packages\PowerShell'
    Write-Host ''
    Write-UiCaption '# Elevated, from a share, with remoting endpoints and logs elsewhere'
    Write-UiCmd 'powershell -ExecutionPolicy Bypass -File .\Install-PowerShell7.ps1 `'
    Write-UiCmd '    -EnablePSRemoting -AuditLog D:\Logs\ -ErrorLog D:\Logs\ `'
    Write-UiCmd '    -MsiSource \\server.example.local\packages\PowerShell'
    Write-Host ''
    Write-UiCaption '# Scheduled task or startup script (one line there; nothing waits)'
    Write-UiCmd 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `'
    Write-UiCmd '    -File C:\Tools\Install-PowerShell7.ps1 -NetworkWaitSeconds 90'
    Write-UiSection 'STARTING IT'
    Write-UiText 'Install-PowerShell7.cmd starts this script in 64-bit Windows PowerShell with the execution policy bypassed for that one process; the computer''s own policy is not changed. An execution policy set by Group Policy still applies and wins over the bypass: then sign the script, or ask for the policy to change.'
    Write-UiText 'That is why the examples go through the launcher or -ExecutionPolicy Bypass. Started as .\Install-PowerShell7.ps1, the script runs only where the policy allows it: Windows 10 and 11 allow no script by default (Restricted), and RemoteSigned, the default on Windows Server, refuses a downloaded copy until Unblock-File (or Unblock in the file''s Properties) clears it.'
    Write-UiText 'Double-clicked, the launcher asks Windows for elevation when needed and waits for a key at the end so that the result can be read. Started from cmd.exe or PowerShell with arguments (.\ in front works in both), it passes them to the script unchanged, and neither asks for elevation nor waits: to install that way, start it from an elevated window. /? shows this help. In a scheduled task, startup script or deployment tool, start the .ps1 directly as in the last example.'
    Write-UiText 'Not over SSH. Replacing PowerShell 7 over SSH can end the session and stop the install half-way, especially when the OpenSSH default shell is pwsh. So a run inside an SSH session (SSH_CONNECTION or SSH_CLIENT is set, or sshd is among its parent processes) installs and updates nothing: it stops with exit code 1 before it looks up a release, reads -MsiSource or downloads anything, also when PowerShell 7 is already current, and says so in the error log and the audit log. Run it at the console, by Remote Desktop, or through WinRM (Enter-PSSession or Invoke-Command) instead. -CheckOnly works over SSH.'
    Write-UiText 'Every parameter is named, with a dash. A word the script does not know (checkonly, or /CheckOnly as cmd.exe programs spell switches) stops the run before anything is done, and so does a quoted folder ending in a backslash that swallowed the rest of the command line; one at the very end is read as the folder it names.'
    Write-UiSection 'OUTPUT'
    Write-UiText 'Timed lines on screen and in the run log, ending with what was done (or what failed) and the version now installed; after a failure that version is read again from pwsh.exe. Exit code 0: installed, updated, already current, or (with -CheckOnly) reported. 3010 or 1641: installed, and a restart is needed to finish. 1: not elevated, inside an SSH session (see STARTING IT), an argument the script cannot use, nothing found, a download or check failed, or another error. Any other number is the msiexec error code; 1618 means another installation kept running, so run it again later.'
    Write-UiSection 'LOGGING'
    Write-UiText 'Run log: Install-PowerShell7_<date-time>.log in -LogRoot, one per run. msiexec log: msiexec_<date-time>.log beside it (verbose; search it for "Return value 3" when an install fails).'
    Write-UiText 'Audit log (-AuditLog): one appended key=value line per run saying who ran it, where, the versions before and after (after an install or a failure, after= is read again from pwsh.exe), and the outcome. Error log (-ErrorLog): the detail of each failure. A command line the script cannot fully read (a word that is not a parameter, a quote inside a path) is refused on screen only, before any log is opened, as PowerShell refuses a parameter it does not know: its paths cannot be trusted. No password or token is asked for, used or written.'
    Write-UiSection 'REQUIREMENTS'
    Write-UiText 'Windows with Windows PowerShell 5.1 (or PowerShell 7). Installing needs an elevated session; -CheckOnly does not. Internet access to aka.ms, github.com and GitHub''s download servers, through the system proxy if one is set, unless -MsiSource names a package. Check Microsoft''s list of supported Windows versions for the release you install.'
    Write-UiSection 'ABOUT'
    Write-UiText "Version $($script:Version). Created 2026-11-23. MIT License; see the LICENSE file."
    Write-UiSection 'DOCUMENTATION'
    Write-UiText 'Microsoft Learn, "Installing PowerShell on Windows", the section on installing the MSI package from the command line (it lists the installer options used here).'
    Write-UiText 'Releases: https://github.com/PowerShell/PowerShell/releases'
    Write-Host ''
}

# ------------------------------------------------------------------- logging
function Resolve-LogPath { param([string]$Value, [string]$DefaultName)
    # A file, or a folder (then $DefaultName in it). Parent folders are created.
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $v = $Value.Trim()
    if ((Test-Path -LiteralPath $v -PathType Container) -or $v.EndsWith('\') -or $v.EndsWith('/')) { $v = Join-Path $v $DefaultName }
    $dir = Split-Path -Parent $v
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    return $v }
function Add-LogLine { param([string]$Path, [string[]]$Lines, [string]$Header)
    # Appends, never truncates; the header is written once, when the file is created. A log
    # that cannot be written does not stop the run: that is said once on screen.
    try {
        if ($Header -and -not (Test-Path -LiteralPath $Path)) { Add-Content -LiteralPath $Path -Encoding UTF8 -Value $Header }
        Add-Content -LiteralPath $Path -Encoding UTF8 -Value $Lines
        return $true
    } catch {
        if (-not $script:LogWarned) { $script:LogWarned = $true; Write-Host ($script:ui.Caution + "  Could not write to $Path - $($_.Exception.Message)" + $script:ui.Reset) }
        return $false
    } }
function Say { param([string]$Message, [string]$Level = 'INFO')
    # One timed line on screen, wrapped so later lines continue under the message; the same
    # line, unwrapped and with the date, in the run log.
    $c = $script:ui.Text
    if ($Level -eq 'OK') { $c = $script:ui.Ok } elseif ($Level -eq 'WARN') { $c = $script:ui.Caution } elseif ($Level -eq 'ERROR') { $c = $script:ui.Warn }
    $prefix = '[{0}] [{1,-5}] ' -f (Get-Date -Format 'HH:mm:ss'), $Level
    foreach ($l in (Get-HangingLines -Prefix $prefix -Text $Message)) { Write-Host ($c + $l + $script:ui.Reset) }
    if ($script:RunLog) { $null = Add-LogLine -Path $script:RunLog -Lines ('{0} [{1}] {2}' -f (Get-Date -Format 's'), $Level, $Message) } }
function Write-ErrorEntry { param([string]$Message, [string]$Stage, [System.Management.Automation.ErrorRecord]$Record)
    # The screen gets the message; the error log also gets the line and statement that failed.
    Say $Message 'ERROR'
    if (-not $script:ErrorPath) { return }
    $stamp = (Get-Date).ToString('o')
    $st = ''; if ($Stage) { $st = " [$Stage]" }
    $lines = @("$stamp [ERROR]$st " + ($Message -replace '\s+', ' ').Trim())
    if ($Record -and $Record.InvocationInfo -and $Record.InvocationInfo.Line) {
        $lines += "$stamp [ERROR]   at line $($Record.InvocationInfo.ScriptLineNumber): " + ([string]$Record.InvocationInfo.Line).Trim() }
    $null = Add-LogLine -Path $script:ErrorPath -Lines $lines -Header "# $($script:Name) error log - created $stamp" }
function Write-AuditEntry { param([string]$Outcome, [string]$Stage, [string]$Detail)
    # One key=value line per run, on every exit path.
    if (-not $script:AuditPath -or $script:AuditWritten) { return }
    $mode = 'install'; if ($CheckOnly) { $mode = 'check' }
    $f = [ordered]@{ time=(Get-Date).ToString('o'); user=[Environment]::UserName; host=[Environment]::MachineName
        script=$script:Name; version=$script:Version; mode=$mode; outcome=$Outcome }
    if ($Stage) { $f['stage'] = $Stage }
    if ($script:AuditArch) { $f['arch'] = $script:AuditArch }
    $f['before'] = $script:AuditBefore
    if ($script:AuditPackage) { $f['package'] = $script:AuditPackage }
    if ($script:AuditAfter) { $f['after'] = $script:AuditAfter }
    $f['durationSec'] = [math]::Round(((Get-Date) - $script:Started).TotalSeconds, 1)
    if ($Detail) { $f['detail'] = ($Detail -replace '\s+', ' ').Trim() }
    $line = ($f.GetEnumerator() | ForEach-Object { $v = [string]$_.Value
        if ($v -match '[\s"]') { '{0}="{1}"' -f $_.Key, ($v -replace '"', "'") } else { '{0}={1}' -f $_.Key, $v } }) -join ' '
    if (Add-LogLine -Path $script:AuditPath -Lines $line -Header ("# $($script:Name) audit log - append only - created " + (Get-Date).ToString('o'))) { $script:AuditWritten = $true } }
function Remove-WorkDir {
    try { if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir)) { Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue } } catch { } }
function Write-InstalledState {
    # A failed run still ends by saying which PowerShell 7 is installed. It is read again from
    # pwsh.exe, never assumed (a failed msiexec may or may not have rolled back), and the audit
    # line's after= takes that reading. Silent until pwsh.exe's path is known.
    if (-not $script:Exe) { return }
    $now = $null
    try { $now = Get-InstalledPwsh -Exe $script:Exe } catch { }
    $script:AuditAfter = 'none'; if ($now) { $script:AuditAfter = [string]$now }
    $what = 'no PowerShell 7'; if ($now) { $what = "PowerShell $now" }
    $dir = $script:PwshDir
    if ($script:AuditAfter -eq $script:AuditBefore) { Say "Installed now: $what in $dir (unchanged)." }
    elseif ($script:AuditBefore -eq 'none') { Say "Installed now: $what in $dir (none before this run)." 'WARN' }
    else { Say "Installed now: $what in $dir (PowerShell $($script:AuditBefore) before this run)." 'WARN' } }
function Stop-Run { param([string]$Message, [string]$Stage, [int]$Code = 1, [System.Management.Automation.ErrorRecord]$Record)
    Write-ErrorEntry -Message $Message -Stage $Stage -Record $Record
    try { Write-InstalledState } catch { }
    Write-AuditEntry -Outcome 'FAILED' -Stage $Stage -Detail $Message
    Remove-WorkDir
    exit $Code }
function Repair-QuotedPath { param([string]$Value)
    # A quoted folder that ends in a backslash ("D:\IT Logs\") reaches a script started from
    # cmd.exe as D:\IT Logs" : the backslash escapes the closing quote. No Windows path holds a
    # quote, so a trailing one stands for that backslash, and the backslash is put back. The
    # value then still names a folder: a log folder that does not exist yet would otherwise
    # become a file of that name.
    $v = ([string]$Value).Trim()
    if ($v.EndsWith('"')) { $v = $v.TrimEnd('"'); if ($v -and -not $v.EndsWith('\')) { $v = $v + '\' } }
    return $v }

# ----------------------------------------------------------------------- web
function Get-WebException { param($Exception)
    # .NET methods called from PowerShell wrap what they throw; find the WebException inside.
    $e = $Exception
    while ($e) { if ($e -is [System.Net.WebException]) { return $e }; $e = $e.InnerException }
    return $null }
function Get-HttpStatus { param($Exception)
    $we = Get-WebException $Exception
    if ($we -and $we.Response) { try { return [int]$we.Response.StatusCode } catch { } }
    return 0 }
function Get-ErrorText { param($Exception)
    $e = Get-WebException $Exception
    if (-not $e) { $e = $Exception; if ($e -is [System.Management.Automation.MethodInvocationException] -and $e.InnerException) { $e = $e.InnerException } }
    return ([string]$e.Message -replace '\s+', ' ').Trim().TrimEnd('.') }
function Initialize-Network {
    # TLS 1.2 at least (Windows PowerShell 5.1 can default to older protocols), and the system
    # proxy, when one is set, with the signed-in account's own Windows credentials.
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    try { $p = [Net.WebRequest]::DefaultWebProxy; if ($p) { $p.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials } } catch { } }
function New-WebClient {
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add('User-Agent', $script:UserAgent)
    $wc.Encoding = [System.Text.Encoding]::UTF8
    return $wc }
function Invoke-WithRetry {
    # Runs a script block, retrying on failure with a pause that grows with each try. HTTP
    # 403/429 (rate limit) gets a longer pause than a plain socket error; 404 is not retried.
    param([scriptblock]$Action, [string]$Description, [int]$Attempts = $MaxAttempts, [int]$DelaySeconds = $RetryDelaySeconds)
    for ($i = 1; $i -le $Attempts; $i++) {
        try { return (& $Action) }
        catch {
            $code = Get-HttpStatus $_.Exception
            if ($code -eq 404 -or $i -ge $Attempts) { throw }
            $wait = $DelaySeconds * $i
            if ($code -eq 403 -or $code -eq 429) { $wait = $DelaySeconds * $i * 3 }
            $suffix = ''; if ($code) { $suffix = " (HTTP $code)" }
            Say ("$Description, try $i of $Attempts failed$suffix - " + (Get-ErrorText $_.Exception) + ". Retrying in $wait s.") 'WARN'
            Start-Sleep -Seconds $wait
        }
    } }
function Get-WebText { param([string]$Url, [string]$Description, [string]$Accept)
    return (Invoke-WithRetry -Description $Description -Action {
        $wc = New-WebClient
        if ($Accept) { $wc.Headers.Add('Accept', $Accept) }
        try { $wc.DownloadString($Url) } finally { $wc.Dispose() } }) }
function Save-WebFile { param([string]$Url, [string]$Path, [long]$MinBytes = 0)
    $null = Invoke-WithRetry -Description ('Download of ' + (Split-Path -Leaf $Path)) -Action {
        # Clear any partial file left behind by a previous try.
        if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
        $wc = New-WebClient
        try { $wc.DownloadFile($Url, $Path) } finally { $wc.Dispose() }
        # A truncated or empty file counts as a failure worth retrying.
        $len = (Get-Item -LiteralPath $Path).Length
        if ($len -lt $MinBytes) { throw "the file is only $len bytes - treating it as incomplete" } } }
function Wait-ForNetwork { param([int]$TimeoutSeconds)
    # Startup and logon scripts routinely fire before DNS and the network adapter are ready.
    # Waits until github.com resolves, or the time runs out. Behind a proxy the proxy resolves
    # names, so there is nothing to wait for here.
    if ($TimeoutSeconds -le 0) { return $true }
    $probe = 'github.com'
    try {
        $p = [Net.WebRequest]::DefaultWebProxy
        if ($p -and -not $p.IsBypassed((New-Object System.Uri ('https://' + $probe + '/')))) { return $true }
    } catch { }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds); $first = $true
    while ($true) {
        try { $null = [Net.Dns]::GetHostAddresses($probe); if (-not $first) { Say "Network ready - $probe resolves." }; return $true } catch { }
        if ($first) { Say "Waiting up to $TimeoutSeconds s for the network ($probe does not resolve yet) ..."; $first = $false }
        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Seconds 5
    }
    Say "The network wait ran out after $TimeoutSeconds s ($probe still does not resolve). Trying anyway." 'WARN'
    return $false }

# ------------------------------------------------------------ release lookup
function ConvertFrom-ReleaseUrl { param([string]$Url)
    # .../PowerShell/releases/tag/v7.5.4 -> 7.5.4. A preview tag (v7.6.0-preview.5) is no match.
    if ($Url -match '/releases/tag/v(\d+\.\d+\.\d+)(?:[/?#]|$)') { return [version]$Matches[1] }
    return $null }
function Get-StableVersionFromRedirect {
    # Microsoft's stable-release link redirects to the GitHub page of the current stable tag.
    # Following it hop by hop costs no GitHub API request (those are limited to 60 an hour
    # per address). Returns the version, or $null.
    $url = 'https://aka.ms/powershell-release?tag=stable'
    try {
        for ($hop = 0; $hop -lt 6; $hop++) {
            $req = [System.Net.HttpWebRequest]::Create($url)
            $req.AllowAutoRedirect = $false; $req.UserAgent = $script:UserAgent; $req.Timeout = 20000
            $resp = $null
            try { $resp = $req.GetResponse() }
            catch { $we = Get-WebException $_.Exception; if ($we -and $we.Response) { $resp = $we.Response } else { throw } }
            $loc = $resp.Headers['Location']; $resp.Close()
            if (-not $loc) { break }
            $v = ConvertFrom-ReleaseUrl $loc
            if ($v) { return $v }
            $url = (New-Object System.Uri -ArgumentList (New-Object System.Uri $url), $loc).AbsoluteUri
        }
        Say "Microsoft's stable-release link did not lead to a release page." 'WARN'
    } catch { Say ("Microsoft's stable-release link did not answer: " + (Get-ErrorText $_.Exception)) 'WARN' }
    return $null }
function Get-PublishedHash { param([string]$Text, [string]$FileName)
    # A hashes.sha256 line holds a 64-digit SHA-256 and a file name (either order, the name
    # perhaps after a '*'). The name must match exactly: the .msix of the same release must
    # not be mistaken for the .msi. Returns the hash in capitals, or $null.
    foreach ($line in ([string]$Text -split "`r?`n")) {
        $t = @(($line.Trim().TrimStart([char]0xFEFF).Trim() -split '\s+') | ForEach-Object { $_.TrimStart('*') } | Where-Object { $_ })
        if ($t -icontains $FileName) { foreach ($w in $t) { if ($w -match '^[0-9A-Fa-f]{64}$') { return $w.ToUpperInvariant() } } }
    }
    return $null }
function Select-MsiRelease { param($Releases, [string]$Arch)
    # From GitHub API release objects: the highest stable version (no draft, no preview) that
    # has PowerShell-<version>-win-<arch>.msi. Some releases are published as MSIX only, so a
    # plain "latest release" lookup can land on one with no MSI; those are skipped here.
    $pick = $null; $newest = $null
    foreach ($r in @($Releases)) {
        if (-not $r -or $r.draft -or $r.prerelease) { continue }
        if ([string]$r.tag_name -notmatch '^v(\d+\.\d+\.\d+)$') { continue }
        $v = [version]$Matches[1]
        if (-not $newest -or $v -gt $newest) { $newest = $v }
        $name = "PowerShell-$v-win-$Arch.msi"
        $asset = $null; $hashUrl = $null
        foreach ($a in @($r.assets)) {
            if ([string]$a.name -ieq $name) { $asset = $a }
            elseif ([string]$a.name -ieq 'hashes.sha256') { $hashUrl = [string]$a.browser_download_url }
        }
        if (-not $asset) { continue }
        if ($pick -and $v -le $pick.Version) { continue }
        $digest = $null
        if ([string]$asset.digest -match '^sha256:([0-9A-Fa-f]{64})$') { $digest = $Matches[1].ToUpperInvariant() }
        $pick = [pscustomobject]@{ Version = $v; Tag = [string]$r.tag_name; MsiName = $name
            MsiUrl = [string]$asset.browser_download_url; HashUrl = $hashUrl; Digest = $digest }
    }
    return [pscustomobject]@{ Pick = $pick; NewestStable = $newest } }
function Get-ReleaseFromApi { param([string]$Arch)
    # Up to 30 releases, in pages of 10. The list is newest first by date, and a later page can
    # still hold a higher version (an older line's update comes out later), so all are read
    # before choosing. Small pages also stay well inside what Windows PowerShell parses.
    $all = New-Object System.Collections.Generic.List[object]
    for ($page = 1; $page -le 3; $page++) {
        $json = Get-WebText -Url "https://api.github.com/repos/PowerShell/PowerShell/releases?per_page=10&page=$page" -Description 'GitHub releases API' -Accept 'application/vnd.github+json'
        $list = ConvertFrom-Json -InputObject $json
        if (-not $list) { break }
        foreach ($r in $list) { $all.Add($r) }
        if (@($list).Count -lt 10) { break }
    }
    return (Select-MsiRelease -Releases $all -Arch $Arch) }
function Resolve-Release { param([string]$Arch)
    # The release to install: version, MSI name and address, and the SHA-256 Microsoft published
    # for it (none when it could not be read). $null when no stable release has an MSI here.
    $stable = Get-StableVersionFromRedirect
    if ($stable) {
        $name = "PowerShell-$stable-win-$Arch.msi"
        $base = "https://github.com/PowerShell/PowerShell/releases/download/v$stable"
        $text = $null
        try { $text = Get-WebText -Url "$base/hashes.sha256" -Description "hashes.sha256 of v$stable" }
        catch { Say ("The hashes.sha256 of v$stable could not be read: " + (Get-ErrorText $_.Exception)) 'WARN' }
        $hash = $null; if ($text) { $hash = Get-PublishedHash -Text $text -FileName $name }
        if ($hash) {
            Say "Current stable release: v$stable (Microsoft's stable-release link); it has $name."
            return [pscustomobject]@{ Version = $stable; Tag = "v$stable"; MsiName = $name; MsiUrl = "$base/$name"
                Sha256 = $hash; HashSource = "the hashes.sha256 of v$stable"; NewestStable = $stable }
        }
        if ($text) { Say "Current stable release v$stable has no $name. Looking for the newest release that has one." 'WARN' }
    }
    Say 'Asking the GitHub releases API ...'
    $res = Get-ReleaseFromApi -Arch $Arch
    $p = $res.Pick
    if (-not $p) { return $null }
    $newest = $res.NewestStable
    if ($stable -and (-not $newest -or $stable -gt $newest)) { $newest = $stable }
    $hash = $null; $src = ''
    $hashUrl = $p.HashUrl
    if (-not $hashUrl) { $hashUrl = "https://github.com/PowerShell/PowerShell/releases/download/$($p.Tag)/hashes.sha256" }
    try { $hash = Get-PublishedHash -Text (Get-WebText -Url $hashUrl -Description "hashes.sha256 of $($p.Tag)") -FileName $p.MsiName; $src = "the hashes.sha256 of $($p.Tag)" }
    catch { Say ("The hashes.sha256 of $($p.Tag) could not be read: " + (Get-ErrorText $_.Exception)) 'WARN' }
    if (-not $hash -and $p.Digest) { $hash = $p.Digest; $src = "GitHub's recorded digest of $($p.MsiName)" }
    if ($newest -and $p.Version -lt $newest) { Say "The newest stable release, v$newest, has no MSI for win-$Arch; using $($p.Tag), the newest that has one." 'WARN' }
    else { Say "Newest stable release with an MSI: $($p.Tag) (GitHub releases API)." }
    return [pscustomobject]@{ Version = $p.Version; Tag = $p.Tag; MsiName = $p.MsiName; MsiUrl = $p.MsiUrl
        Sha256 = $hash; HashSource = $src; NewestStable = $newest } }

# ------------------------------------------------------------- this computer
function Get-ProgramFiles64 {
    # The 64-bit Program Files also from a 32-bit PowerShell, where ProgramFiles is the x86 one.
    if ($env:ProgramW6432) { return $env:ProgramW6432 }
    return $env:ProgramFiles }
function Get-WindowsArch {
    # The processor type of Windows itself, not of this process: an x64 PowerShell emulated on
    # Arm64, or a 32-bit one on x64, reports its own type in PROCESSOR_ARCHITECTURE.
    $a = $null
    try { $a = [string](Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name 'PROCESSOR_ARCHITECTURE' -ErrorAction Stop).PROCESSOR_ARCHITECTURE } catch { }
    if (-not $a) { $a = $env:PROCESSOR_ARCHITEW6432 }
    if (-not $a) { $a = $env:PROCESSOR_ARCHITECTURE }
    switch ([string]$a) {
        'AMD64' { return 'x64' }
        'ARM64' { return 'arm64' }
        'x86'   { return 'x86' }
    }
    return $null }
function Get-InstalledPwsh { param([string]$Exe)
    # The stable MSI puts pwsh.exe in <Program Files>\PowerShell\7 (a preview goes to 7-preview
    # and does not count). Its product version starts with the release number.
    if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) { return $null }
    try {
        $raw = [string](Get-Item -LiteralPath $Exe).VersionInfo.ProductVersion
        if ($raw -match '^(\d+\.\d+\.\d+)') { return [version]$Matches[1] }
    } catch { }
    return $null }
function Test-PwshStarts { param([string]$Exe)
    # Starts the installed pwsh.exe once and returns the version it reports, or $null.
    # (Windows PowerShell 5.1 turns a native program's error output into errors, which
    # 'Stop' would make fatal, so this runs with 'Continue'.)
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe -NoLogo -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()' 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) { return ([string](@($out)[-1])).Trim() }
    } catch { } finally { $ErrorActionPreference = $eap }
    return $null }
function Get-ProcessTable {
    # Every process: its ID, its parent's ID, its name and when it started (Win32_Process).
    return @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId, Name, CreationDate -ErrorAction Stop) }
function Get-SshSession {
    # Why this run counts as one inside an SSH session, or $null. OpenSSH sets SSH_CONNECTION and
    # SSH_CLIENT in each session, and a program started in one has sshd among its parent processes
    # (sshd-session in OpenSSH 9.8 and later), also when those variables were cleared on the way.
    # A parent's process ID can belong to a later program by now, so the walk stops at a "parent"
    # that started after its child. $script:SshCheckNote says when the parents could not be read.
    $script:SshCheckNote = $null
    foreach ($n in @('SSH_CONNECTION', 'SSH_CLIENT')) {
        $v = ([string][Environment]::GetEnvironmentVariable($n)).Trim()
        if ($v) { return ($n + ' is set: a session from ' + @($v -split '\s+')[0]) } }
    $byId = @{}
    try { foreach ($p in @(Get-ProcessTable)) { $byId[[string]$p.ProcessId] = $p } }
    catch { $script:SshCheckNote = 'The parent processes could not be read (' + (Get-ErrorText $_.Exception) + '), so only SSH_CONNECTION and SSH_CLIENT showed whether this runs in an SSH session.'; return $null }
    $cur = $byId[[string]$PID]; $seen = @{}
    for ($hop = 0; $cur -and $hop -lt 64; $hop++) {
        $seen[[string]$cur.ProcessId] = $true
        $parentId = [string]$cur.ParentProcessId
        if (-not $parentId -or $parentId -eq '0' -or $seen.ContainsKey($parentId)) { break }
        $par = $byId[$parentId]
        if (-not $par) { break }
        if ($par.CreationDate -and $cur.CreationDate -and $par.CreationDate -gt $cur.CreationDate) { break }
        if ([string]$par.Name -match '^sshd(-[a-z]+)?\.exe$') { return ('its parent process ' + $par.Name + ' (process ' + $parentId + ') is the OpenSSH server') }
        $cur = $par
    }
    return $null }
function Find-StagedMsi { param([string]$Source, [string]$Arch)
    # -MsiSource: a file, or a folder holding PowerShell-<version>-win-<arch>.msi. In a folder
    # the highest version wins, compared as versions (7.10 is newer than 7.9, which a sort by
    # name gets wrong). Previews and other processor types are left out.
    $script:StagedProblem = $null
    $rx = '^PowerShell-(\d+\.\d+\.\d+)-win-' + [regex]::Escape($Arch) + '\.msi$'
    if (Test-Path -LiteralPath $Source -PathType Container) {
        $best = $null
        foreach ($f in @(Get-ChildItem -LiteralPath $Source -Filter '*.msi' -File -ErrorAction SilentlyContinue)) {
            if ($f.Name -match $rx) {
                $v = [version]$Matches[1]
                if (-not $best -or $v -gt $best.Version) { $best = [pscustomobject]@{ Path = $f.FullName; Name = $f.Name; Version = $v } }
            }
        }
        return $best
    }
    if (Test-Path -LiteralPath $Source -PathType Leaf) {
        $f = Get-Item -LiteralPath $Source
        if ($f.Name -match $rx) { return [pscustomobject]@{ Path = $f.FullName; Name = $f.Name; Version = [version]$Matches[1] } }
        $script:StagedProblem = "$($f.Name) is not named PowerShell-<version>-win-$Arch.msi, the name Microsoft gives the package for this processor (the name is how the version is known)"
    }
    return $null }
function Test-MsiSignature { param([string]$Path)
    # $null when the package carries a valid Authenticode signature from Microsoft, otherwise
    # the reason it does not.
    try { $sig = Get-AuthenticodeSignature -LiteralPath $Path } catch { return ('its signature could not be read: ' + (Get-ErrorText $_.Exception)) }
    if ([string]$sig.Status -ne 'Valid') { return ("its signature is $($sig.Status): " + ([string]$sig.StatusMessage).Trim()) }
    $subject = ''; if ($sig.SignerCertificate) { $subject = [string]$sig.SignerCertificate.Subject }
    if ($subject -notmatch 'O=Microsoft Corporation') { return "it is signed by $subject, not by Microsoft" }
    return $null }
function Invoke-MsiInstall { param([string[]]$Arguments)
    # 1618 = another installation holds the Windows Installer mutex: common at start-up, while
    # Windows Update or a management agent is busy. Back off and retry.
    $msiexec = Join-Path $env:SystemRoot 'System32\msiexec.exe'
    $rc = 1618
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $proc = Start-Process -FilePath $msiexec -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
        $rc = $proc.ExitCode
        if ($rc -ne 1618) { break }
        if ($attempt -eq $MaxAttempts) { Say "Windows Installer stayed busy through $MaxAttempts tries (1618)." 'WARN'; break }
        $wait = $RetryDelaySeconds * $attempt * 3
        Say "Windows Installer is busy with another installation (1618), try $attempt of $MaxAttempts. Retrying in $wait s." 'WARN'
        Start-Sleep -Seconds $wait
    }
    return $rc }

# ====================================================================== main
Initialize-UiStyle
Show-LaunchNotice
# cmd.exe's own help switch: /? (or /help) on its own asks for the same as -Help.
$wantHelp = [bool]$Help
if (($script:Supplied -contains 'Unexpected') -and @($Unexpected).Count -eq 1 -and (@('/?', '/help') -contains [string]$Unexpected[0])) { $wantHelp = $true }
if ($wantHelp) { Show-Help; return }

# Anything not handled below still gets an error-log line, an audit line and exit code 1.
trap {
    $why = Get-ErrorText $_.Exception
    Write-ErrorEntry -Message ('Unexpected error: ' + $why + '.') -Stage 'unexpected' -Record $_
    try { Write-InstalledState } catch { }
    Write-AuditEntry -Outcome 'FAILED' -Stage 'unexpected' -Detail $why
    Remove-WorkDir
    exit 1
}

# ---- a command line this script cannot fully read is refused before anything is done. That
# happens before any log is opened, like a parameter PowerShell itself cannot bind: the stray
# words may be the rest of a log path (D:\IT Logs typed without quotes), so no path on this
# command line is trusted. (Bound, not truthy: one empty argument, "", is refused too.)
if ($script:Supplied -contains 'Unexpected') {
    $words = ($Unexpected -join ' ').Trim(); if (-not $words) { $words = '(an empty argument)' }
    Stop-Run ('Not a parameter of this script: ' + $words + '. Its parameters are all named with a dash, as -Help lists them (for example -CheckOnly, or -MsiSource <path>), and a path with spaces needs quotes. Nothing was changed.') 'args' }
$MsiSource = Repair-QuotedPath $MsiSource
$LogRoot   = Repair-QuotedPath $LogRoot
$AuditLog  = Repair-QuotedPath $AuditLog
$ErrorLog  = Repair-QuotedPath $ErrorLog
# A quote left inside a value comes from a quoted folder ending in a backslash that was not the
# last argument: Windows then joins the rest of the command line to it ("D:\IT Logs\" -CheckOnly
# arrives as the one value D:\IT Logs" -CheckOnly), so the switches after it never arrive. A run
# on half a command line could install when only a check was asked for.
foreach ($p in @(@('MsiSource', $MsiSource), @('LogRoot', $LogRoot), @('AuditLog', $AuditLog), @('ErrorLog', $ErrorLog))) {
    if (([string]$p[1]).Contains('"')) {
        Stop-Run ("-$($p[0]) is not a usable path, it holds a quote: $($p[1]). A quoted folder that ends in a backslash (""D:\IT Logs\"") makes Windows read \"" as part of the value, so the rest of the command line joined it. End such a folder with two backslashes (""D:\IT Logs\\""), or leave out the quotes when the path has no spaces. Nothing was changed.") 'args' }
}

# ---- logs: explicit paths first, so that a failure below is recorded where asked
try { $script:AuditPath = Resolve-LogPath -Value $AuditLog -DefaultName 'Install-PowerShell7-audit.log' }
catch { Stop-Run ("The audit log $AuditLog cannot be used: " + (Get-ErrorText $_.Exception) + '.') 'args' }
try { $script:ErrorPath = Resolve-LogPath -Value $ErrorLog -DefaultName 'Install-PowerShell7-errors.log' }
catch { Stop-Run ("The error log $ErrorLog cannot be used: " + (Get-ErrorText $_.Exception) + '.') 'args' }
$defaultRoot = $false
if (-not $LogRoot -and $env:ProgramData) { $LogRoot = Join-Path $env:ProgramData 'PS7Deploy'; $defaultRoot = $true }
if ($LogRoot) {
    try {
        if (-not (Test-Path -LiteralPath $LogRoot -PathType Container)) { $null = New-Item -ItemType Directory -Path $LogRoot -Force }
        # One run log per run, also when two runs start in the same second (the msiexec log
        # takes the same tag).
        $tag = $script:Stamp; $n = 1
        while (Test-Path -LiteralPath (Join-Path $LogRoot ('Install-PowerShell7_' + $tag + '.log'))) { $n++; $tag = $script:Stamp + '-' + $n }
        $script:Stamp = $tag
        $script:RunLog = Join-Path $LogRoot ('Install-PowerShell7_' + $script:Stamp + '.log')
    } catch {
        $why = Get-ErrorText $_.Exception
        if (-not $defaultRoot) { Stop-Run "The log folder $LogRoot cannot be created: $why." 'args' }
        Say "The log folder $LogRoot cannot be created ($why). Logging to the screen only." 'WARN'
        $LogRoot = $null
    }
}
if ($LogRoot -and -not $script:AuditPath) { $script:AuditPath = Join-Path $LogRoot 'Install-PowerShell7-audit.log' }
if ($LogRoot -and -not $script:ErrorPath) { $script:ErrorPath = Join-Path $LogRoot 'Install-PowerShell7-errors.log' }

# ---- arguments, then switch conflicts (silent when the command line is clean)
if ($MaxAttempts -lt 1 -or $MaxAttempts -gt 20) { Stop-Run "-MaxAttempts must be from 1 to 20 (it is $MaxAttempts)." 'args' }
if ($RetryDelaySeconds -lt 0 -or $RetryDelaySeconds -gt 600) { Stop-Run "-RetryDelaySeconds must be from 0 to 600 (it is $RetryDelaySeconds)." 'args' }
if ($NetworkWaitSeconds -lt 0 -or $NetworkWaitSeconds -gt 3600) { Stop-Run "-NetworkWaitSeconds must be from 0 to 3600 (it is $NetworkWaitSeconds)." 'args' }
if (($script:Supplied -contains 'MsiSource') -and [string]::IsNullOrWhiteSpace($MsiSource)) { Stop-Run '-MsiSource needs an MSI file, or a folder holding one.' 'args' }
if ($CheckOnly) {
    foreach ($n in 'EnablePSRemoting','NoMicrosoftUpdate') { if ($script:Supplied -contains $n) { Say "[ignored] -$n has no effect with -CheckOnly: nothing is installed." 'WARN' } }
}

# ---- Windows only. (Windows PowerShell 5.1 has no $IsWindows; it only runs on Windows.)
$onWindows = ($PSVersionTable.PSEdition -ne 'Core') -or $IsWindows
if (-not $onWindows) {
    $hint = ''
    if ($IsMacOS -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'install-powershell7-macos.sh'))) { $hint = ' To update it on macOS, use install-powershell7-macos.sh in this folder.' }
    Stop-Run ("This script installs PowerShell 7 on Windows only. This computer already runs PowerShell $($PSVersionTable.PSVersion).$hint") 'precheck'
}

# ---- this computer
Initialize-Network
$isAdmin = $false
try { $isAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { }
$arch = Get-WindowsArch
if (-not $arch) { Stop-Run "This computer's processor type ($env:PROCESSOR_ARCHITECTURE) has no PowerShell 7 MSI." 'precheck' }
$script:AuditArch = $arch
$exe = Join-Path (Get-ProgramFiles64) 'PowerShell\7\pwsh.exe'
$pwshDir = Split-Path -Parent $exe
$before = Get-InstalledPwsh -Exe $exe
if ($before) { $script:AuditBefore = [string]$before }
$script:Exe = $exe; $script:PwshDir = $pwshDir
$edition = 'Windows PowerShell'; if ($PSVersionTable.PSEdition -eq 'Core') { $edition = 'PowerShell' }
$elev = ', not elevated'; if ($isAdmin) { $elev = ', elevated' }
Say ("{0}: Windows {1}, {2}. Running in {3} {4}{5}." -f $env:COMPUTERNAME, [Environment]::OSVersion.Version, $arch, $edition, $PSVersionTable.PSVersion, $elev)
if ($before) { Say "Installed now: PowerShell $before ($exe)." } else { Say "Installed now: no PowerShell 7 in $pwshDir." }
if (-not $CheckOnly -and -not $isAdmin) {
    Stop-Run 'Installing needs an elevated session. Open Windows PowerShell with Run as administrator and run this again, or double-click Install-PowerShell7.cmd, which asks for elevation. (-CheckOnly needs no elevation.)' 'precheck' }
# ---- not inside an SSH session. Replacing PowerShell 7 over SSH can end the session that runs
# this (above all when pwsh is the OpenSSH default shell), and the install with it, half-way. So
# every run but -CheckOnly stops here, before the release lookup, before -MsiSource is read and
# before anything is downloaded, also when PowerShell 7 would turn out to be current: over SSH the
# same command line gives the same answer whatever is installed or published.
if (-not $CheckOnly) {
    $ssh = Get-SshSession
    if ($script:SshCheckNote) { Say ('[note] ' + $script:SshCheckNote) 'WARN' }
    if ($ssh) {
        Stop-Run ("This run is inside an SSH session ($ssh), so PowerShell 7 is not installed or updated: replacing PowerShell 7 over SSH can end the session and stop the install half-way, especially when the OpenSSH default shell is pwsh. Run this at the console, by Remote Desktop, or through WinRM (Enter-PSSession or Invoke-Command) instead. -CheckOnly works over SSH. Nothing was changed.") 'precheck' }
}

# ---- the package: a pre-staged MSI wins, GitHub is the fallback
$offline = ' For a computer without Internet access: on another computer, download the MSI and hashes.sha256 from https://github.com/PowerShell/PowerShell/releases into one folder, then run this with -MsiSource <that folder>.'
$pkg = $null
if ($MsiSource) {
    $staged = $null
    try { $staged = Find-StagedMsi -Source $MsiSource -Arch $arch } catch { $script:StagedProblem = Get-ErrorText $_.Exception }
    if ($staged) {
        Say "Pre-staged package: $($staged.Path) (version $($staged.Version))."
        $pkg = [pscustomobject]@{ Version = $staged.Version; MsiName = $staged.Name; From = 'staged'; Path = $staged.Path; MsiUrl = $null; Sha256 = $null; HashSource = '' }
    } else {
        $why = $script:StagedProblem
        if (-not $why -and -not (Test-Path -LiteralPath $MsiSource)) { $why = 'that path does not exist or cannot be reached from this session' }
        if (-not $why) { $why = "it holds no PowerShell-<version>-win-$arch.msi" }
        Say "-MsiSource $MsiSource is not used: $why. Downloading instead." 'WARN'
    }
}
if (-not $pkg) {
    $null = Wait-ForNetwork -TimeoutSeconds $NetworkWaitSeconds
    Say "Looking for the newest stable PowerShell 7 release with an MSI for win-$arch ..."
    $rel = $null
    try { $rel = Resolve-Release -Arch $arch }
    catch { Stop-Run ('The release lookup failed: ' + (Get-ErrorText $_.Exception) + '.' + $offline) 'lookup' -Record $_ }
    if (-not $rel) { Stop-Run ("No stable PowerShell 7 release with an MSI for win-$arch was found." + $offline) 'lookup' }
    $pkg = [pscustomobject]@{ Version = $rel.Version; MsiName = $rel.MsiName; From = 'download'; Path = $null; MsiUrl = $rel.MsiUrl; Sha256 = $rel.Sha256; HashSource = $rel.HashSource }
}
$script:AuditPackage = $pkg.MsiName

# ---- idempotent: an equal or newer installed version is left alone
if ($before -and $before -ge $pkg.Version) {
    $script:AuditAfter = [string]$before
    if ($before -gt $pkg.Version) { Say "PowerShell $before is installed, newer than the package ($($pkg.Version)). Nothing to do." 'OK' }
    else { Say "PowerShell $before is installed and current. Nothing to do." 'OK' }
    if (-not $CheckOnly) {
        if ($EnablePSRemoting) { Say '[note] -EnablePSRemoting changed nothing, because nothing was installed. To turn the endpoints on, run Enable-PSRemoting in PowerShell 7 (pwsh) opened as administrator.' 'WARN' }
        if ($NoMicrosoftUpdate) { Say '[note] -NoMicrosoftUpdate changed nothing, because nothing was installed: the Microsoft Update choice made at the last install stays.' 'WARN' }
    }
    Say "Result: no change. PowerShell $before is installed in $pwshDir." 'OK'
    Write-AuditEntry -Outcome 'SUCCESS' -Stage 'current'
    exit 0
}
if ($CheckOnly) {
    if ($before) { Say "Update available: PowerShell $before -> $($pkg.Version). Run this again without -CheckOnly to install it." 'OK' }
    else { Say "PowerShell 7 is not installed; $($pkg.Version) would be. Run this again without -CheckOnly to install it." 'OK' }
    $script:AuditAfter = $script:AuditBefore
    Write-AuditEntry -Outcome 'SUCCESS' -Stage 'check' -Detail ('available=' + $pkg.Version)
    exit 0
}

# ---- before installing: not from inside the PowerShell 7 that would be replaced. (A run inside
# an SSH session stopped before the lookup; -CheckOnly, and a run that finds PowerShell 7
# current, ended above.)
if ($PSVersionTable.PSEdition -eq 'Core' -and $PSHOME -and ($PSHOME.TrimEnd('\') -ieq $pwshDir.TrimEnd('\'))) {
    Stop-Run ("This window runs the PowerShell 7 that the update would replace ($PSHOME). Start the update from Windows PowerShell instead: double-click Install-PowerShell7.cmd, or run powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`".") 'precheck' }
$busy = @()
# (Reading another process's path can fail; this note is advice only, so it never stops the run.)
try { $busy = @(Get-Process -Name 'pwsh' -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID -and $_.Path -and ($_.Path -like ($pwshDir + '\*')) }) } catch { $busy = @() }
if ($busy.Count) { Say ("[note] {0} PowerShell 7 process(es) are running from {1}. The installer may close them, or need a restart to finish (exit code 3010). Close them first to avoid that." -f $busy.Count, $pwshDir) 'WARN' }

# ---- the package goes to a new local folder of its own, and is checked there
$script:WorkDir = Join-Path ([IO.Path]::GetTempPath()) ('Install-PowerShell7-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $script:WorkDir
$local = Join-Path $script:WorkDir $pkg.MsiName
if ($pkg.From -eq 'staged') {
    try { Copy-Item -LiteralPath $pkg.Path -Destination $local -Force }
    catch { Stop-Run ("The package could not be copied from $($pkg.Path): " + (Get-ErrorText $_.Exception) + '.') 'copy' -Record $_ }
    $hf = Join-Path (Split-Path -Parent $pkg.Path) 'hashes.sha256'
    if (Test-Path -LiteralPath $hf -PathType Leaf) {
        $text = $null
        try { $text = [IO.File]::ReadAllText($hf) } catch { Stop-Run ("$hf cannot be read: " + (Get-ErrorText $_.Exception) + '.') 'verify' -Record $_ }
        $pkg.Sha256 = Get-PublishedHash -Text $text -FileName $pkg.MsiName
        if (-not $pkg.Sha256) { Stop-Run ("$hf does not list $($pkg.MsiName). Put the hashes.sha256 of the same release beside the package, or remove it to rely on the signature check alone.") 'verify' }
        $pkg.HashSource = $hf
    } else { Say '[note] No hashes.sha256 beside the package, so only its Microsoft signature is checked. The release page on GitHub has that file.' 'WARN' }
} else {
    # Fail closed: without the hash Microsoft published, nothing is downloaded or installed.
    if (-not $pkg.Sha256) { Stop-Run ("No SHA-256 published by Microsoft for $($pkg.MsiName) could be read, so it is not downloaded or installed. Try again later, or use -MsiSource.") 'verify' }
    Say "Downloading $($pkg.MsiName) from GitHub ..."
    try { Save-WebFile -Url $pkg.MsiUrl -Path $local -MinBytes 1MB }
    catch { Stop-Run ('The download failed: ' + (Get-ErrorText $_.Exception) + '.') 'download' -Record $_ }
    Say ('Downloaded {0:N1} MB.' -f ((Get-Item -LiteralPath $local).Length / 1MB))
}
if ($pkg.Sha256) {
    $actual = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actual -ne $pkg.Sha256) { Stop-Run ("SHA-256 MISMATCH for $($pkg.MsiName): $($pkg.HashSource) says $($pkg.Sha256), the file is $actual. Refusing to install it.") 'verify' }
    Say "SHA-256 matches $($pkg.HashSource)." 'OK'
}
$sigProblem = Test-MsiSignature -Path $local
if ($sigProblem) { Stop-Run ("Refusing to install $($pkg.MsiName): $sigProblem.") 'verify' }
Say 'Signature valid: signed by Microsoft Corporation.' 'OK'

# ---- silent install
$msiDir = $LogRoot; if (-not $msiDir) { $msiDir = [IO.Path]::GetTempPath() }
$msiLog = Join-Path $msiDir ('msiexec_' + $script:Stamp + '.log')
$remoting = 0; if ($EnablePSRemoting) { $remoting = 1 }
$mu = 1; if ($NoMicrosoftUpdate) { $mu = 0 }
$msiArgs = @(
    '/package', ('"' + $local + '"')
    '/quiet'
    '/norestart'
    'ADD_PATH=1'                                    # pwsh reachable from PATH
    'REGISTER_MANIFEST=1'                           # event log manifest
    'ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=1'    # "Open here" on folders
    'ADD_FILE_CONTEXT_MENU_RUNPOWERSHELL=1'         # "Run with PowerShell 7" on .ps1 files
    "ENABLE_PSREMOTING=$remoting"
    "USE_MU=$mu"                                    # updates via Microsoft Update, WSUS or ConfigMgr
    "ENABLE_MU=$mu"                                 # opts the computer in to Microsoft Update
    'DISABLE_TELEMETRY=1'                           # sets POWERSHELL_TELEMETRY_OPTOUT
    '/l*v', ('"' + $msiLog + '"')
)
if ($before) { Say "Updating PowerShell $before to $($pkg.Version) ..." } else { Say "Installing PowerShell $($pkg.Version) ..." }
Say ('msiexec.exe ' + ($msiArgs -join ' '))
$rc = Invoke-MsiInstall -Arguments $msiArgs
switch ($rc) {
    0    { Say 'msiexec finished: success (0).' 'OK' }
    3010 { Say 'msiexec finished: success; a restart is needed to finish (3010).' 'WARN' }
    1641 { Say 'msiexec finished: success; the installer started a restart (1641).' 'WARN' }
}
if ($rc -ne 0 -and $rc -ne 3010 -and $rc -ne 1641) {
    $why = "msiexec returned $rc. Details: $msiLog (search it for ""Return value 3"")."
    if ($rc -eq 1618) { $why = 'Windows Installer stayed busy with another installation (1618). Run this again once that has finished.' }
    # (Stop-Run reads pwsh.exe again and says what is installed now.)
    Stop-Run $why 'install' -Code $rc
}

# ---- verify, clean up, and say what was done
$restart = ($rc -eq 3010 -or $rc -eq 1641)
$after = Get-InstalledPwsh -Exe $exe
$script:AuditAfter = 'none'; if ($after) { $script:AuditAfter = [string]$after }
if (-not $after -or $after -lt $pkg.Version) {
    $seen = 'is missing'; if ($after) { $seen = "reports $after" }
    if (-not $restart) { Stop-Run ("msiexec reported success, but $exe $seen. Details: $msiLog") 'verify' }
    Say "pwsh.exe $seen until the restart, when the new files replace the old ones." 'WARN'
} else {
    $reported = Test-PwshStarts -Exe $exe
    if ($reported) { Say "Verified: pwsh.exe starts and reports $reported." 'OK' }
    else { Say "pwsh.exe is version $after, but it did not start for a test. Try it in a new window." 'WARN' }
}
Remove-WorkDir
$did = "installed PowerShell $($pkg.Version)"; if ($before) { $did = "updated PowerShell $before to $($pkg.Version)" }
$from = 'downloaded from GitHub'; if ($pkg.From -eq 'staged') { $from = 'pre-staged' }
$checks = 'signature checked'; if ($pkg.Sha256) { $checks = 'SHA-256 and signature checked' }
Say "Result: $did, from $($pkg.MsiName) ($from; $checks)." 'OK'
if ($after -and $after -ge $pkg.Version) { Say "Installed: PowerShell $after in $pwshDir." 'OK' }
else { Say "Installed: PowerShell $($pkg.Version) in $pwshDir once Windows restarts." 'WARN' }
if ($restart) { Say 'Restart Windows to finish the installation.' 'WARN' }
Say 'Open a new window to use pwsh: windows opened before the install do not see the new PATH.'
if ($script:RunLog) { Say "Logs: $($script:RunLog) and $msiLog" } else { Say "msiexec log: $msiLog" }
Write-AuditEntry -Outcome 'SUCCESS' -Stage 'install' -Detail ("msiexec=$rc")
exit $rc
