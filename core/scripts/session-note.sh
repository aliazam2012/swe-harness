#!/usr/bin/env bash
# Append one fact to the session journal, and to the project ledger when the
# kind is a durable one. One fact per call, one line per fact.
#
# Data Sources:
#   - Local filesystem only: the workspace
#
# Default Environment: local
# Environments Supported: local
#
# Usage: session-note.sh [-k KIND] [-t TICKET] "one sentence"
#        KIND   DECISION | DONE | BLOCKED | FRICTION | NOTE   (default NOTE)
#        TICKET free-form id such as T-812, or omitted
#        -l     force a ledger line even for NOTE (used by the SessionEnd hook)
#
# AGENT GUIDE
#   WORKFLOW
#     1. Record at a real boundary: a commit, a decision, a blocker found, a
#        hand-off. Never batch to the end of the session.
#     2. One fact per call. A fact held in context does not survive a session
#        that dies, which is the whole reason this script exists.
#     3. DECISION, DONE, BLOCKED and FRICTION also append to that project's
#        LEDGER.md, the permanent greppable history. NOTE stays in the journal.
#   ERROR RECOVERY
#     - "invalid kind": use DECISION, DONE, BLOCKED, FRICTION or NOTE.
#     - "invalid ticket": a ticket is a free-form id such as T-812 or PROJ-123.
#       Omit -t rather than passing something that is not an id.
#     - "note text is empty": the fact is the final argument, quoted as one
#       sentence.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=session-lib.sh
. "$SCRIPT_DIR/session-lib.sh"

kind=NOTE
ticket='-'
force_ledger=no

usage() {
  # Matched by content, not by line number: a line number goes stale the
  # first time the header grows, and the help silently loses its tail.
  sed -n '/^# Append one fact/,/^[^#]/{/^[^#]/!p;}' "$0" >&2
  exit "${1:-2}"
}

case "${1:-}" in --help|-help) usage 0 ;; esac

while getopts ':k:t:lh' opt; do
  case "$opt" in
    k) kind=$(printf '%s' "$OPTARG" | tr '[:lower:]' '[:upper:]') ;;
    t) ticket="$OPTARG" ;;
    l) force_ledger=yes ;;
    h) usage 0 ;;
    :) die "option -$OPTARG requires an argument" ;;
    \?) die "unknown option -$OPTARG" ;;
  esac
done
shift $((OPTIND - 1))

[ "$#" -ge 1 ] || usage 2
text="$*"

case " $LEDGER_KINDS " in
  *" $kind "*) ;;
  *) die "invalid kind '$kind'; use one of: $LEDGER_KINDS" ;;
esac

# A trailing * in a case glob matches anything, so allowlist the first char and
# reject on the presence of any character outside the set.
#
# LC_ALL=C, scoped to this function: a character range in a glob follows the
# collating order of the current locale, and under en_US.UTF-8 bash 3.2 (what
# macOS ships at /bin/bash) sorts accented letters inside A-Z and a-z. The range
# then accepts characters this rule exists to keep out of a ledger column.
check_ticket() {
  local LC_ALL=C
  case "$1" in
    -) ;;
    '') die "ticket must not be empty" ;;
    *[!A-Za-z0-9._/-]*) die "invalid ticket '$1'" ;;
    [!A-Za-z0-9]*) die "invalid ticket '$1'" ;;
  esac
}
check_ticket "$ticket"

# Collapse to a single line and free the pipe character for the ledger columns.
text=$(printf '%s' "$text" | tr '\n\t|' '  /' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//')
[ -n "$text" ] || die "note text is empty"

eval "$(session_state)"

stamp=$(date '+%H:%M')
printf -- '- %s **%s** %s%s\n' \
  "$stamp" "$kind" "$( [ "$ticket" = '-' ] || printf '[%s] ' "$ticket" )" "$text" \
  >> "$SESSION_JOURNAL"

if { [ "$kind" != NOTE ] || [ "$force_ledger" = yes ]; } && [ -n "$SESSION_PROJECT" ]; then
  ledger=$(project_file "$SESSION_PROJECT" LEDGER.md)
  # Create-if-absent is a check-then-act race between two sessions on the same
  # project. Claim the file with an O_EXCL redirect so only one writes the header.
  if [ ! -f "$ledger" ]; then
    mkdir -p "$(dirname "$ledger")"
    if ( set -o noclobber; : > "$ledger" ) 2>/dev/null; then
    {
      printf '# Ledger: %s\n\n' "$SESSION_PROJECT"
      printf 'Append-only. One fact per line. Never rewritten, never trimmed.\n'
      printf 'Columns: date | session | kind | ticket | fact\n\n'
    } > "$ledger"
    fi
  fi
  printf '%s | %s | %-8s | %-8s | %s\n' \
    "$(date +%Y-%m-%d)" "$SESSION_ID" "$kind" "$ticket" "$text" >> "$ledger"
  printf 'ledger  %s\n' "$ledger"
fi

printf 'journal %s\n' "$SESSION_JOURNAL"
