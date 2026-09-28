# Mermaid Diagram Standards

## Table of Contents

- [Overview](#overview)
- [Frontmatter Config Standard](#frontmatter-config-standard)
- [Workflow — Generating Diagrams for Reports](#workflow--generating-diagrams-for-reports)
- [File Conventions](#file-conventions)
- [Color Key](#color-key)
- [Diagram Types and When to Use Them](#diagram-types-and-when-to-use-them)
- [Border Pattern](#border-pattern)
- [Color Key in Reports (Not in Diagrams)](#color-key-in-reports-not-in-diagrams)
- [Rendering](#rendering)
- [Embedding in Markdown for PDF](#embedding-in-markdown-for-pdf)
- [Style Rules](#style-rules)
- [Layout Gotchas](#layout-gotchas)
- [Naming Conflicts to Avoid](#naming-conflicts-to-avoid)

---

## Overview

Mermaid diagrams are used in engineering reports and gap analyses. The source `.mmd` files live alongside the markdown report. Diagrams are pre-rendered to PNG via local `mmdc` (primary) or mermaid.ink HTTP API (fallback) and referenced as images in the markdown. This ensures the `md-to-pdf.sh` script can generate PDFs without Puppeteer issues related to inline mermaid rendering.

### Design Philosophy

Keep diagrams **clean and focused**. The diagram communicates structure and flow — color keys and context belong in the surrounding report markdown, not crammed into the diagram itself. Every diagram follows the same pattern: dark theme, bordered frame with a concise title, vertical TB flow, color-coded nodes.

---

## Frontmatter Config Standard

Every `.mmd` file MUST begin with a YAML frontmatter block. This prevents text overlap, ensures consistent spacing, and applies the standard dark theme. The `mermaid.ink` API respects frontmatter (Mermaid v10.5+).

### Required Frontmatter Template

```yaml
---
config:
  theme: dark
  flowchart:
    nodeSpacing: 70
    rankSpacing: 50
    diagramPadding: 20
    subGraphTitleMargin:
      top: 15
      bottom: 10
    curve: basis
---
```

### Config Properties Explained

| Property | Default (Mermaid) | Our Standard | Why |
|----------|-------------------|-------------|-----|
| `theme` | `default` | `dark` | Easy on the eyes, professional look |
| `nodeSpacing` | `50` | `70` | Prevents horizontal node crowding |
| `rankSpacing` | `50` | `50` | Keeps vertical flow tight but readable |
| `diagramPadding` | `20` | `20` | Whitespace around entire diagram |
| `subGraphTitleMargin.top` | `0` | `15` | **Prevents title-node overlap** (root cause of overlap bug) |
| `subGraphTitleMargin.bottom` | `0` | `10` | Spacing below subgraph title |
| `curve` | `basis` | `basis` | Smooth connector curves |

### Sequence Diagram Frontmatter

Sequence diagrams use a separate config key:

```yaml
---
config:
  theme: dark
---
```

### Why Frontmatter, Not Directives

Mermaid deprecated `%%{init: {...}}%%` directives in v10.5.0. YAML frontmatter is the modern, supported approach. It is cleaner, supports full nesting, and is respected by `mermaid.ink`.

---

## Workflow — Generating Diagrams for Reports

1. **Write `.mmd` files** — one per diagram, next to the report markdown
2. **Render to PNG** — use mermaid.ink API (see [Rendering](#rendering-via-mermaidink-api))
3. **Reference in markdown** — use `![Caption](filename.png)` (relative path)
4. **Generate PDF** — `md-to-pdf.sh` auto-embeds local images as base64

Do NOT use inline ` ```mermaid ` code blocks in report markdown files intended for PDF. The `md-to-pdf` npm tool uses Puppeteer for inline mermaid rendering, and the Cursor sandbox interferes with Chrome cache paths. Pre-rendered PNGs avoid this entirely.

---

## File Conventions

```
<project>/
├── report-name.md                    ← Report markdown (images as ![](*.png))
├── diagram1_descriptive_name.mmd     ← Mermaid source
├── diagram1_descriptive_name.png     ← Rendered PNG
├── diagram2_descriptive_name.mmd
├── diagram2_descriptive_name.png
└── report-name_v1.pdf                ← Generated PDF
```

- File naming: `diagram_{snake_case_description}_v{N}.mmd` (e.g., `diagram_uc2_invoice_billing_v1.mmd`)
- PNG shares the same base name as the `.mmd`
- Keep `.mmd` source files — they allow re-rendering if colors or content change
- **Versioning: NEVER overwrite.** When iterating on a diagram, create `_v2`, `_v3`, etc. Preserve all previous versions. The latest version is the active one; older versions are the history.

---

## Color Key

Use a consistent color key across all diagrams in a report. Document the key in the markdown above the first diagram.

### Standard Palette (Semantic)

The primary palette uses semantic names that map to workflow roles. Every workflow diagram should use these classDefs.

| Role | classDef name | Fill | Stroke | Text | When to use |
|------|--------------|------|--------|------|-------------|
| Input / data source | `intake_cls` | `#cce5ff` | `#0056b3` | `#004085` | Emails, invoices, exports, external data arriving |
| Decision / gate | `decision_cls` | `#fff3cd` | `#856404` | `#856404` | Diamond nodes — yes/no, match/mismatch, approve/deny |
| Agent action | `action_cls` | `#d4edda` | `#28a745` | `#155724` | Steps the agent or system performs |
| Risk / flag / discrepancy | `risk_cls` | `#f8d7da` | `#dc3545` | `#721c24` | Errors, flags, escalation paths, out-of-scope |
| Human / ops action | `gray` | `#e9ecef` | `#6c757d` | `#495057` | Steps a human performs, external/third-party |
| Log / register / pipeline | `log_cls` | `#d1ecf1` | `#0c5460` | `#0c5460` | Logging, billing registers, system records |
| Reference data / optional | `nice_cls` | `#e2e3f1` | `#6c6f9d` | `#3b3d6b` | Rate sheets, reference lookups, nice-to-have docs. Dashed border via `stroke-dasharray:5 5` |

### Applying in Flowcharts

```
classDef intake_cls fill:#cce5ff,stroke:#0056b3,color:#004085
classDef decision_cls fill:#fff3cd,stroke:#856404,color:#856404
classDef action_cls fill:#d4edda,stroke:#28a745,color:#155724
classDef risk_cls fill:#f8d7da,stroke:#dc3545,color:#721c24
classDef gray fill:#e9ecef,stroke:#6c757d,color:#495057
classDef log_cls fill:#d1ecf1,stroke:#0c5460,color:#0c5460
classDef nice_cls fill:#e2e3f1,stroke:#6c6f9d,color:#3b3d6b,stroke-dasharray:5 5

class A1,A2 intake_cls
class A3,D1 decision_cls
class C1,C2 action_cls
class E1 risk_cls
```

### Legacy Palette (simple reports only)

For non-workflow diagrams (system landscapes, status comparisons), the original 4-color palette is still acceptable:

| Purpose | classDef name | Fill | Stroke | Text |
|---------|--------------|------|--------|------|
| Positive / Working | `green` | `#d4edda` | `#28a745` | `#155724` |
| Negative / Broken | `red` | `#f8d7da` | `#dc3545` | `#721c24` |
| Infrastructure | `blue` | `#cce5ff` | `#0056b3` | `#004085` |
| External | `gray` | `#e9ecef` | `#6c757d` | `#495057` |

### Applying in Sequence Diagrams

Sequence diagrams don't support `classDef`. Use `rect rgb()` blocks:

```
rect rgb(209, 237, 210)
Note over A,B: Phase description [POSITIVE LABEL]
...
end

rect rgb(248, 215, 218)
Note over A,B: Phase description [NEGATIVE LABEL]
...
end
```

---

## Diagram Types and When to Use Them

| Diagram Type | Use When |
|-------------|----------|
| `flowchart LR` | **Workflow diagrams** (primary) — process flows, SOPs, reconciliation pipelines. Phases flow left-to-right, steps flow top-to-bottom within each phase. Also for system landscapes. |
| `flowchart TB` | Status comparison — reported vs unreported, working vs broken. Avoid for workflows. |
| `sequenceDiagram` | Lifecycle / timeline — tracing a request through multiple phases |

---

## Workflow Diagram Pattern (Primary)

All process flow and SOP diagrams use this pattern. Reference implementations: `diagram_uc1_returns_flow_v6.mmd` (returns), `diagram_uc2_invoice_billing_v1.mmd` (billing).

### Structure

1. **`flowchart LR`** — horizontal left-to-right for the overall flow
2. **Outer `main` subgraph** — wraps everything, provides border and title
3. **Phase subgraphs** — one per step (e.g., "Step A: Invoice Receipt"), each with `direction TB` so internal nodes stack vertically
4. **Decision diamonds** — `{" question? "}` at gate points within phases
5. **Nested detail subgraphs** — for grouped items (rate sheets, surcharge checks, doc types) with dashed borders
6. **Cross-phase connections** — defined after all subgraphs, inside `main`

### Frontmatter for Workflow Diagrams

```yaml
---
config:
  theme: dark
  flowchart:
    nodeSpacing: 40
    rankSpacing: 80
    diagramPadding: 20
    subGraphTitleMargin:
      top: 15
      bottom: 10
    curve: basis
---
```

Note: `rankSpacing: 80` (not 50) gives horizontal phases room to breathe.

### Skeleton

```
flowchart LR
  subgraph main [" UC Name — Workflow Title V1 "]
    direction LR

    subgraph stepa [" Step A: Phase Name "]
      direction TB
      A1["First action"]
      A2{"Decision?"}
      A1 --> A2
      A2 -->|"No"| A3["Handle no"]
    end

    subgraph stepb [" Step B: Phase Name "]
      direction TB
      B1["Action"]

      subgraph details [" Grouped Items "]
        direction LR
        D1["Item 1"]
        D2["Item 2"]
      end

      B1 --> details
    end

    %% Cross-phase connections
    A2 -->|"Yes"| B1

  end

  classDef intake_cls fill:#cce5ff,stroke:#0056b3,color:#004085
  classDef decision_cls fill:#fff3cd,stroke:#856404,color:#856404
  classDef action_cls fill:#d4edda,stroke:#28a745,color:#155724
  classDef risk_cls fill:#f8d7da,stroke:#dc3545,color:#721c24
  classDef gray fill:#e9ecef,stroke:#6c757d,color:#495057
  classDef log_cls fill:#d1ecf1,stroke:#0c5460,color:#0c5460
  classDef nice_cls fill:#e2e3f1,stroke:#6c6f9d,color:#3b3d6b,stroke-dasharray:5 5

  class A1 intake_cls
  class A2 decision_cls

  style main fill:#1e1e2e,stroke:#cdd6f4,stroke-width:2px
  style stepa fill:#1e1e2e,stroke:#4a5568,stroke-width:1px
  style stepb fill:#1e1e2e,stroke:#4a5568,stroke-width:1px
  style details fill:#2a2a3e,stroke:#6c6f9d,stroke-width:1px,stroke-dasharray:5 5
```

### Subgraph Styling

| Subgraph type | fill | stroke | Notes |
|---------------|------|--------|-------|
| Phase (Step A, B, ...) | `#1e1e2e` | `#4a5568`, 1px | Standard phase border |
| Nested detail group | `#2a2a3e` | `#6c6f9d`, 1px, dashed | Rate sheets, doc types, check groups |
| Positive path (e.g., "Looks Good") | `#2a3e2a` | `#28a745`, 1px, dashed | Optional — highlight happy path |
| Negative path (e.g., "Discrepancies") | `#3e2a2a` | `#dc3545`, 1px, dashed | Optional — highlight error path |
| Loop / reconciliation | `#1e1e2e` | `#856404`, 1px, dashed | Re-verify loops, retry flows |

---

## Border Pattern

Every diagram MUST have a visible border with a title. Use an outer `main` subgraph with explicit styling.

### Standard Template

```
---
config:
  theme: dark
  flowchart:
    nodeSpacing: 70
    rankSpacing: 50
    diagramPadding: 20
    subGraphTitleMargin:
      top: 15
      bottom: 10
    curve: basis
---
flowchart TB
  subgraph main [" Diagram Title "]
    direction TB
    %% ... subgraphs and nodes here ...
  end

  classDef red fill:#f8d7da,stroke:#dc3545,color:#721c24
  classDef blue fill:#cce5ff,stroke:#0056b3,color:#004085
  classDef gray fill:#e9ecef,stroke:#6c757d,color:#495057

  class NodeA,NodeB blue
  class NodeC,NodeD red

  style main fill:#1e1e2e,stroke:#cdd6f4,stroke-width:2px
```

### Rules

1. The outer `main` subgraph wraps ALL diagram content
2. The subgraph title is the diagram title — keep it concise
3. `classDef`, `class`, and `style` statements go OUTSIDE `main` (after `end`)
4. Border colors: dark fill `#1e1e2e`, light stroke `#cdd6f4`, 2px width

## Color Key in Reports (Not in Diagrams)

Do NOT put legends inside diagrams. They clutter the layout and fight Mermaid's auto-positioning. Instead, document the color key in the report markdown above the first diagram:

```markdown
### Agent Attribution

**Color key:** Blue = trigger/caller, Red = unreported gap, Gray = external entry point.

![Agent Attribution](diagram1_agent_attribution.png)
```

This keeps the diagram clean and gives you full formatting control in the report text.

---

## Rendering

Render with `mmdc`, the mermaid CLI, locally. It needs no network, does not time
out, and renders at 2x. Install it per project rather than globally, so the
version that rendered a diagram is the version the repository records:

```bash
npm install @mermaid-js/mermaid-cli
npx mmdc -i <file.mmd> -o <file.png> --scale 2 --backgroundColor transparent
```

`mmdc` drives Chrome through Puppeteer, so the first run downloads a headless
Chrome:

```bash
npx puppeteer browsers install chrome-headless-shell
```

An agent sandbox that blocks process launch blocks that Chrome, and the failure
reads as a Puppeteer error rather than as a permission one. Run the render with
the permission it needs, or render outside the sandbox.

The hosted `mermaid.ink` API is the fallback and only the fallback. It has URL
length limits, so it fails on exactly the complex diagrams worth rendering, it
has no SLA, and a first render under load takes 30 seconds or more. Validate
syntax at <https://mermaid.live> before blaming the renderer.
## Embedding in Markdown for PDF

Reference rendered PNGs with relative paths in the report markdown:

```markdown
### System Landscape

![System Landscape](diagram1_system_landscape.png)

Green nodes report time. Red nodes do not.
```

The `md-to-pdf.sh` script's `embed_local_images` function automatically converts local image paths to base64 data URIs during PDF generation. This makes the PDF self-contained.

---

## Style Rules

1. **Every `.mmd` file starts with frontmatter.** No exceptions. Use the template from [Frontmatter Config Standard](#frontmatter-config-standard).
2. **Every diagram has a border.** Use the outer subgraph pattern from [Border Pattern](#border-pattern).
3. **No legends inside diagrams.** Document color keys in the report markdown, not in the diagram. See [Color Key in Reports](#color-key-in-reports-not-in-diagrams).
4. **classDef names must not conflict with subgraph names.** Use generic names like `green`, `red`, `blue`, `gray` — never names that match a subgraph ID (e.g., don't name a classDef `reported` if you also have `subgraph reported`)
5. **Keep subgraph titles short.** Long titles cause overlap. Move details (env var names, config keys) into the report text, not the diagram title.
6. **Keep node labels concise.** Use `<br/>` for multi-line labels in flowcharts.
7. **Subgraph titles should be human-readable.** Use quotes: `subgraph PA ["ingest worker, eu-central-1"]`
8. **Edge labels in quotes.** Always quote edge labels: `-->|"writes"|`
9. **Wrap node labels with special chars in double quotes.** `A["Rule::in()"]` not `A[Rule::in()]`
10. **One primary direction per flowchart.** Workflow diagrams use `flowchart LR` with `direction TB` inside phase subgraphs — this is the intended pattern (phases flow horizontally, steps within a phase stack vertically). Don't mix directions arbitrarily outside this pattern.
11. **Sequence diagram phases should have Note labels.** Every `rect` block should have a `Note over` line describing the phase
12. **No deprecated directives.** Never use `%%{init: {...}}%%` — use YAML frontmatter instead.

---

## Layout Gotchas

Two behaviours silently defeat the `flowchart LR` + inner `direction TB` pattern in Style Rule 10. Both look like the diagram ignoring you.

### Inner `direction` is ignored when an edge crosses the subgraph boundary

If any edge connects a node **inside** a phase subgraph to a node **outside** it, Mermaid drops that subgraph's `direction` and inherits the parent's. Every phase then lays out left to right and the diagram renders as one flat strip.

Route the phase chain subgraph to subgraph instead:

```
p1 -- "edge label" --> p2
p2 --> p3
```

Not `D3 --> R1`. If a node-level edge carries meaning you need, fold it into the subgraph edge's label.

### A feedback edge reorders the phases

Drawing a real edge from a late phase back to an early one (`p4 --> p2`) makes the graph cyclic. Mermaid's cycle-breaking then ranks the phases out of sequence, typically dropping the last phase below the first.

Where the loop is narrative rather than structural, use a terminal flag node inside the source phase:

```
O4>"Re-enters Redefine: production reveals<br/>the process Discovery missed"]
```

The loop is stated, the ranking is untouched. Invisible links (`~~~`) and declaring the edge in reverse both fail to fix this.

### Node labels carry the test, not the abstraction

A box reading `Auditability` communicates nothing a section heading does not. Write the bar the reader would check against: `Auditability. A row before every external action, never updated. Skips are rows too.` Longer labels make the diagram a reference chart rather than a slide, which is usually the right trade in a brain document. When both are needed, keep two `.mmd` files rather than compromising one.

---

---

## Naming Conflicts to Avoid

Mermaid can hang or produce errors when:

- A `classDef` name matches a `subgraph` ID (e.g., `classDef reported` + `subgraph reported`)
- A node ID matches a reserved keyword (`end`, `graph`, `subgraph`)
- Edge labels contain unescaped special characters

Always use distinct names: `classDef green` (not `classDef reported`), `subgraph reportedGroup` (not `subgraph reported`).
