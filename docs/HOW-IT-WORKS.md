# How it works

The token model and the design decisions, with the reasoning that produced them.

## The cost model

An agent session spends tokens on three things, in ascending order of size:

1. Your prompts. Small.
2. The code it reads. Medium, and mostly necessary.
3. **Raw command output.** Large, repetitive, and mostly noise.

A failing build prints 200 lines; three are the error. A test suite prints every
passing test. `git status` in a busy repo is a wall. All of it is billed at full
rate, and re-billed on every compaction.

The three levers attack (3), then (2), then the *frequency* of both.

## Lever 1: filter output before the model sees it

RTK proxies shell commands and compresses their output. The hook rewrites
`git status` to `rtk git status` transparently.

**The limit, stated honestly.** Compression is only acceptable where the
diagnostic survives. On failing builds and test runs — exactly the cases that
compress best, 78–88% — the compressor tends to drop the line naming the failing
file, which is the one line a repair needs. So the generated gates call
toolchains directly and take the token hit. A gate that hides the traceback
costs more than it saves, because the agent then flails.

## Lever 2: move heavy reading off the main thread

A subagent has its own context window. Reading fifty files there costs the main
thread one paragraph.

This is why `researcher` is read-only and why its report format is prescribed:
answer first, then `file:line` citations, no large code blocks. An agent that
pastes back what it read has defeated the entire point.

## Lever 3: run validation once, at the right time

This is the lever with the most leverage, and it is a *timing* fix.

The naive design validates after every edit:

```
edit → full gate → edit → full gate → edit → full gate ...
```

Ten edits, ten builds, ten test suites. Most run against a half-finished tree,
so most of their output is noise the agent reads and discards. And it has the
timing exactly backwards: it validates constantly while the work is incomplete,
and guarantees nothing once the work is done. Nothing runs a full gate before
the agent stops.

The kit inverts it:

```
edit → mark dirty (runs NOTHING)
edit → mark dirty
edit → mark dirty
stop → FULL GATE ← enforced here, exactly once
```

Ten edits run **zero** full gates. The gate runs when the agent believes it is
finished — which is the only moment its result means anything.

### Why the loop terminates

A failing gate blocks the stop, so the agent repairs and stops again. That is a
loop, and an unbounded loop is worse than no gate. Three independent brakes, any
one sufficient:

1. **Attempt cap.** At most `maxRepairAttempts` (default 3) blocked stops.
2. **Repeat detection.** The same failure signature twice running means the
   agent changed something and the gate produced a byte-identical complaint. It
   is not converging. Stop and report.
3. **`stop_hook_active`.** Claude Code's own flag, honoured on entry.

On give-up the hook does **not** block. It allows the stop and reports honestly,
because an agent that cannot fix something should return to a human rather than
burn turns proving it again.

### Failure signatures

Brake 2 needs "is this the same failure?" without diffing whole logs. The
signature normalises out the volatile parts — absolute paths, hex addresses,
GUIDs, and **all runs of digits** — then hashes what remains with the command
and exit code.

Collapsing every number is deliberate: a changing line number, PID, or elapsed
time is not a different bug. This has a consequence worth knowing — you cannot
fake a novel failure with `$RANDOM`, because `error 12345` and `error 99999`
share a signature. (This surfaced as a *test* bug during development: a test
that used `$RANDOM` to simulate varying failures was measuring the normaliser
working correctly.)

## Fail-open vs fail-closed

Stated deliberately, because both directions are silent when wrong:

| Situation | Behaviour | Why |
|---|---|---|
| Gate configured, failing | **Fail closed** — block | The entire point |
| Gate not configured | **Fail open**, loudly | Blocking would deadlock a project with no way to satisfy a check that doesn't exist |
| Gate command won't start | **Fail open**, loudly | A broken gate is not failing work; don't send the agent to fix healthy code |
| The hook itself errors | **Fail open**, silently | Never wedge a session over bookkeeping |

"Loudly" means the hook emits `additionalContext` saying *nothing verified these
edits*. It never lets work be described as validated when nothing validated it.

## The kill boundary

See the README table for the two mechanisms. The design rule is that ownership
must be established **before the child executes its first instruction**:

- **cgroup**: the child writes its own `$BASHPID` to `cgroup.procs` in a shell
  that has not yet run any user code, *then* execs the command.
- **pgroup**: `setsid` creates the new session before the exec.

Compare `Process.Start()` followed by "now add it to the job" — that leaves a
window where the process exists outside the boundary, and a fast-forking build
tool escapes through it.

**Why the fallback freezes before killing.** `TerminateJobObject` and
`kill -- -PGID` both walk members in sequence. Killing a grandchild first can
wake its parent out of `wait()`, letting it be scheduled and run its next
command *during teardown*. `SIGSTOP` first means nothing in the group can be
scheduled at all. cgroup v2's `cgroup.kill` has no such race — it is one atomic
kernel operation — which is why it is preferred when available.

## Why bash, not PowerShell-on-Linux

`pwsh` exists for Linux, and a direct port would have run. It was rejected
because the Windows code's complexity is mostly *working around PowerShell 5.1*:
hand-rolled JSON reading (5.1's `Set-Content -Encoding UTF8` emits a BOM that
strict parsers reject), `CommandLineToArgvW` quoting rules, `PSModulePath`
repair when pwsh launches powershell.

None of those problems exist here. `jq` handles JSON. Bash arrays handle
arguments. Porting the workarounds would produce bash that reads like
PowerShell — strictly worse than either language alone.

What ports is the **design**: fail closed on integrity, back up before every
write, keep planners pure and testable, refuse to invent a gate, and never
silently downgrade a guarantee.

## Design rules, in priority order

1. **Nothing is overwritten without a backup.** Every destructive step registers
   an undo entry.
2. **Only kit-owned things are touched.** A user's own hooks, prose and settings
   keys survive install *and* uninstall.
3. **Fail closed on integrity.** A pinned download whose hash doesn't match is
   deleted and the install aborts. No "install it anyway" path — a fallback
   makes the check decorative.
4. **Never silently downgrade.** If a weaker guarantee is used, say which one.
5. **Refuse to guess.** No inferable build system means no commands and
   `configured: false`. An honest refusal beats a confusing failure, and both
   beat a silent one.
6. **Planners are pure.** Detection takes facts and returns a plan. That is why
   the whole matrix is testable with no toolchain installed.
