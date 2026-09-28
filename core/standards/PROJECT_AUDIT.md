# Project Audit — End-to-End Methodology

## Table of Contents

- [TLDR](#tldr)
- [When To Use This Standard](#when-to-use-this-standard)
- [Where The Methodology Comes From](#where-the-methodology-comes-from)
- [Cross-Org Comparison](#cross-org-comparison)
- [The Dual-Mode Contract](#the-dual-mode-contract)
- [Audit Cadence](#audit-cadence)
- [The 19 Dimensions](#the-19-dimensions)
  - [Rule routing](#rule-routing)
  - Packs: [architecture and code], [testing], [security], [delivery], [runtime],
    [data and contracts], [cost and scope]
- [DORA Meta-Metrics](#dora-meta-metrics)
- [Audit Runner Protocol](#audit-runner-protocol)
- [Audit Report Format](#audit-report-format)
- [Severity Taxonomy](#severity-taxonomy)
- [Remediation Workflow](#remediation-workflow)
- [Quick Checklist](#quick-checklist)
- [Anti-Patterns](#anti-patterns)
- [Sources](#sources)

---

## TLDR

A reusable, dual-mode framework for auditing any software project end-to-end. Distilled from Google SRE PRR, AWS Well-Architected + ORR, NIST SSDF, OWASP ASVS, SLSA, DORA/Accelerate, Microsoft SDL, Anthropic Claude Code review patterns, Stripe, Twelve-Factor, and ISO/IEC 25010.

**Two lenses, one checklist.**

- **Standalone lens**: judge the project against the engineering bar. Would Google or Stripe accept this? Independent of intent.
- **Scoped lens**: does the project deliver what its spec says (design doc, implementation tracker, contract, ADRs)?

Each of the 19 dimensions declares which lens(es) apply. The runner picks the lens at audit time. Same artifact, two reports.

**Tooling is open source only.** No paid SaaS. Every gate cites the open-source tool that proves or disproves it.

**Severity is the AppSec scale.** Critical / High / Medium / Low / Info. Critical and High block launch. Medium and Low ship with tickets. Info is for learning.

---

## When To Use This Standard

Load this doc when:

- Pre-launch readiness review on any repo entering production.
- Quarterly engineering health check on a long-lived service.
- Onboarding a repo handed off from another engineer or vendor.
- Post-incident audit (use COE for the incident itself, this for the surrounding system).
- Customer security review preparation.
- Engineer assessment scaffolding when reviewing a junior engineer's PR series.

Skip this for trivial PRs, single-file fixes, or proposal-stage work. Auditing a project that hasn't been built yet is design review, not audit. Use `SYSTEM_DESIGN_REFERENCE.md` for that.

This is the base framework and it names no organisation. An organisation that has house rules of its own (a report structure, a docstring standard, a diagram standard) writes them into an overlay document and loads that after this one.

---

## Where The Methodology Comes From

This isn't invented. It's the intersection of every public framework worth citing, plus the patterns Anthropic and OpenAI have published for agent-driven review.

| Source | Contribution to this framework |
|---|---|
| [Google SRE Production Readiness Review (PRR)](https://sre.google/sre-book/evolving-sre-engagement-model/) | Cross-functional, evidence-driven, gating before launch. The original "is this ready for prod?" review. |
| [Google Engineering Practices](https://google.github.io/eng-practices/) | Code review standard: improve overall code health over time, approve once it improves the codebase even if imperfect. |
| [AWS Well-Architected Framework (6 pillars)](https://docs.aws.amazon.com/wellarchitected/latest/framework/welcome.html) | The pillar taxonomy — Operational Excellence, Security, Reliability, Performance, Cost, Sustainability. 57 questions, HRI/MRI flagging, no pass/fail grading. |
| [AWS Operational Readiness Review (ORR)](https://docs.aws.amazon.com/wellarchitected/latest/operational-readiness-reviews/wa-operational-readiness-reviews.html) | Pre-launch checklist generated from real incidents (COE). Self-assessment against curated questions. |
| [Amazon Correction of Errors (COE)](https://aws.amazon.com/blogs/mt/why-you-should-develop-a-correction-of-error-coe/) | Closed-loop post-incident analysis. Feeds the next ORR. |
| [NIST SSDF SP 800-218](https://csrc.nist.gov/projects/ssdf) | Four practice groups: Prepare Org, Protect Software, Produce Well-Secured Software, Respond to Vulnerabilities. The SSDLC backbone. |
| [OWASP ASVS 5.0](https://asvs.dev/) | 350 security verification requirements across 17 chapters. L1 baseline, L2 standard (most apps), L3 highest-assurance. |
| [SLSA v1.1](https://slsa.dev/spec/v1.1/levels) | Build provenance levels L0–L3. Supply chain integrity guarantees. |
| [DORA / Accelerate](https://dora.dev/research/) | The 4 (now 5) metrics: Deployment Frequency, Lead Time for Changes, Change Failure Rate, MTTR/Failed Deployment Recovery, Rework Rate. Elite vs. low performer bands. |
| [Microsoft SDL](https://www.microsoft.com/en-us/securityengineering/sdl/practices) | 10 practices — security standards, threat modeling, crypto standards, supply chain security, security testing, monitoring, training. |
| [Anthropic Claude Code Review](https://docs.anthropic.com/en/docs/claude-code/code-review) | Severity tagging (Important/Nit/Pre-existing), parallel agent review, multi-pass automated audit. Customizable via `CLAUDE.md`/`REVIEW.md`. |
| [Stripe API Review Culture](https://newsletter.pragmaticengineer.com/p/stripe-part-2) | API contract review is a separate, harder gate than code review. Backward compatibility is a first-class concern. |
| [Twelve-Factor App](https://12factor.net/) | Cloud-native readiness baseline. Config in env, stateless processes, dev/prod parity, logs as event streams, disposability. |
| [ISO/IEC 25010:2023](https://www.iso.org/standard/78176.html) | Quality model: 8 characteristics — Functional Suitability, Performance Efficiency, Compatibility, Usability, Reliability, Security, Maintainability, Portability. |
| [CNCF Cloud Native readiness](https://tag-app-delivery.cncf.io/) | Auto-scaling, auto-remediation, observability, lifecycle management. Operator pattern for stateful services. |

---

## Cross-Org Comparison

How the major frameworks handle the same dimension. Use this to defend any gate to a skeptic — every checkpoint in the dimensions table below is grounded in at least two of these.

| Dimension | Google (SRE/Eng) | AWS (WAF/ORR) | NIST SSDF | OWASP ASVS | Microsoft SDL | Anthropic |
|---|---|---|---|---|---|---|
| Architecture | Design doc + PRR | "Operational Excellence" + "Reliability" pillars | PO.1, PO.5 | n/a | Practice 3 (threat modeling) | "Separate exploration from implementation" |
| Code quality | "Code health over time" + readability reviews | n/a | PW.4 | n/a | Practice 7 (security testing) | Multi-agent review for logic/edge cases |
| Testing | SLO-driven, error budget | "Test at production scale" design principle | PW.7, PW.8 | V11 (BOLA), V14 (config), V51 (testing) | Practice 7 | Self-verification: tests as oracles |
| Security | Security review pre-launch | "Security" pillar | PW.4, PW.5, PW.6 | All 17 chapters | Practices 1, 3, 7 | `/security-review` command + automated PR scan |
| Supply chain | Borg + signed builds | "Operational Excellence" | PS.1, PS.3 | V14 | Practice 5 | Dependency vulnerability detection |
| Secrets | KMS + rotation | "Security" pillar | PS.2 | V6, V14.1 | Practice 4 | Secrets in audit scope |
| Infra | Borg + automated rollouts | All 6 pillars | PO.3 | n/a | Practice 8 | n/a |
| CI/CD | "Speed of code reviews" | "Operational Excellence" | PS.3, PW.4 | n/a | Practices 5, 7 | GitHub Actions integration |
| Observability | Golden signals (latency, traffic, errors, saturation) | "Operational Excellence" | n/a | V8 (data protection logs) | Practice 9 | n/a |
| Reliability | SLOs + error budgets + chaos | "Reliability" pillar | n/a | V11 | n/a | n/a |
| Performance | Latency budgets + capacity planning | "Performance Efficiency" pillar | n/a | n/a | n/a | n/a |
| Data layer | Schema review | "Reliability" + "Security" | PW.6 | V8, V14 | Practice 4 | n/a |
| API contracts | Backward-compat review | "Operational Excellence" | n/a | V13 | n/a | n/a |
| Docs | Design docs, runbooks | "Operational Excellence" + ORR | PO.4 | n/a | n/a | `CLAUDE.md` for review customization |
| Ops readiness | PRR is exactly this | ORR is exactly this | RV.1, RV.2 | n/a | Practice 9 | n/a |
| Cost | n/a (Google scale) | "Cost Optimization" pillar | n/a | n/a | n/a | n/a |
| Compliance | Internal | All pillars + ORR | All practices | All chapters | Practice 1 | n/a |

The framework below picks the strictest published bar from each cell, then defines an open-source way to prove or disprove it.

---

## The Dual-Mode Contract

Every dimension and every gate within a dimension declares its lens applicability. A gate is one of:

- **STANDALONE**: judged against the universal engineering bar. The spec doesn't matter. Example: "secrets are not in the repo" is STANDALONE; it's true or false regardless of what the project is supposed to do.
- **SCOPED**: judged against the project's spec (implementation doc, design doc, ADRs, contract, tracker). Example: "the 25-method vendor API v3 port roster is implemented per `CHECKLIST-vendor-port-methods.md`" is SCOPED; only meaningful in the Acme Phase 1A context.
- **BOTH**: has a generic version and a spec-specific version. Audited twice. Example: "idempotency exists" (STANDALONE) and "idempotency uses `email_message_id` per ADR-006" (SCOPED).

The audit runner picks the lens at audit time. The same checklist produces two report shapes:

- **Standalone Audit Report**: engineering bar pass/fail. Cite OSS framework (NIST, OWASP, AWS WAF, etc.) per gate.
- **Scope Conformance Audit Report**: spec compliance. Cite the project's own docs (impl tracker, design doc, ADRs) per gate.

A full audit runs both lenses and produces both reports. A focused audit picks one lens.

---

## Audit Cadence

When to run, how deep, who runs it. Map per dimension below.

| Trigger | Depth | Lens | Who |
|---|---|---|---|
| Pre-launch (first prod deploy) | Full audit, all 18 dimensions | Both | Owner + senior reviewer |
| Pre-deploy (every release) | Subset: CI/CD gates, SAST/SCA, smoke tests, DORA tracking | Standalone | Automated (CI) + on-call |
| Pre-merge (every PR) | Code quality, tests, SAST, secrets scan | Standalone | Automated (CI) + reviewer |
| Quarterly | Full audit, all 18 dimensions | Standalone | Owner |
| Customer security review | Full audit, focus on App Sec + Supply Chain + Compliance | Standalone | Owner + Security reviewer |
| Post-incident (per COE) | Full audit on the failed dimension + adjacent ones | Both | Incident owner + IC |
| Phase milestone (e.g., Acme Phase 1A → 1B) | Scope conformance only | Scoped | Phase owner |
| Repo handoff / new owner | Full audit, all 18 dimensions | Both | Incoming owner |

The same gate at different cadences uses the same evidence — automated tool output. PR-time runs a subset; quarterly runs the whole thing.

---

## The 19 Dimensions

Each dimension follows the same shape:

- **Definition**: what the dimension covers.
- **Why it matters**: the failure mode if you skip it.
- **Gates**: a numbered list. Each gate has a lens marker (`STANDALONE` / `SCOPED` / `BOTH`), the question to answer, the evidence to collect, and the source it traces back to.
- **Open-source tooling**: concrete tools to run. Install + invocation guidance.
- **Sources**: links to the published framework(s) that justify the gates.

---

### Rule routing

The 19 dimensions live in `references/project-audit/`, one pack per group of related
dimensions. **Read only the packs the audit's scope covers.** A scoped security review reads
one pack; a full standalone audit reads all seven. Reading all seven when the scope needs one
buries the evidence under rules that do not apply, which is the failure this split exists to
prevent.

Each pack opens with a `Scope` block naming what it covers and what it does not, so a pack
read out of scope says so in its first ten lines.

| Dimension | Pack |
| --- | --- |
| 1. Architecture and System Design | [`01-architecture-and-code.md`](references/project-audit/01-architecture-and-code.md) |
| 2. Code Quality | [`01-architecture-and-code.md`](references/project-audit/01-architecture-and-code.md) |
| 3. Testing | [`02-testing.md`](references/project-audit/02-testing.md) |
| 4. Application Security | [`03-security.md`](references/project-audit/03-security.md) |
| 5. Supply Chain and Dependencies | [`03-security.md`](references/project-audit/03-security.md) |
| 6. Secrets and Configuration | [`03-security.md`](references/project-audit/03-security.md) |
| 7. Infrastructure and Deployment | [`04-delivery.md`](references/project-audit/04-delivery.md) |
| 8. CI/CD Pipeline | [`04-delivery.md`](references/project-audit/04-delivery.md) |
| 9. Observability | [`05-runtime.md`](references/project-audit/05-runtime.md) |
| 10. Reliability | [`05-runtime.md`](references/project-audit/05-runtime.md) |
| 11. Performance and Scalability | [`05-runtime.md`](references/project-audit/05-runtime.md) |
| 12. Data Layer | [`06-data-and-contracts.md`](references/project-audit/06-data-and-contracts.md) |
| 13. API Contracts | [`06-data-and-contracts.md`](references/project-audit/06-data-and-contracts.md) |
| 14. Documentation | [`01-architecture-and-code.md`](references/project-audit/01-architecture-and-code.md) |
| 15. Operational Readiness | [`04-delivery.md`](references/project-audit/04-delivery.md) |
| 16. Cost and Resource Efficiency | [`07-cost-and-scope.md`](references/project-audit/07-cost-and-scope.md) |
| 17. Compliance and Privacy | [`03-security.md`](references/project-audit/03-security.md) |
| 18. Scope Conformance | [`07-cost-and-scope.md`](references/project-audit/07-cost-and-scope.md) |
| 19. AI/LLM Security | [`03-security.md`](references/project-audit/03-security.md) |

This file owns the cadence, the runner protocol, the report format, the severity taxonomy and
the remediation workflow. The packs own the gates. Neither restates the other.
---

## DORA Meta-Metrics

DORA isn't a dimension — it measures the team's delivery capability across all dimensions. Track these for every service, report quarterly.

| Metric | Definition | Elite | High | Medium | Low |
|---|---|---|---|---|---|
| **Deployment Frequency** | How often code reaches production | Multiple per day | Daily–weekly | Weekly–monthly | Less than monthly |
| **Lead Time for Changes** | Commit → production | < 1 hour | 1 day–1 week | 1 week–1 month | > 1 month |
| **Change Failure Rate** | % deploys causing prod incident | 0–15% | 16–30% | 31–45% | > 45% |
| **MTTR / Failed Deploy Recovery** | Time to restore service after failed deploy | < 1 hour | < 1 day | 1 day–1 week | > 1 week |
| **Rework Rate** (added 2024) | % unplanned deployments from incidents | Low | Low | Moderate | High |

DORA's core finding: **speed and stability are not tradeoffs**. Elite performers excel at all five. Low performers struggle with all five. If a team is fast on one and slow on another, the slow one is silently dragging down the fast one.

Source: [DORA 2025 State of AI-assisted Software Development](https://dora.dev/research/2025/dora-report/).

---

## Audit Runner Protocol

How to actually run an audit. Same protocol regardless of lens.

**1. Frame the audit.** Pick the lens (standalone, scoped, both). Pick the depth (full, subset). Pick the trigger context (pre-launch, quarterly, post-incident, etc.). Write it down at the top of the audit report.

**2. Collect context.** For standalone: clone the repo at the audit commit hash. For scoped: also pull the spec set (impl doc, design doc, ADRs, contract, tracker).

**3. Run the dimensions in order.** Don't skip ahead. The order is rough top-to-bottom of risk-cascade. Architecture failures invalidate code-quality findings. Code-quality failures invalidate testing findings. Etc.

**4. For each dimension, for each gate:**

- Read the gate's question.
- Run the open-source tool (or do the manual check).
- Record evidence in the report (tool output snippet, file reference, screenshot).
- Tag the finding with severity (Critical / High / Medium / Low / Info).
- For each finding, record: what, where, why it matters, how to fix.

**5. Run automated tools in parallel where possible.** SAST + SCA + secrets scan + lint + type check + tests can all run concurrently. Don't serialize.

**6. Don't fix during the audit.** Findings go in the report. Fixes go in follow-up PRs. The audit must be a snapshot — fixing mid-audit invalidates the report.

**7. Cite sources for every gate.** A finding without a cited source (this framework + the OSS framework it traces to) is a personal opinion, not an audit finding.

**8. Produce the audit report.** Single artifact. Single canonical structure. Use `AUDIT_REPORT_FORMAT.md` — copy the skeleton, fill it in, save to `<project>/AUDIT-<repo>-<YYYY-MM-DD>.md`. Both the findings and the prioritized fix list live in this one file (sections §"Detailed findings" and §"Findings prioritized" respectively).

**9. Sign off.** Auditor name + date + commit hash captured in the report's §"Sign-off" section. The audit is now historical record.

---

## Audit Report Format

Every audit run produces one report. The canonical structure, naming convention, verdict taxonomy, severity scale, evidence standard, and copy-pasteable skeleton live in a dedicated standard:

**See `AUDIT_REPORT_FORMAT.md`.**

That file is the contract between auditor and reader. Don't invent ad-hoc shapes — the format is split out so it can evolve without rewriting this framework, and so non-PROJECT_AUDIT reviews (security review, design review, customer compliance review) can adopt the same shape if useful.

Quick recap of what the format requires:

- File at `<project>/AUDIT-<repo>-<YYYY-MM-DD>.md`.
- Front-matter block: framework version, format version, auditor, target, lens, depth, trigger.
- Required sections in fixed order: TL;DR → Calibration notes → Scoped lens summary → Standalone lens summary → Detailed findings → Tool gates not run → Findings prioritized → Framework feedback → Sign-off.
- Verdict labels: `PASS / WARN / FAIL / N/A / TOOL-NEEDED` at gate and dimension level.
- Priority labels: `P0 / P1 / P2 / P3` at finding level.
- Every finding cites evidence (`path:line` or tool snippet or spec reference).

---

## Severity Taxonomy

Same scale across all dimensions. Inherited from OWASP + Anthropic Claude Code Review.

The audit report uses a single `P0 / P1 / P2 / P3` scale that combines severity and priority. Defined in `AUDIT_REPORT_FORMAT.md` §"Severity / priority taxonomy". Mapping for teams that prefer the older Critical / High / Medium / Low scale:

| P-tag | Older severity | Definition | Action |
|---|---|---|---|
| `P0` | Critical | Active exploit risk, data loss risk, hard outage risk, or real bug already exploitable. | Fix before next merge. Page if found in production. |
| `P1` | High | Latent vulnerability, missing-but-required practice, or spec violation that will bite within the next release. | Fix before next release. Tracked ticket. Owner named in the report. |
| `P2` | Medium | Quality / maintainability / minor reliability gap. Won't break anything immediately. | Tracked ticket. Fix opportunistically. |
| `P3` | Low + Info | Style, docs, nit, or "out of scope but worth noting." | Optional. Inform team. |

Anthropic's Claude Code uses three labels (Important / Nit / Pre-existing) which map cleanly: Important = P0 + P1, Nit = P2 + P3, Pre-existing = P3 (info).

---

## Remediation Workflow

How findings turn into fixes.

**1. Filter by priority.** P0 and P1 block the next gate (merge / release / launch, depending on the audit trigger). P2 and P3 ship.

**2. Owner per finding.** No anonymous fixes. Every P0 and P1 has a named owner before the audit closes.

**3. Tracked in the issue tracker.** Every P1 and P2 gets a ticket. P0 fixes happen before the next merge — ticket optional but evidence required.

**4. Re-audit on fix.** Every fix is verified by re-running the same gate. The fix-PR description cites the audit finding ID.

**5. Pattern detection.** If three findings of the same shape appear, lift them to a TECH_DEBT entry or a process change. Pointlessly fixing the same bug shape over and over is its own anti-pattern.

---

## Quick Checklist

Use this as a one-pager for an audit you're running solo.

- [ ] Lens picked (standalone / scoped / both).
- [ ] Trigger context recorded.
- [ ] Spec set collected (if scoped).
- [ ] Repo cloned at audit commit hash.
- [ ] All 19 dimensions run in order (D19 applies only if the service uses LLM/AI components).
- [ ] Every gate has evidence.
- [ ] Every fail has a P-tag (P0 / P1 / P2 / P3).
- [ ] Every P0 and P1 has a named owner.
- [ ] Audit report file written to `<project>/AUDIT-<repo-name>-<date>.md` per `AUDIT_REPORT_FORMAT.md`.
- [ ] §"Findings prioritized" populated (every finding listed once, sorted by P-tag).
- [ ] DORA metrics recorded (if pre-launch or quarterly).
- [ ] Sign-off block populated.
- [ ] Ticket created for every P1 and P2.

---

## Anti-Patterns

The audit failure modes.

- **Audit-as-opinion.** Findings without cited sources. The auditor's seniority is not a citation.
- **Audit-as-blame.** Naming engineers in the report instead of patterns/files. The COE doctrine applies — blameless or it doesn't get done next time.
- **Audit-as-rebuild.** Findings that say "the architecture should be different". An audit measures against the spec; if the spec is wrong, that's a separate document (design proposal). Don't conflate.
- **Audit-by-tooling.** Running the tools and shipping the raw output as the report. The auditor's job is interpretation, prioritization, and remediation guidance.
- **Audit-without-evidence.** "I think there's a problem with X" without a tool output, file reference, or repro. Every finding must be reproducible by a different reader.
- **Audit-without-cadence.** A one-off audit that never runs again. The next audit is always the most useful one.
- **Audit-with-fix.** Fixing things mid-audit. The audit becomes unreproducible and the next reviewer can't trust the snapshot.
- **Skipping a dimension because "it doesn't apply".** It probably does, even if at a low bar. Mark it `n/a` with a one-sentence justification — never just skip.

---

## Sources

Live links to every source cited above. Last refreshed 2026-04-26.

**Source freshness notes:**
- OWASP ASVS references are per v5.0 (May 2025). Chapter numbers changed significantly from v4.0.3; see the OWASP migration guide for mappings.
- AWS WAF references include the April 2025 refresh (78 updated best practices, Reliability pillar updated for the first time since 2022).
- Twelve-Factor is cited for factors still current in 2026 (1-6, 8-12). Factor 7 (port binding) is partially superseded by service meshes. Factor 11 (logs) is expanded by D9 to include metrics and traces. Known gaps (security, observability beyond logs, API design) are covered by D4, D9, D10, D13, and D19.

**Engineering practices.**

- Google Engineering Practices: <https://google.github.io/eng-practices/>
- Google Engineering Practices — code review standard: <https://google.github.io/eng-practices/review/reviewer/standard.html>
- PEP 257 (docstring conventions): <https://peps.python.org/pep-0257/>
- PEP 484 (type hints): <https://peps.python.org/pep-0484/>

**Site reliability + production readiness.**

- Google SRE Book: <https://sre.google/sre-book/>
- Google SRE — Production Readiness Review pattern: <https://sre.google/sre-book/evolving-sre-engagement-model/>
- Google SRE — Launch Coordination Checklist: <https://sre.google/sre-book/launch-checklist/>
- USENIX — Production Readiness Reviews: A Surprisingly Versatile Practice (2024): <https://www.usenix.org/publications/loginonline/production-readiness-reviews-surprisingly-versatile-practice>
- AWS Operational Readiness Reviews (ORR): <https://docs.aws.amazon.com/wellarchitected/latest/operational-readiness-reviews/wa-operational-readiness-reviews.html>
- AWS Correction of Errors (COE): <https://aws.amazon.com/blogs/mt/why-you-should-develop-a-correction-of-error-coe/>

**Architecture + quality.**

- AWS Well-Architected Framework (Nov 2024 revision, April 2025 refresh): <https://docs.aws.amazon.com/wellarchitected/latest/framework/welcome.html>
- ISO/IEC 25010:2023 (product quality model): <https://www.iso.org/standard/78176.html>
- The Twelve-Factor App: <https://12factor.net/>
- CNCF TAG App Delivery: <https://tag-app-delivery.cncf.io/>

**Security + compliance.**

- NIST SSDF SP 800-218: <https://csrc.nist.gov/projects/ssdf>
- OWASP ASVS 5.0 (May 2025): <https://asvs.dev/>
- OWASP Top 10 for LLM Applications 2025: <https://owasp.org/www-project-top-10-for-large-language-model-applications/>
- SLSA v1.1: <https://slsa.dev/spec/v1.1/levels>
- Microsoft Security Development Lifecycle (SDL): <https://www.microsoft.com/en-us/securityengineering/sdl/practices>
- Microsoft SDL for AI (Feb 2026): <https://www.microsoft.com/en-us/security/blog/2026/02/03/microsoft-sdl-evolving-security-practices-for-an-ai-powered-world/>

**Delivery performance.**

- DORA 2025 State of DevOps: <https://dora.dev/research/2025/dora-report/>
- DORA Four Keys: <https://dora.dev/guides/dora-metrics-four-keys/>

**Agent-driven review.**

- Anthropic Claude Code best practices: <https://docs.anthropic.com/en/docs/claude-code/best-practices>
- Anthropic Claude Code — code review: <https://docs.anthropic.com/en/docs/claude-code/code-review>
- Anthropic Claude Code — automated security reviews: <https://support.anthropic.com/en/articles/11932705-automated-security-reviews-in-claude-code>

**Industry context.**

- Stripe engineering culture: <https://newsletter.pragmaticengineer.com/p/stripe-part-2>
- Stripe Sorbet: <https://stripe.com/blog/sorbet-stripes-type-checker-for-ruby>
- Netflix chaos engineering + incident management: <https://netflixtechblog.com/tagged/chaos-engineering>

**Acceptance test for the framework itself:** a senior engineer + an AI agent can pick this doc up cold, point it at any repo, and produce a defensible audit report within one working session for standalone-lens, or two working sessions for both-lens.

[architecture and code]: references/project-audit/01-architecture-and-code.md
[cost and scope]: references/project-audit/07-cost-and-scope.md
[data and contracts]: references/project-audit/06-data-and-contracts.md
[delivery]: references/project-audit/04-delivery.md
[runtime]: references/project-audit/05-runtime.md
[security]: references/project-audit/03-security.md
[testing]: references/project-audit/02-testing.md
