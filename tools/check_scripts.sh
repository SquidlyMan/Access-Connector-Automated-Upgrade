#!/bin/sh
# Offline checks for the three scripts. Run from the repository root:  sh tools/check_scripts.sh
# Needs pwsh and python3. Touches no connector: the scripts are parsed and asked for -Help, never run.
# (The file name goes to pwsh in an environment variable. Text after -Command '...' would be executed.)
set -u
fail=0
for f in "FleetDeploy/Invoke-AccessConnectorUpgrade.ps1" "FleetDeploy/Invoke-ConnectorUpgradeLocal.ps1" "Silent Install/Install-AccessConnector.ps1"; do
  # 1. parses, and uses nothing Windows PowerShell 5.1 lacks (connector-side scripts)
  CHECK_FILE="$f" pwsh -NoLogo -NoProfile -Command '
    $e = $null; $t = $null; $file = $env:CHECK_FILE
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $file).Path, [ref]$t, [ref]$e)
    if ($e.Count) { $e | ForEach-Object { "  line {0}: {1}" -f $_.Extent.StartLineNumber, $_.Message }; exit 1 }
    $new = @($ast.FindAll({ param($n) $n.GetType().Name -in "TernaryExpressionAst","PipelineChainAst" }, $true)).Count
    "parse ok, PowerShell 7-only constructs: $new   $file"
    if ($new -and $file -notlike "*Invoke-AccessConnectorUpgrade.ps1") { exit 1 }
  ' || fail=1
  # 2. ASCII only (Windows PowerShell 5.1 reads a file without a byte-order mark in the system code page)
  n=$(python3 -c "import sys; print(sum(1 for b in open(sys.argv[1],'rb').read() if b > 127))" "$f")
  [ "$n" = "0" ] || { echo "  non-ASCII bytes: $n   $f"; fail=1; }
done
# 3. help text is at most 78 columns wide, and both scripts carry the same version
for f in "FleetDeploy/Invoke-AccessConnectorUpgrade.ps1" "FleetDeploy/Invoke-ConnectorUpgradeLocal.ps1"; do
  w=$(NO_COLOR=1 pwsh -NoLogo -NoProfile -File "$f" -Help | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')
  echo "help width $w   $f"; [ "$w" -le 78 ] || fail=1
done
v1=$(grep -m1 -o "script:Version *= *'[^']*'" FleetDeploy/Invoke-AccessConnectorUpgrade.ps1)
v2=$(grep -m1 -o "script:Version *= *'[^']*'" FleetDeploy/Invoke-ConnectorUpgradeLocal.ps1)
echo "versions: $v1 | $v2"; [ "$v1" = "$v2" ] || fail=1
pwsh -NoLogo -NoProfile -Command '$null = Import-PowerShellDataFile -LiteralPath FleetDeploy/fleet.example.psd1; "example fleet file parses"' || fail=1
[ "$fail" = "0" ] && echo "ALL CHECKS PASSED" || echo "CHECKS FAILED"
exit $fail
