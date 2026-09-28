---
name: root-cause-fixes
description: Use when fixing a bug, a review MUST-FIX, a failing CI check, a red test, an error from a monitoring tool, or any reported defect. Covers finding the real cause instead of patching the symptom.
---

# root-cause-fixes

This task follows the standard in `standards/ROOT_CAUSE_FIXES.md` inside the harness clone.
Read that file now and follow it exactly. It is the single source of truth; do not
paraphrase from memory.

To find it: this skill is linked into `~/.claude/skills/root-cause-fixes`. Resolve that
symlink, then the standard is at `../../standards/ROOT_CAUSE_FIXES.md` relative to the real
skill directory. If that file is not in this clone, the summary below is all this skill
has; follow it and say the full standard was not available.

It defines the six steps from a symptom to a proved fix: reproduce it, name the mechanism in
one sentence, answer why it happened and why nothing caught it and where else it lives, sweep
for the class, fix at the layer that owns the invariant, then prove the fix with a
before-and-after run and a regression test. It also carries the whack-a-mole catalogue: the
patches that are never a fix on their own, and what to write when the correct fix is too big
for the change in hand.
