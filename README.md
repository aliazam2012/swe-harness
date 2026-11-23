# swe-harness

A harness for Claude Code and Codex that installs in one command and works on any machine. No dependency on
any company: `core/` names nobody, and a test enforces that before it ships.

```bash
git clone <this repo> && cd swe-harness
./install.sh --write
```

That's it. No packages to install beyond `bash`, `git` and the python 3.9 that macOS already
ships. `./install.sh` on its own is a dry run: it prints the full plan and changes nothing until
you add `--write`.

## Table of Contents

- [5 ways this makes your agents smarter](#5-ways-this-makes-your-agents-smarter)
- [Layout](#layout)
- [Codex](#codex)
- [Writing your own layer](#writing-your-own-layer)
- [Requirements](#requirements)
- [Tests](#tests)
- [Uninstall](#uninstall)
- [License](#license)

## 5 ways this makes your agents smarter

1. **It stops the agent before a bad edit lands, not after.** Guards on every tool call block a
   force-push, a `chmod 777`, a weakened linter config, or an edit outside the working directory
   before it happens, instead of catching it in review.
2. **It knows when a session is actually done.** A Stop hook audits the reply against the
   original request before the agent hands back: every claim has to point at a file, a command,
   or a log, and every unresolved part has to be named, not dropped.
3. **It never lets a session vanish without a trace.** Every session gets a journal entry, and if
   one dies mid-task, the next session in that pane picks up exactly where it left off instead of
   starting cold.
4. **It carries real procedure, not just prompts.** Sixteen skills ship in `core/skills/` for the
   judgment calls that come up in almost any codebase: root-causing a bug instead of patching the
   symptom, writing a commit message, handling API retries and rate limits, naming files, keeping
   regex free of ReDoS.
5. **It keeps your rules yours.** Everything specific to how you work, your ticket system, your
   review channel, your customers, lives in a separate layer that never gets published with core.
   Copy `layers/example/`, write your own, and core stays clean underneath it.

## Layout

```
install.sh                 one entry point, dry run by default
core/
  hooks/                   the guards, gates and session lifecycle
  skills/                  procedure the agent reaches for on its own
  agents/ commands/        a subagent and two slash commands
  scripts/                 session, lane and pane tooling
  tests/                   the suite, and the purity gate that keeps core clean
layers/
  example/                 copy this to add your own rules on top
```

## Codex

`./install.sh --codex --write` also installs into Codex CLI, next to Claude Code; `--codex-only` installs into Codex and leaves Claude Code's settings exactly as they are:

- **Skills** are linked into `~/.agents/skills`, where Codex finds them (same `SKILL.md` format).
- **Hooks** are merged into `~/.codex/hooks.json` (or `$CODEX_HOME/hooks.json`). Entries you or other tools put there stay as they are; uninstall removes only the harness's own.
- **What runs on Codex:** the session-start context, the shell guards (such as the `--no-verify` block), the config-file protection, and the Python lint on every edited `.py` file. Codex reports each file edit as one `apply_patch` call, so `core/hooks/codex_patch.py` splits the patch into one call per file and the same guards judge each.
- **What does not, yet:** the done gate and the session lifecycle hooks. They read the conversation transcript, and Codex documents its transcript format as unstable.

Codex asks you to trust new hooks the first time it sees them.

## Writing your own layer

```bash
cp -R layers/example layers/mine
$EDITOR layers/mine/layer.json     # set "name": "mine"
./install.sh --layers mine --write
```

A layer contributes hooks, skills, subagents, commands and standards, and declares whatever
configuration it needs. `core/CONTRACT.md` is the full interface.

## Requirements

`bash`, `git`, python 3.9 or newer. Nothing else, ever, in `core/`.

## Tests

```bash
core/tests/test-core-purity.py   # the release gate: fails on a company name or an absolute path
core/tests/run.sh                # everything
```

## Uninstall

```bash
./install.sh --uninstall --write
```

## License

MIT, see [LICENSE](LICENSE).

Removes only what the installer's own manifest recorded, and restores your original
`settings.json`.
