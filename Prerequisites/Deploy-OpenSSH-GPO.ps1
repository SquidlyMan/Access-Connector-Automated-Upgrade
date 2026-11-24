<#
.SYNOPSIS
    Deploys OpenSSH Server with key-only sign-in to every computer in one
    organizational unit, through a Group Policy computer startup script.
    Run it once from a domain-joined Windows machine; each computer in the
    OU installs it at its next restart.

    Run with -Help for usage. Windows PowerShell 5.1.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$TargetOU,
    [string]$GpoName = 'Deploy OpenSSH Server (Access Connectors)',
    [string[]]$PublicKey,
    [string]$PublicKeyFile,
    [string[]]$AllowFrom,
    [switch]$AllowFromAnyAddress,
    [hashtable]$PayloadParameters,
    [string]$PayloadPath,
    [string]$Server,
    [switch]$AllowDomainRoot,
    [switch]$AllowDomainControllers,
    [switch]$AllowOtherLinks,
    [switch]$WhatIf,
    [switch]$Yes,
    [string]$AuditLog,
    [string]$ErrorLog,
    [switch]$Help
)

# ---------------------------------------------------------------------------
# Why it is built this way. Lessons from the earlier deployer, paid for in a
# real rollout:
#  * A computer GPO whose COMPUTER version is 0 is shown by members as
#    "Not Applied (Empty)" and SILENTLY skipped (gpresult: "Filtering: Not
#    Applied (Empty)"). In versionNumber the COMPUTER version is the LOW 16
#    bits and the USER version the HIGH 16 bits. The first deployer relied on
#    Set-GPRegistryValue alone to raise it; when an earlier step threw, the
#    GPO was left created and linked but empty, with no warning. This one
#    raises the computer version itself, checks it, and links the GPO only
#    after that. A GPO it made is deleted again if any step fails.
#  * psscripts.ini must be Unicode and must hold BOTH [ScriptsConfig]
#    (StartExecutePSFirst) and [Startup]: exactly what GPMC writes. GPMC also
#    registers the Scripts client-side extension on the GPO object
#    (gPCMachineExtensionNames) behind the scenes; this script does the same.
#    Both are always rewritten, so a rerun repairs a half-made GPO.
#  * Get-GPO -Name can throw (not just return nothing) when the GPO is
#    absent, and New-GPO can report "already exists" while it races itself
#    across domain controllers. Both are handled.
#  * Every file goes to the GPO's own folder in SYSVOL, through the same
#    domain controller as the directory changes, so the files and the version
#    number reach the other domain controllers by their own replication, and
#    the GPO can be backed up, restored or deleted as one piece.
# ---------------------------------------------------------------------------

$script:Version      = '1.0.0'
$script:UiWidth      = 78
$script:Name         = 'Deploy-OpenSSH-GPO.ps1'
$script:Started      = Get-Date
$script:AuditPath    = $null
$script:ErrorPath    = $null
$script:AuditWritten = $false

# The three files this script keeps in the GPO's Machine\Scripts\Startup folder.
$script:PayloadName  = 'Install-OpenSSHServer.ps1'
$script:LauncherName = 'OpenSSHServer-Startup.ps1'
$script:SettingsName = 'OpenSSHServer-Settings.json'
# The Scripts client-side extension and its computer tool extension, as GPMC registers them.
$script:CseScripts = '{42B5FAAE-6536-11D2-AE5A-0000F87571E3}'
$script:CseTool    = '{40B6664F-4972-11D1-A7CA-0000F87571E3}'
# Written into the comment of every GPO this script makes. A GPO of the same name
# without it was made by someone else and is never touched.
$script:Tag = 'Made by Deploy-OpenSSH-GPO.ps1'
# The keys and -AllowFrom are checked with the payload's own functions, so that what is accepted
# here is accepted on every computer, where a refusal would repeat at every startup, and the two
# cannot drift apart. Get-PayloadChecks takes these function definitions, and the two constants
# they read ($script:KeyTypes, $script:PrivateKeyText), from the payload's syntax tree; nothing
# else of the payload is run here, so a payload whose functions call another command or use
# another variable of the payload is refused.
$script:CheckFunctions = @('Read-SshField', 'Get-OptionsEnd', 'Test-KeyOptions', 'ConvertTo-KeyRecord',
    'Split-JoinedKeys', 'Get-KeyLineProblem', 'Split-Lines', 'Read-TextFile', 'Get-InputKeys',
    'Get-MaskedBytes', 'ConvertTo-NetSpec', 'Test-ShowableValue', 'Get-InputNetworks')
# What they may call besides each other and Add-Warning (Test-PayloadKeys provides it), by name.
$script:CheckCmdlets = @('New-Object', 'Where-Object', 'ForEach-Object', 'Test-Path', 'Resolve-Path')
# Text that only a private key holds. The payload's own pattern replaces this one once it is read;
# until then, and when it cannot be read, this one keeps a private key from being used or shown.
$script:PrivateKeyText = 'PRIVATE KEY|PuTTY-User-Key-File|Private-Lines:'
$script:KeyTypes = @()
$script:AuditContext = ''

# The startup wrapper that Group Policy runs on each computer. It is the same for every
# GPO and every run; only the settings file beside it changes.
$script:LauncherText = @'
# OpenSSHServer-Startup.ps1 - written by Deploy-OpenSSH-GPO.ps1 @VERSION@.
# Do not edit it here: run Deploy-OpenSSH-GPO.ps1 again instead. A rerun
# rewrites the files in this folder.
#
# Group Policy runs this as a computer startup script, as SYSTEM, in Windows
# PowerShell. It runs Install-OpenSSHServer.ps1 from this folder with the
# parameters in OpenSSHServer-Settings.json from this folder, and ends with
# its exit code. The values reach it as real arrays and switches, so nothing
# depends on how a startup script command line would be quoted.
#
# It fails closed. Without its settings the payload would install sshd with no
# key and no address limit, so it is not run at all when the settings cannot
# be read or name no public key. Exit codes:
#   0, 1  the payload's own: done, or failed (its logs are in
#         C:\ProgramData\ssh\logs on this computer); 1 also when the payload
#         could not be started or did not finish
#   2     the payload or the settings are not in this folder yet: SYSVOL
#         replication is still bringing them to the domain controller this
#         computer uses, and a later restart runs it
#   3     the settings cannot be read, or name no public key: nothing was run
$ErrorActionPreference = 'Stop'
$here     = Split-Path -Parent $MyInvocation.MyCommand.Path
$payload  = Join-Path $here 'Install-OpenSSHServer.ps1'
$settings = Join-Path $here 'OpenSSHServer-Settings.json'
if (-not (Test-Path -LiteralPath $payload) -or -not (Test-Path -LiteralPath $settings)) { exit 2 }
$p = @{}
try {
    $json = (Get-Content -LiteralPath $settings -Raw) | ConvertFrom-Json
    foreach ($prop in $json.Parameters.PSObject.Properties) {
        if ($null -ne $prop.Value) { $p[$prop.Name] = $prop.Value }
    }
} catch { exit 3 }
$keys = @($p['PublicKey'] | Where-Object { $_ })
if (-not $keys.Count) { exit 3 }
try { & $payload @p } catch { exit 1 }
# The payload always ends with exit 0 or 1; without an exit code it did not finish.
if ($null -eq $LASTEXITCODE) { exit 1 }
exit $LASTEXITCODE
'@

# ---------------------------------------------------------------- UI helpers
function Initialize-UiStyle {
    # Colour only on an interactive console; plain text when redirected or NO_COLOR is set.
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
            Warn="$e[1;91m"; Notice="$e[1;93m"; Ok="$e[92m"; Info="$e[96m"
            # Notice = bold yellow (the UNSUPPORTED notice); Caution = yellow (warnings);
            # Warn = bold red (alerts and errors); Dim = gray (captions of examples).
            Caution="$e[93m"; Dim="$e[38;5;244m"
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
function Write-UiCaption { param([string]$T) Write-Host ($script:ui.Dim + '  ' + $T + $script:ui.Reset) }
function Write-UiCmd { param([string]$T) Write-Host ($script:ui.Cmd + '  ' + $T + $script:ui.Reset) }
function Write-UiParam { param([string]$Flag, [string]$Desc)
    $col = 26
    $lines = @(Get-WrappedLines -Text $Desc -Width ($script:UiWidth - $col))
    $pad = "  $Flag".PadRight($col); $first = $true
    foreach ($l in $lines) {
        if ($first) { Write-Host ($script:ui.Flag + $pad + $script:ui.Reset + $script:ui.Text + $l + $script:ui.Reset); $first = $false }
        else { Write-Host ($script:ui.Text + (' ' * $col) + $l + $script:ui.Reset) }
    }
}
function Write-UiField { param([string]$Label, [string]$Value, [string]$Style)
    # A run-time line: the label, then the value wrapped under itself.
    $col = 20
    if (-not $Style) { $Style = $script:ui.Text }
    $lines = @(Get-WrappedLines -Text $Value -Width ($script:UiWidth - $col))
    if (-not $lines.Count) { $lines = @('') }
    $first = $true
    foreach ($l in $lines) {
        if ($first) { Write-Host ($script:ui.Info + ("  $Label").PadRight($col) + $script:ui.Reset + $Style + $l + $script:ui.Reset); $first = $false }
        else { Write-Host ((' ' * $col) + $Style + $l + $script:ui.Reset) }
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
    Write-UiWarn 'Use of the Omnissa products is governed by your agreement with Omnissa; customers assume all responsibility for automated changes to them.'
}
function Show-Help {
    Write-Host ($script:ui.Banner + (" $($script:Name)  v$($script:Version) ").PadRight($script:UiWidth) + $script:ui.Reset)
    Show-Disclaimer
    Write-UiSection 'SYNOPSIS'
    Write-UiText 'Makes one Group Policy object (GPO) that installs OpenSSH Server with key-only sign-in, and links it to one organizational unit (OU). Every computer in that OU, and in the OUs under it, runs it as a computer startup script: it happens at the computer''s next restart.'
    Write-UiText 'Run it once from a domain-joined Windows machine. Run it again to change the keys or the settings: it updates the GPO it made before, and the plan lists what changes.'
    Write-UiText 'On a computer that already ran it, the payload adds keys and turns settings on; it never takes back what an earlier run did there. A key taken out of the GPO stays trusted on those computers until it is removed there by hand (see UNDOING IT).'
    Write-UiSection 'DESCRIPTION'
    Write-UiText 'The work on each computer is done by the payload, Install-OpenSSHServer.ps1, kept beside this script. It installs the in-box OpenSSH Server, adds the public keys given here to the keys trusted for administrators, turns password sign-in off, limits the firewall rule to -AllowFrom and starts sshd. Its own -Help says exactly what it changes.'
    Write-UiText 'This script, working on one domain controller (-Server; by default the PDC emulator, the one the Group Policy Management Console uses): creates the GPO, or reuses the one it made before; writes the payload, a small startup wrapper and a settings file holding the keys and addresses into the GPO''s own folder in SYSVOL; registers the wrapper as a computer startup PowerShell script the way the Group Policy Management Console does (psscripts.ini and the Scripts client-side extension); turns on Run Windows PowerShell scripts first; raises the GPO''s computer version; checks all of it; and only then links the GPO to -TargetOU. Replication takes it to the other domain controllers.'
    Write-UiText 'The wrapper hands the settings to the payload as real arrays and switches, so nothing depends on how a startup script''s command line is quoted.'
    Write-UiSection 'SAFETY'
    Write-UiText 'Nothing is changed before the plan is shown. -WhatIf shows the plan and stops. Otherwise the plan ends with a prompt, and only YES, typed in capitals, goes on. -Yes skips the prompt for an unattended run; a run with no terminal to type in is refused without it.'
    Write-UiText 'A computer GPO whose computer version is 0 is shown by members as Not Applied (Empty) and skipped, without a warning. So the GPO is linked last, after its computer version is above 0 and its files and script registration are checked. If a step fails, a GPO made by the same run is deleted again and a link made by the same run is removed: nothing is left linked but empty. A GPO that existed before the run is left as it is; fix the cause and run again, since a rerun rewrites every file and setting.'
    Write-UiText 'Each file is written whole under a temporary name in the GPO''s folder and then renamed over the old one, so a computer that restarts during a rerun reads the old file or the new one, never part of one.'
    Write-UiText 'Refused before any change: the domain root as -TargetOU unless -AllowDomainRoot is given (it would reach every computer in the domain); an OU with a domain controller in it or under it, the domain root included, unless -AllowDomainControllers is given; a container such as CN=Computers (Group Policy cannot be linked to one); a GPO of the same name that this script did not make; a GPO that is linked to another OU as well, unless -AllowOtherLinks is given (this run''s settings would reach that OU too); a run without -AllowFrom, unless -AllowFromAnyAddress is given; an -AllowFrom that names no address, only commas, semicolons or spaces (as empty variables give), with or without -AllowFromAnyAddress; a private key; a key, an -AllowFrom value or a -DefaultShell that the payload would refuse; and a payload that does not parse in Windows PowerShell 5.1.'
    Write-UiText 'The keys and -AllowFrom are checked by the payload''s own functions (ConvertTo-KeyRecord, Get-InputKeys, Get-InputNetworks and those they call), taken from the same bytes of the payload file that this run copies into the GPO. Only those function definitions, and the two constants they read, are taken from its text and run here; the rest of the payload is not run. A payload is refused when it lacks those functions, or when they call any other command or use any other variable of the payload, since that is not taken here. So a key or a network is accepted here exactly when the payload accepts it on the computers, and the two cannot drift apart. The settings are then read back as each computer reads them and checked by those functions once more.'
    Write-UiText 'Those functions run on this machine, as the whole payload runs as SYSTEM on every computer in the OU: give only a payload you trust. The plan shows its SHA256.'
    Write-UiText 'What only a computer can tell, such as whether a -Source folder is there, or PowerShell 7 for -DefaultShell PowerShell7, is checked on each computer, and a refusal there repeats at every startup. Run the payload by hand on one computer first, with the same settings.'
    Write-UiSection 'WHEN IT RUNS'
    Write-UiText 'A computer startup script runs only while the computer starts: gpupdate /force alone does not run it. Each computer in the OU runs it at its next restart, and again at every later startup, so a computer that was off, or failed once, catches up by itself.'
    Write-UiText 'Windows Server applies computer policy before the sign-in screen, so one restart is enough there. A Windows 10 or 11 computer that uses fast logon can need two.'
    Write-UiText 'The startup wrapper runs the payload only with its settings. When the settings file cannot be read, or names no key, it runs nothing (exit code 3). While SYSVOL replication has not yet brought the files to the domain controller a computer uses, that computer runs nothing (exit code 2) and catches up at a later restart.'
    Write-UiSection 'PARAMETERS'
    Write-UiParam '-TargetOU <dn>' 'Required. Distinguished name of the OU to link the GPO to ($ou in the examples). Every computer in it, and in the OUs under it, runs the script. Refused: the domain root unless -AllowDomainRoot is given, and an OU that holds domain controllers unless -AllowDomainControllers is given.'
    Write-UiParam '-GpoName <name>' 'Name of the GPO. Default: Deploy OpenSSH Server (Access Connectors). Run again with the same name to update it. Give each OU its own name: one GPO linked to two OUs gives both the same keys and -AllowFrom.'
    Write-UiParam '-PublicKey <keys>' 'One or more OpenSSH public keys, each the one line of a .pub file: ssh-ed25519, ecdsa-sha2-nistp256/384/521 or ssh-rsa (1024 bits or more), optionally with one list of authorized_keys options in front, as sshd reads them (from="10.0.0.0/24",no-pty). They are added to the keys trusted for administrators on every computer. Each is checked as the payload checks it there: a key it would refuse stops the run here.'
    Write-UiParam '-PublicKeyFile <path>' 'A file of public keys on this machine, one per line: a .pub file or an authorized_keys file. Blank lines and lines starting with # are skipped; every other line is checked as one -PublicKey value. Used together with -PublicKey when both are given. A private key is refused and never printed.'
    Write-UiParam '-AllowFrom <list>' 'Required, unless -AllowFromAnyAddress is given. Addresses or networks in CIDR form (10.0.0.5, 10.0.0.0/24, fd00::/64) that may reach TCP 22 on the computers, separated by commas. Checked as the payload checks it; one that names no address at all, such as -AllowFrom "$a,$b" with both variables empty, is refused. The payload limits the OpenSSH firewall rules to them on every computer, at each startup. Include the network of the machine that runs the Access Connector tool, or it is shut out too.'
    Write-UiParam '-AllowFromAnyAddress' 'Leave -AllowFrom out on purpose. A computer where the GPO installs OpenSSH Server then accepts TCP 22 from ANY address (the install''s own firewall rule), and with KeepPasswordSignIn, password sign-in from any address too.'
    Write-UiParam '-PayloadParameters @{}' 'Other settings for the payload, as a hashtable of its own parameter names and values, such as Source or KeepPasswordSignIn (see the examples; its -Help lists them all). Each name and value is checked against the payload''s parameters before anything is changed.'
    Write-UiParam '-PayloadPath <path>' 'The payload. Default: Install-OpenSSHServer.ps1 beside this script. It must parse in Windows PowerShell 5.1, and its own checks of the keys and -AllowFrom are run here (see SAFETY). It is copied into the GPO; a rerun copies it again.'
    Write-UiParam '-Server <dc>' 'Domain controller to make every change on. Default: the PDC emulator of this computer''s domain. The domain used is the one it serves.'
    Write-UiParam '-AllowDomainRoot' 'Allow the domain root as -TargetOU. The domain controllers are under it, so -AllowDomainControllers is needed as well.'
    Write-UiParam '-AllowDomainControllers' 'Allow a -TargetOU with domain controllers in it or under it. They then get sshd, with key sign-in for the domain''s Administrators group.'
    Write-UiParam '-AllowOtherLinks' 'Allow a GPO that is linked to another OU as well, as when a second -TargetOU is given with the same -GpoName. This run''s keys, -AllowFrom and settings then reach the computers there too, at their next restart. Better: one -GpoName per OU.'
    Write-UiParam '-WhatIf' 'Show the plan, change nothing.'
    Write-UiParam '-Yes' 'Make the changes without the Type YES prompt, for an unattended run. A run with no terminal to type in is refused without it.'
    Write-UiParam '-AuditLog <path>' 'Append-only audit log. File or folder.'
    Write-UiParam '-ErrorLog <path>' 'Error log. File or folder.'
    Write-UiParam '-Help' 'Show this help.'
    Write-UiSection 'EXAMPLES'
    Write-UiCaption '# Show the plan only: what would be made and linked (changes nothing)'
    Write-UiCmd '$ou = ''OU=Access Connectors,DC=example,DC=local'''
    Write-UiCmd '.\Deploy-OpenSSH-GPO.ps1 -TargetOU $ou -PublicKeyFile .\admin.pub `'
    Write-UiCmd '    -AllowFrom 10.0.0.0/24 -WhatIf'
    Write-Host ''
    Write-UiCaption '# Make and link the GPO, with audit and error logs (asks for YES first)'
    Write-UiCmd '.\Deploy-OpenSSH-GPO.ps1 -TargetOU $ou -PublicKeyFile .\admin.pub `'
    Write-UiCmd '    -AllowFrom 10.0.0.0/24,10.0.1.0/24 `'
    Write-UiCmd '    -AuditLog C:\Logs\ -ErrorLog C:\Logs\'
    Write-Host ''
    Write-UiCaption '# Unattended, such as from a scheduled task: -Yes instead of the prompt'
    Write-UiCmd '.\Deploy-OpenSSH-GPO.ps1 -TargetOU $ou -PublicKeyFile .\admin.pub `'
    Write-UiCmd '    -AllowFrom 10.0.0.0/24 -Yes -AuditLog C:\Logs\ -ErrorLog C:\Logs\'
    Write-Host ''
    Write-UiCaption '# Two keys given inline: an admin key and a break-glass key'
    Write-UiCmd '$keys = ''ssh-ed25519 AAAA... admin@example'','
    Write-UiCmd '        ''ssh-ed25519 AAAA... breakglass@example'''
    Write-UiCmd '.\Deploy-OpenSSH-GPO.ps1 -TargetOU $ou -PublicKey $keys `'
    Write-UiCmd '    -AllowFrom 10.0.0.0/24'
    Write-Host ''
    Write-UiCaption '# Computers that update from WSUS: install from a Features on Demand share'
    Write-UiCmd '.\Deploy-OpenSSH-GPO.ps1 -TargetOU $ou -PublicKeyFile .\admin.pub `'
    Write-UiCmd '    -AllowFrom 10.0.0.0/24 `'
    Write-UiCmd '    -PayloadParameters @{ Source = ''\\fileserver.example.local\FoD'' }'
    Write-Host ''
    Write-UiCaption '# Staged: trust the keys, keep password sign-in (from -AllowFrom only)'
    Write-UiCaption '# until the keys are proven, then run again without KeepPasswordSignIn'
    Write-UiCmd '.\Deploy-OpenSSH-GPO.ps1 -TargetOU $ou -PublicKeyFile .\admin.pub `'
    Write-UiCmd '    -AllowFrom 10.0.0.0/24 `'
    Write-UiCmd '    -PayloadParameters @{ KeepPasswordSignIn = $true }'
    Write-Host ''
    Write-UiCaption '# Change the keys later. Give every setting again: a rerun replaces the'
    Write-UiCaption '# GPO''s settings, and the plan lists what changes. A key taken out stays'
    Write-UiCaption '# trusted on the computers that already ran it: see UNDOING IT'
    Write-UiCmd '.\Deploy-OpenSSH-GPO.ps1 -TargetOU $ou -PublicKeyFile .\new-keys.pub `'
    Write-UiCmd '    -AllowFrom 10.0.0.0/24 -WhatIf'
    Write-Host ''
    Write-UiCaption '# A second OU: its own GPO, so each OU keeps its own keys and networks'
    Write-UiCmd '.\Deploy-OpenSSH-GPO.ps1 -TargetOU ''OU=Site B,DC=example,DC=local'' `'
    Write-UiCmd '    -GpoName ''Deploy OpenSSH Server (Site B)'' `'
    Write-UiCmd '    -PublicKeyFile .\admin.pub -AllowFrom 10.0.2.0/24'
    Write-Host ''
    Write-UiCaption '# On a computer in the OU, after its restart (elevated): did it apply?'
    Write-UiCmd 'gpresult /scope computer /r'
    Write-UiSection 'CONFIRMING IT ON A COMPUTER'
    Write-UiText 'After the computer has restarted, at an elevated prompt on it:'
    Write-UiCmd 'gpresult /scope computer /r'
    Write-UiText 'The GPO must be listed under Applied Group Policy Objects. Filtered out with Not Applied (Empty): its computer version is 0, so run this script again. Denied (Security): the GPO''s security filtering leaves the computer out. Not listed at all: the computer is not in -TargetOU, or has not read its policy since the GPO was made.'
    Write-UiCmd 'gpresult /scope computer /h C:\Temp\gpresult.html'
    Write-UiText 'The HTML report lists the startup script under Computer Details, Windows Settings, Scripts.'
    Write-UiCmd 'Get-Service sshd'
    Write-UiText 'Then, from the admin machine, sign in with the key:'
    Write-UiCmd 'ssh -i ~/.ssh/id_ed25519 -l ''EXAMPLE\admin'' connector1.example.local'
    Write-UiText 'The payload keeps its own audit and error logs on the computer, by default in C:\ProgramData\ssh\logs (see its -Help). The GPO applied but there is no log at all: the startup wrapper ran nothing, because its settings could not be read or its files had not replicated yet (see WHEN IT RUNS).'
    Write-UiSection 'UNDOING IT'
    Write-UiText 'Taking a key out: run this script again without it, so that the computers which run the GPO from then on do not get it. Then remove its line from C:\ProgramData\ssh\administrators_authorized_keys on each computer that already ran it: the payload adds keys and never removes one. The plan of that rerun lists the fingerprints of the keys taken out. The same holds for new authorized_keys options on a key that a computer already trusts: it keeps the old line.'
    Write-UiCaption '# On each computer that already ran it (elevated): take one key out'
    Write-UiCmd '$f = ''C:\ProgramData\ssh\administrators_authorized_keys'''
    Write-UiCmd '(Get-Content $f) | Where-Object { $_ -notlike ''*old-admin@example*'' } |'
    Write-UiCmd '    Set-Content $f -Encoding Ascii'
    Write-UiText 'Remove-GPLink stops computers that have not run it yet from getting it. Remove-GPO deletes the GPO with its files and links. Neither removes OpenSSH Server, or the keys, from a computer that already ran it: a startup script is not undone when its GPO goes. Install-OpenSSHServer.ps1 -Help says how to remove it from a computer.'
    Write-UiCmd 'Remove-GPLink -Name ''Deploy OpenSSH Server (Access Connectors)'' -Target $ou'
    Write-UiCmd 'Remove-GPO -Name ''Deploy OpenSSH Server (Access Connectors)'''
    Write-UiSection 'OUTPUT'
    Write-UiText 'The plan, each step as it is done, a check of the finished GPO and what to do next. Exit code 0 = done (or -WhatIf), 1 = failed, refused or not confirmed.'
    Write-UiSection 'LOGGING'
    Write-UiText 'Audit log (-AuditLog): one appended key=value line per run, on every exit path (a refusal and a run that was not confirmed included), with the GPO, its GUID, the OU, the SHA256 fingerprints of the keys (not the keys) and the outcome. Error log (-ErrorLog): the detail of each failure, with the line of this script where it stopped.'
    Write-UiText 'This script takes no passwords. A private key given by mistake is refused and is never printed or logged, also when it is given as -AllowFrom: then all of -AllowFrom is refused. Keys are shown by fingerprint and comment, a long comment cut short. An -AllowFrom value that is not an address or a network is shown only when it is short and looks like an address or a host name; otherwise only its place and length are, so a key given there by mistake is not printed either.'
    Write-UiSection 'REQUIREMENTS'
    Write-UiText 'Windows PowerShell 5.1 on a domain-joined Windows machine with the Group Policy Management tools and the Active Directory module for Windows PowerShell (RSAT; on Windows Server: Install-WindowsFeature GPMC, RSAT-AD-PowerShell). The account must be allowed to create GPOs (Domain Admins, or Group Policy Creator Owners), to link GPOs on the OU, and to write to SYSVOL.'
    Write-UiText 'Computers in the OU: Windows Server 2019 or Windows 10 1809, or later (the first with OpenSSH Server built in), and a way to download it: Windows Update, or a Features on Demand share that the computer accounts can read, given to the payload as its Source. Computers that take updates from WSUS cannot download it unless the policy Specify settings for optional component installation and component repair lets them use Windows Update.'
    Write-UiText 'If Windows refuses to run a downloaded copy of these scripts, unblock them first:'
    Write-UiCmd 'Unblock-File .\*.ps1'
    Write-UiSection 'ABOUT'
    Write-UiText "Version $($script:Version). Created 2026-11-23. MIT License; see the LICENSE file. It keeps the lessons of an earlier field-tested deployer: the psscripts.ini and Scripts extension registration that the Group Policy Management Console writes, Run Windows PowerShell scripts first, and a computer version that must be above 0."
    Write-UiSection 'DOCUMENTATION'
    Write-UiText 'Microsoft Learn: Get started with OpenSSH for Windows; Key-based authentication in OpenSSH for Windows; the GroupPolicy module reference; gpresult.'
    Write-Host ''
}

# ------------------------------------------------------------------- logs
function Resolve-LogPath { param([string]$Value, [string]$DefaultName)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $v = $Value.Trim()
    if ((Test-Path -LiteralPath $v -PathType Container) -or $v.EndsWith('\') -or $v.EndsWith('/')) { $v = Join-Path $v $DefaultName }
    $dir = Split-Path -Parent $v
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    return $v }
function Say { param([string]$Message, [string]$Level = 'INFO')
    $c = $script:ui.Text
    if ($Level -eq 'OK') { $c = $script:ui.Ok } elseif ($Level -eq 'WARN') { $c = $script:ui.Caution } elseif ($Level -eq 'ERROR') { $c = $script:ui.Warn }
    Write-Host ($c + ('[{0}] [{1,-5}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message) + $script:ui.Reset) }
function Write-ErrorEntry { param([string]$Message, [string]$Stage, [System.Management.Automation.ErrorRecord]$Record)
    # The screen gets what to do; the file also gets where it stopped, from the error record.
    Say $Message 'ERROR'
    if (-not $script:ErrorPath) { return }
    $stamp = (Get-Date).ToString('o')
    try {
        if (-not (Test-Path -LiteralPath $script:ErrorPath)) { Add-Content -LiteralPath $script:ErrorPath -Encoding utf8 -Value ("# $($script:Name) error log - created $stamp") }
        $st = ''; if ($Stage) { $st = " [$Stage]" }
        $lines = @("$stamp [ERROR]$st $Message")
        if ($Record -and $Record.InvocationInfo -and $Record.InvocationInfo.ScriptLineNumber) {
            $at = 'at line ' + $Record.InvocationInfo.ScriptLineNumber
            $sn = [string]$Record.InvocationInfo.ScriptName
            if ($sn -and $PSCommandPath -and $sn -ne $PSCommandPath) { $at += ' of ' + (Split-Path -Leaf $sn) }
            $lines += ("$stamp [ERROR]   " + $at + ': ' + (([string]$Record.InvocationInfo.Line).Trim() -replace '\s+', ' ')) }
        Add-Content -LiteralPath $script:ErrorPath -Encoding utf8 -Value $lines
    } catch { Write-Host ($script:ui.Warn + '  The error log could not be written: ' + $_.Exception.Message + $script:ui.Reset) } }
function Write-AuditEntry { param([string]$Outcome, [string]$Stage, [string]$Detail)
    if (-not $script:AuditPath -or $script:AuditWritten) { return }
    $f = [ordered]@{ time=(Get-Date).ToString('o'); user=[Environment]::UserName; host=[Environment]::MachineName
        script=$script:Name; version=$script:Version; outcome=$Outcome }
    if ($Stage) { $f['stage'] = $Stage }
    $f['durationSec'] = [math]::Round(((Get-Date) - $script:Started).TotalSeconds, 1)
    # What the run was for (GPO, OU, key fingerprints) is on every line, failures included.
    $d = (($script:AuditContext + ' ' + $Detail) -replace '\s+', ' ').Trim()
    if ($d) { $f['detail'] = $d }
    $line = ($f.GetEnumerator() | ForEach-Object { $v = [string]$_.Value
        if ($v -match '[\s"]') { '{0}="{1}"' -f $_.Key, ($v -replace '"', "'") } else { '{0}={1}' -f $_.Key, $v } }) -join ' '
    try {
        if (-not (Test-Path -LiteralPath $script:AuditPath)) { Add-Content -LiteralPath $script:AuditPath -Encoding utf8 -Value ("# $($script:Name) audit log - append only - created " + (Get-Date).ToString('o')) }
        Add-Content -LiteralPath $script:AuditPath -Value $line -Encoding utf8
    } catch { Write-Host ($script:ui.Warn + '  The audit log could not be written: ' + $_.Exception.Message + $script:ui.Reset) }
    $script:AuditWritten = $true }
function Stop-Run { param([string]$Message, [string]$Stage, [System.Management.Automation.ErrorRecord]$Record)
    Write-ErrorEntry $Message $Stage $Record
    Write-AuditEntry 'FAILED' $Stage $Message
    exit 1 }
function Read-Confirmation {
    # What was typed at the prompt, or $null when this run has no terminal to type in: input
    # redirected (a pipe), powershell -NonInteractive, or no interactive session at all (a
    # scheduled task that runs whether a user is signed in or not, whose console nobody sees).
    $redirected = $false
    try { $redirected = [Console]::IsInputRedirected } catch { }
    if ($redirected -and $Host.Name -eq 'ConsoleHost') { return $null }
    if (-not [Environment]::UserInteractive) { return $null }
    Write-Host ($script:ui.Warn + '  Type YES to continue: ' + $script:ui.Reset) -NoNewline
    $a = $null
    try { $a = Read-Host } catch { Write-Host ''; return $null }
    if ($null -eq $a) { return $null }
    return [string]$a }

# ------------------------------------------------------------ input checks
function Get-OutsideVariables { param($Function)
    # The variables a function taken from the payload uses that are not its own, as text for a
    # message (none: an empty list). Its own: its parameters, the variables it sets with = and its
    # foreach variables ([ref] needs a variable that exists already, so it makes none), and the
    # automatic variables whose value comes from the call itself ($_, $args, $Matches and the
    # like). Besides those it may use $PublicKey, $PublicKeyFile and $AllowFrom (the payload's
    # parameters, which Test-PayloadKeys and Test-PayloadNetworks set here), $env: variables, and
    # $script:KeyTypes and $script:PrivateKeyText, also unqualified, which main sets here from the
    # payload. Any other variable (another $script: or $global: one, one that the payload sets at
    # its top level, or one read through a drive such as variable: or function:) is the payload's
    # on each computer but this script's here, so the check would not give here what it gives
    # there.
    $auto = @('_', 'PSItem', 'null', 'true', 'false', 'args', 'input', 'Matches', 'PSBoundParameters', 'this', 'foreach', 'switch', '?')
    $given = @('PublicKey', 'PublicKeyFile', 'AllowFrom', 'KeyTypes', 'PrivateKeyText')
    $vars = @($Function.FindAll({ param($x) $x -is [System.Management.Automation.Language.VariableExpressionAst] }, $true))
    $own = @{}
    foreach ($v in $vars) {
        $p = $v.Parent; $x = $v
        while ($x.Parent -is [System.Management.Automation.Language.AttributedExpressionAst] -or $x.Parent -is [System.Management.Automation.Language.ArrayLiteralAst]) { $x = $x.Parent }
        $mine = $false
        if ($p -is [System.Management.Automation.Language.ParameterAst]) { $mine = $true }
        elseif ($p -is [System.Management.Automation.Language.ForEachStatementAst] -and $p.Variable -eq $v) { $mine = $true }
        # Only =: $x += 1 reads $x first.
        elseif ($x.Parent -is [System.Management.Automation.Language.AssignmentStatementAst] -and $x.Parent.Left -eq $x -and [string]$x.Parent.Operator -eq 'Equals') { $mine = $true }
        if ($mine) { $own[($v.VariablePath.UserPath -replace '^(?:local|private|variable):', '')] = $true }
    }
    $fn = [string]$Function.Name; $out = @()
    foreach ($v in $vars) {
        $vp = $v.VariablePath; $u = [string]$vp.UserPath
        if ($vp.IsDriveQualified) { if ([string]$vp.DriveName -ne 'env') { $out += ($fn + ' uses $' + $u) }; continue }
        if ($vp.IsScript) { if (@('script:KeyTypes', 'script:PrivateKeyText') -notcontains $u) { $out += ($fn + ' uses $' + $u) }; continue }
        if ($vp.IsGlobal) { $out += ($fn + ' uses $' + $u); continue }
        $bare = $u -replace '^(?:local|private|variable):', ''
        if ($own.ContainsKey($bare) -or $auto -contains $bare -or $given -contains $bare) { continue }
        $out += ($fn + ' reads $' + $u + ', which it does not set')
    }
    return @($out | Select-Object -Unique) }
function Get-PayloadChecks { param($Ast, [string]$Path)
    # The payload's own checks of -PublicKey and -AllowFrom, from its syntax tree: the functions
    # in $script:CheckFunctions, each defined once at its top level, and the two constants they
    # read, $script:KeyTypes and $script:PrivateKeyText, each set once in the whole payload, at
    # its top level, to a plain value (SafeGetValue takes literals only, and runs nothing). The
    # functions may call each other, Add-Warning and $script:CheckCmdlets, each by its name, and
    # no other command, and use no variable of the payload but those two (Get-OutsideVariables):
    # so a payload whose checks need more than this script provides is refused at once, not
    # halfway through a run, and not accepted with a value that would be the payload's on each
    # computer but missing here. Each whole definition is searched, so a command or variable in
    # the default value of an inline parameter, function F($x = ...), counts too. That is not a
    # sandbox (the payload is code that every computer runs as SYSTEM, and is trusted as such).
    # Returns Definitions (the text of each function, for main to define), KeyTypes,
    # PrivateKeyText and Problem: why they cannot be used, or ''.
    $r = New-Object psobject -Property @{ Definitions = @(); KeyTypes = $null; PrivateKeyText = $null; Problem = '' }
    $top = @($Ast.EndBlock.Statements)
    $known = @($script:CheckFunctions) + 'Add-Warning' + @($script:CheckCmdlets)
    $missing = @(); $calls = @(); $reads = @()
    foreach ($n in $script:CheckFunctions) {
        $f = @($top | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq $n })
        if ($f.Count -ne 1) { $missing += $n; continue }
        foreach ($c in @($f[0].FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] }, $true))) {
            $cn = $c.GetCommandName()
            if ($c.InvocationOperator -ne 'Unknown' -or -not $cn) { $calls += ($n + ' calls a command named only as it runs') }
            elseif ($known -notcontains $cn) { $calls += ($n + ' calls ' + $cn) } }
        $reads += @(Get-OutsideVariables $f[0])
        $r.Definitions += $f[0].Extent.Text
    }
    foreach ($n in @('KeyTypes', 'PrivateKeyText')) {
        # Every assignment that sets the script's variable: script: or global: anywhere, or any
        # assignment at the top level. A function's own $KeyTypes is another variable.
        $sets = @($Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.AssignmentStatementAst] -and $x.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and ($x.Left.VariablePath.UserPath -replace '^(?:script|global|local|private):', '') -eq $n -and ($x.Left.VariablePath.IsScript -or $x.Left.VariablePath.IsGlobal -or $top -contains $x) }, $true))
        $v = $null
        if ($sets.Count -eq 1 -and $top -contains $sets[0] -and $sets[0].Operator -eq 'Equals' -and $sets[0].Right -is [System.Management.Automation.Language.CommandExpressionAst]) {
            try { $v = $sets[0].Right.Expression.SafeGetValue() } catch { $v = $null } }
        $all = @($v); $ok = @($all | Where-Object { $_ -is [string] -and $_ -match '^[\x21-\x7E]+$' })
        if ($n -eq 'KeyTypes' -and $ok.Count -and $ok.Count -eq $all.Count) { $r.KeyTypes = [string[]]$ok; continue }
        if ($n -eq 'PrivateKeyText' -and $v -is [string] -and $v.Trim()) {
            $rx = $true; try { $null = [regex]::Match('', $v) } catch { $rx = $false }
            if ($rx) { $r.PrivateKeyText = $v; continue } }
        $missing += ('$script:' + $n)
    }
    $belongs = " Is $Path the Install-OpenSSHServer.ps1 that belongs with this script?"
    $fm = @($missing | Where-Object { -not $_.StartsWith('$') }); $vm = @($missing | Where-Object { $_.StartsWith('$') })
    $what = @()
    if ($fm.Count) { $what += ('the function(s) ' + ($fm -join ', ')) }
    if ($vm.Count) { $what += (($vm -join ' and ') + ' set once, at its top level, to a plain value') }
    if ($what.Count) { $r.Problem = 'The payload lacks ' + ($what -join ', and ') + '. This script checks the keys and -AllowFrom with the payload''s own functions, as every computer checks them, and takes only those from it.' + $belongs }
    elseif ($calls.Count -or $reads.Count) {
        $msg = 'The payload''s checks of the keys and -AllowFrom cannot be run here: ' + ((@($calls) + @($reads) | Select-Object -Unique) -join '; ') + '.'
        if ($calls.Count) { $msg += ' They may call each other, Add-Warning and ' + ($script:CheckCmdlets -join ', ') + ', and nothing else.' }
        if ($reads.Count) { $msg += ' Besides their own variables, $PublicKey, $PublicKeyFile, $AllowFrom and $env: variables, they may use only $script:KeyTypes and $script:PrivateKeyText: no other variable of the payload is set here, so they would not check here as they check on the computers.' }
        $r.Problem = $msg + $belongs }
    return $r }
function Test-PayloadKeys { param([string[]]$Values)
    # The payload's own Get-InputKeys, run on $Values as the payload runs it on its -PublicKey:
    # Keys (the keys it would trust, each with Type, Blob, Bits, Fingerprint, Comment, Options,
    # Line and Id), Errors (what it would refuse) and Warnings. It reads $PublicKey,
    # $PublicKeyFile and Add-Warning from the scope it is called from, so they are set here. The
    # payload never reads a key file of its own: the lines of -PublicKeyFile reach it as -PublicKey
    # values. Its messages never show key data.
    $ErrorActionPreference = 'Stop'
    $keyCheckNotes = New-Object System.Collections.Generic.List[string]
    function Add-Warning { param([string]$Message) $keyCheckNotes.Add($Message) }
    $PublicKey = [string[]]@($Values); $PublicKeyFile = @()
    $r = Get-InputKeys
    return New-Object psobject -Property @{ Keys = @($r.Keys); Errors = @($r.Errors); Warnings = $keyCheckNotes.ToArray() } }
function Test-PayloadNetworks { param([string[]]$Values)
    # The payload's own Get-InputNetworks, run on $Values as the payload runs it on its
    # -AllowFrom: Specs (Text, Prefix, Address, HostBits) and Errors. Its rule for what a message
    # shows: private-key text in any value refuses all of -AllowFrom and shows none of it, a public
    # key is named by its place, and a value that is not an address or a network is shown only
    # when it is short and looks like an address or a host name, else by its place and length.
    $ErrorActionPreference = 'Stop'
    $AllowFrom = [string[]]@($Values)
    $r = Get-InputNetworks
    return New-Object psobject -Property @{ Specs = @($r.Specs); Errors = @($r.Errors) } }
function Convert-KeyMessage { param([string]$Text, $Item)
    # The payload names the one value Test-PayloadKeys gave it "-PublicKey value 1"; here the
    # value is named where it came from. On a line of -PublicKeyFile, the lines the payload counts
    # are the keys that commas put on that one line.
    $m = [regex]::Match($Text, '^-PublicKey value 1(?!\d)(?<line>, line (?<n>\d+))?')
    if (-not $m.Success) { return $Text }
    $w = $Item.Where
    if ($m.Groups['line'].Success) { if ($Item.File) { $w += ', key ' + $m.Groups['n'].Value } else { $w += ', line ' + $m.Groups['n'].Value } }
    return ($w + $Text.Substring($m.Length)) }
function Format-KeyShort { param($Key)
    # A key as the plan shows it: type, fingerprint, size of an RSA key and comment, never the key
    # data. As in the payload, a long comment is cut short, so key data that ran into one is not
    # shown either; a character that is not printable ASCII is shown as ?.
    $s = $Key.Type + ' ' + $Key.Fingerprint
    if ($Key.Type -eq 'ssh-rsa') { $s += ' (' + $Key.Bits + ' bits)' }
    $c = [regex]::Replace([string]$Key.Comment, '[^\x20-\x7E]', '?')
    if ($c.Length -gt 40) { $c = $c.Substring(0, 37) + '...' }
    if ($c) { $s += ' ' + $c }
    return $s }
function Get-Sha256 { param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ,$sha.ComputeHash($Bytes) } finally { $sha.Dispose() } }
function Get-Sha256Hex { param([byte[]]$Bytes) return (([BitConverter]::ToString((Get-Sha256 $Bytes))) -replace '-', '') }
function Get-PayloadInfo { param([string]$Path)
    # What this script needs to know about the payload: does it parse, is it plain ASCII,
    # its checksum, its parameters (name, declared type, mandatory or not), and its syntax tree.
    # The file is read once. The syntax tree, and so the check functions run here, comes from the
    # same bytes that are hashed, shown in the plan and copied into the GPO, also when the file
    # is saved again during the run.
    $info = New-Object psobject -Property @{ Errors = @(); Params = @{}; Mandatory = @(); Bytes = $null; Sha256 = ''; NonAscii = $false; HasBom = $false; Ast = $null }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $info.Bytes = $bytes
    $info.HasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    foreach ($b in $bytes) { if ($b -gt 127) { $info.NonAscii = $true; break } }
    $info.Sha256 = Get-Sha256Hex $bytes
    # Decoded as PowerShell decodes a script file it parses: by its byte-order mark, else in the
    # default encoding ([Text.Encoding]::Default). The bytes of an ASCII payload read the same in
    # every encoding, and a payload that is not ASCII needs a byte-order mark (main refuses it).
    $reader = New-Object System.IO.StreamReader -ArgumentList (New-Object System.IO.MemoryStream -ArgumentList (, $bytes)), ([Text.Encoding]::Default), $true
    try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
    $tok = $null; $err = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tok, [ref]$err)
    $info.Errors = @($err)
    $info.Ast = $ast
    if ($ast.ParamBlock) {
        foreach ($p in $ast.ParamBlock.Parameters) {
            $n = $p.Name.VariablePath.UserPath
            $info.Params[$n] = $p.StaticType
            foreach ($a in $p.Attributes) {
                if (-not ($a -is [System.Management.Automation.Language.AttributeAst])) { continue }
                if ($a.TypeName.Name -notmatch '(^|\.)Parameter(Attribute)?$') { continue }
                foreach ($na in $a.NamedArguments) {
                    if ($na.ArgumentName -eq 'Mandatory' -and ($na.ExpressionOmitted -or $na.Argument.Extent.Text -match '^\$true$|^1$')) { $info.Mandatory += $n }
                }
            }
        }
    }
    return $info }
function ConvertTo-PayloadValue { param($Value, [type]$Type)
    # Checks a -PayloadParameters value against the type the payload declares and returns it
    # in the form the settings file holds: text, a list of text, true/false or a number.
    $r = New-Object psobject -Property @{ Value = $null; Why = '' }
    $isNumber = ($Value -is [int] -or $Value -is [long])
    if ($Type -eq [System.Management.Automation.SwitchParameter] -or $Type -eq [bool]) {
        if ($Value -is [bool]) { $r.Value = $Value }
        elseif ($Value -is [System.Management.Automation.SwitchParameter]) { $r.Value = $Value.IsPresent }
        else { $r.Why = 'is a switch: give $true or $false' }
        return $r }
    if ($Type -eq [int] -or $Type -eq [long]) {
        if ($isNumber) { $r.Value = [long]$Value } else { $r.Why = 'takes a whole number' }
        return $r }
    if ($Type.IsArray -and ($Type.GetElementType() -eq [string] -or $Type.GetElementType() -eq [object])) {
        $list = @()
        foreach ($i in @($Value)) {
            if (-not ($i -is [string] -or $i -is [int] -or $i -is [long]) -or ([string]$i -match '[^\x20-\x7E]')) { $r.Why = 'takes plain ASCII text values'; return $r }
            $list += [string]$i }
        $r.Value = [string[]]$list
        return $r }
    if ($Type -eq [string] -or $Type -eq [object]) {
        if ($Type -eq [object] -and $Value -is [bool]) { $r.Value = $Value; return $r }
        if ($Type -eq [object] -and $Value -is [array]) { return (ConvertTo-PayloadValue $Value ([string[]])) }
        if (($Value -is [string] -or $isNumber) -and -not ([string]$Value -match '[^\x20-\x7E]')) { $r.Value = [string]$Value }
        else { $r.Why = 'takes plain ASCII text' }
        return $r }
    $r.Why = 'is of type ' + $Type.Name + ', which this script cannot pass on; leave it to the payload''s default'
    return $r }
function Test-OsHasOpenSsh { param([string]$OsVersion)
    # OperatingSystemVersion reads like '10.0 (17763)'. Build 17763 (Windows Server 2019,
    # Windows 10 1809) is the first with OpenSSH Server built in. $null when not known.
    if ($OsVersion -notmatch '^\s*(\d+)\.(\d+)\s*\((\d+)\)') { return $null }
    $maj = [int]$Matches[1]; $build = [int]$Matches[3]
    if ($maj -gt 10) { return $true }
    if ($maj -lt 10) { return $false }
    return ($build -ge 17763) }
function Get-PlatformProblem {
    if ($env:OS -ne 'Windows_NT') { return 'This script runs on Windows: a domain-joined machine with the Group Policy Management tools and the Active Directory module.' }
    if ($PSVersionTable.PSEdition -eq 'Core') { return 'Run this in Windows PowerShell 5.1 (powershell.exe), not in PowerShell 7: the GroupPolicy module is a Windows PowerShell module, and through the PowerShell 7 compatibility layer its objects lose details this script checks.' }
    if ($PSVersionTable.PSVersion -lt [version]'5.1') { return ('This needs Windows PowerShell 5.1; this is ' + $PSVersionTable.PSVersion + '. Install Windows Management Framework 5.1.') }
    return '' }
function Get-SysvolRoot { param([string]$Server, [string]$Fqdn)
    # Files go through the same domain controller as the directory changes.
    return ('\\' + $Server + '\SYSVOL\' + $Fqdn) }
function Get-GpoFolder { param([string]$Server, [string]$Fqdn, [string]$GuidText)
    # \\<dc>\SYSVOL\<domain>\Policies\{GUID}: the GPO's own folder.
    return (Join-Path (Join-Path (Get-SysvolRoot -Server $Server -Fqdn $Fqdn) 'Policies') $GuidText) }

# ------------------------------------------------------------ GPO contents
function ConvertTo-JsonString { param([string]$Text)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        if ($code -eq 34) { [void]$sb.Append('\"') }
        elseif ($code -eq 92) { [void]$sb.Append('\\') }
        elseif ($code -lt 32 -or $code -gt 126) { [void]$sb.Append(('\u{0:x4}' -f $code)) }
        else { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString() }
function ConvertTo-JsonValue { param($Value)
    # The settings file is written by hand, so it reads the same in every PowerShell version.
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { if ($Value) { return 'true' }; return 'false' }
    if ($Value -is [int] -or $Value -is [long]) { return [string]$Value }
    if ($Value -is [array]) {
        $items = @(); foreach ($v in $Value) { $items += (ConvertTo-JsonValue $v) }
        return ('[' + ($items -join ', ') + ']') }
    return (ConvertTo-JsonString ([string]$Value)) }
function New-SettingsJson { param($Parameters)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('{')
    $lines.Add('    "WrittenBy": ' + (ConvertTo-JsonString ($script:Name + ' ' + $script:Version)) + ',')
    $lines.Add('    "Written": ' + (ConvertTo-JsonString ((Get-Date).ToString('s'))) + ',')
    $lines.Add('    "Parameters": {')
    $keys = @($Parameters.Keys)
    for ($i = 0; $i -lt $keys.Count; $i++) {
        $sep = ','; if ($i -eq $keys.Count - 1) { $sep = '' }
        $lines.Add('        ' + (ConvertTo-JsonString ([string]$keys[$i])) + ': ' + (ConvertTo-JsonValue $Parameters[[string]$keys[$i]]) + $sep)
    }
    $lines.Add('    }')
    $lines.Add('}')
    return (($lines -join "`r`n") + "`r`n") }
function New-PsScriptsIni { param([string]$CmdLine)
    # Exactly what GPMC writes for one computer startup PowerShell script with Run Windows
    # PowerShell scripts first. The name alone: it is found in the GPO's Startup folder.
    return ("[ScriptsConfig]`r`nStartExecutePSFirst=true`r`n[Startup]`r`n0CmdLine=" + $CmdLine + "`r`n0Parameters=`r`n") }
function Test-ScriptsCse { param([string]$Names)
    foreach ($g in [regex]::Matches([string]$Names, '\[[^\]]*\]')) {
        $v = $g.Value.ToUpper()
        if ($v.StartsWith('[' + $script:CseScripts) -and $v.Contains($script:CseTool)) { return $true } }
    return $false }
function Add-ScriptsCse { param([string]$Names)
    # gPCMachineExtensionNames is a sorted list of [{extension}{tool}...] groups. GPMC adds
    # the Scripts extension when a script is assigned in its editor; this does the same.
    $out = New-Object System.Collections.Generic.List[string]
    $done = $false
    foreach ($m in [regex]::Matches([string]$Names, '\[[^\]]*\]')) {
        $g = $m.Value
        $ids = @([regex]::Matches($g, '\{[^}]+\}') | ForEach-Object { $_.Value.ToUpper() })
        if ($ids.Count -and $ids[0] -eq $script:CseScripts) {
            $tools = @($ids | Select-Object -Skip 1)
            if ($tools -notcontains $script:CseTool) { $tools = @($tools + $script:CseTool) }
            $g = '[' + $script:CseScripts + ((@($tools) | Sort-Object -Unique) -join '') + ']'
            $done = $true }
        $out.Add($g) }
    if (-not $done) { $out.Add('[' + $script:CseScripts + $script:CseTool + ']') }
    return ((@($out) | Sort-Object -Unique) -join '') }
function Get-BumpedVersion { param([long]$VersionNumber)
    # versionNumber: COMPUTER version = low 16 bits, USER version = high 16 bits. Raise the
    # computer word by 1 on every run (cheap, monotonic) so members see a change.
    $vn = $VersionNumber
    if ($vn -lt 0) { $vn += 4294967296 }
    $user = ($vn -shr 16) -band 0xFFFF
    $comp = ($vn -band 0xFFFF) + 1
    if ($comp -gt 0xFFFF) { $comp = 1 }
    $new = ($user -shl 16) -bor $comp
    if ($new -gt 2147483647) { $new -= 4294967296 }
    return (New-Object psobject -Property @{ Value = [int]$new; Computer = [int]$comp; User = [int]$user }) }
function Clear-FileAttributes { param([string]$Path)
    # GPMC can leave psscripts.ini hidden, and .NET cannot overwrite a hidden or read-only file.
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        $mask = [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::ReadOnly
        if ($item.Attributes -band $mask) { $item.Attributes = [IO.FileAttributes]::Normal } } }
function Write-SysvolFile { param([string]$Path, [byte[]]$Bytes)
    # Written whole under a temporary name in the same folder, then renamed over the old file:
    # a computer that reads it at that moment (one that restarts during a rerun) gets the old
    # file or the new one, never the start of one. Written as a new file rather than copied: a
    # copy would carry a downloaded file's Zone.Identifier stream along, and the computers
    # could then refuse to run it. File.Replace keeps the streams of the file it replaces, so
    # that stream is taken off the old file first.
    $tmp = $Path + '.' + ([guid]::NewGuid().ToString('N')).Substring(0, 8) + '.tmp'
    [IO.File]::WriteAllBytes($tmp, $Bytes)
    try {
        $attempt = 0
        while ($true) {
            $attempt++
            try {
                if (Test-Path -LiteralPath $Path) {
                    Clear-FileAttributes $Path
                    if ($env:OS -eq 'Windows_NT') { try { Unblock-File -LiteralPath $Path -ErrorAction Stop } catch { } }
                    # No backup file. A plain $null would reach .NET as an empty string.
                    [IO.File]::Replace($tmp, $Path, [System.Management.Automation.Language.NullString]::Value, $true)
                } else { [IO.File]::Move($tmp, $Path) }
                break
            } catch {
                # A computer reading the file at that moment can hold it open, a sharing violation
                # (an IOException): try again shortly. Any other error would only repeat.
                $ex = $_.Exception; if ($ex.InnerException) { $ex = $ex.InnerException }
                if ($attempt -ge 5 -or -not ($ex -is [System.IO.IOException])) { throw }
                Start-Sleep -Seconds 2
            }
        }
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } } }
function Write-SysvolText { param([string]$Path, [string]$Text, [System.Text.Encoding]$Encoding)
    # The bytes [IO.File]::WriteAllText writes: the encoding's byte-order mark, if it has one
    # (UTF-16 for psscripts.ini, none for ASCII), then the text.
    $pre = $Encoding.GetPreamble(); $body = $Encoding.GetBytes($Text)
    $all = New-Object byte[] ($pre.Length + $body.Length)
    [Array]::Copy($pre, 0, $all, 0, $pre.Length)
    [Array]::Copy($body, 0, $all, $pre.Length, $body.Length)
    Write-SysvolFile $Path $all }
function Set-GptVersion { param([string]$Path, [int]$Version)
    # GPT.ini in SYSVOL carries the same version as the directory, so members detect the change.
    $text = "[General]`r`nVersion=$Version`r`n"
    if (Test-Path -LiteralPath $Path) {
        $old = [IO.File]::ReadAllText($Path)
        if ($old -match '(?im)^\s*Version\s*=\s*-?\d+') { $text = [regex]::Replace($old, '(?im)^(\s*Version\s*=\s*)-?\d+', ('${1}' + $Version)) } }
    Write-SysvolText $Path $text ([Text.Encoding]::ASCII) }
function Get-GptVersion { param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $m = [regex]::Match([IO.File]::ReadAllText($Path), '(?im)^\s*Version\s*=\s*(-?\d+)')
    if ($m.Success) { return [long]$m.Groups[1].Value }
    return $null }
function Get-StartupFolder { param([string]$GpoRoot)
    return (Join-Path (Join-Path (Join-Path $GpoRoot 'Machine') 'Scripts') 'Startup') }

# ------------------------------------------------------------ GPO actions
function Find-GpoByName { param([string]$Name, [string]$Fqdn, [string]$Server)
    # Get-GPO -Name can throw (not just return nothing) when the GPO is absent, so the GPOs
    # are listed and matched by name instead.
    return @(Get-GPO -All -Domain $Fqdn -Server $Server -ErrorAction Stop | Where-Object { $_.DisplayName -eq $Name }) }
function Get-GpoLink { param($GpoId, [string]$Target, [string]$Fqdn, [string]$Server)
    $inh = Get-GPInheritance -Target $Target -Domain $Fqdn -Server $Server -ErrorAction Stop
    return (@($inh.GpoLinks | Where-Object { $_.GpoId -eq $GpoId }) | Select-Object -First 1) }
function Get-GpoLinkList { param([string]$GuidText, [string]$DomainDn, [string]$Server)
    # Every OU, and the domain itself, that links the GPO: each names it in its gPLink attribute
    # as [LDAP://cn={GUID},cn=policies,cn=system,<domain>;<flags>], where flag 1 means the
    # link is disabled. Returns Dn and Enabled for each. A link on an AD site (made by hand in
    # the Group Policy Management Console) is not in the domain, so it is not listed.
    $g = $GuidText.Trim().Trim('{', '}')
    $filter = '(&(|(objectClass=organizationalUnit)(objectClass=domainDNS))(gPLink=*' + $g + '*))'
    $out = @()
    foreach ($o in @(Get-ADObject -LDAPFilter $filter -SearchBase $DomainDn -SearchScope Subtree -Server $Server -Properties gPLink -ErrorAction Stop)) {
        foreach ($m in [regex]::Matches([string]$o.gPLink, ('\[LDAP://[^\]]*?\{' + [regex]::Escape($g) + '\}[^\]]*?;(\d+)\]'), 'IgnoreCase')) {
            $out += New-Object psobject -Property @{ Dn = [string]$o.DistinguishedName; Enabled = ((([int]$m.Groups[1].Value) -band 1) -eq 0) } } }
    return $out }
function Test-GpoReady { param($GpoId, [string]$AdDn, [string]$GpoRoot, [string]$Fqdn, [string]$Server, [string]$PayloadSha)
    # The check the first deployer lacked at the end: FAIL LOUDLY if a member would still see
    # this GPO as empty, or if anything the startup script needs is missing.
    $r = New-Object psobject -Property @{ Problems = (New-Object System.Collections.Generic.List[string]); Notes = (New-Object System.Collections.Generic.List[string]); Lines = (New-Object System.Collections.Generic.List[string]); ComputerVersion = 0 }
    $o = Get-ADObject -Identity $AdDn -Server $Server -Properties versionNumber, gPCMachineExtensionNames -ErrorAction Stop
    $vn = [long]$o.versionNumber
    $cv = $vn -band 0xFFFF
    $r.ComputerVersion = $cv
    if ($cv -gt 0) { $r.Lines.Add("Computer version|$cv (versionNumber $vn)") }
    else { $r.Problems.Add('its computer version is 0, so members would show it as Not Applied (Empty) and skip it') }
    if (Test-ScriptsCse ([string]$o.gPCMachineExtensionNames)) { $r.Lines.Add('Scripts extension|registered on the GPO') }
    else { $r.Problems.Add('the Scripts client-side extension is not registered on the GPO (gPCMachineExtensionNames), so members would not run the script') }
    $gv = Get-GptVersion (Join-Path $GpoRoot 'GPT.ini')
    if ($null -ne $gv -and $gv -eq $vn) { $r.Lines.Add("GPT.ini|version $gv, the same as the directory") }
    else { $r.Problems.Add("GPT.ini in SYSVOL has version $gv, the directory has $vn") }
    $startup = Get-StartupFolder $GpoRoot
    $ini = Join-Path (Split-Path -Parent $startup) 'psscripts.ini'
    $iniOk = $false
    if (Test-Path -LiteralPath $ini) { $iniOk = ([IO.File]::ReadAllText($ini) -match ('(?m)^0CmdLine=' + [regex]::Escape($script:LauncherName) + '\s*$')) }
    if ($iniOk) { $r.Lines.Add("psscripts.ini|startup script $($script:LauncherName), PowerShell scripts first") }
    else { $r.Problems.Add('psscripts.ini does not assign the startup script') }
    $pl = Join-Path $startup $script:PayloadName
    $plOk = $false
    if (Test-Path -LiteralPath $pl) { $plOk = ((Get-Sha256Hex ([IO.File]::ReadAllBytes($pl))) -eq $PayloadSha) }
    if ($plOk) { $r.Lines.Add("Payload|$($script:PayloadName) in SYSVOL, the same as the source") }
    else { $r.Problems.Add('the payload in SYSVOL is missing or differs from the source') }
    foreach ($f in @($script:LauncherName, $script:SettingsName)) {
        if (-not (Test-Path -LiteralPath (Join-Path $startup $f))) { $r.Problems.Add("$f is missing from the GPO folder") } }
    try {
        $x = [xml](Get-GPOReport -Guid $GpoId -ReportType Xml -Domain $Fqdn -Server $Server -ErrorAction Stop)
        $s = @(@($x.GPO.Computer.ExtensionData | Where-Object { $_.Name -eq 'Scripts' }) | ForEach-Object { $_.Extension.Script }) | Select-Object -First 1
        if ($s) { $r.Lines.Add('GPO report|' + $s.Type + ' -> ' + $s.Command + ' (' + $s.RunOrder + ')') }
        else { $r.Notes.Add('The GPO report does not show the startup script yet; it can lag. Run Get-GPOReport again in a minute.') }
        $links = @(@($x.GPO.LinksTo) | Where-Object { $_ } | ForEach-Object { [string]$_.SOMPath + ' (enabled ' + [string]$_.Enabled + ')' })
        if ($links.Count) { $r.Lines.Add('Linked to|' + ($links -join '; ')) }
    } catch { $r.Notes.Add('The GPO report could not be read: ' + $_.Exception.Message) }
    try {
        $st = [string](Get-GPO -Guid $GpoId -Domain $Fqdn -Server $Server -ErrorAction Stop).GpoStatus
        if ($st -eq 'AllSettingsDisabled' -or $st -eq 'ComputerSettingsDisabled') { $r.Notes.Add("Its computer settings are disabled (GPO status $st), so members ignore it until they are enabled in the Group Policy Management Console.") }
    } catch { }
    return $r }
function Undo-PartialGpo { param($State, [string]$OuDn, [string]$Fqdn, [string]$Server)
    # Never leave a GPO linked but empty: undo what this run made, and say what is left.
    if ($State.Created -and $State.Guid) {
        try { Remove-GPO -Guid $State.Guid -Domain $Fqdn -Server $Server -ErrorAction Stop | Out-Null
            return 'The GPO made by this run was deleted again, with its files and any link. Nothing is left behind.' }
        catch {
            $l = 'It is not linked anywhere.'; if ($State.LinkCreated) { $l = "It IS LINKED to $OuDn." }
            return ('The GPO made by this run could not be deleted (' + $_.Exception.Message + '). ' + $l + ' Delete it in the Group Policy Management Console, or: Remove-GPO -Guid ' + $State.Guid) } }
    if ($State.LinkCreated -and $State.Guid) {
        try { Remove-GPLink -Guid $State.Guid -Target $OuDn -Domain $Fqdn -Server $Server -ErrorAction Stop | Out-Null
            return 'The link made by this run was removed again. The GPO existed before this run and was left in place; run the script again to repair it.' }
        catch { return ('The link made by this run could not be removed (' + $_.Exception.Message + '). Remove it: Remove-GPLink -Guid ' + $State.Guid + " -Target '$OuDn'") } }
    if ($State.Guid) { return 'The GPO existed before this run and is left as it is now. Fix the cause and run the script again: a rerun rewrites every file and setting.' }
    return 'Nothing was changed.' }
function Format-PayloadValue { param($Value)
    if ($Value -is [bool]) { if ($Value) { return '$true' }; return '$false' }
    if ($Value -is [array]) { return (@($Value) -join ', ') }
    return [string]$Value }
function Get-KeyChange { param($OldLines, $NewKeys)
    # The plan's lines for a rerun that changes -PublicKey. Keys are matched by type and data,
    # as the payload matches them. The payload adds a key that a computer does not trust yet
    # and keeps every line already in administrators_authorized_keys as it is, so a key taken
    # out of the GPO stays trusted on the computers that already ran it, and new options on a
    # key they already trust do not reach them.
    $out = New-Object System.Collections.Generic.List[string]
    $old = New-Object 'System.Collections.Generic.Dictionary[string,object]' -ArgumentList ([StringComparer]::Ordinal)
    $new = New-Object 'System.Collections.Generic.Dictionary[string,object]' -ArgumentList ([StringComparer]::Ordinal)
    $bad = 0
    foreach ($l in @($OldLines)) {
        if (-not ([string]$l).Trim()) { continue }
        # Read with the payload's own ConvertTo-KeyRecord, as the computers read it.
        $k = ConvertTo-KeyRecord ([string]$l)
        if (-not $k -or -not $k.Usable) { $bad++; continue }
        $id = $k.Type + ' ' + $k.Blob
        if (-not $old.ContainsKey($id)) { $old[$id] = $k } }
    # Not @($NewKeys): it is a List[object], which PowerShell 7.6 cannot put in @() ("Argument
    # types do not match"), and the simulation of this script runs in PowerShell 7.
    foreach ($k in $NewKeys) { $id = $k.Type + ' ' + $k.Blob; if (-not $new.ContainsKey($id)) { $new[$id] = $k } }
    $added = @($new.Keys | Where-Object { -not $old.ContainsKey($_) }).Count
    $gone = @($old.Keys | Where-Object { -not $new.ContainsKey($_) } | ForEach-Object { $old[$_] })
    $opts = @($new.Keys | Where-Object { $old.ContainsKey($_) -and $old[$_].Options -cne $new[$_].Options }).Count
    $removed = $gone.Count + $bad
    if ($added -or $removed) { $out.Add("keys: $($old.Count + $bad) before, $($new.Count) after ($added added, $removed removed)") }
    if ($removed) {
        $which = @($gone | ForEach-Object { Format-KeyShort $_ })
        if ($bad) { $which += ([string]$bad + ' line(s) of the earlier settings that are not a valid key') }
        $out.Add("$removed key(s) taken out of the GPO only: the computers that already ran it keep trusting them, because the payload adds keys and never removes one. Remove them from C:\ProgramData\ssh\administrators_authorized_keys on each of those computers (-Help, UNDOING IT): " + ($which -join '; ')) }
    if ($opts) { $out.Add("$opts key(s) now have other authorized_keys options: a computer that already trusts the key keeps its old line, so the new options apply only where the key is added for the first time") }
    if (-not $out.Count) { $out.Add("keys: the same $($new.Count); only their order or comments change, and a computer that already trusts a key keeps its old line") }
    return $out }

# ====================================================================== main
Initialize-UiStyle
Show-LaunchNotice
if ($Help) { Show-Help; return }

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
try {
    $script:AuditPath = Resolve-LogPath -Value $AuditLog -DefaultName 'deploy-openssh-gpo-audit.log'
    $script:ErrorPath = Resolve-LogPath -Value $ErrorLog -DefaultName 'deploy-openssh-gpo-errors.log'
} catch {
    Say ('The log path cannot be used: ' + $_.Exception.Message + ' Nothing was changed.') 'ERROR'
    exit 1
}

# ------------------------------------- arguments: all checked before the domain is read
$problems = New-Object System.Collections.Generic.List[string]
$notes    = New-Object System.Collections.Generic.List[string]

# -TargetOU: an OU. Never the domain root unless asked for, never a container.
$ou = ''; $isRoot = $false
if ([string]::IsNullOrWhiteSpace($TargetOU)) {
    $problems.Add("-TargetOU is required: the distinguished name of the OU to link the GPO to, for example -TargetOU 'OU=Access Connectors,DC=example,DC=local'. The domain root is never used by default.")
} else {
    $ou = $TargetOU.Trim()
    $kinds = @($ou -split '(?<!\\),' | ForEach-Object { if ($_ -match '^\s*([A-Za-z]+)\s*=\s*\S') { $Matches[1].ToUpper() } else { '?' } })
    if ($kinds -contains '?' -or $kinds[$kinds.Count - 1] -ne 'DC') {
        $problems.Add("-TargetOU '$ou' is not a full distinguished name: it must end with the domain, for example 'OU=Access Connectors,DC=example,DC=local'.")
    } elseif ($kinds[0] -eq 'DC') { $isRoot = $true }
    elseif ($kinds[0] -eq 'CN') {
        $problems.Add("-TargetOU '$ou' is a container, not an OU. Group Policy cannot be linked to a container (CN=Computers is one): move the computer accounts into an OU and give that OU.")
    } elseif ($kinds[0] -ne 'OU') { $problems.Add("-TargetOU '$ou' does not name an OU.") }
}
if ($isRoot -and -not $AllowDomainRoot) {
    $problems.Add("-TargetOU '$ou' is the domain root: the GPO would reach every computer in the domain, the domain controllers included. Give an OU, or add -AllowDomainRoot and -AllowDomainControllers if that is really meant.")
}
if ($AllowDomainRoot -and $ou -and -not $isRoot) { $notes.Add('[ignored] -AllowDomainRoot has no effect: -TargetOU is not the domain root.') }
if ($Yes -and $WhatIf) { $notes.Add('[ignored] -Yes has no effect with -WhatIf: nothing is changed, so there is nothing to confirm.') }

$GpoName = ([string]$GpoName).Trim()
if (-not $GpoName) { $problems.Add('-GpoName is empty.') }
elseif ($GpoName -match '[^\x20-\x7E]') { $problems.Add('-GpoName must be plain ASCII text.') }

# The payload: it must parse in Windows PowerShell 5.1, which runs it on the computers, and take
# the parameters this script hands it. Its own checks of the keys and of -AllowFrom are taken from
# it first (Get-PayloadChecks), so that the keys and networks below are checked by them.
if (-not $PayloadPath) { $PayloadPath = Join-Path $here $script:PayloadName }
$payloadFull = ''; $pinfo = $null; $checksOk = $false
if (-not (Test-Path -LiteralPath $PayloadPath -PathType Leaf)) {
    $problems.Add("The payload was not found: $PayloadPath. It is Install-OpenSSHServer.ps1, kept beside this script; or name it with -PayloadPath.")
} else {
    $payloadFull = (Resolve-Path -LiteralPath $PayloadPath).ProviderPath
    $pinfo = Get-PayloadInfo $payloadFull
    if ($pinfo.Errors.Count) {
        $pe = $pinfo.Errors[0]
        $problems.Add(('The payload does not parse in this PowerShell ({0}), and the computers run it in Windows PowerShell 5.1. Line {1}: {2}' -f $PSVersionTable.PSVersion, $pe.Extent.StartLineNumber, $pe.Message))
    } else {
        $chk = Get-PayloadChecks $pinfo.Ast $payloadFull
        if ($chk.Problem) { $problems.Add($chk.Problem) }
        else {
            # Each text is one function definition: running it defines that function in this
            # script's scope and does nothing else. The payload's code runs only when a check
            # below calls one of them.
            foreach ($d in $chk.Definitions) { . ([scriptblock]::Create($d)) }
            $script:KeyTypes = $chk.KeyTypes; $script:PrivateKeyText = $chk.PrivateKeyText
            $checksOk = $true
        }
    }
    if ($pinfo.NonAscii -and -not $pinfo.HasBom) { $problems.Add('The payload has non-ASCII characters and no byte-order mark: Windows PowerShell 5.1 on the computers would misread them.') }
    if (-not $pinfo.Params.ContainsKey('PublicKey')) { $problems.Add("The payload has no -PublicKey parameter. Is $payloadFull the Install-OpenSSHServer.ps1 that belongs with this script?") }
}

# -PublicKey / -PublicKeyFile: at least one public key, and never a private one. Each value, and
# each line of -PublicKeyFile, reaches the payload as one -PublicKey value, so each is checked as
# one by the payload's own Get-InputKeys (Test-PayloadKeys): what it refuses, every computer
# would refuse at every startup. It also splits keys joined with a comma ('powershell -File'
# passes -PublicKey 'k1','k2' as 'k1,k2') or with spaces, so the plan, the duplicate check and
# the settings hold the keys it will trust, one per line.
$keys = New-Object System.Collections.Generic.List[object]
$seen = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::Ordinal)
$keyItems = New-Object System.Collections.Generic.List[object]
$keyRefused = 0
$i = 0
foreach ($v in @($PublicKey)) {
    $i++
    if ($null -eq $v -or -not ([string]$v).Trim()) { continue }
    if ([string]$v -match $script:PrivateKeyText) {
        $problems.Add("-PublicKey value $i is a PRIVATE key. It was not printed, copied or kept. Give the public key: the .pub file."); $keyRefused++; continue }
    $keyItems.Add(@{ Where = "-PublicKey value $i"; Text = [string]$v; File = $false })
}
if ($PublicKeyFile) {
    $raw = $null
    if (-not (Test-Path -LiteralPath $PublicKeyFile -PathType Leaf)) { $problems.Add("-PublicKeyFile not found: $PublicKeyFile"); $keyRefused++ }
    elseif ((Get-Item -LiteralPath $PublicKeyFile).Length -gt 1048576) { $problems.Add("-PublicKeyFile $PublicKeyFile is too large to be a key file."); $keyRefused++ }
    else {
        # Read as the payload reads a key file: plain, UTF-8 with a byte-order mark, or UTF-16.
        $full = (Get-Item -LiteralPath $PublicKeyFile).FullName
        try { if ($checksOk) { $raw = (Read-TextFile $full).Text } else { $raw = [IO.File]::ReadAllText($full) } }
        catch { $problems.Add("-PublicKeyFile $PublicKeyFile cannot be read: " + $_.Exception.Message); $keyRefused++ }
    }
    if ($null -ne $raw) {
        if ($raw -match $script:PrivateKeyText) {
            $problems.Add("-PublicKeyFile $PublicKeyFile holds a PRIVATE key. It was not printed, copied or kept. Give the public key: the matching .pub file."); $keyRefused++
        } elseif ($raw -match 'BEGIN SSH2 PUBLIC KEY') {
            $problems.Add("-PublicKeyFile $PublicKeyFile is in the SSH2 (RFC 4716) format. Convert it to the OpenSSH format first: ssh-keygen -i -f <file>"); $keyRefused++
        } else {
            # Blank lines are left out here; lines starting with # the payload skips itself.
            $n = 0
            foreach ($l in ($raw -split "`r?`n")) {
                $n++
                if ($l.Trim()) { $keyItems.Add(@{ Where = "-PublicKeyFile line $n"; Text = $l; File = $true }) } }
        }
    }
}
if ($checksOk) {
    foreach ($it in $keyItems) {
        $r = $null
        try { $r = Test-PayloadKeys @($it.Text) }
        catch { $problems.Add(('{0} could not be checked: the payload''s own key check failed ({1}). Is {2} the Install-OpenSSHServer.ps1 that belongs with this script?' -f $it.Where, $_.Exception.GetType().Name, $payloadFull)); $keyRefused++; continue }
        foreach ($e in $r.Errors) { $problems.Add((Convert-KeyMessage $e $it)); $keyRefused++ }
        foreach ($w in $r.Warnings) { $notes.Add('[note] ' + (Convert-KeyMessage $w $it)) }
        if (-not $it.File -and -not $r.Keys.Count -and -not $r.Errors.Count) { $notes.Add(('[note] {0} holds no key: a line that starts with # is a comment, which the payload skips.' -f $it.Where)) }
        foreach ($k in $r.Keys) {
            if (-not $seen.Add($k.Id)) { $notes.Add(('[note] {0} repeats a key given before ({1}); it is used once.' -f $it.Where, $k.Fingerprint)); continue }
            $keys.Add($k) }
    }
}
if (-not $keys.Count -and -not $keyRefused -and ($checksOk -or -not $keyItems.Count)) {
    $problems.Add('No public key given. Use -PublicKey or -PublicKeyFile: the payload trusts these keys and turns password sign-in off, so without one nobody could sign in.')
}

# -AllowFrom, checked by the payload's own Get-InputNetworks (Test-PayloadNetworks), as every
# computer checks it. Commas, semicolons and spaces all separate values, because under
# powershell -File a list arrives as one string. A message shows a value only by the payload's
# rule, so that a key given here by mistake is neither printed nor logged.
$allow = New-Object System.Collections.Generic.List[string]
$allowValues = @(@($AllowFrom) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
# Whether -AllowFrom holds any text at all. Whether that text names a network is for the
# payload's check to say: commas, semicolons and spaces alone name none.
$allowText = (@($allowValues | Where-Object { $_.Trim() }).Count -gt 0)
if ($checksOk -and $allowValues.Count) {
    $r = $null
    try { $r = Test-PayloadNetworks $allowValues }
    catch { $problems.Add(('-AllowFrom could not be checked: the payload''s own check failed ({0}). Is {1} the Install-OpenSSHServer.ps1 that belongs with this script?' -f $_.Exception.GetType().Name, $payloadFull)) }
    if ($r) {
        foreach ($e in $r.Errors) {
            # The payload's advice about the order of its own -ArgumentList does not apply here.
            $t = [regex]::Replace([string]$e, '\s*[^.]*-ArgumentList[^.]*\.', '')
            if ($t -ne [string]$e) { $t += ' -AllowFrom takes addresses and networks only; public keys go in -PublicKey or -PublicKeyFile.' }
            $problems.Add($t) }
        foreach ($s in $r.Specs) {
            if ($s.Prefix -eq 0) { $notes.Add('[note] -AllowFrom ' + $s.Text + ' allows every address of its kind, so it limits nothing.') }
            $allow.Add([string]$s.Text) }
        # Text, but neither a network nor an error in it: only separators, as -AllowFrom "$a,$b"
        # gives when both variables are empty. The payload would then leave TCP 22 open to ANY
        # address, the very thing -AllowFrom is required against, so it is refused, also with
        # -AllowFromAnyAddress: which of the two was meant is not clear.
        if ($allowText -and -not $r.Specs.Count -and -not $r.Errors.Count) {
            $problems.Add('-AllowFrom holds no address or network, only separators (commas, semicolons or spaces), as -AllowFrom "$a,$b" gives when both variables are empty. Without a network every computer where this GPO installs OpenSSH Server would accept TCP 22 from ANY address. Give the networks, or leave -AllowFrom out and add -AllowFromAnyAddress if that is really meant.') }
    }
}

# What the payload is handed: the keys and networks checked above, one per value, and
# -PayloadParameters, each checked against the payload's own parameters.
$pp = [ordered]@{}
if ($pinfo) {
    if ($allow.Count -and -not $pinfo.Params.ContainsKey('AllowFrom')) { $problems.Add('The payload has no -AllowFrom parameter, so -AllowFrom cannot be passed on.') }
    $pp['PublicKey'] = [string[]]@($keys | ForEach-Object { $_.Line })
    if ($allow.Count) { $pp['AllowFrom'] = [string[]]$allow.ToArray() }
    if ($PayloadParameters) {
        foreach ($k in @($PayloadParameters.Keys)) {
            $name = [string]$k
            if ($name -eq 'PublicKey' -or $name -eq 'AllowFrom') {
                $problems.Add("-PayloadParameters: give $name with this script's own -$name, not here."); continue }
            if ($name -eq 'PublicKeyFile') {
                $problems.Add('-PayloadParameters: PublicKeyFile is not offered. The keys are read here and written into the GPO: a key file that each computer read at startup would let whoever can change that file decide who signs in as administrator everywhere. Use this script''s own -PublicKeyFile.'); continue }
            if ($name -eq 'Help') {
                $problems.Add('-PayloadParameters: Help is not a setting; with it the payload would only show its help at every startup.'); continue }
            $match = @($pinfo.Params.Keys | Where-Object { $_ -eq $name })
            if (-not $match.Count) {
                $have = (@($pinfo.Params.Keys) | Sort-Object | ForEach-Object { '-' + $_ }) -join ', '
                $problems.Add(('-PayloadParameters: the payload has no -{0} parameter. It has: {1}.' -f $name, $have)); continue }
            $cv = ConvertTo-PayloadValue $PayloadParameters[$k] $pinfo.Params[$match[0]]
            if ($cv.Why) { $problems.Add(('-PayloadParameters: -{0} {1}.' -f $match[0], $cv.Why)); continue }
            if ($match[0] -eq 'DefaultShell') {
                # The payload takes these three names only (in any case), and stops on any other.
                $sh = ([string]$cv.Value).Trim().ToLowerInvariant()
                if (@('none', 'windowspowershell', 'powershell7') -notcontains $sh) {
                    $problems.Add(('-PayloadParameters: -DefaultShell ''{0}'': the payload takes None, WindowsPowerShell or PowerShell7 only. It would refuse any other name, change nothing and stop at every startup, on every computer.' -f $cv.Value)); continue }
                if ($sh -eq 'powershell7') { $notes.Add('[note] -DefaultShell PowerShell7: on a computer without PowerShell 7 (C:\Program Files\PowerShell\7\pwsh.exe) the payload stops before it changes anything, so OpenSSH Server is not installed there, at every startup. Install PowerShell 7 on them first, or use WindowsPowerShell.') }
            }
            $pp[[string]$match[0]] = $cv.Value
        }
    }
    foreach ($m in $pinfo.Mandatory) {
        if (-not $pp.Contains($m)) { $problems.Add("The payload's -$m is mandatory, and a startup script cannot answer a prompt: give it in -PayloadParameters.") }
    }
}

# -AllowFrom is required. Without it the payload leaves the firewall rules as they are, and on a
# computer where it installs OpenSSH Server that is the install's own rule: TCP 22 from ANY
# address. The earlier deployer always limited TCP 22 to the management networks.
# The rule asks whether -AllowFrom was given at all ($allowText). Text that names no network was
# refused above, by the payload's own errors or as separators only, so it needs no second message
# here; and when the checks could not be taken from the payload, the run is refused already.
# Whether TCP 22 is limited is what the payload's check found ($allow), and the [ignored] note,
# the plan and the audit line go by that: a run that goes on either limits TCP 22 to $allow, or
# was given no -AllowFrom at all and -AllowFromAnyAddress.
$keepPw = ($pp.Contains('KeepPasswordSignIn') -and $pp['KeepPasswordSignIn'] -eq $true)
$allowGiven = ($allow.Count -gt 0)
if (-not $allowText -and -not $AllowFromAnyAddress) {
    $pw = ''; if ($keepPw) { $pw = ', and with KeepPasswordSignIn, password sign-in from ANY address' }
    $problems.Add("-AllowFrom is required. Without it, every computer where this GPO installs OpenSSH Server accepts TCP 22 from ANY address (the install's own firewall rule)$pw. Give the networks the admins and the Access Connector tool connect from, for example -AllowFrom 10.0.0.0/24, or add -AllowFromAnyAddress if that is really meant.")
}
if ($allowGiven -and $AllowFromAnyAddress) { $notes.Add('[ignored] -AllowFromAnyAddress has no effect: -AllowFrom is given, and TCP 22 is limited to it.') }

# The settings this run would write, read back as the startup wrapper reads them and checked
# again by the payload's own functions, as each computer will check them: every key and network
# must be accepted, and be exactly the lines and networks of the plan.
if ($checksOk -and -not $problems.Count) {
    $what = ''
    try {
        $back = (New-SettingsJson $pp) | ConvertFrom-Json
        $kb = Test-PayloadKeys @($back.Parameters.PublicKey)
        $nb = Test-PayloadNetworks @(@($back.Parameters.AllowFrom) | Where-Object { $null -ne $_ })
        if ($kb.Errors.Count -or ((@($kb.Keys | ForEach-Object { $_.Line }) -join "`n") -cne (@($keys | ForEach-Object { $_.Line }) -join "`n"))) { $what = 'the keys' }
        elseif ($nb.Errors.Count -or ((@($nb.Specs | ForEach-Object { $_.Text }) -join ',') -cne ($allow -join ','))) { $what = 'the -AllowFrom networks' }
    } catch { $what = 'the keys and networks (the check failed: ' + $_.Exception.GetType().Name + ')' }
    if ($what) { $problems.Add("Read back as each computer will read them, the settings this run would write do not give $what that the plan shows. That is a fault in this script: please report it.") }
}

# ANY only when the GPO is meant to leave TCP 22 open: no -AllowFrom text, and -AllowFromAnyAddress.
$af = ($allow -join ','); if (-not $allowText -and $AllowFromAnyAddress) { $af = 'ANY' }
$script:AuditContext = "gpo='$GpoName' ou='$ou' keys=$($keys.Count) fingerprints=" + (@($keys | ForEach-Object { $_.Fingerprint }) -join ',') + ' allowFrom=' + $af
foreach ($n in $notes) { Say $n 'WARN' }
if ($problems.Count) {
    foreach ($p in $problems) { Write-ErrorEntry $p 'args' }
    Say 'Nothing was changed. See -Help.' 'INFO'
    Write-AuditEntry 'FAILED' 'args' ($problems -join ' | ')
    exit 1
}

# ------------------------------------------------------------ platform and domain
$why = Get-PlatformProblem
if ($why) { Stop-Run ($why + ' Nothing was changed.') 'precheck' }
foreach ($m in @('GroupPolicy', 'ActiveDirectory')) {
    try { Import-Module $m -ErrorAction Stop }
    catch { Stop-Run ("The $m module could not be loaded: " + $_.Exception.Message + ' Install the Group Policy Management tools and the Active Directory module for Windows PowerShell (RSAT; on Windows Server: Install-WindowsFeature GPMC, RSAT-AD-PowerShell). Nothing was changed.') 'precheck' -Record $_ }
}
try {
    if ($Server) { $dom = Get-ADDomain -Server $Server -ErrorAction Stop }
    else { $dom = Get-ADDomain -ErrorAction Stop; $Server = [string]$dom.PDCEmulator }
} catch { Stop-Run ('The domain could not be read: ' + $_.Exception.Message + ' Nothing was changed.') 'precheck' -Record $_ }
$fqdn = [string]$dom.DNSRoot; $domDn = [string]$dom.DistinguishedName
$isPdc = ($Server -eq [string]$dom.PDCEmulator)

try { $ouObj = Get-ADObject -Identity $ou -Server $Server -ErrorAction Stop }
catch { Stop-Run ("-TargetOU '$ou' was not found in $fqdn (" + $_.Exception.Message + '). Nothing was changed.') 'precheck' -Record $_ }
$ouDn = [string]$ouObj.DistinguishedName
$cls = [string]$ouObj.ObjectClass
if (-not $ouDn.EndsWith($domDn, [StringComparison]::OrdinalIgnoreCase)) { Stop-Run ("-TargetOU '$ouDn' is not in $fqdn. Use -Server with a domain controller of its own domain. Nothing was changed.") 'precheck' }
if ($cls -eq 'domainDNS') {
    if (-not $AllowDomainRoot) { Stop-Run ("-TargetOU '$ouDn' is the domain root: the GPO would reach every computer in the domain, the domain controllers included. Give an OU, or add -AllowDomainRoot and -AllowDomainControllers if that is really meant. Nothing was changed.") 'precheck' }
    $isRoot = $true
} elseif ($cls -ne 'organizationalUnit') {
    Stop-Run ("-TargetOU '$ouDn' is a $cls, not an OU. Group Policy can be linked to an OU or the domain only. Nothing was changed.") 'precheck'
}

# What the link reaches: shown in the plan, so the reach is seen before anything changes.
$computers = @(); $listed = $true; $listWhy = ''
try { $computers = @(Get-ADComputer -SearchBase $ouDn -SearchScope Subtree -Filter * -Server $Server -Properties OperatingSystem, OperatingSystemVersion, primaryGroupID -ErrorAction Stop | Sort-Object Name) }
catch { $listed = $false; $listWhy = $_.Exception.Message }
# Domain controllers and read-only domain controllers, by their primary group.
$dcs = @($computers | Where-Object { $_.primaryGroupID -eq 516 -or $_.primaryGroupID -eq 521 })

try { $found = @(Find-GpoByName -Name $GpoName -Fqdn $fqdn -Server $Server) }
catch { Stop-Run ('The GPOs could not be listed: ' + $_.Exception.Message + ' Nothing was changed.') 'precheck' -Record $_ }
if ($found.Count -gt 1) { Stop-Run ("$($found.Count) GPOs are named '$GpoName'. Rename or delete the extra ones in the Group Policy Management Console, or use another -GpoName. Nothing was changed.") 'precheck' }
$gpo = $null; $link = $null; $oldSettings = $null; $linksNow = @(); $otherLinks = @()
if ($found.Count -eq 1) {
    $gpo = $found[0]
    if ([string]$gpo.Description -notlike ('*' + $script:Tag + '*')) {
        Stop-Run ("A GPO named '$GpoName' already exists ($($gpo.Id)) and was not made by this script, so it is left alone. Use another -GpoName. Nothing was changed.") 'precheck' }
    try { $link = Get-GpoLink -GpoId $gpo.Id -Target $ouDn -Fqdn $fqdn -Server $Server }
    catch { Stop-Run ("The links of $ouDn could not be read: " + $_.Exception.Message + ' Nothing was changed.') 'precheck' -Record $_ }
    $guidNow = '{' + $gpo.Id.ToString().ToUpper() + '}'
    # Every OU that links the GPO now. A run with another -TargetOU adds a link and keeps the
    # others, and the settings it writes reach the computers in all of them.
    try { $linksNow = @(Get-GpoLinkList -GuidText $guidNow -DomainDn $domDn -Server $Server) }
    catch { Stop-Run ("The links of '$GpoName' could not be read: " + $_.Exception.Message + ' Nothing was changed.') 'precheck' -Record $_ }
    $otherLinks = @($linksNow | Where-Object { -not [string]::Equals([string]$_.Dn, $ouDn, [StringComparison]::OrdinalIgnoreCase) })
    $oldFile = Join-Path (Get-StartupFolder (Get-GpoFolder -Server $Server -Fqdn $fqdn -GuidText $guidNow)) $script:SettingsName
    try { if (Test-Path -LiteralPath $oldFile) { $oldSettings = (Get-Content -LiteralPath $oldFile -Raw) | ConvertFrom-Json } } catch { $oldSettings = $null }
}

# Refused once the domain is read. Shown after the plan, which lists what they are about.
$refusals = New-Object System.Collections.Generic.List[string]
$domNotes = New-Object System.Collections.Generic.List[string]
if ($dcs.Count -and -not $AllowDomainControllers) {
    $dcNames = @($dcs | Select-Object -First 10 | ForEach-Object { $_.Name }) -join ', '
    if ($dcs.Count -gt 10) { $dcNames += ', and ' + ($dcs.Count - 10) + ' more' }
    $refusals.Add("$($dcs.Count) domain controller(s) are under -TargetOU: $dcNames. The GPO would install sshd on them, with key sign-in for the domain's Administrators group. Give an OU without domain controllers, or add -AllowDomainControllers if that is really meant.")
} elseif (-not $listed -and -not $AllowDomainControllers) {
    $refusals.Add("The computer accounts under -TargetOU could not be listed ($listWhy), so it is not known whether domain controllers are among them. Fix the cause, or add -AllowDomainControllers.")
} elseif ($AllowDomainControllers -and $listed -and -not $dcs.Count) {
    $domNotes.Add('[ignored] -AllowDomainControllers has no effect: there is no domain controller under -TargetOU.')
}
if ($otherLinks.Count -and -not $AllowOtherLinks) {
    $fw = ''; if ($allow.Count) { $fw = ' The payload sets the firewall limit there to this run''s -AllowFrom.' }
    $refusals.Add("'$GpoName' is linked to another OU as well: " + (@($otherLinks | ForEach-Object { $_.Dn }) -join '; ') + ". This run's keys, -AllowFrom and payload settings would reach the computers there too, at their next restart.$fw Give this OU its own GPO with -GpoName, or add -AllowOtherLinks if the same settings are meant for all of them.")
} elseif ($AllowOtherLinks -and -not $otherLinks.Count) {
    $domNotes.Add('[ignored] -AllowOtherLinks has no effect: the GPO is not linked to another OU.')
}

$settingsJson = New-SettingsJson $pp
# Windows line ends, like every other file this script writes into SYSVOL.
$launcherText = ($script:LauncherText.Replace('@VERSION@', $script:Version) -replace "`r?`n", "`r`n") + "`r`n"

# ------------------------------------------------------------------- plan
foreach ($n in $domNotes) { Say $n 'WARN' }
Write-UiSection 'PLAN - nothing has been changed yet'
Write-UiField 'Domain' "$fqdn ($domDn)"
$srv = $Server; if ($isPdc) { $srv += ' (the PDC emulator)' }
Write-UiField 'Changes made on' $srv
if ($gpo) { Write-UiField 'GPO' ("'$GpoName' {" + $gpo.Id.ToString().ToUpper() + '}: made by this script before; it is updated') }
else { Write-UiField 'GPO' ("'$GpoName': new") }
if ($gpo) {
    # Every link, so that one to another OU is seen: the settings of this run reach it too.
    if (-not $linksNow.Count) { Write-UiField 'Linked now' 'nowhere' }
    foreach ($ln in $linksNow) {
        $ls = 'enabled'; if (-not $ln.Enabled) { $ls = 'link disabled' }
        if ([string]::Equals([string]$ln.Dn, $ouDn, [StringComparison]::OrdinalIgnoreCase)) { Write-UiField 'Linked now' "$($ln.Dn) ($ls)" }
        elseif ($ln.Enabled) { Write-UiField 'Linked now' "$($ln.Dn) ($ls): ANOTHER OU. These settings also reach the computers there." $script:ui.Caution }
        else { Write-UiField 'Linked now' "$($ln.Dn) ($ls): ANOTHER OU. Once the link is enabled, these settings reach the computers there." $script:ui.Caution }
    }
}
if (-not $link) { Write-UiField 'Link' "$ouDn - linked once the GPO has passed its check" }
elseif ($link.Enabled) { Write-UiField 'Link' "$ouDn - linked already" }
else { Write-UiField 'Link' "$ouDn - linked already, but the link is DISABLED: computers ignore the GPO until it is enabled" $script:ui.Caution }
if (-not $listed) { Write-UiField 'Computers' "the computer accounts under the OU could not be listed: $listWhy" $script:ui.Caution }
elseif (-not $computers.Count) { Write-UiField 'Computers' 'none under the OU yet; a computer moved into it later runs the script at its next restart' }
else {
    $shown = @($computers | Select-Object -First 20 | ForEach-Object { $_.Name }) -join ', '
    if ($computers.Count -gt 20) { $shown += (', and ' + ($computers.Count - 20) + ' more') }
    Write-UiField 'Computers' ("$($computers.Count) under the OU and the OUs below it: $shown")
    if ($dcs.Count) { Write-UiField '' ("$($dcs.Count) of them are domain controllers: " + (@($dcs | ForEach-Object { $_.Name }) -join ', ')) $script:ui.Caution }
    $old = @($computers | Where-Object { (Test-OsHasOpenSsh ([string]$_.OperatingSystemVersion)) -eq $false })
    if ($old.Count) { Write-UiField '' ("$($old.Count) of them run a Windows older than Windows Server 2019 / Windows 10 1809, which has no built-in OpenSSH Server, so the payload cannot install it there: " + (@($old | Select-Object -First 10 | ForEach-Object { $_.Name + ' (' + $_.OperatingSystem + ')' }) -join ', ')) $script:ui.Caution }
}
Write-UiField 'Payload' ("$payloadFull, $($pinfo.Bytes.Length) bytes, SHA256 $($pinfo.Sha256)")
$guidShown = '{new GUID}'; if ($gpo) { $guidShown = '{' + $gpo.Id.ToString().ToUpper() + '}' }
Write-UiField 'Into' (Get-StartupFolder (Get-GpoFolder -Server $Server -Fqdn $fqdn -GuidText $guidShown))
Write-UiField 'Startup script' "$($script:LauncherName), which runs $($script:PayloadName) with the settings in $($script:SettingsName). Windows PowerShell scripts run first."
$kn = 0
foreach ($k in $keys) {
    $kn++
    $ks = Format-KeyShort $k
    if ($k.Options) { $ks += ', with authorized_keys options' }
    Write-UiField "Key $kn" $ks }
if ($allow.Count) { Write-UiField 'Allowed from' ($allow -join ', ') }
else {
    Write-UiField 'Allowed from' 'ANY address (-AllowFromAnyAddress): a computer where this GPO installs OpenSSH Server accepts TCP 22 from ANY address, through the install''s own firewall rule. Rules that an earlier run limited stay as they are.' $script:ui.Caution
    if ($keepPw) { Write-UiField '' 'With KeepPasswordSignIn: password sign-in from ANY address too.' $script:ui.Caution } }
foreach ($pk in @($pp.Keys)) {
    if ($pk -eq 'PublicKey' -or $pk -eq 'AllowFrom') { continue }
    Write-UiField 'Payload setting' ("-$pk " + (Format-PayloadValue $pp[[string]$pk])) }
if ($gpo) {
    # A rerun replaces the GPO's settings: say what changes, so nothing is widened by accident,
    # and what does not change on the computers that already ran it.
    $chg = New-Object System.Collections.Generic.List[string]
    $oldP = @{}
    if ($oldSettings -and $oldSettings.Parameters) { foreach ($pr in $oldSettings.Parameters.PSObject.Properties) { $oldP[$pr.Name] = $pr.Value } }
    else { $chg.Add('no earlier settings file was found, so every setting is new') }
    foreach ($nm in @(@($oldP.Keys) + @($pp.Keys) | Sort-Object -Unique)) {
        $was = $null; if ($oldP.ContainsKey($nm)) { $was = ConvertTo-JsonValue $oldP[$nm] }
        $now = $null; if ($pp.Contains($nm)) { $now = ConvertTo-JsonValue $pp[[string]$nm] }
        # A switch that is false does what a switch left out does.
        if ($was -ceq 'false') { $was = $null }; if ($now -ceq 'false') { $now = $null }
        if ($was -ceq $now) { continue }
        if ($nm -eq 'PublicKey') { foreach ($c in @(Get-KeyChange @($oldP[$nm]) $keys)) { $chg.Add($c) }; continue }
        if ($nm -eq 'AllowFrom' -and $null -eq $now) {
            $chg.Add("-AllowFrom is no longer given (was $was): the computers that ran it before keep that limit, and a computer that installs OpenSSH Server from now on accepts TCP 22 from ANY address"); continue }
        if ($nm -eq 'KeepPasswordSignIn') {
            if ($now -ceq 'true') { $chg.Add('-KeepPasswordSignIn is now on: where an earlier run turned password sign-in off, it stays off, as the payload never turns it back on') }
            else { $chg.Add('-KeepPasswordSignIn is no longer on: at their next restart the computers turn password sign-in off, where a valid key is in place') }
            continue }
        if ($null -eq $was) { $chg.Add("-$nm is new: $now") }
        elseif ($null -eq $now) { $chg.Add("-$nm is no longer given (was $was): the payload's default applies from now on, and what an earlier run set on a computer is not taken back") }
        else { $chg.Add("-$nm changes from $was to $now") }
    }
    if ($chg.Count) { foreach ($c in $chg) { Write-UiField 'Changes' $c $script:ui.Caution } }
    else { Write-UiField 'Changes' 'none to the settings; the files are written again and the version raised' }
}
Write-UiField 'When' 'at each computer''s next restart: a computer startup script runs only while the computer starts'

if ($refusals.Count) {
    Write-Host ''
    foreach ($r in $refusals) { Write-ErrorEntry $r 'precheck' }
    Say 'Nothing was changed. See -Help.' 'INFO'
    Write-AuditEntry 'FAILED' 'precheck' ($refusals -join ' | ')
    exit 1
}
if ($WhatIf) {
    Write-Host ''
    Say 'WhatIf: nothing was changed. Run the same command without -WhatIf to make these changes.' 'OK'
    Write-AuditEntry 'SUCCESS' 'whatif' ''
    exit 0
}
# A change that reaches many computers waits for a YES; -Yes is the unattended answer.
if (-not $Yes) {
    $reach = 'The computers under the OU, and any moved into it later,'
    if ($listed) { $reach = "The $($computers.Count) computer(s) under the OU now, and any moved into it later," }
    Write-Host ''
    Write-UiWarn "$reach run the payload with these settings at their next restart."
    $answer = Read-Confirmation
    if ($null -eq $answer) { Stop-Run 'This run has no terminal to type YES in. Add -Yes to make these changes without the prompt, or -WhatIf to see the plan only. Nothing was changed.' 'confirm' }
    if ($answer -cne 'YES') { Stop-Run 'Not confirmed. Nothing was changed.' 'confirm' }
}

# ------------------------------------------------------------------- work
# Order matters: everything is written and checked BEFORE the GPO is linked, so no computer
# can see it half-made. On a failure, what this run made is undone.
$ErrorActionPreference = 'Stop'
$state = @{ Created = $false; LinkCreated = $false; Guid = $null; Step = '' }
$check = $null
Write-UiSection 'WORK'
try {
    $state.Step = 'create the GPO'
    if (-not $gpo) {
        $comment = "$($script:Tag) $($script:Version). Computer startup script: installs OpenSSH Server with key-only sign-in on the computers in the linked OU. Change it by running that script again; edits made here are overwritten."
        try { $gpo = New-GPO -Name $GpoName -Comment $comment -Domain $fqdn -Server $Server -ErrorAction Stop }
        catch {
            # New-GPO can complain "already exists" while it races itself across domain
            # controllers: look again before giving up. No GPO had this name when the run
            # started, so one that carries the tag now was made by this run.
            $first = $_
            Start-Sleep -Seconds 3
            $again = @(Find-GpoByName -Name $GpoName -Fqdn $fqdn -Server $Server | Where-Object { [string]$_.Description -like ('*' + $script:Tag + '*') })
            if ($again.Count -ne 1) { throw $first }
            $gpo = $again[0]
        }
        $state.Created = $true
        $state.Guid = $gpo.Id
        $guidText = '{' + $gpo.Id.ToString().ToUpper() + '}'
        Say "[1] GPO created: '$GpoName' $guidText" 'OK'
    } else {
        $state.Guid = $gpo.Id
        $guidText = '{' + $gpo.Id.ToString().ToUpper() + '}'
        Say "[1] GPO exists: '$GpoName' $guidText; updating it" 'OK'
    }
    $gpoAdDn  = "CN=$guidText,CN=Policies,CN=System,$domDn"
    $gpoRoot  = Get-GpoFolder -Server $Server -Fqdn $fqdn -GuidText $guidText

    $state.Step = 'find the GPO folder in SYSVOL'
    for ($w = 0; $w -lt 30 -and -not (Test-Path -LiteralPath $gpoRoot); $w++) { Start-Sleep -Seconds 1 }
    if (-not (Test-Path -LiteralPath $gpoRoot)) { throw "The GPO folder did not appear in SYSVOL on ${Server}: $gpoRoot" }

    $state.Step = 'write the files into the GPO folder'
    $startup  = Get-StartupFolder $gpoRoot
    $scripts  = Split-Path -Parent $startup
    $null = New-Item -ItemType Directory -Force -Path $startup
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $scripts 'Shutdown')
    Write-SysvolFile (Join-Path $startup $script:PayloadName) $pinfo.Bytes
    Write-SysvolText (Join-Path $startup $script:SettingsName) $settingsJson ([Text.Encoding]::ASCII)
    Write-SysvolText (Join-Path $startup $script:LauncherName) $launcherText ([Text.Encoding]::ASCII)
    Say "[2] payload, startup wrapper and settings written to $startup" 'OK'

    $state.Step = 'assign the startup script (psscripts.ini)'
    # Always rewritten, so a rerun repairs a broken or "Empty" GPO.
    Write-SysvolText (Join-Path $scripts 'psscripts.ini') (New-PsScriptsIni $script:LauncherName) ([Text.Encoding]::Unicode)
    Say "[3] startup script assigned: $($script:LauncherName)" 'OK'

    $state.Step = 'set Run Windows PowerShell scripts first'
    # A real computer setting (Administrative Templates > System > Scripts).
    Set-GPRegistryValue -Guid $gpo.Id -Domain $fqdn -Server $Server -Key 'HKLM\Software\Policies\Microsoft\Windows\System' `
        -ValueName 'RunComputerPSScriptsFirst' -Type DWord -Value 1 | Out-Null
    Say '[4] Run Windows PowerShell scripts first: on' 'OK'

    $state.Step = 'register the Scripts client-side extension'
    $cse = [string](Get-ADObject -Identity $gpoAdDn -Server $Server -Properties gPCMachineExtensionNames).gPCMachineExtensionNames
    $cseNew = Add-ScriptsCse $cse
    if ($cseNew -ne $cse) { Set-ADObject -Identity $gpoAdDn -Server $Server -Replace @{ gPCMachineExtensionNames = $cseNew } }
    Say '[5] Scripts client-side extension registered on the GPO' 'OK'

    $state.Step = 'raise the computer version'
    # GUARANTEE a non-zero computer version, and keep GPT.ini in lockstep.
    $vn = [long](Get-ADObject -Identity $gpoAdDn -Server $Server -Properties versionNumber).versionNumber
    $bump = Get-BumpedVersion $vn
    Set-ADObject -Identity $gpoAdDn -Server $Server -Replace @{ versionNumber = $bump.Value }
    Set-GptVersion (Join-Path $gpoRoot 'GPT.ini') $bump.Value
    Say "[6] computer version $($bump.Computer) (versionNumber $($bump.Value))" 'OK'

    $state.Step = 'check the GPO'
    $check = Test-GpoReady -GpoId $gpo.Id -AdDn $gpoAdDn -GpoRoot $gpoRoot -Fqdn $fqdn -Server $Server -PayloadSha $pinfo.Sha256
    if ($check.Problems.Count) { throw ('the finished GPO failed its check: ' + ($check.Problems -join '; ')) }
    Say '[7] GPO checked: a computer would apply it' 'OK'

    $state.Step = 'link the GPO'
    if (-not $link) {
        New-GPLink -Guid $gpo.Id -Target $ouDn -LinkEnabled Yes -Domain $fqdn -Server $Server -ErrorAction Stop | Out-Null
        $state.LinkCreated = $true
    }
    $link = Get-GpoLink -GpoId $gpo.Id -Target $ouDn -Fqdn $fqdn -Server $Server
    if (-not $link) { throw "the link to $ouDn is not there after New-GPLink" }
    if ($state.LinkCreated) { Say "[8] linked to $ouDn" 'OK' } else { Say "[8] already linked to $ouDn" 'OK' }
} catch {
    $rec = $_
    $msg = $rec.Exception.Message
    Write-ErrorEntry ("Stopped while trying to $($state.Step): $msg") 'deploy' $rec
    $undo = Undo-PartialGpo -State $state -OuDn $ouDn -Fqdn $fqdn -Server $Server
    Write-ErrorEntry $undo 'deploy'
    if ($check -and $check.Problems.Count -and -not $state.Created) { Write-UiWarn 'Re-run this script, or assign the startup script in the Group Policy Management Console.' }
    Write-AuditEntry 'FAILED' 'deploy' ("step='$($state.Step)' guid=$($state.Guid) created=$($state.Created) error=$msg undo=$undo")
    exit 1
}

# ------------------------------------------------------------------- done
Write-UiSection 'CHECK'
foreach ($ln in $check.Lines) { $pair = $ln -split '\|', 2; Write-UiField $pair[0] $pair[1] }
$linkState = 'enabled'
if (-not $link.Enabled) { $linkState = 'DISABLED' }
Write-UiField 'Link' "$ouDn ($linkState)"
foreach ($nt in $check.Notes) { Say $nt 'WARN' }
if (-not $link.Enabled) { Say ("The link to $ouDn is disabled, so the computers do not apply the GPO. Enable it when ready: Set-GPLink -Guid $($gpo.Id) -Target '$ouDn' -LinkEnabled Yes") 'WARN' }
Write-Host ''
Say "PASS - '$GpoName' is ready and linked to $ouDn." 'OK'
Write-UiSection 'NEXT'
Write-UiText "Each computer in the OU runs the script at its next restart. A computer startup script runs only while the computer starts: gpupdate /force alone does not run it. Replication takes the GPO from $Server to the other domain controllers; a computer whose domain controller does not have it yet runs it at a later restart."
Write-UiText 'To confirm on a computer after its restart, at an elevated prompt on it:'
Write-UiCmd 'gpresult /scope computer /r'
Write-UiCmd 'Get-Service sshd'
Write-UiText "'$GpoName' must be listed under Applied Group Policy Objects. Filtered out with Not Applied (Empty) means its computer version is 0: run this script again. -Help has more on confirming and undoing it."
Write-Host ''
Write-AuditEntry 'SUCCESS' 'deploy' ("guid=$($gpo.Id) created=$($state.Created) linkCreated=$($state.LinkCreated) link=$linkState computerVersion=$($check.ComputerVersion)")
exit 0
