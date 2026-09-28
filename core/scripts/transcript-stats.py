#!/usr/bin/env python3
"""Measure tool-call volume in the local Claude Code transcripts.

Reads ~/.claude/projects/**/*.jsonl and reports the numbers that turn a
per-hook millisecond cost into a per-session cost: tool calls per turn, tool
calls by name, and how many historical tool calls each hook matcher in
~/.claude/settings.json would have fired on. It also sizes the
Write/Edit/MultiEdit replay corpus for a false-positive guard test. --json lists the replay file
paths so that test can be built straight from the report.

Read-only. Every transcript is opened for reading and nothing is written.

Turn boundary: a turn opens at a prompt entry (type "user", not isMeta, whose
message content carries no tool_result block) and closes at the next prompt.
Every tool_use block in the assistant entries between the two belongs to that
turn. A prompt with no assistant reply after it (a queued or interrupted
prompt) is not counted as a turn. Only main-thread entries (isSidechain false)
are segmented into turns, because several sidechains interleave inside one
file and cannot be ordered into a single thread; sidechain tool calls are
still counted in every total and reported on their own line.

Duplicate entries: a resumed or forked session copies its parent history into
a new transcript, so the same message uuid appears in more than one file. The
first file that carries a uuid owns it; later copies are skipped. Tool calls
whose opening prompt was skipped that way are counted as orphans, not as a
turn.

Matcher semantics: a Claude Code hook matcher is a regular expression tested
against the tool name, unanchored, and an empty matcher or "*" matches every
tool. This tool applies the same rule.

Usage:
  python3 transcript-stats.py
  python3 transcript-stats.py --since 2026-08-01 --project Cursor-Docs
  python3 transcript-stats.py --json
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
import time
from collections import Counter
from collections.abc import Iterator
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

DEFAULT_ROOT = Path.home() / ".claude" / "projects"
DEFAULT_SETTINGS = Path.home() / ".claude" / "settings.json"
EDIT_TOOLS = ("Write", "Edit", "MultiEdit")
TOOL_EVENTS = ("PreToolUse", "PostToolUse")
PERCENTILES = (50.0, 90.0, 99.0)
MATCH_ALL = ("", "*", ".*")


@dataclass
class Options:
    """Command-line options for one run."""

    root: Path
    settings: Path
    since: str | None
    project: str | None
    top: int = 20
    as_json: bool = False


@dataclass
class Matcher:
    """One hook matcher block from settings.json."""

    event: str
    pattern: str
    hook_count: int
    regex: re.Pattern[str] | None

    def matches(self, tool_name: str) -> bool:
        """Report whether this matcher would fire on a tool name.

        Args:
            tool_name: The tool name as the transcript records it.

        Returns:
            True when the matcher fires.
        """
        if self.regex is None:
            return True
        return self.regex.search(tool_name) is not None


@dataclass
class Counts:
    """Everything accumulated over the whole corpus."""

    tool_calls: Counter[str] = field(default_factory=Counter)
    turn_sizes: list[int] = field(default_factory=list)
    sessions: set[str] = field(default_factory=set)
    seen_uuids: set[str] = field(default_factory=set)
    seen_tool_ids: set[str] = field(default_factory=set)
    edit_paths: set[str] = field(default_factory=set)
    edit_calls: int = 0
    edit_calls_no_path: int = 0
    sidechain_calls: int = 0
    orphan_calls: int = 0
    bad_lines: int = 0
    dupe_entries: int = 0
    files: int = 0
    bytes_read: int = 0
    first_ts: str = ""
    last_ts: str = ""


@dataclass
class TurnState:
    """Per-file state of the turn currently being filled."""

    is_open: bool = False
    size: int = 0
    saw_assistant: bool = False


def percentile(sorted_values: list[int], pct: float) -> int:
    """Return the nearest-rank percentile of an already sorted list.

    Args:
        sorted_values: Values in ascending order.
        pct: Percentile between 0 and 100.

    Returns:
        The value at that rank, or 0 when the list is empty.
    """
    if not sorted_values:
        return 0
    rank = max(1, math.ceil(pct / 100.0 * len(sorted_values)))
    return sorted_values[min(rank, len(sorted_values)) - 1]


def compile_matcher(pattern: str) -> re.Pattern[str] | None:
    """Compile a hook matcher, or return None when it matches every tool.

    Args:
        pattern: The matcher string from settings.json.

    Returns:
        A compiled pattern, or None for a match-everything matcher.
    """
    if pattern in MATCH_ALL:
        return None
    try:
        return re.compile(pattern)
    except re.error:
        return re.compile(re.escape(pattern))


def load_matchers(settings_path: Path) -> list[Matcher]:
    """Read the PreToolUse and PostToolUse matchers from a settings file.

    Args:
        settings_path: Path to a Claude Code settings.json.

    Returns:
        One Matcher per matcher block, in file order. Empty when the file is
        missing or unreadable.
    """
    try:
        raw = json.loads(settings_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    if not isinstance(raw, dict):
        return []
    hooks = raw.get("hooks")
    if not isinstance(hooks, dict):
        return []
    found: list[Matcher] = []
    for event in TOOL_EVENTS:
        blocks = hooks.get(event)
        if not isinstance(blocks, list):
            continue
        for block in blocks:
            if not isinstance(block, dict):
                continue
            pattern = str(block.get("matcher", ""))
            commands = block.get("hooks")
            count = len(commands) if isinstance(commands, list) else 0
            found.append(Matcher(event, pattern, count, compile_matcher(pattern)))
    return found


def iter_lines(path: Path) -> Iterator[str]:
    """Yield every line of a transcript, tolerating undecodable bytes.

    Args:
        path: The .jsonl transcript.

    Yields:
        One raw line at a time.
    """
    with path.open(encoding="utf-8", errors="replace") as handle:
        yield from handle


def resolve_file_path(raw_path: str, cwd: str) -> str:
    """Normalize a tool-input file path against the entry's working directory.

    Args:
        raw_path: The file_path value from the tool input.
        cwd: The cwd the transcript entry recorded, possibly empty.

    Returns:
        A normalized absolute-where-possible path string.
    """
    candidate = Path(raw_path).expanduser()
    if not candidate.is_absolute() and cwd:
        candidate = Path(cwd) / candidate
    return os.path.normpath(str(candidate))


def is_prompt(entry: dict[str, Any]) -> bool:
    """Report whether a user entry opens a turn rather than carrying a result.

    A meta entry is context the harness injected, not a turn start, unless it
    carries a promptSource. A session woken by another pane records its opening
    message as isMeta with promptSource "system" and origin "peer", and that
    message does start the turn.

    Args:
        entry: A decoded transcript entry of type "user".

    Returns:
        True for a prompt, False for a tool_result carrier or an injection.
    """
    if entry.get("isMeta") and not entry.get("promptSource"):
        return False
    message = entry.get("message")
    if not isinstance(message, dict):
        return False
    content = message.get("content")
    if isinstance(content, str):
        return True
    if not isinstance(content, list):
        return False
    return not any(
        isinstance(block, dict) and block.get("type") == "tool_result" for block in content
    )


def tool_uses(entry: dict[str, Any]) -> list[dict[str, Any]]:
    """Return the tool_use blocks of an assistant entry.

    Args:
        entry: A decoded transcript entry of type "assistant".

    Returns:
        The tool_use blocks, possibly empty.
    """
    message = entry.get("message")
    if not isinstance(message, dict):
        return []
    content = message.get("content")
    if not isinstance(content, list):
        return []
    return [
        block
        for block in content
        if isinstance(block, dict) and block.get("type") == "tool_use"
    ]


class Scanner:
    """Walks the transcripts once and accumulates every count."""

    def __init__(self, options: Options) -> None:
        """Store the run options and start with empty counts.

        Args:
            options: The parsed command-line options.
        """
        self.options = options
        self.counts = Counts()
        self.turn = TurnState()

    def scan(self, paths: list[Path]) -> None:
        """Read every transcript in order.

        Args:
            paths: The transcript files to read.
        """
        for path in paths:
            self.counts.files += 1
            try:
                self.counts.bytes_read += path.stat().st_size
            except OSError:
                pass
            self.turn = TurnState()
            self._scan_file(path)
            self._close_turn()

    def _scan_file(self, path: Path) -> None:
        """Decode and handle every line of one transcript.

        Args:
            path: The transcript file.
        """
        try:
            lines = iter_lines(path)
            for line in lines:
                if not line.strip():
                    continue
                try:
                    parsed = json.loads(line)
                except ValueError:
                    self.counts.bad_lines += 1
                    continue
                if not isinstance(parsed, dict):
                    self.counts.bad_lines += 1
                    continue
                self._handle(parsed)
        except OSError:
            self.counts.bad_lines += 1

    def _handle(self, entry: dict[str, Any]) -> None:
        """Route one decoded entry to the right accumulator.

        Args:
            entry: A decoded transcript entry.
        """
        kind = entry.get("type")
        if kind not in ("user", "assistant"):
            return
        if not self._in_window(entry):
            return
        uuid = entry.get("uuid")
        if isinstance(uuid, str) and uuid:
            if uuid in self.counts.seen_uuids:
                self.counts.dupe_entries += 1
                return
            self.counts.seen_uuids.add(uuid)
        session = entry.get("sessionId")
        if isinstance(session, str) and session:
            self.counts.sessions.add(session)
        self._note_timestamp(entry)
        if kind == "user":
            self._handle_user(entry)
        else:
            self._handle_assistant(entry)

    def _in_window(self, entry: dict[str, Any]) -> bool:
        """Report whether an entry passes the --since filter.

        Args:
            entry: A decoded transcript entry.

        Returns:
            True when the entry is inside the window.
        """
        since = self.options.since
        if since is None:
            return True
        stamp = entry.get("timestamp")
        if not isinstance(stamp, str) or not stamp:
            return False
        return stamp[:10] >= since

    def _note_timestamp(self, entry: dict[str, Any]) -> None:
        """Widen the observed date range with this entry's timestamp.

        Args:
            entry: A decoded transcript entry.
        """
        stamp = entry.get("timestamp")
        if not isinstance(stamp, str) or not stamp:
            return
        if not self.counts.first_ts or stamp < self.counts.first_ts:
            self.counts.first_ts = stamp
        self.counts.last_ts = max(stamp, self.counts.last_ts)

    def _handle_user(self, entry: dict[str, Any]) -> None:
        """Open a new turn when the entry is a prompt.

        Args:
            entry: A decoded transcript entry of type "user".
        """
        if entry.get("isSidechain"):
            return
        if not is_prompt(entry):
            return
        self._close_turn()
        self.turn = TurnState(is_open=True)

    def _handle_assistant(self, entry: dict[str, Any]) -> None:
        """Count the tool calls of an assistant entry into the open turn.

        Args:
            entry: A decoded transcript entry of type "assistant".
        """
        sidechain = bool(entry.get("isSidechain"))
        if not sidechain and self.turn.is_open:
            self.turn.saw_assistant = True
        cwd = entry.get("cwd")
        for block in tool_uses(entry):
            self._record_tool(block, cwd if isinstance(cwd, str) else "")
            if sidechain:
                self.counts.sidechain_calls += 1
            elif self.turn.is_open:
                self.turn.size += 1
            else:
                self.counts.orphan_calls += 1

    def _record_tool(self, block: dict[str, Any], cwd: str) -> None:
        """Record one tool_use block in the name and replay counters.

        Args:
            block: The tool_use content block.
            cwd: The working directory the entry recorded.
        """
        tool_id = block.get("id")
        if isinstance(tool_id, str) and tool_id:
            if tool_id in self.counts.seen_tool_ids:
                return
            self.counts.seen_tool_ids.add(tool_id)
        name = block.get("name")
        if not isinstance(name, str) or not name:
            name = "(unnamed)"
        self.counts.tool_calls[name] += 1
        if name not in EDIT_TOOLS:
            return
        self.counts.edit_calls += 1
        tool_input = block.get("input")
        raw_path = tool_input.get("file_path") if isinstance(tool_input, dict) else None
        if isinstance(raw_path, str) and raw_path:
            self.counts.edit_paths.add(resolve_file_path(raw_path, cwd))
        else:
            self.counts.edit_calls_no_path += 1

    def _close_turn(self) -> None:
        """Record the open turn, if an assistant actually answered it."""
        if self.turn.is_open and self.turn.saw_assistant:
            self.counts.turn_sizes.append(self.turn.size)
        self.turn = TurnState()


def find_transcripts(options: Options) -> list[Path]:
    """List the transcripts to read, applying the --project filter.

    Args:
        options: The parsed command-line options.

    Returns:
        Transcript paths in a stable order.
    """
    if not options.root.is_dir():
        return []
    paths = sorted(options.root.rglob("*.jsonl"))
    if options.project:
        needle = options.project.lower()
        paths = [p for p in paths if needle in str(p.parent.name).lower()]
    return paths


def turn_summary(turn_sizes: list[int]) -> dict[str, float]:
    """Summarize the tool-calls-per-turn distribution.

    Args:
        turn_sizes: One tool-call count per turn.

    Returns:
        Count, min, mean, the percentiles and max.
    """
    ordered = sorted(turn_sizes)
    summary: dict[str, float] = {
        "turns": float(len(ordered)),
        "min": float(ordered[0]) if ordered else 0.0,
        "mean": round(sum(ordered) / len(ordered), 2) if ordered else 0.0,
        "max": float(ordered[-1]) if ordered else 0.0,
    }
    for pct in PERCENTILES:
        summary[f"p{int(pct)}"] = float(percentile(ordered, pct))
    return summary


def matcher_rows(matchers: list[Matcher], counts: Counts) -> list[dict[str, Any]]:
    """Compute how many historical tool calls each matcher would have fired on.

    Args:
        matchers: The matcher blocks from settings.json.
        counts: The accumulated corpus counts.

    Returns:
        One row per matcher, with matched calls and hook invocations.
    """
    total_turns = len(counts.turn_sizes) or 1
    rows: list[dict[str, Any]] = []
    for matcher in matchers:
        matched = sum(n for name, n in counts.tool_calls.items() if matcher.matches(name))
        rows.append(
            {
                "event": matcher.event,
                "matcher": matcher.pattern,
                "hooks": matcher.hook_count,
                "matched_calls": matched,
                "hook_invocations": matched * matcher.hook_count,
                "invocations_per_turn": round(matched * matcher.hook_count / total_turns, 3),
            }
        )
    return rows


def build_report(scanner: Scanner, matchers: list[Matcher], elapsed: float) -> dict[str, Any]:
    """Assemble the full machine-readable report.

    Args:
        scanner: The scanner that has already read the corpus.
        matchers: The matcher blocks from settings.json.
        elapsed: Wall-clock seconds the scan took.

    Returns:
        The report as a JSON-serializable dict.
    """
    counts = scanner.counts
    total_calls = sum(counts.tool_calls.values())
    by_name = [
        {
            "tool": name,
            "calls": n,
            "share_pct": round(100.0 * n / total_calls, 2) if total_calls else 0.0,
        }
        for name, n in counts.tool_calls.most_common()
    ]
    return {
        "corpus": {
            "root": str(scanner.options.root),
            "files": counts.files,
            "sessions": len(counts.sessions),
            "bytes_read": counts.bytes_read,
            "malformed_lines": counts.bad_lines,
            "duplicate_entries_skipped": counts.dupe_entries,
            "first_timestamp": counts.first_ts,
            "last_timestamp": counts.last_ts,
            "since": scanner.options.since,
            "project": scanner.options.project,
            "elapsed_seconds": round(elapsed, 3),
        },
        "turns": turn_summary(counts.turn_sizes),
        "tool_calls": {
            "total": total_calls,
            "main_thread": total_calls - counts.sidechain_calls,
            "sidechain": counts.sidechain_calls,
            "orphan": counts.orphan_calls,
            "by_name": by_name,
            "hook_relevant": {
                name: counts.tool_calls.get(name, 0) for name in (*EDIT_TOOLS, "Bash")
            },
        },
        "matchers": matcher_rows(matchers, counts),
        "replay_corpus": {
            "edit_calls": counts.edit_calls,
            "edit_calls_with_path": counts.edit_calls - counts.edit_calls_no_path,
            "edit_calls_without_path": counts.edit_calls_no_path,
            "distinct_file_paths": len(counts.edit_paths),
            "file_paths": sorted(counts.edit_paths),
        },
    }


def render_corpus(report: dict[str, Any], lines: list[str]) -> None:
    """Append the corpus and turn sections of the table.

    Args:
        report: The assembled report.
        lines: The output buffer to append to.
    """
    corpus = report["corpus"]
    turns = report["turns"]
    lines.append("CORPUS")
    lines.append(
        f"  files {corpus['files']}  sessions {corpus['sessions']}  "
        f"turns {int(turns['turns'])}  read {corpus['bytes_read'] / 1e6:.1f} MB "
        f"in {corpus['elapsed_seconds']}s"
    )
    lines.append(
        f"  range {corpus['first_timestamp'][:19] or 'n/a'} .. "
        f"{corpus['last_timestamp'][:19] or 'n/a'}"
    )
    lines.append(
        f"  malformed lines {corpus['malformed_lines']}  "
        f"duplicate entries skipped {corpus['duplicate_entries_skipped']}"
    )
    lines.append("")
    lines.append("TOOL CALLS PER TURN")
    lines.append(
        f"  count {int(turns['turns'])}  min {int(turns['min'])}  p50 {int(turns['p50'])}  "
        f"p90 {int(turns['p90'])}  p99 {int(turns['p99'])}  max {int(turns['max'])}  "
        f"mean {turns['mean']}"
    )
    lines.append("")


def render_tools(report: dict[str, Any], top: int, lines: list[str]) -> None:
    """Append the by-tool section of the table.

    Args:
        report: The assembled report.
        top: How many tool names to show.
        lines: The output buffer to append to.
    """
    calls = report["tool_calls"]
    lines.append(
        f"TOOL CALLS BY NAME (total {calls['total']}, "
        f"main {calls['main_thread']}, sidechain {calls['sidechain']}, "
        f"orphan {calls['orphan']})"
    )
    lines.append(f"  {'tool':<44}{'calls':>8}{'share':>9}")
    for row in calls["by_name"][:top]:
        lines.append(f"  {row['tool']:<44}{row['calls']:>8}{row['share_pct']:>8.2f}%")
    remaining = len(calls["by_name"]) - top
    if remaining > 0:
        lines.append(f"  ... {remaining} more tool names (see --json)")
    hook_relevant = calls["hook_relevant"]
    lines.append(
        "  hook-relevant: "
        + "  ".join(f"{name} {n}" for name, n in hook_relevant.items())
    )
    lines.append("")


def render_matchers(report: dict[str, Any], lines: list[str]) -> None:
    """Append the matcher-volume and replay-corpus sections of the table.

    Args:
        report: The assembled report.
        lines: The output buffer to append to.
    """
    lines.append("HOOK MATCHER VOLUME")
    if not report["matchers"]:
        lines.append("  no PreToolUse or PostToolUse matchers found")
    else:
        lines.append(
            f"  {'event':<13}{'matcher':<22}{'hooks':>6}{'calls':>9}"
            f"{'invocations':>13}{'per turn':>10}"
        )
    for row in report["matchers"]:
        lines.append(
            f"  {row['event']:<13}{row['matcher']:<22}{row['hooks']:>6}"
            f"{row['matched_calls']:>9}{row['hook_invocations']:>13}"
            f"{row['invocations_per_turn']:>10.3f}"
        )
    lines.append("")
    replay = report["replay_corpus"]
    lines.append("REPLAY CORPUS (Write / Edit / MultiEdit)")
    lines.append(
        f"  distinct calls {replay['edit_calls']}  with a file_path "
        f"{replay['edit_calls_with_path']}  without {replay['edit_calls_without_path']}"
    )
    lines.append(f"  distinct file paths {replay['distinct_file_paths']}")


def render_text(report: dict[str, Any], top: int) -> str:
    """Render the whole report as a readable table.

    Args:
        report: The assembled report.
        top: How many tool names to show.

    Returns:
        The rendered text, without a trailing newline.
    """
    lines: list[str] = []
    render_corpus(report, lines)
    render_tools(report, top, lines)
    render_matchers(report, lines)
    return "\n".join(lines)


def parse_args(argv: list[str] | None = None) -> Options:
    """Parse the command line.

    Args:
        argv: Argument list, or None to read sys.argv.

    Returns:
        The parsed options.
    """
    parser = argparse.ArgumentParser(
        description="Measure tool-call volume in the local Claude Code transcripts.",
    )
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT, help="transcript root")
    parser.add_argument(
        "--settings", type=Path, default=DEFAULT_SETTINGS, help="settings.json to read hooks from"
    )
    parser.add_argument("--since", help="only entries on or after this UTC date (YYYY-MM-DD)")
    parser.add_argument("--project", help="only transcripts whose project directory contains this")
    parser.add_argument("--top", type=int, default=20, help="tool names to show in the table")
    parser.add_argument("--json", action="store_true", help="emit JSON instead of a table")
    parsed = parser.parse_args(argv)
    if parsed.since and not re.fullmatch(r"\d{4}-\d{2}-\d{2}", parsed.since):
        parser.error("--since must be YYYY-MM-DD")
    options = Options(
        root=parsed.root.expanduser(),
        settings=parsed.settings.expanduser(),
        since=parsed.since,
        project=parsed.project,
        top=max(1, parsed.top),
        as_json=bool(parsed.json),
    )
    return options


def main(argv: list[str] | None = None) -> int:
    """Run the scan and print the report.

    Args:
        argv: Argument list, or None to read sys.argv.

    Returns:
        0 on success, 1 when the transcript root holds nothing to read.
    """
    options = parse_args(argv)
    paths = find_transcripts(options)
    if not paths:
        print(f"no transcripts under {options.root}", file=sys.stderr)
        return 1
    started = time.monotonic()
    scanner = Scanner(options)
    scanner.scan(paths)
    elapsed = time.monotonic() - started
    report = build_report(scanner, load_matchers(options.settings), elapsed)
    if options.as_json:
        print(json.dumps(report, indent=2, sort_keys=False))
    else:
        print(render_text(report, options.top))
    return 0


if __name__ == "__main__":
    sys.exit(main())
