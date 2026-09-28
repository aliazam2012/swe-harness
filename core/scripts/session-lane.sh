#!/usr/bin/env bash
# Allocate and release the resources one parallel lane needs.
#
# A lane is one child agent working one workstream: its own git worktree, its
# own reserved port slot, its own branch. Allocating those by hand means two
# steps that can drift apart, and the one that gets forgotten is the registration
# that lets the close find the resource again. This script makes allocation and
# registration a single call, so they cannot diverge.
#
# A slot is a reserved set of ports. Slot N gives 3000+100N, 8080+100N and
# 8081+100N by default. Override the bases with LANE_PORT_BASES. Slot 0 is
# whatever was already running before the lanes started, and is never handed out.
#
# The registry is ONE well-known file, not one per pane. That is deliberate and
# it is the whole point of this file's identity model: `down --all` is the
# emergency stop, and an emergency stop that only works from the pane that is
# already wedged is not a stop. Discovery must not depend on the process being
# alive, so any shell can read the registry and release every lane in it.
#
# Each row still carries the pane that created it. Discovery is by the registry;
# ownership is by that stamp, and only ownership decides what a routine cleanup
# may touch. The emergency stop deliberately ignores ownership, because when you
# reach for it you do not know which lane is the problem.
#
# Three ways to get a lane, because a road that does not reach the destination
# gets bypassed. Plain `up --repo` cuts a new lane/<name> branch. `--branch` puts
# the lane on a branch that already exists, which is the common case when the work
# predates the lane. `--adopt` takes a checkout that already exists and only gives
# it a slot and a row.
#
# --adopt deliberately does NOT register the worktree, only the slot. Registration
# is what tells the close it may remove something, and a checkout this session did
# not create is not this session's to remove.
#
# The local commit gate. A repository that ships a .pre-commit-config.yaml
# expects a human to run `pre-commit install` once per checkout. A worktree this
# script cuts has never had that run, so every lane it spawns commits through a
# gate that is not there. `up` closes that hole: it installs the repo's hooks once the
# checkout exists, for --adopt too, since an adopted checkout commits through the
# same hooks and has the same hole. The install never fails the lane. A missing
# binary, a broken config or a failed install warns and the lane still starts.
# Set LANE_SKIP_PRECOMMIT=1 to skip it and get a bare checkout.
#
# Git hooks are NOT per worktree. `git rev-parse --git-path hooks` inside a lane
# resolves into the repository's common dir, so one lane's install changes the
# parent checkout and every sibling lane at once. That shared directory is why
# the install is guarded rather than just run:
#   - pre-commit MOVES a hook it did not generate to <hook>.legacy. An install
#     from a lane could therefore displace a hook someone wrote by hand, in a
#     repo they were not working in. It refuses instead: when a hook file is there
#     that pre-commit did not generate, it leaves the directory untouched.
#   - Two lanes on one repo can install in the same instant. pre-commit truncates
#     the hook file before it writes it, so the second install can read the first
#     one half written, judge it a stranger's hook, and move that wreckage over
#     the .legacy backup, which destroys the backup. Installs therefore serialize
#     on a lock in the common dir, so two lanes cannot overlap.
#   - An install is otherwise idempotent, and the sharing is a feature: the first
#     lane closes the hole for the parent checkout and every sibling at once. A
#     lane that finds the hooks already in place writes nothing at all.
#
# The outcome is the last field of the lane row, and `list` shows it:
#   installed  this run wrote the hooks
#   present    pre-commit hooks were already in place, nothing was written
#   none       the repo ships no .pre-commit-config.yaml
#   absent     pre-commit is not on PATH
#   foreign    a hook this script did not write was in the way, left untouched
#   failed     pre-commit install ran and returned non-zero
#   skipped    LANE_SKIP_PRECOMMIT was set
#   locked     another lane held the install lock, so this one wrote nothing
#   unknown    the hooks directory could not be resolved, so nothing was tried
#
# What this does NOT do, on purpose:
#   - It never removes a worktree. session-cleanup.sh owns that decision, and it
#     already refuses to remove one that is dirty or unpushed. Duplicating that
#     check here would let the two copies drift, and a wrong copy destroys work.
#   - It never closes a pane. session-cleanup.sh owns that too, including the
#     rule that a tab holding a stranger or a working child is left alone.
#   - It never kills a port it did not allocate. Stopping services is delegated
#     to the tool that started them.
#
# Data Sources:
#   - Local only: the workspace sessions/.active registry, local git repositories,
#     and listening TCP ports via lsof
#
# Default Environment: local
# Environments Supported: local
#
# Usage: session-lane.sh up <lane> --repo <path> [--base <ref>] [--slot <n>]
#                                  [--branch <existing-branch>]
#        session-lane.sh up <lane> --adopt <existing-worktree> [--slot <n>]
#        session-lane.sh down <lane>
#        session-lane.sh down --all      (emergency stop: every lane, any shell)
#        session-lane.sh down --mine     (only lanes this pane created)
#        session-lane.sh list [--mine] [--porcelain]
#
# AGENT GUIDE
#   WORKFLOW
#     1. The lead allocates. A child never runs `up` for itself, because a child
#        that picks its own worktree and ports picks one a sibling already holds.
#     2. `up <lane> --repo <path>` reserves the worktree and the port slot and
#        registers both in one call. Lane name, worktree name, branch name and
#        pane name are the same word.
#     3. Hand the child its lane name. It works only inside that worktree.
#     4. `down <lane>` once the child is finished and its work is pushed.
#   ERROR RECOVERY
#     - "lane already allocated": the name is taken. `list` names the holder.
#       Choose another; never reuse a name a running child answers to.
#     - "no free slot": every port slot is held. `list` shows who holds what,
#       then `down` a lane whose child is finished.
#     - "slot N has a port already in use": something outside the registry holds
#       that port. Pick another slot. Do not kill the holder.
#     - A `down` that refuses is protecting work: the worktree is dirty or
#       unpushed. Push it, then retry.
#     - `down --all` is an emergency stop and takes every lane on the machine,
#       including lanes other panes own. Prefer `down --mine`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=session-lib.sh
. "$SCRIPT_DIR/session-lib.sh"

readonly MIN_SLOT=1
readonly MAX_SLOT=9
PORT_BASES="${LANE_PORT_BASES:-3000 8080 8081}"
readonly PORT_BASES
# Releasing a port slot means stopping whatever holds it, and only the tool that
# started those services knows how. Core ships no such tool, so this is empty by
# default and `down` reports the slot as carry-over instead of pretending it
# freed it. Point LANE_STACK_DOWN at a script that takes `down --slot N`.
STACK_DOWN="${LANE_STACK_DOWN:-}"
readonly STACK_DOWN
WORKTREE_ROOT="${LANE_WORKTREE_ROOT:-$HOME/worktrees}"
readonly WORKTREE_ROOT

# An explicit --help is a request that succeeded, so it exits 0; a missing or
# wrong argument is a usage error and exits 2. Callers distinguish the two.
usage() { sed -n '/^# Usage:/,/^[^#]/{/^[^#]/!p;}' "$0" >&2; exit "${1:-2}"; }

# A warning is not a failure. Anything that warns here must leave the lane usable.
warn() { printf 'warning: %s\n' "$*" >&2; }

lane_file() { printf '%s/lanes' "$ACTIVE_DIR"; }

# Several sessions share the registry, so the rewrite path needs a lock. mkdir is
# the atomic primitive available everywhere, and matches session-lock.sh. A stale
# lock older than the timeout is reclaimed: a crashed writer must not wedge the
# emergency stop.
readonly LOCK_STALE_SECONDS=30
# Returns non-zero rather than dying, because one caller (the hook install) must
# never take the lane down with it.
_acquire_lock() {
  local lock="$1" waited=0
  while ! mkdir "$lock" 2>/dev/null; do
    if [ -d "$lock" ]; then
      local age
      age=$(( $(date +%s) - $(file_mtime "$lock" || date +%s) ))
      [ "$age" -gt "$LOCK_STALE_SECONDS" ] && { rmdir "$lock" 2>/dev/null || true; continue; }
    fi
    waited=$((waited + 1))
    [ "$waited" -gt 100 ] && return 1
    sleep 0.1
  done
}

with_lock() {
  local lock
  lock="$(lane_file).lock"
  _acquire_lock "$lock" || die "registry lock held too long: $lock"
  trap 'rmdir "$lock" 2>/dev/null || true' EXIT
  "$@"
  rmdir "$lock" 2>/dev/null || true
  trap - EXIT
}

# A lane name addresses a Herdr agent, a git branch and a directory, so it is
# held to the strictest of the three. Herdr's agent-name rule is the strictest.
valid_lane() {
  # LC_ALL=C, scoped to this function: a character range in a glob follows
  # the collating order of the current locale, and under en_US.UTF-8 bash 3.2
  # (what macOS ships at /bin/bash) sorts 'A' and 'e-acute' inside a-z. The
  # range then accepts exactly the names it was written to refuse. Byte order
  # is the order this rule means.
  local LC_ALL=C
  case "$1" in
    ''|*[!a-z0-9_-]*) return 1 ;;
    [!a-z]*) return 1 ;;
    *) [ "${#1}" -le 32 ] ;;
  esac
}

# Ports this slot reserves, space separated.
slot_ports() {
  local base out=""
  for base in $PORT_BASES; do out="$out $(( base + 100 * $1 ))"; done
  printf '%s' "${out# }"
}

# Prints the pid listening on $1, or nothing. lsof exits non-zero when nothing
# is listening, which is the common case and not an error.
port_owner() { lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null | head -1 || true; }

# A port is machine-wide, so a slot another pane holds is taken for everyone.
# Scoping this to the caller would hand out a slot already in use.
slot_taken() {
  local lf; lf=$(lane_file)
  [ -f "$lf" ] && awk -F'|' -v s="$1" '$3 == s { found = 1 } END { exit !found }' "$lf"
}

slot_ports_busy() {
  local p
  for p in $(slot_ports "$1"); do [ -n "$(port_owner "$p")" ] && return 0; done
  return 1
}

# Lowest slot nobody has taken and whose ports nobody is holding. Checking the
# ports as well as the registry is what stops a stack someone started by hand
# from being trampled.
pick_slot() {
  local n
  for (( n = MIN_SLOT; n <= MAX_SLOT; n++ )); do
    slot_taken "$n" && continue
    slot_ports_busy "$n" && continue
    printf '%s' "$n"; return 0
  done
  return 1
}

lane_by_path() {
  local lf; lf=$(lane_file)
  [ -f "$lf" ] && awk -F'|' -v p="$1" '$2 == p { found = 1 } END { exit !found }' "$lf"
}

lane_row() {
  local lf; lf=$(lane_file)
  [ -f "$lf" ] || return 1
  awk -F'|' -v l="$1" '$1 == l { print; found = 1 } END { exit !found }' "$lf"
}

_drop_lane_row() {
  local lf tmp; lf=$(lane_file)
  [ -f "$lf" ] || return 0
  tmp="$lf.tmp.$$"
  trap 'rm -f "$tmp"' EXIT
  awk -F'|' -v l="$1" '$1 != l' "$lf" > "$tmp"
  mv "$tmp" "$lf"
  trap - EXIT
}

# ------------------------------------------------------------ the commit gate

# pre-commit stamps every hook it generates with this line, and reads it back to
# decide whether a hook is its own. Reading the same mark is what lets this
# script tell a hook it may leave alone from one it must not touch.
readonly PRECOMMIT_MARKER='File generated by pre-commit'
readonly HOOK_LOCK_NAME='.session-lane-hooks.lock'

# The hook types an install would write, which is exactly the set the guard has
# to inspect. pre-commit installs the config's default_install_hook_types, or
# pre-commit alone when the config names none. Both YAML spellings are read: an
# inline [a, b] list and a block of "- a" lines. Scoping the guard to these types
# matters: a repo may carry an unrelated hand-written hook, and refusing to
# install because of a post-checkout hook nobody asked about would leave the gate
# off for no reason.
hook_types() {
  # LC_ALL=C: a-z means the 26 ASCII letters, not whatever the locale
  # collates between them. See valid_lane above.
  local LC_ALL=C cfg="$1" raw="" t out=""
  raw=$(awk '
    /^default_install_hook_types:/ {
      line = $0
      sub(/^default_install_hook_types:[ \t]*/, "", line)
      gsub(/[][,]/, " ", line); gsub(/"/, "", line); gsub(/\047/, "", line)
      print line
      block = 1
      next
    }
    block && /^[ \t]*-[ \t]*/ {
      line = $0
      sub(/^[ \t]*-[ \t]*/, "", line)
      sub(/[ \t]*#.*/, "", line)
      gsub(/"/, "", line); gsub(/\047/, "", line)
      print line
      next
    }
    block && /^[^ \t]/ { block = 0 }
  ' "$cfg" 2>/dev/null || true)
  for t in $raw; do
    case "$t" in
      ''|*[!a-z-]*) continue ;;
      *) out="$out $t" ;;
    esac
  done
  out="${out# }"
  printf '%s' "${out:-pre-commit}"
}

# "ours" when pre-commit generated this hook, "foreign" when something else did,
# empty when there is no hook. lexists, not exists: a dangling symlink is still
# a file in the way.
hook_state() {
  { [ -e "$1" ] || [ -L "$1" ]; } || return 0
  if grep -q "$PRECOMMIT_MARKER" "$1" 2>/dev/null; then printf 'ours'; else printf 'foreign'; fi
}

# Install the repo's pre-commit hooks for a checkout. Prints one status word and
# always succeeds. A lane that will not start because a linter is absent is worse
# than a lane without hooks, so every failure here warns and continues.
#
# See the header for why this is guarded: the directory it writes to is shared
# with the parent checkout and every sibling lane of the same repo.
install_commit_hooks() {
  local path="$1" cfg dir lock types t status="" out=""
  cfg="$path/.pre-commit-config.yaml"
  if [ -n "${LANE_SKIP_PRECOMMIT:-}" ] && [ "$LANE_SKIP_PRECOMMIT" != 0 ]; then
    printf 'skipped'; return 0
  fi
  [ -f "$cfg" ] || { printf 'none'; return 0; }
  if ! command -v pre-commit >/dev/null 2>&1; then
    warn "pre-commit is not on PATH, so $path has no local commit gate. Install it, then: (cd $path && pre-commit install)"
    printf 'absent'; return 0
  fi
  dir=$(git -C "$path" rev-parse --path-format=absolute --git-path hooks 2>/dev/null) || dir=""
  if [ -z "$dir" ]; then
    warn "could not resolve the hooks directory for $path, so the hooks were left alone"
    printf 'unknown'; return 0
  fi
  mkdir -p "$dir" 2>/dev/null || true
  lock="$(dirname "$dir")/$HOOK_LOCK_NAME"
  if ! _acquire_lock "$lock"; then
    warn "another lane holds the hook-install lock at $lock, so the hooks were left alone"
    printf 'locked'; return 0
  fi
  trap 'rmdir "$lock" 2>/dev/null || true' EXIT

  types=$(hook_types "$cfg")
  for t in $types; do
    [ "$(hook_state "$dir/$t")" = foreign ] || continue
    warn "$dir/$t was not generated by pre-commit, and an install would move it aside, so the hooks were left alone. Install by hand if you want them: (cd $path && pre-commit install)"
    status=foreign
    break
  done
  if [ -z "$status" ]; then
    status=present
    for t in $types; do
      [ "$(hook_state "$dir/$t")" = ours ] && continue
      status=""
      break
    done
  fi
  if [ -z "$status" ]; then
    if out=$(cd "$path" && pre-commit install 2>&1); then
      status=installed
    else
      warn "pre-commit install failed in $path and the lane still starts: $(printf '%s' "$out" | tr '\n' ' ')"
      status=failed
    fi
  fi

  rmdir "$lock" 2>/dev/null || true
  trap - EXIT
  printf '%s' "$status"
}

cmd_up() {
  local lane="" repo="" base="" slot="" branch="" path=""
  lane="${1:-}"; shift || true
  [ -n "$lane" ] || usage
  valid_lane "$lane" || die "lane must be lowercase letters, digits, hyphen or underscore, starting with a letter, max 32: $lane"
  local adopt=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      --base) base="${2:-}"; shift 2 ;;
      --slot) slot="${2:-}"; shift 2 ;;
      --branch) branch="${2:-}"; shift 2 ;;
      --adopt) adopt="${2:-}"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  require_cmd git lsof
  if [ -n "$adopt" ]; then
    [ -z "$branch" ] || die "--adopt takes the worktree as it is; drop --branch"
    [ -z "$base" ] || die "--adopt takes the worktree as it is; drop --base"
    [ -d "$adopt" ] || die "worktree path does not exist: $adopt"
    adopt=$(cd "$adopt" && pwd -P)
    git -C "$adopt" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
      || die "not a git worktree: $adopt"
    [ -n "$repo" ] || repo=$(git -C "$adopt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's|/\.git$||')
  else
    # A missing required argument is a usage error, not a runtime one, so it exits
    # 2 like every other bad invocation in this file.
    [ -n "$repo" ] || usage
    [ -d "$repo" ] || die "repo path does not exist: $repo"
    repo=$(cd "$repo" && pwd -P)
    git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repository: $repo"
    if [ -n "$branch" ]; then
      git -C "$repo" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null \
        || die "branch does not exist: $branch (drop --branch to cut lane/$lane)"
    fi
  fi
  lane_row "$lane" >/dev/null 2>&1 && die "lane already allocated: $lane (release it with: session-lane.sh down $lane)"

  if [ -n "$slot" ]; then
    case "$slot" in ''|*[!0-9]*) die "slot must be a number, got: $slot" ;; esac
    [ "$slot" -ge "$MIN_SLOT" ] && [ "$slot" -le "$MAX_SLOT" ] \
      || die "slot must be $MIN_SLOT..$MAX_SLOT, got: $slot"
    slot_taken "$slot" && die "slot $slot is already allocated"
    if slot_ports_busy "$slot"; then
      die "slot $slot has a port already in use. Pick another slot; do not kill the holder."
    fi
  else
    slot=$(pick_slot) || die "no free slot in $MIN_SLOT..$MAX_SLOT. Release one with: session-lane.sh down <lane>"
  fi

  if [ -n "$adopt" ]; then
    path="$adopt"
    branch=$(git -C "$path" rev-parse --abbrev-ref HEAD)
    lane_by_path "$path" && die "that worktree is already a lane: $path"
  else
    [ -n "$branch" ] || branch="lane/$lane"
    path="$WORKTREE_ROOT/$(basename "$repo")/$lane"
    [ -e "$path" ] && die "worktree path already exists: $path"
    if git -C "$repo" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
      git -C "$repo" worktree add "$path" "$branch" >/dev/null \
        || die "git worktree add failed for $path on $branch"
    else
      [ -n "$base" ] || base=$(git -C "$repo" rev-parse --abbrev-ref HEAD)
      git -C "$repo" worktree add -b "$branch" "$path" "$base" >/dev/null \
        || die "git worktree add failed for $path"
    fi
  fi

  # The checkout exists now, so the gate can go in. It is deliberately after both
  # paths, adoption included, and deliberately incapable of failing the lane.
  local hooks=""
  hooks=$(install_commit_hooks "$path") || hooks=unknown
  [ -n "$hooks" ] || hooks=unknown

  # Register before announcing. A resource that exists but is unregistered is
  # invisible to the close, which is the leak this script exists to prevent.
  # An adopted worktree is deliberately left unregistered: registration is what
  # permits the close to remove it, and we did not create it.
  [ -n "$adopt" ] || "$SCRIPT_DIR/session-artifact.sh" add worktree "$path" >/dev/null
  "$SCRIPT_DIR/session-artifact.sh" add slot "$slot" >/dev/null
  mkdir -p "$ACTIVE_DIR"
  # Field 8 is the hook status. It is appended, so a row written before this field
  # existed still reads correctly and simply shows no status.
  printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$lane" "$path" "$slot" "$repo" "$branch" \
    "$(pane_token)" "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$hooks" >> "$(lane_file)"

  printf 'lane %s allocated%s\n\n' "$lane" "${adopt:+ (adopted, worktree left unregistered)}"
  printf 'Resources: worktree %s, slot %s (ports %s), branch %s.\n' \
    "$path" "$slot" "$(slot_ports "$slot")" "$branch"
  printf '  Commit hooks (pre-commit): %s.\n' "$hooks"
  printf '  Write output under %s. Lead only: installs, deploys, shared-account writes.\n\n' "$path"
  printf 'Start the child in its own worktree, never in the lead cwd:\n'
  printf '  herdr pane split <child-tab-root-pane> --direction right --cwd %s --no-focus \\\n' "$path"
  printf '    --env HERDR_PARENT_PANE="$HERDR_PANE_ID"\n'
  printf '  herdr agent start %s --kind claude --pane <returned-pane-id> -- --name %s\n' "$lane" "$lane"
}

release_one() {
  local row lane path slot repo branch
  row="$1"
  IFS='|' read -r lane path slot repo branch owner _ <<< "$row"

  if [ -z "$STACK_DOWN" ]; then
    printf -- '- slot %s: no stack tool configured. Stop its services with whatever started them.\n' \
      "$slot"
  elif [ -x "$STACK_DOWN" ]; then
    if "$STACK_DOWN" down --slot "$slot" >/dev/null 2>&1; then
      printf -- '- stopped services on slot %s\n' "$slot"
    else
      printf -- '- no services to stop on slot %s, or the stack tool declined\n' "$slot"
    fi
  else
    printf -- '- slot %s: no stack tool at %s. Stop its services with whatever started them.\n' \
      "$slot" "$STACK_DOWN"
  fi

  local p busy=""
  for p in $(slot_ports "$slot"); do
    [ -n "$(port_owner "$p")" ] && busy="$busy $p"
  done
  if [ -n "$busy" ]; then
    printf -- '- WARNING slot %s still has listeners on%s. The slot is not free yet.\n' "$slot" "$busy"
  fi

  # The artifact registry is per session by design: it records what THIS pane
  # created. The emergency stop runs from any shell, so dropping as the caller
  # would clear the wrong file and leave the owner's row behind. Drop as the
  # owner, which the row already names. Found by the game day on 2026-08-31.
  HERDR_PANE_ID="$owner" "$SCRIPT_DIR/session-artifact.sh" drop "$slot" >/dev/null 2>&1 || true
  with_lock _drop_lane_row "$lane"
  printf -- '- released slot %s and dropped its registration\n' "$slot"
  printf -- '- worktree %s is left to session-cleanup.sh, which removes it only when clean and pushed\n' "$path"
  printf -- '- close its pane with: herdr pane close <pane-id>   (never a tab close while a sibling works)\n'
}

cmd_down() {
  local target="${1:-}"
  [ -n "$target" ] || usage
  local lf; lf=$(lane_file)
  if [ "$target" = "--all" ] || [ "$target" = "--mine" ]; then
    [ -f "$lf" ] && [ -s "$lf" ] || { printf 'no lanes allocated\n'; return 0; }
    local me rows=0
    me=$(pane_token)
    if [ "$target" = "--all" ]; then
      printf 'emergency stop: releasing every lane in the registry, whoever created it\n'
    else
      printf 'releasing every lane this pane created\n'
    fi
    local row owner
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      owner=$(printf '%s' "$row" | cut -d'|' -f6)
      [ "$target" = "--mine" ] && [ "$owner" != "$me" ] && continue
      printf '\nlane %s (created by %s):\n' "${row%%|*}" "$owner"
      release_one "$row"
      rows=$((rows + 1))
    done < <(cat "$lf")
    [ "$rows" -gt 0 ] || { printf 'no lanes allocated\n'; return 0; }
    printf '\nPanes and worktrees remain. Finish with: %s/session-cleanup.sh --apply\n' "$SCRIPT_DIR"
    return 0
  fi
  valid_lane "$target" || die "not a lane name: $target"
  local row
  row=$(lane_row "$target") || die "no such lane: $target"
  printf 'lane %s:\n' "$target"
  release_one "$row"
}

cmd_list() {
  local mine=no porcelain=no a
  # --porcelain is the contract session-batch.sh reads. Keep the field order and
  # the pipe delimiter stable: a human table is not an interface.
  #
  # The hook status is shown in the table and deliberately kept OUT of porcelain.
  # session-batch.sh reads those rows with `read -r lane slot path _ created`,
  # where the last variable takes everything left, so a sixth field would land
  # inside the timestamp and silently cost every new lane its spawn grace period.
  # A column nobody parses belongs in the table, not in the contract.
  for a in "$@"; do
    case "$a" in
      --mine) mine=yes ;;
      --porcelain) porcelain=yes ;;
      *) die "unknown argument: $a" ;;
    esac
  done
  local lf; lf=$(lane_file)
  if [ ! -f "$lf" ] || [ ! -s "$lf" ]; then
    [ "$porcelain" = yes ] || printf 'no lanes allocated\n'
    return 0
  fi
  [ "$porcelain" = yes ] || printf '%-16s %-6s %-22s %-10s %-9s %s\n' \
    LANE SLOT PORTS OWNER HOOKS WORKTREE
  local lane path slot owner created hooks shown=0 me
  me=$(pane_token)
  while IFS='|' read -r lane path slot _ _ owner created hooks; do
    [ -n "$lane" ] || continue
    [ "$mine" = yes ] && [ "$owner" != "$me" ] && continue
    # A row written before the hook field existed has none, and says so.
    [ -n "$hooks" ] || hooks='-'
    if [ "$porcelain" = yes ]; then
      printf '%s|%s|%s|%s|%s\n' "$lane" "$slot" "$path" "$owner" "$created"
    else
      printf '%-16s %-6s %-22s %-10s %-9s %s\n' \
        "$lane" "$slot" "$(slot_ports "$slot")" "$owner" "$hooks" "$path"
    fi
    shown=$((shown + 1))
  done < "$lf"
  [ "$shown" -gt 0 ] || [ "$porcelain" = yes ] || printf 'no lanes allocated\n'
}

[ "$#" -ge 1 ] || usage
cmd="$1"; shift
case "$cmd" in
  up)   cmd_up "$@" ;;
  down) cmd_down "$@" ;;
  list) cmd_list "$@" ;;
  -h|--help) usage 0 ;;
  *) die "unknown command '$cmd'" ;;
esac
