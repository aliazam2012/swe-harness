# Python In-Memory Caching Standard

Applies when creating, modifying, or reviewing any in-memory cache in Python services.

## 1. Immutability at the Cache Boundary

The cache must be structurally isolated from callers. Two approaches, in order of preference:

### Preferred: Freeze on store, return frozen

Convert mutable data to immutable structures at store time. `get()` returns the frozen object directly -- no copy needed, O(1).

```python
from types import MappingProxyType

def _freeze(obj):
    if isinstance(obj, dict):
        return MappingProxyType({k: _freeze(v) for k, v in obj.items()})
    if isinstance(obj, list):
        return tuple(_freeze(item) for item in obj)
    return obj

async def put(self, key, data):
    async with self._lock:
        self._store[key] = _CacheEntry(data=_freeze(data), ...)

async def get(self, key):
    async with self._lock:
        entry = self._store.get(key)
        ...
        return entry.data  # frozen, caller cannot mutate
```

Callers that need a mutable copy call `list()` or `dict()` at the call site. The cache never pays the copy cost.

### Acceptable: Deep-copy on store and retrieve

When freezing is impractical (e.g. deeply nested structures with mixed types, third-party objects), use `copy.deepcopy()` on both store and retrieve.

```python
async def put(self, key, data):
    async with self._lock:
        self._store[key] = _CacheEntry(data=copy.deepcopy(data), ...)

async def get(self, key):
    async with self._lock:
        ...
        return copy.deepcopy(entry.data)
```

### Rules

1. Never return the raw stored reference. "Callers don't mutate today" is not a guarantee.
2. For scalar caches (single string, int, bool), neither freeze nor copy is needed. Document why.
3. For large collections where deep-copy is a measurable cost, use `list()` (shallow copy) only when inner elements are provably never mutated. Document the assumption explicitly.

## 2. Graceful Degradation

1. **Cache-check failures must not discard valid cached data.** If the validation call (count-check, heartbeat, version probe) fails with a transient error, serve the cached data and log a warning. A transient error must never propagate into an exception handler that discards a valid cache entry.
2. **Separate the check from the fetch.** Cache validation (e.g. count-check) must be in its own `try/except`, isolated from the full-fetch `try/except`. A check failure returns stale data. A fetch failure on cold start raises.
3. **Cold-start fetch failures raise.** No cached data + unreachable source = raise the appropriate error. Stale-serving only applies when there IS something to serve.
4. **Full re-fetch failures with warm cache serve stale.** If a stale-detected re-fetch fails, log the failure and return existing cached data rather than raising.

Pattern:

```python
cached = CACHE.get(key)
if cached is not None:
    try:
        live_version = check_source(key)
    except TransientError as exc:
        logger.warning("check failed, serving cached: %s", exc)
        return cached  # frozen or deep-copied by cache.get()
    if live_version == cached_version:
        return cached

try:
    fresh = fetch_from_source(key)
except TransientError as exc:
    if cached is not None:
        logger.warning("refresh failed, serving cached: %s", exc)
        return cached
    raise

CACHE[key] = fresh  # cache.put() handles freeze/copy internally
return fresh
```

## 3. Cache Key Alignment

1. **The cache key must match the invalidation signal.** If the invalidation signal is `total_record_count` from the source, the cache key must store that same value -- not a derived value (e.g. `len(filtered_entries)`).
2. Before choosing a cache key, write down: "what value does the check-call return, and what value does the cache store for comparison?" If they come from different code paths or apply different filters, the cache will perpetually invalidate.

## 4. Stampede Protection

When a cache entry is missing or expired, multiple concurrent requests must not all fetch from the source simultaneously.

1. **Single-flight is required** for any cache backed by a rate-limited or latency-sensitive external service. Only one caller fetches; others wait on the lock and receive the cached result.
2. Implementation: the fetch must happen inside the lock scope. The lock serializes concurrent callers so the second caller sees the populated cache.

```python
async def get_or_fetch(self, key, fetch_fn):
    async with self._lock:
        entry = self._store.get(key)
        if entry is not None and not entry.expired:
            return entry.data
        # Only one caller reaches here; others block on the lock
        data = await fetch_fn()
        self._store[key] = _CacheEntry(data=_freeze(data), ...)
        return self._store[key].data
```

3. For TTL caches, prefer **stale-while-revalidate**: serve the expired entry immediately and trigger a background refresh. This avoids blocking callers on the refresh latency.
4. If single-flight is intentionally skipped (e.g. source handles concurrent reads fine, data is small), document why in a comment next to the cache.

## 5. Bounded Growth

1. Every cache must have a growth bound: TTL expiry, max-size eviction, or explicit invalidation.
2. Module-level dict caches (`_CACHE: dict = {}`) must document their growth model in a comment: what keys accumulate, what bounds them, why unbounded growth is acceptable (if it is).
3. For per-customer caches, the bound is the customer allowlist size. Document this.
4. TTL caches should lazily evict on read (check expiry on `get`) and optionally sweep on a timer for memory hygiene.

## 6. Cache Warming

1. **Reference data caches should pre-warm at startup** when the data is required by every request and the source is reliable. This avoids first-request latency spikes and cold-start stampedes.
2. Warming is optional when: the data is customer-specific (unknown until first request), the source is slow/unreliable at boot (would delay startup), or the cache is a pure optimization (miss is acceptable).
3. Warming failures must not block application startup. Log a warning and proceed -- the first request will trigger a cold fetch.

```python
async def lifespan(app):
    try:
        await warm_catalog_cache(customer_ids=ALLOWED_CUSTOMERS)
    except Exception:
        logger.warning("cache warming failed, will fetch on first request")
    yield
```

4. On deploy/restart, every instance starts cold. If warming takes significant time (>5s), consider a readiness probe that waits for warming to complete before accepting traffic.

## 7. Manual Invalidation

1. Every cache must support a `clear()` or `invalidate(key)` method.
2. For production services, expose cache invalidation via an admin endpoint (protected by auth) or a signal handler. When bad data is cached, operators must be able to flush without restarting the app.

```python
@app.post("/admin/cache/clear", dependencies=[Depends(require_admin)])
async def clear_cache(cache_name: str):
    if cache_name == "catalog":
        _CATALOG_CACHE.clear()
    elif cache_name == "addresses":
        await vendor_adapter._address_cache.clear()
    return {"status": "cleared", "cache": cache_name}
```

3. If admin endpoints are not feasible, document the manual invalidation procedure (e.g. "restart the container" or "send SIGUSR1").

## 8. Negative Caching

1. When the source returns an empty/not-found result, cache the absence to prevent repeated lookups.
2. Negative entries should have a shorter TTL than positive entries (e.g. 60s vs 300s) since the data might appear soon.
3. Document which caches implement negative caching and which skip it.

```python
result = await source.lookup(key)
if not result:
    await cache.put(key, _EMPTY_SENTINEL, ttl=60)
    return []
await cache.put(key, result, ttl=300)
return result
```

4. Use a sentinel value (not `None`) so the cache can distinguish "not cached" from "cached as empty."

## 9. Multi-Instance Awareness

In-memory caches are per-process. In multi-instance deployments (ECS, Kubernetes), each instance maintains its own cache.

1. **Acknowledge divergence.** After one instance invalidates, others still serve stale until their own check fires. This is acceptable for reference data that changes infrequently (catalogs, address books).
2. **Not acceptable for:** session data, locks, counters, or any data where stale reads cause correctness issues. Use Redis or another shared cache for these.
3. Document the divergence window: "Each instance checks vendor call count independently. Worst-case divergence = poll interval (e.g. first-request after deploy)."

## 10. Concurrency Safety

1. Async caches use `asyncio.Lock`. Sync caches use `threading.Lock`.
2. Both get and put operations must be within the lock scope.
3. Never `await` an external call (network I/O) while holding the lock unless implementing single-flight (section 4). If the fetch is inside the lock, document that this is intentional for stampede protection.
4. For mixed async/sync access patterns, use `asyncio.Lock` and ensure all callers are async.

## 11. Logging and Observability

1. Cache hits: DEBUG with the cache key.
2. Cache misses (cold start fetches): DEBUG with the key and result size.
3. Stale-serving (degraded mode): WARNING with the reason.
4. Invalidation (stale detected, re-fetching): INFO with old and new key values.
5. For production services, emit cache metrics (hit rate, miss rate, entry count, eviction count) as structured log fields or StatsD/CloudWatch metrics. Hit rate below 80% for reference data caches indicates a problem.

## 12. Testing

Every cache must have tests for:

1. **Hit**: second call for same key returns cached data without re-fetching.
2. **Miss**: first call fetches from source.
3. **Invalidation**: source reports a change, cache re-fetches.
4. **Graceful degradation**: source fails while cache is warm, cached data returned, warning logged.
5. **Mutation safety**: retrieve, mutate the result, retrieve again. Second retrieval is unaffected.
6. **Stampede**: two concurrent calls for the same uncached key result in only one source fetch (if single-flight is implemented).
7. **Negative cache**: lookup for non-existent key caches the absence; second lookup does not call source (if negative caching is implemented).
