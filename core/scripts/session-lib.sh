#!/usr/bin/env bash
# Shared helpers for the session lifecycle scripts (card, note, wrap, lane).
# Sourced, never executed directly.
#
# Everything this writes lands under HARNESS_WORKSPACE, resolved through
# core/lib/harness_config.py. Nothing here knows the name of a notes repository,
# a project tracker or an employer: a session record is a harness artefact, and a
# layer that wants those records somewhere else sets the one key.
#
# Data Sources:
#   - Local filesystem only: the workspace and ~/.claude/projects transcripts
#
# Default Environment: local (no network, no remote services)
# Environments Supported: local

# shellcheck source=../lib/harness-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness-config.sh"

WORKSPACE="$(harness_config HARNESS_WORKSPACE)"
[ -n "$WORKSPACE" ] || WORKSPACE="$HOME/.swe-harness"
SESSIONS_DIR="$WORKSPACE/sessions"
ACTIVE_DIR="$SESSIONS_DIR/.active"
# shellcheck disable=SC2034  # consumed by session-note.sh after sourcing
LEDGER_KINDS="DECISION DONE BLOCKED FRICTION NOTE"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done
}

# Sanitize a pane ID (w4:p1) into a filename-safe token (w4p1).
pane_token() {
  local raw="${HERDR_PANE_ID:-}"
  if [ -z "$raw" ]; then
    # Outside a multiplexer, derive a stable token from the working directory so
    # that a SessionStart and its SessionEnd resolve to the same session, which a
    # PID would not.
    printf 'nopane%s' "$(printf '%s' "$PWD" | cksum | cut -d' ' -f1)"
    return 0
  fi
  printf '%s' "$raw" | tr -cd 'a-zA-Z0-9'
}

# Name the project a working directory belongs to. Empty output means none.
#
# The repository is the unit, because that is the boundary every checkout already
# agrees on and it needs no list to maintain. A directory outside a repository has
# no project, and its notes stay in the journal.
detect_project() {
  local cwd="${1:-$PWD}" top
  top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || return 0
  [ -n "$top" ] || return 0
  printf '%s' "$(basename "$top")"
}

# Locate the Claude Code transcript directory for a working directory.
transcript_dir_for() {
  local cwd="${1:-$PWD}" slug
  slug=$(printf '%s' "$cwd" | sed 's/[^a-zA-Z0-9]/-/g')
  printf '%s/.claude/projects/%s' "$HOME" "$slug"
}

# Transcript for THIS pane, resolved from the multiplexer instead of guessed.
#
# Herdr knows the agent session id occupying a pane, and Claude Code names the
# transcript after that id. Without this, several panes sharing one cwd all
# resolve to whichever transcript was written last, and one session archives
# another pane's transcript as its own evidence.
#
# Empty when the multiplexer, jq or the file is missing, so callers keep their
# fallback. An absent optional binary is never an error.
herdr_transcript() {
  local bin="${HERDR_BIN_PATH:-}" id path
  [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_PANE_ID:-}" ] || return 0
  [ -n "$bin" ] && [ -x "$bin" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  id=$("$bin" pane get "$HERDR_PANE_ID" 2>/dev/null \
    | jq -r '.result.pane.agent_session.value // .result.agent_session.value // empty' 2>/dev/null)
  [ -n "$id" ] || return 0
  path="$(transcript_dir_for "${1:-$PWD}")/$id.jsonl"
  [ -f "$path" ] && printf '%s' "$path"
}

# Seconds since the epoch of a file's last modification. Empty and non-zero when
# it cannot be read.
#
# GNU first, BSD second, and each reading captured on its own. The obvious
# `stat -f %m "$f" || stat -c %Y "$f"` reads as portable and is not: to GNU stat
# `-f` means --file-system, so it prints a filesystem report on stdout and then
# exits non-zero. The `||` fires, the second reading is appended to the first,
# and the caller ends up doing arithmetic on a paragraph of text. On Linux that
# killed the batch record lock, the lane lock and the staleness report, all with
# a syntax error nobody saw because the writes ran in the background.
file_mtime() {
  local out
  out=$(stat -c %Y "$1" 2>/dev/null) || out=$(stat -f %m "$1" 2>/dev/null) || return 1
  case "$out" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$out"
}

# Newest transcript file for a working directory, or empty. A heuristic: prefer
# herdr_transcript, and fall back here only when the multiplexer cannot answer.
newest_transcript() {
  local dir
  dir=$(transcript_dir_for "${1:-$PWD}")
  [ -d "$dir" ] || return 0
  # GNU first, then BSD, and the second reading replaces the first rather than
  # being appended to it. See file_mtime: a failing `stat -f` on GNU still
  # writes a filesystem report to stdout, and brace-grouping both attempts fed
  # that report into the sort alongside the real timestamps.
  local listing
  listing=$(find "$dir" -name '*.jsonl' -type f -exec stat -c '%Y %n' {} + 2>/dev/null) \
    || listing=$(find "$dir" -name '*.jsonl' -type f -exec stat -f '%m %N' {} + 2>/dev/null) \
    || return 0
  printf '%s\n' "$listing" | sort -rn | head -1 | cut -d' ' -f2-
}

# Path of the state file that pins this pane's session identity.
state_file() { printf '%s/%s.env' "$ACTIVE_DIR" "$(pane_token)"; }

# Create the session state if absent, then emit it as shell assignments.
# Fields: SESSION_ID, SESSION_PROJECT, SESSION_JOURNAL, SESSION_TRANSCRIPT
#
# SESSION_PROJECT is resolved fresh on every call and is deliberately NOT stored.
# A session that opens outside a repository and moves into one later must pick
# that project up; pinning it at start makes a mid-session pivot write to a
# project the session never claimed.
session_state() {
  local sf project sid day journal transcript
  sf=$(state_file)
  if [ -f "$sf" ]; then
    cat "$sf"
    printf 'SESSION_PROJECT=%q\n' "$(detect_project "$PWD")"
    return 0
  fi
  mkdir -p "$ACTIVE_DIR"
  project=$(detect_project "$PWD")
  day=$(date +%Y-%m-%d)
  sid="$(date +%Y-%m-%dT%H%M)-$(pane_token)"
  journal="$SESSIONS_DIR/$day/$sid.md"
  transcript=$(herdr_transcript "$PWD")
  [ -n "$transcript" ] || transcript=$(newest_transcript "$PWD")
  mkdir -p "$SESSIONS_DIR/$day"
  if [ ! -f "$journal" ]; then
    {
      printf '# Session %s\n\n' "$sid"
      printf -- '- started: %s\n' "$(date '+%Y-%m-%d %H:%M %Z')"
      printf -- '- cwd: %s\n' "$PWD"
      printf -- '- project: %s\n' "${project:-none}"
      printf -- '- pane: %s\n' "${HERDR_PANE_ID:-none}"
      printf -- '- transcript: %s\n\n' "${transcript:-unknown}"
      printf -- '---\n\n'
    } > "$journal"
  fi
  {
    printf 'SESSION_ID=%q\n' "$sid"
    printf 'SESSION_JOURNAL=%q\n' "$journal"
    printf 'SESSION_TRANSCRIPT=%q\n' "$transcript"
  } > "$sf"
  cat "$sf"
  printf 'SESSION_PROJECT=%q\n' "$project"
}

# Path of a per-project file inside the workspace. The workspace holds these, not
# the checkout: a ledger written into a repository is a file every branch and
# every worktree disagrees about.
project_file() {
  local project="$1" name="$2"
  [ -n "$project" ] || return 1
  printf '%s/projects/%s/%s' "$WORKSPACE" "$project" "$name"
}

# Path of the file that records the disposable resources this session created:
# child agent panes, tabs, workspaces and worktrees. One line per resource,
# `kind|value|created`. Written by session-artifact.sh, read by
# session-cleanup.sh, deleted by session-wrap.sh once the close is done.
#
# It is keyed by pane token like the state file, so a resource registered by one
# pane is never removed by another.
artifact_file() { printf '%s/%s.artifacts' "$ACTIVE_DIR" "$(pane_token)"; }
