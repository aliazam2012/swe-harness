#!/usr/bin/env python3
"""Discover layers, validate them against the contract, and merge their registries.

A unit is core or a layer. Each may ship a registry.json of hook entries that name
a script by a path relative to that unit's own root. Nothing here resolves a path
to this machine: install.py does that once, at write time, which is the single
reason a clone works somewhere else.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

EVENTS = {
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "PreCompact",
    "Stop",
    "SessionEnd",
}
RUNNERS = {"python3", "bash"}
PROFILES = ("minimal", "standard", "strict")
LINKABLE = ("skills", "agents", "commands")

# An absolute path stored in a registry is the defect this whole design exists to
# prevent, so it is checked rather than trusted.
ABSOLUTE = re.compile(r"(^|[\s\"'=:])(/|~/)")


class LayerError(Exception):
    """A layer breaks the contract. The message names the file and the rule."""


class Unit:
    """Core or one layer: a root directory plus whatever it contributes."""

    def __init__(self, name: str, root: Path, manifest: Optional[Dict[str, Any]] = None):
        self.name = name
        self.root = root
        self.manifest = manifest or {}

    @property
    def is_core(self) -> bool:
        return self.name == "core"

    def registry(self) -> List[Dict[str, Any]]:
        path = self.root / "registry.json"
        if not path.is_file():
            return []
        try:
            data = json.loads(path.read_text())
        except ValueError as exc:
            raise LayerError("%s: not valid JSON (%s)" % (path, exc))
        hooks = data.get("hooks", [])
        if not isinstance(hooks, list):
            raise LayerError("%s: 'hooks' must be a list" % path)
        for entry in hooks:
            self._validate_entry(entry, path)
            entry["_unit"] = self.name
            entry["_root"] = str(self.root)
        return hooks

    def _validate_entry(self, entry: Dict[str, Any], path: Path) -> None:
        for field in ("id", "event", "runner", "script"):
            if not entry.get(field):
                raise LayerError("%s: hook entry missing '%s'" % (path, field))
        if entry["event"] not in EVENTS:
            raise LayerError("%s: unknown event %r in %s" % (path, entry["event"], entry["id"]))
        if entry["runner"] not in RUNNERS:
            raise LayerError("%s: runner must be one of %s" % (path, sorted(RUNNERS)))
        script = str(entry["script"])
        if script.startswith("/") or script.startswith("~"):
            raise LayerError(
                "%s: hook %s stores an absolute script path (%s). Registries are "
                "path-neutral; install.py resolves paths." % (path, entry["id"], script)
            )
        if not (self.root / script).is_file():
            raise LayerError("%s: hook %s names a missing script %s" % (path, entry["id"], script))
        if "command" in entry:
            raise LayerError(
                "%s: hook %s stores a 'command'. Use 'runner' plus 'script'." % (path, entry["id"])
            )

    def config_keys(self) -> List[Dict[str, Any]]:
        return list(self.manifest.get("config", []) or [])

    def requires(self) -> Dict[str, Any]:
        return dict(self.manifest.get("requires", {}) or {})

    def linkable(self) -> List[Tuple[str, Path]]:
        """Directories Claude Code discovers under ~/.claude, as (kind, path) pairs."""
        found = []
        for kind in LINKABLE:
            directory = self.root / kind
            if directory.is_dir():
                for child in sorted(directory.iterdir()):
                    if child.name.startswith("."):
                        continue
                    found.append((kind, child))
        return found


def discover(home: Path, selected: Optional[List[str]] = None) -> List[Unit]:
    """Core first, then each selected layer in the order it was named."""
    units = [Unit("core", home / "core")]
    layers_dir = home / "layers"
    available = {}
    if layers_dir.is_dir():
        for manifest_path in sorted(layers_dir.glob("*/layer.json")):
            try:
                manifest = json.loads(manifest_path.read_text())
            except ValueError as exc:
                raise LayerError("%s: not valid JSON (%s)" % (manifest_path, exc))
            name = manifest.get("name") or manifest_path.parent.name
            if name != manifest_path.parent.name:
                raise LayerError(
                    "%s: name %r does not match its directory %r"
                    % (manifest_path, name, manifest_path.parent.name)
                )
            available[name] = Unit(name, manifest_path.parent, manifest)

    for name in selected or []:
        if name == "core":
            continue
        if name not in available:
            raise LayerError(
                "unknown layer %r. Available: %s" % (name, ", ".join(sorted(available)) or "none")
            )
        units.append(available[name])
    return units


def available_layers(home: Path) -> List[str]:
    layers_dir = home / "layers"
    if not layers_dir.is_dir():
        return []
    return sorted(p.parent.name for p in layers_dir.glob("*/layer.json"))


def merge_registries(units: List[Unit], profile: str) -> Tuple[List[Dict[str, Any]], List[str]]:
    """Merge every unit's hooks. A later unit overriding an id is reported, not hidden."""
    if profile not in PROFILES:
        raise LayerError("unknown profile %r. Choose from %s" % (profile, ", ".join(PROFILES)))

    merged: Dict[str, Dict[str, Any]] = {}
    notes: List[str] = []
    for unit in units:
        for entry in unit.registry():
            hook_id = entry["id"]
            if hook_id in merged:
                previous = merged[hook_id]["_unit"]
                if previous == unit.name:
                    raise LayerError("%s declares hook id %r twice" % (unit.name, hook_id))
                notes.append("%s overrides %s's hook %r" % (unit.name, previous, hook_id))
            merged[hook_id] = entry

    selected = []
    for entry in merged.values():
        profiles = entry.get("profiles") or list(PROFILES)
        if entry.get("mandatory") or profile in profiles:
            selected.append(entry)
    selected.sort(key=lambda e: (e["event"], e["id"]))
    return selected, notes


def scan_absolute_paths(root: Path, skip: Tuple[str, ...] = (".git",)) -> List[Tuple[Path, int, str]]:
    """Every stored absolute home path under root. The core purity gate uses this."""
    hits = []
    pattern = re.compile(r"/(?:Users|home)/[A-Za-z0-9._-]+")
    for path in sorted(root.rglob("*")):
        if not path.is_file() or any(part in skip for part in path.parts):
            continue
        try:
            text = path.read_text()
        except (OSError, UnicodeDecodeError):
            continue
        for number, line in enumerate(text.splitlines(), 1):
            match = pattern.search(line)
            if match:
                hits.append((path, number, match.group(0)))
    return hits


if __name__ == "__main__":
    import sys

    home = Path(__file__).resolve().parents[2]
    names = sys.argv[1:] or available_layers(home)
    units = discover(home, names)
    hooks, notes = merge_registries(units, "standard")
    print("units:   %s" % ", ".join(u.name for u in units))
    print("hooks:   %d" % len(hooks))
    for note in notes:
        print("note:    %s" % note)
