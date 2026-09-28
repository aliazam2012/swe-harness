#!/usr/bin/env bash
# The durable record of one orchestrated batch: what it is for, what each lane
# was asked to do, what state each lane is in, and every steer that arrived.
#
# The lead's context is not durable. A compaction, a /clear or a dead session
# loses the plan, and then nobody can say what a running lane was for. Durable
# execution engines solve this with an append-only event log that survives the
# process, and this is that log at the smallest size that still works: one file
# per batch, one line per event, current state folded from the log on read.
#
# Three things follow from the log being the source of truth:
#   - Anyone can read it. `status` is a read-only query that disturbs nothing and
#     works from any shell, including after the lead has died.
#   - Nothing is overwritten, so the log doubles as the audit trail.
#   - Silence is detectable. `status --stale <minutes>` exits non-zero when no
#     event has landed inside the window, which is the dead-man's-switch signal:
#     the alarm is the absence of a pulse, not the presence of an error.
#
# Resources belong to session-lane.sh. This file records intent and state only,
# so a lost log never strands a port.
#
# Data Sources:
#   - Local filesystem only: the workspace sessions/.active/batches directory
#
# Default Environment: local
# Environments Supported: local
#
# Usage: session-batch.sh open   <batch> --goal <text> [--exit <text>]
#        session-batch.sh brief  <batch> <lane> (--text <text> | --file <path>)
#        session-batch.sh state  <batch> <lane> <working|blocked|done|failed> [--note <text>]
#        session-batch.sh steer  <batch> --input <text> --disposition <amend|add|quiesce> [--lane <lane>]
#        session-batch.sh note   <batch> [--lane <lane>] <text>
#        session-batch.sh burst  <batch> <name> --task <text>
#        session-batch.sh current [--mine]
#        session-batch.sh status [<batch>] [--stale <minutes>]
#        session-batch.sh check  [<batch>]
#        session-batch.sh close  <batch> [--outcome <text>]
#        session-batch.sh list
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=session-lib.sh
. "$SCRIPT_DIR/session-lib.sh"

readonly STATES="working blocked done failed"
readonly DISPOSITIONS="amend add quiesce"

usage() { sed -n '/^# Usage:/,/^[^#]/{/^[^#]/!p;}' "$0" >&2; exit 2; }

batch_dir() { printf '%s/batches' "$ACTIVE_DIR"; }
batch_log() { printf '%s/%s.log' "$(batch_dir)" "$1"; }

valid_name() {
  # LC_ALL=C: a-z means the 26 ASCII letters, not whatever the locale
  # collates between them. See valid_lane in session-lane.sh.
  local LC_ALL=C
  case "$1" in
    ''|*[!a-z0-9_-]*) return 1 ;;
    [!a-z]*) return 1 ;;
    *) [ "${#1}" -le 32 ] ;;
  esac
}

in_set() {
  local want="$1" item; shift
  for item in $1; do [ "$item" = "$want" ] && return 0; done
  return 1
}

# The log is line oriented and pipe delimited, so a payload carrying either would
# corrupt every later read. Flatten rather than reject: a brief legitimately
# contains newlines, and losing the batch record to a formatting rule would be a
# worse outcome than losing the line breaks.
flatten() { printf '%s' "$1" | tr '\n|' '  '; }

# One writer at a time, even though today there is usually only one.
#
# Measured on this platform rather than assumed: twelve concurrent writers with a
# 16 KB payload interleave nothing, and the same twelve at 65 KB tore six of the
# twelve lines. So an ordinary brief or note is never at risk, and the exposure is
# the large payload: `brief --file` reading a real document, or a note quoting a
# report. That is a narrow window, but the record is append only and is the audit
# trail, so a torn line is not a glitch to be retried. It is permanent, and every
# later read of that batch parses it wrong.
#
# mkdir is the atomic primitive and matches session-lane.sh and session-lock.sh. A
# lock older than the timeout is reclaimed, because a crashed writer must not wedge
# the record.
#
# This is also what a child writing its own state needs. The lead is the only
# writer today, so nothing here has ever contended, and a lock added after the
# second writer arrives is a lock added after the corruption.
readonly APPEND_LOCK_STALE_SECONDS=30
append() {
  local batch="$1" kind="$2" lane="$3" payload="$4" log lock waited=0
  log=$(batch_log "$batch")
  mkdir -p "$(batch_dir)"
  lock="$log.lock"
  while ! mkdir "$lock" 2>/dev/null; do
    if [ -d "$lock" ]; then
      local age
      age=$(( $(date +%s) - $(file_mtime "$lock" || date +%s) ))
      [ "$age" -gt "$APPEND_LOCK_STALE_SECONDS" ] && { rmdir "$lock" 2>/dev/null || true; continue; }
    fi
    waited=$((waited + 1))
    [ "$waited" -gt 100 ] && die "batch record lock held too long: $lock"
    sleep 0.1
  done
  trap 'rmdir "$lock" 2>/dev/null || true' EXIT
  printf '%s|%s|%s|%s|%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$kind" \
    "${lane:--}" "$(pane_token)" "$(flatten "$payload")" >> "$log"
  rmdir "$lock" 2>/dev/null || true
  trap - EXIT
}

require_batch() {
  [ -f "$(batch_log "$1")" ] || die "no such batch: $1 (open it with: session-batch.sh open $1 --goal ...)"
}

cmd_open() {
  local batch="${1:-}"; shift || true
  [ -n "$batch" ] || usage
  valid_name "$batch" || die "batch name must be lowercase letters, digits, hyphen or underscore, starting with a letter, max 32"
  [ -f "$(batch_log "$batch")" ] && die "batch already open: $batch"
  local goal="" exit_criteria=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --goal) goal="${2:-}"; shift 2 ;;
      --exit) exit_criteria="${2:-}"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ -n "$goal" ] || usage
  append "$batch" OPEN "" "$batch"
  append "$batch" GOAL "" "$goal"
  # An exit criterion agreed before the work starts is what makes "done" a fact
  # rather than an opinion at the end.
  [ -n "$exit_criteria" ] && append "$batch" EXIT "" "$exit_criteria"
  printf 'batch %s open\n' "$batch"
  printf 'record: %s\n' "$(batch_log "$batch")"
  [ -n "$exit_criteria" ] || printf 'no exit criteria set. Add one before the first lane starts.\n'
}

cmd_brief() {
  local batch="${1:-}" lane="${2:-}"; shift 2 2>/dev/null || usage
  [ -n "$batch" ] && [ -n "$lane" ] || usage
  require_batch "$batch"
  valid_name "$lane" || die "not a lane name: $lane"
  local text=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --text) text="${2:-}"; shift 2 ;;
      --file) [ -r "${2:-}" ] || die "cannot read brief file: ${2:-}"; text=$(cat "$2"); shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ -n "$text" ] || usage
  append "$batch" BRIEF "$lane" "$text"
  printf 'brief recorded for lane %s\n' "$lane"
}

# A burst is a lane with no exclusive resources: no worktree, no port slot, a
# one-line task instead of a seven-field brief. It exists because there was
# nothing between an in-pane subagent, which the user cannot see or steer, and a
# full lane, which is too much ceremony for a two-minute question.
#
# It is still recorded, and that is not negotiable. An unrecorded child is the
# exact failure the reconciliation check exists to catch, so a burst that skipped
# this would set off the alarm rather than slip past it. One line is the price.
cmd_burst() {
  local batch="${1:-}" name="${2:-}"; shift 2 2>/dev/null || usage
  [ -n "$batch" ] && [ -n "$name" ] || usage
  require_batch "$batch"
  valid_name "$name" || die "not a burst name: $name"
  local task=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) task="${2:-}"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ -n "$task" ] || usage
  append "$batch" BURST "$name" "$task"
  printf 'burst %s recorded\n\n' "$name"
  printf 'It owns no worktree and no slot, so it must not write to a repository.\n'
  printf 'If it needs to write, release it and allocate a real lane instead.\n\n'
  printf 'Start it in the batch tab, stamped, and release it as soon as it answers:\n'
  printf '  herdr pane split <batch-tab-root> --direction right --no-focus \\\n'
  printf '    --env HERDR_PARENT_PANE="$HERDR_PANE_ID"\n'
  printf '  herdr agent start %s --kind claude --pane <pane> -- --name %s\n' "$name" "$name"
  printf '  herdr pane close <pane>   # the moment it has answered\n'
}

cmd_state() {
  local batch="${1:-}" lane="${2:-}" state="${3:-}"; shift 3 2>/dev/null || usage
  [ -n "$batch" ] && [ -n "$lane" ] && [ -n "$state" ] || usage
  require_batch "$batch"
  valid_name "$lane" || die "not a lane name: $lane"
  in_set "$state" "$STATES" || die "state must be one of: $STATES"
  local note=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --note) note="${2:-}"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  append "$batch" STATE "$lane" "$state${note:+ :: $note}"
  printf 'lane %s is %s\n' "$lane" "$state"
}

cmd_steer() {
  local batch="${1:-}"; shift || usage
  [ -n "$batch" ] || usage
  require_batch "$batch"
  local input="" disposition="" lane=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --input) input="${2:-}"; shift 2 ;;
      --disposition) disposition="${2:-}"; shift 2 ;;
      --lane) lane="${2:-}"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ -n "$input" ] || usage
  in_set "$disposition" "$DISPOSITIONS" \
    || die "disposition must be one of: $DISPOSITIONS (amend a brief, add a lane, or quiesce and re-plan)"
  [ -n "$lane" ] && { valid_name "$lane" || die "not a lane name: $lane"; }
  append "$batch" STEER "$lane" "$disposition :: $input"
  printf 'steer recorded: %s\n' "$disposition"
  [ "$disposition" = quiesce ] && printf 'quiesce: stop the affected lanes and re-plan before applying it.\n'
  return 0
}

cmd_note() {
  local batch="${1:-}"; shift || usage
  [ -n "$batch" ] || usage
  require_batch "$batch"
  local lane=""
  if [ "${1:-}" = "--lane" ]; then lane="${2:-}"; shift 2; fi
  [ -n "${1:-}" ] || usage
  append "$batch" NOTE "$lane" "$*"
  printf 'noted\n'
}

cmd_close() {
  local batch="${1:-}"; shift || usage
  [ -n "$batch" ] || usage
  require_batch "$batch"
  local outcome=""
  if [ "${1:-}" = "--outcome" ]; then outcome="${2:-}"; shift 2; fi
  append "$batch" CLOSE "" "${outcome:-closed}"
  printf 'batch %s closed\n' "$batch"
}

# Batches that are open, meaning no CLOSE event has landed. Closed batches stay
# on disk as the audit trail, so "which batch is live" is not "which file exists".
open_batches() {
  local f n
  for f in "$(batch_dir)"/*.log; do
    [ -e "$f" ] || continue
    grep -q '|CLOSE|' "$f" && continue
    n=$(basename "$f" .log)
    printf '%s\n' "$n"
  done
}

# The predicate. Prints the single open batch and exits 0; exits 1 when there is
# none and 2 when there are several. A hook or a monitor asks this to find out
# whether this session is orchestrating anything, so it has to answer with an
# exit status rather than with text: `status` is for people and always exits 0,
# which made it useless as a test and is the defect this command fixes.
cmd_current() {
  local mine=no
  [ "${1:-}" = "--mine" ] && mine=yes
  local names=() n me
  me=$(pane_token)
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    # --mine keeps a per-session watcher from firing once per session on a batch
    # somebody else opened. The OPEN event's pane is the owner.
    if [ "$mine" = yes ]; then
      awk -F'|' -v me="$me" '$2=="OPEN" && $4==me { found=1 } END { exit !found }' \
        "$(batch_log "$n")" || continue
    fi
    names+=("$n")
  done < <(open_batches)
  case "${#names[@]}" in
    0) return 1 ;;
    1) printf '%s\n' "${names[0]}" ;;
    *) printf 'several batches open: %s\n' "${names[*]}" >&2; return 2 ;;
  esac
}

# Fold the log into current state. Read only: it never writes, so a status check
# from a watcher cannot disturb a running batch.
#
# Every lane carries the age of its own last state event, because the batch-wide
# `last` hides the case that costs the most. One busy lane keeps the whole record
# looking fresh while four others have said nothing for hours, and `--stale` fires
# on the batch, so without a per-lane age a dead lane stays invisible until
# somebody goes looking. A steer or a note does not refresh the age: neither one
# tells you the lane is still alive, and an age that counts them would say fresh
# about a lane nobody has heard from.
render() {
  local batch="$1" log
  log=$(batch_log "$batch")
  awk -F'|' -v b="$batch" -v now="$(date +%s)" '
    # Days since 1970-01-01 for a civil date (Howard Hinnant). This awk has no
    # mktime, and shelling out to date once per lane would turn a read-only
    # render into a fork per row.
    function civil_days(y, m, d,   era, yoe, doy, doe) {
      y -= (m <= 2)
      era = int((y >= 0 ? y : y - 399) / 400)
      yoe = y - era * 400
      doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
      doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
      return era * 146097 + doe - 719468
    }
    # The log stamps %Y-%m-%dT%H:%M:%S%z. Anything shorter is not a timestamp.
    function iso_epoch(s,   sign, off) {
      if (length(s) < 19) return -1
      off = 0
      sign = substr(s, 20, 1)
      if (sign == "+" || sign == "-")
        off = (substr(s, 21, 2) * 3600 + substr(s, 23, 2) * 60) * (sign == "-" ? -1 : 1)
      return civil_days(substr(s, 1, 4) + 0, substr(s, 6, 2) + 0, substr(s, 9, 2) + 0) * 86400 \
             + substr(s, 12, 2) * 3600 + substr(s, 15, 2) * 60 + substr(s, 18, 2) - off
    }
    function age(ts,   e, m, h, d) {
      e = iso_epoch(ts)
      if (e < 0) return "?"
      m = int((now - e) / 60)
      if (m < 0) return "0m"
      if (m < 60) return m "m"
      h = int(m / 60); m = m % 60
      if (h < 24) return h "h" m "m"
      d = int(h / 24); h = h % 24
      return d "d" h "h"
    }
    $2 == "GOAL"  { goal = $5 }
    $2 == "EXIT"  { exitc = $5 }
    $2 == "OPEN"  { opened = $1 }
    $2 == "CLOSE" { closed = $1; outcome = $5 }
    $2 == "BRIEF" { brief[$3] = $5; if (!($3 in state)) state[$3] = "briefed"; when[$3] = $1 }
    $2 == "STATE" { split($5, p, " :: "); state[$3] = p[1]; note[$3] = p[2]; when[$3] = $1 }
    $2 == "STEER" { steers++; laststeer = $1 " " $5 }
    { last = $1 }
    END {
      printf "batch    %s%s\n", b, (closed ? "  (closed " closed ")" : "")
      printf "goal     %s\n", goal
      printf "exit     %s\n", (exitc ? exitc : "NOT SET")
      printf "opened   %s\n", opened
      printf "last     %s\n", last
      if (outcome) printf "outcome  %s\n", outcome
      n = 0
      for (l in state) n++
      if (n) {
        printf "\nlanes\n"
        printf "  %-16s %-10s %-8s %s\n", "LANE", "STATE", "AGE", "NOTE"
        for (l in state) printf "  %-16s %-10s %-8s %s\n", l, state[l], age(when[l]), note[l]
      }
      if (steers) printf "\nsteers   %d, last: %s\n", steers, laststeer
    }' "$log"
}

# Reconcile the record against what is actually allocated and actually running.
#
# This is the detective half of the controls, and it is stronger than the rule
# watcher for one reason: it compares state rather than command strings. It does
# not care how a lane came to have no slot, only that it has none. The dcl run on
# 2026-08-31 produced exactly that case, and no pattern rule caught it because the
# worktree was made a way the patterns did not spell.
#
# Exits 1 when it finds drift, so a monitor or a hook can use it as a test.
cmd_check() {
  local batch="${1:-}" rc=0
  batch=$(resolve_batch "$batch") || return 1
  require_batch "$batch"
  local log; log=$(batch_log "$batch")

  # Lanes the record knows about and does not consider finished.
  local live_lanes=() l
  while IFS= read -r l; do [ -n "$l" ] && live_lanes+=("$l"); done < <(
    awk -F'|' '
      $2 == "BRIEF" && !($3 in seen) { seen[$3] = "briefed" }
      $2 == "STATE" { split($5, p, " :: "); seen[$3] = p[1] }
      END { for (k in seen) if (seen[k] != "done" && seen[k] != "failed") print k }' "$log")

  # What session-lane actually holds, and what herdr actually runs.
  local alloc=""; alloc=$("$SCRIPT_DIR/session-lane.sh" list --porcelain 2>/dev/null || true)
  local agents="" have_agents=no
  if command -v herdr >/dev/null 2>&1; then
    have_agents=yes
    agents=$(herdr agent list 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for a in d.get("result", {}).get("agents", []):
    print("|".join([str(a.get("name") or ""), str(a.get("agent_status") or ""),
                    str(a.get("cwd") or ""), str((a.get("tokens") or {}).get("role") or "")]))
' 2>/dev/null || true)
  fi

  local lane slot path
  # ${arr[@]+...}, not the plain "${arr[@]}": under `set -u` bash before 4.4
  # calls an empty array expansion an unbound variable, and macOS ships 3.2.
  for lane in ${live_lanes[@]+"${live_lanes[@]}"}; do
    if ! printf '%s\n' "$alloc" | awk -F'|' -v l="$lane" '$1 == l { f = 1 } END { exit !f }'; then
      printf -- '- lane %s is live in the record but holds no slot; it will collide on the default ports\n' "$lane"
      printf -- '    fix: session-lane.sh up %s --adopt <its worktree>\n' "$lane"
      rc=1
    fi
  done

  # A lane is allocated a moment before its agent exists, so a check run during a
  # spawn would report a slot held for nothing. Found on the first live run, when
  # it flagged a lane that was mid-spawn. Give a new lane a grace period.
  local grace="${BATCH_CHECK_GRACE_SECONDS:-120}" now created age
  now=$(date +%s)
  while IFS='|' read -r lane slot path _ created; do
    [ -n "$lane" ] || continue
    age=$grace
    if [ -n "$created" ]; then
      local epoch
      epoch=$(date -j -f '%Y-%m-%dT%H:%M:%S%z' "$created" +%s 2>/dev/null \
        || date -d "$created" +%s 2>/dev/null || printf '0')
      [ "$epoch" -gt 0 ] && age=$(( now - epoch ))
    fi
    if [ "$age" -ge "$grace" ] && [ "$have_agents" = yes ] \
       && ! printf '%s\n' "$agents" | awk -F'|' -v l="$lane" '$1 == l { f = 1 } END { exit !f }'; then
      printf -- '- lane %s holds slot %s with no agent running; the slot is held for nothing\n' "$lane" "$slot"
      printf -- '    fix: session-lane.sh down %s\n' "$lane"
      rc=1
    fi
    local acwd
    acwd=$(printf '%s\n' "$agents" | awk -F'|' -v l="$lane" '$1 == l { print $3 }')
    if [ -n "$acwd" ] && [ "$acwd" != "$path" ]; then
      printf -- '- lane %s runs in %s but its lane worktree is %s\n' "$lane" "$acwd" "$path"
      rc=1
    fi
  done <<< "$alloc"

  # A lane can arrive by steer before it is briefed, so separate the two cases.
  # "No brief yet" is a different problem from "the record has never heard of it",
  # and reporting the first as the second sends you looking in the wrong place.
  # Every lane the record has ever heard of, whatever state it ended in. A lane
  # recorded done whose agent is deliberately still alive is not drift: on the dcl
  # run the lead finished qa and kept it holding the rig on purpose. Only a child
  # the record has never mentioned is worth reporting.
  local known=""
  known=$(awk -F'|' '$2 == "BRIEF" || $2 == "STATE" || $2 == "BURST" { print $3 }' "$log" | sort -u)
  local steered=""
  steered=$(awk -F'|' '$2 == "STEER" || $2 == "NOTE" { print $3 "\n" $5 }' "$log")
  local aname arole
  while IFS='|' read -r aname _ _ arole; do
    [ -n "$aname" ] || continue
    case "$arole" in ↳*) ;; *) continue ;; esac
    printf '%s\n' "$known" | grep -qx "$aname" && continue
    if printf '%s' "$steered" | grep -qw "$aname"; then
      printf -- '- agent %s is running but has no brief in the record; only a steer mentions it\n' "$aname"
      printf -- '    fix: session-batch.sh brief %s %s --text ...\n' "$batch" "$aname"
    else
      printf -- '- agent %s is running as a child but the record does not know it at all\n' "$aname"
    fi
    rc=1
  done <<< "$agents"

  # A burst is meant to be short. One still running when its agent has gone idle
  # has answered and is now just holding a pane, which is the leak this mode is
  # most prone to, since nothing about it reserves a resource anyone would miss.
  local burst
  while IFS= read -r burst; do
    [ -n "$burst" ] || continue
    if printf '%s\n' "$agents" | awk -F'|' -v b="$burst" '$1 == b && $2 == "idle" { f = 1 } END { exit !f }'; then
      printf -- '- burst %s has answered and is idle; close its pane\n' "$burst"
      rc=1
    fi
  done < <(awk -F'|' '$2 == "BURST" { print $3 }' "$log" | sort -u)

  # Where the claim and the disk disagree. Every rule above this point compares
  # the record against other records. These two compare it against the only two
  # things that cannot be talked into agreeing: git, and whether the agent is
  # actually doing anything. Nothing in this file read git before, and
  # agent_status was read only for bursts, so both of these were invisible.
  #
  # A lane recorded finished over a dirty or unpushed worktree is work about to be
  # cleaned away: session-cleanup.sh refuses to remove such a checkout, so the
  # batch reads finished while the change exists nowhere but this machine.
  #
  # A lane recorded working whose agent is idle is the dcl failure exactly. The
  # child stopped, or asked a question and ended its turn, and recorded nothing.
  # notify_when_idle cannot cover the second case and the record cannot cover
  # either, because the thing that failed is the thing that writes the record.
  local lstate lpath dirty ahead upstream astatus
  while IFS="$(printf '\t')" read -r lane lstate; do
    [ -n "$lane" ] || continue
    lpath=$(printf '%s\n' "$alloc" | awk -F'|' -v l="$lane" '$1 == l { print $3 }')
    case "$lstate" in
      done|failed)
        # No allocation means the lane was already released, and a released lane
        # has no worktree to be dirty. Not drift.
        [ -n "$lpath" ] && [ -d "$lpath" ] || continue
        dirty=$(git -C "$lpath" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        if [ "${dirty:-0}" -gt 0 ]; then
          printf -- '- lane %s is recorded %s but its worktree holds %s uncommitted file(s); cleanup will refuse it and the work stays here\n' \
            "$lane" "$lstate" "$dirty"
          printf -- '    fix: commit or discard in %s, then re-record the state\n' "$lpath"
          rc=1
        fi
        # A detached checkout is a rig, not a branch anybody meant to push. A repo
        # with no remote has nowhere to push, so "never pushed" would be a finding
        # about nothing.
        git -C "$lpath" symbolic-ref -q HEAD >/dev/null 2>&1 || continue
        [ -n "$(git -C "$lpath" remote 2>/dev/null)" ] || continue
        upstream=$(git -C "$lpath" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
        if [ -z "$upstream" ]; then
          printf -- '- lane %s is recorded %s but its branch was never pushed; nothing off this machine has the work\n' \
            "$lane" "$lstate"
          printf -- '    fix: git -C %s push -u origin HEAD\n' "$lpath"
          rc=1
        else
          ahead=$(git -C "$lpath" rev-list --count "$upstream..HEAD" 2>/dev/null || printf '0')
          if [ "${ahead:-0}" -gt 0 ]; then
            printf -- '- lane %s is recorded %s but sits %s commit(s) ahead of %s; the work is local only\n' \
              "$lane" "$lstate" "$ahead" "$upstream"
            printf -- '    fix: git -C %s push\n' "$lpath"
            rc=1
          fi
        fi
        ;;
      working)
        # Only when herdr answered. A missing agent is already reported above, and
        # saying it twice in one run trains the reader to skim.
        [ "$have_agents" = yes ] || continue
        astatus=$(printf '%s\n' "$agents" | awk -F'|' -v l="$lane" '$1 == l { print $2 }')
        # Both halves of stopped. `idle` is the child that ended its turn, `done`
        # is the child herdr saw finish. The first live run of this rule read only
        # `idle` and missed a lane sitting at `done` under a working claim.
        # `blocked` is deliberately absent: the watchdog already pushes a blocked
        # child straight from herdr, and a second voice on it trains the reader to
        # skim the whole report.
        case "$astatus" in
          idle|done)
            printf -- '- lane %s is recorded working but its agent is %s; it stopped or asked a question and recorded nothing\n' \
              "$lane" "$astatus"
            printf -- '    fix: read its pane, then session-batch.sh state %s %s <state> --note "..."\n' "$batch" "$lane"
            rc=1
            ;;
        esac
        ;;
    esac
  done < <(awk -F'|' '
    $2 == "STATE" { split($5, p, " :: "); s[$3] = p[1] }
    END { for (k in s) printf "%s\t%s\n", k, s[k] }' "$log")

  [ "$rc" -eq 0 ] && printf 'batch %s reconciles: every live lane holds a slot and runs where it should\n' "$batch"
  return "$rc"
}

# Name the batch to act on: the one given, else the single open one, else the
# single closed one so a status after a close still shows the outcome.
resolve_batch() {
  local batch="${1:-}"
  if [ -n "$batch" ]; then printf '%s' "$batch"; return 0; fi
  local rc=0
  batch=$(cmd_current) || rc=$?
  if [ "$rc" -eq 1 ]; then
    local logs=() f
    for f in "$(batch_dir)"/*.log; do [ -e "$f" ] && logs+=("$f"); done
    [ "${#logs[@]}" -gt 0 ] || return 1
    [ "${#logs[@]}" -eq 1 ] || { cmd_list >&2; die "no open batch. Name one."; }
    batch=$(basename "${logs[0]}" .log)
  elif [ "$rc" -ne 0 ]; then
    cmd_list >&2; die "several batches open. Name one."
  fi
  printf '%s' "$batch"
}

cmd_status() {
  local batch="" stale=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --stale) stale="${2:-}"; shift 2 ;;
      *) batch="$1"; shift ;;
    esac
  done
  if [ -z "$batch" ]; then
    local rc=0
    batch=$(cmd_current) || rc=$?
    if [ "$rc" -eq 1 ]; then
      # No open batch. Fall back to the only closed one when that is unambiguous,
      # so `status` after a close still shows the outcome.
      local logs=() f
      for f in "$(batch_dir)"/*.log; do [ -e "$f" ] && logs+=("$f"); done
      [ "${#logs[@]}" -gt 0 ] || { printf 'no batches\n'; return 0; }
      [ "${#logs[@]}" -eq 1 ] || { cmd_list; die "no open batch. Name one."; }
      batch=$(basename "${logs[0]}" .log)
    elif [ "$rc" -ne 0 ]; then
      cmd_list; die "several batches open. Name one."
    fi
  fi
  require_batch "$batch"
  render "$batch"
  [ -n "$stale" ] || return 0
  case "$stale" in ''|*[!0-9]*) die "--stale takes minutes as a number" ;; esac
  local mtime age
  mtime=$(file_mtime "$(batch_log "$batch")" || printf 0)
  age=$(( ( $(date +%s) - mtime ) / 60 ))
  if [ "$age" -ge "$stale" ]; then
    printf '\nSTALE: no event for %s minutes, limit %s. The lead may be wedged.\n' "$age" "$stale"
    return 1
  fi
  printf '\nfresh: last event %s minutes ago\n' "$age"
}

cmd_list() {
  local f n found=0
  for f in "$(batch_dir)"/*.log; do
    [ -e "$f" ] || continue
    found=1
    n=$(basename "$f" .log)
    printf '%-20s %s\n' "$n" "$(awk -F'|' '$2=="CLOSE"{c="closed"} $2=="GOAL"{g=$5} END{printf "%s%s", (c?"[closed] ":""), g}' "$f")"
  done
  [ "$found" -eq 1 ] || printf 'no batches\n'
}

[ "$#" -ge 1 ] || usage
cmd="$1"; shift
case "$cmd" in
  open)   cmd_open "$@" ;;
  brief)  cmd_brief "$@" ;;
  state)  cmd_state "$@" ;;
  steer)  cmd_steer "$@" ;;
  note)   cmd_note "$@" ;;
  burst)  cmd_burst "$@" ;;
  current) cmd_current "$@" ;;
  check)  cmd_check "$@" ;;
  status) cmd_status "$@" ;;
  close)  cmd_close "$@" ;;
  list)   cmd_list "$@" ;;
  -h|--help) usage ;;
  *) die "unknown command '$cmd'" ;;
esac
