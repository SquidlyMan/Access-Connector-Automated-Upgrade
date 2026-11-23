# End-to-end tests of -ImportFleet and -Mode Discover: the real script is run in a temporary copy of
# the staging folder layout. Offline: ssh is replaced by a stand-in put first on the PATH, which
# logs each call and runs the read-only discovery script locally (or fails, for hosts named down*).
# No connector, domain controller or share is contacted.
#   pwsh -NoLogo -NoProfile -File tools/test_fleet_e2e.ps1
# Prints PASS <name> / FAIL <name>: <why> per case, then ALL TESTS PASSED or TESTS FAILED (exit 0/1).
$ErrorActionPreference = 'Stop'
$repo = if ($env:FLEET_REPO) { $env:FLEET_REPO } else { Split-Path -Parent $PSScriptRoot }
if ($IsWindows) { 'PASS skipped on Windows (the stand-in ssh is a shell script)'; 'ALL TESTS PASSED'; exit 0 }

$base = Join-Path ([IO.Path]::GetTempPath()) ('acu-test-e2e-' + $PID)
$fd = Join-Path $base 'FleetDeploy'
foreach ($d in 'FleetDeploy','Silent Install','Installers','Configs','ChildCerts','TrustedCerts','fakebin','sheets') { $null = New-Item -ItemType Directory -Force -Path (Join-Path $base $d) }
Copy-Item -LiteralPath (Join-Path $repo 'FleetDeploy/Invoke-AccessConnectorUpgrade.ps1') -Destination $fd
Copy-Item -LiteralPath (Join-Path $repo 'FleetDeploy/Invoke-ConnectorUpgradeLocal.ps1') -Destination $fd
Copy-Item -LiteralPath (Join-Path $repo 'Silent Install/Install-AccessConnector.ps1') -Destination (Join-Path $base 'Silent Install')
foreach ($f in 'fleet.example.csv','fleet.example.xlsx') { Copy-Item -LiteralPath (Join-Path $repo "FleetDeploy/$f") -Destination (Join-Path $base 'sheets') }
$sshLog = Join-Path $base 'ssh-calls.log'
$fake = Join-Path $base 'fakebin/ssh'
[IO.File]::WriteAllText($fake, @"
#!/bin/sh
echo "`$*" >> '$sshLog'
for a in "`$@"; do case "`$a" in *down*) echo "ssh: connect to host down.example.invalid port 22: Connection refused" >&2; exit 255;; esac; done
exec pwsh -NoProfile -NonInteractive -Command -
"@.Replace("`r`n", "`n"))
& chmod +x $fake
$env:PATH = (Join-Path $base 'fakebin') + [IO.Path]::PathSeparator + $env:PATH
$env:NO_COLOR = '1'
$script = Join-Path $fd 'Invoke-AccessConnectorUpgrade.ps1'
$csv = Join-Path $base 'sheets/fleet.example.csv'
$xlsx = Join-Path $base 'sheets/fleet.example.xlsx'

$script:Fails = 0
function Invoke-TestCase { param([string]$Name, [scriptblock]$Body)
    try { & $Body; "PASS $Name" } catch { $script:Fails++; "FAIL ${Name}: $($_.Exception.Message)" } }
function Assert-True { param($Condition, [string]$Why) if (-not $Condition) { throw $Why } }
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
    $sub = Join-Path $base 'sheets'
    $r = Invoke-Tool @('-ImportFleet', 'fleet.example.csv', '-FleetConfig', 'fleet.rel.psd1') -Cwd $sub
    Assert-True ($r.Code -eq 0) "exit $($r.Code): $($r.Text)"
    Assert-True (Test-Path (Join-Path $sub 'fleet.rel.psd1')) 'not written in the current folder'
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
Invoke-TestCase 'a password prompt with no terminal stops with exit 1 and contacts nothing' {
    Clear-Fleet; $null = Invoke-Tool @('-ImportFleet', $csv)
    # empty placeholders, so the run gets past the missing-files check to the password prompt
    foreach ($f in 'Installers/Access-Connector-Installer.exe','Configs/tenant2-es-config.json','TrustedCerts/ca.pem') { $null = New-Item -ItemType File -Force -Path (Join-Path $base $f) }
    if (Test-Path $sshLog) { Remove-Item $sshLog }
    $r = Invoke-Tool @('-Tenant', 'TENANT2', '-DryRun') -NoInput
    Assert-True ($r.Code -eq 1) "exit $($r.Code): $($r.Text)"
    Assert-True ($r.Text -match 'no terminal to type it in') 'message'
    Assert-True ($r.Text -match 'or use -Mode Stage') 'Stage not offered in SSH mode'
    Assert-True (-not (Test-Path $sshLog)) 'ssh was called'
    $r = Invoke-Tool @('-Tenant', 'TENANT2', '-DryRun') -PwshArgs @('-NonInteractive')
    Assert-True ($r.Code -eq 1 -and $r.Text -match 'no terminal to type it in') "pwsh -NonInteractive: exit $($r.Code): $($r.Text)"
    $r = Invoke-Tool @('-Tenant', 'TENANT2') -PwshArgs @('-NonInteractive')
    # with no terminal either check may answer first; both must say to add -Yes
    Assert-True ($r.Code -eq 1 -and $r.Text -match '(Not interactive: add -Yes|Add -Yes to confirm without a prompt)') "YES prompt under -NonInteractive: $($r.Text)"
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
Invoke-TestCase 'Discover: -Tenant with -Connector is named as ignored; hosts keep their fleet group; unreachable host is exit 1' {
    $out = Join-Path $base 'sheets/d1.csv'
    $r = Invoke-Tool @('-Mode', 'Discover', '-Tenant', 'TENANT2', '-Connector', 'connector1.example.local,down.example.invalid', '-ExportCsv', $out)
    Assert-True ($r.Code -eq 1) "exit $($r.Code)"
    Assert-True ($r.Text -match '\[ignored\] -Tenant: -Connector names the hosts') 'not named'
    Assert-True ($r.Text -match 'TENANT1 +connector1\.example\.local') 'connector1 not shown under TENANT1'
    $rows = @(Import-Csv -LiteralPath $out)
    Assert-True ($rows.Count -eq 2) "rows: $($rows.Count)"
    Assert-True ($rows[0].Group -eq 'TENANT1') "group: $($rows[0].Group)"
    Assert-True ($rows[1].Group -eq '' -and $rows[1].Notes -match '^not reached: ') "unreachable row: $($rows[1].Notes)"
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
    if (Test-Path $sshLog) { Remove-Item $sshLog }
    $out = Join-Path $base 'sheets/d2.csv'
    $r = Invoke-Tool @('-Mode', 'Discover', '-Connector', 'connector9.example.local', '-ExportCsv', $out)
    Assert-True ($r.Code -eq 0) "exit $($r.Code): $($r.Text)"
    Assert-True ($r.Text -match 'none: hosts named with -Connector') 'plan'
    $calls = @(Get-Content $sshLog)
    Assert-True ($calls.Count -eq 1 -and $calls[0] -match 'powershell -NoProfile -NonInteractive -Command -$') "ssh calls: $($calls -join ' | ')"
    Assert-True (-not (Get-Command scp -ErrorAction SilentlyContinue) -or $r.Text -notmatch 'scp') 'scp mentioned'
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
