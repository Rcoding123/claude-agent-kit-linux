# Claude Agent Kit (Linux)

A portable setup that makes a Claude Code agent on Linux **cheap on tokens** and
**able to fix its own mistakes**. Install once per machine, then drop it into any
repo — C++, Python, Rust, Go, Node, .NET, shell.

It is not tied to a project. It is the operating layer you run *underneath*
every project.

This is the Linux counterpart to the Windows PowerShell kit. It is a **rewrite,
not a transliteration**: the design ports, the code does not. Where PowerShell
5.1 forced hand-rolled JSON parsing and argument quoting, this uses `jq` and
bash arrays. Where Windows needed a Job Object, this uses cgroup v2.

---

## What it does

Three levers, stacked:

**1. Cut the noise before it hits the context window (RTK).**
Most tokens an agent burns aren't your prompts — they're raw command output:
`git status`, test runs, build logs, file dumps. [RTK](https://github.com/rtk-ai/rtk)
is a CLI proxy that filters that output before the model reads it, installing a
hook so every `git status` silently becomes `rtk git status`.

Compression belongs only where diagnostics survive it. On a *failing* run the
best-compressing cases are exactly the ones that delete the line a repair needs
— the failing file name — so the generated gates call toolchains directly
instead. This is output reduction on shell commands, not a 1:1 cut of your bill.

**2. Keep heavy reading out of the main thread (subagents).**
Surveying an unfamiliar codebase or reading long logs is what blows up a
session. Three reusable subagents do that work in their own isolated context and
return a short structured answer:

- `researcher` — "where is X / how does Y work" across many files (read-only)
- `fixer` — drives a failing build/test back to green in isolation
- `reviewer` — reviews a diff for correctness and risk before commit

`researcher` and `reviewer` are read-only, and **the installer refuses to
install a read-only agent that has been given a write tool** — asserted, not
assumed.

**3. Make it self-fixing (checkpoint gate + Stop hook).**
Each project gets a `.claude/gate.json` — fast and full command lists for its
language, generated from what the project actually contains, and marked
`configured: false` when no build system can be inferred rather than looking
wired while validating nothing.

**An edit does not trigger a build.** The PostToolUse hook marks state dirty and
runs nothing; the full gate is enforced once, at completion, by the `Stop` hook.
A failing gate blocks the stop with concise diagnostics naming the failing file,
and that loop is bounded three independent ways — an attempt cap, repeated
identical failures, and `stop_hook_active`. Ten edits run zero full gates.

Silencing a check, deleting a test, or weakening the gate to buy a green result
is forbidden in the contract and asserted in the tests.

---

## The one genuinely hard part: the kill boundary

When a gate command times out, every process it created must die — child,
grandchild, deeper. Getting this wrong leaks build processes that hold files
open and consume the machine.

The kit establishes ownership **before the child runs its first instruction**,
and reports which boundary it got:

| Boundary | Guarantee | When |
|---|---|---|
| **cgroup v2** | Escape-proof, atomic in-kernel kill. A process written into the cgroup cannot leave it. | A writable cgroup v2 subtree exists (systemd user delegation) |
| **process group** | `setsid` + freeze-before-kill (`SIGSTOP` the group, *then* `SIGKILL`). | Fallback — always available |

The freeze-before-kill in the fallback is not decoration. Signalling a group
delivers to members in sequence, so a parent blocked in `wait()` can be woken by
its child's death, get scheduled, and run one more command *during teardown*. A
stopped process cannot be scheduled at all.

**The kit never silently downgrades.** Every result carries
`KIT_PROC_BOUNDARY`, and `install.sh doctor` tells you which one this machine
provides. Verified here: 0 leaked processes across 10 timeout runs on both
paths.

Two bugs found by testing this, both of which were *silent*:

1. Plain `setsid` forks and the wrapper exits 0 immediately — so **every gate
   command reported success**. An always-green gate is the worst possible
   failure for this kit, and only an assertion on a nonzero exit code catches it.
2. In the fallback, `ps --ppid $wrapper` briefly returns the *wrapper's own*
   pgid before the real command is forked. Latching that plausible-but-wrong
   answer made teardown miss the entire tree.

---

## Requirements

- Linux with bash 4.4+
- `jq`, `curl`, `sha256sum`, `tar`, `find`, `sed`, `awk` (all standard)
- Claude Code installed
- **No root.** Everything lands under `$HOME`.

```bash
# Debian/Ubuntu, if jq is missing
sudo apt install jq
```

## Install (once per machine)

```bash
git clone <repo-url>
cd claude-agent-kit-linux
./install.sh
```

This will:
- install pinned `ripgrep` and `rtk` into `~/.local/bin` (SHA-256 verified)
- install the global `CLAUDE.md` rules, the three subagents, and the hooks
- register the hooks in `settings.json`, **preserving every hook it did not write**

Then **fully restart Claude Code** — hooks are read at startup.

```bash
./install.sh doctor      # what is installed, which kill boundary, version drift
./install.sh --dry-run   # show what would happen, change nothing
./install.sh --no-tools  # skip the binary downloads
```

Every download is pinned in `config/tools.manifest.json` with a SHA-256
corroborated from two independent vendor sources. **A hash mismatch deletes the
file and aborts** — there is deliberately no "install it anyway" path, because a
fallback would make the check decorative.

## Use (per project)

```bash
cd path/to/your/repo
kit-new-project
```

Auto-detects the language, writes `.claude/gate.json` from what the project
actually contains, writes any helper the gate references, and creates a starter
`CLAUDE.md` only if you don't have one.

Tools are **probed, not assumed**: no ruff in your interpreter means no ruff
step and a note saying so, rather than a gate that fails for reasons unrelated
to your code.

```bash
kit-new-project --language python
kit-new-project --fast "make lint" --full "make check"
kit-new-project --dry-run

kit-gate --show     # print the configured gate
kit-gate fast       # the cheap subset
kit-gate full       # everything (same path the Stop hook runs)
```

`kit-gate` exits with the gate's own status, so it drops straight into a
pre-commit hook or CI step.

### What gets generated

| Language | Detected by | Notable refusals |
|---|---|---|
| Rust | `Cargo.toml` | clippy doesn't fail the gate by default (says how to change it) |
| C/C++ | presets → `CMakeLists.txt` → meson → Makefile | **no build system inferred → no commands at all**; no `make test` without a real target |
| Python | `pyproject.toml`, `requirements.txt`, loose `.py` | no ruff/pytest step unless importable in *that* interpreter — but if the project **has** tests it cannot run, it says so loudly rather than shrugging |
| Node | `package.json` | **the npm placeholder `test` script is never gated** (it always exits 1) |
| Go | `go.mod` | admits `gofmt -l` exits 0 and shows the enforcing form |
| .NET | `.sln`/`.csproj` | no `dotnet test` without a real test project |
| shell | loose `.sh` | no shellcheck step unless installed |
| unknown | — | **no commands, `configured: false`** |

That last row is the point. An invented gate fails confusingly; an empty one
fails *silently*. A project the kit doesn't understand is marked unconfigured,
and the Stop hook then fails **open but loudly** — it says nothing verified the
work rather than pretending something did.

---

## Everyday habits (these matter more than any tool)

- Run `/context` in a fresh session. If startup already eats 20%+, trim MCP
  servers and skills you aren't using.
- Delegate: "have the **researcher** find where order routing happens" instead
  of reading it yourself in the main thread.
- Let the **fixer** own build loops. It keeps 200 lines of compiler spew out of
  your window.
- `/compact` at task boundaries, don't wait for auto-compaction to re-bill the
  whole window.
- `rtk gain` to see what you've saved; `rtk discover` for unfiltered commands.

---

## Files

```
install.sh                 install | doctor | uninstall
config/
  CLAUDE.global.md         standing rules -> ~/.claude/CLAUDE.md
  tools.manifest.json      pinned versions + SHA-256 + provenance (x86_64, aarch64)
  agents/                  researcher, fixer, reviewer -> ~/.claude/agents/
lib/
  kit-common.sh            JSON, atomic writes, backup/rollback, credential guard
  kit-process.sh           THE KILL BOUNDARY: cgroup v2 + pgroup fallback
  kit-gate.sh              gate config, state, failure signatures, repair brakes
  kit-detect.sh            language detection + pure gate planners
  kit-settings.sh          settings.json merge that preserves foreign hooks
  kit-tools.sh             pinned, hash-verified tool installation
hooks/
  kit-selffix.sh           PostToolUse: marks dirty, RUNS NOTHING
  kit-checkpoint.sh        Stop: the enforced full gate
scripts/
  new-project.sh           per-repo initializer -> kit-new-project
  kit-gate                 manual fast/full gate runner
autonomous/                unattended layer (optional, opt-in)
  kit-guard.sh             PreToolUse hard-block for irreversible actions
  install-autonomous.sh    wires it, ahead of rtk's hook
tests/
  run-all.sh               every suite, one summary
  test-{process,gate,detect,settings,hooks,guard,newproject,installer,tools}.sh
docs/
  HOW-IT-WORKS.md          the token model and design rationale
  AUTONOMOUS.md            what the guard blocks and why
```

## Tests

```bash
./tests/run-all.sh          # 513 assertions, ~70s, no network
./tests/run-all.sh guard    # one suite
./tests/run-all.sh tools    # +37 assertions; downloads real binaries
./tests/run-all.sh --list
```

`tools` is excluded by default because it hits the network. It downloads both
pinned binaries, verifies them against the manifest, runs them to confirm the
version, proves the **aarch64** assets are real arm64 ELF binaries, and — the
assertion that matters — points the installer at a real asset with a **wrong**
hash and confirms it refuses and deletes it.

No test framework required — the kit installs on bare boxes, and a suite that
needs a package manager to run is a suite that doesn't get run where it matters.

The suites use the real thing wherever possible: the Python and shell syntax
checkers are executed against deliberately broken fixtures; the hooks are driven
through their actual stdin/stdout JSON contract; the installer runs against a
**copy of this machine's real `settings.json`** in a sandboxed `HOME`, and
asserts that install-then-uninstall returns it byte-identical.

## What has actually been verified

Claims in this README are backed by runs, not by assertion:

- **Kill boundary** — 0 leaked processes across 10 timeout runs, on *both* the
  cgroup and process-group paths.
- **Pinned downloads** — both binaries really download, verify, extract and
  report the pinned version; a deliberately wrong hash is refused and the file
  deleted; a 404 fails cleanly.
- **aarch64** — the arm64 assets download, match their hashes, and unpack to
  genuine `ELF … ARM aarch64` binaries (verified cross-arch from x86_64).
- **Real projects** — pointed at four real repositories on the author's machine.
  Detection was correct on all four; the generated gates **passed** on the real
  code and **failed** on deliberately broken code, naming the offending file
  every time.
- **Your settings** — the installer suite runs against a copy of the machine's
  real `settings.json` and asserts install-then-uninstall returns it
  byte-identical.

Three bugs were found by that last exercise alone, none of which any fixture
had caught: a `--dry-run` that printed "wrote" having written nothing, a Python
gate that stayed silent about a project with 21 test files it could not run, and
a shell diagnostic that leaked absolute paths into the agent's context.

## Unattended operation (optional)

Want to start a task and walk away? See [`docs/AUTONOMOUS.md`](docs/AUTONOMOUS.md).

```bash
./autonomous/install-autonomous.sh
```

A PreToolUse guard hard-blocks irreversible actions **without asking** — because
on an unattended box a prompt nobody answers is worse than useless. It matches
argument-positionally, so `git commit -m "clean up the deploy script"` runs fine
while `git status && terraform apply` is refused. It fails **closed**, and it
registers ahead of RTK's hook so it inspects what you actually typed.

## Uninstall

```bash
./install.sh uninstall
rtk init -g --uninstall    # RTK owns its own hook entry
```

Removes exactly the kit's own hooks, files and `CLAUDE.md` block, leaving the
rest of your `settings.json` and your own prose intact. `--dry-run` shows what
it would do.

## Differences from the Windows kit

| | Windows | Linux |
|---|---|---|
| Kill boundary | Job Object + `CREATE_SUSPENDED` | cgroup v2 `cgroup.kill`, else `setsid` + freeze-then-kill |
| JSON | hand-rolled (5.1 has no good option) | `jq` throughout |
| Arg quoting | `CommandLineToArgvW` rules, ~40 lines | bash arrays; module not needed |
| Archives | zip | tar.gz, multi-arch (x86_64 + aarch64) |
| PATH | user environment variable | shell rc, detected per shell |
| Autonomous layer | included | ported, with **Linux-specific rules** — `rm -rf`, `dd`/`mkfs`, `chmod -R` on system paths, `systemctl stop ssh`, `iptables -F`, `curl \| sh` — rather than a transliteration of the Windows blocklist |

RTK is Apache-2.0, open source, no account/API key/telemetry-by-default.
