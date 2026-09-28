#!/usr/bin/env python3
"""Claude Code PreToolUse hook: every write-time guard, in one process.

Each hook entry costs a Python start, about 17 ms on a laptop, and the harness
pays it on every matching tool call. So the guards are functions in a package
rather than scripts in settings.json: one entry per matcher imports them and
calls them in order, and a second guard behind the same matcher costs no second
process.

The registry wires this script twice, under two ids:

    write-guards   matcher Write|Edit|MultiEdit  ->  guards.GUARDS
    bash-guards    matcher Bash                  ->  guards.BASH_GUARDS

Which tuple runs is decided here, from the payload's tool name, so the two
entries share one file and one set of tests.

Fails open, always. A guard that raises is skipped and the ones after it still
run; a dispatcher that raises exits 0 and says nothing. A broken guard must
never wedge a session: it protects a file that git remembers, not a promotion
nobody can take back.

Add a guard: write it in guards/, then list it in guards/__init__.py.
"""

from __future__ import annotations

import json
import os
import sys
from typing import Any

# Claude Code runs this through the ~/.claude/hooks symlink, so sys.path[0] is
# the symlink's directory and the guards package beside the real file is not on
# it. Resolve the link and add the directory the package actually lives in.
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))


def deny(reason: str) -> None:
    """Block the tool call and say what to do instead."""
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))


def verdict(payload: dict[str, Any]) -> str | None:
    """Run the guards for this tool and return the first refusal, or None."""
    from guards import BASH_GUARDS, GUARDS  # noqa: PLC0415 - paid once, here

    selected = BASH_GUARDS if payload.get("tool_name") == "Bash" else GUARDS
    for guard in selected:
        # A guard that raises is skipped, not fatal: the ones after it still run.
        try:
            reason = guard(payload)
        except Exception:
            reason = None
        if reason:
            return reason
    return None


def main() -> None:
    """Read the hook payload, run the guards, allow unless one refuses."""
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        print("{}")
        return
    if not isinstance(payload, dict):
        print("{}")
        return
    reason = verdict(payload)
    if reason:
        deny(reason)
        return
    print("{}")


if __name__ == "__main__":
    try:
        main()
    except Exception:  # never wedge a session over a guard
        print("{}")
    sys.exit(0)
