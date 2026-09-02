#!/usr/bin/env bash
# test-newproject.sh - the per-repo initializer, end to end.
#
# This is where the pure planners meet the filesystem. The assertions worth
# caring about:
#   - the gate it writes is VALID JSON that the gate reader can read back
#   - a command containing quotes/backslashes/newlines round-trips intact
#   - it never overwrites a CLAUDE.md or a gate.json without being told to
#   - the helper scripts the gate NAMES are actually written
#   - a project it cannot understand is marked unconfigured rather than given a
#     gate that validates nothing

set -uo pipefail

TEST_DIR="$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KIT_ROOT="$(dirname -- "$TEST_DIR")"
source "$TEST_DIR/kit-test-lib.sh"
source "$KIT_ROOT/lib/kit-gate.sh"

NP="$KIT_ROOT/scripts/new-project.sh"
GATE_BIN="$KIT_ROOT/scripts/kit-gate"

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

kit_section 'a python project'

P="$WORK/pyproj"; mkdir -p "$P/src"
touch "$P/pyproject.toml"
printf 'x = 1\n' > "$P/src/app.py"
bash "$NP" "$P" --quiet >/dev/null 2>&1
RC=$?
kit_assert_eq '0' "$RC" 'new-project succeeds on a python project'
kit_assert_json "$P/.claude/gate.json" 'it writes valid JSON'
kit_assert_jq "$P/.claude/gate.json" '.language' 'python' 'and records the detected language'
kit_assert_jq "$P/.claude/gate.json" '.configured' 'true' 'and marks it configured'
kit_assert_file_exists "$P/.claude/py-syntax.py" 'the helper the gate NAMES is actually written'
kit_assert_file_exists "$P/CLAUDE.md" 'a starter CLAUDE.md is created'

# The gate reader must be able to read back exactly what the writer produced.
kit_gate_config "$P"
kit_assert_eq '1' "$KIT_GATE_OK" 'the gate it wrote is readable by the gate reader'
kit_assert_contains "$(printf '%s\n' "${KIT_GATE_FULL[@]}")" 'py-syntax.py' \
  'and the syntax command survives the round trip'

# And the gate it wrote must actually PASS on a clean project.
bash "$GATE_BIN" full "$P" >/dev/null 2>&1
kit_assert_eq '0' "$?" 'THE GENERATED GATE PASSES on a clean project'

# ...and FAIL on a broken one. A gate that cannot fail is not a gate.
printf 'def broken(:\n' > "$P/src/bad.py"
bash "$GATE_BIN" full "$P" >/dev/null 2>&1
kit_assert_ne '0' "$?" 'and FAILS on a syntax error'
rm -f "$P/src/bad.py"

kit_section 'idempotence and not clobbering'

printf '# my own notes\n' > "$P/CLAUDE.md"
cp "$P/.claude/gate.json" "$WORK/gate-before.json"
bash "$NP" "$P" --quiet >/dev/null 2>&1
kit_assert_eq '# my own notes' "$(cat "$P/CLAUDE.md")" \
  'a second run does NOT overwrite an existing CLAUDE.md'
kit_assert_eq "$(cat "$WORK/gate-before.json")" "$(cat "$P/.claude/gate.json")" \
  'and does NOT overwrite an existing gate.json'

bash "$NP" "$P" --quiet --force --fast 'echo forced' >/dev/null 2>&1
kit_assert_jq "$P/.claude/gate.json" '.fast[0]' 'echo forced' '--force does overwrite it'

kit_section 'explicit commands beat detection'

P="$WORK/explicit"; mkdir -p "$P"; touch "$P/Cargo.toml"
bash "$NP" "$P" --quiet --fast 'make lint' --full 'make check' >/dev/null 2>&1
kit_assert_jq "$P/.claude/gate.json" '.fast[0]' 'make lint'  'an explicit --fast is used verbatim'
kit_assert_jq "$P/.claude/gate.json" '.full[0]' 'make check' 'an explicit --full is used verbatim'
kit_assert_jq "$P/.claude/gate.json" '.full | length' '1' 'and detection is not mixed in'

kit_section 'awkward commands round-trip'

# A command containing quotes, a backslash and a newline. Hand-assembled JSON
# breaks on every one of these; this is why the writer goes through jq.
P="$WORK/awkward"; mkdir -p "$P"
AWKWARD='echo "it'"'"'s \\ tricky"
echo second-line'
bash "$NP" "$P" --quiet --full "$AWKWARD" >/dev/null 2>&1
kit_assert_json "$P/.claude/gate.json" 'a gate with quotes/backslashes/newlines is valid JSON'
kit_gate_config "$P"
kit_assert_eq '1' "${#KIT_GATE_FULL[@]}" 'a multi-line command stays ONE command through the round trip'
kit_assert_eq "$AWKWARD" "${KIT_GATE_FULL[0]}" 'and is byte-identical to what was passed in'

kit_section 'a project the kit cannot understand'

P="$WORK/mystery"; mkdir -p "$P"
printf 'some data\n' > "$P/data.txt"
bash "$NP" "$P" --quiet >/dev/null 2>&1
kit_assert_json "$P/.claude/gate.json" 'an unknown project still gets a valid gate file'
kit_assert_jq "$P/.claude/gate.json" '.configured' 'false' \
  'MARKED UNCONFIGURED rather than looking wired while validating nothing'
kit_assert_jq "$P/.claude/gate.json" '.full | length' '0' 'with no invented commands'
NOTES="$(jq -r '.notes | join(" ")' "$P/.claude/gate.json")"
kit_assert_contains "$NOTES" 'deliberate' 'and the file explains that this is deliberate'

# The gate reader must refuse it, and the Stop hook must therefore fail OPEN.
kit_assert_fails 'and the gate reader refuses it' kit_gate_config "$P"

kit_section 'a shell project'

P="$WORK/shproj"; mkdir -p "$P"
printf '#!/bin/bash\necho hi\n' > "$P/run.sh"
bash "$NP" "$P" --quiet >/dev/null 2>&1
kit_assert_jq "$P/.claude/gate.json" '.language' 'shell' 'a loose .sh project is detected as shell'
kit_assert_file_exists "$P/.claude/sh-syntax.sh" 'and its syntax helper is written'
bash "$GATE_BIN" full "$P" >/dev/null 2>&1
kit_assert_eq '0' "$?" 'the generated shell gate passes on clean scripts'
printf '#!/bin/bash\nif [ 1 ; then\n' > "$P/broken.sh"
bash "$GATE_BIN" full "$P" >/dev/null 2>&1
kit_assert_ne '0' "$?" 'and fails on a parse error'

kit_section 'dry run changes nothing'

P="$WORK/dry"; mkdir -p "$P"; touch "$P/Cargo.toml"
bash "$NP" "$P" --quiet --dry-run >/dev/null 2>&1
kit_assert_file_absent "$P/.claude/gate.json" '--dry-run writes no gate'
kit_assert_file_absent "$P/CLAUDE.md" '--dry-run writes no CLAUDE.md'

kit_section 'gitignore'

P="$WORK/gitproj"; mkdir -p "$P"; git -C "$P" init -q 2>/dev/null
touch "$P/Cargo.toml"
bash "$NP" "$P" --quiet >/dev/null 2>&1
kit_assert_contains "$(cat "$P/.gitignore" 2>/dev/null)" 'kit-state.json' \
  'per-machine runtime state is gitignored'
bash "$NP" "$P" --quiet --force >/dev/null 2>&1
kit_assert_eq '1' "$(grep -c 'kit-state.json' "$P/.gitignore")" \
  'and a second run does not append it twice'

kit_section 'kit-gate --show'

P="$WORK/showproj"; mkdir -p "$P"; touch "$P/Cargo.toml"
bash "$NP" "$P" --quiet >/dev/null 2>&1
OUT="$(bash "$GATE_BIN" --show "$P" 2>&1)"
kit_assert_contains "$OUT" 'language: rust' '--show reports the language'
kit_assert_contains "$OUT" 'cargo'          'and lists the real commands'

kit_section 'against this repository itself'

# The kit is a shell project, so it should detect itself and write a gate that
# passes over its own scripts. Run in a copy so the real repo is untouched.
SELF="$WORK/selfcopy"
mkdir -p "$SELF"
cp -r "$KIT_ROOT/lib" "$KIT_ROOT/scripts" "$KIT_ROOT/hooks" "$SELF/" 2>/dev/null
bash "$NP" "$SELF" --quiet >/dev/null 2>&1
kit_assert_jq "$SELF/.claude/gate.json" '.language' 'shell' 'the kit detects ITSELF as a shell project'
bash "$GATE_BIN" full "$SELF" >/dev/null 2>&1
kit_assert_eq '0' "$?" "AND THE KIT'S OWN SCRIPTS PASS THE GATE IT GENERATES"

kit_test_summary
