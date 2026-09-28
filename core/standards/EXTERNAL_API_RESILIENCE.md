# External API Resilience Standard

Applies when creating, modifying, or reviewing any HTTP client that calls an external API. Covers retry, circuit breaking, rate limiting, and backoff. These patterns compose; each solves a different failure mode. Skipping any one creates a gap that shows up under load or during outages.

## Prior Art

This standard distills patterns from:

- Google SRE Book, chapters "Handling Overload" and "Addressing Cascading Failures"
- Netflix Hystrix (circuit breaker, bulkhead isolation, fallback)
- Resilience4j (circuit breaker, rate limiter, retry, bulkhead as composable decorators)
- AWS SDK retry modes (standard + adaptive, with token-bucket circuit breaking)
- OpenAI / Anthropic Python SDKs (built-in exponential backoff + jitter, `Retry-After` honoring)
- Stripe Python SDK (automatic idempotency keys, configurable `max_network_retries`)

## 1. Layer Order

Resilience patterns stack in a fixed order. Each layer wraps the next. Getting the order wrong negates the protection.

```
caller
  -> circuit breaker     (fail-fast if service is known-down)
    -> rate limiter       (throttle outbound to stay within budget)
      -> concurrency limiter  (bound in-flight requests)
        -> retry with backoff   (handle transient errors)
          -> timeout            (bound latency per attempt)
            -> HTTP call
```

Rules:

1. Circuit breaker wraps everything. If the breaker is open, no tokens are consumed, no retries fire, no HTTP call leaves the process.
2. Rate limiter sits outside retry. Each retry attempt consumes a token. The limiter prevents retry storms from exceeding the service's rate budget.
3. Retry sits inside the rate limiter. Retries are a controlled response to transient failure, not a throughput mechanism.
4. Timeout applies per-attempt, not per-retry-sequence. A 10s timeout with 3 retries means worst case is ~30s (plus backoff), not 10s total.

## 2. Retry Policy

### What to retry

| Status / Error | Retry? | Rationale |
|---|---|---|
| 429 (rate limited) | Yes, with circuit breaker | Service is throttling. Retry after lockout, not immediately. |
| 408, 409 | Yes | Request timeout or conflict. Transient by nature. |
| 5xx | Yes | Server-side failure. Usually transient. |
| Network error (connect, read, timeout) | Yes | Infrastructure blip. |
| 400 (validation) | No | Caller sent bad data. Same payload will fail the same way. |
| 401, 403 | No | Auth failure. Retrying won't fix credentials. |
| 404 | No | Resource doesn't exist. Retrying doesn't create it. |
| 2xx with unexpected shape | No | API contract violation. Retrying returns the same shape. |

### How to retry

1. Exponential backoff with full jitter: `delay = min(cap, base * 2^attempt)`, `sleep = uniform(0, delay)`. Default: base=2s, cap=30s.
2. Max 3 retries (4 total attempts). More than 3 means the problem isn't transient.
3. Honor `Retry-After` header when present. Add jitter on top of it to prevent synchronized retries across clients.
4. Per-client retry budget: track the ratio of retries to total requests. If retries exceed 10% of total volume, stop retrying and propagate failures. This prevents retry storms during widespread outages.
5. Retry at one layer only. If service A calls B calls C, only B retries calls to C. A does not also retry. Multiplicative retry (3 * 3 * 3 = 27 attempts) is a self-inflicted DDoS.

## 3. Circuit Breaker

The circuit breaker prevents wasted requests against a service that is known to be failing. Three states:

| State | Behavior | Transition |
|---|---|---|
| **Closed** | All requests pass through. Failures are counted. | Failure threshold exceeded -> Open |
| **Open** | All requests fail immediately (or block until lockout expires). No HTTP calls. | Lockout timer expires -> Half-Open |
| **Half-Open** | A limited number of probe requests pass through. | Probe succeeds -> Closed. Probe fails -> Open (reset timer). |

### Implementation rules

1. **Trip condition.** Define the trip condition based on the service's actual rate limit policy, not a generic threshold. Example: the vendor API limits 25 4xx responses per 10-minute window. The breaker trips on the first 429 with a lockout matching the window.
2. **Scope.** One breaker per external service (not per endpoint). Rate limits are typically account-wide, not endpoint-specific. Module-level (not instance-level) when the limit is tied to the API key.
3. **Lockout duration.** Match the service's actual recovery window, plus a small buffer (10-30s). Don't guess. Read the API docs or measure empirically.
4. **429 is NOT a standard retry.** A 429 means the error budget is exhausted. The correct response is to freeze all requests for the lockout duration, not retry after 2 seconds. The retry utility handles 5xx/network errors. The circuit breaker handles 429.
5. **Trip BEFORE raising.** The circuit breaker must trip before the 429 exception propagates. This ensures concurrent in-flight requests see the open breaker on their next attempt.
6. **Log state transitions.** Every trip and reset must log at WARNING level with the lockout duration. Operators need to see when the breaker fires without digging through debug logs.

### Death spiral prevention

A "death spiral" occurs when retry responses (429) are themselves counted as errors that extend the lockout window. This is the most common circuit breaker bug.

Prevention:
- The circuit breaker's `acquire()` blocks before any HTTP call is made. While blocked, no requests go out, no 429s are generated, no window is extended.
- After the lockout sleep completes, the breaker resets to Closed. The next request goes through cleanly.
- Never retry a 429 with short delays (2s, 4s, 8s). Each retry generates another 429, which extends the lockout.

## 4. Rate Limiting (Client-Side)

Client-side rate limiting prevents the caller from exceeding the service's throughput budget, even when no errors have occurred yet.

### Token bucket

The standard implementation. Tokens refill at a fixed rate. Each request consumes one token. When empty, the caller waits for a token.

```python
rate = 3.0        # tokens per second
capacity = 5      # burst allowance
```

Rules:

1. Target 80-90% of the service's stated limit. Leave headroom for retries and concurrent processes.
2. Burst capacity should be small (3-5 tokens). Large bursts defeat the purpose.
3. The token bucket controls throughput (requests per second). It does not protect against error-budget exhaustion (4xx per window). That's the circuit breaker's job.
4. For services with separate rate limits per endpoint, use per-endpoint buckets.

### Concurrency limiter

Bounds the number of in-flight requests. Prevents connection pool exhaustion and protects the service from bursty parallelism.

```python
semaphore = asyncio.Semaphore(5)
```

The concurrency limiter and rate limiter are complementary. The semaphore caps parallelism; the token bucket caps throughput. A system can have 5 concurrent requests all rate-limited to 3/second.

## 5. Timeout

1. Set explicit timeouts on every external call. A circuit breaker cannot detect latency-based failures without them.
2. Default: 30s for API calls, 60s for file downloads, 5s for health checks.
3. Timeout applies per-attempt. The retry wrapper creates new attempts, each with its own timeout.
4. When a timeout fires, it counts as a retryable error (same as network error).

## 6. Fallback and Graceful Degradation

When the circuit breaker is open or retries are exhausted:

1. Serve cached data if available (see `PYTHON_CACHING.md` section 2, Graceful Degradation).
2. Return a degraded response (fewer features, partial data) rather than a hard error, when the missing data is non-critical.
3. For critical paths where no fallback exists, propagate the error to a human-in-the-loop gate. Don't silently drop the request.
4. Log the fallback activation at WARNING level with the reason and duration.

## 7. Observability

1. Log every retry attempt at WARNING with: attempt number, max attempts, operation name, error type, sleep duration.
2. Log circuit breaker state transitions (trip/reset) at WARNING.
3. Log rate limiter waits longer than 1s at WARNING.
4. For production services, emit metrics: retry count, circuit breaker state, request latency p50/p95/p99, error rate by status code.

## 8. Testing

Every external API client must have tests for:

1. **Happy path**: 2xx response parsed correctly.
2. **Retryable errors**: 5xx/network error followed by success. Verify correct retry count and that the successful response is returned.
3. **Non-retryable errors**: 400/401/404 propagated immediately. Verify exactly 1 request was made (no retry).
4. **429 trips circuit breaker**: Single 429 response trips the breaker. Verify `is_open` is true.
5. **Circuit breaker blocks requests**: While breaker is open, new requests wait (or fail fast). After lockout, requests succeed.
6. **Circuit breaker reset**: After reset, requests pass through immediately.
7. **Retry delays are mocked**: All tests mock `asyncio.sleep` (retry utility AND circuit breaker) so tests don't block for real.

## 9. Anti-Patterns

| Anti-pattern | Why it fails | Fix |
|---|---|---|
| Retrying 429 with short backoff (2s) | Each retry generates another 429, extending the lockout window. Death spiral. | Circuit breaker with lockout matching the service's rate-limit window. |
| Retrying 404 on sequential ID probes | 404s are 4xx. 25 probes can exhaust the error budget and lock out the entire API key. | Don't probe. Use list/search endpoints. Cache the result. |
| Retry at every layer | Service A retries 3x, B retries 3x, C retries 3x = 27 calls for one user request. | Retry at one layer only (closest to the failing call). |
| No timeout on external calls | Slow service causes thread/connection exhaustion. Circuit breaker never trips because there's no error, just latency. | Explicit per-attempt timeout. |
| Instance-level circuit breaker for account-wide rate limits | Instance 1 trips its breaker, instance 2 keeps hitting the same locked-out API key. | Module-level breaker shared across all instances using the same API key. |
| Token bucket without circuit breaker | Throughput is controlled, but 25 consecutive 404s still exhaust the error budget. | Token bucket + circuit breaker. They solve different problems. |
| Mocking sleep without mocking the breaker | Tests hang or spin because the breaker's `acquire()` loop never exits (time doesn't advance). | Mock sleep in both `retry` and the adapter module. |

## 10. Reference Implementations

Name the real ones in your own codebase here, one row per component, so a
reviewer can read the pattern rather than re-derive it.

| Component | Where it lives | What it is for |
|---|---|---|
| Token bucket rate limiter | `_TokenBucket` in the adapter module | Controls throughput to the external API |
| Circuit breaker (429) | `_CircuitBreaker` beside it, module level | Freezes every call on a 429 for the lockout window |
| Retry with backoff and jitter | `retry_with_backoff()` in the shared utility | Handles 5xx and network errors. A 429 is the breaker's job, not a retry delay |
| Concurrency limiter | `asyncio.Semaphore` held by the adapter | Bounds requests in flight |
| Adapter test suite | The adapter's own test module | One test per category in section 8 |
