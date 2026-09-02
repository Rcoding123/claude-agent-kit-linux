#!/usr/bin/env bash
# test-process.sh - the kill-boundary and exit-code contract.
#
# These are the tests that matter most in the kit. Two of them exist because the
# implementation failed them during development, and both failures were SILENT:
#
#   1. Plain `setsid` (no --wait) forks and the wrapper exits 0 immediately, so
#      every command reported success. A gate that always passes is worse than
#      no gate; only an assertion on a nonzero exit code catches it.
#   2. In the process-group fallback, `ps --ppid $wrapper` briefly reports the
#      WRAPPER'S pgid before the real command is forked. Latching that plausible
#      wrong answer made teardown miss the whole tree, leaking processes on
#      every timeout.
#
# The containment cases run repeatedly, because a race that leaks 1 run in 10 is
# more dangerous than one that leaks every time.

set -uo pipefail

TEST_DIR="$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KIT_ROOT="$(dirname -- "$TEST_DIR")"
source "$TEST_DIR/kit-test-lib.sh"
source "$KIT_ROOT/lib/kit-process.sh"

WORK="$(mktemp -d)"
trap 'pkill -9 -f "$WORK/sleeper.sh" 2>/dev/null; rm -rf -- "$WORK"' EXIT

cat > "$WORK/sleeper.sh" <<'EOF'
#!/bin/bash
exec sleep 300
EOF
chmod +x "$WORK/sleeper.sh"

# --- exit code fidelity -------------------------------------------------------
# The child's real exit code must arrive unchanged. This is what catches the
# plain-setsid always-green failure.
for code in 0 1 2 3 17 42 127; do
  kit_run_shell "exit $code" >/dev/null 2>&1
  kit_assert_eq "$code" "$KIT_PROC_EXIT_CODE" "exit code $code survives (cgroup path)"
done

kit_assert_eq 'success' "$(kit_run_shell 'true' >/dev/null 2>&1; printf '%s' "$KIT_PROC_STATUS")" \
  'exit 0 reports status=success'
kit_assert_eq 'failure' "$(kit_run_shell 'exit 5' >/dev/null 2>&1; printf '%s' "$KIT_PROC_STATUS")" \
  'nonzero exit reports status=failure'

# --- stream separation --------------------------------------------------------
kit_run_shell 'echo OUT; echo ERR >&2' >/dev/null 2>&1
kit_assert_eq 'OUT' "$KIT_PROC_STDOUT" 'stdout captured separately'
kit_assert_eq 'ERR' "$KIT_PROC_STDERR" 'stderr captured separately'

# Neither stream may be lost when both are large - the classic deadlock is
# reading one to EOF before starting on the other.
kit_run_shell 'for i in $(seq 1 4000); do echo "out line $i"; echo "err line $i" >&2; done' \
  --max-output 200000 >/dev/null 2>&1
kit_assert_contains "$KIT_PROC_STDOUT" 'out line 4000' 'large stdout not truncated by deadlock'
kit_assert_contains "$KIT_PROC_STDERR" 'err line 4000' 'large stderr not truncated by deadlock'

# --- output bounding ----------------------------------------------------------
# Bounding must keep BOTH ends: a compiler puts the real error first, a test
# runner puts the summary last. Losing either end defeats the repair loop.
kit_run_shell 'echo FIRSTMARKER; for i in $(seq 1 5000); do echo "filler $i"; done; echo LASTMARKER' \
  --max-output 2000 >/dev/null 2>&1
kit_assert_contains "$KIT_PROC_STDOUT" 'FIRSTMARKER' 'bounded output keeps the head'
kit_assert_contains "$KIT_PROC_STDOUT" 'LASTMARKER'  'bounded output keeps the tail'
kit_assert_contains "$KIT_PROC_STDOUT" 'omitted'     'bounded output says how much was dropped'

# --- working directory --------------------------------------------------------
kit_run_shell 'pwd' --cwd "$WORK" >/dev/null 2>&1
kit_assert_eq "$(cd "$WORK" && pwd)" "$KIT_PROC_STDOUT" 'runs in the requested working directory'

kit_run_shell 'true' --cwd "$WORK/definitely-not-here" >/dev/null 2>&1
kit_assert_eq 'spawn-failure' "$KIT_PROC_STATUS" 'missing cwd is a spawn-failure, not a fake exit code'

# --- timeout ------------------------------------------------------------------
kit_run_shell 'sleep 60' --timeout 1 >/dev/null 2>&1
kit_assert_eq 'timeout' "$KIT_PROC_STATUS" 'a slow command times out'
kit_assert_eq '124'     "$KIT_PROC_EXIT_CODE" 'timeout reports the conventional 124'

# A timeout must not be reported for a command that finished in time.
kit_run_shell 'sleep 0.2' --timeout 30 >/dev/null 2>&1
kit_assert_eq 'success' "$KIT_PROC_STATUS" 'a fast command is not reported as timed out'

# --- raw log ------------------------------------------------------------------
LOG="$WORK/raw.log"
kit_run_shell 'echo logged-stdout; echo logged-stderr >&2; exit 3' --log "$LOG" >/dev/null 2>&1
kit_assert_file_exists "$LOG" 'raw log is written'
kit_assert_contains "$(cat "$LOG")" 'logged-stdout' 'raw log carries stdout'
kit_assert_contains "$(cat "$LOG")" 'logged-stderr' 'raw log carries stderr'
kit_assert_contains "$(cat "$LOG")" 'exit=3'        'raw log records the real exit code'
kit_assert_contains "$(cat "$LOG")" 'boundary='     'raw log records which boundary was used'

# --- THE CONTAINMENT CONTRACT -------------------------------------------------
# A timeout must tear down the ENTIRE tree: child, grandchild, great-grandchild.
# Repeated, because the bug this catches was a startup race.
# Reports the boundary used via the global KIT_LAST_BOUNDARY rather than by
# printing it: this function also emits pass/fail lines, and command
# substitution would swallow those into the caller's variable.
KIT_LAST_BOUNDARY=''
containment_case() {   # containment_case <label> <disable_cgroup 0|1> <runs>
  local label="$1" disable="$2" runs="$3"
  local leaked=0 wrong_status=0 i surv boundary=''
  for (( i = 0; i < runs; i++ )); do
    boundary="$(
      if [[ "$disable" == "1" ]]; then export KIT_DISABLE_CGROUP=1; fi
      # A deliberately awkward tree: a background grandchild AND a nested shell
      # that itself backgrounds a great-grandchild.
      kit_run_shell "\"$WORK/sleeper.sh\" & bash -c '\"$WORK/sleeper.sh\" & \"$WORK/sleeper.sh\"'" \
        --timeout 1 >/dev/null 2>&1
      printf '%s|%s' "$KIT_PROC_STATUS" "$KIT_PROC_BOUNDARY"
    )"
    [[ "${boundary%%|*}" == "timeout" ]] || wrong_status=$((wrong_status+1))
    sleep 0.4
    surv="$(pgrep -f "$WORK/sleeper.sh" 2>/dev/null | wc -l)"
    (( surv > 0 )) && leaked=$((leaked+1))
    pkill -9 -f "$WORK/sleeper.sh" 2>/dev/null
    sleep 0.15
  done
  kit_assert_eq '0' "$wrong_status" "$label: every run reported status=timeout ($runs runs)"
  kit_assert_eq '0' "$leaked"       "$label: no run leaked a process ($runs runs)"
  KIT_LAST_BOUNDARY="${boundary##*|}"
}

containment_case 'cgroup boundary' 0 5
kit_assert_eq 'cgroup' "$KIT_LAST_BOUNDARY" 'cgroup boundary is selected when a delegated subtree exists'

containment_case 'pgroup fallback' 1 5
kit_assert_eq 'pgroup' "$KIT_LAST_BOUNDARY" 'pgroup boundary is selected when cgroups are disabled'

# --- boundary is announced, never silently downgraded -------------------------
kit_run_shell 'true' >/dev/null 2>&1
kit_assert_matches "$KIT_PROC_BOUNDARY" '^(cgroup|pgroup)$' 'boundary is always reported to the caller'

( export KIT_DISABLE_CGROUP=1
  source "$KIT_ROOT/lib/kit-process.sh"
  kit_run_shell 'true' >/dev/null 2>&1
  [[ "$KIT_PROC_BOUNDARY" == 'pgroup' ]] ) \
  && kit_pass 'KIT_DISABLE_CGROUP forces the fallback (so it is testable everywhere)' \
  || kit_fail_test 'KIT_DISABLE_CGROUP forces the fallback'

# --- background survivors on a CLEAN exit -------------------------------------
# A command that exits 0 but leaves a daemon behind must still be torn down,
# otherwise a gate run holds its own log file open forever.
kit_run_shell "\"$WORK/sleeper.sh\" & exit 0" >/dev/null 2>&1
kit_assert_eq 'success' "$KIT_PROC_STATUS" 'clean exit with a background child still succeeds'
sleep 0.4
kit_assert_eq '0' "$(pgrep -f "$WORK/sleeper.sh" 2>/dev/null | wc -l)" \
  'background children are torn down even on a successful exit'

kit_test_summary
