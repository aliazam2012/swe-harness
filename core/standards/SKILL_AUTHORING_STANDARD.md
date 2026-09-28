# Skill Authoring Standard

The bar for building an Agent Skill. A skill is a `SKILL.md` file (plus optional bundled files and scripts) that teaches an agent how to do one job well. This standard is the synthesis of how Anthropic, Google, OpenAI, Cursor, and the open community say to build them, plus the house rules that sit on top.

For installing, versioning, vetting, and where skills live, see `MCP_SKILL_MANAGEMENT.md`. This doc covers authoring and quality. Every skill passes both.

## Table of Contents

- [When to use this standard](#when-to-use-this-standard)
- [Choosing the right tool](#choosing-the-right-tool)
- [The mental model: progressive disclosure](#the-mental-model-progressive-disclosure)
- [The seven principles](#the-seven-principles)
- [Anatomy of a skill](#anatomy-of-a-skill)
- [The description is the product](#the-description-is-the-product)
- [Body patterns](#body-patterns)
- [Scripts](#scripts)
- [Security and least privilege](#security-and-least-privilege)
- [Evaluation and iteration](#evaluation-and-iteration)
- [Anti-patterns](#anti-patterns)
- [Harness-specific features](#harness-specific-features)
- [Authoring checklist](#authoring-checklist)
- [Sources](#sources)

---

## When to use this standard

Read this before creating or editing any `SKILL.md`. It governs the skill file, its bundled references, and its scripts.

Where a skill lives (reconciled with `MCP_SKILL_MANAGEMENT.md`): a shared skill is authored as a real directory in the repository that owns it and surfaced to each harness by symlink, so one edit updates every harness and the skill is in version control from the first commit. A personal skill is authored the same way, in whichever unit owns it, and symlinked into every harness that uses it. A project-scoped skill lives in that project's own skills directory. Never hand-author a directory inside a folder the harness manages for itself: the install step is what places the symlink there, and a hand-made directory beside it becomes a copy that goes stale without a word.

Before building a new skill at all, clear the market-first gate: an MCP server, an existing skill, or a library may already do the job. A skill is the right tool when the job is a repeatable procedure or body of judgment that an agent should apply on its own, not a one-off prompt and not a network integration that wants an MCP server.

## Choosing the right tool

A skill is one option among several. Picking the wrong container is the most common mistake in our setup, where rules, skills, MCP servers, and subagents all coexist. Decide first:

| Need | Use | Why |
|---|---|---|
| A procedure or body of judgment the agent should apply on its own when a task matches | **Skill** (`SKILL.md`) | Loads on demand by description match, carries bundled refs and scripts, composes with other skills |
| A rule that must apply on every turn in a scope (always-on behavior, coding standard, guardrail) | **Cursor rule** (`.cursor/rules/*.mdc`) | Always or glob-scoped, not description-triggered; this is the brain's `core.mdc` model |
| Cross-tool, repo-level "how to build and test this project" context | **`AGENTS.md`** | Open standard, read by Codex, Cursor, Copilot; command-first repo operations |
| A network integration or a stateful external system (DB, API, ticketing) | **MCP server** | Real tool calls with auth and schemas, not a markdown procedure; see `MCP_SKILL_MANAGEMENT.md` |
| A focused job that should run in its own clean context and return a summary | **Subagent** (or a skill with `context: fork`) | Isolates token-heavy work; the lead agent keeps a small context |
| A one-off instruction for the current conversation | **Just prompt** | Not worth a file |

A skill and a rule are the pair most often confused. The test: if it should fire only when a specific kind of task shows up, it is a skill (description-triggered). If it must hold no matter what the agent is doing, it is a rule (always-on). When a skill needs a tool integration, it calls an MCP server; it does not reimplement one.

## The mental model: progressive disclosure

A skill is built around one idea, named by Anthropic as the core design principle: load context in tiers, only as needed. Treat the context window as a finite public good. Anthropic's context-engineering work shows model recall degrades as the window fills (context rot), so every token competes.

Three tiers, each loaded later than the last:

| Tier | What | When loaded | Budget |
|---|---|---|---|
| 1. Metadata | `name` + `description` in the frontmatter | Always, at startup, for every installed skill | ~100 tokens. Keep tight. |
| 2. Body | The `SKILL.md` markdown below the frontmatter | When the agent decides the skill applies | Under ~500 lines |
| 3. Bundled files + scripts | `references/*.md`, `assets/`, `scripts/*` | A reference is read only when pointed to; a script runs without loading its source | Effectively unbounded |

The payoff: a skill can carry deep expertise without paying for it on every turn. The metadata is the table of contents the agent reads before deciding what to open. Write the body assuming the agent already saw the metadata and chose to open it, so it starts with substance.

## The seven principles

### 1. Context is a finite public good

Default assumption: the agent is already smart. Add only what it does not already know. Challenge every line: does the agent need this explanation, or can it be assumed? Does this paragraph earn its tokens? The concise version of an instruction beats the verbose one because it trusts the model to know what a PDF is.

### 2. Write at the right altitude

Anthropic's context-engineering guidance names two failure modes. Too low: brittle if-else logic hardcoded to force exact behavior, which is fragile and rots. Too high: vague guidance that gives no concrete signal and assumes shared context the model lacks. Aim for the middle: specific enough to steer, flexible enough to leave the model strong heuristics. Minimal does not mean short. It means the smallest set of high-signal tokens that fully specifies the behavior.

### 3. Disclose progressively

Keep the body under ~500 lines (a guideline, not a wall; the skill-creator skill runs at 480 and is fine). When it grows past that, split content into `references/` and point to it. Keep references one level deep from `SKILL.md`: the agent may only partial-read a file reached through a chain of links, so never make it follow `SKILL.md` to `a.md` to `b.md` for the real content. Give every reference file over ~100 lines its own table of contents so a partial read still shows the full scope.

### 4. Instructions over constraints

Google's prompt-engineering whitepaper: lead with what to do, not a pile of what not to do. Positive instructions communicate the target directly; long constraint lists leave the model guessing and can contradict each other. Reserve constraints for safety, hard formatting, and the few boundaries that genuinely need a "never." A skill that is mostly prohibitions is a skill written at the wrong altitude.

### 5. Match degrees of freedom to fragility

Set specificity by how fragile the task is. Anthropic's robot-on-a-path analogy: a narrow bridge needs exact steps, an open field needs direction and trust.

| Freedom | Use when | Form |
|---|---|---|
| High | Many valid approaches, context decides | Text instructions and heuristics |
| Medium | A preferred pattern with acceptable variation | Pseudocode, parameterized templates |
| Low | Fragile, consistency-critical, one safe sequence | An exact script, "run this, do not modify" |

### 6. Scripts solve, they do not punt

When a step is deterministic or fragile, ship a script instead of asking the agent to regenerate code each time. Scripts are more reliable, cost no tokens until run, and stay consistent. Handle the error conditions inside the script rather than failing and leaving the agent to guess. No voodoo constants: every magic number carries a comment explaining it (Ousterhout's point: if you do not know the right value, the agent will not either).

### 7. Evaluation-driven development

Anthropic and Cursor both put this first: build the evals before the prose. Skills written to pass real tasks beat skills written to document imagined ones. The loop is in [Evaluation and iteration](#evaluation-and-iteration). The short version: find the gap on a real task, write the smallest skill that closes it, measure against a no-skill baseline.

## Anatomy of a skill

### Directory layout

```
skill-name/
├── SKILL.md            # required, exact filename, all caps
├── references/         # optional, loaded on demand, one level deep
│   ├── schema.md
│   └── patterns.md
├── scripts/            # optional, executed (or read as reference)
│   └── validate.py
└── assets/             # optional, templates/files used in output
```

The file must be named exactly `SKILL.md`. Use forward slashes in every path, on every OS. Keep subdirectories flat: `references/schema.md`, not `references/db/v1/schema.md`.

### Frontmatter

YAML frontmatter with two required fields:

```yaml
---
name: processing-pdfs
description: Extract text and tables from PDFs, fill forms, merge documents. Use when the user works with PDF files, forms, or document extraction.
---
```

| Field | Required | Rule |
|---|---|---|
| `name` | Yes | Max 64 chars. Lowercase letters, numbers, hyphens only. No XML tags. No reserved words (`anthropic`, `claude`). Match the folder name. |
| `description` | Yes | Non-empty. Max 1024 chars. No XML tags (the angle-bracket ban is a security restriction, not a style one). Carries both what the skill does and when to use it. |

Optional fields, with where each one works. The two required fields are the whole open standard; everything below is either the standard's optional set or a harness extension, so label which you depend on.

| Field | Portability | Use |
|---|---|---|
| `disable-model-invocation: true` | Agent Skills standard (Claude Code default `false`; Cursor honors it) | Skill loads only when named explicitly (`/skill-name`). Default to this for anything risky or write-capable. |
| `allowed-tools` | Claude Code | Tools the skill may use without a per-use approval prompt while active. A grant, not a restriction. |
| `disallowed-tools` | Claude Code | Tools removed from the pool while the skill is active. Use for autonomous loops that must never call something (e.g. `AskUserQuestion`). |
| `license` | Agent Skills standard | License for a shared or open-sourced skill. |
| `metadata` | Agent Skills standard | Custom fields. Carry `version`, `author`, and a last-reviewed date for any skill we maintain; optionally `category`, `tags`, `mcp-server`. |
| `context: fork` / `agent` | Claude Code | Run the skill in an isolated subagent. See [Harness-specific features](#harness-specific-features). |

Maintainability: every skill we own carries `metadata.version` (bump on change), an owner, and a last-reviewed date, so a stale skill is visible. Deprecate by moving its body into an "old patterns" collapse and pointing the description at the replacement, the same way the content guideline handles stale instructions.

### Naming

Prefer gerund form (verb + -ing): `processing-pdfs`, `analyzing-spreadsheets`, `reviewing-agent-prompts`. Noun phrases (`pdf-processing`) and action forms (`process-pdfs`) are acceptable. Never `helper`, `utils`, `tools`, `documents`. Keep the pattern consistent across the skill library so skills are easy to scan and reference.

## The description is the product

The `description` is the only text the agent sees before deciding whether to trigger the skill, chosen against potentially 100+ others. If it is vague, the skill is invisible. This is the field that does the most work in the whole file.

Rules:

- **Third person, always.** It is injected into the system prompt. "Extracts text from PDFs", never "I can help you" or "You can use this."
- **What and when, both.** What the skill does, and the concrete triggers that should fire it.
- **Specific trigger terms.** Name the file types, the phrases a user would say, the tools involved. "Use when the user mentions PDFs, forms, or document extraction" beats "helps with documents."
- **Negative triggers when the boundary is easy to cross.** Say when not to use it, so it does not fire on adjacent tasks. The community calls these negative triggers and they measurably cut false activation.
- **Design for the whole library, not one skill.** Descriptions are matched against each other. When two skills cover neighboring ground, the agent picks wrong. Carve the boundaries in their descriptions so exactly one wins per task. Anthropic's tool-design rule applies: if a person cannot say which of two should fire, the agent cannot either. Audit the descriptions together whenever you add a skill near an existing one.

Good:

```yaml
description: Generate descriptive commit messages by analyzing git diffs. Use when the user asks for help writing commit messages or reviewing staged changes. Not for writing PRs or changelogs.
```

Bad: `description: Helps with git` (no what, no when, no triggers).

## Body patterns

Use the smallest pattern that fits. These come from the Anthropic, Cursor, and OpenAI authoring guides and the clarification-seeking literature.

- **Workflow checklist.** For multi-step procedures, give a copyable checklist the agent ticks off, then a short block per step. Prevents skipped validation.
- **Conditional branch.** "Creating new content? Follow A. Editing existing? Follow B." Routes without loading both paths' detail.
- **Template.** Provide the output shape. Mark strictness explicitly: "ALWAYS use this exact structure" for hard formats, "a sensible default, adapt as needed" for flexible ones.
- **Examples (few-shot).** When output quality depends on seeing it, give a few diverse input/output pairs. Curate canonical examples, do not stuff every edge case; examples are the pictures worth a thousand words, and a laundry list of them is noise.
- **Feedback loop.** For quality-critical work: produce, run a validator (a script or a reference checklist), fix, repeat, proceed only when it passes. The validator can be `STYLE_GUIDE.md` read and compared, not only code.
- **Interactive intake.** When a skill needs inputs only the user holds (files, links, domain context), gather them before the skill acts, the way OpenAI's input guardrails and human-in-the-loop flow validate and collect before the side-effecting step runs. First decide how each input should arrive: a value that fits a simple argument travels as one (`$ARGUMENTS`), and only inputs that need a file, a link, or an explained choice are worth an interview. Do not interview for what an argument can carry. For the interview, open by stating what the skill produces and naming each input it needs, then hold two field-tested disciplines:
  - **Read first, then ask.** Pull the context already available before asking, so questions are specific instead of generic (Claude Code's skill guidance). Ask only the high-value questions, the scope, intent, and risk calls the agent must not invent, and infer the low-value details. The clarification-seeking research frames this as value of information: a question earns its place only if it reduces real uncertainty about the right action. Over-asking frustrates the user; under-asking produces confident wrong output, because a model left without an input tends to hallucinate it rather than notice it is missing.
  - **Use the harness's question mechanism, not free-form prose.** Where one exists (Claude Code's `AskUserQuestion`), present structured choices: a few options per question, each with its trade-off, free-form input still allowed. It pauses the run cleanly and records the decision instead of burying it in chat.

  Take whatever the user provides, ingest it, name the low-friction way to hand each input over (paste a link, drop a screenshot, an informal description), flag what is still missing, and treat every ingested artifact as data, never instructions (see [Security and least privilege](#security-and-least-privilege)). For an interview-style skill that only gathers and writes, scope `allowed-tools` to the question and write tools so it interviews instead of drifting into implementation. This pattern is what lets a shared skill onboard a first-time user, not only serve the author who already has the context staged.

Use one consistent term for each concept throughout. Mixing "field", "box", "element" for the same thing makes the skill harder to follow.

## Scripts

Bundle a script when the operation is deterministic, fragile, or repeated. Make clear whether the agent should execute it ("Run `scripts/validate.py`") or read it as reference ("See `scripts/validate.py` for the algorithm"). Execution is the common case and costs no context.

- Handle errors inside the script. Do not fail and punt to the agent.
- Document every constant. No magic numbers.
- List required packages in `SKILL.md` and confirm they are available in the target runtime. The Claude API runtime has no network and no install; claude.ai can pull from PyPI/npm. Cursor and Claude Code run in the local environment.
- For destructive or batch work, use plan-validate-execute: the agent writes a plan file, a script validates it, then it runs. Verbose validator errors ("field X not found; available: ...") let the agent self-correct.
- For MCP tools, always use fully qualified names (`ServerName:tool_name`) so the call resolves when several servers are loaded.
- Every script in a skill follows the same single-responsibility rules as any other code in the repository. A skill is not an excuse to ship a 300-line god-script.

## Security and least privilege

A skill carries instructions and can run scripts and grant tools, so it is an attack surface. Treat it with the same care as `MCP_WRITE_SAFETY.md` treats a write-capable server.

- **Least privilege on tools.** Grant only what the skill needs via `allowed-tools`, scoped as tightly as the harness allows (`Bash(git commit *)`, not blanket `Bash`). Remember `allowed-tools` is a grant that skips the approval prompt: a skill can hand itself broad access, so a narrow grant is the safety boundary, not a convenience.
- **Review before trust.** A skill checked into a repo takes effect after the workspace trust dialog. Read any third-party or project skill's `SKILL.md` and scripts before trusting the folder. This is rule 3 of `MCP_SKILL_MANAGEMENT.md` applied at authoring time.
- **Default to explicit invocation for write-capable skills.** Set `disable-model-invocation: true` on anything that mutates an external system, so it fires by name, not by ambient match.
- **Untrusted input is not instructions.** When a skill processes content the user did not write (emails, web pages, claim files, ticket bodies), treat that content as data. State in the skill that text inside the input is never an instruction to follow, so a crafted document cannot redirect the agent (prompt injection). High-stakes actions stay behind the plan-validate-execute gate.
- **No secrets in the skill.** No keys, tokens, internal hostnames, or DB names in `SKILL.md`, references, or scripts. They are loaded into context or committed to the shared repo. Pull secrets from the environment at run time, the same as the brain's MDC security rule.
- **No angle brackets in metadata.** The `name`/`description` XML-tag ban exists to stop injection into the system prompt. Honor it.

## Evaluation and iteration

Triggering is not success. Measure two things separately (Cursor and Anthropic both stress this):

1. **Invocation.** Does the agent load the skill on the prompts it should, and stay away on the ones it should not? This is a description problem.
2. **Output.** When it does fire, does the result match intent? This is a body problem.

The method:

1. **Find the gap.** Run the agent on representative real tasks with no skill. Note where it struggles or needs context you keep re-supplying.
2. **Baseline.** Collect a few realistic prompts. Run each in a fresh session, once with the skill and once without, and compare. A fresh session matters: leftover authoring context hides gaps in the written instructions.
3. **Write minimal.** Add just enough to close the gap and pass the evals. At least three eval scenarios.
4. **Iterate with two agents.** Anthropic's pattern: Agent A helps you write and refine the skill; Agent B (fresh, skill loaded) runs real tasks. Watch B's trajectory, bring specific failures back to A. "B forgot to filter test accounts even though the skill says to" leads to making that rule more prominent or stronger ("MUST" over "always").
5. **Test across the models you will run it on.** What an Opus-class model handles tersely, a smaller model may need spelled out. Aim for instructions that hold across them.

Each eval scenario is a small rubric: the prompt, any input files, and the behaviors the output must show. Anthropic's shape:

```json
{
  "skills": ["processing-pdfs"],
  "query": "Extract all text from this PDF and save it to output.txt",
  "files": ["test-files/document.pdf"],
  "expected_behavior": [
    "Reads the PDF with an appropriate library",
    "Extracts text from every page, none skipped",
    "Saves to output.txt in readable form"
  ]
}
```

An interactive-intake skill needs a multi-turn scenario, not a single-shot one. The scenario carries the user's answers to the questions the skill will ask (scripted or replayed), and the rubric grades the asking itself: did the skill request the high-value inputs, skip the ones it could infer, decline to invent a missing one, and stop asking once it had enough? The field's disambiguation benchmarks run this way. A single `query` plus `expected_behavior` cannot catch an over-asking or a hallucinated input, so an interview skill that ships with only single-turn evals is under-tested.

When you edit a mature skill, run a blind A/B between the old and new versions on the same prompts before committing, so you confirm the edit is an improvement and not a regression. Claude Code's `skill-creator` automates this loop (isolated per-case runs, token and duration counts, version comparison); use it where available.

Keep a skill's eval scenarios next to the skill, in an `evals/` file or folder, so they version with it. This mirrors `EVAL_SET_STANDARD.md` for agents; a skill that produces analysis or customer-facing output gets the same eval discipline, not a lighter one.

Watch how the agent navigates: unexpected read order, missed references, a bundled file it never opens (cut it or signal it better), a file it reads every time (promote it into the body). Iterate on observation, not assumption.

A note on failure modes: if the frontmatter YAML is malformed, the harness loads the body with empty metadata, so `/name` still works but the description never matches and the skill silently stops auto-triggering. Validate the frontmatter parses after every edit.

## Anti-patterns

| Anti-pattern | Why it fails |
|---|---|
| Vague description ("helps with documents") | The skill never triggers; it is invisible among many |
| First or second person in the description | Injected into the system prompt; breaks discovery |
| Verbose body that explains what the model knows | Burns the attention budget for no signal |
| Brittle if-else logic hardcoded for exact behavior | Fragile, rots, wrong altitude |
| Constraint pile instead of positive instruction | The model guesses; constraints clash |
| Assuming a user-held input exists instead of asking | The model hallucinates the missing input; an interactive skill gathers first |
| Over-asking for details the agent could infer | Interrogates the user and raises friction; ask only scope, intent, and risk |
| Interviewing for an input a simple argument could carry | Slow and clumsy; pass it as `$ARGUMENTS`, reserve the interview for files and choices |
| Deeply nested references (`SKILL.md` to a to b) | The agent partial-reads and misses content; keep one level deep |
| Reference over ~100 lines with no table of contents | Partial reads miss scope |
| Too many options ("use pypdf or pdfplumber or PyMuPDF or...") | Decision paralysis; give one default plus an escape hatch |
| Time-sensitive notes ("before August 2025, use...") | Goes stale; put legacy behavior in an "old patterns" section |
| Inconsistent terminology | The model works harder to follow |
| Windows-style paths (`scripts\helper.py`) | Breaks on Unix; always forward slashes |
| Vague skill names (`helper`, `utils`) | Unscannable, collides, no signal |
| Script that fails and punts to the agent | Defeats the reliability the script existed to provide |

## Harness-specific features

The two required fields and the progressive-disclosure model are portable across every harness that reads the Agent Skills standard (Claude Code, Cursor, Codex, and others). The features below are Claude Code extensions. They are powerful but not portable, so use them only when the skill is Claude-Code-bound, and say so in the skill.

- **Subagent execution.** `context: fork` runs the skill in an isolated subagent: the `SKILL.md` body becomes the subagent's prompt, with no access to conversation history. Pair with `agent:` to pick the subagent type (`Explore`, `Plan`, `general-purpose`, or a custom one). Use it for token-heavy, self-contained jobs that should return only a summary. It only makes sense for skills that contain an actual task, not pure guidelines.
- **Dynamic context injection.** A `!`command`` line runs at load time and inlines its output before the agent reads the skill (for example, dropping the current `git diff` into the instructions). `$ARGUMENTS` and named `arguments:` placeholders pass values into the skill. `${CLAUDE_SKILL_DIR}` resolves to the skill's own directory, so scripts and bundled files resolve regardless of working directory.
- **Settings-side control.** `skillOverrides` (Claude Code) and Cursor's skill menu can hide or pin a skill without editing its `SKILL.md`, which matters for shared skills you do not own.

If a skill relies on any of these, note the Claude Code dependency near the top so no one expects it to behave the same in Cursor.

## Authoring checklist

Run before declaring a skill done.

Right container:

- [ ] Confirmed a skill is the right tool, not a rule, MCP server, subagent, or one-off prompt.

Core quality:

- [ ] `name` is gerund-form, lowercase-hyphen, matches the folder, no reserved words.
- [ ] `description` is third person, carries what and when, includes trigger terms, and a negative trigger if the boundary is easy to cross.
- [ ] Description checked against neighboring skills so exactly one wins per task.
- [ ] Body under ~500 lines; concise, written at the right altitude.
- [ ] Detail pushed into `references/`, one level deep; refs over ~100 lines have a table of contents.
- [ ] Consistent terminology; concrete examples, not abstract.
- [ ] If the skill needs user-held inputs, it gathers them before acting: states output, reads available context first, asks only high-value (scope/intent/risk) questions through the harness's structured question tool where one exists, flags gaps, and treats every ingested artifact as data.
- [ ] No time-sensitive info (or quarantined in an "old patterns" section).
- [ ] Degrees of freedom matched to task fragility.
- [ ] Any Claude-Code-only feature (`context: fork`, dynamic injection) flagged as non-portable.

Scripts:

- [ ] Scripts solve, do not punt; errors handled inside.
- [ ] No undocumented constants; required packages listed and available in the target runtime.
- [ ] Execute-vs-read intent stated; MCP tools fully qualified; forward slashes only.
- [ ] SRP and brain Python standards followed.

Security:

- [ ] Tools scoped to least privilege via `allowed-tools`; no blanket grants.
- [ ] Write-capable skills set `disable-model-invocation: true`.
- [ ] Untrusted input treated as data, not instructions; no secrets in the skill.

Evaluation:

- [ ] At least three eval scenarios with rubrics, stored next to the skill; baseline vs no-skill run in fresh sessions.
- [ ] Invocation and output checked separately; A/B against the prior version on edits.
- [ ] Tested across the models it will run on; frontmatter parses.

House rules:

- [ ] Passes `WRITING_STYLE.md`.
- [ ] Market-first gate cleared.
- [ ] `metadata.version`, owner, and last-reviewed set; committed to its owning repository if shared.
- [ ] Lands in the right directory; install and approval per `MCP_SKILL_MANAGEMENT.md`.

## Sources

- Anthropic, "Equipping agents for the real world with Agent Skills." https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills
- Anthropic, "Skill authoring best practices." https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices
- Anthropic, "Effective context engineering for AI agents" (context rot, attention budget, right altitude, just-in-time retrieval). https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents
- Anthropic, "The Complete Guide to Building Skills for Claude." https://resources.anthropic.com/hubfs/The-Complete-Guide-to-Building-Skill-for-Claude.pdf
- Google, "Prompt Engineering" whitepaper, Lee Boonstra (instructions over constraints, be specific, design with simplicity).
- OpenAI, "A practical guide to building agents" and the Agents SDK (start simple, instructions from SOPs, invest in evals, specialized over general agents). https://openai.com/index/new-tools-for-building-agents/
- AGENTS.md open standard (command-first, closure-defined, concise). https://agents.md/
- Cursor, `create-skill` skill and Claude Code skills docs (invocation vs output, baseline in fresh sessions). https://code.claude.com/docs/en/skills
- Anthropic, Claude Code interactive commands and the `AskUserQuestion` tool (structured clarifying questions inside a skill, read-first then ask, scope `allowed-tools` to interview). https://github.com/anthropics/claude-code/blob/main/plugins/plugin-dev/skills/command-development/references/interactive-commands.md and https://code.claude.com/docs/en/agent-sdk/user-input
- OpenAI, "Guardrails and human review" (input guardrails gather and validate before the side-effecting step; human-in-the-loop pauses and resumes). https://developers.openai.com/api/docs/guides/agents/guardrails-approvals
- Clarification-seeking research (when and what to ask, value of information, the cost of over- and under-asking, hallucinated missing arguments): "Structured Uncertainty guided Clarification for LLM Agents," arXiv 2511.08798; "Uncertainty-Aware Clarification in LLM Agents with Information Gain," arXiv 2606.03135.
- Community: Simon Willison, "Claude Skills are awesome"; `mgechev/skills-best-practices`; `obra/superpowers`; `travisvn/awesome-claude-skills`.
- In this repository: `MCP_SKILL_MANAGEMENT.md`, `WRITING_STYLE.md`.
