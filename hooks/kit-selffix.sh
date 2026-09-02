#!/usr/bin/env bash
# kit-selffix.sh - PostToolUse hook. Marks state dirty and RUNS NOTHING.
#
# This is the cheap half of the design, and its restraint is the whole point.
#
# The obvious implementation runs the project's gate after every edit. A
# ten-edit refactor then demands ten builds and ten test suites, most of them
# against a half-finished tree, and every line of that output is paid for at
# full token rate. Worse, it validates constantly while the work is incomplete
# and guarantees nothing once the work is done.
#
# So this hook records ONE fact - "something changed" - and returns. The full
# gate is enforced exactly once, at the Stop hook, when the agent believes it is
# finished. Ten edits run zero gates.
#
# It must be fast and it must never block. Anything that goes wrong here is
# swallowed: a broken bookkeeping hook that wedges a session is a far worse
# outcome than a missed dirty flag, which the next edit sets anyway.

set -uo pipefail

# Resolve the kit's lib directory from this script's real location, following
# symlinks. $PWD is the user's project, not the kit, so it is no help.
_src="${BASH_SOURCE[0]}"
while [[ -L "$_src" ]]; do
  _d="$(cd -P "$(dirname -- "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  [[ "$_src" != /* ]] && _src="$_d/$_src"
done
HOOK_DIR="$(cd -P "$(dirname -- "$_src")" && pwd)"

# Installed layout is ~/.claude/hooks/ with ~/.claude/kit-lib/ beside it; the
# in-repo layout is hooks/ with lib/ beside it. Try both.
for candidate in "$HOOK_DIR/../kit-lib" "$HOOK_DIR/../lib"; do
  if [[ -f "$candidate/kit-gate.sh" ]]; then LIB_DIR="$(cd -P "$candidate" && pwd)"; break; fi
done
[[ -n "${LIB_DIR:-}" ]] || exit 0

{
  # The event arrives on stdin as JSON. `cwd` is the project directory; without
  # it fall back to the process working directory.
  raw="$(timeout 5 cat 2>/dev/null || true)"
  start_dir=''
  if [[ -n "$raw" ]] && command -v jq >/dev/null 2>&1; then
    start_dir="$(printf '%s' "$raw" | jq -r '.cwd // ""' 2>/dev/null)"
  fi
  [[ -n "$start_dir" && -d "$start_dir" ]] || start_dir="$PWD"

  source "$LIB_DIR/kit-gate.sh" 2>/dev/null || exit 0

  root="$(kit_find_project_root "$start_dir" 2>/dev/null)" || exit 0
  [[ -n "$root" ]] || exit 0

  kit_state_mark_dirty "$root" 2>/dev/null || true
} >/dev/null 2>&1

# Always allow. This hook has no opinion about whether an edit was good; it only
# records that one happened.
exit 0
