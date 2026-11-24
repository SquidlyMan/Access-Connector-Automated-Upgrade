# Offline tests of Prerequisites/Install-OpenSSHServer.ps1: its key, -AllowFrom, sshd_config,
# firewall and default-shell steps, run as functions against stand-ins for the Windows-only
# commands (firewall cmdlets, ACLs, the registry, sshd -t), with real files in a temporary
# folder. The script's functions and script-level variables are loaded from its text (everything
# before its main block), so its main block never runs. The public keys are made up from a
# seeded random number generator, so every run sees the same keys. No server, domain controller
# or share is contacted, and nothing outside the temporary folder is written.
#   pwsh -NoLogo -NoProfile -File tools/test_prereq_openssh.ps1
# Prints PASS <name> / FAIL <name>: <why> per case, then ALL TESTS PASSED or TESTS FAILED (exit 0/1).
$repo = if ($env:FLEET_REPO) { $env:FLEET_REPO } else { Split-Path -Parent $PSScriptRoot }
$Script = Join-Path $repo 'Prerequisites/Install-OpenSSHServer.ps1'
if (-not (Test-Path -LiteralPath $Script -PathType Leaf)) { "FAIL load: $Script not found"; 'TESTS FAILED'; exit 1 }
$work = Join-Path ([IO.Path]::GetTempPath()) ('acu-test-openssh-' + $PID)
$null = New-Item -ItemType Directory -Force -Path $work

# ---- the functions and script-level variables of the script (everything before its main block)
$text = [System.IO.File]::ReadAllText($Script)
$start = $text.IndexOf("`$ErrorActionPreference = 'Stop'")
$end = $text.IndexOf('# ====================================================================== main')
if ($start -lt 0 -or $end -le $start) { "FAIL load: the main block of $Script was not found"; 'TESTS FAILED'; exit 1 }
$body = $text.Substring($start, $end - $start)
$body = $body -replace '\$script:Cmdlet\s+=\s+\$PSCmdlet', '$script:Cmdlet = $null'
$body = $body -replace "\`$ErrorActionPreference = 'Stop'", "`$ErrorActionPreference = 'Stop'; `$PublicKey = @(); `$AllowFrom = @(); `$PublicKeyFile = @()"
. ([scriptblock]::Create($body))

# ---- made-up public keys (random ed25519 data, seeded) and a made-up private-key text
$script:Rng = New-Object System.Random 20261123
function New-TestKey { param([string]$Comment = 'test@example')
    $name = [System.Text.Encoding]::ASCII.GetBytes('ssh-ed25519')
    $pk = New-Object byte[] 32; $script:Rng.NextBytes($pk)
    $ms = New-Object System.IO.MemoryStream
    foreach ($f in @($name, $pk)) { $len = [BitConverter]::GetBytes([int]$f.Length); [Array]::Reverse($len); $ms.Write($len, 0, 4); $ms.Write($f, 0, $f.Length) }
    $line = 'ssh-ed25519 ' + [Convert]::ToBase64String($ms.ToArray())
    if ($Comment) { $line += ' ' + $Comment }
    return $line }
function New-FakePrivateKey {
    $b = New-Object byte[] 300; $script:Rng.NextBytes($b)
    $s = [Convert]::ToBase64String($b)
    $lines = @('-----BEGIN OPENSSH PRIVATE KEY-----')
    for ($i = 0; $i -lt $s.Length; $i += 70) { $lines += $s.Substring($i, [Math]::Min(70, $s.Length - $i)) }
    $lines += '-----END OPENSSH PRIVATE KEY-----'
    return $lines }
# ---- stand-ins for the Windows-only commands. A test sets $global:FW (rules) etc.
function Get-AclProblem { param($Path) return $null }
function Set-AdminOnlyAcl { param($Path) return $null }
function Initialize-SshFolder { }
function Confirm-Change { param($Target, $Action) if ($global:Decline -and $Action -like $global:Decline) { return $false }; if ($script:IsWhatIf) { return $false }; return $true }
# firewall: $global:FW = @{ name = @{ Name; DisplayName; Enabled; Direction; Action; RA; Protocol; Port; Program; Service; Package; Active } }
function Get-NetFirewallRule { [CmdletBinding()] param($Name, $PolicyStore, [Parameter(ValueFromPipeline)]$InputObject)
  process {
    if ($InputObject) { $r = $global:FW[$InputObject.InstanceID]; if ($r -and ($PolicyStore -ne 'ActiveStore' -or $r.Active)) { return (New-RuleObj $r) }; return }
    $out = @($global:FW.Values | Where-Object { $_.Name -like $Name })
    if ($PolicyStore -eq 'ActiveStore') { $out = @($out | Where-Object { $_.Active }); if (-not $out.Count) { throw "No MSFT_NetFirewallRule objects found with property 'InstanceID' equal to '$Name'." } }
    foreach ($r in $out) { New-RuleObj $r } } }
function New-RuleObj { param($r) [pscustomobject]@{ Name = $r.Name; InstanceID = $r.Name; DisplayName = $r.DisplayName; Enabled = $r.Enabled; Direction = $r.Direction; Action = $r.Action } }
function Get-NetFirewallProfile { [CmdletBinding()] param($PolicyStore) @($global:Profiles) }
function Get-NetFirewallAddressFilter { [CmdletBinding()] param([Parameter(ValueFromPipeline)]$InputObject) process { [pscustomobject]@{ RemoteAddress = $global:FW[$InputObject.Name].RA } } }
function Get-NetFirewallApplicationFilter { [CmdletBinding()] param([Parameter(ValueFromPipeline)]$InputObject) process { $r = $global:FW[$InputObject.Name]; [pscustomobject]@{ Program = $r.Program; Package = $r.Package } } }
function Get-NetFirewallServiceFilter { [CmdletBinding()] param([Parameter(ValueFromPipeline)]$InputObject) process { $r = $global:FW[$InputObject.Name]; [pscustomobject]@{ Service = $r.Service } } }
function Get-NetFirewallPortFilter { [CmdletBinding()] param([switch]$All, $PolicyStore)
  if ($global:PortFilterThrows) { throw 'The RPC server is unavailable.' }
  foreach ($r in @($global:FW.Values | Where-Object { $_.Active })) { [pscustomobject]@{ InstanceID = $r.Name; Protocol = $r.Protocol; LocalPort = $r.Port } } }
function Enable-NetFirewallRule { [CmdletBinding(SupportsShouldProcess = $true)] param($Name) if ($global:FailEnable) { throw 'Access is denied.' }; $global:FW[$Name].Enabled = 'True'; if (-not $global:GpoIgnoresLocal) { $global:FW[$Name].Active = $true }; $global:FwLog.Add("ENABLED $Name") }
function Set-NetFirewallRule { [CmdletBinding(SupportsShouldProcess = $true)] param($Name, $RemoteAddress) if ($global:FailSet) { throw 'The parameter is incorrect.' }; $global:FW[$Name].RA = @($RemoteAddress); $global:FwLog.Add("SCOPED $Name " + ($RemoteAddress -join ',')) }
function New-NetFirewallRule { [CmdletBinding(SupportsShouldProcess = $true)] param($Name, $DisplayName, $Enabled, $Direction, $Protocol, $LocalPort, $Action, $Profile, $RemoteAddress)
  $ra = @('Any'); if ($RemoteAddress) { $ra = @($RemoteAddress) }
  $global:FW[$Name] = [pscustomobject]@{ Name = $Name; DisplayName = $DisplayName; Enabled = $Enabled; Direction = 'Inbound'; Action = 'Allow'; RA = $ra; Protocol = 'TCP'; Port = '22'; Program = 'Any'; Service = 'Any'; Package = ''; Active = $true }
  $global:FwLog.Add("CREATED $Name from " + ($ra -join ',')) }
function New-FwRule { param($Name, $Enabled = 'True', $RA = @('Any'), $Protocol = 'TCP', $Port = '22', $Program = 'Any', $Service = 'Any', $Package = '', $Active = $true, $Direction = 'Inbound', $Action = 'Allow')
  [pscustomobject]@{ Name = $Name; DisplayName = "Rule $Name"; Enabled = $Enabled; Direction = $Direction; Action = $Action; RA = @($RA); Protocol = $Protocol; Port = $Port; Program = $Program; Service = $Service; Package = $Package; Active = $Active } }
function Reset-Run { $script:Problems.Clear(); $script:Warnings.Clear(); $global:FwLog = New-Object System.Collections.Generic.List[string]; $global:Decline = $null; $global:FailSet = $false; $global:FailEnable = $false; $global:PortFilterThrows = $false; $script:IsWhatIf = $false; $script:Pending = $false; $script:R.Firewall = '' }
$env:NO_COLOR = '1'; Initialize-UiStyle
$global:Pass = 0; $global:Fail = 0
function Check { param([string]$Name, [bool]$Ok, [string]$Detail = '') if ($Ok) { $global:Pass++; "PASS $Name" } else { $global:Fail++; "FAIL ${Name}: $Detail" } }
$dir = $work; $script:SshDir = $dir; $script:KeysFile = Join-Path $dir 'administrators_authorized_keys'
$script:ConfigFile = Join-Path $dir 'sshd_config'; $script:BannerFile = Join-Path $dir 'banner.txt'
$env:ProgramData = 'C:\ProgramData'; $env:SystemRoot = 'C:\Windows'
$script:SshdExe = 'C:\Windows\System32\OpenSSH\sshd.exe'
$k1 = New-TestKey 'one@example'; $k2 = New-TestKey 'two@example'; $k3 = New-TestKey ''; $k4 = New-TestKey 'four@example'
$b1 = ($k1 -split ' ')[1]
function Rec { param($l) $r = ConvertTo-KeyRecord $l; if ($r) { 'ok:' + $r.Options } else { 'no' } }

# ---- F1 option grammar and comment lines
Check 'commented key refused' ((Rec "# $k1 revoked") -eq 'no')
Check 'label in front refused' ((Rec "Here is my key: $k1") -eq 'no')
Check 'unknown option refused' ((Rec "no-such-option $k1") -eq 'no')
Check 'garbage word refused' ((Rec "garbage $k1") -eq 'no')
Check 'from= accepted' ((Rec "from=""10.0.0.0/24"" $k1") -eq 'ok:from="10.0.0.0/24"')
Check 'command with quoted space accepted' ((Rec "command=""echo hi there"" $k1") -eq 'ok:command="echo hi there"')
Check 'flag list accepted' ((Rec "no-pty,no-port-forwarding,no-X11-forwarding $k1") -eq 'ok:no-pty,no-port-forwarding,no-X11-forwarding')
Check 'restrict,pty accepted' ((Rec "restrict,pty $k1") -eq 'ok:restrict,pty')
Check 'upper case name accepted' ((Rec "NO-PTY $k1") -eq 'ok:NO-PTY')
Check 'no-restrict refused' ((Rec "no-restrict $k1") -eq 'no')
Check 'unquoted value refused' ((Rec "from=10.0.0.5 $k1") -eq 'no')
Check 'trailing comma refused' ((Rec "no-pty, $k1") -eq 'no')
Check 'escaped quote accepted' ((Rec "command=""echo \""a b\"""" $k1") -like 'ok:*')
Check 'open quote refused' ((Rec "from=""10.0.0.5 $k1") -eq 'no')
Check 'ptyx refused' ((Rec "ptyx $k1") -eq 'no')
Check 'plain key accepted' ((Rec $k1) -eq 'ok:')
Check 'tab separator accepted' ((Rec ($k1 -replace ' ', "`t")) -like 'ok:*')
Check 'NBSP separator refused as read' ($null -eq (ConvertTo-KeyRecord ($k1 -replace ' ', [string][char]0xA0) -AsRead))
$PublicKey = @("Here is my key: $k1"); $PublicKeyFile = @()
$ki = Get-InputKeys
Check 'input with label refused' ($ki.Errors.Count -eq 1 -and $ki.Keys.Count -eq 0) ($ki.Errors -join '|')
Check 'error names the cause, not the key' ($ki.Errors[0] -match 'text in front of the ssh-ed25519 key' -and -not $ki.Errors[0].Contains($b1)) $ki.Errors[0]
$PublicKey = @(($k1 -replace ' ', [string][char]0xA0))
$ki = Get-InputKeys
Check 'NBSP in a pasted key becomes a space' ($ki.Errors.Count -eq 0 -and $ki.Keys.Count -eq 1 -and $ki.Keys[0].Line -eq $k1) ($ki.Errors -join '|')
Reset-Run
[System.IO.File]::WriteAllText($script:KeysFile, "# $k1 revoked`r`n")
$script:InputKeys = @(); Add-AdminKeys *> $null
Check 'commented-only file counts 0 keys' ($script:ValidKeys -eq 0) "ValidKeys=$($script:ValidKeys)"
Reset-Run; $PublicKey = @($k1); $script:InputKeys = @((Get-InputKeys).Keys); Add-AdminKeys *> $null
$lines = @(Get-Content $script:KeysFile)
Check 'same key given again is added' ($script:R.KeysAdded -eq 1 -and $script:ValidKeys -eq 1 -and $lines.Count -eq 2 -and $lines[1] -eq $k1) "added=$($script:R.KeysAdded) valid=$($script:ValidKeys) lines=$($lines.Count)"
Reset-Run
[System.IO.File]::WriteAllText($script:KeysFile, "garbage $k1`r`n")
$script:InputKeys = @(); Add-AdminKeys *> $null
Check 'garbage-prefixed line counts 0 and is named' ($script:ValidKeys -eq 0 -and @($script:Warnings | Where-Object { $_ -match 'line 1: a key that sshd does not use' }).Count -eq 1) ($script:Warnings -join '|')
Reset-Run
[System.IO.File]::WriteAllText($script:KeysFile, "from=""10.0.0.5"" $k1`r`n")
$script:R.KeysAdded = 0; $script:InputKeys = @((Get-InputKeys).Keys); $out = Add-AdminKeys 6>&1 | Out-String
Check 'key with valid options is present, not added again' ($script:R.KeysAdded -eq 0 -and $script:ValidKeys -eq 1 -and $out -match 'Already in the file, with options in front') "added=$($script:R.KeysAdded) valid=$($script:ValidKeys)"

# ---- F2 UTF-16 and byte-order mark files
Reset-Run; $script:KeysUnreadable = ''
[System.IO.File]::WriteAllText($script:KeysFile, $k1 + "`r`n", [System.Text.Encoding]::Unicode)
$global:Decline = 'Save again*'; $script:InputKeys = @(); Add-AdminKeys *> $null
Check 'UTF-16, rewrite declined: 0 keys, said why' ($script:ValidKeys -eq 0 -and $script:KeysUnreadable -eq 'UTF-16' -and @($script:Warnings | Where-Object { $_ -match 'cannot be read by sshd while the file is saved as UTF-16' }).Count -eq 1) "valid=$($script:ValidKeys) w=$($script:Warnings -join '|')"
[System.IO.File]::WriteAllText($script:ConfigFile, "#PasswordAuthentication yes`nMatch Group administrators`n       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys`n")
function Test-SshdConfig { param($Candidate) [pscustomobject]@{ State = 'passed'; Text = '' } }
$KeepPasswordSignIn = $false; $Banner = $false; $LoginAlert = $false; $script:KeyFileOk = $true; $global:Decline = $null
Update-SshdConfig *> $null
Check 'UTF-16 not rewritten: password stays on' ($script:R.PasswordSignIn -like 'on (*saved as UTF-16*' -and -not ((Get-Content $script:ConfigFile) -contains 'PasswordAuthentication no')) $script:R.PasswordSignIn
Reset-Run; $script:KeysUnreadable = ''
[System.IO.File]::WriteAllText($script:KeysFile, $k1 + "`r`n", [System.Text.Encoding]::Unicode)
$savedWrite = ${function:Write-TextLines}
function Write-TextLines { throw 'Access to the path is denied.' }
Add-AdminKeys *> $null
Set-Item -Path function:Write-TextLines -Value $savedWrite
Check 'UTF-16, write fails: problem and 0 keys' ($script:Problems.Count -eq 1 -and $script:ValidKeys -eq 0) "p=$($script:Problems.Count) valid=$($script:ValidKeys)"
Reset-Run
$bom = [byte[]](0xEF, 0xBB, 0xBF) + [System.Text.Encoding]::ASCII.GetBytes($k1 + "`r`n" + $k2 + "`r`n")
[System.IO.File]::WriteAllBytes($script:KeysFile, $bom)
$global:Decline = 'Save again*'; $script:InputKeys = @(); Add-AdminKeys *> $null
Check 'BOM, rewrite declined: first key does not count' ($script:ValidKeys -eq 1 -and $script:KeysUnreadable -eq 'UTF-8 BOM') "valid=$($script:ValidKeys)"
Reset-Run; $script:KeysUnreadable = ''
[System.IO.File]::WriteAllBytes($script:KeysFile, $bom); Add-AdminKeys *> $null
$b = [System.IO.File]::ReadAllBytes($script:KeysFile)
Check 'BOM, rewrite done: both keys count, no BOM' ($script:ValidKeys -eq 2 -and $b[0] -ne 0xEF -and -not $script:KeysUnreadable) "valid=$($script:ValidKeys)"
Reset-Run; $script:KeysUnreadable = ''; $script:IsWhatIf = $true
[System.IO.File]::WriteAllText($script:KeysFile, $k1 + "`r`n", [System.Text.Encoding]::Unicode)
Add-AdminKeys *> $null
Check 'UTF-16 under -WhatIf: counted as it would be' ($script:ValidKeys -eq 1 -and -not $script:KeysUnreadable) "valid=$($script:ValidKeys)"

# ---- key file kept when the install is pending
Reset-Run; $script:KeysUnreadable = ''; $script:Pending = $true
[System.IO.File]::WriteAllText($script:KeysFile, $k1 + "`r`n")
$PublicKey = @($k2); $script:InputKeys = @((Get-InputKeys).Keys); Add-AdminKeys *> $null
$lines = @(Get-Content $script:KeysFile)
Check 'pending install: existing key kept, new one added' ($lines.Count -eq 2 -and $lines[0] -eq $k1 -and $lines[1] -eq $k2 -and $script:ValidKeys -eq 2) "lines=$($lines.Count) valid=$($script:ValidKeys)"
$script:Pending = $false

# ---- F7 keys run together
$script:IsWhatIf = $false; $script:Warnings.Clear()
$PublicKey = @("$k1 $k2"); $ki = Get-InputKeys
Check 'two keys with comments split' ($ki.Errors.Count -eq 0 -and $ki.Keys.Count -eq 2 -and $ki.Keys[0].Comment -eq 'one@example' -and $ki.Keys[1].Comment -eq 'two@example') ($ki.Errors -join '|')
$PublicKey = @("$k3 $k2 $k4"); $ki = Get-InputKeys
Check 'three keys, first without comment' ($ki.Errors.Count -eq 0 -and $ki.Keys.Count -eq 3) ($ki.Errors -join '|')
$PublicKey = @("from=""10.0.0.5"" $k1 $k2"); $ki = Get-InputKeys
Check 'options of the first key stay with it' ($ki.Keys.Count -eq 2 -and $ki.Keys[0].Options -eq 'from="10.0.0.5"' -and $ki.Keys[1].Options -eq '') ($ki.Errors -join '|')
$PublicKey = @("$k1 from=""10.0.0.6"" $k2"); $ki = Get-InputKeys
Check 'possible options of a later key: refused' ($ki.Errors.Count -eq 1 -and $ki.Keys.Count -eq 0 -and $ki.Errors[0] -match 'run together') ($ki.Errors -join '|')
$PublicKey = @("$k1 no-pty $k2"); $ki = Get-InputKeys
Check 'flag word before a later key: refused' ($ki.Errors.Count -eq 1) ($ki.Errors -join '|')
$PublicKey = @("$k1,$k2"); $ki = Get-InputKeys
Check 'comma-joined still split' ($ki.Errors.Count -eq 0 -and $ki.Keys.Count -eq 2) ($ki.Errors -join '|')
$PublicKey = @("$k1 my ssh-rsa key"); $ki = Get-InputKeys
Check 'key type word in a comment: not split' ($ki.Errors.Count -eq 0 -and $ki.Keys.Count -eq 1 -and $ki.Keys[0].Comment -eq 'one@example my ssh-rsa key') ($ki.Errors -join '|')
$rec = ConvertTo-KeyRecord ($k1 + ' ' + ('x' * 80))
Check 'long comment cut in Format-Key' ((Format-Key $rec).Length -le 103 -and (Format-Key $rec).EndsWith('...')) (Format-Key $rec)

# ---- F4 -AllowFrom never echoes key text
$AllowFrom = @(New-FakePrivateKey); $ni = Get-InputNetworks
$body = @($AllowFrom | Where-Object { $_ -notmatch '^-----' })
$leak = @($ni.Errors | Where-Object { $e = $_; @($body | Where-Object { $e.Contains($_) -or $e.Contains($_.Substring(0, 12)) }).Count -gt 0 }).Count
Check 'private key: one error, nothing echoed' ($ni.Errors.Count -eq 1 -and $leak -eq 0 -and $ni.Errors[0] -match 'PRIVATE key') ($ni.Errors -join '|')
$AllowFrom = @($body); $ni = Get-InputNetworks
$leak = @($ni.Errors | Where-Object { $e = $_; @($body | Where-Object { $e.Contains($_.Substring(0, 12)) }).Count -gt 0 }).Count
Check 'private key body without its markers: not echoed' ($ni.Errors.Count -eq $body.Count -and $leak -eq 0) ($ni.Errors[0])
$AllowFrom = @($k1); $ni = Get-InputNetworks
Check 'public key in -AllowFrom: named as such' ($ni.Errors.Count -eq 1 -and $ni.Errors[0] -match 'is a public key' -and -not $ni.Errors[0].Contains($b1)) ($ni.Errors -join '|')
$AllowFrom = @('connector1.example.local', 'server01', '10.0.0.0/33', '10.0.0.5/24', '10.0.0.0/24'); $ni = Get-InputNetworks
Check 'host name with dots shown' (@($ni.Errors | Where-Object { $_ -like '-AllowFrom connector1.example.local:*' }).Count -eq 1) ($ni.Errors -join '|')
Check 'single word not shown' (@($ni.Errors | Where-Object { $_ -like '-AllowFrom value 2 (8 characters, not shown)*' }).Count -eq 1) ($ni.Errors -join '|')
Check 'bad prefix shown' (@($ni.Errors | Where-Object { $_ -like '-AllowFrom 10.0.0.0/33:*' }).Count -eq 1) ($ni.Errors -join '|')
Check 'host bits message kept' (@($ni.Errors | Where-Object { $_ -like '*bits set past /24*' }).Count -eq 1 -and $ni.Specs.Count -eq 1) ($ni.Errors -join '|')
$AllowFrom = @('10.0.0.0/24,fd00::/64; 10.0.1.5'); $ni = Get-InputNetworks
Check 'good list still parsed' ($ni.Errors.Count -eq 0 -and $ni.Specs.Count -eq 3) ($ni.Errors -join '|')

# ---- F5 sshd_config gate
function Run-Config { param([string]$Cfg)
    Reset-Run; $script:ConfigChanged = $false
    [System.IO.File]::WriteAllText($script:ConfigFile, $Cfg)
    $script:ValidKeys = 1; $script:KeyFileOk = $true; $script:KeysUnreadable = ''
    Update-SshdConfig *> $null
    return ((Get-Content $script:ConfigFile) -contains 'PasswordAuthentication no') }
$base = "#PasswordAuthentication yes`nSubsystem sftp sftp-server.exe`n"
$adm = "Match Group administrators`n       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys`n"
Check 'Windows default: password off' (Run-Config ($base + $adm)) $script:R.PasswordSignIn
$off = Run-Config ($base + $adm + "       PubkeyAuthentication no`n")
$ln = [regex]::Match($script:R.PasswordSignIn, 'PubkeyAuthentication no \(line (\d+)\)').Groups[1].Value
Check 'admin block PubkeyAuthentication no: kept on, line named in the written file' ((-not $off) -and $ln -and ((Get-Content $script:ConfigFile)[[int]$ln - 1].Trim() -eq 'PubkeyAuthentication no')) $script:R.PasswordSignIn
Check 'Match Group sshusers: kept on' (-not (Run-Config ($base + "Match Group sshusers`n  AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys`n"))) $script:R.PasswordSignIn
Check 'other key file path: kept on' (-not (Run-Config ($base + "Match Group administrators`n  AuthorizedKeysFile D:/other/administrators_authorized_keys`n")) -and $script:R.PasswordSignIn -match 'reads D:/other') $script:R.PasswordSignIn
Check 'admin AuthenticationMethods publickey,password: kept on' (-not (Run-Config ($base + $adm + "       AuthenticationMethods publickey,password`n"))) $script:R.PasswordSignIn
Check 'global AuthenticationMethods publickey,password: kept on' (-not (Run-Config ("AuthenticationMethods publickey,password`n" + $base + $adm))) $script:R.PasswordSignIn
Check 'admin AuthenticationMethods publickey: password off' (Run-Config ($base + $adm + "       AuthenticationMethods publickey`n")) $script:R.PasswordSignIn
Check 'Match with extra criteria: kept on' (-not (Run-Config ($base + "Match Group administrators Address 10.0.0.0/8`n  AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys`n")) -and $script:R.PasswordSignIn -match 'criteria besides') $script:R.PasswordSignIn
Check 'Match All with the admin file: password off' (Run-Config ($base + "Match All`n  AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys`n"))
Check 'quoted group and C:/ProgramData path: password off' (Run-Config ($base + "Match Group ""administrators""`n  AuthorizedKeysFile ""C:/ProgramData/ssh/administrators_authorized_keys""`n"))
Check 'global AuthorizedKeysFile admin file, no Match: password off' (Run-Config ("AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys`n" + $base))
Check 'global PubkeyAuthentication no is set to yes, then off' (Run-Config ("PubkeyAuthentication no`n" + $base + $adm))
$null = Run-Config ($base + "Match User backup`n  PasswordAuthentication yes`n" + $adm)
$ln = [regex]::Match($script:R.PasswordSignIn, '^off, but on for the accounts selected by Match User backup \(line (\d+)\)$').Groups[1].Value
Check 'Match block with PasswordAuthentication yes reported as on' ($ln -and ((Get-Content $script:ConfigFile)[[int]$ln - 1].Trim() -eq 'PasswordAuthentication yes')) $script:R.PasswordSignIn
Check 'no Match block at all: kept on' (-not (Run-Config $base) -and $script:R.PasswordSignIn -match 'no Match Group administrators block') $script:R.PasswordSignIn

# ---- F3 firewall left alone without -AllowFrom; limited before enabled with it
$global:Profiles = @([pscustomobject]@{ Name = 'Domain'; Enabled = 'True'; AllowLocalFirewallRules = 'NotConfigured' })
$global:GpoIgnoresLocal = $false
Reset-Run; $script:Specs = @()
$global:FW = @{ 'OpenSSH-Server-In-TCP' = (New-FwRule 'OpenSSH-Server-In-TCP' -Enabled 'False' -Active $false); 'SSH-Jump' = (New-FwRule 'SSH-Jump' -RA @('192.0.2.10')) }
Set-SshFirewallScope *> $null
Check 'no -AllowFrom: disabled rule stays disabled' ($global:FwLog.Count -eq 0 -and $global:FW['OpenSSH-Server-In-TCP'].Enabled -eq 'False') ($global:FwLog -join '; ')
Check 'no -AllowFrom: other rule reported, no problem, no blocked warning' ($script:Problems.Count -eq 0 -and $script:R.Firewall -match 'TCP 22 from 192.0.2.10 \("Rule SSH-Jump"\)' -and @($script:Warnings | Where-Object { $_ -match 'most likely blocked' }).Count -eq 0) ($script:R.Firewall + ' | ' + ($script:Warnings -join '|'))
Reset-Run; $script:Specs = @()
$global:FW = @{ 'OpenSSH-Server-In-TCP' = (New-FwRule 'OpenSSH-Server-In-TCP' -Enabled 'False' -Active $false) }
Set-SshFirewallScope *> $null
Check 'no -AllowFrom, nothing lets TCP 22 in: warning only' ($global:FwLog.Count -eq 0 -and $script:Problems.Count -eq 0 -and @($script:Warnings | Where-Object { $_ -match 'most likely blocked' }).Count -eq 1) ($script:Warnings -join '|')
Reset-Run; $script:Specs = @(); $global:FW = @{}
Set-SshFirewallScope *> $null
Check 'no -AllowFrom, no rule: none created' ($global:FwLog.Count -eq 0 -and $global:FW.Count -eq 0 -and $script:Problems.Count -eq 0) ($global:FwLog -join '; ')
Reset-Run; $script:Specs = @(); $global:FW = @{ 'OpenSSH-Server-In-TCP' = (New-FwRule 'OpenSSH-Server-In-TCP') }
Set-SshFirewallScope *> $null
Check 'no -AllowFrom, rule in force: summary, nothing changed' ($global:FwLog.Count -eq 0 -and $script:R.Firewall -eq 'TCP 22 from any address (OpenSSH-Server-In-TCP)' -and $script:Warnings.Count -eq 0) ($script:R.Firewall)
Reset-Run; $script:Specs = @(ConvertTo-NetSpec '10.0.0.0/24'); $global:FailSet = $true
$global:FW = @{ 'OpenSSH-Server-In-TCP' = (New-FwRule 'OpenSSH-Server-In-TCP' -Enabled 'False' -Active $false) }
Set-SshFirewallScope *> $null
Check '-AllowFrom, limit fails: rule left disabled, one problem' ($global:FwLog.Count -eq 0 -and $global:FW['OpenSSH-Server-In-TCP'].Enabled -eq 'False' -and $script:Problems.Count -eq 1) ("log=" + ($global:FwLog -join '; ') + " p=" + ($script:Problems -join '|'))
Reset-Run; $script:Specs = @(ConvertTo-NetSpec '10.0.0.0/24')
$global:FW = @{ 'OpenSSH-Server-In-TCP' = (New-FwRule 'OpenSSH-Server-In-TCP' -Enabled 'False' -Active $false) }
Set-SshFirewallScope *> $null
Check '-AllowFrom: limited first, then enabled' (($global:FwLog -join '; ') -eq 'SCOPED OpenSSH-Server-In-TCP 10.0.0.0/24; ENABLED OpenSSH-Server-In-TCP' -and $script:Problems.Count -eq 0 -and $script:R.Firewall -eq 'TCP 22 from 10.0.0.0/24 (OpenSSH-Server-In-TCP)') (($global:FwLog -join '; ') + ' | ' + $script:R.Firewall + ' | ' + ($script:Problems -join '|'))
Reset-Run; $script:Specs = @(ConvertTo-NetSpec '10.0.0.0/24'); $global:FW = @{}
Set-SshFirewallScope *> $null
Check '-AllowFrom, no rule: created already limited' (($global:FwLog -join '; ') -eq 'CREATED OpenSSH-Server-In-TCP from 10.0.0.0/24' -and $script:Problems.Count -eq 0) ($global:FwLog -join '; ')
Reset-Run; $script:Specs = @(ConvertTo-NetSpec '10.0.0.0/24'); $global:FailSet = $true
$global:FW = @{ 'OpenSSH-Server-In-TCP' = (New-FwRule 'OpenSSH-Server-In-TCP') }
Set-SshFirewallScope *> $null
Check '-AllowFrom, enabled wide rule, limit fails: one problem, rule untouched' ($script:Problems.Count -eq 1 -and $script:Problems[0] -match 'still lets TCP 22 in from any address' -and $global:FW['OpenSSH-Server-In-TCP'].Enabled -eq 'True') ($script:Problems -join '|')
Reset-Run; $script:Specs = @(ConvertTo-NetSpec '10.0.0.0/24'); $script:IsWhatIf = $true
$global:FW = @{ 'OpenSSH-Server-In-TCP' = (New-FwRule 'OpenSSH-Server-In-TCP' -Enabled 'False' -Active $false) }
Set-SshFirewallScope *> $null
Check '-AllowFrom -WhatIf: nothing changed, would be' ($global:FwLog.Count -eq 0 -and $script:R.Firewall -eq 'would be TCP 22 from 10.0.0.0/24' -and $script:Problems.Count -eq 0) $script:R.Firewall
$script:IsWhatIf = $false

# ---- F6 Group Policy that ignores local rules
$global:Profiles = @('Domain','Private','Public' | ForEach-Object { [pscustomobject]@{ Name = $_; Enabled = 'True'; AllowLocalFirewallRules = 'False' } })
$global:GpoIgnoresLocal = $true
Reset-Run; $script:Specs = @(); $global:FW = @{ 'OpenSSH-Server-In-TCP' = (New-FwRule 'OpenSSH-Server-In-TCP' -Active $false) }
Set-SshFirewallScope *> $null
Check 'no -AllowFrom: warnings, no problem' ($script:Problems.Count -eq 0 -and @($script:Warnings | Where-Object { $_ -match 'is not in the policy Windows enforces' }).Count -eq 1) ("p=" + ($script:Problems -join '|') + " w=" + ($script:Warnings -join '|'))
Reset-Run; $script:Specs = @()
$global:FW = @{ 'OpenSSH-Server-In-TCP' = (New-FwRule 'OpenSSH-Server-In-TCP' -Active $false); 'gpo-ssh' = (New-FwRule 'gpo-ssh' -RA @('10.0.0.0/255.255.255.0')) }
Set-SshFirewallScope *> $null
Check 'policy rule lets TCP 22 in: named, no blocked warning' ($script:Problems.Count -eq 0 -and $script:R.Firewall -match 'TCP 22 from 10.0.0.0/24 \("Rule gpo-ssh"\)' -and @($script:Warnings | Where-Object { $_ -match 'most likely blocked' }).Count -eq 0) ($script:R.Firewall)
Reset-Run; $script:Specs = @(ConvertTo-NetSpec '10.0.0.0/24'); $global:FW = @{ 'OpenSSH-Server-In-TCP' = (New-FwRule 'OpenSSH-Server-In-TCP' -Active $false) }
Set-SshFirewallScope *> $null
Check 'with -AllowFrom: one problem, the limit is not in force' ($script:Problems.Count -eq 1 -and $script:Problems[0] -match 'limit to 10.0.0.0/24 is not in force. Set it in that policy') ($script:Problems -join '|')
$global:GpoIgnoresLocal = $false
$global:Profiles = @([pscustomobject]@{ Name = 'Domain'; Enabled = 'True'; AllowLocalFirewallRules = 'NotConfigured' })

# ---- F9 other rules of any protocol and port
function Run-Other { param($Other)
    Reset-Run; $script:Specs = @(ConvertTo-NetSpec '10.0.0.0/24')
    $global:FW = @{ 'OpenSSH-Server-In-TCP' = (New-FwRule 'OpenSSH-Server-In-TCP' -RA @('10.0.0.0/24')); 'other' = $Other }
    Set-SshFirewallScope *> $null
    return (@($script:Warnings | Where-Object { $_ -match 'also lets TCP 22 in from any address' }).Count) }
Check 'protocol Any, port Any, any program: named' ((Run-Other (New-FwRule 'other' -Protocol 'Any' -Port 'Any')) -eq 1)
Check 'TCP, port Any: named' ((Run-Other (New-FwRule 'other' -Port 'Any')) -eq 1)
Check 'TCP 20-30: named' ((Run-Other (New-FwRule 'other' -Port '20-30')) -eq 1)
Check 'sshd.exe by %SystemRoot% path: named' ((Run-Other (New-FwRule 'other' -Protocol 'Any' -Port 'Any' -Program '%SystemRoot%\System32\OpenSSH\sshd.exe')) -eq 1)
Check 'another program: not named' ((Run-Other (New-FwRule 'other' -Protocol 'Any' -Port 'Any' -Program 'C:\Program Files\App\app.exe')) -eq 0)
Check 'System (kernel) program: not named' ((Run-Other (New-FwRule 'other' -Port 'Any' -Program 'System')) -eq 0)
Check 'app package: not named' ((Run-Other (New-FwRule 'other' -Protocol 'Any' -Port 'Any' -Package 'S-1-15-2-1-2-3')) -eq 0)
Check 'another service: not named' ((Run-Other (New-FwRule 'other' -Protocol 'Any' -Port 'Any' -Service 'WinRM')) -eq 0)
Check 'any service (*): named' ((Run-Other (New-FwRule 'other' -Protocol 'Any' -Port 'Any' -Service '*')) -eq 1)
Check 'UDP 22: not named' ((Run-Other (New-FwRule 'other' -Protocol 'UDP')) -eq 0)
Check 'disabled: not named' ((Run-Other (New-FwRule 'other' -Protocol 'Any' -Port 'Any' -Enabled 'False')) -eq 0)
Check 'outbound: not named' ((Run-Other (New-FwRule 'other' -Protocol 'Any' -Port 'Any' -Direction 'Outbound')) -eq 0)
Check 'block rule: not named' ((Run-Other (New-FwRule 'other' -Protocol 'Any' -Port 'Any' -Action 'Block')) -eq 0)
Check 'narrow scope: listed, not named' (((Run-Other (New-FwRule 'other' -Protocol 'Any' -Port 'Any' -RA @('192.0.2.10'))) -eq 0) -and $script:R.Firewall -match '192.0.2.10')
Reset-Run; $script:Specs = @(ConvertTo-NetSpec '10.0.0.0/24'); $global:PortFilterThrows = $true
$global:FW = @{ 'OpenSSH-Server-In-TCP' = (New-FwRule 'OpenSSH-Server-In-TCP' -RA @('10.0.0.0/24')) }
Set-SshFirewallScope *> $null
Check 'other rules unreadable: warning, no problem' ($script:Problems.Count -eq 0 -and @($script:Warnings | Where-Object { $_ -match 'could not be read' }).Count -eq 1)

# ---- F8 default shell already PowerShell 7
function Get-ItemProperty { param($Path, $Name, $ErrorAction) if ($global:RegShell) { [pscustomobject]@{ DefaultShell = $global:RegShell } } else { throw 'no value' } }
function New-Item { param($Path, [switch]$Force, $Confirm) }
function New-ItemProperty { param($Path, $Name, $Value, $PropertyType, [switch]$Force, $Confirm) if ($global:FailReg) { throw 'Access denied.' }; $global:RegShell = $Value }
$script:Pwsh7Path = 'C:\Program Files\PowerShell\7\pwsh.exe'; $env:SystemRoot = $work
Reset-Run; $script:Shell = 'None'; $global:RegShell = 'C:\Program Files\PowerShell\7\pwsh.exe'
Set-SshDefaultShell *> $null
Check 'None, pwsh set: warned, unchanged' ($script:R.DefaultShell -eq 'unchanged: C:\Program Files\PowerShell\7\pwsh.exe' -and @($script:Warnings | Where-Object { $_ -like '*PowerShell 7 (C:\Program Files\PowerShell\7\pwsh.exe), left as it is*' }).Count -eq 1) ($script:Warnings -join '|')
Reset-Run; $script:Shell = 'None'; $global:RegShell = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
Set-SshDefaultShell *> $null
Check 'None, Windows PowerShell set: no warning' ($script:Warnings.Count -eq 0)
Reset-Run; $script:Shell = 'None'; $global:RegShell = $null
Set-SshDefaultShell *> $null
Check 'None, nothing set: no warning' ($script:Warnings.Count -eq 0 -and $script:R.DefaultShell -eq 'unchanged: cmd.exe (the Windows default)')
Reset-Run; $script:Shell = 'WindowsPowerShell'; $global:RegShell = 'C:\Program Files\PowerShell\7\pwsh.exe'
Set-SshDefaultShell *> $null
Check 'WindowsPowerShell replaces pwsh: no warning' ($script:Warnings.Count -eq 0 -and $global:RegShell -like '*powershell.exe') ($script:Warnings -join '|')
Reset-Run; $script:Shell = 'WindowsPowerShell'; $global:RegShell = 'C:\Program Files\PowerShell\7\pwsh.exe'; $global:FailReg = $true
Set-SshDefaultShell *> $null
Check 'WindowsPowerShell fails: problem and still-pwsh warning' ($script:Problems.Count -eq 1 -and @($script:Warnings | Where-Object { $_ -like '*still PowerShell 7*' }).Count -eq 1)
$global:FailReg = $false
Reset-Run; $script:Shell = 'PowerShell7'; $global:RegShell = $null
Set-SshDefaultShell *> $null
Check 'PowerShell7: note kept once' (@($script:Warnings | Where-Object { $_ -eq $script:Pwsh7Note }).Count -eq 1)

try { Remove-Item -LiteralPath $work -Recurse -Force } catch { "note: could not remove $work" }
if ($global:Fail) { 'TESTS FAILED'; exit 1 }
'ALL TESTS PASSED'
