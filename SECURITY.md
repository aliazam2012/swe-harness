# Security

## Reporting

This is a personal repository. Report a vulnerability privately to its owner rather than opening an
issue, and do not include a working exploit or a real credential in the report.

## What this repository does to your machine

The installer writes in exactly two places: `~/.claude`, and the directory named by
`HARNESS_WORKSPACE`, which defaults to `~/.swe-harness`. It backs up every file it replaces, records
a manifest of what it did, and `--uninstall` reverses only what that manifest records.

It is a dry run unless you pass `--write`. Read the plan first; it prints every hook command and
every link before it does anything.

## What a hook can do

A hook runs with your shell's privileges on every matching tool call. Treat a new hook, and any
layer you install, as code you are choosing to run. Read a layer before installing it, the same way
you would read any script.

Core ships two guards that deny rather than warn: one blocks a git command that would skip the
commit hooks, and one protects configuration files from being rewritten without intent.

## Secrets

No credential belongs in this repository. The installer refuses to write a configuration value that
matches a credential pattern, and aborts before touching `settings.json`.

`core/tests/test-core-purity.py` runs in CI and fails the build on a credential pattern, a real
email address or an absolute home path anywhere under `core/`. An organisation adds its own terms
through a denylist in its layer.

These are backstops. They catch a shape, not a secret you have disguised.
