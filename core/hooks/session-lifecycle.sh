#!/usr/bin/env bash
# Claude Code hook bridge for the harness session lifecycle.
#
# One script, three events. The mode comes from the hook payload's
# hook_event_name, because the installer resolves a registry entry into
# "<interpreter> <script>" and passes no arguments. An explicit first argument
# still wins, so the script stays callable by hand:
#
#   SessionStart -> start       create the journal
#   PreCompact   -> precompact  checkpoint before the context is dropped
#   SessionEnd   -> end         auto-wrap a session nobody closed
#
# The session scripts are optional. A clone without them is a working harness,
# so a missing directory is silence. Always exits 0: a hook must never block or
# fail a session.
set -uo pipefail

# Resolve this file through any symlink, then the clone root above core/hooks.
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do
  link="$(readlink "$SELF")"
  case "$link" in
    /*) SELF="$link" ;;
    *)  SELF="$(dirname "$SELF")/$link" ;;
  esac
done
HOOKS_DIR="$(cd "$(dirname "$SELF")" && pwd -P)"
readonly HOOKS_DIR
HARNESS_HOME="${HARNESS_HOME:-$(cd "$HOOKS_DIR/../.." && pwd -P)}"
readonly HARNESS_HOME
SCRIPTS="$HARNESS_HOME/core/scripts"
readonly SCRIPTS

payload="$(cat 2>/dev/null || printf '')"

# One python3 call for the three fields, tab separated. python3 is a floor
# requirement of the harness, so this needs nothing installed.
fields="$(printf '%s' "$payload" | python3 -c '
import json, sys
try:
    data = json.loads(sys.stdin.read() or "{}")
except ValueError:
    data = {}
if not isinstance(data, dict):
    data = {}
def field(name):
    value = data.get(name)
    return value if isinstance(value, str) and "\t" not in value else ""
print("\t".join([field("hook_event_name"), field("cwd"), field("transcript_path")]))
' 2>/dev/null || printf '\t\t')"

event="$(printf '%s' "$fields" | cut -f1)"
cwd="$(printf '%s' "$fields" | cut -f2)"
transcript="$(printf '%s' "$fields" | cut -f3)"

case "${1:-}" in
  start|precompact|end) MODE="$1" ;;
  *)
    case "$event" in
      SessionStart) MODE=start ;;
      PreCompact)   MODE=precompact ;;
      SessionEnd)   MODE=end ;;
      *)            MODE=end ;;
    esac
    ;;
esac
readonly MODE

[ -d "$SCRIPTS" ] || exit 0

if [ -n "$cwd" ] && [ -d "$cwd" ]; then cd "$cwd" || exit 0; fi

case "$MODE" in
  start)
    [ -x "$SCRIPTS/session-card.sh" ] &&
      "$SCRIPTS/session-card.sh" >/dev/null 2>&1 || true
    ;;
  precompact)
    [ -x "$SCRIPTS/session-note.sh" ] &&
      "$SCRIPTS/session-note.sh" -k NOTE \
        "context compacted; earlier detail survives only in the transcript" \
        >/dev/null 2>&1 || true
    ;;
  end)
    if [ -x "$SCRIPTS/session-wrap.sh" ]; then
      if [ -n "$transcript" ]; then
        "$SCRIPTS/session-wrap.sh" --auto --transcript "$transcript" >/dev/null 2>&1 || true
      else
        "$SCRIPTS/session-wrap.sh" --auto >/dev/null 2>&1 || true
      fi
    fi
    ;;
esac
exit 0
