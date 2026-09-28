#!/usr/bin/env python3
"""Tests for core/lib/layers.py: what the contract refuses, and what it reports.

Each case writes a throwaway clone under a temporary directory. HOME is
repointed at a sandbox for the whole run, so nothing here can touch the real
one.

Two properties carry the whole design and are the reason this file exists.

A registry may not store an absolute path. The installer resolves `runner` plus
`script` against this machine at write time, and that is the single reason a
clone works on someone else's. A stored path would still install, still look
right in the diff, and silently do nothing on the second machine, so the refusal
has to be tested rather than assumed.

An override must be reported. A layer that reuses a core hook id replaces it,
which is a feature; an override nobody is told about is how a guard disappears.
"""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import tempfile
from pathlib import Path

CORE = Path(__file__).resolve().parents[1]


def load(name):
    """Import a core library by path, so nothing on sys.path can shadow it."""
    spec = importlib.util.spec_from_file_location("t_%s" % name, CORE / "lib" / ("%s.py" % name))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


lib = load("layers")

PASSED = 0
FAILED = 0


def check(name, got, want):
    global PASSED, FAILED
    if got == want:
        print("  ok   %s" % name)
        PASSED += 1
    else:
        print("  FAIL %s (want %r, got %r)" % (name, want, got))
        FAILED += 1


def refuses(name, call, must_say=None):
    """The call raises LayerError, and its message names the rule."""
    global PASSED, FAILED
    try:
        call()
    except lib.LayerError as exc:
        if must_say and must_say not in str(exc):
            print("  FAIL %s (message %r does not mention %r)" % (name, str(exc)[:80], must_say))
            FAILED += 1
            return
        print("  ok   %s" % name)
        PASSED += 1
        return
    except Exception as exc:  # noqa: BLE001 - a different exception is a different bug
        print("  FAIL %s (raised %s: %s)" % (name, type(exc).__name__, str(exc)[:60]))
        FAILED += 1
        return
    print("  FAIL %s (raised nothing)" % name)
    FAILED += 1


def hook(**overrides):
    entry = {
        "id": "example",
        "description": "one line",
        "event": "Stop",
        "matcher": None,
        "runner": "python3",
        "script": "hooks/example.py",
        "timeout": 10,
        "profiles": ["standard", "strict"],
        "mandatory": False,
    }
    entry.update(overrides)
    return entry


def write_unit(root: Path, hooks, scripts=("hooks/example.py",), manifest=None):
    """A unit directory: a registry, the scripts it names, and a manifest."""
    root.mkdir(parents=True, exist_ok=True)
    for relative in scripts:
        target = root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("# a hook\n")
    (root / "registry.json").write_text(json.dumps({"version": 1, "hooks": hooks}))
    if manifest is not None:
        (root / "layer.json").write_text(json.dumps(manifest))
    return root


def make_clone(sandbox: Path, name: str, core_hooks=None, layers=None) -> Path:
    home = sandbox / name
    write_unit(home / "core", core_hooks if core_hooks is not None else [])
    for layer_name, spec in (layers or {}).items():
        write_unit(
            home / "layers" / layer_name,
            spec.get("hooks", []),
            spec.get("scripts", ("hooks/example.py",)),
            spec.get("manifest", {"name": layer_name, "description": "a layer"}),
        )
    return home


def main() -> int:
    sandbox = Path(tempfile.mkdtemp(prefix="harness-layers-test-"))
    real_home = os.environ.get("HOME")
    os.environ["HOME"] = str(sandbox / "home")
    (sandbox / "home").mkdir()
    try:
        return run(sandbox)
    finally:
        if real_home is not None:
            os.environ["HOME"] = real_home
        shutil.rmtree(str(sandbox), ignore_errors=True)


def run(sandbox: Path) -> int:
    print("the sandbox itself")
    check("HOME is not the real one", os.environ["HOME"].startswith(str(sandbox)), True)

    # Assembled from parts, never written out: the purity gate scans this file
    # too, and a stored home path in a test reads exactly like a stored home
    # path in a hook.
    home_root = "/" + "Users" + "/someone"
    print("\na registry may not store an absolute path")
    for stored in (home_root + "/.claude/hooks/example.py", "~/.claude/hooks/example.py"):
        home = make_clone(sandbox / ("abs-" + stored[1:3]), "c", core_hooks=[hook(script=stored)])
        unit = lib.Unit("core", home / "core")
        refuses("%s is refused" % stored, unit.registry, "absolute script path")

    print("\nand may not store a resolved command")
    home = make_clone(sandbox, "cmd", core_hooks=[hook(command="python3 hooks/example.py")])
    refuses("a 'command' field is refused",
            lib.Unit("core", home / "core").registry, "Use 'runner' plus 'script'")

    print("\nevery field is checked before anything runs")
    home = make_clone(sandbox, "event", core_hooks=[hook(event="OnTuesday")])
    refuses("an unknown event is refused",
            lib.Unit("core", home / "core").registry, "unknown event")

    home = make_clone(sandbox, "runner", core_hooks=[hook(runner="perl")])
    refuses("an unknown runner is refused",
            lib.Unit("core", home / "core").registry, "runner must be one of")

    home = make_clone(sandbox, "noid", core_hooks=[hook(id="")])
    refuses("a missing id is refused",
            lib.Unit("core", home / "core").registry, "missing 'id'")

    home = make_clone(sandbox, "missing", core_hooks=[hook(script="hooks/gone.py")])
    refuses("a script that is not on disk is refused",
            lib.Unit("core", home / "core").registry, "missing script")

    home = make_clone(sandbox, "dupe", core_hooks=[hook(), hook()])
    refuses("one unit declaring an id twice is refused",
            lambda: lib.merge_registries([lib.Unit("core", home / "core")], "standard"),
            "twice")

    print("\na valid registry loads")
    home = make_clone(sandbox, "good", core_hooks=[hook()])
    entries = lib.Unit("core", home / "core").registry()
    check("one entry", len(entries), 1)
    check("it is stamped with its unit", entries[0]["_unit"], "core")
    check("and with its root", entries[0]["_root"], str(home / "core"))

    print("\na layer overriding a core hook is reported, not hidden")
    home = make_clone(
        sandbox, "override",
        core_hooks=[hook(id="done-gate", script="hooks/example.py")],
        layers={"acme": {"hooks": [hook(id="done-gate", script="hooks/example.py")]}},
    )
    units = lib.discover(home, ["acme"])
    check("core first, then the layer", [u.name for u in units], ["core", "acme"])
    entries, notes = lib.merge_registries(units, "standard")
    check("the id appears once", len(entries), 1)
    check("the layer's copy won", entries[0]["_unit"], "acme")
    check("one note", len(notes), 1)
    check("the note names both units and the id",
          "acme overrides core's hook 'done-gate'" in notes[0], True)

    print("\ntwo layers that do not collide both load")
    home = make_clone(
        sandbox, "two",
        core_hooks=[hook(id="core-one")],
        layers={
            "alpha": {"hooks": [hook(id="alpha-one")]},
            "beta": {"hooks": [hook(id="beta-one")]},
        },
    )
    entries, notes = lib.merge_registries(lib.discover(home, ["alpha", "beta"]), "standard")
    check("three hooks", len(entries), 3)
    check("no overrides", notes, [])

    print("\nprofiles select, and mandatory overrides the selection")
    home = make_clone(sandbox, "profiles", core_hooks=[
        hook(id="strict-only", profiles=["strict"]),
        hook(id="everywhere", profiles=["minimal", "standard", "strict"]),
        hook(id="always", profiles=["strict"], mandatory=True),
    ])
    units = [lib.Unit("core", home / "core")]
    minimal, _ = lib.merge_registries(units, "minimal")
    check("minimal drops the strict-only hook",
          sorted(e["id"] for e in minimal), ["always", "everywhere"])
    strict, _ = lib.merge_registries(units, "strict")
    check("strict keeps all three", len(strict), 3)
    refuses("an unknown profile is refused",
            lambda: lib.merge_registries(units, "paranoid"), "unknown profile")

    print("\ndiscovery checks the manifest against the directory")
    home = make_clone(sandbox, "misnamed",
                      layers={"acme": {"manifest": {"name": "not-acme"}}})
    refuses("a name that disagrees with its directory is refused",
            lambda: lib.discover(home, []), "does not match its directory")

    home = make_clone(sandbox, "unknown-layer", layers={"acme": {}})
    check("available_layers finds it", lib.available_layers(home), ["acme"])
    refuses("selecting a layer that is not there is refused",
            lambda: lib.discover(home, ["ghost"]), "unknown layer")

    print("\nscan_absolute_paths is the purity gate's eyes")
    home = make_clone(sandbox, "scan", core_hooks=[hook()])
    (home / "core" / "note.md").write_text("fine\nsee %s/thing\n" % home_root)
    hits = lib.scan_absolute_paths(home / "core")
    check("it finds the stored path", len(hits), 1)
    check("and names the line", hits[0][1], 2)

    print("\n%d passed, %d failed" % (PASSED, FAILED))
    return 1 if FAILED else 0


if __name__ == "__main__":
    raise SystemExit(main())
