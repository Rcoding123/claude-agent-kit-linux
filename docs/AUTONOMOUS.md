# Unattended operation

Optional layer. Install it only if you intend to start a task and walk away.

```bash
./autonomous/install-autonomous.sh            # opt in
./autonomous/install-autonomous.sh uninstall  # opt out
```

It is separate from the main installer on purpose: the guard **blocks commands
without asking**, which is right for a box nobody is watching and wrong for a
laptop where you are at the keyboard and would rather be prompted.

## Why blocking, not asking

Under `bypassPermissions` there is no human to approve anything. A prompt nobody
answers is worse than useless — it hangs the run. So the guard refuses the
irreversible action outright and tells the agent what to do instead. It exits 2,
which Claude Code treats as "denied, here is why" even in bypass mode, and feeds
the message back so the agent self-corrects.

## What it blocks, and why those things

The rules are **not** a translation of the Windows guard's. Linux's irreversible
actions are a different set, and mostly concern the machine rather than a remote:

| Blocked | Why it cannot be undone |
|---|---|
| `rm -rf` at or under `/`, `/etc`, `/usr`, `~`, … | No recycle bin. This is final. |
| `dd of=/dev/…`, `mkfs`, `fdisk`, `wipefs` | Destroys a filesystem in one command |
| `chmod -R` / `chown -R` on system paths | Routinely makes a machine unbootable |
| `shutdown`, `reboot`, `poweroff` | An unattended box does not come back |
| `systemctl stop/disable` on ssh, networking, firewall | Locks you out of a remote machine |
| `iptables -F`, `ufw disable` | Drops the connection you are working over |
| `curl`/`wget` piped into `sh`/`bash`/`python` | Executes code nobody reviewed |
| `git push` (forced or not) to `main`/`master` | Bypasses review; force rewrites shared history |
| `npm`/`cargo publish`, `docker push` | A published version can never be recalled |
| `terraform apply/destroy`, `kubectl apply`, `helm upgrade` | Changes real infrastructure |
| `docker system prune` | Deletes things this session did not create |

Everything else runs at full speed. This is a denylist of irreversible actions,
not an allowlist.

## Matching is argument-positional, not substring

This is the part that decides whether people keep the guard switched on.

A regex over the raw command string blocks anything that merely *mentions* a
blocked word — `git commit -m "clean up the deploy script"` gets refused as a
deployment. That punishes an agent for writing an honest commit message, and the
refusal points at something it never did. People then disable the guard, at
which point it protects nothing.

So the command is split into segments (on `&&` `||` `;` `|` newline and command
substitution), each segment is tokenized quote-aware, and rules match on the
**program** and its **argument positions**:

```bash
git commit -m "notes on terraform apply"   # ALLOWED - prose, not a command
git status && terraform apply              # BLOCKED - each segment is checked
echo "$(rm -rf /)"                         # BLOCKED - $() really executes
echo 'rm -rf /'                            # ALLOWED - single quotes do not
echo "\$(rm -rf /)"                        # ALLOWED - escaped, so literal text
```

The laundering cases matter: a blocked command inside a quoted command
substitution *does* execute, so quoting must not protect it. A single-quoted
string never executes, so it stays prose.

## It fails closed

If the guard cannot parse the event, cannot find `jq`, or hits an unexpected
error, it **blocks**. A broken fence that fails open is indistinguishable from a
permissive one, and the first thing you learn about it is the `rm -rf` that went
through. Blocking is annoying and visible; an absent fence is invisible and
irreversible.

It is registered **first** in `PreToolUse`, ahead of RTK's hook. RTK *rewrites*
the command, so a guard behind it would inspect something the user never typed.

## Three bugs the tests caught

All three failed **open** — the direction where nothing looks wrong:

1. **Only exact system paths were protected.** `rm -rf /etc` blocked, but
   `rm -rf /usr/lib` sailed through. Just as unbootable, and rather more likely
   to be typed by accident. Now anything at or under a protected root matches.
2. **The wrapper-skip loop ate the program's own flags.** For `chmod -R 777 /`
   it walked past `chmod`, past `-R`, past `777`, and concluded the program was
   `/`. Every rule then missed. Flags are now skipped only while they directly
   follow a wrapper like `sudo`.
3. **The free-text flag list was global.** `-F` is git's message-file flag, but
   for iptables it means `--flush` — so `iptables -F` had its `-F` swallowed as
   "prose" and was allowed. Text flags are now scoped to the programs that
   actually have them.

Each has a regression test. `./tests/run-all.sh guard` runs 117 assertions,
roughly half of which assert that ordinary work is **allowed**.

## Tuning it

The rules are in `autonomous/kit-guard.sh`, in one `case` per program. To add a
rule, add a branch; to relax one, delete it. Then:

```bash
./tests/run-all.sh guard              # 117 assertions
./autonomous/install-autonomous.sh    # reinstall
```

Err toward blocking when unsure — a false block costs a minute, and a false
allow can cost the machine.

Add allow-cases as well as block-cases when you change the rules. Half the value
of the suite is proving that normal work still runs.
