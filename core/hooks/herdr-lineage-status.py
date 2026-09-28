#!/usr/bin/env python3
"""Mark a parent agent that has finished but still has a child running.

Herdr has five agent states and no concept of lineage, so a parent that is
done while a child works looks identical to a parent that is done and free.
This sets a display-only label on the `done` state, so such a parent reads
"waiting on 2" instead of "done". Kept short so it fits the sidebar.

Runs a full reconcile over every agent pane rather than a targeted update:
the pass is one `agent list` call plus a write per pane that actually
changed, and it repairs drift left by a pane that died without a hook.

Lineage comes from the `parent` token that herdr-lineage.sh writes.
"""

import json
import os
import subprocess
import sys

SOURCE = "custom:lineage"
# A child still counts as running while it works or waits on an approval.
# An idle child is sitting at its prompt, which is not the parent's problem.
LIVE = {"working", "blocked"}


def herdr(*args):
    binary = os.environ.get("HERDR_BIN_PATH") or "herdr"
    try:
        return subprocess.run(
            [binary, *args], capture_output=True, text=True, timeout=10
        )
    except (OSError, subprocess.SubprocessError):
        return None


def label_for(count):
    if not count:
        return None
    return f"waiting on {count}"


def main():
    # Claude sends hook JSON on stdin. Drain it so the writer never blocks.
    try:
        sys.stdin.read()
    except Exception:
        pass

    if os.environ.get("HERDR_ENV") != "1":
        return

    result = herdr("agent", "list")
    if result is None or result.returncode != 0:
        return
    try:
        agents = json.loads(result.stdout)["result"]["agents"]
    except (ValueError, KeyError):
        return

    live_children = {}
    for agent in agents:
        parent = (agent.get("tokens") or {}).get("parent")
        if parent and agent.get("agent_status") in LIVE:
            live_children[parent] = live_children.get(parent, 0) + 1

    for agent in agents:
        pane = agent.get("pane_id")
        if not pane:
            continue
        want = label_for(live_children.get(pane, 0))
        have = (agent.get("state_labels") or {}).get("done")
        if want == have:
            continue
        if want:
            herdr("pane", "report-metadata", pane, "--source", SOURCE,
                  "--state-label", f"done={want}")
        else:
            herdr("pane", "report-metadata", pane, "--source", SOURCE,
                  "--clear-state-labels")


main()
