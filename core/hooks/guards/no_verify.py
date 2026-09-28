#!/usr/bin/env python3
"""Refuse a git command that switches off the pre-commit and pre-push hooks.

A team rule that forbids `--no-verify` and lives only in prose is not a guard.
Before this file existed, every hook a repository installs could be skipped by
typing six characters, and the skip left no trace anywhere.

What the bypassed hooks actually do decides how much this matters. They
typically run a secret scanner, a linter, a type checker and the repository's
own checks. A commit that skips them can carry a credential into history, and
history is the one place a mistake is expensive to take back.

Three bypasses, one rule:

  * `--no-verify` on any subcommand that runs a hook.
  * `git commit -n`, which is the same flag spelled short, and the bundled
    spelling `-nm`. Only for `commit`: `git push -n` is `--dry-run`.
  * `git -c core.hooksPath=...` pointed at nothing, which disables the hooks
    without naming them.

Two normalizations before matching. Heredoc bodies are data, not commands: a
document quoting its own trigger is not a bypass. Quoted strings are data too,
so `git commit -m "document --no-verify"` passes and `grep -r "no-verify"`
passes, while `git commit --no-verify -m "x"` does not.

Override: GIT_NO_VERIFY_OVERRIDE=1, the machine owner's call and nobody
else's. A bypass is acceptable when it is disclosed, so this is an env var
rather than the config guard's allowlist: the need is a broken hook on one
command, not a standing exemption for one file.
"""

from __future__ import annotations

import os
import re
from typing import Any

OVERRIDE = "GIT_NO_VERIFY_OVERRIDE"

# Subcommands that run a hook. `push` runs pre-push; the rest run pre-commit,
# commit-msg or both.
VERIFYING = r"(?:commit|push|merge|rebase|am|cherry-pick|revert)"

# `[^;&|\n]*?` keeps a match inside one command, so `git status; echo --no-verify`
# is not a match.
# `--no-veri` is where git's unique-prefix rule starts to resolve: `--no-ver` is
# still ambiguous with `--no-verbose`, so matching from `--no-veri` catches every
# abbreviation git itself accepts and never catches `--no-verbose`.
LONG = re.compile(rf"\bgit\b[^;&|\n]*?\b{VERIFYING}\b[^;&|\n]*?--no-veri\w*")

# The short spelling, commit only: `git push -n` is `--dry-run` and is harmless.
# Short flags bundle, so `git commit -nm "x"` is the same bypass as `-n` and the
# character class has to look inside the bundle rather than at the whole token.
SHORT = re.compile(r"\bgit\b[^;&|\n]*?\bcommit\b[^;&|\n]*?(?<![\w-])-[a-zA-Z]*n[a-zA-Z]*\b")

# Disabling the hooks by pointing git at a directory that holds none.
HOOKS_PATH = re.compile(r"\bgit\b[^;&|\n]*?\bcore\.hooksPath\s*=\s*(?:/dev/null|\"\"|''|(?=\s|$))")

HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")

# Quoted bodies only. The quotes stay so the token boundaries around them do.
QUOTED = re.compile(r"'[^']*'|\"[^\"]*\"")

REASON = (
    "Blocked: this command switches off the git hooks.\n\n"
    "{what}\n\n"
    "Those hooks are where the secret scanner, the linter and the type checker "
    "run. A commit that skips them can put a credential in history, which is the "
    "one mistake that is expensive to take back.\n\n"
    "Fix the failing hook instead. If the hook itself is broken and the owner of "
    "this machine has said to go around it, set {override}=1 for the command and "
    "disclose the bypass in the pull request description."
)


def _strip_heredocs(command: str) -> str:
    """Return the command with heredoc bodies removed."""
    out, pos = [], 0
    while True:
        found = HEREDOC.search(command, pos)
        if not found:
            out.append(command[pos:])
            return "".join(out)
        out.append(command[pos:found.end()])
        rest = command[found.end():]
        end = re.search(rf"^\s*{re.escape(found.group(2))}\s*$", rest, re.M)
        if not end:
            return "".join(out)
        pos = found.end() + end.end()


def _normalized(command: str) -> str:
    """Return the command with heredoc bodies and quoted text emptied out."""
    return QUOTED.sub("''", _strip_heredocs(command))


def _what(command: str) -> str | None:
    """Name the bypass this command uses, or None when it uses none."""
    if LONG.search(command):
        return "It passes --no-verify, which skips the pre-commit and pre-push hooks."
    if SHORT.search(command):
        return "It passes -n to git commit, which is --no-verify spelled short."
    if HOOKS_PATH.search(command):
        return "It sets core.hooksPath to nothing, which disables every hook."
    return None


def check(payload: dict[str, Any]) -> str | None:
    """Return a refusal reason for this tool call, or None to let it through."""
    if payload.get("tool_name") != "Bash":
        return None
    if os.environ.get(OVERRIDE) == "1":
        return None
    data = payload.get("tool_input")
    if not isinstance(data, dict):
        return None
    command = data.get("command")
    if not isinstance(command, str) or "git" not in command:
        return None
    what = _what(_normalized(command))
    if what is None:
        return None
    return REASON.format(what=what, override=OVERRIDE)
