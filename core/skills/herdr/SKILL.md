---
name: herdr
description: "Control Herdr, a terminal multiplexer for coding agents. Load it before spawning a child agent, handing a distinct workstream to another pane, or running a command in a background pane, and whenever the user mentions Herdr or asks to inspect or control panes, tabs, workspaces, or another agent. Covers the pane and agent CLI, where to place a child agent, stamping a child with its parent, and cleanup. Requires HERDR_ENV=1. Not for deciding whether to split a job across agents or how to brief them."
---

# Herdr

Herdr organizes terminals into workspaces, tabs, and panes, recognizes coding agents running inside panes, and exposes the current session through the `herdr` CLI.

This skill is the mechanics: where a child goes, how to start it, how to read it, how to clean up.
The judgment (whether to split at all, how to brief a child, how to verify what it returns) lives
in whatever orchestration guidance your layer ships. Load both when you are actually spawning.

Before issuing any control command, verify that this agent is running inside a Herdr-managed pane:

```bash
test "${HERDR_ENV:-}" = 1
```

If the check fails, say that you are not running inside Herdr and stop. Do not inspect or control the focused Herdr session from outside Herdr.

When the check passes, the `herdr` binary in `PATH` talks to the current session. Use it to inspect neighboring work, create terminal layout, start agents and commands, read output, and wait for state changes.

## Learn the current CLI

The installed binary is the authority for command syntax. Start with:

```bash
herdr --help
```

Then print the relevant command group by running the group without a subcommand:

```bash
herdr agent
herdr pane
herdr workspace
herdr tab
herdr worktree
herdr terminal
herdr notification
herdr integration
herdr session
```

Do not run bare `herdr` for discovery; it launches or attaches the TUI. Do not probe a mutating nested command by omitting arguments. Commands such as `herdr workspace create` are valid with defaults and will execute.

Most control commands return JSON. Read identifiers and state from those responses instead of predicting them.

## Understand layout, panes, and agents

Choose the primitive that matches the job:

- Workspace, tab, and pane topology organize terminal locations.
- Pane commands control raw terminals, shells, tests, servers, input, and output.
- Agent commands control the recognized coding agent currently occupying a pane.

A pane exists whether or not it contains an agent. `agent start` requires an existing available shell pane and never creates, splits, or moves layout. Use pane commands for ordinary processes. Use agent commands when Herdr must validate agent identity or interpret `idle`, `working`, `blocked`, `done`, and `unknown` lifecycle states.

Agent commands accept either a unique live agent name or the pane ID currently hosting that agent. They do not accept terminal IDs or bare agent-kind labels. Names must match `[a-z][a-z0-9_-]{0,31}` and be unique among live agents. A name follows the current pane occupant and is cleared when that agent exits, is released, or is replaced.

`idle` means the agent is ready for input and its tab has been seen in the focused Herdr UI. `done` is the same underlying idle state after unseen background work finishes. Focusing the tab or targeting the pane or agent with a focus command marks it seen. CLI reads do not mark it seen. `blocked` means Herdr recognized an approval or question UI. `unknown` means an agent is present but Herdr cannot classify it confidently; it does not prove completion.

## Use IDs and caller context

Public IDs are opaque stable handles:

- workspace: `w1`
- tab: `w1:t1`
- pane: `w1:p1`

Closed tab and pane IDs are not reused. A pane moved into another workspace receives a new workspace-qualified pane ID. After `pane move`, continue with `.result.move_result.pane.pane_id` or the live agent name. The old value is reported as `.result.move_result.previous_pane_id`; only the moved process's inherited caller context keeps resolving that old ID, so do not use it as a general agent target.

Herdr injects the caller's context into each managed pane:

```bash
printf '%s\n' "$HERDR_WORKSPACE_ID" "$HERDR_TAB_ID" "$HERDR_PANE_ID"
```

Prefer `--current` when a pane command should target the calling pane. Omitting a target may use the UI-focused pane, which can belong to the user or another client.

Discover live state with:

```bash
herdr workspace list
herdr tab list --workspace "$HERDR_WORKSPACE_ID"
herdr pane current --current
herdr pane list --workspace "$HERDR_WORKSPACE_ID"
herdr agent list
```

Creation responses expose the IDs to use next. `workspace create` returns `.result.workspace`, `.result.tab`, and `.result.root_pane`. `tab create` returns `.result.tab` and `.result.root_pane`. `pane split` returns the new pane as `.result.pane`.

## Start and coordinate an agent

### Never put a child agent in your own tab

The calling agent's tab stays the calling agent's tab. The user needs to know at a glance which
pane is the one they talk to, and that is only true if the main agent sits alone in its tab.

So spawn every child into **one dedicated sibling tab**, created once per delegation and shared by
every child in that batch:

```bash
# Once per batch. Read .result.tab.tab_id and .result.root_pane.pane_id from the response.
herdr tab create --workspace "$HERDR_WORKSPACE_ID" --label "reviewers" --cwd "$PWD" --no-focus \
  --env HERDR_PARENT_PANE="$HERDR_PANE_ID"
```

Then place the children:

- **The first child goes in that tab's root pane.** `tab create` already gave you an empty shell
  pane; splitting before using it wastes it and leaves a stray shell.
- **Each additional child is a split inside that tab**, never a split of your own pane.

```bash
herdr pane split <child-tab-root-pane> --direction right --cwd <that child's worktree> --no-focus \
  --env HERDR_PARENT_PANE="$HERDR_PANE_ID"
```

**`--cwd` is the child's own worktree, never the lead's `$PWD`.** Starting every child in the lead's
directory puts two writers in one checkout, which is the failure the worktree was there to prevent.
The harness lane script (`core/scripts/session-lane.sh up <lane> --repo <path>`, when your clone
installs it) reserves that worktree and prints the exact line. Use `--branch <existing>` when the
work is already on a branch, and `--adopt <path>` when the checkout already exists.
`herdr worktree create` reserves no ports, so a lane made that way collides on the default stack.

Label the tab for what the batch is doing, not what it is. `reviewers` or `docs-lanes` tells the
user something; `agents` does not. One batch, one tab, one label.

Name the pane too, not only the tab. Herdr draws a label in each split pane border when
`show_agent_labels_on_pane_borders` is on. An agent pane shows the name you passed to
`herdr agent start`, so a child named by the `-- --name` rule labels itself. A plain shell or
command pane shows nothing until you name it, so name it in the same step that creates it:

```bash
herdr pane rename <pane-id> <name>
```

Use the lane name, so the pane name, the worktree name and the branch name stay one word. A manual
name wins over the detected agent label and survives the agent going idle or exiting.
`herdr pane rename <pane-id> --clear` returns the border to the detected label.

Register the tab as soon as you create it:

```bash
"$HARNESS_HOME/core/scripts/session-artifact.sh" add tab <returned-tab-id>
```

That is what lets the close remove the tab even after every child in it has exited. The children
themselves need nothing: the `HERDR_PARENT_PANE` stamp below is how the close finds them. Skip
this step if your clone does not install the session scripts; nothing else here depends on them.

Never pass `--focus`. The user's focus stays where they put it.

### Always stamp the child with its parent

Every pane you create for a child agent carries `--env HERDR_PARENT_PANE="$HERDR_PANE_ID"`. The
child's SessionStart hook reads that variable and marks itself in the agent sidebar with an arrow
plus the parent's pane suffix, such as `↳p5`, so the user can see at a glance which agents they own
and which ones another agent spawned. The suffix carries the weight here: the own-tab rule above
keeps a child out of its parent's tab, and the sidebar sorts by attention rather than lineage, so a
bare arrow would never sit under the row it belongs to. A pane created without the variable reads
as a lead agent, which is wrong for a child and sends the user to the wrong pane. This is display-only: it changes no routing and no permissions. It also
feeds the parent's own row: while a stamped child is working or blocked, a parent that has finished
reads `waiting on 2` instead of `done`, so the user can tell a free parent from a held one.

A command pane is not a child agent, so it does not take the variable.

### Keep the panes readable, or do not rely on them

Splitting is not free. Each split halves a dimension, so a tab of six panes on a normal window
gives each agent roughly twenty columns, and at that width agent output wraps to a few characters
per line and becomes unreadable through `agent read`.

Two rules follow:

- **Alternate the split direction** as you add panes. Split a wide pane right and a narrow or tall
  pane down. Repeated same-direction splits produce unusable slivers. Check with
  `herdr pane layout --pane <id>` when unsure.
- **Past about four children, stop treating the pane as the output channel.** Ask each child to
  write its final response to a file and reply with only the path, then read the file. Do this by
  design at that size rather than discovering it after a wait, and see the alternate-screen note
  under `pane read` for the same fallback.

### Then start the agent

An available shell pane must be at its interactive prompt, with the shell itself in the foreground
and no foreground command, editor, or agent running. Start a supported agent in that pane with a
useful unique name. Names must match `[a-z][a-z0-9_-]{0,31}`, so pass the name as a single argument
and never let a shell loop expand two words into it:

```bash
herdr agent start reviewer --kind codex --pane <returned-pane-id>
```

Use the kind requested by the user. Run `herdr agent` to inspect the installed kind list and options. Pass native agent arguments only after `--`:

```bash
herdr agent start reviewer --kind codex --pane <returned-pane-id> -- <agent-args...>
```

**Give a Claude child the same name in both systems.** Pass the name again as a native argument:

```bash
herdr agent start reviewer --kind claude --pane <returned-pane-id> -- --name reviewer
```

A Claude child binds its own cross-session inbox, and it answers to the name Claude Code holds for
it, not the name Herdr holds. Without the trailing `-- --name`, Claude Code assigns its own name such
as `claude-ac`, the two namespaces drift, and every message needs a lookup first. With it, one string
addresses the child through `herdr agent` and through `SendMessage`.

A successful `agent start` returns only after Herdr detects the expected agent in the same pane and considers it ready for interactive input. If the agent is blocked during startup, the command returns `agent_not_ready` immediately but keeps the name available for `agent read` and `agent send-keys`. Wait until the agent becomes idle before prompting it. Startup defaults to a 30-second timeout.

Submit work through the agent surface:

```bash
herdr agent prompt reviewer "Review the current diff and report only actionable findings." --wait --timeout 120000
```

`agent prompt` honors the pane's live bracketed-paste mode and sends text followed by encoded Enter after a short delay. It rejects an agent already waiting at an approval or question dialog with `agent_blocked` before sending any input. Inspect the blocked UI and ask the user before answering it. For normal agent work, `--wait` is enough: it waits for the first settled `idle`, `done`, or `blocked` state. Do not repeat those defaults with `--until`.

A prompt sent from a non-working state must produce an observed lifecycle change within five seconds. Otherwise Herdr returns `agent_prompt_stalled` instead of waiting indefinitely. This wait tracks lifecycle state, not an individual turn; if the agent is already working, completion of the active turn may satisfy it.

### Do not block the pane the user talks to

`--wait` holds the calling agent until the child settles. In a lead pane that is the pane the user
steers from, so a long `--wait` takes their agent away for the length of the child's work. Use
`--wait` for a first kickoff that answers immediately, and for nothing else.

For a Claude child started with the `-- --name` rule above, coordinate by message instead:

- `SendMessage` to instruct the child or answer something it is blocked on. Delivery is pushed, and
  the lead keeps its turn.
- `SendMessage` with `notify_when_idle` to be told once when the child next goes idle. Omit the
  message text for a pure subscription that costs the child nothing.
- Never poll. No `agent get` loop, no `ListAgents` loop, no "are you done" messages.

`agent read` stays the right tool for inspecting a child that is stuck or blocked, and for reading a
non-Claude child that has no inbox.

Use `--until` only for a state-specific workflow, such as waiting for an already-running agent to request input:

```bash
herdr agent wait reviewer --until blocked --timeout 120000
```

Without `--until`, standalone `agent wait` uses the same settled-state defaults as `agent prompt --wait`.

Use logical keys for interactive agent UI controls:

```bash
herdr agent send-keys reviewer esc
herdr agent send-keys reviewer ctrl+c
```

Herdr validates all keys before writing any bytes. Read the result through the resolved agent:

```bash
herdr agent get reviewer
herdr agent read reviewer --source recent-unwrapped --lines 120
```

If a wait fails or returns `blocked`, inspect `agent get` and `agent read` before deciding what input to send. Use the pane surface only when raw terminal control is intentional.

## Run an ordinary command in another pane

A command is not a child agent, and the own-tab rule does not apply to it. A build, a test run, or
a log tail is short-lived and is more useful beside you than in a separate tab, so splitting your
own pane is correct here. Close the pane when the command has served its purpose.

Create a sibling pane with the same geometry rule, preserve the caller's working directory, and keep user focus unchanged:

```bash
herdr pane split --current --direction right --cwd "$PWD" --no-focus
```

Read the new pane ID from `.result.pane.pane_id`, then run and inspect the command:

```bash
herdr pane run <returned-pane-id> "just test"
herdr pane wait-output <returned-pane-id> --match "test result" --timeout 120000
herdr pane read <returned-pane-id> --source recent-unwrapped --lines 120
```

`pane run` atomically sends command text and Enter. `pane wait-output` searches the selected snapshot immediately, so output that already exists can match. Use `--match <text>` for a literal substring or `--regex <pattern>` for a Rust regular expression. Omitting `--timeout` allows an indefinite wait.

Use the read source that matches the task:

- `visible`: the currently rendered viewport.
- `recent`: recent rendered output, including soft wraps.
- `recent-unwrapped`: recent output with soft wraps joined; prefer it for logs and transcripts.
- `detection`: the plain-text bottom-buffer snapshot used for agent detection.

Use `--format ansi` when colors and terminal styling are evidence. Otherwise use text.

`--lines` asks Herdr for more rows from the pane's available screen and host scrollback. If increasing it does not reveal more of a completed response, the pane is probably running the agent on the terminal's alternate screen. Rows that leave the alternate screen do not enter Herdr's host scrollback, so a larger line count cannot recover them.

After that failed read, ask the agent to write its complete response as Markdown in a temporary directory and reply only with the file path, then read the file directly. Keep this a fallback for a single agent whose output you could not recover. The exception is a batch large enough that pane width alone makes reading impossible, where you ask for file output up front instead of discovering the problem after the wait.

## Clean up when the work is done

A delegation is not finished until the topology it created is gone. Leftover panes crowd the
session, and a stale agent pane is worse than no pane because it looks live.

Release each child when that child is finished, not when the batch is. Closing one pane leaves the
tab and every sibling running, including when the pane closed is the tab's root, and a tab retires
itself once its last pane closes. There is no emptied tab to sweep up.

```bash
herdr pane close <child-pane-id>
```

Use a whole-tab close only when every child in that tab is finished at the same time:

```bash
herdr tab close <child-tab-id>
```

That closes the tab and every pane in it, so it is wrong while any sibling is still working.

Sequence it properly:

1. **Collect what you need first.** Once the tab is closed the panes and their scrollback are gone,
   and closed tab and pane IDs are never reused. Read every child's output, or have them write to
   files, before closing anything.
2. **Confirm each child is finished**, not merely quiet. Check `herdr agent get <name>` per child.
   `idle` and `done` are finished. `working` is not, and `unknown` does not prove completion. A
   child sitting at `blocked` is waiting on an approval or a question: inspect it and ask the user
   rather than closing over it.
3. **Close the tab.**
4. **Verify.** `herdr pane list --workspace "$HERDR_WORKSPACE_ID"` should show your own pane and
   nothing you created.

Clean up other resources you created in the same pass. A worktree is the one that leaks, because
nothing in git or Herdr records which session created which checkout. So register it at creation:

```bash
"$HARNESS_HOME/core/scripts/session-artifact.sh" add worktree <path>
"$HARNESS_HOME/core/scripts/session-artifact.sh" add workspace <workspace-id>
```

Then the close removes it for you. `core/scripts/session-cleanup.sh` runs inside
`session-wrap.sh` and does everything in this section: closes your finished children, closes a tab
that holds only them, removes registered worktrees and workspaces, and prunes worktree records
whose checkout is gone. Run it yourself as a dry run when you want the plan without the removals:

```bash
"$HARNESS_HOME/core/scripts/session-cleanup.sh"
```

It never removes a worktree that is dirty, unpushed, or has a live agent in it. Those are kept and
reported with a `herdr worktree open` command, so the work resumes rather than disappearing. Doing
the cleanup by hand is still correct; doing it by hand and forgetting is what the registry prevents.

Two limits on this:

- **Only what you created.** Never close a tab, pane, or workspace you did not create unless the
  user explicitly asks. Another client may own it.
- **Never your own pane**, and never the workspace you are running in.

Interrupting a child is `herdr agent send-keys <name> escape`, which returns it to idle without
closing it. Reach for that before a close when a child is stuck, since a closed pane cannot be
inspected afterwards.

## Safety and coordination rules

- Use `--no-focus` for background work unless the user asked to switch context.
- Use `--current`, an explicit pane ID, or a unique agent name. Do not rely on another client's focused pane.
- Parse IDs from JSON responses. Do not derive them from sidebar order or examples.
- Do not close workspaces, tabs, panes, or sessions you did not create unless the user explicitly asked.
- Child agents go in their own tab. Never split your own pane to host one, and never leave a batch's tab behind once the work is collected.
- Never run `herdr server stop` from an active session unless the user explicitly intends to stop the server and its pane processes.
- Never kill the main Herdr process. Use named test sessions for experiments that need an isolated server.
- CLI server errors are JSON on stderr with exit status 1. CLI syntax errors exit with status 2.
