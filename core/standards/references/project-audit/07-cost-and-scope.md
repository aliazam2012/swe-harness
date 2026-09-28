# Audit dimensions: Cost efficiency and scope conformance

Dimension pack for `PROJECT_AUDIT.md`. Read it only when the audit's scope covers one of these dimensions.

## Scope

- Covers: dimension 16 (Cost and Resource Efficiency), dimension 18 (Scope Conformance).
- Does NOT cover: the other 19-dimension packs in this directory (`01-architecture-and-code.md`, `02-testing.md`, `03-security.md`, `04-delivery.md`, `05-runtime.md`, `06-data-and-contracts.md`), nor the cadence, runner protocol, report format, severity taxonomy or remediation workflow, which `PROJECT_AUDIT.md` owns.

---

### 16. Cost and Resource Efficiency

**Definition.** What the system costs to run, and whether it's spending right. Includes infra cost, license cost, build/CI cost, observability data cost.

**Why it matters.** Cost is the constraint that forces architecture choices to face reality. An over-provisioned service hides reliability bugs; an under-provisioned one becomes one. Cost discipline is the canary for engineering discipline.

**Gates.**

1. `STANDALONE`. Cost attribution per environment + per service. Tags on every cloud resource. Evidence: cloud billing dashboard. Source: AWS WAF Cost Optimization.
2. `STANDALONE`. Cost budget set. Alert when projected spend exceeds budget. Evidence: budget alert config. Source: AWS WAF Cost Optimization.
3. `STANDALONE`. Right-sizing review done at least quarterly. Idle resources removed. Evidence: review record. Source: AWS WAF Cost Optimization.
4. `STANDALONE`. Auto-scaling has a max cap. No runaway scaling. Evidence: scaling policy. Source: AWS WAF Cost Optimization + Performance.
5. `STANDALONE`. Observability data volume understood and capped. Logs/metrics retention policy explicit. Evidence: retention config. Source: AWS WAF Cost.
6. `STANDALONE`. Dev/stage environments shut down outside business hours (where applicable). Evidence: schedule. Source: AWS WAF Cost.
7. `STANDALONE`. CI/CD minutes monitored. Long-running jobs identified. Evidence: pipeline metrics. Source: open-source norms.

**Open-source tooling.**

- `infracost`: cost diff from Terraform plan. CI integration available.
- `cloudability` (paid) / native AWS Cost Explorer (free with AWS account): usage attribution.
- `kubecost` (open source): Kubernetes cost allocation.
- `opencost` (CNCF): cost allocation for any container env.

**Sources.** AWS WAF (Cost Optimization pillar).

---


### 18. Scope Conformance

**Definition.** The pure-scoped dimension. Does the project deliver exactly what the spec says it should, no more and no less?

**Why it matters.** Scope creep is the most expensive form of "good intent". Missing scope is the most expensive form of "shipped early". This dimension exists to keep both honest.

**Gates.**

1. `SCOPED`. Every Definition of Done line in the implementation doc has corresponding code. Evidence: DoD ↔ code map. Source: `IMPLEMENTATION_DOC_FORMAT.md`.
2. `SCOPED`. Every Goal in the spec is met. Evidence: goal ↔ test map. Source: spec.
3. `SCOPED`. No Non-Goal accidentally in scope. Evidence: code audit against non-goals list. Source: spec.
4. `SCOPED`. Every Decision Locked In has been respected. Evidence: code audit against decisions list. Source: spec.
5. `SCOPED`. Every ADR is honored. Evidence: code audit against ADR set. Source: ADR set.
6. `SCOPED`. Every step in the implementation plan is either ✅ done or ❌ explicitly deferred with a tracking entry. Evidence: step status table. Source: spec.
7. `SCOPED`. Open questions in the spec are either resolved (linked to ADR or decision record) or have an owner + due date. Evidence: open-questions section. Source: spec.
8. `SCOPED`. Risks listed in the spec are either mitigated or have a tracked mitigation. Evidence: risk register. Source: spec.

**Open-source tooling.**

This dimension is doc-to-code cross-referencing. No tool replaces a careful read. Useful aids:

- `grep` / `ripgrep`: find references to step IDs, T-IDs, ADR IDs in code and docs.
- Custom `pytest` markers — tag tests with the DoD line they cover. `pytest --markers` lists coverage.
- Issue tracker integration — every spec line links to a closed issue/PR.

**Sources.** An implementation-document format, plus ordinary spec discipline.

---
