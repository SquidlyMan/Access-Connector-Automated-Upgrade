# Offline tests for -Mode Discover: the read-only remote script (static safety checks, and a run
# here under pwsh), ConvertTo-DiscoveredRows, Invoke-ConnectorDiscovery (against a stand-in ssh put
# first on the PATH) and Export-DiscoveredCsv. No connector, domain controller or share is contacted.
#   pwsh -NoLogo -NoProfile -File tools/test_fleet_discover.ps1
# Functions and the $script: constants are loaded from the orchestrator through its AST; env
# FLEET_FUNC_FILES (semicolon-separated) names other files to load from (for each name the first
# file that has it wins). Fixtures go in a temporary folder that is removed at the end. The
# transport cases are skipped on Windows (the stand-in ssh is a shell script).
# Prints PASS <name> / FAIL <name>: <why> per case, then ALL TESTS PASSED or TESTS FAILED (exit 0/1).
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$repo = Split-Path -Parent $PSScriptRoot
$files = @(if ($env:FLEET_FUNC_FILES) { $env:FLEET_FUNC_FILES -split ';' | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() } }
           else { (Join-Path $repo 'FleetDeploy/Invoke-AccessConnectorUpgrade.ps1') })
$fnNames = @('Invoke-ConnectorDiscovery','ConvertTo-DiscoveredRows','Export-DiscoveredCsv','Get-SshBaseArgs','Get-SshTarget')
$varNames = @('script:FleetColumns','script:DiscoverRemoteScript')

$script:Failed = 0
$script:Problems = $null
function Test-Case { param([string]$Name, [scriptblock]$Body)
    $script:Problems = [System.Collections.Generic.List[string]]::new()
    try { $null = & $Body } catch { $script:Problems.Add('threw: ' + $_.Exception.Message + ' (test line ' + $_.InvocationInfo.ScriptLineNumber + ')') }
    if ($script:Problems.Count) { $script:Failed++; "FAIL ${Name}: " + ($script:Problems -join ' | ') } else { "PASS $Name" } }
function Want { param($Cond, [string]$Why) if (-not $Cond) { $script:Problems.Add($Why) } }
function Want-Eq { param($Actual, $Expected, [string]$What) if ([string]$Actual -cne [string]$Expected) { $script:Problems.Add("$What is '$Actual', expected '$Expected'") } }

# ---------------------------------------------------------------- load the functions under test
$found = @{}; $from = @{}
$loadProblems = [System.Collections.Generic.List[string]]::new()
foreach ($f in $files) {
    if (-not (Test-Path -LiteralPath $f)) { $loadProblems.Add("file not found: $f"); continue }
    $tk = $null; $er = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tk, [ref]$er)
    if ($er.Count) { $loadProblems.Add("$f does not parse: " + $er[0].Message); continue }
    foreach ($fd in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $fnNames }, $true)) {
        if (-not $found.ContainsKey($fd.Name)) { $found[$fd.Name] = $fd.Extent.Text; $from[$fd.Name] = $f } }
    foreach ($as in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.UserPath -in $varNames }, $true)) {
        $vn = $as.Left.VariablePath.UserPath
        if (-not $found.ContainsKey($vn)) { $found[$vn] = $as.Extent.Text; $from[$vn] = $f } }
}
foreach ($n in @($fnNames + $varNames)) { if (-not $found.ContainsKey($n)) { $loadProblems.Add("not found in any file: $n") } }
if ($loadProblems.Count) { "FAIL load: " + ($loadProblems -join ' | '); 'TESTS FAILED'; exit 1 }
. ([scriptblock]::Create((@($found.Values) -join "`n")))
$SshKey = $null
"PASS load ($(@($fnNames + $varNames).Count) definitions from $(@($from.Values | Sort-Object -Unique).Count) file(s))"

$runDir = Join-Path ([IO.Path]::GetTempPath()) ('acu-test-discover-' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '-' + $PID)
$null = New-Item -ItemType Directory -Path $runDir -Force
$specColumns = @('Group','Host','SshUser','Installer','InstallerVersion','ExpectVersionPrefix','ConfigFile','Services','ServiceAccount','Pfx','TrustStore','Syslog','ForceReinstall','InstallDir','EnableFips','DirectorySyncPort','UserAuthPort','KerberosAuthPort','VirtualAppPort','ProxyHost','ProxyPort','ProxyUser','NonProxyHosts','Notes')
$all4 = 'DirectorySyncService,UserAuthService,KerberosAuthService,VirtualAppService'
$three = 'DirectorySyncService,UserAuthService,VirtualAppService'
$LS = 'NT AUTHORITY\LocalService'; $SA = 'EXAMPLE\svc-access'

# ---------------------------------------------------------------- builders
function New-Cert { param([string]$Subject = 'connector1.example.local', [string[]]$Names = @('connector1.example.local','connector.example.local'),
        [string]$Issuer = 'EXAMPLE-CA', [switch]$SelfSigned, [switch]$NotOk, [string]$Message = '')
    [ordered]@{ Ok = (-not $NotOk); Port = 443; Subject = $Subject; Names = $Names; Issuer = $Issuer; NotAfter = '2027-07-25'; SelfSigned = [bool]$SelfSigned; Message = $Message } }
function New-Data { param([string[]]$Svc = @('DirectorySyncService','UserAuthService','KerberosAuthService','VirtualAppService'),
        [hashtable]$Props = @{}, [hashtable]$Reg = @{}, $Cert = 'default', [switch]$JavaFlag, [string]$Tenant = 'TENANT1', [string]$Version = '26.10.0.0', [switch]$Bare)
    # shaped like the remote script's JSON, and sent through JSON as it would be over ssh
    $services = @(foreach ($k in $Svc) { [ordered]@{ Key = $k; Name = 'Access' + $k; Status = 'Running'; StartName = $(if ($k -in 'KerberosAuthService','VirtualAppService') { $SA } else { $LS }) } })
    $p = [ordered]@{ INSTALL_DIR = 'C:\Program Files\Access Connector\'; TENANT_URL = "https://$Tenant.us1.example.com"; TRUST_CERTS = ''; SYSLOG_CONFIGURATIONS = ''
        PROXY_HOST = ''; PROXY_PORT = ''; PROXY_USER = ''; NON_PROXY_HOSTS = ''; FIPS_ENABLED = 'false'
        DIRECTORY_SYNC_SVC_PORT = '8080'; USER_AUTH_SVC_PORT = '8090'; KERBEROS_AUTH_SVC_PORT = '443'; VIRTUAL_APP_SYNC_SVC_PORT = '8008' }
    foreach ($k in $Props.Keys) { if ($null -eq $Props[$k]) { $p.Remove($k) } else { $p[$k] = $Props[$k] } }
    $r = [ordered]@{ IS_NET_API_LOGON_USERNAME = $SA; InstallDir = 'C:\Program Files\' }
    foreach ($k in $Reg.Keys) { if ($null -eq $Reg[$k]) { $r.Remove($k) } else { $r[$k] = $Reg[$k] } }
    if ($Cert -is [string] -and $Cert -eq 'default') { $Cert = $(if ('KerberosAuthService' -in $Svc) { New-Cert } else { $null }) }
    $d = [ordered]@{ Computer = 'CONNECTOR1'; Fqdn = 'connector1.example.local'; InstalledVersion = $Version; InstallLocation = 'C:\Program Files\'
        InstallRoot = 'C:\Program Files\Access Connector'; Services = $services; Registry = $r; Properties = $p; JavaFlag = [bool]$JavaFlag; Cert = $Cert; Errors = @() }
    if ($Bare) { $d = [ordered]@{ Computer = 'CONNECTOR1'; Fqdn = $null; InstalledVersion = $null; InstallLocation = $null; InstallRoot = 'C:\Program Files\Access Connector'; Services = @(); Registry = [ordered]@{}; Properties = [ordered]@{}; JavaFlag = $false; Cert = $null; Errors = @() } }
    return (ConvertTo-Json -InputObject $d -Depth 6 -Compress | ConvertFrom-Json) }
function New-Result { param([string]$HostName, $Data, $Entry = $null, [string]$SshUser = '', [string]$ErrorText = '')
    [pscustomobject]@{ Host = $HostName; SshUser = $SshUser; Ok = ($null -ne $Data); Data = $Data; Error = $ErrorText; Entry = $Entry } }
function New-Staging { param([string]$Name, [string[]]$Installers = @(), [string[]]$Configs = @(), [string[]]$Pfx = @(), [string[]]$Trusted = @())
    $root = Join-Path $runDir $Name
    foreach ($sub in 'Installers','Configs','ChildCerts','TrustedCerts') { $null = New-Item -ItemType Directory -Path (Join-Path $root $sub) -Force }
    foreach ($x in $Installers) { $null = New-Item -ItemType File -Path (Join-Path (Join-Path $root 'Installers') $x) }
    foreach ($x in $Pfx) { $null = New-Item -ItemType File -Path (Join-Path (Join-Path $root 'ChildCerts') $x) }
    foreach ($x in $Trusted) { $null = New-Item -ItemType File -Path (Join-Path (Join-Path $root 'TrustedCerts') $x) }
    # empty placeholders, and unreadable: discovery must match them by name and never open one
    foreach ($x in $Configs) { $cp = Join-Path (Join-Path $root 'Configs') $x; $null = New-Item -ItemType File -Path $cp; if (-not $IsWindows) { & chmod 000 $cp } }
    return $root }
function Get-Row { param($Rows, [string]$HostName) $m = @($Rows | Where-Object { $_['Host'] -eq $HostName }); if ($m.Count -ne 1) { throw "expected one row for $HostName, found $($m.Count)" }; return $m[0] }
function Want-Row { param($Row, [hashtable]$Expect, [string]$Label)
    # every column: the expected value, or '' when not named (Notes is checked only when named)
    $keys = @($Row.Keys)
    if (($keys -join ',') -cne ($specColumns -join ',')) { $script:Problems.Add("$Label columns are '$($keys -join ',')'") }
    foreach ($c in $specColumns) {
        if ($c -eq 'Notes' -and -not $Expect.ContainsKey('Notes')) { continue }
        $want = ''; if ($Expect.ContainsKey($c)) { $want = [string]$Expect[$c] }
        if ([string]$Row[$c] -cne $want) { $script:Problems.Add("$Label $c is '$($Row[$c])', expected '$want'") }
    } }

$stage = New-Staging 'main' -Installers @('Access-Connector-Installer-26.10.0.0.exe', '._Access-Connector-Installer-26.10.0.0.exe', 'readme.txt') `
    -Configs @('tenant1.us1.example.com-es-config.json', 'tenant2.us1.example.com-es-config.json', 'tenant5.us1.example.com-es-config.json', 'tenant6.us1.example.com-es-config.json', 'tenant10.us1.example.com-es-config.json') `
    -Pfx @('connector.example.local.pfx', 'other.example.local.pfx', 'connector3.example.local.pfx') -Trusted @('root-ca.pem', 'notes.txt')
$stageTwoExe = New-Staging 'two-installers' -Installers @('Access-Connector-Installer-26.05.0.0.exe', 'Access-Connector-Installer-26.10.0.0.exe') -Configs @('tenant1.us1.example.com-es-config.json')
$stageTwoCfg = New-Staging 'two-configs' -Installers @('AccessConnector_26.10.exe') -Configs @('tenant1.us1.example.com-es-config.json', 'old-tenant1.us1.example.com-es-config.json')
$stageNoVer = New-Staging 'no-version' -Installers @('Access-Connector-Installer.exe')

# ================================================================ the part file itself
Test-Case 'source file: ASCII only, parses; the discovery functions never exit or call Say/Stop-Run' {
    $pfile = $from['ConvertTo-DiscoveredRows']
    $bytes = [IO.File]::ReadAllBytes($pfile)
    Want (@($bytes | Where-Object { $_ -gt 127 }).Count -eq 0) "non-ASCII bytes in $pfile"
    $tk = $null; $er = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($pfile, [ref]$tk, [ref]$er)
    Want ($er.Count -eq 0) 'parse errors'
    foreach ($fn in 'Invoke-ConnectorDiscovery','ConvertTo-DiscoveredRows','Export-DiscoveredCsv') {
        $fa = [System.Management.Automation.Language.Parser]::ParseInput($found[$fn], [ref]$null, [ref]$null)
        Want (@($fa.FindAll({ param($n) $n -is [System.Management.Automation.Language.ExitStatementAst] }, $true)).Count -eq 0) "$fn calls exit"
        $names = @($fa.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
        Want (-not ($names -contains 'Say' -or $names -contains 'Stop-Run')) "$fn calls Say or Stop-Run"
    }
}
Test-Case 'FleetColumns is the canonical column list' { Want-Eq ($script:FleetColumns -join ',') ($specColumns -join ',') 'FleetColumns' }
Test-Case 'ConvertTo-DiscoveredRows opens no file (static)' {
    $txt = $found['ConvertTo-DiscoveredRows']
    foreach ($bad in 'Get-Content','ReadAll','OpenRead','OpenText','StreamReader','Import-Csv','Import-PowerShellDataFile','Select-String','FileStream') { Want ($txt -notmatch [regex]::Escape($bad)) "uses $bad" }
}

# ================================================================ the remote script
$rs = [string]$script:DiscoverRemoteScript
Test-Case 'remote script: ASCII only' { Want (@($rs.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count -eq 0) 'non-ASCII characters' }
Test-Case 'remote script: parses, no PowerShell 7-only constructs' {
    $tk = $null; $er = $null
    $sa = [System.Management.Automation.Language.Parser]::ParseInput($rs, [ref]$tk, [ref]$er)
    Want ($er.Count -eq 0) ('parse errors: ' + (@($er | ForEach-Object { $_.Message }) -join '; '))
    $new = @($sa.FindAll({ param($n) $n.GetType().Name -in 'TernaryExpressionAst','PipelineChainAst' }, $true))
    Want ($new.Count -eq 0) "PowerShell 7-only constructs: $($new.Count)"
    $badTok = @($tk | Where-Object { $_.Kind -in 'QuestionQuestion','QuestionQuestionEquals','QuestionDot','QuestionLBracket','AndAnd','OrOr' })
    # the same by the syntax tree, which also sees inside "...$(...)..." strings
    $badTok += @($sa.FindAll({ param($n) ($n -is [System.Management.Automation.Language.BinaryExpressionAst] -and "$($n.Operator)" -eq 'QuestionQuestion') -or ($n -is [System.Management.Automation.Language.AssignmentStatementAst] -and "$($n.Operator)" -eq 'QuestionQuestionEquals') -or (($n -is [System.Management.Automation.Language.MemberExpressionAst] -or $n -is [System.Management.Automation.Language.IndexExpressionAst]) -and $n.NullConditional) }, $true))
    Want ($badTok.Count -eq 0) ('PowerShell 7-only tokens: ' + (@($badTok | ForEach-Object { $_.Text }) -join ' '))
    Want ($rs -notmatch '\?\?|\?\.') "text contains '??' or '?.'"
    Want ($rs -notmatch '(?i)-Parallel\b') 'uses -Parallel'
    Want ($rs -notmatch '(?i)\bclean\s*\{') 'uses a clean block'
}
Test-Case 'remote script: one block, no blank line inside it, blank lines after it' {
    $lines = @(($rs -replace "`r`n", "`n") -split "`n")
    $nonEmpty = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim()) { $i } })
    Want-Eq $lines[$nonEmpty[0]] '& {' 'first line'
    Want-Eq $lines[$nonEmpty[-1]] '}' 'last line'
    $inner = @($lines[$nonEmpty[0]..$nonEmpty[-1]] | Where-Object { -not $_.Trim() })
    Want ($inner.Count -eq 0) "$($inner.Count) blank line(s) inside the block"
    Want (($lines.Count - 1 - $nonEmpty[-1]) -ge 2) 'fewer than two blank lines after the block'
}
Test-Case 'remote script: read-only and allow-list only (static)' {
    foreach ($pat in '(?i)\bSet-', '(?i)\bNew-(?!Object\b)', '(?i)\bRemove-', '(?i)\bAdd-Content', '(?i)\bOut-File', '(?i)\bStart-Service', '(?i)\bStop-', '(?i)\bRestart-', '(?i)\bRename-', '(?i)\bMove-', '(?i)\bCopy-', '(?i)\bRegister-',
                     '(?i)\bClear-', '(?i)\bStart-Process', '(?i)\bInvoke-', '(?i)\bExport-', '(?i)\bTee-Object', '(?i)\bWrite-',
                     '(?i)\.(SetValue|CreateSubKey|DeleteValue|DeleteSubKey|DeleteSubKeyTree|GetValueNames|OpenWrite|WriteAllText|WriteAllLines|WriteAllBytes|AppendAllText)\(', '(?i)\[(System\.)?IO\.File\]', '(?i)Get-ItemProperty', '(?i)\bGet-Item\b') {
        Want ($rs -notmatch $pat) "matches $pat"
    }
    Want ($rs -notmatch 'CLIENT_SECRET') 'mentions CLIENT_SECRET'
    Want ($rs -notmatch 'SSL_CERT_PASS') 'mentions SSL_CERT_PASS'
    $tk = $null; $er = $null
    $sa = [System.Management.Automation.Language.Parser]::ParseInput($rs, [ref]$tk, [ref]$er)
    Want (@($sa.FindAll({ param($n) $n -is [System.Management.Automation.Language.RedirectionAst] }, $true)).Count -eq 0) 'uses a redirection'
    $cmds = @($sa.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Sort-Object -Unique)
    $allowed = 'Get-CimInstance','Get-Service','Join-Path','Test-Path','Get-Content','Select-String','Where-Object','ConvertTo-Json','New-Object'
    $other = @($cmds | Where-Object { $_ -notin $allowed })
    Want ($other.Count -eq 0) ('commands outside the read-only list: ' + ($other -join ', '))
    # Get-Content reads only install.properties ($pf) and application.properties ($ap); Select-String only the service XML ($xf)
    foreach ($ca in $sa.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in 'Get-Content','Select-String' }, $true)) {
        $argText = ($ca.CommandElements | Select-Object -Skip 1 | ForEach-Object { $_.Extent.Text }) -join ' '
        Want ($argText -match '^-LiteralPath \$(pf|ap|xf)\b') "reads something else: $($ca.Extent.Text)"
    }
    foreach ($m in [regex]::Matches($rs, 'OpenSubKey\(([^()]*)\)')) { Want ($m.Groups[1].Value -notmatch ',') "OpenSubKey with more than one argument: $($m.Value)" }
    foreach ($m in [regex]::Matches($rs, '\.GetValue\(([^()]*)\)')) { Want ($m.Groups[1].Value -in "'DisplayName'", "'DisplayVersion'", "'InstallLocation'", '$vn') "GetValue of $($m.Groups[1].Value)" }
    $ar = [regex]::Match($rs, '\$allowR = @\(([^)]*)\)').Groups[1].Value -replace "[' ]", ''
    Want-Eq $ar 'WS1_SYSLOG_HOSTNAME,IS_NET_API_LOGON_USERNAME,InstallDir,WS1_INSTALLED_SERVICES' 'registry allow-list'
    Want ($ar -notmatch '(?i)PASS') 'registry allow-list names a PASS value'
    Want ($rs -match "if \(\`$vn -match 'PASS'\) \{ continue \}") 'no guard against value names containing PASS'
    $ap = [regex]::Match($rs, '\$allowP = @\(([^)]*)\)').Groups[1].Value -replace "[' ]", ''
    Want-Eq $ap 'INSTALL_DIR,TENANT_URL,TRUST_CERTS,SYSLOG_CONFIGURATIONS,PROXY_HOST,PROXY_PORT,PROXY_USER,NON_PROXY_HOSTS,FIPS_ENABLED,DIRECTORY_SYNC_SVC_PORT,USER_AUTH_SVC_PORT,KERBEROS_AUTH_SVC_PORT,VIRTUAL_APP_SYNC_SVC_PORT' 'install.properties allow-list'
    Want ($rs -match 'eks\\\.http\\\.server\\\.port') 'application.properties is not matched on eks.http.server.port'
}

function Invoke-LocalRemote { param([string]$Text)
    # runs the text the way a connector does: piped to PowerShell's standard input
    $o = $Text | & pwsh -NoLogo -NoProfile -NonInteractive -Command -
    return @($o) }
function Get-DiscoverLines { param($Out)
    $clean = @($Out | ForEach-Object { ([string]$_ -replace '\x1b\[[0-9;?]*[A-Za-z]', '' -replace '\x1b[=>]', '') })
    [pscustomobject]@{ Hits = @($clean | Where-Object { $_.Contains('DISCOVER_JSON:') }); Other = @($clean | Where-Object { $_.Trim() -and -not $_.Contains('DISCOVER_JSON:') }) } }

Test-Case 'remote script runs in pwsh here (no registry, CIM or services): no throw, exactly one DISCOVER_JSON line that parses' {
    $out = Invoke-LocalRemote $rs
    $g = Get-DiscoverLines $out
    Want ($g.Hits.Count -eq 1) "DISCOVER_JSON lines: $($g.Hits.Count)"
    Want ($g.Other.Count -eq 0) ('other output: ' + ($g.Other -join ' / '))
    if ($g.Hits.Count -eq 1) {
        Want ($g.Hits[0].StartsWith('DISCOVER_JSON:')) 'the line does not start with DISCOVER_JSON: once terminal codes are removed'
        $j = $g.Hits[0].Substring($g.Hits[0].IndexOf('DISCOVER_JSON:') + 14) | ConvertFrom-Json
        foreach ($k in 'Computer','Fqdn','InstalledVersion','InstallLocation','InstallRoot','Services','Registry','Properties','JavaFlag','Cert','Errors') { Want ($null -ne $j.PSObject.Properties[$k]) "field $k missing" }
        Want-Eq $j.InstallRoot 'C:\Program Files\Access Connector' 'InstallRoot'
        Want (@($j.Services).Count -eq 0) 'services found on this Mac'
        Want (@($j.Properties.PSObject.Properties).Count -eq 0) 'properties found on this Mac'
        Want ($null -eq $j.Cert) 'Cert read on this Mac'
        Want (@($j.Errors | Where-Object { $_ -match '^registry ' }).Count -ge 1) 'the missing registry was not recorded in Errors'
    }
}
Test-Case 'remote script on a fixture install folder: allow-listed keys only, no other value, Java flag' {
    $fx = Join-Path $runDir 'connector-root/Access Connector'
    $null = New-Item -ItemType Directory -Path (Join-Path $fx 'Support/scripts') -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $fx 'Directory Sync Service') -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $fx 'User Auth Service') -Force
    $propLines = @('# install.properties fixture: placeholders only', 'INSTALL_DIR=D:\Program Files\Access Connector\', 'TENANT_URL=https://TENANT1.us1.example.com',
        'DIRECTORY_SYNC_CLIENT_SECRET=placeholder-not-a-secret-1', 'SSL_CERT_PASS=placeholder-not-a-secret-2', 'SSL_CERT=', 'ES_CONFIG_FILE=',
        'PROXY_PORT = 3128', 'FIPS_ENABLED=false', 'SOME_OTHER_KEY=placeholder-not-a-secret-3', '#TENANT_URL=https://commented.example.com',
        'a line without an equals sign', '=placeholder-not-a-secret-4', 'TRUST_CERTS=C:\ProgramData\AccessConnectorUpdate\TrustedCerts\root-ca.pem',
        ('PROXY_USER=EXAMPLE\jos' + [char]0x00E9))
    [IO.File]::WriteAllText((Join-Path $fx 'Support/scripts/install.properties'), (($propLines -join "`r`n") + "`r`n"))
    [IO.File]::WriteAllText((Join-Path $fx 'Directory Sync Service/DirectorySyncService.xml'), '<service><arguments>-Xmx1g -XX:-UseBASE64Intrinsics</arguments></service>')
    [IO.File]::WriteAllText((Join-Path $fx 'User Auth Service/UserAuthService.xml'), '<service><arguments>-Xmx1g</arguments></service>')
    $lit = "'C:\Program Files\Access Connector'"
    Want ((([regex]::Matches($rs, [regex]::Escape($lit))).Count) -eq 1) 'the default install folder is not written exactly once'
    $out = Invoke-LocalRemote ($rs.Replace($lit, "'" + $fx + "'"))
    $g = Get-DiscoverLines $out
    Want ($g.Hits.Count -eq 1) "DISCOVER_JSON lines: $($g.Hits.Count)"
    if ($g.Hits.Count -eq 1) {
        $raw = $g.Hits[0]
        Want ($raw -notmatch 'placeholder-not-a-secret') 'a value of a key outside the allow-list was emitted'
        foreach ($bad in 'CLIENT_SECRET','SSL_CERT','ES_CONFIG_FILE','SOME_OTHER_KEY','commented.example.com') { Want ($raw -notmatch $bad) "output mentions $bad" }
        $j = $raw.Substring($raw.IndexOf('DISCOVER_JSON:') + 14) | ConvertFrom-Json
        Want-Eq (@($j.Properties.PSObject.Properties.Name) -join ',') 'INSTALL_DIR,TENANT_URL,PROXY_PORT,FIPS_ENABLED,TRUST_CERTS,PROXY_USER' 'Properties keys'
        Want (@($raw.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count -eq 0) 'the output line is not ASCII'
        Want ($raw.Contains('EXAMPLE\\jos\u00e9')) 'a non-ASCII character was not sent as a \u escape'
        Want-Eq $j.Properties.PROXY_USER ('EXAMPLE\jos' + [char]0x00E9) 'PROXY_USER (non-ASCII, escaped and read back)'
        Want-Eq $j.Properties.INSTALL_DIR 'D:\Program Files\Access Connector\' 'INSTALL_DIR'
        Want-Eq $j.Properties.PROXY_PORT '3128' 'PROXY_PORT'
        Want-Eq $j.InstallRoot $fx 'InstallRoot'
        Want ($j.JavaFlag -eq $true) 'JavaFlag not found'
    }
}

# ================================================================ findings to rows
Test-Case 'four services with Kerberos, matching PFX and config file' {
    $rows = @(ConvertTo-DiscoveredRows -Results @(New-Result 'connector1.example.local' (New-Data -JavaFlag -Props @{ TRUST_CERTS = 'C:\ProgramData\AccessConnectorUpdate\TrustedCerts\root-ca.pem'; SYSLOG_CONFIGURATIONS = 'syslog.example.local:514' } -Reg @{ WS1_SYSLOG_HOSTNAME = 'syslog.example.local:514' })) -StagingRoot $stage)
    Want ($rows.Count -eq 1) "rows: $($rows.Count)"
    Want ($rows[0] -is [System.Collections.Specialized.OrderedDictionary]) 'row is not an [ordered] dictionary'
    Want-Row $rows[0] @{ Group = 'TENANT1'; Host = 'connector1.example.local'; Installer = 'Installers\Access-Connector-Installer-26.10.0.0.exe'; InstallerVersion = '26.10.0.0'
        ConfigFile = 'Configs\tenant1.us1.example.com-es-config.json'; Services = $all4; ServiceAccount = $SA; Pfx = 'ChildCerts\connector.example.local.pfx'
        TrustStore = 'TrustedCerts'; Syslog = 'syslog.example.local:514'
        Notes = 'installed 26.10.0.0; tenant tenant1.us1.example.com; Java4Shell patch flag present: set JavaPatchDir in the fleet file' } 'row'
}
Test-Case 'three services without Kerberos (account from the Virtual App service, syslog from install.properties)' {
    $d = New-Data -Tenant 'TENANT2' -Svc 'DirectorySyncService','UserAuthService','VirtualAppService' -Reg @{ IS_NET_API_LOGON_USERNAME = $null } -Props @{ SYSLOG_CONFIGURATIONS = 'syslog.example.local:1514' }
    $rows = @(ConvertTo-DiscoveredRows -Results @(New-Result 'connector2.example.local' $d) -StagingRoot $stage)
    Want-Row $rows[0] @{ Group = 'TENANT2'; Host = 'connector2.example.local'; Installer = 'Installers\Access-Connector-Installer-26.10.0.0.exe'; InstallerVersion = '26.10.0.0'
        ConfigFile = 'Configs\tenant2.us1.example.com-es-config.json'; Services = $three; ServiceAccount = $SA; Syslog = 'syslog.example.local:1514'
        Notes = 'installed 26.10.0.0; tenant tenant2.us1.example.com' } 'row'
}
Test-Case 'two services: no ServiceAccount even when the registry has one' {
    $rows = @(ConvertTo-DiscoveredRows -Results @(New-Result 'connector2b.example.local' (New-Data -Tenant 'TENANT2' -Svc 'DirectorySyncService','UserAuthService')) -StagingRoot $stage)
    Want-Eq $rows[0]['Services'] 'DirectorySyncService,UserAuthService' 'Services'
    Want-Eq $rows[0]['ServiceAccount'] '' 'ServiceAccount'
    Want ($rows[0]['Notes'] -notmatch 'fill:') "Notes: $($rows[0]['Notes'])"
}
Test-Case 'self-signed served certificate: no Pfx even when a file has its name, note says RepairCertificate' {
    $c = New-Cert -Subject 'connector3.example.local' -Names @('connector3.example.local') -Issuer 'Internal Root CA 2026-11-22 10:00:00' -SelfSigned
    $rows = @(ConvertTo-DiscoveredRows -Results @(New-Result 'connector3.example.local' (New-Data -Cert $c)) -StagingRoot $stage)
    Want-Row $rows[0] @{ Group = 'TENANT1'; Host = 'connector3.example.local'; Installer = 'Installers\Access-Connector-Installer-26.10.0.0.exe'; InstallerVersion = '26.10.0.0'
        ConfigFile = 'Configs\tenant1.us1.example.com-es-config.json'; Services = $all4; ServiceAccount = $SA
        Notes = "installed 26.10.0.0; tenant tenant1.us1.example.com; Kerberos Auth serves the installer's self-signed certificate: set Pfx, then run -Mode RepairCertificate" } 'row'
}
Test-Case 'Kerberos not running / certificate not readable: blank Pfx with a reason' {
    $rows = @(ConvertTo-DiscoveredRows -Results @(
        (New-Result 'k1.example.local' (New-Data -Cert $null)),
        (New-Result 'k2.example.local' (New-Data -Cert (New-Cert -NotOk -Subject '' -Names @() -Message 'no answer on port 443 within 5 seconds')))) -StagingRoot $stage)
    $r1 = Get-Row $rows 'k1.example.local'; $r2 = Get-Row $rows 'k2.example.local'
    Want-Eq $r1['Pfx'] '' 'k1 Pfx'
    Want ($r1['Notes'] -match 'set Pfx if a PFX is used: without one the installer makes a self-signed certificate; Kerberos Auth is not running, so its certificate was not read$' -and $r1['Notes'] -notmatch 'fill:') "k1 Notes: $($r1['Notes'])"
    Want ($r2['Notes'] -match 'set Pfx if a PFX is used: without one the installer makes a self-signed certificate; Kerberos Auth certificate not read: no answer on port 443 within 5 seconds$') "k2 Notes: $($r2['Notes'])"
}
Test-Case 'PFX matched by a certificate name; two candidate files means blank' {
    $c1 = New-Cert -Subject 'kerberos.example.local' -Names @('kerberos.example.local', 'other.example.local')
    $c2 = New-Cert -Subject 'connector.example.local' -Names @('connector.example.local', 'other.example.local')
    $rows = @(ConvertTo-DiscoveredRows -Results @((New-Result 'p1.example.local' (New-Data -Cert $c1)), (New-Result 'p2.example.local' (New-Data -Cert $c2))) -StagingRoot $stage)
    Want-Eq (Get-Row $rows 'p1.example.local')['Pfx'] 'ChildCerts\other.example.local.pfx' 'p1 Pfx'
    Want-Eq (Get-Row $rows 'p2.example.local')['Pfx'] '' 'p2 Pfx'
}
Test-Case 'non-default ports, proxy with user, install folder on D:, FIPS true; unknown property ignored' {
    $d = New-Data -Tenant 'TENANT5' -Props @{ INSTALL_DIR = 'D:\Program Files\Access Connector\'; FIPS_ENABLED = 'true'; DIRECTORY_SYNC_SVC_PORT = '9080'; USER_AUTH_SVC_PORT = '8090'
        KERBEROS_AUTH_SVC_PORT = '8443'; VIRTUAL_APP_SYNC_SVC_PORT = '9008'; PROXY_HOST = 'proxy.example.local'; PROXY_PORT = '3128'; PROXY_USER = 'EXAMPLE\svc-proxy'
        NON_PROXY_HOSTS = 'host1.example.local|host2.example.local'; SSL_CERT_PASS = 'placeholder-not-a-secret-9' } -Cert (New-Cert -Subject 'connector.example.local' -Names @('connector.example.local'))
    $rows = @(ConvertTo-DiscoveredRows -Results @(New-Result 'connector5.example.local' $d) -StagingRoot $stage)
    Want-Row $rows[0] @{ Group = 'TENANT5'; Host = 'connector5.example.local'; Installer = 'Installers\Access-Connector-Installer-26.10.0.0.exe'; InstallerVersion = '26.10.0.0'
        ConfigFile = 'Configs\tenant5.us1.example.com-es-config.json'; Services = $all4; ServiceAccount = $SA; Pfx = 'ChildCerts\connector.example.local.pfx'
        InstallDir = 'D:\Program Files'; EnableFips = 'TRUE'; DirectorySyncPort = '9080'; KerberosAuthPort = '8443'; VirtualAppPort = '9008'
        ProxyHost = 'proxy.example.local'; ProxyPort = '3128'; ProxyUser = 'EXAMPLE\svc-proxy'; NonProxyHosts = 'host1.example.local|host2.example.local'
        Notes = 'installed 26.10.0.0; tenant tenant5.us1.example.com' } 'row'
    Want (@($rows[0].Values | Where-Object { [string]$_ -match 'placeholder-not-a-secret' }).Count -eq 0) 'a property outside the allow-list reached a row'
}
Test-Case 'proxy columns stay blank without PROXY_HOST; install folder from the registry when INSTALL_DIR is absent' {
    $d = New-Data -Props @{ PROXY_PORT = '3128'; PROXY_USER = 'EXAMPLE\svc-proxy'; INSTALL_DIR = $null } -Reg @{ InstallDir = 'E:\Apps\' }
    $rows = @(ConvertTo-DiscoveredRows -Results @(New-Result 'px.example.local' $d) -StagingRoot $stage)
    foreach ($c in 'ProxyHost','ProxyPort','ProxyUser','NonProxyHosts') { Want-Eq $rows[0][$c] '' $c }
    Want-Eq $rows[0]['InstallDir'] 'E:\Apps' 'InstallDir'
}
Test-Case 'two hosts of one tenant with different services: GROUP and GROUP-2 (then -3), identical rows share' {
    $res = @(
        (New-Result 'c1.example.local' (New-Data -Tenant 'TENANT6')),
        (New-Result 'c2.example.local' (New-Data -Tenant 'TENANT6' -Svc 'DirectorySyncService','UserAuthService','VirtualAppService')),
        (New-Result 'c3.example.local' (New-Data -Tenant 'TENANT6')),
        (New-Result 'c4.example.local' (New-Data -Tenant 'TENANT6' -Reg @{ WS1_SYSLOG_HOSTNAME = 'syslog.example.local:514' })),
        (New-Result 'c5.example.local' (New-Data -Tenant 'TENANT6' -Svc 'DirectorySyncService','UserAuthService','VirtualAppService')))
    $rows = @(ConvertTo-DiscoveredRows -Results $res -StagingRoot $stage)
    Want-Eq (@($rows | ForEach-Object { $_['Host'] }) -join ',') 'c1.example.local,c2.example.local,c3.example.local,c4.example.local,c5.example.local' 'row order'
    Want-Eq (@($rows | ForEach-Object { $_['Group'] }) -join ',') 'TENANT6,TENANT6-2,TENANT6,TENANT6-3,TENANT6-2' 'groups'
}
Test-Case 'a suffix never takes a name already used by another group' {
    $entry = @{ Name = 'SITE-2'; Services = $all4; Connectors = @(@{ Host = 'x1.example.local' }) }
    $res = @(
        (New-Result 'x1.example.local' (New-Data -Tenant 'zzz') -Entry $entry),
        (New-Result 'x2.example.local' (New-Data -Tenant 'site')),
        (New-Result 'x3.example.local' (New-Data -Tenant 'site' -Svc 'DirectorySyncService','UserAuthService')))
    $rows = @(ConvertTo-DiscoveredRows -Results $res -StagingRoot $stage)
    Want-Eq (@($rows | ForEach-Object { $_['Group'] }) -join ',') 'SITE-2,SITE,SITE-3' 'groups'
}
Test-Case 'unreachable host: Group blank, only Host, SshUser and Notes' {
    $rows = @(ConvertTo-DiscoveredRows -Results @(New-Result 'connector9.example.local' $null -SshUser 'admin9' -ErrorText "ssh: connect to host connector9.example.local port 22:`nConnection refused") -StagingRoot $stage)
    Want-Row $rows[0] @{ Host = 'connector9.example.local'; SshUser = 'admin9'; Notes = 'not reached: ssh: connect to host connector9.example.local port 22: Connection refused' } 'row'
    $rows = @(ConvertTo-DiscoveredRows -Results @(New-Result 'connector8.example.local' $null) -StagingRoot $stage)
    Want-Eq $rows[0]['Notes'] 'not reached: no answer' 'Notes without an error text'
}
Test-Case "host from a fleet entry whose settings differ: 'differs from fleet entry' note, entry Name as Group" {
    $entry = @{ Name = 'BRANCH'; Installer = 'Installers\Access-Connector-Installer-26.10.0.0.exe'; ConfigFile = 'Configs/tenant1.us1.example.com-es-config.json'; Services = $all4
        ServiceAccount = $SA; Pfx = 'ChildCerts\connector.example.local.pfx'; TrustStore = 'TrustedCerts'; Syslog = 'syslog.example.local:514'
        Connectors = @(@{ Host = 'connector7.example.local'; SshUser = 'admin7' }, @{ Host = 'connector8.example.local' }) }
    $d = New-Data -Svc 'DirectorySyncService','UserAuthService','VirtualAppService' -Props @{ TRUST_CERTS = 'C:\ProgramData\AccessConnectorUpdate\TrustedCerts\root-ca.pem'; USER_AUTH_SVC_PORT = '9090' } -Reg @{ WS1_SYSLOG_HOSTNAME = 'syslog2.example.local:514' }
    $rows = @(ConvertTo-DiscoveredRows -Results @(New-Result 'connector7.example.local' $d -Entry $entry) -StagingRoot $stage)
    Want-Eq $rows[0]['Group'] 'BRANCH' 'Group'
    Want-Eq $rows[0]['SshUser'] 'admin7' 'SshUser (from the fleet connector)'
    Want ($rows[0]['Notes'] -match '(^|; )differs from fleet entry BRANCH: Services, Syslog, UserAuthPort$') "Notes: $($rows[0]['Notes'])"
    # the same entry, a connector that matches it (explicit default port and FIPS false count as the defaults)
    $entry2 = $entry.Clone(); $entry2['DirectorySyncPort'] = 8080; $entry2['EnableFips'] = $false
    $d2 = New-Data -Props @{ TRUST_CERTS = 'C:\ProgramData\AccessConnectorUpdate\TrustedCerts\root-ca.pem' } -Reg @{ WS1_SYSLOG_HOSTNAME = 'syslog.example.local:514' } -Cert (New-Cert -Subject 'connector.example.local' -Names @('connector.example.local'))
    $rows = @(ConvertTo-DiscoveredRows -Results @(New-Result 'connector8.example.local' $d2 -Entry $entry2) -StagingRoot $stage)
    Want ($rows[0]['Notes'] -notmatch 'differs') "matching connector Notes: $($rows[0]['Notes'])"
    Want-Eq $rows[0]['Group'] 'BRANCH' 'Group of the matching connector'
}
Test-Case 'config file named by the tenant first label only (tenant1-es-config.json)' {
    $st = New-Staging 'label-config' -Installers @('Access-Connector-Installer-26.10.0.0.exe') -Configs @('tenant1-es-config.json', 'tenant10-es-config.json', 'xtenant1.json')
    $rows = @(ConvertTo-DiscoveredRows -Results @(New-Result 'connector1.example.local' (New-Data -Svc 'DirectorySyncService','UserAuthService')) -StagingRoot $st)
    Want-Eq $rows[0]['ConfigFile'] 'Configs\tenant1-es-config.json' 'ConfigFile (whole-word label match, not tenant10 or xtenant1)'
}
Test-Case 'host from a fleet entry: unmatched Installer, ConfigFile and Pfx taken from the entry' {
    $st = New-Staging 'entry-fill' -Installers @('a-26.05.exe', 'b-26.10.exe') -Configs @('unrelated.json')
    $entry = @{ Name = 'TENANT1'; Installer = 'Installers/Access-Connector-Installer-26.10.0.0.exe'; InstallerVersion = '26.10.0.0'; ExpectVersionPrefix = '26.10'
        ConfigFile = 'Configs\tenant1-es-config.json'; Services = $all4; ServiceAccount = $SA; Pfx = 'ChildCerts\connector.example.local.pfx'
        Connectors = @(@{ Host = 'connector1.example.local' }) }
    $rows = @(ConvertTo-DiscoveredRows -Results @(New-Result 'connector1.example.local' (New-Data) -Entry $entry) -StagingRoot $st)
    Want-Eq $rows[0]['Installer'] 'Installers\Access-Connector-Installer-26.10.0.0.exe' 'Installer'
    Want-Eq $rows[0]['InstallerVersion'] '26.10.0.0' 'InstallerVersion'
    Want-Eq $rows[0]['ExpectVersionPrefix'] '' 'ExpectVersionPrefix (never taken: Excel would damage it)'
    Want-Eq $rows[0]['ConfigFile'] 'Configs\tenant1-es-config.json' 'ConfigFile'
    Want-Eq $rows[0]['Pfx'] 'ChildCerts\connector.example.local.pfx' 'Pfx'
    Want ($rows[0]['Notes'] -match '(^|; )taken from fleet entry TENANT1: Installer, InstallerVersion, ConfigFile, Pfx(;|$)') "Notes: $($rows[0]['Notes'])"
    Want ($rows[0]['Notes'] -notmatch 'fill:') "nothing left to fill: $($rows[0]['Notes'])"
}
Test-Case 'config file match: a longer host name or another tenant does not count; a first-name-part match is noted' {
    $st = New-Staging 'anchor-config' -Configs @('dev.tenant1.us1.example.com-es-config.json', 'xtenant1.us1.example.com.json')
    $rows = @(ConvertTo-DiscoveredRows -Results @(New-Result 'connector1.example.local' (New-Data -Svc 'DirectorySyncService','UserAuthService')) -StagingRoot $st)
    Want-Eq $rows[0]['ConfigFile'] '' 'ConfigFile (dev.tenant1... and xtenant1... are other names)'
    $st2 = New-Staging 'label-other-host' -Configs @('tenant1.eu1.example.com-es-config.json')
    $rows = @(ConvertTo-DiscoveredRows -Results @(New-Result 'connector1.example.local' (New-Data -Svc 'DirectorySyncService','UserAuthService')) -StagingRoot $st2)
    Want-Eq $rows[0]['ConfigFile'] '' 'ConfigFile (the label is in a name that holds another host)'
    $st3 = New-Staging 'label-noted' -Configs @('tenant1-es-config.json')
    $rows = @(ConvertTo-DiscoveredRows -Results @(New-Result 'connector1.example.local' (New-Data -Svc 'DirectorySyncService','UserAuthService')) -StagingRoot $st3)
    Want ($rows[0]['Notes'] -match "ConfigFile matched by the tenant's first name part only \(tenant1\): check it") "Notes: $($rows[0]['Notes'])"
}
Test-Case 'group settings differing only in case: one group, the fleet entry spelling' {
    $entry = @{ Name = 'TENANT1'; Services = $all4; ServiceAccount = 'EXAMPLE\SVC-ACCESS'; Connectors = @(@{ Host = 'c1.example.local' }, @{ Host = 'c2.example.local' }) }
    $d1 = New-Data -Reg @{ IS_NET_API_LOGON_USERNAME = 'example\svc-access' }
    $d2 = New-Data -Reg @{ IS_NET_API_LOGON_USERNAME = 'EXAMPLE\SVC-ACCESS' }
    $rows = @(ConvertTo-DiscoveredRows -Results @((New-Result 'c1.example.local' $d1 -Entry $entry), (New-Result 'c2.example.local' $d2 -Entry $entry)) -StagingRoot $stage)
    Want-Eq ((@($rows | ForEach-Object { $_['Group'] })) -join ',') 'TENANT1,TENANT1' 'Groups'
    Want-Eq $rows[0]['ServiceAccount'] 'EXAMPLE\SVC-ACCESS' 'ServiceAccount spelling'
}
Test-Case 'trusted certificates: TrustStore from the fleet entry, else a note; read errors are noted' {
    $empty = New-Staging 'no-trusted'
    $entry = @{ Name = 'TENANT1'; Services = $all4; ServiceAccount = $SA; TrustStore = 'CA-Certs'; Connectors = @(@{ Host = 'c1.example.local' }) }
    $d = New-Data -Props @{ TRUST_CERTS = 'C:\ProgramData\AccessConnectorUpdate\TrustedCerts\root-ca.pem' }
    $rows = @(ConvertTo-DiscoveredRows -Results @(New-Result 'c1.example.local' $d -Entry $entry) -StagingRoot $empty)
    Want-Eq $rows[0]['TrustStore'] 'CA-Certs' 'TrustStore from the entry'
    $rows = @(ConvertTo-DiscoveredRows -Results @(New-Result 'c1.example.local' $d) -StagingRoot $empty)
    Want ($rows[0]['Notes'] -match 'the connector trusts extra CA certificates: set TrustStore') "Notes: $($rows[0]['Notes'])"
    $j = ConvertTo-Json -InputObject $d -Depth 6 | ConvertFrom-Json; $j.Errors = @('install.properties: access denied')
    $rows = @(ConvertTo-DiscoveredRows -Results @(New-Result 'c1.example.local' $j) -StagingRoot $empty)
    Want ($rows[0]['Notes'] -match 'not read on the connector: install.properties: access denied') "Notes: $($rows[0]['Notes'])"
}
Test-Case 'from the fleet entry: InstallerVersion padded to four parts; the entry trust folder kept; no first-name-part match in a dotted name' {
    $st = New-Staging 'entry-rules' -Installers @('a.exe', 'b.exe') -Configs @('tenant1.eu.json') -Trusted @('root-ca.pem')
    $entry = @{ Name = 'TENANT1'; Installer = 'Installers\x-26.10.exe'; InstallerVersion = '26.10'; Services = $all4; ServiceAccount = $SA; TrustStore = 'Certs\Corp'; Connectors = @(@{ Host = 'c1.example.local' }) }
    $d = New-Data -Props @{ TRUST_CERTS = 'C:\ProgramData\AccessConnectorUpdate\TrustedCerts\root-ca.pem' }
    $rows = @(ConvertTo-DiscoveredRows -Results @(New-Result 'c1.example.local' $d -Entry $entry) -StagingRoot $st)
    Want-Eq $rows[0]['InstallerVersion'] '26.10.0.0' 'InstallerVersion'
    Want-Eq $rows[0]['TrustStore'] 'Certs\Corp' 'TrustStore'
    Want-Eq $rows[0]['ConfigFile'] '' 'ConfigFile (tenant1.eu.json holds another dotted name)'
}
Test-Case 'a connector that differs from its fleet entry takes -2; the one that matches keeps the name' {
    $entry = @{ Name = 'TENANT1'; Services = $all4; ServiceAccount = $SA; Syslog = 'syslog.example.local:514'; Connectors = @(@{ Host = 'c1.example.local' }, @{ Host = 'c2.example.local' }) }
    $bad = New-Data -Reg @{ WS1_SYSLOG_HOSTNAME = 'sylog.example.local:514' }
    $ok = New-Data -Reg @{ WS1_SYSLOG_HOSTNAME = 'syslog.example.local:514' }
    $rows = @(ConvertTo-DiscoveredRows -Results @((New-Result 'c1.example.local' $bad -Entry $entry), (New-Result 'c2.example.local' $ok -Entry $entry)) -StagingRoot $stage)
    Want-Eq ((@($rows | ForEach-Object { $_['Host'] + '=' + $_['Group'] })) -join ',') 'c1.example.local=TENANT1-2,c2.example.local=TENANT1' 'groups (row order kept)'
}
Test-Case 'several installers: Installer and InstallerVersion blank, fill note' {
    $rows = @(ConvertTo-DiscoveredRows -Results @(New-Result 'connector1.example.local' (New-Data)) -StagingRoot $stageTwoExe)
    Want-Eq $rows[0]['Installer'] '' 'Installer'
    Want-Eq $rows[0]['InstallerVersion'] '' 'InstallerVersion'
    Want-Eq $rows[0]['ConfigFile'] 'Configs\tenant1.us1.example.com-es-config.json' 'ConfigFile'
    Want ($rows[0]['Notes'] -match '(^|; )fill: Installer; set Pfx if a PFX is used') "Notes: $($rows[0]['Notes'])"
}
Test-Case 'two config files matching the tenant: ConfigFile blank; short version normalised to four parts' {
    $rows = @(ConvertTo-DiscoveredRows -Results @(New-Result 'connector1.example.local' (New-Data -Svc 'DirectorySyncService','UserAuthService')) -StagingRoot $stageTwoCfg)
    Want-Eq $rows[0]['ConfigFile'] '' 'ConfigFile'
    Want-Eq $rows[0]['Installer'] 'Installers\AccessConnector_26.10.exe' 'Installer'
    Want-Eq $rows[0]['InstallerVersion'] '26.10.0.0' 'InstallerVersion'
    Want ($rows[0]['Notes'] -match '(^|; )fill: ConfigFile(;|$)') "Notes: $($rows[0]['Notes'])"
}
Test-Case 'installer without a version in its name; no staging folder at all' {
    $rows = @(ConvertTo-DiscoveredRows -Results @(New-Result 'connector1.example.local' (New-Data -Svc 'DirectorySyncService')) -StagingRoot $stageNoVer)
    Want-Eq $rows[0]['Installer'] 'Installers\Access-Connector-Installer.exe' 'Installer'
    Want-Eq $rows[0]['InstallerVersion'] '' 'InstallerVersion'
    $rows = @(ConvertTo-DiscoveredRows -Results @(New-Result 'connector1.example.local' (New-Data)))
    foreach ($c in 'Installer','InstallerVersion','ConfigFile','Pfx','TrustStore') { Want-Eq $rows[0][$c] '' "$c without a staging folder" }
    Want ($rows[0]['Notes'] -match 'fill: Installer, ConfigFile; set Pfx if a PFX is used') "Notes: $($rows[0]['Notes'])"
}
Test-Case '-SshUser wins; Group from the tenant name made safe; GROUP when nothing names one' {
    $rows = @(ConvertTo-DiscoveredRows -Results @(
        (New-Result 'a.example.local' (New-Data -Tenant 'my_tenant') -SshUser 'admin7'),
        (New-Result 'b.example.local' (New-Data -Props @{ TENANT_URL = $null }))) -StagingRoot $stage -SshUser 'ops')
    $a = Get-Row $rows 'a.example.local'; $b = Get-Row $rows 'b.example.local'
    Want-Eq $a['SshUser'] 'ops' 'SshUser'
    Want-Eq $a['Group'] 'MY-TENANT' 'Group from my_tenant'
    Want ($a['Notes'] -match 'tenant my_tenant\.us1\.example\.com') "Notes: $($a['Notes'])"
    Want-Eq $b['Group'] 'GROUP' 'Group without a tenant'
    Want ($b['Notes'] -match 'fill: ConfigFile') "Notes: $($b['Notes'])"
}
Test-Case 'nothing installed: no Access Connector found; services from WS1_INSTALLED_SERVICES when the service list is empty' {
    $rows = @(ConvertTo-DiscoveredRows -Results @(New-Result 'n1.example.local' (New-Data -Bare)) -StagingRoot $stage)
    Want-Row $rows[0] @{ Group = 'GROUP'; Host = 'n1.example.local'; Installer = 'Installers\Access-Connector-Installer-26.10.0.0.exe'; InstallerVersion = '26.10.0.0'
        Notes = 'no Access Connector found; fill: ConfigFile, Services' } 'bare row'
    $d = New-Data -Svc @() -Reg @{ WS1_INSTALLED_SERVICES = 'DirectorySyncService,UserAuthService' }
    $rows = @(ConvertTo-DiscoveredRows -Results @(New-Result 'n2.example.local' $d) -StagingRoot $stage)
    Want-Eq $rows[0]['Services'] 'DirectorySyncService,UserAuthService' 'Services from the registry'
}
Test-Case 'rows come out one by one: one row collected with @() is one dictionary; every row has every column' {
    $one = @(ConvertTo-DiscoveredRows -Results @(New-Result 'connector1.example.local' (New-Data)) -StagingRoot $stage)
    Want ($one.Count -eq 1 -and $one[0] -is [System.Collections.IDictionary]) "one result gave $($one.Count) item(s) of type $($one[0].GetType().Name)"
    $many = @(ConvertTo-DiscoveredRows -Results @((New-Result 'a.example.local' (New-Data)), (New-Result 'b.example.local' $null)) -StagingRoot $stage)
    foreach ($r in $many) { Want-Eq (@($r.Keys) -join ',') ($specColumns -join ',') "columns of $($r['Host'])"; foreach ($c in $specColumns) { Want ($r[$c] -is [string]) "$($r['Host']) $c is not a string" } }
}

# ================================================================ transport: Invoke-ConnectorDiscovery against a fake ssh
if ($IsWindows) { 'PASS transport: skipped on Windows (the stand-in ssh is a shell script)' } else {
$fakeDir = Join-Path $runDir 'fake-bin'
$null = New-Item -ItemType Directory -Path $fakeDir -Force
$canned = 'DISCOVER_JSON:{"Computer":"CONNECTOR1","Fqdn":"connector1.example.local","InstalledVersion":"26.10.0.0","Services":[],"Registry":{},"Properties":{"TENANT_URL":"https://TENANT1.us1.example.com"},"JavaFlag":false,"Cert":null,"Errors":[]}'
$fake = @'
#!/bin/sh
# stand-in ssh for test_fleet_discover.ps1: no connection is made; the arguments are recorded
for a in "$@"; do printf '%s\n' "$a"; done > "$FAKE_SSH_DIR/args.txt"
case "$FAKE_SSH_MODE" in
  run)
    exec pwsh -NoLogo -NoProfile -NonInteractive -Command - ;;
  canned)
    cat > "$FAKE_SSH_DIR/stdin.txt"
    printf '#< CLIXML\r\n'
    printf '<Objs Version="1.1.0.1">DISCOVER_JSON:{"Computer":"WRONG"}\r\n'
    printf 'a line of other output\r\n'
    printf '\033[?1h%s\r\n' "$FAKE_SSH_JSON"
    printf '#< CLIXML\n<Objs Version="1.1.0.1"><S S="Error">x</S></Objs>\n' >&2 ;;
  fail)
    cat > /dev/null
    printf '#< CLIXML\n<Objs Version="1.1.0.1"><S S="Error">remote error record</S></Objs>\n' >&2
    printf 'ssh: connect to host connector9.example.invalid port 22: Connection refused\r\n' >&2
    exit 255 ;;
  nojson)
    cat > /dev/null; printf 'hello\n'; exit 0 ;;
  badjson)
    cat > /dev/null; printf 'DISCOVER_JSON:{not json\n'; exit 0 ;;
  hang)
    echo $$ > "$FAKE_SSH_DIR/pid.txt"
    exec sleep 30 ;;
esac
'@
[IO.File]::WriteAllText((Join-Path $fakeDir 'ssh'), ($fake -replace "`r`n", "`n"))
if (-not $IsWindows) { & chmod +x (Join-Path $fakeDir 'ssh') }
$savedPath = $env:PATH
$env:PATH = $fakeDir + [IO.Path]::PathSeparator + $env:PATH
$env:FAKE_SSH_DIR = $fakeDir
$env:FAKE_SSH_JSON = $canned
function Get-FakeArgs { @(Get-Content -LiteralPath (Join-Path $fakeDir 'args.txt')) }

Test-Case 'transport: real remote script through ssh to pwsh -Command - (fake ssh runs it here)' {
    $env:FAKE_SSH_MODE = 'run'
    $r = Invoke-ConnectorDiscovery -Conn ([pscustomobject]@{ Host = 'connector1.example.invalid'; SshUser = '' }) -TimeoutSec 60
    Want ($r.Ok -eq $true) "Ok is $($r.Ok) (Error: $($r.Error))"
    Want-Eq $r.Host 'connector1.example.invalid' 'Host'
    Want-Eq $r.Error '' 'Error'
    Want ($null -ne $r.Data -and $r.Data.InstallRoot -eq 'C:\Program Files\Access Connector') 'Data not parsed'
    $a = Get-FakeArgs
    Want-Eq $a[-1] 'powershell -NoProfile -NonInteractive -Command -' 'remote command'
    Want-Eq $a[-2] 'administrator@connector1.example.invalid' 'target (blank SshUser = administrator)'
    Want (($a -join ' ') -match 'BatchMode=yes') 'base ssh arguments missing'
}
Test-Case 'transport: CLIXML dropped, result found after terminal codes, script sent on standard input, SSH key passed' {
    $env:FAKE_SSH_MODE = 'canned'
    $SshKey = Join-Path $runDir 'no-such-key'
    $r = Invoke-ConnectorDiscovery -Conn ([pscustomobject]@{ Host = 'connector1.example.invalid'; SshUser = 'ops' })
    $SshKey = $null
    Want ($r.Ok -eq $true) "Ok is $($r.Ok) (Error: $($r.Error))"
    Want-Eq $r.Data.Computer 'CONNECTOR1' 'Computer (a CLIXML line was not dropped?)'
    Want-Eq $r.Data.Properties.TENANT_URL 'https://TENANT1.us1.example.com' 'TENANT_URL'
    $a = Get-FakeArgs
    Want-Eq $a[-2] 'ops@connector1.example.invalid' 'target'
    $ki = [array]::IndexOf($a, '-i')
    Want ($ki -ge 0 -and $a[$ki + 1] -eq (Join-Path $runDir 'no-such-key')) 'SSH key not passed with -i'
    $sent = [IO.File]::ReadAllText((Join-Path $fakeDir 'stdin.txt'))
    $expect = (([string]$script:DiscoverRemoteScript) -replace "`r`n", "`n").TrimEnd() + "`n`n`n"
    Want ($sent -ceq $expect) "standard input differs from the remote script ($($sent.Length) vs $($expect.Length) characters)"
    Want ($sent -notmatch "`r") 'standard input has CR characters'
}
Test-Case 'transport: ssh error text captured without CLIXML; no result' {
    $env:FAKE_SSH_MODE = 'fail'
    $r = Invoke-ConnectorDiscovery -Conn ([pscustomobject]@{ Host = 'connector9.example.invalid'; SshUser = 'administrator' })
    Want ($r.Ok -eq $false) 'Ok is true'
    Want ($null -eq $r.Data) 'Data is set'
    Want-Eq $r.Error 'ssh: connect to host connector9.example.invalid port 22: Connection refused' 'Error'
}
Test-Case 'transport: no result line, unreadable result line' {
    $env:FAKE_SSH_MODE = 'nojson'
    $r = Invoke-ConnectorDiscovery -Conn ([pscustomobject]@{ Host = 'connector1.example.invalid'; SshUser = 'administrator' })
    Want ($r.Ok -eq $false) 'nojson: Ok is true'
    Want-Eq $r.Error 'the connector returned no discovery result' 'nojson Error'
    $env:FAKE_SSH_MODE = 'badjson'
    $r = Invoke-ConnectorDiscovery -Conn ([pscustomobject]@{ Host = 'connector1.example.invalid'; SshUser = 'administrator' })
    Want ($r.Ok -eq $false) 'badjson: Ok is true'
    Want-Eq $r.Error 'the discovery result could not be read' 'badjson Error'
}
Test-Case 'transport: killed after the timeout' {
    $env:FAKE_SSH_MODE = 'hang'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-ConnectorDiscovery -Conn ([pscustomobject]@{ Host = 'connector1.example.invalid'; SshUser = 'administrator' }) -TimeoutSec 2
    $sw.Stop()
    Want ($r.Ok -eq $false) 'Ok is true'
    Want-Eq $r.Error 'no answer within 2 seconds' 'Error'
    Want ($sw.Elapsed.TotalSeconds -lt 12) "took $([int]$sw.Elapsed.TotalSeconds) seconds"
    $fakePid = [int](Get-Content -LiteralPath (Join-Path $fakeDir 'pid.txt') -First 1)
    $alive = $null; try { $alive = [Diagnostics.Process]::GetProcessById($fakePid); if ($alive.HasExited) { $alive = $null } } catch { $alive = $null }
    Want ($null -eq $alive) "the fake ssh (process $fakePid) is still running"
}
Test-Case 'transport: ssh missing from the PATH gives an Error, not a throw' {
    $keep = $env:PATH
    try {
        $env:PATH = Join-Path $runDir 'empty-bin'
        $r = Invoke-ConnectorDiscovery -Conn ([pscustomobject]@{ Host = 'connector1.example.invalid'; SshUser = 'administrator' })
    } finally { $env:PATH = $keep }
    Want ($r.Ok -eq $false) 'Ok is true'
    Want ($r.Error -match '^ssh could not be run: ') "Error: $($r.Error)"
}
$env:PATH = $savedPath
foreach ($v in 'FAKE_SSH_MODE','FAKE_SSH_DIR','FAKE_SSH_JSON') { Remove-Item -LiteralPath "Env:$v" -ErrorAction SilentlyContinue }

# ================================================================ the CSV
}
Test-Case 'Export-DiscoveredCsv: BOM, every field quoted, CRLF, canonical header, reads back the same, refuses an existing path' {
    $rows = @(ConvertTo-DiscoveredRows -Results @(
        (New-Result 'connector1.example.local' (New-Data -JavaFlag)),
        (New-Result 'connector9.example.local' $null -ErrorText 'ssh: Connection refused'),
        (New-Result 'connector5.example.local' (New-Data -Tenant 'TENANT5' -Props @{ PROXY_HOST = 'proxy.example.local'; NON_PROXY_HOSTS = 'host1.example.local|host2.example.local' }))) -StagingRoot $stage)
    $odd = [ordered]@{}; foreach ($c in $specColumns) { $odd[$c] = '' }
    $odd['Group'] = 'TENANT1'; $odd['Host'] = 'odd.example.local'; $odd['Notes'] = 'a "quoted" word, a comma; and a line' + "`n" + 'break'
    $rows += $odd
    $out = Join-Path $runDir 'out/discovered.csv'
    $null = New-Item -ItemType Directory -Path (Split-Path $out) -Force
    $written = Export-DiscoveredCsv -Rows $rows -Path $out
    Want-Eq $written $out 'returned path'
    $bytes = [IO.File]::ReadAllBytes($out)
    Want ($bytes.Length -gt 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) 'no UTF-8 byte-order mark'
    $text = [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    Want (([regex]::Matches($text, "`n")).Count -eq ([regex]::Matches($text, "`r`n")).Count + 1) 'line ends are not CRLF (one LF inside a quoted field is expected)'
    Want ($text.EndsWith("`r`n")) 'no CRLF after the last row'
    $first = $text.Substring(0, $text.IndexOf("`r`n"))
    Want-Eq $first ((@($specColumns | ForEach-Object { '"' + $_ + '"' })) -join ',') 'header line'
    $fieldRx = '"(?:[^"]|"")*"'
    foreach ($ln in ($text.TrimEnd() -split "`r`n")) { Want ($ln -match "^$fieldRx(,$fieldRx){23}$") "line not fully quoted with 24 fields: $ln" }
    Want ($text.Contains('"a ""quoted"" word, a comma; and a line' + "`n" + 'break"')) 'quotes were not doubled'
    $back = @(Import-Csv -LiteralPath $out -Encoding utf8)
    Want ($back.Count -eq $rows.Count) "read back $($back.Count) rows, wrote $($rows.Count)"
    Want-Eq (@($back[0].PSObject.Properties.Name) -join ',') ($specColumns -join ',') 'columns read back'
    for ($i = 0; $i -lt [Math]::Min($back.Count, $rows.Count); $i++) { foreach ($c in $specColumns) { Want-Eq $back[$i].$c $rows[$i][$c] "row $i $c read back" } }
    $before = [IO.File]::ReadAllBytes($out)
    $threw = $false; try { $null = Export-DiscoveredCsv -Rows $rows -Path $out } catch { $threw = $_.Exception.Message -match 'already exists' }
    Want $threw 'an existing path was not refused'
    Want ([Convert]::ToBase64String([IO.File]::ReadAllBytes($out)) -eq [Convert]::ToBase64String($before)) 'the existing file was changed'
    $threw = $false; try { $null = Export-DiscoveredCsv -Rows $rows -Path (Join-Path $runDir 'no-such-folder/x.csv') } catch { $threw = $true }
    Want $threw 'a missing folder was not refused'
    # rows handed over as one list inside an array are still written one per line
    $out2 = Join-Path $runDir 'out/nested.csv'
    $list = [System.Collections.Generic.List[object]]::new(); foreach ($r in $rows) { $list.Add($r) }
    $null = Export-DiscoveredCsv -Rows @(,$list) -Path $out2
    Want (@(Import-Csv -LiteralPath $out2).Count -eq $rows.Count) 'a nested list was not written row by row'
}

# ---------------------------------------------------------------- clean up and report
try { Get-ChildItem -LiteralPath $runDir -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { if (-not $IsWindows) { & chmod 600 $_.FullName } }; Remove-Item -LiteralPath $runDir -Recurse -Force } catch { "note: could not remove $runDir" }
if ($script:Failed) { 'TESTS FAILED'; exit 1 } else { 'ALL TESTS PASSED'; exit 0 }
