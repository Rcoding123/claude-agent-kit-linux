#!/usr/bin/env bash
# test-tools.sh - the pinned download path, for real.
#
# This is the one suite that touches the network, so it is NOT in the default
# run-all set. Run it explicitly:  ./tests/run-all.sh tools
#
# It exists because everything else in this kit skips tool installation
# (--no-tools), which left the download-verify-extract-place path as the largest
# piece of code in the repo that had never once executed. Hashes that have never
# been checked against a real download are hashes nobody has verified.
#
# The assertion that matters is the NEGATIVE one: a corrupted download must be
# refused and deleted. A verification step that has only ever been observed
# passing is indistinguishable from one that always returns true.
#
# Skips cleanly with no network rather than failing, because a suite that cannot
# run offline is a suite people stop running.

set -uo pipefail

TEST_DIR="$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KIT_ROOT="$(dirname -- "$TEST_DIR")"
source "$TEST_DIR/kit-test-lib.sh"
source "$KIT_ROOT/lib/kit-tools.sh"

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

MANIFEST="$(kit_manifest_path "$KIT_ROOT")"
ARCH="$(kit_arch)"

kit_section 'the manifest itself'

kit_assert_json "$MANIFEST" 'the manifest is valid JSON'
kit_assert_jq "$MANIFEST" '.tools | keys | length' '2' 'it pins two tools'

# Every pinned hash must be a real 64-hex digest. An empty or short hash would
# make the integrity check decorative, and it is exactly the kind of thing that
# rots when someone bumps a version in a hurry.
BAD_HASH=0
UNPINNED=()
while IFS=$'\t' read -r tool arch sha; do
  if [[ -z "$sha" ]]; then
    UNPINNED+=("$tool/$arch")
  elif [[ ! "$sha" =~ ^[0-9a-f]{64}$ ]]; then
    BAD_HASH=$((BAD_HASH+1))
  fi
done < <(jq -r '.tools | to_entries[] | .key as $t | .value.arch | to_entries[]
                | [$t, .key, (.value.sha256 // "")] | @tsv' "$MANIFEST")
kit_assert_eq '0' "$BAD_HASH" 'every populated hash is a well-formed 64-hex digest'

# A deliberately unpinned arch is fine, PROVIDED the installer refuses it. That
# is asserted below rather than assumed here.
if (( ${#UNPINNED[@]} > 0 )); then
  kit_pass "unpinned entries exist and must be refused: ${UNPINNED[*]}"
fi

# Provenance is part of the contract: a hash with no stated source cannot be
# re-verified by the next person to touch this file.
NO_PROV="$(jq -r '[.tools | to_entries[] | .value.arch | to_entries[]
                  | select((.value.sha256 // "") != "")
                  | select(((.value.verifiedFrom // []) | length) < 2)] | length' "$MANIFEST")"
kit_assert_eq '0' "$NO_PROV" 'every pinned hash cites two independent sources'

kit_section 'the pure decision function'

kit_assert_eq 'install'      "$(kit_tool_action 1 ''         ''       '1.0.0' 0)" 'absent -> install'
kit_assert_eq 'present'      "$(kit_tool_action 1 '/usr/bin/x' '1.0.0' '1.0.0' 0)" 'matching version -> present'
kit_assert_eq 'reinstall'    "$(kit_tool_action 1 '/usr/bin/x' '0.9.0' '1.0.0' 0)" 'older version -> reinstall'
kit_assert_eq 'reinstall'    "$(kit_tool_action 1 '/usr/bin/x' '1.0.0' '1.0.0' 1)" '--force -> reinstall'
kit_assert_eq 'skip-disabled' "$(kit_tool_action 0 ''         ''       '1.0.0' 0)" 'disabled -> skipped'
# Absence is checked BEFORE force, so a forced run on a clean machine reports
# the truth rather than the misleading 'reinstall'.
kit_assert_eq 'install'      "$(kit_tool_action 1 ''         ''       '1.0.0' 1)" '--force on a clean machine still says install'
# An installed tool whose version cannot be read is left alone: it may be a
# deliberate system install the kit does not own.
kit_assert_eq 'present'      "$(kit_tool_action 1 '/usr/bin/x' ''      '1.0.0' 0)" 'unreadable version -> left alone'

kit_section 'PATH handling'

kit_assert_ok    'an exact entry is found on PATH'      kit_on_path '/opt/bin' '/usr/bin:/opt/bin:/bin'
kit_assert_ok    'a trailing slash still matches'       kit_on_path '/opt/bin/' '/usr/bin:/opt/bin:/bin'
kit_assert_fails 'a PREFIX of an entry does not match'  kit_on_path '/opt/bin' '/usr/bin:/opt/bin2:/bin'
kit_assert_fails 'an absent directory is absent'        kit_on_path '/nope' '/usr/bin:/bin'
# The naive substring test would pass the /opt/bin2 case above and silently skip
# adding the directory, leaving the installed binaries unreachable.

kit_section 'refusing what cannot be verified'

# An arch with no pinned hash must be refused rather than downloaded.
FAKE="$WORK/unpinned.json"
jq '.tools.ripgrep.arch.x86_64.sha256 = ""' "$MANIFEST" > "$FAKE"
kit_assert_fails 'an empty hash is refused, not treated as "skip the check"' \
  kit_install_pinned_tool "$FAKE" ripgrep "$WORK/bin"
kit_assert_file_absent "$WORK/bin/rg" 'and nothing is installed'

FAKE2="$WORK/shorthash.json"
jq '.tools.ripgrep.arch.x86_64.sha256 = "abc123"' "$MANIFEST" > "$FAKE2"
kit_assert_fails 'a malformed hash is refused' \
  kit_install_pinned_tool "$FAKE2" ripgrep "$WORK/bin"

FAKE3="$WORK/noarch.json"
jq '.tools.ripgrep.arch = {}' "$MANIFEST" > "$FAKE3"
kit_assert_fails 'a tool with no asset for this arch is refused' \
  kit_install_pinned_tool "$FAKE3" ripgrep "$WORK/bin"

kit_section 'live download'

# Offline is a skip, not a failure.
if ! curl --fail --silent --head --max-time 10 https://github.com >/dev/null 2>&1; then
  kit_pass 'no network - live download tests skipped'
  kit_test_summary
fi

for TOOL in ripgrep rtk; do
  BIN="$(kit_tool_field "$MANIFEST" "$TOOL" bin)"
  WANT="$(kit_tool_field "$MANIFEST" "$TOOL" version)"
  DEST="$WORK/live-$TOOL"

  if kit_install_pinned_tool "$MANIFEST" "$TOOL" "$DEST" >/dev/null 2>&1; then
    kit_pass "$TOOL $WANT downloads and verifies against its pinned hash"
    kit_assert_file_exists "$DEST/$BIN" "and $BIN lands in the install directory"
    [[ -x "$DEST/$BIN" ]] && kit_pass "and $BIN is executable" \
                          || kit_fail_test "and $BIN is executable"
    # The real proof: the binary runs and reports the version we pinned.
    GOT="$(kit_tool_version "$DEST/$BIN" 2>/dev/null || printf '')"
    kit_assert_eq "$WANT" "$GOT" "and the INSTALLED $BIN reports version $WANT"
  else
    kit_fail_test "$TOOL $WANT downloads and verifies" \
      'the download or verification failed - check the pinned hash against the vendor checksum'
  fi
done

kit_section 'cross-arch: the aarch64 entries are real'

# This box is x86_64, so an arm64 binary cannot be RUN here - but the part that
# would otherwise be pure assertion (does the pinned hash match a real asset,
# does the archive contain the binary the manifest names, is it actually an
# arm64 ELF) can all be proven by driving the real installer with kit_arch()
# forced. Without this, "aarch64 supported" would be a claim backed by nothing.
if [[ "$ARCH" != 'aarch64' ]]; then
  ( kit_arch() { printf 'aarch64'; }
    for TOOL in ripgrep rtk; do
      BIN="$(jq -r --arg t "$TOOL" '.tools[$t].bin' "$MANIFEST")"
      DEST="$WORK/arm-$TOOL"
      if kit_install_pinned_tool "$MANIFEST" "$TOOL" "$DEST" >/dev/null 2>&1 \
         && [[ -f "$DEST/$BIN" ]] \
         && file -b "$DEST/$BIN" | grep -q 'aarch64'; then
        printf 'PASS %s\n' "$TOOL"
      else
        printf 'FAIL %s\n' "$TOOL"
      fi
    done ) > "$WORK/arm-results" 2>/dev/null

  for TOOL in ripgrep rtk; do
    if grep -q "^PASS $TOOL\$" "$WORK/arm-results" 2>/dev/null; then
      kit_pass "the pinned aarch64 $TOOL asset verifies and yields a real arm64 binary"
    else
      kit_fail_test "the pinned aarch64 $TOOL asset verifies and yields a real arm64 binary" \
        'the hash, the archive layout, or the asset architecture is wrong in the manifest'
    fi
  done
else
  kit_pass 'running ON aarch64 - the live download tests above already cover it'
fi

kit_section 'a CORRUPTED download is refused'

# The most important assertion in this file. Point the manifest at a real,
# reachable asset but pin the WRONG hash. The installer must delete the file and
# abort - not warn, not fall back, not install it anyway.
CORRUPT="$WORK/corrupt.json"
jq --arg s '0000000000000000000000000000000000000000000000000000000000000000' \
   ".tools.ripgrep.arch.\"$ARCH\".sha256 = \$s" "$MANIFEST" > "$CORRUPT"

OUT="$(kit_install_pinned_tool "$CORRUPT" ripgrep "$WORK/corrupt-bin" 2>&1)"
RC=$?
kit_assert_ne '0' "$RC" 'A HASH MISMATCH ABORTS THE INSTALL'
kit_assert_file_absent "$WORK/corrupt-bin/rg" 'and the binary is NOT installed anyway'
kit_assert_contains "$OUT" 'INTEGRITY CHECK FAILED' 'and it says so unmistakably'
kit_assert_contains "$OUT" 'expected sha256' 'naming the hash it wanted'
kit_assert_contains "$OUT" 'actual   sha256' 'and the hash it got'
kit_assert_contains "$OUT" 'Do NOT bypass' 'and refuses to suggest a workaround'

kit_section 'a bad URL fails cleanly'

BADURL="$WORK/badurl.json"
jq ".tools.ripgrep.arch.\"$ARCH\".url = \"https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/does-not-exist.tar.gz\"" \
   "$MANIFEST" > "$BADURL"
kit_assert_fails 'a 404 is a failure, not an empty file treated as an asset' \
  kit_install_pinned_tool "$BADURL" ripgrep "$WORK/badurl-bin"
kit_assert_file_absent "$WORK/badurl-bin/rg" 'and nothing is installed'

kit_test_summary
