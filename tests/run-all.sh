#!/usr/bin/env bash
# run-all.sh - every suite, one summary.
#
# Runs each suite in its own process so a suite that leaves a global set, or
# exits early, cannot affect the next one. Reports per-suite counts and a total,
# and exits nonzero if anything failed - so it drops straight into CI.
#
# Usage:
#   run-all.sh              all suites
#   run-all.sh gate detect  only the named ones
#   run-all.sh --list       show what exists

set -uo pipefail

TEST_DIR="$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KIT_ROOT="$(dirname -- "$TEST_DIR")"

if [[ -t 1 ]]; then
  G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; O=$'\033[0m'
else
  G=''; R=''; Y=''; B=''; O=''
fi

# Ordered cheapest-and-most-fundamental first: if the process runner is broken,
# knowing that before reading forty gate failures saves real time.
#
# `tools` is EXCLUDED by default because it downloads real binaries over the
# network. Run it explicitly (`run-all.sh tools`) when changing the manifest or
# the install path.
SUITES=(process gate detect settings hooks guard newproject installer)
ALL_SUITES=(process gate detect settings hooks guard newproject installer tools)

if [[ "${1:-}" == '--list' ]]; then
  printf 'available suites:\n'
  for s in "${ALL_SUITES[@]}"; do
    if [[ " ${SUITES[*]} " == *" $s "* ]]; then printf '  %s\n' "$s"
    else printf '  %s   (network; not run by default)\n' "$s"; fi
  done
  exit 0
fi

if (( $# > 0 )); then SUITES=("$@"); fi

# Preconditions, checked once and by name. "jq: command not found" repeated
# across seven suites is a worse diagnostic than one line here.
MISSING=()
for c in bash jq curl sha256sum tar find sed awk python3 git; do
  command -v "$c" >/dev/null 2>&1 || MISSING+=("$c")
done
if (( ${#MISSING[@]} > 0 )); then
  printf '%smissing required command(s): %s%s\n' "$R" "${MISSING[*]}" "$O" >&2
  printf 'install them and re-run\n' >&2
  exit 2
fi

TOTAL_PASS=0
TOTAL_FAIL=0
FAILED_SUITES=()
START="$(date +%s)"

for suite in "${SUITES[@]}"; do
  file="$TEST_DIR/test-$suite.sh"
  if [[ ! -f "$file" ]]; then
    printf '%s?? no such suite: %s%s\n' "$Y" "$suite" "$O"
    continue
  fi

  printf '\n%s=== %s ===%s\n' "$B" "$suite" "$O"
  out="$(bash "$file" 2>&1)"
  rc=$?

  # The last line of a suite is "N passed, M failed" (or "M FAILED").
  summary="$(printf '%s\n' "$out" | grep -E '^[0-9]+ passed' | tail -1)"
  p="$(printf '%s' "$summary" | grep -oE '^[0-9]+' || printf '0')"
  f="$(printf '%s' "$summary" | grep -oiE '[0-9]+ failed' | grep -oE '^[0-9]+' || printf '0')"
  TOTAL_PASS=$(( TOTAL_PASS + p ))
  TOTAL_FAIL=$(( TOTAL_FAIL + f ))

  if (( rc == 0 )); then
    printf '%s  %s passed%s\n' "$G" "$p" "$O"
  else
    FAILED_SUITES+=("$suite")
    # On failure, show everything - a summary line is not enough to act on.
    printf '%s\n' "$out" | sed 's/^/  /'
  fi
done

ELAPSED=$(( $(date +%s) - START ))
printf '\n%s%s%s\n' "$B" '────────────────────────────────────────' "$O"
if (( TOTAL_FAIL == 0 && ${#FAILED_SUITES[@]} == 0 )); then
  printf '%s%d passed, 0 failed%s  (%ss)\n' "$G" "$TOTAL_PASS" "$O" "$ELAPSED"
  exit 0
fi
printf '%s%d passed, %d FAILED%s  (%ss)\n' "$R" "$TOTAL_PASS" "$TOTAL_FAIL" "$O" "$ELAPSED"
for s in "${FAILED_SUITES[@]}"; do printf '  failing suite: %s\n' "$s"; done
exit 1
