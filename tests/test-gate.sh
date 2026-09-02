#!/usr/bin/env bash
# test-gate.sh - gate configuration, state, signatures, diagnostics, bounding.
#
# The fail-open / fail-closed split is asserted in both directions here, because
# getting it backwards is silent in both cases:
#   - a configured, failing gate that fails OPEN lets broken work be called done
#   - an unconfigured gate that fails CLOSED deadlocks a project with no way for
#     the agent to satisfy a check that does not exist

set -uo pipefail

TEST_DIR="$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KIT_ROOT="$(dirname -- "$TEST_DIR")"
source "$TEST_DIR/kit-test-lib.sh"
source "$KIT_ROOT/lib/kit-gate.sh"

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

new_project() {  # new_project <name> -> prints root
  local root="$WORK/$1"
  mkdir -p "$root/.claude"
  printf '%s' "$root"
}

kit_section 'gate.json parsing'

P="$(new_project parse)"
cat > "$P/.claude/gate.json" <<'EOF'
{
  "language": "python",
  "fast": ["echo one", "echo 'two with spaces'"],
  "full": ["echo full-a", "echo full-b"],
  "maxRepairAttempts": 5
}
EOF
kit_gate_config "$P"
kit_assert_eq '1' "$KIT_GATE_OK"                     'a populated gate.json is usable'
kit_assert_eq '2' "${#KIT_GATE_FAST[@]}"             'fast list parsed'
kit_assert_eq '2' "${#KIT_GATE_FULL[@]}"             'full list parsed'
kit_assert_eq "echo 'two with spaces'" "${KIT_GATE_FAST[1]}" 'a command with quotes survives parsing intact'
kit_assert_eq '5' "$KIT_GATE_MAX_REPAIR"             'maxRepairAttempts honoured'
kit_assert_eq 'python' "$KIT_GATE_LANGUAGE"          'language recorded'

# A command containing a newline must not be split into two commands.
P="$(new_project multiline)"
jq -n '{full: ["echo a\necho b"]}' > "$P/.claude/gate.json"
kit_gate_config "$P"
kit_assert_eq '1' "${#KIT_GATE_FULL[@]}"             'a multi-line command stays ONE command'
kit_assert_contains "${KIT_GATE_FULL[0]}" $'\n'      'the embedded newline is preserved'

kit_section 'gates that are not really gates'

# The failure this exists to prevent: a project that LOOKS wired and validates
# nothing.
P="$(new_project empty)"
echo '{"fast":[],"full":[]}' > "$P/.claude/gate.json"
kit_assert_fails 'an empty gate.json is refused, not treated as passing' kit_gate_config "$P"
kit_gate_config "$P" 2>/dev/null || true
kit_assert_contains "$KIT_GATE_REASON" 'NO validation configured' 'and it says so in plain words'

P="$(new_project badjson)"
echo '{ not json at all' > "$P/.claude/gate.json"
kit_assert_fails 'unparseable gate.json is refused' kit_gate_config "$P"

P="$(new_project emptytxt)"
printf '   \n\n' > "$P/.claude/gate.txt"
kit_assert_fails 'an empty legacy gate.txt is refused' kit_gate_config "$P"

P="$(new_project nogate)"
kit_assert_fails 'a project with no gate file at all is not configured' kit_gate_config "$P"

kit_section 'legacy gate.txt'

P="$(new_project legacy)"
echo 'echo legacy-command' > "$P/.claude/gate.txt"
kit_gate_config "$P"
kit_assert_eq '1' "$KIT_GATE_OK"                       'gate.txt is accepted'
kit_assert_eq 'echo legacy-command' "${KIT_GATE_FULL[0]}" 'gate.txt becomes the FULL gate'
kit_assert_eq '0' "${#KIT_GATE_FAST[@]}"               'gate.txt defines no fast gate'

kit_section 'project root discovery'

P="$(new_project rootwalk)"
mkdir -p "$P/src/deep/deeper"
echo '{"full":["true"]}' > "$P/.claude/gate.json"
kit_assert_eq "$P" "$(kit_find_project_root "$P/src/deep/deeper")" 'root is found by walking up'
kit_assert_eq "$P" "$(kit_find_project_root "$P")"                 'root is found from the root itself'
kit_assert_fails 'a directory with no gate anywhere above it returns failure' \
  kit_find_project_root /

kit_section 'state'

P="$(new_project state)"
echo '{"full":["true"]}' > "$P/.claude/gate.json"
kit_state_load "$P"
kit_assert_eq '0' "$KIT_STATE_DIRTY" 'a fresh project starts clean'

kit_state_mark_dirty "$P"
kit_state_load "$P"
kit_assert_eq '1' "$KIT_STATE_DIRTY" 'an edit marks it dirty'
kit_assert_eq '1' "$KIT_STATE_EDITS" 'and counts the edit'

kit_state_mark_dirty "$P"; kit_state_mark_dirty "$P"
kit_state_load "$P"
kit_assert_eq '3' "$KIT_STATE_EDITS" 'edits accumulate'
kit_assert_json "$(kit_state_path "$P")" 'state file is valid JSON'

kit_state_clear_dirty "$P"
kit_state_load "$P"
kit_assert_eq '0' "$KIT_STATE_DIRTY"    'a passing gate clears dirty'
kit_assert_eq '0' "$KIT_STATE_EDITS"    'and resets the edit count'
kit_assert_eq '0' "$KIT_STATE_ATTEMPTS" 'and resets repair attempts'

# A corrupt state file must not wedge the hook - it degrades to defaults.
echo 'not json' > "$(kit_state_path "$P")"
kit_state_load "$P"
kit_assert_eq '0' "$KIT_STATE_DIRTY" 'a corrupt state file degrades to clean defaults'

kit_section 'failure signatures'

SIG_A="$(kit_failure_signature 'make' 2 'out' 'error: undefined reference to foo')"
SIG_B="$(kit_failure_signature 'make' 2 'out' 'error: undefined reference to foo')"
kit_assert_eq "$SIG_A" "$SIG_B" 'the same failure produces the same signature'

SIG_C="$(kit_failure_signature 'make' 2 'out' 'error: undefined reference to BAR')"
kit_assert_ne "$SIG_A" "$SIG_C" 'a different failure produces a different signature'

# Volatile detail must NOT change the signature, or loop detection never fires.
SIG_D="$(kit_failure_signature 'make' 2 'out' 'error at /home/alice/proj/src/x.c:42 undefined reference to foo')"
SIG_E="$(kit_failure_signature 'make' 2 'out' 'error at /home/bob/other/src/x.c:99 undefined reference to foo')"
kit_assert_eq "$SIG_D" "$SIG_E" 'paths and line numbers are normalised out'

SIG_F="$(kit_failure_signature 'make' 2 'out' 'crash at 0xdeadbeef')"
SIG_G="$(kit_failure_signature 'make' 2 'out' 'crash at 0xcafef00d')"
kit_assert_eq "$SIG_F" "$SIG_G" 'hex addresses are normalised out'

SIG_H="$(kit_failure_signature 'make'  2 'o' 'e')"
SIG_I="$(kit_failure_signature 'cmake' 2 'o' 'e')"
kit_assert_ne "$SIG_H" "$SIG_I" 'a different command is a different signature'

SIG_J="$(kit_failure_signature 'make' 1 'o' 'e')"
SIG_K="$(kit_failure_signature 'make' 2 'o' 'e')"
kit_assert_ne "$SIG_J" "$SIG_K" 'a different exit code is a different signature'

kit_assert_matches "$SIG_A" '^[0-9a-f]{16}$' 'signature is a short stable hex digest'

kit_section 'repair decision (the loop brakes)'

kit_assert_eq 'block' "$(kit_repair_decision 'sigA' '' 0 0 3)" \
  'a first, novel failure blocks so the agent can repair it'
kit_assert_eq 'block' "$(kit_repair_decision 'sigB' 'sigA' 0 1 3)" \
  'a DIFFERENT failure after a repair blocks again - progress is being made'

# The subtle one: on the second identical failure the caller has not yet
# incremented the repeat count, so this must key on the signatures alone.
kit_assert_eq 'give-up-repeat' "$(kit_repair_decision 'sigA' 'sigA' 0 1 3)" \
  'an identical failure twice running gives up IMMEDIATELY, not a cycle later'

kit_assert_eq 'give-up-attempts' "$(kit_repair_decision 'sigC' 'sigB' 0 3 3)" \
  'the attempt cap gives up'
kit_assert_eq 'give-up-attempts' "$(kit_repair_decision 'sigC' 'sigB' 0 9 3)" \
  'the attempt cap gives up when overshot'
kit_assert_eq 'block' "$(kit_repair_decision 'sigC' 'sigB' 0 2 3)" \
  'one attempt below the cap still blocks'

# An empty signature (a command that failed with no output at all) must not
# be mistaken for "same as last time".
kit_assert_eq 'block' "$(kit_repair_decision '' '' 0 0 3)" \
  'two empty signatures are not treated as a repeat'

kit_section 'running a gate'

P="$(new_project run)"
jq -n '{full: ["true", "true"], fast: ["true"]}' > "$P/.claude/gate.json"
kit_assert_ok 'a passing full gate returns success' kit_run_gate "$P" full
kit_run_gate "$P" full
kit_assert_eq '2' "$KIT_GATE_RESULT_RAN" 'every command in a passing gate runs'

P="$(new_project failfast)"
jq -n '{full: ["true", "exit 3", "touch SHOULD_NOT_EXIST"]}' > "$P/.claude/gate.json"
kit_assert_fails 'a failing full gate returns failure' kit_run_gate "$P" full
kit_run_gate "$P" full
kit_assert_eq '2' "$KIT_GATE_RESULT_RAN" 'the gate stops at the FIRST failure'
kit_assert_file_absent "$P/SHOULD_NOT_EXIST" 'commands after a failure never run'
kit_assert_eq '3' "$KIT_PROC_EXIT_CODE"      'the failing command real exit code is preserved'

# A fast-only project must not have its full gate silently satisfied by the
# fast one, nor the reverse.
P="$(new_project fastonly)"
jq -n '{fast: ["true"]}' > "$P/.claude/gate.json"
kit_run_gate "$P" full
kit_assert_eq 'no full gate configured' "$KIT_GATE_RESULT_REASON" \
  'a fast-only project reports that no full gate ran'

P="$(new_project fullonly)"
jq -n '{full: ["true"]}' > "$P/.claude/gate.json"
kit_run_gate "$P" fast
kit_assert_eq 'no fast gate configured' "$KIT_GATE_RESULT_REASON" \
  'a full-only project does NOT silently run the full gate as its fast gate'

# Logs are written and pruned.
P="$(new_project logs)"
jq -n '{full: ["echo hello"]}' > "$P/.claude/gate.json"
kit_run_gate "$P" full
kit_assert_eq '1' "$(ls -1 "$P/.claude/gate-logs"/*.log 2>/dev/null | wc -l)" 'a gate run writes a log'

mkdir -p "$P/.claude/gate-logs"
for i in $(seq 1 60); do touch "$P/.claude/gate-logs/old-$i.log"; done
kit_prune_logs "$P/.claude/gate-logs" 40
LOGN="$(ls -1 "$P/.claude/gate-logs"/*.log 2>/dev/null | wc -l)"
[[ "$LOGN" -le 40 ]] && kit_pass 'gate logs are pruned so they cannot fill the disk' \
                     || kit_fail_test 'gate logs are pruned' "found $LOGN logs"

kit_section 'diagnostics'

kit_run_shell 'echo "src/main.c: error: undefined reference to foo"; exit 1' >/dev/null 2>&1
DIAG="$(kit_concise_diagnostics)"
kit_assert_contains "$DIAG" 'FAILED:'            'diagnostics name the failing command'
kit_assert_contains "$DIAG" 'exit: 1'            'diagnostics carry the real exit code'
kit_assert_contains "$DIAG" 'undefined reference' 'diagnostics carry the error text'

# THE regression that matters: a small failure must not be filtered down to the
# keyword line, because the LOCATION line often carries no keyword of its own.
kit_run_shell 'echo "F401 unused import"; echo "  --> src/lint_me.py:1:8"; exit 1' >/dev/null 2>&1
DIAG="$(kit_concise_diagnostics)"
kit_assert_contains "$DIAG" 'src/lint_me.py' 'a small failure keeps its location line, not just its keyword line'

# A large failure is bounded, but the keyword lines keep their context.
kit_run_shell 'for i in $(seq 1 300); do echo "noise $i"; done; echo "error: real problem here"; echo "  --> at src/thing.py:12"; exit 1' \
  >/dev/null 2>&1
DIAG="$(kit_concise_diagnostics 40)"
kit_assert_contains "$DIAG" 'real problem here' 'a large failure keeps the error line'
kit_assert_contains "$DIAG" 'src/thing.py'      'and keeps the location line next to it'
DIAGN="$(printf '%s\n' "$DIAG" | wc -l)"
[[ "$DIAGN" -lt 80 ]] && kit_pass 'a large failure is bounded' \
                      || kit_fail_test 'a large failure is bounded' "got $DIAGN lines"

kit_run_shell 'sleep 30' --timeout 1 >/dev/null 2>&1
DIAG="$(kit_concise_diagnostics)"
kit_assert_contains "$DIAG" 'timed out'  'a timeout is described as a timeout, not exit 124'
kit_assert_contains "$DIAG" 'torn down'  'and says the process tree was torn down'

kit_test_summary
