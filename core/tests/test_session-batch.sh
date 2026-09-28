#!/usr/bin/env bash
# Tests for session-batch.sh: the durable record of an orchestrated batch.
#
# The properties under test are the ones the record exists for: it survives the
# pane that wrote it, it is readable without disturbing anything, it is append
# only, and silence in it is detectable.
set -uo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
readonly SCRIPTS
TEST_DIR=$(mktemp -d)
readonly TEST_DIR
trap 'rm -rf "$TEST_DIR"' EXIT
export HARNESS_WORKSPACE="$TEST_DIR/workspace"
export HERDR_PANE_ID="wA:p1"
mkdir -p "$HARNESS_WORKSPACE"

PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (missing '$3')" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1 (unexpected '$3')" ;; *) ok "$1" ;; esac; }
b() { "$SCRIPTS/session-batch.sh" "$@"; }
LOG="$HARNESS_WORKSPACE/sessions/.active/batches/orbit.log"

printf 'open\n'
EXIT=0; OUT=$(b open 'Orbit' --goal g 2>&1) || EXIT=$?
check "an invalid batch name is refused" "$EXIT" "1"
EXIT=0; OUT=$(b open orbit 2>&1) || EXIT=$?
check "a goal is required" "$EXIT" "2"
OUT=$(b open orbit --goal "ship the dashboard" 2>&1)
has "it reports the batch open" "$OUT" "batch orbit open"
has "it warns when no exit criteria are set" "$OUT" "no exit criteria"
EXIT=0; OUT=$(b open orbit --goal x 2>&1) || EXIT=$?
check "a duplicate batch is refused" "$EXIT" "1"
EXIT=0; OUT=$(b brief nosuch api --text x 2>&1) || EXIT=$?
check "an unknown batch is refused" "$EXIT" "1"
has "the refusal says how to open one" "$OUT" "session-batch.sh open"

printf 'brief\n'
b brief orbit api --text "own src/api, branch lane/api" >/dev/null
printf 'multi\nline brief with a | pipe\n' > "$TEST_DIR/brief.txt"
b brief orbit web --file "$TEST_DIR/brief.txt" >/dev/null
# OPEN, GOAL and two BRIEFs. A two-line brief file that stayed two lines would
# make this five, so the count is what proves the flattening.
check "a brief with newlines and pipes stays on one line" "$(grep -c . "$LOG")" "4"
check "no stray pipe split the brief into extra fields" \
  "$(awk -F'|' '$2=="BRIEF" && NF!=5' "$LOG" | wc -l | tr -d ' ')" "0"
check "the log still parses into five fields" \
  "$(awk -F'|' 'NF!=5{n++} END{print n+0}' "$LOG")" "0"
EXIT=0; OUT=$(b brief orbit api --file /nope 2>&1) || EXIT=$?
check "an unreadable brief file is refused" "$EXIT" "1"

printf 'state\n'
EXIT=0; OUT=$(b state orbit api sideways 2>&1) || EXIT=$?
check "an invalid state is refused" "$EXIT" "1"
b state orbit api working >/dev/null
b state orbit web working --note "waiting on the schema" >/dev/null
b state orbit api "done" --note "merged" >/dev/null

printf 'steer\n'
EXIT=0; OUT=$(b steer orbit --input x --disposition ignore 2>&1) || EXIT=$?
check "an invalid disposition is refused" "$EXIT" "1"
has "the refusal lists the three dispositions" "$OUT" "amend a brief, add a lane, or quiesce"
OUT=$(b steer orbit --input "also cover the error path" --disposition amend --lane api 2>&1)
has "an amend is recorded" "$OUT" "steer recorded: amend"
OUT=$(b steer orbit --input "drop the web lane, requirements changed" --disposition quiesce 2>&1)
has "quiesce tells you to stop and re-plan" "$OUT" "stop the affected lanes and re-plan"

printf 'status is a read-only query\n'
BEFORE=$(md5 -q "$LOG" 2>/dev/null || md5sum "$LOG" | cut -d' ' -f1)
OUT=$(b status orbit 2>&1)
AFTER=$(md5 -q "$LOG" 2>/dev/null || md5sum "$LOG" | cut -d' ' -f1)
check "reading the status writes nothing" "$BEFORE" "$AFTER"
has "it folds the goal" "$OUT" "ship the dashboard"
has "it flags missing exit criteria" "$OUT" "NOT SET"
has "it shows the latest lane state, not the first" "$OUT" "done"
has "it carries the note" "$OUT" "merged"
has "it counts the steers" "$OUT" "steers   2"

printf 'the record survives the pane that wrote it\n'
OUT=$(HERDR_PANE_ID="wB:p9" "$SCRIPTS/session-batch.sh" status orbit 2>&1)
has "another shell reads the goal" "$OUT" "ship the dashboard"
has "another shell reads the lane state" "$OUT" "api"
OUT=$(HERDR_PANE_ID="wB:p9" "$SCRIPTS/session-batch.sh" list 2>&1)
has "another shell lists the batch" "$OUT" "orbit"

printf 'append only\n'
LINES=$(grep -c . "$LOG")
b note orbit --lane api "one more thing" >/dev/null
check "a note appends rather than replacing" "$(grep -c . "$LOG")" "$((LINES + 1))"
check "the original open event is still there" "$(grep -c '|OPEN|' "$LOG")" "1"
check "both briefs are still there" "$(grep -c '|BRIEF|' "$LOG")" "2"

printf 'silence is detectable\n'
EXIT=0; OUT=$(b status orbit --stale 60 2>&1) || EXIT=$?
check "a fresh record passes the stale check" "$EXIT" "0"
has "it says how fresh" "$OUT" "fresh: last event"
touch -t 202601010000 "$LOG"
EXIT=0; OUT=$(b status orbit --stale 60 2>&1) || EXIT=$?
check "a silent record fails the stale check" "$EXIT" "1"
has "it says the lead may be wedged" "$OUT" "may be wedged"
EXIT=0; OUT=$(b status orbit --stale abc 2>&1) || EXIT=$?
check "a non-numeric stale window is refused" "$EXIT" "1"

printf 'close\n'
OUT=$(b close orbit --outcome "shipped, one lane deferred" 2>&1)
has "it reports the batch closed" "$OUT" "batch orbit closed"
OUT=$(b status orbit 2>&1)
has "status shows it closed" "$OUT" "(closed"
has "status shows the outcome" "$OUT" "shipped, one lane deferred"

printf 'exit criteria are recorded when given\n'
b open second --goal "fix the flake" --exit "the suite passes ten times" >/dev/null
OUT=$(b status second 2>&1)
has "the exit criterion is folded" "$OUT" "the suite passes ten times"
hasnt "no missing-criteria warning" "$OUT" "NOT SET"
# Before the `current` predicate existed, a bare status refused whenever a second
# log file existed at all, even a closed one. It now resolves the open batch,
# which is what someone asking "what is running" means.
EXIT=0; OUT=$(b status 2>&1) || EXIT=$?
check "a bare status resolves the open batch past a closed one" "$EXIT" "0"
has "and it is the open one, not the closed one" "$OUT" "fix the flake"

printf 'the current predicate answers with an exit status\n'
# `status` is for people and always exits 0, which made it useless as a test.
# A hook asking "am I orchestrating anything?" needs an exit status, and getting
# that wrong is what would have put string matching back into the guard layer.
CUR=$TEST_DIR/cur; mkdir -p "$CUR"
EXIT=0; OUT=$(HARNESS_WORKSPACE="$CUR" "$SCRIPTS/session-batch.sh" current 2>&1) || EXIT=$?
check "no batch exits 1" "$EXIT" "1"
check "and prints nothing" "$OUT" ""
HARNESS_WORKSPACE="$CUR" "$SCRIPTS/session-batch.sh" open only --goal g >/dev/null
EXIT=0; OUT=$(HARNESS_WORKSPACE="$CUR" "$SCRIPTS/session-batch.sh" current 2>&1) || EXIT=$?
check "one open batch exits 0" "$EXIT" "0"
check "and prints its name" "$OUT" "only"
HARNESS_WORKSPACE="$CUR" "$SCRIPTS/session-batch.sh" close only >/dev/null
EXIT=0; OUT=$(HARNESS_WORKSPACE="$CUR" "$SCRIPTS/session-batch.sh" current 2>&1) || EXIT=$?
check "a closed batch is not current" "$EXIT" "1"
OUT=$(HARNESS_WORKSPACE="$CUR" "$SCRIPTS/session-batch.sh" status 2>&1)
has "status still resolves the only closed batch" "$OUT" "only"
HARNESS_WORKSPACE="$CUR" "$SCRIPTS/session-batch.sh" open one --goal g >/dev/null
HARNESS_WORKSPACE="$CUR" "$SCRIPTS/session-batch.sh" open two --goal g >/dev/null
EXIT=0; OUT=$(HARNESS_WORKSPACE="$CUR" "$SCRIPTS/session-batch.sh" current 2>&1) || EXIT=$?
check "several open batches exit 2" "$EXIT" "2"
has "and the ambiguity is named" "$OUT" "several batches open"
EXIT=0; OUT=$(HARNESS_WORKSPACE="$CUR" "$SCRIPTS/session-batch.sh" status 2>&1) || EXIT=$?
check "a bare status is refused while several are open" "$EXIT" "1"

printf 'check reconciles the record against real state\n'
# The detective control. It compares state rather than command strings, which is
# why it caught a slotless lane on the vega run that no pattern rule could see.
CH="$TEST_DIR/check"; mkdir -p "$CH"
STUB2="$TEST_DIR/stub2"; mkdir -p "$STUB2"
cat > "$STUB2/herdr" <<'STUBEOF'
#!/usr/bin/env bash
[ "$1 $2" = "agent list" ] && cat "$AGENTS_JSON"
exit 0
STUBEOF
chmod +x "$STUB2/herdr"
export AGENTS_JSON="$STUB2/agents.json"
printf '{"result":{"agents":[]}}\n' > "$AGENTS_JSON"
CHECK() { HARNESS_WORKSPACE="$CH" PATH="$STUB2:$PATH" "$SCRIPTS/session-batch.sh" check "$@" 2>&1; }

REPO2="$TEST_DIR/repo2"
git init -q -b main "$REPO2"; git -C "$REPO2" config user.email t@t.t; git -C "$REPO2" config user.name t
printf 'x\n' > "$REPO2/f"; git -C "$REPO2" add f; git -C "$REPO2" commit -qm i

HARNESS_WORKSPACE="$CH" "$SCRIPTS/session-batch.sh" open recon --goal g >/dev/null
HARNESS_WORKSPACE="$CH" "$SCRIPTS/session-batch.sh" brief recon alpha --text "own it" >/dev/null

EXIT=0; OUT=$(CHECK recon) || EXIT=$?
check "a briefed lane with no slot is flagged" "$EXIT" "1"
has "and it says why it matters" "$OUT" "collide on the default ports"
has "and how to fix it" "$OUT" "--adopt"

HARNESS_WORKSPACE="$CH" LANE_WORKTREE_ROOT="$CH/wt" PATH="$STUB2:$PATH" \
  "$SCRIPTS/session-lane.sh" up alpha --repo "$REPO2" >/dev/null 2>&1
printf '{"result":{"agents":[{"name":"alpha","agent_status":"working","cwd":"%s","tokens":{"role":"\\u21b3p1"}}]}}\n' \
  "$CH/wt/repo2/alpha" > "$AGENTS_JSON"
EXIT=0; OUT=$(CHECK recon) || EXIT=$?
check "once allocated and running, it reconciles" "$EXIT" "0"
has "and says so plainly" "$OUT" "reconciles"

printf 'a lane mid-spawn is not reported as a leak\n'
# The first live run flagged a lane that was being spawned that second.
printf '{"result":{"agents":[]}}\n' > "$AGENTS_JSON"
EXIT=0; OUT=$(CHECK recon) || EXIT=$?
check "inside the grace period it stays quiet about the missing agent" \
  "$(printf '%s' "$OUT" | grep -c 'held for nothing' || true)" "0"
EXIT=0; OUT=$(HARNESS_WORKSPACE="$CH" PATH="$STUB2:$PATH" BATCH_CHECK_GRACE_SECONDS=0 \
  "$SCRIPTS/session-batch.sh" check recon 2>&1) || EXIT=$?
has "past the grace period it does report it" "$OUT" "held for nothing"

printf 'a finished lane whose agent is deliberately still alive\n'
# On the vega run the lead recorded qa done and kept its agent up to hold a test
# rig for a later step. The check called that drift, which it is not: the record
# knows the lane, and the lead chose to keep the agent.
HARNESS_WORKSPACE="$CH" "$SCRIPTS/session-batch.sh" state recon alpha "done" --note "holding the rig" >/dev/null
printf '{"result":{"agents":[{"name":"alpha","agent_status":"idle","cwd":"%s","tokens":{"role":"\\u21b3p1"}}]}}\n' \
  "$CH/wt/repo2/alpha" > "$AGENTS_JSON"
EXIT=0; OUT=$(CHECK recon) || EXIT=$?
hasnt "a done lane with a live agent is not reported as unknown" "$OUT" "does not know it"
HARNESS_WORKSPACE="$CH" "$SCRIPTS/session-batch.sh" state recon alpha working >/dev/null

printf 'a child the record has not briefed\n'
printf '{"result":{"agents":[{"name":"alpha","agent_status":"working","cwd":"%s","tokens":{"role":"\\u21b3p1"}},{"name":"ghost","agent_status":"working","cwd":"/tmp","tokens":{"role":"\\u21b3p1"}}]}}\n' \
  "$CH/wt/repo2/alpha" > "$AGENTS_JSON"
EXIT=0; OUT=$(CHECK recon) || EXIT=$?
check "an unknown child is flagged" "$EXIT" "1"
has "and named as entirely unknown" "$OUT" "does not know it at all"
HARNESS_WORKSPACE="$CH" "$SCRIPTS/session-batch.sh" steer recon --input "add a ghost lane" --disposition add --lane ghost >/dev/null
OUT=$(CHECK recon)
has "once steered, it reports the softer no-brief case" "$OUT" "has no brief in the record"

printf 'burst mode\n'
# A burst is a lane with no worktree and no slot, for a targeted question that
# does not justify the ceremony. Recording is not optional: an unrecorded child
# is precisely what the reconciliation check exists to catch.
BU="$TEST_DIR/burst"; mkdir -p "$BU"
BURST() { HARNESS_WORKSPACE="$BU" PATH="$STUB2:$PATH" "$SCRIPTS/session-batch.sh" "$@" 2>&1; }
HARNESS_WORKSPACE="$BU" "$SCRIPTS/session-batch.sh" open bb --goal g >/dev/null
printf '{"result":{"agents":[]}}\n' > "$AGENTS_JSON"

EXIT=0; OUT=$(BURST burst bb scan) || EXIT=$?
check "a burst without a task is refused" "$EXIT" "2"
OUT=$(BURST burst bb scan --task "which files import the old client")
has "it records the burst" "$OUT" "burst scan recorded"
has "it says it must not write" "$OUT" "must not write to a repository"
has "it says what to do if it needs to" "$OUT" "allocate a real lane instead"
has "and it hands over the release step" "$OUT" "herdr pane close"

# The forcing function: a burst is known to the check, so recording it is what
# keeps it from tripping the unknown-child alarm.
printf '{"result":{"agents":[{"name":"scan","agent_status":"working","tokens":{"role":"\\u21b3p1"}}]}}\n' > "$AGENTS_JSON"
OUT=$(BURST check bb)
hasnt "a recorded burst is not an unknown child" "$OUT" "does not know it at all"

# And the leak this mode is most prone to: it answered, and nobody closed it.
printf '{"result":{"agents":[{"name":"scan","agent_status":"idle","tokens":{"role":"\\u21b3p1"}}]}}\n' > "$AGENTS_JSON"
EXIT=0; OUT=$(BURST check bb) || EXIT=$?
check "an idle burst is reported" "$EXIT" "1"
has "and named as answered" "$OUT" "has answered and is idle"

# An unrecorded child still trips the alarm, which is the whole point.
printf '{"result":{"agents":[{"name":"sneaky","agent_status":"working","tokens":{"role":"\\u21b3p1"}}]}}\n' > "$AGENTS_JSON"
OUT=$(BURST check bb)
has "an unrecorded child is still caught" "$OUT" "does not know it at all"
printf '{"result":{"agents":[]}}\n' > "$AGENTS_JSON"

printf 'every lane carries the age of its own last state event\n'
# A batch-wide `last` says fresh while a lane sits dead. On the vega run one busy
# lane kept the record ticking, so nothing looked stale and a quiet lane had to be
# found by hand. The age is per lane for that reason.
AG="$TEST_DIR/age"; mkdir -p "$AG"
A() { HARNESS_WORKSPACE="$AG" "$SCRIPTS/session-batch.sh" "$@"; }
A open ages --goal g >/dev/null
A brief ages busy --text own >/dev/null
A brief ages quiet --text own >/dev/null
AGELOG="$AG/sessions/.active/batches/ages.log"
# Backdate quiet by three hours and leave busy on now, which is the shape that
# defeats a batch-wide staleness check.
OLD=$(date -v-3H '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date -d '3 hours ago' '+%Y-%m-%dT%H:%M:%S%z')
printf '%s|STATE|quiet|wA:p1|working :: reading\n' "$OLD" >> "$AGELOG"
A state ages busy working --note "still going" >/dev/null
OUT=$(A status ages)
has "the lanes table names an age column" "$OUT" "AGE"
has "a lane that just reported reads as minutes old" "$OUT" "0m"
has "a lane quiet for three hours says so" "$OUT" "3h0m"
# The whole point: the batch is fresh and one lane is not.
EXIT=0; A status ages --stale 60 >/dev/null 2>&1 || EXIT=$?
check "the batch itself still passes a staleness check" "$EXIT" "0"
# A steer is not a sign of life from the lane, so it must not reset the age.
A steer ages --input "keep going" --disposition amend --lane quiet >/dev/null
OUT=$(A status ages)
has "a steer does not refresh a quiet lane's age" "$OUT" "3h0m"

printf 'check compares the record against git and against the agent\n'
# Every other rule compares one record with another. These two compare the claim
# with the disk, which is the only source that cannot be talked into agreeing.
GD="$TEST_DIR/gitdrift"; mkdir -p "$GD"
REPO3="$TEST_DIR/repo3"
git init -q -b main "$REPO3"; git -C "$REPO3" config user.email t@t.t; git -C "$REPO3" config user.name t
printf 'x\n' > "$REPO3/f"; git -C "$REPO3" add f; git -C "$REPO3" commit -qm i
G() { HARNESS_WORKSPACE="$GD" PATH="$STUB2:$PATH" "$SCRIPTS/session-batch.sh" "$@" 2>&1; }
HARNESS_WORKSPACE="$GD" "$SCRIPTS/session-batch.sh" open drift --goal g >/dev/null
HARNESS_WORKSPACE="$GD" "$SCRIPTS/session-batch.sh" brief drift beta --text own >/dev/null
HARNESS_WORKSPACE="$GD" LANE_WORKTREE_ROOT="$GD/wt" PATH="$STUB2:$PATH" \
  "$SCRIPTS/session-lane.sh" up beta --repo "$REPO3" >/dev/null 2>&1
BETA="$GD/wt/repo3/beta"
printf '{"result":{"agents":[{"name":"beta","agent_status":"working","cwd":"%s","tokens":{"role":"\\u21b3p1"}}]}}\n' \
  "$BETA" > "$AGENTS_JSON"

# A repo with no remote has nowhere to push, so silence is correct.
HARNESS_WORKSPACE="$GD" "$SCRIPTS/session-batch.sh" state drift beta "done" >/dev/null
OUT=$(G check drift)
hasnt "a clean done lane in a remoteless repo is not called unpushed" "$OUT" "never pushed"

printf 'scratch\n' > "$BETA/uncommitted"
EXIT=0; OUT=$(G check drift) || EXIT=$?
check "a done lane with a dirty worktree is flagged" "$EXIT" "1"
has "and it counts the files" "$OUT" "1 uncommitted file(s)"
has "and it says what happens next" "$OUT" "cleanup will refuse it"
rm -f "$BETA/uncommitted"

# With a remote, unpushed work under a done claim is the finding.
BARE="$TEST_DIR/bare.git"; git init -q --bare "$BARE"
git -C "$BETA" remote add origin "$BARE"
EXIT=0; OUT=$(G check drift) || EXIT=$?
check "a done lane that was never pushed is flagged" "$EXIT" "1"
has "and it says the work is nowhere else" "$OUT" "never pushed"
git -C "$BETA" push -q -u origin HEAD 2>/dev/null
OUT=$(G check drift)
hasnt "once pushed it stops being reported" "$OUT" "never pushed"
printf 'more\n' > "$BETA/f2"; git -C "$BETA" add f2; git -C "$BETA" commit -qm second
EXIT=0; OUT=$(G check drift) || EXIT=$?
has "a done lane ahead of its upstream is flagged" "$OUT" "commit(s) ahead of"

printf 'a lane recorded working whose agent is idle\n'
# The vega failure exactly: the child stopped, or asked a question and ended its
# turn, and recorded nothing. notify_when_idle cannot cover the second case, and
# the record cannot cover either, because what failed is what writes the record.
HARNESS_WORKSPACE="$GD" "$SCRIPTS/session-batch.sh" state drift beta working >/dev/null
OUT=$(G check drift)
hasnt "a working lane with a working agent is quiet" "$OUT" "its agent is idle"
printf '{"result":{"agents":[{"name":"beta","agent_status":"idle","cwd":"%s","tokens":{"role":"\\u21b3p1"}}]}}\n' \
  "$BETA" > "$AGENTS_JSON"
EXIT=0; OUT=$(G check drift) || EXIT=$?
check "a working lane with an idle agent is flagged" "$EXIT" "1"
has "and it names both readings" "$OUT" "recorded working but its agent is idle"
has "and the fix is to read the pane, not to guess" "$OUT" "read its pane"

# Found on the first live run of this rule: it read only `idle` and stayed silent
# on a lane whose agent herdr had already marked `done` under a working claim.
# Both are the same failure, so both are reported.
printf '{"result":{"agents":[{"name":"beta","agent_status":"done","cwd":"%s","tokens":{"role":"\\u21b3p1"}}]}}\n' \
  "$BETA" > "$AGENTS_JSON"
EXIT=0; OUT=$(G check drift) || EXIT=$?
check "a working lane whose agent herdr calls done is flagged too" "$EXIT" "1"
has "and it names the status it actually saw" "$OUT" "its agent is done"

# blocked is left to the watchdog, which pushes it straight from herdr. A second
# voice on the same fact trains the reader to skim the whole report.
printf '{"result":{"agents":[{"name":"beta","agent_status":"blocked","cwd":"%s","tokens":{"role":"\\u21b3p1"}}]}}\n' \
  "$BETA" > "$AGENTS_JSON"
OUT=$(G check drift)
hasnt "a blocked agent is not double-reported here" "$OUT" "it stopped or asked a question"
printf '{"result":{"agents":[]}}\n' > "$AGENTS_JSON"

printf 'concurrent writers cannot tear a line\n'
# The lead is the only writer today, so nothing has ever contended. A child
# writing its own state is the second writer.
#
# The payload size here is measured, not guessed. The first version of this test
# used 4 KB and passed with the lock removed, which made it worthless. Twelve
# writers at 16 KB still tear nothing; at 65 KB the unlocked version tore six of
# twelve. So the test runs at the size that actually reproduces the fault, and it
# fails if the lock is taken out.
CC="$TEST_DIR/conc"; mkdir -p "$CC"
HARNESS_WORKSPACE="$CC" "$SCRIPTS/session-batch.sh" open race --goal g >/dev/null
CCLOG="$CC/sessions/.active/batches/race.log"
BIG=$(head -c 65000 < /dev/zero | tr '\0' 'x')
for i in $(seq 1 12); do
  HARNESS_WORKSPACE="$CC" HERDR_PANE_ID="wA:p$i" \
    "$SCRIPTS/session-batch.sh" state race "lane$i" working --note "$BIG" >/dev/null 2>&1 &
done
wait
check "every concurrent write landed" "$(grep -c '|STATE|' "$CCLOG")" "12"
check "and none of them tore a line" \
  "$(awk -F'|' 'NF != 5 { n++ } END { print n + 0 }' "$CCLOG")" "0"
check "each writer is still attributable" \
  "$(awk -F'|' '$2 == "STATE" { print $4 }' "$CCLOG" | sort -u | grep -c .)" "12"
check "the lock left nothing behind" "$([ -d "$CCLOG.lock" ] && printf 1 || printf 0)" "0"

# The check above is honest but weak: the unlocked version tore in only 2 of 6
# trials, so as a regression guard it misses more often than it catches. It can
# never fail falsely, since the locked path tore in none. These two pin the lock
# itself, deterministically, and they are what actually holds the behaviour.
printf 'the lock is real, and a crashed writer cannot wedge the record\n'
mkdir "$CCLOG.lock"
BEFORE=$(grep -c . "$CCLOG")
HARNESS_WORKSPACE="$CC" HERDR_PANE_ID="wA:p99" \
  "$SCRIPTS/session-batch.sh" note race "held out" >/dev/null 2>&1 &
WRITER=$!
sleep 1
check "a writer waits while the lock is held" "$(grep -c . "$CCLOG")" "$BEFORE"
rmdir "$CCLOG.lock"
wait "$WRITER"
check "and lands as soon as it is released" "$(grep -c . "$CCLOG")" "$((BEFORE + 1))"

# A writer that died holding the lock must not stop everyone else forever.
mkdir "$CCLOG.lock"; touch -t 202601010000 "$CCLOG.lock"
BEFORE=$(grep -c . "$CCLOG")
HARNESS_WORKSPACE="$CC" "$SCRIPTS/session-batch.sh" note race "past a stale lock" >/dev/null 2>&1
check "a stale lock is reclaimed rather than waited out" "$(grep -c . "$CCLOG")" "$((BEFORE + 1))"
check "and it is not left lying around" "$([ -d "$CCLOG.lock" ] && printf 1 || printf 0)" "0"

printf 'source quality\n'

SRC=$(cat "$SCRIPTS/session-batch.sh")
has "strict mode" "$SRC" "set -euo pipefail"
has "readonly constants" "$SRC" "readonly STATES"
has "errors go to stderr through die" "$SRC" "die "
has "payloads are flattened, not rejected" "$SRC" "flatten()"
has "the predicate is a separate command from status" "$SRC" "cmd_current()"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
