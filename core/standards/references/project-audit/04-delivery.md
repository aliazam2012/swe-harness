# Audit dimensions: Infrastructure, CI/CD and operational readiness

Dimension pack for `PROJECT_AUDIT.md`. Read it only when the audit's scope covers one of these dimensions.

## Scope

- Covers: dimension 7 (Infrastructure and Deployment), dimension 8 (CI/CD Pipeline), dimension 15 (Operational Readiness).
- Does NOT cover: the other 19-dimension packs in this directory (`01-architecture-and-code.md`, `02-testing.md`, `03-security.md`, `05-runtime.md`, `06-data-and-contracts.md`, `07-cost-and-scope.md`), nor the cadence, runner protocol, report format, severity taxonomy or remediation workflow, which `PROJECT_AUDIT.md` owns.

---

### 7. Infrastructure and Deployment

**Definition.** Where the service runs. How it's provisioned. How it's deployed. How it scales. How it's networked. How it's torn down.

**Why it matters.** Code that works on a laptop and dies in prod is a story everyone has lived. Infra parity is the difference.

**Gates.**

1. `STANDALONE`. Infrastructure defined as code (Terraform, CloudFormation, CDK, Pulumi). No click-ops. Evidence: IaC repo + plan output. Source: AWS WAF Operational Excellence.
2. `STANDALONE`. Per-environment IaC isolation. Dev / stage / prod separate state files + accounts (or at minimum, separate IAM roles). Evidence: state file layout. Source: AWS WAF Security.
3. `STANDALONE`. IaC linted. Evidence: `tflint` + `tfsec` + `checkov` exit code 0. Source: NIST SSDF PO.3.
4. `STANDALONE`. Deployment is automated. No SSH-in-and-edit. Evidence: deploy pipeline definition. Source: Twelve-Factor 5.
5. `STANDALONE`. Deployment is reversible. Rollback procedure documented and tested. Evidence: rollback runbook. Source: AWS WAF Operational Excellence.
6. `STANDALONE`. Blue/green or canary deploys for any service with > 1 instance. Evidence: deploy config. Source: Google SRE.
7. `STANDALONE`. Health checks defined. Liveness + readiness separated. Evidence: probe config. Source: CNCF + Twelve-Factor 9.
8. `STANDALONE`. Graceful shutdown handles SIGTERM. Drains in-flight requests within configured window. Evidence: signal handler + drain test. Source: Twelve-Factor 9 + CNCF.
9. `STANDALONE`. Resource limits set (CPU, memory, file descriptors, connection pool). Evidence: container/process config. Source: AWS WAF Performance.
10. `STANDALONE`. Network attack surface minimal. Only the ports the service needs are exposed. Evidence: security group / firewall rules. Source: AWS WAF Security.
11. `BOTH`. Deployment shape matches design. Standalone: any deploy shape works. Scoped: matches spec (single env, multi-env, blue/green, etc.). Evidence: design doc ↔ IaC. Source: project-specific.

**Open-source tooling.**

- `terraform` + `terragrunt`: IaC.
- `tflint`: Terraform linter.
- `tfsec`: Terraform security scanner.
- `checkov`: multi-cloud + multi-IaC security/compliance scanner.
- `kube-linter`: Kubernetes manifest linter.
- `kubeval`: Kubernetes manifest schema validation.
- `kustomize` / `helm`: manifest templating.
- `argocd` / `flux`: GitOps deploy controllers.
- `infracost`: cost estimate from Terraform plan (also covered in §16).

**Sources.** AWS WAF (Op Excellence + Security + Reliability) · Twelve-Factor (5, 9, 10) · CNCF · Google SRE.

---


### 8. CI/CD Pipeline

**Definition.** The conveyor belt from `git push` to running code. Every gate that runs automatically before a change ships.

**Why it matters.** The pipeline is the place to enforce every other dimension. What ships to prod is exactly what the pipeline allows. If the pipeline doesn't gate on it, it doesn't matter that you wrote it down.

**Gates.**

1. `STANDALONE`. Build is reproducible. Same commit → same artifact. Evidence: byte-identical artifacts on rebuild. Source: SLSA L1.
2. `STANDALONE`. Lint, format, type check run on every PR. Evidence: CI workflow file. Source: Google Engineering Practices.
3. `STANDALONE`. Test suite runs on every PR with coverage gate. Evidence: CI workflow + coverage threshold check. Source: NIST SSDF PW.7.
4. `STANDALONE`. SAST runs on every PR. Findings block merge. Evidence: workflow + status check. Source: NIST SSDF PW.6.
5. `STANDALONE`. SCA (dep vuln scan) runs on every PR + nightly on `main`. Evidence: workflow. Source: NIST SSDF PS.3.
6. `STANDALONE`. Secret scan runs on every PR. Evidence: `gitleaks` job. Source: NIST SSDF PS.2.
7. `STANDALONE`. Branch protection enforced on long-lived branches. No direct push, required reviewers, required status checks. Evidence: GitHub branch protection settings. Source: Google "Speed of code reviews" + NIST SSDF PO.3.
8. `STANDALONE`. Required reviewer count ≥ 1 (≥ 2 for high-risk paths). CODEOWNERS routing. Evidence: branch protection + `CODEOWNERS` file. Source: Google Engineering Practices.
9. `STANDALONE`. Deploy to staging is automated and runs smoke tests. Evidence: workflow. Source: AWS WAF Op Excellence.
10. `STANDALONE`. Deploy to prod requires approval gate or auto-promotes only after staging soak period. Evidence: workflow. Source: AWS WAF Reliability.
11. `STANDALONE`. Pipeline workflows themselves are linted. Evidence: `actionlint` for GitHub Actions. Source: NIST SSDF PO.3.
12. `STANDALONE`. Build provenance signed and stored. Evidence: SLSA attestation in artifact metadata. Source: SLSA L2.

**Open-source tooling.**

- `actionlint`: GitHub Actions workflow linter.
- `pre-commit`: local-side gate.
- GitHub Actions / GitLab CI / Drone: pipeline runner (open core or fully OSS).
- `act`: run GitHub Actions locally for debugging workflows.
- `slsa-github-generator`: SLSA L3 provenance from GitHub Actions.
- `cosign`: sign container images and SBOMs.

**Sources.** SLSA v1.1 · NIST SSDF PO.3/PS.3/PW.6/PW.7 · Google Engineering Practices · AWS WAF Op Excellence + Reliability.

---


### 15. Operational Readiness

**Definition.** The non-code artifacts that let humans run the system. Runbooks, on-call rotation, escalation paths, SLOs, error budgets, incident process.

**Why it matters.** Code that ships without ops readiness is a future incident with extra steps. PRR exists exactly to gate on this.

**Gates.**

1. `STANDALONE`. On-call rotation defined. Primary + secondary. Evidence: rotation schedule. Source: Google SRE.
2. `STANDALONE`. Pager wired to SLO violations. Evidence: alert config. Source: Google SRE.
3. `STANDALONE`. Runbook for every alert. Steps to triage, diagnose, mitigate, escalate. Evidence: runbook dir. Source: Google SRE PRR.
4. `STANDALONE`. Incident response process documented. Roles (IC, comms, scribe). Evidence: incident playbook. Source: Google SRE + AWS COE.
5. `STANDALONE`. COE template (or equivalent post-incident review) defined. Last incident has a written COE. Evidence: COE doc. Source: AWS COE.
6. `STANDALONE`. Operational dashboards exist and are linked from the README. Evidence: dashboard URL in README. Source: Google SRE.
7. `STANDALONE`. Service tier defined. Tier 1 / Tier 2 / Tier 3 with associated SLOs and on-call expectations. Evidence: service tier doc. Source: AWS WAF Op Excellence.
8. `STANDALONE`. Pre-launch checklist (PRR/ORR equivalent) signed off before first prod deploy. Evidence: signed checklist. Source: Google SRE PRR + AWS ORR.
9. `BOTH`. Operational expectations match the spec. Standalone: any operational baseline. Scoped: matches the spec's HITL/escalation/SLA requirements. Evidence: spec ↔ runbook. Source: project-specific.
10. `STANDALONE`. Incident severity levels defined (at least 3 tiers) with response time targets per level. Example: SEV-1 (service down, 15 min response), SEV-2 (degraded, 1 hr response), SEV-3 (minor, next business day). Evidence: incident playbook with severity table. Source: Netflix incident management + Google SRE.
11. `STANDALONE`. Postmortems completed within 5 business days of incident resolution. Action items tracked to completion. Evidence: postmortem timestamps + action item tracking. Source: Google SRE Postmortem Culture.
12. `STANDALONE`. Kill switch runbook exists. Documents: how to activate (command, URL, or config change), what gets suppressed, what happens to in-flight and queued requests, how to verify the switch is active, and how to resume. Tested at least once before production launch. Evidence: runbook + test record. Source: D10.15 (kill switch gate) plus ordinary operational safety.

**Open-source tooling.**

- Runbook format: plain Markdown with a consistent shape (symptom → diagnosis → mitigation → escalation).
- `oncall` (LinkedIn-OSS): on-call rotation manager.
- `cabot`: alerting + on-call (open source).
- `incidentbot`: Slack-based incident response.
- `dispatch` (Netflix-OSS, archived but reference): incident management.
- COE / postmortem template: see AWS WAF docs (publicly available text template).

**Sources.** Google SRE PRR · Google SRE Book (Incident Response, Postmortems) · Netflix Incident Management · AWS ORR · AWS COE.

---
