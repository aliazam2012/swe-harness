# Layer Contract

The core is a working agent harness on its own. A layer adds business logic on top of it without
editing a single core file. This document is the interface between the two. Core owns it; a layer
consumes it.

## Table of Contents

- [Rules](#rules)
- [Anatomy of a layer](#anatomy-of-a-layer)
- [layer.yml](#layeryml)
- [The hook registry](#the-hook-registry)
- [Configuration keys](#configuration-keys)
- [What core guarantees](#what-core-guarantees)
- [What a layer must not do](#what-a-layer-must-not-do)

---

## Rules

Three, and CI enforces all three.

1. **Core never names a layer.** No file under `core/` may contain a customer name, an internal
   hostname, a real email address, an absolute path under `/Users/` or `/home/`, or the name of any
   private repository. `core/tests/test-core-purity.sh` is the gate.
2. **A layer may read core. Core may not read a layer.** A layer imports from `core/lib`. The
   reverse fails the build.
3. **No environment-specific literal anywhere.** Every value that differs between two people is a
   configuration key, declared by whoever needs it and supplied at install time.

---

## Anatomy of a layer

```
layers/<name>/
  layer.json        required. identity, requirements, config keys
  registry.json     optional. hook entries this layer adds
  hooks/            optional. the scripts those entries name
  skills/           optional. one directory per skill, each with SKILL.md
  agents/           optional. one .md per subagent
  commands/         optional. one .md per slash command
  standards/        optional. reference documents the skills point at
  scripts/          optional. executables added to the harness PATH
  README.md         recommended
```

Every directory is optional except `layer.yml`. A layer that ships only skills is a valid layer.

---

## layer.json

JSON, not YAML or TOML. The floor is python 3.9 with its standard library only, which has a JSON
parser and neither of the others. That constraint is the reason a team member needs nothing
installed.

```json
{
  "name": "acme",
  "description": "One line.",
  "requires": {
    "core": ">=1.0",
    "binaries": ["git"],
    "optional_binaries": ["herdr", "nvim"]
  },
  "config": [
    {
      "key": "NOTES_ROOT",
      "description": "Absolute path to the notes repository.",
      "required": true
    },
    {
      "key": "TRACKER_PROJECT_KEY",
      "description": "Default project key for ticket creation.",
      "required": false,
      "default": ""
    }
  ]
}
```

The example names a fictional organisation on purpose. Core is held to its own gate, so a real
company name here would fail the build the moment that company adds itself to a denylist.

`install.sh` reads every selected layer's `layer.json`, unions the requirements, checks the binaries
once, and resolves the configuration before it writes anything.

---

## The hook registry

Core and each layer may ship a `registry.json`. The installer merges them in selection order and
generates `~/.claude/settings.json` from the result. **A registry never contains an absolute path.**

```json
{
  "version": 1,
  "hooks": [
    {
      "id": "done-gate",
      "description": "Blocks a turn that used a tool and carries no evidence footer.",
      "event": "Stop",
      "matcher": null,
      "runner": "python3",
      "script": "hooks/stop-done-gate.py",
      "timeout": 10,
      "profiles": ["standard", "strict"],
      "mandatory": false
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `id` | Unique across every selected layer. A layer that reuses a core id overrides it, and the installer reports the override |
| `event` | `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PreCompact`, `Stop`, `SessionEnd` |
| `matcher` | Tool-name regex, or `null` for events that take none |
| `runner` | `python3` or `bash`. The installer resolves the interpreter on this machine |
| `script` | Path relative to the owning unit's root. Never absolute |
| `profiles` | Which of `minimal`, `standard`, `strict` include this hook |
| `mandatory` | A profile or a `--disable` flag cannot drop it |

The installer resolves `runner` plus `script` into an absolute command at write time. This is the
single reason a clone works on someone else's machine, so nothing may reintroduce a stored path.

---

## Configuration keys

Core declares these. A layer may add its own and must declare each one it reads.

| Key | Default | Meaning |
|---|---|---|
| `HARNESS_HOME` | the clone directory | Resolved, never set by hand |
| `HARNESS_WORKSPACE` | `~/.swe-harness` | Where session journals, lane records and batch state are written |
| `HARNESS_PROFILE` | `standard` | Which hook profile to install |
| `HARNESS_EDITOR` | `$EDITOR`, else `vi` | Editor the scripts open |

Resolution order, first hit wins: an environment variable, then `harness.config.json` in the clone,
then the key's default. A required key with no value aborts the install and names the key.

A hook or script reads a key through `core/lib/harness_config.py` or `core/lib/harness-config.sh`.
Reading an environment variable directly is how a default gets bypassed and is a review failure.

---

## What core guarantees

- **No dependency beyond bash 3.2, git, and python 3.9 with its standard library.** That is what
  macOS ships. No package install, no network access, no Homebrew, no Nix. Anything else is
  optional and degrades.
- **An absent optional binary is never an error.** A hook that wants Herdr and does not find it
  exits 0 and does nothing.
- **Nothing outside `~/.claude` and `HARNESS_WORKSPACE` is written**, and every replaced file is
  backed up first.
- **Uninstall is one command** and restores what was there before.

---

## What a layer must not do

- Edit any file under `core/`. A layer that needs a core change asks for one.
- Write an absolute path into a registry.
- Assume another layer is installed. Two layers that need each other are one layer.
- Ship a credential. The installer refuses to write a value that matches a credential pattern.
