#!/bin/bash
# Offline tests of Prerequisites/Install-PowerShell7.ps1. Five parts, written into a temporary
# folder and run there in turn:
#   1. its pure functions (hash file, release choice, pre-staged MSI, retry, wrapping), loaded
#      from its syntax tree;
#   2. the main flow, in a simulation copy of the script: the real file with stand-ins inserted
#      for the functions that reach the network, the registry, msiexec, Authenticode and the
#      process table (make_sim.py below); nothing in it contacts a host or changes the system;
#   3. the command line (stray words, a quoted folder that ends in a backslash) and how a failed
#      run ends (the installed version read again);
#   4. the refusal inside an SSH session, and what still runs there (-CheckOnly);
#   5. the launcher Install-PowerShell7.cmd, as text (CRLF, ASCII, version, waits only on
#      failure, or after a restart code when double-clicked).
# Each case starts the simulation copy in a new pwsh. TMPDIR is a folder inside the temporary
# folder, and SSH_CONNECTION and SSH_CLIENT are cleared, so a run of this suite over SSH sees
# the same results. Needs pwsh, python3 and bash; contacts no host.
#   bash tools/test_prereq_powershell7.sh
# Prints PASS <name> / FAIL <name>: <why> per case, then ALL TESTS PASSED or TESTS FAILED (exit 0/1).
set -u
REPO="${FLEET_REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
SRC="$REPO/Prerequisites/Install-PowerShell7.ps1"
[ -f "$SRC" ] || { echo "FAIL load: $SRC not found"; echo "TESTS FAILED"; exit 1; }
T="$(mktemp -d)" || { echo "FAIL load: no temporary folder"; echo "TESTS FAILED"; exit 1; }
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/tmp"; TMPDIR="$T/tmp"; export TMPDIR
unset SSH_CONNECTION SSH_CLIENT

# ---------------------------------------------------------------------- make_sim.py
cat > "$T/make_sim.py" <<'PS7_MAKE_SIM'
# Builds a simulation copy of Install-PowerShell7.ps1: the real file, with stand-ins for the
# Windows-only and network functions inserted just before the main body. Nothing in the copy
# contacts a host or changes the system; msiexec, downloads and signatures are simulated.
import sys, re
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
marker = '# ====================================================================== main\n'
assert s.count(marker) == 1
mocks = r'''
# ---- SIMULATION STAND-INS (test copy only)
$script:SimCalls = 0
function Get-WindowsArch { 'x64' }
function Wait-ForNetwork { param([int]$TimeoutSeconds) $true }
function Get-InstalledPwsh { param([string]$Exe)
    $script:SimCalls++
    $v = $env:SIM_BEFORE; if ($script:SimCalls -gt 1) { $v = $env:SIM_AFTER }
    if ($v) { return [version]$v }; return $null }
function Resolve-Release { param([string]$Arch)
    if ($env:SIM_LOOKUP -eq 'throw') { throw (New-Object System.Net.WebException "The remote name could not be resolved: 'api.github.com'.") }
    if ($env:SIM_LOOKUP -eq 'none') { return $null }
    $h = $env:SIM_SHA; if ($env:SIM_LOOKUP -eq 'nohash') { $h = $null }
    [pscustomobject]@{ Version = [version]'7.5.4'; Tag = 'v7.5.4'; MsiName = "PowerShell-7.5.4-win-$Arch.msi"
        MsiUrl = 'https://example.invalid/PowerShell-7.5.4-win-x64.msi'; Sha256 = $h; HashSource = 'the hashes.sha256 of v7.5.4'; NewestStable = [version]'7.5.4' } }
function Save-WebFile { param([string]$Url, [string]$Path, [long]$MinBytes = 0)
    [IO.File]::WriteAllText($Path, ('FAKE-MSI-' * 1000)) }
function Test-MsiSignature { param([string]$Path) if ($env:SIM_SIG) { return $env:SIM_SIG }; return $null }
function Invoke-MsiInstall { param([string[]]$Arguments) $script:SimArgs = $Arguments; return [int]$env:SIM_RC }
function Test-PwshStarts { param([string]$Exe) if ($env:SIM_AFTER) { return $env:SIM_AFTER }; return $null }
# the process table: SIM_PROC picks the parent chain of this run
function Get-ProcessTable {
    $now = Get-Date
    function P([int]$Id, [int]$Parent, [string]$Name, [int]$AgeMin) { [pscustomobject]@{ ProcessId = [uint32]$Id; ParentProcessId = [uint32]$Parent; Name = $Name; CreationDate = $now.AddMinutes(-$AgeMin) } }
    switch ($env:SIM_PROC) {
        'fail'     { throw (New-Object System.UnauthorizedAccessException 'Access denied') }
        'sshd'     { return @((P $PID 2000 'powershell.exe' 1), (P 2000 1500 'powershell.exe' 2), (P 1500 1000 'sshd-session.exe' 3), (P 1000 700 'sshd.exe' 90), (P 700 4 'services.exe' 100)) }
        'sshd-old' { return @((P $PID 2000 'powershell.exe' 1), (P 2000 1500 'cmd.exe' 2), (P 1500 1000 'sshd.exe' 3), (P 1000 700 'sshd.exe' 90)) }
        'reused'   { return @((P $PID 2000 'powershell.exe' 1), (P 2000 1500 'cmd.exe' 5), (P 1500 1000 'sshd.exe' 2)) }
        'cycle'    { return @((P $PID 2000 'powershell.exe' 1), (P 2000 3000 'cmd.exe' 2), (P 3000 2000 'cmd.exe' 3)) }
        default    { return @((P $PID 2000 'powershell.exe' 1), (P 2000 1000 'cmd.exe' 2), (P 1000 4 'explorer.exe' 60)) }
    } }
'''
s = s.replace(marker, mocks + marker)
s = s.replace('$onWindows = ($PSVersionTable.PSEdition -ne \'Core\') -or $IsWindows', '$onWindows = $true')
old_admin = re.search(r'\$isAdmin = \$false\ntry \{ \$isAdmin = .*\n', s)
assert old_admin
s = s.replace(old_admin.group(0), "$isAdmin = ($env:SIM_ADMIN -eq '1')\n")
open(dst, 'w').write(s)
PS7_MAKE_SIM

# ---------------------------------------------------------------------- test-functions.ps1
cat > "$T/test-functions.ps1" <<'PS7_FUNCTIONS'
# Offline tests for the pure functions of Install-PowerShell7.ps1. Loads only the function
# definitions from the syntax tree, so the main body (and anything Windows-only) never runs.
# No network: nothing here calls a function that makes a web request.
param([string]$Script)
$ErrorActionPreference = 'Stop'
$t = $null; $e = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$t, [ref]$e)
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}
$script:UiWidth = 78; $script:RunLog = $null; $env:NO_COLOR = '1'
$MaxAttempts = 3; $RetryDelaySeconds = 0
Initialize-UiStyle
$pass = 0; $fail = 0
function Check { param([string]$Name, $Got, $Want)
    if ("$Got" -ceq "$Want") { $script:pass++; "PASS $Name" } else { $script:fail++; "FAIL ${Name}: got '$Got', want '$Want'" } }

# ---- Get-PublishedHash
$h1 = 'A' * 64; $h2 = 'b' * 64; $h3 = 'C' * 64; $h4 = 'd' * 64
$text = ([char]0xFEFF) + "$h3 *PowerShell-7.5.4-win-x64.msix`r`n$h1 *PowerShell-7.5.4-win-x64.msi`r`n$h2  PowerShell-7.5.4-win-arm64.msi`r`nPowerShell-7.5.4-win-x86.msi $h4`r`n"
Check 'hash: exact .msi name, not the .msix line before it' (Get-PublishedHash -Text $text -FileName 'PowerShell-7.5.4-win-x64.msi') $h1
Check 'hash: two-space form, returned in capitals' (Get-PublishedHash -Text $text -FileName 'PowerShell-7.5.4-win-arm64.msi') $h2.ToUpper()
Check 'hash: name-first form' (Get-PublishedHash -Text $text -FileName 'PowerShell-7.5.4-win-x86.msi') $h4.ToUpper()
Check 'hash: name matched case-insensitively' (Get-PublishedHash -Text $text -FileName 'powershell-7.5.4-WIN-x64.msi') $h1
Check 'hash: file not listed' ([string](Get-PublishedHash -Text $text -FileName 'PowerShell-7.5.3-win-x64.msi')) ''
Check 'hash: BOM on the first line' (Get-PublishedHash -Text (([char]0xFEFF) + "$h1 PowerShell-7.5.4-win-x64.msi") -FileName 'PowerShell-7.5.4-win-x64.msi') $h1
Check 'hash: short hex is not a hash' ([string](Get-PublishedHash -Text 'ABCDEF PowerShell-7.5.4-win-x64.msi' -FileName 'PowerShell-7.5.4-win-x64.msi')) ''

# ---- ConvertFrom-ReleaseUrl
Check 'tag url' (ConvertFrom-ReleaseUrl 'https://github.com/PowerShell/PowerShell/releases/tag/v7.5.4') '7.5.4'
Check 'tag url, trailing slash' (ConvertFrom-ReleaseUrl 'https://github.com/PowerShell/PowerShell/releases/tag/v7.10.0/') '7.10.0'
Check 'tag url, query' (ConvertFrom-ReleaseUrl '/PowerShell/PowerShell/releases/tag/v7.4.6?x=1') '7.4.6'
Check 'preview tag is no match' ([string](ConvertFrom-ReleaseUrl 'https://github.com/PowerShell/PowerShell/releases/tag/v7.6.0-preview.5')) ''
Check 'latest url is no match' ([string](ConvertFrom-ReleaseUrl 'https://github.com/PowerShell/PowerShell/releases/latest')) ''

# ---- Select-MsiRelease (shape of the GitHub API, parsed from JSON as the script does)
$json = @'
[
 {"tag_name":"v7.7.0","draft":false,"prerelease":false,"assets":[{"name":"PowerShell-7.7.0-win-x64.msix","browser_download_url":"u770x"},{"name":"hashes.sha256","browser_download_url":"h770"}]},
 {"tag_name":"v7.8.0-preview.1","draft":false,"prerelease":true,"assets":[{"name":"PowerShell-7.8.0-preview.1-win-x64.msi","browser_download_url":"p"}]},
 {"tag_name":"v7.9.0","draft":true,"prerelease":false,"assets":[{"name":"PowerShell-7.9.0-win-x64.msi","browser_download_url":"d"}]},
 {"tag_name":"v7.4.13","draft":false,"prerelease":false,"assets":[{"name":"PowerShell-7.4.13-win-x64.msi","browser_download_url":"u7413"}]},
 {"tag_name":"v7.6.2","draft":false,"prerelease":false,"assets":[{"name":"PowerShell-7.6.2-win-x64.msi","browser_download_url":"u762","digest":"sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"},{"name":"PowerShell-7.6.2-win-arm64.msi","browser_download_url":"u762a"},{"name":"hashes.sha256","browser_download_url":"h762"}]}
]
'@
$list = ConvertFrom-Json -InputObject $json
$r = Select-MsiRelease -Releases $list -Arch 'x64'
Check 'release: highest stable with an x64 MSI (skips MSIX-only, preview, draft; 7.6.2 beats a later-listed 7.4.13)' $r.Pick.Tag 'v7.6.2'
Check 'release: newest stable overall is reported' $r.NewestStable '7.7.0'
Check 'release: MSI address' $r.Pick.MsiUrl 'u762'
Check 'release: hashes.sha256 address from the same release' $r.Pick.HashUrl 'h762'
Check 'release: GitHub digest in capitals' $r.Pick.Digest ('0123456789abcdef' * 4).ToUpper()
Check 'release: arm64' (Select-MsiRelease -Releases $list -Arch 'arm64').Pick.MsiName 'PowerShell-7.6.2-win-arm64.msi'
Check 'release: x86 has none' ([string](Select-MsiRelease -Releases $list -Arch 'x86').Pick) ''
# Issue 13: Get-ReleaseFromApi collects the pages in a List[object]; under Windows PowerShell 5.1
# @() around that List threw "Argument types do not match". PowerShell 7 does not throw, so the
# List is passed here as it is, and the source is checked for the pattern below.
$gl = New-Object System.Collections.Generic.List[object]
foreach ($o in $list) { $gl.Add($o) }
$r = Select-MsiRelease -Releases $gl -Arch 'x64'
Check 'release: List[object] of ConvertFrom-Json objects, pick' $r.Pick.Tag 'v7.6.2'
Check 'release: List[object] of ConvertFrom-Json objects, newest stable' $r.NewestStable '7.7.0'
Check 'release: plain array from List.ToArray()' (Select-MsiRelease -Releases $gl.ToArray() -Arch 'x64').Pick.Tag 'v7.6.2'
$r = Select-MsiRelease -Releases (New-Object System.Collections.Generic.List[object]) -Arch 'x64'
Check 'release: empty List[object] gives no pick' ([string]$r.Pick) ''
Check 'release: empty List[object] gives no newest' ([string]$r.NewestStable) ''
$r = Select-MsiRelease -Releases $null -Arch 'x64'
Check 'release: $null gives no pick' ([string]$r.Pick) ''
Check 'release: one release object (not a list)' (Select-MsiRelease -Releases @($list)[4] -Arch 'x64').Pick.Tag 'v7.6.2'
# Get-ReleaseFromApi over three pages, with a stand-in for Get-WebText (no network): two full
# pages of MSIX-only releases and previews, then the page above. All pages are read.
$fill1 = @(1..10 | ForEach-Object { '{"tag_name":"v7.7.' + $_ + '","draft":false,"prerelease":false,"assets":[{"name":"PowerShell-7.7.' + $_ + '-win-x64.msix","browser_download_url":"m"}]}' }) -join ','
$fill2 = @(1..10 | ForEach-Object { '{"tag_name":"v7.8.0-preview.' + $_ + '","draft":false,"prerelease":true,"assets":[{"name":"PowerShell-7.8.0-preview.' + $_ + '-win-x64.msi","browser_download_url":"p"}]}' }) -join ','
$script:Pages = @{ 1 = "[$fill1]"; 2 = "[$fill2]"; 3 = $json }
$script:PagesAsked = 0
function Get-WebText { param([string]$Url, [string]$Description, [string]$Accept)
    $script:PagesAsked++
    if ($Url -notmatch '[?&]page=(\d+)') { throw "unexpected address $Url" }
    $script:Pages[[int]$Matches[1]] }
$r = Get-ReleaseFromApi -Arch 'x64'
Check 'api: three pages read' $script:PagesAsked '3'
Check 'api: pick across pages (List handed on as an array)' $r.Pick.Tag 'v7.6.2'
Check 'api: newest stable across pages' $r.NewestStable '7.7.10'
$script:Pages = @{ 1 = '[]' }; $script:PagesAsked = 0
$r = Get-ReleaseFromApi -Arch 'x64'
Check 'api: empty first page gives no pick' ([string]$r.Pick) ''
$srcText = [IO.File]::ReadAllText($Script)
Check 'source: no @() around the releases List' ([bool]($srcText -match '@\(\$Releases\)')) 'False'
Check 'source: Get-ReleaseFromApi passes $all.ToArray()' ([bool]($srcText -match 'Select-MsiRelease -Releases \$all\.ToArray\(\)')) 'True'

# ---- Find-StagedMsi (empty placeholder files in a temporary folder)
$d = Join-Path ([IO.Path]::GetTempPath()) ('ps7test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $d
foreach ($n in 'PowerShell-7.9.0-win-x64.msi','PowerShell-7.10.0-win-x64.msi','PowerShell-7.11.0-preview.1-win-x64.msi','PowerShell-7.12.0-win-arm64.msi','other.msi','PowerShell-7.13.0-win-x64.msix') { $null = New-Item -ItemType File -Path (Join-Path $d $n) }
try {
    Check 'staged: folder, 7.10 beats 7.9, preview/msix/other arch ignored' (Find-StagedMsi -Source $d -Arch 'x64').Name 'PowerShell-7.10.0-win-x64.msi'
    Check 'staged: version parsed' (Find-StagedMsi -Source $d -Arch 'x64').Version '7.10.0'
    Check 'staged: arm64 in the same folder' (Find-StagedMsi -Source $d -Arch 'arm64').Name 'PowerShell-7.12.0-win-arm64.msi'
    Check 'staged: file given directly' (Find-StagedMsi -Source (Join-Path $d 'PowerShell-7.9.0-win-x64.msi') -Arch 'x64').Version '7.9.0'
    $x = Find-StagedMsi -Source (Join-Path $d 'other.msi') -Arch 'x64'
    Check 'staged: file with a non-standard name is refused' ([string]$x) ''
    Check 'staged: ...and the reason is kept' ([bool]($script:StagedProblem -match 'is not named PowerShell-<version>-win-x64.msi')) 'True'
    Check 'staged: file for another processor is refused' ([string](Find-StagedMsi -Source (Join-Path $d 'PowerShell-7.12.0-win-arm64.msi') -Arch 'x64')) ''
    Check 'staged: missing path' ([string](Find-StagedMsi -Source (Join-Path $d 'nope') -Arch 'x64')) ''
} finally { Remove-Item -LiteralPath $d -Recurse -Force }

# ---- Invoke-WithRetry and Get-ErrorText (no network: the actions fail on purpose)
$script:calls = 0
$v = Invoke-WithRetry -Description 'test' -Action { $script:calls++; if ($script:calls -lt 3) { throw 'transient' }; 'ok' } 6>$null
Check 'retry: succeeds on the third try' "$v/$($script:calls)" 'ok/3'
$script:calls = 0; $threw = $false
try { $null = Invoke-WithRetry -Description 'test' -Action { $script:calls++; throw 'always' } 6>$null } catch { $threw = $true }
Check 'retry: gives up after -MaxAttempts and rethrows' "$threw/$($script:calls)" 'True/3'
$we = New-Object System.Net.WebException 'The remote name could not be resolved: ''github.com''.'
$mie = New-Object System.Management.Automation.MethodInvocationException -ArgumentList 'Exception calling "DownloadString" with "1" argument(s)', $we
Check 'error text: the WebException inside, without the final period' (Get-ErrorText $mie) 'The remote name could not be resolved: ''github.com'''
Check 'http status: none without a response' (Get-HttpStatus $mie) '0'

# ---- wrapping
$lines = @(Get-HangingLines -Prefix '[12:00:00] [INFO ] ' -Text (('word ' * 40).Trim()))
Check 'say: wrapped lines fit 78 columns' ([bool](@($lines | Where-Object { $_.Length -gt 78 }).Count -eq 0)) 'True'
Check 'say: continuation lines hang under the message' ([bool]($lines[1].StartsWith(' ' * 19) -and -not $lines[1].StartsWith(' ' * 20))) 'True'

if ($fail) { exit 1 }
PS7_FUNCTIONS

# ---------------------------------------------------------------------- run_sim.sh
cat > "$T/run_sim.sh" <<'PS7_MAIN_FLOW'
#!/bin/bash
# Runs the simulation copy through the main-flow cases. Offline: the stand-ins replace every
# function that would reach the network, the registry, msiexec or Authenticode.
set -u
T="$(cd "$(dirname "$0")" && pwd)"
SRC="$1"
SIM="$T/sim/Install-PowerShell7.sim.ps1"
mkdir -p "$T/sim/logs" "$T/sim/staged-ok" "$T/sim/staged-bad" "$T/sim/staged-nohash" "$T/sim/staged-empty"
python3 -I "$T/make_sim.py" "$SRC" "$SIM" || exit 1
# a fake package: the download stand-in writes the same bytes
python3 -I -c "open('$T/sim/fake.msi','w').write('FAKE-MSI-' * 1000)"
SHA=$(python3 -I -c "import hashlib; print(hashlib.sha256(open('$T/sim/fake.msi','rb').read()).hexdigest().upper())")
for d in staged-ok staged-bad staged-nohash; do cp "$T/sim/fake.msi" "$T/sim/$d/PowerShell-7.5.4-win-x64.msi"; done
printf '%s *PowerShell-7.5.4-win-x64.msix\n%s *PowerShell-7.5.4-win-x64.msi\n' "$(printf 'E%.0s' {1..64})" "$SHA" > "$T/sim/staged-ok/hashes.sha256"
printf '%s *PowerShell-7.5.4-win-x64.msi\n' "$(printf 'F%.0s' {1..64})" > "$T/sim/staged-bad/hashes.sha256"
pass=0; fail=0
run() { # name, want-exit, want-text, then KEY=VALUE... -- args...
  local name="$1" want="$2" text="$3"; shift 3
  local envs=(ProgramFiles="$T/sim/pf" SIM_ADMIN=1 SIM_RC=0 SIM_SHA="$SHA" SIM_LOOKUP=ok SIM_BEFORE= SIM_AFTER= SIM_SIG=)
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "$#" -gt 0 ] && shift
  out=$(env "${envs[@]}" NO_COLOR=1 COMPUTERNAME=SIMHOST pwsh -NoLogo -NoProfile -File "$SIM" -LogRoot "$T/sim/logs" -RetryDelaySeconds 0 "$@" 2>&1); rc=$?
  if [ "$rc" = "$((want % 256))" ] && printf '%s' "$out" | tr '\n' ' ' | tr -s ' ' | grep -qF -- "$text"; then pass=$((pass+1)); echo "PASS $name (exit $rc)"
  else fail=$((fail+1)); echo "FAIL $name: exit $rc (want $want), text '$text'"; printf '%s\n' "$out" | sed 's/^/    /'; fi
}
run 'current version: nothing to do'           0    'is installed and current. Nothing to do.'      SIM_BEFORE=7.5.4
run 'newer installed: nothing to do'           0    'newer than the package (7.5.4)'                SIM_BEFORE=7.6.0
run 'current + -EnablePSRemoting: note'        0    '[note] -EnablePSRemoting changed nothing'      SIM_BEFORE=7.5.4 -- -EnablePSRemoting
run 'check only: update available'             0    'Update available: PowerShell 7.4.6 -> 7.5.4'   SIM_ADMIN=0 SIM_BEFORE=7.4.6 -- -CheckOnly
run 'check only: not installed'                0    '7.5.4 would be'                                SIM_ADMIN=0 -- -CheckOnly
run 'install without elevation: refused'       1    'Installing needs an elevated session'          SIM_ADMIN=0
run 'download install: verified, installed'    0    'Result: installed PowerShell 7.5.4, from PowerShell-7.5.4-win-x64.msi (downloaded from GitHub; SHA-256 and signature checked)' SIM_AFTER=7.5.4
run 'download without published hash: closed'  1    'so it is not downloaded or installed'          SIM_LOOKUP=nohash
run 'download hash mismatch: refused'          1    'SHA-256 MISMATCH'                              SIM_SHA=0000000000000000000000000000000000000000000000000000000000000000
run 'staged + hashes, 3010: restart pending'   3010 'Restart Windows to finish the installation.'   SIM_BEFORE=7.4.6 SIM_AFTER=7.4.6 SIM_RC=3010 -- -MsiSource "$T/sim/staged-ok"
run 'staged + hashes: .msix line not used'     0    'SHA-256 matches'                               SIM_BEFORE=7.4.6 SIM_AFTER=7.5.4 -- -MsiSource "$T/sim/staged-ok"
run 'staged, wrong hash: refused'              1    'SHA-256 MISMATCH'                              -- -MsiSource "$T/sim/staged-bad/"
run 'staged, no hashes file: note, installs'   0    'only its Microsoft signature is checked'       SIM_AFTER=7.5.4 -- -MsiSource "$T/sim/staged-nohash"
run 'staged folder empty: falls back'          0    'is not used: it holds no PowerShell-<version>-win-x64.msi. Downloading instead.' SIM_AFTER=7.5.4 -- -MsiSource "$T/sim/staged-empty"
run 'staged path missing: falls back'          0    'that path does not exist'                      SIM_AFTER=7.5.4 -- -MsiSource "$T/sim/nope"
run 'quoted folder with trailing quote'        0    'SHA-256 matches'                               SIM_AFTER=7.5.4 -- -MsiSource "$T/sim/staged-ok\""
run 'msiexec 1603: its code, log named'        1603 'msiexec returned 1603. Details:'               SIM_RC=1603
run 'msiexec 1618: busy message'               1618 'stayed busy with another installation (1618)'  SIM_RC=1618
run 'signature bad: refused'                   1    'Refusing to install PowerShell-7.5.4-win-x64.msi: its signature is NotSigned' SIM_SIG='its signature is NotSigned: none'
run 'lookup fails: offline hint'               1    'The release lookup failed: The remote name could not be resolved' SIM_LOOKUP=throw
run 'no release found'                         1    'No stable PowerShell 7 release with an MSI for win-x64 was found' SIM_LOOKUP=none
run 'success code but pwsh missing: error'     1    'msiexec reported success, but'                 SIM_RC=0
run 'check only + -NoPause (for the launcher)' 0   'Update available: PowerShell 7.4.6 -> 7.5.4'   SIM_ADMIN=0 SIM_BEFORE=7.4.6 -- -CheckOnly -NoPause
run 'remoting and MU switches reach msiexec'   0    'ENABLE_PSREMOTING=1 USE_MU=0 ENABLE_MU=0'      SIM_AFTER=7.5.4 -- -EnablePSRemoting -NoMicrosoftUpdate
[ "$fail" = 0 ]
PS7_MAIN_FLOW

# ---------------------------------------------------------------------- fix_cases.sh
cat > "$T/fix_cases.sh" <<'PS7_COMMAND_LINE'
#!/bin/bash
# Cases for the command line (stray words, quoted paths) and for how a failed run ends, run against the
# simulation copy that run_sim.sh builds (stand-ins for msiexec, downloads, signatures and the
# registry; nothing here contacts a host or changes the system).
set -u
T="$(cd "$(dirname "$0")" && pwd)"
SIM="$T/sim/Install-PowerShell7.sim.ps1"
[ -f "$SIM" ] || { echo "run run_sim.sh first"; exit 1; }
W="$T/cases"; mkdir -p "$W/logs" "$W/pf"
SHA=$(python3 -I -c "import hashlib; print(hashlib.sha256(('FAKE-MSI-' * 1000).encode()).hexdigest().upper())")
AUD="$W/logs/Install-PowerShell7-audit.log"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; printf '%s\n' "$OUT" | sed 's/^/    /' | tail -25; }
# sim NAME KEY=VALUE... -- args...   -> sets OUT (all output), RC, FIRST, LAST (non-empty lines, wrapped lines joined)
sim() {
  local envs=(ProgramFiles="$W/pf" SIM_ADMIN=1 SIM_RC=0 SIM_SHA="$SHA" SIM_LOOKUP=ok SIM_BEFORE= SIM_AFTER= SIM_SIG=)
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "$#" -gt 0 ] && shift
  OUT=$(env "${envs[@]}" NO_COLOR=1 COMPUTERNAME=SIMHOST pwsh -NoLogo -NoProfile -File "$SIM" -RetryDelaySeconds 0 "$@" 2>&1); RC=$?
  FLAT=$(printf '%s\n' "$OUT" | python3 -I -c "
import sys, re
out, cur = [], None
for l in sys.stdin.read().splitlines():
    if not l.strip(): continue
    if l.startswith(' ' * 19) and cur is not None and re.match(r'^\[\d\d:\d\d:\d\d\] ', cur): cur += ' ' + l.strip(); continue
    if cur is not None: out.append(cur)
    cur = l
if cur is not None: out.append(cur)
print('\n'.join(out))")
  FIRST=$(printf '%s\n' "$FLAT" | head -1); LAST=$(printf '%s\n' "$FLAT" | tail -1)
}
has()   { printf '%s' "$FLAT" | grep -qF -- "$1"; }
entries() { [ -f "$AUD" ] && grep -c '^time=' "$AUD" || echo 0; }
lastaudit() { tail -1 "$AUD" | tr ' ' '\n' | grep -E "^$1=" | cut -d= -f2-; }
NOTICE='UNSUPPORTED - provided "AS IS", NO WARRANTY.'

for w in '/?' '/HELP'; do
  sim SIM_BEFORE=7.4.6 SIM_AFTER=7.5.4 -- "$w" -LogRoot "$W/logs"
  if [ "$RC" = 0 ] && has 'LEGAL DISCLAIMER' && has ' EXAMPLES ' && ! has 'Result:' && [[ "$FIRST" == *"$NOTICE"* ]]; then ok "'$w' alone shows the help, installs nothing"; else bad "'$w' alone"; fi
done
n0=$(entries); f0=$(ls "$W/logs" | wc -l | tr -d ' ')
for w in 'checkonly' '/CheckOnly' '-CheckOnyl' 'help'; do
  sim SIM_BEFORE=7.4.6 SIM_AFTER=7.5.4 -- "$w" -LogRoot "$W/logs"
  if [ "$RC" = 1 ] && has "Not a parameter of this script: $w." && ! has 'Result:' && ! has 'Downloading' && [[ "$FIRST" == *"$NOTICE"* ]] && [[ "$LAST" == *"Nothing was changed."* ]]; then ok "'$w': refused after the notice, exit 1"; else bad "'$w'"; fi
done
sim SIM_BEFORE=7.4.6 -- '/?' extra -LogRoot "$W/logs"
[ "$RC" = 1 ] && has 'Not a parameter of this script: /? extra.' && ok "'/? extra': refused (help only for /? alone)" || bad "'/? extra'"
sim SIM_BEFORE=7.4.6 SIM_AFTER=7.5.4 -- '' -LogRoot "$W/logs"
[ "$RC" = 1 ] && has 'Not a parameter of this script: (an empty argument).' && ! has 'Result:' && ok "one empty argument: refused (the old binding refused it as an empty -MsiSource)" || bad "empty argument"
sim SIM_BEFORE=7.4.6 -- '/?' -CheckOnly -LogRoot "$W/logs"
[ "$RC" = 0 ] && has 'LEGAL DISCLAIMER' && ! has 'Update available' && ok "'/? -CheckOnly': help, nothing else" || bad "'/? -CheckOnly'"
n1=$(entries); f1=$(ls "$W/logs" | wc -l | tr -d ' ')
[ "$n0" = "$n1" ] && [ "$f0" = "$f1" ] && ok "refusals open no log: audit entries $n0 -> $n1, files in log folder $f0 -> $f1" || bad "refusals wrote logs ($n0 -> $n1 entries, $f0 -> $f1 files)"
mkdir -p "$W/sp"
sim SIM_ADMIN=0 SIM_BEFORE=7.4.6 -- -CheckOnly -AuditLog "$W/sp/IT" 'Logs/a.log' -LogRoot "$W/logs"
[ "$RC" = 1 ] && has 'Not a parameter of this script: Logs/a.log.' && [ -z "$(ls -A "$W/sp")" ] && ok "unquoted path with a space: refused, no stray file" || bad "unquoted path with a space"
sim SIM_ADMIN=0 SIM_BEFORE=7.4.6 SIM_AFTER=7.4.6 -- -MsiSource "$T/sim/staged-ok" -CheckOnly -LogRoot "$W/logs"
[ "$RC" = 0 ] && has 'Pre-staged package:' && has 'Update available: PowerShell 7.4.6 -> 7.5.4' && ok "named -MsiSource and -CheckOnly still bind" || bad "named parameters"
sim SIM_ADMIN=0 -- -Check -LogRoot "$W/logs"
[ "$RC" = 0 ] && has 'would be. Run this again without -CheckOnly' && ok "a unique prefix (-Check) still binds" || bad "prefix"

mkdir -p "$W/f2"
sim SIM_ADMIN=0 SIM_BEFORE=7.4.6 -- -CheckOnly -LogRoot "$W/logs" -AuditLog "$W/f2/Logs\"" -ErrorLog "$W/f2/Logs\"" -NetworkWaitSeconds 99999
sim SIM_ADMIN=0 SIM_BEFORE=7.4.6 -- -CheckOnly -LogRoot "$W/logs" -AuditLog "$W/f2/Logs\"" -ErrorLog "$W/f2/Logs\""
if [ -d "$W/f2/Logs" ] && [ "$(grep -c '^time=' "$W/f2/Logs/Install-PowerShell7-audit.log")" = 2 ] && [ "$(grep -c '^# Install-PowerShell7.ps1 audit log - append only' "$W/f2/Logs/Install-PowerShell7-audit.log")" = 1 ] \
   && grep -q '^# Install-PowerShell7.ps1 error log' "$W/f2/Logs/Install-PowerShell7-errors.log" && grep -q 'NetworkWaitSeconds must be' "$W/f2/Logs/Install-PowerShell7-errors.log"; then
  ok "-AuditLog/-ErrorLog \"<new folder>\\\": a folder with both default-named logs, audit header once ($(ls "$W/f2/Logs" | tr '\n' ' '))"
else bad "trailing quote: $(ls -la "$W/f2")"; fi
sim SIM_ADMIN=0 SIM_BEFORE=7.4.6 -- -CheckOnly -LogRoot "$W/f2/root\""
[ "$RC" = 0 ] && [ -d "$W/f2/root" ] && ls "$W/f2/root" | grep -q '^Install-PowerShell7_' && ok "-LogRoot with a trailing quote: the folder, with its run log" || bad "-LogRoot"
mkdir -p "$W/f2b"; n0=$(entries)
sim SIM_BEFORE=7.4.6 SIM_AFTER=7.5.4 -- -LogRoot "$W/logs" -AuditLog "$W/f2b/IT Logs\" -CheckOnly"
if [ "$RC" = 1 ] && has '-AuditLog is not a usable path, it holds a quote:' && ! has 'Result:' && ! has 'Downloading' && [ -z "$(ls -A "$W/f2b")" ] && [ "$(entries)" = "$n0" ]; then ok "swallowed -CheckOnly: refused, nothing installed, nothing written"; else bad "swallowed switch"; fi
sim SIM_BEFORE=7.4.6 SIM_AFTER=7.5.4 -- -LogRoot "$W/logs" -MsiSource "$T/sim/staged-ok\" -CheckOnly"
[ "$RC" = 1 ] && has '-MsiSource is not a usable path, it holds a quote:' && ok "swallowed switch after -MsiSource: refused" || bad "-MsiSource"

sim SIM_BEFORE=7.4.6 SIM_AFTER=7.4.6 SIM_RC=1603 -- -LogRoot "$W/logs"
[ "$RC" = 67 ] && [[ "$LAST" == *"[INFO ] Installed now: PowerShell 7.4.6 in "*"(unchanged)." ]] && [ "$(lastaudit after)" = 7.4.6 ] && [ "$(lastaudit stage)" = install ] && ok "1603, rolled back: last line '(unchanged)', after=7.4.6" || bad "1603 rolled back (last: $LAST)"
sim SIM_BEFORE=7.4.6 SIM_AFTER= SIM_RC=1603 -- -LogRoot "$W/logs"
[ "$RC" = 67 ] && [[ "$LAST" == *"[WARN ] Installed now: no PowerShell 7 in "*"(PowerShell 7.4.6 before this run)." ]] && [ "$(lastaudit after)" = none ] && ok "1603, pwsh.exe gone: says so, after=none (was a copied 7.4.6)" || bad "1603 gone (last: $LAST; after=$(lastaudit after))"
sim SIM_BEFORE= SIM_AFTER=7.5.4 SIM_RC=1603 -- -LogRoot "$W/logs"
[[ "$LAST" == *"[WARN ] Installed now: PowerShell 7.5.4 in "*"(none before this run)." ]] && [ "$(lastaudit after)" = 7.5.4 ] && ok "1603, yet a version appeared: says so" || bad "1603 appeared (last: $LAST)"
sim SIM_BEFORE=7.4.6 SIM_AFTER=7.4.6 SIM_RC=1618 -- -LogRoot "$W/logs"
[ "$RC" = 82 ] && [[ "$LAST" == *"Installed now: PowerShell 7.4.6 in "*"(unchanged)." ]] && ok "1618: ends with the version" || bad "1618 (last: $LAST)"
sim SIM_BEFORE=7.4.6 SIM_AFTER=7.4.6 SIM_SHA=0000000000000000000000000000000000000000000000000000000000000000 -- -LogRoot "$W/logs"
[ "$RC" = 1 ] && has 'SHA-256 MISMATCH' && [[ "$LAST" == *"(unchanged)." ]] && [ "$(lastaudit stage)" = verify ] && [ "$(lastaudit after)" = 7.4.6 ] && ok "hash mismatch: ends with the version, after= measured" || bad "mismatch (last: $LAST)"
sim SIM_BEFORE= SIM_AFTER= SIM_RC=0 -- -LogRoot "$W/logs"
[ "$RC" = 1 ] && has 'msiexec reported success, but' && [[ "$LAST" == *"Installed now: no PowerShell 7 in "*"(unchanged)." ]] && ok "verify failure: ends with the version" || bad "verify (last: $LAST)"
sim SIM_ADMIN=0 SIM_BEFORE=7.4.6 SIM_AFTER=7.4.6 SIM_LOOKUP=throw -- -CheckOnly -LogRoot "$W/logs"
[ "$RC" = 1 ] && has 'The release lookup failed' && [[ "$LAST" == *"(unchanged)." ]] && ok "-CheckOnly lookup failure: ends with the version" || bad "lookup (last: $LAST)"
sim SIM_ADMIN=0 SIM_BEFORE=7.4.6 SIM_AFTER=7.4.6 -- -LogRoot "$W/logs"
[ "$RC" = 1 ] && has 'Installing needs an elevated session' && [[ "$LAST" == *"(unchanged)." ]] && ok "not elevated: ends with the version" || bad "precheck (last: $LAST)"
sim SIM_BEFORE=7.4.6 -- -LogRoot "$W/logs" -MaxAttempts 99
[ "$RC" = 1 ] && [[ "$LAST" == *"-MaxAttempts must be from 1 to 20"* ]] && [ -z "$(lastaudit after)" ] && ok "argument error before pwsh.exe is looked at: no state line, no after=" || bad "args (last: $LAST)"
sim SIM_BEFORE=7.4.6 SIM_AFTER=7.4.6 TMPDIR=/nonexistent-ps7-test/ -- -LogRoot "$W/logs"
[ "$RC" = 1 ] && has 'Unexpected error:' && [[ "$LAST" == *"Installed now: PowerShell 7.4.6 in "*"(unchanged)." ]] && [ "$(lastaudit stage)" = unexpected ] && [ "$(lastaudit after)" = 7.4.6 ] && ok "trap (work folder cannot be made): ends with the version" || bad "trap (last: $LAST)"

for a in "-Help" "/?" "checkonly" "-CheckOnly"; do sim SIM_ADMIN=0 -- "$a" -LogRoot "$W/logs"; [[ "$FIRST" == *"$NOTICE"* ]] && ok "notice first: $a" || bad "notice first: $a"; done
[ "$fail" = 0 ]
PS7_COMMAND_LINE

# ---------------------------------------------------------------------- ssh_cases.sh
cat > "$T/ssh_cases.sh" <<'PS7_SSH'
#!/bin/bash
# Cases for the SSH refusal, run against the simulation copy that run_sim.sh builds (stand-ins for
# msiexec, downloads, signatures, the registry and the process table; nothing here contacts a
# host or changes the system).
set -u
T="$(cd "$(dirname "$0")" && pwd)"
SIM="$T/sim/Install-PowerShell7.sim.ps1"
[ -f "$SIM" ] || { echo "run run_sim.sh first"; exit 1; }
W="$T/sshcases"; mkdir -p "$W/logs" "$W/pf"
SHA=$(python3 -I -c "import hashlib; print(hashlib.sha256(('FAKE-MSI-' * 1000).encode()).hexdigest().upper())")
AUD="$W/logs/Install-PowerShell7-audit.log"; ERR="$W/logs/Install-PowerShell7-errors.log"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; printf '%s\n' "$OUT" | sed 's/^/    /' | tail -25; }
sim() {
  local envs=(ProgramFiles="$W/pf" SIM_ADMIN=1 SIM_RC=0 SIM_SHA="$SHA" SIM_LOOKUP=ok SIM_BEFORE= SIM_AFTER= SIM_SIG= SIM_PROC=)
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "$#" -gt 0 ] && shift
  OUT=$(env -u SSH_CONNECTION -u SSH_CLIENT "${envs[@]}" NO_COLOR=1 COMPUTERNAME=SIMHOST pwsh -NoLogo -NoProfile -File "$SIM" -RetryDelaySeconds 0 -LogRoot "$W/logs" "$@" 2>&1); RC=$?
  FLAT=$(printf '%s\n' "$OUT" | tr '\n' ' ' | tr -s ' ')
  LAST=$(printf '%s\n' "$OUT" | python3 -I -c "
import sys, re
out, cur = [], None
for l in sys.stdin.read().splitlines():
    if not l.strip(): continue
    if l.startswith(' ' * 19) and cur is not None and re.match(r'^\[\d\d:\d\d:\d\d\] ', cur): cur += ' ' + l.strip(); continue
    if cur is not None: out.append(cur)
    cur = l
if cur is not None: out.append(cur)
print(out[-1] if out else '')")
}
has() { printf '%s' "$FLAT" | grep -qF -- "$1"; }
lastaudit() { tail -1 "$AUD" | tr ' ' '\n' | grep -E "^$1=" | cut -d= -f2-; }
REFUSED='so PowerShell 7 is not installed or updated: replacing PowerShell 7 over SSH can end the session and stop the install half-way, especially when the OpenSSH default shell is pwsh. Run this at the console, by Remote Desktop, or through WinRM (Enter-PSSession or Invoke-Command) instead. -CheckOnly works over SSH. Nothing was changed.'
n=0
for spec in "SSH_CONNECTION=10.9.8.7 51000 10.0.0.9 22|SSH_CONNECTION is set: a session from 10.9.8.7" \
            "SSH_CLIENT=10.9.8.7 51000 22|SSH_CLIENT is set: a session from 10.9.8.7" \
            "SIM_PROC=sshd|its parent process sshd-session.exe (process 1500) is the OpenSSH server" \
            "SIM_PROC=sshd-old|its parent process sshd.exe (process 1500) is the OpenSSH server"; do
  envset="${spec%%|*}"; why="${spec#*|}"; n=$((n+1))
  e0=$( [ -f "$ERR" ] && grep -c 'inside an SSH session' "$ERR" || echo 0 )
  sim "$envset" SIM_BEFORE=7.4.6 SIM_AFTER=7.4.6 --
  e1=$(grep -c 'inside an SSH session' "$ERR")
  if [ "$RC" = 1 ] && has "This run is inside an SSH session ($why), $REFUSED" && ! has 'Downloading' && ! has 'msiexec.exe' && ! has 'Result:' && ! has 'Looking for the newest' && [ -z "$(lastaudit package)" ] \
     && [[ "$LAST" == *"Installed now: PowerShell 7.4.6 in "*"(unchanged)." ]] && [ "$(lastaudit outcome)" = FAILED ] && [ "$(lastaudit stage)" = precheck ] \
     && [ "$((e1 - e0))" = 1 ] && tail -1 "$AUD" | grep -qF "($why)"; then
    ok "SSH $n ($why): exit 1, no lookup, nothing downloaded or run, error and audit lines, installed version said"
  else bad "SSH $n ($envset)"; fi
done
sim "SSH_CONNECTION=10.9.8.7 51000 10.0.0.9 22" SIM_BEFORE= SIM_AFTER= --
[ "$RC" = 1 ] && has 'inside an SSH session' && ! has 'Downloading' && ok "SSH: a first install is refused too" || bad "SSH first install"
sim "SSH_CONNECTION=10.9.8.7 51000 10.0.0.9 22" SIM_BEFORE=7.4.6 SIM_AFTER=7.4.6 -- -MsiSource "$T/sim/staged-ok"
[ "$RC" = 1 ] && has 'inside an SSH session' && ! has 'SHA-256 matches' && ok "SSH: a pre-staged package is not copied or checked" || bad "SSH staged"
sim "SSH_CONNECTION=10.9.8.7 51000 10.0.0.9 22" SIM_ADMIN=0 SIM_BEFORE=7.4.6 --
[ "$RC" = 1 ] && has 'Installing needs an elevated session' && ok "SSH, not elevated: the elevation message comes first" || bad "SSH not elevated"
sim "SSH_CONNECTION=10.9.8.7 51000 10.0.0.9 22" SIM_ADMIN=0 SIM_BEFORE=7.4.6 -- -CheckOnly
[ "$RC" = 0 ] && has 'Update available: PowerShell 7.4.6 -> 7.5.4' && ! has 'inside an SSH session' && [ "$(lastaudit stage)" = check ] && ok "SSH + -CheckOnly: reports, exit 0" || bad "SSH -CheckOnly"
sim "SSH_CONNECTION=10.9.8.7 51000 10.0.0.9 22" SIM_ADMIN=0 SIM_BEFORE=7.5.4 -- -CheckOnly
[ "$RC" = 0 ] && has 'is installed and current. Nothing to do.' && ! has 'inside an SSH session' && [ "$(lastaudit stage)" = current ] && ok "SSH + -CheckOnly, already current: reports, exit 0" || bad "SSH -CheckOnly current"
sim "SSH_CONNECTION=10.9.8.7 51000 10.0.0.9 22" SIM_ADMIN=0 SIM_BEFORE=7.4.6 SIM_LOOKUP=throw -- -CheckOnly
[ "$RC" = 1 ] && has 'The release lookup failed' && ! has 'inside an SSH session' && [ "$(lastaudit stage)" = lookup ] && ok "SSH + -CheckOnly, lookup fails: the lookup's own message (it runs over SSH)" || bad "SSH -CheckOnly lookup"
sim "SSH_CONNECTION=10.9.8.7 51000 10.0.0.9 22" SIM_BEFORE=7.5.4 SIM_AFTER=7.5.4 --
[ "$RC" = 1 ] && has 'inside an SSH session' && ! has 'is installed and current' && ! has 'Looking for the newest' && [ "$(lastaudit outcome)" = FAILED ] && [ "$(lastaudit stage)" = precheck ] && ok "SSH, already current: refused before the lookup, exit 1 (was exit 0)" || bad "SSH current"
sim "SSH_CONNECTION=10.9.8.7 51000 10.0.0.9 22" SIM_BEFORE=7.6.0 SIM_AFTER=7.6.0 --
[ "$RC" = 1 ] && has 'inside an SSH session' && ! has 'newer than the package' && ok "SSH, newer installed: refused before the lookup" || bad "SSH newer"
sim "SSH_CONNECTION=10.9.8.7 51000 10.0.0.9 22" SIM_BEFORE=7.4.6 SIM_AFTER=7.4.6 SIM_LOOKUP=throw --
[ "$RC" = 1 ] && has 'inside an SSH session' && ! has 'The release lookup failed' && [ "$(lastaudit stage)" = precheck ] && ok "SSH, the lookup would fail: the SSH reason is given, stage=precheck (was stage=lookup)" || bad "SSH lookup throw"
sim "SSH_CONNECTION=10.9.8.7 51000 10.0.0.9 22" SIM_BEFORE=7.4.6 SIM_AFTER=7.4.6 -- -MsiSource "$W/no-such-folder"
[ "$RC" = 1 ] && has 'inside an SSH session' && ! has 'is not used' && ! has 'Pre-staged package' && ok "SSH, -MsiSource given: refused before the path is read" || bad "SSH msisource"
for p in reused cycle ''; do
  sim SIM_PROC="$p" SIM_BEFORE=7.4.6 SIM_AFTER=7.5.4 --
  [ "$RC" = 0 ] && has 'Result: updated PowerShell 7.4.6 to 7.5.4' && ! has 'inside an SSH session' && ! has '[note] The parent processes' && ok "no SSH (parent chain '${p:-plain}'): installs" || bad "no SSH ($p)"
done
sim "SSH_CONNECTION=   " SIM_BEFORE=7.4.6 SIM_AFTER=7.5.4 --
[ "$RC" = 0 ] && has 'Result: updated' && ok "SSH_CONNECTION of spaces only: not a session, installs" || bad "blank SSH_CONNECTION"
sim SIM_PROC=fail SIM_BEFORE=7.4.6 SIM_AFTER=7.5.4 --
[ "$RC" = 0 ] && has '[note] The parent processes could not be read (Access denied), so only SSH_CONNECTION and SSH_CLIENT showed whether this runs in an SSH session.' && has 'Result: updated' && ok "parents unreadable: a note, then the install" || bad "parents unreadable"
sim SIM_PROC=fail SIM_BEFORE=7.5.4 SIM_AFTER=7.5.4 --
[ "$RC" = 0 ] && has '[note] The parent processes could not be read' && has 'is installed and current. Nothing to do.' && ok "parents unreadable, already current: a note, then nothing to do" || bad "parents unreadable current"
sim SIM_PROC=sshd SIM_BEFORE=7.4.6 SIM_AFTER=7.4.6 -- -CheckOnly
[ "$RC" = 0 ] && has 'Update available' && ! has 'inside an SSH session' && ! has '[note] The parent processes' && ok "sshd among the parents + -CheckOnly: reports, the parents not even read" || bad "sshd parent checkonly"
H=$(NO_COLOR=1 pwsh -NoLogo -NoProfile -File "$SIM" -Help 2>&1)
w=$(printf '%s\n' "$H" | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')
HF=$(printf '%s' "$H" | tr '\n' ' ' | tr -s ' ')
if [ "$w" -le 78 ] && printf '%s' "$HF" | grep -qF 'Not over SSH. Replacing PowerShell 7 over SSH can end the session and stop the install half-way, especially when the OpenSSH default shell is pwsh.' && printf '%s' "$HF" | grep -qF 'Needs no elevation, and works over SSH.' && printf '%s' "$HF" | grep -qF '1: not elevated, inside an SSH session (see STARTING IT)' && printf '%s' "$HF" | grep -qF 'it stops with exit code 1 before it looks up a release, reads -MsiSource or downloads anything, also when PowerShell 7 is already current' && ! printf '%s' "$HF" | grep -qF 'and so does a run that finds PowerShell 7 current' && ! printf '%s' "$HF" | grep -qF 'before anything is downloaded'; then ok "-Help: the SSH rule, -CheckOnly and exit code 1 say it; widest line $w"; else bad "-Help (width $w)"; fi
[ "$fail" = 0 ]
PS7_SSH

# ---------------------------------------------------------------------- cmd_cases.sh
cat > "$T/cmd_cases.sh" <<'PS7_LAUNCHER'
#!/bin/bash
# Text checks of the launcher, Install-PowerShell7.cmd (there is no cmd.exe here): ASCII and CRLF
# throughout, its version, and that it waits for a key only after a failure (issue 13): the
# success code 0 and NOPAUSE (-NoPause, or SYSTEM) end before the one pause; 3010 and 1641
# say to restart and wait only in a window started without arguments; and the exit code is
# passed back on every path.
set -u
CMD="$1"; PS1="$2"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; }
chk() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
[ -f "$CMD" ] || { echo "FAIL launcher: $CMD not found"; exit 1; }
TXT=$(tr -d '\r' < "$CMD")
lines=$(wc -l < "$CMD" | tr -d ' '); crlf=$(grep -c $'\r$' "$CMD")
chk 'launcher: CRLF on every line' '[ "$lines" = "$crlf" ] && [ "$lines" -gt 0 ]'
chk 'launcher: ASCII only' '! LC_ALL=C grep -q "[^[:print:][:space:]]" "$CMD"'
v=$(sed -n "s/^\$script:Version *= *'\([0-9.]*\)'.*/\1/p" "$PS1" | head -1)
chk 'launcher: version line matches the script ($script:Version)' 'printf "%s\n" "$TXT" | grep -qE "^REM  Install-PowerShell7.cmd - version $v,"'
chk 'launcher and script: version 1.0.1' '[ "$v" = "1.0.1" ]'
# The code lines only (no REM, no blank lines), so that comments cannot satisfy a check.
CODE=$(printf '%s\n' "$TXT" | grep -viE '^[[:space:]]*(rem( |$)|$)')
np=$(printf '%s\n' "$CODE" | grep -ciE '^[[:space:]]*pause[[:space:]]*$')
chk 'launcher: exactly one pause' '[ "$np" = 1 ]'
chk 'launcher: no pause tied to a double-click any more' '! printf "%s\n" "$CODE" | grep -qiE "defined INTERACTIVE|set .INTERACTIVE="'
DONE=$(printf '%s\n' "$CODE" | sed -n '/^:done/,/^exit \/b %RC%$/p')
before=$(printf '%s\n' "$DONE" | sed '/^pause/,$d')
chk 'launcher: 0 ends before the pause'    'printf "%s\n" "$before" | grep -qxF "if \"%RC%\"==\"0\" exit /b %RC%"'
RST=$(printf '%s\n' "$before" | sed -n '/^:restart$/,$p')
chk 'launcher: 3010 says to restart, and waits only when started without arguments' 'printf "%s\n" "$before" | grep -qxF "if \"%RC%\"==\"3010\" goto :restart" && printf "%s\n" "$RST" | grep -q "^echo \[WARN\] PowerShell 7 is installed. Restart Windows" && printf "%s\n" "$RST" | grep -qxF "if defined NOPAUSE exit /b %RC%" && printf "%s\n" "$RST" | grep -qxF "if defined HASARGS if not defined ELEVATEDRUN exit /b %RC%"'
chk 'launcher: 1641 goes the way of 3010' 'printf "%s\n" "$before" | grep -qxF "if \"%RC%\"==\"1641\" goto :restart"'
chk 'launcher: NOPAUSE ends before the pause' 'printf "%s\n" "$before" | grep -qxF "if defined NOPAUSE exit /b %RC%"'
chk 'launcher: the pause is in the :done block' 'printf "%s\n" "$DONE" | grep -qx "pause"'
chk 'launcher: the exit code is passed back after the pause' '[ "$(printf "%s\n" "$DONE" | tail -1)" = "exit /b %RC%" ]'
chk 'launcher: -NoPause found among the arguments, by its first four characters (-NoPa, -NoPause:$true)' 'printf "%s\n" "$CODE" | grep -qxF "set \"ARG=%~1\"" && printf "%s\n" "$CODE" | grep -qxF "if /i \"%ARG:~0,4%\"==\"-NoP\" set \"NOPAUSE=1\"" && [ "$(grep -cE "^[[:space:]]*\[[a-z]+\]\\\$NoP" "$PS1")" = 1 ]'
chk 'launcher: argument scan keeps its own path (shift /1)' 'printf "%s\n" "$CODE" | grep -qx "shift /1" && ! printf "%s\n" "$CODE" | grep -qix "shift"'
chk 'launcher: SYSTEM never waits' 'printf "%s\n" "$CODE" | grep -qxF "if /i \"%USERNAME%\"==\"%COMPUTERNAME%\$\" set \"NOPAUSE=1\""'
chk 'launcher: no CALL to a label with the arguments (CALL answers /? itself)' '! printf "%s\n" "$CODE" | grep -qiE "^call :"'
chk 'launcher: arguments still reach the script whole' 'printf "%s\n" "$CODE" | grep -qF -- "-File \"%PS1%\" %*"'
chk 'launcher: an empty first argument counts as an argument' 'printf "%s\n" "$CODE" | grep -qxF "if not [%1]==[] set \"HASARGS=1\""'
chk 'script: accepts -NoPause' 'grep -qF "[switch]\$NoPause," "$PS1"'
echo "launcher: $pass passed, $fail failed"
[ "$fail" = 0 ]
PS7_LAUNCHER

# ------------------------------------------------------------------------ run the parts in turn
rc=0
pwsh -NoLogo -NoProfile -File "$T/test-functions.ps1" "$SRC" 2>&1 || rc=1
bash "$T/run_sim.sh" "$SRC" 2>&1 || rc=1
bash "$T/fix_cases.sh" 2>&1 || rc=1
bash "$T/ssh_cases.sh" 2>&1 || rc=1
bash "$T/cmd_cases.sh" "$REPO/Prerequisites/Install-PowerShell7.cmd" "$SRC" 2>&1 || rc=1
if [ "$rc" = 0 ]; then echo "ALL TESTS PASSED"; else echo "TESTS FAILED"; fi
exit "$rc"
