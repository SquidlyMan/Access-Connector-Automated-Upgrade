#Requires -Version 7
# Offline tests for the spreadsheet import (-ImportFleet): Read-FleetTable, ConvertFrom-FleetRows,
# ConvertTo-FleetFileText and Compare-FleetData, with fixtures built here (CSV in several encodings
# and delimiters, .xlsx built with System.IO.Compression). Contacts nothing.
#   pwsh -NoLogo -NoProfile -File tools/test_fleet_import.ps1
# Functions, $script:TenantKeys and $script:FleetColumns are loaded from the orchestrator through its
# AST (env FLEET_FUNC_FILES, semicolon-separated, names other files; a later file's function
# replaces an earlier one's). FLEET_EXAMPLE names another example fleet file. Fixtures go in a
# temporary folder that is removed at the end.
# Output: one line per case, PASS <name> or FAIL <name>: <why>; then ALL TESTS PASSED (exit 0) or
# TESTS FAILED (exit 1).

$ErrorActionPreference = 'Stop'
$testDir = $PSScriptRoot
$repo = if ($env:FLEET_REPO) { $env:FLEET_REPO } else { Split-Path -Parent $PSScriptRoot }
$orchDefault = Join-Path $repo 'FleetDeploy/Invoke-AccessConnectorUpgrade.ps1'
$files = if ($env:FLEET_FUNC_FILES) { @($env:FLEET_FUNC_FILES -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
         else { @($orchDefault) }

# ---------------------------------------------------------------- load functions from the AST
$constNames = @('script:FleetColumns', 'script:TenantKeys')
$code = [System.Collections.Generic.List[string]]::new()
$loadNote = ''
$fnCount = 0; $constFrom = @{}
foreach ($f in $files) {
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { "FAIL load functions: $f not found"; 'TESTS FAILED'; exit 1 }
    $tk = $null; $pe = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $f).Path, [ref]$tk, [ref]$pe)
    if ($pe.Count) { "FAIL load functions: $f does not parse (line $($pe[0].Extent.StartLineNumber): $($pe[0].Message))"; 'TESTS FAILED'; exit 1 }
    foreach ($n in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) { $code.Add($n.Extent.Text); $fnCount++ }
    foreach ($n in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $x.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $x.Left.VariablePath.UserPath -in $constNames }, $false)) {
        $code.Add($n.Extent.Text); $constFrom[$n.Left.VariablePath.UserPath] = Split-Path -Leaf $f }
}
. ([scriptblock]::Create($code -join "`n"))
$example = if ($env:FLEET_EXAMPLE) { $env:FLEET_EXAMPLE } else {
    $o = @($files | Where-Object { (Split-Path -Leaf $_) -eq 'Invoke-AccessConnectorUpgrade.ps1' } | Select-Object -First 1)
    if ($o.Count) { Join-Path (Split-Path -Parent $o[0]) 'fleet.example.psd1' } else { Join-Path $repo 'FleetDeploy/fleet.example.psd1' } }

# ---------------------------------------------------------------- harness
$script:Fails = 0
function Invoke-TestCase { param([string]$Name, [scriptblock]$Body)
    try { & $Body; "PASS $Name" }
    catch { $script:Fails++; "FAIL ${Name}: $($_.Exception.Message)" } }
function Assert-True { param($Condition, [string]$Why) if (-not $Condition) { throw $Why } }
function Assert-Equal { param($Actual, $Expected, [string]$What)
    if (-not ([string]$Actual -ceq [string]$Expected)) { throw "${What}: expected '$Expected', got '$Actual'" } }
function Assert-Has { param($List, [string]$Pattern, [string]$What)
    $l = @($List | Where-Object { $_ })
    if (-not @($l | Where-Object { $_ -match $Pattern }).Count) { throw "no $What matches /$Pattern/; got: $(if ($l.Count) { $l -join ' | ' } else { '(none)' })" } }
function Assert-None { param($List, [string]$What)
    $l = @($List | Where-Object { $_ })
    if ($l.Count) { throw "unexpected ${What}: $($l -join ' | ')" } }

$work = Join-Path ([IO.Path]::GetTempPath()) ('acu-test-import-' + $PID)
$null = New-Item -ItemType Directory -Force -Path $work
function Write-Fixture { param([string]$Name, [string]$Text, [string]$Encoding = 'utf8')
    $p = Join-Path $work $Name
    $u8 = [Text.UTF8Encoding]::new($false)
    $b = switch ($Encoding) {
        'utf8'          { $u8.GetBytes($Text) }
        'utf8bom'       { [byte[]](0xEF, 0xBB, 0xBF) + $u8.GetBytes($Text) }
        'utf16le'       { [byte[]](0xFF, 0xFE) + [Text.Encoding]::Unicode.GetBytes($Text) }
        'utf16le-nobom' { [Text.Encoding]::Unicode.GetBytes($Text) }
        'utf16be'       { [byte[]](0xFE, 0xFF) + [Text.Encoding]::BigEndianUnicode.GetBytes($Text) }
        '1252'          { [Text.Encoding]::GetEncoding(1252).GetBytes($Text) }
        default         { throw "unknown encoding $Encoding" }
    }
    if ($null -eq $b) { $b = [byte[]]@() }   # an empty array comes out of the switch as nothing
    [IO.File]::WriteAllBytes($p, [byte[]]$b)
    return $p }
function Join-Crlf { param([string[]]$Lines) return (($Lines -join "`r`n") + "`r`n") }
function ConvertTo-TestCsv { param([object[]]$Rows, [string]$Delimiter = ',')
    $lines = foreach ($r in $Rows) {
        (@($r) | ForEach-Object { $s = [string]$_; if ($s -match '[",;\t\r\n]') { '"' + $s.Replace('"', '""') + '"' } else { $s } }) -join $Delimiter }
    return (($lines -join "`r`n") + "`r`n") }
$cols = @('Group','Host','SshUser','Installer','InstallerVersion','ExpectVersionPrefix','ConfigFile','Services','ServiceAccount',
    'Pfx','TrustStore','Syslog','ForceReinstall','InstallDir','EnableFips','DirectorySyncPort','UserAuthPort','KerberosAuthPort',
    'VirtualAppPort','ProxyHost','ProxyPort','ProxyUser','NonProxyHosts','Notes')
function New-Row { param([hashtable]$Over = @{})
    $r = @{ Group = 'TENANT1'; Host = 'connector1.example.local'; Installer = 'Installers\Access-Connector-Installer.exe'
            ConfigFile = 'Configs\tenant1-es-config.json'; Services = 'DirectorySyncService,UserAuthService' }
    foreach ($k in $Over.Keys) { $r[$k] = $Over[$k] }
    return $r }
function Import-TestSheet { param([string]$Name, [object[]]$Rows, [string[]]$Columns = $cols, [string]$StagingRoot, [string]$Delimiter = ',', [string]$Encoding = 'utf8')
    $all = [System.Collections.Generic.List[object]]::new(); $all.Add($Columns)
    foreach ($r in $Rows) { $all.Add(@(foreach ($c in $Columns) { if ($r.Contains($c)) { [string]$r[$c] } else { '' } })) }
    $p = Write-Fixture $Name (ConvertTo-TestCsv $all.ToArray() $Delimiter) $Encoding
    $t = Read-FleetTable -Path $p
    $c = if ($StagingRoot) { ConvertFrom-FleetRows -Table $t -StagingRoot $StagingRoot } else { ConvertFrom-FleetRows -Table $t }
    return [pscustomobject]@{ Path = $p; Table = $t; Conv = $c
        Problems = @(@($t.Problems) + @($c.Problems) | Where-Object { $_ }); Warnings = @(@($t.Warnings) + @($c.Warnings) | Where-Object { $_ }) } }
function ConvertTo-Canon { param($x)
    # independent of Compare-FleetData: sorted keys, then JSON (keeps text / number / boolean apart)
    if ($x -is [System.Collections.IDictionary]) { $o = [ordered]@{}; foreach ($k in @($x.Keys | ForEach-Object { [string]$_ } | Sort-Object)) { $o[$k] = ConvertTo-Canon $x[$k] }; return $o }
    if ($x -is [System.Collections.IEnumerable] -and $x -isnot [string]) { return ,@(foreach ($i in $x) { ConvertTo-Canon $i }) }
    return $x }
function Get-CanonJson { param($x) ConvertTo-Json -InputObject (ConvertTo-Canon $x) -Depth 30 -Compress }
function Write-FleetText { param([string]$Name, [string]$Text)
    # as the orchestrator writes it: UTF-8 without a BOM
    $p = Join-Path $work $Name
    [IO.File]::WriteAllText($p, $Text, [Text.UTF8Encoding]::new($false))
    return $p }
function New-TestXlsx { param([string]$Name, [hashtable]$Parts)
    $p = Join-Path $work $Name
    $fs = [IO.File]::Create($p)
    try {
        $zip = [IO.Compression.ZipArchive]::new($fs, [IO.Compression.ZipArchiveMode]::Create)
        foreach ($k in $Parts.Keys) {
            $w = [IO.StreamWriter]::new($zip.CreateEntry($k).Open(), [Text.UTF8Encoding]::new($false))
            $w.Write($Parts[$k]); $w.Dispose() }
        $zip.Dispose()
    } finally { $fs.Dispose() }
    return $p }
$stamp = '2026-11-22 22:30'
$gen = 'Invoke-AccessConnectorUpgrade.ps1 1.5.0'
$rsq = [string][char]0x2019; $lsq = [string][char]0x2018; $eacute = [string][char]0x00E9

# ================================================================= cases
Invoke-TestCase 'load functions and constants from the AST' {
    foreach ($fn in 'Read-FleetTable','ConvertFrom-FleetRows','ConvertTo-FleetFileText','Compare-FleetData','Get-TenantOptionProblems','Get-StagingGaps') {
        Assert-True (Get-Command $fn -CommandType Function -ErrorAction SilentlyContinue) "$fn was not loaded from: $($files -join '; ')" }
    Assert-True ($constFrom['script:TenantKeys']) 'no $script:TenantKeys assignment was found'
    Assert-True ($constFrom['script:FleetColumns']) 'no $script:FleetColumns assignment was found'
    Assert-True (@($script:TenantKeys) -contains 'NonProxyHosts' -and @($script:TenantKeys) -contains 'Connectors') '$script:TenantKeys looks wrong'
    Assert-True (Test-Path -LiteralPath $example) "example fleet file not found: $example"
}
Invoke-TestCase "FleetColumns is the spec's column list, in order" {
    Assert-Equal ($script:FleetColumns -join ',') ($cols -join ',') 'FleetColumns'
}

# ---------------------------------------------------------------- round trip with the example
$rtLines = @(
    'Group,Host,SshUser,Installer,InstallerVersion,ExpectVersionPrefix,ConfigFile,Services,ServiceAccount,Pfx,TrustStore,Syslog,ForceReinstall,Notes'
    'TENANT1,connector1.example.local,administrator,Installers\Access-Connector-Installer.exe,26.10.0.0,26.10,Configs\tenant1-es-config.json,"DirectorySyncService,UserAuthService,KerberosAuthService,VirtualAppService",EXAMPLE\svc-access,ChildCerts\connector.example.local.pfx,TrustedCerts,syslog.example.local:514,FALSE,all four services'
    'TENANT1,connector2.example.local,administrator,,,,,,,,,,,'
    'TENANT2,connector3.example.local,,Installers\Access-Connector-Installer.exe,26.10.0.0,26.10,Configs\tenant2-es-config.json,"DirectorySyncService,UserAuthService,VirtualAppService",EXAMPLE\svc-access,,TrustedCerts,,FALSE,three services'
    'TENANT2,connector4.example.local,,,,,,,,,,,,'
)
$rtPath = Write-Fixture 'roundtrip.csv' (Join-Crlf $rtLines)
$rtTable = Read-FleetTable -Path $rtPath
$rtConv = ConvertFrom-FleetRows -Table $rtTable
$exData = Import-PowerShellDataFile -LiteralPath $example
$exTop = [ordered]@{}; foreach ($k in 'StagingRoot','StagingFolders','CentralLogRoot','InstallScript','JavaPatchDir') { if ($exData.ContainsKey($k)) { $exTop[$k] = $exData[$k] } }

Invoke-TestCase 'comma CSV: format, delimiter, encoding, columns, rows' {
    Assert-None $rtTable.Problems 'problems'
    Assert-Equal $rtTable.Format 'csv' 'Format'; Assert-Equal $rtTable.Delimiter ',' 'Delimiter'; Assert-Equal $rtTable.Encoding 'UTF-8' 'Encoding'
    Assert-Equal (@($rtTable.Columns | ForEach-Object { if ($_) { $_ } else { '-' } }) -join ',') 'Group,Host,SshUser,Installer,InstallerVersion,ExpectVersionPrefix,ConfigFile,Services,ServiceAccount,Pfx,TrustStore,Syslog,ForceReinstall,-' 'Columns (Notes ignored)'
    Assert-Equal (@($rtTable.Rows | ForEach-Object { $_.RowNumber }) -join ',') '2,3,4,5' 'row numbers'
    Assert-Equal $rtTable.Rows[0].Values['Services'] 'DirectorySyncService,UserAuthService,KerberosAuthService,VirtualAppService' 'quoted Services cell'
    Assert-True (-not $rtTable.Rows[0].Values.Contains('Notes')) 'Notes must not be in the row values'
}
Invoke-TestCase 'round trip: rows like fleet.example.psd1 convert without problems or warnings' {
    Assert-None $rtConv.Problems 'problems'; Assert-None $rtConv.Warnings 'warnings'
    Assert-Equal (@($rtConv.Tenants | ForEach-Object { $_.Name }) -join ',') 'TENANT1,TENANT2' 'groups'
}
Invoke-TestCase 'round trip: converted Tenants equal those in fleet.example.psd1 (same keys and values)' {
    $a = Get-CanonJson @($rtConv.Tenants); $b = Get-CanonJson @($exData.Tenants)
    if ($a -cne $b) { throw "converted: $a`n   example: $b" }
}
Invoke-TestCase 'round trip: written file reads back the same (Compare-FleetData empty), with the example top level' {
    $text = ConvertTo-FleetFileText -Tenants $rtConv.Tenants -TopLevel $exTop -Source 'roundtrip.csv' -Generator $gen -Stamp $stamp
    $p = Write-FleetText 'roundtrip.psd1' $text
    $back = Import-PowerShellDataFile -LiteralPath $p
    $d = @(Compare-FleetData -Tenants $rtConv.Tenants -TopLevel $exTop -Actual $back)
    Assert-None $d 'differences'
    $a = Get-CanonJson $back; $b = Get-CanonJson $exData
    if ($a -cne $b) { throw "the written file does not mean the same as fleet.example.psd1:`n $a`n $b" }
}
Invoke-TestCase 'round trip: new fleet file (no TopLevel) gets the defaults and commented examples' {
    $text = ConvertTo-FleetFileText -Tenants $rtConv.Tenants -TopLevel $null -Source 'roundtrip.csv' -Generator $gen -Stamp $stamp
    foreach ($want in @("    # StagingRoot = '\\fileserver.example.local\Deploy\AccessConnector'", '    # StagingFolders = @(', "    #     'Deploy/AccessConnector'",
                        "    # JavaPatchDir   = 'Installers\Java4shellPatch'", "    CentralLogRoot = 'FleetDeploy\FleetLogs'", "    InstallScript  = 'Silent Install\Install-AccessConnector.ps1'")) {
        Assert-True ($text.Contains($want)) "the text lacks: $want" }
    $p = Write-FleetText 'roundtrip-new.psd1' $text
    $back = Import-PowerShellDataFile -LiteralPath $p
    Assert-None @(Compare-FleetData -Tenants $rtConv.Tenants -TopLevel $null -Actual $back) 'differences'
    Assert-Equal ((@($back.Keys) | Sort-Object) -join ',') 'CentralLogRoot,InstallScript,Tenants' 'top-level keys'
}
Invoke-TestCase 'fleet file text: header, comment wording from fleet.example.psd1, UTF-8 without BOM, CRLF only' {
    $text = ConvertTo-FleetFileText -Tenants $rtConv.Tenants -TopLevel $null -Source 'roundtrip.csv' -Generator $gen -Stamp $stamp
    Assert-True ($text.Contains("# Generated by $gen from roundtrip.csv on $stamp.")) 'no generated-by line'
    Assert-True ($text.Contains('NO PASSWORDS BELONG IN THIS FILE')) 'no passwords line'
    $exLines = @(Get-Content -LiteralPath $example | ForEach-Object { $_.Trim() })
    foreach ($l in ($text -split "`r`n")) {
        if ($l -notmatch '^\s*#' -or $l -match 'Generated by|To change it, edit the spreadsheet') { continue }
        # a commented-out setting may be live in the example (JavaPatchDir is)
        Assert-True ($exLines -contains $l.Trim() -or $exLines -contains ($l.Trim() -replace '^#\s?', '')) "comment line not worded as in fleet.example.psd1: $l" }
    $p = Write-FleetText 'bytes.psd1' $text
    $bytes = [IO.File]::ReadAllBytes($p)
    Assert-True (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) 'the file starts with a BOM'
    $lf = @($bytes | Where-Object { $_ -eq 10 }).Count; $crlf = ([regex]::Matches($text, "`r`n")).Count
    Assert-True ($lf -gt 10 -and $lf -eq $crlf) "line ends are not all CRLF ($lf LF, $crlf CRLF)"
    Assert-True ($text.EndsWith("}`r`n")) 'the text does not end with }CRLF'
    Assert-Equal (@($bytes | Where-Object { $_ -gt 127 }).Count) 0 'non-ASCII bytes for ASCII input'
    Assert-True ($text -match "(?m)^            Connectors = @\(\r?$") 'Connectors line not laid out as in the example'
    Assert-True ($text.Contains("                @{ Host = 'connector1.example.local'; SshUser = 'administrator' }")) 'connector line with SshUser'
    Assert-True ($text.Contains("                @{ Host = 'connector3.example.local' }")) 'connector line without SshUser'
}
Invoke-TestCase 'top-level settings of an existing file are carried; only the five named ones' {
    $old = [ordered]@{ StagingRoot = '\\fileserver.example.local\Deploy\AccessConnector'
        StagingFolders = @('Deploy/AccessConnector', '\\fileserver.example.local\Deploy\AccessConnector')
        CentralLogRoot = 'Logs\Fleet'; InstallScript = 'Silent Install\Install-AccessConnector.ps1'
        Unused = 'x'; Tenants = @(@{ Name = 'OLD'; Connectors = @(@{ Host = 'old.example.local' }) }) }
    $text = ConvertTo-FleetFileText -Tenants $rtConv.Tenants -TopLevel $old -Source 'roundtrip.csv' -Generator $gen -Stamp $stamp
    Assert-True ($text.Contains("    StagingRoot = '\\fileserver.example.local\Deploy\AccessConnector'")) 'StagingRoot not carried'
    Assert-True ($text.Contains("    # JavaPatchDir   = 'Installers\Java4shellPatch'")) 'JavaPatchDir example not commented'
    Assert-True (-not $text.Contains('Unused') -and -not $text.Contains('OLD')) 'an unnamed key or the old Tenants leaked in'
    $back = Import-PowerShellDataFile -LiteralPath (Write-FleetText 'carried.psd1' $text)
    Assert-None @(Compare-FleetData -Tenants $rtConv.Tenants -TopLevel $old -Actual $back) 'differences'
    Assert-Equal (@($back.StagingFolders) -join '|') 'Deploy/AccessConnector|\\fileserver.example.local\Deploy\AccessConnector' 'StagingFolders'
    Assert-Equal $back.CentralLogRoot 'Logs\Fleet' 'CentralLogRoot'
}
Invoke-TestCase 'Compare-FleetData finds a changed value, a changed type and a missing connector' {
    $text = ConvertTo-FleetFileText -Tenants $rtConv.Tenants -TopLevel $exTop -Source 'x' -Generator $gen -Stamp $stamp
    $t1 = $text.Replace("Name                = 'TENANT2'", "Name                = 'TENANT3'")
    Assert-Has @(Compare-FleetData -Tenants $rtConv.Tenants -TopLevel $exTop -Actual (Import-PowerShellDataFile -LiteralPath (Write-FleetText 'tamper1.psd1' $t1))) "TENANT2\.Name: meant 'TENANT2', the file holds 'TENANT3'" 'difference'
    $t2 = ([regex]'ForceReinstall      = \$false').Replace($text, "ForceReinstall      = 'False'", 1)
    Assert-Has @(Compare-FleetData -Tenants $rtConv.Tenants -TopLevel $exTop -Actual (Import-PowerShellDataFile -LiteralPath (Write-FleetText 'tamper2.psd1' $t2))) 'ForceReinstall: meant true/false .*holds text' 'difference'
    $t3 = $text.Replace("                @{ Host = 'connector4.example.local' }`r`n", '')
    Assert-Has @(Compare-FleetData -Tenants $rtConv.Tenants -TopLevel $exTop -Actual (Import-PowerShellDataFile -LiteralPath (Write-FleetText 'tamper3.psd1' $t3))) 'Connectors: 2 item\(s\) meant, the file holds 1' 'difference'
    Assert-Has @(Compare-FleetData -Tenants $rtConv.Tenants -TopLevel $null -Actual (Import-PowerShellDataFile -LiteralPath (Write-FleetText 'tamper4.psd1' $text))) 'JavaPatchDir: in the file, but not meant to be' 'difference'
    Assert-Has @(Compare-FleetData -Tenants $rtConv.Tenants -TopLevel $null -Actual 'not a table') 'did not read back' 'difference'
}
Invoke-TestCase 'quote characters survive the file: apostrophe and typographic quotes are doubled' {
    $sa = 'EXAMPLE\o' + $rsq + 'brien'; $sl = "it's-" + $lsq + 'x' + $rsq + '.example.local:514'
    $r = Import-TestSheet 'quotes.csv' @((New-Row @{ Services = 'VirtualAppService'; ServiceAccount = $sa; Syslog = $sl }))
    Assert-None $r.Problems 'problems'
    $text = ConvertTo-FleetFileText -Tenants $r.Conv.Tenants -TopLevel $null -Source 'quotes.csv' -Generator $gen -Stamp $stamp
    $back = Import-PowerShellDataFile -LiteralPath (Write-FleetText 'quotes.psd1' $text)
    Assert-None @(Compare-FleetData -Tenants $r.Conv.Tenants -TopLevel $null -Actual $back) 'differences'
    Assert-Equal $back.Tenants[0].ServiceAccount $sa 'ServiceAccount'; Assert-Equal $back.Tenants[0].Syslog $sl 'Syslog'
}

# ---------------------------------------------------------------- encodings and delimiters
Invoke-TestCase 'semicolon CSV with a UTF-8 BOM (commas inside cells are data)' {
    $p = Write-Fixture 'semicolon-bom.csv' (Join-Crlf @('Group;Host;Installer;ConfigFile;Services', 'TENANT1;connector1.example.local;Installers\x.exe;Configs\t.json;DirectorySyncService,UserAuthService')) 'utf8bom'
    $t = Read-FleetTable -Path $p
    Assert-None $t.Problems 'problems'
    Assert-Equal $t.Delimiter ';' 'Delimiter'; Assert-Equal $t.Encoding 'UTF-8 with BOM' 'Encoding'; Assert-Equal $t.Columns[0] 'Group' 'first column (BOM removed)'
    $c = ConvertFrom-FleetRows -Table $t
    Assert-None $c.Problems 'conversion problems'
    Assert-Equal $c.Tenants[0].Services 'DirectorySyncService,UserAuthService' 'Services'
}
Invoke-TestCase 'UTF-16LE tab-separated text (Excel Unicode text) with an accented name' {
    $sa = 'EXAMPLE\jos' + $eacute
    $p = Write-Fixture 'unicode.txt' (Join-Crlf @("Group`tHost`tInstaller`tConfigFile`tServices`tServiceAccount", "TENANT1`tconnector1.example.local`tInstallers\x.exe`tConfigs\t.json`tVirtualAppService`t$sa")) 'utf16le'
    $t = Read-FleetTable -Path $p
    Assert-None $t.Problems 'problems'
    Assert-Equal $t.Delimiter "`t" 'Delimiter'; Assert-Equal $t.Encoding 'UTF-16LE' 'Encoding'
    Assert-Equal $t.Rows[0].Values['ServiceAccount'] $sa 'ServiceAccount'
    $c = ConvertFrom-FleetRows -Table $t; Assert-None $c.Problems 'conversion problems'
}
Invoke-TestCase 'UTF-16BE with a BOM, and UTF-16LE without one' {
    $txt = Join-Crlf @('Group,Host,Installer,ConfigFile,Services', 'TENANT1,connector1.example.local,Installers\x.exe,Configs\t.json,UserAuth')
    $t = Read-FleetTable -Path (Write-Fixture 'be.csv' $txt 'utf16be'); Assert-None $t.Problems 'problems (BE)'; Assert-Equal $t.Encoding 'UTF-16BE' 'Encoding (BE)'; Assert-Equal $t.Rows[0].Values['Host'] 'connector1.example.local' 'Host (BE)'
    $t = Read-FleetTable -Path (Write-Fixture 'le-nobom.csv' $txt 'utf16le-nobom'); Assert-None $t.Problems 'problems (LE)'; Assert-Equal $t.Encoding 'UTF-16LE (no BOM)' 'Encoding (LE)'; Assert-Equal $t.Rows[0].Values['Services'] 'UserAuth' 'Services (LE)'
}
Invoke-TestCase 'Windows-1252 file (not valid UTF-8): accent and typographic apostrophe decoded, and survive the fleet file' {
    $sa = 'EXAMPLE\o' + $rsq + 'br' + $eacute + 'n'
    $p = Write-Fixture 'ansi.csv' (Join-Crlf @('Group,Host,Installer,ConfigFile,Services,ServiceAccount', "TENANT1,connector1.example.local,Installers\x.exe,Configs\t.json,VirtualApp,$sa")) '1252'
    $raw = [IO.File]::ReadAllBytes($p); Assert-True (($raw -contains 0x92) -and ($raw -contains 0xE9)) 'the fixture is not Windows-1252'
    $t = Read-FleetTable -Path $p
    Assert-None $t.Problems 'problems'
    Assert-Equal $t.Encoding 'Windows-1252' 'Encoding'
    Assert-Equal $t.Rows[0].Values['ServiceAccount'] $sa 'ServiceAccount'
    $c = ConvertFrom-FleetRows -Table $t; Assert-None $c.Problems 'conversion problems'
    $back = Import-PowerShellDataFile -LiteralPath (Write-FleetText 'ansi.psd1' (ConvertTo-FleetFileText -Tenants $c.Tenants -TopLevel $null -Source 'ansi.csv' -Generator $gen -Stamp $stamp))
    Assert-None @(Compare-FleetData -Tenants $c.Tenants -TopLevel $null -Actual $back) 'differences'
}
Invoke-TestCase 'quoted cells holding commas, line breaks and doubled quotes' {
    $txt = 'Group,Host,Services,Notes,# comment,Installer,ConfigFile' + "`r`n" +
           'TENANT1,connector1.example.local,"DirectorySyncService, UserAuthService","line one' + "`r`n" + 'line two, with ""quotes""","a,b",Installers\x.exe,Configs\t.json' + "`r`n" +
           'TENANT1,"connector2.example.local",,"x' + "`n" + 'y",,,' + "`r`n"
    $t = Read-FleetTable -Path (Write-Fixture 'quoted.csv' $txt)
    Assert-None $t.Problems 'problems'
    Assert-Equal (@($t.Rows | ForEach-Object { $_.RowNumber }) -join ',') '2,3' 'row numbers (a cell with a line break is still one row)'
    Assert-Equal $t.Rows[0].Values['Installer'] 'Installers\x.exe' 'Installer after the multi-line cell'
    Assert-Equal $t.Rows[1].Values['Host'] 'connector2.example.local' 'quoted Host'
    Assert-Equal (@($t.Columns | ForEach-Object { if ($_) { $_ } else { '-' } }) -join ',') 'Group,Host,Services,-,-,Installer,ConfigFile' 'Columns'
    $c = ConvertFrom-FleetRows -Table $t; Assert-None $c.Problems 'conversion problems'
    Assert-Equal $c.Tenants[0].Services 'DirectorySyncService,UserAuthService' 'Services'
}
Invoke-TestCase 'a line break inside a Host cell is a problem' {
    $t = Read-FleetTable -Path (Write-Fixture 'host-break.csv' ('Group,Host,Installer,ConfigFile,Services' + "`r`n" + 'TENANT1,"connector1' + "`n" + 'example.local",Installers\x.exe,Configs\t.json,UserAuth' + "`r`n"))
    $c = ConvertFrom-FleetRows -Table $t
    Assert-Has $c.Problems '^row 2 Host: the cell holds a line break' 'problem'
}
Invoke-TestCase 'an unclosed quote is a problem' {
    $t = Read-FleetTable -Path (Write-Fixture 'unclosed.csv' ('Group,Host,Installer' + "`r`n" + 'TENANT1,"connector1.example.local,Installers\x.exe' + "`r`n" + 'TENANT1,connector2.example.local,x' + "`r`n"))
    Assert-Has $t.Problems '^row 2: a quoted cell is not closed' 'problem'
}
Invoke-TestCase 'delimiter from the header line: tab wins, else the more of ; and , outside quotes, comma on a tie' {
    $cases = [ordered]@{
        'tie.csv'      = @("Group,Host;Installer`r`nTENANT1,connector1.example.local;x`r`n", ',')
        'semi.csv'     = @("Group;Host;Installer,ConfigFile`r`n", ';')
        'quoted.csv'   = @("`"Group;Host;Installer`",ConfigFile`r`n", ',')
        'tab.txt'      = @("Group`tHost;Installer;ConfigFile;Services`r`n", "`t")
        'firstrow.csv' = @(",,,`r`n`r`nGroup;Host;Installer`r`n", ';')
    }
    foreach ($k in $cases.Keys) { Assert-Equal (Read-FleetTable -Path (Write-Fixture "delim-$k" $cases[$k][0])).Delimiter $cases[$k][1] "delimiter of $k" }
}
Invoke-TestCase 'sep= first line and lone-CR line ends (old Mac Excel)' {
    $t = Read-FleetTable -Path (Write-Fixture 'sep-cr.csv' ("sep=;`rGroup;Host;Installer;ConfigFile;Services`rTENANT1;connector1.example.local;Installers\x.exe;Configs\t.json;UserAuth`r"))
    Assert-None $t.Problems 'problems'
    Assert-Equal $t.Delimiter ';' 'Delimiter'
    Assert-Equal (@($t.Rows | ForEach-Object { $_.RowNumber }) -join ',') '2' 'row numbers'
    Assert-Equal $t.Rows[0].Values['Services'] 'UserAuth' 'Services'
}

# ---------------------------------------------------------------- headers, rows, cells
Invoke-TestCase 'header spellings and aliases; Notes, # and empty empty columns ignored' {
    $hdr = @('tenant','Server','Ssh_User','Installer','Config-File','Services','Service Account','expect.version-prefix','# owner','','Notes','INSTALLER VERSION')
    $row = @('TENANT1','connector1.example.local','admin','Installers\x.exe','Configs\t.json','VirtualApp','EXAMPLE\svc-access','26.10','someone','','a note','26.10.0.0')
    $t = Read-FleetTable -Path (Write-Fixture 'headers.csv' (ConvertTo-TestCsv @($hdr, $row)))
    Assert-None $t.Problems 'problems'
    Assert-Equal (@($t.Columns | ForEach-Object { if ($_) { $_ } else { '-' } }) -join ',') 'Group,Host,SshUser,Installer,ConfigFile,Services,ServiceAccount,ExpectVersionPrefix,-,-,-,InstallerVersion' 'Columns'
    $c = ConvertFrom-FleetRows -Table $t; Assert-None $c.Problems 'conversion problems'
    Assert-Equal $c.Tenants[0].Connectors[0].SshUser 'admin' 'SshUser'
}
Invoke-TestCase 'blank rows are skipped and row numbers stay those of the sheet' {
    $t = Read-FleetTable -Path (Write-Fixture 'blank-rows.csv' (Join-Crlf @('Group,Host,Installer,ConfigFile,Services', 'TENANT1,connector1.example.local,Installers\x.exe,Configs\t.json,UserAuth', ',,,,', '', 'TENANT1,connector2.example.local,,,', ' , ,,,')))
    Assert-None $t.Problems 'problems'
    Assert-Equal (@($t.Rows | ForEach-Object { $_.RowNumber }) -join ',') '2,5' 'row numbers'
}
Invoke-TestCase 'formula text ="26.10" is taken as 26.10 (raw and quoted)' {
    $txt = Join-Crlf @('Group,Host,Installer,ConfigFile,Services,InstallerVersion,ExpectVersionPrefix', 'TENANT1,connector1.example.local,Installers\x.exe,Configs\t.json,UserAuth,="26.10.0.0","=""26.10"""')
    $t = Read-FleetTable -Path (Write-Fixture 'formula-text.csv' $txt)
    Assert-Equal $t.Rows[0].Values['ExpectVersionPrefix'] '26.10' 'quoted form'; Assert-Equal $t.Rows[0].Values['InstallerVersion'] '26.10.0.0' 'raw form'
    $c = ConvertFrom-FleetRows -Table $t; Assert-None $c.Problems 'problems'; Assert-None $c.Warnings 'warnings'
}
Invoke-TestCase 'paths: / becomes \, leading .\ and trailing \ go' {
    $r = Import-TestSheet 'paths.csv' @((New-Row @{ Installer = './Installers/Access-Connector-Installer.exe'; ConfigFile = '.\Configs\\tenant1-es-config.json'; TrustStore = 'TrustedCerts/' }))
    Assert-None $r.Problems 'problems'
    $e = $r.Conv.Tenants[0]
    Assert-Equal $e.Installer 'Installers\Access-Connector-Installer.exe' 'Installer'; Assert-Equal $e.ConfigFile 'Configs\tenant1-es-config.json' 'ConfigFile'; Assert-Equal $e.TrustStore 'TrustedCerts' 'TrustStore'
}
Invoke-TestCase 'Services: spellings, separators, duplicates, canonical order' {
    $r = Import-TestSheet 'services.csv' @((New-Row @{ Services = 'Virtual App; Directory Sync | user auth service KerberosAuth kerberosauthservice, AccessVirtualAppService'; ServiceAccount = 'EXAMPLE\svc-access'; Pfx = 'ChildCerts\connector.example.local.pfx' }))
    Assert-None $r.Problems 'problems'
    Assert-Equal $r.Conv.Tenants[0].Services 'DirectorySyncService,UserAuthService,KerberosAuthService,VirtualAppService' 'Services'
}
Invoke-TestCase 'booleans: TRUE/FALSE, yes/no, y/n, 1/0, $true/$false' {
    $r = Import-TestSheet 'booleans.csv' @(
        (New-Row @{ ForceReinstall = 'yes'; EnableFips = 'N' }),
        (New-Row @{ Group = 'TENANT2'; Host = 'connector2.example.local'; ForceReinstall = '1'; EnableFips = '$FALSE' }),
        (New-Row @{ Group = 'TENANT3'; Host = 'connector3.example.local'; ForceReinstall = 'True'; EnableFips = 'no' }))
    Assert-None $r.Problems 'problems'
    $v = @($r.Conv.Tenants | ForEach-Object { "$($_.ForceReinstall)/$($_.EnableFips)/$($_.ForceReinstall.GetType().Name)" }) -join ' '
    Assert-Equal $v 'True/False/Boolean True/False/Boolean True/False/Boolean' 'values'
}
Invoke-TestCase 'entry shape: key order as the spec, only keys with values, ints and booleans, SshUser only when set' {
    $full = New-Row @{ SshUser = 'admin'; InstallerVersion = '26.10.0.0'; ExpectVersionPrefix = '26.10'; Services = 'DirectorySync,UserAuth,KerberosAuth,VirtualApp'
        ServiceAccount = 'EXAMPLE\svc-access'; Pfx = 'ChildCerts\connector.example.local.pfx'; TrustStore = 'TrustedCerts'; Syslog = 'syslog.example.local:514'
        ForceReinstall = 'TRUE'; InstallDir = 'D:\Program Files'; EnableFips = 'FALSE'; DirectorySyncPort = '8081'; UserAuthPort = '8091'; KerberosAuthPort = '8443'
        VirtualAppPort = '8009'; ProxyHost = 'proxy.example.local'; ProxyPort = '3128'; ProxyUser = 'EXAMPLE\svc-proxy'; NonProxyHosts = 'host1.example.local|host2.example.local' }
    $r = Import-TestSheet 'full.csv' @($full, @{ Group = 'TENANT1'; Host = 'connector2.example.local' })
    Assert-None $r.Problems 'problems'; Assert-None $r.Warnings 'warnings'
    $e = $r.Conv.Tenants[0]
    Assert-Equal (@($e.Keys) -join ',') 'Name,Installer,InstallerVersion,ExpectVersionPrefix,ConfigFile,TrustStore,Pfx,Services,ServiceAccount,Syslog,ForceReinstall,InstallDir,EnableFips,DirectorySyncPort,UserAuthPort,KerberosAuthPort,VirtualAppPort,ProxyHost,ProxyPort,ProxyUser,NonProxyHosts,Connectors' 'keys'
    foreach ($k in 'DirectorySyncPort','UserAuthPort','KerberosAuthPort','VirtualAppPort','ProxyPort') { Assert-True ($e[$k] -is [int]) "$k is not an int" }
    Assert-True ($e.ForceReinstall -is [bool] -and $e.ForceReinstall) 'ForceReinstall'; Assert-True ($e.EnableFips -is [bool] -and -not $e.EnableFips) 'EnableFips'
    Assert-True ($e.Connectors -is [array] -and $e.Connectors.Count -eq 2) 'Connectors is not an array of 2'
    Assert-Equal (@($e.Connectors[0].Keys) -join ',') 'Host,SshUser' 'first connector keys'; Assert-Equal (@($e.Connectors[1].Keys) -join ',') 'Host' 'second connector keys'
    $fo = [string](Format-TenantOptions $e)   # the orchestrator's plan line reads the entry as converted
    foreach ($bit in 'D:\Program Files', '8081', '8443', 'proxy.example.local', 'EXAMPLE\svc-proxy') { Assert-True ($fo.Contains($bit)) "Format-TenantOptions shows no '$bit': $fo" }
    $r2 = Import-TestSheet 'minimal.csv' @((New-Row))
    Assert-Equal (@($r2.Conv.Tenants[0].Keys) -join ',') 'Name,Installer,ConfigFile,Services,Connectors' 'keys of a minimal entry'
    $text = ConvertTo-FleetFileText -Tenants $r.Conv.Tenants -TopLevel $null -Source 'full.csv' -Generator $gen -Stamp $stamp
    Assert-True ($text.Contains('            DirectorySyncPort   = 8081') -and $text.Contains('            ForceReinstall      = $true')) 'ports and booleans are not bare in the file'
    $back = Import-PowerShellDataFile -LiteralPath (Write-FleetText 'full.psd1' $text)
    Assert-None @(Compare-FleetData -Tenants $r.Conv.Tenants -TopLevel $null -Actual $back) 'differences'
}
Invoke-TestCase 'groups in order of first appearance, connectors in row order' {
    $r = Import-TestSheet 'order.csv' @(
        (New-Row @{ Group = 'TENANT2'; Host = 'connector3.example.local' }), (New-Row @{ Host = 'connector1.example.local' }),
        @{ Group = 'TENANT2'; Host = 'connector4.example.local' }, @{ Group = 'tenant1'; Host = 'connector2.example.local' })
    Assert-None $r.Problems 'problems'
    Assert-Equal (@($r.Conv.Tenants | ForEach-Object { $_.Name + ':' + (@($_.Connectors | ForEach-Object { $_.Host }) -join '+') }) -join ' ') 'TENANT2:connector3.example.local+connector4.example.local TENANT1:connector1.example.local+connector2.example.local' 'order'
    Assert-Has $r.Warnings "^row 5 Group: 'tenant1' is taken as 'TENANT1'" 'warning'
}

# ---------------------------------------------------------------- xlsx
$ns = 'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"'
$relNs = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
$ct = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/></Types>'
$pkgRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="' + $relNs + '/officeDocument" Target="xl/workbook.xml"/></Relationships>'
$sst = @('Group','Host','Ssh User','Installer','Expect Version Prefix','Services','Config File','Force Reinstall','Kerberos Auth Port','# comment','Service Account','Pfx','TENANT1') |
    ForEach-Object { "<si><t>$_</t></si>" }
$sst += '<si><r><t>connector1</t></r><r><rPr><b/></rPr><t>.example.local</t></r></si>'                    # 13: rich text, two runs
$sst += '<si><t>administrator</t></si>'                                                                     # 14
$sst += '<si><r><t>DirectorySync</t></r><r><rPr><i/></rPr><t> </t></r><r><t>KerberosAuth</t></r></si>'  # 15: a run that is only a space (no xml:space)
$sst += '<si><t>EXAMPLE\svc-access</t></si>'                                                                # 16
$sst += '<si><t>connector2.example.local</t><rPh sb="0" eb="1"><t>PHONETIC</t></rPh><phoneticPr fontId="1"/></si>'  # 17: phonetic guide left out
$sst += '<si><t>TENANT9</t></si><si><t>decoy.example.local</t></si>'                                         # 18, 19: only on the second sheet
$sstXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><sst ' + $ns + ' count="20" uniqueCount="20">' + ($sst -join '') + '</sst>'
$hdrCells = (0..11 | ForEach-Object { '<c r="{0}1" t="s"><v>{1}</v></c>' -f [char](65 + $_), $_ }) -join ''
$fleetSheet = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet ' + $ns + '><dimension ref="A1:L6"/><sheetData>' +
    '<row r="1">' + $hdrCells + '</row>' +
    '<row r="2"><c r="A2" t="s"><v>12</v></c><c r="B2" t="s"><v>13</v></c><c r="C2" t="s"><v>14</v></c>' +
    '<c r="D2" t="inlineStr"><is><t>Installers\Access-Connector-Installer.exe</t></is></c>' +
    '<c r="E2"><v>26.100000000000001</v></c><c r="F2" t="s"><v>15</v></c>' +
    '<c r="G2" t="str"><f>"Configs\"&amp;"tenant1-es-config.json"</f><v>Configs\tenant1-es-config.json</v></c>' +
    '<c r="H2" t="b"><v>0</v></c><c r="I2"><v>8443</v></c><c r="J2" t="inlineStr"><is><t>a note, ignored</t></is></c>' +
    '<c r="K2" t="s"><v>16</v></c><c r="L2" t="inlineStr"><is><t>ChildCerts/connector.example.local.pfx</t></is></c></row>' +
    '<row r="4"><c r="A4" t="s"><v>12</v></c><c t="s"><v>17</v></c><c r="D4" s="1"/>' +
    '<c r="F4" t="inlineStr"><is><r><t xml:space="preserve">Directory Sync Service; </t></r><r><t>kerberos auth service</t></r></is></c><c r="H4" t="b"><v>0</v></c></row>' +
    '<row r="6"><c r="C6" s="1"/></row></sheetData></worksheet>'
$decoySheet = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet ' + $ns + '><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row><row r="2"><c r="A2" t="s"><v>18</v></c><c r="B2" t="s"><v>19</v></c></row></sheetData></worksheet>'
# the data sheet is sheet2.xml but FIRST in workbook order; sheet1.xml (second in order) is a decoy
$wbXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook ' + $ns + '><sheets><sheet name="Fleet" sheetId="2" r:id="rId2"/><sheet name="Other" sheetId="1" r:id="rId1"/></sheets></workbook>'
$wbRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
    '<Relationship Id="rId1" Type="' + $relNs + '/worksheet" Target="worksheets/sheet1.xml"/>' +
    '<Relationship Id="rId2" Type="' + $relNs + '/worksheet" Target="/xl/worksheets/sheet2.xml"/>' +
    '<Relationship Id="rId3" Type="' + $relNs + '/sharedStrings" Target="sharedStrings.xml"/></Relationships>'
$xlsxPath = New-TestXlsx 'fleet.xlsx' @{ '[Content_Types].xml' = $ct; '_rels/.rels' = $pkgRels; 'xl/workbook.xml' = $wbXml; 'xl/_rels/workbook.xml.rels' = $wbRels
    'xl/worksheets/sheet1.xml' = $decoySheet; 'xl/worksheets/sheet2.xml' = $fleetSheet; 'xl/sharedStrings.xml' = $sstXml }
$xt = Read-FleetTable -Path $xlsxPath
Invoke-TestCase 'xlsx: first sheet in workbook order (not by part name), columns, sparse rows' {
    Assert-None $xt.Problems 'problems'
    Assert-Equal $xt.Format 'xlsx' 'Format'
    Assert-None $xt.Warnings 'warnings (other sheets, such as help sheets, are ignored without a note)'
    Assert-Equal (@($xt.Columns | ForEach-Object { if ($_) { $_ } else { '-' } }) -join ',') 'Group,Host,SshUser,Installer,ExpectVersionPrefix,Services,ConfigFile,ForceReinstall,KerberosAuthPort,-,ServiceAccount,Pfx' 'Columns'
    Assert-Equal (@($xt.Rows | ForEach-Object { $_.RowNumber }) -join ',') '2,4' 'row numbers (real row index; row 3 absent, row 6 empty)'
    Assert-True (-not ((ConvertTo-Json -InputObject $xt -Depth 10) -match 'decoy|TENANT9')) 'the second sheet was read'
}
Invoke-TestCase 'xlsx: shared strings with rich-text runs, inline strings, t="str", booleans, numbers, cells without r' {
    $v = $xt.Rows[0].Values
    Assert-Equal $v['Host'] 'connector1.example.local' 'rich-text Host'
    Assert-Equal $v['Installer'] 'Installers\Access-Connector-Installer.exe' 'inline string'
    Assert-Equal $v['ExpectVersionPrefix'] '26.1' 'number 26.100000000000001'
    Assert-Equal $v['Services'] 'DirectorySync KerberosAuth' 'rich text with a run that is only a space'
    Assert-Equal $v['ConfigFile'] 'Configs\tenant1-es-config.json' 'formula text (t="str")'
    Assert-Equal $v['ForceReinstall'] 'FALSE' 'boolean'
    Assert-Equal $v['KerberosAuthPort'] '8443' 'whole number'
    $w = $xt.Rows[1].Values
    Assert-Equal $w['Host'] 'connector2.example.local' 'cell without r, phonetic guide left out'
    Assert-Equal $w['SshUser'] '' 'missing cell'
    Assert-Equal $w['Services'] 'Directory Sync Service; kerberos auth service' 'inline rich text'
}
Invoke-TestCase 'xlsx: converted entry; the number 26.1 in ExpectVersionPrefix alone is a warning with the hint' {
    $c = ConvertFrom-FleetRows -Table $xt
    Assert-None $c.Problems 'problems'
    Assert-Has $c.Warnings ([regex]::Escape("TENANT1 ExpectVersionPrefix: '26.1' (row 2): Excel may have turned 26.10 into 26.1: format the column as Text and type it again")) 'warning'
    $e = $c.Tenants[0]
    Assert-Equal $e.Services 'DirectorySyncService,KerberosAuthService' 'Services'
    Assert-Equal $e.Pfx 'ChildCerts\connector.example.local.pfx' 'Pfx'
    Assert-True ($e.KerberosAuthPort -is [int] -and $e.KerberosAuthPort -eq 8443) 'KerberosAuthPort'
    Assert-True ($e.ForceReinstall -is [bool] -and -not $e.ForceReinstall) 'ForceReinstall'
    Assert-Equal (@($e.Connectors | ForEach-Object { $_.Host + '/' + $_.SshUser }) -join ' ') 'connector1.example.local/administrator connector2.example.local/' 'Connectors'
}
Invoke-TestCase 'xlsx: Excel-mangled prefix (26.1 vs 26.10.0.0) is a problem; error cell; merged group cell' {
    $sheet = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet ' + $ns + '><sheetData>' +
        '<row r="1">' + ((@('Group','Host','Installer','InstallerVersion','ExpectVersionPrefix','ConfigFile','Services','Syslog','DirectorySyncPort') | ForEach-Object -Begin { $i = 0 } -Process { '<c r="{0}1" t="inlineStr"><is><t>{1}</t></is></c>' -f [char](65 + $i), $_; $i++ }) -join '') + '</row>' +
        '<row r="2"><c r="A2" t="inlineStr"><is><t>TENANT1</t></is></c><c r="B2" t="inlineStr"><is><t>connector1.example.local</t></is></c><c r="C2" t="inlineStr"><is><t>Installers\x.exe</t></is></c>' +
        '<c r="D2" t="s"><v>0</v></c><c r="E2"><v>26.1</v></c><c r="F2" t="inlineStr"><is><t>Configs\t.json</t></is></c><c r="G2" t="inlineStr"><is><t>DirectorySync</t></is></c><c r="H2" t="e"><f>#REF!</f><v>#REF!</v></c>' +
        '<c r="I2"><f>8000+80</f><v>8080.000000000001</v></c></row>' +
        '<row r="3"><c r="A3" s="2"/><c r="B3" t="inlineStr"><is><t>connector2.example.local</t></is></c></row>' +
        '</sheetData><mergeCells count="1"><mergeCell ref="A2:A3"/></mergeCells></worksheet>'
    $p = New-TestXlsx 'mangled.xlsx' @{ '[Content_Types].xml' = $ct; '_rels/.rels' = $pkgRels
        'xl/workbook.xml' = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook ' + $ns + '><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>')
        'xl/_rels/workbook.xml.rels' = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="' + $relNs + '/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="' + $relNs + '/sharedStrings" Target="sharedStrings.xml"/></Relationships>')
        'xl/worksheets/sheet1.xml' = $sheet
        'xl/sharedStrings.xml' = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><sst ' + $ns + '><si><t>26.10.0.0</t></si></sst>') }
    $t = Read-FleetTable -Path $p
    Assert-Has $t.Problems '^row 2 Syslog: the cell holds the Excel error #REF!' 'error-cell problem'
    Assert-None $t.Warnings 'warnings (one sheet)'
    Assert-Equal $t.Rows[1].Values['Group'] 'TENANT1' 'merged Group in row 3'
    Assert-Equal $t.Rows[0].Values['DirectorySyncPort'] '8080' 'a formula result with float noise, as Excel shows it (15 digits)'
    $c = ConvertFrom-FleetRows -Table $t
    Assert-True ($c.Tenants[0].DirectorySyncPort -is [int] -and $c.Tenants[0].DirectorySyncPort -eq 8080) 'DirectorySyncPort'
    Assert-Has $c.Problems ([regex]::Escape("group TENANT1 ExpectVersionPrefix: '26.1' (row 2) does not match InstallerVersion '26.10.0.0' (row 2)") + '.*' + [regex]::Escape('Excel may have turned 26.10 into 26.1: format the column as Text and type it again')) 'problem'
    Assert-Equal (@($c.Tenants[0].Connectors).Count) 2 'connectors in the merged group'
}
Invoke-TestCase 'xlsx: rows on a sheet that is not the first are not read, and the problem says why' {
    $readMe = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet ' + $ns + '><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>Fill in the Fleet sheet</t></is></c></row></sheetData></worksheet>'
    $empty = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet ' + $ns + '><sheetData/></worksheet>'
    foreach ($first in @(@('readme-first.xlsx', $readMe), @('empty-first.xlsx', $empty))) {
        $p = New-TestXlsx $first[0] @{ '[Content_Types].xml' = $ct; '_rels/.rels' = $pkgRels
            'xl/workbook.xml' = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook ' + $ns + '><sheets><sheet name="Read me" sheetId="1" r:id="rId1"/><sheet name="Fleet" sheetId="2" r:id="rId2"/></sheets></workbook>')
            'xl/_rels/workbook.xml.rels' = $wbRels.Replace('/xl/worksheets/sheet2.xml', 'worksheets/sheet2.xml')
            'xl/worksheets/sheet1.xml' = $first[1]; 'xl/worksheets/sheet2.xml' = $fleetSheet; 'xl/sharedStrings.xml' = $sstXml }
        $t = Read-FleetTable -Path $p
        Assert-Has $t.Problems "^only the first sheet of the workbook, 'Read me', is read, and it holds no connector rows; the workbook has 2 sheets" "problem ($($first[0]))"
        Assert-Equal @($t.Rows).Count 0 "rows ($($first[0]))"
    }
}
Invoke-TestCase 'xlsx: a hidden first sheet is passed over, named in a warning; the sheet read is reported' {
    $hiddenSheet = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet ' + $ns + '><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>Group</t></is></c><c r="B1" t="inlineStr"><is><t>Host</t></is></c></row><row r="2"><c r="A2" t="inlineStr"><is><t>OLD</t></is></c><c r="B2" t="inlineStr"><is><t>old.example.local</t></is></c></row></sheetData></worksheet>'
    $p = New-TestXlsx 'hidden-first.xlsx' @{ '[Content_Types].xml' = $ct; '_rels/.rels' = $pkgRels
        'xl/workbook.xml' = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook ' + $ns + '><sheets><sheet name="Lists" sheetId="1" state="hidden" r:id="rId1"/><sheet name="Fleet" sheetId="2" r:id="rId2"/></sheets></workbook>')
        'xl/_rels/workbook.xml.rels' = $wbRels.Replace('/xl/worksheets/sheet2.xml', 'worksheets/sheet2.xml')
        'xl/worksheets/sheet1.xml' = $hiddenSheet; 'xl/worksheets/sheet2.xml' = $fleetSheet; 'xl/sharedStrings.xml' = $sstXml }
    $t = Read-FleetTable -Path $p
    Assert-Equal $t.Sheet 'Fleet' 'sheet read'
    Assert-Equal $t.SheetCount 2 'sheet count'
    Assert-Has $t.Warnings "^hidden sheet\(s\) before it passed over: 'Lists'$" 'warning'
    Assert-True (-not @($t.Rows | Where-Object { $_.Values['Host'] -eq 'old.example.local' }).Count) 'a row of the hidden sheet was read'
}
Invoke-TestCase 'CSV: Excel error values written as text (#N/A, #REF!) are problems' {
    $r = Import-TestSheet 'errtext.csv' @((New-Row @{ Syslog = '#N/A' }), (New-Row @{ Host = 'connector2.example.local'; ProxyHost = '#REF!' }))
    Assert-Has $r.Problems '^row 2 Syslog: the cell holds the Excel error #N/A' 'problem'
    Assert-Has $r.Problems '^row 3 ProxyHost: the cell holds the Excel error #REF!' 'problem'
}
Invoke-TestCase 'Services: one service per line in the cell (Alt+Enter) is accepted' {
    $r = Import-TestSheet 'svc-lines.csv' @((New-Row @{ Services = "DirectorySyncService`nUserAuthService`r`nVirtualAppService"; ServiceAccount = 'EXAMPLE\svc-access' }))
    Assert-None $r.Problems 'problems'
    Assert-Equal $r.Conv.Tenants[0].Services 'DirectorySyncService,UserAuthService,VirtualAppService' 'Services'
}
Invoke-TestCase 'xlsx and other files that cannot be read are problems' {
    $p = Write-Fixture 'not-a-zip.xlsx' 'this is not a workbook'
    Assert-Has (Read-FleetTable -Path $p).Problems 'not a readable \.xlsx workbook' 'problem (not a zip)'
    $ole = Join-Path $work 'ole.xlsx'; [IO.File]::WriteAllBytes($ole, [byte[]](0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 0, 0, 0, 0))
    Assert-Has (Read-FleetTable -Path $ole).Problems 'saved with a password\?' 'problem (OLE container)'
    $zipAsCsv = Join-Path $work 'workbook-named.csv'; Copy-Item -LiteralPath $xlsxPath -Destination $zipAsCsv -Force
    Assert-Has (Read-FleetTable -Path $zipAsCsv).Problems 'is an Excel workbook, not text' 'problem (workbook named .csv)'
    Assert-Has (Read-FleetTable -Path (Write-Fixture 'old.xls' 'x')).Problems 'save it as \.xlsx or \.csv' 'problem (.xls)'
    Assert-Has (Read-FleetTable -Path (Write-Fixture 'sheet.ods' 'x')).Problems 'save it as \.xlsx or \.csv' 'problem (.ods)'
    Assert-Has (Read-FleetTable -Path (Join-Path $work 'no-such-file.csv')).Problems 'was not found' 'problem (missing)'
    Assert-Has (Read-FleetTable -Path (Write-Fixture 'empty.csv' '')).Problems 'is empty' 'problem (empty)'
    $t = Read-FleetTable -Path (Write-Fixture 'header-only.csv' (Join-Crlf @('Group,Host,Installer')))
    Assert-None $t.Problems 'table problems (header only)'
    Assert-Has (ConvertFrom-FleetRows -Table $t).Problems 'no connector rows' 'problem (header only)'
}

# ---------------------------------------------------------------- problems and warnings
Invoke-TestCase 'unknown column is a problem, with a suggestion and the column list' {
    $r = Import-TestSheet 'unknown.csv' @((New-Row @{ Instaler = 'x' })) @('Group','Host','Instaler','Installer','ConfigFile','Services')
    Assert-Has $r.Table.Problems "^column C 'Instaler' is not a known column \(did you mean Installer\?\)" 'problem'
    Assert-Has $r.Table.Problems '^known columns: Group, Host, SshUser' 'column list'
    Assert-None $r.Conv.Problems 'conversion problems (the table problems are the caller''s to add)'
}
Invoke-TestCase 'password columns are refused and their values appear nowhere' {
    $secret = 'SENTINEL-not-a-real-password-7Q2x'; $secret2 = 'SENTINEL-second-9Kd'
    $r = Import-TestSheet 'password.csv' @((New-Row @{ 'Proxy Password' = $secret; '# admin pwd' = $secret2 })) @('Group','Host','Installer','ConfigFile','Services','Proxy Password','# admin pwd')
    Assert-Has $r.Table.Problems "^column F 'Proxy Password': columns that hold passwords are refused; passwords are asked at run time" 'problem'
    Assert-Has $r.Table.Problems "^column G '# admin pwd': columns that hold passwords are refused" 'problem (ignored-looking column)'
    Assert-Equal (@($r.Table.Columns | ForEach-Object { if ($_) { $_ } else { '-' } }) -join ',') 'Group,Host,Installer,ConfigFile,Services,-,-' 'Columns'
    $text = ConvertTo-FleetFileText -Tenants $r.Conv.Tenants -TopLevel $null -Source 'password.csv' -Generator $gen -Stamp $stamp
    $all = (ConvertTo-Json -InputObject $r.Table -Depth 20) + (ConvertTo-Json -InputObject $r.Conv -Depth 20) + ($r.Problems -join "`n") + ($r.Warnings -join "`n") + $text
    Assert-True (-not $all.Contains($secret) -and -not $all.Contains($secret2)) 'a password cell value appears in the output'
    Assert-True (-not $all.Contains('SENTINEL')) 'part of a password cell value appears in the output'
}
Invoke-TestCase 'a column with values but no header is a problem; a second column of the same name is a problem' {
    $r = Import-TestSheet 'noheader.csv' @(@{ Group = 'TENANT1'; Host = 'connector1.example.local'; '' = 'stray' }) @('Group','Host','')
    Assert-Has $r.Table.Problems '^column C has no header but holds values \(first in row 2\)' 'problem'
    $r = Import-TestSheet 'dupcol.csv' @(@{ Group = 'TENANT1'; Host = 'connector1.example.local'; Server = 'connector9.example.local' }) @('Group','Host','Server')
    Assert-Has $r.Table.Problems '^columns B and C are both Host' 'problem'
}
Invoke-TestCase 'missing Group or Host column is a problem' {
    $r = Import-TestSheet 'nogroup.csv' @(@{ Host = 'connector1.example.local'; Installer = 'x' }) @('Host','Installer')
    Assert-Has $r.Table.Problems 'has no Group column \(it may also be headed Name or Tenant\)' 'problem'
    $r = Import-TestSheet 'nohost.csv' @(@{ Group = 'TENANT1'; Installer = 'x' }) @('Group','Installer')
    Assert-Has $r.Table.Problems 'has no Host column \(it may also be headed Connector or Server\)' 'problem'
    Assert-None $r.Conv.Problems 'conversion problems (not repeated)'
}
Invoke-TestCase 'a row with values but no Host is a problem' {
    $r = Import-TestSheet 'missing-host.csv' @((New-Row), @{ Group = 'TENANT1'; Syslog = 'syslog.example.local:514' })
    Assert-Has $r.Problems '^row 3: the row has values but no Host' 'problem'
}
Invoke-TestCase 'a duplicate Host (any case) is a problem naming both rows' {
    $r = Import-TestSheet 'dup-host.csv' @((New-Row), (New-Row @{ Group = 'TENANT2'; Host = 'CONNECTOR1.example.local' }))
    Assert-Has $r.Problems '^row 3 Host: CONNECTOR1\.example\.local is also in row 2; list each connector once' 'problem'
}
Invoke-TestCase 'an empty or badly formed Group is a problem; bad Host and SshUser are problems' {
    $r = Import-TestSheet 'bad-group.csv' @((New-Row @{ Group = '' }), (New-Row @{ Group = 'TENANT 1'; Host = 'connector2.example.local' }),
        (New-Row @{ Host = 'connector 3.example.local' }), (New-Row @{ Host = '-oProxyCommand=x' }), (New-Row @{ Host = 'connector5.example.local'; SshUser = 'admin user' }))
    Assert-Has $r.Problems '^row 2 Group: empty' 'problem (empty)'
    Assert-Has $r.Problems "^row 3 Group: 'TENANT 1' may hold only letters" 'problem (bad name)'
    Assert-Has $r.Problems "^row 4 Host: 'connector 3\.example\.local' is not a DNS name" 'problem (space in Host)'
    Assert-Has $r.Problems "^row 5 Host: '-oProxyCommand=x' is not a DNS name" 'problem (Host starting with -)'
    Assert-Has $r.Problems "^row 6 SshUser: 'admin user' is not an account name" 'problem (SshUser)'
}
Invoke-TestCase 'conflicting group values are a problem naming group, column, both values and both rows' {
    $r = Import-TestSheet 'conflict.csv' @((New-Row), (New-Row @{ Host = 'connector2.example.local'; Installer = 'Installers\Other-Installer.exe' }))
    Assert-Has $r.Problems ([regex]::Escape("group TENANT1 Installer: row 2 says 'Installers\Access-Connector-Installer.exe' but row 3 says 'Installers\Other-Installer.exe'")) 'problem'
}
Invoke-TestCase 'the same setting in other words is not a conflict' {
    $r = Import-TestSheet 'same-meaning.csv' @((New-Row @{ ForceReinstall = 'TRUE'; Services = 'DirectorySyncService,UserAuthService'; KerberosAuthPort = '' }),
        (New-Row @{ Host = 'connector2.example.local'; ForceReinstall = 'yes'; Services = 'user auth; Directory Sync'; Installer = 'installers/access-connector-installer.exe' }))
    Assert-None $r.Problems 'problems'
    Assert-Equal $r.Conv.Tenants[0].Installer 'Installers\Access-Connector-Installer.exe' 'the first value counts'
}
Invoke-TestCase 'missing required group values are a problem' {
    $r = Import-TestSheet 'required.csv' @(@{ Group = 'TENANT1'; Host = 'connector1.example.local'; Installer = 'Installers\x.exe' }, @{ Group = 'TENANT1'; Host = 'connector2.example.local' })
    Assert-Has $r.Problems '^group TENANT1 \(rows 2, 3\): ConfigFile is required and is empty in every row' 'problem (ConfigFile)'
    Assert-Has $r.Problems '^group TENANT1 \(rows 2, 3\): Services is required' 'problem (Services)'
}
Invoke-TestCase 'an unknown service is a problem naming it' {
    $r = Import-TestSheet 'bad-services.csv' @((New-Row @{ Services = 'DirectorySync, Foo Service, UserAuth' }))
    Assert-Has $r.Problems "^row 2 Services: 'Foo Service' is not a service; use DirectorySyncService, UserAuthService, KerberosAuthService or VirtualAppService" 'problem'
}
Invoke-TestCase 'a bad boolean is a problem' {
    $r = Import-TestSheet 'bad-bool.csv' @((New-Row @{ ForceReinstall = 'maybe' }))
    Assert-Has $r.Problems "^row 2 ForceReinstall: 'maybe' is not TRUE or FALSE" 'problem'
}
Invoke-TestCase 'bad ports: not whole numbers, out of range, used twice (the orchestrator check)' {
    $r = Import-TestSheet 'bad-ports.csv' @((New-Row @{ DirectorySyncPort = '80a'; UserAuthPort = '8080.0' }),
        (New-Row @{ Group = 'TENANT2'; Host = 'connector2.example.local'; KerberosAuthPort = '70000'; VirtualAppPort = '99999999999' }),
        (New-Row @{ Group = 'TENANT3'; Host = 'connector3.example.local'; DirectorySyncPort = '8080'; UserAuthPort = '8080' }))
    Assert-Has $r.Problems "^row 2 DirectorySyncPort: '80a' is not a whole number" 'problem (letters)'
    Assert-Has $r.Problems "^row 2 UserAuthPort: '8080\.0' is not a whole number" 'problem (decimal)'
    Assert-Has $r.Problems "^TENANT2 KerberosAuthPort: '70000' is not a port number" 'problem (range)'
    Assert-Has $r.Problems "^TENANT2 VirtualAppPort: '99999999999' is not a port number" 'problem (too big)'
    Assert-Has $r.Problems '^TENANT3 UserAuthPort: port 8080 is already used by DirectorySyncPort' 'problem (duplicate)'
}
Invoke-TestCase 'versions: Excel-mangled prefix is a problem with the hint; prefix alone is a warning; bad versions are problems' {
    $r = Import-TestSheet 'versions.csv' @((New-Row @{ InstallerVersion = '26.10.0.0'; ExpectVersionPrefix = '26.1' }),
        (New-Row @{ Group = 'TENANT2'; Host = 'connector2.example.local'; ExpectVersionPrefix = '26.1' }),
        (New-Row @{ Group = 'TENANT3'; Host = 'connector3.example.local'; InstallerVersion = 'v26'; ExpectVersionPrefix = '26,1' }),
        (New-Row @{ Group = 'TENANT4'; Host = 'connector4.example.local'; InstallerVersion = '26.10.0.0'; ExpectVersionPrefix = '26.10' }),
        (New-Row @{ Group = 'TENANT5'; Host = 'connector5.example.local'; InstallerVersion = '26.1' }))
    Assert-Has $r.Problems ([regex]::Escape("group TENANT1 ExpectVersionPrefix: '26.1' (row 2) does not match InstallerVersion '26.10.0.0' (row 2)") + '.*' + [regex]::Escape('Excel may have turned 26.10 into 26.1: format the column as Text and type it again')) 'problem (mangled)'
    Assert-Has $r.Warnings ([regex]::Escape("group TENANT2 ExpectVersionPrefix: '26.1' (row 3): Excel may have turned 26.10 into 26.1: format the column as Text and type it again")) 'warning (prefix only)'
    Assert-Has $r.Problems "^row 4 InstallerVersion: 'v26' is not a version" 'problem (InstallerVersion)'
    Assert-Has $r.Problems "^row 4 ExpectVersionPrefix: '26,1' is not the start of a version" 'problem (ExpectVersionPrefix)'
    Assert-Has $r.Warnings "^group TENANT5 InstallerVersion: '26\.1' \(row 6\): Excel may have turned 26\.10 into 26\.1" 'warning (two-part InstallerVersion)'
    Assert-True (-not @($r.Problems + $r.Warnings | Where-Object { $_ -match 'TENANT4' }).Count) 'a correct version pair was flagged'
}
Invoke-TestCase 'absolute paths are problems ("relative to the staging folder")' {
    $r = Import-TestSheet 'absolute.csv' @((New-Row @{ Installer = 'C:\Installers\x.exe'; ConfigFile = '\\fileserver.example.local\Deploy\Configs\t.json'; TrustStore = '/Volumes/Deploy/TrustedCerts' }),
        (New-Row @{ Group = 'TENANT2'; Host = 'connector2.example.local'; Services = 'KerberosAuth'; ServiceAccount = 'EXAMPLE\svc-access'; Pfx = '\ChildCerts\x.pfx' }))
    foreach ($pat in "^row 2 Installer: 'C:\\Installers\\x\.exe' is not relative to the staging folder", "^row 2 ConfigFile: '\\\\fileserver", "^row 2 TrustStore: '/Volumes/Deploy/TrustedCerts' is not relative", "^row 3 Pfx: '\\ChildCerts\\x\.pfx' is not relative") {
        Assert-Has $r.Problems $pat 'problem' }
}
Invoke-TestCase 'Pfx without Kerberos Auth and Kerberos Auth without Pfx are warnings' {
    $r = Import-TestSheet 'pfx.csv' @((New-Row @{ Pfx = 'ChildCerts\connector.example.local.pfx' }),
        (New-Row @{ Group = 'TENANT2'; Host = 'connector2.example.local'; Services = 'DirectorySync,KerberosAuth'; ServiceAccount = 'EXAMPLE\svc-access' }))
    Assert-None $r.Problems 'problems'
    Assert-Has $r.Warnings '^group TENANT1 Pfx: not used, because Services has no KerberosAuthService' 'warning (Pfx)'
    Assert-Has $r.Warnings '^group TENANT2 installs KerberosAuthService without a Pfx; the installer will make a self-signed certificate' 'warning (no Pfx)'
}
Invoke-TestCase 'ServiceAccount: required with Virtual App or Kerberos Auth, must be DOMAIN\name' {
    $r = Import-TestSheet 'service-account.csv' @((New-Row @{ Services = 'DirectorySync,UserAuth,VirtualApp' }),
        (New-Row @{ Group = 'TENANT2'; Host = 'connector2.example.local'; Services = 'VirtualApp'; ServiceAccount = 'svc-access' }),
        (New-Row @{ Group = 'TENANT3'; Host = 'connector3.example.local'; ServiceAccount = 'EXAMPLE\svc-access' }))
    Assert-Has $r.Problems '^group TENANT1 \(row 2\): ServiceAccount is required with VirtualAppService' 'problem (missing)'
    Assert-Has $r.Problems "^row 3 ServiceAccount: 'svc-access' is not DOMAIN\\name" 'problem (format)'
    Assert-Has $r.Warnings '^group TENANT3 ServiceAccount: not used' 'warning (not used)'
}
Invoke-TestCase "the orchestrator's option checks run on each entry (Get-TenantOptionProblems)" {
    $r = Import-TestSheet 'options.csv' @((New-Row @{ ProxyPort = '3128'; InstallDir = 'Program Files'; ProxyUser = 'EXAMPLE\svc proxy' }))
    Assert-Has $r.Problems '^TENANT1 ProxyPort is set but ProxyHost is not' 'problem (proxy)'
    Assert-Has $r.Problems "^TENANT1 InstallDir: 'Program Files' is not a full Windows path" 'problem (InstallDir)'
    Assert-Has $r.Problems '^TENANT1 ProxyUser: spaces and double quotes are not allowed' 'problem (ProxyUser)'
}
Invoke-TestCase 'files missing under -StagingRoot are warnings, not problems (Get-StagingGaps)' {
    $stg = Join-Path $work 'staging'
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $stg 'Installers'), (Join-Path $stg 'TrustedCerts')
    Set-Content -LiteralPath (Join-Path $stg 'Installers/Access-Connector-Installer.exe') -Value 'placeholder'
    $r = Import-TestSheet 'staging.csv' @((New-Row @{ ConfigFile = 'Configs\never-created-es-config.json'; TrustStore = 'TrustedCerts' })) -StagingRoot $stg
    Assert-None $r.Problems 'problems'
    Assert-Has $r.Warnings ([regex]::Escape('not in the staging folder yet (add it before a run): TENANT1 ConfigFile: Configs\never-created-es-config.json')) 'warning'
    Assert-True (-not @($r.Warnings | Where-Object { $_ -match 'Installer:|TrustStore:' }).Count) 'a file that is there was reported missing'
}
Invoke-TestCase 'entry keys are checked against $script:TenantKeys' {
    $saved = $script:TenantKeys
    try {
        $script:TenantKeys = @($saved | Where-Object { $_ -ne 'Syslog' })
        $r = Import-TestSheet 'tenantkeys.csv' @((New-Row @{ Syslog = 'syslog.example.local:514' }))
        Assert-Has $r.Conv.Problems "^group TENANT1: 'Syslog' is not a fleet setting this script knows" 'problem'
    } finally { $script:TenantKeys = $saved }
    $r = Import-TestSheet 'tenantkeys2.csv' @((New-Row @{ Syslog = 'syslog.example.local:514' }))
    Assert-None $r.Problems 'problems with the real TenantKeys'
}

# ---------------------------------------------------------------- end
try { Remove-Item -LiteralPath $work -Recurse -Force } catch { "note: could not remove $work" }
if ($script:Fails) { 'TESTS FAILED'; exit 1 }
'ALL TESTS PASSED'
exit 0
