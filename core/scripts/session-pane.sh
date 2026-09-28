#!/usr/bin/env bash
# Run something long-lived in a pane the operator can see, not in the background.
#
# A child that starts a server, a tail or a watcher inside its own pane makes the
# work invisible: the output scrolls past its agent transcript or vanishes into a
# background job. A workstream worth watching belongs somewhere visible: a server
# nobody can watch is a server nobody can debug.
#
# This is one command because the alternative is four, and a child gets four
# wrong. It splits a pane in the child's own tab, labels it so the sidebar says
# what it is, stamps it with the lead so lineage reads correctly, registers it to
# the LEAD's artifact file so the lead's close owns it, and runs the command.
#
# Registering to the lead rather than to the caller is deliberate. The registry is
# per pane, the close reads the lead's copy, and a pane registered to a child that
# has since exited is a pane nobody removes. It is the same ownership mistake the
# emergency stop had, avoided here rather than repeated.
#
# Data Sources:
#   - Local only: the Herdr CLI over its socket, and the workspace sessions/.active registry
#
# Default Environment: local
# Environments Supported: local
#
# Usage: session-pane.sh <label> -- <command...>
#        session-pane.sh --list
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=session-lib.sh
. "$SCRIPT_DIR/session-lib.sh"

usage() { sed -n '/^# Usage:/,/^[^#]/{/^[^#]/!p;}' "$0" >&2; exit 2; }

# A label names the pane in the sidebar, so keep it to something a person reads.
valid_label() {
  # LC_ALL=C: a-z means the 26 ASCII letters, not whatever the locale
  # collates between them. See valid_lane in session-lane.sh.
  local LC_ALL=C
  case "$1" in
    ''|*[!a-z0-9_-]*) return 1 ;;
    *) [ "${#1}" -le 24 ] ;;
  esac
}

[ "${HERDR_ENV:-}" = 1 ] || die "not running inside Herdr, so there is no pane to open"
require_cmd herdr

if [ "${1:-}" = "--list" ]; then
  herdr pane list --workspace "$HERDR_WORKSPACE_ID"
  exit 0
fi

label="${1:-}"; shift 2>/dev/null || usage
[ -n "$label" ] || usage
valid_label "$label" || die "label must be lowercase letters, digits, hyphen or underscore, max 24: $label"
[ "${1:-}" = "--" ] || usage
shift
[ "$#" -ge 1 ] || usage
command_text="$*"

# The lead is this pane's parent when we are a child, and ourselves when we are
# the lead. Either way it is the pane whose close should own what we open.
lead="${HERDR_PARENT_PANE:-$HERDR_PANE_ID}"

# Split down: a server pane is read, not typed into, so it wants width more than
# height, and the caller's own pane keeps the wider half.
pane=$(herdr pane split --current --direction down --cwd "$PWD" --no-focus \
         --env HERDR_PARENT_PANE="$lead" 2>/dev/null \
       | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])' 2>/dev/null) \
  || die "could not split a pane"
[ -n "$pane" ] || die "could not read the new pane id"

# Register to the lead, not to us. See the header.
HERDR_PANE_ID="$lead" "$SCRIPT_DIR/session-artifact.sh" add pane "$pane" >/dev/null 2>&1 || true

herdr pane run "$pane" "printf '\\033]0;%s\\007' $label; $command_text" >/dev/null 2>&1 \
  || die "pane $pane opened but the command did not start"

# The sidebar renders terminal_title_stripped, not the pane label, so renaming
# the pane changes a field he never sees. Set the terminal title instead, which
# is what the sidebar actually shows, and set the label too so both agree.
#
# The title is set from inside the pane, before the command, so it survives the
# shell echoing the command afterwards. That ordering is the whole trick: a rename
# sent from outside loses the race with `pane run` every time.
herdr pane rename "$pane" "$label" >/dev/null 2>&1 || true

printf 'running in pane %s, labelled %s\n' "$pane" "$label"
printf '  %s\n\n' "$command_text"
printf 'Read it with : herdr pane read %s --source recent-unwrapped --lines 60\n' "$pane"
printf 'Close it with: herdr pane close %s\n' "$pane"
