# Python Docstring Standard

## Table of Contents

- [TLDR](#tldr)
- [The Contract](#the-contract)
- [Required Template](#required-template)
- [Section-by-Section Rules](#section-by-section-rules)
  - [Summary Line](#summary-line)
  - [Use When](#use-when)
  - [Args](#args)
  - [Returns](#returns)
  - [Raises](#raises)
  - [Side Effects](#side-effects)
  - [Example](#example)
- [What to Leave Out](#what-to-leave-out)
- [Module and Class Docstrings](#module-and-class-docstrings)
- [Pydantic Field Docstrings](#pydantic-field-docstrings)
- [Quick Checklist](#quick-checklist)
- [Full Examples](#full-examples)
- [Sources](#sources)

---

## TLDR

Every public Python function, method, class, and module uses **Google-style docstrings extended for AI agents**. The docstring is the function's contract to both humans and coding agents (Cursor, Claude Code, Copilot). It must answer five questions:

1. What does this do? (one-line imperative summary)
2. When should I call this vs. a sibling function? (Use when)
3. What goes in, with what semantic constraints? (Args)
4. What comes out, with what shape? (Returns)
5. What can fail and is the error retryable? (Raises)

Side-effectful functions add a **Side effects** section. Functions used in unit tests or as worked examples add an **Example** section. Type information goes in PEP 484 hints, never repeated in the docstring.

The acceptance test: a competent agent reading only the signature and docstring (no body) can decide whether to call this function, with what arguments, and what to do with the result.

---

## The Contract

Traditional human-only docstrings answered three questions: what, args, returns. Agentic docstrings have to answer five additional ones because the agent has zero implicit context, can't ask a teammate, and pays a token cost for every wrong assumption.

| Question | Why agents need it | Section |
|---|---|---|
| When should I call this vs. something else? | Disambiguates against sibling functions in the same module. | One-line summary or `Use when:` |
| What are the preconditions? | Agent does not know what state must already exist. | Inline in `Args` or top of docstring |
| What side effects happen? | DB write, external API call, file I/O, idempotency. Agent decides whether it can run autonomously. | `Side effects:` |
| What does success and failure look like concretely? | Agent verifies its own work. Without examples it guesses. | `Example:` |
| What are the error semantics? | Not just "raises X" but: retryable, caller's fault, system fault. | `Raises:` with one-line semantic |

---

## Required Template

```python
def submit_order(order: OrderRequest, *, idempotency_key: str) -> OrderResult:
    """Submit an order to the vendor API and persist the outcome.

    Use when the customer-side validation has passed and the order is
    ready for vendor commitment. For pre-submission validation only,
    call ``validate_order`` instead.

    Args:
        order: Validated order payload. Must have ``item_sku`` set
            and at least one line item.
        idempotency_key: Stable key derived from the customer envelope.
            Reusing the same key returns the prior result without
            re-submitting to the vendor.

    Returns:
        OrderResult with ``vendor_ref`` populated on success. The
        ``status`` field is one of ``confirmed``, ``pending_review``,
        ``rejected``.

    Raises:
        VendorUnavailable: Vendor API returned 5xx or timed out. Retryable.
        InvalidOrder: Order failed vendor-side validation. Not retryable;
            caller must fix the payload.
        DuplicateSubmission: Idempotency key matched a different payload.
            Caller bug; do not retry.

    Side effects:
        - Writes one row to ``order_submissions``.
        - Calls vendor ``POST /v1/orders`` (network).
        - Emits ``order.submitted`` event on success.

    Example:
        >>> result = submit_order(order, idempotency_key="env_abc123")
        >>> result.vendor_ref
        'ORD-44918'
        >>> result.status
        'confirmed'
    """
```

---

## Section-by-Section Rules

### Summary Line

- One imperative sentence. "Submit an order to the vendor." not "Submits an order."
- Fits on one line under 100 characters.
- Ends with a period.
- Describes **what the function does**, not how.
- This is the only line many tools (IDE hover, search previews, agent context windows) will show. Make it standalone.

### Use When

- Required when the module has more than one function with a similar name or shape (`submit_order` vs. `validate_order` vs. `simulate_order`).
- One short paragraph after the summary line.
- States the precondition for choosing this function over its siblings.
- This single section has the largest impact on agent tool selection (per Anthropic's tool-writing research).

### Args

- One entry per parameter, in signature order.
- Format: ``name: description``. Type goes in the signature (PEP 484), not here.
- Description states **semantic constraints**, not type constraints. The type hint already says ``str``; the docstring says *what kind of string* ("Stable key derived from the customer envelope.").
- Document defaults in prose only when the default has behavioral meaning. Don't restate ``default: 10``.
- For optional parameters, state what happens when omitted.
- Keyword-only and positional-only parameters get the same treatment.

### Returns

- Describe the **shape the caller actually consumes**, not the type name.
- Enum and Literal values listed inline so the caller does not have to chase a definition. Don't write "Returns the status." Write "The ``status`` field is one of ``booked``, ``pending_review``, ``rejected``."
- For ``None`` returns on side-effectful functions, omit the section.
- For generators, use `Yields:` instead of `Returns:`.

### Raises

- One entry per exception type the function may raise (including those raised by direct callees that this function does not catch).
- Each entry includes a one-line **semantic**: retryable vs. terminal, caller fault vs. system fault.
- This is the highest-impact agent signal. The agent uses it to decide whether to wrap the call in a retry, surface to user, or escalate.
- Do not document `RuntimeError` and other generic exceptions unless the function raises them deliberately with a specific meaning.

### Side Effects

- Required for any function that mutates external state. Required for any function that does network I/O.
- Bulleted list. Each bullet names the side effect concretely (table name, endpoint path, event name, file path).
- Pure functions skip this section.
- This section lets the agent decide if it can autonomously call the function during exploration, or if it needs human approval first.

### Example

- Required for any function that is part of a public contract (HTTP route handler, public service method, library entry point).
- Use doctest format (``>>>``) so the example is executable and verifiable.
- Use realistic values, not ``"foo"`` and ``"bar"``. The example is an additional test case the agent reads before generating its own.
- Examples in tool descriptions had the largest single impact on Anthropic's SWE-bench scores. Treat them as part of the contract.

---

## What to Leave Out

| Don't include | Why |
|---|---|
| Type repeats: ``param (str): description`` | Type hint already says it. Noise. |
| Implementation narration: "Loops through items and calls X" | The agent reads the body. The docstring is the contract. |
| Trivial restatements: ``"""Return the name."""`` for ``@property def name`` | Adds zero information. Drop the docstring. |
| History: "Renamed from ``submit_request``", "Previously used the V1 API" | Agents trip on stale history. Use git blame for history. |
| Roadmap: "Will add bulk support in S04", "Lands in Phase 1A" | Stale within weeks. Tracker is the source of truth, not the code. |
| Project step IDs: ``S04``, ``R17`` | Internal-only references that mean nothing to the cloned repo. |
| Project lifecycle labels: ``Phase 1A``, ``MVP`` | Same reason. |
| External doc paths: a path into a notes repository, or a document that lives outside this checkout | The repo must be self-contained. |
| The "why" behind the implementation | That goes in a code comment inside the function body, not the docstring. |

The acceptance test: a reader who clones the repo with no other context must understand current behavior from the docstring and the surrounding code alone.

---

## Module and Class Docstrings

**Module docstring** (first statement of the file):

- One paragraph: what this module is responsible for.
- One paragraph: who calls it and what it depends on.
- Optional: a short list of the main exports.

```python
"""Order submission and idempotency tracking.

Called by the order route handler after envelope validation. Depends
on the vendor HTTP client and the ``order_submissions`` table. Owns the
idempotency contract: the same ``idempotency_key`` always returns the
same ``OrderResult`` for the lifetime of the row.
"""
```

**Class docstring**:

- One imperative sentence on what the class is.
- `Attributes:` section for instance attributes (Google style).
- For Pydantic models, attribute docs go in `Field(..., description="...")` instead.
- For service classes, document the constructor's `Args` on the class docstring (not on `__init__`).

---

## Pydantic Field Docstrings

Pydantic models are read by both humans (in IDE tooltips) and agents (extracted into LLM tool schemas, FastAPI OpenAPI docs, JSON Schema). Every field gets a description.

```python
class OrderResult(BaseModel):
    vendor_ref: str = Field(
        ...,
        description=(
            "Vendor-issued order reference. Format: 'ORD-' followed by "
            "5+ digits. Stable for the life of the order."
        ),
    )
    status: Literal["confirmed", "pending_review", "rejected"] = Field(
        ...,
        description=(
            "Outcome of the submission. 'confirmed' means the vendor "
            "accepted and assigned a vendor_ref. 'pending_review' means "
            "a human queue entry was created. 'rejected' means the order "
            "failed vendor validation; vendor_ref will be empty."
        ),
    )
```

Rules:

- Use the verbose `description=...` form, never `Field(..., title="...")`.
- Describe the **value semantics**, not the field name. "Stable for the life of the order" is signal. "The vendor reference" is noise.
- For Literal/Enum fields, document what each value means.
- Stripe's `stripe-python` library added per-field descriptions on every API model for exactly this reason: IDE tooltips and agent context windows benefit equally.

---

## Quick Checklist

For every public function, method, class, and module:

- [ ] One-line imperative summary, ends with a period
- [ ] `Use when:` paragraph if the module has sibling functions with similar shape
- [ ] `Args:` with semantic constraints (not just types)
- [ ] `Returns:` with concrete shape and enum values inline
- [ ] `Raises:` with retryable vs. terminal semantic per exception
- [ ] `Side effects:` for any function that does I/O or mutates state
- [ ] `Example:` with realistic values for any public-contract function
- [ ] No type repeats (signature already has the type)
- [ ] No implementation narration
- [ ] No history, roadmap, or project IDs
- [ ] No external doc paths
- [ ] All Pydantic fields have `Field(..., description="...")`

---

## Full Examples

### Pure function

```python
def parse_vin(raw: str) -> VINComponents:
    """Parse a 17-character VIN into its component fields.

    Args:
        raw: Vehicle identification number. Must be 17 characters,
            alphanumeric, with no I, O, or Q. Whitespace is stripped
            before validation.

    Returns:
        VINComponents with ``wmi``, ``vds``, and ``vis`` populated.

    Raises:
        InvalidVIN: Length, character set, or check digit failed.
            Caller fault; do not retry with the same input.

    Example:
        >>> parts = parse_vin("1HGBH41JXMN109186")
        >>> parts.wmi
        '1HG'
    """
```

### Side-effectful service method

```python
def mark_envelope_processed(self, envelope_id: str) -> None:
    """Persist that an envelope has reached terminal state.

    Use when the order outcome has been written and no further
    processing is needed for this envelope. For partial-progress
    checkpoints, call ``record_envelope_step`` instead.

    Args:
        envelope_id: Customer envelope identifier. Must already exist
            in ``order_envelopes``; otherwise the update is a no-op.

    Raises:
        DBUnavailable: MySQL connection failed. Retryable with backoff.

    Side effects:
        - Updates one row in ``order_envelopes`` (``processed_at = NOW()``).
        - Emits ``envelope.processed`` log line at INFO.
    """
```

### FastAPI route handler

```python
@router.post("/orders", response_model=OrderResult)
async def create_order(
    request: OrderRequest,
    order_service: OrderService = Depends(get_order_service),
) -> OrderResult:
    """Accept an order envelope and submit it to the vendor.

    Use when the customer's webhook delivers a new order. Idempotent on
    ``request.idempotency_key``; safe for the customer to retry.

    Args:
        request: Validated order envelope from the customer webhook.
        order_service: Injected service that owns vendor submission and
            idempotency tracking.

    Returns:
        OrderResult with the vendor reference and status. HTTP 200 on
        all non-error paths (including ``rejected``).

    Raises:
        HTTPException 422: Envelope failed Pydantic validation before
            reaching this handler.
        HTTPException 503: Vendor unavailable. Customer should retry.

    Side effects:
        - One row written to ``order_submissions``.
        - One outbound call to the vendor.
    """
```

---

## Sources

- [Google Python Style Guide §3.8](https://google.github.io/styleguide/pyguide.html): sectioned format, `Args`/`Returns`/`Raises`/`Yields`/`Attributes`.
- [PEP 257](https://peps.python.org/pep-0257/): baseline conventions (triple double quotes, imperative mood, one-line summary).
- [PEP 484](https://peps.python.org/pep-0484/): type hints in signatures, so docstrings don't repeat them.
- [PyTorch Docstring Guidelines](https://github.com/pytorch/pytorch/wiki/Docstring-Guidelines): Meta's public application of Google style at scale.
- [OpenAI Agents SDK function schema](https://openai.github.io/openai-agents-python/ref/function_schema/): docstrings extracted directly into tool schemas.
- [Anthropic, Writing tools for agents](https://www.anthropic.com/engineering/writing-tools-for-agents): tool descriptions as UX, examples and explicit naming, error responses as teaching opportunities.
- [Anthropic, Best practices for Claude Code](https://docs.anthropic.com/en/docs/claude-code/best-practices): context window management, verifiable success criteria.
- [Cursor, Best practices for coding with agents](https://www.cursor.com/blog/agent-best-practices): comments document the *problem*, specific instructions outperform vague.
- [Stripe stripe-python field descriptions](https://github.com/stripe/stripe-python/wiki/Inline-type-annotations): per-field docstrings for IDE and agent discovery.
