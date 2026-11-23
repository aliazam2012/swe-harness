#!/usr/bin/env python3
"""install.py --codex: Codex hooks merged, skills linked, and undone cleanly.

Runs the real installer under a temporary HOME, starting from a Codex hooks.json
that already holds someone else's SessionStart hook, which must survive every
step.
"""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

CLONE = Path(__file__).resolve().parents[2]
INSTALL = CLONE / "core" / "lib" / "install.py"

fails = 0
total = 0


def report(name, ok, detail=""):
    global fails, total
    total += 1
    print(("  ok   %s" % name) if ok else ("  FAIL %s %s" % (name, detail)))
    if not ok:
        fails += 1


def run(home, *args):
    env = dict(os.environ, HOME=home, HARNESS_HOME=str(CLONE))
    env.pop("CODEX_HOME", None)
    return subprocess.run(  # noqa: S603 - our interpreter, our installer
        [sys.executable, str(INSTALL), *args], capture_output=True, text=True, env=env, check=False)


FOREIGN = {"type": "command", "command": "bash '/opt/other/agent-state.sh' session", "timeout": 10}

with tempfile.TemporaryDirectory() as home:
    codex = Path(home, ".codex")
    codex.mkdir()
    (codex / "hooks.json").write_text(json.dumps({"hooks": {"SessionStart": [{"hooks": [FOREIGN]}]}}))

    out = run(home, "--codex")
    report("a dry run changes nothing", json.loads((codex / "hooks.json").read_text())["hooks"].keys() == {"SessionStart"},
           out.stdout[-300:])
    report("the dry run names the Codex plan", "Codex:" in out.stdout, out.stdout[-300:])

    out = run(home, "--codex", "--write")
    report("install succeeds", out.returncode == 0, out.stderr[-400:])
    data = json.loads((codex / "hooks.json").read_text())["hooks"]
    commands = [h["command"] for blocks in data.values() for b in blocks for h in b["hooks"]]
    report("the foreign hook is kept", FOREIGN["command"] in commands)
    matchers = {(event, b.get("matcher")) for event, blocks in data.items() for b in blocks}
    report("Bash and apply_patch guards are on PreToolUse",
           {("PreToolUse", "Bash"), ("PreToolUse", "apply_patch")} <= matchers, matchers)
    report("lint is on PostToolUse apply_patch", ("PostToolUse", "apply_patch") in matchers, matchers)
    report("no Claude-only hook reaches Codex",
           not any(e in data for e in ("Stop", "PreCompact", "SessionEnd", "UserPromptSubmit")), sorted(data))
    report("every harness command points into the clone",
           all(str(CLONE) in c for c in commands if c != FOREIGN["command"]))
    skills = Path(home, ".agents", "skills")
    linked = sorted(p.name for p in skills.iterdir()) if skills.is_dir() else []
    report("skills are linked for Codex", "writing-style" in linked and all((skills / n).is_symlink() for n in linked),
           linked[:5])
    report("each linked skill has a SKILL.md", all((skills / n / "SKILL.md").is_file() for n in linked))

    run(home, "--codex", "--write")
    again = json.loads((codex / "hooks.json").read_text())["hooks"]
    count = sum(len(b["hooks"]) for blocks in again.values() for b in blocks)
    report("a second install adds nothing", count == len(commands), (count, len(commands)))

    out = run(home, "--uninstall", "--write")
    report("uninstall succeeds", out.returncode == 0, out.stderr[-400:])
    left = json.loads((codex / "hooks.json").read_text())["hooks"]
    left_commands = [h["command"] for blocks in left.values() for b in blocks for h in b["hooks"]]
    report("uninstall leaves only the foreign hook", left_commands == [FOREIGN["command"]], left_commands)
    report("uninstall removes the skill links", not skills.is_dir() or not any(skills.iterdir()),
           sorted(p.name for p in skills.iterdir())[:5] if skills.is_dir() else [])


# --codex-only: Codex gets the harness; Claude Code's settings are not touched at all.
with tempfile.TemporaryDirectory() as home:
    claude = Path(home, ".claude")
    claude.mkdir()
    mine = {"model": "opus", "hooks": {"SessionStart": [{"hooks": [
        {"type": "command", "command": "bash '/opt/someone-else/hook.sh'", "timeout": 10}]}]}}
    (claude / "settings.json").write_text(json.dumps(mine, indent=2) + "\n")
    before = (claude / "settings.json").read_bytes()

    out = run(home, "--codex-only", "--write")
    report("codex-only install succeeds", out.returncode == 0, out.stderr[-400:] + out.stdout[-400:])
    report("codex-only leaves Claude settings byte for byte", (claude / "settings.json").read_bytes() == before)
    report("codex-only links nothing into ~/.claude",
           not any(p.is_symlink() for p in claude.rglob("*")), sorted(str(p) for p in claude.rglob("*"))[:5])
    codex_hooks = json.loads(Path(home, ".codex", "hooks.json").read_text())["hooks"]
    report("codex-only writes the Codex hooks", ("PreToolUse" in codex_hooks), sorted(codex_hooks))
    skills = Path(home, ".agents", "skills")
    report("codex-only links the skills", skills.is_dir() and any(skills.iterdir()))

    out = run(home, "--uninstall", "--write")
    report("uninstall after codex-only succeeds", out.returncode == 0, out.stderr[-400:])
    report("uninstall leaves Claude settings byte for byte", (claude / "settings.json").read_bytes() == before)
    left = json.loads(Path(home, ".codex", "hooks.json").read_text())["hooks"]
    report("uninstall empties the Codex hooks it wrote", left == {}, left)
    report("uninstall removes the Codex skill links", not any(skills.iterdir()))

print("\n%d passed, %d failed" % (total - fails, fails))
sys.exit(1 if fails else 0)
