---
name: writing-style
description: "Use when creating or editing any Markdown or documentation file: enforces TOC, file naming, banned words, zero em dashes, full names, engineer voice, and the team-facing checklist. Not for code comments or docstrings."
---

# Markdown Documentation Standards

The full guide is `standards/WRITING_STYLE.md` inside the harness clone. This skill is linked
into `~/.claude/skills/writing-style`; resolve that symlink and the standard is at
`../../standards/WRITING_STYLE.md` relative to the real skill directory. Read it for the
detail; if it is not in this clone, the rules below stand on their own. What follows is the part that applies to every file without exception.

## Table of Contents (mandatory)

Every `.md` file created or updated in a documentation tree MUST have a Table of Contents.

- Add `## Table of Contents` after the title (`# heading`) and any metadata.
- Include an anchor link to every `##` section: `- [Section Name](#section-slug)`.
- When you add a section, update the TOC.

## Format

```markdown
# File Title

## Table of Contents

- [Section One](#section-one)
- [Section Two](#section-two)

---

## Section One
...
```

## Writing style, every generated file

This applies to ALL output: notes, session logs, design docs, proposals, external-facing docs,
chat posts, pull request descriptions. No exceptions.

- No AI tropes: no negative parallelism ("It's not X, it's Y"), no rhetorical question and
  answer, no tricolon for rhythm, no filler transitions, no gerund fragment litanies.
- No banned words: delve, leverage, robust, seamless, comprehensive, innovative, pivotal,
  crucial, foster, harness, underscore, tapestry, landscape, utilize, streamline, elevate,
  showcase.
- Plain vocabulary: "use" not "leverage", "show" not "showcase", "improve" not "elevate",
  "full" not "comprehensive".
- Engineer's voice: direct, specific, no drama, short paragraphs, active voice.
- Zero em dashes, in any output. Use a period, a comma, a colon or parentheses instead.
- No hedge words. Commit to the statement or cut it.
- Before writing any file, check: would a senior engineer write it this way, or does it sound
  like an AI?

## Names in documents

Always use a full name on first reference. Never a nickname, an abbreviation or a shortened
name.

- First reference: the full name.
- Later references in the same document: the first name alone is fine.
- Never initials or a nickname, in any document.

## File naming, every new file

Every new `.md` file MUST follow `standards/FILE_NAMING_STANDARD.md`, found the same way as
the style guide above. Read it before creating a file. The rules that matter most:

- A type prefix is mandatory for a non-project file: `REF-`, `RUNBOOK-`, `RFC-`, `ADR-`,
  `RCA-`, `RETRO-`, `TPL-`, `CHECKLIST-`, `LOG-`, `TRACKER-`.
- Format: `PREFIX-kebab-case-subject.md`, for example `REF-agent-data.md`.
- A project standard file stays UPPER_SNAKE with no prefix: `PROJECT_SUMMARY.md`,
  `KEY_INSIGHTS.md`, `SESSION_HISTORY.md`.
- Do not repeat the folder's context in the filename.
- Under 40 characters, 50 hard maximum, excluding the extension.
- No spaces, no UPPER_SNAKE for a new typed file, no `_FINAL` or `_DRAFT` suffix.

## Team-facing document checklist

When a document is going to any audience beyond the person you are working with, run this
before the first publish, not after.

**Audience readiness**

- No individual person names. Generalize: "the customer", "the operations team", "the
  engineering team".
- No internal team labels or role acronyms. Use a neutral label the reader will understand.
- No internal-only context that assumes the reader knows who does what.
- Put self-service links at the top, so the reader can start their own research without asking
  anyone.

**Source credibility, for a research document**

- Filter for credibility DURING the research, not after. If a source is not a recognized
  publication, a regulatory filing or an official corporate channel, find a better one before
  you include it.
- Never cite: AI-generated analyses, unknown blogs, vendor marketing content, individual
  newsletters, or a site writing outside its domain expertise.
- Acceptable: regulatory filings, official press releases, established trade press, major
  newspapers, recognized financial data platforms.
- Add a credibility note per source category, so the reader knows what bias to watch for.

**Do not ask a question you can answer yourself.** If the answer follows from the context
(where a section goes, which format to use), just do it. Save the round trip for real
ambiguity.
