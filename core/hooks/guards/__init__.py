"""The write-time guards the PreToolUse dispatcher runs, in order.

A guard is a function that takes the hook payload and returns a refusal reason,
or None to let the call through. Adding one here costs no extra process: the
dispatcher imports them and calls them in this order, stopping at the first
refusal.

A guard still self-selects on `tool_name`, so a guard handed a call it does not
own returns None and the split below is an optimisation, not a correctness rule.
"""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from .config_protection import check as config_protection
from .no_verify import check as no_verify

Guard = Callable[[dict[str, Any]], "str | None"]

# Split by matcher, because the two run in different processes. A PreToolUse
# entry costs a Python start, so every guard behind one matcher shares a single
# start. GUARDS runs on Write, Edit and MultiEdit; BASH_GUARDS runs on Bash.
# Both tuples are dispatched by the same script, which picks by tool name.
#
# A layer that already starts a process on every Bash call can take BASH_GUARDS
# over, by importing this tuple and overriding the `bash-guards` registry id.
GUARDS: tuple[Guard, ...] = (config_protection,)
BASH_GUARDS: tuple[Guard, ...] = (no_verify,)
