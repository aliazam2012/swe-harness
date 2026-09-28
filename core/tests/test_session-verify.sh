#!/usr/bin/env bash
# Tests for session-verify.sh and the PR gate that reads it.
#
# The property that matters is the commit binding. A verification that survived a
# further push would describe code that is not being shipped, which is worse than
# no verification because it reads like assurance.
#
# The PreToolUse gate that reads this checker is a layer hook, so its tests live
# with it, in layers/<name>/tests. They used to live here and reached the hook
# through "$HOME/.claude/hooks": a path that resolves only on a machine where
# that layer is already installed, which is why this file passed for its author
# and failed on a clean checkout.
set -uo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
readonly SCRIPTS
TEST_DIR=$(mktemp -d)
readonly TEST_DIR
trap 'rm -rf "$TEST_DIR"' EXIT
export HARNESS_WORKSPACE="$TEST_DIR/workspace"
export HERDR_PANE_ID="wV:p1"
mkdir -p "$HARNESS_WORKSPACE"

PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (missing '$3')" ;; esac; }

REPO="$TEST_DIR/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t.t; git -C "$REPO" config user.name t
printf 'x\n' > "$REPO/f"; git -C "$REPO" add f; git -C "$REPO" commit -qm one
V() { "$SCRIPTS/session-verify.sh" "$@"; }

printf 'validation\n'
EXIT=0; OUT=$(V record --repo "$REPO" --how "ran it" 2>&1) || EXIT=$?
check "recording without what was observed is refused" "$EXIT" "2"
EXIT=0; OUT=$(V record --repo "$TEST_DIR" --how a --observed b 2>&1) || EXIT=$?
check "a non-repository is refused" "$EXIT" "1"

printf 'the commit binding\n'
EXIT=0; OUT=$(V check --repo "$REPO" 2>&1) || EXIT=$?
check "an unverified commit fails" "$EXIT" "1"
has "and says so plainly" "$OUT" "no local run recorded"
V record --repo "$REPO" --how "ran the service on localhost:8081 against dev postgres" \
         --observed "required-items came back 3 on the seed fixture" >/dev/null
EXIT=0; OUT=$(V check --repo "$REPO" 2>&1) || EXIT=$?
check "the verified commit passes" "$EXIT" "0"
has "and echoes what was run" "$OUT" "localhost:8081"

printf 'more\n' >> "$REPO/f"; git -C "$REPO" add f; git -C "$REPO" commit -qm two
EXIT=0; OUT=$(V check --repo "$REPO" 2>&1) || EXIT=$?
check "a further commit invalidates it" "$EXIT" "1"
has "and distinguishes stale from never" "$OUT" "the code has moved since"

printf 'evidence with a newline does not corrupt the store\n'
V record --repo "$REPO" --how "ran it
across two lines" --observed "saw|a pipe too" >/dev/null
check "the store stays one record per line" \
  "$(awk -F'|' 'NF!=6' "$HARNESS_WORKSPACE/sessions/.active/verifications" | wc -l | tr -d ' ')" "0"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
