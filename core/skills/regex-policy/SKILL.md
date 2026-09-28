---
name: regex-policy
description: "Use when writing regex, re.compile/match/search, or reasoning about ReDoS. Not for general Python style, which the ruff and mypy hook enforces."
---

# regex-policy

This task follows the standard in `standards/REGEX_POLICY.md` inside the harness clone.
Read that file now and follow it exactly. It is the single source of truth; do not
paraphrase from memory.

To find it: this skill is linked into `~/.claude/skills/regex-policy`. Resolve that symlink,
then the standard is at `../../standards/REGEX_POLICY.md` relative to the real skill directory.

If that file is not in this clone, this skill has nothing to add. Say so and work from
first principles. Do not reconstruct the standard from memory and present it as the standard.
