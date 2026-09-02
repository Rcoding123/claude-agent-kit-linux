#!/usr/bin/env bash
# test-settings.sh - merging into a user's settings.json without eating it.
#
# The tests that matter here are the PRESERVATION ones. An installer that adds
# its hook correctly but drops someone's existing configuration has done more
# damage than one that fails outright, because the failure is silent and the
# backup is the only thing standing between the user and a bad afternoon.
#
# One suite runs against a copy of the REAL settings.json on this machine when
# one exists, because a synthetic fixture only proves the installer survives
# the shapes the author imagined.

set -uo pipefail

TEST_DIR="$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KIT_ROOT="$(dirname -- "$TEST_DIR")"
source "$TEST_DIR/kit-test-lib.sh"
source "$KIT_ROOT/lib/kit-settings.sh"

# Build a unit-separated registration. Exercising the helper here is the point:
# the matcher below is an alternation containing pipes, which is exactly what a
# pipe-delimited format would have silently mangled.
kit_reg() { printf '%s\x1f%s\x1f%s\x1f%s\x1f%s' "$1" "$2" "$3" "$4" "$5"; }

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

CLAUDE_DIR="$WORK/claude"
mkdir -p "$CLAUDE_DIR/hooks"

kit_section 'adding hooks to a fresh settings.json'

S="$WORK/fresh.json"
kit_hook_add "$S" Stop '' "$CLAUDE_DIR/hooks/kit-checkpoint.sh" 'kit-checkpoint' >/dev/null 2>&1 || true
# A missing file is not a valid jq input, so the merge path (not the raw add)
# is what handles creation. Assert that directly.
printf '{}\n' > "$S"
RES="$(kit_hook_add "$S" Stop '' "$CLAUDE_DIR/hooks/kit-checkpoint.sh" 'kit-checkpoint')"
kit_assert_eq 'added' "$RES" 'a hook is added to an empty settings object'
kit_assert_json "$S" 'the result is still valid JSON'
kit_assert_jq "$S" '.hooks.Stop | length' '1' 'the Stop event has one entry'
kit_assert_jq "$S" '.hooks.Stop[0].hooks[0].type' 'command' 'the entry is a command hook'

RES="$(kit_hook_add "$S" Stop '' "$CLAUDE_DIR/hooks/kit-checkpoint.sh" 'kit-checkpoint')"
kit_assert_eq 'already-present' "$RES" 'adding the same hook twice is a no-op'
kit_assert_jq "$S" '.hooks.Stop | length' '1' 'and does not duplicate the entry'

kit_section 'an empty matcher is legitimate'

# Stop, SessionStart and friends have no tool to match on. An installer that
# treats an empty matcher as a missing argument aborts on exactly the hook this
# kit most needs.
kit_assert_jq "$S" '.hooks.Stop[0].matcher' '' 'an empty matcher is preserved as an empty string'

kit_section 'preserving what the kit did not write'

S="$WORK/populated.json"
cat > "$S" <<'EOF'
{
  "cleanupPeriodDays": 20,
  "env": { "DISABLE_TELEMETRY": "1" },
  "permissions": { "allow": ["Read", "Bash(git status)"] },
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "rtk hook claude" }] }
    ],
    "PostToolUse": [
      { "matcher": "Edit|Write", "hooks": [{ "type": "command", "command": "$HOME/.claude/hooks/fmt.sh", "timeout": 30 }] }
    ]
  }
}
EOF
cp "$S" "$WORK/populated.orig.json"

kit_hook_add "$S" Stop '' "$CLAUDE_DIR/hooks/kit-checkpoint.sh" 'kit-checkpoint' >/dev/null
kit_hook_add "$S" PostToolUse 'Edit|Write|MultiEdit' "$CLAUDE_DIR/hooks/kit-selffix.sh" 'kit-selffix' >/dev/null

kit_assert_json "$S" 'settings remain valid JSON after merging'
kit_assert_jq "$S" '.cleanupPeriodDays' '20'          'unrelated top-level keys survive'
kit_assert_jq "$S" '.env.DISABLE_TELEMETRY' '1'       'env survives'
kit_assert_jq "$S" '.permissions.allow | length' '2'  'permissions survive'
kit_assert_jq "$S" '.hooks.PreToolUse[0].hooks[0].command' 'rtk hook claude' \
  "RTK's own hook is left exactly as it was"
kit_assert_jq "$S" '.hooks.PostToolUse | length' '2' \
  'an existing PostToolUse hook is kept alongside the new one'
kit_assert_jq "$S" '.hooks.PostToolUse[0].hooks[0].command' '$HOME/.claude/hooks/fmt.sh' \
  "the user's own fmt.sh hook stays FIRST and unmodified"
kit_assert_jq "$S" '.hooks.PostToolUse[0].hooks[0].timeout' '30' \
  'and keeps its own timeout'

kit_section 'ordering'

S="$WORK/order.json"
cat > "$S" <<'EOF'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"rtk hook claude"}]}]}}
EOF
kit_hook_add "$S" PreToolUse 'Bash' "$CLAUDE_DIR/hooks/kit-guard.sh" 'kit-guard' --first >/dev/null
kit_assert_jq "$S" '.hooks.PreToolUse[0].hooks[0].command' "$CLAUDE_DIR/hooks/kit-guard.sh" \
  '--first puts a guard BEFORE rtk, so it inspects what the user actually typed'
kit_assert_jq "$S" '.hooks.PreToolUse[1].hooks[0].command' 'rtk hook claude' \
  'and rtk is pushed to second, not replaced'

kit_section 'removal takes only what the kit owns'

S="$WORK/remove.json"
cp "$WORK/populated.json" "$S"
N="$(kit_hook_remove "$S" Stop 'kit-checkpoint')"
kit_assert_eq '1' "$N" 'the kit Stop hook is removed'
N="$(kit_hook_remove "$S" PostToolUse 'kit-selffix')"
kit_assert_eq '1' "$N" 'the kit PostToolUse hook is removed'

kit_assert_json "$S" 'settings are still valid JSON after removal'
kit_assert_jq "$S" '.hooks.PreToolUse[0].hooks[0].command' 'rtk hook claude' \
  "RTK's hook survives the kit's uninstall"
kit_assert_jq "$S" '.hooks.PostToolUse | length' '1' \
  "the user's own PostToolUse hook survives"
kit_assert_jq "$S" '.hooks.PostToolUse[0].hooks[0].command' '$HOME/.claude/hooks/fmt.sh' \
  'and it is the right one that survived'
kit_assert_jq "$S" '.cleanupPeriodDays' '20' 'unrelated keys survive uninstall too'

# Removing a hook that is not there must be a clean no-op.
N="$(kit_hook_remove "$S" Stop 'kit-checkpoint')"
kit_assert_eq '0' "$N" 'removing an absent hook removes nothing'

# An event list that becomes empty is deleted rather than left as a husk.
S="$WORK/husk.json"
printf '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/kit-checkpoint.sh"}]}]}}\n' > "$S"
kit_hook_remove "$S" Stop 'kit-checkpoint' >/dev/null
kit_assert_jq "$S" 'has("hooks")' 'false' 'an emptied hooks object is removed entirely'

kit_section 'a settings.json that cannot be parsed is never overwritten'

S="$WORK/broken.json"
printf '{ this is not json\n' > "$S"
cp "$S" "$WORK/broken.orig"
kit_assert_fails 'merging into unparseable settings fails loudly' \
  kit_settings_merge "$S" "$CLAUDE_DIR" "$(kit_reg Stop '' kit-checkpoint.sh kit-checkpoint 0)"
kit_assert_eq "$(cat "$WORK/broken.orig")" "$(cat "$S")" \
  'and the unparseable file is left byte-for-byte alone'

kit_section 'full merge: idempotence and backups'

S="$WORK/merge.json"
cat > "$S" <<'EOF'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"rtk hook claude"}]}]}}
EOF
kit_txn_start
kit_settings_merge "$S" "$CLAUDE_DIR" \
  "$(kit_reg Stop '' kit-checkpoint.sh kit-checkpoint 0)" \
  "$(kit_reg PostToolUse 'Edit|Write|MultiEdit' kit-selffix.sh kit-selffix 0)"
kit_assert_eq '2' "${#KIT_SETTINGS_CHANGES[@]}" 'the merge reports exactly what it changed'
kit_assert_contains "${KIT_SETTINGS_CHANGES[0]}" 'added Stop hook' 'and names the specific change'
kit_assert_eq '1' "$(ls -1 "$WORK"/merge.json.bak-* 2>/dev/null | wc -l)" \
  'an existing settings.json is backed up before it is written'

kit_settings_merge "$S" "$CLAUDE_DIR" \
  "$(kit_reg Stop '' kit-checkpoint.sh kit-checkpoint 0)" \
  "$(kit_reg PostToolUse 'Edit|Write|MultiEdit' kit-selffix.sh kit-selffix 0)"
kit_assert_eq '0' "${#KIT_SETTINGS_CHANGES[@]}" 're-running the merge changes nothing'
kit_assert_eq '1' "$(ls -1 "$WORK"/merge.json.bak-* 2>/dev/null | wc -l)" \
  'and an idempotent run takes no second backup'

kit_section 'CLAUDE.md block'

SRC="$WORK/rules.md"
printf '## Kit rules\n\nSearch before reading.\n' > "$SRC"

MD="$WORK/CLAUDE.md"
RES="$(kit_md_merge "$MD" "$SRC")"
kit_assert_eq 'created' "$RES" 'a missing CLAUDE.md is created'
kit_assert_contains "$(cat "$MD")" 'Search before reading' 'with the kit rules in it'
kit_assert_contains "$(cat "$MD")" "$KIT_MD_BEGIN" 'wrapped in sentinels'

RES="$(kit_md_merge "$MD" "$SRC")"
kit_assert_eq 'already-present' "$RES" 're-merging is a no-op'
kit_assert_eq '1' "$(grep -cF "$KIT_MD_BEGIN" "$MD")" 'and does not add a second copy'

MD2="$WORK/existing.md"
printf '# My own notes\n\nDo not lose this line.\n' > "$MD2"
RES="$(kit_md_merge "$MD2" "$SRC")"
kit_assert_eq 'appended' "$RES" 'an existing CLAUDE.md is appended to'
kit_assert_contains "$(cat "$MD2")" 'Do not lose this line' "the user's own prose is preserved"
kit_assert_eq '1' "$(ls -1 "$WORK"/existing.md.bak-* 2>/dev/null | wc -l)" 'and backed up first'

RES="$(kit_md_uninstall "$MD2")"
kit_assert_eq 'removed' "$RES" 'uninstall removes the kit block'
kit_assert_contains "$(cat "$MD2")" 'Do not lose this line' "and leaves the user's prose intact"
kit_assert_not_contains "$(cat "$MD2")" 'Search before reading' 'with the kit rules gone'
kit_assert_not_contains "$(cat "$MD2")" "$KIT_MD_BEGIN" 'and the sentinels gone'

RES="$(kit_md_uninstall "$MD")"
kit_assert_eq 'removed-empty-file' "$RES" 'a CLAUDE.md that was ONLY the kit block is removed entirely'
kit_assert_file_absent "$MD" 'and the file no longer exists'

kit_assert_eq 'absent' "$(kit_md_uninstall "$WORK/never-existed.md")" \
  'uninstalling from a missing file is a clean no-op'

MD3="$WORK/foreign.md"
printf '# Someone elses file\n' > "$MD3"
kit_assert_eq 'no-kit-block' "$(kit_md_uninstall "$MD3")" \
  'a CLAUDE.md with no kit block is left alone'
kit_assert_contains "$(cat "$MD3")" 'Someone elses file' 'and untouched'

kit_section 'against the REAL settings.json on this machine'

REAL="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
if [[ -f "$REAL" ]] && jq -e . "$REAL" >/dev/null 2>&1; then
  S="$WORK/real-copy.json"
  # Strip any kit hooks already present. Once the kit is INSTALLED on this
  # machine the real settings.json contains them, and seeding with those would
  # make the round-trip assertion below compare "kit hooks present" against
  # "kit hooks correctly removed" - a guaranteed failure that says nothing
  # about the code. The point of this suite is that the kit round-trips a
  # user's OWN configuration, so the seed must be that configuration without us
  # in it.
  jq '(.hooks // {}) |= with_entries(
        .value |= map(select(((.hooks // []) | map(.command // "")
                              | any(test("kit-(selffix|checkpoint|guard)"))) | not)))
      | (.hooks // {}) |= with_entries(select((.value | length) > 0))' \
     "$REAL" > "$S"
  BEFORE_KEYS="$(jq -r 'keys | join(",")' "$S")"
  BEFORE_HOOKS="$(jq -S '.hooks' "$S")"

  kit_settings_merge "$S" "$CLAUDE_DIR" \
    "$(kit_reg Stop '' kit-checkpoint.sh kit-checkpoint 0)" \
    "$(kit_reg PostToolUse 'Edit|Write|MultiEdit' kit-selffix.sh kit-selffix 0)" >/dev/null

  kit_assert_json "$S" 'a copy of the real settings.json survives the merge as valid JSON'
  AFTER_KEYS="$(jq -r 'keys | join(",")' "$S")"
  kit_assert_eq "$BEFORE_KEYS" "$AFTER_KEYS" 'no top-level key is added or lost'

  # Every pre-existing hook command must still be present afterwards.
  MISSING=0
  while IFS= read -r cmd; do
    [[ -z "$cmd" ]] && continue
    jq -e --arg c "$cmd" '[.. | objects | select(has("command")) | .command] | any(. == $c)' \
      "$S" >/dev/null 2>&1 || MISSING=$((MISSING+1))
  done < <(printf '%s' "$BEFORE_HOOKS" | jq -r '[.. | objects | select(has("command")) | .command] | .[]' 2>/dev/null)
  kit_assert_eq '0' "$MISSING" 'every pre-existing hook command is still present'

  kit_settings_uninstall "$S" \
    "$(kit_reg Stop '' kit-checkpoint.sh kit-checkpoint 0)" \
    "$(kit_reg PostToolUse 'Edit|Write|MultiEdit' kit-selffix.sh kit-selffix 0)" >/dev/null
  AFTER_UNINSTALL="$(jq -S '.hooks' "$S")"
  kit_assert_eq "$BEFORE_HOOKS" "$AFTER_UNINSTALL" \
    'install-then-uninstall returns the real hooks to their exact original shape'
else
  kit_pass 'no real settings.json to test against (skipped)'
fi

kit_test_summary
