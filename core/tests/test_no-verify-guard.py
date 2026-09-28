#!/usr/bin/env python3
"""Exercise the no-verify guard in both directions.

The must-allow half is the half that decides whether the guard survives. A guard
that blocks `git log -n 5` or a commit message quoting the flag gets switched off
the first week, and then it protects nothing.

BLOCK covers every spelling of the bypass found in git's own interface: the long
flag, its unambiguous abbreviations, the short flag, the short flag bundled with
another, and the hooksPath trick. ALLOW covers the near misses that share the
same characters and mean something else.

One case goes through the real hook as a subprocess, to prove the guard is wired
and not merely importable. It runs inside pretooluse-dispatcher.py under the
Bash matcher: one PreToolUse entry per matcher, so every Bash guard shares a
single interpreter start.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

HOOKS = Path(__file__).resolve().parents[1] / "hooks"
sys.path.insert(0, str(HOOKS))
from guards.no_verify import (  # type: ignore[import-not-found]  # noqa: E402
    OVERRIDE,
    check,
)

HOOK = str(HOOKS / "pretooluse-dispatcher.py")

BLOCK = [
    ('git commit --no-verify -m "x"', "long flag before the message"),
    ('git commit -m "x" --no-verify', "long flag after the message"),
    ("git push --no-verify", "pre-push hook"),
    ("git push origin main --no-verify", "flag last"),
    ("git commit --no-verif", "abbreviation git accepts"),
    ("git commit --no-veri", "shortest unambiguous abbreviation"),
    ('git commit -n -m "x"', "short flag"),
    ('git commit -nm "x"', "short flag bundled"),
    ("git commit --amend -n", "short flag with amend"),
    ('git -c core.hooksPath=/dev/null commit -m "x"', "hooksPath to nowhere"),
    ('git -c core.hooksPath="" commit', "hooksPath emptied"),
    ("git merge --no-verify topic", "merge runs a hook too"),
    ('cd /var/tmp/repo && git commit --no-verify -m "x"', "after a separator"),
]

ALLOW = [
    ('git commit -m "x"', "an ordinary commit"),
    ('git commit -am "x"', "a bundle with no n in it"),
    ("git commit --amend --no-edit", "--no-edit is not --no-verify"),
    ("git commit --no-verbose", "shares the --no-ver prefix, different flag"),
    ('git commit -m "document the --no-verify rule"', "the flag inside a message"),
    ('git commit -m "fix: stop using -n"', "the short flag inside a message"),
    ('grep -r "no-verify" .', "reading about the flag"),
    ("git push -n", "-n on push is --dry-run"),
    ("git log --oneline -n 5", "-n on log is a count"),
    ("git push --force-with-lease", "the one allowed force"),
    ("git status", "no flag at all"),
    ("cat <<EOF\ngit commit --no-verify\nEOF", "the flag inside a heredoc body"),
    ("ls -la", "not a git command"),
]


def payload(command: str) -> dict:
    """Return a Bash PreToolUse payload for this command."""
    return {"tool_name": "Bash", "tool_input": {"command": command}}


fails = 0


def report(name: str, ok: bool, note: str = "") -> None:
    """Print one assertion line in the shape the runner counts."""
    global fails
    print("  %s %s%s" % ("ok  " if ok else "FAIL", name, (": %s" % note) if note else ""))
    fails += 0 if ok else 1


for command, why in BLOCK:
    report("block/%s" % why, check(payload(command)) is not None, command)

for command, why in ALLOW:
    reason = check(payload(command))
    report("allow/%s" % why, reason is None, command)

report(
    "not-this-guards-call",
    check({"tool_name": "Write", "tool_input": {"file_path": "/var/tmp/x"}}) is None,
    "a Write call is the config guard's, not this one's",
)

os.environ[OVERRIDE] = "1"
report("%s=1 lets it through" % OVERRIDE, check(payload("git commit --no-verify")) is None)
del os.environ[OVERRIDE]

# Through the real hook, to prove the guard is wired and not merely importable.
_env = dict(os.environ)
_env.pop(OVERRIDE, None)
_out = subprocess.run(  # noqa: S603 - the interpreter and the hook are ours
    [sys.executable, HOOK],
    input=json.dumps(payload('git commit --no-verify -m "x"')),
    capture_output=True, text=True, env=_env, check=False,
)
_decision = ""
if _out.stdout.strip():
    _decision = json.loads(_out.stdout).get(
        "hookSpecificOutput", {}).get("permissionDecision", "")
report("wired into pretooluse-dispatcher.py on the Bash matcher",
       _decision == "deny", _decision or _out.stderr[:60])

_total = len(BLOCK) + len(ALLOW) + 3
print("\n%d passed, %d failed" % (_total - fails, fails))
sys.exit(1 if fails else 0)
