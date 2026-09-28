#!/usr/bin/env bash
# Close a session: clean up the resources it created, finalize the journal,
# archive the raw transcript, and (unless --auto) stage, commit and push the
# files this session touched.
#
# --auto is the SessionEnd hook path. It never runs git, and its cleanup pass is
# report-only, so an unattended exit still preserves the record without an
# unreviewed commit or an unwatched removal.
#
# Data Sources:
#   - Local filesystem only: the workspace, ~/.claude/projects transcripts
#   - Remote: git origin, on push, in interactive mode only
#
# Default Environment: local
# Environments Supported: local
#
# Usage: session-wrap.sh [--auto] [--no-cleanup] [--summary TEXT]
#                        [--transcript PATH] [PATH...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=session-lib.sh
. "$SCRIPT_DIR/session-lib.sh"

auto=no
cleanup=yes
summary=''
transcript_override=''
extra_paths=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --auto) auto=yes; shift ;;
    --no-cleanup) cleanup=no; shift ;;
    --summary) [ "$#" -ge 2 ] || die "--summary needs a value"; summary="$2"; shift 2 ;;
    --transcript) [ "$#" -ge 2 ] || die "--transcript needs a path"; transcript_override="$2"; shift 2 ;;
    -h|--help) sed -n '/^# Usage:/,/^[^#]/{/^[^#]/!p;}' "$0" >&2; exit 0 ;;
    --) shift; break ;;
    -*) die "unknown option $1" ;;
    *) extra_paths+=("$1"); shift ;;
  esac
done
[ "$#" -eq 0 ] || extra_paths+=("$@")

require_cmd git gzip

LOCK_HELD=no
release_lock() {
  if [ "$LOCK_HELD" = yes ]; then
    "$SCRIPT_DIR/session-lock.sh" release >/dev/null 2>&1 || true
    LOCK_HELD=no
  fi
}
trap release_lock EXIT

eval "$(session_state)"

[ -f "$SESSION_JOURNAL" ] || die "no journal for session $SESSION_ID"

if grep -q '^## Closed' "$SESSION_JOURNAL" 2>/dev/null; then
  if [ "$auto" = yes ]; then
    printf 'already wrapped: %s\n' "$SESSION_ID"
    exit 0
  fi
  printf 'note: journal already has a Closed block; appending a second one\n' >&2
fi

transcript="${transcript_override:-$SESSION_TRANSCRIPT}"
[ -n "$transcript" ] || transcript=$(herdr_transcript "$PWD")
[ -n "$transcript" ] || transcript=$(newest_transcript "$PWD")

# -s not -f: a session that did nothing leaves a 0-byte transcript, and archiving
# that is noise. Note also that newest_transcript is a heuristic; the SessionEnd
# hook passes the real path via --transcript and should be trusted over it.
archive=''
if [ -n "$transcript" ] && [ -s "$transcript" ]; then
  archive="$(dirname "$SESSION_JOURNAL")/$SESSION_ID.jsonl.gz"
  if [ ! -f "$archive" ]; then
    gzip -c "$transcript" > "$archive"
  fi
fi

# Cleanup runs before the Closed block so its carry-over notes land in the session
# body rather than under the footer, and before git so a worktree it removed is
# already gone when the commit is written.
#
# It is report-only under --auto. Nobody is watching an unattended exit, the hook
# that calls it has a 30 second budget, and closing a pane or removing a checkout
# is not something to do unobserved.
cleanup_report=''
if [ "$cleanup" = yes ]; then
  cleanup_args=(--record)
  [ "$auto" = yes ] || cleanup_args+=(--apply)
  cleanup_report=$("$SCRIPT_DIR/session-cleanup.sh" "${cleanup_args[@]}" 2>&1) \
    || cleanup_report="- cleanup failed: $cleanup_report"
fi

# An auto-close must leave a durable, greppable trace. NOTE is excluded from the
# ledger by default, so force it here, and write it before the Closed block so it
# lands in the session body rather than under the footer.
if [ "$auto" = yes ] && [ -n "$SESSION_PROJECT" ]; then
  "$SCRIPT_DIR/session-note.sh" -l -k NOTE \
    "session auto-closed by the SessionEnd hook without an agent summary" >/dev/null || true
fi

{
  printf '\n## Closed\n\n'
  printf -- '- ended: %s\n' "$(date '+%Y-%m-%d %H:%M %Z')"
  printf -- '- closed by: %s\n' "$( [ "$auto" = yes ] && printf 'SessionEnd hook (auto)' || printf 'agent' )"
  printf -- '- transcript: %s\n' "${transcript:-unknown}"
  printf -- '- archive: %s\n' "${archive:-none (transcript empty or missing)}"
  if [ -n "$summary" ]; then
    printf '\n### Summary\n\n%s\n' "$summary"
  fi
  if [ -n "$cleanup_report" ]; then
    printf '\n### Cleanup and carry-over\n\n%s\n' "$cleanup_report"
  fi
} >> "$SESSION_JOURNAL"

if [ "$auto" = yes ]; then
  rm -f "$(state_file)"
  printf 'auto-wrapped %s (no git)\n' "$SESSION_ID"
  exit 0
fi

# The git index is shared repo state, so a scoped `git add` does NOT stop another
# session's staged files from being swept into this commit. Verified: stage a.txt
# in one session and b.txt in another, and the first commit carries both. Hold the
# lock across stage, commit and push only, which is sub-second.
#
# The workspace is a plain directory by default. Version control is opt-in: it
# becomes a git repository when someone runs `git init` in it, and only then is
# there anything to commit. A workspace that is not a repository is finished at
# this point, and saying so is not a failure.
if ! git -C "$WORKSPACE" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  rm -f "$(state_file)"
  printf 'wrapped %s (workspace is not a git repository, nothing committed)\n' "$SESSION_ID"
  exit 0
fi

if ! "$SCRIPT_DIR/session-lock.sh" acquire; then
  die "could not acquire the close lock; run 'session-lock.sh status' to see who holds it"
fi
LOCK_HELD=yes

cd "$WORKSPACE"
stage=("$SESSION_JOURNAL")
[ -n "$archive" ] && stage+=("$archive")
if [ -n "$SESSION_PROJECT" ]; then
  for f in LEDGER.md OPEN.md; do
    p=$(project_file "$SESSION_PROJECT" "$f")
    [ -f "$p" ] && stage+=("$p")
  done
fi
[ "${#extra_paths[@]}" -gt 0 ] && stage+=("${extra_paths[@]}")

git add -- "${stage[@]}"

if git diff --cached --quiet; then
  printf 'nothing to commit\n'
else
  git commit -q -m "session: $SESSION_ID -- ${summary:-close}"
fi

# Push only when there is somewhere to push. A workspace with no remote is the
# normal case, and treating that as a failure would make every close look broken.
if ! git remote get-url origin >/dev/null 2>&1; then
  release_lock
  rm -f "$(state_file)"
  printf 'wrapped %s (committed; no origin remote, nothing pushed)\n' "$SESSION_ID"
  exit 0
fi

pushed=no
for attempt in 1 2 3 4 5; do
  if git pull --rebase --autostash -q; then
    if git push -q; then pushed=yes; break; fi
  else
    printf 'ERROR: rebase failed, likely a real conflict. Aborting rebase.\n' >&2
    git rebase --abort 2>/dev/null || true
    printf 'Local commits are intact. Resolve manually in %s\n' "$WORKSPACE" >&2
    exit 1
  fi
  printf 'push attempt %s failed, retrying\n' "$attempt" >&2
  sleep $(( (RANDOM % 5) + 2 ))
done

[ "$pushed" = yes ] || die "push failed after 5 attempts; the commit is safe locally"

release_lock
rm -f "$(state_file)"
printf 'wrapped %s\n' "$SESSION_ID"
