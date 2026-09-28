#!/usr/bin/env python3
"""Claude Code PostToolUse hook: enforce Python standards on every .py write.

The mechanical half of the Python standard. Runs after Write, Edit or MultiEdit
on a .py file: ruff for lint, mypy for types, and an optional extra checks
script. Violations are fed back so the agent self-corrects, which replaces "the
model remembers the rules" with "the tool enforces the rules" at zero standing
context cost.

Tool discovery is lenient by design. A missing ruff, mypy or checks script is
skipped, never a hard failure: real work must not stop because tooling is not
installed in this repository.

Configuration:
  BLOCK_ON_ERROR      True, so a hard finding blocks. Set False to warn only.
  PYTHON_CHECKS_RUNNER  Harness config key. An extra checks script run as
                        `<python> <script> <file>`. Unset means no extra
                        checks; the in-clone default is used when it exists.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))

import harness_config  # noqa: E402

BLOCK_ON_ERROR = True
TIMEOUT_S = 60


def checks_runner() -> str:
    """Absolute path to the extra checks script, or an empty string."""
    try:
        configured = harness_config.get("PYTHON_CHECKS_RUNNER")
    except KeyError:
        configured = None
    if configured:
        return os.path.expanduser(configured)
    bundled = (
        harness_config.harness_home() / "core" / "scripts" / "python-checks" / "run_checks.py"
    )
    return str(bundled) if bundled.is_file() else ""


def emit(block: bool, reason: str = "") -> None:
    """Write the hook's decision and exit 0."""
    print(json.dumps({"decision": "block", "reason": reason}) if block and reason else "{}")
    sys.exit(0)


def run(cmd: list[str]) -> tuple[int, str]:
    """Run a checker and return its exit code and combined output."""
    try:
        done = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT_S)
        return done.returncode, (done.stdout + done.stderr).strip()
    except Exception as exc:
        return 0, f"(skipped: {exc})"  # lenient: tooling problems never block


def main() -> None:
    """Lint the file this tool call wrote, and feed back what failed."""
    try:
        data = json.loads(sys.stdin.read() or "{}")
    except Exception:
        emit(False)
        return
    if not isinstance(data, dict):
        emit(False)
        return

    tool_input = data.get("tool_input") or {}
    path = tool_input.get("file_path") or tool_input.get("path") or ""
    if not isinstance(path, str) or not path.endswith(".py") or not os.path.exists(path):
        emit(False)
        return

    findings = []
    if shutil.which("ruff"):
        code, out = run(["ruff", "check", path])
        if code != 0 and out:
            findings.append("ruff:\n" + out)
    if shutil.which("mypy"):
        code, out = run(["mypy", path])
        if code != 0 and out:
            findings.append("mypy:\n" + out)
    runner = checks_runner()
    if runner and os.path.exists(runner):
        code, out = run([sys.executable, runner, path])
        if code != 0 and out:
            findings.append("project-checks:\n" + out)

    if findings:
        emit(
            BLOCK_ON_ERROR,
            "Python standard violations in "
            + os.path.basename(path)
            + " (fix before continuing):\n\n"
            + "\n\n".join(findings),
        )
    else:
        emit(False)


if __name__ == "__main__":
    main()
