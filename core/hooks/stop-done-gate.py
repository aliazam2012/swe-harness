#!/usr/bin/env python3
"""Claude Code Stop hook: block a hand-off that skipped the done gate.

The user kept having to ask two things by hand: audit your own work and address
the gaps, and be certain of every statement you make. Rules text in the harness
contract already said both and did not change behaviour, because neither rule
named a moment where it had to happen. This hook is that moment.

Contract (verified against the first-party security-guidance plugin, which is
the reference implementation for a blocking Stop hook):

  - `stop_hook_active` is true on the Stop that follows a hook-forced
    continuation. Exit immediately when it is set, or the block loops.
  - A plain settings.json Stop hook (no `asyncRewake`) is the sync path, which
    reads top-level `decision` and `reason` from stdout JSON. Guidance also
    goes to stderr, the body channel the async path reads, so the hook keeps
    working if it is ever registered with `asyncRewake`.

Fires only on a turn that used a tool. A turn that used no tool made no claim
worth auditing, so pure conversation passes free.

Exit: 0 always. The block is carried by the stdout JSON, not by the exit code.
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))

import harness_config  # noqa: E402

WORKSPACE = harness_config.workspace()
STATE_DIR = WORKSPACE / "done-gate"
STATE_TTL_S = 7 * 24 * 3600
# Read the tail only. A long session's transcript runs to tens of MB and the
# gate only ever looks at the turn in flight.
TAIL_BYTES = 4_000_000

# Claude Code fires Stop and flushes the turn's last assistant message at
# almost the same instant. Measured once at a 66 ms gap: the footer landed,
# this hook read the file 66 ms later, saw no footer, and blocked a reply that
# had one. Whether the race is won or lost is pure timing, so a single read
# cannot decide. Poll instead: a
# compliant turn returns on the first or second read, and only a turn that is
# genuinely missing the footer pays the full wait, which it then spends being
# blocked anyway. Stays well inside the hook's 15 s timeout.
SETTLE_DEADLINE_S = 3.0
SETTLE_POLL_S = 0.15
# The deadline is a guess nobody had measured. Override it to try another one
# without editing the hook; an unparseable value falls back to the default, and
# the ceiling keeps the wait inside the hook's own 15 s timeout.
SETTLE_ENV = "DONE_GATE_SETTLE_S"
SETTLE_MAX_S = 10.0

# One metadata row per settled decision, so the deadline can be set from a
# distribution instead of the single 66 ms observation it was built on. It is
# telemetry, not a document: it lives in the harness workspace and nowhere else.
SETTLE_LOG = WORKSPACE / "gate-settle.jsonl"

# Both lines are required, so a reply cannot pass by naming evidence and
# staying quiet about the gaps.
FOOTER_VERIFIED = re.compile(r"^\s*(?:[-*>]\s*)?(?:\*\*)?verified:", re.I | re.M)
FOOTER_GAPS = re.compile(r"^\s*(?:[-*>]\s*)?(?:\*\*)?gaps:", re.I | re.M)

# The "Needs from you" block. It cannot be required on every turn: a turn that
# needs nothing must not carry one, and no hook can know what a turn needs. So
# the gate reads the reply's own words instead. A reply that puts a question to
# the user has, by its own admission, something it needs, and that ask belongs
# in one place at the end rather than buried in a paragraph to hunt through.
NEEDS_BLOCK = re.compile(r"^\s*(?:[-*>]\s*)?(?:\*\*)?needs? from you\s*:", re.I | re.M)

# Explicit phrases only. A bare "?" is too broad: quoted evidence, a log line and
# a pasted message all carry one, and a gate that fires on those gets disabled.
ASK_PATTERNS = re.compile(
    r"\b(?:"
    r"want me to|should i\b|shall i\b|do you want|would you like|"
    r"let me know|say go\b|your call\b|need your|needs your|"
    r"waiting on you|tell me which|tell me what to|which do you want"
    r")",
    re.I,
)

# Each ask is one line the user can read at a glance. The rule says about fifteen
# words; the gate allows twenty before it complains, so a borderline line passes
# and only a paragraph pretending to be a bullet is caught.
NEEDS_BULLET = re.compile(r"^\s*[-*]\s+(.*\S)\s*$", re.M)
NEEDS_MAX_WORDS = 20

# Quoted evidence is not the reply's own voice. A log line, a pasted message or
# a command output can carry "do you want to retry?" without the reply asking
# the user anything, so strip the quoted forms before looking for an ask.
FENCED = re.compile(r"```.*?```", re.S)
INLINE_CODE = re.compile(r"`[^`\n]*`")
QUOTED_LINE = re.compile(r"^\s*>.*$", re.M)
# A phrase named as an example is not the reply's voice either. A reply
# explaining this very gate wrote an ask phrase inside plain double quotes and
# the gate fired on it. Only double quotes are stripped.
# Apostrophes cannot be paired safely, so "don't want me to" would lose the ask.
QUOTED_SPAN = re.compile("[\"\u201c\u201d][^\"\u201c\u201d\n]*[\"\u201c\u201d]")

GATE = """DONE GATE (mandatory). This turn used tools, but the reply carries no audit
footer. Do not hand it back yet. Run the audit now.

1. Scope. Re-read the request. Every part is done, or is named as not done.
   Never narrow or drop a part in silence.
2. Evidence. Every claim in the reply points at a file, a line, a command
   output, or a log. A claim you cannot point at is not verified.
3. Run it. Code or config you changed gets executed, or read back. Never
   report a result you did not observe.
4. Label the rest. What you could not prove carries [ASSUMPTION], [INFERENCE],
   [GUESS] or [UNVERIFIED] inline, plus what would resolve it.
5. Gaps. Say what is still open, wrong, or risky. Flag your own mistake before
   someone else finds it.

Fix what the audit finds. Correct the reply where it overstated. Then end with
these two lines:

Verified: <what you ran or read to prove the claims>
Gaps: <what is unverified, incomplete or risky, or "none">

"I believe", "should work" and "looks correct" are not evidence. Prove it, or
label it and name what would prove it. This is a gate, not a suggestion, and
this is the audit the user would otherwise have to ask for.
"""

NEEDS_GATE = """DONE GATE (mandatory). This reply asks the user for something, and the ask is
not in one place at the end. Do not hand it back yet.

Collect every ask into one block, immediately before the Verified/Gaps footer:

Needs from you:
- <what the user does, in one plain line>

One line per ask: a decision, an approval, a credential, a sign-off, an answer.
Explain each as you would to someone who has not seen the code. No jargon, no
file paths, about fifteen words at most, and the line says what the user does.

Keep the ask in the body too if it needs context. The block is the summary the
user reads last, so they never have to hunt for what is wanted from them.
"""

NEEDS_LONG_GATE = """DONE GATE (mandatory). The "Needs from you" block is there, but a line in it
is too long to read at a glance. Do not hand it back yet.

Rewrite each of these as one plain line of about fifteen words, saying what the
user does. No jargon, no file paths, no second clause explaining the reasoning.

{offenders}
"""


def read_tail(path: str) -> tuple:
    """Return (entries, bytes_read) for the transcript's JSONL tail, oldest first."""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as handle:
            if size > TAIL_BYTES:
                handle.seek(size - TAIL_BYTES)
                handle.readline()  # drop the partial line the seek landed in
            data = handle.read()
    except OSError:
        return [], 0
    raw = data.decode("utf-8", errors="replace")
    out = []
    for line in raw.splitlines():
        if not line.startswith("{"):
            continue
        try:
            out.append(json.loads(line))
        except ValueError:
            continue
    return out, len(data)


def is_real_prompt(entry: dict) -> bool:
    """True for a prompt the user typed, not a tool result or an injected block.

    Tool results and skill injections both arrive as type "user". A tool result
    carries tool_result content blocks; an injection sets isMeta.
    """
    if entry.get("type") != "user" or entry.get("isSidechain"):
        return False
    if entry.get("isMeta"):
        return False
    content = (entry.get("message") or {}).get("content")
    if isinstance(content, str):
        return bool(content.strip())
    if isinstance(content, list):
        kinds = {b.get("type") for b in content if isinstance(b, dict)}
        return "tool_result" not in kinds
    return False


def current_turn(entries: list) -> tuple:
    """Split the tail at the last real prompt. Returns (prompt_uuid, entries)."""
    start = None
    for i in range(len(entries) - 1, -1, -1):
        if is_real_prompt(entries[i]):
            start = i
            break
    if start is None:
        return None, []
    return entries[start].get("uuid"), entries[start + 1:]


def inspect(turn: list) -> tuple:
    """Return (tool_was_used, assistant_text) for the main-chain turn.

    Sidechain entries are a subagent's own transcript. Its tool calls are not
    the gate's business; the text the user reads is the main chain only.
    """
    used_tool = False
    text = []
    for entry in turn:
        if entry.get("type") != "assistant" or entry.get("isSidechain"):
            continue
        for block in (entry.get("message") or {}).get("content") or []:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "tool_use":
                used_tool = True
            elif block.get("type") == "text":
                text.append(block.get("text") or "")
    return used_tool, "\n".join(text)


def already_fired(session_id: str, prompt_uuid: str) -> bool:
    """One block per prompt, whatever `stop_hook_active` does.

    The recursion guard alone is enough on the documented path. This keeps the
    gate from stalling a turn twice if that flag ever arrives unset.
    """
    if not prompt_uuid:
        return False
    safe = re.sub(r"[^A-Za-z0-9_-]", "_", session_id or "default")[:64]
    marker = STATE_DIR / f"{safe}.json"
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        prune(marker)
        if marker.is_file():
            if json.loads(marker.read_text()).get("prompt_uuid") == prompt_uuid:
                return True
        marker.write_text(json.dumps({"prompt_uuid": prompt_uuid, "at": time.time()}))
    except (OSError, ValueError):
        return False
    return False


def prune(keep: Path) -> None:
    cutoff = time.time() - STATE_TTL_S
    for stale in STATE_DIR.glob("*.json"):
        try:
            if stale != keep and stale.stat().st_mtime < cutoff:
                stale.unlink()
        except OSError:
            pass


def prose_only(text: str) -> str:
    """Drop fenced blocks, inline code, blockquotes and quoted spans.

    What is left is the reply speaking in its own voice, which is the only place
    an ask directed at the user can live.
    """
    for pattern in (FENCED, INLINE_CODE, QUOTED_LINE, QUOTED_SPAN):
        text = pattern.sub(" ", text)
    return text


def needs_verdict(text: str) -> str:
    """Judge the "Needs from you" block on a reply that already has the footer.

    Returns "pass", the NEEDS_GATE text, or the NEEDS_LONG_GATE text. The block
    is judged only when the reply asks for something or already carries one, so a
    turn that needs nothing is never asked to invent an ask.
    """
    has_block = bool(NEEDS_BLOCK.search(text))
    if not has_block:
        return NEEDS_GATE if ASK_PATTERNS.search(prose_only(text)) else "pass"

    tail = text[NEEDS_BLOCK.search(text).end():]
    offenders = [
        line for line in NEEDS_BULLET.findall(tail)
        if len(line.split()) > NEEDS_MAX_WORDS
    ]
    if offenders:
        return NEEDS_LONG_GATE.format(
            offenders="\n".join(f"- {o}" for o in offenders)
        )
    return "pass"


def settle_deadline() -> float:
    """Seconds to wait for the footer, honouring the environment override."""
    raw = os.environ.get(SETTLE_ENV)
    if not raw:
        return SETTLE_DEADLINE_S
    try:
        return min(max(float(raw), 0.0), SETTLE_MAX_S)
    except ValueError:
        return SETTLE_DEADLINE_S


def _settled(prompt_uuid: str | None, verdict: str, stats: dict,
             started: float, kind: str) -> tuple:
    """Stamp the settle stats with the outcome and hand back the decision."""
    stats["verdict"] = kind
    stats["elapsed_ms"] = int((time.monotonic() - started) * 1000)
    return prompt_uuid, verdict, stats


def settled_verdict(transcript: str) -> tuple:
    """Decide only once the transcript has stopped moving under us.

    Returns (prompt_uuid, "pass" | the gate text to block with, stats). Re-reads
    the file until the footer appears or the deadline expires, so a reply that
    lost the flush race by milliseconds is not blocked for a footer it actually
    wrote. The stats describe the wait itself, never the turn it read.
    """
    started = time.monotonic()
    deadline = time.time() + settle_deadline()
    stats = {"polls": 0, "footer_at_poll": None, "tail_bytes": 0}
    while True:
        entries, tail_bytes = read_tail(transcript)
        stats["polls"] += 1
        if stats["polls"] == 1:
            stats["tail_bytes"] = tail_bytes
        prompt_uuid, turn = current_turn(entries)
        if not turn:
            return _settled(prompt_uuid, "pass", stats, started, "pass_no_tool")
        used_tool, text = inspect(turn)
        if not used_tool:
            return _settled(prompt_uuid, "pass", stats, started, "pass_no_tool")
        if FOOTER_VERIFIED.search(text) and FOOTER_GAPS.search(text):
            # The footer is the last thing written, so the text is flushed and
            # the ask block can be judged on this read without settling again.
            if stats["polls"] > 1:
                stats["footer_at_poll"] = stats["polls"]
            verdict = needs_verdict(text)
            if verdict != "pass":
                kind = "block"
            else:
                kind = "pass_first_read" if stats["polls"] == 1 else "pass_settled"
            return _settled(prompt_uuid, verdict, stats, started, kind)
        if time.time() >= deadline:
            return _settled(prompt_uuid, GATE, stats, started, "block")
        time.sleep(SETTLE_POLL_S)


def log_settle(session_id: str, prompt_uuid: str | None, stats: dict) -> None:
    """Append one row about the wait. Metadata only, and never the turn.

    A transcript can hold anything, secrets included, so nothing read out of it
    is written here: no prompt text, no reply text, no path from the turn. The
    verdict is already decided by the time this runs, and a failure here is
    swallowed, so telemetry can never change what the gate does.
    """
    try:
        row = {
            "ts": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
            "session_id": session_id or None,
            "prompt_uuid": prompt_uuid or None,
            "verdict": stats.get("verdict"),
            "elapsed_ms": stats.get("elapsed_ms"),
            "polls": stats.get("polls"),
            "footer_at_poll": stats.get("footer_at_poll"),
            "tail_bytes": stats.get("tail_bytes"),
        }
        SETTLE_LOG.parent.mkdir(parents=True, exist_ok=True)
        with open(SETTLE_LOG, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(row) + "\n")
    except Exception:  # noqa: S110 - telemetry must never change the verdict
        pass


def block(reason: str) -> None:
    sys.stderr.write(reason)
    sys.stderr.flush()
    print(json.dumps({"decision": "block", "reason": reason}), flush=True)


def main() -> None:
    try:
        data = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        return
    if not isinstance(data, dict):
        return
    if os.environ.get("DONE_GATE_DISABLE") == "1":
        return
    # Recursion guard first: this Stop is the one the previous block caused.
    if data.get("stop_hook_active"):
        return

    transcript = data.get("transcript_path")
    if not transcript:
        return
    prompt_uuid, verdict, stats = settled_verdict(transcript)
    log_settle(data.get("session_id", ""), prompt_uuid, stats)
    if verdict == "pass":
        return
    if already_fired(data.get("session_id", ""), prompt_uuid):
        return
    block(verdict)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # A broken gate must never wedge a session. Fail open, stay quiet.
        pass
    sys.exit(0)
