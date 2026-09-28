#!/usr/bin/env bash
# Tests for harness-drift.sh.
#
# The property that matters is what counts as owned. A file adopted into the
# clone and linked back is owned; a real file someone dropped into ~/.claude is
# not, and it is invisible on every other machine. Getting that backwards in
# either direction makes the report worthless: a false positive trains people to
# ignore it, and a false negative is the silence the script exists to break.
#
# Everything runs against a fake clone and a fake HOME under mktemp.
set -uo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
readonly SCRIPTS
TEST_DIR=$(mktemp -d)
readonly TEST_DIR
trap 'rm -rf "$TEST_DIR"' EXIT

PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (missing '$3')" ;; esac; }
lacks(){ case "$2" in *"$3"*) bad "$1 (found '$3')" ;; *) ok "$1" ;; esac; }

export HARNESS_HOME="$TEST_DIR/clone"
export HOME="$TEST_DIR/home"
mkdir -p "$HARNESS_HOME/core/skills/example" "$HARNESS_HOME/core/agents"
mkdir -p "$HOME/.claude/skills" "$HOME/.claude/agents" "$HOME/.claude/commands"
printf '# a skill\n' > "$HARNESS_HOME/core/skills/example/SKILL.md"
printf '# an agent\n' > "$HARNESS_HOME/core/agents/reviewer.md"

D() { "$SCRIPTS/harness-drift.sh" "$@" 2>&1; }

printf 'an empty managed tree is clean\n'
EXIT=0; OUT=$(D) || EXIT=$?
check "exit 0" "$EXIT" "0"
has "it says so" "$OUT" "no drift"

printf 'a link into the clone is owned\n'
ln -s "$HARNESS_HOME/core/skills/example" "$HOME/.claude/skills/example"
EXIT=0; OUT=$(D) || EXIT=$?
check "still clean" "$EXIT" "0"
lacks "the owned link is not reported" "$OUT" "skills/example"

printf 'a link through a second link is still owned\n'
ln -s "$HARNESS_HOME/core/agents/reviewer.md" "$TEST_DIR/hop.md"
ln -s "$TEST_DIR/hop.md" "$HOME/.claude/agents/reviewer.md"
EXIT=0; OUT=$(D) || EXIT=$?
check "a two-hop chain resolves to the clone" "$EXIT" "0"
lacks "and is not reported" "$OUT" "agents/reviewer.md"

printf 'a real file is drift\n'
printf 'local only\n' > "$HOME/.claude/commands/mine.md"
EXIT=0; OUT=$(D) || EXIT=$?
check "exit 1" "$EXIT" "1"
has "it names the file" "$OUT" "commands/mine.md"
has "it counts one" "$OUT" "1 entry(ies)"
has "it says what to do" "$OUT" "install.sh --write"

printf 'a link somewhere else is drift too\n'
printf 'elsewhere\n' > "$TEST_DIR/stray.md"
ln -s "$TEST_DIR/stray.md" "$HOME/.claude/agents/stray.md"
OUT=$(D) || true
has "the foreign link is reported" "$OUT" "agents/stray.md"

printf 'noise is filtered, not reported\n'
: > "$HOME/.claude/skills/.DS_Store"
: > "$HOME/.claude/settings.local.json"
: > "$HOME/.claude/skills/old.md.harness-bak-20260101-000000"
mkdir -p "$HOME/.claude/skills/__pycache__"
OUT=$(D) || true
lacks "a .DS_Store is ignored" "$OUT" ".DS_Store"
lacks "a harness backup is ignored" "$OUT" "harness-bak"
lacks "a pycache is ignored" "$OUT" "__pycache__"

printf 'quiet mode prints nothing and still reports through its exit code\n'
EXIT=0; OUT=$(D --quiet) || EXIT=$?
check "exit still 1 with drift present" "$EXIT" "1"
check "no output" "$(printf '%s' "$OUT" | wc -c | tr -d ' ')" "0"

printf 'usage\n'
EXIT=0; OUT=$(D --bogus) || EXIT=$?
check "an unknown flag exits 2" "$EXIT" "2"

printf 'an unmanaged directory is not inspected\n'
mkdir -p "$HOME/.claude/projects"
printf 'runtime state\n' > "$HOME/.claude/projects/state.json"
OUT=$(D) || true
lacks "Claude Code's own state is left alone" "$OUT" "projects/state.json"

printf 'source quality\n'
if grep -q 'set -euo pipefail' "$SCRIPTS/harness-drift.sh"; then ok "strict mode"; else bad "no strict mode"; fi
# Comments are stripped first: the resolver's own comment explains why
# `readlink -f` is avoided, and a naive grep reads that prose as a call.
if sed -e 's/#.*$//' "$SCRIPTS/harness-drift.sh" | grep -q 'readlink -f'; then
  bad "uses readlink -f, which older BSD userlands do not have"
else
  ok "resolves links portably"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
