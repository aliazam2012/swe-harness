#!/usr/bin/env python3
"""Refuse an edit that weakens an existing linter, formatter or type-checker config.

An agent that cannot make a check pass can instead weaken the check and commit
both halves together. CI then runs the weakened config and goes green, so CI
cannot catch this by construction. It matters most where a checker runs only
locally: the PostToolUse lint hook is then the only enforcement there is, and
its config is a plain file any write can reach.

Two rules:

  * A config file that exists already is read-only. Creating one that does not
    exist yet is ordinary work and passes.
  * `pyproject.toml` carries dependencies and metadata as well as our ruff
    settings, so a blanket rule would be wrong. It is inspected instead: the
    call is refused only when it changes a `[tool.ruff]`, `[tool.mypy]`,
    `[tool.pytest]` or `[tool.coverage]` table. A dependency bump passes.

The exemption is a line in an allowlist with a written reason, never an
environment variable: a switch that turns the guard off is the same hole the
guard exists to close. Only the person who owns the machine edits that file.
"""

from __future__ import annotations

import fnmatch
import os
import re
from typing import Any

# Basename globs. Every one of these is a linter, formatter or type-checker
# configuration and nothing else, so the name alone decides.
PROTECTED = (
    "ruff.toml", ".ruff.toml", "mypy.ini", ".flake8", "setup.cfg",
    ".eslintrc*", "eslint.config.*", "biome.json", ".stylelintrc*",
    ".markdownlint*", ".shellcheckrc", ".pre-commit-config.yaml",
)

PYPROJECT = "pyproject.toml"

# The `[tool.<name>]` tables inside pyproject.toml that decide whether a check
# passes. Sub-tables such as `[tool.ruff.lint]` are covered by the prefix.
GUARDED = ("ruff", "mypy", "pytest", "coverage")

# Home-relative on purpose: it has to resolve the same way under the dotfiles
# symlink layout and under a test sandbox that moves HOME.
ALLOWLIST = ".claude/config-guard-allowlist.txt"

TABLE = re.compile(r"^[ \t]*\[\[?[ \t]*([^\]\n]+?)[ \t]*\]\]?[ \t]*$", re.M)


def _is_guarded(name: str) -> bool:
    """Report whether a TOML table name is one of the guarded tool tables."""
    return any(name == f"tool.{t}" or name.startswith(f"tool.{t}.") for t in GUARDED)


def _allowlist_path() -> str:
    """Return where the written exemptions live."""
    return os.path.join(os.path.expanduser("~"), ALLOWLIST)


def _target(payload: dict[str, Any]) -> str:
    """Return the absolute path the tool call would write, or an empty string."""
    data = payload.get("tool_input")
    if not isinstance(data, dict):
        return ""
    path = data.get("file_path") or data.get("path") or ""
    if not isinstance(path, str) or not path:
        return ""
    path = os.path.expanduser(path)
    if not os.path.isabs(path):
        path = os.path.join(str(payload.get("cwd") or os.getcwd()), path)
    return os.path.normpath(path)


def _allowlisted(path: str) -> bool:
    """Report whether an exemption line covers this path.

    A line is `<path glob>  # <reason>`. The reason is not decoration: a line
    without one does not exempt anything, so nobody can silence the guard by
    pasting a path.
    """
    try:
        with open(_allowlist_path(), encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except OSError:
        return False
    for line in lines:
        pattern, _, reason = line.strip().partition("#")
        pattern = os.path.expanduser(pattern.strip())
        if pattern and reason.strip() and fnmatch.fnmatch(path, pattern):
            return True
    return False


def _applied(payload: dict[str, Any], current: str) -> str | None:
    """Return the content the call would leave on disk, or None if unknowable."""
    data = payload.get("tool_input")
    if not isinstance(data, dict):
        return None
    if payload.get("tool_name") == "Write":
        content = data.get("content")
        return content if isinstance(content, str) else None
    edits = data.get("edits") if payload.get("tool_name") == "MultiEdit" else [data]
    if not isinstance(edits, list):
        return None
    text = current
    for edit in edits:
        if not isinstance(edit, dict):
            return None
        old, new = edit.get("old_string"), edit.get("new_string")
        if not isinstance(old, str) or not isinstance(new, str) or old not in text:
            return None
        text = text.replace(old, new, -1 if edit.get("replace_all") else 1)
    return text


def _parsed_tables(text: str) -> dict[str, Any] | None:
    """Return the guarded tables as parsed values, or None if the TOML is broken.

    tomllib arrived in python 3.11 and the harness floor is 3.9, so a clone on
    the floor gets None here and the line comparison below answers instead.
    """
    try:
        import tomllib  # noqa: PLC0415 - kept off the cold path
    except ImportError:
        return None

    try:
        tool = tomllib.loads(text).get("tool")
    except (ValueError, TypeError):
        return None
    if not isinstance(tool, dict):
        return {}
    return {name: value for name, value in tool.items() if name in GUARDED}


def _guarded_lines(text: str) -> list[str]:
    """Return the guarded tables as their significant lines.

    The fallback for TOML the parser refuses. Blank and comment lines are
    dropped: a comment is not a rule, so rewriting one is not weakening a check.
    """
    out, inside = [], False
    for line in text.splitlines():
        found = TABLE.match(line)
        if found:
            inside = _is_guarded(found.group(1).strip())
        stripped = line.strip()
        if inside and stripped and not stripped.startswith("#"):
            out.append(stripped)
    return out


def _touches_guarded(path: str, payload: dict[str, Any]) -> bool:
    """Report whether the call changes a guarded table in this pyproject.toml.

    The comparison is of the file as it is against the file as the call would
    leave it, so a dependency bump, a metadata change or a comment rewrite is
    invisible here and passes. When the parser refuses either side, the line
    comparison answers instead.
    """
    try:
        with open(path, encoding="utf-8") as handle:
            current = handle.read()
    except OSError:
        return False
    candidate = _applied(payload, current)
    if candidate is None:
        # The edit did not apply against the file on disk, so the result cannot
        # be computed. Fall back to what the call itself says.
        return _mentions_guarded(payload)
    before, after = _parsed_tables(current), _parsed_tables(candidate)
    if before is not None and after is not None:
        return before != after
    return _guarded_lines(current) != _guarded_lines(candidate)


def _mentions_guarded(payload: dict[str, Any]) -> bool:
    """Report whether the call's own text declares a guarded table."""
    data = payload.get("tool_input")
    if not isinstance(data, dict):
        return False
    blobs = [data.get("content"), data.get("old_string"), data.get("new_string")]
    edits = data.get("edits")
    for edit in edits if isinstance(edits, list) else []:
        if isinstance(edit, dict):
            blobs += [edit.get("old_string"), edit.get("new_string")]
    text = "\n".join(b for b in blobs if isinstance(b, str))
    return any(_is_guarded(found.group(1).strip()) for found in TABLE.finditer(text))


def _refuse(path: str, what: str) -> str:
    """Build the refusal: the rule, and the two ways out of it."""
    return (
        f"CONFIG PROTECTION: {path} is {what}.\n\n"
        "A check you cannot pass is not a check to weaken. Loosening a linter, a "
        "formatter or a type checker and committing the change with the code it "
        "excuses makes CI go green on a defect, and CI cannot catch that by "
        "construction.\n\n"
        "Do one of these instead:\n"
        "  1. Fix the code so the configuration as it stands passes.\n"
        "  2. Ask the owner of this machine for an exemption. It is one line "
        f"in ~/{ALLOWLIST}, the path and a written reason after a '#'. "
        "There is no environment variable that switches this guard off, and a "
        "line without a reason exempts nothing.\n\n"
        "Creating a config that does not exist yet is allowed; this rule is "
        "about changing one that does."
    )


def _by_name(path: str) -> str | None:
    """Refuse a change to a config that the filename alone identifies."""
    if not any(fnmatch.fnmatch(os.path.basename(path), p) for p in PROTECTED):
        return None
    if not os.path.exists(path) or _allowlisted(path):
        return None
    return _refuse(path, "an existing linter, formatter or type-checker configuration")


def _by_content(path: str, payload: dict[str, Any]) -> str | None:
    """Refuse a pyproject.toml change only when it reaches a guarded table."""
    if not os.path.exists(path) or _allowlisted(path) or not _touches_guarded(path, payload):
        return None
    return _refuse(
        path,
        "carrying a [tool.ruff], [tool.mypy], [tool.pytest] or [tool.coverage] "
        "table, and this call changes one",
    )


def check(payload: dict[str, Any]) -> str | None:
    """Return a refusal reason for this tool call, or None to let it through."""
    path = _target(payload)
    if not path:
        return None
    if path == _allowlist_path():
        return _refuse(
            path, "the guard's own exemption allowlist, which only its owner edits"
        )
    if os.path.basename(path) == PYPROJECT:
        return _by_content(path, payload)
    return _by_name(path)
