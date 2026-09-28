#!/usr/bin/env bash
# Register a disposable resource this session created, so the close can remove it.
#
# A session that spawns a child agent pane, a tab for a batch of children, a
# workspace or a worktree owns that resource. Nothing else on the machine records
# who created it, so without this registry the close cannot tell your worktree
# from a worktree someone opened by hand, and the safe answer would be to leave every
# one of them behind. Register at creation, not at close: the close reads only
# what is here.
#
# Child panes stamped with HERDR_PARENT_PANE do not need registering; the close
# finds those from the Herdr sidebar tokens. Register the tab you created for a
# batch, and every worktree.
#
# A slot is a reserved set of ports held by one lane, such as the Relay stack
# slot that fixes webapp, org agent and product-backend ports. The machine has no
# record of which lane reserved which slot, so an unregistered slot is invisible
# at close and its ports stay held by a process nobody can attribute. The close
# does not stop services, because only the tool that started them knows how; it
# reports a still-registered slot as carry-over so the lead releases it.
#
# Data Sources:
#   - Local filesystem only: the workspace sessions/.active directory
#
# Default Environment: local
# Environments Supported: local
#
# Usage: session-artifact.sh add <worktree|tab|pane|workspace|slot> <value>
#        session-artifact.sh drop <value>
#        session-artifact.sh list
#
# AGENT GUIDE
#   WORKFLOW
#     1. Register at creation, never at close. What is not registered is never
#        cleaned up, because the close reads only this registry.
#     2. One call per resource, immediately after you create it.
#     3. `drop <value>` only when you removed the resource yourself.
#   ERROR RECOVERY
#     - "invalid kind": the kind is one of worktree, tab, pane, workspace, slot.
#       An unrecognized kind is refused rather than recorded wrongly.
#     - "worktree path does not exist" or "not a git worktree": register the
#       worktree after `git worktree add` succeeds, not before.
#     - "not a Herdr id": a pane or tab value is the Herdr id, not its label.
#     - A resource created before you registered it is still yours. Register it
#       late rather than not at all.
#     - A child pane stamped with HERDR_PARENT_PANE needs no registration; the
#       close finds it from the Herdr sidebar tokens.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=session-lib.sh
. "$SCRIPT_DIR/session-lib.sh"

readonly KINDS="worktree tab pane workspace slot"

# Print the Usage block from the header. Matched by content, not by line number,
# so editing the header above cannot silently break the help text.
# An explicit --help is a request that succeeded, so it exits 0; a missing or
# wrong argument is a usage error and exits 2. Callers distinguish the two.
usage() { sed -n '/^# Usage:/,/^[^#]/{/^[^#]/!p;}' "$0" >&2; exit "${1:-2}"; }

valid_kind() {
  local k want="$1"
  for k in $KINDS; do [ "$k" = "$want" ] && return 0; done
  return 1
}

# A slot number identifies a reserved port set. Keep it a bare positive integer
# with no leading zero, so the value can never carry a path, a flag or a command
# into whatever later reads the registry.
valid_slot() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    0*) return 1 ;;
    *) [ "${#1}" -le 2 ] ;;
  esac
}

# Herdr public IDs are opaque handles of the form w1, w1:t2, w1:p3. Anything else
# is a typo or an injection attempt, and both must fail before touching the file.
valid_herdr_id() {
  # LC_ALL=C: a-z means the 26 ASCII letters, not whatever the locale
  # collates between them. See valid_lane in session-lane.sh.
  local LC_ALL=C
  case "$1" in
    *[!A-Za-z0-9:]*) return 1 ;;
    w*:t*|w*:p*|w*) return 0 ;;
    *) return 1 ;;
  esac
}

[ "$#" -ge 1 ] || usage
cmd="$1"; shift

case "$cmd" in
  add)
    [ "$#" -eq 2 ] || usage
    kind="$1"; value="$2"
    valid_kind "$kind" || die "invalid kind '$kind' (want one of: $KINDS)"
    [ -n "$value" ] || die "value must not be empty"
    # The registry is pipe-delimited and line-oriented, so a value carrying either
    # would corrupt the file the close reads.
    case "$value" in *'|'*) die "value must not contain a pipe" ;; esac
    [ "$value" = "${value%%$'\n'*}" ] || die "value must not contain a newline"
    if [ "$kind" = worktree ]; then
      [ -d "$value" ] || die "worktree path does not exist: $value"
      # Resolve symlinks now. A path recorded as /tmp/x and reported by git as
      # /private/tmp/x would never match at close, and the worktree would leak.
      value=$(cd "$value" && pwd -P)
      git -C "$value" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || die "not a git worktree: $value"
    elif [ "$kind" = slot ]; then
      valid_slot "$value" \
        || die "slot must be 1-99 with no leading zero, got: $value"
    else
      valid_herdr_id "$value" || die "not a Herdr id: $value"
    fi
    af=$(artifact_file)
    mkdir -p "$(dirname "$af")"
    if [ -f "$af" ] && awk -F'|' -v k="$kind" -v v="$value" \
        '$1 == k && $2 == v { found = 1 } END { exit !found }' "$af"; then
      printf 'already registered: %s %s\n' "$kind" "$value"
      exit 0
    fi
    printf '%s|%s|%s\n' "$kind" "$value" "$(date '+%Y-%m-%dT%H:%M:%S%z')" >> "$af"
    printf 'registered: %s %s\n' "$kind" "$value"
    ;;
  drop)
    [ "$#" -eq 1 ] || usage
    value="$1"
    af=$(artifact_file)
    [ -f "$af" ] || exit 0
    tmp="$af.tmp.$$"
    trap 'rm -f "$tmp"' EXIT
    awk -F'|' -v v="$value" '$2 != v' "$af" > "$tmp"
    mv "$tmp" "$af"
    printf 'dropped: %s\n' "$value"
    ;;
  list)
    af=$(artifact_file)
    [ -f "$af" ] || exit 0
    cat "$af"
    ;;
  -h|--help) usage 0 ;;
  *) die "unknown command '$cmd'" ;;
esac
