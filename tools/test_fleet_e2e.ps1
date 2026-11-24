# End-to-end tests of -ImportFleet, -Mode Discover, the SSH sign-in check, the first SSH step,
# -Mode Stage and -Mode Verify: the real script is run in a temporary copy of the staging folder
# layout. Offline: ssh and scp are replaced by stand-ins put first on the PATH. The ssh stand-in
# logs each call and connects nowhere: the read-only discovery script, and the short scripts sent
# with -EncodedCommand, run here under pwsh (C: is a folder per host); the helper's -VerifyOnly
# gets a canned result; FAKE_SSH_* variables make it fail as ssh, or as Windows PowerShell on the
# connector, would. The scp stand-in copies into that folder. Before those, unit cases (these
# run on any platform) for functions loaded through the syntax tree from the orchestrator and
# the helper, and the orchestrator's own start loop and health gate, run in WinRM mode with
# stand-ins for remoting.
# No connector, domain controller or share is contacted.
#   pwsh -NoLogo -NoProfile -File tools/test_fleet_e2e.ps1
# Prints PASS <name> / FAIL <name>: <why> per case, then ALL TESTS PASSED or TESTS FAILED (exit 0/1).
$ErrorActionPreference = 'Stop'
$repo = if ($env:FLEET_REPO) { $env:FLEET_REPO } else { Split-Path -Parent $PSScriptRoot }

$script:Fails = 0
function Invoke-TestCase { param([string]$Name, [scriptblock]$Body)
    try { & $Body; "PASS $Name" } catch { $script:Fails++; "FAIL ${Name}: $($_.Exception.Message)" } }
function Assert-True { param($Condition, [string]$Why) if (-not $Condition) { throw $Why } }
function Assert-Equal { param($Actual, $Expected, [string]$What)
    if (-not ([string]$Actual -ceq [string]$Expected)) { throw "${What}: expected '$Expected', got '$Actual'" } }

# ================================================================ unit cases (any platform)
$orch = Join-Path $repo 'FleetDeploy/Invoke-AccessConnectorUpgrade.ps1'
$helper = Join-Path $repo 'FleetDeploy/Invoke-ConnectorUpgradeLocal.ps1'
$unitFns = @('Get-SshHint','Add-SshHint','Get-SshStepError','ConvertFrom-RemoteErrorText','Test-WinRMSignInRefused','Get-WinRMSignInReason','Get-VerifyVerdict','Test-CertBad','Format-Cert','Protect-Text','Register-Secret','Test-SshSignInCheckNeeded','Start-ConnectorRun')
$helperFns = @('Get-TaskCommand','Get-SelfDeletingTaskArgument','Get-ScheduleProblem')   # from the helper (pwsh parses it)
$tk = $null; $pe = $null; $he = $null
$oast = [System.Management.Automation.Language.Parser]::ParseFile($orch, [ref]$tk, [ref]$pe)
$hast = [System.Management.Automation.Language.Parser]::ParseFile($helper, [ref]$tk, [ref]$he)
$defs = @{}
foreach ($fd in $oast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $unitFns }, $true)) { if (-not $defs.ContainsKey($fd.Name)) { $defs[$fd.Name] = $fd.Extent.Text } }
foreach ($fd in $hast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $helperFns }, $true)) { if (-not $defs.ContainsKey($fd.Name)) { $defs[$fd.Name] = $fd.Extent.Text } }
$notFound = @(@($unitFns + $helperFns) | Where-Object { -not $defs.ContainsKey($_) })
if ($pe.Count -or $he.Count -or $notFound.Count) { "FAIL load: " + $(if ($pe.Count) { "$orch does not parse" } elseif ($he.Count) { "$helper does not parse" } else { 'not found: ' + ($notFound -join ', ') }); 'TESTS FAILED'; exit 1 }
. ([scriptblock]::Create((@($defs.Values) -join "`n")))
$script:SecretValues = [System.Collections.Generic.List[string]]::new()
$orchText = [IO.File]::ReadAllText($orch)
$helperText = [IO.File]::ReadAllText($helper)

Invoke-TestCase 'hint: each ssh reason gets its hint, with the user and host; any other reason none' {
    $h = 'connector1.example.local'
    $want = [ordered]@{
        'administrator@connector1.example.local: Permission denied (publickey).' = 'the key was not accepted: name it with -SshKey <file>, or add an IdentityFile line for these hosts to the SSH settings file (Getting Started 4.7); test by hand with ssh ops@connector1.example.local hostname.'
        'Host key verification failed.' = "the connector's host key changed: remove the old one with ssh-keygen -R connector1.example.local and check the new one (Getting Started 4.6)."
        '@@@@@@@@@@@ / @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @ / @@@@@@@@@@@' = "the connector's host key changed: remove the old one with ssh-keygen -R connector1.example.local and check the new one (Getting Started 4.6)."
        'ssh: Could not resolve hostname connector1.example.local: nodename nor servname provided, or not known' = 'the name does not resolve from this machine.'
        'ssh: connect to host connector1.example.local port 22: Connection timed out' = 'port 22 is not reachable from this machine (firewall, or OpenSSH Server not running).'
        'ssh: connect to host connector1.example.local port 22: Operation timed out' = 'port 22 is not reachable from this machine (firewall, or OpenSSH Server not running).'
        'ssh: connect to host connector1.example.local port 2222: Connection refused' = 'port 2222 is not reachable from this machine (firewall, or OpenSSH Server not running).'
        'ssh: connect to host connector1.example.local port 22: No route to host' = 'port 22 is not reachable from this machine (firewall, or OpenSSH Server not running).'
        'Received disconnect from 192.0.2.10 port 22:2: Too many authentication failures / Disconnected from 192.0.2.10 port 22' = 'too many keys were offered: name the key with -SshKey, or set IdentitiesOnly for these hosts.'
        'kex_exchange_identification: Connection closed by remote host' = ''
        'no answer within 120 seconds' = ''
        '' = ''
    }
    foreach ($r in $want.Keys) { Assert-Equal (Get-SshHint -Reason $r -User 'ops' -HostName $h) $want[$r] "hint for '$r'" }
    Assert-Equal (Get-SshHint -Reason 'Permission denied (publickey).' -User '' -HostName $h) 'the key was not accepted: name it with -SshKey <file>, or add an IdentityFile line for these hosts to the SSH settings file (Getting Started 4.7); test by hand with ssh administrator@connector1.example.local hostname.' 'no user: administrator'
}
Invoke-TestCase 'hint: with -SshKey the key is named and the test command uses it' {
    Assert-Equal (Get-SshHint -Reason 'Permission denied (publickey).' -User 'ops' -HostName 'connector1.example.local' -KeyFile '~/.ssh/connector_ed25519') 'the key ~/.ssh/connector_ed25519 was not accepted: check that its public key is authorised on the connector (Getting Started 4.4); test by hand with ssh -i ~/.ssh/connector_ed25519 ops@connector1.example.local hostname.' 'Permission denied'
    Assert-True ((Get-SshHint -Reason 'Permission denied' -User 'ops' -HostName 'c1' -KeyFile '/keys/my key') -match "ssh -i '/keys/my key' ops@c1 hostname") 'a key path with a space is not quoted'
    Assert-Equal (Get-SshHint -Reason 'Too many authentication failures' -HostName 'c1' -KeyFile 'k') 'too many keys were offered before the one named with -SshKey: set IdentitiesOnly yes for these hosts in the SSH settings file (Getting Started 4.7).' 'Too many'
}
Invoke-TestCase 'hint: a domain account in the test command is quoted, so that zsh and bash keep its backslash' {
    Assert-Equal (Get-SshHint -Reason 'Permission denied (publickey).' -User 'EXAMPLE\admin' -HostName 'connector1.example.local') "the key was not accepted: name it with -SshKey <file>, or add an IdentityFile line for these hosts to the SSH settings file (Getting Started 4.7); test by hand with ssh 'EXAMPLE\admin@connector1.example.local' hostname." 'without -SshKey'
    Assert-Equal (Get-SshHint -Reason 'Permission denied (publickey).' -User 'EXAMPLE\admin' -HostName 'connector1.example.local' -KeyFile '~/.ssh/connector_ed25519') "the key ~/.ssh/connector_ed25519 was not accepted: check that its public key is authorised on the connector (Getting Started 4.4); test by hand with ssh -i ~/.ssh/connector_ed25519 'EXAMPLE\admin@connector1.example.local' hostname." 'with -SshKey'
}
Invoke-TestCase 'first SSH step message: ssh not reached (with the hint), or signed in and the script failed; masked' {
    $c = [pscustomobject]@{ Host = 'connector1.example.local'; SshUser = 'administrator' }
    $m = Get-SshStepError -Conn $c -Result ([pscustomobject]@{ ExitCode = 255; Lines = @(); Errors = @('administrator@connector1.example.local: Permission denied (publickey).'); TimedOut = $false }) -What 'create C:\ProgramData\AccessConnectorUpdate'
    Assert-Equal $m 'cannot reach connector1.example.local over SSH: administrator@connector1.example.local: Permission denied (publickey). Hint: the key was not accepted: name it with -SshKey <file>, or add an IdentityFile line for these hosts to the SSH settings file (Getting Started 4.7); test by hand with ssh administrator@connector1.example.local hostname.' 'Permission denied'
    $m = Get-SshStepError -Conn $c -Result ([pscustomobject]@{ ExitCode = 255; Lines = @(); Errors = @('ssh: connect to host connector1.example.local port 22: Connection refused'); TimedOut = $false }) -What 'create X'
    Assert-Equal $m 'cannot reach connector1.example.local over SSH: ssh: connect to host connector1.example.local port 22: Connection refused. Hint: port 22 is not reachable from this machine (firewall, or OpenSSH Server not running).' 'Connection refused'
    $m = Get-SshStepError -Conn $c -Result ([pscustomobject]@{ ExitCode = 255; Lines = @(); Errors = @(); TimedOut = $false }) -What 'create X'
    Assert-Equal $m 'cannot reach connector1.example.local over SSH: ssh ended with exit code 255 and gave no reason' 'no reason'
    $m = Get-SshStepError -Conn $c -Result ([pscustomobject]@{ ExitCode = $null; Lines = @(); Errors = @('no answer within 120 seconds'); TimedOut = $true }) -What 'create X'
    Assert-Equal $m 'cannot reach connector1.example.local over SSH: no answer within 120 seconds' 'timeout'
    $m = Get-SshStepError -Conn $c -Result ([pscustomobject]@{ ExitCode = $null; Lines = @(); Errors = @('ssh could not be run: not found'); TimedOut = $false }) -What 'create X'
    Assert-Equal $m 'cannot reach connector1.example.local over SSH: ssh could not be run: not found' 'ssh not run'
    $m = Get-SshStepError -Conn $c -Result ([pscustomobject]@{ ExitCode = 0; Lines = @('not made: C:\ProgramData\AccessConnectorUpdate'); Errors = @("New-Item : Access to the path 'C:\ProgramData\AccessConnectorUpdate' is denied."); TimedOut = $false }) -What 'create C:\ProgramData\AccessConnectorUpdate'
    Assert-Equal $m "signed in to connector1.example.local over SSH, but could not create C:\ProgramData\AccessConnectorUpdate: New-Item : Access to the path 'C:\ProgramData\AccessConnectorUpdate' is denied. / not made: C:\ProgramData\AccessConnectorUpdate" 'signed in, folder not made'
    $m = Get-SshStepError -Conn $c -Result ([pscustomobject]@{ ExitCode = 1; Lines = @(); Errors = @("'powershell' is not recognized as an internal or external command,"); TimedOut = $false }) -What 'create X'
    Assert-True ($m -like 'signed in to connector1.example.local over SSH, but could not create X: *not recognized*') "remote shell error: $m"
    $m = Get-SshStepError -Conn $c -Result ([pscustomobject]@{ ExitCode = 0; Lines = @(); Errors = @(); TimedOut = $false }) -What 'create X'
    Assert-Equal $m 'signed in to connector1.example.local over SSH, but could not create X: the connector did not confirm it (exit code 0)' 'no confirmation'
    $m = Get-SshStepError -Conn $c -Result ([pscustomobject]@{ ExitCode = 0; Lines = @('not made: X, X\Logs'); Errors = @('New-Item : denied.', 'New-Item : denied.', 'New-Item : denied.'); TimedOut = $false }) -What 'create X'
    Assert-Equal $m 'signed in to connector1.example.local over SSH, but could not create X: New-Item : denied. / not made: X, X\Logs' 'a repeated error is given once'
    Register-Secret 'Pa55word-in-a-message'
    try {
        $m = Get-SshStepError -Conn $c -Result ([pscustomobject]@{ ExitCode = 1; Lines = @(); Errors = @('it said Pa55word-in-a-message'); TimedOut = $false }) -What 'create X'
        Assert-True ($m -notmatch 'Pa55word' -and $m -match '\*{8}') "not masked: $m"
    } finally { $script:SecretValues.Clear() }
}
Invoke-TestCase 'first SSH step message: the step answered and only the end of the session failed, so ssh did sign in' {
    $c = [pscustomobject]@{ Host = 'connector1.example.local'; SshUser = 'administrator' }
    $m = Get-SshStepError -Conn $c -Result ([pscustomobject]@{ ExitCode = 255; Lines = @('ok'); Errors = @('client_loop: send disconnect: Broken pipe'); TimedOut = $false }) -What 'create C:\ProgramData\AccessConnectorUpdate'
    Assert-Equal $m 'signed in to connector1.example.local over SSH and the step answered, but ssh then ended with exit code 255: client_loop: send disconnect: Broken pipe' 'ok, then the session dropped'
    $m = Get-SshStepError -Conn $c -Result ([pscustomobject]@{ ExitCode = 255; Lines = @('ok'); Errors = @(); TimedOut = $false }) -What 'create X'
    Assert-Equal $m 'signed in to connector1.example.local over SSH and the step answered, but ssh then ended with exit code 255 and gave no reason' 'ok, then exit code 255 and no reason'
    $m = Get-SshStepError -Conn $c -Result ([pscustomobject]@{ ExitCode = $null; Lines = @('signin-ok'); Errors = @('no answer within 120 seconds'); TimedOut = $true }) -What 'run Windows PowerShell there'
    Assert-Equal $m 'signed in to connector1.example.local over SSH and the step answered, but the session did not end within 120 seconds' 'signin-ok, then the time ran out'
    $m = Get-SshStepError -Conn $c -Result ([pscustomobject]@{ ExitCode = $null; Lines = @('not made: X'); Errors = @('no answer within 120 seconds'); TimedOut = $true }) -What 'create X'
    Assert-Equal $m 'signed in to connector1.example.local over SSH, but could not create X: no answer within 120 seconds / not made: X' 'other output, then the time ran out'
}
Invoke-TestCase 'remote error text: CLIXML error records decoded, position lines, progress and colour codes dropped' {
    $w51 = "#< CLIXML`r`n" + '<Objs Version="1.1.0.1" xmlns="http://schemas.microsoft.com/powershell/2004/04"><Obj S="progress" RefId="0"><TN RefId="0"><T>System.Management.Automation.PSCustomObject</T></TN><MS><I64 N="SourceId">1</I64><PR N="Record"><AV>Preparing modules for first use.</AV></PR></MS></Obj><S S="Error">New-Item : Access to the path ''C:\ProgramData\AccessConnectorUpdate'' is denied._x000D__x000A_</S><S S="Error">At line:1 char:88_x000D__x000A_</S><S S="Error">+ ... foreach($d in $dirs){if(-not(Test-Path $d)){$null=New-Item -ItemType D ..._x000D__x000A_</S><S S="Error">+                                                       ~~~~~~~~~~~~~~~~~~~~~_x000D__x000A_</S><S S="Error">    + CategoryInfo          : PermissionDenied: (C:\ProgramData\AccessConnectorUpdate:String) [New-Item], UnauthorizedAccessException_x000D__x000A_</S><S S="Error">    + FullyQualifiedErrorId : CreateDirectoryUnauthorizedAccessError,Microsoft.PowerShell.Commands.NewItemCommand_x000D__x000A_</S><S S="Error"> _x000D__x000A_</S></Objs>' + "`r`n"
    $got = @(ConvertFrom-RemoteErrorText $w51)
    Assert-Equal ($got -join ' | ') "New-Item : Access to the path 'C:\ProgramData\AccessConnectorUpdate' is denied." 'Windows PowerShell 5.1 record'
    $pw = "#< CLIXML`n" + '<Objs Version="1.1.0.1" xmlns="http://schemas.microsoft.com/powershell/2004/04"><S S="Error">_x001B_[31;1mNew-Item: _x001B_[31;1mAccess to the path &apos;/x&apos; is denied &amp; more &lt;here&gt;._x001B_[0m_x000A_</S></Objs>' + "`n"
    Assert-Equal (@(ConvertFrom-RemoteErrorText $pw) -join ' | ') "New-Item: Access to the path '/x' is denied & more <here>." 'PowerShell 7 record'
    $mixed = "administrator@connector1.example.local: Permission denied (publickey).`r`n`r`n" + [char]27 + "[31mcoloured ssh line" + [char]27 + "[0m`n"
    Assert-Equal (@(ConvertFrom-RemoteErrorText $mixed) -join ' | ') 'administrator@connector1.example.local: Permission denied (publickey). | coloured ssh line' 'plain lines'
    Assert-True (@(ConvertFrom-RemoteErrorText '').Count -eq 0 -and @(ConvertFrom-RemoteErrorText "#< CLIXML`n").Count -eq 0) 'empty input'
}
Invoke-TestCase 'WinRM sign-in classification: refused sign-ins are true, connectors not reached are false' {
    $tx = { param([string]$Message, [int]$Code) $e = [System.Management.Automation.Remoting.PSRemotingTransportException]::new($Message); $e.ErrorCode = $Code; $e }
    $rec = { param($Ex, [string]$Fqid) [System.Management.Automation.ErrorRecord]::new($Ex, $Fqid, [System.Management.Automation.ErrorCategory]::OpenError, $null) }
    $denied = 'Connecting to remote server connector1.example.local failed with the following error message : Access is denied. For more information, see the about_Remote_Troubleshooting Help topic.'
    $yes = [ordered]@{
        'ErrorCode 5 in an ErrorRecord'      = (& $rec (& $tx $denied 5) 'AccessDenied,PSSessionOpenFailed')
        'ErrorCode 5, other words'           = (& $rec (& $tx 'Connecting to remote server failed.' 5) 'x,PSSessionOpenFailed')
        'ErrorCode 1326'                     = (& $tx 'Connecting failed.' 1326)
        'FullyQualifiedErrorId AccessDenied' = (& $rec ([Exception]::new('failed')) 'AccessDenied,PSSessionOpenFailed')
        'user name or password'              = (& $rec (& $tx 'Connecting to remote server c1 failed with the following error message : The user name or password is incorrect.' 0) 'x,PSSessionOpenFailed')
        'logon failure (text)'               = 'Logon failure: unknown user name or bad password.'
        'Kerberos logon attempt failed'      = (& $tx 'WinRM cannot process the request. The following error with errorcode 0x8009030c occurred while using Kerberos authentication: The logon attempt failed.' -2144108387)
        'locked out'                         = (& $tx 'The referenced account is currently locked out and may not be logged on to.' 0)
        'inner exception'                    = [Exception]::new('outer', (& $tx $denied 5))
        'access denied (text)'               = 'Access is denied.'
    }
    $no = [ordered]@{
        'network (53)'       = (& $rec (& $tx 'WinRM cannot complete the operation. Verify that the specified computer name is valid, that the computer is accessible over the network, and that a firewall exception for the WinRM service is enabled and allows access from this computer.' 53) 'WinRMOperationTimeout,PSSessionOpenFailed')
        'name not resolved'  = (& $tx 'The WinRM client cannot process the request because the server name cannot be resolved.' -2144108103)
        'no logon servers'   = (& $tx 'WinRM cannot process the request. The following error with errorcode 0x80090311 occurred while using Kerberos authentication: There are currently no logon servers available to service the logon request.' -2144108387)
        'TrustedHosts'       = 'The WinRM client cannot process the request. If the authentication scheme is different from Kerberos, or if the client computer is not joined to a domain, then HTTPS transport must be used or the destination machine must be added to the TrustedHosts configuration setting.'
        'nothing'            = $null
    }
    foreach ($k in $yes.Keys) { Assert-True (Test-WinRMSignInRefused $yes[$k]) "not taken as refused: $k" }
    foreach ($k in $no.Keys) { Assert-True (-not (Test-WinRMSignInRefused $no[$k])) "taken as refused: $k" }
    Assert-Equal (Get-WinRMSignInReason (& $rec (& $tx $denied 5) 'AccessDenied,PSSessionOpenFailed')) 'Access is denied.' 'reason without the boilerplate'
    Assert-Equal (Get-WinRMSignInReason "[connector1.example.local] $denied") 'Access is denied.' 'reason with the host prefix'
}
Invoke-TestCase 'WinRM: the refused sign-in message is the one the health gate stops on, in dry runs too (static)' {
    Assert-True ($orchText.Contains('Could not sign in to $($X.Host) over WinRM as $($cred.UserName): ')) 'Start-ConnectorRun does not throw the sign-in message'
    Assert-True ($orchText.Contains("-like 'Could not sign in to * over WinRM as *'")) 'the health gate does not match it'
    Assert-True ($orchText -match '\$badSignIn = \$badTask -or \$badWinRM' -and $orchText -match 'elseif \(\$badSignIn -or \(-not \$DryRun') 'a refused sign-in does not stop a dry run'
}
# The orchestrator's own start loop and health gate (its text from '# Batches:' to the summary),
# run in WinRM mode with the real Start-ConnectorRun. Stand-ins replace remoting (New-PSSession
# and what follows it), the result of each connector and the screen. Errors are made up in the
# shape PowerShell remoting gives them. Two groups of two connectors.
$i0 = $orchText.IndexOf('# Batches:'); $i1 = $orchText.IndexOf("Write-UiSection 'SUMMARY'")
$script:RunLoop = $null
if ($i0 -ge 0 -and $i1 -gt $i0 -and $orchText.IndexOf('# Batches:', $i0 + 1) -lt 0) { $script:RunLoop = [scriptblock]::Create($orchText.Substring($i0, $i1 - $i0)) }
$script:WinRMError = { param([string]$HostName, [string]$Kind)
    $msg = if ($Kind -eq 'refused') { 'Access is denied.' } else { 'WinRM cannot complete the operation. Verify that the specified computer name is valid, that the computer is accessible over the network, and that a firewall exception for the WinRM service is enabled and allows access from this computer.' }
    $e = [System.Management.Automation.Remoting.PSRemotingTransportException]::new("Connecting to remote server $HostName failed with the following error message : $msg For more information, see the about_Remote_Troubleshooting Help topic.")
    $e.ErrorCode = $(if ($Kind -eq 'refused') { 5 } else { 53 })
    [System.Management.Automation.ErrorRecord]::new($e, $(if ($Kind -eq 'refused') { 'AccessDenied,PSSessionOpenFailed' } else { 'WinRMOperationTimeout,PSSessionOpenFailed' }), [System.Management.Automation.ErrorCategory]::OpenError, $null) }
function Invoke-RunLoop { param([hashtable]$Fail = @{}, [bool]$DryRun = $true, [bool]$Parallel = $false, [bool]$ParallelTenants = $false, [bool]$ContinueOtherTenants = $false)
    # $Fail: host -> 'refused' or 'unreachable', the error New-PSSession gives for it
    if (-not $script:RunLoop) { throw "the start loop was not found in the orchestrator (between '# Batches:' and the summary)" }
    $Mode = 'WinRM'; $Authentication = 'Negotiate'; $RemoteStageDir = 'C:\ProgramData\AccessConnectorUpdate'
    $t1 = @{ Name = 'TENANT1' }; $t2 = @{ Name = 'TENANT2' }
    $plan = [System.Collections.Generic.List[object]]::new()
    foreach ($p in @(@($t1, 'connector1.example.local'), @($t1, 'connector2.example.local'), @($t2, 'connector3.example.local'), @($t2, 'connector4.example.local'))) { $plan.Add([pscustomobject]@{ Tenant = $p[0]; Host = $p[1]; SshUser = 'administrator' }) }
    $planTenants = [System.Collections.Generic.List[object]]::new(); $planTenants.Add($t1); $planTenants.Add($t2)
    $acct = [pscustomobject]@{ UserName = 'EXAMPLE\admin' }   # Start-ConnectorRun reads only the name
    $secrets = @{ TENANT1 = @{}; TENANT2 = @{} }; $creds = @{ TENANT1 = $acct; TENANT2 = $acct }; $runAs = @{}
    $results = [System.Collections.Generic.List[object]]::new(); $haltedTenants = @{}; $haltAll = $false
    $tried = [System.Collections.Generic.List[string]]::new(); $said = [System.Collections.Generic.List[string]]::new()
    function New-PSSession { param($ComputerName, $Credential, $Authentication)
        $tried.Add([string]$ComputerName)
        if ($Fail.ContainsKey([string]$ComputerName)) { throw (& $script:WinRMError ([string]$ComputerName) $Fail[[string]$ComputerName]) }
        [pscustomobject]@{ ComputerName = $ComputerName } }
    function Send-PayloadWinRM { param($Session, $T, $X) }
    function Invoke-Command { param($Session, [switch]$AsJob, $ArgumentList, $ScriptBlock) 'job' }
    function Remove-PSSession { param($Session) }
    function Complete-ConnectorRun { param($H) [pscustomobject]@{ Status = $(if ($DryRun) { 'DryRunPassed' } else { 'Success' }); Before = $null; After = $null; InstallerExit = 0; PatchExit = 0; Message = '' } }
    function Format-State { param($S) 'state' }
    function Write-UiSection { param([string]$Text) }
    function Say { param([string]$Message, [string]$Level) $said.Add([string]$Message) }
    function Write-ErrorEntry { param([string]$Message, [string]$Stage, $Record) }
    . $script:RunLoop
    [pscustomobject]@{ Tried = (@($tried) -join ','); Status = (@($results | ForEach-Object { $_.Status }) -join ','); Rows = @($results); Stops = (@($said | Where-Object { $_ -like 'Stopping:*' }) -join ' | ') } }
$script:All4 = 'connector1.example.local,connector2.example.local,connector3.example.local,connector4.example.local'
$script:Stop1 = 'Stopping: connector1.example.local refused the WinRM sign-in with the account given, so it is not tried on the other connectors.'
Invoke-TestCase 'WinRM health gate, the real start loop: a refused sign-in stops the tenant and the run, in a dry run too; a connector not reached stops only a real run' {
    $r = Invoke-RunLoop -Fail @{ 'connector1.example.local' = 'refused' }
    Assert-Equal $r.Tried 'connector1.example.local' 'dry run, first refused: connectors tried'
    Assert-Equal $r.Status 'Error,Skipped,Skipped,Skipped' 'dry run, first refused: statuses'
    Assert-Equal $r.Rows[0].Message 'Could not sign in to connector1.example.local over WinRM as EXAMPLE\admin: Access is denied.' 'the refused row'
    Assert-Equal $r.Rows[3].Message 'not attempted - an earlier connector failed' 'a connector not started'
    Assert-Equal $r.Stops $script:Stop1 'dry run, first refused: the stop is said once'
    $r = Invoke-RunLoop -Fail @{ 'connector1.example.local' = 'refused' } -ContinueOtherTenants $true
    Assert-Equal $r.Tried 'connector1.example.local,connector3.example.local,connector4.example.local' '-ContinueOtherTenants: connectors tried'
    Assert-Equal $r.Stops 'Stopping: connector1.example.local refused the WinRM sign-in with the account given, so it is not tried on the other TENANT1 connectors.' '-ContinueOtherTenants: the stop'
    $r = Invoke-RunLoop -Fail @{ 'connector1.example.local' = 'unreachable' }
    Assert-Equal $r.Tried $script:All4 'dry run, first not reached: connectors tried'
    Assert-Equal $r.Status 'Error,DryRunPassed,DryRunPassed,DryRunPassed' 'dry run, first not reached: statuses'
    Assert-True ($r.Rows[0].Message -like 'Connecting to remote server connector1.example.local failed with the following error message : WinRM cannot complete the operation.*') "the not-reached row keeps its own error: $($r.Rows[0].Message)"
    Assert-Equal $r.Stops '' 'a dry run stopped on a connector not reached'
    $r = Invoke-RunLoop -Fail @{ 'connector1.example.local' = 'unreachable' } -DryRun $false
    Assert-Equal $r.Tried 'connector1.example.local' 'real run, first not reached: connectors tried'
    Assert-Equal $r.Stops 'Stopping: connector1.example.local did not finish healthy. Connectors not yet started are left untouched.' 'real run, first not reached: the stop'
    $r = Invoke-RunLoop -Fail @{ 'connector2.example.local' = 'refused' } -DryRun $false
    Assert-Equal $r.Status 'Success,Error,Skipped,Skipped' 'real run, second refused: statuses'
}
Invoke-TestCase 'WinRM health gate with -Parallel and -ParallelTenants: a refused sign-in leaves the connectors not yet started alone' {
    $r = Invoke-RunLoop -Fail @{ 'connector1.example.local' = 'refused' } -Parallel $true
    Assert-Equal $r.Tried 'connector1.example.local' '-Parallel, first refused: connectors tried'
    Assert-Equal $r.Status 'Error,Skipped,Skipped,Skipped' '-Parallel, first refused: statuses'
    Assert-Equal $r.Stops $script:Stop1 '-Parallel, first refused: the stop is said once'
    $r = Invoke-RunLoop -Fail @{ 'connector1.example.local' = 'refused' } -Parallel $true -ContinueOtherTenants $true
    Assert-Equal $r.Tried 'connector1.example.local' '-Parallel ignores -ContinueOtherTenants'
    $r = Invoke-RunLoop -Fail @{ 'connector2.example.local' = 'refused' } -Parallel $true
    Assert-Equal $r.Tried 'connector1.example.local,connector2.example.local' '-Parallel, second refused: connectors tried'
    Assert-Equal $r.Status 'DryRunPassed,Error,Skipped,Skipped' '-Parallel, second refused: the one already started is collected'
    $r = Invoke-RunLoop -Fail @{ 'connector1.example.local' = 'unreachable' } -Parallel $true
    Assert-Equal $r.Tried $script:All4 '-Parallel, first not reached: connectors tried'
    $r = Invoke-RunLoop -Fail @{ 'connector1.example.local' = 'refused' } -ParallelTenants $true
    Assert-Equal $r.Tried 'connector1.example.local' '-ParallelTenants, first refused: connectors tried'
    $r = Invoke-RunLoop -Fail @{ 'connector1.example.local' = 'refused' } -ParallelTenants $true -ContinueOtherTenants $true
    Assert-Equal $r.Tried 'connector1.example.local,connector3.example.local,connector4.example.local' '-ParallelTenants -ContinueOtherTenants: connectors tried'
}
Invoke-TestCase 'SSH sign-in check: made by an upgrade or dry run over SSH and the two repair modes, and by no other mode' {
    $want = [ordered]@{ SSH = $true; WinRM = $false; Stage = $false; Verify = $false; RepairKeytab = $true; RepairCertificate = $true; Discover = $false }
    $modeParam = @($oast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Mode' })[0]
    $set = @($modeParam.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' })[0].PositionalArguments | ForEach-Object { $_.Value }
    Assert-Equal (@($set | Sort-Object) -join ',') (@($want.Keys | Sort-Object) -join ',') 'the modes of -Mode'
    foreach ($m in $want.Keys) { Assert-True ((Test-SshSignInCheckNeeded $m) -eq $want[$m]) "mode ${m}: expected $($want[$m])" }
    Assert-True ($orchText.Contains('if (Test-SshSignInCheckNeeded $Mode) {')) 'the run does not decide with Test-SshSignInCheckNeeded'
}
Invoke-TestCase 'helper: the command line of a task, and the self-deleting task argument (exact text)' {
    $inner = Get-TaskCommand -ScriptPath 'C:\ProgramData\AccessConnectorUpdate\Invoke-ConnectorUpgradeLocal.ps1' -JobFile 'C:\ProgramData\AccessConnectorUpdate\job.json' -SecretsFile 'C:\ProgramData\AccessConnectorUpdate\secrets.dat'
    Assert-Equal $inner 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\ProgramData\AccessConnectorUpdate\Invoke-ConnectorUpgradeLocal.ps1" -JobFile "C:\ProgramData\AccessConnectorUpdate\job.json" -SecretsFile "C:\ProgramData\AccessConnectorUpdate\secrets.dat"' 'job'
    Assert-Equal (Get-TaskCommand -ScriptPath 'C:\S\h.ps1' -JobFile 'C:\S\job.json' -SecretsFile 'C:\S\secrets.dat' -SkipDomainCheck -AuditLog 'C:\Logs\audit.log' -ErrorLog 'C:\Logs\errors.log') 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\S\h.ps1" -JobFile "C:\S\job.json" -SecretsFile "C:\S\secrets.dat" -SkipDomainCheck -AuditLog "C:\Logs\audit.log" -ErrorLog "C:\Logs\errors.log"' 'job with -SkipDomainCheck and the logs'
    Assert-Equal (Get-TaskCommand -ScriptPath 'C:\S\h.ps1' -Extra ' -RepairKeytab -CheckOnly') 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\S\h.ps1" -RepairKeytab -CheckOnly' 'keytab check'
    Assert-Equal (Get-SelfDeletingTaskArgument -Inner $inner -ConsoleLog 'C:\ProgramData\AccessConnectorUpdate\Logs\task-console_20261124_2230.log' -TaskName 'AccessConnectorUpgrade') ('/s /c "' + $inner + ' < NUL > "C:\ProgramData\AccessConnectorUpdate\Logs\task-console_20261124_2230.log" 2>&1 & schtasks.exe /Delete /TN "AccessConnectorUpgrade" /F >NUL 2>&1"') 'task argument'
    Assert-Equal (Get-SelfDeletingTaskArgument -Inner 'run' -ConsoleLog 'C:\L\c.log' -TaskName 'T') '/s /c "run < NUL > "C:\L\c.log" 2>&1 & schtasks.exe /Delete /TN "T" /F >NUL 2>&1"' 'task argument, literal'
}
Invoke-TestCase 'helper, -Schedule (by the syntax tree): checks before secrets.dat, a self-deleting cmd.exe action, a trigger that expires, -DeleteExpiredTaskAfter' {
    $ifs = @($hast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq '$Schedule' }, $true))
    Assert-True ($ifs.Count -eq 1) "blocks if (`$Schedule): $($ifs.Count)"
    $body = $ifs[0].Clauses[0].Item2
    $cmds = @($body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
    $named = { param([string]$Name) @($cmds | Where-Object { $_.GetCommandName() -eq $Name }) }
    $assigned = { param([string]$Left) @($body.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $Left }, $true)) }
    $reg = @(& $named 'Register-ScheduledTask')
    Assert-True ($reg.Count -eq 1 -and $reg[0].Extent.Text -match ' -Settings \$settings ') "Register-ScheduledTask without -Settings `$settings: $($reg.Extent.Text)"
    $set = @(& $assigned '$settings')
    Assert-True ($set.Count -eq 1 -and $set[0].Right.Extent.Text -match '^New-ScheduledTaskSettingsSet -DeleteExpiredTaskAfter ') "settings: $($set.Right.Extent.Text)"
    Assert-True (@(& $assigned '$trigger.EndBoundary').Count -eq 1) 'the trigger has no EndBoundary'
    $act = @(& $named 'New-ScheduledTaskAction')
    Assert-True ($act.Count -eq 1 -and $act[0].Extent.Text -match "-Execute 'cmd\.exe' -Argument \(Get-SelfDeletingTaskArgument -Inner \`$inner ") "action: $($act.Extent.Text)"
    $inner = @(& $assigned '$inner')
    Assert-True ($inner.Count -eq 1 -and $inner[0].Right.Extent.Text -match '^Get-TaskCommand .*-JobFile \$JobFile .*-SkipDomainCheck:\$SkipDomainCheck -AuditLog \$script:TaskAuditLog -ErrorLog \$script:TaskErrorLog$') "inner: $($inner.Right.Extent.Text)"
    $checks = @(& $named 'Get-ScheduleProblem'); $write = @(& $named 'Set-Content')
    Assert-True ($checks.Count -eq 2 -and $write.Count -eq 1 -and $checks[1].Extent.StartOffset -lt $write[0].Extent.StartOffset -and $checks[1].Extent.StartOffset -gt (& $named 'Read-UiSecret')[0].Extent.StartOffset) 'the checks are not made before secrets.dat is written, and again after the password prompt'
    # one construction of the self-deleting argument, used by the run-as task and by -Schedule
    Assert-True (@([regex]::Matches($helperText, 'schtasks\.exe /Delete')).Count -eq 1) 'the delete command is written in more than one place'
    Assert-True (@($hast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-SelfDeletingTaskArgument' }, $true)).Count -eq 2) 'the run-as task and -Schedule do not both use Get-SelfDeletingTaskArgument'
    Assert-True ($helperText.Contains('$JobFile = (Resolve-Path -LiteralPath $JobFile).ProviderPath')) 'the job file is not made a full path'
}
Invoke-TestCase 'helper, -Schedule: a time that has passed, and a task of that name that is running, are refused; a later time is not' {
    $state = $null
    function Get-ScheduledTask { [CmdletBinding()] param([string]$TaskName) if ($state) { [pscustomobject]@{ TaskName = $TaskName; State = $state } } }
    $m = Get-ScheduleProblem -When (Get-Date).AddMinutes(-1) -Text '2026-11-21 22:30' -TaskName 'AccessConnectorUpgrade'
    Assert-True ($m -match "^the time given, 2026-11-21 22:30, has already passed on this server's clock \(now \d{4}-\d\d-\d\d \d\d:\d\d\)$") "past: $m"
    $later = (Get-Date).AddDays(1)
    Assert-Equal (Get-ScheduleProblem -When $later -Text 'x' -TaskName 'AccessConnectorUpgrade') '' 'later, no task'
    $state = 'Ready'
    Assert-Equal (Get-ScheduleProblem -When $later -Text 'x' -TaskName 'AccessConnectorUpgrade') '' 'later, a task waiting'
    $state = 'Running'
    Assert-Equal (Get-ScheduleProblem -When $later -Text 'x' -TaskName 'AccessConnectorUpgrade') 'a task named AccessConnectorUpgrade is running on this server now (an earlier scheduled run is still working); schedule again when it has ended' 'later, a task running'
}
Invoke-TestCase 'Verify verdict: red items named, yellow and green as the line is coloured' {
    $svc = { param([string[]]$Keys, [string]$Stopped = '') @(foreach ($k in $Keys) { [pscustomobject]@{ Key = $k; Name = "Access$k"; Status = $(if ($k -eq $Stopped) { 'Stopped' } else { 'Running' }) } }) }
    $four = @('DirectorySyncService','UserAuthService','KerberosAuthService','VirtualAppService'); $three = @('DirectorySyncService','UserAuthService','VirtualAppService')
    $good = [pscustomobject]@{ Ok = $true; Installer = $false; NamesServer = $true; NotAfter = '2099-01-01'; Subject = 'connector.example.local'; Issuer = 'EXAMPLE-CA'; Message = '' }
    $self = [pscustomobject]@{ Ok = $true; Installer = $true; NamesServer = $true; NotAfter = '2099-01-01'; Subject = 'connector1'; Issuer = 'Internal Root CA 2026'; Message = '' }
    $old = [pscustomobject]@{ Ok = $true; Installer = $false; NamesServer = $true; NotAfter = '2001-01-01'; Subject = 'connector.example.local'; Issuer = 'EXAMPLE-CA'; Message = '' }
    $st = { param($Svc, [int]$Keytab = 412, $Cert = $good, [int]$Java = 4, [int]$Flag = 4) [pscustomobject]@{ Services = $Svc; KeytabBytes = $Keytab; Cert = $Cert; JavaCount = $Java; JavaWithFlag = $Flag } }
    $v = Get-VerifyVerdict (& $st (& $svc $four)) $true; Assert-True ($v.Level -eq 'OK' -and @($v.Red).Count -eq 0) "healthy: $($v.Level)"
    $v = Get-VerifyVerdict (& $st (& $svc $four 'KerberosAuthService')) $true; Assert-True ($v.Level -eq 'ERROR' -and ($v.Red -join ';') -eq 'not running: KerberosAuth=Stopped') "service down: $($v.Red -join ';')"
    $v = Get-VerifyVerdict (& $st (& $svc $four) 6) $true; Assert-True ($v.Level -eq 'ERROR' -and ($v.Red -join ';') -eq 'keytab EMPTY (6 bytes)') "keytab empty: $($v.Red -join ';')"
    $v = Get-VerifyVerdict (& $st (& $svc $four) -1) $true; Assert-True ($v.Level -eq 'ERROR' -and ($v.Red -join ';') -eq 'keytab missing') "keytab missing: $($v.Red -join ';')"
    $v = Get-VerifyVerdict (& $st (& $svc $three) -1 $null) $false; Assert-True ($v.Level -eq 'OK') "no Kerberos: a missing keytab does not count ($($v.Level))"
    $v = Get-VerifyVerdict (& $st (& $svc $four) 412 $self) $true; Assert-True ($v.Level -eq 'ERROR' -and ($v.Red -join ';') -like 'certificate SELF-SIGNED by the installer*') "self-signed with a Pfx: $($v.Red -join ';')"
    $v = Get-VerifyVerdict (& $st (& $svc $four) 412 $self) $false; Assert-True ($v.Level -eq 'OK') "self-signed without a Pfx is meant to be there ($($v.Level))"
    $v = Get-VerifyVerdict (& $st (& $svc $four) 412 $old) $true; Assert-True ($v.Level -eq 'ERROR' -and ($v.Red -join ';') -like 'certificate EXPIRED 2001-01-01*') "expired: $($v.Red -join ';')"
    $v = Get-VerifyVerdict (& $st (& $svc $four 'UserAuthService') 6 $self) $true; Assert-True (@($v.Red).Count -eq 3) "three red items: $($v.Red -join ';')"
    $v = Get-VerifyVerdict (& $st @() -1 $null 0 0) $false; Assert-True ($v.Level -eq 'WARN' -and @($v.Red).Count -eq 0) "nothing installed: $($v.Level)"
    $v = Get-VerifyVerdict (& $st (& $svc $three) 412 $null 2 1) $false; Assert-True ($v.Level -eq 'WARN' -and @($v.Red).Count -eq 0) "java flag 1/2: $($v.Level)"
}

# ================================================================ the real script (not on Windows)
if ($IsWindows) {
    'PASS end-to-end cases skipped on Windows (the stand-ins for ssh and scp are shell scripts)'
    if ($script:Fails) { 'TESTS FAILED'; exit 1 }; 'ALL TESTS PASSED'; exit 0 }

$base = Join-Path ([IO.Path]::GetTempPath()) ('acu-test-e2e-' + $PID)
$fd = Join-Path $base 'FleetDeploy'
foreach ($d in 'FleetDeploy','Silent Install','Installers','Configs','ChildCerts','TrustedCerts','fakebin','sheets','remote','results') { $null = New-Item -ItemType Directory -Force -Path (Join-Path $base $d) }
Copy-Item -LiteralPath (Join-Path $repo 'FleetDeploy/Invoke-AccessConnectorUpgrade.ps1') -Destination $fd
Copy-Item -LiteralPath (Join-Path $repo 'FleetDeploy/Invoke-ConnectorUpgradeLocal.ps1') -Destination $fd
Copy-Item -LiteralPath (Join-Path $repo 'Silent Install/Install-AccessConnector.ps1') -Destination (Join-Path $base 'Silent Install')
foreach ($f in 'fleet.example.csv','fleet.example.xlsx') { Copy-Item -LiteralPath (Join-Path $repo "FleetDeploy/$f") -Destination (Join-Path $base 'sheets') }
$sshLog = Join-Path $base 'ssh-calls.log'
$scpLog = Join-Path $base 'scp-calls.log'
$remote = Join-Path $base 'remote'
$results = Join-Path $base 'results'
# The ssh stand-in. FAKE_SSH_FAIL_HOST / FAKE_SSH_FAIL_TEXT: for that host, write the text on
# standard error and exit 255, as ssh does when it cannot connect or sign in. FAKE_SSH_PS_ERROR:
# answer every -EncodedCommand script with that text in a Windows PowerShell 5.1 CLIXML error
# record and exit 1, as a connector does when the script fails there.
$fakeSsh = @'
#!/bin/sh
echo "$*" >> '__SSHLOG__'
last=''; target=''
for a in "$@"; do last="$a"; case "$a" in *@*) target="${a#*@}";; esac; done
case "$target" in *down*) echo "ssh: connect to host $target port 22: Connection refused" >&2; exit 255;; esac
if [ -n "${FAKE_SSH_FAIL_HOST:-}" ]; then
  case "$target" in *"$FAKE_SSH_FAIL_HOST"*) printf '%s\r\n' "$FAKE_SSH_FAIL_TEXT" >&2; exit 255;; esac
fi
case "$last" in
  "powershell -NoProfile -EncodedCommand "*)
    if [ -n "${FAKE_SSH_PS_ERROR:-}" ]; then
      printf '#< CLIXML\r\n<Objs Version="1.1.0.1" xmlns="http://schemas.microsoft.com/powershell/2004/04"><S S="Error">%s_x000D__x000A_</S><S S="Error">At line:1 char:60_x000D__x000A_</S></Objs>\r\n' "$FAKE_SSH_PS_ERROR" >&2
      exit 1
    fi
    root='__REMOTE__'/"$target"; mkdir -p "$root"
    ENC="${last#powershell -NoProfile -EncodedCommand }" FAKE_ROOT="$root" exec pwsh -NoLogo -NoProfile -NonInteractive -Command '$null = New-PSDrive -Name C -PSProvider FileSystem -Root $env:FAKE_ROOT; Set-Location C:\; Invoke-Expression ([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($env:ENC)))' ;;
  *"Invoke-ConnectorUpgradeLocal.ps1 -VerifyOnly"*)
    printf 'output of the helper\r\n'
    if [ -f '__RESULTS__'/"$target.json" ]; then printf 'RESULT_JSON:'; cat '__RESULTS__'/"$target.json"; printf '\r\n'; fi
    exit 0 ;;
esac
exec pwsh -NoProfile -NonInteractive -Command -
'@
$fakeScp = @'
#!/bin/sh
# stand-in scp: copies the files into the host's folder under remote/ (C: there)
echo "$*" >> '__SCPLOG__'
dest=''; for a in "$@"; do dest="$a"; done
case "$dest" in
  *@*:*) h="${dest#*@}"; h="${h%%:*}"; p="${dest#*:}"; p="${p#C:/}"; d='__REMOTE__'/"$h/$p"; mkdir -p "$d"
         skip=0
         for a in "$@"; do
           if [ "$skip" = 1 ]; then skip=0; continue; fi
           case "$a" in -o|-i|-P|-F) skip=1; continue;; -*) continue;; esac
           [ "$a" = "$dest" ] && continue
           if [ -f "$a" ]; then cp "$a" "$d"; fi
         done ;;
esac
exit 0
'@
$sub = { param([string]$Text) $Text.Replace('__SSHLOG__', $sshLog).Replace('__SCPLOG__', $scpLog).Replace('__REMOTE__', $remote).Replace('__RESULTS__', $results).Replace("`r`n", "`n") }
[IO.File]::WriteAllText((Join-Path $base 'fakebin/ssh'), (& $sub $fakeSsh))
[IO.File]::WriteAllText((Join-Path $base 'fakebin/scp'), (& $sub $fakeScp))
[IO.File]::WriteAllText((Join-Path $base 'fakebin/icacls.exe'), "#!/bin/sh`nexit 0`n")
foreach ($f in 'ssh','scp','icacls.exe') { & chmod +x (Join-Path $base "fakebin/$f") }
$env:PATH = (Join-Path $base 'fakebin') + [IO.Path]::PathSeparator + $env:PATH
$env:NO_COLOR = '1'
$script = Join-Path $fd 'Invoke-AccessConnectorUpgrade.ps1'
$csv = Join-Path $base 'sheets/fleet.example.csv'
$xlsx = Join-Path $base 'sheets/fleet.example.xlsx'

function Invoke-Tool { param([string[]]$ToolArgs, [string]$Cwd = $fd, [switch]$NoInput, [string[]]$PwshArgs = @())
    # runs the script in its own pwsh, from $Cwd; -NoInput pipes in nothing; returns output and exit code
    Push-Location $Cwd
    try {
        $pa = @('-NoLogo', '-NoProfile') + $PwshArgs + @('-File', $script)
        $out = if ($NoInput) { '' | & pwsh @pa @ToolArgs 2>&1 } else { & pwsh @pa @ToolArgs 2>&1 }
        # the screen wraps long lines at 78 columns: match on the text with line breaks collapsed
        $t = (@($out | ForEach-Object { [string]$_ }) -join "`n")
        return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($t -replace '\s*\n\s*', ' ') }
    } finally { Pop-Location } }
function Clear-Fleet { Get-ChildItem -LiteralPath $fd -File | Where-Object { $_.Name -like 'fleet*' } | Remove-Item -Force }
function Clear-Calls { foreach ($f in $sshLog, $scpLog) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f } } }
function Get-Calls { param([string]$Log) if (Test-Path -LiteralPath $Log) { @(Get-Content -LiteralPath $Log) } else { @() } }
function Get-SentScript { param([string]$Call)
    # the script an ssh call sent with -EncodedCommand, or $null
    if ($Call -match '-EncodedCommand (\S+)$') { return [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1])) }
    return $null }
function Set-FakeSsh { param([hashtable]$Vars)
    foreach ($k in 'FAKE_SSH_FAIL_HOST','FAKE_SSH_FAIL_TEXT','FAKE_SSH_PS_ERROR') { Remove-Item -LiteralPath "Env:$k" -ErrorAction SilentlyContinue }
    foreach ($k in $Vars.Keys) { Set-Item -LiteralPath "Env:$k" -Value $Vars[$k] } }
function New-VerifyResult { param([string]$HostName, [string[]]$Services, [string]$Stopped = '', [int]$Keytab = 412, [switch]$SelfSigned, [int]$Java = 4, [int]$Flag = 4)
    # a canned -VerifyOnly result, shaped like the helper's, for the stand-in ssh to return
    $svc = @(foreach ($k in $Services) { [ordered]@{ Key = $k; Name = "Access$k"; Status = $(if ($k -eq $Stopped) { 'Stopped' } else { 'Running' }) } })
    $cert = $null
    if ($Services -contains 'KerberosAuthService') { $cert = [ordered]@{ Ok = $true; Thumbprint = 'AB12'; Subject = $(if ($SelfSigned) { 'CONNECTOR1' } else { 'connector.example.local' }); Issuer = $(if ($SelfSigned) { 'Internal Root CA 2026' } else { 'EXAMPLE-CA' }); NotAfter = '2099-01-01'; Installer = [bool]$SelfSigned; NamesServer = $true; Message = '' } }
    $st = [ordered]@{ Computer = 'CONNECTOR'; InstalledVersion = '26.10.0.0'; InstallRoot = 'C:\Program Files\Access Connector'; Services = $svc; Xml = @(); JavaCount = $Java; JavaWithFlag = $Flag; KeytabBytes = $Keytab; Cert = $cert; FreeGB = 40; RebootPending = $false; WhoAmI = 'example\administrator' }
    [IO.File]::WriteAllText((Join-Path $results "$HostName.json"), (ConvertTo-Json -InputObject ([ordered]@{ Status = 'Verified'; State = $st }) -Depth 6 -Compress)) }
$four = @('DirectorySyncService','UserAuthService','KerberosAuthService','VirtualAppService')
$three = @('DirectorySyncService','UserAuthService','VirtualAppService')

# ---------------------------------------------------------------- -ImportFleet
Invoke-TestCase 'blank -ImportFleet stops; nothing else runs' {
    $r = Invoke-Tool @('-ImportFleet', '')
    Assert-True ($r.Code -eq 1) "exit $($r.Code)"
    Assert-True ($r.Text -match '-ImportFleet needs the name of a spreadsheet file') 'message'
    Assert-True ($r.Text -notmatch 'PLAN - mode') 'an upgrade plan was shown'
}
Invoke-TestCase 'dry run writes nothing; the sheet read is named' {
    Clear-Fleet
    $r = Invoke-Tool @('-ImportFleet', $xlsx, '-DryRun')
    Assert-True ($r.Code -eq 0) "exit $($r.Code): $($r.Text)"
    Assert-True ($r.Text -match "\(xlsx, sheet 'Fleet' of 3\)") 'sheet not named'
    Assert-True (-not (Test-Path (Join-Path $fd 'fleet.psd1'))) 'a file was written'
}
Invoke-TestCase 'import writes fleet.psd1 that equals the example; audit says mode=ImportFleet' {
    Clear-Fleet
    $audit = Join-Path $base 'audit.log'
    $r = Invoke-Tool @('-ImportFleet', $csv, '-AuditLog', $audit)
    Assert-True ($r.Code -eq 0) "exit $($r.Code): $($r.Text)"
    $a = Import-PowerShellDataFile (Join-Path $fd 'fleet.psd1'); $b = Import-PowerShellDataFile (Join-Path $repo 'FleetDeploy/fleet.example.psd1')
    Assert-True ((ConvertTo-Json $a.Tenants -Depth 10 -Compress) -eq (ConvertTo-Json $b.Tenants -Depth 10 -Compress)) 'tenants differ from fleet.example.psd1'
    $line = @(Get-Content $audit | Where-Object { $_ -notmatch '^#' })[-1]
    Assert-True ($line -match ' mode=ImportFleet ' -and $line -match ' stage=import ') "audit line: $line"
}
Invoke-TestCase 'replacing needs -Yes when not interactive; two quick replacements keep two distinct copies' {
    $orig = Get-Content -Raw (Join-Path $fd 'fleet.psd1')
    $r = Invoke-Tool @('-ImportFleet', $xlsx) -NoInput
    Assert-True ($r.Code -eq 1 -and $r.Text -match 'Not interactive: add -Yes') "no -Yes: exit $($r.Code)"
    $r1 = Invoke-Tool @('-ImportFleet', $xlsx, '-Yes'); $r2 = Invoke-Tool @('-ImportFleet', $csv, '-Yes')
    Assert-True ($r1.Code -eq 0 -and $r2.Code -eq 0) 'a replacement failed'
    $baks = @(Get-ChildItem -LiteralPath $fd -Filter 'fleet.psd1.bak-*')
    Assert-True ($baks.Count -eq 2) "backups: $($baks.Count)"
    Assert-True (@($baks | Where-Object { (Get-Content -Raw $_.FullName) -eq $orig }).Count -ge 1) 'the original file is not among the copies'
}
Invoke-TestCase 'a relative -FleetConfig is resolved against the current folder; no stray temporary file' {
    Clear-Fleet
    $sheets = Join-Path $base 'sheets'
    $r = Invoke-Tool @('-ImportFleet', 'fleet.example.csv', '-FleetConfig', 'fleet.rel.psd1') -Cwd $sheets
    Assert-True ($r.Code -eq 0) "exit $($r.Code): $($r.Text)"
    Assert-True (Test-Path (Join-Path $sheets 'fleet.rel.psd1')) 'not written in the current folder'
    Assert-True (-not @(Get-ChildItem -Recurse -LiteralPath $base -Filter '*.importing').Count) 'a .importing file was left'
}
Invoke-TestCase '-FleetConfig naming a folder, or a folder that does not exist, stops with nothing written' {
    $r = Invoke-Tool @('-ImportFleet', $csv, '-FleetConfig', (Join-Path $base 'sheets'))
    Assert-True ($r.Code -eq 1 -and $r.Text -match '-FleetConfig names a folder') "folder: $($r.Text)"
    $r = Invoke-Tool @('-ImportFleet', $csv, '-FleetConfig', (Join-Path $base 'nowhere/fleet.psd1'))
    Assert-True ($r.Code -eq 1 -and $r.Text -match 'folder for the fleet file does not exist') "missing folder: $($r.Text)"
}
Invoke-TestCase 'fleet.<computer>.psd1 beside the script: warning, and the next commands name the file written' {
    Clear-Fleet
    $mine = Join-Path $fd ("fleet.$([Environment]::MachineName).psd1")
    Set-Content -LiteralPath $mine -Value "@{ Tenants = @() }"
    try {
        $r = Invoke-Tool @('-ImportFleet', $csv)
        Assert-True ($r.Code -eq 0) "exit $($r.Code)"
        Assert-True ($r.Text -match 'A run without -Fleet or -FleetConfig uses fleet\.') 'no warning'
        Assert-True ($r.Text -match "-FleetConfig '[^']*fleet\.psd1' -Mode Verify") 'next command does not name the file'
    } finally { Remove-Item -LiteralPath $mine -Force }
}
Invoke-TestCase '-Fleet with -FleetConfig is named as ignored' {
    Clear-Fleet
    $r = Invoke-Tool @('-ImportFleet', $csv, '-Fleet', 'lab', '-FleetConfig', (Join-Path $fd 'fleet.x.psd1'), '-DryRun')
    Assert-True ($r.Text -match '\[ignored\] -Fleet: -FleetConfig names the file directly') 'not named'
}

Invoke-TestCase 'replacing a fleet file names the groups it removes' {
    $one = Join-Path $base 'sheets/one-group.csv'
    (Get-Content -LiteralPath $csv) | Where-Object { $_ -notmatch 'TENANT2' } | Set-Content -LiteralPath $one -Encoding utf8BOM
    Clear-Fleet; $null = Invoke-Tool @('-ImportFleet', $csv)
    $r = Invoke-Tool @('-ImportFleet', $one, '-DryRun')
    Assert-True ($r.Text -match 'removes 1 group\(s\) the spreadsheet does not hold: TENANT2') "no note: $($r.Text)"
    $noPrefix = Join-Path $base 'sheets/no-prefix.csv'
    $rows = @(Import-Csv -LiteralPath $csv); foreach ($x in $rows) { $x.ExpectVersionPrefix = '' }
    $rows | Export-Csv -LiteralPath $noPrefix -NoTypeInformation -Encoding utf8BOM
    $r = Invoke-Tool @('-ImportFleet', $noPrefix, '-DryRun')
    Assert-True ($r.Text -match 'TENANT1: the current fleet file sets ExpectVersionPrefix, which the spreadsheet leaves blank') "no lost-setting note: $($r.Text)"
    Assert-True ($r.Text -notmatch 'sets [^.]*ForceReinstall') 'a false ForceReinstall was named'
    # a connector left out (a 'not reached' row deleted), and a group split off as TENANT1-2
    $rows = @(Import-Csv -LiteralPath $csv)
    $kept = @($rows | Where-Object { $_.Host -ne 'connector4.example.local' })
    foreach ($x in $kept) { if ($x.Host -eq 'connector2.example.local') { $x.Group = 'TENANT1-2'; $x.ExpectVersionPrefix = '' } }
    $edited = Join-Path $base 'sheets/edited.csv'; $kept | Export-Csv -LiteralPath $edited -NoTypeInformation -Encoding utf8BOM
    $r = Invoke-Tool @('-ImportFleet', $edited, '-DryRun')
    Assert-True ($r.Text -match 'removes 1 connector\(s\) the spreadsheet does not hold: connector4\.example\.local \(TENANT2\)') "no removed-connector note: $($r.Text)"
    Assert-True ($r.Text -match 'TENANT1-2: the current fleet file sets ExpectVersionPrefix') 'split-off group not compared with its entry'
}
Invoke-TestCase 'a password prompt with no terminal stops with exit 1; before it, only the SSH sign-in check reaches the connectors' {
    Clear-Fleet; $null = Invoke-Tool @('-ImportFleet', $csv)
    # empty placeholders, so the run gets past the missing-files check to the password prompt
    foreach ($f in 'Installers/Access-Connector-Installer.exe','Configs/tenant2-es-config.json','TrustedCerts/ca.pem') { $null = New-Item -ItemType File -Force -Path (Join-Path $base $f) }
    Set-FakeSsh @{}; Clear-Calls
    $r = Invoke-Tool @('-Tenant', 'TENANT2', '-DryRun') -NoInput
    Assert-True ($r.Code -eq 1) "exit $($r.Code): $($r.Text)"
    Assert-True ($r.Text -match 'SSH sign-in checked on 2 connector\(s\)') "no sign-in check line: $($r.Text)"
    Assert-True ($r.Text -match 'no terminal to type it in') 'message'
    Assert-True ($r.Text -match 'or use -Mode Stage') 'Stage not offered in SSH mode'
    $calls = @(Get-Calls $sshLog)
    Assert-True ($calls.Count -eq 2) "ssh calls: $($calls.Count)"
    foreach ($c in $calls) { Assert-True ((Get-SentScript $c) -match "^\`$ProgressPreference='SilentlyContinue';'signin-ok'$") "not the sign-in check: $c" }
    Assert-True (@(Get-Calls $scpLog).Count -eq 0) 'scp was called'
    $r = Invoke-Tool @('-Tenant', 'TENANT2', '-DryRun') -PwshArgs @('-NonInteractive')
    Assert-True ($r.Code -eq 1 -and $r.Text -match 'no terminal to type it in') "pwsh -NonInteractive: exit $($r.Code): $($r.Text)"
    $r = Invoke-Tool @('-Tenant', 'TENANT2') -PwshArgs @('-NonInteractive')
    # with no terminal either check may answer first; both must say to add -Yes
    Assert-True ($r.Code -eq 1 -and $r.Text -match '(Not interactive: add -Yes|Add -Yes to confirm without a prompt)') "YES prompt under -NonInteractive: $($r.Text)"
}

# ---------------------------------------------------------------- SSH sign-in check, first SSH step, Stage
Invoke-TestCase 'SSH sign-in check: a refused key stops the run before any prompt, with ssh''s reason, the hint and exit 1' {
    if (-not (Test-Path -LiteralPath (Join-Path $fd 'fleet.psd1'))) { $null = Invoke-Tool @('-ImportFleet', $csv) }
    $err = Join-Path $base 'signin-errors.log'; $audit = Join-Path $base 'signin-audit.log'
    Set-FakeSsh @{ FAKE_SSH_FAIL_HOST = 'connector4.example.local'; FAKE_SSH_FAIL_TEXT = 'Permission denied (publickey).' }; Clear-Calls
    try { $r = Invoke-Tool @('-Tenant', 'TENANT2', '-DryRun', '-ErrorLog', $err, '-AuditLog', $audit) -NoInput } finally { Set-FakeSsh @{} }
    Assert-True ($r.Code -eq 1) "exit $($r.Code): $($r.Text)"
    Assert-True ($r.Text -match 'cannot reach connector4\.example\.local over SSH: Permission denied \(publickey\)\. Hint: the key was not accepted: name it with -SshKey <file>, or add an IdentityFile line for these hosts to the SSH settings file \(Getting Started 4\.7\); test by hand with ssh administrator@connector4\.example\.local hostname\.') "no reason or hint: $($r.Text)"
    Assert-True ($r.Text -match 'The SSH sign-in check failed on 1 of 2 connector\(s\): connector4\.example\.local\. Nothing was changed and no password was asked\.') 'no stop message'
    Assert-True ($r.Text -match 'leave those connectors out with -Connector \(for the others: -Connector connector3\.example\.local\)') 'the others are not offered'
    Assert-True ($r.Text -notmatch 'no terminal to type it in' -and $r.Text -notmatch 'Passwords for tenant' -and $r.Text -notmatch 'SSH sign-in checked on') 'it went on to a prompt'
    Assert-True (@(Get-Calls $sshLog).Count -eq 2 -and @(Get-Calls $scpLog).Count -eq 0) 'more than the sign-in check was run'
    $el = Get-Content -Raw -LiteralPath $err
    Assert-True ($el -match '\[signin\] cannot reach connector4\.example\.local over SSH: Permission denied' -and $el -match '\[signin\] The SSH sign-in check failed') "error log: $el"
    $line = @(Get-Content $audit | Where-Object { $_ -notmatch '^#' })[-1]
    Assert-True ($line -match ' outcome=FAILED ' -and $line -match ' stage=signin ') "audit line: $line"
}
Invoke-TestCase 'SSH sign-in check comes before YES: RepairKeytab with a changed host key stops at the check, not at "add -Yes"' {
    if (-not (Test-Path -LiteralPath (Join-Path $fd 'fleet.psd1'))) { $null = Invoke-Tool @('-ImportFleet', $csv) }
    Set-FakeSsh @{ FAKE_SSH_FAIL_HOST = 'connector2.example.local'; FAKE_SSH_FAIL_TEXT = 'Host key verification failed.' }; Clear-Calls
    try { $r = Invoke-Tool @('-Mode', 'RepairKeytab', '-Tenant', 'TENANT1') -NoInput } finally { Set-FakeSsh @{} }
    Assert-True ($r.Code -eq 1) "exit $($r.Code): $($r.Text)"
    Assert-True ($r.Text -match "Host key verification failed\. Hint: the connector's host key changed: remove the old one with ssh-keygen -R connector2\.example\.local and check the new one \(Getting Started 4\.6\)\.") "no hint: $($r.Text)"
    Assert-True ($r.Text -notmatch 'Not interactive: add -Yes' -and $r.Text -notmatch 'Type YES') 'it reached the YES prompt'
    Assert-True ($r.Text -match '-Connector connector1\.example\.local\)') 'the others are not offered'
}
Invoke-TestCase 'SSH sign-in check in -Mode RepairCertificate: a changed host key stops the run before YES and the PFX password' {
    if (-not (Test-Path -LiteralPath (Join-Path $fd 'fleet.psd1'))) { $null = Invoke-Tool @('-ImportFleet', $csv) }
    $null = New-Item -ItemType File -Force -Path (Join-Path $base 'ChildCerts/connector.example.local.pfx')   # an empty placeholder
    Set-FakeSsh @{ FAKE_SSH_FAIL_HOST = 'connector2.example.local'; FAKE_SSH_FAIL_TEXT = 'Host key verification failed.' }; Clear-Calls
    try { $r = Invoke-Tool @('-Mode', 'RepairCertificate', '-Tenant', 'TENANT1') -NoInput } finally { Set-FakeSsh @{} }
    Assert-True ($r.Code -eq 1) "exit $($r.Code): $($r.Text)"
    Assert-True ($r.Text -match "cannot reach connector2\.example\.local over SSH: Host key verification failed\. Hint: the connector's host key changed: remove the old one with ssh-keygen -R connector2\.example\.local and check the new one \(Getting Started 4\.6\)\.") "no reason or hint: $($r.Text)"
    Assert-True ($r.Text -match 'The SSH sign-in check failed on 1 of 2 connector\(s\): connector2\.example\.local\.' -and $r.Text -match '-Connector connector1\.example\.local\)') 'the stop does not offer the other connector'
    Assert-True ($r.Text -notmatch 'Password for tenant' -and $r.Text -notmatch 'Not interactive: add -Yes') 'it went on to YES or the PFX password'
    $calls = @(Get-Calls $sshLog)
    Assert-True ($calls.Count -eq 2 -and @(Get-Calls $scpLog).Count -eq 0) "more than the sign-in check was run: $($calls.Count) ssh calls"
}
Invoke-TestCase 'Stage: the first SSH step names ssh''s reason and the hint; the connector that answers is staged' {
    if (-not (Test-Path -LiteralPath (Join-Path $fd 'fleet.psd1'))) { $null = Invoke-Tool @('-ImportFleet', $csv) }
    Set-FakeSsh @{ FAKE_SSH_FAIL_HOST = 'connector3.example.local'; FAKE_SSH_FAIL_TEXT = 'ssh: connect to host connector3.example.local port 22: Connection refused' }; Clear-Calls
    try { $r = Invoke-Tool @('-Mode', 'Stage', '-Tenant', 'TENANT2') } finally { Set-FakeSsh @{} }
    Assert-True ($r.Code -eq 1) "exit $($r.Code): $($r.Text)"
    Assert-True ($r.Text -match 'connector3\.example\.local: cannot reach connector3\.example\.local over SSH: ssh: connect to host connector3\.example\.local port 22: Connection refused\. Hint: port 22 is not reachable from this machine \(firewall, or OpenSSH Server not running\)\.') "first-step message: $($r.Text)"
    Assert-True ($r.Text -notmatch 'cannot reach connector3\.example\.local over SSH or create') 'the old message is shown'
    Assert-True ($r.Text -match 'connector4\.example\.local: staged in C:\\ProgramData\\AccessConnectorUpdate') "connector4 not staged: $($r.Text)"
    Assert-True ($r.Text -notmatch 'SSH sign-in checked') 'Stage ran the sign-in check'
    $stage4 = Join-Path $remote 'connector4.example.local/ProgramData/AccessConnectorUpdate'
    foreach ($f in 'Invoke-ConnectorUpgradeLocal.ps1','Access-Connector-Installer.exe','job.json','Run-Upgrade.cmd','Logs','TrustedCerts/ca.pem') { Assert-True (Test-Path -LiteralPath (Join-Path $stage4 $f)) "not on connector4: $f" }
}
Invoke-TestCase 'Stage: signed in, but the folder could not be made: the connector''s own error is named' {
    if (-not (Test-Path -LiteralPath (Join-Path $fd 'fleet.psd1'))) { $null = Invoke-Tool @('-ImportFleet', $csv) }
    Set-FakeSsh @{ FAKE_SSH_PS_ERROR = "New-Item : Access to the path 'C:\ProgramData\AccessConnectorUpdate' is denied." }; Clear-Calls
    try { $r = Invoke-Tool @('-Mode', 'Stage', '-Tenant', 'TENANT2', '-Connector', 'connector3.example.local') } finally { Set-FakeSsh @{} }
    Assert-True ($r.Code -eq 1) "exit $($r.Code): $($r.Text)"
    Assert-True ($r.Text -match "signed in to connector3\.example\.local over SSH, but could not create C:\\ProgramData\\AccessConnectorUpdate: New-Item : Access to the path 'C:\\ProgramData\\AccessConnectorUpdate' is denied\.") "message: $($r.Text)"
    Assert-True ($r.Text -notmatch 'At line:1 char:60') 'a position line is shown'
    Assert-True (@(Get-Calls $scpLog).Count -eq 0) 'scp was called'
}
Invoke-TestCase 'Stage: the folder script answers ok only when the folders are there (a file where the folder should be)' {
    if (-not (Test-Path -LiteralPath (Join-Path $fd 'fleet.psd1'))) { $null = Invoke-Tool @('-ImportFleet', $csv) }
    # A regular file named ProgramData on the stand-in C: drive: New-Item makes no folder under it,
    # with no error, whatever the account running the suite (root included).
    $root = Join-Path $remote 'connector3.example.local'
    $null = New-Item -ItemType Directory -Force -Path $root
    $pd = Join-Path $root 'ProgramData'
    if (Test-Path -LiteralPath $pd) { Remove-Item -LiteralPath $pd -Recurse -Force }
    Set-Content -LiteralPath $pd -Value 'a file where the folder should be'
    try {
        Set-FakeSsh @{}; Clear-Calls
        $r = Invoke-Tool @('-Mode', 'Stage', '-Tenant', 'TENANT2', '-Connector', 'connector3.example.local')
        Assert-True ($r.Code -eq 1) "exit $($r.Code): $($r.Text)"
        Assert-True ($r.Text -match 'signed in to connector3\.example\.local over SSH, but could not create C:\\ProgramData\\AccessConnectorUpdate: (.* / )?not made: C:\\ProgramData\\AccessConnectorUpdate, ') "message: $($r.Text)"
        Assert-True (@(Get-Calls $scpLog).Count -eq 0) 'it went on to copy files'
    } finally { Remove-Item -LiteralPath $pd -Force -ErrorAction SilentlyContinue }
}
Invoke-TestCase 'helper: -Schedule with -RunAsUser is refused before anything is asked or written' {
    $hp = Join-Path $fd 'Invoke-ConnectorUpgradeLocal.ps1'
    $err = Join-Path $base 'helper-errors.log'; $audit = Join-Path $base 'helper-audit.log'
    $out = '' | & pwsh -NoLogo -NoProfile -File $hp -Prompt -Schedule '2099-01-01 22:30' -RunAsUser 'EXAMPLE\svc-access' -AuditLog $audit -ErrorLog $err 2>&1
    $code = $LASTEXITCODE; $t = (@($out | ForEach-Object { [string]$_ }) -join "`n") -replace '\s*\n\s*', ' '
    Assert-True ($code -eq 1) "exit ${code}: $t"
    Assert-True ($t -match '-Schedule cannot be used with -RunAsUser or -RunAsTask: the run-as task starts the work now\.') "message: $t"
    Assert-True ($t -notmatch 'password') "a password was asked: $t"
    Assert-True ((Get-Content -Raw -LiteralPath $err) -match '\[ERROR\] \[args\] -Schedule cannot be used with -RunAsUser') 'error log'
    $line = @(Get-Content $audit | Where-Object { $_ -notmatch '^#' })[-1]
    Assert-True ($line -match ' outcome=FAILED ' -and $line -match ' stage=args') "audit line: $line"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fd 'secrets.dat'))) 'secrets.dat was written'
}

# ---------------------------------------------------------------- -Mode Verify exit code
Invoke-TestCase 'Verify: a red line gives exit 1 and one error-log entry naming what is red; green and yellow lines do not' {
    if (-not (Test-Path -LiteralPath (Join-Path $fd 'fleet.psd1'))) { $null = Invoke-Tool @('-ImportFleet', $csv) }
    New-VerifyResult 'connector1.example.local' $four -Keytab 6 -SelfSigned
    New-VerifyResult 'connector2.example.local' $four
    New-VerifyResult 'connector3.example.local' $three -Java 2 -Flag 1
    New-VerifyResult 'connector4.example.local' $three -Java 2 -Flag 2
    $err = Join-Path $base 'verify-errors.log'; $audit = Join-Path $base 'verify-audit.log'
    Set-FakeSsh @{}; Clear-Calls
    $r = Invoke-Tool @('-Mode', 'Verify', '-ErrorLog', $err, '-AuditLog', $audit)
    Assert-True ($r.Code -eq 1) "exit $($r.Code): $($r.Text)"
    Assert-True ($r.Text -match '\[ERROR\] TENANT1 +connector1\.example\.local v26\.10\.0\.0 \| services 4/4 up \| java flag 4/4 keytab EMPTY \(6 bytes\) \| certificate SELF-SIGNED') "connector1 line: $($r.Text)"
    Assert-True ($r.Text -match '\[OK +\] TENANT1 +connector2\.example\.local' -and $r.Text -match '\[WARN +\] TENANT2 +connector3\.example\.local' -and $r.Text -match '\[OK +\] TENANT2 +connector4\.example\.local') 'colours of the other lines'
    $entries = @(Get-Content -LiteralPath $err | Where-Object { $_ -match '\[verify\]' })
    Assert-True ($entries.Count -eq 1) "error-log entries: $($entries -join ' | ')"
    Assert-True ($entries[0] -match 'connector1\.example\.local \(TENANT1\): red in Verify: keytab EMPTY \(6 bytes\); certificate SELF-SIGNED by the installer') "entry: $($entries[0])"
    Assert-True (@([regex]::Matches($r.Text, 'red in Verify')).Count -eq 0) 'the entry was also shown on screen'
    $line = @(Get-Content $audit | Where-Object { $_ -notmatch '^#' })[-1]
    Assert-True ($line -match ' outcome=FAILED ' -and $line -match ' stage=verify ' -and $line -match 'detail="notRead=0 red=1"') "audit line: $line"
    Assert-True ($r.Text -notmatch 'SSH sign-in checked') 'Verify ran the sign-in check'
}
Invoke-TestCase 'Verify: green and yellow lines only: exit 0, nothing in the error log' {
    $err = Join-Path $base 'verify-errors-2.log'
    $r = Invoke-Tool @('-Mode', 'Verify', '-Connector', 'connector2.example.local,connector3.example.local,connector4.example.local', '-ErrorLog', $err)
    Assert-True ($r.Code -eq 0) "exit $($r.Code): $($r.Text)"
    Assert-True (-not (Test-Path -LiteralPath $err)) 'an error was logged'
}
Invoke-TestCase 'Verify: a service that is not running is red: exit 1' {
    New-VerifyResult 'connector2.example.local' $four -Stopped 'UserAuthService'
    $err = Join-Path $base 'verify-errors-3.log'
    $r = Invoke-Tool @('-Mode', 'Verify', '-Connector', 'connector2.example.local', '-ErrorLog', $err)
    Assert-True ($r.Code -eq 1) "exit $($r.Code): $($r.Text)"
    Assert-True ((Get-Content -Raw -LiteralPath $err) -match 'red in Verify: not running: UserAuth=Stopped') 'entry'
}

# ---------------------------------------------------------------- -Mode Discover
$null = Invoke-Tool @('-ImportFleet', $csv, '-Yes')   # fleet.psd1 = the example (connector1..4.example.local)
Invoke-TestCase 'Discover: an -ExportCsv folder that does not exist is made, as for the logs' {
    $out = Join-Path $base 'made/here/x.csv'
    $r = Invoke-Tool @('-Mode', 'Discover', '-Connector', 'connector1.example.local', '-ExportCsv', $out)
    Assert-True ($r.Code -eq 0) "exit $($r.Code): $($r.Text)"
    Assert-True (Test-Path -LiteralPath $out) 'draft not written'
}
Invoke-TestCase 'Discover: a -Fleet whose file does not exist stops, even with -Connector' {
    $r = Invoke-Tool @('-Mode', 'Discover', '-Fleet', 'nosuch', '-Connector', 'connector1.example.local')
    Assert-True ($r.Code -eq 1 -and $r.Text -match 'No fleet file found') "exit $($r.Code): $($r.Text)"
}
Invoke-TestCase 'Discover: -Tenant with -Connector is named as ignored; hosts keep their fleet group; unreachable host is exit 1, with the hint on screen only' {
    $out = Join-Path $base 'sheets/d1.csv'
    $r = Invoke-Tool @('-Mode', 'Discover', '-Tenant', 'TENANT2', '-Connector', 'connector1.example.local,down.example.invalid', '-ExportCsv', $out)
    Assert-True ($r.Code -eq 1) "exit $($r.Code)"
    Assert-True ($r.Text -match '\[ignored\] -Tenant: -Connector names the hosts') 'not named'
    Assert-True ($r.Text -match 'TENANT1 +connector1\.example\.local') 'connector1 not shown under TENANT1'
    Assert-True ($r.Text -match 'down\.example\.invalid: not reached: ssh: connect to host down\.example\.invalid port 22: Connection refused\. Hint: port 22 is not reachable from this machine') "no hint on screen: $($r.Text)"
    $rows = @(Import-Csv -LiteralPath $out)
    Assert-True ($rows.Count -eq 2) "rows: $($rows.Count)"
    Assert-True ($rows[0].Group -eq 'TENANT1') "group: $($rows[0].Group)"
    Assert-True ($rows[1].Group -eq '' -and $rows[1].Notes -match '^not reached: ' -and $rows[1].Notes -notmatch 'Hint:') "unreachable row: $($rows[1].Notes)"
    Assert-True ($r.Text -match 'Only part of fleet\.psd1 was read') 'no partial-read warning'
    $m = [regex]::Match($r.Text, "-ImportFleet \S+d1\.csv -FleetConfig '([^']*fleet\.discovered_\d{8}_\d{6}\.psd1)' -DryRun")
    Assert-True $m.Success 'a partial draft is not sent to a new fleet file'
    $new = $m.Groups[1].Value
    $skel = Import-PowerShellDataFile -LiteralPath $new
    $orig = Import-PowerShellDataFile -LiteralPath (Join-Path $fd 'fleet.psd1')
    Assert-True (@($skel.Tenants).Count -eq 0) 'the new file already holds groups'
    foreach ($k in 'CentralLogRoot','InstallScript','JavaPatchDir') { Assert-True ([string]$skel[$k] -eq [string]$orig[$k]) "top-level $k not carried: '$($skel[$k])' vs '$($orig[$k])'" }
    # the shown import works without -Yes (the new file holds no groups to lose) and keeps the settings
    $good = Join-Path $base 'sheets/d1-good.csv'
    # as an admin would: the stand-in ssh finds no connector here, so Services is filled in by hand
    $gr = @(Import-Csv -LiteralPath (Join-Path $base 'sheets/d1.csv') | Where-Object { $_.Group }); foreach ($x in $gr) { $x.Services = 'DirectorySyncService,UserAuthService' }
    $gr | Export-Csv -LiteralPath $good -NoTypeInformation -Encoding utf8BOM
    $i = Invoke-Tool @('-ImportFleet', $good, '-FleetConfig', $new) -NoInput
    Assert-True ($i.Code -eq 0) "import into the new file: exit $($i.Code): $($i.Text)"
    $done = Import-PowerShellDataFile -LiteralPath $new
    Assert-True (@($done.Tenants).Name -contains 'TENANT1') 'TENANT1 not written'
    Assert-True ([string]$done.JavaPatchDir -eq [string]$orig.JavaPatchDir) "JavaPatchDir lost: '$($done.JavaPatchDir)'"
}
Invoke-TestCase 'Discover: -ExportCsv naming a missing path with no extension makes it a folder' {
    $dir = Join-Path $base 'sheets/newdrafts'
    $r = Invoke-Tool @('-Mode', 'Discover', '-Connector', 'connector1.example.local', '-ExportCsv', $dir)
    Assert-True ($r.Code -eq 0) "exit $($r.Code)"
    Assert-True ((Test-Path -LiteralPath $dir -PathType Container) -and @(Get-ChildItem -LiteralPath $dir -Filter 'fleet.discovered_*.csv').Count -eq 1) 'not a folder with a dated draft'
}
Invoke-TestCase 'Discover: naming every host of the fleet file is not a partial read' {
    $out = Join-Path $base 'sheets/all-named.csv'
    $r = Invoke-Tool @('-Mode', 'Discover', '-Connector', 'connector1.example.local,connector2.example.local,connector3.example.local,connector4.example.local', '-ExportCsv', $out)
    Assert-True ($r.Code -eq 0) "exit $($r.Code)"
    Assert-True ($r.Text -notmatch 'Only part of') 'called partial'
    Assert-True ($r.Text -match "-FleetConfig '[^']*FleetDeploy/fleet\.psd1' -DryRun") 'next command does not name the fleet file'
}
Invoke-TestCase 'Discover: a full read points back at the fleet file; -ExportCsv may name a folder' {
    $dir = Join-Path $base 'sheets/drafts'; $null = New-Item -ItemType Directory -Force -Path $dir
    $r = Invoke-Tool @('-Mode', 'Discover', '-ExportCsv', $dir)
    Assert-True ($r.Code -eq 0) "exit $($r.Code): $($r.Text)"
    Assert-True (@(Get-ChildItem -LiteralPath $dir -Filter 'fleet.discovered_*.csv').Count -eq 1) 'no dated draft in the folder'
    Assert-True ($r.Text -match "-FleetConfig '[^']*FleetDeploy/fleet\.psd1' -DryRun") 'next command does not name the fleet file'
    Assert-True ($r.Text -notmatch 'Only part of') 'partial warning on a full read'
}
Invoke-TestCase 'Discover: an existing output file is never overwritten' {
    $out = Join-Path $base 'sheets/d1.csv'
    $before = Get-Content -Raw $out
    $r = Invoke-Tool @('-Mode', 'Discover', '-Connector', 'connector1.example.local', '-ExportCsv', $out)
    Assert-True ($r.Code -eq 1 -and $r.Text -match 'already exists and is not overwritten') "exit $($r.Code)"
    Assert-True ((Get-Content -Raw $out) -eq $before) 'the file changed'
}
Invoke-TestCase 'Discover: no fleet file needed when hosts are named; nothing is copied to them' {
    Clear-Fleet
    Clear-Calls
    $out = Join-Path $base 'sheets/d2.csv'
    $r = Invoke-Tool @('-Mode', 'Discover', '-Connector', 'connector9.example.local', '-ExportCsv', $out)
    Assert-True ($r.Code -eq 0) "exit $($r.Code): $($r.Text)"
    Assert-True ($r.Text -match 'none: hosts named with -Connector') 'plan'
    $calls = @(Get-Calls $sshLog)
    Assert-True ($calls.Count -eq 1 -and $calls[0] -match 'powershell -NoProfile -NonInteractive -Command -$') "ssh calls: $($calls -join ' | ')"
    Assert-True (@(Get-Calls $scpLog).Count -eq 0 -and $r.Text -notmatch 'scp') 'scp called or mentioned'
}
Invoke-TestCase 'existing modes still need a fleet file' {
    Clear-Fleet
    $r = Invoke-Tool @('-Mode', 'Verify')
    Assert-True ($r.Code -eq 1 -and $r.Text -match 'No fleet file found') "exit $($r.Code): $($r.Text)"
}

try { Remove-Item -LiteralPath $base -Recurse -Force } catch { "note: could not remove $base" }
if ($script:Fails) { 'TESTS FAILED'; exit 1 }
'ALL TESTS PASSED'
exit 0
