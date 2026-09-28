---
name: shell-scripts
description: "Use when writing or editing a shell script (.sh, .bash, .zsh). Not for Python, which the ruff and mypy hook owns, and not for a one-off command."
---

# Shell Script Standards

Every shell script MUST meet these standards.

## Procedure — modifying an existing script

1. Run the existing test suite FIRST. Confirm the baseline passes before touching anything.
2. Make the code changes. Apply every standard below.
3. Add or update tests to cover the new behavior.
4. Run the full test suite. ALL tests must pass.
5. Lint: `shellcheck -S warning ./script.sh` (bash only, zsh exempt). Zero warnings.
6. Verify that new variables which should not change are `readonly`.
7. If the name, purpose or usage changed, update the script inventory README beside it.

## Procedure — creating a new script

1. Scaffold: strict mode, readonly constants, cleanup trap, error function.
2. Implement. Apply every standard below.
3. Create tests in `tests/test_scriptname.sh`. Cover error paths, guard clauses, input
   validation, injection attempts and edge cases.
4. Run the tests. ALL must pass.
5. Lint: `shellcheck -S warning` (bash only). Zero warnings.
6. Add the script to the inventory README beside it.

## Security

- Validate every user input (regex for format, type checks for numbers).
- No raw interpolation into JSON, SQL or heredocs. Use `jq -n --arg` for JSON.
- Error messages go to stderr (`>&2`).
- Check file permissions before operating on files.

## Robustness

- Bash: `set -euo pipefail` at the top.
- Zsh: `setopt ERR_EXIT PIPE_FAIL; set -u` at the top.
- All constants `readonly`, declared and assigned separately (SC2155).
- `trap cleanup EXIT` for temp files and partial state.
- Guard clauses: check required tools (`command -v`), required files, valid state.
- Division-by-zero protection.
- Graceful handling of corrupt or malformed data.

## Efficiency

- A single `jq` call for several fields, not N separate calls.
- Chain `sed` expressions: `sed -e '...' -e '...'`, not `sed | sed | sed`.
- Use `printf` over `echo` for user-controlled data.

## Testing (mandatory)

- Tests in a `tests/` folder beside the script.
- File naming: `test_<scriptname>.sh`.
- Cover error paths, guard clauses, input validation, injection attempts and edge cases.
- Exit-code pattern: `EXIT=0; OUTPUT=$(...) || EXIT=$?`, not `|| true` followed by `$?`.
- Counter arithmetic: `VAR=$((VAR + 1))`, not `((VAR++))`, which fails under `set -e` at 0.
- Cleanup trap in tests: `trap 'rm -rf "$TEST_DIR"' EXIT`.
- Assert source quality too: verify that strict mode, `readonly`, stderr routing and cleanup
  traps are present.

## Naming convention

Format: `{project}-{function}-{datasource}.sh`

1. Project prefix: which project the script belongs to.
2. Function: what it does, for example `weekly-usage` or `execution-detail`.
3. Data source: where the data comes from, for example `dual-source` or `localdb`.
4. No ambiguous abbreviations. Write the word out.
5. Bugfix or one-off scripts: append `-bugfix` or `-oneoff`.
6. Test files: `tests/test_{script-name}.sh`.

## Data source and environment documentation

Every script that connects to a database or an external service MUST carry this header:

```bash
# Data Sources:
#   - {DB or service name} ({region or URL}) — what data is pulled
#
# Default Environment: prod (override with --env)
# Environments Supported: dev, staging, prod
```

- State which databases are used, and their region or purpose.
- State the default environment. Never assume the reader knows it.
- Support an `--env` flag where it applies.
- Never mix environments silently. Document a cross-source pull.
- A cross-validation script flags discrepancies explicitly in its output.
