#!/usr/bin/env python3
"""Claude Code SessionStart hook: create the session journal, say nothing.

How to work and how to find things are identical for every agent on every
start, so they live in the always-on contract file, which is already loaded.
Injecting them again would spend tokens restating what the agent can see.

This hook therefore runs the harness session card with --anomalies, which
creates this session's journal and state file (SessionEnd needs them to close a
session the agent never closed) and prints only what actually needs saying: a
peer agent in this same directory, or an unregistered write guard. A normal
start injects nothing.

The session card is optional. A clone installed without it is a working
harness, so an absent script is silence, not an error. A script that is present
and fails is reported, because that is a real fault.

Output: SessionStart additionalContext, usually empty.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))

import harness_config  # noqa: E402

CARD = harness_config.harness_home() / "core" / "scripts" / "session-card.sh"
TIMEOUT_S = 4


def anomalies() -> str:
    """Run the session card and return what it wants said, or an empty string."""
    if not CARD.is_file():
        return ""
    try:
        done = subprocess.run(
            ["bash", str(CARD), "--anomalies"],
            capture_output=True, text=True, timeout=TIMEOUT_S, check=False,
        )
    except subprocess.TimeoutExpired:
        return ("SESSION START: session-card.sh did not finish within "
                f"{TIMEOUT_S}s. The session journal may not exist.")
    except OSError as exc:
        return f"SESSION START: session-card.sh could not be started ({exc})."
    if done.returncode != 0:
        detail = (done.stderr or "").strip()[:200] or f"exit {done.returncode}"
        return f"SESSION START: session-card.sh failed ({detail})."
    out = done.stdout.strip()
    return f"SESSION START: {out}" if out else ""


def main() -> None:
    """Emit the anomaly text as additionalContext, then exit 0 whatever happened."""
    try:
        sys.stdin.read()
    except Exception:
        pass
    try:
        context = anomalies()
    except Exception:
        context = ""
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": context,
        }
    }))
    sys.exit(0)


if __name__ == "__main__":
    main()
