"""Turn a Codex apply_patch call into the Claude-shaped calls the guards read.

Codex reports every file edit as tool_name "apply_patch" with the whole patch in
tool_input.command. The guards and the lint hook were written for Claude Code's
Write, Edit and MultiEdit, which name one file each. Converting the patch once,
here, lets every existing guard run unchanged on Codex.

Grammar: openai/codex, codex-rs/apply-patch/src/parser.rs (Begin Patch, an
optional Environment ID, then Add File, Delete File or Update File hunks, an
update optionally carrying Move to, chunks opened by "@@", End Patch). Like the
upstream parser, markers are matched with surrounding whitespace ignored.

A patch that does not parse is returned unchanged: the guards ignore a tool they
do not know, so a hook never wedges a session over its own parsing.
"""

from typing import Any, Dict, List, Optional

BEGIN = "*** Begin Patch"
END = "*** End Patch"
ENV = "*** Environment ID: "
ADD = "*** Add File: "
DELETE = "*** Delete File: "
UPDATE = "*** Update File: "
MOVE = "*** Move to: "
EOF_MARK = "*** End of File"


def _new_chunk() -> Dict[str, List[str]]:
    return {"old": [], "new": []}


def _close(chunk: Dict[str, List[str]]) -> Optional[Dict[str, str]]:
    if not chunk["old"] and not chunk["new"]:
        return None
    return {
        "old": "".join(line + "\n" for line in chunk["old"]),
        "new": "".join(line + "\n" for line in chunk["new"]),
    }


def parse_patch(text: str) -> List[Dict[str, Any]]:
    """Return one dict per file: op (add, delete, update), path, and lines, chunks or move_to."""
    lines = text.splitlines()
    i = 0
    while i < len(lines) and lines[i].strip() != BEGIN:
        i += 1
    if i == len(lines):
        raise ValueError("no Begin Patch marker")
    i += 1
    changes: List[Dict[str, Any]] = []
    current: Optional[Dict[str, Any]] = None
    chunk = _new_chunk()

    def finish() -> None:
        nonlocal current, chunk
        if current is not None and current["op"] == "update":
            closed = _close(chunk)
            if closed:
                current["chunks"].append(closed)
        if current is not None:
            changes.append(current)
        current, chunk = None, _new_chunk()

    ended = False
    for raw in lines[i:]:
        marker = raw.strip()
        if marker == END:
            ended = True
            break
        if marker.startswith(ENV.strip()) and current is None:
            continue
        if raw.lstrip().startswith(ADD):
            finish()
            current = {"op": "add", "path": raw.lstrip()[len(ADD):].strip(), "lines": []}
        elif raw.lstrip().startswith(DELETE):
            finish()
            current = {"op": "delete", "path": raw.lstrip()[len(DELETE):].strip()}
        elif raw.lstrip().startswith(UPDATE):
            finish()
            current = {"op": "update", "path": raw.lstrip()[len(UPDATE):].strip(), "chunks": [], "move_to": None}
        elif current is not None and current["op"] == "update" and raw.lstrip().startswith(MOVE):
            current["move_to"] = raw.lstrip()[len(MOVE):].strip()
        elif current is not None and current["op"] == "add":
            if raw.startswith("+"):
                current["lines"].append(raw[1:])
            elif marker:
                raise ValueError("unexpected line in an added file: %r" % raw[:40])
        elif current is not None and current["op"] == "update":
            if marker == EOF_MARK:
                continue
            if raw.startswith("@@"):
                closed = _close(chunk)
                if closed:
                    current["chunks"].append(closed)
                chunk = _new_chunk()
            elif raw.startswith("-"):
                chunk["old"].append(raw[1:])
            elif raw.startswith("+"):
                chunk["new"].append(raw[1:])
            elif raw.startswith(" ") or raw == "":
                context = raw[1:] if raw else ""
                chunk["old"].append(context)
                chunk["new"].append(context)
            else:
                raise ValueError("unexpected line in an update: %r" % raw[:40])
        elif marker:
            raise ValueError("unexpected line outside a file: %r" % raw[:40])
    finish()
    if not ended or not changes:
        raise ValueError("incomplete patch")
    return changes


def _call(base: Dict[str, Any], tool: str, tool_input: Dict[str, Any]) -> Dict[str, Any]:
    call = dict(base)
    call["tool_name"] = tool
    call["tool_input"] = tool_input
    return call


def as_claude_calls(payload: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Return the Claude-shaped calls an apply_patch payload stands for; anything else as is."""
    if payload.get("tool_name") != "apply_patch":
        return [payload]
    data = payload.get("tool_input")
    text = data.get("command") if isinstance(data, dict) else None
    if not isinstance(text, str):
        return [payload]
    try:
        changes = parse_patch(text)
    except ValueError:
        return [payload]
    base = {k: v for k, v in payload.items() if k not in ("tool_name", "tool_input")}
    calls: List[Dict[str, Any]] = []
    for change in changes:
        path = change["path"]
        if change["op"] == "add":
            content = "".join(line + "\n" for line in change["lines"])
            calls.append(_call(base, "Write", {"file_path": path, "content": content}))
        elif change["op"] == "delete":
            calls.append(_call(base, "Write", {"file_path": path, "content": ""}))
        else:
            target = path
            if change["move_to"]:
                # The old path is emptied; the edits land on the new one.
                calls.append(_call(base, "Write", {"file_path": path, "content": ""}))
                target = change["move_to"]
            if change["chunks"]:
                edits = [{"old_string": c["old"], "new_string": c["new"]} for c in change["chunks"]]
                calls.append(_call(base, "MultiEdit", {"file_path": target, "edits": edits}))
    return calls
