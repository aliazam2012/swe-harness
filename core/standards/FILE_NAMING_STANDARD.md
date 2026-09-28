# File Naming Standard

## Table of Contents

- [Purpose](#purpose)
- [Core Rules](#core-rules)
- [Type Prefix System](#type-prefix-system)
- [Casing Rules](#casing-rules)
- [Separator Rules](#separator-rules)
- [Date Convention](#date-convention)
- [Versioning](#versioning)
- [Length Limit](#length-limit)
- [Folder Naming](#folder-naming)
- [Exempt Files](#exempt-files)
- [Quick Reference Card](#quick-reference-card)

---

## Purpose

A file name should tell you **what the file does** before you open it. A scanning agent or a human browsing a directory should be able to classify every file by name alone. This standard defines how to name files going forward and how to evaluate existing names.

**Scope:** Every `.md`, `.mmd`, `.sh` and `.py` file an agent or a person authors in a documentation tree. It does not apply to content synced in from another system, which keeps that system's naming.

---

## Core Rules

1. **Type prefix is mandatory** for all new non-project files. The prefix tells you what the file *does*.
2. **One file, one purpose.** If a name needs two type prefixes, it's two files.
3. **Folder context carries weight.** A file in `playbooks/` doesn't need "PLAYBOOK" in the name, and a file in a project folder doesn't need the project in the name.
4. **Never duplicate folder context in the filename.** `playbooks/RUNBOOK-cognito.md` — not `playbooks/COGNITO_PLAYBOOK.md`.
5. **Name the thing, not the format.** `agent-data.md` — not `agent-data-document.md`.

---

## Type Prefix System

Every non-project file gets a type prefix that signals its intent. Prefix is always uppercase, separated from the subject by a hyphen.

### Knowledge & Learning

| Prefix | Intent | When to use |
|--------|--------|-------------|
| `REF` | Reference material — read to learn | Architecture docs, system descriptions, how things work |
| `GUIDE` | How-to instructions — follow steps to set up or learn | Setup guides, onboarding docs, tutorials |

### Action & Operations

| Prefix | Intent | When to use |
|--------|--------|-------------|
| `RUNBOOK` | Operational procedure — follow when an event happens | Incident response, permission fixes, deployment steps |
| `CHECKLIST` | Verification list — run before/after an action | Pre-ship checks, quality gates, validation steps |

### Proposals & Decisions

| Prefix | Intent | When to use |
|--------|--------|-------------|
| `RFC` | Proposal seeking feedback — open for discussion | Process changes, new features, team-wide proposals |
| `ADR` | Architecture decision record — immutable once accepted | Technical decisions with context + consequences |

### Incidents & Analysis

| Prefix | Intent | When to use |
|--------|--------|-------------|
| `IR` | Incident record — what happened | Production incidents: impact, timeline, mitigation, follow-up actions |
| `RCA` | Root cause analysis — post-incident | Production incidents, misclassifications, outages |
| `RETRO` | Retrospective — learnings from a completed effort | Project retros, sprint retros, customer retros |

**Pairing `IR` with `RCA`.** When an incident needs both a record and a causal analysis, both files share
one timestamp mint so the pair is identifiable: `IR-YYYYMMDDHHMM-{subject}.md` and
`RCA-YYYYMMDDHHMM-{subject}.md`. The mint is the minute the incident was raised, local time, not the
minute the defect started. Never reuse a mint. An `IR` with no `RCA` yet is fine; an `RCA` with no
matching `IR` is not. Use a single `RCA-YYYY-MM-DD-{subject}.md` when the incident does not warrant a
separate record.

### Templates & Reusable

| Prefix | Intent | When to use |
|--------|--------|-------------|
| `TPL` | Template — copy and fill for new instances | Assessment templates, onboarding templates, ticket templates |

### Tracking & Status

| Prefix | Intent | When to use |
|--------|--------|-------------|
| `LOG` | Append-only chronological record | Session history, comms log, decision log |
| `TRACKER` | Living status dashboard — updated regularly | Implementation trackers, pilot trackers, TODO lists |

---

## Casing Rules

| Context | Convention | Example |
|---------|-----------|---------|
| **Type prefix** | UPPERCASE | `REF`, `RUNBOOK`, `RCA` |
| **Subject (after prefix)** | kebab-case | `REF-time-reporting.md` |
| **Project standard files** | UPPER_SNAKE (no prefix) | `PROJECT_SUMMARY.md`, `KEY_INSIGHTS.md` |
| **Convention files** | UPPER_SNAKE (no prefix) | `README.md`, `PROFILE.md`, `TODO.md` |
| **Scripts** | kebab-case | `ticket-reader.py`, `get-secret.sh` |
| **Folders** | kebab-case for tasks, PascalCase or descriptive for top-level | `Architecture/`, `shipment-updates/` |

**Why two conventions?** Project standard files (`PROJECT_SUMMARY.md`, `KEY_INSIGHTS.md`, `SESSION_HISTORY.md`) are a repeating pattern across every project folder — they're structural, not content-typed. They stay UPPER_SNAKE because they're the same file in every project. Everything else uses type prefix + kebab-case because the prefix already signals intent.

---

## Separator Rules

- **Hyphen (`-`)** separates words within a segment: `time-reporting`, `cognito-admin-center`
- **Hyphen (`-`)** separates the type prefix from the subject: `REF-time-reporting.md`
- **Underscore (`_`)** separates major structural segments only: date from subject (`2026-04-09_Reviewer.md`), or in legacy UPPER_SNAKE names
- **Never use spaces** in filenames

---

## Date Convention

When a file is date-specific (incident, meeting, conversation note):

```
PREFIX-YYYY-MM-DD-subject.md
```

Examples:
- `RCA-2026-04-09-misclassified-intake.md`
- `2026-04-09_Reviewer.md` (conversation notes, the date_Person pattern stays)
- `2026-04-10.md` (conversation logs — date only)

---

## Versioning

**Prefer dates over version numbers.** If a document evolves, the `updated_at` in content or git history tracks it.

When versioning is necessary (draft iterations shared externally):

```
subject-v1.md, subject-v2.md
```

- Lowercase `v` followed by number, no leading zeros: `v1`, `v2`, `v12`
- Version goes at the end of the subject, before the extension
- Final/accepted version drops the version suffix — it just becomes the canonical name

**Anti-patterns:**
- `_V1`, `_V2` (uppercase V — legacy, don't create new ones)
- `_FINAL`, `_FINAL_v2` (never use "final")
- `_DRAFT` in the filename (use content-level status instead)

---

## Length Limit

- **Target: under 40 characters** (excluding extension)
- **Hard max: 50 characters** (excluding extension)
- If you can't fit it, the name is doing too much. Let the folder path carry context.

**Too long:** `ADMIN_CENTER_COGNITO_PERMISSION_FIX_PLAYBOOK.md` (48 chars)
**Right:** `RUNBOOK-cognito-admin-center.md` (30 chars) inside `playbooks/`

---

## Folder Naming

| Level | Convention | Examples |
|-------|-----------|----------|
| **Top-level folders** | PascalCase or descriptive | `Architecture/`, `Initiatives/` |
| **Subfolders (organizational)** | lowercase kebab or snake | `reference/`, `playbooks/`, `shared/`, `internal/` |
| **Type-based subfolders** | lowercase, short | `scope/`, `rcas/`, `impl/`, `audits/`, `uat/`, `platform/`, `references/`, `usecases/` |
| **Project folders** | repo name, as it is | `payments-api/`, `ingest-worker/` |
| **Task folders** | ticket key or kebab-case | `PROJ-123-column-widths/`, `shipment-updates/` |

---

## Exempt Files

These follow their own conventions and are not subject to the type prefix system:

| File Pattern | Convention | Reason |
|-------------|-----------|--------|
| `README.md` | As-is | Universal convention |
| `PROFILE.md`, `WORKFLOW.md` | As it is | Root-level identity files |
| `PROJECT_SUMMARY.md`, `KEY_INSIGHTS.md`, `SESSION_HISTORY.md`, `TECH_DEBT.md` | UPPER_SNAKE | Project standard files — same name in every project folder |
| `<logs>/YYYY-MM-DD.md` | Date only | Conversation log convention |
| `<meetings>/YYYY-MM-DD_title.md` | Date_title | Synced from a transcription tool |
| `<chat>/*.md` | Channel name | Synced from a chat system |
| `<tickets>/*.md` | Ticket key | Synced from a tracker |
| `*.mdc` | Existing convention | Another harness's rule files |
| Conversation notes | `YYYY-MM-DD_Person.md` | People conversation convention |

---

## Quick Reference Card

```
New reference doc?       → REF-{subject}.md
New operational runbook? → RUNBOOK-{subject}.md
New proposal?            → RFC-{subject}.md
New decision record?     → ADR-NNN-{subject}.md
New incident analysis?   → RCA-YYYY-MM-DD-{subject}.md
New template?            → TPL-{subject}.md
New checklist?           → CHECKLIST-{subject}.md
New retrospective?       → RETRO-{subject}.md
Tracking something?      → TRACKER-{subject}.md
Append-only log?         → LOG-{subject}.md
Project standard file?   → UPPER_SNAKE (no prefix)
Script?                  → kebab-case.ext

Subject format:          kebab-case, under 40 chars
Date in name:            YYYY-MM-DD after prefix
Version in name:         -v1, -v2 (lowercase, at end)
```
