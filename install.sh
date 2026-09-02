#!/usr/bin/env bash
# install.sh - machine installer for claude-agent-kit (Linux).
#
#   install.sh                 install or update
#   install.sh doctor          check what is installed, change nothing
#   install.sh uninstall       remove exactly what this installed
#   install.sh --dry-run       show what would happen
#   install.sh --no-tools      skip downloading rtk/ripgrep
#   install.sh --force         reinstall pinned tools even if present
#
# Design rules, in order of importance:
#
#   1. NOTHING IS OVERWRITTEN WITHOUT A BACKUP. Every destructive step registers
#      an undo entry, so a failure partway through can put the machine back.
#   2. Only kit-owned things are added or removed. A user's own hooks, prose and
#      settings keys are preserved exactly, including on uninstall.
#   3. No sudo. Everything lands under $HOME. An installer that needs root to
#      configure a text editor is an installer that will not be run.
#   4. Fail closed on integrity. A pinned download whose hash does not match is
#      deleted and the install aborts - there is deliberately no "install it
#      anyway" path.

set -uo pipefail

KIT_ROOT="$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$KIT_ROOT/lib/kit-common.sh"
source "$KIT_ROOT/lib/kit-settings.sh"
source "$KIT_ROOT/lib/kit-tools.sh"

MODE='install'
NO_TOOLS=0
FORCE=0

while (( $# > 0 )); do
  case "$1" in
    install|doctor|uninstall) MODE="$1"; shift ;;
    --mode)     MODE="$2"; shift 2 ;;
    --dry-run)  KIT_DRY_RUN=1; shift ;;
    --quiet)    KIT_QUIET=1; shift ;;
    --no-tools) NO_TOOLS=1; shift ;;
    --force)    FORCE=1; shift ;;
    -h|--help)
      sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
      exit 0 ;;
    *) kit_die "unknown argument: $1" "Run with --help."; exit 1 ;;
  esac
done

CLAUDE_DIR="$(kit_claude_dir)"
HOOKS_DIR="$CLAUDE_DIR/hooks"
LIB_DIR="$CLAUDE_DIR/kit-lib"
AGENTS_DIR="$CLAUDE_DIR/agents"
BIN_DIR="$HOME/.local/bin"
SETTINGS="$CLAUDE_DIR/settings.json"
GLOBAL_MD="$CLAUDE_DIR/CLAUDE.md"

# The hooks this kit owns. The marker is what makes "remove exactly ours"
# possible; it must appear in the installed command string.
# Fields: event <US> matcher <US> script <US> marker <US> first
US=$'\x1f'
REGISTRATIONS=(
  "PostToolUse${US}Edit|Write|MultiEdit${US}kit-selffix.sh${US}kit-selffix${US}0"
  "Stop${US}${US}kit-checkpoint.sh${US}kit-checkpoint${US}0"
)

LIB_FILES=(kit-common.sh kit-process.sh kit-gate.sh kit-detect.sh kit-settings.sh kit-tools.sh)
HOOK_FILES=(kit-selffix.sh kit-checkpoint.sh)
AGENT_FILES=(researcher.md fixer.md reviewer.md)

# ==============================================================================
doctor() {
  printf '\n== claude-agent-kit doctor ==\n\n'

  printf 'environment\n'
  printf '  %-22s %s\n' 'kit root'      "$KIT_ROOT"
  printf '  %-22s %s\n' 'claude dir'    "$CLAUDE_DIR"
  printf '  %-22s %s\n' 'arch'          "$(kit_arch)"
  printf '  %-22s %s\n' 'bash'          "${BASH_VERSION%%(*}"

  printf '\nrequired commands\n'
  local c
  for c in bash jq curl sha256sum tar find sed awk; do
    if kit_have "$c"; then printf '  %-22s %s\n' "$c" "$(command -v "$c")"
    else printf '  %-22s MISSING\n' "$c"; fi
  done

  printf '\nkill boundary\n'
  source "$KIT_ROOT/lib/kit-process.sh"
  local base; base="$(kit_cgroup_base)"
  if [[ -n "$base" ]]; then
    printf '  %-22s cgroup v2 (escape-proof, atomic)\n' 'available'
    printf '  %-22s %s\n' 'subtree' "$base"
  else
    printf '  %-22s process group (setsid + freeze-before-kill)\n' 'available'
    printf '  %-22s no writable cgroup v2 subtree; a child could setpgid() out\n' 'note'
  fi

  printf '\npinned tools\n'
  local manifest; manifest="$(kit_manifest_path "$KIT_ROOT")"
  if [[ -f "$manifest" ]]; then
    local tool want have path
    for tool in $(jq -r '.tools | keys[]' "$manifest" 2>/dev/null); do
      want="$(kit_tool_field "$manifest" "$tool" version)"
      local bin; bin="$(kit_tool_field "$manifest" "$tool" bin)"
      path="$(kit_tool_path "$bin" "$BIN_DIR")"
      if [[ -n "$path" ]]; then
        have="$(kit_tool_version "$path" 2>/dev/null || printf 'unknown')"
        if [[ "$have" == "$want" ]]; then
          printf '  %-22s %s (pinned %s) %s\n' "$tool" "$have" "$want" "$path"
        else
          printf '  %-22s %s (pinned %s - MISMATCH) %s\n' "$tool" "$have" "$want" "$path"
        fi
      else
        printf '  %-22s not installed (pinned %s)\n' "$tool" "$want"
      fi
    done
  else
    printf '  manifest missing: %s\n' "$manifest"
  fi

  printf '\ninstalled files\n'
  local f
  for f in "${HOOK_FILES[@]}"; do
    [[ -f "$HOOKS_DIR/$f" ]] && printf '  %-22s ok\n' "$f" || printf '  %-22s MISSING\n' "$f"
  done
  for f in "${LIB_FILES[@]}"; do
    [[ -f "$LIB_DIR/$f" ]] && printf '  %-22s ok\n' "$f" || printf '  %-22s MISSING\n' "$f"
  done
  for f in "${AGENT_FILES[@]}"; do
    [[ -f "$AGENTS_DIR/$f" ]] && printf '  %-22s ok\n' "agents/$f" || printf '  %-22s MISSING\n' "agents/$f"
  done

  printf '\nhooks in settings.json\n'
  if [[ -f "$SETTINGS" ]]; then
    if ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
      printf '  settings.json is NOT valid JSON - fix it before installing\n'
    else
      local reg event matcher script marker first
      for reg in "${REGISTRATIONS[@]}"; do
        IFS="$US" read -r event matcher script marker first <<< "$reg"
        if kit_hook_present "$SETTINGS" "$event" "$marker"; then
          printf '  %-22s registered\n' "$event"
        else
          printf '  %-22s NOT registered\n' "$event"
        fi
      done
      local others
      others="$(jq -r '[.hooks // {} | to_entries[] | .value[] | .hooks[]? | .command]
                       | map(select(contains("kit-") | not)) | length' "$SETTINGS" 2>/dev/null)"
      printf '  %-22s %s\n' 'other (not ours)' "${others:-0}"
    fi
  else
    printf '  no settings.json yet\n'
  fi

  printf '\nglobal CLAUDE.md\n'
  if kit_md_present "$GLOBAL_MD"; then printf '  kit block present\n'
  elif [[ -f "$GLOBAL_MD" ]]; then printf '  exists, but no kit block\n'
  else printf '  not present\n'; fi

  printf '\n'
}

# ==============================================================================
install_kit() {
  kit_require jq curl sha256sum tar || return 1

  kit_info "installing to $CLAUDE_DIR"
  kit_txn_start

  kit_mkdir "$CLAUDE_DIR" "$HOOKS_DIR" "$LIB_DIR" "$AGENTS_DIR" || return 1

  # --- libraries and hooks ----------------------------------------------------
  # The hooks are installed with their libs BESIDE them (~/.claude/kit-lib), so
  # a hook keeps working if the cloned repo is moved or deleted. A hook that
  # depends on a path the user might rm -rf is a hook that will break silently.
  local f res
  for f in "${LIB_FILES[@]}"; do
    res="$(kit_copy_file "$KIT_ROOT/lib/$f" "$LIB_DIR/$f" 0644)" || return 1
    [[ "$res" != 'unchanged' ]] && kit_ok "$res $LIB_DIR/$f"
  done
  for f in "${HOOK_FILES[@]}"; do
    res="$(kit_copy_file "$KIT_ROOT/hooks/$f" "$HOOKS_DIR/$f" 0755)" || return 1
    [[ "$res" != 'unchanged' ]] && kit_ok "$res $HOOKS_DIR/$f"
  done

  # --- agents -----------------------------------------------------------------
  for f in "${AGENT_FILES[@]}"; do
    local src="$KIT_ROOT/config/agents/$f"
    [[ -f "$src" ]] || continue
    # A read-only agent that can write is a contradiction the installer must not
    # ship. Assert it rather than trusting the file.
    if [[ "$f" == 'researcher.md' || "$f" == 'reviewer.md' ]]; then
      if grep -qE '^tools:.*\b(Edit|Write|MultiEdit)\b' "$src"; then
        kit_die "$f is declared read-only but grants a write tool" \
                "Fix config/agents/$f before installing."
        return 1
      fi
    fi
    res="$(kit_copy_file "$src" "$AGENTS_DIR/$f" 0644)" || return 1
    [[ "$res" != 'unchanged' ]] && kit_ok "$res $AGENTS_DIR/$f"
  done

  # --- the manual gate runner -------------------------------------------------
  kit_mkdir "$BIN_DIR" || return 1
  res="$(kit_copy_file "$KIT_ROOT/scripts/kit-gate" "$BIN_DIR/kit-gate" 0755)" || return 1
  [[ "$res" != 'unchanged' ]] && kit_ok "$res $BIN_DIR/kit-gate"
  res="$(kit_copy_file "$KIT_ROOT/scripts/new-project.sh" "$BIN_DIR/kit-new-project" 0755)" || return 1
  [[ "$res" != 'unchanged' ]] && kit_ok "$res $BIN_DIR/kit-new-project"

  # --- pinned tools -----------------------------------------------------------
  if (( NO_TOOLS )); then
    kit_info 'skipping pinned tools (--no-tools)'
  else
    local manifest; manifest="$(kit_manifest_path "$KIT_ROOT")"
    [[ -f "$manifest" ]] || { kit_die "tool manifest missing: $manifest" "Re-clone the repository."; return 1; }
    local tool bin want path have action
    for tool in $(jq -r '.tools | keys[]' "$manifest" 2>/dev/null); do
      bin="$(kit_tool_field "$manifest" "$tool" bin)"
      want="$(kit_tool_field "$manifest" "$tool" version)"
      # kit_tool_path, not `command -v`: BIN_DIR is not yet on this shell's
      # PATH, so command -v would find a system copy and - if its version
      # happened to match - skip installing the kit's own entirely.
      path="$(kit_tool_path "$bin" "$BIN_DIR")"
      have=''
      [[ -n "$path" ]] && have="$(kit_tool_version "$path" 2>/dev/null || true)"
      action="$(kit_tool_action 1 "$path" "$have" "$want" "$FORCE")"
      case "$action" in
        present)   kit_info "$tool $have already present" ;;
        install|reinstall)
          kit_install_pinned_tool "$manifest" "$tool" "$BIN_DIR" || {
            kit_warn "$tool was not installed; continuing without it"
          }
          ;;
      esac
    done
    kit_add_to_path "$BIN_DIR" >/dev/null
  fi

  # --- global CLAUDE.md -------------------------------------------------------
  res="$(kit_md_merge "$GLOBAL_MD" "$KIT_ROOT/config/CLAUDE.global.md")" || return 1
  case "$res" in
    created)         kit_ok "created $GLOBAL_MD" ;;
    appended)        kit_ok "appended kit rules to $GLOBAL_MD" ;;
    already-present) kit_info 'kit rules already in CLAUDE.md' ;;
  esac

  # --- settings.json ----------------------------------------------------------
  kit_settings_merge "$SETTINGS" "$CLAUDE_DIR" "${REGISTRATIONS[@]}" || return 1
  if (( ${#KIT_SETTINGS_CHANGES[@]} > 0 )); then
    local c; for c in "${KIT_SETTINGS_CHANGES[@]}"; do kit_ok "$c"; done
  else
    kit_info 'hooks already registered; settings.json unchanged'
  fi

  printf '\n'
  kit_ok 'installed'
  cat >&2 <<EOF

Next:
  1. FULLY RESTART Claude Code (hooks are read at startup).
  2. In a project:  kit-new-project
  3. Check it:      kit-gate --show
     Run it:        kit-gate fast   |   kit-gate full

  Verify the install any time with:  $KIT_ROOT/install.sh doctor
EOF
  return 0
}

# ==============================================================================
uninstall_kit() {
  kit_info "removing the kit from $CLAUDE_DIR"
  kit_txn_start

  kit_settings_uninstall "$SETTINGS" "${REGISTRATIONS[@]}" || true
  if (( ${#KIT_SETTINGS_CHANGES[@]} > 0 )); then
    local c; for c in "${KIT_SETTINGS_CHANGES[@]}"; do kit_ok "$c"; done
  else
    kit_info 'no kit hooks were registered'
  fi

  local res; res="$(kit_md_uninstall "$GLOBAL_MD")"
  case "$res" in
    removed)            kit_ok "removed the kit block from $GLOBAL_MD" ;;
    removed-empty-file) kit_ok "removed $GLOBAL_MD (it contained only the kit block)" ;;
    no-kit-block)       kit_info 'CLAUDE.md has no kit block; left alone' ;;
    absent)             kit_info 'no global CLAUDE.md' ;;
  esac

  # Only files this kit owns, named explicitly. Never a recursive delete of a
  # directory the user might also be using.
  local f
  for f in "${HOOK_FILES[@]}"; do
    if [[ -f "$HOOKS_DIR/$f" ]]; then
      if kit_is_dry_run; then kit_info "would remove $HOOKS_DIR/$f"
      else rm -f -- "$HOOKS_DIR/$f"; kit_ok "removed $HOOKS_DIR/$f"; fi
    fi
  done
  for f in "${LIB_FILES[@]}"; do
    if [[ -f "$LIB_DIR/$f" ]]; then
      if kit_is_dry_run; then kit_info "would remove $LIB_DIR/$f"
      else rm -f -- "$LIB_DIR/$f"; kit_ok "removed $LIB_DIR/$f"; fi
    fi
  done
  for f in "${AGENT_FILES[@]}"; do
    if [[ -f "$AGENTS_DIR/$f" ]]; then
      if kit_is_dry_run; then kit_info "would remove $AGENTS_DIR/$f"
      else rm -f -- "$AGENTS_DIR/$f"; kit_ok "removed $AGENTS_DIR/$f"; fi
    fi
  done
  for f in kit-gate kit-new-project; do
    if [[ -f "$BIN_DIR/$f" ]]; then
      if kit_is_dry_run; then kit_info "would remove $BIN_DIR/$f"
      else rm -f -- "$BIN_DIR/$f"; kit_ok "removed $BIN_DIR/$f"; fi
    fi
  done

  # kit-lib is ours entirely, so remove it when empty.
  [[ -d "$LIB_DIR" ]] && rmdir -- "$LIB_DIR" 2>/dev/null

  printf '\n'
  kit_ok 'uninstalled'
  cat >&2 <<'EOF'

Left in place deliberately:
  - rtk and rg binaries (other things may use them)
  - RTK's own hook - remove it with:  rtk init -g --uninstall
  - every backup the kit took (*.bak-*)
  - each project's .claude/ directory

Restart Claude Code to stop loading the hooks.
EOF
  return 0
}

# ==============================================================================
case "$MODE" in
  doctor)    doctor; exit 0 ;;
  install)
    if install_kit; then exit 0; fi
    kit_fail 'install failed - rolling back'
    kit_txn_undo
    exit 1
    ;;
  uninstall)
    if uninstall_kit; then exit 0; fi
    kit_fail 'uninstall failed'
    exit 1
    ;;
  *) kit_die "unknown mode: $MODE" "Use install, doctor or uninstall."; exit 1 ;;
esac
