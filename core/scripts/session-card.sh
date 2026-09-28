#!/usr/bin/env bash
# Session start card. Deliberately universal and short: where you are, who else
# is running, and how to find anything. It never inlines project content; it
# points at it. Loading detail is the agent's job, on demand, when a task needs
# it.
#
# Data Sources:
#   - Local filesystem only: the workspace, the git working tree, the Herdr CLI
#
# Default Environment: local
# Environments Supported: local
#
# Usage: session-card.sh [--anomalies]
#        --anomalies  print only things that need saying (a peer agent in this
#                     same directory, or an unregistered MCP write-guard) and
#                     nothing at all when everything is fine. Still creates the
#                     session journal and state file. Used by the SessionStart
#                     hook so a normal start injects zero tokens.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=session-lib.sh
. "$SCRIPT_DIR/session-lib.sh"

mode=full
case "${1:-}" in
  --anomalies) mode=anomalies ;;
  '') ;;
  *) printf 'usage: %s [--anomalies]\n' "$0" >&2; exit 2 ;;
esac

# Creates the journal and state file as a side effect. This must happen on every
# start, including the silent one, or SessionEnd has no session to close.
eval "$(session_state)"

# Whether any PreToolUse hook is wired at all. jq is optional, so fall back to a
# grep: an absent optional binary must not report a live guard as missing.
guard_state() {
  local settings="$HOME/.claude/settings.json"
  if [ ! -f "$settings" ]; then
    printf 'unregistered'
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    if jq -e '.hooks.PreToolUse' "$settings" >/dev/null 2>&1; then
      printf 'registered'
    else
      printf 'unregistered'
    fi
  elif grep -q '"PreToolUse"' "$settings" 2>/dev/null; then
    printf 'registered'
  else
    printf 'unregistered'
  fi
}

# Peer agents whose working directory is this one. A peer elsewhere is not a
# problem and is not worth a token.
same_dir_peers() {
  [ "${HERDR_ENV:-}" = 1 ] || return 0
  command -v herdr >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  herdr agent list 2>/dev/null \
    | jq -r --arg me "${HERDR_PANE_ID:-}" --arg cwd "$PWD" '
        .result.agents[]? | select(.pane_id != $me) | select((.cwd // "") == $cwd)
        | "\(.pane_id)/\(.agent_status // .state // "unknown")"' 2>/dev/null \
    | paste -sd ' ' - || true
}

if [ "$mode" = anomalies ]; then
  peers=$(same_dir_peers)
  guard=$(guard_state)
  [ -n "$peers" ] && printf 'Another agent is working in this same directory: %s. Coordinate before writing shared files.\n' "$peers"
  [ "$guard" != registered ] && printf 'No PreToolUse hook is registered. Treat every guarded action as unguarded, and say so before taking one.\n'
  exit 0
fi

printf 'session   %s\n' "$SESSION_ID"

git_bit=''
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git_bit=$(printf ' (%s, %s dirty)' \
    "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || printf '?')" \
    "$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')")
fi
printf 'cwd       %s%s\n' "$PWD" "$git_bit"
printf 'ledger    %s\n' "${SESSION_PROJECT:-none for this cwd; notes stay in the journal}"
HARNESS_HOME="$(harness_home)"

if [ "${HERDR_ENV:-}" = 1 ] && command -v herdr >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  peers=$(herdr agent list 2>/dev/null \
    | jq -r --arg me "${HERDR_PANE_ID:-}" '
        .result.agents[]? | select(.pane_id != $me)
        | "\(.pane_id)/\(.agent_status // .state // "unknown")"' \
    2>/dev/null | paste -sd ' ' - || printf '')
  printf 'peers     %s\n' "${peers:-none}"
fi

printf 'guard     PreToolUse hooks %s\n' "$(guard_state)"

cat <<GUIDE

find things (run these when you need them, not now)
  what is open on a project   cat $WORKSPACE/projects/<project>/OPEN.md
  the history of a ticket     grep -r 'T-812' $WORKSPACE/projects/*/LEDGER.md
  why something was done      grep -ri '<topic>' $WORKSPACE/projects/*/LEDGER.md
  what is stuck anywhere      grep -r 'BLOCKED' $WORKSPACE/projects/*/LEDGER.md
  the full story behind it    open the journal a ledger line cites, then its transcript
  when a file changed         git -C <repo> log -S '<string>'
  what this harness ships     ls $HARNESS_HOME/core/scripts $HARNESS_HOME/core/standards
  which projects exist        ls -d $WORKSPACE/projects/*/

record as you go (at real boundaries, not batched at the end)
  $HARNESS_HOME/core/scripts/session-note.sh -k DECISION -t T-812 "chose X because Y"
  kinds  DECISION DONE BLOCKED FRICTION NOTE
GUIDE
