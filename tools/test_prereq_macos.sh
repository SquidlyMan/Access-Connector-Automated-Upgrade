#!/bin/bash
# Offline tests of Prerequisites/install-powershell7-macos.sh (macOS only). Stand-ins replace
# curl, sudo, installer and pkgutil (the signature check gets a canned answer; no trust
# evaluation runs), and overlays for uname, sysctl, id and stat stand for an Intel Mac, a shell
# under Rosetta 2 and a run as root. Every case runs a test copy of the script, which differs
# from it only in its INSTALLER line (the stand-in instead of /usr/sbin/installer), with an empty
# environment, the stand-ins first on the PATH and HOME and TMPDIR inside a temporary folder.
# Nothing is downloaded or installed, no host is contacted, and the real sudo and the real
# installer are never run.
#   bash tools/test_prereq_macos.sh
# Prints PASS <name> / FAIL <name> per case (the end of the run's output under a failure), then
# ALL TESTS PASSED or TESTS FAILED (exit 0/1).
set -u
REPO="${FLEET_REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
F="$REPO/Prerequisites/install-powershell7-macos.sh"
[ -f "$F" ] || { echo "FAIL load: $F not found"; echo "TESTS FAILED"; exit 1; }
[ "$(uname -s)" = Darwin ] || { echo "FAIL load: this suite needs macOS"; echo "TESTS FAILED"; exit 1; }
SV="$(sed -n 's/^SCRIPT_VERSION="\(.*\)"$/\1/p' "$F" | head -n 1)"
[ -n "$SV" ] || { echo "FAIL load: no SCRIPT_VERSION line in $F"; echo "TESTS FAILED"; exit 1; }
H="$(mktemp -d)" || { echo "FAIL load: no temporary folder"; echo "TESTS FAILED"; exit 1; }
trap 'rm -rf "$H"' EXIT
# its physical path: the script names folders by their real path (/private/var, not /var), and
# the cases compare its messages with these paths
H="$(cd "$H" && pwd -P)"

cat > "$H/make_fakes.sh" <<'MAKE_FAKES'
#!/bin/bash
# Builds the stand-ins used by the tests. Nothing here uses the network,
# the real sudo or the real installer, and nothing is installed.
# Usage: make_fakes.sh <fakebin> <rootid> <rosetta> <intel>
set -u
B="$1"; X="$2"; R="$3"; I="$4"
mkdir -p "$B" "$X" "$R" "$I"

cat > "$B/curl" <<'EOF'
#!/bin/bash
# stand-in for curl: answers from the test state; never touches the network
out=""; wfmt=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) wfmt="$2"; shift 2 ;;
    -A|--max-time|--max-redirs|--retry|--proto|--proto-redir|--retry-delay) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
S="$PS7T_STATE"
echo "$url -o ${out:-none}" >> "$S/curl.log"
case "$url" in
  "https://aka.ms/powershell-release?tag="*)
    [ -f "$S/aka_url" ] || { echo "curl: (6) Could not resolve host: aka.ms" >&2; exit 6; }
    [ -n "$wfmt" ] && printf '%s' "$(cat "$S/aka_url")"; exit 0 ;;
  "https://api.github.com/repos/PowerShell/PowerShell/releases/latest")
    [ -f "$S/api_latest.json" ] || { echo "curl: (22) The requested URL returned error: 403" >&2; exit 22; }
    cat "$S/api_latest.json"; exit 0 ;;
  "https://api.github.com/repos/PowerShell/PowerShell/releases?per_page="*)
    [ -f "$S/api_list.json" ] || { echo "curl: (22) The requested URL returned error: 403" >&2; exit 22; }
    cat "$S/api_list.json"; exit 0 ;;
  "https://github.com/PowerShell/PowerShell/releases/download/"*"/hashes.sha256")
    mode=utf16; [ -f "$S/hashes_mode" ] && mode=$(cat "$S/hashes_mode")
    [ "$mode" = fail ] && { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
    tag="${url%/hashes.sha256}"; tag="${tag##*/}"; v="${tag#v}"
    h=$(shasum -a 256 "$(cat "$S/pkg_source")" | awk '{print toupper($1)}')
    [ -f "$S/hash_tamper" ] && h=0000000000000000000000000000000000000000000000000000000000000000
    sep=" *"; [ "$mode" = utf8-textmode ] && sep="  "
    tb="$S/hashbody.$$"; : > "$tb"
    line() { printf '%s%s%s\r\n' "$1" "$sep" "$2" >> "$tb"; }
    line 1111111111111111111111111111111111111111111111111111111111111111 "PowerShell-$v-win-x64.msi"
    line 2222222222222222222222222222222222222222222222222222222222222222 "powershell-$v-osx-arm64.pkg.tar.gz"
    if [ "$mode" != missing-entry ]; then
      for n in "powershell-$v-osx-arm64.pkg" "powershell-$v-osx-x64.pkg" "powershell-lts-$v-osx-arm64.pkg" "powershell-lts-$v-osx-x64.pkg"; do
        line "$h" "$n"
      done
    fi
    case "$mode" in
      utf16) { printf '\377\376'; iconv -f UTF-8 -t UTF-16LE < "$tb"; } > "$out" ;;
      utf16nobom) iconv -f UTF-8 -t UTF-16LE < "$tb" > "$out" ;;
      *) cat "$tb" > "$out" ;;
    esac
    rm -f "$tb"
    exit 0 ;;
  "https://github.com/PowerShell/PowerShell/releases/download/"*".pkg")
    [ -f "$S/pkg_source" ] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
    if [ -f "$S/curl_kill" ]; then echo "partial" > "$out"; kill -TERM "$PPID"; exit 7; fi
    cat "$(cat "$S/pkg_source")" > "$out"; exit 0 ;;
  *) echo "fake curl: unexpected URL $url" >&2; exit 97 ;;
esac
EOF

cat > "$B/sudo" <<'EOF'
#!/bin/bash
# stand-in for sudo: never elevates. It follows a sudoers policy named in the test state:
#   nopasswd-installer  ACCOUNT ALL=(root) NOPASSWD: <installer>, everything else needs a password (default)
#   password            everything needs a password
#   nopasswd-all        nothing needs a password
#   list-only           listing works without a password (another rule has NOPASSWD), running the installer does not
# -A runs SUDO_ASKPASS and, when it answers, treats the account as authenticated.
S="$PS7T_STATE"
echo "sudo $*" >> "$S/sudo.log"
pol=nopasswd-installer; [ -f "$S/sudo_policy" ] && pol=$(cat "$S/sudo_policy")
n=""; a=""; list=""
while [ $# -gt 0 ]; do case "$1" in -n) n=1; shift ;; -A) a=1; shift ;; -l) list=1; shift ;; --) shift; break ;; -*) shift ;; *) break ;; esac; done
cmd="${1:-}"
is_inst() { [ "$cmd" = "$PS7T_BIN/installer" ] || [ "$cmd" = "installer" ]; }
nopw=""
case "$pol" in
  nopasswd-all) nopw=1 ;;
  nopasswd-installer) is_inst && nopw=1 ;;
  list-only) [ -n "$list" ] && nopw=1 ;;
esac
if [ -z "$nopw" ]; then
  if [ -n "$a" ]; then
    if [ -n "${SUDO_ASKPASS:-}" ] && [ -x "$SUDO_ASKPASS" ] && [ -n "$("$SUDO_ASKPASS" 'Password:')" ]; then echo "askpass answered" >> "$S/sudo.log"
    else echo "sudo: no password was provided" >&2; exit 1; fi
  elif [ -n "$n" ]; then echo "sudo: a password is required" >&2; exit 1
  else echo "sudo: a terminal is required to read the password" >&2; exit 1; fi
fi
if [ -n "$list" ]; then echo "$*"; exit 0; fi
case "$cmd" in
  true) exit 0 ;;
  "$PS7T_BIN/installer"|installer) shift; exec "$PS7T_BIN/installer" "$@" ;;
  *) echo "fake sudo refuses: $*" >&2; exit 99 ;;
esac
EOF

cat > "$B/installer" <<'EOF'
#!/bin/bash
# stand-in for the macOS installer: records the call and updates the test receipt
S="$PS7T_STATE"
echo "installer $*" >> "$S/installer.log"
pkg=""; while [ $# -gt 0 ]; do case "$1" in -pkg) pkg="$2"; shift 2 ;; *) shift ;; esac; done
[ -f "$S/installer_kill" ] && { kill -TERM "$PPID"; sleep 1; exit 1; }
[ -f "$pkg" ] && cp "$pkg" "$S/installed_copy"
rc=0; [ -f "$S/installer_rc" ] && rc=$(cat "$S/installer_rc")
if [ "$rc" != 0 ]; then echo "installer: The install failed. (stand-in)" >&2; exit "$rc"; fi
if [ -f "$S/installer_noop" ]; then echo "installer: The upgrade was successful. (stand-in; changed nothing)"; exit 0; fi
base="${pkg##*/}"; v="${base#powershell-}"; v="${v#lts-}"; v="${v%-osx-*}"
echo "$v" > "$S/pkg_version"
id=com.microsoft.powershell
case "$base" in powershell-lts-*) [ -f "$S/lts_id" ] && id=com.microsoft.powershell-lts ;; esac
echo "$id" > "$S/pkg_id"
rm -f "$S/pkg_broken"
echo "installer: Package name is PowerShell (stand-in)"
echo "installer: The upgrade was successful."
EOF

cat > "$B/pkgutil" <<'EOF'
#!/bin/bash
# stand-in for pkgutil: receipts come from the test state; --check-signature prints a canned
# genuine-looking result (no trust evaluation runs), or the one the test names
S="$PS7T_STATE"
id=com.microsoft.powershell; [ -f "$S/pkg_id" ] && id=$(cat "$S/pkg_id")
have() { [ -f "$S/pkg_version" ] && [ "$1" = "$id" ]; }
case "${1:-}" in
  --check-signature)
    echo "$2" >> "$S/sigcheck.log"
    if [ -f "$S/sig_override" ]; then cat "$S/sig_override"; rc=0; [ -f "$S/sig_rc" ] && rc=$(cat "$S/sig_rc"); exit "$rc"; fi
    printf 'Package "%s":\n   Status: signed by a developer certificate issued by Apple for distribution\n   Notarization: trusted by the Apple notary service\n   Certificate Chain:\n    1. Developer ID Installer: Microsoft Corporation (UBF8T346G9)\n       Expires: 2030-01-01 00:00:00 +0000\n    2. Developer ID Certification Authority\n       Expires: 2031-09-17 00:00:00 +0000\n    3. Apple Root CA\n       Expires: 2035-02-09 21:40:36 +0000\n' "${2##*/}"
    exit 0 ;;
  --pkg-info)
    have "$2" || { echo "No receipt for '$2' found at '/'." >&2; exit 1; }
    printf 'package-id: %s\nversion: %s\nvolume: /\nlocation: \ninstall-time: 0\n' "$id" "$(cat "$S/pkg_version")" ;;
  --files)
    have "$2" || { echo "No receipt for '$2' found at '/'." >&2; exit 1; }
    printf 'Applications\nApplications/PowerShell.app\nusr/local/bin/pwsh\n%s\n%s\n' \
      "${S#/}/root/usr/local/microsoft/powershell/7" "${S#/}/root/usr/local/microsoft/powershell/7/pwsh" ;;
  *) echo "fake pkgutil: unsupported: $*" >&2; exit 98 ;;
esac
EOF

# fake root: id -u answers 0 (the files are still owned by the real account)
printf '#!/bin/bash\ncase "${1:-}" in -u) echo 0 ;; *) /usr/bin/id "$@" ;; esac\n' > "$X/id"
# with fake root, stat reports user ID 0 as the owner of the folders listed in PS7T_ROOTISH, one per
# line ("DIR/*" means DIR and everything in it); every other path is reported as it is
if [ -n "${5:-}" ]; then mkdir -p "$5"; cat > "$5/stat" <<'EOF'
#!/bin/bash
out="$(/usr/bin/stat "$@")" || exit $?
if [ "$#" = 3 ] && [ "$1" = "-f" ] && [ "$2" = "%u %p" ]; then
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    case "$r" in
      *"/*") case "$3/" in "${r%/\*}"/*) printf '0 %s\n' "${out#* }"; exit 0 ;; esac ;;
      *) if [ "$3" = "$r" ]; then printf '0 %s\n' "${out#* }"; exit 0; fi ;;
    esac
  done <<LIST
${PS7T_ROOTISH:-}
LIST
fi
printf '%s\n' "$out"
EOF
chmod 755 "$5/stat"; fi
# overlays: a shell under Rosetta 2, and an Intel Mac
cat > "$R/uname" <<'EOF'
#!/bin/bash
case "${1:-}" in -m) echo x86_64 ;; -s) echo Darwin ;; *) /usr/bin/uname "$@" ;; esac
EOF
cat > "$R/sysctl" <<'EOF'
#!/bin/bash
case "$*" in *sysctl.proc_translated*) echo 1 ;; *) /usr/sbin/sysctl "$@" ;; esac
EOF
cp "$R/uname" "$I/uname"
cat > "$I/sysctl" <<'EOF'
#!/bin/bash
case "$*" in *sysctl.proc_translated*) echo 0 ;; *) /usr/sbin/sysctl "$@" ;; esac
EOF
chmod 755 "$B"/* "$X"/* "$R"/* "$I"/*
echo "fakes ready"
MAKE_FAKES

T="$H/work"; mkdir -p "$T"
B="$H/fakebin"; X="$H/rootid"; R="$H/rosetta"; I="$H/intel"; RS="$H/rootstat"
/bin/bash "$H/make_fakes.sh" "$B" "$X" "$R" "$I" "$RS" >/dev/null || { echo "cannot build the stand-ins"; exit 2; }
for t in curl sudo installer pkgutil; do [ -x "$B/$t" ] || { echo "stand-in missing: $t"; exit 2; }; done
# the test copy: the one INSTALLER line points at the stand-in, nothing else changes
U="$H/ut"; mkdir -p "$U"; TC="$U/install-powershell7-macos.sh"
sed "s#^INSTALLER=\"/usr/sbin/installer\"#INSTALLER=\"$B/installer\"#" "$F" > "$TC"
[ "$(grep -c "^INSTALLER=\"$B/installer\"" "$TC")" = 1 ] || { echo "the test copy does not point at the stand-in installer"; exit 2; }
[ "$(diff "$F" "$TC" | grep -c '^[<>]')" = 2 ] || { echo "the test copy differs in more than the INSTALLER line"; exit 2; }
# the stand-in package: the same bytes on every run
FIX="$H/fixtures"; mkdir -p "$FIX"; yes 'stand-in package bytes for the offline tests, not a real package' | head -c 65536 > "$FIX/ms.pkg"
ESC="$(printf '\033')"
pass=0; fail=0
okk() { pass=$((pass+1)); echo "PASS $*"; }
bad() { fail=$((fail+1)); echo "FAIL $*"; [ -n "${OUT:-}" ] && [ -f "$OUT" ] && sed 's/^/      | /' "$OUT" | tail -n 30; }
check() { local n="$1"; shift; if "$@"; then okk "$n"; else bad "$n"; fi; }
has()    { grep -qF -- "$1" "${2:-$OUT}"; }
hasnot() { ! grep -qF -- "$1" "${2:-$OUT}" 2>/dev/null; }
hasj()   { awk '{ sub(/^ +/, ""); printf "%s ", $0 }' "${2:-$OUT}" | tr -s ' ' | grep -qF -- "$1"; }   # across wrapped lines
rc()     { [ "$RC" = "$1" ]; }
nfile()  { [ ! -e "$1" ] && [ ! -L "$1" ]; }
lines()  { [ "$(grep -c -- "$1" "$2" 2>/dev/null)" = "$3" ]; }
empty()  { [ -z "$(ls -A "$1" 2>/dev/null)" ]; }
first_is_notice() { [ "$(grep -v '^$' "$OUT" | head -n 1)" = '  UNSUPPORTED - provided "AS IS", NO WARRANTY. Use at your own risk. Neither' ]; }

new() {   # new NAME: a fresh test state
  N="$1"; D="$T/$N"; S="$D/state"; C="$D/cache"; L="$D/logs"
  mkdir -p "$S/root/usr/local/microsoft/powershell/7" "$D/home" "$D/tmp"
  printf '#!/bin/bash\n[ -f "$PS7T_STATE/pkg_broken" ] && exit 1\ncat "$PS7T_STATE/pkg_version"\n' > "$S/root/usr/local/microsoft/powershell/7/pwsh"
  chmod 755 "$S/root/usr/local/microsoft/powershell/7/pwsh"
  echo "$FIX/ms.pkg" > "$S/pkg_source"
  EXTRA_PATH=""; EXTRA_ENV="PS7T_NONE=1"; EXTRA_ENV2="PS7T_NONE2=1"; CWD="$D"; OUT="$D/out.txt"; HOMEV="HOME=$D/home"; TMPV="$D/tmp"
}
aka() { echo "https://github.com/PowerShell/PowerShell/releases/tag/v$1" > "$S/aka_url"; }
run() {   # run ARGS...: the test copy with the stand-ins first on the PATH; sets RC
  ( cd "$CWD" && exec env -i "$HOMEV" USER=tester LOGNAME=tester TMPDIR="$TMPV" "$EXTRA_ENV" "$EXTRA_ENV2" \
      PATH="${EXTRA_PATH:+$EXTRA_PATH:}$B:/usr/bin:/bin:/usr/sbin:/sbin" \
      PS7T_STATE="$S" PS7T_BIN="$B" /bin/bash "$TC" "$@" ) > "$OUT" 2>&1
  RC=$?
}
brew_copy() {
  mkdir -p "$S/brew/Cellar/powershell/$1/bin" "$S/brew/bin"
  printf '#!/bin/bash\necho %s\n' "$1" > "$S/brew/Cellar/powershell/$1/bin/pwsh"; chmod 755 "$S/brew/Cellar/powershell/$1/bin/pwsh"
  ln -sf "../Cellar/powershell/$1/bin/pwsh" "$S/brew/bin/pwsh"
  EXTRA_PATH="$S/brew/bin"
}
private_pkg() { echo "$TMPV/Install-PowerShell7."; }   # the private folder's prefix
as_root() {   # fake root: id -u is 0; TMPDIR is a folder outside $D that stat reports, with each folder above it, as root's
  local p l
  TMPV="$T/rtmp-$N"; mkdir -p "$TMPV"; l="$TMPV/*"; p="${TMPV%/*}"
  while [ -n "$p" ] && [ "$(/usr/bin/stat -f %u "$p")" != 0 ]; do l="$l\n$p"; p="${p%/*}"; done
  EXTRA_PATH="$X:$RS"; EXTRA_ENV2="PS7T_ROOTISH=$(printf '%b' "$l")"; }
AUD="install-powershell7-macos-audit.log"; ERR="install-powershell7-macos-errors.log"; RUNL="install-powershell7-macos-run.log"
MSS="Developer ID Installer: Microsoft Corporation (UBF8T346G9)"
PK="powershell-7.7.0-osx-arm64.pkg"

# ======================================================================== help and version
new help; run --help
check "help: exit 0, notice first, disclaimer, examples" eval 'rc 0 && first_is_notice && has "LEGAL DISCLAIMER - UNSUPPORTED" && has " EXAMPLES "'
check "help: writes nothing, contacts nothing" eval 'empty "$D/home" && nfile "$S/curl.log" && nfile "$C" && empty "$TMPV"'
check "[scope] help names /etc/shells, the manual page, the receipt and the private folder" eval 'hasj "adds /usr/local/bin/pwsh to /etc/shells" && hasj "pwsh manual page in /usr/local/share/man/man1" && hasj "installer receipt" && hasj "private temporary folder"'
check "[sudo] help: --non-interactive explains sudo -n -l and SUDO_ASKPASS" eval 'hasj "before the download when sudo already says so (sudo -n -l), otherwise at the install step" && hasj "When SUDO_ASKPASS names a helper, sudo -A asks the helper instead"'
new version; run --version
check "version: notice then name and version" eval 'rc 0 && first_is_notice && has "install-powershell7-macos.sh $SV" && hasnot "[ignored]"'
new version2; run --version --bogus
check "[runlog] --version --bogus: the unknown switch is named, the version still printed" eval 'rc 0 && has "[ignored] --bogus: unknown switch" && [ "$(tail -n 1 "$OUT")" = "install-powershell7-macos.sh $SV" ] && empty "$D/home"'
new unknown; run --bogus --audit-log "$L/" --run-log "$L/"
check "unknown switch: exit 1, named, audit FAILED stage=config, nothing attempted" eval 'rc 1 && has "ERROR [config] --bogus: unknown switch" && has "outcome=FAILED" "$L/$AUD" && has "stage=config" "$L/$AUD" && nfile "$S/curl.log"'
check "[runlog] unknown switch: the run log has the notice and the error" eval 'has "UNSUPPORTED - provided" "$L/$RUNL" && has "ERROR [config] --bogus: unknown switch" "$L/$RUNL"'
new cfgbad; printf 'CHANNEL=beta\nKEEP_PKG=maybe\n' > "$D/bad.cfg"; run --config "$D/bad.cfg" --cache-dir "$C" --run-log "$L/" --audit-log "$L/"
check "config: every bad value reported together, exit 1" eval 'rc 1 && has "CHANNEL must be '"'"'stable'"'"' or '"'"'lts'"'"' (got '"'"'beta'"'"')" && has "KEEP_PKG must be yes or no (got '"'"'maybe'"'"')"'
check "[runlog] config error: written to the run log too" eval 'has "KEEP_PKG must be yes or no" "$L/$RUNL" && has "stage=config" "$L/$AUD"'
new badlog; echo x > "$D/afile"; run --dry-run --pin 7.7.0 --cache-dir "$C" --audit-log "$D/afile/x.log" --run-log "$L/"
check "audit log under a file: exit 1, named" eval 'rc 1 && hasj "--audit-log: cannot create the folder $D/afile"'
check "[runlog] a log-stage stop still writes the run log" eval 'has "ERROR [logs] --audit-log: cannot create the folder" "$L/$RUNL"'
new missing; run --pin
check "missing value: --pin needs a value" eval 'rc 1 && has "--pin: needs a value."'
new helpbogus; run --help --bogus
check "help with an unknown switch: named as [ignored], help still shown" eval 'rc 0 && has "[ignored] --bogus: unknown switch" && has " SYNOPSIS "'

# ======================================================================== export-template
new tpl; run --export-template "$D/cfg/ps7.cfg" --audit-log "$L/"
check "export-template: written, parent created, audit SUCCESS" eval 'rc 0 && has "CHANNEL=stable" "$D/cfg/ps7.cfg" && has "outcome=SUCCESS" "$L/$AUD" && has "stage=export-template" "$L/$AUD"'
run --export-template "$D/cfg/ps7.cfg"
check "export-template: never overwrites an existing file" eval 'rc 1 && has "already exists"'
ln -s "$D/victim-new.txt" "$D/cfg/link.cfg"; run --export-template "$D/cfg/link.cfg"
check "export-template: a dangling link counts as existing; its target is not created" eval 'rc 1 && has "already exists" && nfile "$D/victim-new.txt"'
new tplrun; run --export-template "$D/ps7.cfg" --run-log "$L/" --audit-log "$L/"
check "[runlog] export-template with --run-log: the run log is written" eval 'rc 0 && has "template written: $D/ps7.cfg" "$L/$RUNL" && hasnot "[ignored] --run-log" && has "run log:   $L/$RUNL"'
new tplign; run --export-template "$D/p2.cfg" --pin 7.6.5 --dry-run
check "export-template: operational switches reported as [ignored]" eval 'rc 0 && has "[ignored] --pin: --export-template writes the template and exits." && has "[ignored] --dry-run"'

# ======================================================================== dry runs
new dry; run --dry-run --pin 7.7.0 --cache-dir "$C"
check "dry-run --pin: no lookup, download, sudo or installer; installer named by full path" eval 'rc 0 && has "upgrade needed: installed none -> 7.7.0" && has "would install   sudo $B/installer -pkg $PK -target /" && nfile "$S/curl.log" && nfile "$S/sudo.log" && nfile "$S/installer.log"'
check "dry-run: no private folder is made" eval 'empty "$TMPV"'
new rosetta; EXTRA_PATH="$R"; run --dry-run --pin 7.7.0 --cache-dir "$C"
check "Rosetta 2 shell: Apple silicon package chosen" eval 'rc 0 && has "runs under Rosetta 2" && has "$PK"'
new intel; EXTRA_PATH="$I"; run --dry-run --pin 7.7.0 --cache-dir "$C"
check "Intel Mac: x64 package chosen" eval 'rc 0 && has "arch=osx-x64" && has "powershell-7.7.0-osx-x64.pkg"'

# ======================================================================== full install
new full; aka 7.7.0; run --cache-dir "$C" --audit-log "$L/" --error-log "$L/" --run-log "$L/"
check "install: exit 0, hash and signature verified, installed and confirmed" eval 'rc 0 && has "hash verified" && has "signature verified: $MSS" && has "INSTALLED PowerShell 7.7.0"'
check "[cache] install: the installer got the private copy, not a cache path" eval 'grep -q "^installer -pkg $(private_pkg)[A-Za-z0-9]\{6\}/$PK -target /$" "$S/installer.log" && grep -q "^$(private_pkg)[A-Za-z0-9]\{6\}/$PK$" "$S/sigcheck.log" && cmp -s "$S/installed_copy" "$FIX/ms.pkg"'
check "[sudo] install: one sudo call, the installer by full path, the private copy" eval 'lines "." "$S/sudo.log" 1 && grep -q "^sudo $B/installer -pkg $(private_pkg)[A-Za-z0-9]\{6\}/$PK -target /$" "$S/sudo.log"'
check "[cache] install: nothing left in TMPDIR, the cache is empty (no .part or hashes files)" eval 'empty "$TMPV" && empty "$C"'
check "install: downloads went to the private folder" eval 'grep -q "releases/download/v7.7.0/$PK -o $(private_pkg)[A-Za-z0-9]\{6\}/$PK$" "$S/curl.log" && grep -q "/hashes.sha256 -o $(private_pkg)[A-Za-z0-9]\{6\}/hashes.raw$" "$S/curl.log"'
check "install: audit SUCCESS; error log has no ERROR; run log plain" eval 'has "outcome=SUCCESS" "$L/$AUD" && has "installed=7.7.0 previous=none" "$L/$AUD" && hasnot "[ERROR]" "$L/$ERR" && hasnot "$ESC" "$L/$RUNL"'
check "install: a clean command line prints no [ignored] or [note]" eval 'hasnot "[ignored]" && hasnot "[note]"'
run --cache-dir "$C" --audit-log "$L/"
check "audit log: appended, header written once" eval 'lines "^time=" "$L/$AUD" 2 && lines "^#" "$L/$AUD" 1'
new current; aka 7.7.0; echo 7.7.0 > "$S/pkg_version"; run --cache-dir "$C"
check "current: nothing to do, no download, no private folder" eval 'rc 0 && has "nothing to do" && lines "." "$S/curl.log" 1 && nfile "$S/installer.log" && empty "$TMPV"'
new upgrade; aka 7.7.0; echo 7.6.9 > "$S/pkg_version"; run --cache-dir "$C"
check "upgrade: older package upgraded" eval 'rc 0 && has "upgrade needed: installed 7.6.9 -> 7.7.0" && has "INSTALLED PowerShell 7.7.0"'
new force; aka 7.7.0; echo 7.7.0 > "$S/pkg_version"; run --cache-dir "$C" --force
check "force: reinstall when current" eval 'rc 0 && has "reinstall (--force)" && [ -f "$S/installer.log" ]'
new down; echo 7.7.0 > "$S/pkg_version"; run --cache-dir "$C" --pin 7.6.5
check "pin below installed: nothing to do without --force" eval 'rc 0 && has "current: installed 7.7.0 >= pinned 7.6.5"'
run --cache-dir "$C" --pin 7.6.5 --force
check "pin below installed with --force: goes back to it" eval 'rc 0 && has "INSTALLED PowerShell 7.6.5"'

# ======================================================================== cache safety and HOME
new nohome; aka 7.7.0; HOMEV="PS7T_NOHOME=1"; run --audit-log "$L/"
check "[cache] HOME unset: no cache, installed from the private folder, nothing left" eval 'rc 0 && has "cache=none" && hasj "no cache: HOME is not set" && has "INSTALLED PowerShell 7.7.0" && empty "$TMPV" && hasnot "[note]"'
check "[cache] HOME unset: no fixed folder under /var/tmp exists or is named" eval 'nfile /var/tmp/Library/Caches/PowerShell7Install && hasnot "/var/tmp" && ! grep -q "HOME:-/var/tmp" "$F"'
new nohomekeep; aka 7.7.0; HOMEV="PS7T_NOHOME=1"; run --keep
check "[cache] HOME unset with --keep: [ignored], still installs" eval 'rc 0 && has "[ignored] --keep: there is no cache folder to keep the package in." && has "INSTALLED PowerShell 7.7.0" && empty "$TMPV"'
new ww; aka 7.7.0; mkdir -p "$D/shared"; chmod 777 "$D/shared"; run --cache-dir "$D/shared"
check "[cache] a world-writable --cache-dir is refused before any work" eval 'rc 1 && hasj "--cache-dir: '"'"'$D/shared'"'"' cannot be used: $D/shared can be changed by other users" && nfile "$S/curl.log" && empty "$TMPV"'
new gw; aka 7.7.0; mkdir -p "$D/grp"; chmod 770 "$D/grp"; run --cache-dir "$D/grp"
check "[cache] a group-writable --cache-dir is refused" eval 'rc 1 && hasj "$D/grp can be changed by other users"'
new sticky; aka 7.7.0; mkdir -p "$D/st"; chmod 1777 "$D/st"; run --cache-dir "$D/st/cache"
check "[cache] no cache is created inside a world-writable sticky folder" eval 'rc 1 && hasj "it would be created where $D/st can be changed by other users" && nfile "$D/st/cache"'
mkdir "$D/st/own"; chmod 700 "$D/st/own"; run --cache-dir "$D/st/own" --keep
check "[cache] an own folder inside a sticky folder is accepted" eval 'rc 0 && has "INSTALLED PowerShell 7.7.0" && [ -f "$D/st/own/$PK" ]'
new linkww; aka 7.7.0; mkdir -p "$D/shared"; chmod 777 "$D/shared"; ln -s "$D/shared" "$D/cachelink"; run --cache-dir "$D/cachelink"
check "[cache] a link to a world-writable folder is followed and refused" eval 'rc 1 && hasj "can be changed by other users"'
new defbad; aka 7.7.0; mkdir -p "$D/home/Library/Caches"; chmod 777 "$D/home/Library/Caches"; run --audit-log "$L/"
check "[cache] an unsafe default cache is left out with a note; the install goes on" eval 'rc 0 && hasj "[note] cache: $D/home/Library/Caches/PowerShell7Install is not used: it would be created where $D/home/Library/Caches can be changed by other users" && has "cache=none" && has "INSTALLED PowerShell 7.7.0" && empty "$D/home/Library/Caches" && empty "$TMPV"'
new oldnames; aka 7.7.0; mkdir -p "$C"; chmod 700 "$C"
for n in "$PK.part" hashes.raw hashes.sha256; do echo "precious $n" > "$D/victim-$n"; ln -s "$D/victim-$n" "$C/$n"; done
run --cache-dir "$C"
check "[cache] links at the old fixed names in the cache are never written through" eval 'rc 0 && has "INSTALLED PowerShell 7.7.0" && [ "$(cat "$D/victim-$PK.part")" = "precious $PK.part" ] && [ "$(cat "$D/victim-hashes.raw")" = "precious hashes.raw" ] && [ "$(cat "$D/victim-hashes.sha256")" = "precious hashes.sha256" ]'
new pkglink; aka 7.7.0; mkdir -p "$C"; chmod 700 "$C"; echo "precious" > "$D/victim"; ln -s "$D/victim" "$C/$PK"; run --cache-dir "$C" --keep
check "[cache] a link at the package name is not used, not written through, not kept" eval 'rc 0 && hasj "[note] cache: $C/$PK is a symbolic link, so it is not used." && hasj "[note] the package was not kept: $C/$PK is a symbolic link" && [ "$(cat "$D/victim")" = "precious" ] && [ -L "$C/$PK" ]'
new keep; aka 7.7.0; run --cache-dir "$C" --keep
check "[cache] --keep: the verified package is kept (mode 600), nothing else left" eval 'rc 0 && has "kept package: $C/$PK" && cmp -s "$C/$PK" "$FIX/ms.pkg" && [ "$(stat -f %Lp "$C/$PK")" = 600 ] && [ "$(ls -A "$C")" = "$PK" ] && empty "$TMPV"'
check "[cache] a cache folder made by the script is private (700)" eval '[ "$(stat -f %Lp "$C")" = 700 ]'
rm -f "$S/curl.log" "$S/installer.log" "$S/pkg_version"; run --cache-dir "$C"
check "[cache] reuse: the cached copy is copied, checked and installed from the private folder, then removed" eval 'rc 0 && has "reusing cached $PK" && hasnot "/$PK -o" "$S/curl.log" && grep -q "^installer -pkg $(private_pkg)[A-Za-z0-9]\{6\}/$PK -target /$" "$S/installer.log" && nfile "$C/$PK" && empty "$TMPV"'
new stale; aka 7.7.0; mkdir -p "$C"; chmod 700 "$C"; echo "not a package" > "$C/$PK"; run --cache-dir "$C"
check "[cache] a bad cached package is deleted, exit 4, nothing installed" eval 'rc 4 && has "reusing cached" && has "SHA-256 MISMATCH" && nfile "$C/$PK" && nfile "$S/installer.log" && empty "$TMPV"'
run --cache-dir "$C"
check "next run downloads afresh and installs" eval 'rc 0 && has "downloading $PK" && has "INSTALLED PowerShell 7.7.0"'
new instfail; aka 7.7.0; echo 1 > "$S/installer_rc"; run --cache-dir "$C" --audit-log "$L/" --error-log "$L/"
check "installer fails: exit 4, the verified package kept for the next run" eval 'rc 4 && hasj "the macOS installer failed. The verified package was kept for the next run: $C/$PK." && cmp -s "$C/$PK" "$FIX/ms.pkg" && has "stage=install" "$L/$AUD" && has "installer: The install failed." "$L/$ERR" && empty "$TMPV"'
rm -f "$S/installer_rc" "$S/curl.log"; run --cache-dir "$C"
check "rerun: the kept package is reused and installed" eval 'rc 0 && has "reusing cached" && has "INSTALLED PowerShell 7.7.0" && nfile "$C/$PK"'
new badcache; echo x > "$D/afile"; run --cache-dir "$D/afile"
check "cache dir that is a file: exit 1" eval 'rc 1 && hasj "cannot be used: $D/afile cannot be created"'

# ======================================================================== run as root (id -u answers 0)
new rootnohome; aka 7.7.0; as_root; HOMEV="PS7T_NOHOME=1"; run
check "[root] HOME unset: no cache, no sudo, the installer run directly on the private copy" eval 'rc 0 && has "cache=none" && nfile "$S/sudo.log" && grep -q "^installer -pkg $(private_pkg)[A-Za-z0-9]\{6\}/$PK -target /$" "$S/installer.log" && has "INSTALLED PowerShell 7.7.0" && empty "$TMPV"'
new rootsudo; aka 7.7.0; as_root; EXTRA_ENV="SUDO_USER=someone"; run
check "[root] through sudo with the user's HOME: the default cache is left out; notes; installed" eval 'rc 0 && hasj "[note] cache: $D/home/Library/Caches/PowerShell7Install is not used: it would be created where $D/home belongs to user ID $(id -u)" && hasj "[note] Running as root through sudo." && has "INSTALLED PowerShell 7.7.0" && empty "$D/home" && nfile "$S/sudo.log"'
new rootcache; aka 7.7.0; as_root; mkdir -p "$C"; chmod 700 "$C"; run --cache-dir "$C"
check "[root] a --cache-dir that another user owns is refused" eval 'rc 1 && hasj "--cache-dir: '"'"'$C'"'"' cannot be used: $C belongs to user ID $(id -u)" && nfile "$S/curl.log"'
new rootlog; aka 7.7.0; as_root; HOMEV="PS7T_NOHOME=1"; run --audit-log "$L/"
check "[root] a log folder that another user could change is refused, nothing created" eval 'rc 1 && hasj "--audit-log: run as root, $L/$AUD is not used: it would be created where $D belongs to user ID" && nfile "$L" && nfile "$S/curl.log"'
new rootlink; aka 7.7.0; as_root; HOMEV="PS7T_NOHOME=1"; run --config "$D/ps7.cfg"
check "[root] a --config file in a folder another user owns is refused" eval 'rc 1 && hasj "--config: run as root, '"'"'$D/ps7.cfg'"'"' is not used: $D belongs to user ID"'
new roottpl; as_root; HOMEV="PS7T_NOHOME=1"; run --export-template "$D/ps7.cfg"
check "[root] --export-template into a folder another user owns is refused" eval 'rc 1 && hasj "--export-template: run as root, $D/ps7.cfg is not used" && nfile "$D/ps7.cfg"'
new rootrun; as_root; HOMEV="PS7T_NOHOME=1"; run --bogus --run-log "$L/"
check "[root] a config error with an unsafe --run-log writes no run log" eval 'rc 1 && nfile "$L"'

new tmpww; aka 7.7.0; mkdir -p "$D/wtmp"; chmod 777 "$D/wtmp"; TMPV="$D/wtmp"; run --cache-dir "$C"
check "[tmpdir] a TMPDIR that other users can write to is refused before any work" eval 'rc 1 && hasj "TMPDIR: '"'"'$D/wtmp'"'"' cannot hold the private temporary folder: $D/wtmp can be changed by other users" && nfile "$S/curl.log" && empty "$D/wtmp"'
new tmpst; aka 7.7.0; mkdir -p "$D/stmp"; chmod 1777 "$D/stmp"; TMPV="$D/stmp"; run --cache-dir "$C"
check "[tmpdir] an own sticky TMPDIR is accepted, and left empty" eval 'rc 0 && has "INSTALLED PowerShell 7.7.0" && grep -q "^installer -pkg $D/stmp/Install-PowerShell7.[A-Za-z0-9]\{6\}/$PK -target /$" "$S/installer.log" && empty "$D/stmp"'
new roottmp; aka 7.7.0; EXTRA_PATH="$X"; HOMEV="PS7T_NOHOME=1"; run
check "[root] a TMPDIR that another user owns is refused (sudo -E, say)" eval 'rc 1 && hasj "TMPDIR: '"'"'$D/tmp'"'"' cannot hold the private temporary folder: $D/tmp belongs to user ID $(id -u)" && nfile "$S/curl.log"'

# ======================================================================== sudo and SUDO_ASKPASS
new ni; aka 7.7.0; run --non-interactive --cache-dir "$C" --audit-log "$L/"
check "[sudo] --non-interactive, rule for the installer only: sudo -n -l, then sudo -n, no 'true'" eval 'rc 0 && grep -q "^sudo -n -l $B/installer -pkg $(private_pkg)[A-Za-z0-9]\{6\}/$PK -target /$" "$S/sudo.log" && grep -q "^sudo -n $B/installer -pkg $(private_pkg)[A-Za-z0-9]\{6\}/$PK -target /$" "$S/sudo.log" && hasnot "true" "$S/sudo.log" && has "INSTALLED PowerShell 7.7.0"'
new nipw; aka 7.7.0; echo password > "$S/sudo_policy"; run --non-interactive --cache-dir "$C" --audit-log "$L/"
check "[sudo] --non-interactive, password needed: exit 1 before the download" eval 'rc 1 && has "ERROR [privilege]" && hasj "sudo needs a password to run $B/installer here" && hasj "Nothing was downloaded or installed." && lines "." "$S/curl.log" 1 && nfile "$S/installer.log" && has "stage=privilege" "$L/$AUD" && empty "$TMPV"'
run --non-interactive --dry-run --cache-dir "$C"
check "[sudo] --dry-run --non-interactive predicts that stop" eval 'rc 0 && hasj "[note] --non-interactive: sudo would ask for a password to run $B/installer here"'
new nidry; run --non-interactive --dry-run --pin 7.7.0 --cache-dir "$C"
check "[sudo] --dry-run --non-interactive with the installer rule: no note" eval 'rc 0 && hasnot "[note]" && has "sudo -n -l $B/installer -pkg $PK -target /" "$S/sudo.log"'
new nilist; aka 7.7.0; echo list-only > "$S/sudo_policy"; run --non-interactive --cache-dir "$C" --audit-log "$L/"
check "[sudo] the check passes but the install is refused a password: exit 1, stage privilege, package kept" eval 'rc 1 && has "ERROR [privilege]" && hasj "Nothing was installed. The verified package was kept for the next run: $C/$PK." && has "stage=privilege" "$L/$AUD" && cmp -s "$C/$PK" "$FIX/ms.pkg" && nfile "$S/installer.log"'
new askni; aka 7.7.0; echo password > "$S/sudo_policy"; printf '#!/bin/sh\necho stub-answer\n' > "$D/askpass"; chmod 755 "$D/askpass"; EXTRA_ENV="SUDO_ASKPASS=$D/askpass"; run --non-interactive --cache-dir "$C"
check "[askpass] --non-interactive with SUDO_ASKPASS: sudo -A, no -n check, installed" eval 'rc 0 && lines "." "$S/sudo.log" 2 && grep -q "^sudo -A $B/installer -pkg " "$S/sudo.log" && has "askpass answered" "$S/sudo.log" && hasnot "sudo -n" "$S/sudo.log" && hasnot "[note]" && hasnot "[ignored]"'
rm -f "$S/sudo.log" "$S/pkg_version"; run --non-interactive --dry-run --cache-dir "$C"
check "[askpass] --dry-run: sudo -A shown, no password note, sudo not called" eval 'rc 0 && has "would install   sudo -A $B/installer -pkg $PK -target /" && hasnot "[note]" && nfile "$S/sudo.log"'
new askbad; aka 7.7.0; EXTRA_ENV="SUDO_ASKPASS=$D/no-such-helper"; run --dry-run --cache-dir "$C"
check "[askpass] SUDO_ASKPASS that is not an executable file: [ignored], plain sudo" eval 'rc 0 && hasj "[ignored] SUDO_ASKPASS: '"'"'$D/no-such-helper'"'"' is not an executable file, so sudo is run without it." && has "would install   sudo $B/installer"'
new plainpw; aka 7.7.0; echo password > "$S/sudo_policy"; run --cache-dir "$C"
check "without --non-interactive, sudo failing stays an install failure (exit 4)" eval 'rc 4 && has "ERROR [install]" && hasnot "ERROR [privilege]"'

# ======================================================================== --lts and PIN_VERSION
new ltspin; printf 'PIN_VERSION=7.4.6\n' > "$D/pin.cfg"; echo "https://github.com/PowerShell/PowerShell/releases/tag/v7.6.9" > "$S/aka_url"; run --lts --dry-run --config "$D/pin.cfg" --cache-dir "$C"
check "[lts] typed --lts wins over PIN_VERSION in the file, and says so" eval 'rc 0 && hasj "[ignored] PIN_VERSION=7.4.6 in $D/pin.cfg: --lts was typed, and a typed switch wins over the file." && has "https://aka.ms/powershell-release?tag=lts" "$S/curl.log" && has "powershell-lts-7.6.9-osx-arm64.pkg" && hasnot "7.4.6-osx"'
new pinfile; printf 'PIN_VERSION=7.4.6\n' > "$D/pin.cfg"; run --dry-run --config "$D/pin.cfg" --cache-dir "$C"
check "[lts] PIN_VERSION in the file alone: pinned, no note" eval 'rc 0 && has "pinned version: v7.4.6 (no lookup)" && hasnot "[ignored]" && hasnot "[note]"'
new pinlts; printf 'CHANNEL=lts\n' > "$D/lts.cfg"; run --dry-run --pin 7.6.5 --config "$D/lts.cfg" --cache-dir "$C"
check "[lts] typed --pin with CHANNEL=lts in the file: pinned, no note" eval 'rc 0 && has "pinned version: v7.6.5" && has "powershell-7.6.5-osx-arm64.pkg" && hasnot "[ignored]"'
new conflicts; run --pin 7.7.0 --lts --dry-run --keep --cache-dir "$C"
check "typed --pin and --lts: --lts and --keep ignored" eval 'rc 0 && has "[ignored] --lts: --pin names an exact version" && has "[ignored] --keep: nothing is downloaded under --dry-run."'

# ======================================================================== interrupted
new intr; aka 7.7.0; touch "$S/curl_kill"; run --cache-dir "$C" --audit-log "$L/"
check "[interrupt] during the download: exit 130, audited, nothing left in TMPDIR or the cache" eval 'rc 130 && has "stage=interrupted" "$L/$AUD" && empty "$TMPV" && empty "$C" && nfile "$S/installer.log"'
new intr2; aka 7.7.0; touch "$S/installer_kill"; run --cache-dir "$C" --audit-log "$L/"
check "[interrupt] during the install: exit 130, nothing left in TMPDIR" eval 'rc 130 && has "stage=interrupted" "$L/$AUD" && empty "$TMPV"'

# ======================================================================== hash, signature, lookups (unchanged behaviour)
new tamper; aka 7.7.0; touch "$S/hash_tamper"; run --cache-dir "$C" --error-log "$L/" --audit-log "$L/"
check "hash mismatch: exit 4, not installed, detail in the error log" eval 'rc 4 && has "SHA-256 MISMATCH" && nfile "$S/installer.log" && has "[DETAIL]   expected 0000" "$L/$ERR" && has "stage=verify-hash" "$L/$AUD" && empty "$TMPV"'
new noentry; aka 7.7.0; echo missing-entry > "$S/hashes_mode"; run --cache-dir "$C"
check "no published hash: exit 4" eval 'rc 4 && has "no published hash for $PK" && nfile "$S/installer.log"'
new nohash; aka 7.7.0; echo fail > "$S/hashes_mode"; run --cache-dir "$C"
check "hashes.sha256 not downloadable: exit 2" eval 'rc 2 && has "could not download hashes.sha256" && nfile "$S/installer.log"'
for m in utf16nobom utf8 utf8-textmode; do
  new "enc-$m"; aka 7.7.0; echo "$m" > "$S/hashes_mode"; run --cache-dir "$C"
  check "hashes.sha256 as $m: verified" eval 'rc 0 && has "hash verified"'
done
new otherorg; aka 7.7.0
printf 'Package "x.pkg":\n   Status: signed by a developer certificate issued by Apple for distribution\n   Certificate Chain:\n    1. Developer ID Installer: Example Corp (ABCDE12345)\n    2. Developer ID Certification Authority\n    3. Apple Root CA\n' > "$S/sig_override"
run --cache-dir "$C"
check "signed by another Developer ID: exit 4" eval 'rc 4 && hasj "it is signed by '"'"'Developer ID Installer: Example Corp (ABCDE12345)'"'"'" && nfile "$S/installer.log"'
new untrusted; aka 7.7.0
printf 'Package "x.pkg":\n   Status: signed by untrusted certificate\n   Certificate Chain:\n    1. Developer ID Installer: Microsoft Corporation (UBF8T346G9)\n' > "$S/sig_override"
run --cache-dir "$C"
check "untrusted certificate with Microsoft's name: exit 4" eval 'rc 4 && hasj "not signed with a Developer ID certificate issued by Apple" && nfile "$S/installer.log"'
new noroot; aka 7.7.0
printf 'Package "x.pkg":\n   Status: signed by a developer certificate issued by Apple for distribution\n   Certificate Chain:\n    1. Developer ID Installer: Microsoft Corporation (UBF8T346G9)\n    2. Some Other CA\n' > "$S/sig_override"
run --cache-dir "$C"
check "chain not ending at Apple Root CA: exit 4" eval 'rc 4 && has "does not end at Apple Root CA"'
new api; echo '{ "tag_name": "v7.7.0" }' > "$S/api_latest.json"; run --cache-dir "$C"
check "aka.ms down: GitHub API fallback" eval 'rc 0 && has "via the GitHub API: v7.7.0" && has "INSTALLED PowerShell 7.7.0"'
new offline; run --cache-dir "$C" --audit-log "$L/"
check "both lookups fail: exit 2, audit stage=resolve" eval 'rc 2 && has "stage=resolve" "$L/$AUD" && empty "$TMPV"'
new lts1; echo "https://github.com/PowerShell/PowerShell/releases/tag/v7.6.9" > "$S/aka_url"; touch "$S/lts_id"; run --lts --cache-dir "$C"
check "LTS install with its own receipt: confirmed" eval 'rc 0 && has "powershell-lts-7.6.9-osx-arm64.pkg" "$S/installer.log" && has "INSTALLED PowerShell 7.6.9"'
new noop; aka 7.7.0; echo 7.6.9 > "$S/pkg_version"; touch "$S/installer_noop"; run --cache-dir "$C"
check "installer changes nothing: confirm fails, exit 4" eval 'rc 4 && hasj "reports '"'"'7.6.9'"'"', expected 7.7.0" && empty "$TMPV"'
new broken; aka 7.7.0; echo 7.6.9 > "$S/pkg_version"; touch "$S/pkg_broken"; run --cache-dir "$C"
check "receipt present, pwsh does not start: reinstalled" eval 'rc 0 && has "recorded as installed" && has "INSTALLED PowerShell 7.7.0"'
new brewold; aka 7.7.0; brew_copy 7.6.0; run --cache-dir "$C"
check "another pwsh on the PATH: installs, then names it once" eval 'rc 0 && has "INSTALLED PowerShell 7.7.0" && lines "\\[note\\] Typing pwsh starts" "$OUT" 1'

# ======================================================================== console and config
new quiet; aka 7.7.0; run --quiet --cache-dir "$C" --run-log "$L/"
check "quiet: notice kept, info only in the run log" eval 'rc 0 && first_is_notice && hasnot "hash verified" && has "hash verified" "$L/$RUNL"'
new verbose; aka 7.7.0; run --verbose --cache-dir "$C"
check "verbose: the installer output is shown" eval 'rc 0 && has "installer: The upgrade was successful."'
new color; aka 7.7.0; EXTRA_ENV="SCRIPT_UI_COLOR=1"; run --cache-dir "$C" --run-log "$L/"
check "colour forced on: console coloured, run log plain" eval 'rc 0 && has "$ESC" && hasnot "$ESC" "$L/$RUNL"'
new savecur; aka 7.7.0; echo 7.7.0 > "$S/pkg_version"; run --config "$D/new.cfg" --save-config --cache-dir "$C"
check "save-config when current: file created" eval 'rc 0 && has "settings saved" && has "CACHE_DIR=$C" "$D/new.cfg"'
run --config "$D/new.cfg"
check "saved file read back" eval 'rc 0 && has "config: read 7 setting(s)"'
new cfgparse
printf '  # a comment\r\nCHANNEL = "lts"\r\nPIN_VERSION=\r\nCACHE_DIR = ~/ps7cache\r\nKEEP_PKG='"'"'yes'"'"'\r\nBOGUS=1\r\nnot a setting\r\nAUDIT_LOG=~/logs/\r\n' > "$D/odd.cfg"
run --config "$D/odd.cfg" --dry-run --pin 7.7.0
check "config: CRLF, spaces, quotes, ~ handled; unknown key and bad line noted" eval 'rc 0 && has "channel=lts" && has "cache=$D/home/ps7cache" && has "unknown key '"'"'BOGUS'"'"' ignored" && [ -f "$D/home/logs/$AUD" ]'
new cfgmissing; run --config "$D/none.cfg" --cache-dir "$C"
check "config: missing file without --save-config is an error" eval 'rc 1 && has "--config: cannot read"'

if [ "$fail" = 0 ]; then echo "ALL TESTS PASSED"; else echo "TESTS FAILED"; exit 1; fi
