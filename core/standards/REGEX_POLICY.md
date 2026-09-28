# Regex Policy

## Table of Contents

- [TLDR](#tldr)
- [The Decision Framework](#the-decision-framework)
- [Why Regex Is a Liability](#why-regex-is-a-liability)
- [What Google Does](#what-google-does)
- [Production Incidents](#production-incidents)
- [The Hierarchy: What to Use Instead](#the-hierarchy-what-to-use-instead)
- [Python-Specific Rules](#python-specific-rules)
- [LLM Output Parsing](#llm-output-parsing)
- [When Regex Is Acceptable](#when-regex-is-acceptable)
- [Required Safeguards for Accepted Regex](#required-safeguards-for-accepted-regex)
- [Anti-Patterns](#anti-patterns)
- [Regex Done Right](#regex-done-right)
- [Agent-Specific Pitfalls](#agent-specific-pitfalls)
- [Existing Code Stance](#existing-code-stance)
- [Code Review Checklist](#code-review-checklist)
- [Quick Reference Card](#quick-reference-card)
- [Sources](#sources)

---

## TLDR

Default position: **don't use regex**. Use string methods, structured parsers, or Pydantic validators instead. Regex is acceptable only when the pattern genuinely requires alternation, repetition, or character class logic that string methods can't express. When you do use regex, compile patterns at module level and never accept regex from untrusted input without a linear-time engine.

This policy is informed by Google's internal Abseil guidance, production outages at Cloudflare and Stack Overflow, ReDoS research (ACM 2025), and structured output standards from OpenAI and Anthropic.

---

## The Decision Framework

Before writing a regex, answer this question: **can a string method do this?**

| Task | Use | Don't use |
|------|-----|-----------|
| Check if string starts with a prefix | `str.startswith()` | `re.match(r"^prefix")` |
| Check if string ends with a suffix | `str.endswith()` | `re.search(r"suffix$")` |
| Check if substring exists | `"needle" in haystack` | `re.search(r"needle")` |
| Split on a fixed delimiter | `str.split(",")` | `re.split(r",")` |
| Replace a fixed substring | `str.replace("old", "new")` | `re.sub(r"old", "new")` |
| Strip whitespace | `str.strip()` | `re.sub(r"^\s+|\s+$", "")` |
| Case-insensitive comparison | `str.lower() == target` | `re.match(r"(?i)target")` |
| Case-insensitive containment | `"error" in text.lower()` | `re.search(r"error", text, re.I)` |
| Remove a known prefix | `str.removeprefix("prefix")` | `re.sub(r"^prefix", "")` |
| Remove a known suffix | `str.removesuffix(".txt")` | `re.sub(r"\.txt$", "")` |
| Split at first occurrence | `str.partition("=")` | `re.split(r"=", s, maxsplit=1)` |
| Split at last occurrence | `str.rpartition("/")` | `re.match(r"(.*)/(.*)", s)` |
| Validate email format | Pydantic `EmailStr` | `re.match(r"^[a-zA-Z0-9...]")` |
| Parse JSON from text | `json.loads()` | `re.search(r"\{.*\}")` |
| Parse dates | `datetime.strptime()` or `dateutil` | `re.match(r"\d{4}-\d{2}-\d{2}")` |
| Parse URLs | `urllib.parse.urlparse()` | `re.match(r"https?://...")` |
| Parse HTML/XML | `BeautifulSoup` or `lxml` | `re.findall(r"<tag>.*?</tag>")` |
| Validate IP address | `ipaddress.ip_address()` | `re.match(r"\d{1,3}\.\d{1,3}...")` |
| Extract structured LLM output | Structured output API / Pydantic | `re.search(r"\{.*\}", response)` |

If the answer is yes, use the string method. It's faster, more readable, and doesn't carry ReDoS risk.

---

## Why Regex Is a Liability

Three problems with regex in production code:

**1. ReDoS (Regular Expression Denial of Service).** Python's `re` module uses a backtracking engine. Certain patterns exhibit exponential time complexity on specific inputs. A 30-character input can freeze a process for minutes. This isn't theoretical; it has taken down Cloudflare and Stack Overflow (see incidents below). The fourth most common server-side vulnerability class in npm (ACM ASIACCS 2025).

**2. Readability.** Regex is write-only code. The pattern `^(?:(?:[a-zA-Z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[a-zA-Z0-9!#$%&'*+/=?^_`{|}~-]+)*|"(?:[\x01-\x08\x0b\x0c\x0e-\x1f\x21\x23-\x5b\x5d-\x7f]|\\[\x01-\x09\x0b\x0c\x0e-\x7f])*")@...)` is the RFC 5322 email spec. Nobody reviews that in a PR. Nobody debugs it at 2 AM. String methods and purpose-built parsers are self-documenting.

**3. False confidence.** Regex gives a veneer of validation without actually parsing structure. A regex that "validates" JSON will fail on nested braces, escaped quotes, and unicode escapes. A regex that "parses" HTML will fail on self-closing tags, attributes with quotes, and CDATA sections. These aren't edge cases; they're the normal cases that regex can't handle because regex matches regular languages, and JSON/HTML/XML/email addresses are not regular languages.

---

## What Google Does

Google's internal Abseil performance tips (public, abseil.io/fast/21) are explicit:

> "In many situations, regular expressions are unnecessary because simple string operations will suffice. [...] These are much faster than regular expressions and more readable, so using them where possible is recommended."

Google built RE2, an alternative regex engine that guarantees linear-time matching by construction. It's been in production at Google since 2006. The fact that Google's response to regex problems was to build an entirely new engine tells you how seriously they take this. RE2 intentionally drops backtracking features (backreferences, lookaheads) because those are what make regex dangerous.

Key takeaways from Google's approach:
1. Prefer string operations over regex for simple matching.
2. When regex is needed, use a linear-time engine (RE2).
3. Precompile patterns. Never construct regex objects inside loops.
4. Anchor patterns with `^` and `$`.
5. Avoid `.*` (greedy dot-star). Use specific character classes.

---

## Production Incidents

| Incident | Date | Root cause | Impact | Fix |
|----------|------|-----------|--------|-----|
| Cloudflare global outage | July 2, 2019 | WAF rule with `.*.*=.*` (nested quantifiers). Catastrophic backtracking on every request. | 27 minutes of global downtime. 100% CPU on all edge nodes. Revenue loss in the millions. | Replaced pattern, added ReDoS testing to CI. |
| Stack Overflow outage | July 20, 2016 | Whitespace-trimming regex `^\s+|\s+$` hit a post with 20,000 consecutive spaces. Backtracking engine explored ~200M paths. | 34-minute outage. Load balancer health checks hit the same page, cascading the failure. | Replaced regex with a substring function. |

In both cases the fix was the same: **stop using regex for something a string method handles**.

---

## The Hierarchy: What to Use Instead

Ordered by preference. Pick the first one that works.

**1. Built-in string methods.** `str.startswith()`, `str.endswith()`, `in`, `str.split()`, `str.replace()`, `str.strip()`, `str.lower()`, `str.removeprefix()`, `str.removesuffix()` (3.9+), `str.partition()`, `str.rpartition()`. Fastest, most readable, zero risk.

**2. Standard library parsers.** `json.loads()`, `datetime.strptime()`, `urllib.parse.urlparse()`, `ipaddress.ip_address()`, `email.utils.parseaddr()`, `csv.reader()`. Purpose-built, well-tested, handle edge cases regex can't.

**3. Pydantic validators.** `EmailStr`, `HttpUrl`, `IPvAnyAddress`, `constr(pattern=...)`. Declarative, composable, and the validation error messages are actually useful.

**4. Domain-specific parsers.** `BeautifulSoup`/`lxml` for HTML/XML, `sqlparse` for SQL, `phonenumbers` for phone numbers, `dateutil.parser` for fuzzy dates.

**5. Compiled regex (module-level, anchored, minimal).** Only when steps 1-4 can't express the pattern. Compile at module level. Anchor with `^`/`$`. Use specific character classes, not `.`. Add a comment explaining what the pattern matches and why string methods won't work.

**6. RE2 via `google-re2` package.** When the regex processes untrusted input or the pattern is complex enough that backtracking risk is non-trivial. Drop-in for most `re` usage, guarantees linear-time matching.

---

## Python-Specific Rules

### Always compile at module level

```python
# GOOD: compiled once at import time
_ORDER_ID_PATTERN = re.compile(r"^ORD-\d{6,10}$")

def is_valid_order_id(order_id: str) -> bool:
    return bool(_ORDER_ID_PATTERN.match(order_id))
```

```python
# BAD: compiled on every call
def is_valid_order_id(order_id: str) -> bool:
    return bool(re.match(r"^ORD-\d{6,10}$", order_id))
```

Python's `re.compile()` caches internally, but module-level compilation makes the cost explicit and the pattern discoverable. It also prevents the pattern from being rebuilt if the cache is evicted under memory pressure.

### Name regex constants descriptively

```python
# GOOD: name says what it matches
_TRACKING_NUMBER_PATTERN = re.compile(r"^1Z[A-Z0-9]{16}$")
_BOL_REFERENCE_PATTERN = re.compile(r"^[A-Z]{2}\d{8}$")

# BAD: generic names
PATTERN = re.compile(r"^1Z[A-Z0-9]{16}$")
REGEX = re.compile(r"^[A-Z]{2}\d{8}$")
```

### Use raw strings

Always use `r"..."` for regex patterns. Without it, Python interprets backslash sequences before the regex engine sees them, creating silent bugs (e.g., `\b` is a backspace in a regular string but a word boundary in regex).

### Prefer `re.match()` over `re.search()` with `^`

`re.match()` anchors at the start by default. Use it instead of `re.search(r"^...")`. Use `re.fullmatch()` when the entire string must match.

### Use `re.VERBOSE` for complex patterns

If a pattern exceeds ~40 characters, use `re.VERBOSE` to break it across lines with inline comments. A 10-line annotated pattern is easier to maintain than a 60-character one-liner.

```python
_SHIPMENT_REF_PATTERN = re.compile(r"""
    ^
    (?P<carrier>[A-Z]{2,4})     # 2-4 letter carrier code
    -
    (?P<year>\d{4})             # 4-digit year
    -
    (?P<sequence>\d{5,8})       # 5-8 digit sequence number
    $
""", re.VERBOSE)
```

---

## LLM Output Parsing

Never use regex to extract structured data from LLM responses. This is a solved problem.

| Provider | Method | Guarantee |
|----------|--------|-----------|
| OpenAI | `response_format: { type: "json_schema", strict: true }` | Constrained decoding. Schema enforced at token level. |
| Anthropic | Tool use with `input_schema` | Constrained decoding. Model emits only schema-valid JSON. |
| Google Gemini | `responseMimeType: "application/json"` + `responseSchema` | Server-side constraint. |

If you're calling an LLM and parsing the response with `re.search(r"\{.*\}", response)`, you will hit failures on nested braces, code fences, escaped quotes, multi-line strings, and responses containing multiple JSON objects. Use the provider's structured output API or Pydantic with Instructor.

---

## When Regex Is Acceptable

Regex is the right tool when the pattern genuinely requires features that string methods can't express:

1. **Character class alternation.** Matching any of several character ranges (e.g., `[A-Za-z0-9_-]`).
2. **Repetition with bounds.** Matching a digit sequence of variable length (e.g., `\d{5,10}`).
3. **Capture groups for extraction.** Pulling named fields out of a known format (e.g., log lines with a fixed structure).
4. **Alternation across patterns.** Matching one of several possible formats (e.g., `(?:USD|EUR|GBP)\s?\d+`).
5. **DB/table name validation in SQL.** Validating identifiers before interpolation (this is already in `python.mdc`).

Even in these cases, the pattern should be:
- Compiled at module level
- Anchored (`^`, `$`)
- Using specific character classes (not `.`)
- Commented with what it matches and why
- Tested with both matching and non-matching inputs

---

## Required Safeguards for Accepted Regex

When regex passes the decision framework and is genuinely needed:

1. **Compile at module level.** Never inside functions or loops.
2. **Anchor the pattern.** Use `^` and `$` (or `re.fullmatch()`).
3. **Avoid nested quantifiers.** Never `(a+)+`, `(a*)*`, `(.*)+`, `(\w+)*`. These are the canonical ReDoS shapes.
4. **Avoid overlapping alternation under repetition.** Never `(a|a)+` or `(.|a)*`.
5. **Use specific character classes.** `[^"]*` instead of `.*` inside quotes. `\d` instead of `.` for digits.
6. **Cap input length before matching.** If the input comes from outside the system, validate length before passing to regex.
7. **Add a code comment.** Explain what the pattern matches, why it's needed, and why string methods won't work.
8. **Test pathological inputs.** Include a test case with long repetitive input to verify the pattern doesn't backtrack.

For untrusted input (user-supplied strings, webhook payloads, email bodies), consider `google-re2` (the Python binding for Google's RE2 engine). It guarantees linear-time matching by construction. Install: `pip install google-re2`. API is nearly identical to `re`.

---

## Anti-Patterns

### Regex for fixed-string checks

```python
# BAD
if re.search(r"error", log_line):
    handle_error()

# GOOD
if "error" in log_line:
    handle_error()
```

### Regex for prefix/suffix checks

```python
# BAD
if re.match(r"^https://", url):
    ...

# GOOD
if url.startswith("https://"):
    ...
```

### Regex for splitting on fixed delimiters

```python
# BAD
parts = re.split(r",", csv_line)

# GOOD
parts = csv_line.split(",")
```

### Regex for stripping whitespace

```python
# BAD (this is literally what caused the Stack Overflow outage)
cleaned = re.sub(r"^\s+|\s+$", "", text)

# GOOD
cleaned = text.strip()
```

### Regex for JSON extraction from LLM output

```python
# BAD
match = re.search(r"\{.*\}", response.text, re.DOTALL)
data = json.loads(match.group(0))

# GOOD: use structured output
response = client.chat.completions.create(
    model="gpt-4o",
    messages=messages,
    response_format={"type": "json_schema", "json_schema": schema},
)
data = json.loads(response.choices[0].message.content)
```

### Regex for email validation

```python
# BAD
if re.match(r"^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$", email):
    ...

# GOOD
from pydantic import EmailStr, validate_email
try:
    validate_email(email)
except ValueError:
    ...
```

### Regex for removing a known prefix/suffix

```python
# BAD
cleaned = re.sub(r"^data:", "", uri)
filename = re.sub(r"\.tmp$", "", path)

# GOOD (Python 3.9+)
cleaned = uri.removeprefix("data:")
filename = path.removesuffix(".tmp")
```

### Regex for splitting at first occurrence

```python
# BAD
key, value = re.split(r"=", line, maxsplit=1)

# GOOD
key, _, value = line.partition("=")
```

### Regex for URL parsing

```python
# BAD
match = re.match(r"https?://([^/]+)(.*)", url)
host, path = match.group(1), match.group(2)

# GOOD
from urllib.parse import urlparse
parsed = urlparse(url)
host, path = parsed.hostname, parsed.path
```

---

## Regex Done Right

When regex is the correct tool, this is what it looks like. Every example follows the safeguards: module-level compilation, anchoring, specific character classes, named groups, and a descriptive constant name.

### Validating a structured identifier

```python
import re

_UPS_TRACKING_PATTERN = re.compile(r"^1Z[A-Z0-9]{16}$")

def is_ups_tracking_number(tracking_number: str) -> bool:
    """UPS tracking numbers: '1Z' + 16 alphanumeric chars. String methods
    can check the prefix but not the character class + length constraint."""
    return bool(_UPS_TRACKING_PATTERN.fullmatch(tracking_number))
```

Why regex: needs character class `[A-Z0-9]` with exact length `{16}`. `startswith("1Z")` handles the prefix but can't enforce the rest.

### Extracting named fields from a known format

```python
_LOG_LINE_PATTERN = re.compile(r"""
    ^
    (?P<timestamp>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})  # ISO timestamp
    \s+
    (?P<level>DEBUG|INFO|WARNING|ERROR|CRITICAL)           # log level enum
    \s+
    (?P<message>.+)                                        # rest of line
    $
""", re.VERBOSE)

def parse_log_line(line: str) -> dict[str, str] | None:
    """Extract timestamp, level, and message from structured log lines.
    String split would work for simple cases but can't enforce the level
    enum or timestamp format in one pass."""
    match = _LOG_LINE_PATTERN.match(line)
    return match.groupdict() if match else None
```

Why regex: alternation (`DEBUG|INFO|...`), named capture groups, and format enforcement combined. `str.split()` would split on whitespace but can't validate the timestamp format or restrict levels to the enum.

### Normalizing variable whitespace

```python
_MULTI_SPACE_PATTERN = re.compile(r"\s{2,}")

def normalize_whitespace(text: str) -> str:
    """Collapse runs of 2+ whitespace chars to a single space.
    str.split() + join works too, but strips leading/trailing and doesn't
    preserve single spaces in the original."""
    return _MULTI_SPACE_PATTERN.sub(" ", text)
```

Why regex: `\s{2,}` with bounded repetition. No nested quantifiers, no backtracking risk. `" ".join(text.split())` is an alternative but changes semantics (strips edges, collapses all whitespace including singles).

---

## Agent-Specific Pitfalls

AI coding agents have specific failure modes with regex that human engineers are less prone to. This section addresses those directly.

**1. Training-data bias toward regex.** LLMs are trained on massive codebases where regex is overrepresented because it's been the default tool for decades. When an agent sees "check if a string matches a pattern," its first instinct is `re.match()`. Fight this. Ask "can a string method do this?" before every pattern.

**2. Generating complex regex instead of composing simple operations.** An agent asked to "extract the domain from an email" might generate `re.match(r"^[^@]+@([^@]+)$", email).group(1)`. The correct answer is `email.split("@")[1]` or `email.utils.parseaddr()`. Agents tend toward single-expression solutions. String methods compose better and fail more explicitly.

**3. Copy-pasting patterns without understanding them.** Agents reproduce regex patterns from training data without verifying they're correct for the current input domain. A "URL validation regex" from a StackOverflow answer circa 2015 doesn't handle modern TLDs, internationalized domain names, or IPv6 addresses. Use `urllib.parse.urlparse()`.

**4. Never testing edge cases.** Agents write regex and test it against 2-3 happy-path inputs. They don't test empty strings, strings with only whitespace, strings with unicode, strings at length boundaries, or strings designed to trigger backtracking. When regex is used, the test file must include pathological inputs.

**5. Using `re.DOTALL` or `re.MULTILINE` without understanding the difference.** `re.DOTALL` makes `.` match newlines. `re.MULTILINE` makes `^`/`$` match at line boundaries instead of string boundaries. Agents frequently confuse them or apply both "just in case," which changes matching semantics in unexpected ways. If you need either flag, you probably need a real parser.

**6. Regex for things that aren't regular languages.** JSON, HTML, XML, email addresses (the full RFC), and nested parentheses are not regular languages. Regex cannot correctly parse them by definition. Agents confidently write `re.findall(r"<div>(.*?)</div>", html)` and it works on the test input but fails on real HTML. Use the domain parser.

### The self-check before writing regex

Before an agent writes any `re.*` call, answer these in order. Stop at the first "yes":

1. Can a string method do this? → Use it.
2. Can a stdlib parser do this? → Use it.
3. Can Pydantic validate this? → Use it.
4. Is the input a non-regular language (JSON, HTML, XML, nested structures)? → Use a real parser.
5. None of the above? → Regex is acceptable. Follow the safeguards.

---

## Existing Code Stance

When an agent encounters existing regex in a codebase:

**During a focused task (bugfix, feature, refactor with a defined scope):**
- Don't refactor existing regex outside the task scope. That's scope creep.
- If the existing regex is part of the code you're modifying and it's simple enough to replace with string methods, do it as part of the change. Mention it in the PR.
- If the existing regex is complex or risky to change, leave it and note it as tech debt.

**During a code review:**
- Flag new regex that violates this policy (see Code Review Checklist below).
- Don't demand refactoring of existing regex that the PR author didn't touch. Comment it as a follow-up suggestion, not a merge blocker.

**During an audit or dedicated cleanup:**
- Proactively scan for regex anti-patterns (fixed-string checks, `^\s+|\s+$`, unanchored patterns, nested quantifiers).
- Prioritize by risk: untrusted input patterns first, internal-only patterns last.
- Each replacement is its own commit with a clear description.

**Never:**
- Refactor a regex you don't fully understand in a drive-by change.
- Replace regex in a hot path without benchmarking the alternative.
- Remove regex that's protected by existing tests without running those tests.

---

## Code Review Checklist

When reviewing a PR that introduces or modifies regex, check each item:

| Check | What to look for | Verdict |
|-------|-----------------|---------|
| Necessity | Could string methods, stdlib parsers, or Pydantic handle this? | Block if yes |
| Compilation | Is the pattern compiled at module level? | Block if inside a function/loop |
| Anchoring | Does the pattern use `^`/`$` or `fullmatch()`? | Block if unanchored on untrusted input |
| Nested quantifiers | Any `(X+)+`, `(X*)*`, `(.*)+`, `(\w+)*` shapes? | Block (ReDoS vector) |
| Dot-star | Uses `.*` or `.+`? Could it use a specific character class? | Flag, suggest replacement |
| Naming | Is the compiled pattern named descriptively? | Flag if generic (`PATTERN`, `REGEX`) |
| Comment | Does a comment explain what it matches and why regex is needed? | Flag if missing |
| Raw string | Uses `r"..."` syntax? | Block if not (silent backslash bugs) |
| Tests | Are there test cases for matching, non-matching, and pathological inputs? | Flag if missing pathological tests |
| Untrusted input | If input is external, is `google-re2` used instead of `re`? | Flag |

---

## Quick Reference Card

```
Can a string method do it?           → Use the string method.
Can a stdlib parser do it?           → Use the parser (json, datetime, urllib, csv, ipaddress).
Can Pydantic validate it?            → Use a Pydantic type or constr().
Can a domain library do it?          → Use the library (BeautifulSoup, dateutil, phonenumbers).
None of the above work?              → Regex is acceptable. Compile at module level, anchor, comment.
Processing untrusted input?          → Use google-re2 instead of re.
Parsing LLM output?                  → Use structured output APIs. Never regex.
```

---

## Sources

1. Google Abseil. "Performance Tip of the Week #21: Improving the efficiency of your regular expressions." abseil.io/fast/21.
2. Russ Cox. "Regular Expression Matching in the Wild." swtch.com/~rsc/regexp/regexp3.html. (RE2 design and implementation.)
3. Google. "RE2: an efficient, principled regular expression library." github.com/google/re2. In production at Google since 2006.
4. Cloudflare. "Details of the Cloudflare outage on July 2, 2019." (WAF regex with nested quantifiers caused 27-minute global outage.)
5. Stack Overflow. "Outage Postmortem, July 20, 2016." (Whitespace-trimming regex caused 34-minute outage. Replaced with substring function.)
6. ACM ASIACCS 2025. "SoK: A Literature and Engineering Review of Regular Expression Denial of Service (ReDoS)." (ReDoS is the 4th most common server-side vulnerability in npm.)
7. Snyk Learn. "ReDoS Tutorial & Examples." learn.snyk.io/lesson/redos/. (Mitigation strategies, engine comparison.)
8. llmbestpractices.com. "Structured Output: Never regex a JSON object out of free-form prose." (OpenAI, Anthropic, Gemini structured output APIs.)
