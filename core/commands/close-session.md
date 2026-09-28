---
description: Close the session (record facts, wrap, commit)
---

Two steps. Both use the harness session scripts under `$HARNESS_HOME/core/scripts`. Resolve
`HARNESS_HOME` with `python3 <clone>/core/lib/harness_config.py HARNESS_HOME`. If those scripts are
not installed in this clone, there is no close to run.

**1. Record anything durable you have not already recorded.** One call per fact:

```bash
"$HARNESS_HOME/core/scripts/session-note.sh" -k DONE -t T-812 "abc1234 parser handles empty tier"
"$HARNESS_HOME/core/scripts/session-note.sh" -k BLOCKED "waiting on the cutover date"
```

**2. Wrap.** Cleans up what the session created, finalizes the journal, gzip-archives the raw transcript beside it, then takes the close lock and stages, commits and pushes only this session's files:

```bash
"$HARNESS_HOME/core/scripts/session-wrap.sh" --summary "<one or two sentences>" [extra paths...]
```

Pass any other file this session touched as a trailing argument. The journal, the transcript archive and the ledger are staged automatically.

Then reply with a short summary of what was done, and name anything the cleanup kept.

**Cleanup is part of the wrap, not a separate ritual.** `session-wrap.sh` calls `session-cleanup.sh --record --apply`, which:

- closes child agent panes stamped with this pane as their parent, and closes the whole tab when it holds nothing else
- removes worktrees registered with `session-artifact.sh`, and closes registered workspaces
- prunes worktree records whose checkout is already gone

It removes a worktree only when it is clean, pushed and holds no live agent, and it closes a child only when that child is `idle` or `done`. Anything else is kept, written into the journal with the command to resume it, and given a `NOTE` line in the ledger. A cleanup that can destroy work is not cleanup.

To see the plan before it runs, run it as a dry run first. It changes nothing without `--apply`:

```bash
"$HARNESS_HOME/core/scripts/session-cleanup.sh"
```

If a child is still `working` or `blocked`, deal with it before wrapping. Read its output, or interrupt it with `herdr agent send-keys <name> escape`. Do not close over it.

**Register as you create, not at close.** A worktree, a batch tab or a workspace this session creates gets one line at creation:

```bash
"$HARNESS_HOME/core/scripts/session-artifact.sh" add worktree ~/worktrees/<repo>/<lane>
```

Nothing else on the machine records which session created which checkout. An unregistered worktree is left behind, every time. Child panes stamped with `HERDR_PARENT_PANE` need no registration; the close finds those from the Herdr sidebar.

**That is the close.** No project-doc sweep, no verification checklist, no self-assessment, no session-number stub, no conversation log.

**An open-items file is not a close step.** Update a project's open items when you change what is open on it, during the work, not as a closing ritual. Delete the lines for things now closed rather than striking them through; that accretion is what makes a state file unreadable. If you never touched a project's open items, leave its file alone.

**Notes**

- If the session dies before step 2, the `SessionEnd` hook runs `session-wrap.sh --auto`. It writes the closing block, archives the transcript and puts a line in the ledger saying nobody summarized this one. It never runs git, and its cleanup pass reports rather than removes: nobody is watching an unattended exit. The registry survives, so the next session in that pane finishes the job. An abandoned session still leaves a record, just a worse one.
- `--no-cleanup` wraps without touching panes or worktrees. Use it when the session's resources are deliberately staying up, and say so in the summary.
- The lock is held only across stage, commit and push. It is needed because the git index is shared repository state: a scoped `git add` does not stop another session's staged files being swept into your commit.
- Never `git add -A`, never `git push --force`, never `git reset --hard`, never `git checkout -- .`.
