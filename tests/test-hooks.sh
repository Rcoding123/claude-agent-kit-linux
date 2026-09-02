#!/usr/bin/env bash
# test-hooks.sh - the hooks driven through their real JSON contract.
#
# These run the hook scripts as Claude Code runs them: event JSON on stdin,
# decision JSON on stdout, exit code as the outer signal. Nothing here calls the
# library functions directly, because the thing being tested is the CONTRACT -
# a hook that computes the right answer and prints it in the wrong shape is
# broken in exactly the way that is hardest to notice.
#
# Both directions of the fail-open/fail-closed split are asserted:
#   - a configured, failing gate MUST block
#   - an unconfigured gate MUST NOT block
# Getting either backwards is silent.

set -uo pipefail

TEST_DIR="$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KIT_ROOT="$(dirname -- "$TEST_DIR")"
source "$TEST_DIR/kit-test-lib.sh"
source "$KIT_ROOT/lib/kit-gate.sh"

SELFFIX="$KIT_ROOT/hooks/kit-selffix.sh"
CHECKPOINT="$KIT_ROOT/hooks/kit-checkpoint.sh"

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

project() {  # project <name> <gate json> -> prints root
  local root="$WORK/$1"; mkdir -p "$root/.claude"
  printf '%s\n' "$2" > "$root/.claude/gate.json"
  printf '%s' "$root"
}

event() {  # event <cwd> [stop_hook_active]
  jq -cn --arg c "$1" --argjson a "${2:-false}" \
    '{session_id:"test", cwd:$c, hook_event_name:"Stop", stop_hook_active:$a}'
}

# Sets HOOK_OUT and HOOK_RC as globals rather than printing, because
# `X="$(run_hook ...)"` would run this in a subshell and the exit code would
# never reach the caller.
HOOK_OUT=''
HOOK_RC=0
run_hook() {  # run_hook <script> <event json>
  local script="$1" ev="$2"
  HOOK_OUT="$(printf '%s' "$ev" | bash "$script" 2>/dev/null)"
  HOOK_RC=$?
}

kit_section 'selffix: records, runs nothing'

P="$(project selffix '{"full":["touch GATE_RAN"]}')"
run_hook "$SELFFIX" "$(event "$P")"; OUT="$HOOK_OUT"
kit_assert_eq '0' "$HOOK_RC" 'the PostToolUse hook always exits 0'
kit_assert_eq '' "$OUT" 'and prints nothing to stdout'
kit_assert_file_absent "$P/GATE_RAN" 'AN EDIT DOES NOT RUN THE GATE - this is the cost model'

kit_state_load "$P"
kit_assert_eq '1' "$KIT_STATE_DIRTY" 'but it does mark the project dirty'
kit_assert_eq '1' "$KIT_STATE_EDITS" 'and counts the edit'

run_hook "$SELFFIX" "$(event "$P")"
run_hook "$SELFFIX" "$(event "$P")"
kit_state_load "$P"
kit_assert_eq '3' "$KIT_STATE_EDITS" 'ten edits would run ten gates in the naive design; here they run zero'
kit_assert_file_absent "$P/GATE_RAN" 'still no gate has run after three edits'

# A directory with no gate at all must not crash the hook.
NOGATE="$WORK/nogate"; mkdir -p "$NOGATE"
run_hook "$SELFFIX" "$(event "$NOGATE")"
kit_assert_eq '0' "$HOOK_RC" 'a project with no gate does not break the edit hook'

# Malformed stdin must not break it either.
HOOK_OUT="$(printf 'not json at all' | bash "$SELFFIX" 2>/dev/null)"; HOOK_RC=$?
kit_assert_eq '0' "$HOOK_RC" 'malformed event JSON does not wedge the edit hook'

kit_section 'checkpoint: clean tree'

P="$(project clean '{"full":["touch GATE_RAN"]}')"
run_hook "$CHECKPOINT" "$(event "$P")"; OUT="$HOOK_OUT"
kit_assert_eq '0' "$HOOK_RC" 'a clean tree allows the stop'
kit_assert_eq '' "$OUT" 'silently - there is nothing to verify'
kit_assert_file_absent "$P/GATE_RAN" 'and does not run the gate when nothing was edited'

kit_section 'checkpoint: dirty tree, passing gate'

P="$(project passing '{"full":["touch GATE_RAN","true"]}')"
run_hook "$SELFFIX" "$(event "$P")"
run_hook "$CHECKPOINT" "$(event "$P")"; OUT="$HOOK_OUT"
kit_assert_eq '0' "$HOOK_RC" 'a passing gate allows the stop'
kit_assert_eq '' "$OUT" 'and says nothing'
kit_assert_file_exists "$P/GATE_RAN" 'THE GATE REALLY RAN at completion time'
kit_state_load "$P"
kit_assert_eq '0' "$KIT_STATE_DIRTY" 'and a passing gate clears the dirty flag'

kit_section 'checkpoint: dirty tree, FAILING gate (fail closed)'

P="$(project failing '{"full":["echo \"src/app.py:12: error: broken thing\" >&2; exit 1"]}')"
run_hook "$SELFFIX" "$(event "$P")"
run_hook "$CHECKPOINT" "$(event "$P")"; OUT="$HOOK_OUT"
kit_assert_eq '0' "$HOOK_RC" 'the hook itself still exits 0 (the decision is in the JSON)'
printf '%s' "$OUT" | jq -e . >/dev/null 2>&1 \
  && kit_pass 'a failing gate emits valid JSON' \
  || kit_fail_test 'a failing gate emits valid JSON' "got: $OUT"
kit_assert_eq 'block' "$(printf '%s' "$OUT" | jq -r '.decision')" \
  'A CONFIGURED, FAILING GATE BLOCKS THE STOP'
REASON="$(printf '%s' "$OUT" | jq -r '.reason')"
kit_assert_contains "$REASON" 'src/app.py' 'the block reason names the failing file'
kit_assert_contains "$REASON" 'ROOT CAUSE' 'and demands a root-cause fix'
kit_assert_contains "$REASON" 'Do NOT silence' 'and forbids silencing the check'
kit_assert_contains "$REASON" 'Attempt 1 of 3' 'and reports which attempt this is'

kit_state_load "$P"
kit_assert_eq '1' "$KIT_STATE_ATTEMPTS" 'the attempt counter is persisted'
kit_assert_ne '' "$KIT_STATE_LAST_SIG" 'and the failure signature is recorded'

kit_section 'checkpoint: the loop brakes'

# BRAKE 2 - an identical failure twice running gives up rather than blocking a
# third time. This is the brake that fires first for a genuinely stuck agent.
run_hook "$CHECKPOINT" "$(event "$P")"; OUT="$HOOK_OUT"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // "none"')"
kit_assert_eq 'none' "$DEC" 'an IDENTICAL failure twice running stops blocking'
CTX="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""')"
kit_assert_contains "$CTX" 'not converging' 'and explains that the loop is not converging'
kit_assert_contains "$CTX" 'needs a human'  'and hands back to a human'

kit_state_load "$P"
kit_assert_eq '1' "$KIT_STATE_GAVE_UP" 'the give-up flag is persisted'

run_hook "$CHECKPOINT" "$(event "$P")"; OUT="$HOOK_OUT"
kit_assert_eq '' "$OUT" 'and once given up, it does not re-block on the next stop'

# BRAKE 1 - the attempt cap, exercised with a failure that CHANGES every run so
# brake 2 never fires.
#
# The variation must be NON-NUMERIC. The signature normaliser deliberately
# collapses every run of digits to '#', so "error 12345" and "error 99999"
# share a signature - which is correct (a changing line number is not a
# different bug) and means $RANDOM cannot be used to fake a novel failure here.
P="$(project varying '{"full":["echo \"error in module-$(tr -dc a-z </dev/urandom | head -c8) unique\" >&2; exit 1"],"maxRepairAttempts":3}')"
BLOCKS=0
for i in 1 2 3 4 5 6; do
  run_hook "$SELFFIX" "$(event "$P")"
  run_hook "$CHECKPOINT" "$(event "$P")"; OUT="$HOOK_OUT"
  [[ "$(printf '%s' "$OUT" | jq -r '.decision // "none"')" == 'block' ]] && BLOCKS=$((BLOCKS+1))
done
kit_assert_eq '3' "$BLOCKS" 'an always-different failure blocks at most maxRepairAttempts times'

# BRAKE 3 - stop_hook_active is honoured on entry.
P="$(project active '{"full":["exit 1"]}')"
run_hook "$SELFFIX" "$(event "$P")"
run_hook "$CHECKPOINT" "$(event "$P" true)"; OUT="$HOOK_OUT"
kit_assert_eq '' "$OUT" 'stop_hook_active is honoured as an independent brake'

kit_section 'checkpoint: fail OPEN where blocking would deadlock'

# A project that never opted in must not be blocked: the agent would have no way
# to satisfy a check that does not exist.
P="$WORK/unconfigured"; mkdir -p "$P/.claude"
printf '{"fast":[],"full":[]}\n' > "$P/.claude/gate.json"
run_hook "$SELFFIX" "$(event "$P")"
run_hook "$CHECKPOINT" "$(event "$P")"; OUT="$HOOK_OUT"
kit_assert_ne 'block' "$(printf '%s' "$OUT" | jq -r '.decision // "none"')" \
  'AN UNCONFIGURED GATE DOES NOT BLOCK - that would deadlock the project'
CTX="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""')"
kit_assert_contains "$CTX" 'no usable validation gate' 'but it says so loudly rather than pretending'
kit_assert_contains "$CTX" 'nothing verified these edits' 'and never claims the work was validated'

# A project with no .claude at all is simply not ours.
NOGATE="$WORK/nothing"; mkdir -p "$NOGATE"
run_hook "$CHECKPOINT" "$(event "$NOGATE")"; OUT="$HOOK_OUT"
kit_assert_eq '0' "$HOOK_RC" 'a project outside the kit is left entirely alone'
kit_assert_eq '' "$OUT" 'and nothing is printed'

# A gate whose command cannot start is a broken gate, not failing work.
P="$(project nocmd '{"full":["this-command-does-not-exist-anywhere"]}')"
run_hook "$SELFFIX" "$(event "$P")"
run_hook "$CHECKPOINT" "$(event "$P")"; OUT="$HOOK_OUT"
CTX="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""')"
DEC="$(printf '%s' "$OUT" | jq -r '.decision // "none"')"
# Either shape is defensible; what matters is that it does not silently pass.
if [[ "$DEC" == 'block' ]]; then
  kit_pass 'a gate command that does not exist is surfaced, not ignored'
else
  kit_assert_contains "$CTX" 'could not run' 'a gate command that does not exist is surfaced, not ignored'
fi

kit_section 'checkpoint: robustness'

HOOK_OUT="$(printf 'not json' | bash "$CHECKPOINT" 2>/dev/null)"; HOOK_RC=$?
kit_assert_eq '0' "$HOOK_RC" 'malformed event JSON never wedges a session'

HOOK_OUT="$(printf '' | bash "$CHECKPOINT" 2>/dev/null)"; HOOK_RC=$?
kit_assert_eq '0' "$HOOK_RC" 'empty stdin never wedges a session'

# A gate that hangs must be torn down by the runner's timeout rather than
# hanging the stop forever. Uses a short timeout via the gate config.
P="$(project slow '{"full":["sleep 300"],"timeoutSec":3}')"
run_hook "$SELFFIX" "$(event "$P")"
START="$(date +%s)"
( printf '%s' "$(event "$P")" | timeout 30 bash "$CHECKPOINT" >/dev/null 2>&1 ) || true
ELAPSED=$(( $(date +%s) - START ))
[[ "$ELAPSED" -lt 30 ]] \
  && kit_pass "a hanging gate does not hang the stop forever (returned in ${ELAPSED}s)" \
  || kit_fail_test 'a hanging gate does not hang the stop forever' "took ${ELAPSED}s"

kit_test_summary
