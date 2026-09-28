#!/usr/bin/env python3
"""Measure what the wired hook set costs per turn and per session.

A per-call millisecond figure is not what anyone feels. What is felt is the sum
over a turn, and that sum is dominated by whichever matcher fires most: a
PreToolUse hook on `Bash` is paid on most tool calls in a turn while a Stop
hook is paid once. So this tool measures per scenario, then multiplies by the
real invocation volume that `transcript-stats.py` reads out of the local
transcripts, and makes the per-turn and per-session totals the headline.

Three things separate this from a naive timing loop.

Safety. Every hook this tool knows how to run carries a verdict in the
side-effect table below: SAFE runs as it is, SAFE-IF runs under the sandbox
named beside it, and UNSAFE runs only when that sandbox provably contains every
effect. One that cannot be contained is skipped unless `--include-unsafe` is
passed. A hook with no verdict is never executed, so an unclassified hook is
reported rather than timed. Nothing is skipped silently.

Branches. Most hooks bail before their real work on a generic payload. A hook
timed on its early exit reports the interpreter floor and calls it the cost of
the hook. Every hook with a branch is measured on both sides of it, each branch
named in the output, each weighted by how often production takes it.

Proof. Timing the wrong branch is invisible, so every scenario asserts that the
payload reached the code path it claims to time, by checking exit code, stdout,
a file the hook writes, or a duration band that only the real path can occupy. A
scenario whose assertion fails is reported UNTRUSTED rather than as a fast
number.

Window. Behaviour is not stationary, so a weight averaged over the whole corpus
is not the weight in force now. A gate changes the behaviour it enforces, and
the whole-corpus average of the branch it gates then overstates that hook for
as long as the old data outweighs the new. Every corpus-derived weight is
counted over a window (14 days by default), the window is recorded in the
stored run, --compare refuses two runs whose windows differ, and each weight is
recomputed over the window's two halves so a weight that is still moving is
flagged rather than published as settled.

Scope. This measures the hooks core knows. A layer's hooks are discovered and
reported, but core cannot classify a side effect it has never seen, so a layer
hook shows as UNKNOWN and is skipped rather than run blind.

Data Sources:
  - Local only: the generated ~/.claude/settings.json, any enabled plugin
    hooks.json, and the local transcript corpus by way of transcript-stats.py

Default Environment: local
Environments Supported: local

Usage:
  harness-bench.py [--runs N] [--only PATTERN] [--json] [--list]
  harness-bench.py [--window-days 14 | --window-days 0]
  harness-bench.py --compare last [--threshold-pct 25]
"""

from __future__ import annotations

import argparse
import datetime as dt
import fnmatch
import glob
import importlib
import json
import os
import platform
import re
import shlex
import shutil
import socket
import statistics
import subprocess
import sys
import tempfile
import time
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))

import harness_config  # type: ignore[import-not-found]  # noqa: E402

# Every hook payload, stored run and rendered report is plain JSON, so one alias
# keeps the signatures readable instead of repeating dict[str, Any] everywhere.
JSON = dict[str, Any]

HOME = Path.home()
HARNESS_HOME = Path(harness_config.harness_home())


def _path(name: str, default: Path) -> Path:
    """Return a test seam's path override, or its default.

    Every input this tool reads is overridable, so the test suite can point the
    whole thing at fixture hooks it wrote itself and never touch the installed
    harness. The defaults are the real harness, so no flag is needed in use.
    These are seams, not configuration: a value a user sets is a declared key
    resolved through harness_config.
    """
    raw = os.environ.get(name)
    return Path(raw).expanduser() if raw else default


SETTINGS = _path("HARNESS_BENCH_SETTINGS", HOME / ".claude" / "settings.json")
PLUGIN_HOOKS_GLOB = (os.environ.get("HARNESS_BENCH_PLUGIN_GLOB")
                     or str(HOME / ".claude" / "plugins" / "*" / "hooks" / "hooks.json"))
HOOKS_DIR = _path("HARNESS_BENCH_HOOKS", HARNESS_HOME / "core" / "hooks")
STATS_TOOL = _path("HARNESS_BENCH_STATS",
                   HARNESS_HOME / "core" / "scripts" / "transcript-stats.py")


def _store_path() -> Path:
    """Where runs are recorded: under the harness workspace, never in a repo."""
    raw = os.environ.get("HARNESS_BENCH_STORE")
    if raw:
        return Path(raw).expanduser()
    return harness_config.workspace() / "benchmarks" / "hooks.jsonl"


STORE = _store_path()

# Resolved once so the calls below name an absolute executable rather than
# trusting whatever PATH the benchmark inherited. Both are floor requirements of
# the harness, so neither lookup can come back empty on a machine that runs it.
PY3 = shutil.which("python3") or sys.executable
GIT = shutil.which("git") or "git"

# The scenarios below cite this rather than a document, because core ships the
# table and the table is the classification. A layer that adds a hook adds no
# row here and its hook is therefore never executed.
SAFETY_DOC = "the side-effect table in harness-bench.py"


def _protected_config_globs() -> tuple[str, ...]:
    """Return the config-protection guard's own protected basenames.

    Imported rather than restated. A copy of this list here would drift from the
    guard the first time either side changed, and the weight would then be
    counted over a different set of files than the guard actually refuses.
    Returns empty on any failure, which makes the branch weight 0 rather than
    wrong.
    """
    try:
        sys.path.insert(0, str(HOOKS_DIR))
        from guards.config_protection import (  # type: ignore[import-not-found]  # noqa: PLC0415
            PROTECTED,
            PYPROJECT,
        )
        return (*PROTECTED, PYPROJECT)
    except Exception:
        return ()


def _no_verify_matcher():
    """Return a predicate that says whether a command trips the no_verify guard.

    The guard's own normalization and patterns, not a copy of them: a second
    spelling of the rule would count a branch the guard does not actually take.
    The private helpers are used rather than `check` because `check` honours
    GIT_NO_VERIFY_OVERRIDE, and whether the machine running the benchmark has
    that set says nothing about how often the branch is taken in production.
    """
    try:
        sys.path.insert(0, str(HOOKS_DIR))
        # import_module, not `from guards import no_verify`: the package
        # re-exports the guard's `check` under that name, so the plain import
        # binds the function and the module behind it is unreachable.
        guard = importlib.import_module("guards.no_verify")

        def matches(command: str) -> bool:
            if "git" not in command:
                return False
            return guard._what(guard._normalized(command)) is not None

        return matches
    except Exception:
        return lambda command: False


def _harness_path_matcher():
    """Return a predicate that says whether a written path is harness state.

    Delegates to hooks/harness_fingerprint.py, which is the one definition of
    what the harness is, so this weight counts exactly the edits the Stop gate
    reacts to.
    """
    try:
        sys.path.insert(0, str(HOOKS_DIR))
        import harness_fingerprint as hf  # type: ignore[import-not-found]  # noqa: PLC0415
        return hf.is_harness_path
    except Exception:
        return lambda path: False


PROTECTED_CONFIG = _protected_config_globs()
IS_NO_VERIFY = _no_verify_matcher()
IS_HARNESS_PATH = _harness_path_matcher()
# Resolving a path stats the filesystem, so the harness check is only asked
# about files that could possibly be one.
HARNESS_SUFFIXES = (".py", ".sh", ".json")

DEFAULT_RUNS = 50

# Below this, a comparison reports noise as a regression. Measured by taking
# identical back-to-back runs and reading the spread: at --runs 5 the median
# scenario drifted by about a third between runs and more than half crossed the
# 25% threshold on their own; at --runs 15 the median drift was under 4% and
# none crossed it. The default of 50 is the safe answer; 15 is the floor at
# which a delta means anything.
MIN_COMPARE_RUNS = 15
WARMUP_RUNS = 3
# A scenario that costs more than this per run would dominate the wall clock of
# the whole benchmark, so it gets fewer samples. The reported n says so.
SLOW_SCENARIO_S = 1.0
SLOW_SCENARIO_RUNS = 10
LOAD_WARN = 2.0
DEFAULT_THRESHOLD_PCT = 25.0

# How far back the branch weights are counted. Fourteen days is two working
# weeks: long enough that a quiet week does not empty a branch, short enough
# that a gate landed a month ago no longer sets the weight of the behaviour it
# changed. 0 means the whole corpus, which is the old behaviour and is kept only
# so a historical run can be reproduced.
DEFAULT_WINDOW_DAYS = 14
# Below this many observations a percentage is noise, so it is printed with the
# count beside it instead of on its own. Thirty is the usual floor for treating a
# proportion as anything but indicative: at n=30 the 95% interval on a 50% share
# is still about +/-18 points, and it only gets wider below that.
MIN_OBSERVATIONS = 30
# A weight that moved by more than this factor between the window's first and
# second half is still moving, so the headline built on it is provisional.
STABILITY_RATIO = 2.0
# The YYYY-MM-DD prefix of an ISO timestamp, which is the granularity every
# window bound, half split and stored date range is expressed in.
DATE_LEN = 10

# Sampled at import, before any corpus scan, fixture build or scenario runs.
# The report is assembled at the end, so reading the load there would measure
# this tool's own process spawns and report them as a busy machine.
LOAD_AT_START = os.getloadavg()[0]

# PreCompact has no matcher row in transcript-stats, so its rate is carried
# here: compaction entries are a small fraction of a session on any corpus
# measured so far. Small enough that it never moves a total, and carried
# explicitly so the number is not silently assumed to be zero.
PRECOMPACT_PER_SESSION = 0.036


@dataclass(frozen=True)
class Safety:
    """One row of the side-effect table: what a hook does, and how it is contained."""

    verdict: str
    reason: str
    mitigation: str
    contained: bool


# Keyed by the script basename, optionally qualified by "@<event>" when one
# script is wired to more than one event and the events differ in what they do.
# `contained` is True when the mitigation provably keeps every effect inside a
# temp tree; an UNSAFE hook with contained=False is skipped unless
# --include-unsafe is passed.
SAFETY: dict[str, Safety] = {
    "sessionstart-inject.py": Safety(
        "SAFE-IF",
        "creates the session journal and state file through session-card.sh",
        "HARNESS_WORKSPACE points at a temp tree; the script path is pinned separately",
        True,
    ),
    "session-lifecycle.sh@SessionStart": Safety(
        "SAFE-IF",
        "the same journal and state writes as sessionstart-inject.py",
        "HARNESS_WORKSPACE points at a temp tree",
        True,
    ),
    "session-lifecycle.sh@PreCompact": Safety(
        "UNSAFE",
        "appends a 'context compacted' note to the live journal, once per run",
        "HARNESS_WORKSPACE points at a temp tree, reused across runs as production would be",
        True,
    ),
    "session-lifecycle.sh@SessionEnd": Safety(
        "UNSAFE",
        "auto-wraps the live session: appends a Closed block, writes an auto-close "
        "ledger row and deletes the session state file",
        "a fresh HARNESS_WORKSPACE per run, so every write lands in a temp tree and "
        "run 2 does not hit the already-wrapped exit",
        True,
    ),
    "herdr-agent-state.sh": Safety(
        "SAFE-IF",
        "rebinds the live pane to the synthetic session_id over the multiplexer socket",
        "HERDR_SOCKET_PATH points at a path with no socket, so connect fails on ENOENT",
        True,
    ),
    "herdr-lineage.sh": Safety(
        "UNSAFE",
        "with no parent pane in the environment it clears the role and parent "
        "tokens on the live pane",
        "none that keeps the cost: pointing the binary at /usr/bin/true removes "
        "the CLI start, which is the entire measurement",
        False,
    ),
    "herdr-sticky-prompt.py": Safety(
        "UNSAFE",
        "renames the live pane and overwrites the recorded last input",
        "HOME and HARNESS_WORKSPACE point at a temp tree and the multiplexer "
        "binary at /usr/bin/true",
        True,
    ),
    "pretooluse-dispatcher.py": Safety(
        "SAFE",
        "read-only: reads the payload, stats the target path and reads the guard "
        "allowlist. It writes nothing but its own JSON verdict",
        "none needed",
        True,
    ),
    "posttooluse-python-lint.py": Safety(
        "SAFE",
        "runs ruff, mypy and any configured extra checks; leaves a .mypy_cache directory",
        "run from the scratch directory so the cache is contained",
        True,
    ),
    "stop-done-gate.py": Safety(
        "SAFE-IF",
        "a non-passing verdict writes a marker file and prunes old markers",
        "HARNESS_WORKSPACE points at a temp tree, which moves the marker directory",
        True,
    ),
    "stop-harness-bench-gate.py": Safety(
        "SAFE-IF",
        "reads the transcript, the hook tree and the stored run log; writes nothing",
        "HARNESS_BENCH_STORE points at a temp file so the live run log is not read",
        True,
    ),
    "herdr-lineage-status.py": Safety(
        "SAFE-IF",
        "rewrites state labels on every agent pane, not just this one",
        "the multiplexer binary points at a stub that replays a captured agent "
        "list and discards writes",
        True,
    ),
}


@dataclass(frozen=True)
class Wiring:
    """One hook command as the harness will actually run it."""

    event: str
    matcher: str
    command: str
    argv: tuple[str, ...]
    script: str
    key: str
    language: str
    source: str

    @property
    def safety_key(self) -> str:
        """The side-effect table key for this wiring, event-qualified first."""
        qualified = f"{self.key}@{self.event}"
        return qualified if qualified in SAFETY else self.key


@dataclass
class Scenario:
    """One named branch of one hook, with the payload that reaches it."""

    key: str
    name: str
    argv: list[str]
    payload: str
    weight: float
    event: str | None = None
    matcher: str | None = None
    env: dict[str, str | None] = field(default_factory=dict)
    fresh_workspace: bool = False
    expect_stdout: str | None = None
    reject_stdout: str | None = None
    expect_exit: int | None = 0
    marker: str | None = None
    min_floors: float | None = None
    max_floors: float | None = None
    requires: str | None = None
    fidelity: str = "full"

    @property
    def ident(self) -> str:
        """Return the stable id this scenario is stored and compared under."""
        return f"{self.key} :: {self.name}"

    def wires(self, wiring: Wiring) -> bool:
        """Report whether this scenario describes that wiring's branch."""
        if wiring.key != self.key:
            return False
        if self.event is not None and wiring.event != self.event:
            return False
        return not (self.matcher is not None and wiring.matcher != self.matcher)

    @property
    def safety_key(self) -> str:
        """The side-effect table key, event-qualified when the table has one."""
        qualified = f"{self.key}@{self.event}"
        return qualified if self.event and qualified in SAFETY else self.key


@dataclass
class Stats:
    """The distribution of one scenario's measured durations, in milliseconds."""

    n: int
    min: float
    p50: float
    mean: float
    p95: float
    p99: float
    max: float
    stddev: float


@dataclass
class Result:
    """One scenario's measurement plus whether it can be trusted."""

    scenario: Scenario
    stats: Stats
    trusted: bool
    detail: str
    floor_ms: float

    @property
    def marginal_ms(self) -> float:
        """Return p50 less the interpreter floor for this hook's language."""
        return round(self.stats.p50 - self.floor_ms, 2)


# --------------------------------------------------------------- discovery


def _classify(argv: list[str]) -> tuple[str, str, str]:
    """Return (script path, key, language) for one resolved hook command."""
    script, rest = "", []
    for i, token in enumerate(argv):
        if token.endswith((".py", ".sh")) and os.path.exists(token):
            script, rest = token, argv[i + 1:]
            break
    key = os.path.basename(script) or (argv[0] if argv else "?")
    if rest:
        key = f"{key} {' '.join(rest)}"
    language = "python" if script.endswith(".py") or "python" in argv[0] else "bash"
    return script, key, language


def _entries(doc: JSON, source: str, plugin_root: str | None) -> list[Wiring]:
    """Flatten one hooks mapping into wirings, resolving the plugin root."""
    out: list[Wiring] = []
    for event, groups in (doc.get("hooks") or {}).items():
        for group in groups:
            for hook in group.get("hooks", []):
                command = str(hook.get("command", ""))
                if plugin_root:
                    command = command.replace("${CLAUDE_PLUGIN_ROOT}", plugin_root)
                argv = shlex.split(command)
                script, key, language = _classify(argv)
                out.append(Wiring(
                    event, str(group.get("matcher", "*")), command,
                    tuple(argv), script, key, language, source,
                ))
    return out


def discover() -> list[Wiring]:
    """Return every wired hook command, from settings.json and plugin hooks."""
    found: list[Wiring] = []
    if SETTINGS.is_file():
        found += _entries(json.loads(SETTINGS.read_text()), "settings.json", None)
    for path in sorted(glob.glob(PLUGIN_HOOKS_GLOB)):
        root = os.path.dirname(os.path.dirname(path))
        doc = json.loads(Path(path).read_text())
        found += _entries(doc, f"plugin:{os.path.basename(root)}", root)
    return found


# ---------------------------------------------------------------- fixtures


@dataclass
class Fixtures:
    """Every file the scenarios feed to a hook, all inside one temp tree."""

    root: Path
    workspace: Path
    home: Path
    repo: Path
    herdr_stub: Path
    py_dirty: Path
    ruff_toml: Path
    store: Path
    transcripts: dict[str, Path]
    transcript_bytes: int


def _pad_line(index: int) -> str:
    """Return one filler transcript entry, shaped like a real tool result."""
    return json.dumps({
        "type": "user",
        "uuid": f"pad-{index}",
        "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": f"t{index}", "content": "x" * 400},
        ]},
    })


def _write_transcript(path: Path, tail: list[JSON], target_bytes: int) -> None:
    """Write a JSONL transcript padded to the corpus mean size, tail last."""
    written = 0
    index = 0
    with path.open("w", encoding="utf-8") as handle:
        while written < target_bytes:
            line = _pad_line(index)
            handle.write(line + "\n")
            written += len(line) + 1
            index += 1
        for entry in tail:
            handle.write(json.dumps(entry) + "\n")


def _turn(text: str, with_tool: bool, edited: str | None = None) -> list[JSON]:
    """Return the entries of one finished turn: prompt, optional tool, reply."""
    out: list[JSON] = [{
        "type": "user", "uuid": "prompt-1",
        "message": {"role": "user", "content": "run the benchmark fixture"},
    }]
    if with_tool:
        call: JSON = {"type": "tool_use", "id": "t-1", "name": "Bash",
                      "input": {"command": "ls"}}
        if edited:
            call = {"type": "tool_use", "id": "t-1", "name": "Edit",
                    "input": {"file_path": edited}}
        out.append({
            "type": "assistant", "uuid": "a-1",
            "message": {"role": "assistant", "content": [call]},
        })
        out.append({
            "type": "user", "uuid": "r-1",
            "message": {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": "t-1", "content": "ok"},
            ]},
        })
    out.append({
        "type": "assistant", "uuid": "a-2",
        "message": {"role": "assistant", "content": [{"type": "text", "text": text}]},
    })
    return out


FOOTER_REPLY = "Did it.\n\nVerified: ran the fixture and read the output\nGaps: none\n"
BARE_REPLY = "Did it.\n"


def _make_repo(path: Path) -> None:
    """Create a one-commit git work tree for any scenario that needs one."""
    path.mkdir(parents=True, exist_ok=True)

    def git(*args: str) -> None:
        subprocess.run(  # noqa: S603
            [GIT, *args], cwd=path, capture_output=True, check=False, timeout=60,
        )

    git("init", "-q", "-b", "main", ".")
    git("config", "user.email", "bench@example.com")
    git("config", "user.name", "bench")
    (path / "f.txt").write_text("x\n")
    git("add", "f.txt")
    git("commit", "-qm", "init")


HERDR_STUB = """#!/bin/sh
# Stub multiplexer CLI for the benchmark. Replays a captured `agent list` and
# swallows every write, so the lineage hook walks its real reconcile loop
# without touching the live sidebar. Deliberately the cheapest possible
# process: the real CLI start is measured separately and reported as a floor to
# add back, rather than being approximated here.
case "$1 $2" in
  "agent list") cat "$HARNESS_BENCH_AGENTS" ;;
  *) : ;;
esac
exit 0
"""

DIRTY_PY = '''"""Fixture module for the python-lint hook: ruff must have something to say."""
import os
import sys


def f(a):
    return a
'''


def build_fixtures(root: Path, transcript_bytes: int) -> Fixtures:
    """Create every fixture the scenarios need under one temp root."""
    workspace, home, repo = root / "workspace", root / "home", root / "repo"
    for each in (workspace, home):
        each.mkdir(parents=True, exist_ok=True)
    _make_repo(repo)
    stub = root / "herdr-stub.sh"
    stub.write_text(HERDR_STUB)
    stub.chmod(0o755)
    agents = root / "agents.json"
    agents.write_text(_capture_agents())
    py_dirty = root / "lintme.py"
    py_dirty.write_text(DIRTY_PY)
    # The guard refuses an edit to a config that already exists, so the file has
    # to be on disk or the scenario measures the create path instead.
    ruff_toml = root / "ruff.toml"
    ruff_toml.write_text("line-length = 100\n")
    store = root / "bench-store.jsonl"
    store.write_text("")
    hook_file = str(HOOKS_DIR / "stop-done-gate.py")
    transcripts = {
        "footer": root / "t-footer.jsonl",
        "notool": root / "t-notool.jsonl",
        "nofooter": root / "t-nofooter.jsonl",
        "harness": root / "t-harness.jsonl",
    }
    _write_transcript(transcripts["footer"], _turn(FOOTER_REPLY, True), transcript_bytes)
    _write_transcript(transcripts["notool"], _turn(BARE_REPLY, False), transcript_bytes)
    _write_transcript(transcripts["nofooter"], _turn(BARE_REPLY, True), transcript_bytes)
    _write_transcript(transcripts["harness"],
                      _turn(FOOTER_REPLY, True, edited=hook_file), transcript_bytes)
    return Fixtures(root, workspace, home, repo, stub, py_dirty, ruff_toml,
                    store, transcripts, transcript_bytes)


def _capture_agents() -> str:
    """Return a real agent list payload, or an empty one when unavailable.

    The multiplexer is optional. Without it the stub replays an empty list and
    the lineage scenario still walks its loop, so a machine that does not have
    the binary measures the hook rather than skipping it.
    """
    binary = os.environ.get("HERDR_BIN_PATH") or shutil.which("herdr")
    if binary:
        try:
            done = subprocess.run(  # noqa: S603
                [binary, "agent", "list"], capture_output=True, text=True,
                timeout=10, check=False,
            )
            if done.returncode == 0 and done.stdout.strip():
                return done.stdout
        except (OSError, subprocess.SubprocessError):
            pass
    return json.dumps({"result": {"agents": []}})


# ------------------------------------------------------------- branch weights


@dataclass(frozen=True)
class Window:
    """The slice of the corpus every branch weight is counted over.

    Behaviour is not stationary, so the whole-corpus average of a branch weight
    is not the weight in force now. Every weight is counted over this window
    instead, and the window travels with the run so two runs are only ever
    compared on the same footing.
    """

    days: int
    start: str | None
    end: str | None

    @property
    def whole_corpus(self) -> bool:
        """Report whether this window drops nothing, the pre-window behaviour."""
        return self.days <= 0

    @property
    def label(self) -> str:
        """Return the one-line description printed and stored with the run."""
        if self.whole_corpus:
            return "whole corpus, no date filter (--window-days 0)"
        return f"last {self.days} days, {self.start} .. {self.end}"

    def contains(self, date: str) -> bool:
        """Report whether a turn opened on this YYYY-MM-DD date is in the window."""
        if self.whole_corpus:
            return True
        return bool(date) and self.start is not None and date >= self.start


def make_window(days: int, today: str | None = None) -> Window:
    """Return the window of the last `days` days, ending today in UTC.

    Args:
        days: How many days back to count weights over; 0 for the whole corpus.
        today: The end date, for tests. Defaults to today in UTC.

    Returns:
        The window, with its bounds as YYYY-MM-DD strings.
    """
    if days <= 0:
        return Window(0, None, None)
    end = today or dt.datetime.now(dt.timezone.utc).date().isoformat()
    start = (dt.date.fromisoformat(end) - dt.timedelta(days=days)).isoformat()
    return Window(days, start, end)


@dataclass(frozen=True)
class Turn:
    """One finished turn: the date it opened on, and what it did.

    Weights are aggregated from these rather than counted straight into one
    tally, because the window and its two halves are date slices of the same
    scan and a turn is the smallest unit that carries a date.
    """

    date: str
    counts: Counter


@dataclass(frozen=True)
class Weights:
    """How often production takes each expensive branch, counted off the corpus.

    A branch weight decides how much of a hook's cost is real, so guessing one
    makes the headline a guess. Every field here is counted from the same
    transcripts transcript-stats.py reads, in one pass, at run time, over the
    window this run was given. `branches` carries each weight's two halves and
    its observation count, so a weight that is still moving or is built on a
    handful of turns is visible rather than implied.
    """

    bash_calls: int
    edit_calls: int
    turns: int
    bash_no_verify: float
    lint_py: float
    guard_config: float
    stop_footer: float
    stop_no_tool: float
    stop_no_footer: float
    stop_harness_edit: float
    window_days: int
    window_start: str | None
    window_end: str | None
    split_date: str | None
    first_date: str | None
    last_date: str | None
    turns_excluded: int
    turns_undated: int
    branches: list


# Each weight as (name, numerator key, denominator key), so the value, the two
# halves, the observation count and the stability check are all derived from one
# table instead of being written out four times.
BRANCH_SPEC: tuple[tuple[str, str, str], ...] = (
    ("bash_no_verify", "bash_no_verify", "bash"),
    ("lint_py", "edit_py", "edit"),
    ("guard_config", "edit_config", "edit"),
    ("stop_footer", "turn_footer", "turns"),
    ("stop_no_tool", "turn_no_tool", "turns"),
    ("stop_no_footer", "turn_no_footer", "turns"),
    ("stop_harness_edit", "turn_harness", "turns"),
)


FOOTER_V = re.compile(r"^\s*(?:[-*>]\s*)?(?:\*\*)?verified:", re.I | re.M)
FOOTER_G = re.compile(r"^\s*(?:[-*>]\s*)?(?:\*\*)?gaps:", re.I | re.M)
EDIT_TOOLS = {"Write", "Edit", "MultiEdit"}


def is_prompt(entry: JSON) -> bool:
    """Report whether an entry is a typed prompt, opening a turn.

    The same three tests stop-done-gate.py applies, so the turn split this
    counts over is the split that hook itself sees.
    """
    if entry.get("type") != "user" or entry.get("isSidechain") or entry.get("isMeta"):
        return False
    content = (entry.get("message") or {}).get("content")
    if isinstance(content, str):
        return bool(content.strip())
    if isinstance(content, list):
        kinds = {b.get("type") for b in content if isinstance(b, dict)}
        return "tool_result" not in kinds
    return False


def _tally_blocks(entry: JSON, turn: JSON) -> None:
    """Count one assistant entry's tool calls into the open turn's tally."""
    counts: Counter = turn["counts"]
    for block in (entry.get("message") or {}).get("content") or []:
        if not isinstance(block, dict):
            continue
        if block.get("type") == "text":
            turn["text"].append(str(block.get("text") or ""))
            continue
        if block.get("type") != "tool_use":
            continue
        turn["tool"] = True
        name = block.get("name")
        args = block.get("input") or {}
        if name == "Bash":
            _tally_bash(str(args.get("command", "")), counts)
        elif name in EDIT_TOOLS:
            _tally_edit(str(args.get("file_path", "")), counts, turn)


def _tally_bash(command: str, counts: Counter) -> None:
    """Count one Bash command into the branches the Bash hooks take."""
    counts["bash"] += 1
    if IS_NO_VERIFY(command):
        counts["bash_no_verify"] += 1


def _tally_edit(path: str, counts: Counter, turn: JSON) -> None:
    """Count one edited path into the branches the write-time hooks take."""
    counts["edit"] += 1
    if path.endswith(".py"):
        counts["edit_py"] += 1
    base = os.path.basename(path)
    if any(fnmatch.fnmatch(base, pattern) for pattern in PROTECTED_CONFIG):
        counts["edit_config"] += 1
    if path.endswith(HARNESS_SUFFIXES) and IS_HARNESS_PATH(path):
        turn["harness"] = True


def _close_turn(turn: JSON | None, out: list) -> None:
    """Classify a finished turn into the branches the Stop hooks take."""
    if turn is None or not turn["seen"]:
        return
    counts: Counter = turn["counts"]
    counts["turns"] += 1
    if turn["harness"]:
        counts["turn_harness"] += 1
    if not turn["tool"]:
        counts["turn_no_tool"] += 1
    else:
        joined = "\n".join(turn["text"])
        if FOOTER_V.search(joined) and FOOTER_G.search(joined):
            counts["turn_footer"] += 1
        else:
            counts["turn_no_footer"] += 1
    out.append(Turn(str(turn["date"]), counts))


def _entry_date(entry: JSON) -> str:
    """Return an entry's UTC date as YYYY-MM-DD, or '' when it carries none."""
    stamp = entry.get("timestamp")
    if not isinstance(stamp, str) or len(stamp) < DATE_LEN:
        return ""
    return stamp[:DATE_LEN]


def _new_turn(entry: JSON) -> JSON:
    """Return the open-turn accumulator for a prompt entry."""
    return {"tool": False, "text": [], "seen": False, "harness": False,
            "date": _entry_date(entry), "counts": Counter()}


def _scan_file(path: str, out: list, seen: set) -> None:
    """Fold one transcript into per-turn records, skipping fork duplicates.

    A turn is dated by the prompt that opened it, not by its individual entries,
    so a turn is never split across the window edge and the assistant entries
    that carry no timestamp of their own are still counted.
    """
    turn: JSON | None = None
    try:
        with open(path, "rb") as handle:
            for line in handle:
                if not line.startswith(b"{"):
                    continue
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                uuid = entry.get("uuid")
                if uuid:
                    if uuid in seen:
                        continue
                    seen.add(uuid)
                if is_prompt(entry):
                    _close_turn(turn, out)
                    turn = _new_turn(entry)
                    continue
                if turn is None or entry.get("type") != "assistant" or entry.get("isSidechain"):
                    continue
                turn["seen"] = True
                _tally_blocks(entry, turn)
    except OSError:
        return
    _close_turn(turn, out)


def _sum(turns: list) -> Counter:
    """Return the branch tallies of a set of turns, added together."""
    total: Counter = Counter()
    for turn in turns:
        total.update(turn.counts)
    return total


def _split_date(dates: list) -> str | None:
    """Return the date that halves the observed span, or None when there is none.

    The split follows the data rather than the window, so a 14-day window whose
    transcripts all land in its last three days still splits into two halves
    that can be compared instead of one empty half.
    """
    if not dates:
        return None
    first, last = dt.date.fromisoformat(dates[0]), dt.date.fromisoformat(dates[-1])
    if first == last:
        return None
    return (first + (last - first) / 2).isoformat()


def _share(counts: Counter, numerator: str, denominator: str) -> float:
    """Return one branch's share of its denominator, or 0.0 when it has none."""
    total = counts[denominator]
    return counts[numerator] / total if total else 0.0


def _branch(spec: tuple[str, str, str], total: Counter,
            first: Counter, second: Counter) -> JSON:
    """Return one weight with its halves, its observation count and its verdicts."""
    name, num, den = spec
    halves_known = first[den] >= MIN_OBSERVATIONS and second[den] >= MIN_OBSERVATIONS
    a, b = _share(first, num, den), _share(second, num, den)
    ratio = (max(a, b) / min(a, b)) if a > 0 and b > 0 else None
    if not halves_known:
        moved = False
    elif ratio is not None:
        moved = ratio > STABILITY_RATIO
    else:
        # One half is zero. That is an infinite ratio when the other is not, and
        # no movement at all when both are.
        moved = a != b
    return {
        "name": name, "value": _share(total, num, den),
        "observations": total[num], "denominator": total[den],
        "thin": min(total[num], total[den]) < MIN_OBSERVATIONS,
        "first_half": a, "second_half": b,
        "first_denominator": first[den], "second_denominator": second[den],
        "ratio": round(ratio, 2) if ratio is not None else None,
        "halves_known": halves_known, "unstable": moved,
    }


def build_weights(turns: list, excluded: int, window: Window) -> Weights:
    """Aggregate per-turn records into the weights, halves and stability flags."""
    dated = sorted(t.date for t in turns if t.date)
    split = _split_date(dated)
    total = _sum(turns)
    first = _sum([t for t in turns if t.date and split and t.date < split])
    second = _sum([t for t in turns if t.date and split and t.date >= split])
    branches = [_branch(spec, total, first, second) for spec in BRANCH_SPEC]
    values = {b["name"]: float(b["value"]) for b in branches}
    return Weights(
        bash_calls=total["bash"], edit_calls=total["edit"], turns=total["turns"],
        bash_no_verify=values["bash_no_verify"], lint_py=values["lint_py"],
        guard_config=values["guard_config"], stop_footer=values["stop_footer"],
        stop_no_tool=values["stop_no_tool"], stop_no_footer=values["stop_no_footer"],
        stop_harness_edit=values["stop_harness_edit"],
        window_days=window.days, window_start=window.start, window_end=window.end,
        split_date=split, first_date=dated[0] if dated else None,
        last_date=dated[-1] if dated else None,
        turns_excluded=excluded, turns_undated=sum(1 for t in turns if not t.date),
        branches=branches,
    )


def scan_corpus(root: str, window: Window) -> Weights:
    """Count every branch weight off the slice of the corpus the window names."""
    turns: list = []
    seen: set = set()
    for path in sorted(glob.glob(os.path.join(root, "**", "*.jsonl"), recursive=True)):
        _scan_file(path, turns, seen)
    kept = [t for t in turns if window.contains(t.date)]
    return build_weights(kept, len(turns) - len(kept), window)


# --------------------------------------------------------------- scenarios


def _p(obj: JSON) -> str:
    """Return a hook payload as the JSON string that goes on stdin."""
    return json.dumps(obj)


SESSION_ID = "harness-bench-0000-0000"
DEAD_SOCKET = "/nonexistent/harness-bench/no-such.sock"
ACTIVE_MARKER = "sessions/.active/*.env"
JOURNAL_MARKER = "sessions/*/*.md"
WRITE_MATCHER = "Write|Edit|MultiEdit"


def _session_start(fx: Fixtures) -> list:
    """Return the SessionStart scenarios, cold and warm where it matters."""
    base = {"hook_event_name": "SessionStart", "session_id": SESSION_ID,
            "transcript_path": str(fx.transcripts["footer"]),
            "cwd": str(fx.repo), "source": "startup"}
    inject = [PY3, str(HOOKS_DIR / "sessionstart-inject.py")]
    lifecycle = ["bash", str(HOOKS_DIR / "session-lifecycle.sh")]
    out: list = []
    for key, argv in (("sessionstart-inject.py", inject),
                      ("session-lifecycle.sh", lifecycle)):
        out.append(Scenario(
            key, "cold workspace (first call of a session, journal created)", argv,
            _p(base), 0.0, event="SessionStart", fresh_workspace=True,
            marker=ACTIVE_MARKER,
        ))
        out.append(Scenario(
            key, "warm workspace (state file cached, the steady state)", argv,
            _p(base), 1.0, event="SessionStart",
            env={"HARNESS_WORKSPACE": str(fx.workspace)}, marker=ACTIVE_MARKER,
        ))
    out.append(Scenario(
        "herdr-agent-state.sh",
        "no session_id (the shell guards fail, nothing else runs)",
        ["sh", str(HOOKS_DIR / "herdr-agent-state.sh")],
        _p({"hook_event_name": "SessionStart"}), 0.0,
        event="SessionStart", env={"HERDR_SOCKET_PATH": DEAD_SOCKET},
    ))
    out.append(Scenario(
        "herdr-agent-state.sh",
        "dead socket (full parse, the RPC fails on ENOENT)",
        ["sh", str(HOOKS_DIR / "herdr-agent-state.sh")],
        _p(base), 1.0, event="SessionStart",
        env={"HERDR_ENV": "1", "HERDR_PANE_ID": "w1:p1",
             "HERDR_SOCKET_PATH": DEAD_SOCKET},
        fidelity="partial: the socket round trip is the one part that must not run",
    ))
    out.append(Scenario(
        "herdr-lineage.sh", "clears the live pane's role and parent tokens",
        ["sh", str(HOOKS_DIR / "herdr-lineage.sh")], _p(base), 1.0,
        event="SessionStart",
    ))
    return out


def _pre_tool_use(fx: Fixtures, w: Weights) -> list:
    """Return the PreToolUse scenarios, including the hot path on Bash."""
    dispatch = [PY3, str(HOOKS_DIR / "pretooluse-dispatcher.py")]
    plain = {"hook_event_name": "PreToolUse", "session_id": SESSION_ID,
             "cwd": str(fx.repo), "tool_name": "Bash",
             "tool_input": {"command": "ls -la"}}
    bypass = dict(plain, tool_input={"command": 'git commit --no-verify -m "x"'})
    return [
        Scenario("pretooluse-dispatcher.py",
                 "plain command (guards imported, nothing matches; the hot path)",
                 dispatch, _p(plain), 1 - w.bash_no_verify,
                 event="PreToolUse", matcher="Bash",
                 expect_stdout="{}", reject_stdout="deny"),
        Scenario("pretooluse-dispatcher.py",
                 "git commit --no-verify (the guard refuses)",
                 dispatch, _p(bypass), w.bash_no_verify,
                 event="PreToolUse", matcher="Bash",
                 expect_stdout='"deny"',
                 env={"GIT_NO_VERIFY_OVERRIDE": None}),
        Scenario("pretooluse-dispatcher.py",
                 "ordinary write (guards imported, no config match; the common path)",
                 dispatch,
                 _p(dict(plain, tool_name="Write",
                         tool_input={"file_path": str(fx.root / "notes.md"),
                                     "content": "x"})),
                 1 - w.guard_config, event="PreToolUse", matcher=WRITE_MATCHER,
                 expect_stdout="{}", reject_stdout="deny"),
        Scenario("pretooluse-dispatcher.py",
                 "write to an existing ruff.toml (config protection refuses)",
                 dispatch,
                 _p(dict(plain, tool_name="Write",
                         tool_input={"file_path": str(fx.ruff_toml),
                                     "content": "line-length = 200\n"})),
                 w.guard_config, event="PreToolUse", matcher=WRITE_MATCHER,
                 expect_stdout='"deny"'),
    ]


def _post_tool_use(fx: Fixtures, w: Weights) -> list:
    """Return the PostToolUse scenarios, both sides of the early exit."""
    lint = [PY3, str(HOOKS_DIR / "posttooluse-python-lint.py")]
    base = {"hook_event_name": "PostToolUse", "session_id": SESSION_ID,
            "cwd": str(fx.repo), "tool_name": "Edit", "duration": 12,
            "tool_response": {"success": True}}
    return [
        Scenario("posttooluse-python-lint.py",
                 "non-python path (exits before ruff, mypy and the extra checks)",
                 lint, _p(dict(base, tool_input={"file_path": str(fx.root / "x.md")})),
                 1 - w.lint_py, event="PostToolUse", matcher=WRITE_MATCHER,
                 expect_stdout="{}", max_floors=1.5),
        Scenario("posttooluse-python-lint.py",
                 "real .py file (ruff plus mypy plus any extra checks)",
                 lint, _p(dict(base, tool_input={"file_path": str(fx.py_dirty)})),
                 w.lint_py, event="PostToolUse", matcher=WRITE_MATCHER,
                 min_floors=1.5),
    ]


def _stop_and_end(fx: Fixtures, w: Weights) -> list:
    """Return the Stop, SessionEnd, PreCompact and UserPromptSubmit scenarios."""
    done_gate = [PY3, str(HOOKS_DIR / "stop-done-gate.py")]
    bench_gate = [PY3, str(HOOKS_DIR / "stop-harness-bench-gate.py")]
    lineage = [PY3, str(HOOKS_DIR / "herdr-lineage-status.py")]
    sticky = [PY3, str(HOOKS_DIR / "herdr-sticky-prompt.py")]
    stop = {"hook_event_name": "Stop", "session_id": SESSION_ID, "cwd": str(fx.repo),
            "stop_hook_active": False}
    sandbox = {"HARNESS_WORKSPACE": str(fx.workspace)}
    stub_env = {"HERDR_ENV": "1", "HERDR_PANE_ID": "w1:p1",
                "HERDR_BIN_PATH": str(fx.herdr_stub),
                "HARNESS_BENCH_AGENTS": str(fx.root / "agents.json")}
    bench_env = dict(sandbox, HARNESS_BENCH_STORE=str(fx.store))
    out = _done_gate_scenarios(fx, done_gate, stop, w)
    out += [
        Scenario("stop-harness-bench-gate.py",
                 "no harness edit in the transcript (exits after the tail read)",
                 bench_gate,
                 _p(dict(stop, transcript_path=str(fx.transcripts["footer"]))),
                 1 - w.stop_harness_edit, event="Stop",
                 env=dict(bench_env), expect_stdout=""),
        Scenario("stop-harness-bench-gate.py",
                 "a hook was edited (fingerprints the whole hook tree, then blocks)",
                 bench_gate,
                 _p(dict(stop, transcript_path=str(fx.transcripts["harness"]))),
                 w.stop_harness_edit, event="Stop",
                 env=dict(bench_env), expect_stdout='"block"'),
        Scenario("herdr-lineage-status.py", "no pane in the environment (early exit)",
                 lineage, _p(stop), 0.0, event="Stop",
                 env={"HERDR_ENV": None}, max_floors=1.4),
        Scenario("herdr-lineage-status.py", "stubbed CLI, live agent list replayed",
                 lineage, _p(stop), 1.0, event="Stop", env=dict(stub_env),
                 fidelity="partial: the real multiplexer CLI start is replaced by a "
                          "shell stub; add its floor back once per agent-list call"),
        Scenario("herdr-sticky-prompt.py", "empty prompt (exits before both side effects)",
                 sticky, _p({"hook_event_name": "UserPromptSubmit"}), 0.0,
                 event="UserPromptSubmit", max_floors=1.4),
        Scenario("herdr-sticky-prompt.py", "real prompt (state write plus pane rename)",
                 sticky, _p({"hook_event_name": "UserPromptSubmit",
                             "prompt": "benchmark payload, please ignore"}), 1.0,
                 event="UserPromptSubmit",
                 env={"HOME": str(fx.home), "HERDR_ENV": "1",
                      "HERDR_PANE_ID": "w1:p1", "HERDR_BIN_PATH": "/usr/bin/true",
                      "HARNESS_WORKSPACE": str(fx.workspace)},
                 fidelity="partial: /usr/bin/true stands in for the pane rename"),
    ]
    out += _lifecycle_scenarios(fx)
    return out


def _done_gate_scenarios(fx: Fixtures, argv: list, stop: JSON, w: Weights) -> list:
    """Return the three stop-done-gate branches, each on its own fixture."""
    sandbox = {"HARNESS_WORKSPACE": str(fx.workspace)}
    return [
        Scenario("stop-done-gate.py", "turn with a valid footer (pass on the first read)",
                 argv, _p(dict(stop, transcript_path=str(fx.transcripts["footer"]))),
                 w.stop_footer, event="Stop", env=dict(sandbox), expect_stdout="",
                 requires="no footer", max_floors=6.0),
        Scenario("stop-done-gate.py", "turn that used no tool (passes free)",
                 argv, _p(dict(stop, transcript_path=str(fx.transcripts["notool"]))),
                 w.stop_no_tool, event="Stop", env=dict(sandbox), expect_stdout="",
                 requires="no footer", max_floors=6.0),
        Scenario("stop-done-gate.py",
                 "no footer (polls to the settle deadline in small steps, then blocks)",
                 argv, _p(dict(stop, transcript_path=str(fx.transcripts["nofooter"]))),
                 w.stop_no_footer, event="Stop", env=dict(sandbox),
                 expect_stdout='"block"'),
    ]


def _lifecycle_scenarios(fx: Fixtures) -> list:
    """Return the SessionEnd and PreCompact scenarios, both sandboxed."""
    script = str(HOOKS_DIR / "session-lifecycle.sh")
    payload = _p({"hook_event_name": "SessionEnd", "session_id": SESSION_ID,
                  "cwd": str(fx.repo), "transcript_path": str(fx.transcripts["footer"]),
                  "reason": "other"})
    compact = _p({"hook_event_name": "PreCompact", "session_id": SESSION_ID,
                  "cwd": str(fx.repo), "transcript_path": str(fx.transcripts["footer"]),
                  "trigger": "auto"})
    return [
        Scenario("session-lifecycle.sh",
                 "fresh sandbox workspace per run (wrap, gzip, cleanup pass)",
                 ["bash", script], payload, 1.0, event="SessionEnd",
                 fresh_workspace=True, marker=JOURNAL_MARKER,
                 fidelity="partial: an empty sandbox registry means no registered "
                          "worktrees, so the cleanup pass skips all of its git work"),
        Scenario("session-lifecycle.sh",
                 "reused sandbox workspace (state file cached, as in production)",
                 ["bash", script], compact, 1.0, event="PreCompact",
                 env={"HARNESS_WORKSPACE": str(fx.workspace)}, marker=JOURNAL_MARKER),
    ]


def build_scenarios(fx: Fixtures, w: Weights) -> list:
    """Return every scenario, one hook branch each, weighted by the corpus."""
    return (_session_start(fx) + _pre_tool_use(fx, w)
            + _post_tool_use(fx, w) + _stop_and_end(fx, w))


# ----------------------------------------------------------------- running


def workspace_for(sc: Scenario, fx: Fixtures) -> Path:
    """Return the HARNESS_WORKSPACE this run will use: fresh, or the sandbox.

    Never the real one. Unlike a brain path, a workspace holds no file a hook
    audits, so a scratch tree changes no branch and the containment is free.
    """
    if sc.fresh_workspace:
        return Path(tempfile.mkdtemp(dir=fx.root, prefix="workspace-"))
    override = sc.env.get("HARNESS_WORKSPACE")
    return Path(override) if override else fx.workspace


def _env_for(sc: Scenario, fx: Fixtures, workspace: Path) -> dict:
    """Return the child environment: the real one, plus this scenario's overrides."""
    env = dict(os.environ)
    env["HARNESS_WORKSPACE"] = str(workspace)
    env["HARNESS_HOME"] = str(HARNESS_HOME)
    env["HOME"] = str(HOME)
    env.pop("DONE_GATE_DISABLE", None)
    env.pop("HARNESS_BENCH_GATE_DISABLE", None)
    for name, value in sc.env.items():
        if value is None:
            env.pop(name, None)
        else:
            env[name] = value
    env.setdefault("HARNESS_BENCH_AGENTS", str(fx.root / "agents.json"))
    return env


def run_once(sc: Scenario, fx: Fixtures) -> tuple[float, int, str, Path]:
    """Run the hook once and return (seconds, exit code, stdout, workspace used)."""
    workspace = workspace_for(sc, fx)
    env = _env_for(sc, fx, workspace)
    start = time.perf_counter()
    try:
        done = subprocess.run(  # noqa: S603
            sc.argv, input=sc.payload, capture_output=True, text=True,
            env=env, cwd=str(fx.root), timeout=120, check=False,
        )
        elapsed = time.perf_counter() - start
        return elapsed, done.returncode, done.stdout, workspace
    except (OSError, subprocess.SubprocessError) as err:
        return time.perf_counter() - start, -1, f"<failed: {err}>", workspace


def validate(sc: Scenario, fx: Fixtures) -> tuple[bool, str]:
    """Run the scenario once and check the payload reached the intended branch."""
    _, code, out, workspace = run_once(sc, fx)
    if sc.expect_exit is not None and code != sc.expect_exit:
        return False, f"exit {code}, wanted {sc.expect_exit}"
    if sc.expect_stdout == "" and out.strip():
        return False, f"wanted empty stdout, got {out.strip()[:60]!r}"
    if sc.expect_stdout and sc.expect_stdout not in out:
        return False, f"stdout missing {sc.expect_stdout!r}"
    if sc.reject_stdout and sc.reject_stdout in out:
        return False, f"stdout carries {sc.reject_stdout!r}, so the wrong branch ran"
    if sc.marker and not glob.glob(str(workspace / sc.marker)):
        return False, f"the hook wrote no {sc.marker} under its workspace"
    return True, "payload reached the branch"


def measure(sc: Scenario, fx: Fixtures, runs: int) -> Stats:
    """Time the scenario, discarding warmup runs, and return its distribution."""
    warm = [run_once(sc, fx)[0] for _ in range(WARMUP_RUNS)]
    if statistics.median(warm) > SLOW_SCENARIO_S:
        runs = min(runs, SLOW_SCENARIO_RUNS)
    samples = sorted(run_once(sc, fx)[0] * 1000 for _ in range(runs))
    return Stats(
        n=len(samples), min=round(samples[0], 2), p50=round(_pct(samples, 50), 2),
        mean=round(statistics.fmean(samples), 2), p95=round(_pct(samples, 95), 2),
        p99=round(_pct(samples, 99), 2), max=round(samples[-1], 2),
        stddev=round(statistics.pstdev(samples), 2),
    )


def _pct(sorted_values: list, pct: float) -> float:
    """Return the nearest-rank percentile of an already sorted list."""
    if not sorted_values:
        return 0.0
    rank = int(-(-pct / 100 * len(sorted_values) // 1))
    return sorted_values[min(max(rank, 1), len(sorted_values)) - 1]


def floors(fx: Fixtures) -> dict:
    """Return the p50 start cost of each interpreter, so a slow hook is separable.

    An absent binary is not an error: its probe is skipped, the floor is simply
    not reported, and every band assertion that would have used it is skipped
    with it.
    """
    probes = {
        "bash": ["bash", "-c", "true"],
        "python": [PY3, "-c", "pass"],
        "node": ["node", "-e", ""],
        "herdr": [os.environ.get("HERDR_BIN_PATH") or "herdr", "agent", "list"],
    }
    out: dict = {}
    for name, argv in probes.items():
        if not (os.path.exists(argv[0]) or shutil.which(argv[0])):
            continue
        probe = Scenario("floor", name, argv, "", 0.0)
        out[name] = measure(probe, fx, 20).p50
    return out


# ------------------------------------------------------------------ volume


def transcript_volume(since: str | None) -> JSON:
    """Return the invocation volume transcript-stats.py reads off the corpus.

    The window is passed through as --since, because the per-turn invocation
    rates are corpus-derived too: how often Bash fires in a turn is behaviour,
    and weighting this year's hook cost by last year's tool mix is the same
    mistake as weighting a branch by a rate that no longer holds.
    """
    argv = [sys.executable, str(STATS_TOOL), "--json"]
    if since:
        argv += ["--since", since]
    done = subprocess.run(  # noqa: S603
        argv, capture_output=True, text=True, timeout=600, check=False,
    )
    if done.returncode != 0:
        raise RuntimeError(f"transcript-stats.py failed: {done.stderr.strip()[:200]}")
    parsed: JSON = json.loads(done.stdout)
    return parsed


def rates(volume: JSON) -> tuple[dict, float]:
    """Return per-turn invocation rates by (event, matcher), and turns per session."""
    turns = float(volume["turns"]["turns"]) or 1.0
    sessions = float(volume["corpus"]["sessions"]) or 1.0
    per_session = turns / sessions
    out: dict = {}
    for row in volume["matchers"]:
        out[(row["event"], row["matcher"])] = float(row["invocations_per_turn"])
    out[("SessionStart", "*")] = 1.0 / per_session
    out[("SessionEnd", "*")] = 1.0 / per_session
    out[("PreCompact", "*")] = PRECOMPACT_PER_SESSION / per_session
    out[("Stop", "*")] = 1.0
    out[("UserPromptSubmit", "*")] = 1.0
    return out, per_session


def rate_for(wiring: Wiring, table: dict) -> float:
    """Return the per-turn invocation rate for one wiring."""
    exact = table.get((wiring.event, wiring.matcher))
    if exact is not None:
        return exact
    return table.get((wiring.event, "*"), 0.0)


# ------------------------------------------------------------------ context


def harness_fingerprint() -> str:
    """Return one SHA-256 over the harness state this run measures.

    Delegates to hooks/harness_fingerprint.py so the Stop gate, which lives
    beside that module, computes the identical value. Two copies would agree
    until one was edited, and the gate would then fire on a difference that is
    not a change.
    """
    try:
        sys.path.insert(0, str(HOOKS_DIR))
        import harness_fingerprint as hf  # type: ignore[import-not-found]  # noqa: PLC0415
        return hf.fingerprint()
    except Exception:
        return ""


def run_context() -> JSON:
    """Return everything needed to judge whether this run is comparable."""
    return {
        "harness_sha": harness_fingerprint(),
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "hostname": socket.gethostname(),
        "harness_commit": _commit(),
        "cpu_count": os.cpu_count(),
        "load_start": round(LOAD_AT_START, 2),
        "platform": platform.platform(),
        "python": _version([PY3, "-V"]),
        "bash": _version(["bash", "-c", "echo $BASH_VERSION"]),
        "node": _version(["node", "-v"]),
    }


def _commit() -> str:
    """Return the clone's current commit, or 'unknown' when it cannot be read."""
    try:
        done = subprocess.run(  # noqa: S603
            [GIT, "-C", str(HARNESS_HOME), "rev-parse", "--short", "HEAD"],
            capture_output=True, text=True, timeout=10, check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return "unknown"
    return done.stdout.strip() or "unknown"


def _version(argv: list) -> str:
    """Return a tool's version string, or 'absent' when the tool is missing."""
    try:
        done = subprocess.run(  # noqa: S603
            argv, capture_output=True, text=True, timeout=10, check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return "absent"
    raw = (done.stdout or done.stderr or "").strip()
    return raw.splitlines()[0] if raw else "absent"


# ------------------------------------------------------------------ report


def hook_cost(wiring: Wiring, results: dict) -> tuple[float, bool]:
    """Return one wiring's weighted per-call cost and whether every part is trusted."""
    total, trusted = 0.0, True
    for res in results.values():
        if not res.scenario.wires(wiring) or res.scenario.weight <= 0:
            continue
        total += res.scenario.weight * res.stats.p50
        trusted = trusted and res.trusted
    return round(total, 2), trusted


def headline(wirings: list, results: dict, table: dict, per_session: float) -> JSON:
    """Return the per-turn and per-session cost of every wiring, and the totals."""
    rows: list = []
    turn_ms = 0.0
    for wiring in wirings:
        cost, trusted = hook_cost(wiring, results)
        if cost == 0.0:
            continue
        rate = rate_for(wiring, table)
        per_turn = cost * rate
        turn_ms += per_turn
        rows.append({
            "event": wiring.event, "matcher": wiring.matcher, "hook": wiring.key,
            "per_call_ms": cost, "per_turn_calls": round(rate, 3),
            "per_turn_ms": round(per_turn, 1),
            "per_session_ms": round(per_turn * per_session, 1), "trusted": trusted,
        })
    rows.sort(key=lambda r: -float(r["per_turn_ms"]))
    return {"rows": rows, "per_turn_ms": round(turn_ms, 1),
            "per_session_ms": round(turn_ms * per_session, 1),
            "turns_per_session": round(per_session, 2)}


def render(report: JSON) -> None:
    """Print the report: the per-turn headline first, the per-scenario table after."""
    _render_context(report)
    _render_headline(report)
    _render_stability(report)
    _render_weights(report)
    _render_skips(report)
    _render_scenarios(report)


def _render_context(report: JSON) -> None:
    """Print the run context and the load-average warning."""
    ctx = report["context"]
    print(f"harness-bench  {ctx['timestamp']}  harness {ctx['harness_commit']}  "
          f"{ctx['hostname']}")
    print(f"  {ctx['cpu_count']} cpus, load {ctx['load_start']} -> {report['load_end']}, "
          f"{ctx['python']}, bash {ctx['bash']}, node {ctx['node']}")
    print(f"  safety classification from {SAFETY_DOC}")
    print(f"  volume from transcript-stats.py: {report['corpus']['sessions']} sessions, "
          f"{int(report['corpus']['turns'])} turns, "
          f"{report['headline']['turns_per_session']} turns per session")
    print(f"  stop-gate fixtures padded to {report['fixture_transcript_kb']} KB, "
          "the corpus mean transcript size")
    if max(ctx["load_start"], report["load_end"]) > LOAD_WARN:
        print(f"\n  ** WARNING: load average above {LOAD_WARN}. The machine is too busy "
              "for a trustworthy baseline. Treat every number here as an upper bound "
              "and re-run on an idle machine before storing a baseline. **")


def _render_headline(report: JSON) -> None:
    """Print the per-turn and per-session cost, which is the number that matters."""
    head = report["headline"]
    print(f"\n{'=' * 92}\nWHAT THE HOOK SET COSTS")
    print(f"  {head['per_turn_ms']} ms per turn, {head['per_session_ms']} ms per session "
          f"({head['per_session_ms'] / 1000:.1f} s)")
    print(f"{'=' * 92}")
    print(f"  {'event':<16} {'matcher':<20} {'hook':<34} "
          f"{'/turn':>7} {'ms/turn':>8} {'ms/sess':>9}")
    for row in head["rows"]:
        flag = "" if row["trusted"] else "  UNTRUSTED"
        print(f"  {row['event']:<16} {row['matcher'][:20]:<20} {row['hook'][:34]:<34} "
              f"{row['per_turn_calls']:>7.3f} {row['per_turn_ms']:>8.1f} "
              f"{row['per_session_ms']:>9.1f}{flag}")


def _render_stability(report: JSON) -> None:
    """Print the weight-stability verdict, which says whether the headline holds.

    A weight that is still moving inside its own window means the behaviour is
    still changing, so the per-turn total above it is provisional. That is the
    check a whole-corpus average never gets to make, and its absence is how a
    stale weight silently overstates the hook that changed the behaviour.
    """
    window = report["window"]
    branches = report["weights"]["branches"]
    print(f"\n{'-' * 92}\nWEIGHT STABILITY (each weight over the window's two halves)")
    if window["split_date"] is None:
        print("  the window holds less than two dated days, so no half-split is possible")
        return
    print(f"  split at {window['split_date']}; a weight is flagged when it moved by more "
          f"than {STABILITY_RATIO}x")
    for row in branches:
        _render_branch_halves(row)
    if window["unstable"]:
        names = ", ".join(window["unstable"])
        print(f"\n  ** WARNING: {len(window['unstable'])} weight(s) moved by more than "
              f"{STABILITY_RATIO}x inside the window: {names}. Behaviour is still "
              "changing, or the window is too long. Every per-turn number above is "
              "provisional; re-run with a shorter --window-days and compare. **")
    elif not any(b["halves_known"] for b in branches):
        print(f"\n  no weight has {MIN_OBSERVATIONS} observations in both halves, so "
              "none of them could be judged. Stability is unknown, not confirmed")
    else:
        print("\n  no weight moved by more than "
              f"{STABILITY_RATIO}x, so the window is settled and the headline stands")


def _render_branch_halves(row: JSON) -> None:
    """Print one weight's two halves and whichever caveat applies to it."""
    if not row["halves_known"]:
        print(f"  {row['name']:<18} {row['value']:>7.2%}  halves not comparable: "
              f"{row['first_denominator']} and {row['second_denominator']} observations, "
              f"under the {MIN_OBSERVATIONS} floor")
        return
    if row["ratio"] is not None:
        ratio = f"{row['ratio']:.2f}x"
    elif row["first_half"] == row["second_half"]:
        ratio = "never taken"
    else:
        ratio = "zero one side"
    flag = "  ** MOVED **" if row["unstable"] else ""
    print(f"  {row['name']:<18} {row['value']:>7.2%}  first half {row['first_half']:>7.2%}  "
          f"second half {row['second_half']:>7.2%}  {ratio:>12}{flag}")


def _thin(w: JSON, name: str) -> str:
    """Return the low-sample caveat for one weight, or an empty string."""
    row = next((b for b in w["branches"] if b["name"] == name), None)
    if row is None or not row["thin"]:
        return ""
    return (f" [only {row['observations']} of {row['denominator']} observations, "
            f"under the {MIN_OBSERVATIONS} floor: indicative]")


def _render_weights(report: JSON) -> None:
    """Print the branch weights, so nobody has to guess what a hook cost is made of."""
    w = report["weights"]
    window = report["window"]
    print(f"\n{'-' * 92}\nBRANCH WEIGHTS (counted off the corpus, not assumed)")
    print(f"  window: {window['label']}; {window['turns_in_window']} turns kept, "
          f"{window['turns_excluded']} older turns dropped, "
          f"{window['turns_undated']} undated")
    print(f"  turns run {window['corpus_first']} .. {window['corpus_last']}")
    print(f"  of {w['bash_calls']} Bash calls: {w['bash_no_verify']:.2%} try to skip the "
          f"git hooks, so the guard refuses{_thin(w, 'bash_no_verify')}")
    print(f"  of {w['edit_calls']} Write/Edit calls: {w['lint_py']:.1%} are .py "
          f"(ruff and mypy run){_thin(w, 'lint_py')}, "
          f"{w['guard_config']:.2%} are a protected config{_thin(w, 'guard_config')}")
    print(f"  of {w['turns']} turns: {w['stop_footer']:.1%} carry a footer"
          f"{_thin(w, 'stop_footer')}, {w['stop_no_tool']:.1%} used no tool"
          f"{_thin(w, 'stop_no_tool')}, {w['stop_no_footer']:.1%} used a tool "
          f"with no footer and pay the settle poll{_thin(w, 'stop_no_footer')}")
    print(f"  of {w['turns']} turns: {w['stop_harness_edit']:.2%} edited the harness "
          f"itself, so the bench gate fingerprints it{_thin(w, 'stop_harness_edit')}")
    print(f"  this scan counts {w['turns']} turns where transcript-stats.py counts "
          f"{int(report['corpus']['turns'])}; the two segment a turn slightly "
          "differently, so treat the Stop split as close, not exact")


def _render_skips(report: JSON) -> None:
    """Print every hook that was skipped or sandboxed, and why."""
    print(f"\n{'-' * 92}\nSAFETY")
    for row in report["safety"]:
        print(f"  {row['verdict']:<8} {row['hook']}")
        print(f"           {row['reason']}")
        print(f"           action: {row['action']}")
    joined = ", ".join(f"{k} {v:.1f} ms" for k, v in report["floors"].items())
    print(f"\n  interpreter and binary floors (p50): {joined}")


def _render_scenarios(report: JSON) -> None:
    """Print the per-scenario statistics table."""
    print(f"\n{'-' * 92}\nPER SCENARIO (milliseconds)")
    head = (f"  {'scenario':<62} {'n':>3} {'min':>7} {'p50':>7} {'mean':>7} "
            f"{'p95':>7} {'p99':>7} {'max':>8} {'sd':>6} {'marg':>7}")
    print(head)
    for row in report["scenarios"]:
        st = row["stats"]
        print(f"  {row['id'][:62]:<62} {st['n']:>3} {st['min']:>7.1f} {st['p50']:>7.1f} "
              f"{st['mean']:>7.1f} {st['p95']:>7.1f} {st['p99']:>7.1f} {st['max']:>8.1f} "
              f"{st['stddev']:>6.1f} {row['marginal_ms']:>7.1f}")
        if not row["trusted"]:
            print(f"      UNTRUSTED: {row['detail']}")
        if row["fidelity"] != "full":
            print(f"      fidelity: {row['fidelity']}")


# ------------------------------------------------------------- persistence


def store(report: JSON) -> None:
    """Append one run to the benchmark log, creating its directory if needed."""
    STORE.parent.mkdir(parents=True, exist_ok=True)
    with STORE.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(report) + "\n")


def load_run(which: str) -> JSON:
    """Return a stored run by id, or the most recent one for 'last'."""
    if not STORE.is_file():
        raise RuntimeError(f"no stored runs at {STORE}")
    runs: list = [json.loads(ln) for ln in STORE.read_text().splitlines() if ln.strip()]
    if not runs:
        raise RuntimeError(f"no stored runs at {STORE}")
    if which == "last":
        return runs[-1]
    for run in runs:
        if run.get("run_id") == which:
            return run
    raise RuntimeError(f"no stored run with id {which}")


WINDOW_KEYS = ("days", "start", "end", "corpus_first", "corpus_last")


def window_mismatch(now: JSON, before: JSON) -> str | None:
    """Return why two runs cannot be compared, or None when they can.

    Two runs whose weights were counted over different slices of the corpus are
    not comparable: the same hook set weighted over 14 days and over the whole
    corpus differs by more than any real regression would, and the difference
    would read as one. So this refuses rather than printing a delta.
    """
    mine, theirs = now.get("window"), before.get("window")
    if not isinstance(theirs, dict):
        return (f"the stored run {before.get('run_id', '?')} records no weighting "
                "window, so what its weights were counted over is unknown")
    if not isinstance(mine, dict):
        return "this run records no weighting window"
    differing = [k for k in WINDOW_KEYS if mine.get(k) != theirs.get(k)]
    if not differing:
        return None
    parts = ", ".join(f"{k}: {theirs.get(k)!r} then, {mine.get(k)!r} now"
                      for k in differing)
    return (f"the two runs weighted different slices of the corpus ({parts}). "
            f"Stored: {theirs.get('label')}. This run: {mine.get('label')}")


def _refuse(now: JSON, refusal: str) -> int:
    """Print why two runs cannot be compared and return the refusal exit code."""
    print(f"compare REFUSED: {refusal}")
    print("  A per-turn cost is its branch weights times its per-call costs, so two "
          "runs weighted over different windows are not comparable and the difference "
          "would read as a regression.")
    print("  Re-run both sides with the same --window-days (this run used "
          f"{(now.get('window') or {}).get('days')}).")
    return 2


def compare(now: JSON, before: JSON, threshold: float) -> int:
    """Print a delta table against a stored run and return the exit code."""
    refusal = window_mismatch(now, before)
    if refusal is not None:
        return _refuse(now, refusal)
    old = {row["id"]: row["stats"]["p50"] for row in before["scenarios"]}
    thin = [r["run_id"] for r in (before, now)
            if int(r.get("runs_requested") or 0) < MIN_COMPARE_RUNS]
    if thin:
        print(f"  ** {' and '.join(thin)} used fewer than {MIN_COMPARE_RUNS} runs. "
              "Identical runs drift by about a third at 5 runs, so a delta below that "
              "sample size is noise, not a regression. Re-run both sides. **")
    if now["run_id"] == before["run_id"]:
        print("compare REFUSED: that is this same run. A run compared against "
              "itself reports 0.0% for every scenario, which reads as 'no "
              "regression' when nothing was measured against anything.")
        return 1
    print(f"compare: {now['run_id']} against {before['run_id']} "
          f"({before['context']['timestamp']}, harness "
          f"{before['context'].get('harness_commit', 'unknown')})")
    print(f"  window {(before.get('window') or {}).get('label')}")
    print(f"  threshold {threshold}%\n")
    print(f"  {'scenario':<62} {'was':>9} {'now':>9} {'delta':>9}")
    regressed = 0
    for row in now["scenarios"]:
        was = old.get(row["id"])
        if was is None:
            print(f"  {row['id'][:62]:<62} {'new':>9} {row['stats']['p50']:>9.1f}")
            continue
        now_p50 = row["stats"]["p50"]
        pct = ((now_p50 - was) / was * 100) if was else 0.0
        mark = ""
        if pct > threshold:
            mark, regressed = "  REGRESSED", regressed + 1
        print(f"  {row['id'][:62]:<62} {was:>9.1f} {now_p50:>9.1f} {pct:>8.1f}%{mark}")
    total_pct = _delta(now, before, "per_turn_ms")
    print(f"\n  per turn: {before['headline']['per_turn_ms']} -> "
          f"{now['headline']['per_turn_ms']} ms ({total_pct:+.1f}%)")
    if len(now["scenarios"]) != len(before["scenarios"]):
        print(f"  that total covers {len(now['scenarios'])} scenarios now against "
              f"{len(before['scenarios'])} then, so it is not comparable. Only the "
              "per-scenario rows above are; drop --only for a comparable total")
    if regressed:
        print(f"\n  {regressed} scenario(s) regressed by more than {threshold}%")
    return 1 if regressed else 0


def _delta(now: JSON, before: JSON, field_name: str) -> float:
    """Return the percentage change in one headline field."""
    was = float(before["headline"][field_name]) or 0.0
    return ((float(now["headline"][field_name]) - was) / was * 100) if was else 0.0


# -------------------------------------------------------------------- main


def safety_rows(wirings: list, ran: set, include_unsafe: bool) -> list:
    """Return one row per distinct hook saying what was run, sandboxed or skipped."""
    rows: list = []
    seen: set = set()
    for wiring in wirings:
        label = f"{wiring.key} [{wiring.event}]"
        if label in seen:
            continue
        seen.add(label)
        entry = SAFETY.get(wiring.safety_key)
        if entry is None:
            rows.append({"hook": label, "verdict": "UNKNOWN",
                         "reason": f"not classified in {SAFETY_DOC}",
                         "action": "SKIPPED: nothing says it is safe to execute"})
            continue
        rows.append({"hook": label, "verdict": entry.verdict,
                     "reason": entry.reason,
                     "action": _action(wiring.safety_key, entry, ran, include_unsafe)})
    return rows


def _action(key: str, entry: Safety, ran: set, include_unsafe: bool) -> str:
    """Return what the benchmark did with one hook, and why."""
    if key not in ran:
        if entry.verdict == "UNSAFE" and not entry.contained:
            return (f"SKIPPED ({entry.reason}). No sandbox keeps the cost honest: "
                    f"{entry.mitigation}. Pass --include-unsafe to run it anyway")
        return "SKIPPED by --only, or no scenario is defined for it"
    if entry.verdict == "SAFE":
        return "ran unsandboxed: no mitigation needed"
    if entry.verdict == "UNSAFE" and not entry.contained:
        return f"ran under --include-unsafe: {entry.mitigation}"
    return f"sandboxed: {entry.mitigation}"


def runnable(sc: Scenario, wirings: list, include_unsafe: bool, only: str | None) -> bool:
    """Report whether this scenario may run under the current flags."""
    if only and only not in sc.ident:
        return False
    if not any(sc.wires(w) for w in wirings):
        return False
    entry = SAFETY.get(sc.safety_key)
    if entry is None:
        return False
    return not (entry.verdict == "UNSAFE" and not entry.contained and not include_unsafe)


def language_of(sc: Scenario, wirings: list) -> str:
    """Return the language of the hook a scenario belongs to."""
    for wiring in wirings:
        if sc.wires(wiring):
            return wiring.language
    return "python"


def execute(scenarios: list, fx: Fixtures, wirings: list,
            runs: int, floor: dict) -> dict:
    """Validate then time every scenario, returning results by scenario id."""
    results: dict = {}
    for sc in scenarios:
        ok, detail = validate(sc, fx)
        print(f"  {'ok  ' if ok else 'FAIL'} {sc.ident}  ({detail})", file=sys.stderr)
        stats = measure(sc, fx, runs)
        lang = language_of(sc, wirings)
        results[sc.ident] = Result(sc, stats, ok, detail, floor.get(lang, 0.0))
    _propagate(results)
    return results


def _propagate(results: dict) -> None:
    """Mark a scenario untrusted when the scenario that validates its fixture failed."""
    for res in results.values():
        need = res.scenario.requires
        if not need:
            continue
        for other in results.values():
            if other.scenario.key == res.scenario.key and need in other.scenario.name:
                if not other.trusted:
                    res.trusted = False
                    res.detail = (f"the fixture is unproven: sibling scenario "
                                  f"'{other.scenario.name}' failed its assertion")
    _bands(results)


def _bands(results: dict) -> None:
    """Check the duration-band assertions, which prove a branch by its cost."""
    for res in results.values():
        sc, floor = res.scenario, res.floor_ms
        if floor <= 0:
            continue
        if sc.min_floors and res.stats.p50 < sc.min_floors * floor:
            res.trusted = False
            res.detail = (f"p50 {res.stats.p50} ms is under {sc.min_floors}x the "
                          f"{floor} ms floor, so the real path did not run")
        if sc.max_floors and res.stats.p50 > sc.max_floors * floor:
            res.trusted = False
            res.detail = (f"p50 {res.stats.p50} ms is over {sc.max_floors}x the "
                          f"{floor} ms floor, so this is not the early exit")


@dataclass(frozen=True)
class RunInputs:
    """The corpus-derived inputs one run is built on."""

    volume: JSON
    weights: Weights
    window: Window


def window_block(run: RunInputs) -> JSON:
    """Return the window record stored with the run, and compared against.

    A stored run whose window is unknown cannot be compared with a later one,
    which is the same class of mistake as weighting a branch over a corpus whose
    behaviour has since changed. So the window, the slice of the corpus it
    selected and the thresholds it was judged by all travel with the run.
    """
    w, volume = run.weights, run.volume
    unstable = [b["name"] for b in w.branches if b["unstable"]]
    return {
        "days": run.window.days, "start": run.window.start, "end": run.window.end,
        "label": run.window.label, "split_date": w.split_date,
        "corpus_first": w.first_date, "corpus_last": w.last_date,
        "stats_since": volume["corpus"].get("since"),
        "turns_in_window": w.turns, "turns_excluded": w.turns_excluded,
        "turns_undated": w.turns_undated,
        "min_observations": MIN_OBSERVATIONS, "stability_ratio": STABILITY_RATIO,
        "unstable": unstable,
        "thin": [b["name"] for b in w.branches if b["thin"]],
        "provisional": bool(unstable),
    }


def build_report(args: argparse.Namespace, wirings: list, fx: Fixtures,
                 results: dict, run: RunInputs) -> JSON:
    """Assemble the JSON object that is printed, stored and compared."""
    volume, w = run.volume, run.weights
    table, per_session = rates(volume)
    ran = {res.scenario.safety_key for res in results.values()}
    return {
        "run_id": time.strftime("%Y%m%dT%H%M%S"),
        "tool": "harness-bench.py",
        "runs_requested": args.runs,
        "include_unsafe": args.include_unsafe,
        "context": run_context(),
        "load_end": round(os.getloadavg()[0], 2),
        "corpus": {"sessions": volume["corpus"]["sessions"],
                   "turns": volume["turns"]["turns"],
                   "files": volume["corpus"]["files"],
                   "first_timestamp": volume["corpus"].get("first_timestamp"),
                   "last_timestamp": volume["corpus"].get("last_timestamp")},
        "window": window_block(run),
        "fixture_transcript_kb": round(fx.transcript_bytes / 1024),
        "weights": vars(w),
        "floors": {k: round(v, 2) for k, v in _floor_cache.items()},
        "wirings": [{"event": x.event, "matcher": x.matcher, "command": x.command,
                     "script": x.script, "hook": x.key, "language": x.language,
                     "source": x.source} for x in wirings],
        "safety": safety_rows(wirings, ran, args.include_unsafe),
        "headline": headline(wirings, results, table, per_session),
        "scenarios": [{"id": r.scenario.ident, "hook": r.scenario.key,
                       "scenario": r.scenario.name, "weight": r.scenario.weight,
                       "trusted": r.trusted, "detail": r.detail,
                       "fidelity": r.scenario.fidelity,
                       "floor_ms": r.floor_ms, "marginal_ms": r.marginal_ms,
                       "stats": vars(r.stats)} for r in results.values()],
    }


_floor_cache: dict = {}


def parse_args(argv: list) -> argparse.Namespace:
    """Return the parsed command line."""
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--runs", type=int, default=DEFAULT_RUNS, help="measured runs per scenario")
    ap.add_argument("--only", help="run only scenarios whose id contains this text")
    ap.add_argument("--window-days", type=int, default=DEFAULT_WINDOW_DAYS,
                    help="count every branch weight over the last N days; 0 for the "
                         "whole corpus, which averages over behaviour that has changed")
    ap.add_argument("--list", action="store_true", help="list wirings and scenarios, run nothing")
    ap.add_argument("--json", action="store_true", help="emit JSON instead of the table")
    ap.add_argument("--compare", help="compare against a stored run id, or 'last'")
    ap.add_argument("--threshold-pct", type=float, default=DEFAULT_THRESHOLD_PCT,
                    help="regression threshold for --compare")
    ap.add_argument("--include-unsafe", action="store_true",
                    help="also run hooks whose side effects no sandbox contains")
    ap.add_argument("--no-store", action="store_true", help="do not append to the run log")
    return ap.parse_args(argv)


def do_list(wirings: list, fx: Fixtures, weights: Weights) -> None:
    """Print every wiring and every scenario without running anything."""
    print(f"{len(wirings)} wired hook commands\n")
    for w in wirings:
        entry = SAFETY.get(w.safety_key)
        verdict = entry.verdict if entry else "UNKNOWN"
        print(f"  {w.event:<16} {w.matcher[:20]:<20} {verdict:<8} {w.key}")
        print(f"      {w.script or w.command}   [{w.language}, {w.source}]")
    scenarios = build_scenarios(fx, weights)
    print(f"\n{len(scenarios)} scenarios, weighted over "
          f"{make_window(weights.window_days, weights.window_end).label}\n")
    for sc in scenarios:
        print(f"  {sc.weight:>5.3f}  {sc.ident}")


def main(argv: list) -> int:
    """Run the benchmark, or list, or compare."""
    args = parse_args(argv)
    wirings = discover()
    window = make_window(args.window_days)
    volume = transcript_volume(window.start)
    corpus_root = str(volume["corpus"].get("root") or HOME / ".claude" / "projects")
    run = RunInputs(volume, scan_corpus(corpus_root, window), window)
    mean_bytes = int(volume["corpus"]["bytes_read"] / max(volume["corpus"]["files"], 1))
    with tempfile.TemporaryDirectory(prefix="harness-bench-") as tmp:
        fx = build_fixtures(Path(tmp), mean_bytes)
        if args.list:
            do_list(wirings, fx, run.weights)
            return 0
        _floor_cache.update(floors(fx))
        scenarios = [s for s in build_scenarios(fx, run.weights)
                     if runnable(s, wirings, args.include_unsafe, args.only)]
        print(f"validating and timing {len(scenarios)} scenarios", file=sys.stderr)
        results = execute(scenarios, fx, wirings, args.runs, _floor_cache)
        report = build_report(args, wirings, fx, results, run)
    return _finish(report, args)


def _finish(report: JSON, args: argparse.Namespace) -> int:
    """Emit, store and optionally compare the finished report."""
    # Resolve the baseline BEFORE storing. Otherwise `last` resolves to the run
    # being appended right now and every delta reads 0.0%, so the regression
    # this tool exists to catch reports as no change.
    baseline = load_run(args.compare) if args.compare else None
    if not args.no_store:
        store(report)
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        render(report)
    if baseline is not None:
        print()
        return compare(report, baseline, args.threshold_pct)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
