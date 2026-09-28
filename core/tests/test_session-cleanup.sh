#!/usr/bin/env bash
# Tests for session-artifact.sh and session-cleanup.sh.
#
# Herdr is stubbed: HERDR_BIN_PATH points at a script that serves canned JSON and
# logs every mutating call, so the tab, pane and workspace decisions are tested
# without a live multiplexer.
set -uo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
readonly SCRIPTS
TEST_DIR=$(mktemp -d)
readonly TEST_DIR
trap 'rm -rf "$TEST_DIR"' EXIT

export HARNESS_WORKSPACE="$TEST_DIR/workspace"
export HERDR_PANE_ID="w9:p9"
export HERDR_TAB_ID="w9:t9"
export HERDR_WORKSPACE_ID="w9"
mkdir -p "$HARNESS_WORKSPACE"

PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (missing '$3' in: $2)" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1 (unexpected '$3')" ;; *) ok "$1" ;; esac; }

# ------------------------------------------------------------------ the stub

STUB_DIR="$TEST_DIR/stub"
mkdir -p "$STUB_DIR"
export STUB_DIR
cat > "$STUB_DIR/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "agent list")     cat "$STUB_DIR/agents.json" ;;
  "pane list")      cat "$STUB_DIR/panes.json" ;;
  "workspace list") cat "$STUB_DIR/workspaces.json" ;;
  *) printf '%s\n' "$*" >> "$STUB_DIR/calls.log" ;;
esac
STUB
chmod +x "$STUB_DIR/herdr"
export HERDR_BIN_PATH="$STUB_DIR/herdr"
printf '{"result":{"agents":[]}}\n'     > "$STUB_DIR/agents.json"
printf '{"result":{"panes":[]}}\n'      > "$STUB_DIR/panes.json"
printf '{"result":{"workspaces":[]}}\n' > "$STUB_DIR/workspaces.json"
: > "$STUB_DIR/calls.log"

# ------------------------------------------------------------------- fixtures

ORIGIN="$TEST_DIR/origin.git"
MAIN="$TEST_DIR/repo"
git init -q --bare "$ORIGIN"
git init -q -b main "$MAIN"
git -C "$MAIN" config user.email t@t.t
git -C "$MAIN" config user.name t
git -C "$MAIN" remote add origin "$ORIGIN"
printf 'x\n' > "$MAIN/f.txt"
git -C "$MAIN" add f.txt
git -C "$MAIN" commit -qm init
git -C "$MAIN" push -q -u origin main

# name -> physical path of a new worktree whose branch is pushed and clean.
# The physical path matters: /var is a symlink to /private/var on macOS, and the
# registry stores what `pwd -P` resolves, so a test comparing the logical path
# would fail against correct behaviour.
new_worktree() {
  local name="$1" path="$TEST_DIR/wt-$1"
  git -C "$MAIN" worktree add -q -b "$name" "$path" >/dev/null 2>&1
  git -C "$path" push -q -u origin "$name"
  (cd "$path" && pwd -P)
}

CLEAN_WT=$(new_worktree clean)
DIRTY_WT=$(new_worktree dirty)
AHEAD_WT=$(new_worktree ahead)
printf 'edit\n' > "$DIRTY_WT/f.txt"
printf 'more\n' > "$AHEAD_WT/f.txt"
git -C "$AHEAD_WT" commit -qam "local only"

cd "$TEST_DIR" || exit 1

# ------------------------------------------------------- session-artifact.sh

printf 'session-artifact validation\n'
EXIT=0; OUT=$("$SCRIPTS/session-artifact.sh" add bogus "$CLEAN_WT" 2>&1) || EXIT=$?
check "invalid kind rejected" "$EXIT" "1"
has "invalid kind message" "$OUT" "invalid kind"

EXIT=0; OUT=$("$SCRIPTS/session-artifact.sh" add worktree "$TEST_DIR/nope" 2>&1) || EXIT=$?
check "missing worktree path rejected" "$EXIT" "1"

EXIT=0; OUT=$("$SCRIPTS/session-artifact.sh" add worktree "$TEST_DIR" 2>&1) || EXIT=$?
check "non-git path rejected" "$EXIT" "1"

EXIT=0; OUT=$("$SCRIPTS/session-artifact.sh" add tab 'w1:t1; rm -rf /' 2>&1) || EXIT=$?
check "injection-shaped tab id rejected" "$EXIT" "1"

EXIT=0; "$SCRIPTS/session-artifact.sh" add tab 'w1:t1' >/dev/null 2>&1 || EXIT=$?
check "valid tab id accepted" "$EXIT" "0"

"$SCRIPTS/session-artifact.sh" add tab 'w1:t1' >/dev/null 2>&1
check "duplicate not written twice" "$("$SCRIPTS/session-artifact.sh" list | grep -c '^tab|')" "1"

"$SCRIPTS/session-artifact.sh" drop 'w1:t1' >/dev/null 2>&1
check "drop removes the line" "$("$SCRIPTS/session-artifact.sh" list | grep -c '^tab|' || true)" "0"

printf 'session-artifact slot kind\n'
EXIT=0; OUT=$("$SCRIPTS/session-artifact.sh" add slot '3' 2>&1) || EXIT=$?
check "a bare slot number is accepted" "$EXIT" "0"
has "the slot is reported registered" "$OUT" "registered: slot 3"
check "the slot reaches the registry" \
  "$("$SCRIPTS/session-artifact.sh" list | grep -c '^slot|3|')" "1"

EXIT=0; OUT=$("$SCRIPTS/session-artifact.sh" add slot '0' 2>&1) || EXIT=$?
check "a leading zero is refused" "$EXIT" "1"
EXIT=0; OUT=$("$SCRIPTS/session-artifact.sh" add slot '007' 2>&1) || EXIT=$?
check "a zero-padded slot is refused" "$EXIT" "1"
EXIT=0; OUT=$("$SCRIPTS/session-artifact.sh" add slot '100' 2>&1) || EXIT=$?
check "a slot over two digits is refused" "$EXIT" "1"
EXIT=0; OUT=$("$SCRIPTS/session-artifact.sh" add slot '' 2>&1) || EXIT=$?
check "an empty slot is refused" "$EXIT" "1"
EXIT=0; OUT=$("$SCRIPTS/session-artifact.sh" add slot '3; rm -rf /' 2>&1) || EXIT=$?
check "an injected slot is refused" "$EXIT" "1"
has "the refusal names the rule" "$OUT" "slot must be 1-99"
EXIT=0; OUT=$("$SCRIPTS/session-artifact.sh" add slot '../../etc' 2>&1) || EXIT=$?
check "a path as a slot is refused" "$EXIT" "1"
EXIT=0; OUT=$("$SCRIPTS/session-artifact.sh" add slot '--apply' 2>&1) || EXIT=$?
check "a flag as a slot is refused" "$EXIT" "1"

"$SCRIPTS/session-artifact.sh" add slot '3' >/dev/null 2>&1
check "a duplicate slot is not written twice" \
  "$("$SCRIPTS/session-artifact.sh" list | grep -c '^slot|')" "1"
"$SCRIPTS/session-artifact.sh" drop '3' >/dev/null 2>&1
check "drop releases the slot" \
  "$("$SCRIPTS/session-artifact.sh" list | grep -c '^slot|' || true)" "0"

# A slot is not a Herdr id and a Herdr id is not a slot. Neither validator may
# accept the other's shape, or a typo would register the wrong kind of resource.
EXIT=0; OUT=$("$SCRIPTS/session-artifact.sh" add slot 'w1:p1' 2>&1) || EXIT=$?
check "a Herdr id is refused as a slot" "$EXIT" "1"
EXIT=0; OUT=$("$SCRIPTS/session-artifact.sh" add pane '3' 2>&1) || EXIT=$?
check "a slot number is refused as a pane" "$EXIT" "1"

# An unknown kind must stay invisible to the close rather than crash it, so a
# newer registry never breaks an older cleanup.
printf 'future|whatever|2026-01-01T00:00:00+0000\n' >> "$("$SCRIPTS/session-artifact.sh" list >/dev/null; find "$HARNESS_WORKSPACE" -name 'artifacts*' | head -1)"
EXIT=0; OUT=$("$SCRIPTS/session-cleanup.sh" 2>&1) || EXIT=$?
check "an unknown kind does not break cleanup" "$EXIT" "0"

# ------------------------------------------------------- worktree decisions

printf 'worktree safety gate\n'
for w in "$CLEAN_WT" "$DIRTY_WT" "$AHEAD_WT"; do
  "$SCRIPTS/session-artifact.sh" add worktree "$w" >/dev/null
done

OUT=$("$SCRIPTS/session-cleanup.sh" 2>&1)
has "clean worktree planned for removal" "$OUT" "would remove worktree $CLEAN_WT"
has "dirty worktree kept"                "$OUT" "worktree kept: $DIRTY_WT"
has "dirty reason names uncommitted"     "$OUT" "1 uncommitted"
has "unpushed worktree kept"             "$OUT" "worktree kept: $AHEAD_WT"
has "unpushed reason names unpushed"     "$OUT" "1 unpushed"
has "kept line carries a resume command" "$OUT" "resume with: herdr worktree open --path"
if [ -d "$CLEAN_WT" ]; then ok "dry run removed nothing"; else bad "dry run removed a worktree"; fi

OUT=$("$SCRIPTS/session-cleanup.sh" --apply 2>&1)
has "clean worktree removed" "$OUT" "removed worktree $CLEAN_WT"
if [ ! -d "$CLEAN_WT" ]; then ok "clean worktree gone from disk"; else bad "clean worktree still on disk"; fi
if [ -d "$DIRTY_WT" ] && [ -d "$AHEAD_WT" ]; then ok "work-holding worktrees survive"; else bad "a work-holding worktree was destroyed"; fi
check "removed worktree dropped from the registry" \
  "$("$SCRIPTS/session-artifact.sh" list | grep -c "$CLEAN_WT" || true)" "0"
check "kept worktrees stay registered" \
  "$("$SCRIPTS/session-artifact.sh" list | grep -c '^worktree|' || true)" "2"

printf 'carry-over recording\n'
# The project is the repository, so the ledger only exists for a cwd inside one.
WORKREPO="$TEST_DIR/testco"
git init -q -b main "$WORKREPO"
git -C "$WORKREPO" config user.email t@t.t; git -C "$WORKREPO" config user.name t
(cd "$WORKREPO" && "$SCRIPTS/session-cleanup.sh" --record >/dev/null 2>&1)
LEDGER="$HARNESS_WORKSPACE/projects/testco/LEDGER.md"
if [ -f "$LEDGER" ]; then
  check "one ledger line per kept worktree" "$(grep -c 'carry-over: worktree' "$LEDGER")" "2"
else
  bad "no ledger written for carry-over"
fi

printf 'pruning\n'
STALE=$(new_worktree stale)
rm -rf "$STALE"
OUT=$(cd "$MAIN" && "$SCRIPTS/session-cleanup.sh" --apply 2>&1)
has "stale record pruned" "$OUT" "stale worktree record"
check "prune really ran" "$(git -C "$MAIN" worktree list --porcelain | grep -c '^prunable' || true)" "0"

# ------------------------------------------------------------ child agents

printf 'child agents\n'
: > "$STUB_DIR/calls.log"
export HERDR_ENV=1
cat > "$STUB_DIR/agents.json" <<'JSON'
{"result":{"agents":[
 {"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1","name":"kid-a","agent_status":"idle","cwd":"/x","tokens":{"parent":"w9:p9"}},
 {"pane_id":"w1:p2","tab_id":"w1:t1","workspace_id":"w1","name":"kid-b","agent_status":"working","cwd":"/x","tokens":{"parent":"w9:p9"}},
 {"pane_id":"w1:p3","tab_id":"w1:t2","workspace_id":"w1","name":"kid-c","agent_status":"done","cwd":"/x","tokens":{"parent":"w9:p9"}},
 {"pane_id":"w1:p4","tab_id":"w1:t2","workspace_id":"w1","name":"stranger","agent_status":"idle","cwd":"/x"},
 {"pane_id":"w9:p9","tab_id":"w9:t9","workspace_id":"w9","name":"me","agent_status":"working","cwd":"/x"}
]}}
JSON
cat > "$STUB_DIR/panes.json" <<'JSON'
{"result":{"panes":[
 {"pane_id":"w1:p1","tab_id":"w1:t1","agent":"claude"},
 {"pane_id":"w1:p2","tab_id":"w1:t1","agent":"claude"},
 {"pane_id":"w1:p3","tab_id":"w1:t2","agent":"claude"},
 {"pane_id":"w1:p4","tab_id":"w1:t2","agent":"claude"},
 {"pane_id":"w1:p5","tab_id":"w1:t3","agent":null}
]}}
JSON

OUT=$("$SCRIPTS/session-cleanup.sh" --apply 2>&1)
has  "working child kept"            "$OUT" "child kept: kid-b at w1:p2, state working"
hasnt "tab with a working child closed" "$OUT" "close tab w1:t1"
hasnt "tab holding a stranger closed"   "$OUT" "close tab w1:t2"
has  "finished child pane closed"    "$OUT" "closed child pane w1:p3 (kid-c)"
hasnt "own pane closed"              "$OUT" "w9:p9"
CALLS=$(cat "$STUB_DIR/calls.log")
has  "pane close issued for the finished child" "$CALLS" "pane close w1:p3"
hasnt "no tab close issued"          "$CALLS" "tab close"

printf 'whole-tab close\n'
: > "$STUB_DIR/calls.log"
cat > "$STUB_DIR/panes.json" <<'JSON'
{"result":{"panes":[
 {"pane_id":"w1:p1","tab_id":"w1:t1","agent":"claude"},
 {"pane_id":"w1:p2","tab_id":"w1:t1","agent":"claude"},
 {"pane_id":"w1:p3","tab_id":"w1:t2","agent":"claude"},
 {"pane_id":"w1:p6","tab_id":"w1:t2","agent":null}
]}}
JSON
cat > "$STUB_DIR/agents.json" <<'JSON'
{"result":{"agents":[
 {"pane_id":"w1:p3","tab_id":"w1:t2","workspace_id":"w1","name":"kid-c","agent_status":"done","cwd":"/x","tokens":{"parent":"w9:p9"}}
]}}
JSON
OUT=$("$SCRIPTS/session-cleanup.sh" --apply 2>&1)
has "tab of only my children closed" "$OUT" "closed tab w1:t2 with 2 pane(s) (kid-c)"
has "tab close issued" "$(cat "$STUB_DIR/calls.log")" "tab close w1:t2"

printf 'empty run\n'
printf '{"result":{"agents":[]}}\n' > "$STUB_DIR/agents.json"
rm -f "$HARNESS_WORKSPACE/sessions/.active/w9p9.artifacts"
OUT=$(cd "$TEST_DIR" && "$SCRIPTS/session-cleanup.sh" 2>&1)
check "nothing to do says so" "$OUT" "- nothing to clean up"

# -------------------------------------------------- transcript resolution

printf 'transcript comes from Herdr, not from mtime\n'
# Sourced in the main shell, not a subshell: a check inside a subshell prints its
# result but cannot raise the failure count, so the suite would pass regardless.
# shellcheck source=../session-lib.sh
. "$SCRIPTS/session-lib.sh"
TDIR=$(transcript_dir_for "$TEST_DIR")
mkdir -p "$TDIR"
MINE="$TDIR/aaaa-1111.jsonl"
OTHER="$TDIR/bbbb-2222.jsonl"
printf 'mine\n'  > "$MINE"
sleep 1
printf 'other\n' > "$OTHER"   # newer, and belongs to another pane
printf '{"result":{"pane":{"agent_session":{"value":"aaaa-1111"}}}}\n' > "$STUB_DIR/pane-get.json"
cat > "$STUB_DIR/herdr" <<'STUB2'
#!/usr/bin/env bash
case "$1 $2" in
  "pane get") cat "$STUB_DIR/pane-get.json" ;;
  *) printf '{"result":{}}\n' ;;
esac
STUB2
chmod +x "$STUB_DIR/herdr"
export HERDR_ENV=1
check "newest_transcript picks the wrong one" "$(newest_transcript "$TEST_DIR")" "$OTHER"
check "herdr_transcript picks this pane's"    "$(herdr_transcript "$TEST_DIR")" "$MINE"
HERDR_ENV=0
check "no Herdr means empty, so the caller falls back" "$(herdr_transcript "$TEST_DIR")" ""
HERDR_ENV=1
printf '{"result":{"pane":{"agent_session":{"value":"gone-9999"}}}}\n' > "$STUB_DIR/pane-get.json"
check "a missing transcript file yields empty" "$(herdr_transcript "$TEST_DIR")" ""

# restore the JSON-serving stub for the sections below
cat > "$STUB_DIR/herdr" <<'STUB3'
#!/usr/bin/env bash
case "$1 $2" in
  "agent list")     cat "$STUB_DIR/agents.json" ;;
  "pane list")      cat "$STUB_DIR/panes.json" ;;
  "workspace list") cat "$STUB_DIR/workspaces.json" ;;
  *) printf '%s\n' "$*" >> "$STUB_DIR/calls.log" ;;
esac
STUB3
chmod +x "$STUB_DIR/herdr"

# ----------------------------------------------------------- port slots
#
# Ports outlive a pane: relay-stack.sh detaches its services, so closing a
# child's pane leaves its stack running and its ports held. Before this, the
# close had no idea slots existed and said "nothing to clean up" while a slot
# stayed allocated.

printf 'the close frees the ports it allocated\n'
SLOTREPO="$TEST_DIR/slotrepo"
git init -q -b main "$SLOTREPO"
git -C "$SLOTREPO" config user.email t@t.t; git -C "$SLOTREPO" config user.name t
printf 'x\n' > "$SLOTREPO/f"; git -C "$SLOTREPO" add f; git -C "$SLOTREPO" commit -qm i
LANE_WORKTREE_ROOT="$TEST_DIR/slotwt" "$SCRIPTS/session-lane.sh" up slotlane --repo "$SLOTREPO" >/dev/null 2>&1

OUT=$("$SCRIPTS/session-cleanup.sh" 2>&1)
has "a dry run reports the slot" "$OUT" "would release slot"
has "and names the lane holding it" "$OUT" "slotlane"
check "a dry run releases nothing" \
  "$("$SCRIPTS/session-lane.sh" list --porcelain | grep -c '^slotlane|')" "1"

# A lane whose agent is still working is kept, on the same rule that keeps such
# a child: releasing the slot underneath it would break the work.
printf '{"result":{"agents":[{"name":"slotlane","agent_status":"working","tokens":{"parent":"w9:p9"}}]}}\n' \
  > "$STUB_DIR/agents.json"
OUT=$("$SCRIPTS/session-cleanup.sh" --apply 2>&1)
has "a lane with a working agent is kept" "$OUT" "slot kept"
check "and its slot survives" \
  "$("$SCRIPTS/session-lane.sh" list --porcelain | grep -c '^slotlane|')" "1"

printf '{"result":{"agents":[]}}\n' > "$STUB_DIR/agents.json"
OUT=$("$SCRIPTS/session-cleanup.sh" --apply 2>&1)
has "with no agent running it is released" "$OUT" "released slot"
check "and the lane is gone" \
  "$("$SCRIPTS/session-lane.sh" list --porcelain | grep -c '^slotlane|' || true)" "0"

# The ordering that matters: a service must stop before the pane that started it.
SRC_TEXT=$(cat "$SCRIPTS/session-cleanup.sh")
SLOT_AT=$(printf '%s' "$SRC_TEXT" | grep -n 'port slots' | head -1 | cut -d: -f1)
PANE_AT=$(printf '%s' "$SRC_TEXT" | grep -n 'child agents' | head -1 | cut -d: -f1)
check "slots are released before panes are closed" \
  "$([ "$SLOT_AT" -lt "$PANE_AT" ] && echo yes)" "yes"

# ------------------------------------------------------ session-wrap wiring

printf 'session-wrap integration\n'
WRAPDIR="$TEST_DIR/wrapwork"
mkdir -p "$WRAPDIR"
cd "$WRAPDIR" || exit 1
rm -rf "$HARNESS_WORKSPACE/sessions"
"$SCRIPTS/session-wrap.sh" --auto --summary "s" >/dev/null 2>&1
JOURNAL=$(find "$HARNESS_WORKSPACE/sessions" -name '*.md' | head -1)
has "wrap embeds the cleanup section" "$(cat "$JOURNAL")" "### Cleanup and carry-over"
has "wrap records the empty result"   "$(cat "$JOURNAL")" "nothing to clean up"

rm -rf "$HARNESS_WORKSPACE/sessions"
"$SCRIPTS/session-wrap.sh" --auto --no-cleanup --summary "s" >/dev/null 2>&1
JOURNAL=$(find "$HARNESS_WORKSPACE/sessions" -name '*.md' | head -1)
hasnt "--no-cleanup skips the section" "$(cat "$JOURNAL")" "### Cleanup and carry-over"

printf 'auto mode destroys nothing\n'
SAFE=$(new_worktree safe)
# Reset before registering: the registry lives under SESSIONS/.active, so
# clearing SESSIONS afterwards would throw away the very entry under test.
rm -rf "$HARNESS_WORKSPACE/sessions"
"$SCRIPTS/session-artifact.sh" add worktree "$SAFE" >/dev/null
"$SCRIPTS/session-wrap.sh" --auto --summary "s" >/dev/null 2>&1
if [ -d "$SAFE" ]; then ok "auto wrap left the clean worktree alone"; else bad "auto wrap removed a worktree unwatched"; fi
JOURNAL=$(find "$HARNESS_WORKSPACE/sessions" -name '*.md' | head -1)
has "auto wrap reports what it would remove" "$(cat "$JOURNAL")" "would remove worktree $SAFE"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
