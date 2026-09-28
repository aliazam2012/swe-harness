# Audit dimensions: Observability, reliability and performance

Dimension pack for `PROJECT_AUDIT.md`. Read it only when the audit's scope covers one of these dimensions.

## Scope

- Covers: dimension 9 (Observability), dimension 10 (Reliability), dimension 11 (Performance and Scalability).
- Does NOT cover: the other 19-dimension packs in this directory (`01-architecture-and-code.md`, `02-testing.md`, `03-security.md`, `04-delivery.md`, `06-data-and-contracts.md`, `07-cost-and-scope.md`), nor the cadence, runner protocol, report format, severity taxonomy or remediation workflow, which `PROJECT_AUDIT.md` owns.

---

### 9. Observability

**Definition.** The ability to know what the running system is doing without redeploying. Logs, metrics, traces, and the alerts wired to them.

**Why it matters.** You can't operate what you can't see. Every incident MTTR is gated on observability — fast to diagnose or slow to diagnose, you choose at design time.

**Gates.**

1. `STANDALONE`. Structured logs (JSON or equivalent), one event per line. Evidence: production log sample. Source: Twelve-Factor 11.
2. `STANDALONE`. Log levels used correctly. ERROR for actionable, WARN for noteworthy, INFO for state changes, DEBUG opt-in. Evidence: log config + spot-check sample. Source: Twelve-Factor 11.
3. `STANDALONE`. Logs include correlation/request ID propagated across boundaries. Evidence: request log sample. Source: Google SRE "golden signals" plus tracing.
4. `STANDALONE`. Metrics cover the four golden signals: latency, traffic, errors, saturation. Evidence: dashboard. Source: Google SRE.
5. `STANDALONE`. SLOs defined for the service. Error budget tracked. Evidence: SLO doc + dashboard. Source: Google SRE.
6. `STANDALONE`. Distributed tracing for any multi-hop request path. Evidence: trace sample (Jaeger / Tempo / Honeycomb-OSS). Source: CNCF + Google SRE.
7. `STANDALONE`. Alerts wired to SLOs, not raw metrics. Symptom-based, not cause-based. Evidence: alert config. Source: Google SRE Alerting Philosophy.
8. `STANDALONE`. On-call rotation defined. Pages route to a human within configured window. Evidence: on-call schedule. Source: Google SRE.
9. `STANDALONE`. No alert is so noisy it gets ignored. Alert noise audit shows < 5 false positives per alert per month. Evidence: alert metrics. Source: Google SRE.
10. `BOTH`. Every spec'd HITL gate, business event, and external call emits a log/metric. Standalone: instrumentation exists at boundaries. Scoped: matches the spec's observability requirements. Evidence: code + design cross-reference. Source: project-specific.
11. `STANDALONE`. Logs do not contain secrets, PII, or tokens. Evidence: log redaction audit. Source: OWASP ASVS 5.0 V16 (Security Logging).
12. `STANDALONE`. Logging uses lazy formatting (`logger.info("msg %s", arg)`) not eager f-strings (`logger.info(f"msg {arg}")`). F-strings evaluate arguments even when the log level is suppressed, wasting CPU, and bypass record-factory-based masking. Evidence: grep audit. Source: Python logging docs + structlog best practices.
13. `STANDALONE`. Log ordering / correlation: every log line emitted during a request carries the request's correlation ID (e.g. `request_id`, `trace_id`) as a field, not just in the message body. In async runtimes and aggregated log sinks (CloudWatch, Loki), lines from concurrent requests interleave. Without a machine-parseable correlation field, reconstructing a single request's timeline requires regex guesswork. The correlation ID must be injected automatically (via logging filter, contextvars, or middleware) so it appears even in logs emitted by code that is unaware of the request context. Evidence: log format string + filter/middleware audit + production log sample. Source: Twelve-Factor 11 + OpenTelemetry semantic conventions + AWS CloudWatch Insights best practices.
14. `STANDALONE`. Log sufficiency: INFO-level logs capture the business-relevant lifecycle of every request (received, classified, dispatched, completed/failed) with enough identifiers (entity IDs, status codes, durations) to answer "what happened?" without enabling DEBUG. DEBUG-level logs carry the raw payloads, intermediate state, and branching decisions needed to answer "why did it happen?" without attaching a debugger. Evidence: manual review of log calls on the hot path at each level. Source: Google SRE "Practical Alerting" + Charity Majors "Observability Engineering".
15. `STANDALONE`. Run data persistence: the full lifecycle of every processed request is captured in a queryable data store (database, audit table, or event log), not only in transient log streams. Log retention is bounded, expensive to query at scale, and not indexed by business entities. A durable record keyed by the business entity (order ID, email ID, ticket ID) with timestamps, outcomes, and correlation IDs lets operators reconstruct history days or weeks later without log archaeology. Evidence: schema audit of run/audit/event tables + data-retention policy. Source: AWS WAF Operational Excellence + SOC 2 CC7.2 (incident investigation).

**Open-source tooling.**

- `OpenTelemetry` (OTel): vendor-neutral instrumentation SDK + collector. The standard for new instrumentation.
- `Prometheus`: metrics scrape + storage.
- `Grafana`: dashboards (open-source core).
- `Loki`: log aggregation (Grafana stack).
- `Tempo` / `Jaeger`: distributed tracing backends.
- `Alertmanager`: Prometheus alert routing.
- `structlog` (Python): structured logging library.
- `python-json-logger`: JSON formatter for stdlib logging.

**Sources.** Google SRE Book (Monitoring + Alerting) · Twelve-Factor 11 · CNCF Observability TAG · OpenTelemetry spec · Python logging docs · Charity Majors "Observability Engineering" · AWS WAF Operational Excellence.

---


### 10. Reliability

**Definition.** The system's ability to keep working when things go wrong. Error handling, retries, timeouts, idempotency, circuit breakers, graceful degradation, chaos.

**Why it matters.** Every external dep will fail. Every internal queue will back up. Every deploy will go bad. Reliability is what lets the system survive each of those without an incident.

**Gates.**

1. `STANDALONE`. Every external call has an explicit timeout. No infinite waits. Evidence: code audit. Source: AWS WAF Reliability.
2. `STANDALONE`. Retries use exponential backoff + jitter. Bounded. Evidence: code audit. Source: AWS Builder's Library.
3. `STANDALONE`. Retries only on idempotent operations. Non-idempotent ops have a higher bar (circuit breaker, DLQ). Evidence: code audit. Source: AWS WAF Reliability.
4. `STANDALONE`. Idempotency keys at every boundary that could double-fire. Evidence: code audit + idempotency table or equivalent. Source: AWS WAF Reliability + Stripe API patterns.
5. `STANDALONE`. Circuit breaker on external deps that can take the system down. Evidence: code audit. Source: Netflix Hystrix patterns.
6. `STANDALONE`. Graceful degradation paths defined. Service has a "still answers, even if degraded" mode. Evidence: design doc + code. Source: AWS WAF Reliability.
7. `STANDALONE`. DLQ (or equivalent) for poison-pill messages on async paths. Evidence: queue + DLQ config. Source: AWS WAF Reliability.
8. `STANDALONE`. Disaster recovery runbook exists. RTO + RPO defined. Evidence: DR doc + last-tested date. Source: AWS WAF Reliability + ISO/IEC 25010 "Recoverability".
9. `STANDALONE`. Backups exist and are tested. Evidence: backup schedule + last-restore date. Source: AWS WAF Reliability.
10. `STANDALONE`. Game days or chaos exercises run periodically. Evidence: last game-day record. Source: Netflix Chaos + AWS WAF Op Excellence.
11. `BOTH`. Every spec'd failure mode is handled. Standalone: failures handled. Scoped: matches the spec's failure-mode taxonomy. Evidence: code + design. Source: project-specific.
12. `STANDALONE`. Async correctness: every `async def` method that calls an external system uses an async-native library, or wraps the blocking call in `asyncio.to_thread()` / `loop.run_in_executor()`. A single blocking call in an `async def` stalls the event loop for every concurrent request. Evidence: per-adapter audit of the underlying library. Source: Python asyncio docs + uvicorn concurrency model.
13. `STANDALONE`. Connection/resource pool management: external connections (DB, HTTP, message broker) use pooling rather than open-per-call. Evidence: connection lifecycle audit. Source: AWS WAF Performance + Twelve-Factor 4.
14. `STANDALONE`. Lazy singleton construction does not perform blocking I/O on the first request path. Evidence: startup sequence audit. Source: Twelve-Factor 9 (fast startup).
15. `STANDALONE`. Kill switch exists at the outbound mutation boundary. The service can stop all writes to customer-facing external systems (TMS order creation, ticketing, email sends, customer comms) without shutting down the service itself. The kill switch must be: (a) activatable in under 1 minute (config flag, env var, or admin endpoint, not a code deploy), (b) granular enough to disable one outbound system independently (e.g. stop TMS writes but keep ticketing alive), (c) observable (logs/metrics show the switch state and how many requests are being suppressed), (d) safe to toggle (suppressed requests either queue for replay or return a clear "service paused" response, not silent data loss). This is the boundary between "automation helps" and "automation causes damage at scale." The kill switch turns an outage into a pause. Evidence: kill switch mechanism + test of activation + suppression behavior. Source: operational safety practice plus the Google SRE "Big Red Button" pattern.

**Open-source tooling.**

- `tenacity` (Python): retry library with backoff + jitter.
- `pybreaker`: circuit breaker library.
- `httpx` (built-in timeouts): replaces `requests` for new code.
- `chaos-mesh` (Kubernetes): chaos engineering platform.
- `chaostoolkit`: chaos experiments orchestrator.
- `litmus`: CNCF chaos engineering platform.
- `toxiproxy`: network proxy for failure injection.
- `anyio` / `asyncio.to_thread`: bridges for sync libraries in async code.
- `launchdarkly-server-sdk` / `flipt` / `unleash`: feature flag services usable as kill switches (flipt and unleash are open source).

**Sources.** Google SRE Book (Big Red Button) · AWS WAF (Reliability) · AWS Builder's Library · Netflix Tech Blog · ISO/IEC 25010 (Reliability) · Python asyncio documentation · operational safety practice.

---


### 11. Performance and Scalability

**Definition.** How fast the system answers under expected load, and what happens when load goes up. Latency, throughput, capacity, resource efficiency.

**Why it matters.** Performance is correctness on a deadline. A correct answer that arrives after the timeout is a wrong answer. Capacity planning is the difference between a quiet 2am and an incident.

**Gates.**

1. `STANDALONE`. Latency SLO defined for every user-facing endpoint. Evidence: SLO doc. Source: Google SRE.
2. `STANDALONE`. Latency measured in production at p50, p95, p99. Evidence: dashboard. Source: Google SRE.
3. `STANDALONE`. Load test exists for the critical path. Evidence: `locust` or `k6` script + last run. Source: AWS WAF "Test at production scale".
4. `STANDALONE`. Capacity plan exists. Headroom ≥ 2x expected peak. Evidence: capacity doc. Source: AWS WAF Performance + Google SRE.
5. `STANDALONE`. Auto-scaling configured (where applicable). Evidence: scaling policy. Source: AWS WAF Performance + CNCF.
6. `STANDALONE`. Profiling done at least once on the hot path. Hot spots known. Evidence: profile artifact. Source: AWS WAF Performance.
7. `STANDALONE`. Resource usage trends watched. Memory leaks detected before OOM. Evidence: memory dashboard. Source: AWS WAF Op Excellence.
8. `STANDALONE`. N+1 query patterns audited. ORM eager loading or query batching where needed. Evidence: query profile. Source: ISO/IEC 25010 (Performance Efficiency).
9. `BOTH`. Throughput meets the spec. Standalone: known throughput. Scoped: matches design doc target. Evidence: load test report. Source: project-specific.
10. `STANDALONE`. Capacity plan exists with: (a) current traffic baseline, (b) 6-month and 12-month growth projections, (c) launch spike estimate (if pre-launch), (d) scaling limits and what breaks first. Evidence: capacity plan doc or spreadsheet. Source: Google SRE Launch Coordination Checklist + AWS WAF Reliability (April 2025 REL07-BP01).

**Open-source tooling.**

- `locust`: Python load testing.
- `k6` (open core, MIT-licensed runtime): JavaScript load testing.
- `wrk` / `wrk2`: low-level HTTP load gen.
- `pytest-benchmark`: micro-benchmarks in test suite.
- `py-spy`: sampling profiler for live Python processes.
- `memray`: memory profiler.
- `scalene`: CPU + memory profiler (open source).
- `pgbadger` (Postgres) / Percona Toolkit (MySQL): slow query analysis.

**Sources.** Google SRE Book (Launch Coordination Checklist, Capacity Planning) · AWS WAF (Performance Efficiency, Reliability April 2025 refresh) · ISO/IEC 25010 (Performance Efficiency).

---
