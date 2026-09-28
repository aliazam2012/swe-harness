#!/usr/bin/env bash
# Tests for harness-bench.py.
#
# Nothing here touches the installed harness. The whole tool is pointed at a
# fixture hook directory this script writes, a fixture settings.json, a fixture
# plugin hooks.json and a stub transcript-stats.py, so a failing test can never
# wrap the live session, clear a live pane or read a real transcript. The
# fixture hooks are named exactly as the real ones, because the scenario table
# addresses hooks by name.
#
# The real guards package and the fingerprint module are copied into the fixture
# hook directory rather than stubbed. Both are imported by the tool to derive a
# branch weight, and a stub would make the weight a statement about the stub.
#
# `timeout` is GNU coreutils and macOS does not ship it, so nothing here uses
# it. The fixture hooks are all fast by construction.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly HERE
HOME_DIR="${HARNESS_HOME:-$(cd "$HERE/../.." && pwd -P)}"
readonly HOME_DIR
SCRIPTS="$HOME_DIR/core/scripts"
readonly SCRIPTS
REAL_HOOKS="$HOME_DIR/core/hooks"
readonly REAL_HOOKS
PY="${HARNESS_PYTHON:-python3}"
readonly PY
TEST_DIR=$(mktemp -d)
readonly TEST_DIR
trap 'rm -rf "$TEST_DIR"' EXIT

PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (missing '$3')" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1 (unexpected '$3')" ;; *) ok "$1" ;; esac; }

# ------------------------------------------------------------- fixture hooks

HOOKS="$TEST_DIR/hooks"; mkdir -p "$HOOKS"
PLUGIN="$TEST_DIR/plugin/hooks"; mkdir -p "$PLUGIN"
export HARNESS_BENCH_HOOKS="$HOOKS"

# The real guards and the real fingerprint, because two branch weights are
# derived from them. A stub here would measure the stub.
cp -R "$REAL_HOOKS/guards" "$HOOKS/guards"
cp "$REAL_HOOKS/harness_fingerprint.py" "$HOOKS/harness_fingerprint.py"

# Stands in for the PreToolUse dispatcher: the hot path on Bash, plus the write
# matcher, and the one hook with branches whose outputs differ, so it exercises
# the payload assertions.
cat > "$HOOKS/pretooluse-dispatcher.py" <<'HOOKEOF'
import sys
payload = sys.stdin.read()
if "--no-verify" in payload or "ruff.toml" in payload:
    print('{"hookSpecificOutput": {"permissionDecision": "deny"}}')
else:
    print("{}")
HOOKEOF

# Stands in for the UNSAFE hook no sandbox can contain. It must never run unless
# --include-unsafe is passed, so it records every run it gets.
cat > "$HOOKS/herdr-lineage.sh" <<'HOOKEOF'
#!/bin/sh
cat >/dev/null 2>&1 || true
printf 'ran\n' >> "$HARNESS_TEST_LINEAGE_LOG"
exit 0
HOOKEOF
chmod +x "$HOOKS/herdr-lineage.sh"
export HARNESS_TEST_LINEAGE_LOG="$TEST_DIR/lineage.log"
: > "$HARNESS_TEST_LINEAGE_LOG"

# A hook the safety table has never classified. It must never be executed.
cat > "$HOOKS/mystery-hook.py" <<'HOOKEOF'
import sys
sys.stdin.read()
open(sys.argv[0] + ".ran", "a").write("ran\n")
print("{}")
HOOKEOF

# Stands in for a plugin hook. Core cannot classify a side effect it has never
# seen, so this must be discovered and reported, never run.
cat > "$PLUGIN/observe.sh" <<'HOOKEOF'
#!/bin/sh
cat >/dev/null 2>&1 || true
printf '{}'
exit 0
HOOKEOF
chmod +x "$PLUGIN/observe.sh"

# ------------------------------------------------------- fixture wiring files

SETTINGS="$TEST_DIR/settings.json"
cat > "$SETTINGS" <<EOF
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [
        {"type": "command", "command": "$PY $HOOKS/pretooluse-dispatcher.py"}]},
      {"matcher": "Write|Edit|MultiEdit", "hooks": [
        {"type": "command", "command": "$PY $HOOKS/pretooluse-dispatcher.py"}]}
    ],
    "SessionStart": [
      {"hooks": [{"type": "command", "command": "sh '$HOOKS/herdr-lineage.sh'"}]}
    ],
    "Stop": [
      {"hooks": [{"type": "command", "command": "$PY $HOOKS/mystery-hook.py"}]}
    ]
  }
}
EOF
export HARNESS_BENCH_SETTINGS="$SETTINGS"

PLUGIN_JSON="$TEST_DIR/plugin/hooks/hooks.json"
cat > "$PLUGIN_JSON" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [
        {"type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/observe.sh"}]}
    ]
  }
}
EOF
export HARNESS_BENCH_PLUGIN_GLOB="$TEST_DIR/plugin/hooks/hooks.json"

# A fixture transcript corpus. The branch weights are counted off this, so the
# tool never reads a real transcript to decide what a hook costs. Four turns
# inside the default 14-day window: two carry the audit footer, one used no
# tool, one used a tool and has none, and one edits a file inside the fixture
# hook tree so the harness-edit weight is not zero. A fifth turn is dated 40
# days back, so it is only counted under --window-days 0 and every weight
# assertion below is a statement about the window, not about the whole corpus.
CORPUS="$TEST_DIR/corpus/project"; mkdir -p "$CORPUS"
"$PY" - "$CORPUS/fixture.jsonl" "$HOOKS" <<'EOF'
import datetime as dt, json, os, sys

HOOKS = sys.argv[2]

def stamp(days_ago):
    when = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days_ago)
    return when.strftime("%Y-%m-%dT%H:%M:%S.000Z")

def prompt(i, days_ago):
    return {"type": "user", "uuid": "p%s" % i, "timestamp": stamp(days_ago),
            "message": {"content": "do thing %s" % i}}

def tools(i, cmds):
    return {"type": "assistant", "uuid": "a%s" % i, "message": {"content": [
        {"type": "tool_use", "id": "t%s%s" % (i, n), "name": "Bash",
         "input": {"command": c}}
        for n, c in enumerate(cmds)]}}

def edits(i, paths):
    return {"type": "assistant", "uuid": "e%s" % i, "message": {"content": [
        {"type": "tool_use", "id": "w%s%s" % (i, n), "name": "Edit",
         "input": {"file_path": p}}
        for n, p in enumerate(paths)]}}

def reply(i, text):
    return {"type": "assistant", "uuid": "r%s" % i,
            "message": {"content": [{"type": "text", "text": text}]}}

FOOTER = "Done.\n\nVerified: ran it\nGaps: none\n"
rows = [
    prompt(1, 3), tools(1, ["ls -la", 'git commit --no-verify -m "x"']),
    edits(1, ["/nowhere/a.py", "/nowhere/b.md", "/nowhere/ruff.toml",
              "/nowhere/c.md"]),
    reply(1, FOOTER),
    prompt(2, 2), tools(2, ["gh pr create --fill", "echo hi"]), reply(2, FOOTER),
    prompt(3, 6), reply(3, "just talking"),
    prompt(4, 1), tools(4, ["pwd"]),
    edits(4, [os.path.join(HOOKS, "herdr-lineage.sh")]),
    reply(4, "no footer here"),
    prompt(5, 40), tools(5, ["sleep 1"]), reply(5, FOOTER),
]
with open(sys.argv[1], "w") as h:
    for row in rows:
        h.write(json.dumps(row) + "\n")
EOF

# A second corpus, used only by the stability check. Forty turns ten days back
# with no footer, forty two days back with one: a weight that swings from 100%
# to 0% inside the window is exactly what the half-split is there to catch, and
# 40 turns a half clears the 30-observation floor that suppresses the check when
# there is too little to judge.
CORPUS2="$TEST_DIR/corpus2/project"; mkdir -p "$CORPUS2"
"$PY" - "$CORPUS2/fixture.jsonl" <<'EOF'
import datetime as dt, json, sys

def stamp(days_ago):
    when = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days_ago)
    return when.strftime("%Y-%m-%dT%H:%M:%S.000Z")

FOOTER = "Done.\n\nVerified: ran it\nGaps: none\n"
rows = []
for half, (days_ago, text) in enumerate(((10, "no footer here"), (2, FOOTER))):
    for i in range(40):
        tag = "%s-%s" % (half, i)
        rows.append({"type": "user", "uuid": "p%s" % tag, "timestamp": stamp(days_ago),
                     "message": {"content": "do thing"}})
        rows.append({"type": "assistant", "uuid": "a%s" % tag, "message": {"content": [
            {"type": "tool_use", "id": "t%s" % tag, "name": "Bash",
             "input": {"command": "ls -la"}}]}})
        rows.append({"type": "assistant", "uuid": "r%s" % tag,
                     "message": {"content": [{"type": "text", "text": text}]}})
with open(sys.argv[1], "w") as h:
    for row in rows:
        h.write(json.dumps(row) + "\n")
EOF

# A stub transcript-stats.py, so the volume model is fed fixed numbers and the
# test never waits on a full corpus sweep.
STATS="$TEST_DIR/stats.py"
cat > "$STATS" <<EOF
import json
print(json.dumps({
    "corpus": {"sessions": 100, "files": 200, "bytes_read": 200 * 4096,
               "root": "$TEST_DIR/corpus"},
    "turns": {"turns": 1000.0},
    "matchers": [
        {"event": "PreToolUse", "matcher": "Bash", "invocations_per_turn": 10.0},
    ],
}))
EOF
export HARNESS_BENCH_STATS="$STATS"

# The same stub pointed at the second corpus, for the stability check.
STATS2="$TEST_DIR/stats2.py"
sed "s|$TEST_DIR/corpus\"|$TEST_DIR/corpus2\"|" "$STATS" > "$STATS2"

STORE="$TEST_DIR/hooks.jsonl"
export HARNESS_BENCH_STORE="$STORE"

bench() { "$PY" "$SCRIPTS/harness-bench.py" "$@" 2>/dev/null; }

# ------------------------------------------------------------------ discovery

printf 'discovery\n'
OUT=$(bench --list)
has "lists the settings.json wiring" "$OUT" "PreToolUse"
has "resolves the plugin root in the command" "$OUT" "$PLUGIN/observe.sh"
hasnt "leaves no unresolved plugin placeholder" "$OUT" 'CLAUDE_PLUGIN_ROOT'
check "counts every wiring, settings plus plugin" \
  "$(printf '%s\n' "$OUT" | head -1)" "5 wired hook commands"
has "reports the matcher for the Bash wiring" "$OUT" "Bash"
has "names the resolved script path" "$OUT" "$HOOKS/pretooluse-dispatcher.py"
has "labels a python hook as python" "$OUT" "[python, settings.json]"
has "labels the plugin source by its plugin directory" "$OUT" "plugin:plugin"
has "carries the UNSAFE verdict from the safety table" "$OUT" "UNSAFE   herdr-lineage.sh"
has "marks an unclassified hook UNKNOWN" "$OUT" "UNKNOWN  mystery-hook.py"
has "marks a layer or plugin hook UNKNOWN too" "$OUT" "UNKNOWN  observe.sh"
has "lists scenarios with their production weight" "$OUT" "scenarios"

# ------------------------------------------------------------- safety policy

printf 'safety policy\n'
OUT=$(bench --runs 3 --no-store)
check "the uncontained UNSAFE hook never ran" \
  "$(wc -l < "$HARNESS_TEST_LINEAGE_LOG" | tr -d ' ')" "0"
has "and the output says why it was skipped" "$OUT" "SKIPPED"
has "and names the flag that would run it" "$OUT" "--include-unsafe"
has "and gives the reason, not just the verdict" "$OUT" "clears the role and parent tokens"
if [ -e "$HOOKS/mystery-hook.py.ran" ]; then
  bad "an unclassified hook was executed"
else
  ok "an unclassified hook was never executed"
fi
if [ -e "$PLUGIN/observe.sh.ran" ]; then
  bad "a plugin hook was executed"
else
  ok "a plugin hook core cannot classify was never executed"
fi
has "and the output refuses it out loud" "$OUT" "nothing says it is safe to execute"

OUT=$(bench --runs 3 --no-store --include-unsafe --only herdr-lineage)
if [ "$(wc -l < "$HARNESS_TEST_LINEAGE_LOG" | tr -d ' ')" -gt 0 ]; then
  ok "--include-unsafe does run it"
else
  bad "--include-unsafe did not run it"
fi
has "and the output records that it was opted into" "$OUT" "ran under --include-unsafe"

# ------------------------------------------------------------------ scenarios

printf 'scenarios and assertions\n'
OUT=$(bench --runs 5 --no-store --only dispatcher)
has "names the hot Bash branch" "$OUT" "plain command"
has "names the refused Bash branch" "$OUT" "git commit --no-verify"
has "names the ordinary write branch" "$OUT" "ordinary write"
has "names the protected-config branch" "$OUT" "ruff.toml"
hasnt "a passing scenario is not marked untrusted" "$OUT" "UNTRUSTED"

# A hook that answers nothing fails the scenario's stdout assertion, and the
# number it produced must be reported as untrusted rather than as a fast hook.
cp "$HOOKS/pretooluse-dispatcher.py" "$TEST_DIR/dispatcher.bak"
printf 'import sys\nsys.stdin.read()\n' > "$HOOKS/pretooluse-dispatcher.py"
OUT=$(bench --runs 3 --no-store --only dispatcher)
has "a payload that misses its branch is marked UNTRUSTED" "$OUT" "UNTRUSTED"
has "and the reason names what was missing" "$OUT" "stdout missing"
cp "$TEST_DIR/dispatcher.bak" "$HOOKS/pretooluse-dispatcher.py"

# --------------------------------------------------------------- statistics

printf 'statistics and derived cost\n'
JSON=$(bench --runs 12 --no-store --json --only dispatcher)
STAT=$(printf '%s' "$JSON" | "$PY" -c '
import json, sys
d = json.load(sys.stdin)
row = [s for s in d["scenarios"] if "plain command" in s["id"]][0]
st = row["stats"]
print("n", st["n"])
print("ordered", st["min"] <= st["p50"] <= st["p95"] <= st["p99"] <= st["max"])
print("keys", sorted(st) == sorted(["n","min","p50","mean","p95","p99","max","stddev"]))
print("marginal", "marginal_ms" in row)
print("floors", sorted(d["floors"]) != [])
print("perturn", d["headline"]["per_turn_ms"] > 0)
print("persession", d["headline"]["per_session_ms"] > d["headline"]["per_turn_ms"])
print("tps", d["headline"]["turns_per_session"])
print("ctx", all(k in d["context"] for k in
      ["timestamp","hostname","harness_commit","cpu_count","load_start",
       "python","bash","node","harness_sha"]))
print("loadend", "load_end" in d)
')
check "n matches --runs" "$(printf '%s\n' "$STAT" | awk '/^n /{print $2}')" "12"
check "the percentiles are ordered" "$(printf '%s\n' "$STAT" | awk '/^ordered/{print $2}')" "True"
check "every statistic is reported, not just a mean" \
  "$(printf '%s\n' "$STAT" | awk '/^keys/{print $2}')" "True"
check "the marginal cost over the interpreter floor is reported" \
  "$(printf '%s\n' "$STAT" | awk '/^marginal/{print $2}')" "True"
check "interpreter floors are measured" "$(printf '%s\n' "$STAT" | awk '/^floors/{print $2}')" "True"
check "a per-turn cost is derived" "$(printf '%s\n' "$STAT" | awk '/^perturn/{print $2}')" "True"
check "a per-session cost is derived from it" \
  "$(printf '%s\n' "$STAT" | awk '/^persession/{print $2}')" "True"
check "turns per session comes from the corpus (1000/100)" \
  "$(printf '%s\n' "$STAT" | awk '/^tps/{print $2}')" "10.0"
check "the run context is recorded, fingerprint included" \
  "$(printf '%s\n' "$STAT" | awk '/^ctx/{print $2}')" "True"
check "the load average is recorded at the end too" \
  "$(printf '%s\n' "$STAT" | awk '/^loadend/{print $2}')" "True"

# The two Bash and the two write scenarios share one hook name and one event,
# and are told apart only by the matcher. A run that lost that discrimination
# would weigh the write branches against the Bash invocation rate.
MATCH=$(bench --runs 3 --no-store --json --only dispatcher | "$PY" -c '
import json, sys
d = json.load(sys.stdin)
rows = d["headline"]["rows"]
print("rows", len(rows))
print("matchers", len({r["matcher"] for r in rows}))
')
check "each matcher gets its own headline row" \
  "$(printf '%s\n' "$MATCH" | awk '/^rows/{print $2}')" "2"
check "and the two rows are told apart by their matcher" \
  "$(printf '%s\n' "$MATCH" | awk '/^matchers/{print $2}')" "2"

printf 'branch weights measured off the corpus\n'
JSON=$(bench --runs 3 --no-store --json --only dispatcher)
WEIGHT=$(printf '%s' "$JSON" | "$PY" -c '
import json, sys
w = json.load(sys.stdin)["weights"]
print("bash", w["bash_calls"])
print("noverify", round(w["bash_no_verify"], 3))
print("edits", w["edit_calls"])
print("py", round(w["lint_py"], 3))
print("config", round(w["guard_config"], 3))
print("turns", w["turns"])
print("footer", round(w["stop_footer"], 3))
print("notool", round(w["stop_no_tool"], 3))
print("nofooter", round(w["stop_no_footer"], 3))
print("harness", round(w["stop_harness_edit"], 3))
')
wf() { printf '%s\n' "$WEIGHT" | awk -v k="$1" '$1 == k {print $2}'; }
check "counts every Bash call in the corpus" "$(wf bash)" "5"
check "counts the share the no-verify guard refuses" "$(wf noverify)" "0.2"
check "counts every Write or Edit call" "$(wf edits)" "5"
check "counts the .py share of edited paths" "$(wf py)" "0.2"
check "counts the protected-config share, from the guard's own list" "$(wf config)" "0.2"
check "segments the corpus into turns" "$(wf turns)" "4"
check "counts turns carrying the audit footer" "$(wf footer)" "0.5"
check "counts turns that used no tool" "$(wf notool)" "0.25"
check "counts turns that used a tool and have no footer" "$(wf nofooter)" "0.25"
check "counts turns that edited the harness itself" "$(wf harness)" "0.25"

OUT=$(bench --runs 3 --no-store --only dispatcher)
has "the weights are printed, not hidden in the JSON" "$OUT" "BRANCH WEIGHTS"
has "and are named as counted rather than assumed" "$OUT" "not assumed"

# ------------------------------------------------------------ weighting window

printf 'weighting window\n'
WIN=$(bench --runs 3 --no-store --json --only dispatcher | "$PY" -c '
import json, sys
d = json.load(sys.stdin)
w, weights = d["window"], d["weights"]
print("days", w["days"])
print("start", w["start"])
print("kept", w["turns_in_window"])
print("dropped", w["turns_excluded"])
print("split", w["split_date"] is not None)
print("first", w["corpus_first"])
print("floor", w["min_observations"])
print("ratio", w["stability_ratio"])
print("wdays", weights["window_days"])
print("branches", len(weights["branches"]))
')
wn() { printf '%s\n' "$WIN" | awk -v k="$1" '$1 == k {print $2}'; }
check "the default window is 14 days" "$(wn days)" "14"
check "the window keeps only the turns inside it" "$(wn kept)" "4"
check "and says how many older turns it dropped" "$(wn dropped)" "1"
check "the window start is recorded, not just the length" \
  "$([ -n "$(wn start)" ] && echo yes)" "yes"
check "the half-split date is recorded" "$(wn split)" "True"
check "the observed corpus range is recorded with the run" \
  "$([ -n "$(wn first)" ] && echo yes)" "yes"
check "the sample-size floor is recorded" "$(wn floor)" "30"
check "the stability threshold is recorded" "$(wn ratio)" "2.0"
check "the weights carry the window they were counted over" "$(wn wdays)" "14"
# Tracks the length of BRANCH_SPEC in harness-bench.py. Derived rather than
# hardcoded, so adding a branch weight does not fail a test about reporting.
BRANCHES=$(grep -cE '^    \("[a-z_]+", "[a-z_]+", "[a-z]+"\),$' "$SCRIPTS/harness-bench.py")
check "the branch count is derived, not guessed" "$([ "$BRANCHES" -ge 5 ] && echo yes)" "yes"
check "every branch weight is reported with its halves" "$(wn branches)" "$BRANCHES"

OUT=$(bench --runs 3 --no-store --only dispatcher)
has "the window is named in the human output" "$OUT" "last 14 days"
has "and says what it kept and dropped" "$OUT" "older turns dropped"

# --window-days 0 is the old whole-corpus behaviour, and must pick up the turn
# from 40 days ago that the default window drops.
WIN=$(bench --runs 3 --no-store --json --only dispatcher --window-days 0 | "$PY" -c '
import json, sys
d = json.load(sys.stdin)
print("days", d["window"]["days"])
print("kept", d["window"]["turns_in_window"])
print("dropped", d["window"]["turns_excluded"])
print("bash", d["weights"]["bash_calls"])
print("footer", round(d["weights"]["stop_footer"], 3))
')
check "--window-days 0 records itself as the whole corpus" "$(wn days)" "0"
check "and counts the turn the 14-day window dropped" "$(wn kept)" "5"
check "and drops nothing" "$(wn dropped)" "0"
check "which changes the Bash count it weighs against" "$(wn bash)" "6"
check "and the footer share the whole corpus reports" "$(wn footer)" "0.6"

OUT=$(bench --runs 3 --no-store --only dispatcher --window-days 0)
has "the whole-corpus run says so in the output" "$OUT" "whole corpus"

WIN=$(bench --runs 3 --no-store --json --only dispatcher --window-days 4 | "$PY" -c '
import json, sys
d = json.load(sys.stdin)
print("kept", d["window"]["turns_in_window"])
print("days", d["window"]["days"])
')
check "a shorter window drops the turns outside it too" "$(wn kept)" "3"
check "and records the length it was given" "$(wn days)" "4"

# --------------------------------------------------------- weight stability

printf 'weight stability\n'
OUT=$(bench --runs 3 --no-store --only dispatcher)
has "the stability of each weight is reported" "$OUT" "WEIGHT STABILITY"
has "a half with too few observations is named, not flagged" \
  "$OUT" "halves not comparable"
has "and the floor it failed is named" "$OUT" "under the 30 floor"
hasnt "a corpus too small to judge raises no false alarm" "$OUT" "MOVED"
has "a weight built on too few observations is marked indicative" "$OUT" "indicative"

export HARNESS_BENCH_STATS="$STATS2"
OUT=$(bench --runs 3 --no-store --only dispatcher)
has "a weight that swung inside the window is flagged" "$OUT" "** MOVED **"
has "and the warning is printed, not buried" "$OUT" "moved by more than 2.0x inside the window"
has "and names the weight that moved" "$OUT" "stop_no_footer"
has "and says the headline built on it is provisional" "$OUT" "provisional"
STAB=$(bench --runs 3 --no-store --json --only dispatcher | "$PY" -c '
import json, sys
d = json.load(sys.stdin)
rows = {b["name"]: b for b in d["weights"]["branches"]}
print("unstable", len(d["window"]["unstable"]))
print("provisional", d["window"]["provisional"])
print("first", rows["stop_no_footer"]["first_half"])
print("second", rows["stop_no_footer"]["second_half"])
print("known", rows["stop_no_footer"]["halves_known"])
print("thin", rows["stop_no_footer"]["thin"])
')
sn() { printf '%s\n' "$STAB" | awk -v k="$1" '$1 == k {print $2}'; }
check "the flagged weights are listed in the stored run" "$(sn unstable)" "2"
check "and the run is marked provisional" "$(sn provisional)" "True"
check "the first half of the moved weight is recorded" "$(sn first)" "1.0"
check "the second half is recorded too" "$(sn second)" "0.0"
check "40 observations a half clears the floor, so the halves are judged" \
  "$(sn known)" "True"
check "and a weight with 40 observations is not called thin" "$(sn thin)" "False"
export HARNESS_BENCH_STATS="$STATS"

# ------------------------------------------------------ persistence and compare

printf 'persistence and regression gate\n'
: > "$STORE"
bench --runs 3 --only dispatcher >/dev/null
check "one run appends one line" "$(wc -l < "$STORE" | tr -d ' ')" "1"
bench --runs 3 --only dispatcher >/dev/null
check "a second run appends a second line" "$(wc -l < "$STORE" | tr -d ' ')" "2"
bench --runs 3 --no-store --only dispatcher >/dev/null
check "--no-store appends nothing" "$(wc -l < "$STORE" | tr -d ' ')" "2"

STORED=$(tail -1 "$STORE" | "$PY" -c '
import json, sys
run = json.load(sys.stdin)
w = run["window"]
print("days", w["days"])
print("start", bool(w["start"]))
print("first", bool(w["corpus_first"]))
print("sha", bool(run["context"]["harness_sha"]))
')
check "the stored run records the window length" \
  "$(printf '%s\n' "$STORED" | awk '/^days/{print $2}')" "14"
check "and the window start it used" \
  "$(printf '%s\n' "$STORED" | awk '/^start/{print $2}')" "True"
check "and the corpus date range it covered" \
  "$(printf '%s\n' "$STORED" | awk '/^first/{print $2}')" "True"
check "and the harness fingerprint the Stop gate recompares" \
  "$(printf '%s\n' "$STORED" | awk '/^sha/{print $2}')" "True"

OUT=$(bench --runs 5 --no-store --only dispatcher --compare last); EXIT=$?
has "compare prints a delta table" "$OUT" "was"
has "compare names the run it compared against" "$OUT" "compare:"
has "compare reports the per-turn change" "$OUT" "per turn:"
check "an unchanged run exits clean" "$EXIT" "0"

# Slow the hook down far past the threshold and the gate must fail the run.
cat > "$HOOKS/pretooluse-dispatcher.py" <<'HOOKEOF'
import sys, time
payload = sys.stdin.read()
time.sleep(0.12)
if "--no-verify" in payload or "ruff.toml" in payload:
    print('{"hookSpecificOutput": {"permissionDecision": "deny"}}')
else:
    print("{}")
HOOKEOF
EXIT=0
OUT=$(bench --runs 5 --no-store --only dispatcher --compare last) || EXIT=$?
check "a regression past the threshold exits non-zero" "$EXIT" "1"
has "and the scenario is named as regressed" "$OUT" "REGRESSED"
EXIT=0
OUT=$(bench --runs 5 --no-store --only dispatcher --compare last --threshold-pct 100000) || EXIT=$?
check "a threshold above the change exits clean" "$EXIT" "0"
cp "$TEST_DIR/dispatcher.bak" "$HOOKS/pretooluse-dispatcher.py"

EXIT=0
OUT=$("$PY" "$SCRIPTS/harness-bench.py" --compare nope-no-such-run 2>&1) || EXIT=$?
if [ "$EXIT" -ne 0 ]; then ok "an unknown run id fails"; else bad "an unknown run id was accepted"; fi

# ------------------------------------------------ compare refuses mixed windows

printf 'compare refuses across windows\n'
EXIT=0
OUT=$(bench --runs 3 --no-store --only dispatcher --window-days 0 --compare last) || EXIT=$?
check "comparing a whole-corpus run against a 14-day one fails" "$EXIT" "2"
has "and says it refused rather than printing a delta" "$OUT" "compare REFUSED"
has "and names both windows" "$OUT" "whole corpus"
has "and says why the comparison would mislead" "$OUT" "would read as a regression"
hasnt "and prints no per-turn delta" "$OUT" "per turn:"

EXIT=0
OUT=$(bench --runs 3 --no-store --only dispatcher --window-days 7 --compare last) || EXIT=$?
check "a different window length fails too" "$EXIT" "2"
has "and names the field that differs, with both values" "$OUT" "days: 14 then, 7 now"

# A run stored before the window existed carries no window at all, and cannot be
# compared against either: what its weights were counted over is unknown.
"$PY" -c '
import json, sys
sys.stdout.write(json.dumps({"run_id": "legacy-no-window", "scenarios": [],
                             "context": {}, "headline": {}}) + "\n")
' >> "$STORE"
EXIT=0
OUT=$(bench --runs 3 --no-store --only dispatcher --compare last) || EXIT=$?
check "a stored run with no window recorded fails" "$EXIT" "2"
has "and says the stored window is unknown" "$OUT" "records no weighting window"
has "and names the run it refused" "$OUT" "legacy-no-window"

EXIT=0
OUT=$(bench --runs 3 --no-store --only dispatcher --compare last --window-days 14) || EXIT=$?
check "the refusal is about the window, not the flag" "$EXIT" "2"

# ------------------------------------------------------------------- summary

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
