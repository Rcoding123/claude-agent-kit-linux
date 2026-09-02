#!/usr/bin/env bash
# kit-guard.sh - PreToolUse hook. The ONE safety layer that stays on when
# permission prompts are off.
#
# Under bypassPermissions there is no human to approve anything. So instead of
# ASKING before an irreversible action, this BLOCKS it and tells the agent to do
# the reversible equivalent. It exits 2, which Claude Code treats as "denied,
# here is why" - even in bypass mode - and feeds the message back to the agent
# so it self-corrects.
#
# This is a DENYLIST of irreversible actions, not an allowlist. Reversible work
# runs at full speed; only the things you cannot undo are stopped.
#
# ---------------------------------------------------------------------------
# WHAT THIS BLOCKS, AND WHY THOSE THINGS
# ---------------------------------------------------------------------------
# The rules are chosen from what is irreversible on a Linux box, which is mostly
# about the MACHINE rather than about a remote:
#
#   rm -rf on a root-ish path       - no recycle bin; this is final
#   dd / mkfs / fdisk to a device   - destroys a filesystem in one command
#   chmod/chown -R on system paths  - unbootable, and tedious to reverse
#   iptables -F, ufw disable        - on a remote box, locks you out of it
#   systemctl stop/disable on ssh   - same, and worse
#   shutdown / reboot               - an unattended box does not come back
#   curl | sh                       - executes code nobody reviewed
#   push / force-push to main       - bypasses review; rewrites shared history
#   publish / deploy commands       - a published version cannot be recalled
#
# These are generic. A denylist is only as good as its fit to the machine it
# runs on, so treat this as a starting point and add whatever is irreversible in
# YOUR stack - a deploy script, a migration, anything that touches production
# data. docs/AUTONOMOUS.md says where.
#
# ---------------------------------------------------------------------------
# MATCHING IS ARGUMENT-POSITIONAL, NOT SUBSTRING
# ---------------------------------------------------------------------------
# Regex-matching the raw command string means any command that merely MENTIONS a
# blocked word is refused - `git commit -m "clean up the deploy script"` gets
# blocked as a deployment. That is not a hypothetical annoyance: it punishes an
# agent for writing an honest commit message, and the refusal points at
# something it never did.
#
# So the command is split into segments (on && || ; | newline and command
# substitution), each segment is tokenized quote-aware, and rules match on the
# PROGRAM and its ARGUMENT positions. Two consequences:
#   - text inside quotes is never matched against the denylists
#   - `git status && rm -rf /` still blocks, because each segment is checked
#     independently
#
# Command substitution starts a fresh UNQUOTED segment even inside double
# quotes, because bash really does execute it - `echo "$(rm -rf /)"` must not
# launder a blocked command through a quoted string.
#
# ---------------------------------------------------------------------------
# IT FAILS CLOSED
# ---------------------------------------------------------------------------
# If this script cannot parse the event, cannot find jq, or hits an unexpected
# error, it BLOCKS. A broken fence that fails open is indistinguishable from a
# permissive one, and the first thing you learn about it is the `rm -rf` that
# went through. Blocking is annoying and visible; an absent fence is invisible
# and irreversible.

set -uo pipefail

deny() {  # deny <reason>
  printf '%s\n' "$1" >&2
  exit 2
}

# Any unhandled error blocks rather than passing the command through.
trap 'deny "BLOCKED: the command guard failed while inspecting this command, so it could not
confirm the command is safe. This is a guard bug, not a judgement about your
command. Run autonomous/test-guard.sh to see what broke. To proceed without the
fence you must disable it deliberately (see docs/AUTONOMOUS.md) - it will not
quietly let things past."' ERR

command -v jq >/dev/null 2>&1 || deny \
"BLOCKED: the command guard needs jq to read the tool event and jq is not
installed, so it cannot tell what this command is. Install jq, or remove the
guard deliberately - it will not fail open."

raw="$(timeout 10 cat 2>/dev/null || true)"
# Whitespace-only is "no event", not unparseable input. A pipe delivering a bare
# newline is not a shape change, and treating it as one would block everything.
[[ -z "${raw//[[:space:]]/}" ]] && exit 0

if ! printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
  deny "BLOCKED: the command guard could not parse the tool event it was given, so it
cannot tell what this command is. This usually means the hook event format
changed. Update autonomous/kit-guard.sh rather than removing it."
fi

tool="$(printf '%s' "$raw" | jq -r '.tool_name // ""')"
# PreToolUse always carries tool_name. Its absence means the event shape moved,
# which would otherwise make every command look "not a Bash call" and sail past.
[[ -z "$tool" ]] && deny \
"BLOCKED: the tool event carried no 'tool_name', so the command guard cannot
identify this call. The hook event shape has probably changed; update
autonomous/kit-guard.sh."

# Only Bash tool calls are policed.
[[ "$tool" != 'Bash' ]] && exit 0

cmd="$(printf '%s' "$raw" | jq -r '.tool_input.command // ""')"
[[ -z "$cmd" ]] && exit 0

# ==============================================================================
# TOKENIZER
# ==============================================================================
# Emits one line per segment; tokens within a segment are separated by 0x1F.
# A token that came from inside quotes is prefixed with 'Q', otherwise 'U'.
# Quoted content is prose as far as the denylists are concerned.
tokenize() {  # tokenize <command text>
  local text="$1"
  local -a segs=() cur=()
  local tok='' tok_quoted=0 has_tok=0
  local q=''
  local -a qstack=()
  local i ch nx

  flush_tok() {
    if (( has_tok )); then
      if (( tok_quoted )); then cur+=("Q$tok"); else cur+=("U$tok"); fi
      tok=''; tok_quoted=0; has_tok=0
    fi
  }
  flush_seg() {
    flush_tok
    if (( ${#cur[@]} > 0 )); then
      local IFS=$'\x1f'; segs+=("${cur[*]}"); cur=()
    fi
  }

  for (( i = 0; i < ${#text}; i++ )); do
    ch="${text:i:1}"
    nx="${text:i+1:1}"

    if [[ -n "$q" ]]; then
      # Inside double quotes bash honours \ before $ ` " and \ only. An escaped
      # \$( is literal text, NOT a substitution - without this, a commit message
      # quoting an example command trips the denylists.
      if [[ "$q" == '"' && "$ch" == '\' ]] \
         && [[ "$nx" == '$' || "$nx" == '`' || "$nx" == '"' || "$nx" == '\' ]]; then
        tok+="$nx"; tok_quoted=1; has_tok=1; ((i++)); continue
      fi
      if [[ "$ch" == "$q" ]]; then q=''; continue; fi
      # Substitution RUNS inside double quotes (not single). Start a fresh
      # UNQUOTED segment and remember the quote to restore at the close -
      # otherwise everything after $( stays in "quoted prose" mode and the
      # substituted command is never inspected. That is a laundering route
      # straight through the fence.
      if [[ "$q" == '"' && "$ch" == '$' && "$nx" == '(' ]]; then
        flush_seg; qstack+=("$q"); q=''; ((i++)); continue
      fi
      if [[ "$q" == '"' && "$ch" == '`' ]]; then
        flush_seg; qstack+=("$q"); q=''; continue
      fi
      tok+="$ch"; tok_quoted=1; has_tok=1
      continue
    fi

    case "$ch" in
      "'"|'"') q="$ch"; has_tok=1; continue ;;
      '$')
        if [[ "$nx" == '(' ]]; then flush_seg; qstack+=(''); ((i++)); continue; fi
        ;;
      ')'|'`')
        flush_seg
        if (( ${#qstack[@]} > 0 )); then
          q="${qstack[-1]}"; unset 'qstack[-1]'
        fi
        continue ;;
      '(') flush_seg; continue ;;
      '&'|'|')
        flush_seg
        [[ "$nx" == "$ch" ]] && ((i++))
        continue ;;
      ';'|$'\n'|$'\r') flush_seg; continue ;;
      '\')
        if [[ -n "$nx" ]]; then tok+="$nx"; has_tok=1; ((i++)); continue; fi
        ;;
      ' '|$'\t') flush_tok; continue ;;
    esac

    tok+="$ch"; has_tok=1
  done
  flush_seg

  (( ${#segs[@]} > 0 )) && printf '%s\n' "${segs[@]}"
  return 0
}

# ==============================================================================
# RULES
# ==============================================================================
# Flags whose VALUE is free text (or a path to free text), never a command.
#
# CASE MATTERS. `-F` is git's message-file flag; `-f` is force. `-d` is gh's
# --description; `-D` is git's force-delete-branch. Conflating them means a
# force flag gets swallowed as "text" and never reaches a rule - the guard then
# fails open on exactly the command it exists to stop.
#
# These are also SCOPED BY PROGRAM. `-F` is git's message-file flag, but for
# iptables it means --flush, and treating it as "a flag whose value is prose"
# swallowed the token before any rule could see it - so `iptables -F` was
# allowed. A global text-flag list quietly disarms the guard for every program
# that happens to reuse one of these letters.
declare -A TEXT_FLAG_PROGS=(
  [git]=1 [gh]=1 [hg]=1 [svn]=1 [jj]=1
)
TEXT_FLAGS=(-m --message -F --file --body --body-file -b -t --title
            --description --notes --notes-file -n --subject --grep
            --author --committer -c --reedit-message -C --reuse-message)

is_text_flag() {  # is_text_flag <program> <token>
  [[ -n "${TEXT_FLAG_PROGS[$1]:-}" ]] || return 1
  local f; for f in "${TEXT_FLAGS[@]}"; do [[ "$2" == "$f" ]] && return 0; done
  return 1
}

# Does a short-flag cluster (-rf, -Rv, --recursive) request recursion?
has_recursive_flag() {  # has_recursive_flag <token>
  local a="$1"
  [[ "$a" == '--recursive' ]] && return 0
  # A long flag that is not --recursive never means recursion.
  [[ "$a" == --* ]] && return 1
  # A short cluster: -R, -rf, -fR ... Anything containing r or R.
  [[ "$a" == -* && "$a" == *[rR]* ]] && return 0
  return 1
}

# Paths that must never be the target of a recursive delete or a recursive
# ownership change. Anchored, so /home/me/tmp-root is not confused with /.
PROTECTED_PATHS=(
  / /bin /boot /dev /etc /lib /lib32 /lib64 /opt /proc /root /run /sbin
  /srv /sys /usr /var /home
)

is_protected_path() {  # is_protected_path <path>
  local p="$1"
  # Strip a trailing slash, but keep bare "/" as "/".
  [[ "$p" != '/' ]] && p="${p%/}"
  # ~ and $HOME expand to the user's whole home directory.
  [[ "$p" == '~' || "$p" == '$HOME' || "$p" == "$HOME" ]] && return 0
  [[ "$p" == '/' || "$p" == '/*' ]] && return 0

  # Only ABSOLUTE paths can be system paths. A relative path is by definition
  # inside the project the agent is working in.
  [[ "$p" != /* ]] && return 1

  # Anything AT or UNDER a protected root. Matching only exact roots was the
  # original bug: `rm -rf /etc` was blocked but `rm -rf /usr/lib` sailed through,
  # which is just as unbootable and rather more likely to be typed by accident.
  local q
  for q in "${PROTECTED_PATHS[@]}"; do
    [[ "$q" == '/' ]] && continue
    [[ "$p" == "$q" || "$p" == "$q/"* ]] && return 0
  done

  # A home directory that is not this user's - /home/someone-else.
  [[ "$p" == /home/* ]] && return 0
  return 1
}

# Services whose loss locks you out of a remote box.
CRITICAL_UNITS=(ssh sshd systemd-networkd NetworkManager networking network
                firewalld tailscaled wg-quick docker)

DEPLOY_PROGS=(terraform kubectl helm serverless vercel netlify flyctl heroku)

# ==============================================================================
# INSPECTION
# ==============================================================================
check_segment() {  # check_segment <token...>
  local -a t=("$@")
  (( ${#t[@]} == 0 )) && return 0

  # Split each token into its quoted flag and its text.
  local -a kind=() word=()
  local x
  for x in "${t[@]}"; do
    kind+=("${x:0:1}"); word+=("${x:1}")
  done

  # Skip leading env assignments and sudo/env wrappers so `sudo rm -rf /` is
  # inspected as `rm -rf /` rather than as a call to sudo.
  #
  # A flag is only skipped while we are still INSIDE a wrapper. The first
  # version skipped any leading `-*` unconditionally, so for `chmod -R 777 /`
  # it walked past chmod, past -R, past 777, and decided the program was `/`.
  # Every rule then missed and the guard failed open on exactly the commands it
  # exists to stop - and it did so silently, because "no rule matched" and "safe"
  # look identical from outside.
  # A flag is skipped ONLY while it directly follows a wrapper. Otherwise it
  # belongs to the program and must be left where it is.
  local start=0 after_wrapper=1
  while (( start < ${#word[@]} )); do
    case "${word[$start]}" in
      sudo|doas|env|nohup|time|nice|ionice)
        after_wrapper=1; ((start++)) ;;
      *=*)
        # An environment assignment; the next word could still be a wrapper.
        ((start++)) ;;
      -*)
        (( after_wrapper )) || break
        ((start++)) ;;
      *)
        # This is the program itself. Stop here.
        break ;;
    esac
  done
  (( start >= ${#word[@]} )) && return 0

  # The program name must not have come from inside quotes.
  [[ "${kind[$start]}" != 'U' ]] && return 0
  local prog; prog="$(basename -- "${word[$start]}")"

  # Collect the unquoted arguments after the program, skipping the values of
  # free-text flags. Quoted arguments are prose and are never matched.
  local -a args=()
  local i=$((start + 1)) skip_next=0
  while (( i < ${#word[@]} )); do
    if (( skip_next )); then skip_next=0; ((i++)); continue; fi
    if [[ "${kind[$i]}" == 'U' ]] && is_text_flag "$prog" "${word[$i]}"; then
      skip_next=1; ((i++)); continue
    fi
    [[ "${kind[$i]}" == 'U' ]] && args+=("${word[$i]}")
    ((i++))
  done

  local a
  case "$prog" in
    rm)
      # Recursive + force against a protected path. `rm -rf ./build` is fine and
      # extremely common; `rm -rf /` or `rm -rf ~` is not.
      local recursive=0
      for a in "${args[@]}"; do
        has_recursive_flag "$a" && recursive=1
      done
      if (( recursive )); then
        for a in "${args[@]}"; do
          [[ "$a" == -* ]] && continue
          if is_protected_path "$a"; then
            deny "BLOCKED: 'rm -r' targeting $a would destroy a system or home directory, and
there is no undo on Linux.

Delete a specific path inside your project instead. If you genuinely need to
remove something under a system path, that is a decision for a human at a
terminal, not for an unattended agent."
          fi
        done
      fi
      ;;

    dd)
      for a in "${args[@]}"; do
        if [[ "$a" == of=/dev/* ]]; then
          deny "BLOCKED: 'dd $a' writes directly to a block device and destroys whatever
filesystem is on it. There is no undo.

If you are building an image, write to a file. Writing to a real device is a
human decision."
        fi
      done
      ;;

    mkfs|mkfs.ext4|mkfs.ext3|mkfs.xfs|mkfs.btrfs|mkfs.vfat|mkswap|fdisk|parted|sgdisk|wipefs)
      deny "BLOCKED: '$prog' formats or repartitions a disk. That destroys every filesystem
it touches and cannot be undone.

This is never part of a code change. If it is genuinely needed, a human should
do it at a terminal."
      ;;

    chmod|chown|chgrp)
      local recursive=0
      for a in "${args[@]}"; do
        has_recursive_flag "$a" && recursive=1
      done
      if (( recursive )); then
        for a in "${args[@]}"; do
          [[ "$a" == -* ]] && continue
          if is_protected_path "$a"; then
            deny "BLOCKED: '$prog -R' on $a rewrites permissions or ownership across a system
directory. That routinely makes a machine unbootable and is tedious to reverse
even when you know exactly what changed.

Scope the change to your project directory."
          fi
        done
      fi
      ;;

    shutdown|reboot|poweroff|halt|init)
      # `init` is only dangerous with a runlevel argument.
      if [[ "$prog" == 'init' ]]; then
        local rl=0
        for a in "${args[@]}"; do [[ "$a" =~ ^[0-6]$ ]] && rl=1; done
        (( rl )) || return 0
      fi
      deny "BLOCKED: '$prog' would take this machine down. On an unattended box nothing
brings it back up, so this ends the session and any work still in flight.

If a restart is genuinely required, leave that for a human."
      ;;

    systemctl|service)
      local verb='' unit=''
      for a in "${args[@]}"; do
        [[ "$a" == -* ]] && continue
        if [[ -z "$verb" ]]; then verb="$a"; else [[ -z "$unit" ]] && unit="$a"; fi
      done
      # `service <name> <verb>` has the operands the other way round.
      if [[ "$prog" == 'service' ]]; then local swap="$verb"; verb="$unit"; unit="$swap"; fi
      case "$verb" in
        stop|disable|mask|kill)
          local base="${unit%.service}"; base="${base%.socket}"
          local u
          for u in "${CRITICAL_UNITS[@]}"; do
            if [[ "$base" == "$u" ]]; then
              deny "BLOCKED: '$prog $verb $unit' would stop a service this box depends on to stay
reachable. On a remote machine that locks you out with no way back in.

Restart your own application's unit if you need to; leave networking, SSH and
the firewall alone."
            fi
          done
          ;;
      esac
      ;;

    iptables|ip6tables|nft|ufw)
      for a in "${args[@]}"; do
        case "$a" in
          -F|--flush|-X|reset)
            deny "BLOCKED: '$prog $a' clears the firewall ruleset. On a remote box that
frequently drops the connection you are working over, and the rules are not
recoverable from memory afterwards.

Add or remove a single specific rule instead."
            ;;
          disable)
            [[ "$prog" == 'ufw' ]] && deny \
"BLOCKED: 'ufw disable' turns the firewall off entirely. That is an exposure
change on a live machine, and not something to do unattended."
            ;;
        esac
      done
      ;;

    git)
      local sub=''
      for a in "${args[@]}"; do [[ "$a" == -* ]] && continue; sub="$a"; break; done
      if [[ "$sub" == 'push' ]]; then
        local forced=0 target=''
        local seen_sub=0
        for a in "${args[@]}"; do
          if (( ! seen_sub )); then [[ "$a" == "$sub" ]] && seen_sub=1; continue; fi
          case "$a" in
            -f|--force|--force-with-lease|--force-if-includes) forced=1 ;;
            --delete|-d|-D) forced=1 ;;
            -*) ;;
            *) target="$a" ;;
          esac
        done
        # The refspec is the last bare operand; a branch name may be "main" or
        # "HEAD:main".
        local branch="${target##*:}"
        if [[ "$branch" == 'main' || "$branch" == 'master' ]]; then
          if (( forced )); then
            deny "BLOCKED: force-pushing to $branch rewrites shared history. Commits that exist
only on the remote are gone, and anyone who has pulled is now inconsistent.

Push to your agent/* branch and open a PR instead."
          fi
          deny "BLOCKED: pushing directly to $branch bypasses review on the branch everything
else builds on.

Push to your agent/* branch and open a PR instead - that is reversible and it is
what an unattended run is expected to produce."
        fi
      fi
      ;;

    curl|wget)
      # `curl ... | sh` executes code nobody reviewed. The pipe already split
      # the segments, so this looks at whether THIS segment is a fetch whose
      # output is being piped into a shell - detected by the NEXT segment.
      : # handled by the pipeline check below
      ;;

    terraform|kubectl|helm|serverless|vercel|netlify|flyctl|heroku)
      local sub=''
      for a in "${args[@]}"; do [[ "$a" == -* ]] && continue; sub="$a"; break; done
      case "$prog:$sub" in
        terraform:apply|terraform:destroy|kubectl:apply|kubectl:delete|helm:install|helm:upgrade|helm:uninstall)
          deny "BLOCKED: '$prog $sub' changes real infrastructure, and an unattended agent has
no way to judge blast radius.

Produce the plan or the manifest and leave the apply for a human."
          ;;
        serverless:deploy|vercel:deploy|netlify:deploy|flyctl:deploy|heroku:*)
          deny "BLOCKED: '$prog $sub' deploys to a live environment. Stop here and leave the
deploy for a human."
          ;;
      esac
      ;;

    docker|podman)
      local sub=''
      for a in "${args[@]}"; do [[ "$a" == -* ]] && continue; sub="$a"; break; done
      if [[ "$sub" == 'push' ]]; then
        deny "BLOCKED: '$prog push' publishes an image others will pull. Build and test
locally; leave publishing for a human."
      fi
      if [[ "$sub" == 'system' ]]; then
        for a in "${args[@]}"; do
          [[ "$a" == 'prune' ]] && deny \
"BLOCKED: '$prog system prune' deletes images, containers and volumes across the
whole machine, including things this session did not create. Remove the specific
container or image you meant instead."
        done
      fi
      ;;

    npm|pnpm|yarn)
      local sub=''
      for a in "${args[@]}"; do [[ "$a" == -* ]] && continue; sub="$a"; break; done
      [[ "$sub" == 'publish' ]] && deny \
"BLOCKED: '$prog publish' pushes a package to a registry. Published versions
cannot be recalled, only deprecated. Leave publishing for a human."
      ;;

    cargo)
      local sub=''
      for a in "${args[@]}"; do [[ "$a" == -* ]] && continue; sub="$a"; break; done
      [[ "$sub" == 'publish' ]] && deny \
"BLOCKED: 'cargo publish' pushes a crate to crates.io permanently - a published
version can never be removed. Leave publishing for a human."
      ;;
  esac
  return 0
}

# ==============================================================================
# MAIN
# ==============================================================================
mapfile -t SEGMENTS < <(tokenize "$cmd")

# `curl|wget ... | sh|bash` executes unreviewed code. Detected across segments:
# a fetch in one, a shell in the next.
prev_was_fetch=0
for seg in "${SEGMENTS[@]:-}"; do
  [[ -z "$seg" ]] && continue
  IFS=$'\x1f' read -r -a toks <<< "$seg"

  if (( prev_was_fetch )); then
    first=''
    for tk in "${toks[@]}"; do
      [[ "${tk:0:1}" == 'U' ]] || continue
      w="$(basename -- "${tk:1}")"
      case "$w" in sudo|doas|env) continue ;; esac
      first="$w"; break
    done
    case "$first" in
      sh|bash|zsh|dash|python|python3|perl|ruby|node)
        deny "BLOCKED: piping a download straight into $first executes code that nobody has
read, with this session's privileges. A compromised or changed URL becomes
arbitrary code execution with no review step.

Download to a file, look at it, then run it."
        ;;
    esac
  fi

  prev_was_fetch=0
  for tk in "${toks[@]}"; do
    [[ "${tk:0:1}" == 'U' ]] || continue
    w="$(basename -- "${tk:1}")"
    case "$w" in
      sudo|doas|env|nohup|time) continue ;;
      curl|wget) prev_was_fetch=1 ;;
    esac
    break
  done

  check_segment "${toks[@]}"
done

exit 0
