#!/usr/bin/env bash
# test-installer.sh - install, doctor and uninstall against a sandboxed
# CLAUDE_CONFIG_DIR.
#
# Nothing here touches the real ~/.claude. The sandbox is seeded with a COPY of
# the machine's actual settings.json when one exists, because the install must
# survive the configuration people really have, not the one the author imagined.
#
# The assertion that matters most is the round trip: install then uninstall must
# leave settings.json byte-identical to how it started. An installer that adds
# its hook correctly but cannot cleanly remove it has taken something from the
# user they cannot get back without editing JSON by hand.
#
# Tools are skipped (--no-tools). Downloading two binaries to prove a hash check
# works belongs in a network test, not in the suite that runs on every change.

set -uo pipefail

TEST_DIR="$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KIT_ROOT="$(dirname -- "$TEST_DIR")"
source "$TEST_DIR/kit-test-lib.sh"

INSTALL="$KIT_ROOT/install.sh"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

SANDBOX="$WORK/claude"
mkdir -p "$SANDBOX"

# Read the machine's REAL settings before HOME is redirected, so the seed below
# reflects the configuration this user actually has.
REAL="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"

# Keep the installer's PATH edits and its kit-gate copy inside the sandbox: the
# installer writes to ~/.local/bin and appends to a shell rc, and a test that
# does that to the real home is a test nobody should have to run twice.
export HOME="$WORK/home"
mkdir -p "$HOME"
export CLAUDE_CONFIG_DIR="$SANDBOX"

# Seed with the real settings.json if there is one; otherwise a representative
# fixture with a foreign hook in it.
if [[ -f "$REAL" ]] && jq -e . "$REAL" >/dev/null 2>&1; then
  cp "$REAL" "$SANDBOX/settings.json"
  SEED='the real settings.json from this machine'
else
  cat > "$SANDBOX/settings.json" <<'EOF'
{
  "cleanupPeriodDays": 20,
  "hooks": {
    "PreToolUse": [{"matcher":"Bash","hooks":[{"type":"command","command":"rtk hook claude"}]}],
    "PostToolUse": [{"matcher":"Edit|Write","hooks":[{"type":"command","command":"$HOME/.claude/hooks/fmt.sh","timeout":30}]}]
  }
}
EOF
  SEED='a representative fixture'
fi
printf '# my own global notes\n\nKeep this line.\n' > "$SANDBOX/CLAUDE.md"

cp "$SANDBOX/settings.json" "$WORK/settings.before.json"
cp "$SANDBOX/CLAUDE.md"     "$WORK/claudemd.before.md"

kit_section "seeded with $SEED"

kit_assert_json "$SANDBOX/settings.json" 'the seed settings.json is valid JSON'
FOREIGN_BEFORE="$(jq -r '[.. | objects | select(has("command")) | .command] | length' "$SANDBOX/settings.json")"
kit_assert_ne '0' "$FOREIGN_BEFORE" 'and it contains hooks the kit does not own'

kit_section 'dry run changes nothing'

bash "$INSTALL" --dry-run --no-tools --quiet >/dev/null 2>&1
kit_assert_eq "$(cat "$WORK/settings.before.json")" "$(cat "$SANDBOX/settings.json")" \
  '--dry-run does not touch settings.json'
kit_assert_file_absent "$SANDBOX/hooks/kit-checkpoint.sh" '--dry-run installs no hook'
kit_assert_file_absent "$SANDBOX/kit-lib/kit-gate.sh"     '--dry-run installs no library'

kit_section 'install'

bash "$INSTALL" --no-tools --quiet >/dev/null 2>&1
RC=$?
kit_assert_eq '0' "$RC" 'the installer succeeds'

kit_assert_file_exists "$SANDBOX/hooks/kit-checkpoint.sh" 'the Stop hook is installed'
kit_assert_file_exists "$SANDBOX/hooks/kit-selffix.sh"    'the PostToolUse hook is installed'
kit_assert_file_exists "$SANDBOX/kit-lib/kit-gate.sh"     'the libraries are installed BESIDE the hooks'
kit_assert_file_exists "$SANDBOX/kit-lib/kit-process.sh"  'including the process runner'
kit_assert_file_exists "$SANDBOX/agents/researcher.md"    'the subagents are installed'
kit_assert_file_exists "$SANDBOX/agents/fixer.md"         'all three of them'
kit_assert_file_exists "$SANDBOX/agents/reviewer.md"      'including the reviewer'
kit_assert_file_exists "$HOME/.local/bin/kit-gate"        'the manual gate runner is on PATH'

[[ -x "$SANDBOX/hooks/kit-checkpoint.sh" ]] \
  && kit_pass 'the hook is executable' || kit_fail_test 'the hook is executable'

kit_assert_json "$SANDBOX/settings.json" 'settings.json is still valid JSON'
kit_assert_jq "$SANDBOX/settings.json" \
  '[.hooks.Stop[]?.hooks[]?.command] | map(select(contains("kit-checkpoint"))) | length' '1' \
  'the Stop hook is registered exactly once'

# Every foreign hook must have survived.
MISSING=0
while IFS= read -r cmd; do
  [[ -z "$cmd" ]] && continue
  jq -e --arg c "$cmd" '[.. | objects | select(has("command")) | .command] | any(. == $c)' \
    "$SANDBOX/settings.json" >/dev/null 2>&1 || MISSING=$((MISSING+1))
done < <(jq -r '[.. | objects | select(has("command")) | .command] | .[]' "$WORK/settings.before.json")
kit_assert_eq '0' "$MISSING" 'EVERY pre-existing hook survived the install'

kit_assert_contains "$(cat "$SANDBOX/CLAUDE.md")" 'Keep this line' \
  "the user's own CLAUDE.md prose is preserved"
kit_assert_contains "$(cat "$SANDBOX/CLAUDE.md")" 'claude-agent-kit' \
  'and the kit rules were appended'
kit_assert_eq '1' "$(ls -1 "$SANDBOX"/CLAUDE.md.bak-* 2>/dev/null | wc -l)" \
  'the existing CLAUDE.md was backed up first'
kit_assert_eq '1' "$(ls -1 "$SANDBOX"/settings.json.bak-* 2>/dev/null | wc -l)" \
  'the existing settings.json was backed up first'

kit_section 'install is idempotent'

cp "$SANDBOX/settings.json" "$WORK/settings.after1.json"
BAKS="$(ls -1 "$SANDBOX"/settings.json.bak-* 2>/dev/null | wc -l)"
bash "$INSTALL" --no-tools --quiet >/dev/null 2>&1
kit_assert_eq '0' "$?" 'a second install succeeds'
kit_assert_eq "$(cat "$WORK/settings.after1.json")" "$(cat "$SANDBOX/settings.json")" \
  'and changes settings.json not at all'
kit_assert_eq "$BAKS" "$(ls -1 "$SANDBOX"/settings.json.bak-* 2>/dev/null | wc -l)" \
  'and takes no redundant backup'
kit_assert_eq '1' "$(grep -cF 'BEGIN CLAUDE-AGENT-KIT' "$SANDBOX/CLAUDE.md")" \
  'and does not append the rules a second time'

kit_section 'doctor sees the install'

OUT="$(bash "$INSTALL" doctor 2>&1)"
kit_assert_contains "$OUT" 'kit-checkpoint.sh      ok' 'doctor reports the installed hook'
kit_assert_contains "$OUT" 'registered'                'doctor reports the registration'
kit_assert_contains "$OUT" 'kill boundary'             'doctor reports which kill boundary is available'

kit_section 'read-only agents may not carry a write tool'

# The installer asserts this rather than trusting the file. Break one and
# confirm the install refuses.
BADKIT="$WORK/badkit"
cp -r "$KIT_ROOT" "$BADKIT"
sed -i 's/^tools: Read, Grep, Glob, Bash$/tools: Read, Grep, Glob, Bash, Write/' "$BADKIT/config/agents/researcher.md"
bash "$BADKIT/install.sh" --no-tools --quiet >/dev/null 2>&1
kit_assert_ne '0' "$?" 'an install that would grant a read-only agent Write FAILS'

kit_section 'uninstall'

bash "$INSTALL" uninstall --quiet >/dev/null 2>&1
kit_assert_eq '0' "$?" 'the uninstaller succeeds'

kit_assert_file_absent "$SANDBOX/hooks/kit-checkpoint.sh" 'the Stop hook is removed'
kit_assert_file_absent "$SANDBOX/hooks/kit-selffix.sh"    'the PostToolUse hook is removed'
kit_assert_file_absent "$SANDBOX/kit-lib/kit-gate.sh"     'the libraries are removed'
kit_assert_file_absent "$SANDBOX/agents/researcher.md"    'the agents are removed'
kit_assert_file_absent "$HOME/.local/bin/kit-gate"        'the gate runner is removed'

kit_assert_json "$SANDBOX/settings.json" 'settings.json survives as valid JSON'

# THE ROUND TRIP. This is the assertion the whole uninstall path exists to pass.
BEFORE="$(jq -S . "$WORK/settings.before.json")"
AFTER="$(jq -S . "$SANDBOX/settings.json")"
kit_assert_eq "$BEFORE" "$AFTER" \
  'INSTALL THEN UNINSTALL RETURNS settings.json TO ITS EXACT ORIGINAL SHAPE'

kit_assert_contains "$(cat "$SANDBOX/CLAUDE.md")" 'Keep this line' \
  "the user's CLAUDE.md prose survives uninstall"
kit_assert_not_contains "$(cat "$SANDBOX/CLAUDE.md")" 'BEGIN CLAUDE-AGENT-KIT' \
  'and the kit block is gone'

kit_section 'uninstalling twice is safe'

bash "$INSTALL" uninstall --quiet >/dev/null 2>&1
kit_assert_eq '0' "$?" 'a second uninstall succeeds'
kit_assert_json "$SANDBOX/settings.json" 'and settings.json is still valid'

kit_section 'install onto a machine with no ~/.claude at all'

FRESH="$WORK/fresh"
mkdir -p "$FRESH"
export CLAUDE_CONFIG_DIR="$FRESH/claude"
bash "$INSTALL" --no-tools --quiet >/dev/null 2>&1
kit_assert_eq '0' "$?" 'installing with no existing config succeeds'
kit_assert_json "$FRESH/claude/settings.json" 'and creates a valid settings.json'
kit_assert_file_exists "$FRESH/claude/CLAUDE.md" 'and creates a global CLAUDE.md'
kit_assert_jq "$FRESH/claude/settings.json" \
  '[.hooks.Stop[]?.hooks[]?.command] | length' '1' 'with the Stop hook registered'

bash "$INSTALL" uninstall --quiet >/dev/null 2>&1
kit_assert_file_absent "$FRESH/claude/CLAUDE.md" \
  'uninstall removes a CLAUDE.md that contained only the kit block'


kit_section 'the INSTALLED copies actually run'

# Everything above tests the in-repo scripts. That is not the same program: the
# installed kit-new-project lives in ~/.local/bin, so its parent directory is
# ~/.local and the repo-relative "../lib" it used to assume does not exist
# there. That mismatch shipped a kit whose installer succeeded and whose
# initializer then failed with "kit file missing" - invisible to every test that
# only ever invoked scripts/new-project.sh.
export CLAUDE_CONFIG_DIR="$SANDBOX"
bash "$INSTALL" --no-tools --quiet >/dev/null 2>&1

PROJ="$WORK/installed-proj"; mkdir -p "$PROJ/src"
touch "$PROJ/pyproject.toml"
printf 'x = 1\n' > "$PROJ/src/app.py"

OUT="$("$HOME/.local/bin/kit-new-project" "$PROJ" --quiet 2>&1)"; RC=$?
kit_assert_eq '0' "$RC" 'the INSTALLED kit-new-project runs'
kit_assert_not_contains "$OUT" 'cannot find the kit libraries' 'and finds its libraries'
kit_assert_not_contains "$OUT" 'kit file missing' 'and is not missing kit files'
kit_assert_json "$PROJ/.claude/gate.json" 'and writes a valid gate'
kit_assert_file_exists "$PROJ/.claude/py-syntax.py" 'and writes the helper the gate names'

"$HOME/.local/bin/kit-gate" full "$PROJ" >/dev/null 2>&1
kit_assert_eq '0' "$?" 'the INSTALLED kit-gate runs the generated gate'

# The installed HOOKS must resolve their libraries from ~/.claude/kit-lib too -
# they are invoked by absolute path with the user project as the cwd.
EV="$(jq -cn --arg c "$PROJ" '{cwd:$c,hook_event_name:"Stop",stop_hook_active:false}')"
printf '%s' "$EV" | "$SANDBOX/hooks/kit-selffix.sh" >/dev/null 2>&1
kit_assert_eq '0' "$?" 'the INSTALLED PostToolUse hook runs'
kit_assert_jq "$PROJ/.claude/kit-state.json" '.dirty' 'true' 'and marks the project dirty'

HOUT="$(printf '%s' "$EV" | "$SANDBOX/hooks/kit-checkpoint.sh" 2>/dev/null)"
kit_assert_eq '' "$HOUT" 'the INSTALLED Stop hook allows a passing gate'
kit_assert_jq "$PROJ/.claude/kit-state.json" '.dirty' 'false' 'and clears the dirty flag'

# And it must block a failure, through the installed path.
printf 'def broken(:\n' > "$PROJ/src/bad.py"
printf '%s' "$EV" | "$SANDBOX/hooks/kit-selffix.sh" >/dev/null 2>&1
HOUT="$(printf '%s' "$EV" | "$SANDBOX/hooks/kit-checkpoint.sh" 2>/dev/null)"
kit_assert_eq 'block' "$(printf '%s' "$HOUT" | jq -r '.decision // "none"')" \
  'THE INSTALLED STOP HOOK BLOCKS A FAILING GATE'
kit_assert_contains "$(printf '%s' "$HOUT" | jq -r '.reason // ""')" 'src/bad.py' \
  'and names the file that broke'

kit_test_summary
