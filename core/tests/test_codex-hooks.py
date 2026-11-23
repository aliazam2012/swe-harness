#!/usr/bin/env python3
"""The guardrail hooks on Codex-shaped payloads, through the real hook scripts.

Codex sends the same stdin fields as Claude Code (tool_name, tool_input, cwd,
hook_event_name). Shell calls are tool_name "Bash"; file edits are "apply_patch"
with the patch text in tool_input.command.
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

HOOKS = Path(__file__).resolve().parents[1] / "hooks"
DISPATCHER = str(HOOKS / "pretooluse-dispatcher.py")
sys.path.insert(0, str(HOOKS))

fails = 0
total = 0


def report(name, ok, detail=""):
    global fails, total
    total += 1
    print(("  ok   %s" % name) if ok else ("  FAIL %s %s" % (name, detail)))
    if not ok:
        fails += 1


def decision(payload, home):
    env = dict(os.environ, HOME=home)
    out = subprocess.run(  # noqa: S603 - the interpreter and the hook are ours
        [sys.executable, DISPATCHER], input=json.dumps(payload),
        capture_output=True, text=True, env=env, check=False,
    )
    body = json.loads(out.stdout or "{}")
    return body.get("hookSpecificOutput", {}).get("permissionDecision", "allow")


def patch(*body):
    return "*** Begin Patch\n" + "\n".join(body) + "\n*** End Patch\n"


with tempfile.TemporaryDirectory() as tmp:
    home = os.path.join(tmp, "home")
    repo = os.path.join(tmp, "repo")
    os.makedirs(home)
    os.makedirs(repo)
    Path(repo, "ruff.toml").write_text('[lint]\nselect = ["E", "F"]\n')

    bash = {"hook_event_name": "PreToolUse", "tool_name": "Bash", "cwd": repo,
            "tool_input": {"command": 'git commit --no-verify -m "x"'}}
    report("Codex Bash with --no-verify is denied", decision(bash, home) == "deny")

    weaken = {"hook_event_name": "PreToolUse", "tool_name": "apply_patch", "cwd": repo,
              "tool_input": {"command": patch("*** Update File: ruff.toml", "@@ [lint]",
                                              '-select = ["E", "F"]', '+select = ["E"]')}}
    report("a Codex patch to an existing ruff.toml is denied", decision(weaken, home) == "deny")

    hidden = {"hook_event_name": "PreToolUse", "tool_name": "apply_patch", "cwd": repo,
              "tool_input": {"command": patch("*** Add File: notes.md", "+hello",
                                              "*** Delete File: ruff.toml")}}
    report("a delete of ruff.toml later in the same patch is denied", decision(hidden, home) == "deny")

    plain = {"hook_event_name": "PreToolUse", "tool_name": "apply_patch", "cwd": repo,
             "tool_input": {"command": patch("*** Add File: notes.md", "+hello")}}
    report("a Codex patch that only adds a new file passes", decision(plain, home) == "allow")

    spec = importlib.util.spec_from_file_location("lint_hook", HOOKS / "posttooluse-python-lint.py")
    lint = importlib.util.module_from_spec(spec)
    sys.modules["lint_hook"] = lint
    spec.loader.exec_module(lint)
    Path(repo, "a.py").write_text("x = 1\n")
    Path(repo, "b.py").write_text("y = 2\n")
    touched = {"tool_name": "apply_patch", "cwd": repo,
               "tool_input": {"command": patch("*** Update File: a.py", "@@", "-x = 0", "+x = 1",
                                               "*** Add File: b.py", "+y = 2",
                                               "*** Add File: c.md", "+text")}}
    paths = lint.python_paths(touched)
    report("lint checks every .py file a Codex patch touched",
           paths == [os.path.join(repo, "a.py"), os.path.join(repo, "b.py")], paths)
    claude = {"tool_name": "Write", "tool_input": {"file_path": os.path.join(repo, "a.py")}}
    report("a Claude Write still lints its one file", lint.python_paths(claude) == [os.path.join(repo, "a.py")])

print("\n%d passed, %d failed" % (total - fails, fails))
sys.exit(1 if fails else 0)
