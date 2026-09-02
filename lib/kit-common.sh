#!/usr/bin/env bash
# kit-common.sh - shared primitives for the installer and its tests.
#
# Source this; it defines functions and sets nothing global except the
# transaction array used for rollback.
#
# Three things live here because getting them wrong is how installers eat
# people's configuration:
#
#   1. JSON is always written through jq, UTF-8, no BOM, trailing newline.
#      Hand-assembled JSON is how a config file ends up with a trailing comma
#      that a strict parser (rtk's among them) rejects. Every writer in this kit
#      goes through kit_json_write so the rule cannot be forgotten in one place
#      and remembered in another.
#
#   2. Nothing is overwritten without a timestamped backup first, and every
#      backup is recorded in a transaction so a failure mid-install can put the
#      machine back the way it was.
#
#   3. Dry-run is enforced at the mutation primitives, not at the call sites.
#      A caller cannot forget to check it.
#
# WHY BASH AND NOT A TRANSLITERATION OF THE POWERSHELL:
# The Windows kit hand-rolls JSON reading, argument quoting and hashing because
# PowerShell 5.1 gives it no better option. On Linux those are solved problems -
# jq, arrays, sha256sum - and reimplementing them in bash would be strictly
# worse than either language alone. What ports is the DESIGN (fail closed,
# backup before write, pure planners, honest gates), not the code.

set -o pipefail

# Guard against double-sourcing: these libs source each other freely.
[[ -n "${_KIT_COMMON_SOURCED:-}" ]] && return 0
_KIT_COMMON_SOURCED=1

# --- output -------------------------------------------------------------------
KIT_DRY_RUN="${KIT_DRY_RUN:-0}"
KIT_QUIET="${KIT_QUIET:-0}"

# Colour only when stderr is a terminal. A hook's output is parsed, not read.
if [[ -t 2 ]]; then
  _K_CYAN=$'\033[36m'; _K_GREEN=$'\033[32m'; _K_YELLOW=$'\033[33m'
  _K_RED=$'\033[31m';  _K_GRAY=$'\033[90m'; _K_OFF=$'\033[0m'
else
  _K_CYAN=''; _K_GREEN=''; _K_YELLOW=''; _K_RED=''; _K_GRAY=''; _K_OFF=''
fi

kit_set_mode() {  # kit_set_mode <dryrun 0|1> <quiet 0|1>
  KIT_DRY_RUN="${1:-0}"
  KIT_QUIET="${2:-0}"
}
kit_is_dry_run() { [[ "$KIT_DRY_RUN" == "1" ]]; }

# All diagnostics go to STDERR. stdout is reserved for a script's actual result
# (a hook's JSON, a planner's plan). A log line on stdout corrupts that
# contract, which is exactly how a hook starts silently failing.
_kit_line() {  # _kit_line <tag> <colour> <message>
  [[ "$KIT_QUIET" == "1" ]] && return 0
  local tag="$1" colour="$2"; shift 2
  kit_is_dry_run && tag="$tag dry-run"
  printf '%s[%s]%s %s\n' "$colour" "$tag" "$_K_OFF" "$*" >&2
}
kit_info() { _kit_line 'kit'  "$_K_CYAN"   "$*"; }
kit_ok()   { _kit_line 'ok'   "$_K_GREEN"  "$*"; }
kit_warn() { _kit_line 'warn' "$_K_YELLOW" "$*"; }
kit_fail() { _kit_line 'FAIL' "$_K_RED"    "$*"; }

# An installer that fails should say what to DO, not just what went wrong.
kit_die() {  # kit_die <problem> [action]
  local problem="$1" action="${2:-}"
  printf '%s[FAIL]%s %s\n' "$_K_RED" "$_K_OFF" "$problem" >&2
  [[ -n "$action" ]] && printf '  -> %s\n' "$action" >&2
  return 1
}

# --- dependency probing -------------------------------------------------------
kit_have() { command -v "$1" >/dev/null 2>&1; }

# Fail fast and by name. "jq: command not found" surfacing from line 400 of an
# installer is a worse diagnostic than refusing up front.
kit_require() {  # kit_require <cmd>...
  local missing=()
  local c
  for c in "$@"; do kit_have "$c" || missing+=("$c"); done
  if (( ${#missing[@]} > 0 )); then
    kit_die "required command(s) not found: ${missing[*]}" \
            "Install them first, e.g. 'sudo apt install ${missing[*]}' (Debian/Ubuntu) or the equivalent for your distro."
    return 1
  fi
  return 0
}

# --- JSON ---------------------------------------------------------------------
# Read a JSON file. Prints nothing and returns 1 when the file is missing or
# empty; dies when it exists but does not parse - an unparseable config is a
# situation to stop on, not to overwrite.
kit_json_read() {  # kit_json_read <path>
  local path="$1"
  [[ -f "$path" ]] || return 1
  [[ -s "$path" ]] || return 1
  # Strip a UTF-8 BOM if some other tool wrote one; jq rejects it.
  local raw
  raw="$(sed '1s/^\xEF\xBB\xBF//' "$path")"
  [[ -n "${raw//[[:space:]]/}" ]] || return 1
  if ! printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
    kit_die "$path is not valid JSON" \
            "Fix or move the file, then re-run. The installer will not overwrite a file it cannot parse."
    return 2
  fi
  printf '%s' "$raw"
}

# Write JSON from stdin, pretty-printed, atomically.
#
# Atomic because a hook can fire while an install is mid-write: a reader must
# see either the old file or the new one, never a half-written one. write-then-
# rename gives that, since rename(2) is atomic within a filesystem. The temp
# file is created in the TARGET directory for exactly that reason - /tmp is
# often a different filesystem, and rename across filesystems fails.
kit_json_write() {  # <json on stdin> kit_json_write <path>
  local path="$1"
  local content
  content="$(cat)"
  if ! printf '%s' "$content" | jq -e . >/dev/null 2>&1; then
    kit_die "refusing to write invalid JSON to $path" "This is a bug in the kit."
    return 1
  fi
  if kit_is_dry_run; then kit_info "would write $path"; return 0; fi
  local dir; dir="$(dirname -- "$path")"
  [[ -d "$dir" ]] || mkdir -p -- "$dir"
  local tmp; tmp="$(mktemp "$dir/.kit-json.XXXXXX")" || return 1
  if ! printf '%s' "$content" | jq . > "$tmp"; then
    rm -f -- "$tmp"; return 1
  fi
  chmod 0644 "$tmp"
  mv -f -- "$tmp" "$path"
}

# --- transaction / rollback ---------------------------------------------------
# Every destructive step registers an undo entry. If the install fails, the
# caller invokes kit_txn_undo and the machine goes back to its prior state.
# This is what makes a partial install recoverable instead of a mess.
#
# Entries are "kind<TAB>target<TAB>backup". A tab is used rather than a colon
# because paths contain colons far more often than they contain tabs.
KIT_TXN=()
KIT_TXN_ACTIVE=0

kit_txn_start() { KIT_TXN=(); KIT_TXN_ACTIVE=1; }

kit_txn_register() {  # kit_txn_register <restore|remove> <target> [backup]
  [[ "$KIT_TXN_ACTIVE" == "1" ]] || return 0
  local kind="$1" target="$2" backup="${3:-}"
  case "$kind" in
    restore|remove) ;;
    *) kit_die "invalid undo kind '$kind'" "This is a bug in the kit."; return 1 ;;
  esac
  KIT_TXN+=("${kind}"$'\t'"${target}"$'\t'"${backup}")
}

kit_txn_count() { printf '%s' "${#KIT_TXN[@]}"; }

kit_txn_undo() {
  if (( ${#KIT_TXN[@]} == 0 )); then kit_info 'nothing to roll back'; return 0; fi
  # Unwind newest-first so nested creations come apart in the right order.
  local i entry kind target backup
  for (( i = ${#KIT_TXN[@]} - 1; i >= 0; i-- )); do
    entry="${KIT_TXN[$i]}"
    IFS=$'\t' read -r kind target backup <<< "$entry"
    if [[ "$kind" == "restore" && -n "$backup" && -f "$backup" ]]; then
      if cp -f -- "$backup" "$target" 2>/dev/null; then
        kit_ok "rolled back: restored $target"
      else
        kit_warn "rollback step failed for $target"
      fi
    elif [[ "$kind" == "remove" && -e "$target" ]]; then
      if rm -rf -- "$target" 2>/dev/null; then
        kit_ok "rolled back: removed $target"
      else
        kit_warn "rollback step failed for $target"
      fi
    fi
  done
  KIT_TXN=()
}

# --- backup-before-write ------------------------------------------------------
# Prints the backup path on stdout, or nothing when there was no file to back up.
kit_backup_file() {  # kit_backup_file <path>
  local path="$1"
  if [[ ! -e "$path" ]]; then
    # Nothing to preserve, but the file is about to exist - so registering a
    # 'remove' undo is what makes rollback able to clean up after us.
    kit_txn_register remove "$path"
    return 0
  fi
  local stamp backup n
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="${path}.bak-${stamp}"
  n=1
  while [[ -e "$backup" ]]; do backup="${path}.bak-${stamp}-${n}"; n=$((n+1)); done
  if kit_is_dry_run; then
    kit_info "would back up $path -> $(basename -- "$backup")"
    printf '%s' "$backup"; return 0
  fi
  cp -p -- "$path" "$backup" || { kit_die "could not back up $path"; return 1; }
  kit_txn_register restore "$path" "$backup"
  kit_info "backed up $(basename -- "$path") -> $(basename -- "$backup")"
  printf '%s' "$backup"
}

# Prints one of: unchanged | created | updated
kit_copy_file() {  # kit_copy_file <source> <destination> [mode]
  local src="$1" dst="$2" mode="${3:-0644}"
  if [[ ! -f "$src" ]]; then
    kit_die "kit file missing: $src" "The kit tree is incomplete. Re-clone the repository and re-run."
    return 1
  fi
  local existed=0
  [[ -e "$dst" ]] && existed=1
  if (( existed )); then
    # Compare before touching. An identical file must not produce a spurious
    # .bak on every re-run; that is how a user's directory fills with noise and
    # they stop trusting the backups that matter.
    local a b
    a="$(sha256sum < "$src" | cut -d' ' -f1)"
    b="$(sha256sum < "$dst" 2>/dev/null | cut -d' ' -f1)"
    if [[ -n "$a" && "$a" == "$b" ]]; then printf 'unchanged'; return 0; fi
    kit_backup_file "$dst" >/dev/null || return 1
  else
    kit_txn_register remove "$dst"
  fi
  if kit_is_dry_run; then
    (( existed )) && { kit_info "would update $dst"; printf 'updated'; } \
                  || { kit_info "would create $dst"; printf 'created'; }
    return 0
  fi
  local dir; dir="$(dirname -- "$dst")"
  [[ -d "$dir" ]] || mkdir -p -- "$dir"
  install -m "$mode" -- "$src" "$dst" || { kit_die "could not write $dst"; return 1; }
  (( existed )) && printf 'updated' || printf 'created'
}

kit_mkdir() {  # kit_mkdir <path>...
  local p
  for p in "$@"; do
    [[ -d "$p" ]] && continue
    if kit_is_dry_run; then kit_info "would create directory $p"; continue; fi
    mkdir -p -- "$p" || { kit_die "could not create $p"; return 1; }
    kit_txn_register remove "$p"
  done
}

# --- credential safety --------------------------------------------------------
# The installer copies kit-owned files INTO ~/.claude. It must never read or
# copy anything that carries identity or session state. This is a hard
# assertion rather than a convention, so a future edit that adds a careless
# `cp -r` of a whole directory fails loudly instead of quietly exfiltrating
# credentials into a backup or a repo.
KIT_FORBIDDEN_NAMES=(
  '.credentials.json' 'credentials.json' '.claude.json' 'auth.json'
  'token.json' '.env' 'id_rsa' 'id_ed25519' 'session.json' 'history.jsonl'
)
KIT_FORBIDDEN_DIRS=(
  'projects' 'todos' 'statsig' 'shell-snapshots' 'file-history' 'ide'
  'sessions' 'session-env' 'paste-cache'
)

kit_assert_safe_to_copy() {  # kit_assert_safe_to_copy <path>
  local path="$1"
  local leaf; leaf="$(basename -- "$path")"
  leaf="${leaf,,}"
  local n
  for n in "${KIT_FORBIDDEN_NAMES[@]}"; do
    if [[ "$leaf" == "$n" ]]; then
      kit_die "refusing to copy credential/session file: $path" \
              "This is a bug in the installer. It must only copy kit-owned files."
      return 1
    fi
  done
  local norm="${path,,}"
  local d
  for d in "${KIT_FORBIDDEN_DIRS[@]}"; do
    if [[ "$norm" == *"/.claude/${d}/"* ]]; then
      kit_die "refusing to touch Claude session state: $path" \
              "This is a bug in the installer. Session/state directories are off limits."
      return 1
    fi
  done
  return 0
}

# --- paths --------------------------------------------------------------------
# Respect XDG/CLAUDE_CONFIG_DIR rather than hardcoding ~/.claude. A user who has
# moved their config should not get a second one silently created.
kit_claude_dir() {
  if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then printf '%s' "$CLAUDE_CONFIG_DIR"
  else printf '%s' "$HOME/.claude"; fi
}

# Resolve the kit root from a script's own location, following symlinks. A hook
# is invoked by absolute path from settings.json, so $0-relative resolution is
# the only thing that works; $PWD is the user's project, not the kit.
kit_root_from() {  # kit_root_from <script path, usually ${BASH_SOURCE[0]}>
  local src="$1" dir
  while [[ -L "$src" ]]; do
    dir="$(cd -P "$(dirname -- "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ "$src" != /* ]] && src="$dir/$src"
  done
  cd -P "$(dirname -- "$src")" && pwd
}
