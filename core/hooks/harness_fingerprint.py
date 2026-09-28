#!/usr/bin/env python3
"""One digest over the harness state a benchmark run describes.

`harness-bench.py` records this with every stored run, and the Stop gate
recompares it. They must compute it identically or the gate fires on noise, so
it lives in one module both import rather than in two copies that agree until
someone edits one.

What counts: the generated settings.json, which decides what runs and on what;
every unit's hook registry, which says what those hooks are meant to be; and
every hook and guard source file in the clone. A change to any of them makes an
earlier measurement a description of a harness that no longer exists.

What does not: test files. Editing a test changes no hook's cost, and a gate
that fires on a test edit is a gate people learn to click past.

Three environment seams exist so a test can point the whole thing at a fixture
tree and never read the installed harness: HARNESS_BENCH_SETTINGS,
HARNESS_BENCH_HOOKS and HARNESS_BENCH_REGISTRY. They are test seams, not
configuration; the values a user sets are declared keys read through
harness_config.
"""

from __future__ import annotations

import hashlib
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))

import harness_config  # type: ignore[import-not-found]  # noqa: E402

SOURCE_SUFFIXES = (".py", ".sh")
SKIP_PARTS = ("__pycache__", "tests")


def _override(name: str) -> Path | None:
    """Return a test seam's path, or None when it is unset."""
    raw = os.environ.get(name)
    return Path(raw).expanduser() if raw else None


def settings_path() -> Path:
    """The settings.json the installer generated for this machine."""
    return _override("HARNESS_BENCH_SETTINGS") or Path.home() / ".claude" / "settings.json"


def units() -> list[Path]:
    """Core first, then every layer directory present in the clone.

    Discovery is by shape, never by name: a directory under the clone's layer
    root that carries a manifest is a unit. Core naming one would break the
    contract it is held to.
    """
    home = Path(harness_config.harness_home())
    found = [home / "core"]
    root = home / "layers"
    if root.is_dir():
        for child in sorted(root.iterdir()):
            if (child / "layer.json").is_file():
                found.append(child)
    return found


def hook_dirs() -> list[Path]:
    """Every directory holding hook source, or the one a test seam names."""
    seam = _override("HARNESS_BENCH_HOOKS")
    if seam:
        return [seam]
    return [unit / "hooks" for unit in units() if (unit / "hooks").is_dir()]


def registries() -> list[Path]:
    """Every registry the installer merges, or the one a test seam names."""
    seam = _override("HARNESS_BENCH_REGISTRY")
    if seam:
        return [seam]
    return [unit / "registry.json" for unit in units() if (unit / "registry.json").is_file()]


def sources() -> list[Path]:
    """Return every file the fingerprint covers, in a stable order."""
    found = [settings_path()]
    found += registries()
    for directory in hook_dirs():
        for child in sorted(directory.rglob("*")):
            if not child.is_file() or child.suffix not in SOURCE_SUFFIXES:
                continue
            if any(part in SKIP_PARTS for part in child.parts):
                continue
            found.append(child)
    return found


def is_harness_path(candidate: str) -> bool:
    """Report whether one written path is part of the state this digest covers.

    The Stop gate asks this rather than carrying its own idea of what the
    harness is. One definition means the gate can never fire on a file the
    fingerprint ignores, nor stay silent on one it watches.
    """
    try:
        target = Path(candidate).expanduser().resolve()
    except (OSError, RuntimeError, ValueError):
        return False
    if any(part in SKIP_PARTS for part in target.parts):
        return False
    if _same(target, settings_path()):
        return True
    if any(_same(target, path) for path in registries()):
        return True
    if target.suffix not in SOURCE_SUFFIXES:
        return False
    return any(_under(target, directory) for directory in hook_dirs())


def _same(target: Path, other: Path) -> bool:
    """Compare two paths by their resolved form, symlinks included."""
    try:
        return target == other.expanduser().resolve()
    except (OSError, RuntimeError, ValueError):
        return False


def _under(target: Path, directory: Path) -> bool:
    """Report whether target sits inside directory, after resolution."""
    try:
        resolved = directory.expanduser().resolve()
    except (OSError, RuntimeError, ValueError):
        return False
    return resolved in target.parents


def fingerprint() -> str:
    """Return the SHA-256 over the harness state, names and contents."""
    digest = hashlib.sha256()
    for path in sources():
        digest.update(str(path).encode())
        try:
            digest.update(path.read_bytes())
        except OSError:
            digest.update(b"<unreadable>")
    return digest.hexdigest()


if __name__ == "__main__":
    print(fingerprint())
