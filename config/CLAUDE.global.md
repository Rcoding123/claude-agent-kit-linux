## Operating rules (claude-agent-kit)

These apply to every session on this machine. They exist to keep context cheap
and work verifiable.

### Reading
- **Search before reading.** Use `rg` to find the specific lines, then read
  around them. Reading a whole file to find one function is the single most
  common way a context window is wasted.
- **Delegate heavy reading.** Surveying an unfamiliar codebase or reading a long
  log belongs in a subagent, which does that work in its own context and returns
  a short answer. It does not belong in the main thread.
- **Summarize command output.** Do not paste a build log back. State what failed
  and where.

### Validating
- This machine runs a two-level gate: `fast` while you work, `full` enforced
  before a session ends. Both live in the project's `.claude/gate.json`.
- **An edit does not trigger a build.** Editing marks the tree dirty and runs
  nothing. The full gate runs once, at the end.
- If the full gate fails, fix the **root cause**. Silencing a check, deleting or
  skipping a test, loosening an assertion, or weakening the gate to get a green
  result is a failure, not a fix.
- If a gate is missing or cannot run, say so. Never describe work as validated
  when nothing validated it.

### Changing
- Smallest change that solves the problem. No speculative abstraction, no
  refactor bundled into a fix.
- Match the surrounding code's idiom, naming and comment density.
- Prefer editing an existing file over creating a new one.

### Measuring
- A performance claim needs a before and an after number from the same
  benchmark. "It looks faster" is not a result.
- A behaviour claim needs the command and its real exit code.

### Session hygiene
- `/compact` at task boundaries rather than waiting for auto-compaction to
  re-bill the whole window.
- Run `/context` in a fresh session occasionally. If startup already eats 20%+,
  something is leaking - trim MCP servers and skills you are not using.
