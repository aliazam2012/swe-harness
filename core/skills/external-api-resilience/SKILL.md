---
name: external-api-resilience
description: "Use when writing an external API client: retries, rate limiting, circuit breakers, 429 handling, timeouts. Not for internal service-to-service calls with no external dependency, and not for caching policy."
---

# external-api-resilience

This task follows the standard in `standards/EXTERNAL_API_RESILIENCE.md` inside the harness clone.
Read that file now and follow it exactly. It is the single source of truth; do not
paraphrase from memory.

To find it: this skill is linked into `~/.claude/skills/external-api-resilience`. Resolve that symlink,
then the standard is at `../../standards/EXTERNAL_API_RESILIENCE.md` relative to the real skill directory.

If that file is not in this clone, this skill has nothing to add. Say so and work from
first principles. Do not reconstruct the standard from memory and present it as the standard.
