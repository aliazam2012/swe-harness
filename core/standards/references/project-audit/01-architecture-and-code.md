# Audit dimensions: Architecture, code quality and documentation

Dimension pack for `PROJECT_AUDIT.md`. Read it only when the audit's scope covers one of these dimensions.

## Scope

- Covers: dimension 1 (Architecture and System Design), dimension 2 (Code Quality), dimension 14 (Documentation).
- Does NOT cover: the other 19-dimension packs in this directory (`02-testing.md`, `03-security.md`, `04-delivery.md`, `05-runtime.md`, `06-data-and-contracts.md`, `07-cost-and-scope.md`), nor the cadence, runner protocol, report format, severity taxonomy or remediation workflow, which `PROJECT_AUDIT.md` owns.

---

### 1. Architecture and System Design

**Definition.** The shape of the system. Components, their boundaries, the contracts between them, the patterns chosen, and the trade-offs accepted.

**Why it matters.** Architecture decisions are the most expensive ones to reverse. A repo with 95% test coverage but a wrong-shape architecture is a repo with 95% confidence in the wrong thing.

**Gates.**

1. `BOTH`. A design doc or ADR set exists and is current. Standalone lens: any architecture doc at all. Scoped lens: design matches what was approved before code started. Evidence: link to design doc + ADRs. Source: Google design-doc culture, AWS WAF "Operational Excellence" pillar.
2. `STANDALONE`. Component boundaries are explicit. Each module has a single responsibility. Evidence: directory layout + module docstrings. Source: ISO/IEC 25010 "Modularity" sub-characteristic.
3. `STANDALONE`. Cross-component contracts are typed and validated at the boundary. Evidence: DTOs, Pydantic models, OpenAPI spec, gRPC proto. Source: Stripe API review.
4. `BOTH`. Threat model exists. Standalone: any threat model. Scoped: matches the system's actual data flow. Evidence: threat model doc with STRIDE or similar. Source: Microsoft SDL Practice 3.
5. `STANDALONE`. Pattern choice is documented and justified (Ports & Adapters, Hexagonal, MVC, event-driven, etc.). Evidence: design doc section. Source: Google design-doc culture.
6. `SCOPED`. Architecture matches the customer-app + integration map declared in the spec. Evidence: link impl tracker components → repo modules. Source: project-specific.

**Open-source tooling.**

- `pydeps` (Python dependency graph): surfaces hidden coupling.
- `pyreverse` (from pylint): generates UML class + package diagrams from code.
- `dependency-cruiser` (cross-language): visualizes module dependencies, can fail CI on rule violations.
- `arch-unit` patterns via custom `pytest` rules for layer enforcement.
- Mermaid diagrams in design docs (`MERMAID_DIAGRAMS.md`).

**Sources.** Google design docs · AWS WAF Op Excellence · ISO/IEC 25010 · Microsoft SDL · Stripe API review.

---


### 2. Code Quality

**Definition.** How readable, maintainable, and consistent the code is. Function-level discipline (SRP, complexity, naming), file-level discipline (length, organization), repo-level discipline (style, conventions).

**Why it matters.** Code quality is the carrying cost of every future change. Bad code compounds. Good code is the prerequisite for everything else — you can't audit security of code you can't read.

**Gates.**

1. `STANDALONE`. Linter runs clean. Zero warnings on the default config. Evidence: `ruff check` exit code 0. Source: Google "code health over time".
2. `STANDALONE`. Formatter runs clean. No diff after format. Evidence: `ruff format --check` exit code 0. Source: Google readability.
3. `STANDALONE`. Type checker runs clean. No errors at the configured strictness. Evidence: `mypy --strict` or `pyright` exit code 0. Source: Stripe Sorbet investment.
4. `STANDALONE`. Cyclomatic complexity ≤ 10 per function. Evidence: `radon cc -a` average B or better. Source: ISO/IEC 25010 "Maintainability".
5. `STANDALONE`. Function length ≤ 50 LOC, file length ≤ 500 LOC. Hard caps. Evidence: line counts. Source: Google readability.
6. `STANDALONE`. No dead code. No unused imports, variables, parameters. Evidence: `vulture` + `ruff F401/F841` clean. Source: ISO/IEC 25010 "Maintainability".
7. `STANDALONE`. Naming conventions consistent with language community defaults. PEP 8 for Python. Evidence: `ruff` rule N enabled. Source: PEP 8.
8. `STANDALONE`. Single responsibility per module. Each module's docstring describes one purpose. Evidence: docstring + manual read. Source: ISO/IEC 25010 + Google.
9. `SCOPED`. Architectural patterns from the spec are used consistently (e.g., Ports & Adapters split honored — adapters stay outside the domain). Evidence: directory layout matches design. Source: project-specific.
10. `STANDALONE`. No import-time side effects that trigger I/O or mutate global state. Importing a module should not open connections, read files, or call external services. Evidence: module-level code audit. Source: Python import system best practices + Twelve-Factor 9 (startup/shutdown).
11. `STANDALONE`. Timezone-aware datetime usage. `datetime.now()` and `date.today()` are timezone-naive; code that compares or stores timestamps must use `datetime.now(tz=...)` or an explicit `zoneinfo.ZoneInfo`. Mixing naive and aware datetimes is a latent bug. Evidence: grep audit. Source: Python `datetime` docs + ISO/IEC 25010 (Functional Correctness).

**Open-source tooling.**

- `ruff`: linter + formatter, replaces flake8/black/isort/pyupgrade. Run as `ruff check . && ruff format --check .`.
- `mypy` (strict mode) or `pyright` (faster, MS-maintained, OSS): type checking.
- `radon`: cyclomatic complexity, maintainability index. `radon cc -s -a app/`.
- `vulture`: dead code detection.
- `interrogate`: docstring coverage. `interrogate -v app/`.

**Sources.** Google Engineering Practices · ISO/IEC 25010 (Maintainability, Functional Correctness) · PEP 8 · Stripe Sorbet · Python datetime docs.

---


### 14. Documentation

**Definition.** Every word that explains the system to a future reader. README, design docs, ADRs, runbooks, docstrings, API docs, comments.

**Why it matters.** Docs are the only durable transfer mechanism between minds. They are also the input to every agent-assisted task. Anthropic's `CLAUDE.md` pattern proves the agent reads docs before acting; bad docs poison every agent task downstream.

**Gates.**

1. `STANDALONE`. `README.md` exists and explains: what this is, who it's for, how to run it locally, how to deploy. Evidence: file. Source: open-source norms.
2. `STANDALONE`. Architecture diagram exists and is current. Evidence: file (mermaid, drawio, image). Source: Google design-doc culture.
3. `STANDALONE`. ADRs exist for any non-obvious decision. Evidence: `docs/adrs/` or equivalent. Source: Google design-doc culture.
4. `STANDALONE`. Every public function has a docstring. Evidence: `interrogate` ≥ 90%. Source: PEP 257 + Google style.
5. `STANDALONE`. Docstrings follow a consistent style (Google, NumPy, reST). Evidence: `pydocstyle` or `ruff D` clean. Source: PEP 257.
6. `STANDALONE`. Runbooks exist for every alert. Evidence: runbook directory + alert ↔ runbook map. Source: Google SRE.
7. `STANDALONE`. Contributing guide exists. PR expectations, branch naming, review process. Evidence: `CONTRIBUTING.md`. Source: open-source norms.
8. `STANDALONE`. Changelog kept. Evidence: `CHANGELOG.md` updated per release. Source: Keep a Changelog norms.
9. `STANDALONE`. Module-level docstring on every Python file. Evidence: `interrogate` per-module. Source: PEP 257.
10. `BOTH`. Docs match the code. Standalone: docs not stale. Scoped: docs match the spec. Evidence: spot-check + spec ↔ code ↔ doc cross-reference. Source: project-specific.

**Open-source tooling.**

- `interrogate`: docstring coverage.
- `pydocstyle` (or `ruff D` rules): docstring style enforcement.
- `mkdocs` + `mkdocs-material`: docs site generator.
- `sphinx`: Python docs generator (heavier).
- `vale`: prose linter for docs.
- `markdownlint-cli2`: Markdown style enforcement.

**Sources.** PEP 257 + PEP 484 · Google Style Guide · Anthropic `CLAUDE.md` patterns · Google SRE (runbooks).

---
