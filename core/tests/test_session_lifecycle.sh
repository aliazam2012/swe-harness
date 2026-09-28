#!/usr/bin/env bash
# Tests for session-lib.sh, session-card.sh, session-note.sh, session-wrap.sh.
set -uo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
readonly SCRIPTS
TEST_DIR=$(mktemp -d)
readonly TEST_DIR
trap 'rm -rf "$TEST_DIR"' EXIT

export HARNESS_WORKSPACE="$TEST_DIR/workspace"
export HERDR_PANE_ID="w9:p9"
export HOME="$TEST_DIR/home"
mkdir -p "$HARNESS_WORKSPACE" "$HOME/.claude"
new_repo() { git init -q -b main "$1"; git -C "$1" config user.email t@t.t; git -C "$1" config user.name t; }
WORK="$TEST_DIR/repos/testco"
mkdir -p "$TEST_DIR/repos"; new_repo "$WORK"

PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

reset_state() { rm -rf "$HARNESS_WORKSPACE/sessions"; }

printf 'project detection\n'
# shellcheck source=../session-lib.sh
. "$SCRIPTS/session-lib.sh"
check "a checkout maps to its repository name" "$(detect_project "$WORK")" "testco"
check "a subdirectory maps to the same name" "$(mkdir -p "$WORK/deep/er"; detect_project "$WORK/deep/er")" "testco"
check "a directory in no repository maps to empty" "$(detect_project "$TEST_DIR/repos")" ""
check "pane token strips colon"      "$(pane_token)" "w9p9"

printf 'session-note validation\n'
cd "$WORK" || exit 1
reset_state
EXIT=0; OUT=$("$SCRIPTS/session-note.sh" -k BOGUS "text" 2>&1) || EXIT=$?
check "invalid kind rejected" "$EXIT" "1"
case "$OUT" in *"invalid kind"*) ok "invalid kind message" ;; *) bad "invalid kind message: $OUT" ;; esac

EXIT=0; "$SCRIPTS/session-note.sh" -k NOTE "" >/dev/null 2>&1 || EXIT=$?
check "empty text rejected" "$EXIT" "1"

EXIT=0; "$SCRIPTS/session-note.sh" -t 'bad;rm -rf /' -k NOTE "x" >/dev/null 2>&1 || EXIT=$?
check "injection-shaped ticket rejected" "$EXIT" "1"

EXIT=0; "$SCRIPTS/session-note.sh" >/dev/null 2>&1 || EXIT=$?
check "missing text exits 2" "$EXIT" "2"

printf 'session-note behaviour\n'
reset_state
"$SCRIPTS/session-note.sh" -k NOTE "a plain note" >/dev/null 2>&1
LEDGER="$HARNESS_WORKSPACE/projects/testco/LEDGER.md"
if [ ! -f "$LEDGER" ]; then ok "NOTE does not create the ledger"; else bad "NOTE created the ledger"; fi

"$SCRIPTS/session-note.sh" -k DECISION -t T-1 "chose X over Y" >/dev/null 2>&1
if [ -f "$LEDGER" ]; then ok "DECISION creates the ledger"; else bad "DECISION did not create the ledger"; fi
check "ledger has one fact line" "$(grep -c '| DECISION' "$LEDGER")" "1"

"$SCRIPTS/session-note.sh" -k DONE -t T-2 "pipe | inside | text" >/dev/null 2>&1
LINE=$(grep '| DONE' "$LEDGER")
check "pipes in text are neutralized" "$(printf '%s' "$LINE" | tr -cd '|' | wc -c | tr -d ' ')" "4"

"$SCRIPTS/session-note.sh" -k BLOCKED "multi
line note" >/dev/null 2>&1
check "newlines collapse to one line" "$(grep -c '| BLOCKED' "$LEDGER")" "1"

JOURNAL=$(find "$HARNESS_WORKSPACE/sessions" -name '*.md' | head -1)
check "journal holds every note" "$(grep -c '^- ' "$JOURNAL")" "9"

printf 'mid-session project pivot\n'
new_repo "$TEST_DIR/repos/second"
BEFORE=$(cd "$WORK" && eval "$("$SCRIPTS/session-card.sh" >/dev/null 2>&1; . "$SCRIPTS/session-lib.sh"; session_state)"; printf '%s' "$SESSION_PROJECT")
AFTER=$(cd "$TEST_DIR/repos/second" && eval "$(. "$SCRIPTS/session-lib.sh"; session_state)"; printf '%s' "$SESSION_PROJECT")
check "project follows the working directory" "$BEFORE/$AFTER" "testco/second"
cd "$WORK" || exit 1

printf 'session-card\n'
CARD=$("$SCRIPTS/session-card.sh" 2>&1)
case "$CARD" in *"find things"*) ok "card prints the find-things block" ;; *) bad "card missing find-things block" ;; esac
case "$CARD" in *"ledger    testco"*) ok "card names the target ledger" ;; *) bad "card missing target ledger" ;; esac
case "$CARD" in *"record as you go"*) ok "card prints the record guide" ;; *) bad "card missing record guide" ;; esac
# The card must stay universal: it points at project content, never inlines it.
"$SCRIPTS/session-note.sh" -k BLOCKED "a seeded blocker that must not appear on the card" >/dev/null 2>&1
CARD2=$("$SCRIPTS/session-card.sh" 2>&1)
case "$CARD2" in
  *"a seeded blocker that must not appear"*) bad "card inlines ledger content" ;;
  *) ok "card does not inline ledger content" ;;
esac
mkdir -p "$HARNESS_WORKSPACE/projects/testco"
printf '## Blocked\n\n- an OPEN item that must not appear on the card\n' > "$HARNESS_WORKSPACE/projects/testco/OPEN.md"
CARD3=$("$SCRIPTS/session-card.sh" 2>&1)
case "$CARD3" in
  *"an OPEN item that must not appear"*) bad "card inlines OPEN.md" ;;
  *) ok "card does not inline OPEN.md" ;;
esac
LINES=$(printf '%s\n' "$CARD3" | wc -l | tr -d ' ')
if [ "$LINES" -le 30 ]; then ok "card stays under 30 lines ($LINES)"; else bad "card grew to $LINES lines"; fi

printf 'empty transcripts are not archived\n'
: > "$TEST_DIR/empty.jsonl"
rm -f "$HARNESS_WORKSPACE"/sessions/*/*.jsonl.gz
"$SCRIPTS/session-wrap.sh" --auto --transcript "$TEST_DIR/empty.jsonl" >/dev/null 2>&1 || true
check "no archive for a 0-byte transcript" "$(find "$HARNESS_WORKSPACE/sessions" -name '*.jsonl.gz' | wc -l | tr -d ' ')" "0"
printf 'x\n' > "$TEST_DIR/full.jsonl"
rm -f "$HARNESS_WORKSPACE"/sessions/*/*.md
"$SCRIPTS/session-card.sh" >/dev/null 2>&1
"$SCRIPTS/session-wrap.sh" --auto --transcript "$TEST_DIR/full.jsonl" >/dev/null 2>&1 || true
check "archives a non-empty transcript" "$(find "$HARNESS_WORKSPACE/sessions" -name '*.jsonl.gz' | wc -l | tr -d ' ')" "1"
JOURNAL=$(find "$HARNESS_WORKSPACE/sessions" -name '*.md' | head -1)

printf 'anomalies mode\n'
# A sandboxed HOME has no settings.json, and no settings.json is itself an
# anomaly, so seed a wired guard for the quiet case.
printf '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"true"}]}]}}' \
  > "$HOME/.claude/settings.json"
QUIET=$("$SCRIPTS/session-card.sh" --anomalies 2>&1)
check "silent when nothing is wrong" "$(printf '%s' "$QUIET" | wc -c | tr -d ' ')" "0"
NOGUARD_HOME="$TEST_DIR/noguard"; mkdir -p "$NOGUARD_HOME/.claude"
printf '{"hooks":{}}' > "$NOGUARD_HOME/.claude/settings.json"
LOUD=$(HOME="$NOGUARD_HOME" "$SCRIPTS/session-card.sh" --anomalies 2>&1)
case "$LOUD" in *"No PreToolUse hook is registered"*) ok "speaks up when the guard is missing" ;; *) bad "silent on a missing guard" ;; esac
EXIT=0; "$SCRIPTS/session-card.sh" --bogus >/dev/null 2>&1 || EXIT=$?
check "rejects an unknown flag" "$EXIT" "2"
if [ -f "$JOURNAL" ]; then ok "anomalies mode still creates the journal"; else bad "anomalies mode skipped the journal"; fi

printf 'session-wrap --auto\n'
EXIT=0; "$SCRIPTS/session-wrap.sh" --auto >/dev/null 2>&1 || EXIT=$?
check "auto wrap succeeds" "$EXIT" "0"
check "journal gains a Closed block" "$(grep -c '^## Closed' "$JOURNAL")" "1"
case "$(cat "$JOURNAL")" in *"SessionEnd hook (auto)"*) ok "auto wrap records who closed it" ;; *) bad "auto wrap attribution missing" ;; esac

EXIT=0; OUT=$("$SCRIPTS/session-wrap.sh" --auto 2>&1) || EXIT=$?
check "second auto wrap is a no-op" "$EXIT" "0"
check "no duplicate Closed block" "$(grep -c '^## Closed' "$JOURNAL")" "1"

printf 'auto-close leaves a durable trace\n'
if grep -q 'auto-closed by the SessionEnd hook' "$LEDGER"; then
  ok "auto wrap writes a ledger line"
else
  bad "auto wrap left no ledger trace"
fi
BODY=$(sed -n '1,/^## Closed/p' "$JOURNAL")
case "$BODY" in
  *"auto-closed by the SessionEnd hook"*) ok "auto note sits above the Closed block" ;;
  *) bad "auto note landed below the Closed block" ;;
esac
# Count the delta, not the total: earlier blocks also append NOTE lines, so a
# cumulative assertion here breaks whenever a test is added above it.
NOTES_BEFORE=$(grep -c '| NOTE' "$LEDGER" || true)
"$SCRIPTS/session-note.sh" -l -k NOTE "forced" >/dev/null 2>&1
NOTES_AFTER=$(grep -c '| NOTE' "$LEDGER" || true)
check "-l forces a NOTE into the ledger" "$((NOTES_AFTER - NOTES_BEFORE))" "1"

printf 'git section is lock-guarded\n'
if grep -q 'session-lock.sh" acquire' "$SCRIPTS/session-wrap.sh"; then
  ok "wrap acquires the close lock"
else
  bad "wrap does not acquire the close lock"
fi
if grep -q 'trap release_lock EXIT' "$SCRIPTS/session-wrap.sh"; then
  ok "lock releases on every exit path"
else
  bad "lock has no EXIT trap"
fi
# Strip comments first: the code above the lock explains the race in prose and
# names `git add`, which a naive grep reads as a call.
BEFORE_GIT=$(sed -n '1,/session-lock.sh" acquire/p' "$SCRIPTS/session-wrap.sh" \
  | sed -e 's/#.*$//' | grep -c 'git add' || true)
check "lock is acquired before any git add" "$BEFORE_GIT" "0"
if grep -q 'set -o noclobber' "$SCRIPTS/session-note.sh"; then
  ok "ledger creation is race-free"
else
  bad "ledger creation is check-then-act"
fi

printf 'source quality\n'
for f in session-lib.sh session-card.sh session-note.sh session-wrap.sh; do
  case "$f" in
    session-lib.sh) continue ;;
  esac
  if grep -q 'set -euo pipefail' "$SCRIPTS/$f"; then ok "$f uses strict mode"; else bad "$f missing strict mode"; fi
  if grep -q 'readonly SCRIPT_DIR' "$SCRIPTS/$f"; then ok "$f has readonly SCRIPT_DIR"; else bad "$f missing readonly"; fi
done
if grep -q '>&2' "$SCRIPTS/session-lib.sh"; then ok "errors go to stderr"; else bad "errors not on stderr"; fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
