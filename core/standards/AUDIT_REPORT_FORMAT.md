# Audit Report Format

The canonical structure for every audit report produced under `PROJECT_AUDIT.md`, and under any overlay an organisation adds to it. One file per audit run.

## Table of Contents

- [Purpose](#purpose)
- [When to use this](#when-to-use-this)
- [File location and naming](#file-location-and-naming)
- [Required sections](#required-sections)
- [Verdict taxonomy](#verdict-taxonomy)
- [Severity / priority taxonomy](#severity--priority-taxonomy)
- [Evidence standard](#evidence-standard)
- [Style + tone](#style--tone)
- [Full skeleton](#full-skeleton)
- [Don'ts](#donts)

---

## Purpose

Every audit produces one report. Same shape every time. The format is the contract between auditor and reader so the reader knows where to look for verdict, evidence, and follow-up without rereading the instructions for each new report.

This file is the format spec. The audit framework (`PROJECT_AUDIT.md`) is the methodology spec. The two are deliberately split so the format can evolve without rewriting the framework, and so non-PROJECT_AUDIT audits (security review, design review, customer compliance review) can adopt the same shape later if useful.

---

## When to use this

Required output for:

- Every run of `standards/PROJECT_AUDIT.md` (any lens, any depth).
- Every standalone or scoped audit produced for a customer project.
- Any structured project-quality review that wants a single-page-of-record.

Not required for:

- Code review of a single PR (use `CODE_REVIEW_PROCESS.md`).
- Incident postmortem (a different artifact with its own format).
- Architecture decision record (ADR) (different artifact, different lifecycle).

---

## File location and naming

The file name carries the target and the date, because a second audit of the same target is a new file rather than an edit:

```
<customer-or-project-root>/AUDIT-<repo-or-target>-<YYYY-MM-DD>.md
```

Examples:

- `payments/AUDIT-payments-api-2026-04-21.md`
- `ingest/AUDIT-ingest-worker-2026-05-10.md`

One file per run. Don't overwrite a previous audit. New date, new file. The previous file is historical record.

If the audit is partial (e.g., only Code Quality + Security dimensions), suffix the target: `AUDIT-<repo>-security-only-<YYYY-MM-DD>.md`.

---

## Required sections

Every report contains the following sections, in this order. Section names are exact (auditors and tooling read them):

1. **Title + front-matter block** (top of file, no heading needed)
2. **Table of Contents**
3. **TL;DR**
4. **Calibration notes** (mandatory if any dimension is `N/A`)
5. **Scoped lens summary** (mandatory if scoped lens applied; omit otherwise)
6. **Standalone lens summary** (mandatory if standalone lens applied; omit otherwise)
7. **Detailed findings** (one subsection per non-PASS dimension)
8. **Tool gates not run** (mandatory if any toolchain gate was deferred)
9. **Findings prioritized** (P0 → P3, every finding from §7 listed once)
10. **Framework feedback** (optional, for first-time runs against new project shapes)
11. **Sign-off**

Anything outside this list goes into an appendix at the bottom (`## Appendix A: ...`). Don't sneak custom sections into the main spine.

---

## Verdict taxonomy

Verdicts apply at two levels: per-gate and rolled up to per-dimension. Same labels at both levels.

| Verdict | Meaning |
|---|---|
| `PASS` | Gate meets the bar. No action. |
| `WARN` | Gate is borderline or has a minor gap. Note the fix, ship anyway. |
| `FAIL` | Gate misses the bar. Fix required before next gate (merge / release / launch — depends on audit trigger). |
| `N/A` | Gate does not apply. Always pair with a reason: `N/A — documented exclusion in <doc>` or `N/A — no production deployment` or `N/A — needs ≥90 days of commit history`. |
| `TOOL-NEEDED` | Gate could not be evaluated without a tool that wasn't run during this pass. List the tool + install command in §"Tool gates not run". |

A dimension verdict aggregates its gates. Default rules:

- Any `FAIL` gate → dimension is `FAIL`.
- Otherwise any `WARN` → dimension is `WARN`.
- Otherwise all `PASS` or `N/A` → dimension is `PASS`.
- All `N/A` → dimension is `N/A`.
- All `TOOL-NEEDED` → dimension is `TOOL-NEEDED`.

Mixed `PASS` + `TOOL-NEEDED` → `PASS (partial — see tool gates)`. Don't hide the fact that toolchain gates were skipped.

---

## Severity / priority taxonomy

Findings (the things in §"Findings prioritized") use a single P0 → P3 scale that combines severity and priority. This replaces the older Critical/High/Medium/Low scale to keep the report compact.

| Priority | Definition | Action |
|---|---|---|
| `P0` | Active exploit risk, data loss risk, hard outage risk, or real bug already exploitable in current code. | Fix before next merge. Page if found in production. |
| `P1` | Latent vulnerability, missing-but-required practice, or spec violation that will bite within the next release. | Fix before next release. Tracked ticket. Owner named in the report. |
| `P2` | Quality / maintainability / minor reliability gap. Won't break anything immediately. | Tracked ticket. Fix opportunistically. |
| `P3` | Style, docs, nit, or "out of scope but worth noting." | Optional. Inform team. |

Mapping for teams that prefer the older scale: P0 = Critical, P1 = High, P2 = Medium, P3 = Low + Info.

Every P0 and P1 needs a named owner before the audit closes. P2 needs a tracked ticket. P3 can ship as observation only.

---

## Evidence standard

A finding without evidence is a personal opinion. Every gate verdict and every finding must cite at least one of:

- **Code reference**: `path/to/file.py:42` or `path/to/file.py:42-58`. Always relative to the audit target root, not absolute.
- **Tool output snippet**: a 1-5 line excerpt from the tool, with the command that produced it.
- **Spec reference**: `DECISIONS.md §7` or `IMPLEMENTATION_TRACKER.md row 12` for scoped findings.
- **Commit / PR reference**: `commit a2a44b4` or `PR #189` if the finding traces to a specific change.
- **External standard reference**: `OWASP ASVS 5.0 V2.1.1` or `NIST SSDF SP 800-218 PW.4` for standalone findings that cite an external bar.

Anchors-only links (`see file X`) without line numbers are not evidence. Re-cite with `path:line`.

---

## Style + tone

Per `WRITING_STYLE.md`:

- Engineer's voice. Direct, terse, no AI tropes.
- No banned words (`delve`, `leverage`, `utilize`, `streamline`, `robust`, `seamless`, `comprehensive`, etc.).
- Em dash budget: 1-2 per page in prose. Tables get a pass when the em dash is a structural separator (`file:line — explanation`), but prefer `:` even there.
- No filler labels (`Notably`, `Importantly`, `It's worth noting`).
- No rhetorical Q&A (`But what does that mean? It means…`).
- People referenced by full name on first mention (`George Henderson`, not `George`).

Length budget:

- TL;DR: ≤ 3 short paragraphs.
- Scorecard tables: 1 row per dimension, ≤ 1 sentence per row.
- Detailed findings: only non-PASS dimensions get expanded. PASS dimensions stay in the table.
- Total length: aim for ≤ 500 lines. If it's longer, the audit is too broad — split by area.

---

## Full skeleton

Copy-paste this block into a new `AUDIT-<repo>-<YYYY-MM-DD>.md` and fill in. Comments in `<!-- ... -->` are author guidance, delete them once filled.

````markdown
# Audit — `<project-or-repo-name>`

**Audit date**: <YYYY-MM-DD> (PST)
**Framework**: `PROJECT_AUDIT.md` v<x.y> (plus <overlay> v<x.y>, if one applies)
**Report format**: `AUDIT_REPORT_FORMAT.md` v<x.y>
**Auditor**: <name | "agent (single-runner pass)">
**Target**: `<repo-relative path>` at commit `<sha>` (or "no commit hash, single-commit project")
**Lens**: <standalone | scoped | both>
  - Standalone: <one-line on the engineering bar applied>
  - Scoped (if applicable): <list of spec docs the audit checks against>
**Depth**: <full (18 dims) | light (10 dims for <2k LOC) | subset: D2,D3,D6 only>
**Trigger**: <pre-launch | quarterly | post-incident | educational | other>

---

## Table of Contents

- [TL;DR](#tldr)
- [Calibration notes](#calibration-notes)            <!-- omit if no N/A dims -->
- [Scoped lens summary](#scoped-lens-summary)        <!-- omit if no scoped lens -->
- [Standalone lens summary](#standalone-lens-summary) <!-- omit if no standalone lens -->
- [Detailed findings](#detailed-findings)
- [Tool gates not run](#tool-gates-not-run)          <!-- omit if all gates ran -->
- [Findings prioritized](#findings-prioritized)
- [Framework feedback](#framework-feedback)          <!-- optional -->
- [Sign-off](#sign-off)

---

## TL;DR

<!--
3 short paragraphs max. Structure:
1. Scoped verdict (if scoped lens): hits/total signals, scoring bucket if defined.
2. Standalone verdict (if standalone lens): overall grade, dim counts (PASS/WARN/FAIL/N/A/TOOL-NEEDED).
3. Top 3 fixes worth doing now, with effort estimate.
-->

**Scoped verdict**: <e.g. 23/23 signals hit. Strong Hire L5 by the project's own rubric.>

**Standalone verdict**: <e.g. A-tier. 11 PASS / 2 WARN / 1 FAIL / 5 N/A (documented) / 1 TOOL-NEEDED out of 18.>

**Top fixes**:
1. <P0/P1 finding ID> — <one-line> — <effort>
2. <P0/P1 finding ID> — <one-line> — <effort>
3. <P0/P1 finding ID> — <one-line> — <effort>

---

## Calibration notes

<!--
Required if any dim is N/A or TOOL-NEEDED. Skip if every dim was fully evaluated.
Explain: which dims were excluded, why, what the project's own scoping doc says about them.
This guards against the "audit penalized us for not having Kubernetes manifests when we said no Kubernetes" failure mode.
-->

1. **Documented exclusions.** <list dims marked N/A and the spec section that excludes them.>
2. **History limits.** <if applicable: e.g., single-commit project, no DORA metrics computable.>
3. **Tool runs deferred.** <if applicable: which gates need toolchain, why not run, where to find the install commands.>
4. **Other framework calibrations applied.** <e.g., light preset for <2k LOC.>

---

## Scoped lens summary

<!--
Required if scoped lens was applied. One row per signal in the spec. Verdict + evidence.
The spec might be: a 23-row checklist (interview reference), a contract clause list, an impl-tracker row set.
-->

| # | Signal | Verdict | Evidence |
|---|---|---|---|
| 1 | <signal-name from spec> | PASS / WARN / FAIL / N/A | `path/to/file.py:42`: <one-line> |
| 2 | ... | ... | ... |

**Score**: <hits>/<total> → matches `<spec-doc>` bucket "<bucket-name>".

---

## Standalone lens summary

<!--
Required if standalone lens was applied. One row per dimension. Verdict + 1-line.
For full audits, all 18 dims listed even when N/A.
For light preset, omit always-N/A dims and note in calibration.
-->

| # | Dimension | Verdict | One-line |
|---|---|---|---|
| 1 | Architecture & system design | PASS | <one-line> |
| 2 | Code quality & maintainability | PASS / WARN / FAIL | <one-line> |
| 3 | Testing | ... | ... |
| 4 | Application security | ... | ... |
| 5 | Supply chain & dependencies | ... | ... |
| 6 | Secrets & configuration | ... | ... |
| 7 | Infrastructure & deployment | ... | ... |
| 8 | CI/CD pipeline | ... | ... |
| 9 | Observability | ... | ... |
| 10 | Reliability | ... | ... |
| 11 | Performance & scalability | ... | ... |
| 12 | Data layer | ... | ... |
| 13 | API contracts | ... | ... |
| 14 | Documentation | ... | ... |
| 15 | Operational readiness | ... | ... |
| 16 | Cost & resource efficiency | ... | ... |
| 17 | Compliance & privacy | ... | ... |
| 18 | Scope conformance | ... | ... |

**Verdict counts**: <PASS> / <WARN> / <FAIL> / <N/A> / <TOOL-NEEDED> out of 18.

---

## Detailed findings

<!--
Only non-PASS dimensions get expanded here. PASS dimensions stay in the table above.
For each non-PASS dim: verdict, evidence, what's missing, what's strong (if mixed), what to do.
Section heads use `D<n>: <name>` to keep the dimension number anchored.
-->

### D<n>: <Dimension name>

**Standalone verdict**: <PASS / WARN / FAIL>
**Scoped verdict** (if applicable): <PASS / WARN / FAIL>

**Evidence**:
- `path/to/file.py:N`: <observation>
- <tool snippet or spec reference>

**Findings**:
1. <P-tag> <finding name>: <one-paragraph>
2. ...

**Tool gates** (if any deferred): <list with install command>

---

<!-- repeat per non-PASS dimension -->

---

## Tool gates not run

<!--
Required if any gate was tagged TOOL-NEEDED. Format: bash block with the exact commands the auditor (or human) should run to close the gap.
Honors core.mdc §4: agent does not auto-install; human runs.
-->

```bash
# 1. Bootstrap
python3.11 -m venv .venv-audit
source .venv-audit/bin/activate
pip install -e ".[dev]"

# 2. <category>
<tool> <args>            # purpose
<tool> <args>            # purpose

# 3. <category>
...
```

**Expected results based on static reading**:
- `<tool>`: <expected outcome based on what was visible without running it>

---

## Findings prioritized

<!--
Every finding from §"Detailed findings" appears here exactly once, sorted by P-tag.
This is the actionable to-do list. Owners assigned for P0 and P1 before audit closes.
-->

### P0: real bug risk

1. **<short title>** — <one-paragraph>. Owner: <name>. Ticket: <id or "TBD">.

### P1: worth doing in the next release

2. **<short title>** — <one-paragraph>. Owner: <name>. Ticket: <id or "TBD">.

### P2: tracked, fix opportunistically

3. **<short title>** — <one-paragraph>. Ticket: <id or "TBD">.

### P3: out of scope or polish

4. **<short title>** — <one-paragraph>.

---

## Framework feedback

<!--
Optional. Use this section when running the framework against a new project shape (first small project, first stateful service, first multi-tenant, etc.).
Capture what the framework got right, what it got wrong, and what should change. The framework owner folds these into its next revision.
-->

1. <observation about the framework>
2. <calibration request>

---

## Sign-off

**Verdict**: <one-paragraph wrap-up>.

**Re-audit cadence**: <next-trigger | next-date | "on material change">.

**Auditor**: <name>, <date> (PST).
**Audit commit**: <sha or "single-commit project, no SHA gate">.
**Format version**: `AUDIT_REPORT_FORMAT.md` v<x.y>.
````

---

## Don'ts

- **Don't invent new top-level sections.** If a section doesn't exist in the spec, it goes in an appendix at the bottom.
- **Don't skip §"Findings prioritized" because §"Detailed findings" already lists them.** The two have different audiences. Detailed = the auditor showing work. Prioritized = the team's action list.
- **Don't fix during the audit.** Fixes go in follow-up PRs. The audit must be a snapshot. Fixing mid-audit invalidates the report.
- **Don't omit calibration notes when any dim is N/A.** The reader needs to know the dim was excluded on purpose, not accidentally.
- **Don't hide deferred toolchain gates.** Tag them `TOOL-NEEDED`, list the install commands. Hiding gives a false sense of completeness.
- **Don't strip evidence.** A finding without `file:line` or a tool snippet is an opinion. The reader should be able to reproduce the finding without rereading the source from scratch.
- **Don't overwrite a previous audit.** New date, new file. The previous file is the record of the previous state.
- **Don't write the report in a customer-shareable voice unless the audit was framed for that audience.** Most audits are internal. If a customer needs the findings, write a separate FIIP summary per `TECHNICAL_COMMUNICATION.md` and link the audit as the underlying artifact.
