#!/usr/bin/env bash
# kit-test-lib.sh - a small assertion library.
#
# Deliberately not bats or shunit2: the kit installs on bare boxes and its own
# tests must run with nothing but bash. A test suite that needs a package
# manager to run is a test suite that does not get run on the machine where it
# matters.
#
# Every assertion prints one line and keeps going. A suite reports every failure
# it found rather than stopping at the first, because when a change breaks six
# things you want the list, not six edit-run cycles.

KIT_TESTS_RUN=0
KIT_TESTS_PASSED=0
KIT_TESTS_FAILED=0
KIT_FAILED_NAMES=()

if [[ -t 1 ]]; then
  _T_GREEN=$'\033[32m'; _T_RED=$'\033[31m'; _T_GRAY=$'\033[90m'; _T_OFF=$'\033[0m'
else
  _T_GREEN=''; _T_RED=''; _T_GRAY=''; _T_OFF=''
fi

kit_pass() {
  KIT_TESTS_RUN=$((KIT_TESTS_RUN+1)); KIT_TESTS_PASSED=$((KIT_TESTS_PASSED+1))
  printf '%s  ok%s %s\n' "$_T_GREEN" "$_T_OFF" "$1"
}

kit_fail_test() {
  KIT_TESTS_RUN=$((KIT_TESTS_RUN+1)); KIT_TESTS_FAILED=$((KIT_TESTS_FAILED+1))
  KIT_FAILED_NAMES+=("$1")
  printf '%sFAIL%s %s\n' "$_T_RED" "$_T_OFF" "$1"
  [[ -n "${2:-}" ]] && printf '%s     %s%s\n' "$_T_GRAY" "$2" "$_T_OFF"
  return 0
}

kit_assert_eq() {  # kit_assert_eq <expected> <actual> <name>
  if [[ "$1" == "$2" ]]; then kit_pass "$3"
  else kit_fail_test "$3" "expected '$1' but got '$2'"; fi
}

kit_assert_ne() {  # kit_assert_ne <unexpected> <actual> <name>
  if [[ "$1" != "$2" ]]; then kit_pass "$3"
  else kit_fail_test "$3" "expected something other than '$1'"; fi
}

kit_assert_contains() {  # kit_assert_contains <haystack> <needle> <name>
  if [[ "$1" == *"$2"* ]]; then kit_pass "$3"
  else kit_fail_test "$3" "expected output to contain '$2'"; fi
}

kit_assert_not_contains() {
  if [[ "$1" != *"$2"* ]]; then kit_pass "$3"
  else kit_fail_test "$3" "expected output NOT to contain '$2'"; fi
}

kit_assert_matches() {  # kit_assert_matches <text> <ere> <name>
  if [[ "$1" =~ $2 ]]; then kit_pass "$3"
  else kit_fail_test "$3" "expected '$1' to match /$2/"; fi
}

kit_assert_file_exists() {
  if [[ -f "$1" ]]; then kit_pass "$2"
  else kit_fail_test "$2" "expected file to exist: $1"; fi
}

kit_assert_file_absent() {
  if [[ ! -e "$1" ]]; then kit_pass "$2"
  else kit_fail_test "$2" "expected path NOT to exist: $1"; fi
}

kit_assert_ok() {  # kit_assert_ok <name> <command...>
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then kit_pass "$name"
  else kit_fail_test "$name" "command failed: $*"; fi
}

kit_assert_fails() {  # kit_assert_fails <name> <command...>
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then kit_fail_test "$name" "command unexpectedly succeeded: $*"
  else kit_pass "$name"; fi
}

# Valid JSON is a precondition for half this kit's contracts, so it gets a
# first-class assertion rather than being checked ad hoc.
kit_assert_json() {  # kit_assert_json <path> <name>
  if [[ -f "$1" ]] && jq -e . "$1" >/dev/null 2>&1; then kit_pass "$2"
  else kit_fail_test "$2" "not valid JSON: $1"; fi
}

kit_assert_jq() {  # kit_assert_jq <path> <jq filter> <expected> <name>
  local actual
  actual="$(jq -r "$2" "$1" 2>/dev/null)"
  if [[ "$actual" == "$3" ]]; then kit_pass "$4"
  else kit_fail_test "$4" "jq '$2' on $(basename -- "$1"): expected '$3' but got '$actual'"; fi
}

kit_section() { printf '\n%s-- %s --%s\n' "$_T_GRAY" "$1" "$_T_OFF"; }

kit_test_summary() {
  printf '\n'
  if (( KIT_TESTS_FAILED == 0 )); then
    printf '%s%d passed, 0 failed%s\n' "$_T_GREEN" "$KIT_TESTS_PASSED" "$_T_OFF"
    exit 0
  fi
  printf '%s%d passed, %d FAILED%s\n' "$_T_RED" "$KIT_TESTS_PASSED" "$KIT_TESTS_FAILED" "$_T_OFF"
  local n
  for n in "${KIT_FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done
  exit 1
}
