#!/usr/bin/env bash
# kit-checkpoint.sh - Stop hook. The completion-time full gate.
#
# This is the piece that makes the kit self-fixing. Without it, an agent can
# edit, stop, and finish having never once run the project's real build or test
# suite.
#
# WHAT IT DOES
#   - working tree not dirty -> allow the stop, silently. Nothing to check.
#   - dirty -> run the FULL gate.
#       passes -> clear dirty, allow the stop.
#       fails  -> emit {"decision":"block","reason":...} with concise
#                 diagnostics, so the agent fixes it and tries to finish again.
#
# WHY THE BLOCK LOOP TERMINATES - three independent brakes, any one sufficient:
#   1. at most maxRepairAttempts (default 3) blocked stops
#   2. the same failure signature twice running is a loop that is not
#      converging - stop blocking and report
#   3. Claude Code's own stop_hook_active flag, honoured on entry
#
#   On give-up it does NOT block. It allows the stop and hands back a clear
#   report, because an agent that cannot fix something should return to a human
#   rather than burn turns proving it again.
#
# FAIL-OPEN vs FAIL-CLOSED, stated deliberately:
#   - Gate CONFIGURED and FAILING -> fail closed (block). The whole point.
#   - Gate NOT configured, or this hook itself errors -> fail open (allow).
#     Blocking a project that never opted in would deadlock it with no way for
#     the agent to satisfy a check that does not exist, which is worse than not
#     checking. Both directions are covered by tests/test-hooks.sh.

set -uo pipefail

# stdout is the JSON contract Claude Code parses. Anything else written there
# corrupts it, so every diagnostic in this file goes to stderr or nowhere.
emit_block() {  # emit_block <reason>
  jq -cn --arg r "$1" '{decision: "block", reason: $r}'
  exit 0
}
emit_context() {  # emit_context <text>
  jq -cn --arg t "$1" \
    '{hookSpecificOutput: {hookEventName: "Stop", additionalContext: $t}}'
  exit 0
}

_src="${BASH_SOURCE[0]}"
while [[ -L "$_src" ]]; do
  _d="$(cd -P "$(dirname -- "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  [[ "$_src" != /* ]] && _src="$_d/$_src"
done
HOOK_DIR="$(cd -P "$(dirname -- "$_src")" && pwd)"
for candidate in "$HOOK_DIR/../kit-lib" "$HOOK_DIR/../lib"; do
  if [[ -f "$candidate/kit-gate.sh" ]]; then LIB_DIR="$(cd -P "$candidate" && pwd)"; break; fi
done
# No lib means a broken install. Fail open: never wedge a session.
[[ -n "${LIB_DIR:-}" ]] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

raw="$(timeout 10 cat 2>/dev/null || true)"

# BRAKE 3: Claude Code sets stop_hook_active when it is re-running the Stop
# hooks after a previous block. Honouring it means that even if the two brakes
# below were somehow both defeated, the loop still cannot run away.
if [[ -n "$raw" ]]; then
  active="$(printf '%s' "$raw" | jq -r '.stop_hook_active // false' 2>/dev/null)"
  [[ "$active" == "true" ]] && exit 0
fi

start_dir=''
if [[ -n "$raw" ]]; then
  start_dir="$(printf '%s' "$raw" | jq -r '.cwd // ""' 2>/dev/null)"
fi
[[ -n "$start_dir" && -d "$start_dir" ]] || start_dir="$PWD"

source "$LIB_DIR/kit-gate.sh" 2>/dev/null || exit 0

root="$(kit_find_project_root "$start_dir" 2>/dev/null)" || exit 0
[[ -n "$root" ]] || exit 0

kit_state_load "$root"
# Nothing was edited, so there is nothing to verify.
[[ "$KIT_STATE_DIRTY" == "1" ]] || exit 0
# Already reported an unresolved failure this cycle. Do not re-block.
[[ "$KIT_STATE_GAVE_UP" == "1" ]] && exit 0

if ! kit_gate_config "$root"; then
  # Fail OPEN, but loudly. Never silently pretend the work was validated.
  emit_context "This project has no usable validation gate, so nothing verified these edits. $KIT_GATE_REASON"
fi

if kit_run_gate "$root" full; then
  kit_state_clear_dirty "$root"
  exit 0
fi

# A gate that is configured but whose commands could not even start is a broken
# gate, not failing work. Report it rather than sending the agent to fix code
# that may be fine.
if [[ "$KIT_PROC_STATUS" == "spawn-failure" ]]; then
  emit_context "The validation gate could not run: '$KIT_PROC_COMMAND' failed to start. Check that the command exists and that .claude/gate.json is correct. Nothing verified these edits."
fi

sig="$(kit_failure_signature "$KIT_PROC_COMMAND" "$KIT_PROC_EXIT_CODE" "$KIT_PROC_STDOUT" "$KIT_PROC_STDERR")"
decision="$(kit_repair_decision "$sig" "$KIT_STATE_LAST_SIG" "$KIT_STATE_REPEAT" \
                                "$KIT_STATE_ATTEMPTS" "$KIT_GATE_MAX_REPAIR")"

# Record BEFORE acting, so a crash between here and the next stop cannot reset
# the counters and turn a bounded loop into an unbounded one.
if [[ "$sig" == "$KIT_STATE_LAST_SIG" ]]; then
  KIT_STATE_REPEAT=$(( KIT_STATE_REPEAT + 1 ))
else
  KIT_STATE_REPEAT=0
  KIT_STATE_LAST_SIG="$sig"
fi
KIT_STATE_ATTEMPTS=$(( KIT_STATE_ATTEMPTS + 1 ))

diag="$(kit_concise_diagnostics 40)"

if [[ "$decision" == "block" ]]; then
  kit_state_save "$root"
  emit_block "The full validation gate is failing, so this work is not finished.

$diag

Fix the ROOT CAUSE and stop again - the gate re-runs automatically.
Do NOT silence the check, delete or skip the test, or weaken the gate to get a
green result; that is treated as a failure, not a fix.
Attempt $KIT_STATE_ATTEMPTS of $KIT_GATE_MAX_REPAIR.
If the failure surface is large, delegate it to a subagent so the build output
stays out of the main context."
fi

# Give up: stop blocking, report honestly, let a human take it.
KIT_STATE_GAVE_UP=1
kit_state_save "$root"

why='the repair attempt limit was reached'
[[ "$decision" == "give-up-repeat" ]] && \
  why='the identical failure recurred, so the repair loop is not converging'

emit_context "VALIDATION STILL FAILING - stopping the repair loop because $why.

$diag

This needs a human. Report the failing command, the exit code, what you tried,
and your best hypothesis. Do not keep retrying."
