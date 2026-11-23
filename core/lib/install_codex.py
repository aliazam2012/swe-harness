"""Install the harness into Codex CLI, next to Claude Code.

Codex reads hooks from ~/.codex/hooks.json (or $CODEX_HOME/hooks.json) in the
same shape Claude Code uses, and skills from ~/.agents/skills, one directory per
skill with a SKILL.md, following symlinks. So the work here is small:

  * Only registry entries marked "codex": true are installed. The rest read the
    Claude transcript, whose Codex counterpart the Codex docs call unstable.
  * Claude's file-edit matcher becomes "apply_patch", the tool Codex reports for
    every edit. The hooks convert the patch themselves (hooks/codex_patch.py).
  * hooks.json is merged, never replaced: an entry is the harness's only if its
    command points into this clone, so anything the person or another tool put
    there stays exactly as it was.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any, Dict, List

CODEX_MATCHERS = {"Write|Edit|MultiEdit": "apply_patch"}


def codex_dir() -> Path:
    return Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")


def hooks_file() -> Path:
    return codex_dir() / "hooks.json"


def skills_dir() -> Path:
    return Path.home() / ".agents" / "skills"


def codex_entries(entries: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """The registry entries that work on Codex, with Codex's tool matchers."""
    out = []
    for entry in entries:
        if not entry.get("codex"):
            continue
        converted = dict(entry)
        matcher = entry.get("matcher")
        converted["matcher"] = CODEX_MATCHERS.get(matcher, matcher) if matcher else matcher
        out.append(converted)
    return out


def _owned(hook: Dict[str, Any], clone: str) -> bool:
    return clone in str(hook.get("command", ""))


def merge(existing: Dict[str, Any], harness: Dict[str, List[Dict[str, Any]]], clone: str) -> Dict[str, Any]:
    """Existing hooks.json content with this clone's entries replaced by `harness`."""
    kept: Dict[str, List[Dict[str, Any]]] = {}
    for event, blocks in (existing.get("hooks") or {}).items():
        for block in blocks or []:
            hooks = [h for h in block.get("hooks", []) if not _owned(h, clone)]
            if hooks:
                kept.setdefault(event, []).append(dict(block, hooks=hooks))
    for event, blocks in harness.items():
        kept.setdefault(event, []).extend(blocks)
    merged = dict(existing)
    merged["hooks"] = kept
    return merged


def strip(existing: Dict[str, Any], clone: str) -> Dict[str, Any]:
    """Existing hooks.json content without this clone's entries."""
    return merge(existing, {}, clone)


def plan_skill_links(units: List[Any]) -> List[Dict[str, str]]:
    """One directory link per skill into ~/.agents/skills; later units override earlier ones."""
    by_name: Dict[str, Dict[str, str]] = {}
    for unit in units:
        for kind, source in unit.linkable():
            if kind == "skills":
                by_name[source.name] = {
                    "kind": "codex-skills",
                    "source": str(source),
                    "destination": str(skills_dir() / source.name),
                    "unit": unit.name,
                }
    return [by_name[name] for name in sorted(by_name)]
