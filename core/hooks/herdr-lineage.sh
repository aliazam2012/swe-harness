#!/bin/sh
# Tags this Herdr pane as a lead or a child agent, for the agent sidebar.
#
# Herdr has no built-in agent lineage. This supplies it:
#   - a pane spawned with `--env HERDR_PARENT_PANE=$HERDR_PANE_ID` is a child
#   - any other pane is a lead, the one the user talks to
#
# The role reads as an arrow plus the parent's pane suffix, so a child in a
# different tab still names its parent. A bare arrow does not: the own-tab
# rule keeps a child out of its parent's tab, and priority sort keeps the two
# rows apart, so nothing on screen resolves an unanchored arrow.
#
# The role token renders as $role in ui.sidebar.agents.rows_by_agent.claude.
# Kept beside herdr-agent-state.sh. Herdr is optional: without HERDR_ENV and
# an executable herdr binary this exits 0 and does nothing.

set -eu

# Claude sends hook JSON on stdin. Drain it so the writer never blocks.
cat >/dev/null 2>&1 || true

[ "${HERDR_ENV:-}" = "1" ] || exit 0
[ -n "${HERDR_PANE_ID:-}" ] || exit 0
[ -n "${HERDR_BIN_PATH:-}" ] || exit 0
[ -x "$HERDR_BIN_PATH" ] || exit 0

if [ -n "${HERDR_PARENT_PANE:-}" ]; then
  "$HERDR_BIN_PATH" pane report-metadata "$HERDR_PANE_ID" \
    --source custom:lineage \
    --token "role=↳${HERDR_PARENT_PANE##*:}" \
    --token "parent=$HERDR_PARENT_PANE" >/dev/null 2>&1 || true
else
  "$HERDR_BIN_PATH" pane report-metadata "$HERDR_PANE_ID" \
    --source custom:lineage \
    --clear-token role \
    --clear-token parent >/dev/null 2>&1 || true
fi

exit 0
