#!/usr/bin/env python3
"""Pin the last prompt submitted to this agent in its Herdr pane border.

Herdr draws the pane label at the top of the pane, so the label is the only
surface that stays put while the transcript scrolls. This overwrites it on
every submit with a one-line version of the prompt.

The full untruncated text is kept under HARNESS_WORKSPACE, which
herdr-sticky-show.sh reads for the popup, because a border holds one line.

Herdr is optional. Without HERDR_ENV and a herdr binary this returns having
done nothing, so a plain terminal sees no error.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))

import harness_config  # noqa: E402

# A border label longer than this crowds out the rest of the border.
MAX = 64
STATE_DIRNAME = "herdr-last-input"


def main():
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        return
    text = (payload.get("prompt") or "").strip()
    if not text:
        return

    pane = os.environ.get("HERDR_PANE_ID")
    binary = os.environ.get("HERDR_BIN_PATH")
    if os.environ.get("HERDR_ENV") != "1" or not pane or not binary:
        return

    try:
        state = harness_config.workspace() / STATE_DIRNAME
        state.mkdir(parents=True, exist_ok=True)
        (state / f"{pane.replace(':', '-')}.txt").write_text(text)
    except (OSError, SystemExit):
        pass

    one_line = re.sub(r"\s+", " ", text)
    if len(one_line) > MAX:
        one_line = one_line[: MAX - 1].rstrip() + "…"

    try:
        subprocess.run([binary, "pane", "rename", pane, f"› {one_line}"],
                       capture_output=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        pass


main()
