#!/bin/bash
# =============================================================================
# install-powershell7-macos.sh  (canonical name: Install-PowerShell7)
#
# PURPOSE
#   Install or upgrade to the latest FULL PowerShell 7 for macOS from
#   Microsoft's official GitHub releases. Idempotent and fail-closed: resolves
#   the current stable (or LTS) tag, compares it to the installed PowerShell,
#   downloads the .pkg for this CPU, verifies its SHA-256 against Microsoft's
#   published hashes and its Apple Developer ID signature, then installs.
#   Exits 0 doing nothing when already current, so it is safe to schedule.
#
#   Part of the Access Connector Automated Upgrade repository: the admin
#   machine that runs the tool needs PowerShell 7 (docs/Getting-Started.md).
#
#   macOS port of the author's Windows GPO script Deploy-PowerShell7.ps1 (same
#   design), built on the author's template-standard.sh per the author's
#   Bash-Script-Standards-macOS.md.
#
# ATTRIBUTION  (standards: never redacted by any switch)
#   Author ........ the copyright holder named in LICENSE (repository root)
#   Created ....... 2026-10-08
#   Version ....... 2.1.1
#   Derived from .. Deploy-PowerShell7.ps1 (same author, Windows GPO script)
#
# REVISION HISTORY
#   2026-10-08  1.0.0  First macOS port; functionally verified, not
#                      standards-compliant.
#   2026-10-08  2.0.0  Rebuilt on template-standard.sh: launch notice, red
#                      disclaimer, 78-col help, audit/error/run logs, KEY=VALUE
#                      config, conflict reporting, capture-then-emit, exit codes
#                      0-5. --version now prints THIS script's version; the
#                      PowerShell version pin moved to --pin.
#   2026-10-08  2.0.1  Licence finalised (copyright line replaces the
#                      placeholder).
#   2026-11-23  2.1.0  Joined this repository: contact details and the
#                      fallback to a personal askpass helper removed; the
#                      repository's MIT licence, launch notice and disclaimer.
#                      Fixes: the UTF-16 test of hashes.sha256 always matched
#                      (a NUL byte cannot pass through $(...)), so it now reads
#                      the byte-order mark; the hash is taken for the exact file
#                      name; the signature must also show the Apple distribution
#                      status, Microsoft's Team ID and Apple Root CA; the LTS
#                      channel has its own API fallback; the version compared is
#                      that of Microsoft's package, not whichever pwsh is first
#                      on the PATH (another copy, such as Homebrew's, is named
#                      in a note); a shell under Rosetta 2 gets the Apple
#                      silicon package; --save-config also saves when already
#                      current; --export-template takes a bare file name or a
#                      folder and never overwrites, not even through a link;
#                      quotes in audit values; config values trimmed, ~
#                      expanded; words with * or [ in help text are no longer
#                      glob-expanded.
#                      The package is downloaded, checked and installed in a
#                      private temporary folder (mode 0700), so nobody can
#                      change it between the checks and the install; the cache
#                      only keeps and offers a copy, and it, and every folder
#                      above it, must be changeable only by the account
#                      running the script or root; TMPDIR, where the private
#                      folder is made, may not be one another user owns or may
#                      write to. With HOME unset there is no default cache
#                      (2.0.1 stopped with 'HOME: unbound variable').
#                      Run as root, a cache, log, template or --config file
#                      that is a symbolic link, or that another user could
#                      change, is refused. --non-interactive asks sudo before
#                      the download whether /usr/sbin/installer may run
#                      without a password (sudo -n -l), runs it with sudo -n,
#                      or with sudo -A when SUDO_ASKPASS names a helper, and a
#                      password refused at the install step also exits 1. The
#                      installer is called by its full path. A typed --lts
#                      wins over PIN_VERSION in the --config file. A run that
#                      stops early still writes its run log; --version names
#                      unknown switches; an interrupted command's capture file
#                      is removed. The scope text names /etc/shells, the
#                      manual page and the installer receipt.
#   2026-11-26  2.1.1  No change to what the script does: three names it
#                      never used are removed (exit codes 3 and 5, a colour and
#                      the variable of --allow-plaintext-secrets, which is still
#                      accepted and reported as ignored), and the deliberate
#                      match of a typed ~ is marked for shellcheck, which now
#                      runs on every push.
#
# LICENCE
#   MIT License; see LICENSE at the root of this repository.
#
# RUNTIME
#   Stock macOS /bin/bash 3.2. Forbidden on 3.2 and by rule: declare -A,
#   mapfile/readarray, ${v,,}/${v^^}, |&, ;;&, coproc, set -e, sourcing a
#   config file, LC_ALL=C around width math, box-drawing dividers. ASCII only.
# =============================================================================

# ---- per-script constants ---------------------------------------------------
SCRIPT_NAME="${0##*/}"
SCRIPT_CANON="Install-PowerShell7"
SCRIPT_VERSION="2.1.1"
SCRIPT_CREATED="2026-10-08"
SCRIPT_LICENCE="MIT License; see the LICENSE file at the root of this repository."
SCRIPT_SUPPORT="There is no support channel. For PowerShell itself, see github.com/PowerShell/PowerShell."
SCOPE_OF_WRITES="Installs or upgrades Microsoft's PowerShell package with the macOS installer, run through sudo for that step only: the files under /usr/local/microsoft/powershell, the pwsh link in /usr/local/bin, the pwsh manual page in /usr/local/share/man/man1 and PowerShell.app in /Applications. Microsoft's package also adds /usr/local/bin/pwsh to /etc/shells, and macOS records an installer receipt for it. The package is downloaded, checked and installed from a private temporary folder that is removed when the run ends; a copy is kept in the cache folder (default ~/Library/Caches/PowerShell7Install) only with --keep or when the install step fails. The script also writes the logs and answer files you name. The script itself changes nothing else."
DATA_HANDLING="Logs record the user and host name, this script's version, the PowerShell versions found and installed, download URLs, the verified SHA-256, the outcome, stage, duration and error detail. No credentials are used or stored."
REPO="PowerShell/PowerShell"
UA="ps7-macos-install/$SCRIPT_VERSION"
# What a genuine package shows in 'pkgutil --check-signature' (Microsoft's Apple Team ID is UBF8T346G9)
MS_SIGNER="Developer ID Installer: Microsoft Corporation (UBF8T346G9)"
APPLE_STATUS="signed by a developer certificate issued by Apple for distribution"
PKG_ROOT="/usr/local/microsoft/powershell"
INSTALLER="/usr/sbin/installer"   # by its full path, so that a sudoers rule naming it matches

# ---- environment (D11, D12) -------------------------------------------------
export LC_CTYPE=en_US.UTF-8
set -u
set -o pipefail

# ---- exit codes (D3) --------------------------------------------------------
# 3 (partial) and 5 (no result) belong to the template; this script does not use them,
# so they are not defined.
EX_OK=0; EX_CONFIG=1; EX_SETUP=2; EX_TOTAL=4; EX_INTERRUPT=130

# ---- runtime check (D1) -----------------------------------------------------
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 3 ]; then
  printf '%s: run this script with bash 3.2 or newer, for example: bash %s (found %s)\n' \
    "$SCRIPT_NAME" "$0" "${BASH_VERSION:-another shell}" >&2
  exit 1
fi

# =============================================================================
# EMBEDDED HELPER BLOCK  - from template-standard.sh 1.0.0; the launch notice
# and the disclaimer use this repository's wording
# =============================================================================
UI_WIDTH=78
QUIET=""; VERBOSE=""; DRY_RUN=""; NON_INTERACTIVE=""; HELP=""; SHOW_VERSION=""
AUDIT_LOG=""; ERROR_LOG=""; RUN_LOG=""; CONFIG_FILE=""; EXPORT_TEMPLATE=""
SAVE_CONFIG=""
SUPPLIED=""
AUDIT_PATH=""; ERROR_PATH=""; RUN_LOG_PATH=""
AUDIT_WRITTEN=0; OUTCOME="FAILED"; STAGE="init"; DETAIL=""; NO_AUDIT=""
EARLY_BUF=""; SECRETS=""; PROBLEMS=""; CONFLICTS=""
# The private folder of this run, a command's capture file, a package half copied into the cache
WORK_BASE=""; WORK_DIR=""; TMP_CAPTURE=""; TMP_KEEP=""; RUN_OUT=""; MY_UID=""; SAFE_WHY=""
C_RESET=""; C_BANNER=""; C_SECTION=""; C_LEGAL=""; C_RULE=""; C_CMD=""; C_FLAG=""; C_TEXT=""
C_WARN=""; C_NOTICE=""; C_CAUTION=""; C_OK=""; C_INFO=""; C_DIM=""
# Settings this script understands (config allow-list)
SETTING_CHANNEL=""; SETTING_PIN=""; SETTING_CACHE=""; SETTING_KEEP=""; SETTING_FORCE=""
CACHE_EXPLICIT=""; PIN_FROM_FILE=""
# What is installed (set by detect_installed) and this Mac's package flavour
PKG_ID=""; PKG_PWSH=""; PKG_VER=""; PATH_PWSH=""; PATH_VER=""; PATH_NOTED=""; ARCH=""; ROSETTA=""
# The package: its name, its private copy, its place in the cache, and where it was kept
PKG=""; PKGPATH=""; CACHED=""; FROM_CACHE=""; KEPT=""

add_problem()  { PROBLEMS="$PROBLEMS
$1"; }
add_conflict() { CONFLICTS="$CONFLICTS
$1"; }

register_secret() { local v="$1"; [ -z "$v" ] && return 0; [ "${#v}" -lt 6 ] && return 0
  case "$SECRETS" in *"$v"*) return 0 ;; esac; SECRETS="$SECRETS
$v"; }
protect_text() { local t="$1" s; [ -z "$SECRETS" ] && { printf '%s' "$t"; return 0; }
  while IFS= read -r s; do [ -n "$s" ] && t="${t//"$s"/********}"; done <<EOF
$SECRETS
EOF
  printf '%s' "$t"; }
mask_id() { local v="$1" n; n="${#v}"; if [ "$n" -le 4 ]; then printf '****'; else printf '%s...%s' "${v:0:2}" "${v:$((n-2))}"; fi; }

ui_init() {
  local use=1 e; e="$(printf '\033')"
  [ -n "${NO_COLOR:-}" ] && use=0; [ -t 1 ] || use=0
  [ -n "${SCRIPT_UI_COLOR:-}" ] && use=1; [ -n "${OMNISSA_UI_COLOR:-}" ] && use=1
  if [ "$use" -eq 1 ]; then
    C_RESET="${e}[0m"; C_BANNER="${e}[1;97;44m"; C_SECTION="${e}[1;96;100m"; C_LEGAL="${e}[1;97;41m"
    C_RULE="${e}[38;5;240m"; C_CMD="${e}[92m"; C_FLAG="${e}[1;93m"; C_TEXT="${e}[38;5;250m"
    C_WARN="${e}[1;91m"; C_NOTICE="${e}[1;93m"; C_CAUTION="${e}[93m"; C_OK="${e}[92m"; C_INFO="${e}[96m"
    C_DIM="${e}[38;5;244m"
  fi
  return 0
}
# emit_line STYLED PLAIN [force]: STYLED goes to the console, PLAIN (no colour codes) to the run log
emit_line() {
  if [ -z "$QUIET" ] || [ "${3:-}" = "force" ]; then printf '%s\n' "$1"; fi
  if [ -n "$RUN_LOG_PATH" ]; then printf '%s\n' "$2" >> "$RUN_LOG_PATH"; else EARLY_BUF="$EARLY_BUF$2
"; fi
}
emit() {   # emit STYLE TEXT [force]
  local text="$2"; [ -n "$SECRETS" ] && text="$(protect_text "$2")"
  if [ -n "$1" ]; then emit_line "$1$text$C_RESET" "$text" "${3:-}"; else emit_line "$text" "$text" "${3:-}"; fi
}
# ui_wrap TEXT [INDENT [HANG]]: words joined into lines of at most UI_WIDTH columns. The first line
# starts with INDENT, the later ones with HANG (default INDENT). Words are never glob-expanded.
ui_wrap() { local text="$1" indent="${2:-}" hang="${3-${2:-}}" cur="" w cand glob=1
  case "$-" in *f*) glob=0 ;; esac; set -f
  for w in $text; do
    if [ -z "$cur" ]; then cand="$indent$w"; else cand="$cur $w"; fi
    if [ -z "$cur" ] || [ "${#cand}" -le "$UI_WIDTH" ]; then cur="$cand"; else printf '%s\n' "$cur"; cur="$hang$w"; fi
  done; [ -n "$cur" ] && printf '%s\n' "$cur"
  [ "$glob" -eq 1 ] && set +f; return 0; }
ui_rule()    { emit "$C_RULE" "$(printf '%*s' "$UI_WIDTH" '' | tr ' ' '-')" force; }
ui_section() { local tag="$C_SECTION"; [ "${2:-}" = "legal" ] && tag="$C_LEGAL"; emit "" "" force; emit "$tag" " $1 " force; ui_rule; }
ui_text()    { local l; while IFS= read -r l; do emit "$C_TEXT" "$l" force; done <<EOF
$(ui_wrap "$1" "  ")
EOF
}
ui_warn()    { local l; while IFS= read -r l; do emit "$C_WARN" "$l" force; done <<EOF
$(ui_wrap "$1" "  ")
EOF
}
ui_cmd()     { emit "$C_CMD" "  $1" force; }
ui_caption() { emit "$C_DIM" "  $1" force; }
ui_param() { local col=22 pad first=1 l
  # a flag too long for its column goes on a line of its own, so one space always follows a flag
  if [ "${#1}" -gt $((col - 3)) ]; then emit "$C_FLAG" "  $1" force; first=0; fi
  pad="$(printf "  %-$((col - 2))s" "$1")"
  while IFS= read -r l; do
    if [ "$first" -eq 1 ]; then emit_line "$C_FLAG$pad$C_RESET$C_TEXT$l$C_RESET" "$pad$l" force; first=0
    else emit "$C_TEXT" "$(printf '%*s' "$col" '')$l" force; fi
  done <<EOF
$(UI_WIDTH=$((UI_WIDTH - col)) ui_wrap "$2")
EOF
}
info()    { emit "$C_INFO" "$1"; }
ok()      { emit "$C_OK"   "$1"; }
warn()    { emit "$C_WARN" "$1" force; }
caution() { emit "$C_CAUTION" "$1" force; }
note() {   # note TEXT: yellow, wrapped, later lines under the text that follows a leading [tag]
  local l rest hang="  "
  case "$1" in "["*"] "*) rest="${1#*] }"; hang="$(printf '%*s' $(( ${#1} - ${#rest} )) '')" ;; esac
  while IFS= read -r l; do [ -n "$l" ] && caution "$l"; done <<EOF
$(ui_wrap "$1" "" "$hang")
EOF
}
alert() {   # alert TEXT: red, wrapped, later lines indented
  local l
  while IFS= read -r l; do [ -n "$l" ] && warn "$l"; done <<EOF
$(ui_wrap "$1" "" "  ")
EOF
}

show_launch_notice() {
  emit "" "" force
  emit "$C_NOTICE" '  UNSUPPORTED - provided "AS IS", NO WARRANTY. Use at your own risk. Neither' force
  emit "$C_NOTICE" '  Omnissa nor the author is liable for any damages. Full text: --help' force
  emit "" "" force
}
show_disclaimer() {
  ui_section "LEGAL DISCLAIMER - UNSUPPORTED, USE AT YOUR OWN RISK" legal
  ui_warn "This script is an UNSUPPORTED utility. It is NOT an Omnissa or Microsoft product or offering, and it is not covered by any Omnissa or Microsoft support, maintenance, or service-level agreement."
  ui_warn "It is provided \"AS IS\" and \"AS AVAILABLE\", WITHOUT WARRANTY OF ANY KIND, express or implied, including but not limited to the implied warranties of merchantability, fitness for a particular purpose, title, and non-infringement."
  ui_warn "YOU USE IT ENTIRELY AT YOUR OWN RISK. You are solely responsible for validating its behaviour in a non-production environment before any production use, and for any effect it has on your systems or data."
  ui_warn "TO THE MAXIMUM EXTENT PERMITTED BY LAW, NEITHER OMNISSA NOR THE AUTHOR SHALL BE LIABLE FOR ANY CLAIM, LOSS, OR DAMAGES WHATSOEVER - direct, indirect, incidental, special, exemplary, or consequential (including loss of data, revenue, or profits) - arising from or in connection with the use of, or inability to use, this script."
  ui_warn "PowerShell itself is Microsoft's, under its own licence. This script downloads, checks and installs the package Microsoft publishes; it does not change it."
  ui_warn "Scope of operation: $SCOPE_OF_WRITES"
  ui_warn "Data handling: $DATA_HANDLING"
  ui_warn "Support: $SCRIPT_SUPPORT"
}

# The "~" below is the text the user typed, matched on purpose; HOME takes its place.
# shellcheck disable=SC2088
expand_tilde() { case "$1" in "~") printf '%s' "${HOME:-}" ;; "~/"*) printf '%s/%s' "${HOME:-}" "${1:2}" ;; *) printf '%s' "$1" ;; esac; }
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
# owned_safely PATH [above]: true when PATH belongs to root or to the account running this script
# (only root when that is root) and is not writable by its group or by others. With "above", a
# sticky folder such as /tmp is accepted: others cannot rename or remove what they do not own in it.
owned_safely() { local owner mode
  read -r owner mode <<EOF
$(stat -f '%u %p' "$1" 2>/dev/null)
EOF
  case "${owner:-x}:${mode:-x}" in *[!0-9:]*) SAFE_WHY="the owner and permissions of $1 cannot be read"; return 1 ;; esac
  if [ "$owner" != "0" ] && [ "$owner" != "$MY_UID" ]; then SAFE_WHY="$1 belongs to user ID $owner"; return 1; fi
  if [ $(( 8#$mode & 8#22 )) -ne 0 ]; then
    if [ "${2:-}" != "above" ] || [ $(( 8#$mode & 8#1000 )) -eq 0 ]; then SAFE_WHY="$1 can be changed by other users"; return 1; fi
  fi
  return 0; }
# folder_safe DIR [above]: true when DIR passes owned_safely and so does every folder above it
# (sticky ones accepted there), so that no other user can put a file or a link in it. With "above",
# DIR itself may be sticky too: enough for a folder that only holds a private one (mktemp -d).
# Otherwise false, with the reason in SAFE_WHY. Links are followed first; the real folders are checked.
folder_safe() { local d p
  SAFE_WHY=""; case "$1" in /*) d="$1" ;; *) d="./$1" ;; esac
  d="$(cd -P "$d" 2>/dev/null && pwd -P)" || { SAFE_WHY="$1 cannot be opened"; return 1; }
  owned_safely "$d" "${2:-}" || return 1
  p="$d"; while [ "$p" != "/" ]; do p="${p%/*}"; [ -z "$p" ] && p="/"; owned_safely "$p" above || return 1; done
  return 0; }
# prepare_folder DIR: DIR is created when missing (only inside a folder that passes folder_safe, and
# readable by this account only), then checked with folder_safe.
prepare_folder() { local up="$1"
  if [ ! -d "$1" ]; then
    while [ ! -d "$up" ]; do case "$up" in */*) up="${up%/*}"; [ -z "$up" ] && up="/" ;; *) up="." ;; esac; done
    folder_safe "$up" || { SAFE_WHY="it would be created where $SAFE_WHY"; return 1; }
    ( umask 077; mkdir -p "$1" ) 2>/dev/null || { SAFE_WHY="$1 cannot be created"; return 1; }
  fi
  folder_safe "$1"; }
# resolve_log_path VALUE DEFAULT-NAME: VALUE as a file, or DEFAULT-NAME inside VALUE when it is a
# folder; the folder is created. Run as root, a symbolic link, or a folder that a user other than
# root could change, is refused. On failure it prints the reason and returns 1.
resolve_log_path() { local v="$1" def="$2" dir; [ -z "$v" ] && return 0
  v="$(expand_tilde "$v")"
  case "$v" in */) v="$v$def" ;; *) [ -d "$v" ] && v="$v/$def" ;; esac
  dir="${v%/*}"; [ "$dir" = "$v" ] && dir="."; [ -z "$dir" ] && dir="/"
  if [ "$MY_UID" = "0" ]; then
    prepare_folder "$dir" || { printf 'run as root, %s is not used: %s' "$v" "$SAFE_WHY"; return 1; }
    if [ -L "$v" ]; then printf 'run as root, %s is not used: it is a symbolic link' "$v"; return 1; fi
  else
    mkdir -p "$dir" 2>/dev/null || { printf 'cannot create the folder %s' "$dir"; return 1; }
  fi
  printf '%s' "$v"; }
probe_writable() { ( : >> "$1" ) 2>/dev/null; }
open_run_log() { [ -z "$RUN_LOG_PATH" ] && return 0
  if [ ! -s "$RUN_LOG_PATH" ]; then printf '# %s run log - created %s - version %s\n' \
    "$SCRIPT_NAME" "$(date '+%Y-%m-%dT%H:%M:%S')" "$SCRIPT_VERSION" >> "$RUN_LOG_PATH"; fi
  printf '# run started %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" >> "$RUN_LOG_PATH"
  printf '%s' "$EARLY_BUF" >> "$RUN_LOG_PATH"; EARLY_BUF=""; }
audit_kv() { local v sq="'"; v="$(printf '%s' "$2" | tr '\r\n\t' '   ')"
  case "$v" in *[[:space:]\"]*) v="${v//\"/$sq}"; printf '%s="%s"' "$1" "$v" ;; *) printf '%s=%s' "$1" "$v" ;; esac; }
audit_write() {
  [ "$AUDIT_WRITTEN" -eq 1 ] && return 0; [ -n "$NO_AUDIT" ] && return 0
  if [ -z "$AUDIT_PATH" ] && [ -n "$AUDIT_LOG" ]; then
    AUDIT_PATH="$(resolve_log_path "$AUDIT_LOG" "${SCRIPT_NAME%.sh}-audit.log" 2>/dev/null)" || AUDIT_PATH=""; fi
  [ -z "$AUDIT_PATH" ] && return 0
  if [ ! -s "$AUDIT_PATH" ]; then printf '# %s audit log - append only - created %s - version %s\n' \
    "$SCRIPT_NAME" "$(date '+%Y-%m-%dT%H:%M:%S')" "$SCRIPT_VERSION" >> "$AUDIT_PATH"; fi
  { audit_kv time "$(date '+%Y-%m-%dT%H:%M:%S%z')"; printf ' '; audit_kv user "${USER:-unknown}"; printf ' '
    audit_kv host "$(hostname -s 2>/dev/null)"; printf ' '; audit_kv script "$SCRIPT_NAME"; printf ' '
    audit_kv version "$SCRIPT_VERSION"; printf ' '; audit_kv channel "${SETTING_CHANNEL:-stable}"; printf ' '
    audit_kv dryRun "$([ -n "$DRY_RUN" ] && echo true || echo false)"; printf ' '
    audit_kv outcome "$OUTCOME"; printf ' '; audit_kv stage "$STAGE"; printf ' '; audit_kv durationSec "$SECONDS"
    [ -n "$DETAIL" ] && { printf ' '; audit_kv detail "$(protect_text "$DETAIL")"; }; printf '\n'
  } >> "$AUDIT_PATH"; AUDIT_WRITTEN=1; }
cleanup_temp() {   # the capture file of a command cut short, a half-kept package, and the private folder
  local f; for f in "$TMP_CAPTURE" "$TMP_KEEP"; do [ -n "$f" ] && rm -f "$f"; done; TMP_CAPTURE=""; TMP_KEEP=""
  case "$WORK_DIR" in */"$SCRIPT_CANON".??????*) rm -rf "$WORK_DIR" ;; esac; WORK_DIR=""; return 0; }
late_run_log() {   # a run that stopped before its run log was opened (a configuration error, say) still writes it
  if [ -n "$NO_AUDIT" ] || [ -n "$RUN_LOG_PATH" ] || [ -z "$RUN_LOG" ]; then return 0; fi
  RUN_LOG_PATH="$(resolve_log_path "$RUN_LOG" "${SCRIPT_NAME%.sh}-run.log" 2>/dev/null)" || RUN_LOG_PATH=""
  if [ -n "$RUN_LOG_PATH" ] && probe_writable "$RUN_LOG_PATH"; then open_run_log; else RUN_LOG_PATH=""; fi
  return 0; }
audit_finalize() { cleanup_temp; late_run_log; audit_write; }
on_interrupt()   { STAGE="interrupted"; OUTCOME="FAILED"; DETAIL="signal"; exit "$EX_INTERRUPT"; }
# err STAGE MESSAGE [DETAIL]: red on screen (DETAIL dimmed below it); appended to the error log
err() { local stage="$1" msg="$2" detail="${3:-}" ts l n=0
  alert "ERROR [$stage] $msg"
  if [ -n "$detail" ]; then
    while IFS= read -r l; do n=$((n+1)); [ "$n" -le 20 ] && emit "$C_DIM" "    $l" force; done <<EOF
$detail
EOF
    [ "$n" -gt 20 ] && emit "$C_DIM" "    ... $((n - 20)) more line(s); see the error log" force
  fi
  if [ -z "$ERROR_PATH" ] && [ -n "$ERROR_LOG" ]; then
    ERROR_PATH="$(resolve_log_path "$ERROR_LOG" "${SCRIPT_NAME%.sh}-errors.log" 2>/dev/null)" || ERROR_PATH=""; fi
  [ -z "$ERROR_PATH" ] && return 0; ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  if [ ! -s "$ERROR_PATH" ]; then printf '# %s error log - created %s - version %s\n' "$SCRIPT_NAME" "$ts" "$SCRIPT_VERSION" >> "$ERROR_PATH"; fi
  { printf '%s [ERROR] [%s] %s\n' "$ts" "$stage" "$(protect_text "$msg")"
    if [ -n "$detail" ]; then printf '%s\n' "$(protect_text "$detail")" | sed "s/^/$ts [DETAIL]   /"; fi
  } >> "$ERROR_PATH"; }
die() { STAGE="$2"; OUTCOME="FAILED"; DETAIL="$3"; err "$2" "$3" "${4:-}"; exit "$1"; }
# run_captured STAGE COMMAND...: runs COMMAND with its output captured (kept in RUN_OUT); the
# capture file is named in a global, so an interrupt removes it too
run_captured() { local stage="$1" rc l; shift; STAGE="$stage"; RUN_OUT=""
  if [ -n "$DRY_RUN" ]; then info "[dry-run] $stage: $*"; return 0; fi
  TMP_CAPTURE="$(mktemp "${WORK_DIR:-${TMPDIR:-/tmp}}/${SCRIPT_NAME}.XXXXXX")" || { TMP_CAPTURE=""; return 1; }
  "$@" > "$TMP_CAPTURE" 2>&1; rc=$?; RUN_OUT="$(cat "$TMP_CAPTURE")"; rm -f "$TMP_CAPTURE"; TMP_CAPTURE=""
  if [ "$rc" -ne 0 ]; then err "$stage" "command failed (rc=$rc): $*" "$RUN_OUT"
  elif [ -n "$VERBOSE" ] && [ -n "$RUN_OUT" ]; then while IFS= read -r l; do emit "$C_DIM" "    $l"; done <<EOF
$RUN_OUT
EOF
  fi; return "$rc"; }
is_supplied() { case " $SUPPLIED " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
export_template() { local f
  f="$(resolve_log_path "$1" "${SCRIPT_NAME%.sh}.cfg")" || die "$EX_CONFIG" export-template "--export-template: $f"
  if [ -e "$f" ] || [ -L "$f" ]; then die "$EX_CONFIG" export-template "--export-template: '$f' already exists and was left as it is. Name a new file, or move that one away first."; fi
  # set -C: the file is only created, never written through a file or link that appears meanwhile
  ( set -C; { printf '# %s configuration - KEY=VALUE, one per line, # for comments\n' "$SCRIPT_NAME"
    printf '# WARNING: do not commit a populated copy of this file to source control.\n'
    printf '# Precedence: command-line switch > this file > built-in default\n'
    printf '# CHANNEL is stable or lts. PIN_VERSION installs exactly that release.\n'
    printf '# CACHE_DIR blank means ~/Library/Caches/PowerShell7Install. KEEP_PKG is yes or no.\n'
    printf '# The log keys take a file or a folder, as --audit-log, --error-log and --run-log do.\n'
    printf 'CHANNEL=stable\n# PIN_VERSION=7.6.5\nCACHE_DIR=\nKEEP_PKG=no\nAUDIT_LOG=\nERROR_LOG=\nRUN_LOG=\n'
  } > "$f" ) 2>/dev/null || die "$EX_CONFIG" export-template "cannot write the template to $f"
  ok "template written: $f"
  STAGE="export-template"; OUTCOME="SUCCESS"; DETAIL="template=$f"; }
# =============================================================================
# END HELPER BLOCK
# =============================================================================

# ---- configuration: KEY=VALUE parsed line-by-line, never sourced (D6) ---------
load_config() {
  local f="$1" line key val n=0 cr; cr="$(printf '\r')"
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then add_problem "--config: cannot read '$f'. Check the path, or create it with --export-template."; return 1; fi
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%"$cr"}"; line="$(trim "$line")"
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) note "[note] config: ignoring a line that is not KEY=VALUE: $line"; continue ;; esac
    key="$(trim "${line%%=*}")"; val="$(trim "${line#*=}")"
    case "$val" in \"*\") val="${val#\"}"; val="${val%\"}" ;; \'*\') val="${val#\'}"; val="${val%\'}" ;; esac
    case "$key" in
      CHANNEL)     is_supplied --lts       || SETTING_CHANNEL="$val" ;;
      PIN_VERSION) is_supplied --pin       || { SETTING_PIN="$val"; PIN_FROM_FILE="$val"; } ;;
      CACHE_DIR)   is_supplied --cache-dir || SETTING_CACHE="$(expand_tilde "$val")" ;;
      KEEP_PKG)    is_supplied --keep      || SETTING_KEEP="$val" ;;
      AUDIT_LOG)   is_supplied --audit-log || AUDIT_LOG="$val" ;;
      ERROR_LOG)   is_supplied --error-log || ERROR_LOG="$val" ;;
      RUN_LOG)     is_supplied --run-log   || RUN_LOG="$val" ;;
      *) note "[note] config: unknown key '$key' ignored"; continue ;;
    esac
    n=$((n+1))
  done < "$f"
  info "config: read $n setting(s) from $f"
}
save_config() {   # the settings this run used, written to the --config file
  if { printf '# %s configuration - saved %s\n' "$SCRIPT_NAME" "$(date '+%Y-%m-%dT%H:%M:%S')"
       printf '# WARNING: do not commit a populated copy of this file to source control.\n'
       printf '# Precedence: command-line switch > this file > built-in default\n'
       printf 'CHANNEL=%s\nPIN_VERSION=%s\nCACHE_DIR=%s\nKEEP_PKG=%s\nAUDIT_LOG=%s\nERROR_LOG=%s\nRUN_LOG=%s\n' \
         "$SETTING_CHANNEL" "$SETTING_PIN" "$SETTING_CACHE" "$SETTING_KEEP" "$AUDIT_LOG" "$ERROR_LOG" "$RUN_LOG"
     } 2>/dev/null > "$CONFIG_FILE"
  then ok "settings saved: $CONFIG_FILE  (reuse: $SCRIPT_NAME --config $CONFIG_FILE)"
  else note "[note] --save-config: could not write $CONFIG_FILE. The run itself succeeded."; fi
}

# ---- help (must-haves 1, 5) ---------------------------------------------------
show_help() {
  emit "$C_BANNER" "$(printf '%-*s' "$UI_WIDTH" " $SCRIPT_NAME  v$SCRIPT_VERSION  ($SCRIPT_CANON)")" force
  show_disclaimer
  ui_section "SYNOPSIS"
  ui_cmd "$SCRIPT_NAME [--lts | --pin X.Y.Z] [--force] [--keep]"
  ui_cmd "    [--cache-dir DIR] [--config FILE] [--save-config]"
  ui_cmd "    [--audit-log PATH] [--error-log PATH] [--run-log PATH]"
  ui_cmd "    [--dry-run] [--non-interactive] [--quiet] [--verbose]"
  ui_cmd "$SCRIPT_NAME --export-template FILE | --help | --version"
  ui_section "DESCRIPTION"
  ui_text "Installs or updates PowerShell 7 on a Mac from the package Microsoft publishes on GitHub. The admin machine that runs the Access Connector Automated Upgrade tool needs PowerShell 7; this is one way to get it and keep it current."
  ui_text "It looks up the current stable (or LTS) release and compares it with the PowerShell installed. When that is older or missing, it downloads the full macOS package for this Mac's processor (Apple silicon or Intel; a shell running under Rosetta 2 still gets the Apple silicon package), checks its SHA-256 against the hashes Microsoft publishes with the release and its signature (Developer ID Installer: Microsoft Corporation, Team ID UBF8T346G9, issued by Apple), and installs it. A failed check stops the run before anything is installed, and a package whose hash does not match is deleted. When PowerShell is already current it does nothing and exits 0, so it is safe to schedule."
  ui_text "The latest release is found through Microsoft's aka.ms release link first (no rate limit), then through the GitHub releases API. With --pin no lookup is made."
  ui_text "It installs and updates Microsoft's package only. If typing pwsh starts another copy (one that Homebrew installed, for example), the run says so in a note; update that copy with its own tool, such as brew upgrade powershell. When Microsoft's package is not installed but another copy of PowerShell is, that copy's version is the one compared."
  ui_section "PARAMETERS"
  ui_param "--lts"               "Follow the LTS (long-term support) channel instead of stable. Alias: -Lts."
  ui_param "--pin X.Y.Z"         "Install exactly this release, for example 7.6.5, instead of looking up the latest. If the installed version is the same or newer, nothing is done; add --force to reinstall it or to go back to it. Alias: -PinVersion. (--version prints this script's own version.)"
  ui_param "--force"             "Install even when the installed version is already current. Alias: -Force."
  ui_param "--keep"              "Keep the downloaded package in the cache (see --cache-dir) after a successful install. A cached package is checked again before any reuse. Alias: -Keep."
  ui_param "--cache-dir DIR"     "Where a package is kept (with --keep, or after a failed install) and found again by a later run. Default ~/Library/Caches/PowerShell7Install; when HOME is not set there is no default, and no cache. The download, the checks and the install always use a private temporary folder; a cached package is copied there and checked again. The folder, and every folder above it, must be changeable only by you or root (only by root when the script runs as root): one that other users can change is refused. Alias: -CacheDir."
  ui_param "--config FILE"       "Answer file of KEY=VALUE lines, read line by line and never run as code. Keys: CHANNEL (stable or lts), PIN_VERSION, CACHE_DIR, KEEP_PKG (yes or no), AUDIT_LOG, ERROR_LOG, RUN_LOG. A switch typed on the command line wins over the file. Alias: -ConfigFile."
  ui_param "--export-template FILE" "Write a commented answer file to fill in, then exit: no network, no install. A folder gets ${SCRIPT_NAME%.sh}.cfg in it. An existing file is never overwritten. Alias: -ExportTemplate."
  ui_param "--save-config"       "After a successful run (also when already current), write the settings used to the --config file, which is created if it does not exist. Not with --dry-run. Alias: -SaveConfig."
  ui_param "--audit-log PATH"    "Append-only key=value audit log: one line per run, on every exit path. A file, or a folder (the file is then ${SCRIPT_NAME%.sh}-audit.log). Alias: -AuditLog."
  ui_param "--error-log PATH"    "Append-only error log with the detail of each failure. A file or a folder. Alias: -ErrorLog."
  ui_param "--run-log PATH"      "Plain-text copy of everything shown on screen, appended. A file or a folder. Alias: -RunLog."
  ui_param "--dry-run"           "Look up the latest release (Microsoft's servers are contacted unless --pin is given), compare, and report what would happen. Downloads, checks and installs nothing. Alias: -DryRun."
  ui_param "--non-interactive"   "Never wait for input. sudo is run with -n: when it would need a password to run $INSTALLER, the run stops with exit code 1 instead of waiting, before the download when sudo already says so (sudo -n -l), otherwise at the install step. When SUDO_ASKPASS names a helper, sudo -A asks the helper instead, so the helper must answer without waiting. For schedulers. Alias: -NonInteractive."
  ui_param "--quiet"             "Show only the launch notice, notes and errors. The run log still gets every line. Alias: -Quiet."
  ui_param "--verbose"           "Also show what curl and the installer print when they succeed. Alias: -Verbose."
  ui_param "--help, -h"          "Show this help and exit. Writes no file, contacts nothing. Alias: -Help."
  ui_param "--version"           "Print this script's version and exit. Alias: -Version."
  ui_section "EXAMPLES"
  ui_caption "# 1. Install, or update to the latest stable release"
  ui_cmd "./$SCRIPT_NAME"
  emit "" "" force
  ui_caption "# 2. Preview: look up the latest release and report, change nothing"
  ui_cmd "./$SCRIPT_NAME --dry-run"
  emit "" "" force
  ui_caption "# 3. Follow the LTS channel, with audit and error logs in a folder"
  ui_cmd "./$SCRIPT_NAME --lts --audit-log ./logs/ --error-log ./logs/"
  emit "" "" force
  ui_caption "# 4. Scheduled and unattended (sudo must not need a password)"
  ui_cmd "./$SCRIPT_NAME --non-interactive --quiet \\"
  ui_cmd "    --audit-log ./logs/ --error-log ./logs/ --run-log ./logs/"
  emit "" "" force
  ui_caption "# 5. Pin a version, keep the package, reinstall even if current"
  ui_cmd "./$SCRIPT_NAME --pin 7.6.5 --keep --force"
  emit "" "" force
  ui_caption "# 6. Answer file: export, edit, then run from it"
  ui_cmd "./$SCRIPT_NAME --export-template ./ps7.cfg"
  ui_cmd "./$SCRIPT_NAME --config ./ps7.cfg --audit-log ./logs/"
  emit "" "" force
  ui_caption "# 7. Pipeline: time, outcome and stage of every failed run"
  ui_cmd "grep -h 'outcome=FAILED' ./logs/*-audit.log | cut -d' ' -f1,8,9"
  emit "" "" force
  ui_caption "# 8. Afterwards: which pwsh starts, and its version"
  ui_cmd "command -v pwsh && pwsh --version"
  ui_section "OUTPUT"
  ui_text "Console: the launch notice, then a line per stage (resolve, compare, download, verify-hash, verify-signature, install, confirm). Colour is turned off when the output is redirected or NO_COLOR is set; SCRIPT_UI_COLOR=1 or OMNISSA_UI_COLOR=1 turns it on (for less -R). At the end: the path and version of the pwsh installed, and where the logs are."
  ui_section "LOGGING"
  ui_text "--audit-log: one key=value line per run (time, user, host, script, version, channel, dryRun, outcome, stage, durationSec, detail): on success, at every failure stage and when interrupted. The header is written once and the file is only ever appended to. --error-log: timestamped ERROR lines, with the captured command output as indented DETAIL lines. --run-log: a plain-text copy of the console. Logs never contain colour codes. No password, key or token passes through this script (sudo asks for your password itself), so none can reach a log. Run as root, a log is refused when it is a symbolic link, or when its folder, or a folder above it, can be changed by a user other than root; a folder under /Library/Logs or /var/log is fine."
  ui_section "REQUIREMENTS"
  ui_text "macOS on Apple silicon or Intel, with the stock /bin/bash 3.2 or later and curl, shasum, pkgutil, installer, iconv and sudo, all part of macOS. Network access to aka.ms, api.github.com, github.com and the GitHub download servers."
  ui_text "Run it as yourself: administrator rights are asked for the install step only, by sudo (sudo -A when SUDO_ASKPASS names a helper), which runs $INSTALLER. With --non-interactive, sudo must be able to run it without asking: for example through a sudoers line such as 'ACCOUNT ALL=(root) NOPASSWD: $INSTALLER' for the account that runs the job (such a line lets that account install any package as root), or through SUDO_ASKPASS."
  ui_text "Run as root, from a management tool for example, it does not use sudo, and it uses only files and folders that root alone can change: a cache, log, template or --config file that is a symbolic link, or that another user could change, is refused (the default cache is then left unused, with a note)."
  ui_text "The private temporary folder is made with mktemp -d in TMPDIR, or in /tmp: a TMPDIR that another user owns or may write to is refused (a sticky folder such as /tmp is fine)."
  ui_text "If the file has lost its execute permission (copied without it), run it as: bash ./$SCRIPT_NAME"
  ui_text "Not applicable here, and stated as the house standard asks: secret storage, sign-in modes, target selection and per-item outcomes. The script makes one local change and uses no credentials."
  ui_section "EXIT CODES"
  ui_param "0"   "Installed, upgraded or already current; also --dry-run, --export-template, --help and --version."
  ui_param "1"   "Configuration error, or --non-interactive while sudo needs a password. Nothing was installed."
  ui_param "2"   "The release could not be looked up, or the package or its hashes could not be downloaded."
  ui_param "4"   "A check failed (hash or signature), the installer failed, or Microsoft's package does not report the expected version afterwards."
  ui_param "130" "Interrupted. The audit entry is still written."
  ui_section "ABOUT"
  ui_param "Name"     "$SCRIPT_NAME ($SCRIPT_CANON)"
  ui_param "Version"  "$SCRIPT_VERSION, created $SCRIPT_CREATED"
  ui_param "Author"   "The copyright holder named in the LICENSE file."
  ui_param "Licence"  "$SCRIPT_LICENCE"
  ui_param "Derived"  "Deploy-PowerShell7.ps1, the same author's Windows start-up script for PowerShell 7."
  ui_param "History"  "1.0.0 first port; 2.0.0 rebuilt on the author's script template; 2.0.1 licence; 2.1.0 joined this repository (fixes listed in the script's header); 2.1.1 shellcheck clean, no change to what it does."
  ui_section "DOCUMENTATION"
  ui_text "github.com/PowerShell/PowerShell/releases (the packages and the hashes.sha256 of each release); aka.ms/powershell-release?tag=stable and ?tag=lts; Microsoft Learn, Installing PowerShell on macOS; in this repository, README.md and docs/Getting-Started.md."
  emit "" "" force
}

# ---- argument parsing (D2) ------------------------------------------------------
need_val() {   # need_val SWITCH [VALUE ...]: true when SWITCH is followed by a value
  if [ $# -ge 2 ] && [ -n "$2" ]; then case "$2" in -*) ;; *) return 0 ;; esac; fi
  add_problem "$1: needs a value."; return 1; }
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --help|-h|-Help)                    HELP=1 ;;
      --version|-Version)                 SHOW_VERSION=1 ;;
      --lts|-Lts)                         SETTING_CHANNEL="lts"; SUPPLIED="$SUPPLIED --lts" ;;
      --force|-Force)                     SETTING_FORCE="yes";   SUPPLIED="$SUPPLIED --force" ;;
      --keep|-Keep)                       SETTING_KEEP="yes";    SUPPLIED="$SUPPLIED --keep" ;;
      --dry-run|-DryRun)                  DRY_RUN=1;             SUPPLIED="$SUPPLIED --dry-run" ;;
      --non-interactive|-NonInteractive)  NON_INTERACTIVE=1;     SUPPLIED="$SUPPLIED --non-interactive" ;;
      --quiet|-Quiet)                     QUIET=1;               SUPPLIED="$SUPPLIED --quiet" ;;
      --verbose|-Verbose)                 VERBOSE=1;             SUPPLIED="$SUPPLIED --verbose" ;;
      --save-config|-SaveConfig)          SAVE_CONFIG=1;         SUPPLIED="$SUPPLIED --save-config" ;;
      --allow-plaintext-secrets)                                 SUPPLIED="$SUPPLIED --allow-plaintext-secrets" ;;
      --pin|-PinVersion)        need_val "$@" && { SETTING_PIN="$2";   SUPPLIED="$SUPPLIED --pin"; shift; } ;;
      --cache-dir|-CacheDir)    need_val "$@" && { SETTING_CACHE="$2"; SUPPLIED="$SUPPLIED --cache-dir"; shift; } ;;
      --config|-ConfigFile)     need_val "$@" && { CONFIG_FILE="$2";   SUPPLIED="$SUPPLIED --config"; shift; } ;;
      --export-template|-ExportTemplate) need_val "$@" && { EXPORT_TEMPLATE="$2"; SUPPLIED="$SUPPLIED --export-template"; shift; } ;;
      --audit-log|-AuditLog)    need_val "$@" && { AUDIT_LOG="$2"; SUPPLIED="$SUPPLIED --audit-log"; shift; } ;;
      --error-log|-ErrorLog)    need_val "$@" && { ERROR_LOG="$2"; SUPPLIED="$SUPPLIED --error-log"; shift; } ;;
      --run-log|-RunLog)        need_val "$@" && { RUN_LOG="$2";   SUPPLIED="$SUPPLIED --run-log"; shift; } ;;
      *) add_problem "$1: unknown switch (the PARAMETERS section of --help lists them)." ;;
    esac
    shift
  done
}

# ---- conflicts (must-have 7): reported before any work; silent on a clean command line ----
check_conflicts() {
  local s l
  if is_supplied --pin && is_supplied --lts; then add_conflict "[ignored] --lts: --pin names an exact version, so the channel does not apply."; fi
  if is_supplied --keep && is_supplied --dry-run; then add_conflict "[ignored] --keep: nothing is downloaded under --dry-run."; fi
  if is_supplied --force && is_supplied --dry-run; then add_conflict "[note] --force with --dry-run: reports what a reinstall would do, even when current; installs nothing."; fi
  if is_supplied --save-config && [ -z "$CONFIG_FILE" ]; then add_conflict "[ignored] --save-config: no --config file is named to save into."; fi
  if is_supplied --save-config && is_supplied --dry-run && [ -n "$CONFIG_FILE" ]; then add_conflict "[ignored] --save-config: --dry-run writes no settings."; fi
  if is_supplied --allow-plaintext-secrets; then add_conflict "[ignored] --allow-plaintext-secrets: this script stores no secret."; fi
  if is_supplied --verbose && is_supplied --quiet; then add_conflict "[note] --verbose with --quiet: the captured output goes to the run log only."; fi
  if [ -n "$HELP" ] && is_supplied --quiet; then add_conflict "[note] --quiet: help output is never suppressed."; fi
  if [ -n "$EXPORT_TEMPLATE" ] && [ -z "$HELP" ]; then
    for s in --lts --pin --force --keep --cache-dir --config --save-config --dry-run --non-interactive --verbose; do
      if is_supplied "$s"; then add_conflict "[ignored] $s: --export-template writes the template and exits."; fi
    done
  fi
  while IFS= read -r l; do [ -n "$l" ] && note "$l"; done <<EOF
$CONFLICTS
EOF
  return 0
}

# ---- domain helpers ----------------------------------------------------------------
is_release_version() {   # true for 7.Y.Z with numbers only (no preview or rc suffix)
  local r="${1#7.}" a b
  [ "$r" != "$1" ] || return 1
  a="${r%%.*}"; b="${r#*.}"; [ "$a" != "$r" ] || return 1
  case "$a" in ''|*[!0-9]*) return 1 ;; esac
  case "$b" in ''|*[!0-9]*) return 1 ;; esac
  return 0
}
resolve_via_redirect() {   # GET with -L; the RedirectBot hop does not answer HEAD with a Location
  local url="https://aka.ms/powershell-release?tag=$1" final
  final=$(curl -sS -L -o /dev/null --max-time 25 --max-redirs 6 -A "$UA" -w '%{url_effective}' "$url" 2>/dev/null) || return 1
  case "$final" in */releases/tag/v[0-9]*) printf '%s\n' "${final##*/}"; return 0 ;; esac
  return 1
}
resolve_via_api() {   # stable: the release GitHub marks as latest; lts: the newest LTS macOS package for this CPU
  local json tag
  if [ "$1" = "lts" ]; then
    json=$(curl -fsSL --max-time 60 -A "$UA" "https://api.github.com/repos/$REPO/releases?per_page=30") || return 1
    tag=$(printf '%s' "$json" | grep -o "powershell-lts-7\.[0-9]*\.[0-9]*-$ARCH\.pkg" \
      | sed -e 's/^powershell-lts-//' -e 's/-osx-.*$//' | sort -u -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
    [ -n "$tag" ] && tag="v$tag"
  else
    json=$(curl -fsSL --max-time 20 -A "$UA" "https://api.github.com/repos/$REPO/releases/latest") || return 1
    tag=$(printf '%s' "$json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\(v[0-9][0-9.]*\)".*/\1/p' | head -n 1)
  fi
  [ -n "$tag" ] || return 1
  printf '%s\n' "$tag"
}
pwsh_version() {   # pwsh_version FILE: the version that pwsh reports (7.6.5, say); nothing if it does not start
  local v
  [ -n "$1" ] && [ -x "$1" ] || return 0
  # update check and telemetry off: asking a version must not contact anything
  v=$(POWERSHELL_UPDATECHECK=Off POWERSHELL_TELEMETRY_OPTOUT=1 "$1" -NoProfile -NoLogo -NonInteractive \
      -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null | tr -d '\r' | awk 'NR == 1 { print $1 }')
  case "$v" in [0-9]*.[0-9]*) printf '%s' "$v" ;; esac
  return 0
}
real_path() {   # real_path FILE: FILE with every symbolic link followed and its folder made physical
  local p="$1" t n=0 d
  while [ -L "$p" ] && [ "$n" -lt 40 ]; do
    t="$(readlink "$p")" || break
    case "$t" in /*) p="$t" ;; *) p="${p%/*}/$t" ;; esac
    n=$((n+1))
  done
  d="${p%/*}"; [ "$d" = "$p" ] && d="."
  d="$(cd -P "$d" 2>/dev/null && pwd -P)" || { printf '%s' "$p"; return 0; }
  printf '%s/%s' "${d%/}" "${p##*/}"
}
pkg_ids() {   # the package receipts for this channel, most specific first
  # The LTS package's receipt id is not proven; both are looked at, the -lts one first.
  if [ "$SETTING_CHANNEL" = "lts" ] && [ -z "$SETTING_PIN" ]; then printf '%s\n' com.microsoft.powershell-lts com.microsoft.powershell
  else printf '%s\n' com.microsoft.powershell; fi
}
pkg_pwsh() {   # pkg_pwsh ID: the pwsh that package receipt installed, as an absolute path
  local id="$1" pinfo vol loc rel
  pinfo="$(pkgutil --pkg-info "$id" 2>/dev/null)" || return 1
  vol="$(printf '%s\n' "$pinfo" | sed -n 's/^volume: *//p')"
  loc="$(printf '%s\n' "$pinfo" | sed -n 's/^location: *//p')"
  # The receipt lists usr/local/bin/pwsh (a link another package can repoint) and the binary itself.
  rel="$(pkgutil --files "$id" 2>/dev/null | awk '
    a == "" && /(^|\/)microsoft\/powershell\/[^\/]+\/pwsh$/ { a = $0 }
    b == "" && /(^|\/)pwsh$/ { b = $0 }
    END { if (a != "") print a; else if (b != "") print b }')"
  [ -n "$rel" ] || return 1
  printf '%s' "/$vol/$loc/$rel" | sed 's#//*#/#g'
}
detect_installed() {   # sets PKG_ID PKG_PWSH PKG_VER (Microsoft's package) and PATH_PWSH PATH_VER (pwsh on the PATH)
  local id p
  PKG_ID=""; PKG_PWSH=""; PKG_VER=""; PATH_PWSH=""; PATH_VER=""
  for id in $(pkg_ids); do
    pkgutil --pkg-info "$id" >/dev/null 2>&1 || continue
    PKG_ID="$id"
    p="$(pkg_pwsh "$id")" || p=""
    if [ -z "$p" ] && [ -x "$PKG_ROOT/7/pwsh" ]; then p="$PKG_ROOT/7/pwsh"; fi
    if [ -n "$p" ] && [ -x "$p" ]; then PKG_PWSH="$p"; PKG_VER="$(pwsh_version "$p")"; fi
    break
  done
  p="$(command -v pwsh 2>/dev/null)" || p=""
  [ -n "$p" ] || return 0
  PATH_PWSH="$(real_path "$p")"
  if [ -n "$PKG_PWSH" ] && [ "$PATH_PWSH" = "$(real_path "$PKG_PWSH")" ]; then PATH_VER="$PKG_VER"
  else PATH_VER="$(pwsh_version "$p")"; fi
  return 0
}
path_note() {   # a note, once per run, when typing pwsh starts a copy other than Microsoft's package
  [ -n "$PATH_PWSH" ] && [ -n "$PKG_PWSH" ] && [ -z "$PATH_NOTED" ] || return 0
  [ "$PATH_PWSH" = "$(real_path "$PKG_PWSH")" ] && return 0
  PATH_NOTED=1
  note "[note] Typing pwsh starts $PATH_PWSH (${PATH_VER:-it reports no version}), not Microsoft's package ($PKG_PWSH) that this script installs and updates. If Homebrew installed that copy, update it with brew upgrade powershell, or remove it with brew uninstall powershell."
}
ver_ge() {   # ver_ge A B -> 0 if A >= B (dotted numerics; 7.6.0-rc.1 counts as older than 7.6.0)
  local a="${1%%-*}" b="${2%%-*}"
  if [ "$a" = "$b" ]; then
    case "$1" in *-*) case "$2" in *-*) return 0 ;; *) return 1 ;; esac ;; esac
    return 0
  fi
  [ "$(printf '%s\n%s\n' "$b" "$a" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -n 1)" = "$a" ]
}
decode_hashes() {   # decode_hashes FILE: hashes.sha256 as plain lines (Microsoft's is UTF-16LE + BOM + CRLF)
  local f="$1" bom nul
  bom="$(head -c 2 "$f" | od -An -tx1 | tr -d ' \n')"
  nul="$(LC_ALL=C tr -cd '\000' < "$f" | wc -c | tr -d ' ')"
  case "$bom" in
    fffe|feff) iconv -f UTF-16 -t UTF-8 "$f" | LC_ALL=C tr -d '\r' ;;   # the BOM gives the byte order and is dropped
    *) if [ "$nul" -gt 0 ]; then iconv -f UTF-16LE -t UTF-8 "$f" | LC_ALL=C tr -d '\r'
       else LC_ALL=C tr -d '\r' < "$f"; fi ;;
  esac
}
published_hash() {   # published_hash FILE NAME: the SHA-256 listed for exactly NAME, upper case; nothing if absent
  awk -v p="$2" '{
    f = $NF; sub(/^\*/, "", f)
    if (f != p) next
    if (match($0, /[0-9A-Fa-f]+/) && RLENGTH == 64) { print toupper(substr($0, RSTART, RLENGTH)); exit }
  }' "$1"
}
config_safe() {   # config_safe FILE: run as root, true when FILE is not a link and only root can change it or its folder
  local d="${1%/*}"; [ "$d" = "$1" ] && d="."; [ -z "$d" ] && d="/"
  if [ -L "$1" ]; then SAFE_WHY="it is a symbolic link"; return 1; fi
  folder_safe "$d" || return 1
  if [ -e "$1" ]; then owned_safely "$1" || return 1; fi
  return 0; }
sudo_allows() {   # sudo_allows PACKAGE: true when sudo -n may run the install command without a password; runs nothing
  sudo -n -l "$INSTALLER" -pkg "$1" -target / >/dev/null 2>&1; }
# keep_package: the verified package, copied from the private folder into the cache as a new file
# that is then renamed into place; sets KEPT to where it is. Nothing is written through a link.
keep_package() { KEPT=""
  [ -n "$CACHED" ] && [ -s "$PKGPATH" ] || return 1
  if [ -n "$FROM_CACHE" ]; then KEPT="$CACHED"; return 0; fi
  if [ -L "$CACHED" ] || { [ -e "$CACHED" ] && [ ! -f "$CACHED" ]; }; then
    note "[note] the package was not kept: $CACHED is a symbolic link or not a plain file."; return 1; fi
  TMP_KEEP="$(mktemp "$SETTING_CACHE/.$PKG.XXXXXX")" || { TMP_KEEP=""; return 1; }
  if cp "$PKGPATH" "$TMP_KEEP" 2>/dev/null && mv -f "$TMP_KEEP" "$CACHED"; then TMP_KEEP=""; KEPT="$CACHED"; return 0; fi
  rm -f "$TMP_KEEP"; TMP_KEEP=""; note "[note] the package could not be copied into the cache ($SETTING_CACHE)."; return 1; }
fail_config() {   # every problem found so far, then stop: nothing was attempted
  local l first=""
  STAGE="config"; OUTCOME="FAILED"
  while IFS= read -r l; do [ -n "$l" ] || continue; [ -z "$first" ] && first="$l"; err config "$l"; done <<EOF
$PROBLEMS
EOF
  DETAIL="configuration error, nothing attempted: $first"
  exit "$EX_CONFIG"
}
finish() {   # finish DETAIL: a successful end; saves the settings when asked, names the logs, exits 0
  OUTCOME="SUCCESS"; DETAIL="$1"
  if [ -n "$SAVE_CONFIG" ] && [ -n "$CONFIG_FILE" ] && [ -z "$DRY_RUN" ]; then save_config; fi
  ok "done."
  [ -n "$AUDIT_PATH" ]   && info "audit log: $AUDIT_PATH"
  [ -n "$ERROR_PATH" ]   && info "error log: $ERROR_PATH"
  [ -n "$RUN_LOG_PATH" ] && info "run log:   $RUN_LOG_PATH"
  exit "$EX_OK"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  local l c p
  MY_UID="$(id -u)"
  parse_args "$@"
  ui_init
  show_launch_notice
  trap audit_finalize EXIT
  trap on_interrupt HUP INT TERM

  if [ -n "$SHOW_VERSION" ]; then
    NO_AUDIT=1
    # a switch that was not understood is named, as under --help
    while IFS= read -r l; do [ -n "$l" ] && note "[ignored] $l"; done <<EOF
$PROBLEMS
EOF
    printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit "$EX_OK"
  fi
  if [ -n "$HELP" ]; then
    NO_AUDIT=1
    # a switch that was not understood is named, and the help shown anyway
    while IFS= read -r l; do [ -n "$l" ] && add_conflict "[ignored] $l"; done <<EOF
$PROBLEMS
EOF
    check_conflicts; show_help; exit "$EX_OK"
  fi
  [ -n "$PROBLEMS" ] && fail_config
  if [ -n "$EXPORT_TEMPLATE" ]; then
    check_conflicts
    if [ -n "$RUN_LOG" ]; then
      RUN_LOG_PATH="$(resolve_log_path "$RUN_LOG" "${SCRIPT_NAME%.sh}-run.log")" || { l="$RUN_LOG_PATH"; RUN_LOG_PATH=""; die "$EX_CONFIG" logs "--run-log: $l"; }
      probe_writable "$RUN_LOG_PATH" || { l="$RUN_LOG_PATH"; RUN_LOG_PATH=""; die "$EX_CONFIG" logs "log path is not writable: $l"; }
      open_run_log
    fi
    export_template "$EXPORT_TEMPLATE"
    [ -n "$AUDIT_LOG" ] && info "audit log: $AUDIT_LOG"
    [ -n "$RUN_LOG_PATH" ] && info "run log:   $RUN_LOG_PATH"
    exit "$EX_OK"
  fi

  # --- configuration chain: switch > config > default ---
  if [ -n "$CONFIG_FILE" ]; then
    # run as root, the file that says where root writes must be one that only root can change
    if [ "$MY_UID" = "0" ] && ! config_safe "$CONFIG_FILE"; then
      add_problem "--config: run as root, '$CONFIG_FILE' is not used: $SAFE_WHY."; fail_config
    fi
    if [ ! -e "$CONFIG_FILE" ] && [ -n "$SAVE_CONFIG" ]; then info "config: $CONFIG_FILE does not exist yet; --save-config will create it"
    else load_config "$CONFIG_FILE"; fi
  fi
  # a typed --lts wins over PIN_VERSION from the file, as every typed switch wins over the file
  if is_supplied --lts && [ -n "$PIN_FROM_FILE" ]; then
    add_conflict "[ignored] PIN_VERSION=$PIN_FROM_FILE in $CONFIG_FILE: --lts was typed, and a typed switch wins over the file."
    SETTING_PIN=""
  fi
  [ -n "$SETTING_CACHE" ] && CACHE_EXPLICIT=1
  [ -z "$SETTING_CHANNEL" ] && SETTING_CHANNEL="stable"
  # Without HOME (a LaunchDaemon job, say) there is no default cache, and the package lives only in
  # the private temporary folder: never a fixed folder under /var/tmp, which every user can write to.
  if [ -z "$SETTING_CACHE" ] && [ -n "${HOME:-}" ]; then SETTING_CACHE="$HOME/Library/Caches/PowerShell7Install"; fi
  [ -z "$SETTING_KEEP" ]    && SETTING_KEEP="no"
  [ -z "$SETTING_FORCE" ]   && SETTING_FORCE="no"
  SETTING_CACHE="$(expand_tilde "$SETTING_CACHE")"
  SETTING_PIN="${SETTING_PIN#v}"

  # --- validation: everything before any network or filesystem work ---
  [ "$(uname -s)" = "Darwin" ] || add_problem "This script runs on macOS only (found $(uname -s))."
  for c in curl shasum pkgutil iconv; do
    command -v "$c" >/dev/null 2>&1 || add_problem "Required tool not found: $c."
  done
  [ -x "$INSTALLER" ] || add_problem "Required tool not found: $INSTALLER."
  if [ "$MY_UID" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then add_problem "Required tool not found: sudo (the install step needs it unless the script runs as root)."; fi
  case "$(uname -m)" in
    arm64)  ARCH="osx-arm64" ;;
    # a shell under Rosetta 2 reports x86_64; the Mac itself is Apple silicon
    x86_64) if [ "$(sysctl -in sysctl.proc_translated 2>/dev/null)" = "1" ]; then ARCH="osx-arm64"; ROSETTA=1; else ARCH="osx-x64"; fi ;;
    *) add_problem "Unsupported CPU architecture: $(uname -m)." ;;
  esac
  case "$SETTING_CHANNEL" in stable|lts) ;; *) add_problem "CHANNEL must be 'stable' or 'lts' (got '$SETTING_CHANNEL')." ;; esac
  if [ -n "$SETTING_PIN" ] && ! is_release_version "$SETTING_PIN"; then
    add_problem "--pin: '$SETTING_PIN' is not a PowerShell 7 release of the form 7.Y.Z (previews are not supported)."
  fi
  case "$SETTING_KEEP" in yes|no) ;; *) add_problem "KEEP_PKG must be yes or no (got '$SETTING_KEEP')." ;; esac
  # the cache: one that was named must be usable; the default one is left out, with a note, if not
  if [ -n "$SETTING_CACHE" ]; then
    if prepare_folder "$SETTING_CACHE" && probe_writable "$SETTING_CACHE/.probe"; then rm -f "$SETTING_CACHE/.probe"
    else
      [ -n "$SAFE_WHY" ] || SAFE_WHY="it is not writable"
      if [ -n "$CACHE_EXPLICIT" ]; then
        add_problem "--cache-dir: '$SETTING_CACHE' cannot be used: $SAFE_WHY (the cache must be a folder you can write to that no other user can change)."
      else
        add_conflict "[note] cache: $SETTING_CACHE is not used: $SAFE_WHY. The package is downloaded to a private temporary folder and removed afterwards."
        SETTING_CACHE=""
      fi
    fi
  fi
  if [ -z "$SETTING_CACHE" ] && [ "$SETTING_KEEP" = "yes" ] && [ -z "$DRY_RUN" ]; then
    if is_supplied --keep; then l="--keep"; else l="KEEP_PKG=yes"; fi
    add_conflict "[ignored] $l: there is no cache folder to keep the package in."
  fi
  # The private folder is made in TMPDIR. Nobody else may be able to rename it away and put another
  # in its place: a sticky folder such as /tmp is fine, one that another user owns or may write to is not.
  WORK_BASE="${TMPDIR:-/tmp}"; WORK_BASE="${WORK_BASE%/}"; [ -n "$WORK_BASE" ] || WORK_BASE="/"
  if ! folder_safe "$WORK_BASE" above; then
    add_problem "TMPDIR: '$WORK_BASE' cannot hold the private temporary folder: $SAFE_WHY. Unset TMPDIR, or point it at a folder that no other user can change."
  fi
  if [ "$MY_UID" -ne 0 ] && [ -n "${SUDO_ASKPASS:-}" ] && { [ ! -f "$SUDO_ASKPASS" ] || [ ! -x "$SUDO_ASKPASS" ]; }; then
    add_conflict "[ignored] SUDO_ASKPASS: '$SUDO_ASKPASS' is not an executable file, so sudo is run without it."
  fi
  [ -n "$PROBLEMS" ] && fail_config
  check_conflicts
  if [ "$MY_UID" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    note "[note] Running as root through sudo. Run it as yourself instead: it asks sudo for the install step only, and can then use your own cache and log folders."
  fi

  # --- logs: resolve, create parents, probe BEFORE work (run as root: folders only root can change) ---
  STAGE="logs"
  AUDIT_PATH="$(resolve_log_path "$AUDIT_LOG" "${SCRIPT_NAME%.sh}-audit.log")" || { l="$AUDIT_PATH"; AUDIT_PATH=""; die "$EX_CONFIG" logs "--audit-log: $l"; }
  ERROR_PATH="$(resolve_log_path "$ERROR_LOG" "${SCRIPT_NAME%.sh}-errors.log")" || { l="$ERROR_PATH"; ERROR_PATH=""; die "$EX_CONFIG" logs "--error-log: $l"; }
  RUN_LOG_PATH="$(resolve_log_path "$RUN_LOG" "${SCRIPT_NAME%.sh}-run.log")" || { l="$RUN_LOG_PATH"; RUN_LOG_PATH=""; die "$EX_CONFIG" logs "--run-log: $l"; }
  for p in "$AUDIT_PATH" "$ERROR_PATH" "$RUN_LOG_PATH"; do
    [ -n "$p" ] && { probe_writable "$p" || die "$EX_CONFIG" logs "log path is not writable: $p"; }
  done
  open_run_log
  info "macOS $(sw_vers -productVersion 2>/dev/null)  arch=$ARCH  channel=$SETTING_CHANNEL  cache=${SETTING_CACHE:-none}"
  [ -n "$ROSETTA" ] && info "this shell runs under Rosetta 2; the Apple silicon package is used"
  if [ -z "$SETTING_CACHE" ] && [ -z "${HOME:-}" ]; then info "no cache: HOME is not set and no --cache-dir is named; the package lives only in a private temporary folder"; fi

  # =========================== WORK =========================================
  # --- resolve ---
  STAGE="resolve"
  local TAG="" VER TARGET_DESC
  if [ -n "$SETTING_PIN" ]; then
    TAG="v$SETTING_PIN"; TARGET_DESC="pinned"; info "pinned version: $TAG (no lookup)"
  else
    TARGET_DESC="latest $SETTING_CHANNEL"
    if TAG=$(resolve_via_redirect "$SETTING_CHANNEL"); then info "$TARGET_DESC via the aka.ms redirect: $TAG"
    else
      info "aka.ms redirect lookup failed; falling back to the GitHub API"
      TAG=$(resolve_via_api "$SETTING_CHANNEL") || die "$EX_SETUP" resolve "could not determine the $TARGET_DESC release (offline, or both lookups failed). Try again later, or name a version with --pin."
      info "$TARGET_DESC via the GitHub API: $TAG"
    fi
  fi
  VER="${TAG#v}"
  is_release_version "$VER" || die "$EX_SETUP" resolve "the lookup returned '$TAG', which is not a PowerShell 7 release"

  # --- compare ---
  STAGE="compare"
  local INSTALLED=""
  detect_installed
  if [ -n "$PKG_VER" ]; then
    INSTALLED="$PKG_VER"; info "installed: PowerShell $PKG_VER, Microsoft's package ($PKG_PWSH)"
  else
    [ -n "$PKG_ID" ] && note "[note] Microsoft's package is recorded as installed ($PKG_ID), but its pwsh is missing or does not start, so it counts as not installed."
    if [ -n "$PATH_VER" ]; then INSTALLED="$PATH_VER"; info "installed: PowerShell $PATH_VER at $PATH_PWSH (not Microsoft's package)"
    elif [ -z "$PKG_ID" ]; then info "installed: no PowerShell found"; fi
  fi
  path_note
  if [ -n "$INSTALLED" ] && [ "$SETTING_FORCE" = "no" ] && ver_ge "$INSTALLED" "$VER"; then
    ok "current: installed $INSTALLED >= $TARGET_DESC $VER - nothing to do"
    finish "current installed=$INSTALLED target=$VER"
  fi
  if [ -n "$INSTALLED" ] && ver_ge "$INSTALLED" "$VER"; then info "reinstall (--force): installed $INSTALLED, $TARGET_DESC $VER"
  else info "upgrade needed: installed ${INSTALLED:-none} -> $VER"; fi

  local BASE SUDO_CMD="" NOPW
  if [ "$SETTING_CHANNEL" = "lts" ] && [ -z "$SETTING_PIN" ]; then PKG="powershell-lts-${VER}-${ARCH}.pkg"; else PKG="powershell-${VER}-${ARCH}.pkg"; fi
  BASE="https://github.com/$REPO/releases/download/$TAG"
  [ -n "$SETTING_CACHE" ] && CACHED="$SETTING_CACHE/$PKG"
  # sudo for the install step only, never for the whole script. An askpass helper is how an
  # unattended run supplies the password, so it is used under --non-interactive as well.
  if [ "$MY_UID" -ne 0 ]; then
    if [ -n "${SUDO_ASKPASS:-}" ] && [ -f "$SUDO_ASKPASS" ] && [ -x "$SUDO_ASKPASS" ]; then SUDO_CMD="sudo -A"
    elif [ -n "$NON_INTERACTIVE" ]; then SUDO_CMD="sudo -n"
    else SUDO_CMD="sudo"; fi
  fi
  NOPW="--non-interactive: sudo needs a password to run $INSTALLER here, so the install cannot run unattended. Run it as root (from a management tool, say), allow $INSTALLER without a password in sudoers (NOPASSWD), set SUDO_ASKPASS to a helper that supplies the password, or run it without --non-interactive."

  if [ -n "$DRY_RUN" ]; then
    info "[dry-run] would download  $BASE/$PKG"
    info "[dry-run] would verify    SHA-256 against $BASE/hashes.sha256"
    info "[dry-run] would verify    signature: $MS_SIGNER"
    info "[dry-run] would install   ${SUDO_CMD:+$SUDO_CMD }$INSTALLER -pkg $PKG -target /"
    if [ "$SUDO_CMD" = "sudo -n" ] && ! sudo_allows "$PKG"; then
      note "[note] --non-interactive: sudo would ask for a password to run $INSTALLER here, so a real run would stop before the download."
    fi
    STAGE="dry-run"
    finish "dry-run installed=${INSTALLED:-none} target=$VER"
  fi

  # --- a private folder (mode 0700, this account's) for the download, the checks and the install ---
  STAGE="download"
  WORK_DIR="$(mktemp -d "${WORK_BASE%/}/$SCRIPT_CANON.XXXXXX")" || { WORK_DIR=""; die "$EX_SETUP" download "cannot create a private temporary folder in $WORK_BASE"; }
  PKGPATH="$WORK_DIR/$PKG"

  # --- privilege: an unattended run must not stop at a password prompt ---
  # sudo is asked about the command it will run (sudo -n -l runs nothing), so that a sudoers rule
  # for the installer alone is enough
  STAGE="privilege"
  if [ "$SUDO_CMD" = "sudo -n" ] && ! sudo_allows "$PKGPATH"; then
    die "$EX_CONFIG" privilege "$NOPW Nothing was downloaded or installed."
  fi

  # --- download (a cached copy is reused, copied into the private folder first; always re-verified) ---
  STAGE="download"
  if [ -n "$CACHED" ] && [ -f "$CACHED" ] && [ ! -L "$CACHED" ] && [ -s "$CACHED" ]; then
    info "reusing cached $PKG (copied to a private folder and checked again there)"
    cp "$CACHED" "$PKGPATH" 2>/dev/null || die "$EX_SETUP" download "could not copy the cached package $CACHED"
    FROM_CACHE=1
  else
    if [ -n "$CACHED" ] && [ -L "$CACHED" ]; then note "[note] cache: $CACHED is a symbolic link, so it is not used."; fi
    info "downloading $PKG ..."
    run_captured download curl -fsSL --proto =https --proto-redir =https --retry 2 --max-time 1800 -A "$UA" -o "$PKGPATH" "$BASE/$PKG" \
      || die "$EX_SETUP" download "download failed for $PKG"
    info "downloaded $(stat -f%z "$PKGPATH") bytes"
  fi

  # --- verify-hash (fail closed; hashes.sha256 is UTF-16LE + BOM + CRLF) ---
  STAGE="verify-hash"
  run_captured verify-hash curl -fsSL --proto =https --proto-redir =https --retry 2 --max-time 60 -A "$UA" -o "$WORK_DIR/hashes.raw" "$BASE/hashes.sha256" \
    || die "$EX_SETUP" verify-hash "could not download hashes.sha256 - refusing to install unverified"
  decode_hashes "$WORK_DIR/hashes.raw" > "$WORK_DIR/hashes.sha256" 2>/dev/null \
    || die "$EX_TOTAL" verify-hash "could not read hashes.sha256 - refusing to install unverified"
  local EXPECTED ACTUAL
  EXPECTED=$(published_hash "$WORK_DIR/hashes.sha256" "$PKG")
  [ -n "$EXPECTED" ] || die "$EX_TOTAL" verify-hash "no published hash for $PKG - refusing to install unverified"
  ACTUAL=$(shasum -a 256 "$PKGPATH" | awk '{print toupper($1)}')
  if [ "$EXPECTED" != "$ACTUAL" ]; then
    rm -f "$PKGPATH"; [ -n "$FROM_CACHE" ] && rm -f "$CACHED"
    die "$EX_TOTAL" verify-hash "SHA-256 MISMATCH for $PKG - deleted, refusing to install" "expected $EXPECTED
actual   $ACTUAL"
  fi
  ok "hash verified ${ACTUAL:0:16}..."

  # --- verify-signature: Apple-issued Developer ID, Microsoft's Team ID, chain to Apple Root CA ---
  STAGE="verify-signature"
  local SIG LEAF
  SIG=$(pkgutil --check-signature "$PKGPATH" 2>&1) || die "$EX_TOTAL" verify-signature "signature check failed - refusing to install" "$SIG"
  case "$SIG" in *"Status: $APPLE_STATUS"*) ;; *)
    die "$EX_TOTAL" verify-signature "the package is not signed with a Developer ID certificate issued by Apple - refusing to install" "$SIG" ;; esac
  # the leaf certificate is entry 1 of the chain pkgutil prints
  LEAF=$(printf '%s\n' "$SIG" | awk 'f == 0 && /^[[:space:]]*1\./ { sub(/^[[:space:]]*1\.[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; f = 1 }')
  [ "$LEAF" = "$MS_SIGNER" ] \
    || die "$EX_TOTAL" verify-signature "package is NOT signed by $MS_SIGNER (it is signed by '${LEAF:-nobody}') - refusing to install" "$SIG"
  case "$SIG" in *"Apple Root CA"*) ;; *)
    die "$EX_TOTAL" verify-signature "the certificate chain does not end at Apple Root CA - refusing to install" "$SIG" ;; esac
  ok "signature verified: $MS_SIGNER"

  # --- install (privileged step only; sudo per command, never whole-script) ---
  STAGE="install"
  info "installing $PKG (administrator rights requested) ..."
  # SUDO_CMD is split into words on purpose ("sudo -n"); it is empty when running as root
  # shellcheck disable=SC2086
  if ! run_captured install $SUDO_CMD "$INSTALLER" -pkg "$PKGPATH" -target /; then
    if keep_package; then l=" The verified package was kept for the next run: $KEPT."; else l=""; fi
    # sudo -n refusing here (a rule for another command let the check pass, or a cached sudo
    # timestamp ran out during the download) is the same stop as before the download
    case "$SUDO_CMD:$RUN_OUT" in "sudo -n:"*"password is required"*) die "$EX_CONFIG" privilege "$NOPW Nothing was installed.$l" ;; esac
    die "$EX_TOTAL" install "the macOS installer failed.$l"
  fi

  # --- confirm: Microsoft's package must now report the version installed ---
  STAGE="confirm"
  hash -r 2>/dev/null || true
  detect_installed
  if [ -n "$PKG_VER" ] && ver_ge "$PKG_VER" "$VER"; then
    ok "INSTALLED PowerShell $PKG_VER at $PKG_PWSH"
  else
    die "$EX_TOTAL" confirm "install finished but Microsoft's package reports '${PKG_VER:-nothing}', expected $VER"
  fi
  path_note
  # the private copy goes with the private folder when the run ends; the cache keeps one only with --keep
  if [ "$SETTING_KEEP" = "yes" ]; then
    if keep_package; then info "kept package: $KEPT"; fi
  elif [ -n "$FROM_CACHE" ]; then rm -f "$CACHED"; fi
  # ==========================================================================
  finish "installed=$PKG_VER previous=${INSTALLED:-none} hash=${ACTUAL:0:16}"
}

main "$@"
