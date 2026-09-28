#!/usr/bin/env python3
"""Claude Code Stop hook: no hand-off after changing a hook without measuring it.

A harness change has no visible cost. A hook is paid on every tool call its
matcher selects, and a turn makes many; a change that adds a few milliseconds
to the wrong matcher costs more per turn than everything it saves, and nothing
in the session reports it. A rule that says "measure it" and has no moment
where it must happen does not change behaviour, which is the same reason the
done gate exists.

This is that moment. It fires only when this session actually edited the
harness, so a session that never touched a hook never sees it.

What it checks, and what it deliberately does not: it reads a recorded run, it
does not run the benchmark. A full run takes minutes and a Stop hook has
seconds. That is the same shape as a verification gate that reads a recorded
local run rather than re-running the code.

What counts as the harness is not restated here. harness_fingerprint says what
a benchmark run describes, and this asks that module whether a written path is
part of it, so the two cannot drift into disagreeing about what was changed.

Fails OPEN, unlike a promotion gate. A harness change is reversible and git
remembers it; wedging every session because this hook could not import
something is the worse outcome. Every open failure says so on stderr rather
than passing silently.

Override: HARNESS_BENCH_GATE_DISABLE=1, the machine owner's call and nobody
else's.

Exit: 0 always. The block is carried by the stdout JSON.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))

import harness_config  # type: ignore[import-not-found]  # noqa: E402

OVERRIDE = "HARNESS_BENCH_GATE_DISABLE"
TAIL_BYTES = 4_000_000
EDIT_TOOLS = ("Write", "Edit", "MultiEdit")

GATE = """HARNESS BENCH GATE (mandatory). This session changed the harness and no
benchmark run describes the change.

A hook's cost is invisible. It is paid on every tool call its matcher selects,
and nothing in the session reports it, so a change that made every turn slower
looks exactly like a change that made none.

Measure it, then hand back:

  {command}

Use at least 15 runs. Identical runs drift by about a third at 5 runs, so a
smaller sample compares noise rather than the change. Run it on an idle
machine; the tool warns when the load average is too high to trust.

{detail}

The owner of this machine can override with {override}=1. You cannot decide
that for them."""


def store_path() -> Path:
    """Where benchmark runs are recorded, under the harness workspace."""
    seam = os.environ.get("HARNESS_BENCH_STORE")
    if seam:
        return Path(seam).expanduser()
    return harness_config.workspace() / "benchmarks" / "hooks.jsonl"


def read_tail(path: str) -> list:
    """Return the parsed transcript tail, or an empty list."""
    try:
        with open(path, "rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            handle.seek(max(0, size - TAIL_BYTES))
            raw = handle.read().decode("utf-8", "replace")
    except OSError:
        return []
    out = []
    lines = raw.splitlines()
    # A seek into the middle of the file lands mid-line, so the first one is a
    # fragment rather than a record. Only drop it when the file was truncated.
    for line in lines[1:] if size > TAIL_BYTES else lines:
        try:
            out.append(json.loads(line))
        except ValueError:
            continue
    return out


def touched_harness(entries: list, is_harness) -> str | None:
    """Return the first harness path this session wrote, or None."""
    for entry in entries:
        message = entry.get("message") or {}
        for block in message.get("content") or []:
            if not isinstance(block, dict) or block.get("type") != "tool_use":
                continue
            if block.get("name") not in EDIT_TOOLS:
                continue
            target = str((block.get("input") or {}).get("file_path") or "")
            if target and is_harness(target):
                return target
    return None


def measured() -> tuple:
    """Return (recorded fingerprint, run id) from the newest stored run."""
    try:
        lines = [ln for ln in store_path().read_text().splitlines() if ln.strip()]
        run = json.loads(lines[-1])
        return (run.get("context", {}).get("harness_sha") or "", run.get("run_id") or "")
    except Exception:
        return ("", "")


def block(reason: str) -> None:
    """Emit the Stop block on both channels the two hook paths read."""
    print(reason, file=sys.stderr)
    print(json.dumps({"decision": "block", "reason": reason}))


def bench_command() -> str:
    """The command the message tells the agent to run, resolved for this clone."""
    script = Path(harness_config.harness_home()) / "core" / "scripts" / "harness-bench.py"
    return "python3 %s --runs 15 --compare last" % script


def main() -> None:
    """Block the hand-off when the harness moved and nothing measured it."""
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return
    if not isinstance(payload, dict):
        return
    if payload.get("stop_hook_active") or os.environ.get(OVERRIDE) == "1":
        return
    entries = read_tail(str(payload.get("transcript_path") or ""))
    if not entries:
        return
    try:
        import harness_fingerprint as hf  # noqa: PLC0415
    except Exception as err:  # fail open, loudly
        print("harness bench gate could not load the fingerprint: %s" % err, file=sys.stderr)
        return
    touched = touched_harness(entries, hf.is_harness_path)
    if not touched:
        return
    try:
        current = hf.fingerprint()
    except Exception as err:  # fail open, loudly
        print("harness bench gate could not fingerprint the harness: %s" % err, file=sys.stderr)
        return
    recorded, run_id = measured()
    if recorded == current:
        return
    detail = ("Changed: %s\nHarness now: %s\nLast measured: %s%s"
              % (touched, current[:12], recorded[:12] or "never",
                 (" in run %s" % run_id) if run_id else ""))
    block(GATE.format(command=bench_command(), detail=detail, override=OVERRIDE))


if __name__ == "__main__":
    try:
        main()
    except Exception:  # a Stop hook must never wedge a session
        pass
    sys.exit(0)
