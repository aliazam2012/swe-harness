#!/usr/bin/env python3
"""Tests for the installer: what it links, and what it writes into settings.json.

This is the port of the old link-shape suite. The job moved: a shell script used
to walk a source tree and link whatever it found, and core/lib/install.py now
plans the links from each unit's `skills/`, `agents/` and `commands/` directories
and generates settings.json from the merged registry. The properties worth
testing did not move, so they are tested here against the new owner.

Two of them decide whether a clone works on a second machine:

  A skill is one directory symlink, not a tree of file links. Claude Code
  discovers a skill by directory, and a skill linked file by file stops being
  discoverable the moment the skill gains a reference file nobody re-linked.

  A hook command in settings.json is an absolute interpreter plus an absolute
  script, resolved here and now. Claude Code does not expand `~` in a hook
  command, so a stored relative or tilde path is a hook that silently never runs.

Everything happens under a temporary HOME. The installer writes to
`~/.claude`, so a test that used the real one would edit the machine it runs on.
"""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import tempfile
from pathlib import Path
from typing import Dict, List

CORE = Path(__file__).resolve().parents[1]

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


def truthy(name, got):
    check(name, bool(got), True)


def load(name, home):
    """Import a core library by path, with HARNESS_HOME already pointing at the
    throwaway clone: install.py resolves ~/.claude at import time."""
    os.environ["HARNESS_HOME"] = str(home)
    spec = importlib.util.spec_from_file_location("t_%s" % name, CORE / "lib" / ("%s.py" % name))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def build_clone(root: Path) -> Path:
    """A clone with one core skill, one core agent, one command and one hook."""
    core = root / "core"
    (core / "skills" / "example-skill" / "references").mkdir(parents=True)
    (core / "skills" / "example-skill" / "SKILL.md").write_text("---\nname: example-skill\n---\n")
    (core / "skills" / "example-skill" / "references" / "detail.md").write_text("detail\n")
    (core / "agents").mkdir(parents=True)
    (core / "agents" / "reviewer.md").write_text("# reviewer\n")
    (core / "commands").mkdir(parents=True)
    (core / "commands" / "wrap.md").write_text("# wrap\n")
    (core / "hooks").mkdir(parents=True)
    (core / "hooks" / "gate.py").write_text("#!/usr/bin/env python3\n")
    (core / "VERSION").write_text("1.0.0\n")
    (core / "registry.json").write_text(json.dumps({
        "version": 1,
        "hooks": [{
            "id": "gate", "description": "a gate", "event": "Stop", "matcher": None,
            "runner": "python3", "script": "hooks/gate.py", "timeout": 10,
            "profiles": ["standard", "strict"], "mandatory": False,
        }],
    }))
    return root


def main() -> int:
    sandbox = Path(tempfile.mkdtemp(prefix="harness-install-test-"))
    saved = {k: os.environ.get(k) for k in ("HOME", "HARNESS_HOME", "HARNESS_WORKSPACE")}
    fake_home = sandbox / "home"
    (fake_home / ".claude").mkdir(parents=True)
    os.environ["HOME"] = str(fake_home)
    os.environ["HARNESS_WORKSPACE"] = str(fake_home / ".swe-harness")
    try:
        return run(sandbox, fake_home)
    finally:
        for key, value in saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        shutil.rmtree(str(sandbox), ignore_errors=True)


def run(sandbox: Path, fake_home: Path) -> int:
    clone = build_clone(sandbox / "clone")
    install = load("install", clone)
    layer_lib = load("layers", clone)

    print("the sandbox itself")
    check("HOME is not the real one", str(fake_home) == os.environ["HOME"], True)
    check("the installer targets the sandboxed ~/.claude",
          str(install.CLAUDE_DIR).startswith(str(sandbox)), True)

    units = layer_lib.discover(clone, [])

    print("\nlink shape: one directory link per discoverable item")
    links = install.plan_links(units)
    by_kind: Dict[str, List[Dict[str, str]]] = {}
    for link in links:
        by_kind.setdefault(link["kind"], []).append(link)
    check("one skill, one agent, one command",
          sorted((k, len(v)) for k, v in by_kind.items()),
          [("agents", 1), ("commands", 1), ("skills", 1)])
    check("the skill links the directory, not its files",
          by_kind["skills"][0]["source"], str(clone / "core" / "skills" / "example-skill"))
    check("it lands under ~/.claude/skills",
          by_kind["skills"][0]["destination"], str(fake_home / ".claude" / "skills" / "example-skill"))

    print("\napplying the plan")
    install.apply_links(links, True)
    skill_link = fake_home / ".claude" / "skills" / "example-skill"
    truthy("the skill is a symlink", skill_link.is_symlink())
    truthy("its reference file is reachable through it",
           (skill_link / "references" / "detail.md").is_file())
    truthy("the agent is linked", (fake_home / ".claude" / "agents" / "reviewer.md").is_symlink())

    print("\nit is idempotent")
    again = install.plan_links(units)
    owned = install.apply_links(again, True)
    check("a second run relinks nothing", [entry["state"] for entry in again],
          ["already linked"] * 3)
    check("and still claims all three as ours", len(owned), 3)

    print("\na real file in the way is refused, not overwritten")
    blocked_path = fake_home / ".claude" / "commands" / "wrap.md"
    blocked_path.unlink()
    blocked_path.write_text("a file someone wrote by hand\n")
    plan = install.plan_links(units)
    install.apply_links(plan, True)
    states = {entry["kind"]: entry.get("state", "") for entry in plan}
    truthy("the command is reported as blocked", states["commands"].startswith("blocked"))
    check("and the file is untouched", blocked_path.read_text(), "a file someone wrote by hand\n")
    blocked_path.unlink()

    print("\na stale link is repointed and backed up")
    stale_target = sandbox / "elsewhere.md"
    stale_target.write_text("old\n")
    agent_link = fake_home / ".claude" / "agents" / "reviewer.md"
    agent_link.unlink()
    agent_link.symlink_to(stale_target)
    plan = install.plan_links(units)
    install.apply_links(plan, True)
    check("it now points into the clone",
          os.readlink(str(agent_link)), str(clone / "core" / "agents" / "reviewer.md"))
    backups = list((fake_home / ".claude" / "agents").glob("reviewer.md.harness-bak-*"))
    check("the old link was backed up first", len(backups), 1)

    print("\nsettings.json carries resolved absolute commands")
    entries, _ = layer_lib.merge_registries(units, "standard")
    hooks = install.build_hooks(entries)
    command = hooks["Stop"][0]["hooks"][0]["command"]
    interpreter, script = command.split(" ", 1)
    truthy("the interpreter is absolute", interpreter.startswith("/"))
    check("the script is the one in the clone", script, str(clone / "core" / "hooks" / "gate.py"))
    truthy("nothing stores a tilde", "~" not in command)
    check("the timeout comes from the registry", hooks["Stop"][0]["hooks"][0]["timeout"], 10)

    print("\nwriting settings.json keeps what it did not put there")
    settings = fake_home / ".claude" / "settings.json"
    settings.write_text(json.dumps({
        "model": "keep-me",
        "hooks": {"Stop": ["stale"]},
        "env": {"HARNESS_WORKSPACE": "set-by-hand"},
    }))
    saved, existed, written_keys = install.write_settings(
        hooks, {"HARNESS_WORKSPACE": "ours", "HARNESS_PROFILE": "standard"}, True)
    written = json.loads(settings.read_text())
    check("an unrelated key survives", written.get("model"), "keep-me")
    check("the hooks block is replaced", written["hooks"]["Stop"][0]["hooks"][0]["command"], command)
    check("a hand-set env value wins", written["env"]["HARNESS_WORKSPACE"], "set-by-hand")
    check("an unset one is filled in", written["env"]["HARNESS_PROFILE"], "standard")
    check("only the filled-in key is reported", written_keys, ["HARNESS_PROFILE"])
    check("it knew the file already existed", existed, True)
    check("the previous file was backed up", saved is not None, True)
    check("the backup is on disk",
          len(list((fake_home / ".claude").glob("settings.json.harness-bak-*"))), 1)

    print("\na dry run writes nothing")
    settings.write_text(json.dumps({"model": "untouched"}))
    saved, _, _ = install.write_settings(hooks, {}, False)
    check("write_settings returns no backup", saved, None)
    check("and the file is unchanged", json.loads(settings.read_text()), {"model": "untouched"})

    print("\n%d passed, %d failed" % (PASSED, FAILED))
    return 1 if FAILED else 0


if __name__ == "__main__":
    raise SystemExit(main())
