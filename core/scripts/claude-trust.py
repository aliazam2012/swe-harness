#!/usr/bin/env python3
"""Pre-trust a directory for Claude Code so it does not show the folder-trust dialog.

Claude Code records trust per exact path in ``~/.claude.json`` under
``projects[path].hasTrustDialogAccepted``. There is no global bypass setting, so
every new git worktree is a new path and stalls an unattended agent start with
``agent_not_ready``.

This tool sets that one flag, and only under roots listed in ``allowed_roots()``.
That bound is the point: it cannot be used to blanket-trust an arbitrary
directory someone else handed you.

Usage:
    claude-trust.py <path> [<path> ...]
    claude-trust.py --list
    claude-trust.py --revoke <path>
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))

import harness_config as cfg  # noqa: E402

CONFIG_PATH = Path.home() / ".claude.json"
TRUST_ROOTS_ENV = "CLAUDE_TRUST_ROOTS"
LANE_WORKTREE_ROOT_ENV = "LANE_WORKTREE_ROOT"


def backup_dir() -> Path:
    """Where a pre-write copy of the config goes: inside the workspace."""
    return cfg.workspace() / "backups"


def allowed_roots() -> Tuple[Path, ...]:
    """Directories under which a path may be trusted.

    The bound is the point: this cannot be used to blanket-trust an arbitrary
    directory someone else handed you, which is why the default is narrow: the
    lane worktree root and the harness clone itself. Widen it deliberately with
    CLAUDE_TRUST_ROOTS, a colon-separated list.
    """
    configured = os.environ.get(TRUST_ROOTS_ENV, "")
    roots = [Path(part).expanduser() for part in configured.split(":") if part.strip()]
    if roots:
        return tuple(roots)
    worktrees = os.environ.get(LANE_WORKTREE_ROOT_ENV) or str(Path.home() / "worktrees")
    return (Path(worktrees).expanduser(), cfg.harness_home())


TRUST_KEY = "hasTrustDialogAccepted"


class TrustError(Exception):
    """A path was refused, or the config could not be read or written."""


def _load_config() -> Dict[str, Any]:
    """Read ~/.claude.json, or raise TrustError if it is missing or malformed."""
    if not CONFIG_PATH.exists():
        raise TrustError(f"{CONFIG_PATH} does not exist")
    try:
        loaded: Any = json.loads(CONFIG_PATH.read_text())
    except json.JSONDecodeError as exc:
        raise TrustError(f"{CONFIG_PATH} is not valid JSON: {exc}") from exc
    if not isinstance(loaded, dict):
        raise TrustError(f"{CONFIG_PATH} is not a JSON object")
    return loaded


def _backup_config() -> Path:
    """Copy the config aside before a write, and return the backup path."""
    target_dir = backup_dir()
    target_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    target = target_dir / f"claude.json.bak.{stamp}"
    shutil.copy2(CONFIG_PATH, target)
    return target


def _save_config(config: Dict[str, Any]) -> None:
    """Write the config atomically.

    Writes to a temp file in the same directory then replaces, so a crash
    mid-write cannot leave a truncated config.
    """
    tmp = CONFIG_PATH.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(config, indent=2) + "\n")
    tmp.replace(CONFIG_PATH)


def resolve_and_check(raw: str) -> Path:
    """Resolve a user-supplied path and refuse anything outside allowed_roots()."""
    path = Path(raw).expanduser().resolve()
    if not path.is_dir():
        raise TrustError(f"not a directory: {path}")
    for root in allowed_roots():
        if path == root or root in path.parents:
            return path
    roots = ", ".join(str(r) for r in allowed_roots())
    raise TrustError(f"refused, {path} is not under an allowed root ({roots})")


def trust(paths: list[str]) -> int:
    """Mark each path trusted. Returns 1 if any path was refused."""
    resolved: list[Path] = []
    errors: list[str] = []
    for raw in paths:
        try:
            resolved.append(resolve_and_check(raw))
        except TrustError as exc:
            errors.append(str(exc))

    for message in errors:
        print(f"error: {message}", file=sys.stderr)
    if not resolved:
        return 1

    config = _load_config()
    projects = config.setdefault("projects", {})

    changed: list[Path] = []
    for path in resolved:
        entry = projects.setdefault(str(path), {})
        if entry.get(TRUST_KEY) is True:
            print(f"already trusted  {path}")
            continue
        entry[TRUST_KEY] = True
        changed.append(path)

    if changed:
        backup = _backup_config()
        _save_config(config)
        for path in changed:
            print(f"trusted          {path}")
        print(f"backup           {backup}")

    return 1 if errors else 0


def revoke(raw: str) -> int:
    """Set one path back to untrusted, so the dialog appears again."""
    path = Path(raw).expanduser().resolve()
    config = _load_config()
    entry = config.get("projects", {}).get(str(path))
    if not entry or entry.get(TRUST_KEY) is not True:
        print(f"not trusted, nothing to do: {path}")
        return 0
    backup = _backup_config()
    entry[TRUST_KEY] = False
    _save_config(config)
    print(f"revoked  {path}")
    print(f"backup   {backup}")
    return 0


def list_trusted() -> int:
    """Print every project path Claude Code knows, split by trust state."""
    config = _load_config()
    projects = config.get("projects", {})
    trusted = sorted(p for p, v in projects.items() if v.get(TRUST_KEY) is True)
    untrusted = sorted(p for p, v in projects.items() if v.get(TRUST_KEY) is not True)
    print(f"trusted ({len(trusted)}):")
    for path in trusted:
        print(f"  {path}")
    print(f"not trusted ({len(untrusted)}):")
    for path in untrusted:
        print(f"  {path}")
    return 0


def main() -> int:
    """Parse arguments and dispatch. Returns the process exit code."""
    parser = argparse.ArgumentParser(
        description="Pre-trust directories for Claude Code, bounded to your own repo roots.",
    )
    parser.add_argument("paths", nargs="*", help="directories to trust")
    parser.add_argument("--list", action="store_true", help="show current trust state")
    parser.add_argument("--revoke", metavar="PATH", help="set a path back to untrusted")
    args = parser.parse_args()

    try:
        if args.list:
            return list_trusted()
        if args.revoke:
            return revoke(args.revoke)
        if not args.paths:
            parser.print_help()
            return 2
        return trust(args.paths)
    except TrustError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
