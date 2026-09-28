#!/usr/bin/env bash
# Record that a change was run locally, and check whether the code at HEAD has been.
#
# The PR lifecycle went from "tests pass" straight to "open the PR", so a change
# was not actually run until stage 10, after it had merged to dev. Unit tests
# prove the code does what its author expected; running it proves the behaviour.
#
# Local means the code under test runs as a process on this machine. Its
# dependencies need not be: dev services are allowed, and a tunnel such as ngrok
# is allowed, because what is being verified is the code, not the environment.
# Running the change only on dev is not this, because on dev it has already
# merged and the point is to know before that.
#
# A verification is bound to a commit SHA, not to a branch. Verify, then push two
# more commits, and the verification no longer describes the code being shipped.
# That binding is the whole integrity property here.
#
# Data Sources:
#   - Local only: the workspace sessions/.active directory and local git
#
# Default Environment: local
# Environments Supported: local
#
# Usage: session-verify.sh record --how <text> --observed <text> [--repo <path>]
#        session-verify.sh check [--repo <path>]
#        session-verify.sh show  [--repo <path>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=session-lib.sh
. "$SCRIPT_DIR/session-lib.sh"

usage() { sed -n '/^# Usage:/,/^[^#]/{/^[^#]/!p;}' "$0" >&2; exit 2; }

verify_file() { printf '%s/verifications' "$ACTIVE_DIR"; }

# Flatten, because the store is line oriented and pipe delimited. Evidence with a
# newline in it is common and losing the record would be worse than losing the
# line breaks.
flatten() { printf '%s' "$1" | tr '\n|' '  '; }

# Resolve the repo, branch and HEAD of the change being verified.
#
# Returns non-zero rather than calling die, because every caller reads it through
# a command substitution and die inside one exits only the subshell. The first
# version did call die, and the script carried on to record an entry with an empty
# branch and commit: a silent failure that looked like a verification.
repo_state() {
  local repo="${1:-$PWD}"
  [ -d "$repo" ] || return 1
  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 2
  printf '%s|%s|%s' \
    "$(cd "$repo" && git rev-parse --show-toplevel)" \
    "$(git -C "$repo" rev-parse --abbrev-ref HEAD)" \
    "$(git -C "$repo" rev-parse HEAD)"
}

# Read repo_state in the caller, where a failure can actually stop the script.
read_repo_state() {
  local state rc=0
  state=$(repo_state "$1") || rc=$?
  case "$rc" in
    1) die "repo path does not exist: $1" ;;
    2) die "not a git repository: $1" ;;
  esac
  printf '%s' "$state"
}

cmd_record() {
  local how="" observed="" repo="$PWD"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --how) how="${2:-}"; shift 2 ;;
      --observed) observed="${2:-}"; shift 2 ;;
      --repo) repo="${2:-}"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ -n "$how" ] && [ -n "$observed" ] || usage
  require_cmd git
  local top branch sha
  local state; state=$(read_repo_state "$repo")
  IFS='|' read -r top branch sha <<< "$state"
  mkdir -p "$ACTIVE_DIR"
  printf '%s|%s|%s|%s|%s|%s\n' "$top" "$branch" "$sha" \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$(flatten "$how")" "$(flatten "$observed")" \
    >> "$(verify_file)"
  printf 'verified %s at %s\n' "$branch" "${sha:0:8}"
  printf '  ran      %s\n' "$how"
  printf '  observed %s\n' "$observed"
}

# The predicate. Exit 0 when the code at HEAD has a verification, 1 when it does
# not, so a hook or a person can use it as a test.
cmd_check() {
  local repo="$PWD"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  require_cmd git
  local top branch sha vf state
  state=$(read_repo_state "$repo")
  IFS='|' read -r top branch sha <<< "$state"
  vf=$(verify_file)
  [ -f "$vf" ] || { printf 'not verified: %s at %s has no local run recorded\n' "$branch" "${sha:0:8}"; return 1; }
  if awk -F'|' -v t="$top" -v s="$sha" '$1 == t && $3 == s { found = 1 } END { exit !found }' "$vf"; then
    awk -F'|' -v t="$top" -v s="$sha" '$1 == t && $3 == s { printf "verified %s at %s: %s\n", $2, substr($3,1,8), $5 }' "$vf" | tail -1
    return 0
  fi
  printf 'not verified: %s at %s has no local run recorded\n' "$branch" "${sha:0:8}"
  # Naming an older verification is the difference between "you never ran it" and
  # "you ran it, then changed the code", which are different mistakes.
  if awk -F'|' -v t="$top" -v b="$branch" '$1 == t && $2 == b { found = 1 } END { exit !found }' "$vf"; then
    printf '  an earlier commit on this branch was verified; the code has moved since\n'
  fi
  return 1
}

cmd_show() {
  [ "$#" -eq 0 ] || die "show takes no arguments"
  local vf; vf=$(verify_file)
  [ -f "$vf" ] && [ -s "$vf" ] || { printf 'nothing verified\n'; return 0; }
  printf '%-28s %-10s %s\n' BRANCH COMMIT RAN
  local top branch sha _ts how _obs
  while IFS='|' read -r top branch sha _ts how _obs; do
    [ -n "$branch" ] || continue
    printf '%-28s %-10s %s\n' "$branch" "${sha:0:8}" "$how"
  done < "$vf"
}

[ "$#" -ge 1 ] || usage
cmd="$1"; shift
case "$cmd" in
  record) cmd_record "$@" ;;
  check)  cmd_check "$@" ;;
  show)   cmd_show "$@" ;;
  -h|--help) usage ;;
  *) die "unknown command '$cmd'" ;;
esac
