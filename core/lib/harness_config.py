#!/usr/bin/env python3
"""Resolve harness configuration keys for hooks, scripts and the installer.

One resolution order, used everywhere, so a default can never be bypassed by a
hook that reads os.environ directly:

    1. an environment variable of the same name
    2. harness.config.json in the clone root
    3. the key's declared default

A key that no unit declares is an error rather than an empty string, because a
typo in a hook otherwise reads as "not configured" and silently disables it.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any, Dict, Optional

CONFIG_FILENAME = "harness.config.json"

# Keys core itself declares. A layer adds its own through its layer.json.
CORE_KEYS: Dict[str, Dict[str, Any]] = {
    "HARNESS_HOME": {
        "description": "Absolute path to this clone. Resolved, never set by hand.",
        "required": False,
        "default": None,
    },
    "HARNESS_WORKSPACE": {
        "description": "Where session journals, lane records and batch state are written.",
        "required": False,
        "default": "~/.swe-harness",
    },
    "HARNESS_PROFILE": {
        "description": "Which hook profile to install: minimal, standard or strict.",
        "required": False,
        "default": "standard",
    },
    "HARNESS_EDITOR": {
        "description": "Editor the harness scripts open.",
        "required": False,
        "default": None,
    },
    "PYTHON_CHECKS_RUNNER": {
        "description": (
            "Optional extra Python checks script the PostToolUse lint hook runs "
            "as `<python> <script> <file>`. Unset means ruff and mypy only."
        ),
        "required": False,
        "default": None,
    },
}


def harness_home() -> Path:
    """The clone root, found from this file rather than from the caller's cwd."""
    env = os.environ.get("HARNESS_HOME")
    if env:
        return Path(env).expanduser().resolve()
    return Path(__file__).resolve().parents[2]


def _file_config(home: Optional[Path] = None) -> Dict[str, Any]:
    path = (home or harness_home()) / CONFIG_FILENAME
    if not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def declared_keys(home: Optional[Path] = None) -> Dict[str, Dict[str, Any]]:
    """Core's keys plus every key declared by a layer present in the clone."""
    keys = dict(CORE_KEYS)
    layers_dir = (home or harness_home()) / "layers"
    if not layers_dir.is_dir():
        return keys
    for manifest in sorted(layers_dir.glob("*/layer.json")):
        try:
            data = json.loads(manifest.read_text())
        except (OSError, ValueError):
            continue
        for entry in data.get("config", []) or []:
            key = entry.get("key")
            if key:
                keys[key] = {
                    "description": entry.get("description", ""),
                    "required": bool(entry.get("required", False)),
                    "default": entry.get("default"),
                    "layer": data.get("name", manifest.parent.name),
                }
    return keys


def get(key: str, home: Optional[Path] = None) -> Optional[str]:
    """Resolve one key. Raises KeyError when nothing declares it."""
    home = home or harness_home()
    keys = declared_keys(home)
    if key not in keys:
        raise KeyError("undeclared harness config key: %s" % key)

    if key == "HARNESS_HOME":
        return str(home)

    value = os.environ.get(key)
    if value:
        return _expand(value)

    file_value = _file_config(home).get(key)
    if file_value:
        return _expand(str(file_value))

    default = keys[key].get("default")
    if key == "HARNESS_EDITOR" and not default:
        return os.environ.get("EDITOR") or "vi"
    return _expand(str(default)) if default else None


def require(key: str, home: Optional[Path] = None) -> str:
    """Resolve one key, or fail loudly naming the key and how to set it."""
    value = get(key, home)
    if not value:
        raise SystemExit(
            "harness: %s is not set. Export it, or add it to %s."
            % (key, (home or harness_home()) / CONFIG_FILENAME)
        )
    return value


def workspace(home: Optional[Path] = None) -> Path:
    """HARNESS_WORKSPACE as a directory that exists."""
    path = Path(require("HARNESS_WORKSPACE", home)).expanduser()
    path.mkdir(parents=True, exist_ok=True)
    return path


def _expand(value: str) -> str:
    return os.path.expanduser(os.path.expandvars(value))


if __name__ == "__main__":
    import sys

    if len(sys.argv) == 2:
        resolved = get(sys.argv[1])
        print(resolved if resolved is not None else "")
    else:
        for name in sorted(declared_keys()):
            print("%-24s %s" % (name, get(name) or ""))
