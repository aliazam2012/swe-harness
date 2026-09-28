#!/usr/bin/env bash
# Remove the disposable resources this session created, and report what it could
# not remove so the next session can resume it.
#
# What it acts on:
#   - child agent panes stamped with HERDR_PARENT_PANE = this pane, and the tab
#     that holds only those children
#   - tabs, panes and workspaces registered with session-artifact.sh
#   - git and Herdr worktrees registered with session-artifact.sh
#   - stale worktree admin records in the repos those worktrees belong to
#
# What it never does: touch a resource this pane did not create, close its own
# pane, tab or workspace, delete a branch, or discard uncommitted or unpushed
# work. A resource holding work is kept and reported as carry-over. Cleanup that
# can destroy work is not cleanup.
#
# Default is a dry run. --apply performs the removals.
#
# Data Sources:
#   - Local only: the Herdr CLI over its local socket, local git repositories,
#     and the workspace sessions/.active registry
#
# Default Environment: local
# Environments Supported: local
#
# Usage: session-cleanup.sh [--apply] [--record]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=session-lib.sh
. "$SCRIPT_DIR/session-lib.sh"

# Ceiling for one Herdr call. The SessionEnd hook that reaches this script has a
# 30 second budget, so an unresponsive socket must not hold the close open.
readonly HERDR_TIMEOUT=5

apply=no
record=no

usage() { sed -n '/^# Usage:/,/^[^#]/{/^[^#]/!p;}' "$0" >&2; exit 2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) apply=yes; shift ;;
    --record) record=yes; shift ;;
    -h|--help) usage ;;
    *) die "unknown option $1" ;;
  esac
done

require_cmd git

MY_PANE="${HERDR_PANE_ID:-}"
MY_TAB="${HERDR_TAB_ID:-}"
MY_WS="${HERDR_WORKSPACE_ID:-}"
MY_CWD="$(pwd -P)"
HERDR_BIN="${HERDR_BIN_PATH:-$(command -v herdr 2>/dev/null || true)}"
readonly MY_PANE MY_TAB MY_WS MY_CWD HERDR_BIN

report=()
notes=()
say() { report+=("- $1"); }
note() { notes+=("$1"); }

# "closed" when acting, "would close" when planning. Every action line reads the
# same in both modes apart from this verb, so a dry run is a literal preview.
verb() { if [ "$apply" = yes ]; then printf '%s' "$1"; else printf 'would %s' "$2"; fi; }

herdr_live() {
  [ "${HERDR_ENV:-}" = 1 ] && [ -n "$MY_PANE" ] && [ -n "$HERDR_BIN" ] && [ -x "$HERDR_BIN" ]
}

# Run a command under a wall-clock ceiling. macOS ships no coreutils timeout, so
# the watcher is a backgrounded sleep; its output goes to /dev/null so it cannot
# hold a command substitution open after the real command exits.
bounded() {
  local secs="$1" pid watcher rc=0
  shift
  "$@" &
  pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  watcher=$!
  wait "$pid" 2>/dev/null || rc=$?
  kill -TERM "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  return "$rc"
}

# Herdr JSON on stdout, empty on any failure. A dead socket degrades this script
# to a worktree-only cleanup rather than failing the close.
hjson() {
  herdr_live || return 0
  bounded "$HERDR_TIMEOUT" "$HERDR_BIN" "$@" 2>/dev/null || true
}

hact() {
  if [ "$apply" != yes ]; then return 0; fi
  herdr_live || return 0
  bounded "$HERDR_TIMEOUT" "$HERDR_BIN" "$@" >/dev/null 2>&1
}

# Every array below is expanded as ${arr[@]+"${arr[@]}"} rather than the plainer
# "${arr[@]}". Under `set -u`, bash before 4.4 treats an empty array expansion as
# an unbound variable and aborts the script; macOS ships 3.2 at /bin/bash, so the
# plain form turned "nothing to clean up" into a hard failure there. The `+`
# form expands to no words at all when the array is empty and to its elements
# otherwise, on every version from 3.2 up.
in_list() {
  local needle="$1" item
  shift
  for item in "$@"; do [ "$item" = "$needle" ] && return 0; done
  return 1
}

# Drop a resource from the registry once it is really gone, so a second run does
# not report it again and a later session cannot act on a dead handle.
forget() {
  [ "$apply" = yes ] || return 0
  "$SCRIPT_DIR/session-artifact.sh" drop "$1" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------- the registry

artifacts_worktrees=()
artifacts_tabs=()
artifacts_panes=()
artifacts_workspaces=()

af="$(artifact_file)"
if [ -f "$af" ]; then
  while IFS='|' read -r kind value _created; do
    [ -n "${kind:-}" ] && [ -n "${value:-}" ] || continue
    case "$kind" in
      worktree)  artifacts_worktrees+=("$value") ;;
      tab)       artifacts_tabs+=("$value") ;;
      pane)      artifacts_panes+=("$value") ;;
      workspace) artifacts_workspaces+=("$value") ;;
    esac
  done < "$af"
fi

# --------------------------------------------------------------- port slots
#
# Ports outlive a pane. A stack tool detaches its services and tracks them by
# pidfile, so closing a child's pane leaves its stack running and its ports held
# by a process nobody can attribute. Nothing else on the machine would ever free
# them, and the next session to want that slot finds it taken.
#
# Released before panes close, which is the reverse-order rule the lane doctrine
# already uses: a service stops before the pane that started it goes.
#
# Delegated to session-lane.sh rather than taught here, because only the tool
# that allocated a slot knows how to stop what runs on it. A lane whose agent is
# still working or blocked is kept, on the same rule that keeps such a child.

if [ -x "$SCRIPT_DIR/session-lane.sh" ]; then
  lane_states=""
  if herdr_live; then
    require_cmd jq
    lane_states=$(hjson agent list | jq -r '
      .result.agents[]? | [(.name // "-"), (.agent_status // "unknown")] | @tsv' 2>/dev/null || true)
  fi
  while IFS='|' read -r lane slot _ _ _; do
    [ -n "$lane" ] || continue
    state=$(printf '%s\n' "$lane_states" | awk -F'\t' -v l="$lane" '$1 == l { print $2; exit }')
    case "$state" in
      working|blocked)
        say "slot kept: $slot held by lane $lane, whose agent is $state"
        note "carry-over: lane $lane still $state on slot $slot; release with scripts/session-lane.sh down $lane"
        continue
        ;;
    esac
    [ "$apply" = yes ] && "$SCRIPT_DIR/session-lane.sh" down "$lane" >/dev/null 2>&1
    say "$(verb released release) slot $slot held by lane $lane"
  done < <("$SCRIPT_DIR/session-lane.sh" list --mine --porcelain 2>/dev/null || true)
fi

# ------------------------------------------------------------- child agents

closable_panes=()
closable_names=()
child_tabs=()
child_ws=()

if herdr_live; then
  require_cmd jq
  children=$(hjson agent list | jq -r --arg p "$MY_PANE" '
    .result.agents[]?
    | select((.tokens.parent // "") == $p)
    | [.pane_id, .tab_id, .workspace_id, (.name // "-"), (.agent_status // "unknown")]
    | @tsv' 2>/dev/null || true)

  while IFS=$'\t' read -r pane tab ws name state; do
    [ -n "${pane:-}" ] || continue
    [ "$pane" = "$MY_PANE" ] && continue
    case "$state" in
      idle|done)
        closable_panes+=("$pane")
        closable_names+=("$name")
        in_list "$tab" ${child_tabs[@]+"${child_tabs[@]}"} || { child_tabs+=("$tab"); child_ws+=("$ws"); }
        ;;
      *)
        # working, blocked or unknown. None of those prove the child is finished,
        # and a closed pane cannot be inspected afterwards.
        say "child kept: $name at $pane, state $state"
        note "carry-over: child agent $name left $state in pane $pane"
        ;;
    esac
  done <<< "$children"
fi

# A registered tab is a candidate even when no child of mine is live in it any
# more, which is the usual state after a batch finishes and its agents exit.
for t in ${artifacts_tabs[@]+"${artifacts_tabs[@]}"}; do
  in_list "$t" ${child_tabs[@]+"${child_tabs[@]}"} && continue
  child_tabs+=("$t")
  child_ws+=("${t%%:*}")
done

# Close a whole tab only when nothing in it belongs to anyone else. Any agent
# pane that is not one of my closable children makes the tab foreign, and its
# panes get closed one at a time instead.
closed_tab_panes=()
i=0
for tab in ${child_tabs[@]+"${child_tabs[@]}"}; do
  ws="${child_ws[$i]}"
  i=$((i + 1))
  [ -n "$tab" ] || continue
  [ "$tab" = "$MY_TAB" ] && continue
  panes=$(hjson pane list --workspace "$ws" | jq -r --arg t "$tab" '
    .result.panes[]? | select(.tab_id == $t) | [.pane_id, (.agent // "-")] | @tsv' 2>/dev/null || true)
  [ -n "$panes" ] || continue
  tab_is_mine=yes
  members=()
  while IFS=$'\t' read -r p agent; do
    [ -n "${p:-}" ] || continue
    members+=("$p")
    in_list "$p" ${closable_panes[@]+"${closable_panes[@]}"} && continue
    in_list "$p" ${artifacts_panes[@]+"${artifacts_panes[@]}"} && continue
    [ "${agent:-}" = "-" ] && continue
    tab_is_mine=no
  done <<< "$panes"
  [ "$tab_is_mine" = yes ] || continue
  if hact tab close "$tab" || [ "$apply" != yes ]; then
    closed_tab_panes+=(${members[@]+"${members[@]}"})
    names=()
    j=0
    for p in ${closable_panes[@]+"${closable_panes[@]}"}; do
      in_list "$p" ${members[@]+"${members[@]}"} && names+=("${closable_names[$j]}")
      j=$((j + 1))
    done
    forget "$tab"
    for m in ${members[@]+"${members[@]}"}; do forget "$m"; done
    say "$(verb closed close) tab $tab with ${#members[@]} pane(s)${names:+ (${names[*]})}"
  else
    say "tab $tab could not be closed; its panes are handled one at a time"
  fi
done

# Panes left over: a child in a tab that is not mine, or a registered pane whose
# tab still holds someone else's work.
j=0
for p in ${closable_panes[@]+"${closable_panes[@]}"}; do
  name="${closable_names[$j]}"
  j=$((j + 1))
  in_list "$p" ${closed_tab_panes[@]+"${closed_tab_panes[@]}"} && continue
  [ "$p" = "$MY_PANE" ] && continue
  hact pane close "$p" || true
  forget "$p"
  say "$(verb closed close) child pane $p ($name)"
done
for p in ${artifacts_panes[@]+"${artifacts_panes[@]}"}; do
  in_list "$p" ${closed_tab_panes[@]+"${closed_tab_panes[@]}"} && continue
  in_list "$p" ${closable_panes[@]+"${closable_panes[@]}"} && continue
  [ "$p" = "$MY_PANE" ] && continue
  hact pane close "$p" || true
  forget "$p"
  say "$(verb closed close) registered pane $p"
done

# ------------------------------------------------------------------ worktrees

# The default branch of a repo, for judging whether unpushed commits are already
# somewhere durable. Empty when the repo has no origin.
default_ref() {
  local wt="$1" ref
  ref=$(git -C "$wt" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -z "$ref" ]; then
    for ref in origin/main origin/master; do
      git -C "$wt" rev-parse --verify --quiet "$ref" >/dev/null 2>&1 && break
      ref=''
    done
  fi
  printf '%s' "$ref"
}

# Is a live agent, or this session itself, sitting inside this worktree?
worktree_busy() {
  local wt="$1" cwd
  case "$MY_CWD" in "$wt"|"$wt"/*) return 0 ;; esac
  herdr_live || return 1
  while IFS= read -r cwd; do
    [ -n "$cwd" ] || continue
    case "$cwd" in "$wt"|"$wt"/*) return 0 ;; esac
  done <<< "$(hjson agent list | jq -r '.result.agents[]? | (.cwd // empty), (.foreground_cwd // empty)' 2>/dev/null || true)"
  return 1
}

# Herdr workspace id bound to this checkout, empty when Herdr does not own it.
herdr_workspace_for() {
  hjson workspace list | jq -r --arg p "$1" '
    .result.workspaces[]?
    | select((.worktree.checkout_path // "") == $p and (.worktree.is_linked_worktree // false))
    | .workspace_id' 2>/dev/null | head -1 || true
}

prune_repos=()

for wt in ${artifacts_worktrees[@]+"${artifacts_worktrees[@]}"}; do
  if [ ! -d "$wt" ]; then
    forget "$wt"
    say "worktree already gone: $wt"
    continue
  fi
  if ! git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    say "worktree kept: $wt is no longer a git worktree, left as is"
    continue
  fi
  repo_git=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  repo_root=$(dirname "${repo_git:-/}")
  in_list "$repo_root" ${prune_repos[@]+"${prune_repos[@]}"} || prune_repos+=("$repo_root")

  branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'unknown')
  dirty=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  upstream=$(git -C "$wt" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
  if [ -n "$upstream" ]; then
    ahead=$(git -C "$wt" rev-list --count "$upstream..HEAD" 2>/dev/null || printf '0')
    where="unpushed"
  else
    base=$(default_ref "$wt")
    if [ -n "$base" ]; then
      ahead=$(git -C "$wt" rev-list --count "$base..HEAD" 2>/dev/null || printf '1')
      where="not on $base"
    else
      # No upstream and no origin to compare against. Nothing proves the commits
      # exist anywhere else, so the worktree stays.
      ahead=1
      where="unpushed, no remote to check"
    fi
  fi

  reasons=()
  [ "$dirty" -gt 0 ] && reasons+=("$dirty uncommitted")
  [ "$ahead" -gt 0 ] && reasons+=("$ahead $where")
  worktree_busy "$wt" && reasons+=("an agent is working in it")

  if [ "${#reasons[@]}" -gt 0 ]; then
    joined=$(printf '%s, ' ${reasons[@]+"${reasons[@]}"}); joined="${joined%, }"
    say "worktree kept: $wt on $branch ($joined); resume with: herdr worktree open --path $wt"
    note "carry-over: worktree $wt on $branch, $joined"
    continue
  fi

  ws=$(herdr_workspace_for "$wt")
  if [ -n "$ws" ] && [ "$ws" != "$MY_WS" ]; then
    hact worktree remove --workspace "$ws" || true
    forget "$wt"
    forget "$ws"
    say "$(verb removed remove) Herdr worktree $wt on $branch (workspace $ws)"
  else
    if [ "$apply" = yes ]; then
      git -C "$repo_root" worktree remove "$wt" >/dev/null 2>&1 \
        || { say "worktree kept: git refused to remove $wt"; continue; }
    fi
    forget "$wt"
    say "$(verb removed remove) worktree $wt on $branch"
  fi
done

# ------------------------------------------------------------ registered workspaces

for ws in ${artifacts_workspaces[@]+"${artifacts_workspaces[@]}"}; do
  [ "$ws" = "$MY_WS" ] && continue
  live=$(hjson pane list --workspace "$ws" | jq -r '[.result.panes[]? | select(.agent != null)] | length' 2>/dev/null || printf '0')
  if [ "${live:-0}" -gt 0 ]; then
    say "workspace kept: $ws still holds $live agent pane(s)"
    note "carry-over: workspace $ws still holds $live agent pane(s)"
    continue
  fi
  hact workspace close "$ws" || true
  forget "$ws"
  say "$(verb closed close) workspace $ws"
done

# ------------------------------------------------------------------- pruning

# Only clears admin records whose directory is already gone. It never touches a
# checkout that still exists, so it is safe to run unconditionally.
if [ -d "$MY_CWD" ] && git -C "$MY_CWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  cwd_git=$(git -C "$MY_CWD" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  cwd_root=$(dirname "${cwd_git:-/}")
  in_list "$cwd_root" ${prune_repos[@]+"${prune_repos[@]}"} || prune_repos+=("$cwd_root")
fi

for repo in ${prune_repos[@]+"${prune_repos[@]}"}; do
  stale=$(git -C "$repo" worktree list --porcelain 2>/dev/null | awk '/^prunable/{c++} END{print c+0}')
  [ "${stale:-0}" -gt 0 ] || continue
  [ "$apply" = yes ] && git -C "$repo" worktree prune >/dev/null 2>&1
  say "$(verb pruned prune) $stale stale worktree record(s) in $(basename "$repo")"
done

# -------------------------------------------------------------------- output

if [ "$record" = yes ] && [ "${#notes[@]}" -gt 0 ]; then
  for n in ${notes[@]+"${notes[@]}"}; do
    "$SCRIPT_DIR/session-note.sh" -l -k NOTE "$n" >/dev/null 2>&1 || true
  done
fi

if [ "${#report[@]}" -eq 0 ]; then
  printf -- '- nothing to clean up\n'
else
  printf -- '%s\n' ${report[@]+"${report[@]}"}
fi
