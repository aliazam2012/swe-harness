#!/usr/bin/env bash
# Run every test in the harness and say what happened, one line per file.
#
# That is this directory plus a tests/ directory at the root of any installed
# layer. A layer hook is not core's to test, but nothing runs a test the one
# runner cannot find, and an unrun test is not a test. No layer is named here:
# the glob is the whole rule.
#
# Needs bash 3.2 and python 3.9, which is what macOS ships. No pytest, no
# package install, no network. A harness whose own test suite needs a toolchain
# installed first cannot be the thing that proves a fresh clone works.
#
# Every test runs in its own process with its own temporary HOME, so a test
# cannot read or write the real one. That is enforced here rather than trusted
# to each file: a suite that relies on every author remembering to sandbox will
# eventually meet an author who did not.
#
# Outcomes are kept apart on purpose. A file that exits 0 having asserted
# nothing is not a pass, it is a file that ran no tests, and calling it green is
# how a suite rots without anyone noticing.
#
#   pass     exited 0 and reported at least one passing assertion
#   fail     reported at least one failing assertion
#   crash    exited non-zero while reporting no failing assertion
#   silent   exited 0 and reported no assertion at all
#   timeout  killed after --limit seconds
#
# Usage:
#   core/tests/run.sh [--only PATTERN] [--limit SECONDS] [--list] [--verbose]
#
#   --only PATTERN   run only files whose name contains PATTERN
#   --limit SECONDS  per-file wall-clock limit (default 300)
#   --list           print what would run, run nothing
#   --verbose        print each file's own output as well as the summary line
#
# Exit: 0 every file passed, 1 anything else, 2 a usage error.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly HERE
HARNESS_HOME="$(cd "$HERE/../.." && pwd -P)"
export HARNESS_HOME
readonly DEFAULT_LIMIT=300

ONLY=""
LIMIT="$DEFAULT_LIMIT"
WANT_LIST=0
VERBOSE=0

die() { printf 'run.sh: %s\n' "$1" >&2; exit "${2:-1}"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --only)
      [ "$#" -ge 2 ] || die "--only needs a pattern" 2
      ONLY="$2"; shift 2 ;;
    --limit)
      [ "$#" -ge 2 ] || die "--limit needs a number of seconds" 2
      LIMIT="$2"; shift 2
      case "$LIMIT" in ''|*[!0-9]*) die "--limit must be a positive integer" 2 ;; esac
      [ "$LIMIT" -gt 0 ] || die "--limit must be greater than zero" 2 ;;
    --list)    WANT_LIST=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (try --help)" 2 ;;
  esac
done

# The floor is python 3.9. A machine without one cannot run the harness at all,
# so this is a hard stop rather than a skip.
PYTHON=""
for candidate in python3 /usr/bin/python3; do
  if command -v "$candidate" >/dev/null 2>&1 &&
     "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then
    PYTHON="$(command -v "$candidate")"
    break
  fi
done
[ -n "$PYTHON" ] || die "needs python 3.9 or newer; none found"
export HARNESS_PYTHON="$PYTHON"

WORK="$(mktemp -d)"
cleanup() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; return 0; }
trap cleanup EXIT INT TERM

# Both spellings, because a repository accumulates both and a discovery rule
# that quietly matches one of them is how a suite loses half its files.
discover() {
  local dir
  for dir in "$HERE" "$HARNESS_HOME"/layers/*/tests; do
    [ -d "$dir" ] || continue
    find "$dir" -maxdepth 1 -type f \
         \( -name 'test_*.sh' -o -name 'test_*.py' -o -name 'test-*.sh' -o -name 'test-*.py' \)
  done | LC_ALL=C sort
}

# What to call a file in the report and in its own scratch paths. Two directories
# may ship the same basename, so a layer's file carries its layer.
label_of() {
  case "$1" in
    "$HERE"/*) basename "$1" ;;
    *) printf '%s/%s' "$(basename "$(dirname "$(dirname "$1")")")" "$(basename "$1")" ;;
  esac
}

FILES=()
while IFS= read -r file; do
  [ -n "$file" ] || continue
  base="$(basename "$file")"
  if [ -n "$ONLY" ]; then
    case "$base" in *"$ONLY"*) ;; *) continue ;; esac
  fi
  FILES+=("$file")
done < <(discover)

if [ "${#FILES[@]}" -eq 0 ]; then
  printf 'no test files found in %s%s\n' "$HERE" "$( [ -n "$ONLY" ] && printf ' matching %s' "$ONLY" )"
  exit 1
fi

if [ "$WANT_LIST" -eq 1 ]; then
  for file in "${FILES[@]}"; do printf '%s\n' "$(label_of "$file")"; done
  exit 0
fi

# Run one file to completion or to the limit, and return its exit status.
#
# `timeout` is a GNU coreutils program that macOS does not ship, so this is a
# polling watchdog: TERM first so the test can clean up its own temp directory,
# KILL after a grace period if it did not.
run_one() {
  local file="$1" out="$2" sandbox="$3" pid waited=0 status=0
  (
    # export, not a command prefix. `VAR=x cd dir` scopes the assignment to the
    # `cd` alone, and `cd` is a regular builtin, so the values were discarded the
    # moment it returned and every test ran against the developer's real HOME.
    # That is how a test reading ~/.claude passed here and failed on a runner.
    export HOME="$sandbox"
    export HARNESS_WORKSPACE="$sandbox/.swe-harness"
    export TMPDIR="$sandbox/tmp"
    cd "$HERE" || exit 1
    case "$file" in
      *.py) exec "$PYTHON" "$file" ;;
      *)    exec bash "$file" ;;
    esac
  ) >"$out" 2>&1 </dev/null &
  pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$LIMIT" ]; then
      kill -TERM "$pid" 2>/dev/null
      sleep 2
      kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
  status=$?
  return "$status"
}

# A file reports its own counts. Read them rather than inventing a protocol the
# tests would have to be rewritten to speak.
count_of() { # output, word
  # grep -o, not sed: a greedy `.*` before the capture eats all but the last
  # digit, so "28 passed" was read as 8 and every count above nine was wrong.
  printf '%s' "$1" | grep -o "[0-9][0-9]* $2" | tail -1 | cut -d' ' -f1
}

passed=0; failed=0; crashed=0; silent=0; timedout=0
started="$(date +%s)"

index=0
for file in "${FILES[@]}"; do
  base="$(label_of "$file")"
  index=$((index + 1))
  out="$WORK/$index.out"
  sandbox="$WORK/home-$index"
  mkdir -p "$sandbox/.claude" "$sandbox/tmp"

  status=0
  run_one "$file" "$out" "$sandbox" || status=$?
  output="$(cat "$out" 2>/dev/null)"

  ok_count="$(count_of "$output" passed)"
  bad_count="$(count_of "$output" failed)"
  # A file that prints "PASS:" or "ok" with no counts still asserted something.
  if [ -z "$ok_count" ] && [ -z "$bad_count" ]; then
    case "$output" in
      *PASS:*|*"ok  "*|*" ok "*) ok_count=1 ;;
    esac
    case "$output" in
      *FAIL:*|*"FAIL "*) bad_count=1 ;;
    esac
  fi
  : "${ok_count:=0}" "${bad_count:=0}"

  if [ "$status" -eq 124 ]; then
    verdict="timeout"; timedout=$((timedout + 1))
  elif [ "$bad_count" -gt 0 ]; then
    verdict="fail"; failed=$((failed + 1))
  elif [ "$status" -ne 0 ]; then
    verdict="crash"; crashed=$((crashed + 1))
  elif [ "$ok_count" -eq 0 ]; then
    verdict="silent"; silent=$((silent + 1))
  else
    verdict="pass"; passed=$((passed + 1))
  fi

  printf '%-8s %-38s %s\n' "$verdict" "$base" \
    "$( [ "$ok_count" -gt 0 ] || [ "$bad_count" -gt 0 ] \
        && printf '%s passed, %s failed' "$ok_count" "$bad_count" \
        || printf 'exit %s' "$status" )"

  if [ "$VERBOSE" -eq 1 ] || [ "$verdict" != pass ]; then
    printf '%s\n' "$output" | sed 's/^/    /'
  fi
done

elapsed=$(( $(date +%s) - started ))
printf -- '----\n'
printf '%d file(s) in %ds: %d pass, %d fail, %d crash, %d silent, %d timeout\n' \
  "${#FILES[@]}" "$elapsed" "$passed" "$failed" "$crashed" "$silent" "$timedout"

[ $((failed + crashed + silent + timedout)) -eq 0 ] || exit 1
exit 0
