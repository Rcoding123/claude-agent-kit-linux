#!/usr/bin/env bash
# kit-gate.sh - checkpoint-aware validation, bounded repair, loop detection.
#
# THE PROBLEM THIS REPLACES
# -------------------------
# The naive design runs the project's complete gate after every single Edit or
# Write. A ten-edit refactor demands ten full builds and ten full test suites.
# Most of those runs are against a half-finished state, so most of their output
# is noise the agent has to read and discard - paid for at full token rate,
# repeatedly.
#
# Worse, it has the timing exactly inverted: it validates constantly while the
# work is incomplete, and has no guarantee of validating at all once the work is
# done. Nothing runs a full gate before the agent stops.
#
# THE DESIGN
# ----------
# Two levels, and edits change STATE rather than triggering work:
#
#   an edit          -> marks the working tree dirty. Runs nothing.
#   a checkpoint     -> FAST gate. Targeted: syntax/lint. The smallest
#                       trustworthy check for what changed.
#   before finishing -> FULL gate. Complete lint + build + test suite. Enforced
#                       at the Stop hook.
#
# A failing full gate blocks the stop with concise diagnostics, so the agent
# fixes it and tries again. That loop is bounded:
#
#   - at most maxRepairAttempts (default 3) blocked stops per failure surface
#   - an IDENTICAL failure signature twice in a row is a loop: stop blocking,
#     report, and hand back to a human rather than burning turns
#   - Claude Code's own `stop_hook_active` flag is honoured as a second brake
#
# Nothing here can be satisfied by disabling a check: the gate command is read
# from project config, and the agent is told explicitly that silencing a check
# is not an acceptable repair.

set -o pipefail

[[ -n "${_KIT_GATE_SOURCED:-}" ]] && return 0
_KIT_GATE_SOURCED=1

_kg_dir="$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/kit-common.sh
source "$_kg_dir/kit-common.sh"
# shellcheck source=lib/kit-process.sh
source "$_kg_dir/kit-process.sh"

# --- project root -------------------------------------------------------------
# Walk up from a starting directory looking for the gate file. Bounded depth so
# a symlink cycle or a pathological path cannot spin forever.
kit_find_project_root() {  # kit_find_project_root [start dir]
  local dir="${1:-$PWD}"
  [[ -d "$dir" ]] || dir="$PWD"
  dir="$(cd -P "$dir" 2>/dev/null && pwd)" || return 1
  local depth=0
  while [[ -n "$dir" && "$dir" != "/" && $depth -lt 64 ]]; do
    if [[ -f "$dir/.claude/gate.json" || -f "$dir/.claude/gate.txt" ]]; then
      printf '%s' "$dir"; return 0
    fi
    dir="$(dirname -- "$dir")"
    depth=$((depth+1))
  done
  # Check / itself, then give up.
  if [[ -f "/.claude/gate.json" || -f "/.claude/gate.txt" ]]; then printf '/'; return 0; fi
  return 1
}

# --- gate configuration -------------------------------------------------------
# Modern form: .claude/gate.json  { fast: [...], full: [...], maxRepairAttempts }
# Legacy form: .claude/gate.txt   a single command line, treated as the FULL gate.
#
# Results land in globals rather than a printed structure: gate commands contain
# every delimiter one might pick, so parsing them back would be a bug waiting.
KIT_GATE_OK=0
KIT_GATE_REASON=''
KIT_GATE_FAST=()
KIT_GATE_FULL=()
KIT_GATE_MAX_REPAIR=3
KIT_GATE_LANGUAGE='unknown'
KIT_GATE_PATH=''
# Per-command wall-clock limit. A gate is allowed to be slow - a real build is -
# but it must not be able to hang a session forever, so there is always a limit.
KIT_GATE_TIMEOUT=1800

kit_gate_config() {  # kit_gate_config <project root>
  local root="$1"
  KIT_GATE_OK=0; KIT_GATE_REASON=''; KIT_GATE_FAST=(); KIT_GATE_FULL=()
  KIT_GATE_MAX_REPAIR=3; KIT_GATE_LANGUAGE='unknown'; KIT_GATE_PATH=''
  KIT_GATE_TIMEOUT="${KIT_GATE_TIMEOUT_OVERRIDE:-1800}"

  local json="$root/.claude/gate.json"
  if [[ -f "$json" ]]; then
    KIT_GATE_PATH="$json"
    if ! jq -e . "$json" >/dev/null 2>&1; then
      KIT_GATE_REASON="gate.json is not valid JSON. Fix $json - the kit will not guess what you meant."
      return 1
    fi
    # Base64 per element, one per line. A gate command may legitimately contain
    # a newline (a multi-line shell snippet), so reading raw lines would cut it
    # into two commands - one of which would then run alone and fail
    # confusingly. Encoding sidesteps every delimiter question: base64 output
    # contains no newline, so one line really is one command.
    local _b
    KIT_GATE_FAST=()
    while IFS= read -r _b; do
      [[ -n "$_b" ]] && KIT_GATE_FAST+=("$(printf '%s' "$_b" | base64 -d)")
    done < <(jq -r '(.fast // [])[] | select(type == "string" and . != "") | @base64' "$json" 2>/dev/null)
    KIT_GATE_FULL=()
    while IFS= read -r _b; do
      [[ -n "$_b" ]] && KIT_GATE_FULL+=("$(printf '%s' "$_b" | base64 -d)")
    done < <(jq -r '(.full // [])[] | select(type == "string" and . != "") | @base64' "$json" 2>/dev/null)
    local m; m="$(jq -r '.maxRepairAttempts // 3' "$json" 2>/dev/null)"
    [[ "$m" =~ ^[0-9]+$ ]] && KIT_GATE_MAX_REPAIR="$m"
    local t; t="$(jq -r '.timeoutSec // empty' "$json" 2>/dev/null)"
    [[ "$t" =~ ^[0-9]+$ ]] && KIT_GATE_TIMEOUT="$t"
    KIT_GATE_LANGUAGE="$(jq -r '.language // "unknown"' "$json" 2>/dev/null)"

    if (( ${#KIT_GATE_FULL[@]} > 0 || ${#KIT_GATE_FAST[@]} > 0 )); then
      KIT_GATE_OK=1; return 0
    fi
    KIT_GATE_REASON="gate.json defines no commands. This project has NO validation configured. Fill in 'full' (and ideally 'fast') in $json with the real build/test commands for this project."
    return 1
  fi

  local txt="$root/.claude/gate.txt"
  if [[ -f "$txt" ]]; then
    KIT_GATE_PATH="$txt"
    local cmd; cmd="$(tr -d '\r' < "$txt" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' | head -1)"
    if [[ -z "$cmd" ]]; then
      # An EMPTY gate file means every hook silently no-ops. The project looks
      # wired and validates nothing. Say so instead.
      KIT_GATE_REASON="gate.txt is empty. This project has NO validation configured - nothing is checking your work. Run scripts/new-project.sh or write the build/test command into $txt."
      return 1
    fi
    KIT_GATE_FULL=("$cmd"); KIT_GATE_OK=1; return 0
  fi

  KIT_GATE_REASON='no .claude/gate.json or .claude/gate.txt found'
  return 1
}

# --- state --------------------------------------------------------------------
# Per-project, under .claude/. Tracks dirtiness, repair attempts and the last
# failure signature so a repeat can be recognised.
KIT_STATE_DIRTY=0
KIT_STATE_EDITS=0
KIT_STATE_ATTEMPTS=0
KIT_STATE_LAST_SIG=''
KIT_STATE_REPEAT=0
KIT_STATE_GAVE_UP=0

kit_state_path() { printf '%s' "$1/.claude/kit-state.json"; }

kit_state_load() {  # kit_state_load <project root>
  local p; p="$(kit_state_path "$1")"
  KIT_STATE_DIRTY=0; KIT_STATE_EDITS=0; KIT_STATE_ATTEMPTS=0
  KIT_STATE_LAST_SIG=''; KIT_STATE_REPEAT=0; KIT_STATE_GAVE_UP=0
  [[ -f "$p" ]] || return 0
  jq -e . "$p" >/dev/null 2>&1 || return 0
  KIT_STATE_DIRTY="$(jq -r 'if .dirty then 1 else 0 end' "$p" 2>/dev/null)"
  KIT_STATE_EDITS="$(jq -r '.editsSinceGate // 0' "$p" 2>/dev/null)"
  KIT_STATE_ATTEMPTS="$(jq -r '.repairAttempts // 0' "$p" 2>/dev/null)"
  KIT_STATE_LAST_SIG="$(jq -r '.lastSignature // ""' "$p" 2>/dev/null)"
  KIT_STATE_REPEAT="$(jq -r '.repeatCount // 0' "$p" 2>/dev/null)"
  KIT_STATE_GAVE_UP="$(jq -r 'if .gaveUp then 1 else 0 end' "$p" 2>/dev/null)"
  return 0
}

kit_state_save() {  # kit_state_save <project root>
  local root="$1" p; p="$(kit_state_path "$root")"
  mkdir -p -- "$(dirname -- "$p")" 2>/dev/null || return 1
  jq -n \
    --argjson dirty   "$(( KIT_STATE_DIRTY ? 1 : 0 ))" \
    --argjson edits   "${KIT_STATE_EDITS:-0}" \
    --argjson att     "${KIT_STATE_ATTEMPTS:-0}" \
    --arg     sig     "${KIT_STATE_LAST_SIG:-}" \
    --argjson rep     "${KIT_STATE_REPEAT:-0}" \
    --argjson gave    "$(( KIT_STATE_GAVE_UP ? 1 : 0 ))" \
    '{dirty: ($dirty == 1), editsSinceGate: $edits, repairAttempts: $att,
      lastSignature: $sig, repeatCount: $rep, gaveUp: ($gave == 1)}' \
    > "$p".tmp 2>/dev/null && mv -f "$p".tmp "$p"
}

kit_state_mark_dirty() {  # kit_state_mark_dirty <project root>
  kit_state_load "$1"
  KIT_STATE_DIRTY=1
  KIT_STATE_EDITS=$(( KIT_STATE_EDITS + 1 ))
  kit_state_save "$1"
}

kit_state_clear_dirty() {  # kit_state_clear_dirty <project root>
  kit_state_load "$1"
  KIT_STATE_DIRTY=0; KIT_STATE_EDITS=0; KIT_STATE_ATTEMPTS=0
  KIT_STATE_LAST_SIG=''; KIT_STATE_REPEAT=0; KIT_STATE_GAVE_UP=0
  kit_state_save "$1"
}

# --- failure signature --------------------------------------------------------
# A stable fingerprint of a failure, so "the same thing failed again" can be
# detected without comparing whole logs.
#
# Volatile parts - absolute paths, timings, hex addresses, GUIDs, digits
# generally - are normalised out. Two runs of the same broken build produce the
# same signature; a genuinely different error produces a different one.
#
# Digits go last and go wholesale: line numbers, PIDs, elapsed milliseconds and
# memory addresses are all noise for this purpose, and enumerating them
# individually would miss whichever one a new toolchain invents.
kit_failure_signature() {  # kit_failure_signature <command> <exit code> <stdout> <stderr>
  local cmd="$1" code="$2" out="$3" err="$4"
  local text; text="$(printf '%s\n%s' "$err" "$out")"
  text="${text:0:4000}"
  local norm="$text"
  norm="$(printf '%s' "$norm" \
    | sed -E \
        -e 's#/[^[:space:]:"]{3,}#<path>#g' \
        -e 's#0x[0-9a-fA-F]+#<hex>#g' \
        -e 's#[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}#<guid>#g' \
        -e 's#[0-9]+#\##g' \
        -e 's#[[:space:]]+# #g' \
    | sed -e 's/^ //' -e 's/ $//' \
    | tr '[:upper:]' '[:lower:]')"
  printf '%s|%s|%s' "$cmd" "$code" "$norm" | sha256sum | cut -c1-16
}

# --- diagnostics --------------------------------------------------------------
# Turn a raw process result into something worth putting in an agent's context.
#
# Deliberately NOT the whole log. The full output is on disk and the path is
# included; what comes back is the failing command, the real exit code, and the
# lines most likely to name the problem.
#
# Filtering exists to BOUND large output, not to shrink output that is already
# small. Keyword-filtering a 12-line failure down to its one keyword line
# destroys the location: ruff prints the rule on one line and the file on the
# next (" --> src/lint_me.py:1:8"), and that location line carries no keyword of
# its own. `pytest` does the same with the failing test name. Losing the file
# name is precisely the diagnostic loss that makes a repair loop flail.
kit_concise_diagnostics() {  # uses KIT_PROC_* globals; kit_concise_diagnostics [max lines]
  local max_lines="${1:-40}"
  {
    printf 'FAILED: %s\n' "$KIT_PROC_COMMAND"
    case "$KIT_PROC_STATUS" in
      timeout)       printf 'exit: timed out after the configured limit (owned process tree torn down via %s)\n' "$KIT_PROC_BOUNDARY" ;;
      spawn-failure) printf 'exit: could not start the process (working directory missing, or the command does not exist)\n' ;;
      *)             printf 'exit: %s\n' "$KIT_PROC_EXIT_CODE" ;;
    esac

    # stderr first - that is where compilers and test runners put the reason.
    local body; body="$(printf '%s\n%s' "$KIT_PROC_STDERR" "$KIT_PROC_STDOUT" | grep -v '^[[:space:]]*$')"
    local count; count="$(printf '%s\n' "$body" | wc -l)"

    if [[ -n "${body//[[:space:]]/}" ]]; then
      printf -- '---\n'
      if (( count <= max_lines )); then
        printf '%s\n' "$body"
      else
        # Keep every diagnostic-looking line together with the lines AROUND it,
        # so a location line or code frame attached to an error survives with
        # the error. grep -C 2 does exactly that.
        local kw='(error|fail(ed|ure)?|exception|panic|assert|cannot|unable|undefined|unresolved|not found|traceback|warning|E[0-9]{3})'
        local chosen
        chosen="$(printf '%s\n' "$body" | grep -inE -C 2 "$kw" 2>/dev/null | sed 's/^[0-9]*[-:]//')"
        [[ -z "${chosen//[[:space:]]/}" ]] && chosen="$body"
        # The tail is usually where the summary lives.
        printf '%s\n' "$chosen" | tail -n "$max_lines"
      fi
    fi

    if [[ -n "$KIT_PROC_RAW_LOG" ]]; then
      printf -- '---\nfull output: %s\n' "$KIT_PROC_RAW_LOG"
    fi
  }
}

# --- running a gate -----------------------------------------------------------
KIT_GATE_RESULT_OK=0
KIT_GATE_RESULT_CONFIGURED=0
KIT_GATE_RESULT_RAN=0
KIT_GATE_RESULT_REASON=''

# Run one gate level.
#
# Fail-fast: the first failing command stops the sequence. Running the rest
# after a compile failure just produces cascading noise that costs tokens and
# says nothing new.
#
# Each entry is a single command and the runner stops at the first failure, so
# fail-fast is structural rather than something the shell has to be talked into
# with && chains.
kit_run_gate() {  # kit_run_gate <project root> <fast|full> [timeout sec]
  local root="$1" level="$2" timeout_sec="${3:-}"
  KIT_GATE_RESULT_OK=0; KIT_GATE_RESULT_CONFIGURED=0
  KIT_GATE_RESULT_RAN=0; KIT_GATE_RESULT_REASON=''

  if ! kit_gate_config "$root"; then
    KIT_GATE_RESULT_REASON="$KIT_GATE_REASON"
    return 1
  fi
  KIT_GATE_RESULT_CONFIGURED=1
  # The config may carry its own limit; an explicit argument still wins.
  [[ -z "$timeout_sec" ]] && timeout_sec="$KIT_GATE_TIMEOUT"

  local -a cmds=()
  if [[ "$level" == "fast" ]]; then
    cmds=("${KIT_GATE_FAST[@]}")
    # No fast gate defined is not an error - it means this project only has a
    # full gate. Say nothing ran rather than silently running the full one,
    # which would reintroduce exactly the cost this design removes.
    if (( ${#cmds[@]} == 0 )); then
      KIT_GATE_RESULT_OK=1
      KIT_GATE_RESULT_REASON='no fast gate configured'
      return 0
    fi
  else
    cmds=("${KIT_GATE_FULL[@]}")
    if (( ${#cmds[@]} == 0 )); then
      # A fast-only gate must not be silently promoted to "full passed".
      KIT_GATE_RESULT_OK=1
      KIT_GATE_RESULT_REASON='no full gate configured'
      return 0
    fi
  fi

  local logdir="$root/.claude/gate-logs"
  mkdir -p -- "$logdir" 2>/dev/null
  # Keep the log directory from growing without bound: a gate that runs on every
  # stop for a month should not quietly consume the disk.
  kit_prune_logs "$logdir" 40

  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  local i=0 c
  for c in "${cmds[@]}"; do
    i=$((i+1))
    KIT_GATE_RESULT_RAN=$i
    kit_run_shell "$c" --cwd "$root" --timeout "$timeout_sec" \
                  --log "$logdir/$level-$stamp-$i.log" >/dev/null 2>&1
    if [[ "$KIT_PROC_STATUS" != "success" ]]; then
      KIT_GATE_RESULT_OK=0
      return 1
    fi
  done
  KIT_GATE_RESULT_OK=1
  return 0
}

kit_prune_logs() {  # kit_prune_logs <dir> <keep>
  local dir="$1" keep="${2:-40}"
  [[ -d "$dir" ]] || return 0
  local -a old
  mapfile -t old < <(ls -1t "$dir"/*.log 2>/dev/null | tail -n "+$((keep+1))")
  (( ${#old[@]} > 0 )) && rm -f -- "${old[@]}" 2>/dev/null
  return 0
}

# --- repair decision ----------------------------------------------------------
# Decide what a Stop hook should do about a failing full gate.
#
# Pure function - no I/O - so the bounding and loop-detection rules can be
# tested directly instead of inferred from behaviour.
#
# Prints: block | give-up-repeat | give-up-attempts
kit_repair_decision() {  # kit_repair_decision <sig> <last sig> <repeat> <attempts> <max>
  local sig="$1" last="$2" repeat="${3:-0}" attempts="${4:-0}" max="${5:-3}"
  # An identical failure twice running means the repair loop is not converging:
  # the agent changed something and the gate produced the byte-identical
  # complaint. Blocking again just buys the same failure a third time.
  #
  # Note the condition is on the signatures alone, NOT on repeat count. The
  # caller increments the repeat count AFTER taking this decision, so on the
  # second identical failure the count is still 0 - requiring >= 1 here would
  # mean the second identical failure blocks anyway and detection slips a cycle.
  if [[ -n "$sig" && -n "$last" && "$sig" == "$last" ]]; then
    printf 'give-up-repeat'; return 0
  fi
  if (( attempts >= max )); then printf 'give-up-attempts'; return 0; fi
  printf 'block'
}
