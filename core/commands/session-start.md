---
description: Show live session state (optional; there is no start ritual)
---

There is no start ritual. `~/.claude/CLAUDE.md` already carries how to record and how to find things, and a `SessionStart` hook has already created this session's journal. You do not need to run anything to begin work.

This command exists only for when you want the live state: session ID, cwd and git, where notes land, sibling panes, write guard.

```bash
"$HARNESS_HOME/core/scripts/session-card.sh"
```

`HARNESS_HOME` is the harness clone. Resolve it with `python3 <clone>/core/lib/harness_config.py HARNESS_HOME`, or read it from the hook command lines in `~/.claude/settings.json`. If the script is not there, this clone was installed without the session scripts and there is nothing to show.

Do not load a project overview, a state file or a runbook index because of this command. Load detail on demand, only when a task needs it.
