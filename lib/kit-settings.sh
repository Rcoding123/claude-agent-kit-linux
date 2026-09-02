#!/usr/bin/env bash
# kit-settings.sh - safe, reversible merging of kit configuration into a user's
# ~/.claude.
#
# Invariants:
#   - The user's settings.json is never overwritten without a backup first.
#   - Only kit-owned hook entries are added or removed. Every other key,
#     including hooks the kit did not write, is preserved untouched.
#   - Re-running changes nothing (idempotent) and says so.
#   - Every mutation is reported specifically: "added X", not "updated".
#   - A settings.json that cannot be parsed aborts rather than being replaced
#     with a fresh one. Someone's whole configuration is not an acceptable
#     casualty of a parse error.
#
# The kit's block inside a shared CLAUDE.md is delimited by sentinels so
# uninstall can excise exactly what install added, and not a line more.
#
# Kit hooks are identified by a MARKER substring in their command. That is what
# makes "remove exactly our own entries" possible without a manifest that could
# drift out of sync with reality.

set -o pipefail

[[ -n "${_KIT_SETTINGS_SOURCED:-}" ]] && return 0
_KIT_SETTINGS_SOURCED=1

_ks_dir="$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/kit-common.sh
source "$_ks_dir/kit-common.sh"

KIT_MD_BEGIN='<!-- BEGIN CLAUDE-AGENT-KIT -->'
KIT_MD_END='<!-- END CLAUDE-AGENT-KIT -->'

# --- hook helpers -------------------------------------------------------------
# The command Claude Code will run for a kit hook.
#
# $CLAUDE_PROJECT_DIR is NOT used: these are USER-level hooks installed once per
# machine and they must resolve to the kit's own copy under ~/.claude/hooks,
# whatever project is open. An absolute path is the only thing that always
# works, including when the hook fires with a working directory the kit has
# never seen.
kit_hook_command() {  # kit_hook_command <claude dir> <script>
  printf '%s/hooks/%s' "$1" "$2"
}

kit_hook_present() {  # kit_hook_present <settings file> <event> <marker>
  local file="$1" event="$2" marker="$3"
  [[ -f "$file" ]] || return 1
  jq -e --arg e "$event" --arg m "$marker" \
    '((.hooks[$e] // []) | map((.hooks // [])[] | .command // "")
      | flatten | any(contains($m)))' "$file" >/dev/null 2>&1
}

# Add a kit hook entry if it is not already there. Prints 'added' or
# 'already-present'.
#
# --first puts the entry at the HEAD of the event list. A guard-style hook must
# run before RTK's rewrite hook, otherwise RTK rewrites the command and the
# guard inspects something the user never typed.
kit_hook_add() {  # kit_hook_add <settings file> <event> <matcher> <command> <marker> [--first]
  local file="$1" event="$2" matcher="$3" command="$4" marker="$5" first="${6:-}"
  if kit_hook_present "$file" "$event" "$marker"; then
    printf 'already-present'; return 0
  fi
  local timeout=60
  local tmp; tmp="$(mktemp)"
  local pos='after'
  [[ "$first" == '--first' ]] && pos='before'

  # `.hooks[$e] // []` creates the event list on demand, so a settings.json with
  # no hooks key at all works exactly like one that has hooks for other events.
  if ! jq --arg e "$event" --arg m "$matcher" --arg c "$command" \
          --argjson t "$timeout" --arg pos "$pos" \
     '.hooks //= {}
      | .hooks[$e] //= []
      | ({matcher: $m, hooks: [{type: "command", command: $c, timeout: $t}]}) as $entry
      | .hooks[$e] = (if $pos == "before" then [$entry] + .hooks[$e] else .hooks[$e] + [$entry] end)' \
     "$file" > "$tmp" 2>/dev/null; then
    rm -f -- "$tmp"; kit_die "could not add the $event hook to $file"; return 1
  fi
  mv -f -- "$tmp" "$file"
  printf 'added'
}

# Remove every kit hook entry whose command contains $marker. Prints the number
# removed. Non-kit entries are never touched - that is the entire contract of
# this function, and the uninstall test asserts it.
kit_hook_remove() {  # kit_hook_remove <settings file> <event> <marker>
  local file="$1" event="$2" marker="$3"
  [[ -f "$file" ]] || { printf '0'; return 0; }
  local before after tmp
  before="$(jq --arg e "$event" '(.hooks[$e] // []) | length' "$file" 2>/dev/null)"
  [[ "$before" =~ ^[0-9]+$ ]] || { printf '0'; return 0; }
  tmp="$(mktemp)"
  if ! jq --arg e "$event" --arg m "$marker" \
     'if (.hooks | type) == "object" and (.hooks | has($e)) then
        .hooks[$e] = [ .hooks[$e][]
          | select( ((.hooks // []) | map(.command // "") | any(contains($m))) | not ) ]
        | if (.hooks[$e] | length) == 0 then del(.hooks[$e]) else . end
        | if (.hooks | length) == 0 then del(.hooks) else . end
      else . end' \
     "$file" > "$tmp" 2>/dev/null; then
    rm -f -- "$tmp"; printf '0'; return 0
  fi
  after="$(jq --arg e "$event" '(.hooks[$e] // []) | length' "$tmp" 2>/dev/null)"
  [[ "$after" =~ ^[0-9]+$ ]] || after=0
  mv -f -- "$tmp" "$file"
  printf '%s' "$(( before - after ))"
}

# --- CLAUDE.md ----------------------------------------------------------------
kit_md_present() {  # kit_md_present <file>
  [[ -f "$1" ]] || return 1
  grep -qF "$KIT_MD_BEGIN" "$1" 2>/dev/null && return 0
  # Also treat an unsentinelled marker as present, so a machine set up by an
  # older installer does not get the rules appended a second time.
  grep -qF 'CLAUDE-AGENT-KIT' "$1" 2>/dev/null
}

# Install or refresh the kit rules inside the user's global CLAUDE.md.
# Prints: created | appended | already-present
kit_md_merge() {  # kit_md_merge <target> <source>
  local target="$1" source="$2"
  if [[ ! -f "$source" ]]; then
    kit_die "kit CLAUDE.md source missing: $source" "Re-clone the repository."
    return 1
  fi
  if [[ ! -f "$target" ]]; then
    kit_txn_register remove "$target"
    if kit_is_dry_run; then kit_info "would create $target"; printf 'created'; return 0; fi
    mkdir -p -- "$(dirname -- "$target")"
    { printf '%s\n' "$KIT_MD_BEGIN"; cat "$source"; printf '%s\n' "$KIT_MD_END"; } > "$target"
    printf 'created'; return 0
  fi
  if kit_md_present "$target"; then printf 'already-present'; return 0; fi
  kit_backup_file "$target" >/dev/null || return 1
  if kit_is_dry_run; then kit_info "would append kit rules to $target"; printf 'appended'; return 0; fi
  { printf '\n'; printf '%s\n' "$KIT_MD_BEGIN"; cat "$source"; printf '%s\n' "$KIT_MD_END"; } >> "$target"
  printf 'appended'
}

# Prints: absent | no-kit-block | removed | removed-empty-file
kit_md_uninstall() {  # kit_md_uninstall <target>
  local target="$1"
  [[ -f "$target" ]] || { printf 'absent'; return 0; }
  grep -qF "$KIT_MD_BEGIN" "$target" 2>/dev/null || { printf 'no-kit-block'; return 0; }
  kit_backup_file "$target" >/dev/null || return 1
  if kit_is_dry_run; then kit_info "would remove kit block from $target"; printf 'removed'; return 0; fi
  local tmp; tmp="$(mktemp)"
  # Delete from BEGIN to END inclusive. Anchored to whole lines so a mention of
  # the sentinel inside the user's own prose cannot trigger it.
  awk -v b="$KIT_MD_BEGIN" -v e="$KIT_MD_END" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip   { print }
  ' "$target" > "$tmp"
  # Collapse the blank line the block leaves behind.
  local body; body="$(sed -e :a -e '/^\n*$/{$d;N;};/\n$/ba' "$tmp")"
  rm -f -- "$tmp"
  if [[ -z "${body//[[:space:]]/}" ]]; then
    rm -f -- "$target"; printf 'removed-empty-file'; return 0
  fi
  printf '%s\n' "$body" > "$target"
  printf 'removed'
}

# --- top-level settings.json merge -------------------------------------------
# A registration is "event<US>matcher<US>script<US>marker<US>first", where <US>
# is ASCII 0x1F (unit separator).
#
# NOT pipe-delimited: a PostToolUse matcher is an alternation like
# "Edit|Write|MultiEdit", so a pipe separator would split the matcher into three
# bogus fields and register a hook that matches nothing. 0x1F cannot appear in
# an event name, a tool matcher, a filename or a path substring.
KIT_SETTINGS_CHANGES=()

kit_settings_merge() {  # kit_settings_merge <settings file> <claude dir> <registration>...
  local file="$1" claude_dir="$2"; shift 2
  KIT_SETTINGS_CHANGES=()

  local existed=1
  if [[ ! -f "$file" ]]; then
    existed=0
  else
    # Refuse to touch a file we cannot parse, rather than replacing it.
    if ! jq -e . "$file" >/dev/null 2>&1; then
      kit_die "$file is not valid JSON" \
              "Fix or move it, then re-run. The installer will not overwrite settings it cannot parse."
      return 1
    fi
  fi

  # Work on a copy so a failure partway through leaves the original alone.
  local staging; staging="$(mktemp)"
  if (( existed )); then cp -- "$file" "$staging"; else printf '{}\n' > "$staging"; fi

  local reg event matcher script marker first cmd res
  local -a pending=()
  for reg in "$@"; do
    IFS=$'\x1f' read -r event matcher script marker first <<< "$reg"
    cmd="$(kit_hook_command "$claude_dir" "$script")"
    local flag=''
    [[ "$first" == '1' ]] && flag='--first'
    res="$(kit_hook_add "$staging" "$event" "$matcher" "$cmd" "$marker" "$flag")" || {
      rm -f -- "$staging"; return 1; }
    [[ "$res" == 'added' ]] && pending+=("added $event hook -> $script (matcher: ${matcher:-<none>})")
  done

  if (( ${#pending[@]} == 0 )); then
    rm -f -- "$staging"
    return 0   # nothing to do; no backup, no write, no noise
  fi

  if kit_is_dry_run; then
    kit_info "would update $file:"
    local c; for c in "${pending[@]}"; do kit_info "  $c"; done
    KIT_SETTINGS_CHANGES=("${pending[@]}")
    rm -f -- "$staging"
    return 0
  fi

  if (( existed )); then kit_backup_file "$file" >/dev/null || { rm -f -- "$staging"; return 1; }
  else kit_txn_register remove "$file"; fi

  jq . < "$staging" | kit_json_write "$file" || { rm -f -- "$staging"; return 1; }
  rm -f -- "$staging"
  KIT_SETTINGS_CHANGES=("${pending[@]}")
  return 0
}

kit_settings_uninstall() {  # kit_settings_uninstall <settings file> <registration>...
  local file="$1"; shift
  KIT_SETTINGS_CHANGES=()
  [[ -f "$file" ]] || return 0
  jq -e . "$file" >/dev/null 2>&1 || {
    kit_warn "$file is not valid JSON; leaving it alone"
    return 0
  }

  local staging; staging="$(mktemp)"; cp -- "$file" "$staging"
  local reg event matcher script marker first n
  local -a pending=()
  for reg in "$@"; do
    IFS=$'\x1f' read -r event matcher script marker first <<< "$reg"
    n="$(kit_hook_remove "$staging" "$event" "$marker")"
    (( n > 0 )) && pending+=("removed $n $event hook entry/entries matching '$marker'")
  done

  if (( ${#pending[@]} == 0 )); then rm -f -- "$staging"; return 0; fi
  if kit_is_dry_run; then
    kit_info "would update $file:"
    local c; for c in "${pending[@]}"; do kit_info "  $c"; done
    KIT_SETTINGS_CHANGES=("${pending[@]}"); rm -f -- "$staging"; return 0
  fi

  kit_backup_file "$file" >/dev/null || { rm -f -- "$staging"; return 1; }
  jq . < "$staging" | kit_json_write "$file" || { rm -f -- "$staging"; return 1; }
  rm -f -- "$staging"
  KIT_SETTINGS_CHANGES=("${pending[@]}")
  return 0
}
