# Optional editor and terminal configuration

Three integrations the harness works well with and does not need. `install.sh`
does not link any of them, and nothing under `core/scripts` or `core/hooks`
fails when they are absent: an absent optional binary is never an error.

## Table of Contents

- [What is here](#what-is-here)
- [Installing one](#installing-one)
- [What was stripped](#what-was-stripped)

---

## What is here

| Directory | Tool | What it gives the harness |
|---|---|---|
| `wezterm/` | [WezTerm](https://wezterm.org) | Terminal window, font and theme. It deliberately binds no split or pane keys, so it never fights the multiplexer for a keystroke |
| `herdr/` | Herdr | Pane, tab and workspace bindings, plus the agent sidebar rows that make a child agent's state and lineage readable at a glance |
| `nvim/` | Neovim | Editor with a Python setup whose ruff and mypy rules match the ones the harness lint hook enforces, so the editor and the hook agree |

The lane scripts read `HERDR_ENV`, `HERDR_PANE_ID` and `HERDR_BIN_PATH` when a
multiplexer sets them, and fall back to a working-directory token when nothing
does. A session outside a multiplexer still gets a journal, a ledger and a
cleanup pass.

## Installing one

Each is a whole-directory link, not a per-file one, because each tool loads
files the directory grows over time.

```sh
ln -s "$PWD/core/config/wezterm" ~/.config/wezterm
ln -s "$PWD/core/config/herdr"   ~/.config/herdr
ln -s "$PWD/core/config/nvim"    ~/.config/nvim
```

Run each from the clone root, and move anything already at the destination out
of the way first. Neovim writes `lazy-lock.json` into its own directory on the
first start, which pins plugin versions per machine; it is not tracked here.

## What was stripped

Every absolute path and every machine-specific value, because the whole point
of the clone is that it works for a second person.

- The Herdr popup bindings for the sticky-prompt viewer and the batch emergency
  stop are commented out. Herdr does not expand a variable inside a `command`
  value, so the working version needs a real path on a real machine, which is
  the one thing this repository may not store. Both are two lines from working:
  uncomment the block and replace `<HARNESS_HOME>` with your clone path.
- Herdr's runtime state, which lives in the same directory when `~/.config/herdr`
  is a link into a checkout: `session.json`, `.plugins.lock`, `release-notes.json`,
  the client and server logs, and two live unix sockets. None of it is
  configuration, and a live server socket inside a git checkout is a hazard
  rather than a file to track.
- Neovim's `lazy-lock.json`, for the reason above.
