# Audit dimensions: Testing

Dimension pack for `PROJECT_AUDIT.md`. Read it only when the audit's scope covers this dimension.

## Scope

- Covers: dimension 3 (Testing).
- Does NOT cover: the other 19-dimension packs in this directory (`01-architecture-and-code.md`, `03-security.md`, `04-delivery.md`, `05-runtime.md`, `06-data-and-contracts.md`, `07-cost-and-scope.md`), nor the cadence, runner protocol, report format, severity taxonomy or remediation workflow, which `PROJECT_AUDIT.md` owns.

---

### 3. Testing

**Definition.** Automated verification that the code does what it claims. Unit tests, integration tests, contract tests, end-to-end tests, fixtures, mocks, property-based tests, load tests.

**Why it matters.** Tests are the only durable proof that a behavior holds. Anthropic calls self-verification "the single highest-leverage thing you can do" for agent-assisted work — same principle for human-assisted work.

**Gates.**

1. `STANDALONE`. Test suite exists and passes. Evidence: `pytest` exit code 0. Source: NIST SSDF PW.7.
2. `STANDALONE`. Coverage ≥ 80% on application code (excluding boilerplate, generated files, `__init__.py`). Evidence: `pytest --cov` report. Source: industry baseline.
3. `STANDALONE`. Test pyramid is right-shape. Many unit, fewer integration, fewer still e2e. Evidence: ratio in test report. Source: Google Testing Blog.
4. `STANDALONE`. Critical paths have property-based or fuzz tests. Evidence: `hypothesis` or `schemathesis` cases. Source: NIST SSDF PW.8.
5. `STANDALONE`. External dependencies are mocked at the seam, not deep in code. Evidence: mocks live in `tests/conftest.py` or fixture files, not scattered. Source: Google testing.
6. `BOTH`. Contract tests exist for every external boundary. Standalone: any contract test. Scoped: covers the boundaries declared in the spec. Evidence: `schemathesis` against OpenAPI, `pact` against named consumers. Source: Stripe API review.
7. `STANDALONE`. Tests are deterministic. No flakes. Evidence: 10x repeat runs identical. Source: Google flakiness budget.
8. `STANDALONE`. Fixtures reflect realistic data shapes. Evidence: fixture files include edge cases (empty, max, special chars, internationalization). Source: NIST SSDF PW.7.
9. `SCOPED`. Acceptance tests cover every Definition of Done line in the implementation doc. Evidence: cross-reference DoD ↔ test names. Source: project-specific.

**Dashboards.** For a surface that filters or aggregates records for a person to act on, `DASHBOARD_SDET_STANDARD.md` specialises these gates: it derives the acceptance tests for gate 9 from a story catalogue, and its exit checklist maps line by line onto gates 1, 2, 6, 7 and 8. A dashboard that passes that checklist passes this section for its surface.

**Open-source tooling.**

- `pytest`: runner. Plugins: `pytest-cov`, `pytest-xdist` (parallel), `pytest-randomly` (flake detection), `pytest-benchmark`.
- `coverage.py`: coverage measurement.
- `hypothesis`: property-based testing.
- `schemathesis`: OpenAPI contract testing.
- `pact-python`: consumer-driven contract testing.
- `responses` / `httpx-mock`: HTTP mocking at the seam.
- `freezegun`: deterministic time control in tests.
- `pytest-randomly`: surfaces order-dependent flakes.

**Sources.** Google Testing on the Toilet · NIST SSDF PW.7/PW.8 · Anthropic Claude Code "self-verification" · Stripe API review.

---
