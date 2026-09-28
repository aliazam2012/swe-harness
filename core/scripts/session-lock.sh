#!/usr/bin/env bash
set -euo pipefail

# Close lock for the harness workspace.
#
# Two sessions closing at the same instant write the same shared files (journals,
# ledgers) and run git in the same checkout. The git index is shared state, so a
# scoped `git add` in one session still sweeps the other's staged files into its
# commit. This serializes the close.
#
# Uses mkdir as an atomic lock primitive, which every POSIX filesystem provides.
# Waiters poll with jitter and cascade automatically when the holder releases.
#
# Usage:
#   session-lock.sh acquire [--force]   # blocks until lock is acquired
#   session-lock.sh release             # releases the lock
#   session-lock.sh status              # prints lock state (exit 0=free, 1=held)
#
# --force on acquire: removes any existing lock before attempting,
# regardless of age. Use when the previous holder is known to have crashed.
# All rm operations are internal to this script so agents never need
# blanket rm permission.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/harness-config.sh
. "$SCRIPT_DIR/../lib/harness-config.sh"

WORKSPACE="$(harness_config HARNESS_WORKSPACE)"
[ -n "$WORKSPACE" ] || WORKSPACE="$HOME/.swe-harness"
mkdir -p "$WORKSPACE"
LOCKDIR="$WORKSPACE/.session-close.lock"
MAX_WAIT_SECONDS="${SESSION_LOCK_MAX_WAIT:-900}"   # 15 min default
STALE_AFTER_MINUTES="${SESSION_LOCK_STALE:-20}"    # treat lock older than this as abandoned
POLL_BASE=5                                         # base poll interval (seconds)
POLL_JITTER=5                                       # random 0..POLL_JITTER added each cycle

usage() {
  echo "Usage: session-lock.sh {acquire [--force]|release|status}"
  echo ""
  echo "  acquire          Block until the session-close lock is acquired."
  echo "  acquire --force   Remove any existing lock first, then acquire."
  echo "  release          Release the lock. No-op if not held."
  echo "  status           Print lock state. Exit 0 if free, 1 if held."
  echo ""
  echo "Environment:"
  echo "  SESSION_LOCK_MAX_WAIT   Max seconds to wait for acquire (default: 900)"
  echo "  SESSION_LOCK_STALE      Minutes before a lock is considered abandoned (default: 20)"
  exit 2
}

do_acquire() {
  local force="${1:-}"
  local waited=0
  local attempt=0

  if [ "$force" = "--force" ] && [ -d "$LOCKDIR" ]; then
    # Safety check: refuse to force-acquire if the owning PID is still alive.
    # --force is for orphaned locks from crashed processes, not for stealing
    # from active ones. Stealing causes git add -A collisions.
    if [ -f "$LOCKDIR/owner" ]; then
      local owner_pid
      # sed, not `grep -oP`: -P is a GNU extension that BSD grep rejects, and a
      # rejected match reads as "no owner", which lets --force steal a lock from
      # a process that is still alive.
      owner_pid=$(sed -n 's/^pid=\([0-9][0-9]*\).*/\1/p' "$LOCKDIR/owner" 2>/dev/null || echo "")
      if [ -n "$owner_pid" ] && kill -0 "$owner_pid" 2>/dev/null; then
        echo "ERROR: --force refused. Owner PID $owner_pid is still alive."
        echo "  Owner: $(cat "$LOCKDIR/owner")"
        echo "  Wait for the owning session to release, or kill PID $owner_pid first."
        exit 1
      fi
      echo "WARN: --force specified. Owner PID ${owner_pid:-unknown} is dead. Removing orphaned lock."
      echo "  Previous owner: $(cat "$LOCKDIR/owner")"
    else
      echo "WARN: --force specified. No owner file found. Removing lock."
    fi
    rm -rf "$LOCKDIR"
  fi

  while ! mkdir "$LOCKDIR" 2>/dev/null; do
    attempt=$((attempt + 1))

    # Stale lock detection: if the lockdir is older than STALE_AFTER_MINUTES,
    # the owning process likely crashed. Reclaim it.
    if [ -n "$(find "$LOCKDIR" -maxdepth 0 -mmin +"$STALE_AFTER_MINUTES" 2>/dev/null)" ]; then
      echo "WARN: stale lock detected (>${STALE_AFTER_MINUTES}min old). Reclaiming."
      if [ -f "$LOCKDIR/owner" ]; then
        echo "  Previous owner: $(cat "$LOCKDIR/owner")"
      fi
      rm -rf "$LOCKDIR"
      continue
    fi

    if [ "$waited" -ge "$MAX_WAIT_SECONDS" ]; then
      echo "ERROR: lock held for >${MAX_WAIT_SECONDS}s. Cannot acquire."
      if [ -f "$LOCKDIR/owner" ]; then
        echo "  Current holder: $(cat "$LOCKDIR/owner")"
      fi
      echo "  To force: session-lock.sh acquire --force"
      exit 1
    fi

    # Poll interval with jitter so multiple waiters don't all fire at the same instant.
    # When the holder releases, the next waiter to poll wins; others keep waiting.
    local jitter=$((RANDOM % (POLL_JITTER + 1)))
    local sleep_for=$((POLL_BASE + jitter))
    echo "Lock held. Waiting ${sleep_for}s... (attempt ${attempt}, ${waited}s elapsed)"
    sleep "$sleep_for"
    waited=$((waited + sleep_for))
  done

  # Record owner for diagnostics and stale-lock identification
  echo "pid=$$ host=$(hostname) workspace=${PWD:-unknown} started=$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LOCKDIR/owner"
  echo "SESSION_LOCK_ACQUIRED"
}

do_release() {
  if [ -d "$LOCKDIR" ]; then
    rm -rf "$LOCKDIR"
    echo "SESSION_LOCK_RELEASED"
  else
    echo "No lock to release."
  fi
}

do_status() {
  if [ -d "$LOCKDIR" ]; then
    echo "HELD"
    if [ -f "$LOCKDIR/owner" ]; then
      echo "  Owner: $(cat "$LOCKDIR/owner")"
    fi
    if command -v stat >/dev/null 2>&1; then
      local created
      # GNU first, then BSD, each on its own assignment. Chaining them with
      # `||` inside one substitution concatenates their output, because a
      # failing `stat -f` on GNU still prints a filesystem report to stdout.
      created=$(stat -c "%y" "$LOCKDIR" 2>/dev/null | cut -d. -f1) \
        || created=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$LOCKDIR" 2>/dev/null) \
        || created=""
      [ -n "$created" ] || created="unknown"
      echo "  Created: $created"
    fi
    exit 1
  else
    echo "FREE"
    exit 0
  fi
}

# --- main ---
case "${1:-}" in
  acquire) do_acquire "${2:-}" ;;
  release) do_release ;;
  status)  do_status  ;;
  *)       usage      ;;
esac
