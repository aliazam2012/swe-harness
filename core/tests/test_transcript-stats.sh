#!/usr/bin/env bash
# Tests for transcript-stats.py.
#
# The real transcripts are never read: every fixture is a .jsonl file written
# into an mktemp sandbox, and both --root and --settings are pointed at it. The
# fixtures cover the cases the counters have to get right: a meta injection that
# is not a turn, a peer wake-up that is, a turn with no tool calls, a sidechain,
# a resumed session that repeats its parent's entries, a relative file_path, and
# two lines that are not valid JSON objects.
set -uo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
readonly SCRIPTS
TOOL="$SCRIPTS/transcript-stats.py"
readonly TOOL
TEST_DIR=$(mktemp -d)
readonly TEST_DIR
trap 'rm -rf "$TEST_DIR"' EXIT

PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (missing '$3')" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1 (unexpected '$3')" ;; *) ok "$1" ;; esac; }

# jget <json-file> <dotted.path>  -> one value, list indexes allowed
jget() {
  python3 - "$1" "$2" <<'PYEOF'
import json
import sys

node = json.load(open(sys.argv[1]))
for part in sys.argv[2].split("."):
    node = node[int(part)] if part.isdigit() else node[part]
print(node)
PYEOF
}

# mget <json-file> <matcher> <field>  -> that field of the matching matcher row
mget() {
  python3 - "$1" "$2" "$3" <<'PYEOF'
import json
import sys

report = json.load(open(sys.argv[1]))
rows = [r for r in report["matchers"] if r["matcher"] == sys.argv[2]]
print(rows[0][sys.argv[3]] if rows else "no-such-matcher")
PYEOF
}

# ------------------------------------------------------------------- fixtures

ROOT="$TEST_DIR/projects"
mkdir -p "$ROOT/projA" "$ROOT/projB"

# projA / a.jsonl: an injection, then two turns, one of them with no tool calls.
cat > "$ROOT/projA/a.jsonl" <<'JSONEOF'
{"type":"user","uuid":"a0","sessionId":"s1","timestamp":"2026-08-01T10:00:00.000Z","isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"injected context"}]}}
{"type":"user","uuid":"a1","sessionId":"s1","timestamp":"2026-08-01T10:00:01.000Z","promptSource":"typed","message":{"role":"user","content":"do the thing"}}
{"type":"assistant","uuid":"a2","sessionId":"s1","timestamp":"2026-08-01T10:00:02.000Z","cwd":"/w","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}},{"type":"tool_use","id":"t2","name":"Write","input":{"file_path":"/w/one.py","content":"x"}}]}}
{"type":"user","uuid":"a3","sessionId":"s1","timestamp":"2026-08-01T10:00:03.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}
{"type":"assistant","uuid":"a4","sessionId":"s1","timestamp":"2026-08-01T10:00:04.000Z","cwd":"/work","message":{"role":"assistant","content":[{"type":"tool_use","id":"t3","name":"Edit","input":{"file_path":"rel.py","old_string":"a","new_string":"b"}}]}}
{"type":"user","uuid":"a5","sessionId":"s1","timestamp":"2026-08-01T10:00:05.000Z","promptSource":"typed","message":{"role":"user","content":"and now answer"}}
{"type":"assistant","uuid":"a6","sessionId":"s1","timestamp":"2026-08-01T10:00:06.000Z","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}
JSONEOF

# projA / b.jsonl: a resumed session. The first two entries repeat a.jsonl by
# uuid and must be skipped. Then a peer wake-up turn and one sidechain call.
cat > "$ROOT/projA/b.jsonl" <<'JSONEOF'
{"type":"user","uuid":"a1","sessionId":"s1","timestamp":"2026-08-01T10:00:01.000Z","promptSource":"typed","message":{"role":"user","content":"do the thing"}}
{"type":"assistant","uuid":"a2","sessionId":"s1","timestamp":"2026-08-01T10:00:02.000Z","cwd":"/w","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}},{"type":"tool_use","id":"t2","name":"Write","input":{"file_path":"/w/one.py","content":"x"}}]}}
{"type":"user","uuid":"b1","sessionId":"s1","timestamp":"2026-08-02T09:00:00.000Z","isMeta":true,"promptSource":"system","origin":{"kind":"peer"},"message":{"role":"user","content":"Another Claude session sent a message"}}
{"type":"assistant","uuid":"b2","sessionId":"s1","timestamp":"2026-08-02T09:00:01.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t4","name":"Bash","input":{"command":"pwd"}}]}}
{"type":"assistant","uuid":"b3","sessionId":"s1","isSidechain":true,"timestamp":"2026-08-02T09:00:02.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t5","name":"Bash","input":{"command":"id"}}]}}
JSONEOF

# projB / c.jsonl: an older session, plus two lines that are not JSON objects.
cat > "$ROOT/projB/c.jsonl" <<'JSONEOF'
{"type":"user","uuid":"c1","sessionId":"s2","timestamp":"2026-01-01T08:00:00.000Z","promptSource":"typed","message":{"role":"user","content":"old work"}}
{"type":"assistant","uuid":"c2","sessionId":"s2","timestamp":"2026-01-01T08:00:01.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t6","name":"Bash","input":{"command":"a"}},{"type":"tool_use","id":"t7","name":"Bash","input":{"command":"b"}}]}}
{oops not json
5
JSONEOF

cat > "$TEST_DIR/settings.json" <<'JSONEOF'
{"hooks":{
  "PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"pre.py"}]}],
  "PostToolUse":[
    {"matcher":"Write|Edit|MultiEdit","hooks":[{"type":"command","command":"lint.py"},{"type":"command","command":"docs.py"}]},
    {"matcher":".*","hooks":[{"type":"command","command":"every.py"}]}
  ],
  "Stop":[{"hooks":[{"type":"command","command":"ignored.py"}]}]
}}
JSONEOF

stats() { python3 "$TOOL" --root "$ROOT" --settings "$TEST_DIR/settings.json" "$@"; }

OUT="$TEST_DIR/out.json"

# ------------------------------------------------------------------- the scan

printf 'corpus accounting\n'
EXIT=0; stats --json > "$OUT" 2>"$TEST_DIR/err" || EXIT=$?
check "a clean run exits 0" "$EXIT" "0"
check "every transcript is read" "$(jget "$OUT" corpus.files)" "3"
check "sessions are counted by sessionId" "$(jget "$OUT" corpus.sessions)" "2"
check "bad lines are counted, not fatal" "$(jget "$OUT" corpus.malformed_lines)" "2"
check "repeated entries are skipped" "$(jget "$OUT" corpus.duplicate_entries_skipped)" "2"
check "the range starts at the oldest entry" \
  "$(jget "$OUT" corpus.first_timestamp)" "2026-01-01T08:00:00.000Z"
check "the range ends at the newest entry" \
  "$(jget "$OUT" corpus.last_timestamp)" "2026-08-02T09:00:02.000Z"

printf 'turn boundaries\n'
check "an injection does not open a turn" "$(jget "$OUT" turns.turns)" "4.0"
check "a turn with no tool call is kept" "$(jget "$OUT" turns.min)" "0.0"
check "the busiest turn is the first" "$(jget "$OUT" turns.max)" "3.0"
check "p50 is the nearest rank" "$(jget "$OUT" turns.p50)" "1.0"
check "p99 is the top of the list" "$(jget "$OUT" turns.p99)" "3.0"
check "the mean is over turns, not files" "$(jget "$OUT" turns.mean)" "1.5"

printf 'tool call counting\n'
check "duplicated tool ids are counted once" "$(jget "$OUT" tool_calls.total)" "7"
check "sidechain calls are separated" "$(jget "$OUT" tool_calls.sidechain)" "1"
check "main-thread calls are the rest" "$(jget "$OUT" tool_calls.main_thread)" "6"
check "nothing is orphaned in a clean corpus" "$(jget "$OUT" tool_calls.orphan)" "0"
check "Bash is counted across files" "$(jget "$OUT" tool_calls.hook_relevant.Bash)" "5"
check "Write is counted once despite the resume" "$(jget "$OUT" tool_calls.hook_relevant.Write)" "1"
check "Edit is counted" "$(jget "$OUT" tool_calls.hook_relevant.Edit)" "1"
check "an absent tool reports zero" "$(jget "$OUT" tool_calls.hook_relevant.MultiEdit)" "0"
check "the by-name table leads with Bash" "$(jget "$OUT" tool_calls.by_name.0.tool)" "Bash"
check "shares are a percentage of all calls" \
  "$(jget "$OUT" tool_calls.by_name.0.share_pct)" "71.43"

printf 'hook matcher volume\n'
check "only tool events are read" "$(python3 -c "import json;print(len(json.load(open('$OUT'))['matchers']))")" "3"
check "Bash matches every Bash call" "$(mget "$OUT" Bash matched_calls)" "5"
check "one hook means one invocation each" "$(mget "$OUT" Bash hook_invocations)" "5"
check "the edit matcher matches Write and Edit" \
  "$(mget "$OUT" 'Write|Edit|MultiEdit' matched_calls)" "2"
check "two hooks double the invocations" \
  "$(mget "$OUT" 'Write|Edit|MultiEdit' hook_invocations)" "4"
check "a catch-all matcher matches everything" "$(mget "$OUT" '.*' matched_calls)" "7"
check "per-turn cost divides by turns" "$(mget "$OUT" Bash invocations_per_turn)" "1.25"
check "the Stop event is ignored" "$(mget "$OUT" '' matched_calls)" "no-such-matcher"

printf 'replay corpus\n'
check "every Write and Edit call is offered" "$(jget "$OUT" replay_corpus.edit_calls)" "2"
check "both carry a file_path" "$(jget "$OUT" replay_corpus.edit_calls_with_path)" "2"
check "none is missing a path" "$(jget "$OUT" replay_corpus.edit_calls_without_path)" "0"
check "a relative path resolves against cwd" \
  "$(jget "$OUT" replay_corpus.distinct_file_paths)" "2"
has "the resolved path uses the entry cwd" "$(stats --json)" "/work/rel.py"

# ---------------------------------------------------------------- the filters

printf 'filters\n'
stats --json --since 2026-06-01 > "$TEST_DIR/since.json"
check "--since drops the older session" "$(jget "$TEST_DIR/since.json" turns.turns)" "3.0"
check "--since drops its tool calls too" "$(jget "$TEST_DIR/since.json" tool_calls.total)" "5"
check "--since is echoed back" "$(jget "$TEST_DIR/since.json" corpus.since)" "2026-06-01"
stats --json --project projB > "$TEST_DIR/proj.json"
check "--project keeps one transcript" "$(jget "$TEST_DIR/proj.json" corpus.files)" "1"
check "--project keeps only its turns" "$(jget "$TEST_DIR/proj.json" turns.turns)" "1.0"
check "--project keeps only its calls" "$(jget "$TEST_DIR/proj.json" tool_calls.total)" "2"
stats --json --project PROJB > "$TEST_DIR/proj2.json"
check "--project ignores case" "$(jget "$TEST_DIR/proj2.json" corpus.files)" "1"
EXIT=0; OUT2=$(stats --since 2026 2>&1) || EXIT=$?
check "a malformed --since is refused" "$EXIT" "2"
has "the refusal names the format" "$OUT2" "YYYY-MM-DD"

# ----------------------------------------------------------------- the output

printf 'output shape\n'
TABLE=$(stats)
has "the table names the corpus" "$TABLE" "CORPUS"
has "the table gives the distribution" "$TABLE" "TOOL CALLS PER TURN"
has "the table gives matcher volume" "$TABLE" "HOOK MATCHER VOLUME"
has "the table gives the replay corpus" "$TABLE" "REPLAY CORPUS"
has "the table reports how long it took" "$TABLE" " in 0."
has "the table reports how much it read" "$TABLE" "MB"
hasnt "the table is not JSON" "$TABLE" '"corpus":'
check "--top limits the tool rows" \
  "$(stats --top 1 | grep -c 'more tool names')" "1"
EXIT=0; stats --json | python3 -c 'import json,sys;json.load(sys.stdin)' || EXIT=$?
check "--json emits nothing but JSON" "$EXIT" "0"

printf 'empty and missing roots\n'
mkdir -p "$TEST_DIR/empty"
EXIT=0; OUT3=$(python3 "$TOOL" --root "$TEST_DIR/empty" 2>&1) || EXIT=$?
check "an empty root exits 1" "$EXIT" "1"
has "it says where it looked" "$OUT3" "no transcripts under"
EXIT=0; python3 "$TOOL" --root "$TEST_DIR/nope" >/dev/null 2>&1 || EXIT=$?
check "a missing root exits 1" "$EXIT" "1"
EXIT=0; stats --settings "$TEST_DIR/nope.json" --json >/dev/null 2>&1 || EXIT=$?
check "a missing settings file is not fatal" "$EXIT" "0"

printf 'it never writes\n'
BEFORE=$(find "$ROOT" -type f -exec shasum {} \; | sort | shasum)
stats > /dev/null; stats --json > /dev/null
AFTER=$(find "$ROOT" -type f -exec shasum {} \; | sort | shasum)
check "the transcripts are untouched" "$AFTER" "$BEFORE"

# ------------------------------------------------------------ source quality

printf 'source quality\n'
SRC=$(cat "$TOOL")
has "the turn boundary is written down" "$SRC" "Turn boundary:"
has "the duplicate rule is written down" "$SRC" "Duplicate entries:"
has "the matcher rule is written down" "$SRC" "Matcher semantics:"
has "the standard library only" "$SRC" "import json"
hasnt "no third-party import" "$SRC" "import requests"
hasnt "no file is ever opened for writing" "$SRC" 'open("w"'
hasnt "no write_text call" "$SRC" "write_text"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
