#!/bin/sh
# Show the full last input for the focused pane, in a Herdr popup.
# The pane border holds one line; this is where the rest of it lives.
# Bind it to a key in the Herdr config, for example prefix+alt+p.
#
# Not a hook: herdr-sticky-prompt.py records the text on every submit, and this
# reads it back on demand. It is here so the pair stays together.
#
# Piped through less so the popup waits for q instead of closing at once,
# and so a long prompt scrolls.

# Resolve this file through any symlink, then the clone root above core/hooks.
SELF="$0"
while [ -L "$SELF" ]; do
  link="$(readlink "$SELF")"
  case "$link" in
    /*) SELF="$link" ;;
    *)  SELF="$(dirname "$SELF")/$link" ;;
  esac
done
HOOKS_DIR="$(cd "$(dirname "$SELF")" && pwd -P)"
HARNESS_HOME="${HARNESS_HOME:-$(cd "$HOOKS_DIR/../.." && pwd -P)}"

workspace="$(python3 "$HARNESS_HOME/core/lib/harness_config.py" HARNESS_WORKSPACE 2>/dev/null)"
[ -n "$workspace" ] || workspace="$HOME/.swe-harness"

pane="${HERDR_ACTIVE_PANE_ID:-}"
file="$workspace/herdr-last-input/$(printf '%s' "$pane" | tr ':' '-').txt"

{
  if [ -n "$pane" ] && [ -f "$file" ]; then
    printf '=== last input in %s ===\n\n' "$pane"
    cat "$file"
  else
    printf 'No recorded input for pane %s\n\n' "${pane:-unknown}"
    printf 'A Claude pane records on submit.\n'
    printf 'A shell pane records on each command.\n'
  fi
  printf '\n\n(q to close)\n'
} | less -R
