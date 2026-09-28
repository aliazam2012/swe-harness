#!/usr/bin/env bash
# Resolve a harness configuration key from a shell hook or script.
#
#   source "$HARNESS_HOME/core/lib/harness-config.sh"
#   brain="$(harness_config BRAIN_ROOT)"      # empty if unset
#   brain="$(harness_config_require BRAIN_ROOT)" || exit 1
#   workspace="$(harness_workspace)"
#
# Resolution is delegated to harness_config.py rather than reimplemented here,
# so the order (environment, then harness.config.json, then the declared
# default) has exactly one definition. A second copy in shell would drift from
# it, and the bug would look like a key that is set but not seen.

harness_home() {
  if [ -n "${HARNESS_HOME:-}" ]; then
    printf '%s\n' "$HARNESS_HOME"
    return 0
  fi
  # This file is at <home>/core/lib/, so the clone is two directories up.
  ( cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P )
}

_harness_python() {
  local candidate
  for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3 python3; do
    if command -v "$candidate" >/dev/null 2>&1; then command -v "$candidate"; return 0; fi
  done
  return 1
}

harness_config() {
  local key="$1" home python
  [ -n "$key" ] || { echo "harness_config: needs a key" >&2; return 2; }
  home="$(harness_home)"
  python="$(_harness_python)" || { echo "harness_config: no python3 found" >&2; return 1; }
  HARNESS_HOME="$home" "$python" "$home/core/lib/harness_config.py" "$key" 2>/dev/null
}

harness_config_require() {
  local key="$1" value
  value="$(harness_config "$key")" || return 1
  if [ -z "$value" ]; then
    echo "harness: $key is not set. Export it, or add it to $(harness_home)/harness.config.json" >&2
    return 1
  fi
  printf '%s\n' "$value"
}

harness_workspace() {
  local path
  path="$(harness_config_require HARNESS_WORKSPACE)" || return 1
  mkdir -p "$path"
  printf '%s\n' "$path"
}
