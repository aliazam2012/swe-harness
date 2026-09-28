# Contributing

Two rules decide almost every question here. Everything else follows from them.

1. **Core is publishable.** Nothing under `core/` may name a company, a customer, a person, a host
   or an absolute path. If it would embarrass anyone were the repository made public tomorrow, it
   belongs in a layer.
2. **Core never reads a layer.** A layer imports from core. The reverse fails the build.

`core/CONTRACT.md` is the full interface. Read it before changing anything under `core/lib`.

## Table of Contents

- [Before you push](#before-you-push)
- [Where does my change go](#where-does-my-change-go)
- [Adding a hook](#adding-a-hook)
- [The dependency floor](#the-dependency-floor)
- [Tests](#tests)
- [Versioning](#versioning)
- [Secrets](#secrets)

## Before you push

```bash
core/tests/run.sh
core/tests/test-core-purity.py
shellcheck --severity=warning --exclude=SC1091 $(find . -name '*.sh' -not -path './.git/*')
```

CI runs all three, plus a fresh-clone install on macOS and Linux against python 3.9 and 3.13. Run
them locally first; they take under two minutes and CI is not a search tool.

## Where does my change go

| The change | Where |
|---|---|
| Works for any engineer anywhere | `core/` |
| Names a company, customer, ticket system, chat channel or internal host | `layers/<org>/` |
| A generic base with a company-specific addition | Both: base in `core/`, overlay in the layer |
| Only you need it | Your own layer, not this repository |

When you are unsure, put it in a layer. Moving something from a layer into core later is easy.
Taking a company name out of core after it has been published is not.

## Adding a hook

Write the script, then add an entry to the owning unit's `registry.json`. Never write an absolute
path: use `runner` plus a `script` path relative to that unit's root. The installer resolves both at
install time, and `core/lib/layers.py` rejects a stored path rather than trusting it.

A hook must exit 0 and do nothing when an optional dependency is missing. Someone running this in a
plain terminal with no multiplexer must see no error.

## The dependency floor

`bash`, `git`, and python 3.9 with its standard library. Nothing else, ever, in `core/`.

That floor is why the manifests are JSON rather than YAML or TOML: python 3.9 ships neither parser,
and requiring one would mean a package install before the installer could run. Test with
`/usr/bin/python3` on macOS, which is 3.9, not with whatever your shell resolves.

A layer may require more. It declares each binary in `layer.json`, and the installer checks them.

## Tests

`core/tests/run.sh` gives every file a fresh temporary `HOME`, `HARNESS_WORKSPACE` and `TMPDIR`. Do
not rely on that alone: a test that would damage a real home directory if the sandbox failed is a
badly written test.

Assert behaviour, not execution. A test that only proves a script exits 0 has not tested it.

## Versioning

`core/VERSION` is semver. A layer declares the range it needs as `requires.core`. Raise the minor
when core gains something a layer can use, and the major when you change or remove anything a layer
depends on: the registry schema, a `core/lib` function signature, a declared configuration key, or
the contract itself.

## Secrets

Never commit one. Configuration keys hold paths, hosts and identifiers; a secret belongs in a secret
manager and the key should name where to find it. The installer refuses to write a value matching a
credential pattern, but that is a backstop, not permission to try.

If you commit one by accident, say so immediately and rotate it. Removing the commit is not enough,
because it is already in every clone and in the remote's history.
