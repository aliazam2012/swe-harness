#!/usr/bin/env bash
# Install the harness on this machine. Dry run unless you pass --write.
#
# Finds a python that meets the floor and hands over to core/lib/install.py.
# Everything this needs ships with macOS and with any Linux that has git: bash,
# git, and python 3.9 with its standard library. Nothing is downloaded.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
export HARNESS_HOME="$HERE"

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "harness: $1 is required and is not on PATH" >&2; exit 1; }
}
need git

# 3.9 is the floor because that is what macOS ships, and it is the reason the
# manifests are JSON rather than YAML or TOML.
# A real interpreter is tried before bare `python3`, because `python3` inside an
# activated virtualenv resolves to that venv. Baking a venv path into
# settings.json breaks every hook the day the venv is rebuilt or removed.
pick_python() {
  local candidate
  for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3 python3; do
    if command -v "$candidate" >/dev/null 2>&1 &&
       "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) and sys.prefix == sys.base_prefix else 1)' 2>/dev/null; then
      command -v "$candidate"
      return 0
    fi
  done
  # Last resort: any python meeting the floor, venv or not. install.py warns.
  for candidate in python3 /usr/bin/python3; do
    if command -v "$candidate" >/dev/null 2>&1 &&
       "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then
      command -v "$candidate"
      return 0
    fi
  done
  return 1
}

PYTHON="$(pick_python)" || {
  echo "harness: needs python 3.9 or newer; none found" >&2
  exit 1
}

exec "$PYTHON" "$HERE/core/lib/install.py" "$@"
