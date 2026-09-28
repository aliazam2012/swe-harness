#!/usr/bin/env bash
# Tests for gate-settle-report.py.
#
# Every run is pointed at a fixture log under mktemp with --log, so the real
# ~/.claude/gate-settle.jsonl is never read and the report can be asserted
# against known numbers.
set -uo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
readonly SCRIPTS
REPORT="$SCRIPTS/gate-settle-report.py"
readonly REPORT
TEST_DIR=$(mktemp -d)
readonly TEST_DIR
trap 'rm -rf "$TEST_DIR"' EXIT

PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (missing '$3')" ;; esac; }

row() { # verdict elapsed_ms polls footer_at_poll tail_bytes
  printf '{"ts":"2026-09-17T00:00:00.000+00:00","session_id":"s","prompt_uuid":"u","verdict":"%s","elapsed_ms":%s,"polls":%s,"footer_at_poll":%s,"tail_bytes":%s}\n' \
    "$1" "$2" "$3" "$4" "$5"
}

jq_field() { # json, python expression over `d`
  printf '%s' "$1" | python3 -c "import json,sys; d=json.load(sys.stdin); print($2)"
}

# ------------------------------------------------------------------ fixtures

LOG="$TEST_DIR/gate-settle.jsonl"
{
  row pass_first_read 0 1 null 4000
  row pass_first_read 1 1 null 6000
  row pass_no_tool 0 1 null 2000
  row pass_settled 150 2 2 5000
  row pass_settled 450 4 4 5000
  row block 3010 21 null 7000
  printf 'not json at all\n'
  printf '{"broken":\n'
} > "$LOG"

# ------------------------------------------------------------------- counts

printf 'counts and percentages\n'
OUT=$(python3 "$REPORT" --log "$LOG" 2>&1); EXIT=$?
check "exits 0" "$EXIT" "0"
has "it names the row count, malformed lines dropped" "$OUT" "(6 rows"
has "it reports every verdict" "$OUT" "pass_first_read"
has "and the blocking one" "$OUT" "block"

JSON=$(python3 "$REPORT" --log "$LOG" --json 2>&1); EXIT=$?
check "--json exits 0" "$EXIT" "0"
check "--json is parseable" "$(jq_field "$JSON" "'yes'")" "yes"
check "it counted the rows" "$(jq_field "$JSON" "d['log_rows']")" "6"
check "pass_first_read counted" "$(jq_field "$JSON" "d['by_verdict']['pass_first_read']['count']")" "2"
check "pass_first_read percentage" "$(jq_field "$JSON" "d['by_verdict']['pass_first_read']['pct']")" "33.3"
check "pass_settled counted" "$(jq_field "$JSON" "d['by_verdict']['pass_settled']['count']")" "2"
check "block counted" "$(jq_field "$JSON" "d['by_verdict']['block']['count']")" "1"
check "no row fell outside the known verdicts" "$(jq_field "$JSON" "d['unknown_verdict']")" "0"

# ------------------------------------------------------- elapsed by verdict

printf 'elapsed_ms by verdict\n'
check "the block branch reports its own elapsed" \
  "$(jq_field "$JSON" "int(d['by_verdict']['block']['elapsed_ms']['max'])")" "3010"
check "the settled branch is separated from it" \
  "$(jq_field "$JSON" "int(d['by_verdict']['pass_settled']['elapsed_ms']['max'])")" "450"
check "the no-tool branch reports its own row count" \
  "$(jq_field "$JSON" "d['by_verdict']['pass_no_tool']['elapsed_ms']['n']")" "1"
check "a verdict with no rows reports n=0" \
  "$(jq_field "$JSON" "d['by_verdict'].get('nothing_here', {'elapsed_ms': {'n': 0}})['elapsed_ms']['n']")" "0"

# ------------------------------------------------ the number that matters

printf 'the footer_at_poll distribution\n'
check "only the rows where the footer arrived late are counted" \
  "$(jq_field "$JSON" "d['footer_arrived_late']['count']")" "2"
check "the latest arrival is reported" \
  "$(jq_field "$JSON" "int(d['footer_arrived_late']['poll_index']['max'])")" "4"
check "and translated into milliseconds" \
  "$(jq_field "$JSON" "int(d['footer_arrived_late']['implied_ms']['max'])")" "600"
has "the table says what the deadline must cover" "$OUT" "The deadline needs to cover"

# --------------------------------------------------------------- edge cases

printf 'edge cases\n'
: > "$TEST_DIR/empty.jsonl"
OUT=$(python3 "$REPORT" --log "$TEST_DIR/empty.jsonl" 2>&1); EXIT=$?
check "an empty log exits 0" "$EXIT" "0"
has "and says there is nothing yet" "$OUT" "no rows yet"

OUT=$(python3 "$REPORT" --log "$TEST_DIR/nosuch.jsonl" 2>&1); EXIT=$?
check "a missing log exits 0" "$EXIT" "0"
has "and says there is nothing yet" "$OUT" "no rows yet"

JSON=$(python3 "$REPORT" --log "$TEST_DIR/nosuch.jsonl" --json 2>&1)
check "a missing log still emits valid JSON" "$(jq_field "$JSON" "d['log_rows']")" "0"

printf '{"verdict":"something_else","elapsed_ms":5}\n' > "$TEST_DIR/odd.jsonl"
JSON=$(python3 "$REPORT" --log "$TEST_DIR/odd.jsonl" --json 2>&1)
check "an unknown verdict is counted apart, not dropped" \
  "$(jq_field "$JSON" "d['unknown_verdict']")" "1"

# ------------------------------------------------------------ source quality

printf 'source quality\n'
SRC=$(cat "$REPORT")
has "it documents its data source" "$SRC" "Data Sources:"
has "it reads no network or database" "$SRC" "No database, no network"
has "it defaults to the harness log, not the brain" "$SRC" '.claude/gate-settle.jsonl'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
