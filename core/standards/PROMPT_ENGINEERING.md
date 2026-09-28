# Prompt Engineering Standards for LLM-Powered Extraction

Last updated: 2026-04-05
Sources: OpenAI Cookbook (GPT-5.4 Vision & Document Understanding), OpenAI Structured Outputs docs, Google Document AI, Anthropic prompt engineering guide, FAANG production case studies, academic benchmarks (2025-2026).

---

## 1. Prompt Length Budget

| Threshold | Effect |
|-----------|--------|
| 150–300 words | Optimal for most extraction tasks |
| ~800 tokens (system prompt) | Instruction adherence starts to dilute |
| ~3,000 tokens | Measurable performance degradation across all major models |

**Rule**: If a prompt exceeds 800 tokens, look for material to move out — into Structured Outputs schemas, separate per-type prompts, or few-shot examples supplied at call time rather than baked into the system prompt.

---

## 2. Structured Outputs (OpenAI)

Use `response_format` with `json_schema` + `strict: true` instead of asking for JSON in the prompt.

**Benefits**:
- Guaranteed schema-compliant JSON — no retries, no format validation
- Schema tokens are FREE — they don't count toward input token limit
- Prompt can focus entirely on extraction logic, not formatting rules
- Works with Pydantic models for schema generation

**When to use**: Always, for any extraction task returning structured data. Remove all "OUTPUT FORMAT" sections from prompts when using Structured Outputs.

**How**:
```python
response = client.chat.completions.create(
    model="gpt-4o",
    messages=[...],
    response_format={
        "type": "json_schema",
        "json_schema": {
            "name": "extraction_result",
            "strict": True,
            "schema": { ... }
        }
    }
)
```

---

## 3. Image Detail Parameter (Vision)

| Setting | Use when | Token cost |
|---------|----------|------------|
| `detail="auto"` | Clean digital PDFs, standard layouts | Lowest (model decides) |
| `detail="high"` | Dense scans, small labels, tables with fine text | ~765-1,105 tokens per image |
| `detail="original"` | Handwriting, tiny fields, low-contrast scans, coffee-stained docs | Highest fidelity |

**Rule**: Start with `auto`. If the model misses small fields or line items, escalate to `high` or `original` before touching the prompt.

---

## 4. Reasoning Effort Parameter

Use `reasoning={"effort": "high"}` when the answer requires combining information from multiple parts of the document.

**Good candidates for high reasoning effort**:
- Summing line items (our balance_due problem)
- Cross-referencing fields across sections
- Tables where the answer requires comparing rows/columns
- Any task where the image is readable but the model still gets the answer wrong

**Not needed for**: Simple field reads (invoice number, date, name).

---

## 5. Few-Shot Examples

- 2-5 examples boost structured output reliability from 71% → 94%
- Google recommends 5-10 training documents for few-shot approaches
- Examples should cover EDGE CASES, not just the happy path

**Trade-off**: Examples eat tokens. Prioritize examples that address specific failure modes over generic ones. If prompt is already near budget, move examples to a separate call or use fine-tuning.

**Format**: Place examples BEFORE the actual document, not after instructions. The model processes them as context, not appendix.

---

## 6. XML Tags for Structure

XML-tagged structured output outperforms JSON-requested output by **11% on average compliance rate** (Anthropic research).

Use XML tags to separate:
- `<instructions>` — what to do
- `<schema>` — expected output shape
- `<examples>` — few-shot demonstrations
- `<document>` — the actual content to extract from

This helps the model distinguish between instruction content and extraction content, reducing confusion on documents that happen to contain instruction-like text.

---

## 7. Prompt Architecture Patterns

### Pattern A: Single Mega-Prompt (simple use cases)
One prompt handles classification + extraction. Fast, cheap, but dilutes at scale.

**Use when**: <5 field types, <800 token prompt, document types are distinct.

### Pattern B: Classify → Extract Pipeline (recommended for complex use cases)
1. **Classify prompt** (lean, <200 tokens): Determine document type
2. **Per-type extraction prompt** (focused, <500 tokens each): Extract fields for that specific type

**Benefits**: Each prompt stays under the dilution threshold. Per-type prompts can have tailored examples and rules without bloating other types.

### Pattern C: Classify → Extract → Verify (highest accuracy)
Adds a verification pass that checks extracted values against the document.

**Use when**: Financial data where hallucination is unacceptable.

### Pattern D: Crop-and-Rerun (nuclear option)
1. First pass: Identify the region of interest (e.g., charges table)
2. Crop that region locally
3. Second pass: Focused extraction on just the crop

**Use when**: Model can see the document but consistently fails on a specific section. Latency-tolerant workflows only.

---

## 8. Temperature & Determinism

- **Temperature 0**: Use for all extraction tasks. We want deterministic, reproducible outputs.
- **Top-p**: Leave at default (1.0) when temperature is 0.
- **Seed parameter**: Use a fixed seed for reproducibility in evals.

---

## 9. Null Over Hallucination

Always instruct: **return null for fields where confidence is low**. Never guess.

Financial extraction hallucination is the #1 production risk. An incorrect amount is worse than a missing amount — missing triggers human review, incorrect silently corrupts data.

**Prompt pattern**: "If a field is not clearly visible or you are uncertain, omit it entirely. Do NOT guess, infer, or use placeholder values."

---

## 10. Production Accuracy Benchmarks (2025-2026)

For reference when setting expectations:

| Approach | Field-level accuracy |
|----------|---------------------|
| Zero-shot GPT-4o (no optimization) | ~85% |
| Few-shot GPT-4o + prompt engineering | ~91% |
| Gemini 2.5 Pro (clean invoices) | ~96.5% |
| Gemini 2.5 Pro (scanned docs) | ~92.7% |
| Dedicated OCR/IDP systems | ~98.7% |
| Fine-tuned LLM (domain-specific) | ~99% |

Prompt engineering alone typically plateaus around 91-96%. To break through: fine-tune, use Structured Outputs + reasoning effort, or implement crop-and-rerun.

---

## 11. Eval-Driven Development

Every prompt change must be validated by eval. The loop:

1. **Baseline eval** — measure current accuracy per field
2. **Identify failure mode** — categorize: OCR issue, reasoning issue, prompt dilution, schema issue
3. **Targeted fix** — change ONE thing (prompt text, model param, architecture)
4. **Re-eval** — measure improvement, check for regressions
5. **Repeat** — until target accuracy or diminishing returns

Track: classification accuracy, per-field accuracy, total field accuracy, false positives (hallucinated fields), latency, cost per call.

---

## Quick Decision Tree

```
Is the model returning malformed JSON?
  → Use Structured Outputs (§2)

Is the model missing small text or fine details?
  → Raise image detail to "original" (§3)

Is the model reading the text correctly but computing the wrong answer?
  → Raise reasoning effort (§4)

Is the prompt >800 tokens and accuracy plateauing?
  → Split into classify + per-type extract (§7 Pattern B)

Are 2-3 specific documents failing consistently?
  → Add few-shot examples for those edge cases (§5)

Has prompt engineering plateaued at ~91-96%?
  → Consider fine-tuning or crop-and-rerun (§7 Pattern D, §10)
```
