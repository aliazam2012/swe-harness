# Audit dimensions: Data layer and API contracts

Dimension pack for `PROJECT_AUDIT.md`. Read it only when the audit's scope covers one of these dimensions.

## Scope

- Covers: dimension 12 (Data Layer), dimension 13 (API Contracts).
- Does NOT cover: the other 19-dimension packs in this directory (`01-architecture-and-code.md`, `02-testing.md`, `03-security.md`, `04-delivery.md`, `05-runtime.md`, `07-cost-and-scope.md`), nor the cadence, runner protocol, report format, severity taxonomy or remediation workflow, which `PROJECT_AUDIT.md` owns.

---

### 12. Data Layer

**Definition.** How data is stored, schemed, migrated, indexed, queried, and backed up. Includes idempotency tables, audit trails, and any persisted state.

**Why it matters.** Data outlives code. A bad migration corrupts the durable record. A missing index is a 3am page. The data layer is where the consequences of every other decision finally settle.

**Gates.**

1. `STANDALONE`. Schema is version-controlled. Migrations are forward-only and reviewable. Evidence: migrations dir in repo. Source: NIST SSDF PW.6.
2. `STANDALONE`. Migrations are backward-compatible during deploy. Old code can run against new schema. Evidence: migration audit. Source: AWS WAF Reliability + Stripe.
3. `STANDALONE`. Indexes exist on every column queried in a hot path. Evidence: query plan audit. Source: AWS WAF Performance.
4. `STANDALONE`. No N+1 queries on read paths. Evidence: query log audit. Source: AWS WAF Performance.
5. `STANDALONE`. Idempotency table or equivalent for any "exactly-once" claim. Evidence: schema. Source: AWS Builder's Library.
6. `STANDALONE`. Audit trail for every write that affects business state. Evidence: schema + write path audit. Source: NIST SSDF PW.6 + OWASP ASVS V8.
7. `STANDALONE`. PII columns identified and protected (encryption at rest, encryption in transit, access logged). Evidence: schema annotation + data classification. Source: NIST SSDF PW.5 + OWASP ASVS V8.
8. `STANDALONE`. Backup + restore tested. RPO known. Evidence: DR doc + last test. Source: AWS WAF Reliability.
9. `STANDALONE`. Connection pooling configured. No "connection per request" in long-lived processes. Evidence: pool config. Source: AWS WAF Performance.
10. `BOTH`. Schema matches the spec. Standalone: any documented schema. Scoped: matches the design's data model. Evidence: design doc ↔ schema. Source: project-specific.
11. `STANDALONE`. No `SELECT *` in application code. Every query explicitly lists the columns it needs. Schema additions (especially large payload columns) silently change what a wildcard returns, degrading hot-path performance with no visible callsite change. Evidence: `grep -rn "SELECT \*" app/`. Source: Stripe query hygiene + AWS WAF Performance.

**Open-source tooling.**

- `alembic` (SQLAlchemy): Python migration framework.
- `dbt` (open source): analytics-side schema management + tests.
- `sqlfluff`: SQL linter.
- `pgaudit` (Postgres): audit logging extension.
- `percona-toolkit` (MySQL): migration safety + slow query analysis.
- `gh-ost` / `pt-online-schema-change`: online schema changes for MySQL.
- `pgbadger`: Postgres slow query analyzer.

**Sources.** AWS WAF (Reliability + Performance) · NIST SSDF PW.5/PW.6 · OWASP ASVS V8 · Stripe migration patterns.

---


### 13. API Contracts

**Definition.** The interface the service exposes to the outside world. Versioning, error semantics, idempotency keys, backward compatibility, schema validation.

**Why it matters.** An API is a promise to every caller, current and future. Breaking it costs more than breaking internal code by an order of magnitude. Stripe builds entire orgs around this discipline.

**Gates.**

1. `STANDALONE`. API has a machine-readable schema (OpenAPI, gRPC proto, GraphQL SDL). Evidence: schema file. Source: Stripe API review.
2. `STANDALONE`. Schema is validated at the boundary. Requests and responses both. Evidence: middleware audit. Source: OWASP ASVS V13.
3. `STANDALONE`. Versioning strategy explicit. URL-based, header-based, or content-negotiation. Documented. Evidence: design doc. Source: Stripe API review.
4. `STANDALONE`. Backward compatibility guaranteed within a major version. Breaking changes only at major version bumps. Evidence: changelog + version policy. Source: Stripe API review.
5. `STANDALONE`. Error responses follow a documented schema (RFC 7807 or equivalent). Evidence: error schema. Source: IETF RFC 7807.
6. `STANDALONE`. Idempotency keys supported for unsafe verbs. Documented in API contract. Evidence: API doc + middleware. Source: Stripe API patterns.
7. `STANDALONE`. Rate limit headers exposed. Evidence: response header sample. Source: OWASP ASVS V11.
8. `STANDALONE`. Auth scheme documented. Token format, scopes, refresh. Evidence: API doc. Source: OWASP ASVS V3.
9. `STANDALONE`. Contract tests run against the schema. Evidence: `schemathesis` in CI. Source: Stripe API review.
10. `BOTH`. Public API matches the spec. Standalone: any documented public contract. Scoped: matches the contract doc. Evidence: spec ↔ schema. Source: project-specific.
11. `STANDALONE`. Deprecation policy documented. Deprecated endpoints return a warning header (e.g. `Deprecation`, `Sunset`). Callers get N days notice before removal. Evidence: deprecation policy doc + response header audit. Source: Stripe API review + IETF RFC 8594 (Sunset header).

**Open-source tooling.**

- `openapi-spec-validator`: schema validity check.
- `schemathesis`: property-based contract testing from OpenAPI.
- `pact-python`: consumer-driven contract testing.
- `prism`: OpenAPI mock server.
- `redocly-cli`: OpenAPI linting + bundling.
- `spectral`: OpenAPI linter (Stoplight).

**Sources.** Stripe API review (Pragmatic Engineer) · OWASP ASVS 5.0 V3/V4/V8 · IETF RFC 7807 · IETF RFC 8594.

---
