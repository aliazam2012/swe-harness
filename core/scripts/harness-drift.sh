#!/usr/bin/env bash
# Report files under ~/.claude that this harness does not own.
#
# Root cause this exists for: a managed directory was populated by hand, one file
# at a time, with no manifest and no check that the live directory and the source
# tree agree. Adoption was silent and partial, so every file added after the
# first pass stayed untracked with no failure and no warning.
#
# An owned file is a symlink that resolves into the harness clone. Anything else
# living under a managed directory is drift: it works on this machine and exists
# nowhere else, so a second machine gets a quietly different harness.
#
# Drift is not always a defect. Claude Code writes its own runtime state under
# ~/.claude, and a local override is a deliberate choice. Those are filtered by
# name below; everything else is reported so a person decides.
#
# Data Sources:
#   - Local filesystem only
#
# Default Environment: local
# Environments Supported: local
#
# Usage: harness-drift.sh [--quiet]
# Exit:  0 no drift, 1 drift found, 2 usage error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=../lib/harness-config.sh
. "$SCRIPT_DIR/../lib/harness-config.sh"

# pwd -P, because the link targets resolved below are fully canonical. On macOS
# /var is a symlink to /private/var, so comparing a canonical target against a
# non-canonical prefix silently fails to match and every owned file reads as
# drift.
HOME_DIR="$(cd "$(harness_home)" && pwd -P)"
readonly HOME_DIR
readonly CLAUDE_DIR="$HOME/.claude"
# What install.py links, and nothing else. A directory the harness never writes
# is not a directory it can report drift in.
readonly MANAGED="skills agents commands hooks"

quiet=no
case "${1:-}" in
  --quiet) quiet=yes ;;
  '') ;;
  *) printf 'usage: %s [--quiet]\n' "$0" >&2; exit 2 ;;
esac

report() {
  [ "$quiet" = yes ] && return 0
  printf '%s\n' "$1"
}

# Follow a symlink chain to its final target, portably.
#
# `readlink -f` is a GNU extension that older BSD userlands do not have, and one
# level of readlink is not enough: a file linked to a file linked into the clone
# is owned, and a single hop would wrongly call it drift.
resolve_link() {
  local path="$1" target hops=0
  while [ -L "$path" ] && [ "$hops" -lt 32 ]; do
    target=$(readlink "$path")
    case "$target" in
      /*) path="$target" ;;
      *)  path="$(dirname "$path")/$target" ;;
    esac
    hops=$((hops + 1))
  done
  # The parent must exist to canonicalize; a dangling link resolves to itself.
  if [ -e "$path" ]; then
    (cd "$(dirname "$path")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename "$path")")
  else
    printf '%s' "$path"
  fi
}

drift=0
for kind in $MANAGED; do
  live="$CLAUDE_DIR/$kind"
  [ -d "$live" ] || continue
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    base=$(basename "$entry")
    case "$base" in
      # Backups, editor leavings and this harness's own uninstall copies.
      *.old-*|*.bak|*.bak-*|*.harness-bak-*|*.sock|*.log|.DS_Store) continue ;;
      # Local-only overrides and credentials, never tracked by policy.
      settings.local.json|.credentials.json) continue ;;
      # Interpreter and tool caches.
      __pycache__|.pytest_cache|node_modules) continue ;;
    esac
    if [ -L "$entry" ]; then
      target=$(resolve_link "$entry")
      case "$target" in "$HOME_DIR"/*) continue ;; esac
    fi
    report "  unowned  $entry"
    drift=$((drift + 1))
  done < <(find "$live" -mindepth 1 -maxdepth 1 | LC_ALL=C sort)
done

if [ "$drift" -eq 0 ]; then
  report "no drift: every managed entry under $CLAUDE_DIR resolves into $HOME_DIR"
  exit 0
fi
report ""
report "$drift entry(ies) under $CLAUDE_DIR are not owned by this harness."
report "Move each one into the clone (core/ or a layer), then run ./install.sh --write."
exit 1
