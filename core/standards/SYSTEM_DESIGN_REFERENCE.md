# System Design Reference — Interview to Production

## Table of Contents

- [TLDR](#tldr)
- [Part 1: Interview Framework (Hello Interview)](#part-1-interview-framework-hello-interview)
  - [Delivery Framework](#delivery-framework)
  - [Problem Breakdown Format](#problem-breakdown-format)
  - [Solution Tiering](#solution-tiering)
  - [Key Principles](#key-principles)
  - [Level Expectations](#level-expectations)
- [Part 2: Production System Design (FAANG + AI Giants)](#part-2-production-system-design-faang--ai-giants)
  - [The Gap Between Interviews and Production](#the-gap-between-interviews-and-production)
  - [Production Design Doc Structure](#production-design-doc-structure)
  - [Phase 1: Requirements (Production-Grade)](#phase-1-requirements-production-grade)
  - [Phase 2: Architecture](#phase-2-architecture)
  - [Phase 3: Reliability & Failure Design](#phase-3-reliability--failure-design)
  - [Phase 4: Observability](#phase-4-observability)
  - [Phase 5: Security](#phase-5-security)
  - [Phase 6: Deployment & Rollout](#phase-6-deployment--rollout)
  - [Phase 7: Capacity & Cost](#phase-7-capacity--cost)
  - [Phase 8: External Dependencies](#phase-8-external-dependencies)
  - [Phase 9: Testing Strategy](#phase-9-testing-strategy)
  - [Phase 10: Operational Runbook](#phase-10-operational-runbook)
- [Part 3: AI System Extensions](#part-3-ai-system-extensions)
- [Part 4: Architecture Decision Records (ADRs)](#part-4-architecture-decision-records-adrs)
- [Part 5: Production Readiness Checklist](#part-5-production-readiness-checklist)
- [Sources](#sources)

---

## TLDR

Two-layer system design framework. **Layer 1**: Hello Interview's structured interview approach — Requirements → Core Entities → API → Data Flow → High-Level Design → Deep Dives, with Bad/Good/Great solution tiering for every decision. **Layer 2**: Production hardening from Google SRE, AWS Well-Architected, and OpenAI/Anthropic patterns — failure modes, observability, progressive rollouts, SLOs with error budgets, security, capacity planning, and AI-specific concerns (harness architecture, prompt management, guardrails). Every design decision gets an ADR. Every system gets a Production Readiness Review before launch.

Sources: [Hello Interview](https://www.hellointerview.com/learn/system-design), [Google SRE Book](https://sre.google/sre-book/), [AWS Well-Architected](https://docs.aws.amazon.com/wellarchitected/), OpenAI/Anthropic production patterns.

---

# Part 1: Interview Framework (Hello Interview)

## Delivery Framework

| Phase | Time | What to Do |
|-------|------|------------|
| **Requirements** | ~5 min | Functional (top 3 "users should be able to..."), Non-functional (quantified: latency, scale, durability, CAP), Out-of-scope (explicit). Capacity estimation ONLY if it changes the design. |
| **Core Entities** | ~2 min | Bulleted list of nouns. Good names. Don't over-model — evolve as you design. |
| **API / System Interface** | ~5 min | Map functional reqs to endpoints. Default REST. Show request/response shapes. Auth from token, not body. |
| **Data Flow** | ~5 min (optional) | Numbered sequence of actions from input to output. Only if the system involves a long pipeline of steps. |
| **High-Level Design** | ~10-15 min | Boxes and arrows. Build up ONE requirement at a time. Talk through data flow per request. Document DB columns next to the database box. Start simple — meet functional reqs first. Note complexity for later, don't add it yet. |
| **Deep Dives** | ~10 min | Harden against non-functional reqs. Fix bottlenecks. Address edge cases. Senior+ candidates drive this proactively. |

## Problem Breakdown Format

1. **Understanding the Problem** — What is the system? What does it do? Brief context.
2. **Functional Requirements** — Core (3 prioritized) + Below the line (explicitly out of scope).
3. **Non-Functional Requirements** — Quantified system qualities (latency targets, availability, consistency, freshness SLAs).
4. **Scale Estimations** — Only compute if the numbers change the design. Note read vs write ratio. Hot vs cold data.
5. **The Set Up**
   - Planning the Approach — how you'll walk through the requirements
   - Core Entities — nouns, brief descriptions
   - API or System Interface — REST endpoints with request/response bodies
6. **High-Level Design** — Walk through each functional requirement sequentially. For each design choice, present alternatives with explicit trade-offs:
   - Bad Solution: what's obvious but wrong. Why it fails.
   - Good Solution: reasonable approach. Approach + Challenges.
   - Great Solution: optimal. Approach + Challenges.
7. **Deep Dives** — Numbered sections, each addressing one specific concern (scaling reads, scaling writes, storage optimization, multi-tenant, etc.).
8. **What is Expected at Each Level** — Mid, Senior, Staff+ expectations for this specific problem.

## Solution Tiering

Every design decision gets a tiered analysis:

| Tier | What It Means | Format |
|------|--------------|--------|
| **Bad** | Naive/obvious approach. Technically works but won't scale or has fatal flaws. | Approach → Challenges (why it fails) |
| **Good** | Solid approach. Works at scale with known trade-offs. | Approach → Challenges (what's left unsolved) |
| **Great** | Optimal for the constraints. Minimizes trade-offs. | Approach → Challenges (remaining complexity) |

Never present one solution — always show what was rejected and why.

## Key Principles

1. **Build up sequentially** — one functional requirement at a time. Don't design everything at once.
2. **Start simple** — meet functional reqs with the simplest possible design, then harden in deep dives.
3. **Acknowledge simplifications** — "this is over-simplified, I'll address it later." Don't leave gaps unacknowledged.
4. **Estimate only when it matters** — if the number doesn't change the design, don't compute it.
5. **Quantify non-functional reqs** — "low latency" is meaningless. "< 500ms p50 for search" is useful.
6. **Identify hot vs cold paths** — different SLAs for different data/paths.
7. **Name your patterns** — Scaling Reads, Scaling Writes, Two-Stage Architecture, Fan-out on Read/Write.
8. **Talk through data flow per request** — trace a single request from API to response, showing every state change.
9. **Document schema next to the component** — DB columns live next to the DB box, not in a separate section.
10. **Out-of-scope is first-class** — explicitly enumerate what the system does NOT do.

## Level Expectations

| Level | Breadth vs Depth | What's Expected |
|-------|-----------------|-----------------|
| **Mid** | 80/20 | HLD meets functional reqs. Interviewer probes basics. Mix of driving and following. |
| **Senior** | 60/40 | Speed through HLD. Deep technical detail. Articulate trade-offs. Proactive problem ID. |
| **Staff+** | 40/60 | Breeze through basics. Deep nuance. High proactivity. Interviewer learns something new. |

---

# Part 2: Production System Design (FAANG + AI Giants)

## The Gap Between Interviews and Production

Interviews test whether you can design a system. Production tests whether that system survives contact with reality. The Hello Interview framework gives you the skeleton — the following sections add the muscle, organs, and immune system.

| Interview Covers | Production Adds |
|-----------------|-----------------|
| Functional requirements | SLOs, SLIs, SLAs with error budgets |
| "The system should be available" | Failure mode analysis, blast radius, graceful degradation |
| "Use a cache" | Cache invalidation strategy, thundering herd, cold start |
| One diagram | Architecture Decision Records for every non-trivial choice |
| "Scale horizontally" | Capacity planning, N+2 redundancy, load testing, cost modeling |
| "Add monitoring" | Three-signal observability (metrics, logs, traces), alert taxonomy, runbooks |
| Security hand-wave | Threat model, authn/authz design, data classification, secrets management |
| "Deploy it" | Progressive rollout, canary, feature flags, rollback procedures |
| "Handle errors" | Retry with exponential backoff + jitter, circuit breakers, dead letter queues |
| — | External dependency contracts, SLA cascades, graceful degradation per dependency |
| — | Testing strategy (unit → integration → load → chaos) |
| — | Operational runbook (day 1, week 1, ongoing) |

## Production Design Doc Structure

Adapted from Google's internal design doc format, AWS Well-Architected, and Google SRE best practices.

### Document Metadata

```
Title:          [System Name] — Design Document
Author(s):      [Names]
Reviewers:      [Names]
Status:         Draft | In Review | Approved | Superseded by [link]
Last Updated:   YYYY-MM-DD
Related ADRs:   [links]
Related Docs:   [runbook, monitoring dashboard, API spec]
```

### Section Order

1. Goals & Non-Goals
2. Background & Motivation
3. Requirements (Functional, Non-Functional, Out-of-Scope)
4. Core Entities & Data Model
5. API / System Interface
6. Data Flow
7. High-Level Architecture (diagram + walkthrough)
8. Deep Dives (numbered, one per concern)
9. Architecture Decision Records (inline or linked)
10. Reliability & Failure Design
11. Observability
12. Security
13. Deployment & Rollout
14. Capacity & Cost
15. External Dependencies
16. Testing Strategy
17. Operational Runbook
18. Open Questions & Future Work
19. Appendix (scale estimations, reference data, glossary)

**Google design doc principle**: Goals before "what." Define the "why" first, tie to business objectives or OKRs. Be specific about success metrics. Write for someone encountering the system for the first time.

---

## Phase 1: Requirements (Production-Grade)

### Functional Requirements
Same as interview — "Users/systems should be able to..." Top 3-5, prioritized.

### Non-Functional Requirements (Quantified)

Go beyond interview-level vagueness. Every non-functional req needs a number:

| Category | Interview Version | Production Version |
|----------|------------------|-------------------|
| Latency | "Should be fast" | p50 < 200ms, p99 < 1s for classification; p50 < 2s, p99 < 5s for full pipeline |
| Availability | "Highly available" | 99.9% (8.7h downtime/year). Error budget: 0.1% per month |
| Freshness | "Near real-time" | New emails processed within 60s of arrival |
| Durability | "Don't lose data" | Zero data loss on customer emails. Idempotent processing. At-least-once delivery |
| Throughput | "Handle lots of traffic" | Sustain 50 req/min, burst to 200 req/min for 5 min |
| Consistency | "Eventually consistent" | Order creation is strongly consistent. Email status is eventually consistent (< 30s) |

### SLOs, SLIs, and Error Budgets (Google SRE)

Define SLOs like a user — measure what matters to the end user, not internal metrics.

- **SLI** (Service Level Indicator): the metric you measure. Example: "proportion of email-to-order pipelines completing in < 60s"
- **SLO** (Service Level Objective): the target. Example: "99.5% of pipelines complete in < 60s, measured over 30-day rolling window"
- **Error Budget**: 1 - SLO = room for failure. 99.5% SLO = 0.5% budget. If budget is spent, freeze non-critical changes.

SLO categories to define for every production system:

| SLO Type | What It Measures | Example |
|----------|-----------------|---------|
| **Availability** | % of requests that succeed | 99.9% of API calls return 2xx/4xx (not 5xx) |
| **Latency** | Response time distribution | p50 < 200ms, p99 < 2s |
| **Freshness** | How stale the data can be | Emails processed within 60s of receipt |
| **Correctness** | % of outputs that are right | 99% of extracted fields match ground truth |
| **Throughput** | Sustained request rate | Handle 50 orders/min without degradation |

### Out-of-Scope (Explicit)
Same as interview but more rigorous. For each out-of-scope item, document:
- What it is
- Why it's out of scope (not just "we decided" — the reasoning)
- When it might come back in scope (next phase? never? depends on X?)

---

## Phase 2: Architecture

### High-Level Design
Same approach as interview — boxes and arrows, build up one requirement at a time. But production adds:

- **Every box gets an owner** — which team/service owns this component?
- **Every arrow gets a protocol** — HTTP/REST, gRPC, webhook, Kafka topic, direct DB read?
- **Every arrow gets failure behavior** — what happens when this call fails? Retry? Skip? Dead letter?
- **Every data store gets a rationale** — why this DB? What was considered? (This becomes an ADR.)

### Data Model (Production Detail)

Go beyond interview-level entity lists. For each entity:

| Field | What to Document |
|-------|-----------------|
| Schema | Actual field names, types, constraints, indexes |
| Access patterns | How is this data read? Written? By whom? At what rate? |
| Retention | How long is data kept? Archive strategy? |
| Partitioning | Shard key? Partition strategy? Hot partition risk? |
| Consistency | Strong? Eventual? Read-after-write for which fields? |
| Encryption | At rest? In transit? Field-level? |

### Solution Tiering in Production

Same Bad/Good/Great framework, but with production-grade evaluation criteria:

| Criteria | Interview Weight | Production Weight |
|----------|-----------------|-------------------|
| Correctness | High | Critical — wrong output = customer impact |
| Scalability | High | High |
| Operational complexity | Low | **Critical** — who pages at 3am for this? |
| Cost | Rarely discussed | **High** — $ per request, $ per month |
| Time to implement | Never discussed | **High** — does this ship in 2 weeks or 2 months? |
| Debuggability | Never discussed | **High** — can you trace a single request end-to-end? |
| Testability | Rarely discussed | **High** — can you write a reliable integration test? |

---

## Phase 3: Reliability & Failure Design

The single biggest gap between interview and production design. Interviews ask "what if this fails?" Production demands you answer it for every component, every connection, every dependency.

### Failure Mode Analysis

For every external call and every component, document:

```
Component: [name]
Failure modes:
  1. [What can go wrong]     → Detection: [how you know]  → Response: [what system does]
  2. [What can go wrong]     → Detection: [how you know]  → Response: [what system does]
Blast radius: [what breaks if this component dies]
Recovery: [how to get back to healthy]
```

### Resilience Patterns (Google SRE)

| Pattern | When to Use | How |
|---------|------------|-----|
| **Retry with exponential backoff + jitter** | Transient failures (network blips, 503s) | Base delay * 2^attempt + random(0, base). Cap at max delay. Every client, every RPC. Non-negotiable. |
| **Circuit breaker** | Dependency is down and retries would pile up | Open after N failures in window. Half-open after cooldown. Close on success. Prevents cascade. |
| **Timeout** | Dependency is slow | Set per-call. Tighter than you think. A slow response is worse than a fast failure. |
| **Bulkhead** | Isolate failure domains | Separate thread pools / connection pools per dependency. One slow dependency doesn't starve others. |
| **Dead letter queue** | Can't process now, must not lose | Failed messages go to DLQ for manual review or retry later. Alert on DLQ depth. |
| **Graceful degradation** | System overloaded | Serve reduced functionality. Google Search searches a smaller index under load rather than failing entirely. |
| **Load shedding** | Past graceful degradation | Drop requests above capacity. Better to serve 80% of users well than 100% of users badly. |
| **Idempotency** | At-least-once delivery | Every write operation must be safe to retry. Use idempotency keys. |

### Fail Sanely (Google SRE)

- Validate configuration inputs — syntax AND semantics.
- Watch for empty data, partial data, truncated data.
- Alert if new config is N% smaller than previous version.
- On bad input: **continue operating with previous configuration** + alert. Don't apply garbage.
- Fail permissive over fail restrictive (unless security demands otherwise).

### Cascading Failure Prevention

- Retries amplify low error rates into high traffic → implement retry budgets.
- Every client: exponential backoff with jitter. No exceptions.
- Mobile/external clients are especially dangerous — millions of them, slow to update.
- When total load exceeds capacity: drop a fraction of traffic (including retries) upstream.

---

## Phase 4: Observability

### Three Pillars

| Pillar | What It Provides | Tool Category |
|--------|-----------------|---------------|
| **Metrics** | Aggregated numerical data over time (counters, gauges, histograms) | Prometheus, CloudWatch, Datadog |
| **Logs** | Discrete events with context (structured JSON, not printf) | ELK, CloudWatch Logs, Datadog Logs |
| **Traces** | End-to-end request flow across services | Jaeger, X-Ray, Datadog APM |

All three are required. Metrics tell you something is wrong. Logs tell you what. Traces tell you where.

### Alert Taxonomy (Google SRE)

Monitoring has exactly three output types. Nothing else.

| Type | Definition | Response Time | Example |
|------|-----------|---------------|---------|
| **Page** | A human must act NOW | Minutes | Pipeline stopped processing emails. DLQ depth > 100. |
| **Ticket** | A human must act within days | Hours to days | Error rate elevated but within budget. Disk 80% full. |
| **Log** | No action needed now, available for analysis | Never (proactive) | Individual request latency. Debug traces. |

**Anti-pattern**: Putting alerts in email and hoping someone reads them. This is `/dev/null` with extra steps. It works until it doesn't, and then the outage is worse because of false confidence.

### What to Measure

For every service, instrument:

| Metric | Why |
|--------|-----|
| Request rate (QPS) | Capacity planning, anomaly detection |
| Error rate (by type: 4xx, 5xx, timeout) | SLO tracking, incident detection |
| Latency distribution (p50, p95, p99) | Performance SLO, tail latency issues |
| Saturation (CPU, memory, connections, queue depth) | Capacity limits, scaling triggers |
| Dependency health (per external call) | Blast radius awareness |
| Business metrics (orders created, emails processed) | The metric that actually matters to the customer |

### Structured Logging Standard

Every log entry must include:
- `timestamp` (ISO 8601, UTC)
- `level` (DEBUG, INFO, WARN, ERROR)
- `service` (which service emitted this)
- `trace_id` (correlation ID across services)
- `request_id` (unique per request)
- `message` (what happened)
- `context` (structured key-value pairs relevant to the event)

Never log secrets, PII, or full request bodies in production.

---

## Phase 5: Security

### Threat Model

For every system, answer:
1. **What are we protecting?** (data classification: public, internal, confidential, restricted)
2. **From whom?** (external attackers, malicious insiders, accidental exposure)
3. **What are the attack surfaces?** (API endpoints, message queues, storage, admin interfaces)
4. **What controls exist?** (authn, authz, encryption, audit logging)

### Security Checklist

| Area | Requirement |
|------|------------|
| **Authentication** | Every API call authenticated. No anonymous access to internal services. |
| **Authorization** | Principle of least privilege. Service accounts scoped to minimum required permissions. |
| **Secrets** | Never in code, config files, or env vars on disk. Use secrets manager (AWS SM, Vault). Rotate on schedule. |
| **Encryption in transit** | TLS everywhere. No plaintext between services. |
| **Encryption at rest** | All data stores encrypted. Customer data always encrypted. |
| **Input validation** | Validate and sanitize all external inputs. Assume every input is malicious. |
| **Audit logging** | Log all access to sensitive data. Log all admin actions. Immutable audit trail. |
| **Dependency security** | Pin dependency versions. Scan for CVEs. Update on schedule. |
| **Rate limiting** | Every public endpoint rate-limited. Internal endpoints rate-limited per client. |

---

## Phase 6: Deployment & Rollout

### Progressive Rollout (Google SRE)

Non-emergency rollouts MUST proceed in stages. Both configuration and binary changes introduce risk.

| Stage | Traffic | Duration | Gate |
|-------|---------|----------|------|
| **Canary** | 1-5% | 15-60 min | Automated: error rate, latency within SLO |
| **Stage 1** | 10-25% | 1-4 hours | Automated + manual review |
| **Stage 2** | 50% | 4-24 hours | Automated |
| **Full** | 100% | — | Automated |

Rules:
- Every rollout is supervised — monitored by engineer OR reliable automated system.
- If unexpected behavior detected: **roll back first, diagnose after**. Minimize MTTR.
- Don't deploy on Fridays. Don't deploy before holidays. Don't deploy before you sleep.
- Different stages in different geographies to catch diurnal/geographic traffic differences.
- Feature flags decouple deployment from release — deploy dark, enable incrementally.

### Rollback Design

Every deployment must have a rollback plan BEFORE it ships:
- **Binary rollback**: previous version is tagged and deployable in < 5 minutes.
- **Config rollback**: previous config is versioned and restorable.
- **Data migration rollback**: if schema changed, can the old binary read the new schema? (Forward-compatible migrations only.)
- **Feature flag kill switch**: disable new behavior without redeploying.

---

## Phase 7: Capacity & Cost

### Capacity Planning (Google SRE)

- **N+2 redundancy**: handle peak traffic with the two largest instances offline (one planned maintenance + one unplanned failure, simultaneously).
- **Don't mistake day-one load for steady-state**: launches attract more traffic. Plan for spike + settle.
- **Load test, don't guess**: "X machines handled Y QPS three months ago" ≠ they still can after code changes.
- **Validate forecasts against reality**: if predictions consistently miss, your model is wrong.
- **Growth alerts**: alert when you hit 70% of capacity. Plan at 50%. Panic at 85%.

### Cost Modeling

For every component, estimate:

| Item | Formula | Review Frequency |
|------|---------|-----------------|
| Compute | instances * hours * rate | Monthly |
| Storage | GB stored * rate + GB transferred * rate | Monthly |
| API calls (external) | calls/month * rate per call | Monthly |
| LLM tokens | tokens/request * requests/day * rate per 1K tokens | Weekly (can spike) |
| Network | GB egress * rate | Monthly |

**AWS Well-Architected principle**: Stop guessing capacity needs. Auto-scale where possible. But set spend alerts — auto-scale without cost limits is how you get a $50K surprise bill.

---

## Phase 8: External Dependencies

Every external system your service talks to needs a contract:

| Field | What to Document |
|-------|-----------------|
| **System** | Name, owner, API docs link |
| **SLA** | What does the provider guarantee? (Often: nothing useful.) |
| **Authentication** | How do you auth? Keys, OAuth, certs? Where are creds stored? |
| **Rate limits** | Documented limits. Observed limits. What happens when you hit them? |
| **Failure behavior** | What does a failure look like? Timeout? 5xx? Garbage response? |
| **Degradation plan** | What does YOUR system do when this dependency is down? Queue? Skip? Fallback? |
| **Data contract** | What fields do you depend on? What happens if the schema changes? |
| **Monitoring** | How do you know this dependency is healthy, independent of the provider's status page? |
| **Escape hatch** | Can you switch providers? How hard? How long? |

**Google SRE principle**: Play nice with external systems. Monitor your own traffic to them. Don't accidentally DDoS a partner during launch spikes. Implement rate limiting on YOUR side, not just theirs.

---

## Phase 9: Testing Strategy

### Testing Pyramid (Production Grade)

| Layer | What | How Many | Speed |
|-------|------|----------|-------|
| **Unit** | Individual functions, pure logic | Many (hundreds) | Fast (ms) |
| **Integration** | Service + real dependencies (DB, cache, API mocks) | Moderate (dozens) | Medium (seconds) |
| **Contract** | API contracts between services (schema validation, backward compat) | Per interface | Fast |
| **End-to-End** | Full pipeline from input to output | Few (critical paths only) | Slow (minutes) |
| **Load** | Performance under sustained traffic | Per SLO | Slow (hours) |
| **Chaos** | What happens when things break | Per failure mode | Varies |

### What to Test in Production (Google SRE)

- **Synthetic monitoring**: fake requests that exercise the critical path, continuously, in prod.
- **Canary analysis**: automated comparison of canary vs baseline metrics during rollout.
- **Game days**: scheduled exercises where you simulate failures (kill a service, corrupt data, saturate a queue) to verify your detection and recovery actually work.

**AWS Well-Architected principle**: Test at production scale. Cloud makes this economical. There's no excuse for "works on my machine."

---

## Phase 10: Operational Runbook

Every production system needs a runbook. Not aspirational — the literal steps someone follows at 3am when paged.

### Runbook Structure

```
## [Alert Name]

### What is happening
[One sentence: what the alert means in business terms]

### Impact
[Who is affected? What functionality is degraded?]

### Severity
[P1: customer-facing outage | P2: degraded | P3: internal only]

### Diagnosis Steps
1. [First thing to check — usually a dashboard link]
2. [Second thing to check]
3. [Third thing to check]

### Mitigation Steps
1. [Immediate action — usually restart, rollback, or feature flag off]
2. [Secondary action if step 1 doesn't work]
3. [Escalation path if nothing works]

### Root Cause Investigation
[After mitigation — how to find the actual cause]

### Prevention
[What to do so this doesn't happen again — becomes a ticket]
```

### Blameless Postmortems (Google SRE)

After every significant incident:
- Focus on **process and technology**, not people.
- Assume everyone involved was intelligent, well-intentioned, and making the best decisions with available information.
- You can't "fix" people. Fix the environment: better system design, better information availability, automated validation of operational decisions.
- Document: timeline, impact, root cause, what went well, what didn't, action items with owners and deadlines.

---

# Part 3: AI System Extensions

For systems that include LLM/AI components, add these production concerns on top of everything above.

### Five-Layer Agent Harness (OpenAI/Anthropic Convergence)

| Layer | Responsibility | Production Concern |
|-------|---------------|--------------------|
| **Orchestration** | Execution flow, termination conditions, step budgets | Max steps per task (20-50). Timeout per step. Total cost cap per invocation. |
| **Context Management** | Curate what the model sees | Context window limits. Compaction strategy. Prevent hallucination from context decay. |
| **Tool Integration** | Connect agent to external systems | Per-tool timeout. Per-tool retry policy. Tool call validation before execution. |
| **Verification** | Validate outputs at each step | Schema validation. Confidence thresholds. Human-in-the-loop triggers. |
| **Operations** | Monitoring, cost control, debugging | Token usage tracking. Cost per request. Prompt version tracking. Output quality metrics. |

### AI-Specific Design Principles

1. **Simple > complex**: Vercel cut tools from 15 to 2 — accuracy went from 80% to 100%, tokens dropped 37%, speed improved 3.5x. Start with the minimum tool set. Add only when measured accuracy demands it.
2. **Deterministic orchestration, probabilistic generation**: Separate the workflow logic (deterministic, testable, debuggable) from the model calls (probabilistic, measurable, versioned). Never let the model decide the workflow.
3. **Prompt chaining with validation gates**: Break complex tasks into sequential steps. Validate output between steps programmatically. Fail fast on garbage.
4. **Start with single-agent loop**: One model, one tool set. Only add orchestrator-worker patterns when a single agent demonstrably can't handle the task.
5. **Limit hierarchy to 2 levels**: Orchestrator → workers. Never orchestrator → sub-orchestrator → workers. Debugging becomes impossible.

### AI-Specific Observability

| Metric | Why |
|--------|-----|
| Token usage per request (input + output) | Cost control, anomaly detection (context blowup) |
| Latency per model call | SLO tracking, model degradation detection |
| Output quality score (if measurable) | Drift detection, model regression |
| Tool call success rate | Integration health |
| Prompt version in use | Reproducibility, A/B testing |
| Fallback/escalation rate | Human-in-the-loop load, automation coverage |
| Cost per business outcome | The metric that matters — $/order, $/classification |

### AI-Specific Failure Modes

| Failure | Detection | Response |
|---------|-----------|----------|
| Model returns garbage | Schema validation fails | Retry once with simplified prompt. If still fails → DLQ + alert. |
| Context window exceeded | Token count pre-check | Truncate or summarize context. Never silently drop. |
| Model API rate limited | 429 response | Exponential backoff. Queue overflow → DLQ. |
| Model API down | Timeout / 5xx | Circuit breaker. Queue for retry. Alert if > 5 min. |
| Prompt injection | Input sanitization + output validation | Strip known injection patterns. Validate output schema. Log for review. |
| Cost runaway | Token budget per request exceeded | Hard kill per-request. Alert on daily spend anomaly. |
| Hallucination | Output contradicts source data | Cross-reference extracted fields against source. Flag confidence < threshold. |

---

# Part 4: Architecture Decision Records (ADRs)

Every non-trivial design decision gets an ADR. Store in source control next to the code.

### Template

```
# ADR-[number]: [Title]

**Status**: Proposed | Accepted | Deprecated | Superseded by ADR-[X]
**Date**: YYYY-MM-DD
**Author**: [name]
**Deciders**: [names]

## Context
[The situation. Forces at play. Constraints. Write for someone with zero prior knowledge.]

## Decision Drivers
- [Factor 1]
- [Factor 2]

## Considered Options
1. [Option A] — [one sentence]
2. [Option B] — [one sentence]
3. [Option C] — [one sentence]

## Decision
[Option chosen] because [reasoning].

## Consequences
**Positive**:
- [benefit 1]

**Negative**:
- [trade-off 1]

**Risks**:
- [risk 1]

## Confirmation
[How will we verify this decision was implemented correctly?]
```

### ADR Rules
- If an ADR takes > 30 minutes to write, you're overengineering it.
- Always document downsides. If an ADR only lists positives, it's marketing, not engineering.
- Flag ADRs older than 12 months for re-evaluation.
- Append-only — never edit old ADRs. Supersede them with new ones.
- Link superseding/superseded ADRs bidirectionally.

---

# Part 5: Production Readiness Checklist

Adapted from Google SRE's Launch Coordination Checklist. Every system must pass this before serving production traffic.

### Architecture
- [ ] Architecture diagram current and reviewed
- [ ] All ADRs written for non-trivial decisions
- [ ] Data model documented with access patterns, retention, partitioning
- [ ] API contracts defined and versioned

### Reliability
- [ ] Failure mode analysis complete for every component and dependency
- [ ] Retry, timeout, and circuit breaker configured for every external call
- [ ] Idempotency implemented for all write operations
- [ ] Graceful degradation defined for every dependency failure
- [ ] Dead letter queue configured for unprocessable messages
- [ ] N+2 capacity provisioned

### Observability
- [ ] Metrics: request rate, error rate, latency (p50/p95/p99), saturation
- [ ] Logs: structured, with trace IDs, no secrets/PII
- [ ] Traces: end-to-end request tracing across all services
- [ ] Dashboards: service health, dependency health, business metrics
- [ ] Alerts: pages for critical, tickets for important, logs for everything else
- [ ] Runbook exists for every page-level alert

### Security
- [ ] Threat model documented
- [ ] Authentication on every endpoint
- [ ] Authorization: least-privilege service accounts
- [ ] Secrets in secrets manager, not in code/config/env
- [ ] Encryption: TLS in transit, encryption at rest
- [ ] Input validation on all external inputs
- [ ] Rate limiting on all public endpoints
- [ ] Audit logging for sensitive operations

### Deployment
- [ ] Progressive rollout configured (canary → staged → full)
- [ ] Rollback plan documented and tested
- [ ] Feature flags for new functionality
- [ ] No Friday deploys policy acknowledged

### Capacity & Cost
- [ ] Load tested at 2x expected peak
- [ ] Auto-scaling configured with spend caps
- [ ] Cost estimate documented per component
- [ ] Growth alert at 70% capacity

### External Dependencies
- [ ] Every dependency documented (SLA, auth, rate limits, failure behavior)
- [ ] Degradation plan per dependency
- [ ] Monitoring per dependency (independent of provider status page)

### Testing
- [ ] Unit tests cover critical business logic
- [ ] Integration tests cover critical paths
- [ ] Contract tests validate API interfaces
- [ ] Load tests validate performance SLOs
- [ ] Synthetic monitoring in production

### Operational
- [ ] Runbook complete for all critical alerts
- [ ] On-call rotation defined (minimum 8 people for sustainable rotation)
- [ ] Incident response process documented
- [ ] Postmortem template ready
- [ ] Backup and recovery tested

### AI-Specific (if applicable)
- [ ] Prompt versions tracked and reproducible
- [ ] Token budget per request defined and enforced
- [ ] Output validation (schema + confidence threshold)
- [ ] Cost per business outcome measured
- [ ] Fallback to human defined for low-confidence outputs
- [ ] Prompt injection mitigations in place

---

# Sources

| Source | What It Provides | Link |
|--------|-----------------|------|
| Hello Interview | Interview framework, delivery structure, solution tiering | [hellointerview.com/learn/system-design](https://www.hellointerview.com/learn/system-design) |
| Google SRE Book | SLOs, error budgets, monitoring, postmortems, launch checklist, capacity planning, failure handling | [sre.google/sre-book](https://sre.google/sre-book/) |
| AWS Well-Architected | 6 pillars (operational excellence, security, reliability, performance, cost, sustainability), general design principles | [docs.aws.amazon.com/wellarchitected](https://docs.aws.amazon.com/wellarchitected/) |
| Google Design Docs | Goals-first, audience-aware, trade-off documentation | [ryanmadden.net/things-i-learned-at-google-design-docs](https://ryanmadden.net/things-i-learned-at-google-design-docs/) |
| OpenAI/Anthropic Patterns | 5-layer agent harness, simple > complex, deterministic orchestration | [workos.com/blog/enterprise-ai-agent-playbook](https://workos.com/blog/enterprise-ai-agent-playbook-what-anthropic-and-openai-reveal-about-building-production-ready-systems) |
| MADR (ADR Template) | Architecture Decision Records format | [github.com/adr/madr](https://github.com/adr/madr) |
