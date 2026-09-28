#!/usr/bin/env bash
# Tests for validate-hooks.sh's python half, core/scripts/validate-hooks.py.
#
# The checker exists because settings.json and the registry agree only at the
# moment the installer writes them. Every case here is one way they can come
# apart afterwards, and the assertion is that the drift is named rather than
# tolerated. A checker that reports clean on a broken install is worse than no
# checker: it converts an unknown into a false assurance.
#
# Every case runs against a fake clone and a fake settings file under mktemp.
# The real ~/.claude/settings.json is never read: --settings always points into
# the sandbox.
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

PY=$(command -v python3)
[ -n "$PY" ] || { printf 'python3 is required\n' >&2; exit 1; }

export HOME="$TEST_DIR/home"
mkdir -p "$HOME/.claude"

CLONE="$TEST_DIR/clone"
mkdir -p "$CLONE/core/hooks"
printf '#!/usr/bin/env python3\n' > "$CLONE/core/hooks/gate.py"
cat > "$CLONE/core/registry.json" <<JSON
{"version": 1, "hooks": [
  {"id": "gate", "description": "a gate", "event": "Stop", "matcher": null,
   "runner": "python3", "script": "hooks/gate.py", "timeout": 10,
   "profiles": ["standard", "strict"], "mandatory": false}
]}
JSON
# core/lib is read from the real clone; only the units under test are faked.
ln -s "$(cd "$SCRIPTS/../lib" && pwd)" "$CLONE/core/lib"

settings_with() { printf '%s\n' "$1" > "$TEST_DIR/settings.json"; }
V() { HARNESS_HOME="$CLONE" "$PY" "$SCRIPTS/validate-hooks.py" --settings "$TEST_DIR/settings.json" "$@" 2>&1; }

printf 'a settings file generated from this registry is clean\n'
settings_with "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"$PY $CLONE/core/hooks/gate.py\",\"timeout\":10}]}]}}"
EXIT=0; OUT=$(V) || EXIT=$?
check "exit 0" "$EXIT" "0"
has "it says so" "$OUT" "PASS: settings.json matches the merged registry"

printf 'a quoted command with an argument still matches\n'
settings_with "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"$PY '$CLONE/core/hooks/gate.py' start\"}]}]}}"
EXIT=0; OUT=$(V) || EXIT=$?
check "quoting is not drift" "$EXIT" "0"

printf 'a hook nobody registered is reported\n'
settings_with "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"$PY $CLONE/core/hooks/gate.py\"}]},{\"hooks\":[{\"type\":\"command\",\"command\":\"$PY $TEST_DIR/stranger.py\"}]}]}}"
EXIT=0; OUT=$(V) || EXIT=$?
check "exit 1" "$EXIT" "1"
has "the category is named" "$OUT" "wired but unregistered"
has "the stranger is named" "$OUT" "stranger.py"

printf 'a registered hook that is not wired is reported\n'
settings_with '{"hooks":{}}'
EXIT=0; OUT=$(V) || EXIT=$?
check "exit 1" "$EXIT" "1"
has "the category is named" "$OUT" "registered but unwired"
has "the hook id is named" "$OUT" "gate"
has "and the profile that selects it" "$OUT" "standard profile"

printf 'a profile that drops the hook makes the same settings clean\n'
EXIT=0; OUT=$(V --profile minimal) || EXIT=$?
check "minimal expects nothing" "$EXIT" "0"

printf 'a registry naming a script that is gone is reported\n'
mv "$CLONE/core/hooks/gate.py" "$CLONE/core/hooks/gate.py.moved"
settings_with "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"$PY $CLONE/core/hooks/gate.py\"}]}]}}"
EXIT=0; OUT=$(V) || EXIT=$?
check "a missing script is fatal to the registry read" "$EXIT" "2"
has "and it says which script" "$OUT" "missing script"
mv "$CLONE/core/hooks/gate.py.moved" "$CLONE/core/hooks/gate.py"

printf 'an interpreter this machine does not have is reported\n'
settings_with "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"/opt/nothing/here/python3 $CLONE/core/hooks/gate.py\"}]}]}}"
EXIT=0; OUT=$(V) || EXIT=$?
check "exit 1" "$EXIT" "1"
has "the category is named" "$OUT" "dead interpreter"
has "the path is named" "$OUT" "/opt/nothing/here/python3"

printf 'unreadable input is exit 2, not a false clean\n'
EXIT=0; OUT=$(HARNESS_HOME="$CLONE" "$PY" "$SCRIPTS/validate-hooks.py" --settings "$TEST_DIR/nope.json" 2>&1) || EXIT=$?
check "a missing settings file exits 2" "$EXIT" "2"
settings_with '{ not json'
EXIT=0; OUT=$(V) || EXIT=$?
check "a malformed settings file exits 2" "$EXIT" "2"
settings_with '["a list, not an object"]'
EXIT=0; OUT=$(V) || EXIT=$?
check "a settings file that is not an object exits 2" "$EXIT" "2"

printf 'it writes nothing\n'
settings_with "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"$PY $CLONE/core/hooks/gate.py\"}]}]}}"
BEFORE=$(cat "$TEST_DIR/settings.json")
V >/dev/null
check "settings.json is untouched" "$(cat "$TEST_DIR/settings.json")" "$BEFORE"
# Strip comments: the header explains the read-only property in prose.
WRITES=$(sed -e 's/#.*$//' "$SCRIPTS/validate-hooks.py" | grep -c 'write_text\|\.unlink(\|os\.replace' || true)
check "no write call anywhere in the source" "$WRITES" "0"

printf 'quiet mode prints findings only\n'
settings_with '{"hooks":{}}'
OUT=$(V --quiet) || true
lacks "no clean-run header" "$OUT" "clone:"
has "still names the finding" "$OUT" "registered but unwired"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
