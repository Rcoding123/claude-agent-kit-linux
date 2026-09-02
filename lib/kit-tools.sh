#!/usr/bin/env bash
# kit-tools.sh - pinned, integrity-verified external tool installation.
#
# The rule this file exists to enforce: the installer never resolves "latest"
# and never runs a binary it has not verified.
#
# Resolving "latest" at install time has two quiet failure modes:
#   - Two installs a month apart produce different bytes, so "it worked on my
#     box" carries no information.
#   - A changed or substituted asset is accepted without complaint. There is
#     nothing to notice.
#
# So every download is pinned in config/tools.manifest.json with a SHA-256 that
# was corroborated from two independent vendor sources. A hash mismatch deletes
# the file and aborts - it does NOT fall back to installing it anyway. Fail
# closed is the whole point; a fallback would make the check decorative.
#
# No package manager is used. apt/dnf/pacman all carry their own (different,
# usually older) versions, and shelling out to one re-introduces exactly the
# unpinned-version problem while also requiring root.

set -o pipefail

[[ -n "${_KIT_TOOLS_SOURCED:-}" ]] && return 0
_KIT_TOOLS_SOURCED=1

_kt_dir="$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/kit-common.sh
source "$_kt_dir/kit-common.sh"

kit_arch() {
  local m; m="$(uname -m)"
  case "$m" in
    x86_64|amd64)  printf 'x86_64' ;;
    aarch64|arm64) printf 'aarch64' ;;
    *)             printf '%s' "$m" ;;
  esac
}

kit_manifest_path() { printf '%s/config/tools.manifest.json' "$1"; }

# Read one field of a tool's arch-specific spec. Prints empty when absent.
kit_tool_field() {  # kit_tool_field <manifest> <tool> <field> [arch]
  local manifest="$1" tool="$2" field="$3" arch="${4:-$(kit_arch)}"
  jq -r --arg t "$tool" --arg a "$arch" --arg f "$field" \
    '(.tools[$t] // {}) as $spec
     | ($spec.arch[$a] // {}) as $per
     | ($per[$f] // $spec[$f] // "") | tostring' \
    "$manifest" 2>/dev/null
}

# The single decision the installer makes per tool. Pure, so it can be exercised
# without touching the network, the filesystem, or PATH.
#
# Prints: skip-disabled | present | install | reinstall
kit_tool_action() {  # kit_tool_action <enabled 0|1> <existing path> <existing ver> <pinned ver> <force 0|1>
  local enabled="$1" existing="$2" have_ver="$3" want_ver="$4" force="$5"
  [[ "$enabled" == "1" ]] || { printf 'skip-disabled'; return 0; }
  # Absence is checked BEFORE force, so a forced run on a machine that has
  # nothing installed reports 'install', not the misleading 'reinstall'.
  [[ -n "$existing" ]] || { printf 'install'; return 0; }
  [[ "$force" == "1" ]] && { printf 'reinstall'; return 0; }
  # An installed tool whose version we cannot read is left alone rather than
  # clobbered: it may be a deliberate system install we do not own.
  [[ -n "$have_ver" ]] || { printf 'present'; return 0; }
  [[ -n "$want_ver" ]] || { printf 'present'; return 0; }
  [[ "$have_ver" == "$want_ver" ]] && { printf 'present'; return 0; }
  printf 'reinstall'
}

# Parse a version out of `tool --version`. Both rg and rtk print "<name> <semver>"
# but anything is tolerated by falling back to the first semver seen.
kit_tool_version() {  # kit_tool_version <executable>
  local exe="$1" out
  out="$("$exe" --version 2>&1 | head -5)" || return 1
  [[ "$out" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]] && { printf '%s' "${BASH_REMATCH[1]}"; return 0; }
  return 1
}

# Where a tool the kit manages actually lives.
#
# NOT plain `command -v`: that searches $PATH, and the kit's own bin directory is
# usually NOT on the $PATH of the shell running the installer - it was only just
# added, and a login shell has to be restarted to see it. So `command -v rg`
# finds /usr/bin/rg, and two things go wrong:
#
#   - `doctor` reports the SYSTEM binary's version right after installing a
#     different one, which reads as though the install did nothing.
#   - worse, if the system copy happens to match the pinned version, the
#     installer decides the tool is 'present' and never places its own. The
#     install reports success and ~/.local/bin stays empty.
#
# The kit's own copy wins when it exists; otherwise fall back to $PATH, which is
# the right answer for "is this tool available at all".
kit_tool_path() {  # kit_tool_path <bin name> <install dir>
  local bin="$1" dir="$2"
  [[ -n "$dir" && -x "$dir/$bin" ]] && { printf '%s' "$dir/$bin"; return 0; }
  command -v "$bin" 2>/dev/null || true
}

# Download + verify + extract + place. Fails closed at every step.
kit_install_pinned_tool() {  # kit_install_pinned_tool <manifest> <tool> <install dir>
  local manifest="$1" tool="$2" install_dir="$3"
  local arch; arch="$(kit_arch)"

  local version url asset sha bin
  version="$(kit_tool_field "$manifest" "$tool" version)"
  url="$(kit_tool_field "$manifest" "$tool" url "$arch")"
  asset="$(kit_tool_field "$manifest" "$tool" asset "$arch")"
  sha="$(kit_tool_field "$manifest" "$tool" sha256 "$arch")"
  bin="$(kit_tool_field "$manifest" "$tool" bin)"

  if [[ -z "$url" ]]; then
    kit_die "no pinned asset for $tool on $arch" \
            "Add an entry under tools.$tool.arch.$arch in config/tools.manifest.json."
    return 1
  fi
  # An empty or malformed hash is refused rather than treated as "skip the
  # check". A verification step that can be turned off by leaving a field blank
  # is not a verification step.
  if [[ ! "$sha" =~ ^[0-9a-f]{64}$ ]]; then
    kit_die "manifest entry '$tool' ($arch) has no usable SHA-256 (got '${sha:-<empty>}')" \
            "Populate a 64-hex-character sha256 from the vendor's published checksum. The installer will not download an unverifiable asset."
    return 1
  fi

  if kit_is_dry_run; then
    kit_info "would download $tool $version from $url"
    kit_info "would verify sha256 $sha, then place $bin in $install_dir"
    return 0
  fi

  local work; work="$(mktemp -d)" || return 1
  # shellcheck disable=SC2064
  trap "rm -rf -- '$work'" RETURN

  local archive="$work/$asset"
  kit_info "downloading $tool $version ($arch)"
  # --fail so an HTML error page is not silently saved as if it were the asset;
  # --location because release URLs redirect to a CDN.
  if ! curl --fail --location --silent --show-error \
            --connect-timeout 20 --max-time 300 \
            -A 'claude-agent-kit' -o "$archive" "$url"; then
    kit_die "download failed for $tool" "Check network access to $url and re-run."
    return 1
  fi
  [[ -s "$archive" ]] || { kit_die "download produced an empty file for $tool"; return 1; }

  local actual; actual="$(sha256sum < "$archive" | cut -d' ' -f1)"
  if [[ "$actual" != "$sha" ]]; then
    rm -f -- "$archive"
    kit_die "INTEGRITY CHECK FAILED for $tool $version
     expected sha256 $sha
     actual   sha256 $actual
     source          $url" \
            "The downloaded file was deleted and nothing was installed. Either the vendor re-cut the release, or the download was tampered with. Do NOT bypass this: re-verify the hash from the vendor's published checksum file and update config/tools.manifest.json deliberately."
    return 1
  fi
  kit_ok "$tool $version sha256 verified"

  local extract="$work/x"; mkdir -p "$extract"
  case "$asset" in
    *.tar.gz|*.tgz) tar -xzf "$archive" -C "$extract" 2>/dev/null ;;
    *.tar.xz)       tar -xJf "$archive" -C "$extract" 2>/dev/null ;;
    *.zip)          kit_have unzip && unzip -q "$archive" -d "$extract" 2>/dev/null ;;
    *) kit_die "unsupported archive type for $asset" "Add support or pin a .tar.gz asset."; return 1 ;;
  esac || { kit_die "could not extract $asset"; return 1; }

  local found
  found="$(find "$extract" -type f -name "$bin" -print -quit 2>/dev/null)"
  if [[ -z "$found" ]]; then
    kit_die "$bin was not found inside $asset" \
            "The vendor changed the archive layout. Update the 'bin' field in config/tools.manifest.json to match."
    return 1
  fi

  mkdir -p -- "$install_dir"
  local dest="$install_dir/$bin"
  kit_backup_file "$dest" >/dev/null
  install -m 0755 -- "$found" "$dest" || { kit_die "could not install to $dest"; return 1; }
  kit_ok "$tool -> $dest"
  return 0
}

# --- PATH ---------------------------------------------------------------------
# A substring test ($PATH == *"$dir"*) reports a false positive whenever one
# entry is a prefix of another (/opt/bin vs /opt/bin2), so compare whole,
# normalised entries.
kit_on_path() {  # kit_on_path <directory> [path value]
  local target="${1%/}" value="${2:-$PATH}" entry
  local IFS=':'
  for entry in $value; do
    [[ -z "$entry" ]] && continue
    [[ "${entry%/}" == "$target" ]] && return 0
  done
  return 1
}

# Which shell rc file to append to. Prints empty when none is appropriate.
kit_shell_rc() {
  local shell_name; shell_name="$(basename -- "${SHELL:-/bin/bash}")"
  case "$shell_name" in
    zsh)  printf '%s/.zshrc' "$HOME" ;;
    bash)
      # A login shell reads .bash_profile and NOT .bashrc on some distros, but
      # .bashrc is what interactive terminals actually use; prefer whichever
      # already exists so we do not create a second competing file.
      if [[ -f "$HOME/.bashrc" ]]; then printf '%s/.bashrc' "$HOME"
      elif [[ -f "$HOME/.bash_profile" ]]; then printf '%s/.bash_profile' "$HOME"
      else printf '%s/.bashrc' "$HOME"; fi
      ;;
    fish) printf '%s/.config/fish/config.fish' "$HOME" ;;
    *)    printf '%s/.profile' "$HOME" ;;
  esac
}

# Prints: already-present | added | would-add | manual
kit_add_to_path() {  # kit_add_to_path <directory>
  local dir="$1"
  if kit_on_path "$dir"; then printf 'already-present'; return 0; fi
  local rc; rc="$(kit_shell_rc)"
  if [[ -z "$rc" ]]; then printf 'manual'; return 0; fi

  # Already written by a previous run? Do not append a second line.
  if [[ -f "$rc" ]] && grep -qF "claude-agent-kit PATH" "$rc" 2>/dev/null; then
    export PATH="$PATH:$dir"
    printf 'already-present'; return 0
  fi
  if kit_is_dry_run; then kit_info "would add $dir to PATH via $rc"; printf 'would-add'; return 0; fi

  kit_backup_file "$rc" >/dev/null
  if [[ "$rc" == *fish* ]]; then
    mkdir -p -- "$(dirname -- "$rc")"
    printf '\n# claude-agent-kit PATH\nfish_add_path %s\n' "$dir" >> "$rc"
  else
    printf '\n# claude-agent-kit PATH\nexport PATH="$PATH:%s"\n' "$dir" >> "$rc"
  fi
  export PATH="$PATH:$dir"
  kit_info "added $dir to PATH via $(basename -- "$rc")"
  printf 'added'
}
