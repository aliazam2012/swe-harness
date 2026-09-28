# Example layer

Copy this directory, rename it, and change `name` in `layer.json` to match the new directory name.
That is the whole setup. Install it with:

```bash
./install.sh --layers <your-layer> --write
```

## What you can add

| Directory | What goes in it |
|---|---|
| `hooks/` | Scripts, named by a `registry.json` entry |
| `skills/` | One directory per skill, each holding a `SKILL.md` |
| `agents/` | One `.md` per subagent |
| `commands/` | One `.md` per slash command |
| `standards/` | Reference documents your skills point at |
| `scripts/` | Executables your team runs by hand |

Everything is optional except `layer.json`.

## Adding a hook

Write the script under `hooks/`, then add a `registry.json` beside `layer.json`:

```json
{
  "version": 1,
  "hooks": [
    {
      "id": "my-gate",
      "description": "One line saying what it blocks and why.",
      "event": "Stop",
      "matcher": null,
      "runner": "python3",
      "script": "hooks/my-gate.py",
      "timeout": 10,
      "profiles": ["standard", "strict"]
    }
  ]
}
```

Never write an absolute path into `script`. The installer resolves it against this layer's directory
and against the interpreter on the machine doing the install. That is the only reason a clone works
on someone else's laptop, so the loader rejects a stored path rather than trusting it.

## Reading configuration

Declare every key your layer reads in `layer.json`, then read it through core:

```python
import sys
sys.path.insert(0, os.path.join(os.environ["HARNESS_HOME"], "core", "lib"))
import harness_config

root = harness_config.require("MY_KEY")
```

Reading `os.environ` directly bypasses the default and the config file, and is a review failure.

## Rules you inherit

Read `core/CONTRACT.md`. The three that matter: a layer may read core and core may never read a
layer; every environment-specific value is a declared key, not a literal; and your layer must not
edit anything under `core/`.
