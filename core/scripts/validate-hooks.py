#!/usr/bin/env python3
"""Check the generated settings.json against the merged hook registry.

The installer writes settings.json from the registry. That makes the two agree
at write time and says nothing about any moment after it: someone edits the file
by hand, a layer is added without a reinstall, or the script behind a wired
command is deleted and the hook becomes a command that fails silently on every
turn. Nothing reports any of that, so this does.

Four failures are caught:

  wired but unregistered  a hook command runs that no registry produces, so no
                          profile covers it and nothing here describes it
  registered but unwired  the registry selects a hook that settings.json does
                          not run, so the inventory overstates what is guarding
                          this machine
  missing script          a registry entry names a script that is not on disk
  dead interpreter        a wired command starts with an interpreter this
                          machine does not have, so the hook is a silent no-op

Read-only by construction: it opens files and never writes one, so it is safe in
CI and safe to run mid-incident. It replaces nothing the installer does; it is
the check that the installer's output still matches its input.

Usage:
    validate-hooks.py                     # check the live settings
    validate-hooks.py --profile minimal   # check against a different profile
    validate-hooks.py --settings PATH     # check a file somewhere else
    validate-hooks.py --layers a,b        # assume these layers are installed
    validate-hooks.py --quiet             # findings only, no clean-run summary

Exit codes: 0 clean, 1 findings, 2 a file was missing or unreadable.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import shlex
import sys
from pathlib import Path
from typing import Any, Dict, List, Tuple

LIB = Path(__file__).resolve().parents[1] / "lib"


def _load(name: str) -> Any:
    """Import a core library by path.

    By path rather than by `sys.path` insertion, because `layers` and `install`
    are ordinary words: a caller whose own package shadows one of them would get
    that module instead of this one, and the failure would be an AttributeError
    a long way from its cause.
    """
    spec = importlib.util.spec_from_file_location("harness_%s" % name, LIB / ("%s.py" % name))
    if spec is None or spec.loader is None:
        raise SystemExit("harness: cannot load %s from %s" % (name, LIB))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


cfg = _load("harness_config")
layer_lib = _load("layers")

DEFAULT_SETTINGS = Path.home() / ".claude" / "settings.json"


def wired_commands(settings: Dict[str, Any]) -> List[Tuple[str, str]]:
    """Every (event, command) settings.json would run, in file order."""
    found: List[Tuple[str, str]] = []
    hooks = settings.get("hooks")
    if not isinstance(hooks, dict):
        return found
    for event, blocks in hooks.items():
        if not isinstance(blocks, list):
            continue
        for block in blocks:
            if not isinstance(block, dict):
                continue
            for hook in block.get("hooks", []) or []:
                if isinstance(hook, dict) and hook.get("command"):
                    found.append((event, str(hook["command"])))
    return found


def expected_commands(home: Path, layer_names: List[str], profile: str):
    """Every (event, script path) the merged registry selects for this profile."""
    units = layer_lib.discover(home, layer_names)
    entries, notes = layer_lib.merge_registries(units, profile)
    expected = []
    for entry in entries:
        script = Path(entry["_root"]) / entry["script"]
        expected.append((entry["event"], entry["id"], entry["_unit"], entry["runner"], script))
    return expected, notes


def split_command(command: str) -> Tuple[str, str]:
    """A wired command as (interpreter, script).

    shlex, not str.split: the installer writes the path bare but a hand-edited
    settings.json quotes it and may append an argument, and a quoted path that
    fails to match reads as "wired but unregistered" for a hook that is wired
    correctly. A command shlex cannot parse yields empty strings, which the
    caller reports rather than crashing on.
    """
    try:
        parts = shlex.split(command)
    except ValueError:
        return "", ""
    if not parts:
        return "", ""
    return parts[0], (parts[1] if len(parts) > 1 else "")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--settings", default=None, help="settings.json to check")
    parser.add_argument("--profile", default=None, help="minimal, standard or strict")
    parser.add_argument("--layers", default=None, help="comma-separated layers to assume")
    parser.add_argument("--quiet", action="store_true", help="print findings only")
    args = parser.parse_args()

    home = cfg.harness_home()
    settings_path = Path(args.settings).expanduser() if args.settings else DEFAULT_SETTINGS
    if not settings_path.is_file():
        print("no settings file at %s" % settings_path, file=sys.stderr)
        return 2
    try:
        settings = json.loads(settings_path.read_text())
    except (OSError, ValueError) as exc:
        print("%s is not readable JSON: %s" % (settings_path, exc), file=sys.stderr)
        return 2
    if not isinstance(settings, dict):
        print("%s is not a JSON object" % settings_path, file=sys.stderr)
        return 2

    if args.layers is not None:
        names = [n.strip() for n in args.layers.split(",") if n.strip()]
    else:
        names = layer_lib.available_layers(home)
    profile = args.profile or cfg.get("HARNESS_PROFILE", home) or "standard"

    try:
        expected, notes = expected_commands(home, names, profile)
    except layer_lib.LayerError as exc:
        print("registry is invalid: %s" % exc, file=sys.stderr)
        return 2

    # Compared as real paths on both sides. On macOS /tmp and /var are symlinks,
    # and harness_home() resolves them while a command written from an
    # unresolved path does not, so a clone reached through any symlinked
    # directory would report every hook it correctly wired as drift.
    wired = wired_commands(settings)
    wired_scripts = {os.path.realpath(split_command(command)[1]) for _, command in wired}
    expected_scripts = {os.path.realpath(str(script)) for _, _, _, _, script in expected}

    findings: Dict[str, List[str]] = {
        "wired but unregistered": [],
        "registered but unwired": [],
        "missing script": [],
        "dead interpreter": [],
    }

    for event, command in wired:
        interpreter, script = split_command(command)
        if os.path.realpath(script) not in expected_scripts:
            findings["wired but unregistered"].append("%s  %s" % (event, command))
        if interpreter and os.path.isabs(interpreter) and not os.path.exists(interpreter):
            findings["dead interpreter"].append("%s  %s" % (event, interpreter))

    for event, hook_id, unit, runner, script in expected:
        if os.path.realpath(str(script)) not in wired_scripts:
            findings["registered but unwired"].append(
                "%s  %s (%s) is in the %s profile and is not wired" % (event, hook_id, unit, profile)
            )
        if not script.is_file():
            findings["missing script"].append("%s  %s names %s" % (event, hook_id, script))

    total = sum(len(v) for v in findings.values())

    if not args.quiet:
        print("settings: %s" % settings_path)
        print("clone:    %s" % home)
        print("layers:   %s" % (", ".join(names) if names else "none"))
        print("profile:  %s" % profile)
        print("wired:    %d command(s)" % len(wired))
        print("expected: %d hook(s)" % len(expected))
        for note in notes:
            print("note:     %s" % note)

    for category, hits in findings.items():
        if hits or not args.quiet:
            print("\n%-24s %d" % (category, len(hits)))
        for hit in hits:
            print("  %s" % hit)

    if total:
        print("\nFAIL: %d finding(s). Run ./install.sh to regenerate, or fix the registry." % total)
        return 1
    if not args.quiet:
        print("\nPASS: settings.json matches the merged registry.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
