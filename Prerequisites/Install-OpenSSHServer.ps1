<#
.SYNOPSIS
    Installs OpenSSH Server on this Windows server and makes it ready for key
    sign-in: sshd starts with Windows, the public keys given are authorised
    for administrators, TCP 22 is limited to the networks named, password
    sign-in is turned off once a valid key is in place, and the host key
    fingerprint is shown for the first connection. Safe to run again: each
    step changes only what is not already right.

    Run it elevated on the server, or from a Windows admin machine:
      Invoke-Command -ComputerName <servers> `
        -FilePath .\Install-OpenSSHServer.ps1 -ArgumentList <keys>, <networks>
    Run with -Help for full usage. Windows PowerShell 5.1 compatible.
#>
[CmdletBinding(SupportsShouldProcess = $true, PositionalBinding = $false)]
param(
    [Parameter(Position = 0)]
    [string[]]$PublicKey,
    [Parameter(Position = 1)]
    [string[]]$AllowFrom,
    [string[]]$PublicKeyFile,
    [string]$Source,
    [switch]$LimitAccess,
    [switch]$KeepPasswordSignIn,
    [string]$DefaultShell = 'None',
    [switch]$Banner,
    [switch]$LoginAlert,
    [string]$AuditLog,
    [string]$ErrorLog,
    [switch]$Help
)

# Built from four earlier set-up scripts: a single-server installer, a Group Policy startup
# script (scope checked before the wide rule is touched, host-key permission repair), a key-only
# configuration script (banner, login alert, default shell) and a key push script. Site details
# were taken out; everything specific to a server is a parameter or is read from the server.

$ErrorActionPreference = 'Stop'
$script:Version   = '1.0.0'
$script:UiWidth   = 78
$script:Name      = 'Install-OpenSSHServer.ps1'
$script:Started   = Get-Date
$script:Cmdlet    = $PSCmdlet
$script:BoundKeys = @($PSBoundParameters.Keys)
$script:IsWhatIf  = [bool]$WhatIfPreference
$script:AuditPath = $null
$script:ErrorPath = $null
$script:AuditDefault = $false
$script:ErrorDefault = $false
$script:AuditWritten = $false
$script:LogWarned = $false
$script:Problems  = New-Object System.Collections.Generic.List[string]
$script:Warnings  = New-Object System.Collections.Generic.List[string]
$script:Prefix    = ''
$script:Session   = 'local'
$script:OnWindows = $false
$script:IsAdmin   = $false
$script:SshDir    = $null
$script:Pending   = $false       # -WhatIf before OpenSSH Server is installed: later steps only describe
$script:HostKeysChanged = $false
$script:ConfigChanged   = $false
$script:ConfigBackup    = $null
$script:FinalConfig     = @()
$script:ValidKeys = 0
$script:KeyFileOk = $false
$script:KeysUnreadable = ''       # how the key file is saved, while sshd cannot read all of it
$script:AddedKeys = @()
$script:SidSystem = 'S-1-5-18'       # SYSTEM
$script:SidAdmins = 'S-1-5-32-544'   # BUILTIN\Administrators
$script:SidUsers  = 'S-1-5-11'       # Authenticated Users
$script:KeyTypes  = @('ssh-ed25519', 'ecdsa-sha2-nistp256', 'ecdsa-sha2-nistp384', 'ecdsa-sha2-nistp521', 'ssh-rsa')
$script:PrivateKeyText = 'PRIVATE KEY|PuTTY-User-Key-File|Private-Lines:'   # text only a private key holds
$script:AlertSource = 'SSHLoginAlert'
$script:AlertTask   = 'SSH-Login-Alert'
$script:AlertKey    = 'HKLM:\SOFTWARE\SSHLoginAlert'
$script:Pwsh7Note = 'With PowerShell 7 as the default shell, an upgrade of PowerShell 7 started from an SSH session stops pwsh.exe, which ends the session and the upgrade with it. Upgrade PowerShell 7 from the console, over WinRM, or from an SSH session that starts Windows PowerShell (ssh <server> powershell). The Access Connector tool needs no default shell change: it starts Windows PowerShell by name.'
$script:R = [ordered]@{
    Computer = $env:COMPUTERNAME; Result = ''; OpenSSH = ''; Service = ''; HostKeys = ''
    KeysAdded = 0; KeysInFile = 0; KeyFileAccess = ''; Firewall = ''; PasswordSignIn = ''
    DefaultShell = ''; Banner = ''; LoginAlert = ''; Restarted = ''; HostKey = ''; HostPublicKey = ''
    Problems = @(); Warnings = @()
}

# The scheduled task -LoginAlert registers runs this as SYSTEM (Windows PowerShell 5.1) each time
# sshd writes an event. sshd logs every informational message under event ID 4, so only lines
# saying "Accepted <method> for" (a sign-in) raise an alert, and each event is reported once: the
# last record seen is kept in the registry. Event text is only ever written to another event,
# never run, so a name chosen by whoever connects cannot become a command.
$script:AlertCode = @'
$ErrorActionPreference = 'SilentlyContinue'
$k = 'HKLM:\SOFTWARE\SSHLoginAlert'
if (-not (Test-Path -Path $k)) { $null = New-Item -Path $k -Force }
$last = [long]0
$v = Get-ItemProperty -Path $k -Name LastRecordId
if ($v) { $last = [long]$v.LastRecordId }
$ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'OpenSSH/Operational'; Id = 4; StartTime = (Get-Date).AddHours(-1) } -MaxEvents 500 | Sort-Object RecordId)
if ($ev.Count -gt 0 -and [long]$ev[$ev.Count - 1].RecordId -lt $last) { $last = [long]0 }
foreach ($e in $ev) {
    if ([long]$e.RecordId -le $last) { continue }
    $text = [string]$e.Message
    if (-not $text) { $text = (@($e.Properties | ForEach-Object { [string]$_.Value }) -join ' ') }
    if ($text -match 'Accepted \S+ for ') {
        $msg = 'SSH sign-in on ' + $env:COMPUTERNAME + ' at ' + $e.TimeCreated.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss') + ' UTC: ' + ($text -replace '\s+', ' ').Trim()
        Write-EventLog -LogName Application -Source 'SSHLoginAlert' -EventId 1000 -EntryType Warning -Message $msg
    }
    $last = [long]$e.RecordId
}
$null = New-ItemProperty -Path $k -Name LastRecordId -Value $last -PropertyType QWord -Force
'@

# ---------------------------------------------------------------- UI helpers
function Initialize-UiStyle {
    $useColor = $true
    if ($env:NO_COLOR) { $useColor = $false }
    try { if ([Console]::IsOutputRedirected) { $useColor = $false } } catch { }
    try { if (-not $Host.UI.SupportsVirtualTerminal) { $useColor = $false } } catch { }
    if ($env:OMNISSA_UI_COLOR) { $useColor = $true }
    $e = [char]27
    $script:ui = @{}
    $keys = 'Reset','Banner','Section','Legal','Rule','Cmd','Flag','Text','Warn','Notice','Ok','Info','Caution','Dim'
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
function Write-UiRule { Write-Host ($script:ui.Rule + ('-' * $script:UiWidth) + $script:ui.Reset) }
function Write-UiSection { param([string]$Text, [switch]$Legal)
    Write-Host ''
    if ($Legal) { $tag = $script:ui.Legal } else { $tag = $script:ui.Section }
    Write-Host ($tag + ' ' + $Text + ' ' + $script:ui.Reset); Write-UiRule }
function Write-UiText { param([string]$T, [string]$I = '  ')
    foreach ($l in (Get-WrappedLines -Text $T -Width $script:UiWidth -Indent $I)) { Write-Host ($script:ui.Text + $l + $script:ui.Reset) } }
function Write-UiWarn { param([string]$T, [string]$I = '  ')
    foreach ($l in (Get-WrappedLines -Text $T -Width $script:UiWidth -Indent $I)) { Write-Host ($script:ui.Warn + $l + $script:ui.Reset) } }
function Write-UiItem { param([string]$Mark, [string]$T)
    # A numbered line whose continuation lines start under its text.
    $lead = '  ' + $Mark + ' '; $first = $true
    foreach ($l in (Get-WrappedLines -Text $T -Width ($script:UiWidth - $lead.Length))) {
        if ($first) { Write-Host ($script:ui.Text + $lead + $l + $script:ui.Reset); $first = $false }
        else { Write-Host ($script:ui.Text + (' ' * $lead.Length) + $l + $script:ui.Reset) } } }
function Write-UiCaption { param([string]$T) Write-Host ($script:ui.Dim + '  ' + $T + $script:ui.Reset) }
function Write-UiCmd { param([string]$T) Write-Host ($script:ui.Cmd + '  ' + $T + $script:ui.Reset) }
function Write-UiParam { param([string]$Flag, [string]$Desc)
    $col = 24
    $lines = @(Get-WrappedLines -Text $Desc -Width ($script:UiWidth - $col))
    $pad = "  $Flag".PadRight($col); $first = $true
    foreach ($l in $lines) {
        if ($first) { Write-Host ($script:ui.Flag + $pad + $script:ui.Reset + $script:ui.Text + $l + $script:ui.Reset); $first = $false }
        else { Write-Host ($script:ui.Text + (' ' * $col) + $l + $script:ui.Reset) } } }

# Run-time output. Through Invoke-Command several servers write at once, so every line then
# starts with the server name.
function Write-Out { param([string]$Text, [string]$Style = '')
    if (-not $Text) { Write-Host ''; return }
    Write-Host ($script:Prefix + $Style + $Text + $script:ui.Reset) }
function Say { param([string]$Message, [string]$Level = 'INFO')
    $c = $script:ui.Text
    if ($Level -eq 'OK') { $c = $script:ui.Ok }
    elseif ($Level -eq 'WARN') { $c = $script:ui.Caution }
    elseif ($Level -eq 'ERROR') { $c = $script:ui.Warn }
    elseif ($Level -eq 'STEP') { $c = $script:ui.Info }
    $lead = '[{0}] [{1,-5}] ' -f (Get-Date -Format 'HH:mm:ss'), $Level
    $w = $script:UiWidth - $script:Prefix.Length - $lead.Length
    if ($w -lt 30) { $w = 30 }
    $first = $true
    foreach ($l in @(Get-WrappedLines -Text $Message -Width $w)) {
        if ($first) { Write-Out ($lead + $l) $c; $first = $false } else { Write-Out ((' ' * $lead.Length) + $l) $c } }
    if ($first) { Write-Out $lead $c } }
function Write-Step { param([string]$Title) Write-Out ''; Say $Title 'STEP' }
function Write-Row { param([string]$Label, [string]$Value, [string]$Style = '')
    if (-not $Style) { $Style = $script:ui.Text }
    if (-not $Value) { $Value = '-' }
    $col = 22; $first = $true
    foreach ($l in @(Get-WrappedLines -Text $Value -Width ($script:UiWidth - $script:Prefix.Length - $col))) {
        if ($first) { Write-Out ($script:ui.Flag + ('  ' + $Label).PadRight($col) + $script:ui.Reset + $Style + $l); $first = $false }
        else { Write-Out ((' ' * $col) + $Style + $l) } } }
function Show-LaunchNotice {
    Write-Out ''
    Write-Out '  UNSUPPORTED - provided "AS IS", NO WARRANTY. Use at your own risk. Neither' $script:ui.Notice
    Write-Out '  Omnissa nor the author is liable for any damages. Full text: -Help' $script:ui.Notice
    Write-Out ''
}
function Show-Disclaimer {
    Write-UiSection 'LEGAL DISCLAIMER - UNSUPPORTED, USE AT YOUR OWN RISK' -Legal
    Write-UiWarn 'This script is an UNSUPPORTED utility. It is NOT an Omnissa product or offering, and it is not covered by any Omnissa support, maintenance, or service-level agreement.'
    Write-UiWarn 'It is provided "AS IS" and "AS AVAILABLE", WITHOUT WARRANTY OF ANY KIND, express or implied, including but not limited to the implied warranties of merchantability, fitness for a particular purpose, title, and non-infringement.'
    Write-UiWarn 'YOU USE IT ENTIRELY AT YOUR OWN RISK. You are solely responsible for validating its behaviour, for safeguarding the credentials you supply to it, and for any effect it has on your environment or data.'
    Write-UiWarn 'TO THE MAXIMUM EXTENT PERMITTED BY LAW, NEITHER OMNISSA NOR THE AUTHOR SHALL BE LIABLE FOR ANY CLAIM, LOSS, OR DAMAGES WHATSOEVER - direct, indirect, incidental, special, exemplary, or consequential (including loss of data, revenue, or profits) - arising from or in connection with the use of, or inability to use, this script.'
    Write-UiWarn 'This script changes Windows settings on the servers it runs on (OpenSSH Server, its configuration, the firewall, the registry and scheduled tasks); you assume all responsibility for those changes.'
}
function Show-Help {
    Write-Host ($script:ui.Banner + (" $($script:Name)  v$($script:Version) ").PadRight($script:UiWidth) + $script:ui.Reset)
    Show-Disclaimer
    Write-UiSection 'SYNOPSIS'
    Write-UiText 'Installs OpenSSH Server on a Windows server and makes it ready for key sign-in, the way the Access Connector tool signs in. sshd starts with Windows, your public keys are authorised for administrators, TCP 22 is limited to the networks you name, password sign-in is turned off once a valid key is in place, and the host key fingerprint is shown for you to check on your first connection.'
    Write-UiText 'Safe to run again: each step changes only what is not already right. Run it on the server, or on many servers at once from a Windows admin machine with Invoke-Command (see EXAMPLES).'
    Write-UiSection 'WHAT IT DOES, IN ORDER'
    Write-UiItem '1.' 'Installs the OpenSSH.Server Windows capability when there is no sshd service, from Windows Update or WSUS, or from -Source. This can take several minutes, and on Windows 10 and 11 often much longer.'
    Write-UiItem '2.' 'Checks the host keys. A key made by hand (ssh-keygen -A in an admin''s window) can carry an access entry for that admin which icacls /inheritance:r does not remove; sshd then refuses it and stops with "no hostkeys available". Such keys are reset to SYSTEM and Administrators only.'
    Write-UiItem '3.' 'Sets the sshd service to start automatically and starts it. If it does not start and there are no host keys, they are made with ssh-keygen -A and the start is tried again.'
    Write-UiItem '4.' 'Adds each key from -PublicKey and -PublicKeyFile that sshd does not yet read from C:\ProgramData\ssh\administrators_authorized_keys, the file OpenSSH reads for members of the local Administrators group, then limits that file to Administrators and SYSTEM: OpenSSH ignores it otherwise. A key counts as there only on a line sshd uses: not a # comment, and with nothing in front of it but options sshd accepts. A file saved as UTF-16 or with a byte-order mark, which sshd cannot read, is saved again as plain text; until it is, the keys sshd cannot read do not count.'
    Write-UiItem '5.' 'With -AllowFrom, limits the OpenSSH-Server-In-TCP firewall rules to those networks, then reads back the rules Windows enforces. Windows lets a connection in when any enabled rule allows it, so a narrower rule added beside the original would limit nothing. A rule is limited before it is enabled: when none is enabled, OpenSSH-Server-In-TCP is enabled once it is limited, and a missing one is added already limited. Other enabled rules that let TCP 22 in from any address, whatever their name, are named. Without -AllowFrom no rule is added, enabled or changed: the run reads back which rules let TCP 22 in, and warns when none does.'
    Write-UiItem '6.' 'In sshd_config, sets PubkeyAuthentication yes and, unless -KeepPasswordSignIn, turns password and keyboard-interactive sign-in off when that is safe (see IT DOES NOT LOCK YOU OUT). The new file is tested with sshd -t first and not used if it fails; the old one is kept as sshd_config.bak-<date>.'
    Write-UiItem '7.' 'Applies -DefaultShell, -Banner and -LoginAlert when given.'
    Write-UiItem '8.' 'Restarts sshd when something it reads has changed, and checks that it runs. If it does not, the previous sshd_config is put back.'
    Write-UiItem '9.' 'Shows the ED25519 host key fingerprint, then a summary.'
    Write-UiSection 'IT DOES NOT LOCK YOU OUT'
    Write-UiText 'Password sign-in is turned off only when all of these hold: administrators_authorized_keys holds at least one key that sshd reads from the file as it is on disk; only Administrators and SYSTEM can reach the file; sshd_config points administrators at that file (the Match Group administrators block Windows installs does); and nothing in sshd_config that applies to administrators turns key sign-in off for them (PubkeyAuthentication no) or asks them for more than a key (AuthenticationMethods). Otherwise it stays as it is and the summary says why. This script never turns it back on.'
    Write-UiText 'Bad input stops the run before anything is changed: a key line whose data does not decode, a key line with text in front of the key that sshd would not read as options, an -AllowFrom value that is not an address or a CIDR network, or a run inside an SSH session that comes from outside -AllowFrom. Put the admin machine inside -AllowFrom as well, or the Access Connector tool is shut out too.'
    Write-UiSection 'PARAMETERS'
    Write-UiParam '-PublicKey <lines>' 'Position 0. One or more public key lines as in a .pub file: ssh-ed25519, ecdsa-sha2-nistp256/384/521 or ssh-rsa, optionally with authorized_keys options in front that sshd accepts, such as from="10.0.0.0/24" or no-pty. Each one sshd does not yet read from administrators_authorized_keys is added. Keys run together in one value with spaces between them are read one by one, or refused when it is unclear where one ends. Text that holds a private key is refused and never shown.'
    Write-UiParam '-AllowFrom <networks>' 'Position 1. Addresses or CIDR networks (10.0.0.0/24, 10.0.0.5, fd00::/64) that may reach TCP 22; separate several with commas. The OpenSSH-Server-In-TCP rules are changed to allow only these. Default: no firewall rule is added, enabled or changed.'
    Write-UiParam '-PublicKeyFile <path>' 'Files on this server that hold public keys: a .pub file, or an authorized_keys file with one key per line (blank lines and # comments are skipped). Used together with -PublicKey.'
    Write-UiParam '-Source <path>' 'Where to install OpenSSH Server from when there is no internet access, or WSUS does not supply Features on Demand: a Features on Demand folder or mounted media, such as D:\. Used only when OpenSSH Server is not installed.'
    Write-UiParam '-LimitAccess' 'Do not try Windows Update or WSUS for the install. With -Source, only that source is used; without it, only the source set by Group Policy.'
    Write-UiParam '-KeepPasswordSignIn' 'Leave password sign-in on. Without it, password and keyboard-interactive sign-in are turned off, but only when it is safe (see IT DOES NOT LOCK YOU OUT).'
    Write-UiParam '-DefaultShell <name>' 'None (default): leave the OpenSSH default shell as it is; when that is PowerShell 7, a warning says what that means for upgrades (see NOTES). WindowsPowerShell or PowerShell7: SSH sessions start in that shell. The Access Connector tool needs neither. Read NOTES before choosing PowerShell7.'
    Write-UiParam '-Banner' 'Show a warning before sign-in: this server''s name, role and domain, AUTHORIZED ACCESS ONLY, and that sessions are monitored and logged. Written to C:\ProgramData\ssh\banner.txt.'
    Write-UiParam '-LoginAlert' 'Write a Warning event to the Application log for each SSH sign-in (source SSHLoginAlert, event 1000), so your event collection can raise an alert. Done by a scheduled task, SSH-Login-Alert, that runs as SYSTEM on each sshd event.'
    Write-UiParam '-AuditLog <path>' 'Append-only audit log, one line per run. File or folder. Default: C:\ProgramData\ssh\logs\ on the server.'
    Write-UiParam '-ErrorLog <path>' 'Error log, appended. File or folder. Default: the same folder as the audit log.'
    Write-UiParam '-WhatIf' 'Check everything and show what would change; change nothing. -Confirm asks before each change instead.'
    Write-UiParam '-Help' 'Show this help.'
    Write-UiSection 'EXAMPLES'
    Write-UiCaption '# On the server: authorise one key (paste it between the quotes)'
    Write-UiCmd '.\Install-OpenSSHServer.ps1 ''ssh-ed25519 AAAA...your key... admin@example'''
    Write-Host ''
    Write-UiCaption '# The key from a file, TCP 22 from one network only, with logs'
    Write-UiCmd '.\Install-OpenSSHServer.ps1 -PublicKeyFile .\connector_ed25519.pub `'
    Write-UiCmd '    -AllowFrom 10.0.0.0/24 -AuditLog C:\Logs\ -ErrorLog C:\Logs\'
    Write-Host ''
    Write-UiCaption '# Show what would change, change nothing'
    Write-UiCmd '.\Install-OpenSSHServer.ps1 -PublicKeyFile .\connector_ed25519.pub -WhatIf'
    Write-Host ''
    Write-UiCaption '# No internet access: install from Features on Demand media in D:'
    Write-UiCmd '.\Install-OpenSSHServer.ps1 -PublicKeyFile .\connector_ed25519.pub `'
    Write-UiCmd '    -Source D:\ -LimitAccess'
    Write-Host ''
    Write-UiCaption '# From a Windows admin machine: several servers, one result line each'
    Write-UiCmd '$key = Get-Content $HOME\.ssh\connector_ed25519.pub'
    Write-UiCmd '$servers = ''connector1.example.local'', ''connector2.example.local'''
    Write-UiCmd 'Invoke-Command -ComputerName $servers -ArgumentList $key, ''10.0.0.0/24'' `'
    Write-UiCmd '    -FilePath .\Install-OpenSSHServer.ps1 |'
    Write-UiCmd '    Format-Table PSComputerName, Result, PasswordSignIn, HostKey'
    Write-Host ''
    Write-UiCaption '# The same with switches (-ArgumentList passes values by position only)'
    Write-UiCmd '$code = Get-Content -Raw .\Install-OpenSSHServer.ps1'
    Write-UiCmd '$run = { param($Code, $Key)'
    Write-UiCmd '    & ([scriptblock]::Create($Code)) -PublicKey $Key -KeepPasswordSignIn }'
    Write-UiCmd 'Invoke-Command -ComputerName $servers -ScriptBlock $run `'
    Write-UiCmd '    -ArgumentList $code, $key'
    Write-Host ''
    Write-UiCaption '# A banner before sign-in, and an event for every sign-in'
    Write-UiCmd '.\Install-OpenSSHServer.ps1 -Banner -LoginAlert'
    Write-Host ''
    Write-UiCaption '# PowerShell 7 as the default SSH shell (read NOTES first)'
    Write-UiCmd '.\Install-OpenSSHServer.ps1 -DefaultShell PowerShell7'
    Write-UiSection 'OUTPUT'
    Write-UiText 'A line for each check and change, then a summary. Exit code 0 when every step succeeded (with -WhatIf: every check passed), otherwise 1.'
    Write-UiText 'Exit codes do not come back through Invoke-Command, so in a remote session the script also returns one object: Computer, Result (SUCCESS, WHATIF or FAILED), OpenSSH, Service, HostKeys, KeysAdded, KeysInFile, KeyFileAccess, Firewall, PasswordSignIn, DefaultShell, Banner, LoginAlert, Restarted, HostKey, HostPublicKey, Problems and Warnings. Invoke-Command adds PSComputerName.'
    Write-UiSection 'LOGGING'
    Write-UiText 'Audit log (-AuditLog): one appended key=value line per run, on every exit path: who ran it, how (local, ssh or remote), what changed and the outcome. Error log (-ErrorLog): one line per problem. Both default to C:\ProgramData\ssh\logs\ on the server.'
    Write-UiText 'This script takes no password. Keys are shown and logged by fingerprint and comment, never in full; a long comment is cut short. Text that holds a private key, given as a key or as -AllowFrom, is refused without being shown or logged, and an -AllowFrom value that could be key data is not shown either.'
    Write-UiSection 'NOTES'
    Write-UiText ('Default shell. ' + $script:Pwsh7Note)
    Write-UiText 'Accounts. administrators_authorized_keys serves every member of the local Administrators group, which is what the Access Connector tool signs in with. For other accounts OpenSSH reads .ssh\authorized_keys in that user''s profile; this script does not write that file.'
    Write-UiText 'Group Policy. When Group Policy manages a firewall profile and ignores local rules, the rule changed here has no effect on that profile; set the limit in that policy. The script says so when it sees this. With -AllowFrom the run then fails, because the limit is not in force; without it, that is a warning.'
    Write-UiText 'Login alert. It needs sshd to log to the event log, which is the default (not SyslogFacility LOCAL0). The first run of the task starts after the newest event, so earlier sign-ins are not reported.'
    Write-UiText 'Undo. Password sign-in back on: set PasswordAuthentication yes in C:\ProgramData\ssh\sshd_config, then Restart-Service sshd. Banner off: Banner none, then restart sshd. Default shell back to cmd.exe: Remove-ItemProperty HKLM:\SOFTWARE\OpenSSH -Name DefaultShell. Login alert off: Unregister-ScheduledTask -TaskName SSH-Login-Alert. OpenSSH Server off altogether: Stop-Service sshd, then Remove-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0; C:\ProgramData\ssh stays, with the keys and settings, until you delete it.'
    Write-UiSection 'REQUIREMENTS'
    Write-UiText 'Windows Server 2019 or later, or Windows 10 1809 or later, and an elevated 64-bit Windows PowerShell 5.1 (or an administrator account over Invoke-Command). The install needs Windows Update, a WSUS whose policy allows Features on Demand ("Specify settings for optional component installation and component repair"), or -Source. On older Windows install Win32-OpenSSH first; this script then configures it.'
    Write-UiSection 'ABOUT'
    Write-UiText "Version $($script:Version). Created 2026-11-23. Part of the Access Connector Automated Upgrade tool (Prerequisites folder). MIT License; see the LICENSE file."
    Write-UiSection 'DOCUMENTATION'
    Write-UiText 'Getting Started, section 4 (Stand up SSH on a Windows server). Microsoft Learn: Get started with OpenSSH for Windows; OpenSSH Server configuration for Windows; Key-based authentication in OpenSSH for Windows.'
    Write-Host ''
}

# ---------------------------------------------------------------- logs
function Resolve-LogPath { param([string]$Value, [string]$DefaultName)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $v = $Value.Trim()
    if ((Test-Path -LiteralPath $v -PathType Container) -or $v.EndsWith('\') -or $v.EndsWith('/')) { $v = Join-Path $v $DefaultName }
    $dir = Split-Path -Parent $v
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false -Confirm:$false }
    return $v }
function Test-LogReady { param([string]$Path, $IsDefault)
    # A log named on the command line had its folder made at the start. The default folder,
    # C:\ProgramData\ssh\logs, is made only when something is written and never under -WhatIf.
    if (-not $Path) { return $false }
    $dir = Split-Path -Parent $Path
    if (Test-Path -LiteralPath $dir) { return $true }
    if (-not [bool]$IsDefault -or $script:IsWhatIf -or -not $script:IsAdmin) { return $false }
    try { Initialize-SshFolder; $null = New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false -Confirm:$false; return $true }
    catch {
        if (-not $script:LogWarned) { $script:LogWarned = $true; Say ('No log can be written in ' + $dir + ': ' + $_.Exception.Message) 'WARN' }
        return $false } }
function Write-ErrorEntry { param([string]$Message, [string]$Stage)
    Say $Message 'ERROR'
    if (-not (Test-LogReady $script:ErrorPath $script:ErrorDefault)) { return }
    $stamp = (Get-Date).ToString('o')
    $st = ''; if ($Stage) { $st = " [$Stage]" }
    $m = ($Message -replace '\s*\r?\n\s*', ' | ').Trim()
    try {
        if (-not (Test-Path -LiteralPath $script:ErrorPath)) { Add-Content -LiteralPath $script:ErrorPath -Encoding UTF8 -Value ("# $($script:Name) error log - created $stamp") -WhatIf:$false -Confirm:$false }
        Add-Content -LiteralPath $script:ErrorPath -Encoding UTF8 -Value "$stamp [ERROR]$st $m" -WhatIf:$false -Confirm:$false
    } catch {
        if (-not $script:LogWarned) { $script:LogWarned = $true; Say ('The error log cannot be written: ' + $_.Exception.Message) 'WARN' } } }
function Write-AuditEntry { param([string]$Outcome, [string]$Stage)
    if ($script:AuditWritten) { return }
    $script:AuditWritten = $true
    if (-not (Test-LogReady $script:AuditPath $script:AuditDefault)) { return }
    $f = [ordered]@{ time = (Get-Date).ToString('o'); user = [Environment]::UserName; host = [Environment]::MachineName
        script = $script:Name; version = $script:Version; session = $script:Session; whatIf = $script:IsWhatIf; outcome = $Outcome }
    if ($Stage) { $f['stage'] = $Stage }
    $f['keysAdded'] = $script:R.KeysAdded
    if ($script:AddedKeys.Count) { $f['addedKeys'] = ($script:AddedKeys -join ',') }
    $f['keysInFile'] = $script:R.KeysInFile
    if ($script:Specs -and @($script:Specs).Count) { $f['allowFrom'] = ((@($script:Specs) | ForEach-Object { $_.Text }) -join ',') }
    if ($script:R.PasswordSignIn) { $f['passwordSignIn'] = $script:R.PasswordSignIn }
    if ($script:R.Restarted) { $f['restarted'] = $script:R.Restarted }
    if ($script:R.HostKey) { $f['hostKey'] = $script:R.HostKey }
    $f['durationSec'] = [math]::Round(((Get-Date) - $script:Started).TotalSeconds, 1)
    if ($script:Problems.Count) { $f['detail'] = (($script:Problems -join ' | ') -replace '\s+', ' ').Trim() }
    $line = ($f.GetEnumerator() | ForEach-Object { $v = [string]$_.Value
        if ($v -match '[\s"]') { '{0}="{1}"' -f $_.Key, ($v -replace '"', "'") } else { '{0}={1}' -f $_.Key, $v } }) -join ' '
    try {
        if (-not (Test-Path -LiteralPath $script:AuditPath)) { Add-Content -LiteralPath $script:AuditPath -Encoding UTF8 -Value ("# $($script:Name) audit log - append only - created " + (Get-Date).ToString('o')) -WhatIf:$false -Confirm:$false }
        Add-Content -LiteralPath $script:AuditPath -Encoding UTF8 -Value $line -WhatIf:$false -Confirm:$false
    } catch { Say ('The audit log cannot be written: ' + $_.Exception.Message) 'WARN' } }
function Add-Problem { param([string]$Message, [string]$Stage)
    Write-ErrorEntry $Message $Stage
    $script:Problems.Add($Message) }
function Add-Warning { param([string]$Message)
    Say $Message 'WARN'
    if (-not $script:Warnings.Contains($Message)) { $script:Warnings.Add($Message) } }
function Complete-Run { param([string]$Stage, [switch]$Summary)
    # The one way out: summary, audit line, the result object in a remote session, exit code.
    $outcome = 'SUCCESS'
    if ($script:Problems.Count) { $outcome = 'FAILED' }
    $script:R.Result = $outcome
    if ($outcome -eq 'SUCCESS' -and $script:IsWhatIf) { $script:R.Result = 'WHATIF' }
    $script:R.Problems = $script:Problems.ToArray()
    $script:R.Warnings = $script:Warnings.ToArray()
    if ($Summary) { Show-Summary }
    Write-AuditEntry -Outcome $outcome -Stage $Stage
    if ($script:Session -eq 'remote') { New-Object psobject -Property $script:R }
    if ($outcome -eq 'SUCCESS') { exit 0 }
    exit 1 }
function Stop-Run { param([string]$Message, [string]$Stage)
    Add-Problem $Message $Stage
    Complete-Run -Stage $Stage }
function Confirm-Change { param([string]$Target, [string]$Action)
    # -WhatIf answers no and prints what would happen; -Confirm asks.
    return $script:Cmdlet.ShouldProcess($Target, $Action) }

# ---------------------------------------------------------------- files, programs, permissions
function Invoke-Native { param([string]$FilePath, [string[]]$Arguments)
    # Runs a program; returns its exit code and output, standard error included. Windows
    # PowerShell 5.1 turns redirected standard error into errors that 'Stop' throws on, so the
    # preference is relaxed in here only.
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = -1
    $out = @(& $FilePath @Arguments 2>&1 | ForEach-Object { [string]$_ })
    return New-Object psobject -Property @{ ExitCode = $global:LASTEXITCODE; Output = $out } }
function Join-Output { param($Lines)
    return ((@($Lines) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) -join ' | ') }
function Read-TextFile { param([string]$Path)
    # The text of a small file and how it was saved: plain (UTF-8 or ANSI), UTF-8 with a byte-order
    # mark, or UTF-16, which is what > and Out-File write in Windows PowerShell 5.1. sshd reads
    # plain bytes only, so a key file saved the other ways is saved again without them.
    $b = [System.IO.File]::ReadAllBytes($Path)
    $enc = 'plain'
    if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { $enc = 'UTF-16'; $text = [System.Text.Encoding]::Unicode.GetString($b, 2, $b.Length - 2) }
    elseif ($b.Length -ge 2 -and $b[0] -eq 0xFE -and $b[1] -eq 0xFF) { $enc = 'UTF-16'; $text = [System.Text.Encoding]::BigEndianUnicode.GetString($b, 2, $b.Length - 2) }
    elseif ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $enc = 'UTF-8 BOM'; $text = [System.Text.Encoding]::UTF8.GetString($b, 3, $b.Length - 3) }
    elseif ($b.Length -ge 4 -and $b[1] -eq 0 -and $b[3] -eq 0) { $enc = 'UTF-16'; $text = [System.Text.Encoding]::Unicode.GetString($b) }
    else { $text = [System.Text.Encoding]::UTF8.GetString($b) }
    return New-Object psobject -Property @{ Text = $text; Encoding = $enc } }
function Split-Lines { param([string]$Text)
    # The lines of a text; a final line break does not make an extra empty line.
    if ([string]::IsNullOrEmpty($Text)) { return }
    $l = @($Text -split '\r?\n')
    if ($l[$l.Count - 1] -eq '') { if ($l.Count -eq 1) { return }; $l = $l[0..($l.Count - 2)] }
    return $l }
function Write-TextLines { param([string]$Path, [string[]]$Lines, [string]$NewLine = "`r`n")
    # Plain UTF-8 without a byte-order mark (the same bytes as ASCII for ASCII text), one line
    # break after every line, so a line added later never runs on from the last one.
    $text = ((@($Lines) | ForEach-Object { [string]$_ }) -join $NewLine) + $NewLine
    [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false))) }
function Find-OpenSshTool { param([string]$Exe)
    # sshd.exe and ssh-keygen.exe: beside the sshd service's program, else in the two usual places.
    $dirs = @()
    try {
        $w = Get-CimInstance -ClassName Win32_Service -Filter "Name='sshd'" -ErrorAction Stop
        if ($w -and $w.PathName) {
            $p = ([string]$w.PathName).Trim()
            if ($p.StartsWith('"')) { $p = $p.Substring(1); $q = $p.IndexOf('"'); if ($q -ge 0) { $p = $p.Substring(0, $q) } }
            else { $p = @($p -split ' ')[0] }
            $dirs += (Split-Path -Parent $p)
        }
    } catch { }
    $dirs += (Join-Path $env:SystemRoot 'System32\OpenSSH')
    $dirs += (Join-Path $env:ProgramFiles 'OpenSSH')
    foreach ($d in $dirs) { if ($d) { $f = Join-Path $d $Exe; if (Test-Path -LiteralPath $f) { return $f } } }
    return $null }
function Initialize-SshFolder {
    # sshd makes C:\ProgramData\ssh on its first start. When this script needs it before that,
    # it is made with the permissions sshd gives it: full control for SYSTEM and Administrators,
    # read for Authenticated Users, nothing inherited from C:\ProgramData (where every user may
    # create files).
    if (Test-Path -LiteralPath $script:SshDir) { return }
    $null = New-Item -ItemType Directory -Path $script:SshDir -Force -WhatIf:$false -Confirm:$false
    $r = Invoke-Native 'icacls.exe' @($script:SshDir, '/inheritance:r', '/grant', ('*' + $script:SidSystem + ':(OI)(CI)F'), '/grant', ('*' + $script:SidAdmins + ':(OI)(CI)F'), '/grant', ('*' + $script:SidUsers + ':(OI)(CI)RX'))
    if ($r.ExitCode -ne 0) { throw ('icacls could not set the permissions of ' + $script:SshDir + ': ' + (Join-Output $r.Output)) } }
function Get-SidName { param([string]$Sid)
    if (-not $Sid) { return 'an unknown account' }
    try { return (New-Object System.Security.Principal.SecurityIdentifier($Sid)).Translate([System.Security.Principal.NTAccount]).Value } catch { return $Sid } }
function Get-AclProblem { param([string]$Path)
    # $null when only SYSTEM and Administrators have access, SYSTEM among them, and one of the two
    # owns the file: what OpenSSH asks of administrators_authorized_keys and of private host keys.
    # Otherwise what is wrong. Accounts are compared by SID, so this works in any Windows language.
    try { $acl = Get-Acl -LiteralPath $Path }
    catch { return 'its permissions cannot be read' }
    $why = @()
    $owner = $null
    try { $owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value } catch { }
    if ($owner -ne $script:SidSystem -and $owner -ne $script:SidAdmins) { $why += ('owned by ' + (Get-SidName $owner)) }
    $system = $false
    foreach ($ace in @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))) {
        if ("$($ace.AccessControlType)" -ne 'Allow') { continue }
        $sid = $ace.IdentityReference.Value
        if ($sid -eq $script:SidSystem) { $system = $true }
        elseif ($sid -ne $script:SidAdmins) { $why += ('open to ' + (Get-SidName $sid)) }
    }
    if (-not $system) { $why += 'SYSTEM has no access' }
    if ($why.Count) { return ((@($why) | Select-Object -Unique) -join ', ') }
    return $null }
function Set-AdminOnlyAcl { param([string]$Path)
    # SYSTEM and Administrators only, as Getting Started section 4.4 does it (icacls with the
    # well-known SIDs), plus two things icacls /inheritance:r leaves alone: an entry given to an
    # account by name (ssh-keygen gives one to whoever runs it) and a wrong owner. Returns $null
    # when the file is right afterwards, otherwise what is still wrong.
    $readable = $true
    try { $null = Get-Acl -LiteralPath $Path } catch { $readable = $false }
    if (-not $readable) { $null = Invoke-Native 'takeown.exe' @('/F', $Path, '/A') }   # owner: Administrators
    $why = Get-AclProblem $Path
    if ($why -and $why -match 'owned by') {
        $r = Invoke-Native 'icacls.exe' @($Path, '/setowner', ('*' + $script:SidSystem))
        if ($r.ExitCode -ne 0) { $null = Invoke-Native 'takeown.exe' @('/F', $Path, '/A') }
    }
    $grant = @($Path, '/inheritance:r', '/grant', ('*' + $script:SidAdmins + ':F'), '/grant', ('*' + $script:SidSystem + ':F'))
    $r = Invoke-Native 'icacls.exe' $grant
    if ($r.ExitCode -ne 0) {
        # owned by SYSTEM with no entry for Administrators: take ownership, then once more
        $null = Invoke-Native 'takeown.exe' @('/F', $Path, '/A')
        $r = Invoke-Native 'icacls.exe' $grant
        if ($r.ExitCode -ne 0) { return ('icacls failed: ' + (Join-Output $r.Output)) } }
    try {
        $acl = Get-Acl -LiteralPath $Path
        foreach ($ace in @($acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]))) {
            $sid = $ace.IdentityReference.Value
            if ("$($ace.AccessControlType)" -eq 'Allow' -and $sid -ne $script:SidSystem -and $sid -ne $script:SidAdmins) {
                $null = Invoke-Native 'icacls.exe' @($Path, '/remove:g', ('*' + $sid)) }
        }
    } catch { }
    return (Get-AclProblem $Path) }

# ---------------------------------------------------------------- keys
function Read-SshField { param([byte[]]$Bytes, [int]$At)
    # One length-prefixed field of an SSH public key (RFC 4253, section 6.6) as Data and Next (the
    # offset after it), or $null when it runs past the end.
    if ($At + 4 -gt $Bytes.Length) { return $null }
    $len = ([long]$Bytes[$At] * 16777216) + ([long]$Bytes[$At + 1] * 65536) + ([long]$Bytes[$At + 2] * 256) + [long]$Bytes[$At + 3]
    if ($At + 4 + $len -gt $Bytes.Length) { return $null }
    $data = New-Object byte[] ([int]$len)
    if ($len -gt 0) { [Array]::Copy($Bytes, $At + 4, $data, 0, [int]$len) }
    return New-Object psobject -Property @{ Data = $data; Next = $At + 4 + [int]$len } }
function Get-OptionsEnd { param([string]$Text)
    # Where sshd ends the options in front of a key (sshkey_advance_past_options): at the first
    # space or tab outside double quotes, \" being a quote that does not end them. -1 when a
    # quote is left open.
    $quoted = $false
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($c -eq '\' -and $i + 1 -lt $Text.Length -and $Text[$i + 1] -eq '"') { $i++; continue }
        if ($c -eq '"') { $quoted = -not $quoted; continue }
        if (-not $quoted -and ($c -eq ' ' -or $c -eq "`t")) { return $i }
    }
    if ($quoted) { return -1 }
    return $Text.Length }
function Test-KeyOptions { param([string]$Text)
    # Whether sshd accepts $Text as the options in front of a key (sshauthopt_parse): names and
    # name="value" items separated by commas, in any case, with no- in front of a name where sshd
    # allows it. For any other text (a name sshd does not know, a value without quotes, a comma at
    # the end) sshd skips the whole line. permitlisten, touch-required and verify-required came
    # after OpenSSH 7.7, the version in Windows Server 2019; an older sshd skips them too.
    if (-not $Text) { return $false }
    $flags = '^(?:(?:no-)?(?:port-forwarding|agent-forwarding|x11-forwarding|pty|user-rc|touch-required|verify-required)|restrict|cert-authority)(?=,|$)'
    $named = '^(?:command|principals|from|expiry-time|environment|permitopen|permitlisten|tunnel)="'
    $i = 0
    while ($true) {
        $rest = $Text.Substring($i)
        $m = [regex]::Match($rest, $flags, 'IgnoreCase')
        if ($m.Success) { $i += $m.Length }
        else {
            $m = [regex]::Match($rest, $named, 'IgnoreCase')
            if (-not $m.Success) { return $false }
            $j = $i + $m.Length; $closed = $false
            while ($j -lt $Text.Length) {
                if ($Text[$j] -eq '\' -and $j + 1 -lt $Text.Length -and $Text[$j + 1] -eq '"') { $j += 2; continue }
                if ($Text[$j] -eq '"') { $closed = $true; break }
                $j++ }
            if (-not $closed) { return $false }
            $i = $j + 1 }
        if ($i -ge $Text.Length) { return $true }
        if ($Text[$i] -ne ',') { return $false }
        $i++
        if ($i -ge $Text.Length) { return $false } } }
function ConvertTo-KeyRecord { param([string]$Line, [switch]$AsRead)
    # One authorized_keys line: [options] type base64 [comment]. Returns the key's parts, or $null
    # when it is not an ssh-ed25519, ecdsa-sha2-nistp256/384/521 or ssh-rsa public key whose data
    # decodes and names the same type; a damaged or cut-off paste fails that test. The line is
    # read the way sshd reads it: a line that starts with # is a comment, a space or a tab
    # separates the fields, and the only text allowed in front of the key type is one option list
    # that sshd accepts (Test-KeyOptions); sshd skips any other line. -AsRead takes a line as it
    # is in a file, with only the spaces and tabs that sshd skips taken off its start.
    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }
    if ($AsRead) { $t = $Line.TrimStart([char[]]@(' ', "`t")).TrimEnd([char[]]@(' ', "`t", "`r", "`n", "`f", "`v")) }
    else { $t = $Line.Trim() }
    if (-not $t -or $t.StartsWith('#', [System.StringComparison]::Ordinal)) { return $null }
    $types = (@($script:KeyTypes) | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $rx = '^(?<type>' + $types + ')[ \t]+(?<blob>[A-Za-z0-9+/]+={0,2})(?:[ \t]+(?<comment>.*))?$'
    $opts = ''; $at = 0
    $m = [regex]::Match($t, $rx)
    if (-not $m.Success) {
        $end = Get-OptionsEnd $t
        if ($end -le 0 -or $end -ge $t.Length) { return $null }
        $opts = $t.Substring(0, $end)
        if (-not (Test-KeyOptions $opts)) { return $null }
        $rest = $t.Substring($end).TrimStart([char[]]@(' ', "`t"))
        $at = $t.Length - $rest.Length
        $m = [regex]::Match($rest, $rx)
        if (-not $m.Success) { return $null }
    }
    $type = $m.Groups['type'].Value; $blob = $m.Groups['blob'].Value
    try { $bytes = [Convert]::FromBase64String($blob) } catch { return $null }
    $f = Read-SshField $bytes 0
    if (-not $f -or [System.Text.Encoding]::ASCII.GetString($f.Data) -cne $type) { return $null }
    if ($type -eq 'ssh-ed25519') {
        $pk = Read-SshField $bytes $f.Next
        if (-not $pk -or $pk.Data.Length -ne 32) { return $null }
        $next = $pk.Next; $bits = 256
    } elseif ($type -eq 'ssh-rsa') {
        $e = Read-SshField $bytes $f.Next; if (-not $e) { return $null }
        $n = Read-SshField $bytes $e.Next; if (-not $n -or $n.Data.Length -lt 2) { return $null }
        $len = $n.Data.Length; if ($n.Data[0] -eq 0) { $len-- }
        $next = $n.Next; $bits = $len * 8
    } else {
        $c = Read-SshField $bytes $f.Next; if (-not $c) { return $null }
        if (('ecdsa-sha2-' + [System.Text.Encoding]::ASCII.GetString($c.Data)) -cne $type) { return $null }
        $q = Read-SshField $bytes $c.Next; if (-not $q -or $q.Data.Length -lt 32) { return $null }
        $next = $q.Next; $bits = [int]$type.Substring(16)
    }
    if ($next -ne $bytes.Length) { return $null }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $fp = 'SHA256:' + ([Convert]::ToBase64String($sha.ComputeHash($bytes))).TrimEnd('=') } finally { $sha.Dispose() }
    $commentAt = -1
    if ($m.Groups['comment'].Success) { $commentAt = $at + $m.Groups['comment'].Index }
    return New-Object psobject -Property @{ Type = $type; Blob = $blob; Bits = $bits; Fingerprint = $fp
        Comment = $m.Groups['comment'].Value.Trim(); Options = $opts; CommentAt = $commentAt
        Id = $type + ' ' + $blob; Line = $t; Usable = (($type -ne 'ssh-rsa') -or ($bits -ge 1024)) } }
function Format-Key { param($K)
    # A public key shown short: type, fingerprint and comment, never the key data itself. A long
    # comment is cut short, so key data that ran into one is not shown either.
    $s = $K.Type + ' ' + $K.Fingerprint
    if ($K.Type -eq 'ssh-rsa') { $s += ' (' + $K.Bits + ' bits)' }
    $c = [string]$K.Comment
    if ($c.Length -gt 40) { $c = $c.Substring(0, 37) + '...' }
    if ($c) { $s += ' ' + $c }
    return $s }
function Split-JoinedKeys { param([string]$Line)
    # The keys of a line that holds several run together with spaces between them, as "$keys"
    # joins an array, one line per key: sshd would read every key after the first as part of the
    # first one's comment. $null when it is unclear where the next key's options start: text in
    # front of it that holds = or a double quote, or ends in an option list that sshd accepts,
    # could be options for that key, and splitting there would drop them.
    $out = @()
    $rest = $Line.Trim()
    $types = (@($script:KeyTypes) | ForEach-Object { [regex]::Escape($_) }) -join '|'
    while ($true) {
        $k = ConvertTo-KeyRecord $rest
        if (-not $k -or $k.CommentAt -lt 0) { $out += $rest; break }
        $c = $k.Line.Substring($k.CommentAt)
        $cut = -1
        foreach ($m in [regex]::Matches($c, '(?:^|[ \t])(?<type>' + $types + ')[ \t]')) {
            $at = $m.Groups['type'].Index
            if (ConvertTo-KeyRecord $c.Substring($at)) { $cut = $at; break } }
        if ($cut -lt 0) { $out += $rest; break }
        $before = $c.Substring(0, $cut).Trim()
        if ($before) {
            $last = @($before -split '[ \t]+')[-1]
            if (($before -match '[="]') -or (Test-KeyOptions $last)) { return $null } }
        $out += $k.Line.Substring(0, $k.CommentAt + $cut).TrimEnd()
        $rest = $c.Substring($cut)
    }
    return $out }
function Get-KeyLineProblem { param([string]$Line)
    # Why a line is not a usable public key, naming at most its first word, never the key data.
    $t = $Line.Trim()
    $parts = @($t -split '\s+')
    $first = $parts[0]
    if ($script:KeyTypes -ccontains $first) {
        if ($parts.Count -lt 2) { return ($first + ' with no key data after it. Put the whole key line in quotes') }
        return ('the ' + $first + ' key data does not decode: the line is damaged or cut off') }
    if ($first -match '^(ssh-dss|ssh-ed448|sk-\S+|\S+-cert-v01@openssh\.com)$') {
        return ($first + ' keys are not accepted here; use ssh-ed25519, ecdsa-sha2-nistp256/384/521 or ssh-rsa') }
    if ($parts.Count -eq 1 -and (ConvertTo-NetSpec (@($first -split ',')[0]))) {
        return 'this is a network, not a key. Keys come first: -ArgumentList $null, ''10.0.0.0/24'' gives networks only' }
    # a key further on, behind text that is not options sshd accepts: sshd would skip the line
    $types = (@($script:KeyTypes) | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $km = [regex]::Match($t, '[ \t](?<type>' + $types + ')[ \t]+[A-Za-z0-9+/]')
    if ($km.Success) {
        $type = $km.Groups['type'].Value
        $front = $t.Substring(0, $km.Groups['type'].Index).TrimEnd()
        if ((Get-OptionsEnd $front) -eq $front.Length -and (Test-KeyOptions $front)) { return ('the ' + $type + ' key data does not decode: the line is damaged or cut off') }
        return ('there is text in front of the ' + $type + ' key that sshd does not read as options, so sshd would skip the line. Options go in front of the key as one word, such as from="10.0.0.0/24" or no-pty,no-port-forwarding; otherwise give the key line as it is in the .pub file') }
    return 'not an ssh-ed25519, ecdsa-sha2-nistp256/384/521 or ssh-rsa public key line' }
function Get-InputKeys {
    # The keys from -PublicKey and -PublicKeyFile, checked: Keys (unique, in order) and Errors.
    # A private key or a PuTTY key file is refused without any of its text being shown or logged.
    $keys = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[string]
    # key data is base64, where case matters: compared exactly, not the way PowerShell compares text
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::Ordinal)
    $items = @()
    $n = 0
    # 'powershell -File' passes -PublicKey 'key1','key2' as one string joined by a comma; without
    # this split the second key would vanish into the first one's comment
    $types = (@($script:KeyTypes) | ForEach-Object { [regex]::Escape($_) }) -join '|'
    foreach ($v in @($PublicKey)) {
        if ($null -eq $v -or -not ([string]$v).Trim()) { continue }
        $n++
        $text = [regex]::Replace([string]$v, (',\s*(?=(?:' + $types + ')\s)'), "`n")
        $items += New-Object psobject -Property @{ Where = ('-PublicKey value ' + $n); Text = $text; File = $false } }
    foreach ($f in @($PublicKeyFile)) {
        if (-not $f) { continue }
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { $errors.Add('-PublicKeyFile ' + $f + ': not found on ' + $env:COMPUTERNAME + '.'); continue }
        try {
            $full = (Resolve-Path -LiteralPath $f).ProviderPath
            $items += New-Object psobject -Property @{ Where = $f; Text = (Read-TextFile $full).Text; File = $true }
        } catch { $errors.Add('-PublicKeyFile ' + $f + ': cannot be read: ' + $_.Exception.Message) }
    }
    foreach ($it in $items) {
        if ($it.Text -match $script:PrivateKeyText) {
            $msg = $it.Where + ' holds a PRIVATE key. Give the public half instead (the .pub file). Nothing of it was shown or logged.'
            if ($it.File) { $msg += ' A private key does not belong on this server: delete that copy.' }
            $errors.Add($msg); continue }
        if ($it.Text -match 'BEGIN SSH2 PUBLIC KEY') {
            $errors.Add($it.Where + ' is a PuTTY (RFC 4716) public key. Give the one-line OpenSSH form: in PuTTYgen, the text under "Public key for pasting into OpenSSH authorized_keys file", or convert it with ssh-keygen -i -f <file>.')
            continue }
        $lines = @(Split-Lines $it.Text)
        for ($i = 0; $i -lt $lines.Count; $i++) {
            # a character that only looks like a space (a no-break space from a web page or a
            # document) becomes a space: sshd separates the fields with spaces and tabs only
            $t = ([regex]::Replace([string]$lines[$i], '[\s-[ \t]]', ' ')).Trim()
            if (-not $t -or $t.StartsWith('#', [System.StringComparison]::Ordinal)) { continue }
            $where = $it.Where
            if ($it.File -or $lines.Count -gt 1) { $where += ', line ' + ($i + 1) }
            $pieces = Split-JoinedKeys $t
            if ($null -eq $pieces) {
                $errors.Add($where + ': several keys run together, and the text in front of a later one could be options for it. Give each key as a value of its own (an array, not "$keys"), or one key per line.')
                continue }
            $pieces = @($pieces)
            for ($j = 0; $j -lt $pieces.Count; $j++) {
                $w = $where
                if ($pieces.Count -gt 1) { $w += ', key ' + ($j + 1) + ' of ' + $pieces.Count }
                $k = ConvertTo-KeyRecord $pieces[$j]
                if (-not $k) { $errors.Add($w + ': ' + (Get-KeyLineProblem $pieces[$j]) + '.'); continue }
                if (-not $k.Usable) { $errors.Add($w + ': ssh-rsa key of ' + $k.Bits + ' bits. OpenSSH refuses RSA keys under 1024 bits; make an ssh-ed25519 key instead.'); continue }
                if ($k.Type -eq 'ssh-rsa' -and $k.Bits -lt 2048) { Add-Warning ($w + ': ssh-rsa key of only ' + $k.Bits + ' bits; consider an ssh-ed25519 key.') }
                if ($seen.Add($k.Id)) { $keys.Add($k) }
            }
        }
    }
    return New-Object psobject -Property @{ Keys = $keys.ToArray(); Errors = $errors.ToArray() } }
function Get-KeyFileKeys { param([string[]]$Lines)
    # The keys sshd takes from these lines of administrators_authorized_keys, each line read as
    # sshd reads it (ConvertTo-KeyRecord -AsRead): Keys, by key type and data, each with the first
    # line it is on; and Skipped, the numbers of the lines that hold a key sshd does not use (its
    # data does not decode, it is an RSA key under 1024 bits, or the text in front of it is not
    # options sshd accepts). A line that starts with # is a comment, which sshd skips too.
    $keys = New-Object 'System.Collections.Generic.Dictionary[string,object]' -ArgumentList ([StringComparer]::Ordinal)
    $skipped = @()
    $types = (@($script:KeyTypes) | ForEach-Object { [regex]::Escape($_) }) -join '|'
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $l = [string]$Lines[$i]
        $t = $l.TrimStart([char[]]@(' ', "`t"))
        if (-not $t.Trim() -or $t.StartsWith('#', [System.StringComparison]::Ordinal)) { continue }
        $k = ConvertTo-KeyRecord $l -AsRead
        if ($k -and $k.Usable) { if (-not $keys.ContainsKey($k.Id)) { $keys[$k.Id] = $k }; continue }
        if ($k -or [regex]::IsMatch($l, '(^|[ \t])(' + $types + ')[ \t]+[A-Za-z0-9+/]')) { $skipped += ($i + 1) }
    }
    return New-Object psobject -Property @{ Keys = $keys; Skipped = $skipped } }
function Get-KeysAsRead { param([string]$Path)
    # The keys sshd reads from the file as it is on disk. sshd reads the bytes as they are: in a
    # file saved as UTF-16 it finds no key, and behind a byte-order mark it misses the first one.
    $b = [System.IO.File]::ReadAllBytes($Path)
    $text = (New-Object System.Text.UTF8Encoding($false)).GetString($b)
    return (Get-KeyFileKeys @(Split-Lines $text)) }

# ---------------------------------------------------------------- networks
function Get-MaskedBytes { param([byte[]]$Bytes, [int]$Prefix)
    $out = New-Object byte[] $Bytes.Length
    for ($i = 0; $i -lt $Bytes.Length; $i++) {
        $left = $Prefix - (8 * $i)
        if ($left -ge 8) { $out[$i] = $Bytes[$i] }
        elseif ($left -gt 0) { $out[$i] = [byte]([int]$Bytes[$i] -band (256 - [int][Math]::Pow(2, 8 - $left))) }
    }
    return ,$out }
function ConvertTo-NetSpec { param([string]$Text)
    # One address or one CIDR network, as it is given to the firewall: 10.0.0.0/24, or one address
    # with no prefix. $null when it is neither (and for 10.1 or 010.0.0.1, which Windows would read
    # as other addresses). HostBits is set for 10.0.0.5/24: whether one address or the network is
    # meant is unclear, so the caller refuses it.
    $t = ([string]$Text).Trim()
    $a = $t; $p = -1
    $m = [regex]::Match($t, '^([^/]+)/(\d{1,3})$')
    if ($m.Success) { $a = $m.Groups[1].Value; $p = [int]$m.Groups[2].Value }
    elseif ($t.Contains('/')) { return $null }
    $v4 = '^((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$'
    if (-not ($a -match $v4) -and -not ($a.Contains(':') -and -not $a.Contains('%'))) { return $null }
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($a, [ref]$ip)) { return $null }
    $bytes = $ip.GetAddressBytes()
    $max = $bytes.Length * 8
    if ($p -lt 0) { $p = $max }
    if ($p -gt $max) { return $null }
    $net = Get-MaskedBytes $bytes $p
    $hostBits = $false
    for ($i = 0; $i -lt $bytes.Length; $i++) { if ($bytes[$i] -ne $net[$i]) { $hostBits = $true } }
    $netText = (New-Object System.Net.IPAddress (,$net)).ToString()
    $text = $netText
    if ($p -lt $max) { $text = $netText + '/' + $p }
    return New-Object psobject -Property @{ Text = $text; Bytes = $net; Prefix = $p; Max = $max; HostBits = $hostBits; Address = $ip.ToString() } }
function Test-ShowableValue { param([string]$Text)
    # Whether text that is not an address or a network may be shown in a message: no longer than
    # an IPv6 network (43 characters), made only of the characters of addresses and host names,
    # and holding a dot, a colon or a dash, none of which base64 key data ever holds.
    return ($Text.Length -le 43 -and $Text -match '^[A-Za-z0-9.:/-]+$' -and $Text -match '[.:-]') }
function Get-InputNetworks {
    # -AllowFrom, checked: Specs (unique, in order) and Errors. 'pwsh -File' and 'powershell -File'
    # pass "a,b" as one string, so commas, semicolons and spaces all separate values. -ArgumentList
    # passes values by position, so a key can land here by mistake: a private key is refused
    # without any of it shown or logged, and a value is shown only when it cannot be key data.
    $specs = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    $values = @(@($AllowFrom) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
    if (($values -join "`n") -match $script:PrivateKeyText) {
        $errors.Add('-AllowFrom holds a PRIVATE key. Nothing of it was shown or logged. -AllowFrom takes networks, and keys come first: -ArgumentList <public keys>, <networks>.')
        return New-Object psobject -Property @{ Specs = @(); Errors = $errors.ToArray() } }
    $types = (@($script:KeyTypes) | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $n = 0
    foreach ($v in $values) {
        $n++
        if ($v -cmatch ('(^|\s)(' + $types + ')\s+[A-Za-z0-9+/]')) {
            $errors.Add('-AllowFrom value ' + $n + ' is a public key, not a network. Keys come first: -ArgumentList <public keys>, <networks>.'); continue }
        $tokens = @(@($v -split '[,;\s]+') | Where-Object { $_ })
        for ($m = 0; $m -lt $tokens.Count; $m++) {
            $p = $tokens[$m]
            $s = ConvertTo-NetSpec $p
            if (-not $s) {
                $shown = $p
                if (-not (Test-ShowableValue $p)) {
                    $shown = 'value ' + $n
                    if ($tokens.Count -gt 1) { $shown += ', item ' + ($m + 1) }
                    $shown += ' (' + $p.Length + ' characters, not shown)' }
                $errors.Add('-AllowFrom ' + $shown + ': not an IPv4 or IPv6 address, or a network in CIDR form such as 10.0.0.0/24.'); continue }
            if ($s.HostBits) { $errors.Add('-AllowFrom ' + $p + ': the address has bits set past /' + $s.Prefix + '. Give the network (' + $s.Text + ') or the one address (' + $s.Address + ').'); continue }
            if (-not $seen.ContainsKey($s.Text)) { $seen[$s.Text] = $true; $specs.Add($s) }
        }
    }
    return New-Object psobject -Property @{ Specs = $specs.ToArray(); Errors = $errors.ToArray() } }
function Test-InNetworks { param([string]$Address, $Specs)
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse((([string]$Address) -split '%')[0], [ref]$ip)) { return $false }
    if ($ip.IsIPv4MappedToIPv6) { $ip = $ip.MapToIPv4() }
    $b = $ip.GetAddressBytes()
    foreach ($s in @($Specs)) {
        if ($s.Bytes.Length -ne $b.Length) { continue }
        $mb = Get-MaskedBytes $b $s.Prefix
        $same = $true
        for ($i = 0; $i -lt $b.Length; $i++) { if ($mb[$i] -ne $s.Bytes[$i]) { $same = $false; break } }
        if ($same) { return $true }
    }
    return $false }
function ConvertTo-RuleAddressKey { param([string]$Text)
    # The firewall shows 10.0.0.0/24 as 10.0.0.0/255.255.255.0; both give the same key here.
    $t = ([string]$Text).Trim()
    $m = [regex]::Match($t, '^(\d{1,3}(?:\.\d{1,3}){3})/(\d{1,3}(?:\.\d{1,3}){3})$')
    if ($m.Success) {
        $mask = $null
        if ([System.Net.IPAddress]::TryParse($m.Groups[2].Value, [ref]$mask)) {
            $n = 0
            foreach ($b in $mask.GetAddressBytes()) { for ($k = 7; $k -ge 0; $k--) { if (([int]$b -band [int][Math]::Pow(2, $k)) -ne 0) { $n++ } } }
            $t = $m.Groups[1].Value + '/' + $n
        }
    }
    $s = ConvertTo-NetSpec $t
    if ($s -and -not $s.HostBits) { return $s.Text.ToLowerInvariant() }
    return $t.ToLowerInvariant() }
function Get-AddressKey { param($Addresses)
    return ((@(@($Addresses) | ForEach-Object { ConvertTo-RuleAddressKey ([string]$_) }) | Sort-Object -Unique) -join ',') }
function Format-Scope { param($Addresses)
    # The firewall's remote addresses for people to read, networks in CIDR form.
    $a = @(@($Addresses) | Where-Object { $_ })
    if ($a.Count -eq 0 -or ($a -contains 'Any')) { return 'any address' }
    return ((@($a | ForEach-Object { ConvertTo-RuleAddressKey ([string]$_) })) -join ', ') }
function Test-Port22 { param($Ports)
    # Whether a rule's local ports take in TCP 22: 22, a range that holds it, or Any.
    foreach ($p in @($Ports)) {
        $s = ([string]$p).Trim()
        if ($s -eq '22' -or $s -eq 'Any') { return $true }
        $m = [regex]::Match($s, '^(\d+)-(\d+)$')
        if ($m.Success -and [int]$m.Groups[1].Value -le 22 -and [int]$m.Groups[2].Value -ge 22) { return $true }
    }
    return $false }
function Test-RuleForSshd { param($Rule)
    # Whether a firewall rule can let a connection to sshd in: one for any program and any
    # service, or for sshd. A rule for another program, for an app package or for another
    # service cannot, whatever its ports. When a filter cannot be read, the rule is counted.
    try {
        $app = $Rule | Get-NetFirewallApplicationFilter -ErrorAction Stop
        $prog = ([string]$app.Program).Trim()
        if ($prog -and $prog -ne 'Any') {
            $full = [Environment]::ExpandEnvironmentVariables($prog)
            if ($script:SshdExe) { if ($full -ne $script:SshdExe) { return $false } }
            elseif ((Split-Path -Leaf $full) -ne 'sshd.exe') { return $false } }
        if ([string]$app.Package -match '^S-1-15-') { return $false }
    } catch { }
    try {
        $svc = ([string]($Rule | Get-NetFirewallServiceFilter -ErrorAction Stop).Service).Trim()
        if ($svc -and $svc -ne 'Any' -and $svc -ne '*' -and $svc -ne 'sshd') { return $false }
    } catch { }
    return $true }
function Get-OtherTcp22Rules {
    # The enabled inbound allow rules in the policy Windows enforces, other than the
    # OpenSSH-Server-In-TCP ones, that let TCP 22 to sshd in, whatever their name and wherever
    # they come from (this server or Group Policy): protocol TCP or Any, local port 22, a range
    # that holds it, or Any. Each as Name, DisplayName and Scope. Throws when they cannot be read.
    $out = @()
    $pfs = @(Get-NetFirewallPortFilter -All -PolicyStore ActiveStore -ErrorAction Stop | Where-Object { (@('TCP', '6', 'Any') -contains "$($_.Protocol)") -and (Test-Port22 $_.LocalPort) })
    foreach ($pf in $pfs) {
        $o = @($pf | Get-NetFirewallRule -ErrorAction SilentlyContinue) | Select-Object -First 1
        if (-not $o -or $o.Name -like 'OpenSSH-Server-In-TCP*') { continue }
        if ("$($o.Enabled)" -ne 'True' -or "$($o.Direction)" -ne 'Inbound' -or "$($o.Action)" -ne 'Allow') { continue }
        if (-not (Test-RuleForSshd $o)) { continue }
        $ra = @(($o | Get-NetFirewallAddressFilter).RemoteAddress)
        $out += New-Object psobject -Property @{ Name = [string]$o.Name; DisplayName = [string]$o.DisplayName; Scope = (Format-Scope $ra) }
    }
    return $out }

# ---------------------------------------------------------------- sshd_config
# sshd uses the first value it reads for most keywords, and a keyword after a Match line applies
# only to the connections that Match selects. So settings are made in the part before the first
# Match line, and a keyword that also appears inside a Match block is reported.
function Get-GlobalEnd { param([string[]]$Lines)
    for ($i = 0; $i -lt $Lines.Count; $i++) { if ($Lines[$i] -match '^\s*Match\s') { return $i } }
    return $Lines.Count }
function Get-SshdOption { param([string[]]$Lines, [string]$Name)
    # The value sshd uses for $Name from the part before the first Match line, or $null.
    $end = Get-GlobalEnd $Lines
    $rx = '^\s*' + [regex]::Escape($Name) + '(?:\s+|\s*=\s*)(\S.*?)\s*$'
    for ($i = 0; $i -lt $end; $i++) { $m = [regex]::Match($Lines[$i], $rx, 'IgnoreCase'); if ($m.Success) { return $m.Groups[1].Value } }
    return $null }
function Set-SshdOption { param([string[]]$Lines, [string]$Name, [string]$Value)
    # Every active line for $Name before the first Match line gets $Value. With none, the first
    # commented-out line for it becomes the active line; with neither, the line goes just above
    # the first Match line, or at the end. Lines inside Match blocks are left alone.
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($l in @($Lines)) { $list.Add([string]$l) }
    $end = Get-GlobalEnd $list.ToArray()
    $want = $Name + ' ' + $Value
    $rxOn  = '^\s*' + [regex]::Escape($Name) + '(?:\s+|\s*=\s*)(.*?)\s*$'
    $rxOff = '^\s*#\s*' + [regex]::Escape($Name) + '(\s+|\s*=)'
    $found = $false
    for ($i = 0; $i -lt $end; $i++) {
        $m = [regex]::Match($list[$i], $rxOn, 'IgnoreCase')
        # sshd reads keywords and yes/no in any case: a line that only differs in case is left alone
        if ($m.Success) { $found = $true; if ($m.Groups[1].Value -ne $Value) { $list[$i] = $want } } }
    if (-not $found) {
        $c = -1
        for ($i = 0; $i -lt $end; $i++) { if ([regex]::IsMatch($list[$i], $rxOff, 'IgnoreCase')) { $c = $i; break } }
        if ($c -ge 0) { $list[$c] = $want }
        elseif ($end -lt $list.Count) { $list.Insert($end, ''); $list.Insert($end, $want) }
        else { $list.Add($want) }
    }
    return $list.ToArray() }
function Get-MatchBlocks { param([string[]]$Lines)
    # The Match blocks, in order: Criteria (the text after Match), Line (its line number), Start
    # and End (the indexes of its lines), and Admins: whether it applies to every connection of a
    # member of the local Administrators group, that is Match All, or Match Group with
    # administrators in its list and no other criterion. Other blocks may or may not apply.
    $out = @(); $cur = $null
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $m = [regex]::Match([string]$Lines[$i], '^\s*Match\s+(.*?)\s*$', 'IgnoreCase')
        if (-not $m.Success) { continue }
        if ($cur) { $cur.End = $i; $out += $cur }
        $c = $m.Groups[1].Value
        $admins = ($c -match '^all$')
        $g = [regex]::Match($c, '^group\s+"?([^\s"]+)"?$', 'IgnoreCase')
        if ($g.Success) {
            $names = @($g.Groups[1].Value -split ',')
            $admins = (@($names | Where-Object { $_ -eq 'administrators' }).Count -gt 0) -and (@($names | Where-Object { $_.StartsWith('!') }).Count -eq 0) }
        $cur = New-Object psobject -Property @{ Criteria = $c; Line = $i + 1; Start = $i + 1; End = $Lines.Count; Admins = $admins }
    }
    if ($cur) { $out += $cur }
    return $out }
function Get-AdminOption { param([string[]]$Lines, $Blocks, [string]$Name)
    # The value sshd uses for $Name on an administrator's connection, as Value, Line and Block:
    # a Match block that applies overrides the part before the first Match line, and the first
    # value sshd reads wins. So: the first of $Blocks (the blocks that apply to administrators)
    # that sets it, else the part before the first Match line; $null when neither sets it.
    $rx = '^\s*' + [regex]::Escape($Name) + '(?:\s+|\s*=\s*)(\S.*?)\s*$'
    foreach ($b in @($Blocks)) {
        for ($i = $b.Start; $i -lt $b.End; $i++) {
            $m = [regex]::Match([string]$Lines[$i], $rx, 'IgnoreCase')
            if ($m.Success) { return New-Object psobject -Property @{ Value = $m.Groups[1].Value; Line = $i + 1; Block = $b } } } }
    $end = Get-GlobalEnd $Lines
    for ($i = 0; $i -lt $end; $i++) {
        $m = [regex]::Match([string]$Lines[$i], $rx, 'IgnoreCase')
        if ($m.Success) { return New-Object psobject -Property @{ Value = $m.Groups[1].Value; Line = $i + 1; Block = $null } } }
    return $null }
function Test-KeyOnlyMethods { param([string]$Value)
    # Whether an AuthenticationMethods value lets a key alone sign in: any, or a list that is
    # publickey and nothing more.
    $v = $Value.Trim().Trim('"')
    if ($v -eq 'any') { return $true }
    return (@(@($v -split '\s+') | Where-Object { $_ -eq 'publickey' }).Count -gt 0) }
function Get-AdminKeyConfigProblems { param([string[]]$Lines)
    # Why key sign-in would not work for administrators with this sshd_config, worked out for an
    # administrator's connection (Get-AdminOption). sshd must read the administrators_authorized_keys
    # this script writes for them, and must neither turn key sign-in off for them nor ask them for
    # more than a key. Nothing when key sign-in works. Without this, the Match Group administrators
    # block that Windows installs is what the password-off step relies on.
    $why = @()
    $blocks = @(Get-MatchBlocks $Lines)
    $admin = @($blocks | Where-Object { $_.Admins })
    $file = '__PROGRAMDATA__/ssh/administrators_authorized_keys'
    $ok = @($file.ToLowerInvariant())
    if ($env:ProgramData) { $ok += ((($env:ProgramData -replace '\\', '/') + '/ssh/administrators_authorized_keys').ToLowerInvariant()) }
    $akf = Get-AdminOption $Lines $admin 'AuthorizedKeysFile'
    $named = @()
    if ($akf) { $named = @(@($akf.Value -split '\s+') | Where-Object { $_ } | ForEach-Object { ($_.Trim('"') -replace '\\', '/').ToLowerInvariant() }) }
    if (@($named | Where-Object { $ok -contains $_ }).Count -eq 0) {
        $part = @($blocks | Where-Object { -not $_.Admins -and $_.Criteria -match 'administrators' })
        if ($akf -and $akf.Block) { $why += ('the Match ' + $akf.Block.Criteria + ' block (line ' + $akf.Block.Line + ') reads ' + $akf.Value + ' for administrators, not ' + $file + ', the file this script writes') }
        elseif ($admin.Count) { $why += ('the Match ' + $admin[0].Criteria + ' block (line ' + $admin[0].Line + ') does not set AuthorizedKeysFile ' + $file + ', so administrators'' keys come from their profiles') }
        elseif ($part.Count) { $why += ('the Match ' + $part[0].Criteria + ' block (line ' + $part[0].Line + ') has criteria besides the administrators group, so it does not apply to every administrator connection (Windows installs Match Group administrators)') }
        else { $why += ('sshd_config has no Match Group administrators block that reads ' + $file + ' (the one Windows installs), so administrators'' keys come from their profiles') } }
    $pk = Get-AdminOption $Lines $admin 'PubkeyAuthentication'
    if ($pk -and $pk.Value.Trim('"') -eq 'no') { $why += ('PubkeyAuthentication no (line ' + $pk.Line + ') applies to administrators, so key sign-in does not work for them') }
    $am = Get-AdminOption $Lines $admin 'AuthenticationMethods'
    if ($am -and -not (Test-KeyOnlyMethods $am.Value)) { $why += ('AuthenticationMethods ' + $am.Value + ' (line ' + $am.Line + ') applies to administrators and asks them for more than a key') }
    return $why }
function Get-PasswordOnBlocks { param([string[]]$Lines)
    # The Match blocks that turn password sign-in on for the accounts they select, as text.
    $out = @()
    foreach ($b in @(Get-MatchBlocks $Lines)) {
        for ($i = $b.Start; $i -lt $b.End; $i++) {
            $m = [regex]::Match([string]$Lines[$i], '^\s*PasswordAuthentication(?:\s+|\s*=\s*)(\S+)', 'IgnoreCase')
            if ($m.Success) {
                if ($m.Groups[1].Value.Trim('"') -eq 'yes') { $out += ('Match ' + $b.Criteria + ' (line ' + ($i + 1) + ')') }
                break } } }
    return $out }
function Get-MatchOverrides { param([string[]]$Lines, [string[]]$Names)
    $out = @(); $in = $false
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^\s*Match\s') { $in = $true; continue }
        if (-not $in) { continue }
        foreach ($n in $Names) { if ([regex]::IsMatch($Lines[$i], ('^\s*' + [regex]::Escape($n) + '(\s+|\s*=)'), 'IgnoreCase')) { $out += ($n + ' (line ' + ($i + 1) + ')') } }
    }
    return $out }
function Get-PasswordState { param([string[]]$Lines)
    $pa = Get-SshdOption $Lines 'PasswordAuthentication'
    if ($pa -and $pa.Trim() -eq 'no') { return 'off' }
    $am = Get-SshdOption $Lines 'AuthenticationMethods'
    if ($am -and $am -notmatch 'password' -and $am.Trim() -ne 'any') { return 'off' }
    return 'on' }
function Test-SshdConfig { param([string]$Candidate)
    # sshd -t on the file in use first: when that already fails here, or sshd.exe is not found,
    # the test says nothing about the new file and is skipped (the restart check still guards it).
    if (-not $script:SshdExe) { return New-Object psobject -Property @{ State = 'skipped'; Text = 'sshd.exe was not found' } }
    $base = Invoke-Native $script:SshdExe @('-t')
    if ($base.ExitCode -ne 0) { return New-Object psobject -Property @{ State = 'skipped'; Text = ('sshd -t fails on the file in use as well: ' + (Join-Output $base.Output)) } }
    $r = Invoke-Native $script:SshdExe @('-t', '-f', $Candidate)
    if ($r.ExitCode -eq 0) { return New-Object psobject -Property @{ State = 'passed'; Text = '' } }
    return New-Object psobject -Property @{ State = 'failed'; Text = (Join-Output $r.Output) } }

# ---------------------------------------------------------------- banner
function Get-ServerRole {
    # Best-effort role for the banner, falling back to a plain label.
    foreach ($n in 'AccessUserAuthService','AccessDirectorySyncService','AccessKerberosAuthService','AccessVirtualAppService') {
        if (Get-Service -Name $n -ErrorAction SilentlyContinue) { return 'Omnissa Access Connector' } }
    try {
        $installed = @(Get-WindowsFeature -ErrorAction Stop | Where-Object { $_.Installed } | ForEach-Object { $_.Name })
        $roleMap = [ordered]@{
            'ADFS-Federation'         = 'Active Directory Federation Services'
            'AD-Domain-Services'      = 'Active Directory Domain Services'
            'AD-Certificate'          = 'Active Directory Certificate Services'
            'DNS'                     = 'DNS Server'
            'DHCP'                    = 'DHCP Server'
            'Web-Server'              = 'Web Server (IIS)'
            'FS-FileServer'           = 'File Server'
            'Remote-Desktop-Services' = 'Remote Desktop Services'
        }
        foreach ($key in $roleMap.Keys) { if ($installed -contains $key) { return $roleMap[$key] } }
    } catch { }   # Get-WindowsFeature is not there on client Windows
    if ($script:Cs -and $script:Cs.PartOfDomain) { return 'Domain Member Server' }
    return 'Server' }
function New-BannerText { param([bool]$KeyOnly)
    # The pre-sign-in banner: 78 characters wide whatever the name length, everything read from
    # this server, so one script serves every server.
    $w = 78
    $name = ([string]$env:COMPUTERNAME).ToUpper()
    $domain = ''
    if ($script:Cs -and $script:Cs.PartOfDomain) { $domain = ([string]$script:Cs.Domain).ToUpper(); $name = $name + '.' + $domain }
    $rule = '*' * $w
    $pad = { param($t) $s = '*   ' + $t; if ($s.Length -lt ($w - 1)) { $s = $s.PadRight($w - 1) }; $s + '*' }
    $monitor = 'Sessions are monitored and logged.'
    if ($KeyOnly) { $monitor = 'Key-based authentication required. ' + $monitor }
    $lines = @($rule, (& $pad ''), (& $pad $name), (& $pad ('Role   : ' + (Get-ServerRole))))
    if ($domain) { $lines += (& $pad ('Domain : ' + $domain)) }
    $lines += @((& $pad ''), (& $pad 'AUTHORIZED ACCESS ONLY'), (& $pad $monitor), (& $pad ''), $rule)
    return (($lines -join "`r`n") + "`r`n") }

# ---------------------------------------------------------------- steps
function Install-SshServer {
    Write-Step 'OpenSSH Server'
    if ($script:Svc) {
        $v = ''
        if ($script:SshdExe) { try { $v = [string](Get-Item -LiteralPath $script:SshdExe).VersionInfo.ProductVersion } catch { } }
        $where = ''; if ($script:SshdExe) { $d = Split-Path -Parent $script:SshdExe; if ($d) { $where = ' in ' + $d } }
        $script:R.OpenSSH = ('already installed ' + $v).Trim()
        Say (('Already installed: sshd ' + $v).Trim() + $where + '.') 'OK'
        return }
    Say ('Installing the Windows capability ' + $script:Cap.Name + '. This can take several minutes, and on Windows 10 and 11 often much longer; it is not stuck.')
    if (-not (Confirm-Change $script:Cap.Name 'Install the Windows capability')) {
        $script:Pending = $true; $script:R.OpenSSH = 'would be installed'; return }
    $p = @{ Online = $true; Name = $script:Cap.Name }
    if ($Source) { $p['Source'] = $Source }
    if ($LimitAccess) { $p['LimitAccess'] = $true }
    try { $res = Add-WindowsCapability @p }
    catch {
        $hint = ' With WSUS, the policy "Specify settings for optional component installation and component repair" must let Features on Demand come from Windows Update; otherwise give -Source.'
        if ($Source) { $hint = ' Check that -Source holds the Features on Demand for this exact Windows build.' }
        Stop-Run ('Installing OpenSSH Server failed: ' + $_.Exception.Message + $hint) 'install' }
    if ($res -and $res.RestartNeeded) { Add-Warning 'Windows reports that a restart is needed to finish the OpenSSH Server install.' }
    $script:Svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if (-not $script:Svc) { Stop-Run 'The OpenSSH Server capability was added, but there is no sshd service yet. Restart the server and run this script again.' 'install' }
    $script:SshdExe = Find-OpenSshTool 'sshd.exe'
    $script:KeygenExe = Find-OpenSshTool 'ssh-keygen.exe'
    $script:R.OpenSSH = 'installed now'
    Say 'OpenSSH Server installed.' 'OK' }
function Get-HostKeyFiles {
    if (-not $script:SshDir -or -not (Test-Path -LiteralPath $script:SshDir)) { return }
    return @(Get-ChildItem -LiteralPath $script:SshDir -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^ssh_host_[a-z0-9]+_key$' }) }
function Repair-HostKeyAccess { param([switch]$Quiet)
    # sshd runs as SYSTEM and refuses a private host key that anyone but SYSTEM and Administrators
    # can read, then stops with "no hostkeys available". Each key is put right on its own.
    $keys = @(Get-HostKeyFiles)
    $fixed = 0; $bad = 0
    foreach ($k in $keys) {
        $why = Get-AclProblem $k.FullName
        if (-not $why) { continue }
        Say ($k.Name + ': ' + $why + '. sshd refuses a host key like that.') 'WARN'
        if (-not (Confirm-Change $k.FullName 'Limit access to SYSTEM and Administrators')) { $bad++; continue }
        $left = Set-AdminOnlyAcl $k.FullName
        if ($left) { $bad++; Add-Problem ($k.Name + ': the permissions could not be put right (' + $left + ').') 'hostkeys' }
        else { $fixed++; $script:HostKeysChanged = $true; Say ($k.Name + ': now SYSTEM and Administrators only.') 'OK' }
    }
    if ($keys.Count -and -not $fixed -and -not $bad -and -not $Quiet) { Say ([string]$keys.Count + ' host keys, each limited to SYSTEM and Administrators.') 'OK' }
    $text = [string]$keys.Count + ' found'
    if ($fixed) { $text += ', permissions put right on ' + $fixed }
    if ($bad) { $text += ', ' + $bad + ' still wrong' }
    if (-not $fixed -and -not $bad) { $text += ', permissions right' }
    $script:R.HostKeys = $text }
function Test-HostKeys {
    Write-Step 'Host keys'
    if ($script:Pending) { Say 'sshd makes them on its first start.'; $script:R.HostKeys = 'made on the first start'; return }
    if (@(Get-HostKeyFiles).Count -eq 0) { Say 'None yet: sshd makes them on its first start.'; $script:R.HostKeys = 'none yet'; return }
    Repair-HostKeyAccess }
function Show-SshdEvents {
    # The latest sshd events, which say why it stopped (they hold no secret).
    try {
        $ev = @(Get-WinEvent -LogName 'OpenSSH/Operational' -MaxEvents 6 -ErrorAction Stop)
        [array]::Reverse($ev)
        foreach ($e in $ev) { Say ('sshd event ' + $e.TimeCreated.ToString('HH:mm:ss') + ': ' + (([string]$e.Message) -replace '\s+', ' ').Trim()) 'WARN' }
    } catch { } }
function Start-SshdOnce {
    try { Start-Service -Name sshd -Confirm:$false } catch { Say ('Start-Service: ' + $_.Exception.Message) 'WARN'; return $false }
    Start-Sleep -Seconds 2   # sshd that cannot load its host keys starts, then stops at once
    return ((Get-Service -Name sshd).Status -eq 'Running') }
function Start-SshService {
    Write-Step 'sshd service'
    if ($script:Pending) { Say 'Would set sshd to start automatically and start it.'; $script:R.Service = 'would be started, automatic'; return }
    $w = Get-CimInstance -ClassName Win32_Service -Filter "Name='sshd'"
    $mode = 'automatic'
    if ([string]$w.StartMode -ne 'Auto') {
        if (Confirm-Change 'sshd' 'Set the startup type to Automatic') {
            Set-Service -Name sshd -StartupType Automatic -Confirm:$false
            Say ('Startup type set to Automatic (was ' + $w.StartMode + ').') 'OK'
        } else { $mode = 'would be automatic' } }
    else { Say 'Starts automatically with Windows.' 'OK' }
    if ((Get-Service -Name sshd).Status -eq 'Running') { Say 'sshd is running.' 'OK'; $script:R.Service = 'running, ' + $mode; return }
    if (-not (Confirm-Change 'sshd' 'Start the service')) { $script:R.Service = 'would be started, ' + $mode; return }
    $hadKeys = @(Get-HostKeyFiles).Count
    if (Start-SshdOnce) {
        # a fresh start has read the host keys as they are now: no restart is needed for them
        Say 'sshd started.' 'OK'; $script:R.Service = 'running, ' + $mode; $script:HostKeysChanged = $false
        if ($hadKeys -eq 0) { Repair-HostKeyAccess -Quiet; Say ('sshd made its host keys: ' + $script:R.HostKeys + '.') 'OK' }
        return }
    Show-SshdEvents
    if (@(Get-HostKeyFiles).Count -eq 0 -and $script:KeygenExe) {
        Say 'There are no host keys. Making them with ssh-keygen -A, then starting sshd again.' 'WARN'
        $r = Invoke-Native $script:KeygenExe @('-A')
        if ($r.ExitCode -ne 0) { Say ('ssh-keygen -A: ' + (Join-Output $r.Output)) 'WARN' }
        # keys made in an admin's session carry an entry for that admin: put them right first
        Repair-HostKeyAccess
        if (Start-SshdOnce) { Say 'sshd started.' 'OK'; $script:R.Service = 'running, ' + $mode; $script:HostKeysChanged = $false; return }
        Show-SshdEvents
    }
    Stop-Run 'sshd does not start. The OpenSSH/Operational event log (Applications and Services Logs > OpenSSH > Operational) says why; the latest entries are shown above.' 'service' }
function Add-AdminKeys {
    Write-Step 'Authorised keys'
    $file = $script:KeysFile
    # read whenever it is there, also before OpenSSH Server is installed: C:\ProgramData\ssh stays
    # when it is removed, and lines already in the file are kept, never written over
    $exists = Test-Path -LiteralPath $file
    $lines = @(); $enc = 'plain'
    if ($exists) { $rt = Read-TextFile $file; $enc = $rt.Encoding; $lines = @(Split-Lines $rt.Text) }
    # The keys the file holds once it is plain text, as sshd reads them: a key that is there only
    # on a # comment line, or behind text that sshd does not read as options, does not count, and
    # it is added again when it is given.
    $have = Get-KeyFileKeys $lines
    $present = $have.Keys
    $valid = $present.Count
    if ($have.Skipped.Count) { Add-Warning ('administrators_authorized_keys, line ' + ($have.Skipped -join ', ') + ': a key that sshd does not use (its data does not decode, or what is in front of it is not options sshd accepts). It does not count; give that key with -PublicKey to add it on a line of its own.') }
    $add = @()
    foreach ($k in @($script:InputKeys)) {
        if ($present.ContainsKey($k.Id)) {
            $how = ''; if ($present[$k.Id].Options) { $how = ', with options in front' }
            Say ('Already in the file' + $how + ': ' + (Format-Key $k) + '.') 'OK' }
        else { $add += $k; $present[$k.Id] = $k } }
    if ($enc -eq 'UTF-16') { Say 'The file is saved as UTF-16, which is what > and Out-File write in Windows PowerShell 5.1. sshd cannot read that, so it is saved again as plain text.' 'WARN' }
    elseif ($enc -eq 'UTF-8 BOM') { Say 'The file starts with a byte-order mark, which can hide its first key from sshd, so it is saved again without one.' 'WARN' }
    $saved = $false
    if ($add.Count -or $enc -ne 'plain') {
        $action = 'Save again as plain text'
        if ($add.Count) { $action = 'Add ' + $add.Count + ' public key(s)' }
        if (Confirm-Change $file $action) {
            try {
                Initialize-SshFolder
                # every line already there is kept as it is; the new keys go after the last one
                $keep = @($lines)
                while ($keep.Count -and -not ([string]$keep[$keep.Count - 1]).Trim()) { if ($keep.Count -eq 1) { $keep = @() } else { $keep = @($keep[0..($keep.Count - 2)]) } }
                $all = @($keep) + @($add | ForEach-Object { $_.Line })
                try { Write-TextLines $file $all }
                catch {
                    # a key file administrators cannot write: put its permissions right, then once more
                    $null = Set-AdminOnlyAcl $file; Write-TextLines $file $all }
                $saved = $true
                foreach ($k in $add) { Say ('Added: ' + (Format-Key $k) + '.') 'OK' }
                $script:AddedKeys = @($add | ForEach-Object { $_.Fingerprint })
                $script:R.KeysAdded = $add.Count
            } catch { Add-Problem ('administrators_authorized_keys could not be written: ' + $_.Exception.Message) 'keys' }
        } else { $script:R.KeysAdded = 0 } }
    # What sshd reads counts: the file as it is on disk now, whatever was or was not written.
    # Under -WhatIf, the file as it would be.
    $lost = 0
    if ($script:IsWhatIf) { $script:ValidKeys = $valid + $add.Count }
    elseif (Test-Path -LiteralPath $file) {
        try { $script:ValidKeys = (Get-KeysAsRead $file).Keys.Count }
        catch { $script:ValidKeys = 0; Add-Warning ('administrators_authorized_keys cannot be read back: ' + $_.Exception.Message) } }
    else { $script:ValidKeys = 0 }
    if (-not $script:IsWhatIf -and $enc -ne 'plain' -and -not $saved) {
        $script:KeysUnreadable = $enc
        $lost = $valid - $script:ValidKeys
        if ($lost -gt 0) { Add-Warning ([string]$lost + ' key(s) in administrators_authorized_keys cannot be read by sshd while the file is saved as ' + $enc + '. They do not count, so password sign-in stays as it is; run the script again to save the file as plain text.') } }
    $script:R.KeysInFile = $script:ValidKeys
    if ($script:IsWhatIf -and $add.Count) { $script:R.KeysAdded = 'would add ' + $add.Count }
    # access: OpenSSH ignores the file unless only Administrators and SYSTEM can reach it
    if (-not $script:Pending -and (Test-Path -LiteralPath $file)) {
        $why = Get-AclProblem $file
        if (-not $why) { $script:KeyFileOk = $true; $script:R.KeyFileAccess = 'Administrators and SYSTEM only'; Say 'Only Administrators and SYSTEM can reach the file.' 'OK' }
        else {
            Say ('administrators_authorized_keys: ' + $why + '. OpenSSH ignores the file until only Administrators and SYSTEM can reach it.') 'WARN'
            if (Confirm-Change $file 'Limit access to Administrators and SYSTEM') {
                $left = Set-AdminOnlyAcl $file
                if ($left) { $script:R.KeyFileAccess = 'WRONG: ' + $left; Add-Problem ('administrators_authorized_keys: the permissions could not be put right (' + $left + '), so sshd ignores the file.') 'keys' }
                else { $script:KeyFileOk = $true; $script:R.KeyFileAccess = 'Administrators and SYSTEM only (put right now)'; Say 'Now only Administrators and SYSTEM can reach the file.' 'OK' }
            } else { $script:KeyFileOk = $script:IsWhatIf; $script:R.KeyFileAccess = 'would be limited to Administrators and SYSTEM' } }
    } elseif ($script:IsWhatIf -and $add.Count) { $script:KeyFileOk = $true; $script:R.KeyFileAccess = 'would be Administrators and SYSTEM only' }
    else { $script:R.KeyFileAccess = 'no file yet' }
    if ($script:ValidKeys -eq 0) { if ($lost -le 0) { Add-Warning 'administrators_authorized_keys holds no valid key, so password sign-in stays as it is. Give a key with -PublicKey or -PublicKeyFile.' } }
    elseif ($script:IsWhatIf -and $add.Count) { Say ('The file would then hold ' + $script:ValidKeys + ' valid key(s).') }
    else { Say ([string]$script:ValidKeys + ' valid key(s) in the file.') 'OK' } }
function Set-SshFirewallScope {
    Write-Step 'Firewall (TCP 22)'
    $want = @(@($script:Specs) | ForEach-Object { $_.Text })
    $wantKey = Get-AddressKey $want
    $wantText = $want -join ', '
    if ($script:Pending) {
        if ($want.Count) { Say ('The install adds rule OpenSSH-Server-In-TCP (TCP 22 from any address); it would then be limited to ' + $wantText + '.'); $script:R.Firewall = 'would be TCP 22 from ' + $wantText }
        else { Say 'The install adds rule OpenSSH-Server-In-TCP: TCP 22 from any address.'; $script:R.Firewall = 'TCP 22 from any address (rule made by the install)' }
        return }
    $p0 = $script:Problems.Count
    $failed = @{}; $declined = $false
    $rules = @(Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP*' -ErrorAction SilentlyContinue)
    $profiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction SilentlyContinue)
    $managed = @($profiles | Where-Object { "$($_.Enabled)" -eq 'True' -and "$($_.AllowLocalFirewallRules)" -eq 'False' })
    if (-not $want.Count) {
        # what lets TCP 22 in is read back below; a rule someone disabled stays disabled
        Say 'No -AllowFrom, so no firewall rule is added, enabled or changed.'
    } elseif ($rules.Count -eq 0) {
        Say ('There is no OpenSSH-Server-In-TCP rule. Adding one: TCP 22 from ' + $wantText + '.') 'WARN'
        if (Confirm-Change 'Windows Firewall' ('Add inbound rule OpenSSH-Server-In-TCP, TCP 22 from ' + $wantText)) {
            $p = @{ Name = 'OpenSSH-Server-In-TCP'; DisplayName = 'OpenSSH SSH Server (sshd)'; Enabled = 'True'; Direction = 'Inbound'
                    Protocol = 'TCP'; LocalPort = '22'; Action = 'Allow'; Profile = 'Any'; RemoteAddress = $want }
            try { $null = New-NetFirewallRule @p -Confirm:$false; Say 'Rule added.' 'OK' }
            catch { Add-Problem ('The firewall rule could not be added: ' + $_.Exception.Message) 'firewall' } }
        elseif (-not $script:IsWhatIf) { $declined = $true }
    } else {
        # each rule is limited first and enabled only after that, so it never lets every address in
        $scoped = @{}
        foreach ($r in $rules) {
            $cur = @(($r | Get-NetFirewallAddressFilter).RemoteAddress)
            if ((Get-AddressKey $cur) -eq $wantKey) { $scoped[$r.Name] = $true; Say ($r.Name + ': already TCP 22 from ' + $wantText + ' only.') 'OK'; continue }
            if (Confirm-Change ('firewall rule ' + $r.Name) ('Let TCP 22 in only from ' + $wantText)) {
                try { Set-NetFirewallRule -Name $r.Name -RemoteAddress $want -Confirm:$false; $scoped[$r.Name] = $true; Say ($r.Name + ': TCP 22 now only from ' + $wantText + ' (was ' + (Format-Scope $cur) + ').') 'OK' }
                catch {
                    $failed[$r.Name] = $true
                    $still = ' It is disabled, and stays so.'
                    if ("$($r.Enabled)" -eq 'True') { $still = ' It is enabled, and still lets TCP 22 in from ' + (Format-Scope $cur) + '.' }
                    Add-Problem ('Rule ' + $r.Name + ' could not be limited to ' + $wantText + ': ' + $_.Exception.Message + $still) 'firewall' } }
            elseif ($script:IsWhatIf) { $scoped[$r.Name] = $true }
            else { $declined = $true } }
        if (@($rules | Where-Object { "$($_.Enabled)" -eq 'True' }).Count -eq 0) {
            $pick = @($rules | Where-Object { $_.Name -eq 'OpenSSH-Server-In-TCP' })
            if (-not $pick.Count) { $pick = @($rules[0]) }
            $name = $pick[0].Name
            if ($scoped.ContainsKey($name)) {
                Say ('No OpenSSH-Server-In-TCP rule is enabled. Enabling ' + $name + ', which lets TCP 22 in only from ' + $wantText + '.') 'WARN'
                if (Confirm-Change ('firewall rule ' + $name) 'Enable') {
                    try { Enable-NetFirewallRule -Name $name -Confirm:$false; Say ($name + ' enabled.') 'OK' }
                    catch { Add-Problem ('Rule ' + $name + ' could not be enabled: ' + $_.Exception.Message) 'firewall' } }
                elseif (-not $script:IsWhatIf) { $declined = $true } }
            else { Say ('No OpenSSH-Server-In-TCP rule is enabled, and ' + $name + ' stays disabled: it is enabled only once it lets TCP 22 in from ' + $wantText + ' alone.') 'WARN' } }
    }
    foreach ($pr in $profiles) {
        if ("$($pr.Enabled)" -eq 'True' -and "$($pr.AllowLocalFirewallRules)" -eq 'False') {
            Add-Warning ('Group Policy manages the ' + $pr.Name + ' firewall profile and ignores local rules: the OpenSSH-Server-In-TCP rules have no effect there, and TCP 22 is open only as far as that policy says. Set the limit in that policy.') }
        elseif ("$($pr.Enabled)" -eq 'False' -and $want.Count) {
            Add-Warning ('The firewall is off for the ' + $pr.Name + ' profile: on networks of that type TCP 22 is open to every address, whatever -AllowFrom says.') } }
    if ($script:IsWhatIf -and $want.Count) { $script:R.Firewall = 'would be TCP 22 from ' + $wantText; return }
    # read back from the policy Windows enforces, not only from the local store that was changed
    $parts = @(); $missing = @(); $ours = 0
    foreach ($r in @(Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP*' -ErrorAction SilentlyContinue)) {
        if ("$($r.Enabled)" -ne 'True') { continue }
        $act = $null
        try { $act = Get-NetFirewallRule -Name $r.Name -PolicyStore ActiveStore -ErrorAction Stop } catch { }
        if (-not $act) { $missing += $r.Name; continue }
        $ours++
        $ra = @(($act | Get-NetFirewallAddressFilter).RemoteAddress)
        $parts += ('TCP 22 from ' + (Format-Scope $ra) + ' (' + $r.Name + ')')
        if ($want.Count -and (Get-AddressKey $ra) -ne $wantKey -and -not $failed.ContainsKey($r.Name)) { Add-Problem ('Rule ' + $r.Name + ' still lets TCP 22 in from ' + (Format-Scope $ra) + ', not only from ' + $wantText + '.') 'firewall' }
    }
    if ($missing.Count) {
        # Group Policy that does not merge local rules leaves them out of the policy in force:
        # that fails a run that was to set a limit, and is a warning for one that was not
        $msg = 'Rule ' + ($missing -join ', ') + ' is enabled, but is not in the policy Windows enforces now'
        if ($managed.Count) { $msg += ': Group Policy ignores local rules (see above)' }
        if ($want.Count) {
            $msg += ', so the limit to ' + $wantText + ' is not in force.'
            if ($managed.Count) { $msg += ' Set it in that policy.' }
            Add-Problem $msg 'firewall' }
        else { Add-Warning ($msg + '.') } }
    # Rules of any name: with -AllowFrom the ones that undo the limit, without it whether any
    # rule lets TCP 22 in when no OpenSSH-Server-In-TCP rule does.
    $others = $null
    if ($want.Count -or $ours -eq 0) {
        try { $others = @(Get-OtherTcp22Rules) }
        catch { Add-Warning ('The other firewall rules could not be read: ' + $_.Exception.Message) } }
    if ($others) {
        $i = 0
        foreach ($o in $others) {
            $i++
            if ($i -le 4) { $parts += ('TCP 22 from ' + $o.Scope + ' ("' + $o.DisplayName + '")') }
            if ($want.Count -and $o.Scope -eq 'any address') { Add-Warning ('Rule "' + $o.DisplayName + '" (' + $o.Name + ') also lets TCP 22 in from any address, so the limit has no effect while it is enabled. Change or disable it.') } }
        if ($i -gt 4) { $parts += ('and ' + ($i - 4) + ' more rule(s)') } }
    if ($parts.Count) { $script:R.Firewall = $parts -join '; '; Say ('In force: ' + $script:R.Firewall + '.') }
    elseif ($null -eq $others) { $script:R.Firewall = 'no OpenSSH-Server-In-TCP rule in force; the other rules could not be read' }
    else { $script:R.Firewall = 'no enabled rule lets TCP 22 in' }
    if ($ours -eq 0) {
        if ($want.Count) {
            if ($script:Problems.Count -eq $p0 -and -not $declined) { Add-Problem ('No OpenSSH-Server-In-TCP rule is in force, so the limit to ' + $wantText + ' is not applied.') 'firewall' } }
        elseif ($null -ne $others -and $others.Count -eq 0) {
            Add-Warning 'No enabled inbound firewall rule lets TCP 22 in, so SSH connections are most likely blocked. Give -AllowFrom with the networks that may connect, or enable rule OpenSSH-Server-In-TCP.' } } }
function Update-SshdConfig {
    Write-Step 'sshd_config'
    $gate = New-Object System.Collections.Generic.List[string]
    if ($KeepPasswordSignIn) { $gate.Add('kept by -KeepPasswordSignIn') }
    if ($script:ValidKeys -lt 1) {
        if ($script:KeysUnreadable) { $gate.Add('administrators_authorized_keys holds no key that sshd can read (it is saved as ' + $script:KeysUnreadable + ')') }
        else { $gate.Add('administrators_authorized_keys holds no valid key') } }
    elseif (-not $script:KeyFileOk) { $gate.Add('administrators_authorized_keys is not limited to Administrators and SYSTEM, so sshd ignores it') }
    if ($script:Pending) {
        $set = @('PubkeyAuthentication yes')
        if ($gate.Count -eq 0) { $set += @('PasswordAuthentication no', 'ChallengeResponseAuthentication no'); $script:R.PasswordSignIn = 'would be off' }
        else { $script:R.PasswordSignIn = 'on (' + ($gate -join '; ') + ')' }
        if ($Banner) { $set += ('Banner ' + ($script:BannerFile -replace '\\', '/')); $script:R.Banner = 'would be set' } else { $script:R.Banner = 'not set' }
        $list = $set[0]
        if ($set.Count -gt 1) { $list = ($set[0..($set.Count - 2)] -join ', ') + ' and ' + $set[$set.Count - 1] }
        Say ('Would set ' + $list + ' in the sshd_config that sshd makes on its first start.'); return }
    if (-not (Test-Path -LiteralPath $script:ConfigFile)) { Add-Problem ('sshd_config was not found in ' + $script:SshDir + '. sshd makes it on its first start.') 'config'; return }
    $rt = Read-TextFile $script:ConfigFile
    $nl = "`n"; if ($rt.Text.Contains("`r`n")) { $nl = "`r`n" }
    $orig = @(Split-Lines $rt.Text)
    $names = @('PubkeyAuthentication')
    $new = @(Set-SshdOption $orig 'PubkeyAuthentication' 'yes')
    # Key sign-in must work for administrators with the file as it is about to be, worked out the
    # way sshd does it for their connections, before password sign-in may go: a Match block can
    # point them at another key file, or turn key sign-in off for them.
    foreach ($w in @(Get-AdminKeyConfigProblems $new)) { $gate.Add($w) }
    if ($gate.Count -eq 0) {
        $new = @(Set-SshdOption $new 'PasswordAuthentication' 'no'); $names += 'PasswordAuthentication'
        # ChallengeResponseAuthentication covers keyboard-interactive on every Win32-OpenSSH build;
        # the newer KbdInteractiveAuthentication keyword stops older builds from starting, so it is
        # changed only when the file already uses it.
        $new = @(Set-SshdOption $new 'ChallengeResponseAuthentication' 'no'); $names += 'ChallengeResponseAuthentication'
        if ($null -ne (Get-SshdOption $new 'KbdInteractiveAuthentication')) { $new = @(Set-SshdOption $new 'KbdInteractiveAuthentication' 'no'); $names += 'KbdInteractiveAuthentication' }
    }
    if ($Banner) {
        $keyOnly = ($gate.Count -eq 0) -or ((Get-PasswordState $orig) -eq 'off')
        $text = New-BannerText $keyOnly
        $cur = $null
        if (Test-Path -LiteralPath $script:BannerFile) { $cur = (Read-TextFile $script:BannerFile).Text }
        if ($cur -and $cur.TrimEnd() -ceq $text.TrimEnd()) { Say 'banner.txt is up to date.' 'OK' }
        elseif (Confirm-Change $script:BannerFile 'Write the pre-sign-in banner') {
            [System.IO.File]::WriteAllText($script:BannerFile, $text, [System.Text.Encoding]::ASCII)
            Say ('Banner written to ' + $script:BannerFile + '.') 'OK' }
        # forward slashes: newer sshd reads a backslash in sshd_config as an escape character
        $new = @(Set-SshdOption $new 'Banner' ($script:BannerFile -replace '\\', '/')); $names += 'Banner'
    }
    $changes = @()
    foreach ($n in $names) {
        $a = Get-SshdOption $orig $n; $b = Get-SshdOption $new $n
        if ($a -ne $b) { if ($a) { $changes += ($n + ' ' + $b + ' (was ' + $a + ')') } else { $changes += ($n + ' ' + $b + ' (was the default)') } } }
    $changed = (($orig -join "`n") -cne ($new -join "`n"))
    $script:FinalConfig = $orig
    if (-not $changed) { Say 'Already as wanted; nothing to change.' 'OK' }
    elseif (Confirm-Change $script:ConfigFile ('Set ' + ($changes -join ', '))) {
        $cand = $script:ConfigFile + '.candidate'
        Write-TextLines $cand $new $nl
        $test = Test-SshdConfig $cand
        Remove-Item -LiteralPath $cand -Force -Confirm:$false -ErrorAction SilentlyContinue
        if ($test.State -eq 'failed') {
            Add-Problem ('The new sshd_config fails sshd -t, so it was not used and the file was not changed: ' + $test.Text) 'config' }
        else {
            if ($test.State -eq 'skipped') { Say ('sshd -t could not test the new file (' + $test.Text + '). The restart check below still guards it.') 'WARN' }
            $bak = $script:ConfigFile + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
            Copy-Item -LiteralPath $script:ConfigFile -Destination $bak -Force -Confirm:$false
            Write-TextLines $script:ConfigFile $new $nl
            $script:ConfigBackup = $bak; $script:ConfigChanged = $true; $script:FinalConfig = $new
            foreach ($c in $changes) { Say ('Set ' + $c + '.') 'OK' }
            Say ('The previous file is kept as ' + (Split-Path -Leaf $bak) + '.') } }
    $judge = $script:FinalConfig
    if ($script:IsWhatIf) { $judge = $new }
    $state = Get-PasswordState $judge
    if ($state -eq 'off') {
        $script:R.PasswordSignIn = 'off (key sign-in only)'
        if ($script:IsWhatIf -and (Get-PasswordState $orig) -eq 'on') { $script:R.PasswordSignIn = 'would be off (key sign-in only)' }
        # a Match block can turn it on again for the accounts it selects
        $on = @(Get-PasswordOnBlocks $judge)
        if ($on.Count) { $script:R.PasswordSignIn = ($script:R.PasswordSignIn -replace ' \(key sign-in only\)$', '') + ', but on for the accounts selected by ' + ($on -join ' and ') }
        $cfgWhy = @(Get-AdminKeyConfigProblems $judge)
        if ($script:ValidKeys -lt 1) { Add-Warning 'Password sign-in is off, but administrators_authorized_keys holds no valid key: no administrator can sign in over SSH. Add a key with -PublicKey.' }
        elseif ($cfgWhy.Count) { Add-Warning ('Password sign-in is off, but ' + ($cfgWhy -join '; ') + ': administrators may not be able to sign in over SSH at all.') }
    } elseif ($gate.Count) {
        $script:R.PasswordSignIn = 'on (' + ($gate -join '; ') + ')'
        if (-not $KeepPasswordSignIn) { Add-Warning ('Password sign-in stays on: ' + ($gate -join '; ') + '.') }
    } else { $script:R.PasswordSignIn = 'on' }
    $bv = Get-SshdOption $judge 'Banner'
    if ($bv -and $bv -ne 'none') { $script:R.Banner = 'shown before sign-in (' + $bv + ')' } else { $script:R.Banner = 'not set' }
    foreach ($o in @(Get-MatchOverrides $judge @('PasswordAuthentication','PubkeyAuthentication','AuthenticationMethods','KbdInteractiveAuthentication','ChallengeResponseAuthentication'))) {
        Add-Warning ('sshd_config sets ' + $o + ' inside a Match block; it overrides the global setting for the accounts that block matches.') }
    foreach ($inc in @($judge | Where-Object { $_ -match '^\s*Include\s' })) { Add-Warning ('sshd_config includes other files (' + $inc.Trim() + '); a setting there can come first.') }
    $port = Get-SshdOption $judge 'Port'
    if ($port -and $port.Trim() -ne '22') { Add-Warning ('sshd_config sets Port ' + $port + ', but the OpenSSH-Server-In-TCP rules and this script handle TCP 22 only.') }
    $fac = Get-SshdOption $judge 'SyslogFacility'
    if ($LoginAlert -and $fac -and $fac -match 'LOCAL0') { Add-Warning 'sshd_config sends sshd''s log to a file (SyslogFacility LOCAL0), so the login alert, which reads the event log, sees no sign-in.' } }
function Test-PwshPath { param([string]$Path)
    # Whether a DefaultShell value is PowerShell 7 (pwsh.exe), quoted or not.
    return ([string]$Path -match '(^|[\\/])pwsh(\.exe)?"?\s*$') }
function Set-SshDefaultShell {
    $key = 'HKLM:\SOFTWARE\OpenSSH'
    $cur = $null
    try { $cur = [string](Get-ItemProperty -Path $key -Name DefaultShell -ErrorAction Stop).DefaultShell } catch { }
    $curText = 'cmd.exe (the Windows default)'; if ($cur) { $curText = $cur }
    if ($script:Shell -eq 'None') {
        $script:R.DefaultShell = 'unchanged: ' + $curText
        # earlier set-up scripts made PowerShell 7 the default shell wherever it was installed
        if (Test-PwshPath $cur) {
            Write-Step 'Default shell'
            Add-Warning ('The default SSH shell is PowerShell 7 (' + $cur + '), left as it is. ' + $script:Pwsh7Note + ' -DefaultShell WindowsPowerShell changes it.') }
        return }
    Write-Step 'Default shell'
    $want = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if ($script:Shell -eq 'PowerShell7') { $want = $script:Pwsh7Path }
    $now = $cur
    if ($cur -and $cur -eq $want) { Say ('Already ' + $want + '.') 'OK'; $script:R.DefaultShell = $want }
    elseif (Confirm-Change ($key + '\DefaultShell') ('Set to ' + $want)) {
        try {
            if (-not (Test-Path -Path $key)) { $null = New-Item -Path $key -Force -Confirm:$false }
            $null = New-ItemProperty -Path $key -Name DefaultShell -Value $want -PropertyType String -Force -Confirm:$false
            Say ('Default shell set to ' + $want + ' (was ' + $curText + '). New SSH sessions start in it.') 'OK'
            $script:R.DefaultShell = $want; $now = $want
        } catch { Add-Problem ('The default shell could not be set: ' + $_.Exception.Message) 'shell' }
    } else { $script:R.DefaultShell = 'would be ' + $want; if ($script:IsWhatIf) { $now = $want } }
    if ($script:Shell -eq 'PowerShell7') { if (-not $script:Warnings.Contains($script:Pwsh7Note)) { $script:Warnings.Add($script:Pwsh7Note) } }
    elseif (Test-PwshPath $now) { Add-Warning ('The default SSH shell is still PowerShell 7 (' + $now + '). ' + $script:Pwsh7Note) } }
function Test-AlertSource { return [System.Diagnostics.EventLog]::SourceExists($script:AlertSource) }
function New-AlertSource { [System.Diagnostics.EventLog]::CreateEventSource($script:AlertSource, 'Application') }
function Register-LoginAlert {
    if (-not $LoginAlert) {
        $t = $null
        if (-not $script:Pending) { $t = Get-ScheduledTask -TaskName $script:AlertTask -ErrorAction SilentlyContinue }
        if ($t) { $script:R.LoginAlert = 'set (task ' + $script:AlertTask + ', ' + $t.State + ')' } else { $script:R.LoginAlert = 'not set' }
        return }
    Write-Step 'Login alert'
    if ($script:Pending) { Say ('Would add the ' + $script:AlertSource + ' event source and the ' + $script:AlertTask + ' scheduled task.'); $script:R.LoginAlert = 'would be set'; return }
    try {
        if (-not (Test-AlertSource)) {
            if (Confirm-Change 'Application event log' ('Add the event source ' + $script:AlertSource)) {
                New-AlertSource
                Say ('Event source ' + $script:AlertSource + ' added to the Application log.') 'OK' } }
        $log = Get-WinEvent -ListLog 'OpenSSH/Operational' -ErrorAction SilentlyContinue
        if (-not $log) { Add-Warning 'There is no OpenSSH/Operational event log, so the login alert cannot see sign-ins.' }
        elseif (-not $log.IsEnabled) {
            if (Confirm-Change 'OpenSSH/Operational' 'Enable the event log') { $log.IsEnabled = $true; $log.SaveChanges(); Say 'The OpenSSH/Operational event log is now enabled.' 'OK' } }
        if (-not (Test-Path -Path $script:AlertKey)) {
            # start after the newest event, so sign-ins made before the alert existed are not reported
            if (Confirm-Change $script:AlertKey 'Record where the alert starts') {
                $newest = [long]0
                try { $newest = [long](Get-WinEvent -LogName 'OpenSSH/Operational' -MaxEvents 1 -ErrorAction Stop).RecordId } catch { }
                $null = New-Item -Path $script:AlertKey -Force -Confirm:$false
                $null = New-ItemProperty -Path $script:AlertKey -Name LastRecordId -Value $newest -PropertyType QWord -Force -Confirm:$false } }
        $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($script:AlertCode))
        $taskArgs = '-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand ' + $enc
        $old = Get-ScheduledTask -TaskName $script:AlertTask -ErrorAction SilentlyContinue
        $same = $false
        if ($old) { try { $same = ([string](@($old.Actions)[0].Arguments) -ceq $taskArgs) -and ("$($old.State)" -ne 'Disabled') } catch { } }
        if ($same) { Say ('The ' + $script:AlertTask + ' task is already in place.') 'OK'; $script:R.LoginAlert = 'set (task ' + $script:AlertTask + ')'; return }
        if (-not (Confirm-Change ('scheduled task ' + $script:AlertTask) 'Register it to run as SYSTEM on each sshd event')) { $script:R.LoginAlert = 'would be set'; return }
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $taskArgs
        # A real event trigger bound to the OpenSSH Operational log
        $subscription = '<QueryList><Query Id="0" Path="OpenSSH/Operational"><Select Path="OpenSSH/Operational">*[System[(EventID=4)]]</Select></Query></QueryList>'
        $triggerClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace 'Root/Microsoft/Windows/TaskScheduler'
        $trigger = New-CimInstance -CimClass $triggerClass -ClientOnly
        $trigger.Subscription = $subscription
        $trigger.Enabled = $true
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
        $null = Register-ScheduledTask -TaskName $script:AlertTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force `
            -Description ('Writes an Application log warning (source ' + $script:AlertSource + ', event 1000) for each accepted SSH sign-in. Added by ' + $script:Name + '.')
        Say ('Scheduled task ' + $script:AlertTask + ' registered (trigger: OpenSSH/Operational event 4, runs as SYSTEM).') 'OK'
        # one test run: it should find nothing new to report and end with 0
        Start-ScheduledTask -TaskName $script:AlertTask
        $res = $null
        for ($i = 0; $i -lt 15; $i++) {
            Start-Sleep -Seconds 1
            $info = Get-ScheduledTaskInfo -TaskName $script:AlertTask
            if ("$((Get-ScheduledTask -TaskName $script:AlertTask).State)" -eq 'Ready' -and $info.LastTaskResult -ne 267009 -and $info.LastTaskResult -ne 267011) { $res = $info.LastTaskResult; break } }
        if ($res -eq 0) { Say 'A test run of the task ended without error.' 'OK'; $script:R.LoginAlert = 'set (task ' + $script:AlertTask + ')' }
        else { $script:R.LoginAlert = 'set, test run not confirmed'; Add-Warning ('The test run of ' + $script:AlertTask + ' did not end with 0 (result ' + $res + '). Look at the task''s history in Task Scheduler.') }
    } catch { Add-Problem ('The login alert could not be set up: ' + $_.Exception.Message) 'alert' } }
function Restart-SshServer {
    Write-Step 'Restart sshd'
    if ($script:Pending) { Say 'Would restart sshd once the changes above are made.'; $script:R.Restarted = 'would restart'; return }
    if (-not ($script:ConfigChanged -or $script:HostKeysChanged)) {
        if ($script:IsWhatIf -and $script:Problems.Count -eq 0) { Say 'Needed only if the changes above are made.' } else { Say 'Not needed: nothing that sshd reads at start has changed.' 'OK' }
        $script:R.Restarted = 'not needed'
        if ($script:IsWhatIf) { $script:R.Restarted = 'only if the changes are made' }
        return }
    if (-not (Confirm-Change 'sshd' 'Restart the service')) { $script:R.Restarted = 'would restart'; return }
    if ($script:SshClient) { Say 'This run is inside an SSH session. If the session ends at the restart, every change before it is already made; run the script again to see the summary.' }
    $ok = $false
    try { Restart-Service -Name sshd -Force -Confirm:$false; Start-Sleep -Seconds 2; $ok = ((Get-Service -Name sshd).Status -eq 'Running') }
    catch { Say ('Restart-Service: ' + $_.Exception.Message) 'WARN' }
    if ($ok) {
        $script:R.Restarted = 'yes'; Say 'sshd restarted and running.' 'OK'
        $port = 22
        $pv = Get-SshdOption $script:FinalConfig 'Port'
        if ($pv -and $pv.Trim() -match '^\d+$') { $port = [int]$pv.Trim() }
        $listen = @()
        try { $listen = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction Stop) } catch { }
        if ($listen.Count) { Say ('sshd is listening on TCP ' + $port + '.') 'OK' } else { Add-Warning ('sshd runs, but nothing is listening on TCP ' + $port + ' yet.') }
        return }
    Show-SshdEvents
    if ($script:ConfigBackup) {
        Copy-Item -LiteralPath $script:ConfigBackup -Destination $script:ConfigFile -Force -Confirm:$false
        $script:FinalConfig = @(Split-Lines (Read-TextFile $script:ConfigFile).Text)
        $script:R.PasswordSignIn = (Get-PasswordState $script:FinalConfig) + ' (the previous sshd_config was put back)'
        $script:R.Restarted = 'failed; previous sshd_config put back'
        if (Start-SshdOnce) { Add-Problem ('sshd did not come back with the new sshd_config, so the previous one (' + (Split-Path -Leaf $script:ConfigBackup) + ') was put back and sshd runs with it.') 'restart' }
        else { Add-Problem 'sshd does not start, even with the previous sshd_config put back. See the sshd events above.' 'restart' }
        return }
    $script:R.Restarted = 'failed'
    Add-Problem 'sshd did not come back after the restart. See the sshd events above.' 'restart' }
function Show-HostKey {
    Write-Step 'Host key'
    if ($script:Pending) { Say 'sshd makes it on its first start; run the script again afterwards to see it.'; $script:R.HostKey = 'not made yet'; return }
    $pub = Join-Path $script:SshDir 'ssh_host_ed25519_key.pub'
    if (-not (Test-Path -LiteralPath $pub)) { Add-Warning 'There is no ED25519 host key (ssh_host_ed25519_key.pub) to show.'; $script:R.HostKey = 'none'; return }
    $rec = $null
    foreach ($l in @(Split-Lines (Read-TextFile $pub).Text)) { $rec = ConvertTo-KeyRecord $l; if ($rec) { break } }
    if (-not $rec) { Add-Warning 'ssh_host_ed25519_key.pub cannot be read as a public key.'; $script:R.HostKey = 'unreadable'; return }
    $shown = ''
    if ($script:KeygenExe) {
        $r = Invoke-Native $script:KeygenExe @('-lf', $pub)
        if ($r.ExitCode -eq 0) { $shown = [string](@($r.Output | Where-Object { $_ }) | Select-Object -First 1) } }
    if ($shown -and -not $shown.Contains($rec.Fingerprint)) { Add-Warning ('ssh-keygen -lf shows ' + $shown + ', which differs from ' + $rec.Fingerprint + ' worked out here.') }
    Say ('ED25519 host key fingerprint: ' + $rec.Fingerprint) 'OK'
    if ($shown) { Say ('ssh-keygen -lf shows: ' + $shown.Trim()) }
    Say 'The first time the admin machine connects, ssh shows a fingerprint and asks whether to trust it. Answer yes only when it is the one above (Getting Started, section 4.6).'
    $script:R.HostKey = $rec.Fingerprint
    $script:R.HostPublicKey = $rec.Type + ' ' + $rec.Blob }
function Show-Summary {
    Write-Out ''
    Write-Out (' SUMMARY - ' + $env:COMPUTERNAME + ' ') $script:ui.Section
    Write-Out ('-' * ($script:UiWidth - $script:Prefix.Length)) $script:ui.Rule
    $keys = [string]$script:R.KeysInFile + ' valid in the file'
    if ([string]$script:R.KeysAdded -match '^would') { $keys = [string]$script:R.KeysInFile + ' valid in the file after the changes; ' + $script:R.KeysAdded }
    elseif ($script:R.KeysAdded) { $keys += '; ' + $script:R.KeysAdded + ' added now' }
    Write-Row 'OpenSSH Server' $script:R.OpenSSH
    Write-Row 'sshd service' $script:R.Service
    Write-Row 'Host keys' $script:R.HostKeys
    Write-Row 'Authorised keys' $keys
    Write-Row 'Key file access' $script:R.KeyFileAccess
    Write-Row 'Firewall' $script:R.Firewall
    Write-Row 'Password sign-in' $script:R.PasswordSignIn
    Write-Row 'Default shell' $script:R.DefaultShell
    Write-Row 'Banner' $script:R.Banner
    Write-Row 'Login alert' $script:R.LoginAlert
    Write-Row 'sshd restarted' $script:R.Restarted
    Write-Row 'Host key (ED25519)' $script:R.HostKey
    foreach ($w in $script:Warnings) { Write-Row 'Warning' $w $script:ui.Caution }
    foreach ($p in $script:Problems) { Write-Row 'Problem' $p $script:ui.Warn }
    $c = $script:ui.Ok; if ($script:R.Result -eq 'FAILED') { $c = $script:ui.Warn }
    Write-Row 'Result' $script:R.Result $c
    if ($script:R.Result -eq 'SUCCESS' -and $script:R.HostKey -match '^SHA256:') {
        $fqdn = ([string]$env:COMPUTERNAME).ToLower()
        if ($script:Cs -and $script:Cs.PartOfDomain) { $fqdn = ($fqdn + '.' + $script:Cs.Domain).ToLower() }
        Write-Out ''
        Write-Out '  Next, from the admin machine (check the fingerprint it shows):' $script:ui.Text
        Write-Out ('    ssh administrator@' + $fqdn + ' hostname') $script:ui.Cmd }
    Write-Out '' }

# ====================================================================== main
# Where this run comes from. An SSH session (also PowerShell remoting over SSH) names the client
# address, which must stay inside -AllowFrom.
$script:SshClient = ''
if ($env:SSH_CONNECTION) { $script:SshClient = @($env:SSH_CONNECTION -split ' ')[0] } elseif ($env:SSH_CLIENT) { $script:SshClient = @($env:SSH_CLIENT -split ' ')[0] }
if ($PSSenderInfo) { $script:Session = 'remote'; $script:Prefix = '[' + $env:COMPUTERNAME + '] ' }
elseif ($script:SshClient) { $script:Session = 'ssh' }
Initialize-UiStyle
Show-LaunchNotice
if ($Help) {
    Show-Help
    $extra = @($script:BoundKeys | Where-Object { $_ -ne 'Help' })
    if ($extra.Count) { Say ('[ignored] -Help only shows the help; nothing was done with -' + ($extra -join ', -') + '.') 'WARN' }
    return
}

$script:OnWindows = ($env:OS -eq 'Windows_NT')
if ($script:OnWindows -and $env:ProgramData) {
    $script:SshDir     = Join-Path $env:ProgramData 'ssh'
    $script:KeysFile   = Join-Path $script:SshDir 'administrators_authorized_keys'
    $script:ConfigFile = Join-Path $script:SshDir 'sshd_config'
    $script:BannerFile = Join-Path $script:SshDir 'banner.txt'
    $script:Pwsh7Path  = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    try { $script:IsAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { }
}

# ---- logs: a path given is checked now; the default folder is made only when it is written to
try {
    if ($AuditLog) { $script:AuditPath = Resolve-LogPath -Value $AuditLog -DefaultName 'Install-OpenSSHServer-audit.log' }
    elseif ($script:SshDir) { $script:AuditPath = Join-Path (Join-Path $script:SshDir 'logs') 'Install-OpenSSHServer-audit.log'; $script:AuditDefault = $true }
    if ($ErrorLog) { $script:ErrorPath = Resolve-LogPath -Value $ErrorLog -DefaultName 'Install-OpenSSHServer-errors.log' }
    elseif ($script:SshDir) { $script:ErrorPath = Join-Path (Join-Path $script:SshDir 'logs') 'Install-OpenSSHServer-errors.log'; $script:ErrorDefault = $true }
} catch {
    Say ('The log path cannot be used: ' + $_.Exception.Message + ' Nothing was changed.') 'ERROR'
    exit 1
}

# ---- the input, checked before anything is looked at or changed
$shellNames = @{ 'none' = 'None'; 'windowspowershell' = 'WindowsPowerShell'; 'powershell7' = 'PowerShell7' }
$sk = ([string]$DefaultShell).Trim().ToLowerInvariant()
if (-not $shellNames.ContainsKey($sk)) { Stop-Run ('-DefaultShell ' + $DefaultShell + ': use None (leave it as it is), WindowsPowerShell or PowerShell7. Nothing was changed.') 'args' }
$script:Shell = $shellNames[$sk]
$ki = Get-InputKeys
$ni = Get-InputNetworks
$bad = @(@($ki.Errors) + @($ni.Errors) | Where-Object { $_ })
if ($bad.Count) {
    foreach ($b in $bad) { Add-Problem $b 'args' }
    Say 'Nothing was changed.' 'ERROR'
    Complete-Run -Stage 'args'
}
$script:InputKeys = @($ki.Keys)
$script:Specs = @($ni.Specs)

# ---- switches that will not do what they look like, reported before any work
foreach ($s in $script:Specs) { if ($s.Prefix -eq 0) { Say ('[note] -AllowFrom ' + $s.Text + ' allows every address of its kind, so it limits nothing.') 'WARN' } }
if ($script:Shell -eq 'PowerShell7') { Say ('[note] ' + $script:Pwsh7Note) 'WARN' }
if ($KeepPasswordSignIn -and $script:InputKeys.Count -eq 0 -and -not $script:Specs.Count -and $script:Shell -eq 'None' -and -not $Banner -and -not $LoginAlert) {
    Say '[note] -KeepPasswordSignIn with nothing else to do: the run checks the service, the host keys and the key file, and changes only what is wrong there.' 'WARN' }

# ---- where this runs
if (-not $script:OnWindows) { Stop-Run 'This script runs on the Windows server that is to accept SSH connections, in elevated Windows PowerShell 5.1. From a Windows admin machine, use Invoke-Command (see -Help).' 'precheck' }
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { Stop-Run 'This is 32-bit PowerShell on 64-bit Windows, which does not see the OpenSSH folder. Run it in 64-bit Windows PowerShell.' 'precheck' }
if (-not $script:IsAdmin) { Stop-Run 'This must run elevated (Run as Administrator), or through Invoke-Command with an administrator account. Nothing was changed.' 'precheck' }
if ($script:SshClient -and $script:Specs.Count -and -not (Test-InNetworks $script:SshClient $script:Specs)) {
    Stop-Run ('This run is inside an SSH session from ' + $script:SshClient + ', which is outside -AllowFrom (' + ((@($script:Specs) | ForEach-Object { $_.Text }) -join ', ') + '): the next sign-in from there would be refused. Add that address or its network to -AllowFrom, or run the script from the console or over WinRM. Nothing was changed.') 'precheck' }
try { $script:Cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop } catch { $script:Cs = $null }

# ---- what is there now (read only)
$script:Svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
$script:Cap = $null
$script:SshdExe = $null
$script:KeygenExe = $null
if ($script:Svc) {
    $script:SshdExe = Find-OpenSshTool 'sshd.exe'
    $script:KeygenExe = Find-OpenSshTool 'ssh-keygen.exe'
    foreach ($n in 'Source','LimitAccess') { if ($script:BoundKeys -contains $n) { Say ('[ignored] -' + $n + ': OpenSSH Server is already installed.') 'WARN' } }
} else {
    Say 'There is no sshd service. Looking for the OpenSSH Server capability (this can take a moment).'
    try { $script:Cap = @(Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction Stop)[0] }
    catch { Stop-Run ('The Windows capabilities cannot be read (Get-WindowsCapability): ' + $_.Exception.Message + ' Nothing was changed.') 'precheck' }
    if (-not $script:Cap) { Stop-Run 'OpenSSH Server is not offered as a Windows capability on this Windows build (Windows Server 2016 and older, Windows 10 before 1809). Install Win32-OpenSSH first, then run this script again to configure it. Nothing was changed.' 'precheck' }
    if ("$($script:Cap.State)" -eq 'Installed') { Stop-Run 'OpenSSH Server is installed as a Windows capability, but there is no sshd service. Restart the server and run this script again; if that does not help, remove the capability (Remove-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0) and run this script again. Nothing was changed.' 'precheck' }
    if ($Source -and -not (Test-Path -LiteralPath $Source)) { Stop-Run ('-Source ' + $Source + ' was not found on ' + $env:COMPUTERNAME + '. Nothing was changed.') 'precheck' }
    if ($LimitAccess -and -not $Source) { Say '[note] -LimitAccess without -Source: Windows Update is not used, so the install needs the Features on Demand source set by Group Policy.' 'WARN' }
}
if ($script:Shell -eq 'PowerShell7' -and -not (Test-Path -LiteralPath $script:Pwsh7Path)) { Stop-Run ('-DefaultShell PowerShell7: ' + $script:Pwsh7Path + ' is not there. Install PowerShell 7 first, or use WindowsPowerShell. Nothing was changed.') 'precheck' }

# ---- the work, in order
$stage = 'install'
try {
    Install-SshServer
    $stage = 'hostkeys'; Test-HostKeys
    $stage = 'service';  Start-SshService
    $stage = 'keys';     Add-AdminKeys
    $stage = 'firewall'; Set-SshFirewallScope
    $stage = 'config';   Update-SshdConfig
    $stage = 'shell';    Set-SshDefaultShell
    $stage = 'alert';    Register-LoginAlert
    $stage = 'restart';  Restart-SshServer
    $stage = 'hostkey';  Show-HostKey
    $stage = 'done'
} catch {
    Add-Problem ('Unexpected error at line ' + $_.InvocationInfo.ScriptLineNumber + ': ' + $_.Exception.Message) $stage
}
Complete-Run -Stage $stage -Summary
