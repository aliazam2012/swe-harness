#!/usr/bin/env python3
"""Tests for core/lib/harness_config.py: the resolution order and its edges.

Every case builds a throwaway clone under a temporary directory and points the
resolver at it, and every case that touches the environment puts it back. HOME
is repointed at a sandbox for the whole run, so a bug here cannot read or write
the real one.

The resolution order is the thing worth testing. A hook that reads os.environ
directly bypasses the config file and the default and reports "not configured"
for a key that is configured, which disables the hook silently. That failure has
no symptom, so the test is the only thing that would catch it.
"""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path

CORE = Path(__file__).resolve().parents[1]


def load(name):
    """Import a core library by path, so nothing on sys.path can shadow it."""
    spec = importlib.util.spec_from_file_location("t_%s" % name, CORE / "lib" / ("%s.py" % name))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


cfg = load("harness_config")

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


def raises(name, exception, call):
    global PASSED, FAILED
    try:
        call()
    except exception as exc:
        print("  ok   %s (%s)" % (name, str(exc)[:60]))
        PASSED += 1
        return
    except Exception as exc:  # noqa: BLE001 - the point is that it was the wrong one
        print("  FAIL %s (raised %s, wanted %s)" % (name, type(exc).__name__, exception.__name__))
        FAILED += 1
        return
    print("  FAIL %s (raised nothing, wanted %s)" % (name, exception.__name__))
    FAILED += 1


class Env:
    """Set environment variables for a block and put the old values back."""

    def __init__(self, **values):
        self.values = values
        self.saved = {}

    def __enter__(self):
        for key, value in self.values.items():
            self.saved[key] = os.environ.get(key)
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        return self

    def __exit__(self, *_):
        for key, old in self.saved.items():
            if old is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = old
        return False


def make_clone(root: Path, config=None, layers=None) -> Path:
    """A minimal clone: core/, optionally a config file and some layers."""
    (root / "core" / "lib").mkdir(parents=True, exist_ok=True)
    if config is not None:
        (root / cfg.CONFIG_FILENAME).write_text(json.dumps(config))
    for name, manifest in (layers or {}).items():
        directory = root / "layers" / name
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "layer.json").write_text(json.dumps(manifest))
    return root


def main() -> int:
    sandbox = Path(tempfile.mkdtemp(prefix="harness-config-test-"))
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

    print("\nresolution order, first hit wins")
    home = make_clone(sandbox / "order", config={"HARNESS_WORKSPACE": "/from/file"})
    with Env(HARNESS_WORKSPACE=None):
        check("the file is read when the environment is silent",
              cfg.get("HARNESS_WORKSPACE", home), "/from/file")
    with Env(HARNESS_WORKSPACE="/from/env"):
        check("the environment beats the file",
              cfg.get("HARNESS_WORKSPACE", home), "/from/env")

    bare = make_clone(sandbox / "bare")
    with Env(HARNESS_WORKSPACE=None):
        check("the default is used when neither is set",
              cfg.get("HARNESS_WORKSPACE", bare),
              os.path.expanduser("~/.swe-harness"))
    with Env(HARNESS_PROFILE=None):
        check("HARNESS_PROFILE defaults to standard", cfg.get("HARNESS_PROFILE", bare), "standard")

    print("\nan undeclared key is an error, not an empty string")
    raises("a key nothing declares raises KeyError",
           KeyError, lambda: cfg.get("HARNESS_TYPO", bare))

    print("\na layer declares its own keys")
    layered = make_clone(
        sandbox / "layered",
        layers={
            "acme": {
                "name": "acme",
                "config": [
                    {"key": "ACME_ROOT", "description": "where things live", "required": True},
                    {"key": "ACME_OPTIONAL", "required": False, "default": "quiet"},
                ],
            }
        },
    )
    keys = cfg.declared_keys(layered)
    check("the layer's key is declared", "ACME_ROOT" in keys, True)
    check("the key records its layer", keys["ACME_ROOT"].get("layer"), "acme")
    check("a required key with no value resolves to None", cfg.get("ACME_ROOT", layered), None)
    check("a layer default is used", cfg.get("ACME_OPTIONAL", layered), "quiet")
    with Env(ACME_ROOT=None):
        raises("require() on an unset required key exits",
               SystemExit, lambda: cfg.require("ACME_ROOT", layered))

    print("\nHARNESS_HOME is resolved, never read from a file")
    misleading = make_clone(sandbox / "misleading", config={"HARNESS_HOME": "/nowhere"})
    check("the clone wins over the file", cfg.get("HARNESS_HOME", misleading), str(misleading))

    print("\nexpansion")
    tilde = make_clone(sandbox / "tilde", config={"HARNESS_WORKSPACE": "~/spaces/one"})
    with Env(HARNESS_WORKSPACE=None):
        check("a tilde in the file is expanded",
              cfg.get("HARNESS_WORKSPACE", tilde), os.path.expanduser("~/spaces/one"))
    with Env(HARNESS_WORKSPACE="$HOME/from-var"):
        check("a variable in the environment is expanded",
              cfg.get("HARNESS_WORKSPACE", tilde), os.environ["HOME"] + "/from-var")

    print("\nan unreadable config file is ignored, not fatal")
    broken = make_clone(sandbox / "broken")
    (broken / cfg.CONFIG_FILENAME).write_text("{ this is not json")
    with Env(HARNESS_WORKSPACE=None):
        check("a malformed file falls through to the default",
              cfg.get("HARNESS_WORKSPACE", broken), os.path.expanduser("~/.swe-harness"))

    print("\nworkspace() creates the directory it names")
    target = sandbox / "made" / "nested"
    workspace_clone = make_clone(sandbox / "made-clone")
    with Env(HARNESS_WORKSPACE=str(target)):
        made = cfg.workspace(workspace_clone)
    check("the directory exists afterwards", made.is_dir(), True)
    check("it is the configured path", str(made), str(target))
    check("it is inside the sandbox", str(made).startswith(str(sandbox)), True)

    print("\nHARNESS_EDITOR falls back to $EDITOR, then vi")
    with Env(HARNESS_EDITOR=None, EDITOR="ed"):
        check("$EDITOR is used", cfg.get("HARNESS_EDITOR", bare), "ed")
    with Env(HARNESS_EDITOR=None, EDITOR=None):
        check("vi is the last resort", cfg.get("HARNESS_EDITOR", bare), "vi")

    print("\n%d passed, %d failed" % (PASSED, FAILED))
    return 1 if FAILED else 0


if __name__ == "__main__":
    raise SystemExit(main())
