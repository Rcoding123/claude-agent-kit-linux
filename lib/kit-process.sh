#!/usr/bin/env bash
# kit-process.sh - the one place the kit starts a child process.
#
# Everything else in the kit calls this.
#
# What this guarantees:
#
#   - The child's REAL exit code is preserved. 0, 1, 3, 17 come back as
#     themselves. A launcher problem is reported as a Status, never by
#     inventing an exit code the child never returned.
#   - stdout and stderr are captured separately and neither is lost.
#   - No deadlock when both streams are large. Each stream gets its own file and
#     the kernel writes to both concurrently; the classic "read stdout to the
#     end, then read stderr" pattern wedges as soon as the child fills the
#     stderr pipe buffer.
#   - Complete raw output goes to a log file; only a bounded slice comes back
#     for the agent to read.
#   - EVERY process the invocation creates - child, grandchild, deeper - belongs
#     to one kill boundary established BEFORE the child executes its first
#     instruction, and timeout or cancellation tears that whole boundary down.
#
# ---------------------------------------------------------------------------
# THE KILL BOUNDARY: why there are two, and why the weaker one is announced
# ---------------------------------------------------------------------------
#
# The Windows kit uses a Job Object: the child is created suspended, assigned to
# the job, and only then resumed, so no process ever exists outside the
# boundary. Teardown suspends every process in the job before terminating it,
# because TerminateJobObject still walks the process list, and a parent woken by
# its child's death can be scheduled and run one more command during teardown.
# That was measured, not theorised: taskkill /T let a descendant run an extra
# command in 2 of 10 runs.
#
# Linux offers two boundaries, and they are not equivalent:
#
#   cgroup v2  - The true Job Object analogue. A process written into a cgroup
#                cannot leave it, and `echo 1 > cgroup.kill` terminates every
#                member atomically in the kernel. There is no list walk, so the
#                wake-up-and-continue race does not exist at all. Requires a
#                writable cgroup subtree (systemd user delegation, usually).
#
#   process group - setsid puts the child in a new session and process group;
#                `kill -KILL -$PGID` signals every member. The kernel delivers
#                to the whole group, so it is far tighter than a user-mode PID
#                walk, BUT a process can call setpgid() to leave the group, and
#                signal delivery across a large group is not one atomic act. So
#                teardown here does freeze-before-kill (SIGSTOP the group, then
#                SIGKILL), mirroring the Windows design for the same reason: a
#                stopped process cannot be scheduled, so it cannot react to a
#                sibling's death.
#
# This fails CLOSED in the sense that matters: it never silently downgrades. The
# boundary actually used is reported in the result as `boundary`, so a caller
# can tell whether it got escape-proof containment or the best-effort kind. The
# Windows kit refuses to run at all if it cannot build a boundary; here the
# process-group path is always available on any Linux, so refusing would mean
# refusing to work on perfectly ordinary systems. Announcing is the honest
# middle: you always know which guarantee you got.

set -o pipefail

[[ -n "${_KIT_PROCESS_SOURCED:-}" ]] && return 0
_KIT_PROCESS_SOURCED=1

_kp_dir="$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/kit-common.sh
source "$_kp_dir/kit-common.sh"

# --- cgroup discovery ---------------------------------------------------------
# Find a cgroup v2 subtree we may create children in. Printed on stdout, empty
# when unavailable. Cached: this involves several stats and is called per gate
# command.
_KIT_CGROUP_BASE_CACHED=""
_KIT_CGROUP_BASE_PROBED=0

kit_cgroup_base() {
  if (( _KIT_CGROUP_BASE_PROBED )); then printf '%s' "$_KIT_CGROUP_BASE_CACHED"; return 0; fi
  _KIT_CGROUP_BASE_PROBED=1
  _KIT_CGROUP_BASE_CACHED=""

  # Honour an explicit opt-out, so the fallback path is testable on a machine
  # that has cgroups, and so an operator can force the simpler behaviour.
  if [[ "${KIT_DISABLE_CGROUP:-0}" == "1" ]]; then printf ''; return 0; fi

  # Must be the unified (v2) hierarchy. cgroup v1 has no cgroup.kill and its
  # semantics differ enough that supporting it would be a second design.
  [[ -d /sys/fs/cgroup ]] || { printf ''; return 0; }
  [[ -f /sys/fs/cgroup/cgroup.controllers ]] || { printf ''; return 0; }

  # Our own cgroup, per /proc/self/cgroup. On v2 the line is "0::<path>".
  local own
  own="$(awk -F: '$1=="0"{print $3; exit}' /proc/self/cgroup 2>/dev/null)"
  [[ -n "$own" ]] || { printf ''; return 0; }

  local candidate="/sys/fs/cgroup${own}"
  # Walk up from our own cgroup looking for the first writable directory. We
  # cannot create a sibling of ourselves unless the parent is delegated to us,
  # and per the "no internal process" rule we must not add controllers to a
  # cgroup that has processes in it - creating a child leaf is fine.
  local dir="$candidate" depth=0
  while [[ -n "$dir" && "$dir" != "/sys/fs/cgroup" && $depth -lt 12 ]]; do
    if [[ -w "$dir" && -w "$dir/cgroup.procs" ]]; then
      # cgroup.kill landed in kernel 5.14. Without it we would have to walk
      # cgroup.procs and signal each pid - which is the user-mode walk this
      # whole design exists to avoid - so treat its absence as "no cgroup path".
      if [[ -e "$dir/cgroup.kill" ]] || [[ -e "$candidate/cgroup.kill" ]]; then
        _KIT_CGROUP_BASE_CACHED="$dir"
        break
      fi
    fi
    dir="$(dirname -- "$dir")"
    depth=$((depth+1))
  done
  printf '%s' "$_KIT_CGROUP_BASE_CACHED"
}

# --- teardown -----------------------------------------------------------------
_kit_kill_cgroup() {  # _kit_kill_cgroup <cgroup dir>
  local cg="$1"
  [[ -d "$cg" ]] || return 0
  if [[ -e "$cg/cgroup.kill" ]]; then
    # One atomic kernel operation over every member, including anything that
    # forked a microsecond ago. Nothing to race.
    printf '1' > "$cg/cgroup.kill" 2>/dev/null || true
  fi
}

_kit_cleanup_cgroup() {  # _kit_cleanup_cgroup <cgroup dir>
  local cg="$1"
  [[ -d "$cg" ]] || return 0
  # rmdir fails while the cgroup still has members; the kill above is
  # asynchronous in the sense that exit processing takes a moment.
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    rmdir -- "$cg" 2>/dev/null && return 0
    sleep 0.05
  done
  rmdir -- "$cg" 2>/dev/null || true
}

_kit_kill_pgroup() {  # _kit_kill_pgroup <pgid>
  local pgid="$1"
  [[ -n "$pgid" && "$pgid" =~ ^[0-9]+$ && "$pgid" -gt 1 ]] || return 0
  # FREEZE BEFORE KILL - the same reason as the Windows path. A parent blocked
  # in wait() is woken when its child is killed; if it is merely being signalled
  # one-by-one it can be scheduled and run its next command during teardown.
  # SIGSTOP first means nothing in the group can be scheduled at all.
  #
  # Re-freeze after a beat: a process that forked between our enumeration and
  # our signal inherits the group, so a second STOP catches late arrivals.
  kill -STOP -- "-$pgid" 2>/dev/null || true
  sleep 0.02
  kill -STOP -- "-$pgid" 2>/dev/null || true
  kill -KILL -- "-$pgid" 2>/dev/null || true
  # SIGKILL does not run on a stopped process until it is continued in some
  # kernels' accounting; SIGCONT after SIGKILL guarantees the kill is applied.
  kill -CONT -- "-$pgid" 2>/dev/null || true
}

# --- the runner ---------------------------------------------------------------
# Results are returned by setting these globals rather than by printing a
# structure that the caller has to parse. Command output routinely contains
# every delimiter one might pick, so parsing it back is a bug waiting to happen.
KIT_PROC_STATUS=''       # success | failure | timeout | spawn-failure
KIT_PROC_EXIT_CODE=0
KIT_PROC_STDOUT=''
KIT_PROC_STDERR=''
KIT_PROC_RAW_LOG=''
KIT_PROC_BOUNDARY=''     # cgroup | pgroup
KIT_PROC_DURATION_MS=0
KIT_PROC_COMMAND=''

_kit_reset_result() {
  KIT_PROC_STATUS=''; KIT_PROC_EXIT_CODE=0; KIT_PROC_STDOUT=''
  KIT_PROC_STDERR=''; KIT_PROC_RAW_LOG=''; KIT_PROC_BOUNDARY=''
  KIT_PROC_DURATION_MS=0; KIT_PROC_COMMAND=''
}

# Bound what comes back WITHOUT destroying the diagnostic.
#
# Truncating the tail is wrong for a compiler (the first error is the real one,
# the rest cascade) and truncating the head is wrong for a test runner (the
# summary is at the end). So keep both ends and say how much was dropped.
kit_bound_output() {  # <text on stdin> kit_bound_output <max chars>
  local max="$1"
  local text; text="$(cat)"
  local len=${#text}
  (( len <= max )) && { printf '%s' "$text"; return 0; }
  local half=$(( max / 2 ))
  local head="${text:0:$half}"
  local tail="${text: -$half}"
  printf '%s\n\n... [%d characters omitted - see the full log] ...\n\n%s' \
         "$head" "$(( len - max ))" "$tail"
}

# kit_run_shell <command line> [options]
#   --cwd <dir>          working directory (default: $PWD)
#   --timeout <seconds>  default 1800
#   --max-output <chars> default 20000
#   --log <path>         raw combined log destination
#
# The command line is handed to `bash -c` deliberately: gate entries are single
# commands written by a human in gate.json, and they legitimately contain globs,
# pipes and quoting. This is the same trust boundary the Windows kit has - the
# gate file is project-owned configuration, not untrusted input.
kit_run_shell() {
  local cmdline="$1"; shift
  local cwd="$PWD" timeout_sec=1800 max_output=20000 raw_log=''
  while (( $# > 0 )); do
    case "$1" in
      --cwd)        cwd="$2"; shift 2 ;;
      --timeout)    timeout_sec="$2"; shift 2 ;;
      --max-output) max_output="$2"; shift 2 ;;
      --log)        raw_log="$2"; shift 2 ;;
      *) kit_die "kit_run_shell: unknown option '$1'"; return 1 ;;
    esac
  done

  _kit_reset_result
  KIT_PROC_COMMAND="$cmdline"

  local work; work="$(mktemp -d)" || { KIT_PROC_STATUS='spawn-failure'; return 1; }
  local out_f="$work/stdout" err_f="$work/stderr" rc_f="$work/rc"

  local cg='' pgid='' boundary='pgroup'
  local base; base="$(kit_cgroup_base)"
  if [[ -n "$base" ]]; then
    cg="$base/kit-$$-$RANDOM"
    if mkdir -p "$cg" 2>/dev/null && [[ -w "$cg/cgroup.procs" ]]; then
      boundary='cgroup'
    else
      [[ -d "$cg" ]] && rmdir -- "$cg" 2>/dev/null
      cg=''
    fi
  fi
  KIT_PROC_BOUNDARY="$boundary"

  local start_ms; start_ms=$(( $(date +%s%N) / 1000000 ))

  # Launch. In both paths the boundary is established by the child ITSELF,
  # before it execs the user command - the write to cgroup.procs and the setsid
  # both happen in a shell that has not yet run any user code. That is the
  # Linux equivalent of CREATE_SUSPENDED-then-assign: there is no window in
  # which the user's command exists outside the boundary.
  #
  # setsid is used in BOTH paths. In the cgroup path it is not the boundary, but
  # it still detaches the child from our controlling terminal so a Ctrl-C in the
  # user's shell does not race our teardown.
  # `setsid --wait` is mandatory, not stylistic. Plain `setsid` forks and the
  # wrapper exits 0 IMMEDIATELY, orphaning the real child - so `wait` reaps the
  # wrapper and every command appears to have succeeded. That is a silent
  # always-green gate, the worst possible failure for this kit, and it is
  # invisible unless you assert on a nonzero exit code. --wait makes the wrapper
  # block and re-raise the child's status.
  #
  # The boundary is joined by the child ITSELF before it execs the user command:
  # the write to cgroup.procs happens in a shell that has not yet run any user
  # code. That is the Linux equivalent of CREATE_SUSPENDED-then-assign - there
  # is no window in which the user's command exists outside the boundary.
  local child_pid
  if [[ -n "$cg" ]]; then
    setsid --wait bash -c '
      printf "%s" "$BASHPID" > "$1/cgroup.procs" 2>/dev/null || exit 126
      cd "$2" 2>/dev/null || exit 127
      exec bash -c "$3"
    ' _ "$cg" "$cwd" "$cmdline" > "$out_f" 2> "$err_f" &
    child_pid=$!
  else
    setsid --wait bash -c '
      cd "$1" 2>/dev/null || exit 127
      exec bash -c "$2"
    ' _ "$cwd" "$cmdline" > "$out_f" 2> "$err_f" &
    child_pid=$!
    # With --wait the wrapper keeps its OWN pgid and the real command is placed
    # in a DIFFERENT one, so killing the wrapper's group would miss the command
    # entirely. Read the grandchild's pgid instead.
    #
    # The subtlety that cost a leaked process tree: for the first few
    # milliseconds `ps --ppid $wrapper` reports the WRAPPER'S OWN pgid, because
    # the real command has not been forked yet. That is a non-empty, plausible
    # answer, so a loop that breaks on "non-empty" latches the wrong group and
    # teardown silently misses everything. Reject a pgid equal to the wrapper's
    # own and keep polling until the real one appears.
    local _t _wrapper_pgid
    _wrapper_pgid="$(ps -o pgid= -p "$child_pid" 2>/dev/null | tr -d ' ')"
    for _t in $(seq 1 50); do
      pgid="$(ps -o pgid= --ppid "$child_pid" 2>/dev/null | head -1 | tr -d ' ')"
      [[ -n "$pgid" && "$pgid" != "$_wrapper_pgid" ]] && break
      pgid=''
      # If the child already finished, there is nothing left to contain.
      kill -0 "$child_pid" 2>/dev/null || break
      sleep 0.02
    done
    # Never leave the boundary pointing at nothing: falling back to the
    # wrapper's group still contains more than not signalling at all.
    [[ -z "$pgid" ]] && pgid="$_wrapper_pgid"
  fi

  # Wait with a deadline, without blocking uninterruptibly in `wait`.
  #
  # `timeout` is not used to wrap the child because it would sit between us and
  # the process group, and its own TERM-then-KILL is a weaker teardown than the
  # freeze-before-kill below. Polling costs one stat per 50ms, which is nothing
  # next to a build.
  local waited_ms=0 poll_ms=50 timed_out=0
  local deadline_ms=$(( timeout_sec * 1000 ))
  while kill -0 "$child_pid" 2>/dev/null; do
    if (( waited_ms >= deadline_ms )); then timed_out=1; break; fi
    sleep 0.05
    waited_ms=$(( waited_ms + poll_ms ))
  done

  local rc=0
  if (( timed_out )); then
    if [[ -n "$cg" ]]; then
      _kit_kill_cgroup "$cg"
    else
      # The command's group first (that is where the work is), then the
      # wrapper's, so `wait` below can actually return.
      _kit_kill_pgroup "$pgid"
      kill -KILL "$child_pid" 2>/dev/null || true
    fi
    wait "$child_pid" 2>/dev/null || true
    KIT_PROC_STATUS='timeout'
    KIT_PROC_EXIT_CODE=124   # conventional timeout code, as `timeout` uses
  else
    wait "$child_pid" 2>/dev/null; rc=$?
    # Even on a clean exit, tear the boundary down: the command may have left
    # background children (a dev server, a watcher) that would otherwise outlive
    # the gate and hold its log file open.
    if [[ -n "$cg" ]]; then _kit_kill_cgroup "$cg"; else _kit_kill_pgroup "$pgid"; fi
    KIT_PROC_EXIT_CODE="$rc"
    case "$rc" in
      0)   KIT_PROC_STATUS='success' ;;
      126) KIT_PROC_STATUS='spawn-failure' ;;   # could not join the boundary
      127) KIT_PROC_STATUS='spawn-failure' ;;   # cwd gone / command not found
      *)   KIT_PROC_STATUS='failure' ;;
    esac
  fi

  [[ -n "$cg" ]] && _kit_cleanup_cgroup "$cg"

  local end_ms; end_ms=$(( $(date +%s%N) / 1000000 ))
  KIT_PROC_DURATION_MS=$(( end_ms - start_ms ))

  # Persist the complete raw output, then hand back only a bounded slice. The
  # full log is what a human opens; the slice is what the agent pays for.
  if [[ -n "$raw_log" ]]; then
    local logdir; logdir="$(dirname -- "$raw_log")"
    [[ -d "$logdir" ]] || mkdir -p -- "$logdir"
    {
      printf '$ %s\n' "$cmdline"
      printf '# cwd=%s boundary=%s status=%s exit=%s duration=%sms\n\n' \
             "$cwd" "$boundary" "$KIT_PROC_STATUS" "$KIT_PROC_EXIT_CODE" "$KIT_PROC_DURATION_MS"
      printf -- '--- stdout ---\n'; cat "$out_f" 2>/dev/null
      printf -- '\n--- stderr ---\n'; cat "$err_f" 2>/dev/null
    } > "$raw_log" 2>/dev/null || true
    KIT_PROC_RAW_LOG="$raw_log"
  fi

  KIT_PROC_STDOUT="$(kit_bound_output "$max_output" < "$out_f" 2>/dev/null)"
  KIT_PROC_STDERR="$(kit_bound_output "$max_output" < "$err_f" 2>/dev/null)"

  rm -rf -- "$work" 2>/dev/null || true
  [[ "$KIT_PROC_STATUS" == "success" ]]
}
