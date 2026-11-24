#!/bin/sh
# Offline checks for the scripts, the test suites and the templates. Run from the repository root:  sh tools/check_scripts.sh
# Needs pwsh, python3 and bash. Touches no connector, domain controller or share: the scripts are parsed
# and asked for -Help; the orchestrator is run only as '-ImportFleet <template> -DryRun' and inside
# the test suites, which use temporary folders and stand-ins (for ssh, Windows, Group Policy, the
# network and the installers). The Prerequisites scripts are never run for real.
# (The file name goes to pwsh in an environment variable. Text after -Command '...' would be executed.)
set -u
fail=0
for f in "FleetDeploy/Invoke-AccessConnectorUpgrade.ps1" "FleetDeploy/Invoke-ConnectorUpgradeLocal.ps1" "Silent Install/Install-AccessConnector.ps1" Prerequisites/*.ps1; do
  # 1. parses, and uses nothing Windows PowerShell 5.1 lacks (connector-side scripts and the
  #    Prerequisites scripts; for these, also the code a single-quoted here-string carries, which
  #    runs under Windows PowerShell 5.1 later: a startup wrapper, a scheduled task)
  CHECK_FILE="$f" pwsh -NoLogo -NoProfile -Command '
    $e = $null; $t = $null; $file = $env:CHECK_FILE
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $file).Path, [ref]$t, [ref]$e)
    if ($e.Count) { $e | ForEach-Object { "  line {0}: {1}" -f $_.Extent.StartLineNumber, $_.Message }; exit 1 }
    $trees = @($ast)
    if ($file -like "Prerequisites/*") {
      foreach ($h in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and "$($n.StringConstantType)" -eq "SingleQuotedHereString" }, $true))) {
        $he = $null; $trees += [System.Management.Automation.Language.Parser]::ParseInput($h.Value, [ref]$t, [ref]$he)
        if ($he.Count) { "  line {0}: the here-string does not parse: {1}" -f $h.Extent.StartLineNumber, $he[0].Message; exit 1 } } }
    $new = 0
    foreach ($a in $trees) {
      $new += @($a.FindAll({ param($n) $n.GetType().Name -in "TernaryExpressionAst","PipelineChainAst" }, $true)).Count
      # ?? ??= ?. ?[] by the syntax tree, so they are found inside "...$(...)..." strings as well
      $new += @($a.FindAll({ param($n) ($n -is [System.Management.Automation.Language.BinaryExpressionAst] -and "$($n.Operator)" -eq "QuestionQuestion") -or ($n -is [System.Management.Automation.Language.AssignmentStatementAst] -and "$($n.Operator)" -eq "QuestionQuestionEquals") -or (($n -is [System.Management.Automation.Language.MemberExpressionAst] -or $n -is [System.Management.Automation.Language.IndexExpressionAst]) -and $n.NullConditional) }, $true)).Count }
    "parse ok, PowerShell 7-only constructs: $new   $file"
    if ($new -and $file -notlike "*Invoke-AccessConnectorUpgrade.ps1") { exit 1 }
  ' || fail=1
  # 2. ASCII only (Windows PowerShell 5.1 reads a file without a byte-order mark in the system code page)
  n=$(python3 -c "import sys; print(sum(1 for b in open(sys.argv[1],'rb').read() if b > 127))" "$f")
  [ "$n" = "0" ] || { echo "  non-ASCII bytes: $n   $f"; fail=1; }
done
# 2b. the launcher (.cmd) is ASCII with CRLF line ends throughout; the macOS script (.sh) is ASCII,
#     passes bash -n under /bin/bash (3.2 on macOS) and, when shellcheck is installed, shellcheck
for f in Prerequisites/*.cmd; do
  r=$(python3 -c "
import sys
d = open(sys.argv[1], 'rb').read()
hi = sum(1 for b in d if b > 127)
bad = (d.count(b'\n') - d.count(b'\r\n')) + (d.count(b'\r') - d.count(b'\r\n'))
print('ok' if hi == 0 and bad == 0 and d.endswith(b'\r\n') else 'non-ASCII bytes: %d, line ends other than CRLF: %d, ends with CRLF: %s' % (hi, bad, d.endswith(b'\r\n')))" "$f")
  if [ "$r" = "ok" ]; then echo "ASCII, CRLF line ends   $f"; else echo "  $r   $f"; fail=1; fi
done
b=bash; [ -x /bin/bash ] && b=/bin/bash
for f in Prerequisites/*.sh; do
  n=$(python3 -c "import sys; print(sum(1 for b in open(sys.argv[1],'rb').read() if b > 127))" "$f")
  [ "$n" = "0" ] || { echo "  non-ASCII bytes: $n   $f"; fail=1; }
  if "$b" -n "$f"; then echo "bash -n ok ($b)   $f"; else fail=1; fi
  if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -s bash -S warning "$f"; then echo "shellcheck ok   $f"; else fail=1; fi
  else echo "shellcheck not installed: skipped   $f"; fi
done
# 3. help text is at most 78 columns wide, and both FleetDeploy scripts carry the same version
for f in "FleetDeploy/Invoke-AccessConnectorUpgrade.ps1" "FleetDeploy/Invoke-ConnectorUpgradeLocal.ps1" Prerequisites/*.ps1; do
  w=$(NO_COLOR=1 pwsh -NoLogo -NoProfile -File "$f" -Help | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')
  echo "help width $w   $f"; [ "$w" -le 78 ] || fail=1
done
for f in Prerequisites/*.sh; do
  w=$(NO_COLOR=1 "$b" "$f" --help | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')
  echo "help width $w   $f"; [ "$w" -le 78 ] || fail=1
done
v1=$(grep -m1 -o "script:Version *= *'[^']*'" FleetDeploy/Invoke-AccessConnectorUpgrade.ps1)
v2=$(grep -m1 -o "script:Version *= *'[^']*'" FleetDeploy/Invoke-ConnectorUpgradeLocal.ps1)
echo "versions: $v1 | $v2"; [ "$v1" = "$v2" ] || fail=1
pwsh -NoLogo -NoProfile -Command '$null = Import-PowerShellDataFile -LiteralPath FleetDeploy/fleet.example.psd1; "example fleet file parses"' || fail=1
# 4. the offline test suites: the spreadsheet import, discovery and end to end (ssh is replaced by
#    a stand-in), then the Prerequisites scripts (stand-ins for Windows, Group Policy, the network
#    and the installers); the macOS installer's suite runs on macOS only
for t in tools/test_fleet_import.ps1 tools/test_fleet_discover.ps1 tools/test_fleet_e2e.ps1 \
         tools/test_prereq_openssh.ps1 tools/test_prereq_gpo_keys.ps1 tools/test_prereq_powershell7.sh tools/test_prereq_macos.sh; do
  case "$t" in
    *_macos.sh) [ "$(uname -s)" = "Darwin" ] || { echo "tests: skipped, macOS only   $t"; continue; }
                r=$(/bin/bash "$t" 2>&1); rc=$? ;;
    *.sh) r=$(bash "$t" 2>&1); rc=$? ;;
    *) r=$(pwsh -NoLogo -NoProfile -File "$t" 2>&1); rc=$? ;;
  esac
  printf '%s\n' "$r" | grep -v '^PASS ' | sed "s|^|  |"
  echo "tests: $(printf '%s\n' "$r" | grep -c '^PASS ') passed   $t"; [ "$rc" = "0" ] || fail=1
done
# 5. the committed spreadsheet templates are what the build script makes, and import cleanly
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
python3 tools/build_fleet_template.py --outdir "$tmp" >/dev/null || fail=1
for f in fleet.example.csv fleet.example.xlsx; do
  if cmp -s "$tmp/$f" "FleetDeploy/$f"; then echo "template up to date   FleetDeploy/$f"; else echo "  template differs from a fresh build: FleetDeploy/$f (run python3 tools/build_fleet_template.py)"; fail=1; fi
  NO_COLOR=1 pwsh -NoLogo -NoProfile -File FleetDeploy/Invoke-AccessConnectorUpgrade.ps1 -ImportFleet "FleetDeploy/$f" -FleetConfig "$tmp/fleet.check.psd1" -DryRun >"$tmp/import.out" 2>&1 \
    && echo "template imports (dry run)   FleetDeploy/$f" || { sed 's|^|  |' "$tmp/import.out"; fail=1; }
done
[ "$fail" = "0" ] && echo "ALL CHECKS PASSED" || echo "CHECKS FAILED"
exit $fail
