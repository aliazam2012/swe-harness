#!/usr/bin/env python3
"""Exercise the harness bench Stop gate in both directions.

The must-pass half decides whether the gate survives. A gate that fires on a
session that never touched a hook, or on a test edit, is one the machine owner
turns off in a week, and then it guards nothing.

Every case drives the real hook as a subprocess over a transcript this file
wrote, with the store and the fingerprint inputs pointed at a sandbox, so
nothing here reads or writes the installed harness.
"""
import atexit
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Optional

HOOKS_SRC = Path(__file__).resolve().parents[1] / "hooks"
HOOK = str(HOOKS_SRC / "stop-harness-bench-gate.py")
FPRINT = str(HOOKS_SRC / "harness_fingerprint.py")
SANDBOX = Path(tempfile.mkdtemp(prefix="harness-gate-test-"))
atexit.register(shutil.rmtree, SANDBOX, ignore_errors=True)

# The gate does not carry its own idea of what the harness is: it asks
# harness_fingerprint, which reads the same three seams this sandbox sets. So a
# sandbox hook directory anywhere is a real hook directory as far as the gate is
# concerned, and nothing here needs the installed layout.
HOOKS = SANDBOX / "unit" / "hooks"
HOOKS.mkdir(parents=True)
(HOOKS / "a-hook.py").write_text("print('hi')\n")
(HOOKS / "tests").mkdir()
(HOOKS / "tests" / "test_a.py").write_text("x = 1\n")
SETTINGS = SANDBOX / "settings.json"
SETTINGS.write_text('{"hooks":{}}\n')
REGISTRY = SANDBOX / "unit" / "registry.json"
REGISTRY.write_text('{"hooks":[]}\n')
STORE = SANDBOX / "hooks.jsonl"
ELSEWHERE = SANDBOX / "project"
ELSEWHERE.mkdir()
(ELSEWHERE / "main.py").write_text("x = 1\n")

ENV = dict(
    os.environ,
    HARNESS_BENCH_HOOKS=str(HOOKS),
    HARNESS_BENCH_SETTINGS=str(SETTINGS),
    HARNESS_BENCH_REGISTRY=str(REGISTRY),
    HARNESS_BENCH_STORE=str(STORE),
)
ENV.pop("HARNESS_BENCH_GATE_DISABLE", None)


def current_sha() -> str:
    """Return the fingerprint of the sandbox harness."""
    out = subprocess.run(  # noqa: S603 - the interpreter and the module are ours
        [sys.executable, FPRINT], capture_output=True, text=True, env=ENV, check=False)
    return out.stdout.strip()


def transcript(*paths: str) -> str:
    """Write a transcript whose turn edited each path. Returns its path."""
    target = SANDBOX / ("t-%s.jsonl" % abs(hash(paths)))
    lines = [json.dumps({"type": "user", "message": {"role": "user", "content": "go"}})]
    for path in paths:
        lines.append(json.dumps({
            "type": "assistant",
            "message": {"role": "assistant", "content": [
                {"type": "tool_use", "name": "Edit", "id": "t1",
                 "input": {"file_path": path, "old_string": "a", "new_string": "b"}},
            ]},
        }))
    target.write_text("\n".join(lines) + "\n")
    return str(target)


def record(sha: str) -> None:
    """Store one benchmark run carrying this harness fingerprint."""
    STORE.write_text(json.dumps({"run_id": "T1", "context": {"harness_sha": sha}}) + "\n")


def invoke(payload: dict, env: Optional[dict] = None) -> str:
    """Run the gate and return its stdout decision, or an empty string."""
    out = subprocess.run(  # noqa: S603 - the interpreter and the hook are ours
        [sys.executable, HOOK], input=json.dumps(payload),
        capture_output=True, text=True, env=env or ENV, check=False)
    if not out.stdout.strip():
        return ""
    return json.loads(out.stdout).get("decision", "")


fails = 0


def report(name: str, ok: bool, note: str = "") -> None:
    """Print one assertion line in the shape the runner counts."""
    global fails
    print("  %s %s%s" % ("ok  " if ok else "FAIL", name, (": %s" % note) if note else ""))
    fails += 0 if ok else 1


HOOK_EDIT = transcript(str(HOOKS / "a-hook.py"))
TEST_EDIT = transcript(str(HOOKS / "tests" / "test_a.py"))
REGISTRY_EDIT = transcript(str(REGISTRY))
OTHER_EDIT = transcript(str(ELSEWHERE / "main.py"))

# Nothing measured yet: a harness edit must block.
STORE.write_text("")
report("blocks a hook edit with no run recorded",
       invoke({"transcript_path": HOOK_EDIT}) == "block")
report("blocks a registry edit with no run recorded",
       invoke({"transcript_path": REGISTRY_EDIT}) == "block")

# A run describing a different harness must still block.
record("deadbeef" * 8)
report("blocks a hook edit measured against a different harness",
       invoke({"transcript_path": HOOK_EDIT}) == "block")

# A run describing this harness lets it through.
record(current_sha())
report("passes once a run describes this harness",
       invoke({"transcript_path": HOOK_EDIT}) == "")

# The same recorded run, but the harness moved again afterwards.
(HOOKS / "a-hook.py").write_text("print('changed')\n")
report("blocks again after the harness moves past the recorded run",
       invoke({"transcript_path": HOOK_EDIT}) == "block")

# Must-pass half.
STORE.write_text("")
report("a session that edited no harness file passes",
       invoke({"transcript_path": OTHER_EDIT}) == "")
report("editing a hook's test is not a cost change, so it passes",
       invoke({"transcript_path": TEST_EDIT}) == "")
report("stop_hook_active passes, so the block cannot loop",
       invoke({"stop_hook_active": True, "transcript_path": HOOK_EDIT}) == "")
report("the named override passes",
       invoke({"transcript_path": HOOK_EDIT},
              dict(ENV, HARNESS_BENCH_GATE_DISABLE="1")) == "")
report("an unreadable transcript passes rather than wedging the session",
       invoke({"transcript_path": str(SANDBOX / "missing.jsonl")}) == "")
report("malformed stdin passes",
       subprocess.run(  # noqa: S603 - the interpreter and the hook are ours
           [sys.executable, HOOK], input="not json", capture_output=True,
           text=True, env=ENV, check=False).stdout.strip() == "")

# The fingerprint must ignore test files, or the gate fires on noise.
before = current_sha()
(HOOKS / "tests" / "test_a.py").write_text("x = 2\n")
report("the fingerprint ignores test files", current_sha() == before)
(HOOKS / "a-hook.py").write_text("print('again')\n")
report("the fingerprint tracks hook source", current_sha() != before)
before = current_sha()
SETTINGS.write_text('{"hooks":{"Stop":[]}}\n')
report("the fingerprint tracks the generated settings", current_sha() != before)

print("\n%d passed, %d failed" % (14 - fails, fails))
sys.exit(1 if fails else 0)
