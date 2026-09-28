# PR Message Format

## Table of Contents

- [Rules](#rules)
- [Output Format](#output-format)
- [Structure](#structure)
- [Anti-Patterns](#anti-patterns)

---

## Rules

1. Descriptive without being verbose — say what matters, skip the fluff
2. Always Markdown — headers, bullet points, tables where useful
3. Note the problem — in simple words, what was broken or needed (FIIP: Facts + Impact)
4. Note the solution — in simple words, what approach was taken (FIIP: Proposal)
5. Provide the solutioning — in simple words, how it was implemented
6. Note the testing done — what was tested, how many tests, what passed
7. Use a helpful emoji system — emojis for section headers to make it scannable
8. Follow the FIIP framework from `TECHNICAL_COMMUNICATION.md` for the prose sections

---

## Output Format

- ALWAYS output the PR message inside a markdown code block (triple backticks with `markdown` language tag)
- The author copies the raw Markdown straight into the GitHub PR description
- NEVER render the PR message as formatted chat text

---

## Structure

```markdown
## 🔧 Title

### ❌ Problem
Simple explanation of what was wrong or needed.

### ✅ Solution
Simple explanation of the approach taken.

### 🏗️ How It Works
Key implementation details — files changed, architecture decisions, new patterns.

### 🧪 Testing
What was tested and results.

### 📝 Notes
Any env var changes, migration steps, or deployment considerations.
```

---

## Per-Commit Breakdown (Multi-Commit PRs)

When a PR has multiple commits that each address a distinct concern, use a **Before / Why / Now** structure per commit inside the `🏗️ How It Works` section. This makes each change self-contained and reviewable.

Format:

```markdown
**`<short-sha>` — <one-line description>**
- **Before**: What the behavior was before this commit.
- **Why**: Why it needed to change (the problem it caused).
- **Now**: What the behavior is after this commit.
```

Rules:
- Each commit gets its own block. Don't merge unrelated changes into one block.
- Keep each bullet to 1-3 sentences. The commit diff has the details.
- If a commit is a pure bug fix, the **Before** should describe the broken behavior, not the code structure.
- If a commit is a design change discovered during testing, say so — don't frame reactive fixes as planned work.
- Categorize the commits in the `✅ Solution` section (e.g., "Two planned steps, two design fixes from live testing, two bug fixes") so the reviewer knows the shape before reading details.


---

## Anti-Patterns

- ❌ Walls of text — keep sections tight
- ❌ Repeating the same info in multiple sections
- ❌ Overly technical language when simple words work
- ❌ Tables for everything — use them only when they add clarity
- ❌ Rendering the PR as formatted chat — always give raw Markdown in a code block
