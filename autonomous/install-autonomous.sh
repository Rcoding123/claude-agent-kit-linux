#!/usr/bin/env bash
# install-autonomous.sh - wire the PreToolUse guard.
#
# Separate from the main installer on purpose. The guard blocks commands
# WITHOUT asking, which is right for an unattended box and wrong for a laptop
# where you are sitting at the keyboard and would rather be asked. Opting in is
# a deliberate act.
#
#   install-autonomous.sh              install the guard
#   install-autonomous.sh uninstall    remove it
#   install-autonomous.sh --dry-run    show what would happen

set -uo pipefail

AUTO_DIR="$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KIT_ROOT="$(dirname -- "$AUTO_DIR")"
source "$KIT_ROOT/lib/kit-common.sh"
source "$KIT_ROOT/lib/kit-settings.sh"

MODE='install'
while (( $# > 0 )); do
  case "$1" in
    install|uninstall) MODE="$1"; shift ;;
    --dry-run) KIT_DRY_RUN=1; shift ;;
    --quiet)   KIT_QUIET=1; shift ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
    *) kit_die "unknown argument: $1"; exit 1 ;;
  esac
done

kit_require jq || exit 1

CLAUDE_DIR="$(kit_claude_dir)"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS="$CLAUDE_DIR/settings.json"
US=$'\x1f'

# --first is load-bearing. RTK's PreToolUse hook REWRITES the command, so a
# guard registered after it would inspect something the user never typed - and
# would miss a blocked command that RTK's rewrite happens to reshape.
REGISTRATION="PreToolUse${US}Bash${US}kit-guard.sh${US}kit-guard${US}1"

case "$MODE" in
  install)
    kit_txn_start
    kit_mkdir "$CLAUDE_DIR" "$HOOKS_DIR" || exit 1

    res="$(kit_copy_file "$AUTO_DIR/kit-guard.sh" "$HOOKS_DIR/kit-guard.sh" 0755)" || exit 1
    [[ "$res" != 'unchanged' ]] && kit_ok "$res $HOOKS_DIR/kit-guard.sh"

    kit_settings_merge "$SETTINGS" "$CLAUDE_DIR" "$REGISTRATION" || {
      kit_fail 'failed - rolling back'; kit_txn_undo; exit 1; }
    if (( ${#KIT_SETTINGS_CHANGES[@]} > 0 )); then
      for c in "${KIT_SETTINGS_CHANGES[@]}"; do kit_ok "$c"; done
    else
      kit_info 'the guard was already registered'
    fi

    printf '\n'
    kit_ok 'the command guard is active'
    cat >&2 <<'EOF'

It BLOCKS, without asking, the things you cannot undo:
  rm -rf on a system or home path      dd/mkfs/fdisk against a device
  chmod/chown -R on system paths       shutdown / reboot
  stopping ssh, networking, firewall   iptables -F / ufw disable
  curl|wget piped into a shell         push or force-push to main/master
  publish and deploy commands          docker push / system prune

Everything else runs at full speed. It fails CLOSED: if it cannot parse an
event it blocks rather than waving the command through.

Tune the rules to your stack in autonomous/kit-guard.sh, then re-run this and
./tests/run-all.sh guard. Restart Claude Code to load the hook.
EOF
    ;;

  uninstall)
    kit_txn_start
    kit_settings_uninstall "$SETTINGS" "$REGISTRATION" || true
    if (( ${#KIT_SETTINGS_CHANGES[@]} > 0 )); then
      for c in "${KIT_SETTINGS_CHANGES[@]}"; do kit_ok "$c"; done
    else
      kit_info 'the guard was not registered'
    fi
    if [[ -f "$HOOKS_DIR/kit-guard.sh" ]]; then
      if kit_is_dry_run; then kit_info "would remove $HOOKS_DIR/kit-guard.sh"
      else rm -f -- "$HOOKS_DIR/kit-guard.sh"; kit_ok "removed $HOOKS_DIR/kit-guard.sh"; fi
    fi
    kit_ok 'the command guard is gone - restart Claude Code'
    ;;
esac
exit 0
