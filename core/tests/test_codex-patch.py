#!/usr/bin/env python3
"""Codex apply_patch payloads become the Claude-shaped calls the guards already read.

Codex reports every file edit as tool_name "apply_patch" with the patch text in
tool_input.command (Codex hooks docs). The grammar is the one in openai/codex,
codex-rs/apply-patch/src/parser.rs.
"""
import sys
from pathlib import Path

HOOKS = Path(__file__).resolve().parents[1] / "hooks"
sys.path.insert(0, str(HOOKS))
from codex_patch import as_claude_calls, parse_patch  # type: ignore[import-not-found]  # noqa: E402

fails = 0
total = 0


def report(name, ok, detail=""):
    global fails, total
    total += 1
    if ok:
        print("  ok   %s" % name)
    else:
        fails += 1
        print("  FAIL %s %s" % (name, detail))


PATCH = """*** Begin Patch
*** Add File: docs/new.md
+# New
+text
*** Update File: ruff.toml
@@ [lint]
-select = ["E", "F"]
+select = ["E"]
 line-length = 100
*** Delete File: old.py
*** Update File: a.py
*** Move to: b.py
@@
-x = 1
+x = 2
*** End Patch
"""

changes = parse_patch(PATCH)
report("four file changes", [c["op"] for c in changes] == ["add", "update", "delete", "update"], changes)
report("add keeps its lines", changes[0]["path"] == "docs/new.md" and changes[0]["lines"] == ["# New", "text"])
upd = changes[1]
report("update keeps old and new text per chunk",
       upd["chunks"] == [{"old": 'select = ["E", "F"]\nline-length = 100\n', "new": 'select = ["E"]\nline-length = 100\n'}],
       upd["chunks"])
report("move records the new path", changes[3]["path"] == "a.py" and changes[3]["move_to"] == "b.py")

payload = {"tool_name": "apply_patch", "cwd": "/repo", "tool_input": {"command": PATCH}}
calls = as_claude_calls(payload)
kinds = [(c["tool_name"], c["tool_input"]["file_path"]) for c in calls]
report("calls in order", kinds == [("Write", "docs/new.md"), ("MultiEdit", "ruff.toml"), ("Write", "old.py"),
                                   ("Write", "a.py"), ("MultiEdit", "b.py")], kinds)
report("an added file is written with its content", calls[0]["tool_input"]["content"] == "# New\ntext\n")
report("an update becomes one edit per chunk",
       calls[1]["tool_input"]["edits"] == [{"old_string": 'select = ["E", "F"]\nline-length = 100\n',
                                            "new_string": 'select = ["E"]\nline-length = 100\n'}])
report("a delete empties the old path", calls[2]["tool_input"]["content"] == "")
report("every call keeps the working directory", all(c["cwd"] == "/repo" for c in calls))

loose = "  *** Begin Patch\n*** Environment ID: abc\n*** Add File: x.txt\n+hi\n  *** End Patch  \n"
report("environment id and loose whitespace are tolerated",
       [c["tool_input"]["file_path"] for c in as_claude_calls({"tool_name": "apply_patch", "tool_input": {"command": loose}})] == ["x.txt"])

junk = {"tool_name": "apply_patch", "tool_input": {"command": "not a patch"}}
report("an unparsable patch passes through unchanged", as_claude_calls(junk) == [junk])

bash = {"tool_name": "Bash", "tool_input": {"command": "ls"}}
report("other tools pass through unchanged", as_claude_calls(bash) == [bash])

print("\n%d passed, %d failed" % (total - fails, fails))
sys.exit(1 if fails else 0)
