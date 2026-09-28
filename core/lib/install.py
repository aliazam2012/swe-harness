#!/usr/bin/env python3
"""Install the harness: generate settings.json for THIS machine, then link what
Claude Code discovers by directory.

Dry run by default. Nothing is written without --write, and every file that is
replaced is backed up first. --uninstall reverses exactly what the recorded
manifest says this installer did, and touches nothing else.

The one job that matters: a hook entry in a registry names a script by a relative
path, and this resolves it against the clone and against the interpreter found on
this machine. Claude Code does not expand ~ in a hook command, so a stored path is
the difference between a working clone and a silent no-op.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))

import harness_config as cfg  # noqa: E402
import layers as layer_lib  # noqa: E402

CREDENTIAL = re.compile(
    r"xox[baprs]-[A-Za-z0-9-]{10,}"
    r"|ghp_[A-Za-z0-9]{20,}"
    r"|sk-[A-Za-z0-9]{20,}"
    r"|AKIA[0-9A-Z]{16}"
    r"|-----BEGIN [A-Z ]*PRIVATE KEY-----"
)

CLAUDE_DIR = Path.home() / ".claude"
SETTINGS = CLAUDE_DIR / "settings.json"
MANIFEST_NAME = "install-manifest.json"
STAMP = time.strftime("%Y%m%d-%H%M%S")


# Stable launchers that keep working across an upgrade, most specific first.
STABLE_PYTHONS = (
    "/opt/homebrew/bin/python3",
    "/usr/local/bin/python3",
    "/usr/bin/python3",
)


def _stable_python() -> str:
    """A path to this interpreter that survives a package upgrade.

    sys.executable on Homebrew is version-pinned, for example
    /opt/homebrew/opt/python@3.14/bin/python3.14. Baking that into
    settings.json means a routine `brew upgrade` deletes the path and every
    python hook silently stops running, which is the exact failure this whole
    design exists to prevent. If a generic launcher resolves to the same
    interpreter, that is what gets written.
    """
    running = (sys.base_prefix, sys.version_info[:2])
    for candidate in STABLE_PYTHONS:
        if not os.path.exists(candidate):
            continue
        try:
            out = subprocess.run(
                [candidate, "-c", "import sys;print(sys.base_prefix);print('%d.%d' % sys.version_info[:2])"],
                capture_output=True, text=True, timeout=10, check=False,
            )
        except (OSError, subprocess.SubprocessError):
            continue
        lines = out.stdout.strip().splitlines()
        if len(lines) != 2:
            continue
        major, _, minor = lines[1].partition(".")
        try:
            version = (int(major), int(minor))
        except ValueError:
            continue
        if (lines[0], version) == running:
            return candidate
    return sys.executable


def interpreter(runner: str) -> str:
    """Absolute path to the interpreter on this machine, or fail naming it."""
    if runner == "python3":
        return _stable_python()
    found = shutil.which(runner)
    if not found:
        raise SystemExit("harness: required interpreter %r is not on PATH" % runner)
    return found


def build_hooks(entries: List[Dict[str, Any]]) -> Dict[str, List[Dict[str, Any]]]:
    """Registry entries into the shape Claude Code's settings.json expects."""
    events: Dict[str, Dict[Optional[str], List[Dict[str, Any]]]] = {}
    for entry in entries:
        script = Path(entry["_root"]) / entry["script"]
        command = "%s %s" % (interpreter(entry["runner"]), script)
        matcher = entry.get("matcher")
        events.setdefault(entry["event"], {}).setdefault(matcher, []).append(
            {"type": "command", "command": command, "timeout": entry.get("timeout", 10)}
        )

    built: Dict[str, List[Dict[str, Any]]] = {}
    for event, by_matcher in sorted(events.items()):
        blocks = []
        for matcher, hooks in by_matcher.items():
            block: Dict[str, Any] = {}
            if matcher:
                block["matcher"] = matcher
            block["hooks"] = hooks
            blocks.append(block)
        built[event] = blocks
    return built


def check_requirements(units: List[layer_lib.Unit]) -> List[str]:
    required, optional = set(), set()
    for unit in units:
        requires = unit.requires()
        required.update(requires.get("binaries", []) or [])
        optional.update(requires.get("optional_binaries", []) or [])

    missing = sorted(b for b in required if not shutil.which(b))
    if missing:
        raise SystemExit(
            "harness: missing required %s: %s" % ("binary" if len(missing) == 1 else "binaries", ", ".join(missing))
        )
    return sorted(b for b in optional - required if not shutil.which(b))


def resolve_config(home: Path, units: List[layer_lib.Unit]) -> Dict[str, str]:
    resolved, missing = {}, []
    for unit in units:
        for entry in unit.config_keys():
            key = entry.get("key")
            if not key:
                continue
            value = cfg.get(key, home)
            if not value and entry.get("required"):
                missing.append((key, unit.name, entry.get("description", "")))
            elif value:
                resolved[key] = value
    if missing:
        lines = ["harness: required configuration is not set."]
        for key, unit, description in missing:
            lines.append("  %-22s (%s) %s" % (key, unit, description))
        lines.append("")
        lines.append("Set each one in %s, or export it, then run again." % (home / cfg.CONFIG_FILENAME))
        raise SystemExit("\n".join(lines))

    # CONTRACT.md promises the installer refuses to write a credential. These
    # values land in settings.json, so the promise has to be enforced here.
    leaked = sorted(key for key, value in resolved.items() if CREDENTIAL.search(value))
    if leaked:
        raise SystemExit(
            "harness: refusing to write a credential into %s.\n"
            "  %s\n"
            "A configuration key holds a path, a host or an identifier. A secret belongs in a\n"
            "secret manager, and the key should name where to find it." % (SETTINGS, ", ".join(leaked))
        )
    return resolved


def plan_links(units: List[layer_lib.Unit]) -> List[Dict[str, str]]:
    links, seen = [], {}
    for unit in units:
        for kind, source in unit.linkable():
            destination = CLAUDE_DIR / kind / source.name
            if source.name in seen.get(kind, {}):
                links.append(
                    {
                        "kind": kind,
                        "source": str(source),
                        "destination": str(destination),
                        "unit": unit.name,
                        "overrides": seen[kind][source.name],
                    }
                )
            else:
                links.append(
                    {"kind": kind, "source": str(source), "destination": str(destination), "unit": unit.name}
                )
            seen.setdefault(kind, {})[source.name] = unit.name
    return links


def backup(path: Path) -> Optional[str]:
    """Copy what is AT path, following a symlink to its content.

    follow_symlinks=False copied the link itself, so backing up a symlinked
    settings.json produced a second symlink to the same file: worthless from
    the moment it was made, and restoring from it raised SameFileError after
    uninstall had already removed every link. ~/.claude/settings.json is a
    symlink into a dotfiles repository on a normal setup, so this was the
    common case, not the edge case.
    """
    if not path.exists() and not path.is_symlink():
        return None
    target = path.with_name("%s.harness-bak-%s" % (path.name, STAMP))
    if path.is_symlink() and not path.exists():
        return None  # a dangling link has no content worth keeping
    shutil.copy2(str(path), str(target))  # follows the link: real content
    return str(target)


def _settings_target() -> Path:
    """The real file to write. A symlink is followed so the user keeps it."""
    return SETTINGS.resolve() if SETTINGS.is_symlink() else SETTINGS


def _restore(saved: str, destination: Path) -> None:
    """Put backed-up content back without tripping over a symlink."""
    content = Path(saved).read_text()
    destination.write_text(content)


def write_settings(
    hooks: Dict[str, Any], env: Dict[str, str], write: bool
) -> Tuple[Optional[str], bool, List[str]]:
    """Returns (backup path, whether settings.json pre-existed, env keys written).

    The resolved configuration was previously computed, printed and thrown away,
    so a ${KEY} token in a skill or a hook resolved for nobody. It is written
    into settings.json's env block, which is what puts it in the session's
    environment. A key the user already set by hand wins, because their value is
    a deliberate override of ours.
    """
    existed = SETTINGS.is_file()
    existing: Dict[str, Any] = {}
    if SETTINGS.is_file():
        try:
            existing = json.loads(SETTINGS.read_text())
        except ValueError:
            raise SystemExit("harness: %s is not valid JSON. Fix or move it, then run again." % SETTINGS)

    updated = dict(existing)
    updated["hooks"] = hooks

    existing_env = dict(existing.get("env") or {})
    written_keys = sorted(k for k in env if k not in existing_env)
    merged_env = dict(existing_env)
    for key in written_keys:
        merged_env[key] = env[key]
    if merged_env:
        updated["env"] = merged_env

    rendered = json.dumps(updated, indent=2) + "\n"

    if not write:
        return None, existed, written_keys
    saved = backup(SETTINGS)
    CLAUDE_DIR.mkdir(parents=True, exist_ok=True)
    temporary = SETTINGS.with_name(SETTINGS.name + ".harness-tmp")
    temporary.write_text(rendered)
    os.replace(str(temporary), str(_settings_target()))
    return saved, existed, written_keys


def apply_links(links: List[Dict[str, str]], write: bool) -> List[Dict[str, str]]:
    """Link what is not linked, and record everything this harness owns.

    The manifest records ownership, not actions. An earlier version appended only
    the links it newly created, so a second install skipped the ones already
    correct and dropped them from the manifest, and uninstall then left them
    behind. A link that is already right is still ours to remove.
    """
    owned = []
    for link in links:
        source, destination = Path(link["source"]), Path(link["destination"])
        record = {"destination": str(destination), "source": str(source)}

        if destination.is_symlink() and os.readlink(str(destination)) == str(source):
            link["state"] = "already linked"
            owned.append(record)
            continue
        if destination.exists() and not destination.is_symlink():
            link["state"] = "blocked: a real file or directory is in the way"
            continue

        link["state"] = "link"
        if write:
            destination.parent.mkdir(parents=True, exist_ok=True)
            saved = backup(destination) if destination.is_symlink() else None
            if destination.is_symlink():
                destination.unlink()
            destination.symlink_to(source)
            if saved:
                record["backup"] = saved
            owned.append(record)
    return owned


def read_manifest(home: Path) -> Dict[str, Any]:
    path = cfg.workspace(home) / MANIFEST_NAME
    if not path.is_file():
        return {}
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def record_manifest(home: Path, data: Dict[str, Any], write: bool) -> Path:
    """Persist what to undo, carrying the original pre-harness state forward.

    The manifest used to describe the last run. A second --write, which is what
    adding a layer or pulling an update looks like, therefore recorded the
    harness's own settings.json as the thing to restore, and uninstall put the
    harness back instead of removing it. Undo has to point at the state before
    the FIRST install, so that state is carried across every later run.
    """
    path = cfg.workspace(home) / MANIFEST_NAME
    if write:
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(path.name + ".tmp")
        temporary.write_text(json.dumps(data, indent=2) + "\n")
        os.replace(str(temporary), str(path))
    return path


def uninstall(home: Path, write: bool) -> int:
    path = cfg.workspace(home) / MANIFEST_NAME
    if not path.is_file():
        print("harness: no install manifest at %s. Nothing recorded to undo." % path)
        return 1
    data = json.loads(path.read_text())

    recorded = data.get("links", [])
    print("Removing %d link(s) this installer owns:" % len(recorded))
    for link in recorded:
        destination = Path(link["destination"])
        if not destination.is_symlink():
            print("  skip   %s (not a symlink any more)" % destination)
            continue
        if os.readlink(str(destination)) != link["source"]:
            print("  skip   %s (repointed elsewhere; not ours to remove)" % destination)
            continue
        print("  unlink %s" % destination)
        if write:
            destination.unlink()

    saved = data.get("settings_backup")
    if saved and Path(saved).is_file():
        print("Restoring %s from %s" % (SETTINGS, saved))
        if write:
            _restore(saved, _settings_target())
    elif not data.get("settings_existed", True) and SETTINGS.is_file():
        # We created the file. Take back only the hooks we wrote; anything the
        # user added since is theirs, so the file only goes if nothing is left.
        current = json.loads(SETTINGS.read_text())
        current.pop("hooks", None)
        env_block = current.get("env") or {}
        for key in data.get("env_keys", []):
            env_block.pop(key, None)
        if env_block:
            current["env"] = env_block
        else:
            current.pop("env", None)
        if current:
            print("Removing the hooks this harness wrote from %s" % SETTINGS)
            if write:
                SETTINGS.write_text(json.dumps(current, indent=2) + "\n")
        else:
            print("Removing %s, which this harness created" % SETTINGS)
            if write:
                SETTINGS.unlink()
    else:
        print("No settings backup recorded. %s left as it is." % SETTINGS)

    if write:
        path.unlink()
        print("\nUninstalled.")
    else:
        print("\nDry run. Nothing was changed. Add --write to apply.")
    return 0


def main(argv: Optional[List[str]] = None) -> int:
    home = cfg.harness_home()
    parser = argparse.ArgumentParser(prog="install.sh", description=__doc__.splitlines()[0])
    parser.add_argument("--layers", default="", help="comma-separated layers to install on top of core")
    parser.add_argument("--profile", default=None, choices=list(layer_lib.PROFILES))
    parser.add_argument("--write", action="store_true", help="apply the plan (default is a dry run)")
    parser.add_argument("--uninstall", action="store_true")
    parser.add_argument("--list-layers", action="store_true")
    args = parser.parse_args(argv)

    if args.list_layers:
        found = layer_lib.available_layers(home)
        print("\n".join(found) if found else "no layers found under %s" % (home / "layers"))
        return 0

    if args.uninstall:
        return uninstall(home, args.write)

    selected = [name for name in args.layers.split(",") if name.strip()]
    units = layer_lib.discover(home, selected)
    profile = args.profile or cfg.get("HARNESS_PROFILE", home) or "standard"

    print("harness %s" % (home / "core" / "VERSION").read_text().strip())
    print("clone:   %s" % home)
    print("units:   %s" % ", ".join(u.name for u in units))
    print("profile: %s" % profile)
    print("python:  %s (%s)" % (sys.executable, "%d.%d.%d" % sys.version_info[:3]))
    if sys.prefix != sys.base_prefix:
        print(
            "         WARNING: this is a virtualenv. Every hook command would point\n"
            "         into it, and would break when it is rebuilt. Deactivate and rerun."
        )
    print()

    degraded = check_requirements(units)
    resolved = resolve_config(home, units)
    entries, notes = layer_lib.merge_registries(units, profile)
    hooks = build_hooks(entries)
    links = plan_links(units)

    print("Hooks: %d across %d event(s)" % (len(entries), len(hooks)))
    for entry in entries:
        print("  %-14s %-26s %s" % (entry["event"], entry["id"], entry["_unit"]))
    for note in notes:
        print("  note: %s" % note)

    print("\nLinks into ~/.claude: %d" % len(links))
    by_kind: Dict[str, int] = {}
    for link in links:
        by_kind[link["kind"]] = by_kind.get(link["kind"], 0) + 1
    for kind, count in sorted(by_kind.items()):
        print("  %-10s %d" % (kind, count))

    if resolved:
        print("\nConfiguration:")
        for key in sorted(resolved):
            print("  %-22s %s" % (key, resolved[key]))
    if degraded:
        print("\nOptional binaries not found. The features that use them stay quiet:")
        print("  %s" % ", ".join(degraded))

    if not args.write:
        print("\nDry run. Nothing was changed.")
        print("Apply with:  ./install.sh%s --write" % (" --layers " + args.layers if args.layers else ""))
        return 0

    # An earlier manifest holds the only record of what this machine looked
    # like before the harness touched it. That is what uninstall must restore,
    # so it survives every later run.
    prior = read_manifest(home)
    saved, existed, env_keys = write_settings(hooks, resolved, True)
    if prior:
        saved = prior.get("settings_backup", saved)
        existed = prior.get("settings_existed", existed)
        env_keys = sorted(set(env_keys) | set(prior.get("env_keys", [])))

    # Written before the links so a crash midway still leaves an undoable
    # record. Previously a failure here left settings.json rewritten with no
    # manifest at all, and uninstall then refused to do anything.
    manifest = record_manifest(
        home,
        {
            "installed_at": STAMP,
            "harness_home": str(home),
            "units": [u.name for u in units],
            "profile": profile,
            "settings_backup": saved,
            "settings_existed": existed,
            "env_keys": env_keys,
            "links": [],
        },
        True,
    )
    applied = apply_links(links, True)
    blocked = [l for l in links if l.get("state", "").startswith("blocked")]
    known = {l["destination"]: l for l in prior.get("links", [])}
    for link in applied:
        known[link["destination"]] = link
    record_manifest(
        home,
        {
            "installed_at": STAMP,
            "harness_home": str(home),
            "units": [u.name for u in units],
            "profile": profile,
            "settings_backup": saved,
            "settings_existed": existed,
            "env_keys": env_keys,
            "links": sorted(known.values(), key=lambda l: l["destination"]),
        },
        True,
    )

    print("\nWrote %s (%d hooks, %d env key(s))" % (SETTINGS, len(entries), len(env_keys)))
    if saved:
        print("Backed up the previous settings to %s" % saved)
    print("Linked %d item(s) into ~/.claude (%d owned in total)" % (
        sum(1 for l in links if l.get("state") == "link"), len(applied)))
    for link in blocked:
        print("  skipped %s: %s" % (link["destination"], link["state"]))
    print("Manifest: %s" % manifest)
    print("\nUndo with:  ./install.sh --uninstall --write")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except layer_lib.LayerError as exc:
        # A malformed layer is a user mistake, and a traceback tells the user
        # nothing they can act on.
        raise SystemExit("harness: %s" % exc)
    except KeyboardInterrupt:
        raise SystemExit("harness: interrupted. Nothing further was written.")
