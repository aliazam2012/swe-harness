# Audit dimensions: Application security, supply chain, secrets, privacy and AI

Dimension pack for `PROJECT_AUDIT.md`. Read it only when the audit's scope covers one of these dimensions.

## Scope

- Covers: dimension 4 (Application Security), dimension 5 (Supply Chain and Dependencies), dimension 6 (Secrets and Configuration), dimension 17 (Compliance and Privacy), dimension 19 (AI/LLM Security).
- Does NOT cover: the other 19-dimension packs in this directory (`01-architecture-and-code.md`, `02-testing.md`, `04-delivery.md`, `05-runtime.md`, `06-data-and-contracts.md`, `07-cost-and-scope.md`), nor the cadence, runner protocol, report format, severity taxonomy or remediation workflow, which `PROJECT_AUDIT.md` owns.

---

### 4. Application Security

**Definition.** Defending the running application from attack. Input validation, output encoding, authn/authz, session management, crypto, error handling that doesn't leak, OWASP Top 10 coverage.

**Why it matters.** This is what gets the company on the front page of the news for the wrong reason. Every other dimension is upstream of this; AppSec is where the dollar value of failure lives.

**Gates.**

1. `STANDALONE`. All inputs validated at the trust boundary (HTTP handler, queue consumer, file reader). Evidence: Pydantic schema or equivalent on every entry point. Source: OWASP ASVS V5 (validation).
2. `STANDALONE`. Output encoding correct for sink (HTML, JSON, SQL, shell). No string concatenation into queries or commands. Evidence: parametrized queries everywhere. Source: OWASP ASVS V5.
3. `STANDALONE`. AuthN per request, AuthZ per resource. No "logged in user can do anything" paths. Evidence: middleware audit + per-route decorators. Source: OWASP ASVS V1, V2, V3.
4. `STANDALONE`. Crypto uses standard library or vetted library, no custom algorithms. TLS 1.2+ for transport. Evidence: dep audit. Source: Microsoft SDL Practice 4.
5. `STANDALONE`. Error responses don't leak stack traces, internal paths, SQL fragments to external callers. Evidence: error handler audit. Source: OWASP ASVS V8.
6. `STANDALONE`. SAST clean. No High or Critical findings. Evidence: `bandit` + `semgrep` scan. Source: NIST SSDF PW.6.
7. `STANDALONE`. DAST clean on running service. No High or Critical findings. Evidence: `nuclei` or `OWASP ZAP` baseline scan. Source: NIST SSDF PW.7.
8. `STANDALONE`. Threat model exists with: (a) a Data Flow Diagram showing trust boundaries, (b) STRIDE or equivalent threat enumeration per boundary, (c) documented mitigations per identified threat. Covers the OWASP Top 10 Web (2021) and, if the service uses LLM/AI components, the OWASP Top 10 for LLMs (2025). Evidence: threat model doc with DFD + threat table + mitigation status. Source: Microsoft SDL Practice 3 + OWASP.
9. `BOTH`. PII handling matches data classification. Standalone: minimum encrypted at rest + in transit. Scoped: matches the spec's data sensitivity declaration. Evidence: code audit + contract. Source: NIST SSDF PW.5.
10. `STANDALONE`. Rate limiting and abuse-prevention on every public endpoint. Evidence: middleware. Source: OWASP ASVS V11.

**Open-source tooling.**

- `bandit`: Python AST-based security linter. `bandit -r app/`.
- `semgrep`: multi-language SAST with rule packs. `semgrep --config=auto`.
- `pip-audit`: dependency CVE scan (covers SSDF + ASVS V14).
- `safety`: alternative dep scanner.
- `trufflehog` / `gitleaks`: secret detection (covered in §6 too).
- `nuclei`: DAST template scanner.
- `OWASP ZAP`: DAST proxy.
- `sqlmap`: SQLi-specific DAST.

**Sources.** OWASP ASVS 5.0 · Microsoft SDL · NIST SSDF PW.5/PW.6 · OWASP Top 10.

---


### 5. Supply Chain and Dependencies

**Definition.** Every line of code shipped that wasn't written by the team. Direct deps, transitive deps, build-time tools, container base images, CI runners. SLSA territory.

**Why it matters.** Solarwinds, log4shell, ua-parser-js. The attacker's highest-leverage move is upstream of you. If you don't know what's in your build, you can't defend it.

**Gates.**

1. `STANDALONE`. Lockfile committed. Reproducible builds. Evidence: `requirements.txt` with hashes or `poetry.lock` or `uv.lock` committed. Source: SLSA L1.
2. `STANDALONE`. All deps pinned to specific versions. No floating ranges in production deps. Evidence: lockfile audit. Source: SLSA L1.
3. `STANDALONE`. Dependency CVE scan clean (no High/Critical). Evidence: `pip-audit` exit code 0 for High+. Source: NIST SSDF PS.3.
4. `STANDALONE`. Transitive dep depth and count understood. Evidence: `pipdeptree` output reviewed. Source: SLSA principles.
5. `STANDALONE`. Container base image is minimal and scanned. Evidence: `trivy image` clean for High+. Source: SLSA L2.
6. `STANDALONE`. SBOM produced for every release. Evidence: `syft` or `cyclonedx-py` artifact. Source: NIST SSDF PS.3 + SLSA L1.
7. `STANDALONE`. Build provenance attestation generated. Evidence: SLSA provenance file. Source: SLSA L2/L3.
8. `STANDALONE`. Dependency licenses compatible with project license. No GPL in MIT/Apache project (or vice versa) without intent. Evidence: `pip-licenses` review. Source: NIST SSDF PS.1.
9. `STANDALONE`. No deps that are abandoned (last release > 2 years and < 50 stars). Evidence: `deptry` or manual audit. Source: NIST SSDF PS.1.
10. `STANDALONE`. Dependabot or equivalent automated PR for security updates. Evidence: `.github/dependabot.yml` or Renovate config. Source: SLSA + NIST SSDF RV.1.

**Open-source tooling.**

- `pip-audit`: CVE scan against PyPI advisory + OSV. `pip-audit -r requirements.txt`.
- `safety`: alternative dep scanner.
- `pipdeptree`: transitive dep visualization.
- `syft`: SBOM generation. `syft dir:.` produces CycloneDX or SPDX.
- `grype`: vuln scan against SBOM.
- `trivy`: container + filesystem + SBOM scanner. `trivy image <image>`.
- `osv-scanner`: Google's cross-ecosystem CVE scanner.
- `pip-licenses`: license audit.
- `deptry`: dead deps + missing deps.
- Dependabot or Renovate: automated update PRs.
- `slsa-github-generator`: provenance generation in GitHub Actions.

**Sources.** SLSA v1.1 · NIST SSDF PS.1/PS.3 · OWASP ASVS V14.

---


### 6. Secrets and Configuration

**Definition.** Where the secrets live, how they're rotated, how they're injected. How config differs across environments and how that doesn't leak production into dev.

**Why it matters.** A leaked secret is a one-line CVE that takes weeks to remediate. Hardcoded config is the bug that ships to prod silently.

**Gates.**

1. `STANDALONE`. Zero secrets in the repo. Ever. Evidence: `gitleaks` scan of full git history. Source: NIST SSDF PS.2.
2. `STANDALONE`. Secrets in a vault (AWS Secrets Manager, HashiCorp Vault, GCP Secret Manager). Evidence: code retrieves at runtime. Source: NIST SSDF PS.2 + Twelve-Factor Factor 3.
3. `STANDALONE`. Config in env vars (Twelve-Factor compliant). No `.env` files in production images. Evidence: image audit. Source: Twelve-Factor 3.
4. `STANDALONE`. Per-environment config is explicit, not implicit. Evidence: separate `dev`/`stage`/`prod` config files or env-var sets. Source: Twelve-Factor 10.
5. `STANDALONE`. `.env.example` (or equivalent) checked in with all required keys, blank values. Evidence: file exists + matches actual `.env`. Source: Twelve-Factor.
6. `STANDALONE`. Secret rotation defined and tested. Evidence: rotation runbook exists, last rotation date < 90 days. Source: NIST SSDF PS.2.
7. `STANDALONE`. Secret access is audited at the vault layer. Evidence: CloudTrail / vault audit log enabled. Source: OWASP ASVS V6.
8. `STANDALONE`. Pre-commit secret scan installed. Evidence: `.pre-commit-config.yaml` runs `gitleaks` or `detect-secrets`. Source: NIST SSDF PS.2.
9. `BOTH`. Configuration matches the spec. Standalone: env vars documented. Scoped: every spec'd config knob is wired. Evidence: cross-reference design doc ↔ `.env.example`. Source: project-specific.

**Open-source tooling.**

- `gitleaks`: full-history secret scan. Run pre-commit + in CI on full repo.
- `trufflehog`: alternative, broader regex set, can scan more sources.
- `detect-secrets`: Yelp's tool, supports baseline files for managed exclusions.
- `pre-commit` framework — wires the above into the dev loop.
- `python-decouple` / `pydantic-settings`: env-var loading with type coercion.

**Sources.** Twelve-Factor (Factors 3 + 10) · NIST SSDF PS.2 · OWASP ASVS V6 + V14.

---


### 17. Compliance and Privacy

**Definition.** External obligations the system must meet — data privacy laws (GDPR, CCPA), industry standards (SOC 2, ISO 27001, HIPAA, PCI), customer-specific contractual security requirements (e.g., Acme standalone instance).

**Why it matters.** A non-compliant system is a system that can't sell to certain customers. For Acme-class accounts, this is the gate. For agent-handled customer data, GDPR/CCPA are non-optional.

**Gates.**

1. `STANDALONE`. Data classification documented. PII, financial, regulated, public — labeled per field/table. Evidence: classification doc. Source: NIST SSDF PW.5.
2. `STANDALONE`. Data flow diagram exists. Where data enters, where it's stored, where it leaves, who touches it. Evidence: DFD. Source: NIST + Microsoft SDL Practice 3.
3. `STANDALONE`. Right-to-delete process defined and tested (GDPR Article 17, CCPA). Evidence: deletion runbook. Source: GDPR + CCPA.
4. `STANDALONE`. Data residency per customer requirement (e.g., Acme may require US-only). Evidence: infra placement. Source: customer contracts.
5. `STANDALONE`. Audit log retention meets compliance requirement (often 1+ year for SOC 2). Evidence: retention policy. Source: SOC 2.
6. `STANDALONE`. Vendor risk assessment for every third-party data processor. Evidence: vendor list + DPAs. Source: GDPR.
7. `BOTH`. Customer-specific compliance requirements met. Scoped: per customer contract. Evidence: contract clause ↔ controls map. Source: project-specific.

**Open-source tooling.**

- `cloudquery`: cloud asset inventory (multi-cloud).
- `prowler`: AWS/Azure/GCP compliance scanner with SOC 2, HIPAA, PCI rule sets.
- `kube-bench`: CIS Kubernetes benchmark compliance.
- `lynis`: Linux audit + hardening.

**Sources.** NIST SSDF PW.5 · GDPR · CCPA · SOC 2 · Microsoft SDL Practice 3.

---


### 19. AI/LLM Security

**Definition.** Security, cost, and correctness risks specific to services that integrate LLM/AI components. Prompt injection, data leakage through model I/O, unbounded consumption, output validation, and model supply chain.

**Why it matters.** LLM integrations introduce a category of risk that traditional AppSec gates don't cover. The model is a third-party execution environment that processes untrusted input and produces non-deterministic output. OWASP published a dedicated Top 10 for LLM Applications (2025). Microsoft updated its SDL in Feb 2026 with AI-specific threat modeling, observability, and memory protections. Any service that calls an LLM must be audited against these risks.

**Gates.**

1. `STANDALONE`. Prompt injection defense: user-supplied content is never concatenated into the system prompt. Untrusted input is isolated in a clearly delimited user-content block. Evidence: prompt template audit. Source: OWASP LLM01:2025.
2. `STANDALONE`. System prompt contains no secrets, credentials, connection strings, API keys, or internal URLs. Disclosure of the system prompt must not grant the attacker any capability. Evidence: prompt content audit. Source: OWASP LLM07:2025.
3. `STANDALONE`. LLM output is validated before downstream use. Structured output schema enforced (Pydantic model, JSON schema, or equivalent). Raw model text is never written to a database or returned to a user without validation. Evidence: output validation audit. Source: OWASP LLM05:2025.
4. `STANDALONE`. LLM cost is bounded. Per-request token limits, per-user/per-minute rate limits, and total monthly spend caps configured. An attacker who can trigger LLM calls cannot run up an unbounded bill. Evidence: config audit + rate limit middleware. Source: OWASP LLM10:2025.
5. `STANDALONE`. PII minimization before LLM input. Only the data required for the extraction/classification task is sent. Customer PII not needed by the model is stripped or masked before the prompt is assembled. Evidence: prompt assembly code audit. Source: OWASP LLM02:2025.
6. `STANDALONE`. LLM provider is a swappable backing service. Model selection, API key, endpoint URL, and model parameters are config-driven. Switching providers requires no code change. Evidence: adapter audit. Source: Twelve-Factor 4 + Microsoft SDL for AI.
7. `STANDALONE`. Model version is pinned. No implicit "latest" that silently changes extraction behavior between deploys. Evidence: model config (e.g. `gpt-4o-2024-08-06` not `gpt-4o`). Source: Microsoft SDL for AI.
8. `BOTH`. AI-specific threat model exists. Covers: prompt injection vectors, data exfiltration through model output, model abuse/cost attacks, hallucination impact on downstream decisions. Standalone: threat model exists. Scoped: matches the spec's AI risk analysis. Evidence: threat model doc. Source: Microsoft SDL for AI Practice 3 + OWASP Top 10 for LLMs.

**Open-source tooling.**

- `promptfoo`: LLM red-teaming and eval framework. Tests prompt injection, jailbreaks, and output quality.
- `garak`: LLM vulnerability scanner (probes for injection, leakage, toxicity).
- `rebuff`: prompt injection detection library.
- `guardrails-ai`: output validation framework for LLM responses.
- `langchain` structured output: `with_structured_output()` enforces Pydantic schema on model responses.
- `tiktoken`: token counting for cost bounding.

**Sources.** OWASP Top 10 for LLM Applications 2025 · Microsoft SDL for AI (Feb 2026) · Anthropic responsible scaling policy · OpenAI usage policies · Twelve-Factor 4.
