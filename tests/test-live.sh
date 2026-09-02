#!/usr/bin/env bash
# test-live.sh - the hook CONTRACT, verified against real Claude Code.
#
# Not in the default run-all set: it spends real tokens and needs an
# authenticated `claude`. Run it explicitly, and after any Claude Code upgrade:
#
#   ./tests/run-all.sh live
#
# WHY THIS EXISTS
# Every other suite drives the hooks through the event contract as the AUTHOR
# understands it. That proves the kit is self-consistent; it cannot prove the
# contract is real. The distinction is not academic - a documentation review of
# this same API recommended blocking a Stop with
# {"hookSpecificOutput":{...,"reason":...}}, and that form measurably does NOT
# block. Adopting it would have left every hook running, reporting success, and
# gating nothing.
#
# So each case here drives `claude -p` with a SENTINEL word in the hook output
# and checks whether the agent echoes it back. An agent that repeats the
# sentinel saw the message; one that does not, did not.
#
# The user's ~/.claude is never touched: HOME and CLAUDE_CONFIG_DIR are left
# alone (credentials live there, and overriding either just yields "Not logged
# in"), and the hooks are staged in a temp dir referenced from a temp
# --settings file with --setting-sources '' so no user/project settings load.

set -uo pipefail

TEST_DIR="$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KIT_ROOT="$(dirname -- "$TEST_DIR")"
source "$TEST_DIR/kit-test-lib.sh"

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

if ! command -v claude >/dev/null 2>&1; then
  kit_pass 'claude CLI not installed - live contract tests skipped'
  kit_test_summary
fi

# One cheap call establishes both reachability and authentication. Skipping is
# correct when offline or logged out; failing would make the suite unrunnable
# in CI for reasons unrelated to the kit.
PROBE="$(cd "$WORK" && timeout 90 claude -p 'Say PROBE_OK' \
          --setting-sources '' --dangerously-skip-permissions </dev/null 2>&1)"
if ! printf '%s' "$PROBE" | grep -q 'PROBE_OK'; then
  kit_pass "claude is not usable here (offline or not logged in) - live tests skipped"
  kit_test_summary
fi

# stage <name> <event> <matcher> <hook body...>
stage() {
  local n="$1" event="$2" matcher="$3"; shift 3
  mkdir -p "$WORK/$n/proj"
  printf '%s\n' "$@" > "$WORK/$n/hook.sh"
  chmod +x "$WORK/$n/hook.sh"
  jq -n --arg e "$event" --arg m "$matcher" --arg c "$WORK/$n/hook.sh" \
    '{hooks: {($e): [{matcher: $m, hooks: [{type:"command", command:$c, timeout:30}]}]}}' \
    > "$WORK/$n/settings.json"
}

# ask <name> <prompt> -> the agent's output
ask() {
  local n="$1" prompt="$2"
  ( cd "$WORK/$n/proj" && timeout 240 claude -p "$prompt" \
      --settings "$WORK/$n/settings.json" \
      --setting-sources '' \
      --dangerously-skip-permissions </dev/null 2>&1 )
}

# saw <output> <sentinel> <name>  - did the message reach the model?
saw() {
  if printf '%s' "$1" | grep -qi "$2"; then kit_pass "$3"
  else kit_fail_test "$3" "the agent never echoed '$2'"; fi
}
not_saw() {
  if printf '%s' "$1" | grep -qi "$2"; then kit_fail_test "$3" "unexpectedly saw '$2'"
  else kit_pass "$3"; fi
}

# A hook that fires once, so a blocked stop cannot loop forever in a test.
ONCE='[[ -f "$(dirname "$0")/fired" ]] && exit 0'
MARK='touch "$(dirname "$0")/fired"'

kit_section 'Stop: which output form actually blocks'

# THE form the kit uses.
stage decision Stop '' '#!/usr/bin/env bash' 'cat >/dev/null' "$ONCE" "$MARK" \
  'printf "%s\\n" "{\"decision\":\"block\",\"reason\":\"SENTINEL_ALPHA fix it and stop again\"}"' \
  'exit 0'
OUT="$(ask decision 'Say READY and stop.')"
saw "$OUT" 'ALPHA' 'decision:block DOES block the stop and the reason reaches the agent'

# The form a docs reading suggests - which does NOT work. Asserted so that if a
# future Claude Code starts honouring it, this test fails and tells us the
# contract moved, rather than us finding out some other way.
stage hso Stop '' '#!/usr/bin/env bash' 'cat >/dev/null' "$ONCE" "$MARK" \
  'printf "%s\\n" "{\"hookSpecificOutput\":{\"hookEventName\":\"Stop\",\"reason\":\"SENTINEL_BRAVO\"}}"' \
  'exit 0'
OUT="$(ask hso 'Say READY and stop.')"
not_saw "$OUT" 'BRAVO' 'hookSpecificOutput.reason does NOT block (the kit must not switch to it)'

# exit 2 also blocks; the kit does not use it, but knowing it works is the
# fallback if the JSON contract ever changes.
stage exit2 Stop '' '#!/usr/bin/env bash' 'cat >/dev/null' "$ONCE" "$MARK" \
  'printf "SENTINEL_CHARLIE blocked via exit 2\\n" >&2' 'exit 2'
OUT="$(ask exit2 'Say READY and stop.')"
saw "$OUT" 'CHARLIE' 'exit 2 also blocks a stop (an available fallback)'

kit_section 'Stop: additionalContext reaches the model without blocking'

# The kit's GIVE-UP path: allow the stop, but put the unresolved failure in
# front of the agent. Worthless if the text never arrives.
stage ctx Stop '' '#!/usr/bin/env bash' 'cat >/dev/null' "$ONCE" "$MARK" \
  'printf "%s\\n" "{\"hookSpecificOutput\":{\"hookEventName\":\"Stop\",\"additionalContext\":\"SENTINEL_DELTA the gate could not run\"}}"' \
  'exit 0'
OUT="$(ask ctx 'Say READY and stop.')"
saw "$OUT" 'DELTA' 'additionalContext reaches the agent (the give-up report is not lost)'

kit_section 'PreToolUse: exit 2 denies EVEN under bypassPermissions'

# The entire premise of the autonomous guard. If this stops holding, that layer
# is decorative and must not be described as a fence.
stage guard PreToolUse Bash '#!/usr/bin/env bash' \
  'IN="$(cat)"' \
  'CMD="$(printf "%s" "$IN" | jq -r ".tool_input.command // \"\"")"' \
  'if printf "%s" "$CMD" | grep -q FORBIDDEN_MARKER; then' \
  '  printf "SENTINEL_ECHO blocked by policy\\n" >&2; exit 2' \
  'fi' \
  'exit 0'
OUT="$(ask guard 'Run exactly this bash command once: echo FORBIDDEN_MARKER. Then tell me what happened.')"
saw "$OUT" 'SENTINEL_ECHO\|block' 'PreToolUse exit 2 DENIES the call under --dangerously-skip-permissions'

kit_section 'the event payload carries what the kit reads'

stage payload Stop '' '#!/usr/bin/env bash' \
  "cat > \"$WORK/payload/event.json\"" 'exit 0'
ask payload 'Say READY and stop.' >/dev/null
EV="$WORK/payload/event.json"
kit_assert_json "$EV" 'the Stop event is valid JSON'
kit_assert_jq "$EV" '.hook_event_name' 'Stop' 'hook_event_name is present'
kit_assert_jq "$EV" '(.cwd | length) > 0' 'true' 'cwd is present (the kit locates the project with it)'
kit_assert_jq "$EV" '.stop_hook_active | type' 'boolean' 'stop_hook_active is a real boolean (brake 3)'
kit_assert_jq "$EV" '.permission_mode' 'bypassPermissions' 'permission_mode reports the bypass mode'

kit_test_summary
