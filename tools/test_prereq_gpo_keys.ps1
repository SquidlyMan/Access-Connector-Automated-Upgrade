# Offline test of Prerequisites/Deploy-OpenSSH-GPO.ps1 with its payload,
# Prerequisites/Install-OpenSSHServer.ps1: the deployer accepts exactly the public keys that the
# payload accepts, and puts exactly those keys in the GPO. Each of 27 key lines is given to the
# payload's own key check, here, and to the deployer as -PublicKey. When the deployer makes the
# GPO, the settings file it wrote is read back as a computer reads it and given to the payload's
# check again. A case passes when the payload accepts the line and the deployer succeeds with the
# same keys in its plan and in the settings file, or when the payload refuses the line (or finds
# no key in it) and the deployer stops with no GPO made.
# Offline: fake GroupPolicy and ActiveDirectory modules, written into a temporary folder by this
# file, keep the domain's state in a JSON file, and a temporary folder stands for SYSVOL. A copy
# of the deployer has its Windows check and its SYSVOL path replaced, and nothing else. The
# payload is only parsed: its check functions are defined here, and its body never runs. The keys
# are made up from a seeded random number generator, so every run sees the same keys. Each case
# starts the deployer in a new pwsh. No domain controller, share or server is contacted.
#   pwsh -NoLogo -NoProfile -File tools/test_prereq_gpo_keys.ps1
# Prints PASS <name> / FAIL <name>: <why> per case, then ALL TESTS PASSED or TESTS FAILED (exit 0/1).
$ErrorActionPreference = 'Stop'
$env:NO_COLOR = '1'
$repo = if ($env:FLEET_REPO) { $env:FLEET_REPO } else { Split-Path -Parent $PSScriptRoot }
$New = Join-Path $repo 'Prerequisites/Deploy-OpenSSH-GPO.ps1'
$Payload = Join-Path $repo 'Prerequisites/Install-OpenSSHServer.ps1'
foreach ($f in $New, $Payload) { if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { "FAIL load: $f not found"; 'TESTS FAILED'; exit 1 } }
$base = Join-Path ([IO.Path]::GetTempPath()) ('acu-test-gpo-' + $PID)
$eq = Join-Path $base 'eq'
$null = New-Item -ItemType Directory -Force -Path $eq
$script:Fails = 0

# ---- the fake modules: stand-ins for GroupPolicy and ActiveDirectory that keep state in a file
$fakeState = @'
# Shared by the fake GroupPolicy and ActiveDirectory modules (offline simulation only).
function Get-FakeState { Get-Content -LiteralPath $env:FAKE_STATE -Raw | ConvertFrom-Json }
function Save-FakeState($s) { $s | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $env:FAKE_STATE }
function Test-FakeFlag([string]$Name) { return (@($env:FAKE_FAIL -split ',') -contains $Name) }
function Test-FakeFail([string]$Name) { if (Test-FakeFlag $Name) { throw "simulated failure in $Name" } }
function Get-FakeGpoFolder([string]$Id) { Join-Path (Join-Path $env:FAKE_SYSVOL 'Policies') ('{' + $Id.ToUpper() + '}') }
function Write-FakeLog([string]$m) { Add-Content -LiteralPath $env:FAKE_CALLS -Value $m }
'@
$fakeGroupPolicy = @'
. (Join-Path $PSScriptRoot '../fakestate.ps1')
function ConvertTo-FakeGpo($g) { [pscustomobject]@{ Id = [guid]$g.Id; DisplayName = $g.DisplayName; Description = $g.Description; GpoStatus = $g.GpoStatus } }
function Get-GPO { [CmdletBinding(DefaultParameterSetName = 'Guid')] param([Parameter(ParameterSetName = 'Guid', Position = 0)][guid]$Guid,
        [Parameter(ParameterSetName = 'Name')][string]$Name, [Parameter(ParameterSetName = 'All')][switch]$All, [string]$Domain, [string]$Server)
    Write-FakeLog "Get-GPO all=$All server=$Server"
    $s = Get-FakeState
    if ($All) { return @($s.Gpos | Where-Object { $_ } | ForEach-Object { ConvertTo-FakeGpo $_ }) }
    if ($Name) { $g = @($s.Gpos | Where-Object { $_.DisplayName -eq $Name }); if (-not $g.Count) { throw "A GPO with the name $Name could not be found" }; return (ConvertTo-FakeGpo $g[0]) }
    $g = @($s.Gpos | Where-Object { [guid]$_.Id -eq $Guid })[0]; if (-not $g) { throw "GPO $Guid was not found" }; return (ConvertTo-FakeGpo $g) }
function New-GPO { [CmdletBinding()] param([Parameter(Mandatory, Position = 0)][string]$Name, [string]$Comment, [string]$Domain, [string]$Server)
    Write-FakeLog "New-GPO server=$Server"; Test-FakeFail 'New-GPO'
    $s = Get-FakeState
    $id = [guid]::NewGuid().ToString()
    $g = [pscustomobject]@{ Id = $id; DisplayName = $Name; Description = $Comment; versionNumber = 0; gPCMachineExtensionNames = ''; GpoStatus = 'AllSettingsEnabled'; Registry = @() }
    $s.Gpos = @(@($s.Gpos | Where-Object { $_ }) + $g)
    Save-FakeState $s
    $root = Get-FakeGpoFolder $id
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $root 'Machine'), (Join-Path $root 'User')
    [IO.File]::WriteAllText((Join-Path $root 'GPT.ini'), "[General]`r`nVersion=0`r`ndisplayName=New Group Policy Object`r`n")
    if (Test-FakeFlag 'New-GPO-race') { throw 'The GPO already exists (simulated race)' }
    return (ConvertTo-FakeGpo $g) }
function New-GPLink { [CmdletBinding()] param([guid]$Guid, [Parameter(Mandatory, Position = 0)][string]$Target, [string]$LinkEnabled, [string]$Domain, [string]$Server)
    Write-FakeLog "New-GPLink server=$Server"; Test-FakeFail 'New-GPLink'
    $s = Get-FakeState
    $s.Links = @(@($s.Links | Where-Object { $_ }) + [pscustomobject]@{ GpoId = $Guid.ToString(); Target = $Target; Enabled = ($LinkEnabled -ne 'No') })
    Save-FakeState $s }
function Get-GPInheritance { [CmdletBinding()] param([Parameter(Mandatory, Position = 0)][string]$Target, [string]$Domain, [string]$Server)
    Write-FakeLog "Get-GPInheritance server=$Server"
    $s = Get-FakeState
    $links = @($s.Links | Where-Object { $_ -and $_.Target -eq $Target } | ForEach-Object {
        [pscustomobject]@{ GpoId = [guid]$_.GpoId; Enabled = [bool]$_.Enabled; Target = $_.Target } })
    return [pscustomobject]@{ Path = $Target; GpoLinks = $links } }
function Set-GPRegistryValue { [CmdletBinding()] param([guid]$Guid, [string]$Key, [string[]]$ValueName, [object]$Value, [string]$Type, [string]$Domain, [string]$Server)
    Write-FakeLog "Set-GPRegistryValue $Key $ValueName=$Value ($Type) server=$Server"; Test-FakeFail 'Set-GPRegistryValue'
    $s = Get-FakeState
    $g = @($s.Gpos | Where-Object { [guid]$_.Id -eq $Guid })[0]
    $g.Registry = @(@($g.Registry) + "$Key\$ValueName=$Value")
    $reg = '[{35378EAC-683F-11D2-A89A-00C04FBBCFA2}{D02B1F72-3407-48AE-BA88-E8213C6761F1}]'
    if (-not ([string]$g.gPCMachineExtensionNames).Contains($reg)) {
        $g.gPCMachineExtensionNames = (@(@([regex]::Matches([string]$g.gPCMachineExtensionNames, '\[[^\]]*\]') | ForEach-Object { $_.Value }) + $reg) | Sort-Object) -join '' }
    if (-not (Test-FakeFlag 'version0')) { $g.versionNumber = [int]$g.versionNumber + 1 }
    Save-FakeState $s
    $gpt = Join-Path (Get-FakeGpoFolder $g.Id) 'GPT.ini'
    [IO.File]::WriteAllText($gpt, ([IO.File]::ReadAllText($gpt) -replace 'Version=-?\d+', "Version=$($g.versionNumber)")) }
function Get-GPOReport { [CmdletBinding()] param([Parameter(Position = 0)][guid]$Guid, [Parameter(Position = 1)][string]$ReportType, [string]$Domain, [string]$Server)
    Write-FakeLog "Get-GPOReport server=$Server"; Test-FakeFail 'Get-GPOReport'
    $s = Get-FakeState
    $g = @($s.Gpos | Where-Object { [guid]$_.Id -eq $Guid })[0]
    $ini = Join-Path (Join-Path (Join-Path (Get-FakeGpoFolder $g.Id) 'Machine') 'Scripts') 'psscripts.ini'
    $cmd = ''
    if (Test-Path $ini) { $m = [regex]::Match([IO.File]::ReadAllText($ini), '(?m)^0CmdLine=(.*)$'); if ($m.Success) { $cmd = $m.Groups[1].Value.Trim() } }
    $links = (@($s.Links | Where-Object { $_ -and [guid]$_.GpoId -eq $Guid } | ForEach-Object { "<LinksTo><SOMName>x</SOMName><SOMPath>$($s.Domain.DNSRoot)/$($_.Target)</SOMPath><Enabled>$(([string]$_.Enabled).ToLower())</Enabled></LinksTo>" }) -join '')
    $scr = ''
    if ($cmd) { $scr = "<ExtensionData><Extension xmlns:q1=""http://www.microsoft.com/GroupPolicy/Settings/Scripts"" xmlns:xsi=""http://www.w3.org/2001/XMLSchema-instance"" xsi:type=""q1:Scripts""><q1:Script><q1:Command>$cmd</q1:Command><q1:Type>Startup</q1:Type><q1:Order>0</q1:Order><q1:RunOrder>PSFirst</q1:RunOrder></q1:Script></Extension><Name>Scripts</Name></ExtensionData>" }
    return "<?xml version=""1.0"" encoding=""utf-16""?><GPO xmlns=""http://www.microsoft.com/GroupPolicy/Settings""><Name>$($g.DisplayName)</Name><Computer>$scr</Computer>$links</GPO>" }
function Remove-GPO { [CmdletBinding()] param([guid]$Guid, [string]$Domain, [string]$Server)
    Write-FakeLog "Remove-GPO server=$Server"; Test-FakeFail 'Remove-GPO'
    $s = Get-FakeState
    $s.Gpos = @($s.Gpos | Where-Object { $_ -and [guid]$_.Id -ne $Guid })
    $s.Links = @($s.Links | Where-Object { $_ -and [guid]$_.GpoId -ne $Guid })
    Save-FakeState $s
    Remove-Item -LiteralPath (Get-FakeGpoFolder $Guid.ToString()) -Recurse -Force -ErrorAction SilentlyContinue }
function Remove-GPLink { [CmdletBinding()] param([guid]$Guid, [Parameter(Mandatory, Position = 0)][string]$Target, [string]$Domain, [string]$Server)
    Write-FakeLog "Remove-GPLink server=$Server"; Test-FakeFail 'Remove-GPLink'
    $s = Get-FakeState
    $s.Links = @($s.Links | Where-Object { $_ -and -not ([guid]$_.GpoId -eq $Guid -and $_.Target -eq $Target) })
    Save-FakeState $s }
Export-ModuleMember -Function Get-GPO, New-GPO, New-GPLink, Get-GPInheritance, Set-GPRegistryValue, Get-GPOReport, Remove-GPO, Remove-GPLink
'@
$fakeActiveDirectory = @'
. (Join-Path $PSScriptRoot '../fakestate.ps1')
function Get-ADDomain { [CmdletBinding()] param([string]$Identity, [string]$Server)
    Write-FakeLog "Get-ADDomain server=$Server"; Test-FakeFail 'Get-ADDomain'
    return (Get-FakeState).Domain }
function Get-ADObject { [CmdletBinding(DefaultParameterSetName = 'Identity')] param(
        [Parameter(Mandatory, ParameterSetName = 'Identity')][string]$Identity,
        [Parameter(Mandatory, ParameterSetName = 'Ldap')][string]$LDAPFilter,
        [Parameter(ParameterSetName = 'Ldap')][string]$SearchBase,
        [Parameter(ParameterSetName = 'Ldap')][string]$SearchScope,
        [string]$Server, [string[]]$Properties)
    if ($PSCmdlet.ParameterSetName -eq 'Ldap') {
        # Only the gPLink search the deployer makes: the OUs and the domain that link a GPO.
        Write-FakeLog "Get-ADObject ldap=$LDAPFilter base=$SearchBase server=$Server"; Test-FakeFail 'Get-ADObject-ldap'
        $s = Get-FakeState
        $id = [regex]::Match($LDAPFilter, 'gPLink=\*([^*)]+)\*').Groups[1].Value
        if (-not $id) { throw "fake: unexpected filter $LDAPFilter" }
        $by = [ordered]@{}
        foreach ($l in @($s.Links | Where-Object { $_ })) {
            $flag = 0; if (-not $l.Enabled) { $flag = 1 }
            if (-not $by.Contains($l.Target)) { $by[$l.Target] = '' }
            $by[$l.Target] += "[LDAP://cn={$(([string]$l.GpoId).ToUpper())},cn=policies,cn=system,$($s.Domain.DistinguishedName);$flag]" }
        return @($by.Keys | Where-Object { $by[$_].ToUpper().Contains($id.ToUpper()) } | ForEach-Object { [pscustomobject]@{ DistinguishedName = $_; gPLink = $by[$_] } }) }
    Write-FakeLog "Get-ADObject $Identity server=$Server"
    $s = Get-FakeState
    if ($Identity -match '^CN=\{([0-9A-Fa-f-]+)\},CN=Policies,CN=System,') {
        $id = $Matches[1]
        $g = @($s.Gpos | Where-Object { $_.Id -eq $id })[0]
        if (-not $g) { throw "Cannot find an object with identity: '$Identity'" }
        return [pscustomobject]@{ DistinguishedName = $Identity; ObjectClass = 'groupPolicyContainer'; versionNumber = [int]$g.versionNumber; gPCMachineExtensionNames = $g.gPCMachineExtensionNames } }
    $o = @($s.Objects | Where-Object { $_.DN -eq $Identity })[0]
    if (-not $o) { throw "Cannot find an object with identity: '$Identity'" }
    return [pscustomobject]@{ DistinguishedName = $o.DN; ObjectClass = $o.Class } }
function Set-ADObject { [CmdletBinding()] param([Parameter(Mandatory)][string]$Identity, [string]$Server, [hashtable]$Replace)
    Write-FakeLog "Set-ADObject $($Replace.Keys -join ',') server=$Server"; Test-FakeFail 'Set-ADObject'
    $s = Get-FakeState
    $id = ([regex]::Match($Identity, '\{([0-9A-Fa-f-]+)\}')).Groups[1].Value
    $g = @($s.Gpos | Where-Object { $_.Id -eq $id })[0]
    foreach ($k in $Replace.Keys) {
        if ($k -eq 'versionNumber' -and (Test-FakeFlag 'version0')) { continue }
        if ($k -eq 'gPCMachineExtensionNames' -and (Test-FakeFlag 'nocse')) { continue }
        $g.$k = $Replace[$k] }
    Save-FakeState $s }
function Get-ADComputer { [CmdletBinding()] param([string]$Filter, [string]$SearchBase, [string]$SearchScope, [string]$Server, [string[]]$Properties)
    Write-FakeLog "Get-ADComputer base=$SearchBase server=$Server"
    $s = Get-FakeState
    @($s.Computers | Where-Object { $_.DN.EndsWith(',' + $SearchBase) } | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; OperatingSystem = $_.OperatingSystem; OperatingSystemVersion = $_.OperatingSystemVersion; primaryGroupID = $_.primaryGroupID } }) }
Export-ModuleMember -Function Get-ADDomain, Get-ADObject, Set-ADObject, Get-ADComputer
'@
$fake = Join-Path $base 'fakemods'
$null = New-Item -ItemType Directory -Force -Path (Join-Path $fake 'GroupPolicy'), (Join-Path $fake 'ActiveDirectory')
[IO.File]::WriteAllText((Join-Path $fake 'fakestate.ps1'), $fakeState + "`n")
[IO.File]::WriteAllText((Join-Path (Join-Path $fake 'GroupPolicy') 'GroupPolicy.psm1'), $fakeGroupPolicy + "`n")
[IO.File]::WriteAllText((Join-Path (Join-Path $fake 'ActiveDirectory') 'ActiveDirectory.psm1'), $fakeActiveDirectory + "`n")

# ---- a copy of the deployer with its Windows check and its SYSVOL path replaced
function Patch([string]$Script, [string]$Dest) {
    $t = $null; $e = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$t, [ref]$e)
    $src = [IO.File]::ReadAllText($Script)
    $fns = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in 'Get-PlatformProblem', 'Get-SysvolRoot' }, $false)) | Sort-Object { $_.Extent.StartOffset } -Descending
    if (@($fns).Count -ne 2) { throw "cannot patch $Script" }
    foreach ($f in $fns) {
        $stub = if ($f.Name -eq 'Get-PlatformProblem') { "function Get-PlatformProblem { return '' }" } else { 'function Get-SysvolRoot { param([string]$Server, [string]$Fqdn) return $env:FAKE_SYSVOL }' }
        $src = $src.Substring(0, $f.Extent.StartOffset) + $stub + $src.Substring($f.Extent.EndOffset) }
    [IO.File]::WriteAllText($Dest, $src) }
$deployer = Join-Path $eq 'deployer.ps1'
try { Patch $New $deployer } catch { "FAIL load: $($_.Exception.Message)"; 'TESTS FAILED'; exit 1 }

# ---- the fake domain: one OU, no computers, no GPOs
$env:PSModulePath = $fake + [IO.Path]::PathSeparator + $env:PSModulePath
$env:FAKE_STATE = Join-Path $eq 'state.json'; $env:FAKE_SYSVOL = Join-Path $eq 'sysvol'; $env:FAKE_CALLS = Join-Path $eq 'calls.log'; $env:FAKE_FAIL = ''
$null = New-Item -ItemType Directory -Path (Join-Path $env:FAKE_SYSVOL 'Policies')
$ou = 'OU=Equivalence,DC=example,DC=local'
[ordered]@{
    Domain = [ordered]@{ DNSRoot = 'example.local'; DistinguishedName = 'DC=example,DC=local'; PDCEmulator = 'dc1.example.local'; NetBIOSName = 'EXAMPLE' }
    Objects = @([ordered]@{ DN = $ou; Class = 'organizationalUnit' }); Computers = @(); Gpos = @(); Links = @()
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $env:FAKE_STATE
$runner = Join-Path $eq 'runner.ps1'
Set-Content -LiteralPath $runner -Value 'param([string]$S, [string]$C) $p = Import-Clixml -LiteralPath $C; & $S @p; exit $LASTEXITCODE'

# ---- the payload's own verdict, here: its check functions and the two constants they read
$t = $null; $e = $null
$past = [System.Management.Automation.Language.Parser]::ParseFile($Payload, [ref]$t, [ref]$e)
$names = 'Read-SshField','Get-OptionsEnd','Test-KeyOptions','ConvertTo-KeyRecord','Split-JoinedKeys','Get-KeyLineProblem','Split-Lines','Read-TextFile','Get-InputKeys','Get-MaskedBytes','ConvertTo-NetSpec'
foreach ($f in @($past.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $names -contains $_.Name })) { . ([scriptblock]::Create($f.Extent.Text)) }
foreach ($a in @($past.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and $_.Left.VariablePath.UserPath -in 'script:KeyTypes', 'script:PrivateKeyText' })) { . ([scriptblock]::Create($a.Extent.Text)) }
function Verdict([string[]]$Values) {
    $PublicKey = $Values; $PublicKeyFile = @()
    function Add-Warning { param([string]$Message) }
    $r = Get-InputKeys
    return [pscustomobject]@{ Errors = @($r.Errors).Count; Fps = @($r.Keys | ForEach-Object { $_.Fingerprint }) } }

# ---- made-up public keys of the types and sizes the payload checks (ed25519, ECDSA P-256, RSA
# of 3072 and 1024 bits): random key data from a seeded generator, so every run sees the same keys
$script:Rng = New-Object System.Random 20261123
function New-TestKey { param([string]$Type, [string]$Comment, [int]$Bits = 0)
    $fields = @(, [System.Text.Encoding]::ASCII.GetBytes($Type))
    if ($Type -eq 'ssh-ed25519') { $pk = New-Object byte[] 32; $script:Rng.NextBytes($pk); $fields += , $pk }
    elseif ($Type -eq 'ecdsa-sha2-nistp256') {
        $q = New-Object byte[] 65; $script:Rng.NextBytes($q); $q[0] = 4
        $fields += , [System.Text.Encoding]::ASCII.GetBytes('nistp256'); $fields += , $q }
    else {
        # an mpint: a zero byte, then the modulus with its top bit set (and odd)
        $n = New-Object byte[] ($Bits / 8 + 1); $script:Rng.NextBytes($n)
        $n[0] = 0; $n[1] = $n[1] -bor 0x80; $n[$n.Length - 1] = $n[$n.Length - 1] -bor 1
        $fields += , [byte[]](1, 0, 1); $fields += , $n }
    $ms = New-Object System.IO.MemoryStream
    foreach ($f in $fields) { $len = [BitConverter]::GetBytes([int]$f.Length); [Array]::Reverse($len); $ms.Write($len, 0, 4); $ms.Write($f, 0, $f.Length) }
    return ($Type + ' ' + [Convert]::ToBase64String($ms.ToArray()) + ' ' + $Comment) }
$k = @{ ed25519 = (New-TestKey 'ssh-ed25519' 'test-ed25519@example'); ecdsa = (New-TestKey 'ecdsa-sha2-nistp256' 'test-ecdsa@example')
        rsa = (New-TestKey 'ssh-rsa' 'test-rsa@example' 3072); rsa1024 = (New-TestKey 'ssh-rsa' 'test-rsa1024@example' 1024) }
$ed = $k.ed25519; $ec = $k.ecdsa
$edp = $ed -split ' '; $ecp = $ec -split ' '
$nb = [string][char]0xA0
$corpus = [ordered]@{
    'plain ed25519'                       = $ed
    'plain ecdsa'                         = $ec
    'plain rsa 3072'                      = $k.rsa
    'rsa 1024 (payload warns)'            = $k.rsa1024
    'spaces around it'                    = "  $ed  "
    'tab between the fields'              = ($edp[0] + "`t" + $edp[1] + "`t" + $edp[2])
    'options: from=,no-pty'               = ('from="10.0.0.0/24",no-pty ' + $ed)
    'options: restrict (any case)'        = ('RESTRICT ' + $ed)
    'options: command with a space'       = ('command="echo hi",no-port-forwarding ' + $ed)
    'options: environment="A=B"'          = ('environment="A=B" ' + $ed)
    'text in front, not options'          = ('foo bar ' + $ed)
    'unknown option foo=bar'              = ('foo=bar ' + $ed)
    'option value without quotes'         = ('from=10.0.0.1 ' + $ed)
    'option quote left open'              = ('from="10.0.0.0/24 ' + $ed)
    'option list ending in a comma'       = ('no-pty, ' + $ed)
    'two keys joined by a space'          = "$ed $ec"
    'two keys joined by a comma'          = "$ed,$ec"
    'two keys on two lines'               = "$ed`n$ec"
    'joined, options between them'        = ($ed + ' from="10.0.0.0/24" ' + $ec)
    'joined, the second cut off'          = ($ed + ' ' + $ecp[0] + ' ' + $ecp[1].Substring(0, 60))
    'no-break spaces between fields'      = ($ed -replace ' ', $nb)
    'non-ASCII comment'                   = ($ed + 'x jos' + [char]0xE9)
    'a comment line only'                 = ('# ' + $ed)
    'type only'                           = 'ssh-ed25519'
    'key data cut short'                  = ($edp[0] + ' ' + $edp[1].Substring(0, 40) + ' cut@example')
    'key data with a byte changed'        = ($edp[0] + ' ' + $edp[1].Substring(0, 10) + 'B' + $edp[1].Substring(11) + ' bad@example')
    'ssh-dss'                             = 'ssh-dss AAAAB3NzaC1kc3MAAACB x@example'
}

# ---- each line: the payload's verdict, then the deployer's, and the payload's on what it wrote
$i = 0
foreach ($name in $corpus.Keys) {
    $i++
    $val = [string]$corpus[$name]
    $pv = Verdict @($val)
    $want = 'refuse'; if (-not $pv.Errors -and $pv.Fps.Count) { $want = 'accept ' + $pv.Fps.Count } elseif (-not $pv.Errors) { $want = 'no key' }
    $gpo = "EQ $i"
    $c = Join-Path $eq "case-$i.xml"
    @{ TargetOU = $ou; GpoName = $gpo; PublicKey = @($val); AllowFrom = @('10.0.0.0/24'); PayloadPath = $Payload; Yes = $true } | Export-Clixml -LiteralPath $c
    $out = (& pwsh -NoLogo -NoProfile -NonInteractive -File $runner $deployer $c 2>&1 | Out-String); $rc = $LASTEXITCODE
    $planFps = @([regex]::Matches(($out -replace '\s+', ' '), 'Key \d+ (?:ssh-ed25519|ecdsa-sha2-nistp\d+|ssh-rsa) (SHA256:[A-Za-z0-9+/]+)') | ForEach-Object { $_.Groups[1].Value })
    $comp = '-'
    $g = @((Get-Content -LiteralPath $env:FAKE_STATE -Raw | ConvertFrom-Json).Gpos | Where-Object { $_ -and $_.DisplayName -eq $gpo })
    $ok = $false
    if ($g.Count) {
        $sf = [IO.Path]::Combine($env:FAKE_SYSVOL, 'Policies', ('{' + $g[0].Id.ToUpper() + '}'), 'Machine', 'Scripts', 'Startup', 'OpenSSHServer-Settings.json')
        $vals = @((Get-Content -LiteralPath $sf -Raw | ConvertFrom-Json).Parameters.PublicKey)
        $cv = Verdict $vals
        if ($cv.Errors) { $comp = 'REFUSED at every startup' } else { $comp = "trusts $($cv.Fps.Count)"; if (($cv.Fps -join ' ') -cne ($planFps -join ' ')) { $comp += ', NOT the plan''s keys' } }
        $ok = ($want -like 'accept*' -and $rc -eq 0 -and -not $cv.Errors -and ($cv.Fps -join ' ') -ceq ($pv.Fps -join ' ') -and ($planFps -join ' ') -ceq ($pv.Fps -join ' '))
    } else { $ok = ($want -notlike 'accept*' -and $rc -ne 0) }
    $got = ('payload: {0}; deployer: exit code {1}, {2} key(s) in its plan, computer: {3}' -f $want, $rc, $planFps.Count, $comp)
    if ($ok) { "PASS ${name}: $got" } else { $script:Fails++; "FAIL ${name}: $got" }
}

try { Remove-Item -LiteralPath $base -Recurse -Force } catch { "note: could not remove $base" }
if ($script:Fails) { 'TESTS FAILED'; exit 1 }
'ALL TESTS PASSED'
