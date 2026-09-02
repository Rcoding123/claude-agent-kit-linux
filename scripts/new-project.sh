#!/usr/bin/env bash
# new-project.sh - per-repo initializer.
#
# Detects the language, writes .claude/gate.json with fast and full command
# lists built from what the project ACTUALLY contains, writes any helper the
# gate references, and creates a starter CLAUDE.md only if there is not one
# already.
#
# Tools are probed, not assumed: no ruff in your interpreter means no ruff step
# and a note saying so, rather than a gate that fails for reasons unrelated to
# your code.
#
# Usage:
#   new-project.sh [path]
#   new-project.sh --language python
#   new-project.sh --fast "make lint" --full "make check"
#   new-project.sh --dry-run
#   new-project.sh --force        # overwrite an existing gate.json

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# This script runs from two places and must work from both:
#   - in the repo,  scripts/new-project.sh, with lib/ one level up
#   - installed as  ~/.local/bin/kit-new-project, whose parent is ~/.local and
#                   whose libraries live in ~/.claude/kit-lib beside the hooks
# Assuming the repo layout is why the INSTALLED copy failed with "kit file
# missing" - a bug the suite missed for a while because every test invoked the
# in-repo script, never the installed one.
for _cand in \
  "$(dirname -- "$SCRIPT_DIR")/lib" \
  "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/kit-lib" \
  "$SCRIPT_DIR/../kit-lib"
do
  if [[ -f "$_cand/kit-detect.sh" ]]; then LIB="$(cd -P "$_cand" && pwd)"; break; fi
done
if [[ -z "${LIB:-}" ]]; then
  printf 'new-project: cannot find the kit libraries\n' >&2
  printf '  -> re-run install.sh, or run this script from inside the kit repository\n' >&2
  exit 2
fi
KIT_ROOT="$(dirname -- "$LIB")"
source "$LIB/kit-common.sh"
source "$LIB/kit-detect.sh"

PROJECT=''
LANGUAGE=''
FORCE=0
declare -a OVERRIDE_FAST=() OVERRIDE_FULL=()

usage() {
  cat <<'EOF'
Usage: new-project.sh [path] [options]

  --language <lang>   Override detection (rust|cpp|python|node|cs|go|shell)
  --fast <command>    Add a fast-gate command (repeatable; replaces detection)
  --full <command>    Add a full-gate command (repeatable; replaces detection)
  --force             Overwrite an existing .claude/gate.json
  --dry-run           Show what would happen, change nothing
  --quiet             Suppress progress output
  -h, --help          This message
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --language) LANGUAGE="$2"; shift 2 ;;
    --fast)     OVERRIDE_FAST+=("$2"); shift 2 ;;
    --full)     OVERRIDE_FULL+=("$2"); shift 2 ;;
    --force)    FORCE=1; shift ;;
    --dry-run)  KIT_DRY_RUN=1; shift ;;
    --quiet)    KIT_QUIET=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    -*)         kit_die "unknown option: $1" "Run with --help."; exit 1 ;;
    *)          PROJECT="$1"; shift ;;
  esac
done

kit_require jq || exit 1

[[ -n "$PROJECT" ]] || PROJECT="$PWD"
PROJECT="$(cd -P "$PROJECT" 2>/dev/null && pwd)" || { kit_die "no such directory: $PROJECT"; exit 1; }

kit_info "project: $PROJECT"

# --- detect -------------------------------------------------------------------
if [[ -z "$LANGUAGE" ]]; then
  LANGUAGE="$(kit_detect_language "$PROJECT")"
  kit_info "detected language: $LANGUAGE"
else
  kit_info "language (forced): $LANGUAGE"
fi

# --- plan ---------------------------------------------------------------------
# An explicit --fast/--full replaces detection entirely. Someone who tells the
# kit the commands knows their project better than the detector does.
if (( ${#OVERRIDE_FAST[@]} > 0 || ${#OVERRIDE_FULL[@]} > 0 )); then
  KIT_PLAN_FAST=("${OVERRIDE_FAST[@]}")
  KIT_PLAN_FULL=("${OVERRIDE_FULL[@]}")
  KIT_PLAN_NOTES=('Commands were supplied explicitly on the command line; detection was not used.')
  KIT_PLAN_CONFIGURED=1
  (( ${#KIT_PLAN_FULL[@]} == 0 )) && {
    KIT_PLAN_FULL=("${OVERRIDE_FAST[@]}")
    KIT_PLAN_NOTES+=('No --full was given, so the --fast commands are used as the full gate too.')
  }
else
  kit_build_plan "$PROJECT" "$LANGUAGE"
fi

# --- report -------------------------------------------------------------------
if (( ${#KIT_PLAN_FAST[@]} > 0 )); then
  kit_info "fast gate:"
  for c in "${KIT_PLAN_FAST[@]}"; do kit_info "  $c"; done
fi
if (( ${#KIT_PLAN_FULL[@]} > 0 )); then
  kit_info "full gate:"
  for c in "${KIT_PLAN_FULL[@]}"; do kit_info "  $c"; done
fi
if (( ${#KIT_PLAN_NOTES[@]} > 0 )); then
  for n in "${KIT_PLAN_NOTES[@]}"; do kit_warn "$n"; done
fi
if (( ! KIT_PLAN_CONFIGURED )); then
  kit_warn 'This project is being written as NOT configured. Nothing will validate your work until you fill in .claude/gate.json.'
fi

# --- write --------------------------------------------------------------------
kit_txn_start
CLAUDE_SUB="$PROJECT/.claude"
kit_mkdir "$CLAUDE_SUB" || exit 1

GATE="$CLAUDE_SUB/gate.json"
if [[ -f "$GATE" && "$FORCE" != "1" ]]; then
  kit_warn "$GATE already exists; leaving it alone (use --force to overwrite)"
else
  [[ -f "$GATE" ]] && kit_backup_file "$GATE" >/dev/null
  # jq builds the arrays, so a command containing a quote, a backslash or a
  # newline is encoded correctly rather than producing a broken file.
  #
  # Base64 per element, matching how kit_gate_config reads them back. The
  # obvious `printf '%s\0' ... | jq -Rs 'split("<NUL>")'` does NOT work: a NUL
  # cannot survive shell quoting into jq's program text, and jq's split("")
  # silently splits into individual CHARACTERS - which produced a gate.json
  # whose command list was one entry per letter. Encoding sidesteps it: base64
  # output contains no newline, so one line is reliably one command.
  kit_json_array() {  # kit_json_array <element>...
    local e
    if (( $# == 0 )); then printf '[]'; return 0; fi
    for e in "$@"; do printf '%s' "$e" | base64 -w0; printf '\n'; done \
      | jq -R 'select(length > 0) | @base64d' | jq -sc .
  }
  FAST_JSON="$(kit_json_array "${KIT_PLAN_FAST[@]:-}")"
  FULL_JSON="$(kit_json_array "${KIT_PLAN_FULL[@]:-}")"
  NOTES_JSON="$(kit_json_array "${KIT_PLAN_NOTES[@]:-}")"

  jq -n \
    --arg lang "$LANGUAGE" \
    --argjson fast "$FAST_JSON" \
    --argjson full "$FULL_JSON" \
    --argjson notes "$NOTES_JSON" \
    --argjson configured "$(( KIT_PLAN_CONFIGURED ? 1 : 0 ))" \
    '{
      "$comment": [
        "Written by claude-agent-kit new-project.sh. Edit freely - this file is yours.",
        "fast: the cheap subset, run at a checkpoint. full: everything, enforced at Stop.",
        "Each entry is ONE command. The runner stops at the first failure, so fail-fast",
        "comes from the list rather than from shell && chains.",
        "configured:false means the kit could NOT infer a build system and nothing is",
        "validating this project until you fill in full."
      ],
      language: $lang,
      configured: ($configured == 1),
      fast: $fast,
      full: $full,
      maxRepairAttempts: 3,
      notes: $notes
    }' | kit_json_write "$GATE" || exit 1
  # kit_json_write handles dry-run itself and reports "would write", so this
  # line must not also claim the file was written - a dry run that says "wrote"
  # is exactly the kind of small dishonesty that makes people stop trusting
  # --dry-run and just run the real thing to see what happens.
  kit_is_dry_run || kit_ok "wrote $GATE"
fi

# --- helpers the gate references ---------------------------------------------
# The gate names .claude/py-syntax.py and .claude/sh-syntax.sh, so they must be
# written here. Keeping the command and the script it names together is what
# stops one from drifting away from the other.
case "$LANGUAGE" in
  python)
    if kit_is_dry_run; then kit_info "would write $CLAUDE_SUB/py-syntax.py"
    else
      kit_backup_file "$CLAUDE_SUB/py-syntax.py" >/dev/null
      kit_python_syntax_checker > "$CLAUDE_SUB/py-syntax.py"
      kit_ok "wrote $CLAUDE_SUB/py-syntax.py"
    fi
    ;;
  shell)
    if kit_is_dry_run; then kit_info "would write $CLAUDE_SUB/sh-syntax.sh"
    else
      kit_backup_file "$CLAUDE_SUB/sh-syntax.sh" >/dev/null
      kit_shell_syntax_checker > "$CLAUDE_SUB/sh-syntax.sh"
      chmod +x "$CLAUDE_SUB/sh-syntax.sh"
      kit_ok "wrote $CLAUDE_SUB/sh-syntax.sh"
    fi
    ;;
esac

# --- .gitignore ---------------------------------------------------------------
# The kit's runtime state is per-machine and must not be committed. Appending is
# safe and idempotent; the file is never rewritten.
GI="$PROJECT/.gitignore"
if [[ -d "$PROJECT/.git" ]] && ! kit_is_dry_run; then
  if ! grep -qF '.claude/kit-state.json' "$GI" 2>/dev/null; then
    {
      printf '\n# claude-agent-kit runtime state (per-machine, not project config)\n'
      printf '.claude/kit-state.json\n.claude/gate-logs/\n'
    } >> "$GI"
    kit_info "added kit runtime state to .gitignore"
  fi
fi

# --- starter CLAUDE.md --------------------------------------------------------
# Only if there is not one already. Overwriting someone's project instructions
# would be a far worse outcome than not having a starter file.
MD="$PROJECT/CLAUDE.md"
if [[ -f "$MD" ]]; then
  kit_info 'CLAUDE.md already exists; leaving it alone'
elif kit_is_dry_run; then
  kit_info "would create $MD"
else
  cat > "$MD" <<EOF
# Project instructions

Language: $LANGUAGE

## Validation
This project has a two-level gate in \`.claude/gate.json\`:
- **fast** - the cheap subset. Run it while you work.
- **full** - everything. It is enforced automatically before a session ends.

Run either by hand with \`kit-gate fast\` / \`kit-gate full\`.

A failing full gate blocks completion. Fix the root cause. Do **not** silence a
check, delete or skip a test, or weaken the gate to get a green result.

## Conventions
<!-- Put the things an agent could not infer from the code: architectural
     constraints, invariants, things that look wrong but are deliberate. -->
EOF
  kit_ok "created $MD"
fi

if kit_is_dry_run; then
  kit_ok 'dry run complete - NOTHING was written'
else
  kit_ok 'done - restart Claude Code in this folder'
fi
exit 0
