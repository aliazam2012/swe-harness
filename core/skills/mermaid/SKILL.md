---
name: mermaid
description: "Use when creating or editing a mermaid diagram (.mmd file or inline mermaid block): frontmatter theme, main subgraph, classDef placement. Not for a chart or data visualization."
---

# Mermaid Diagram Rules

The full reference (frontmatter template, color palette, border pattern, rendering workflow)
is `standards/MERMAID_DIAGRAMS.md` inside the harness clone. This skill is linked into
`~/.claude/skills/mermaid`; resolve that symlink and the standard is at
`../../standards/MERMAID_DIAGRAMS.md` relative to the real skill directory. If that file
is not in this clone, the rules below stand on their own.

## Mandatory structure for every `.mmd` file

1. Start with YAML frontmatter (theme, spacing config, subGraphTitleMargin).
2. Use `flowchart TB`. Vertical flow is the default.
3. Wrap the content in an outer `main` subgraph. The title goes in the subgraph label and the
   border comes from `style`.
4. Put `classDef`, `class` and `style` statements OUTSIDE the `main` subgraph.
5. Do NOT include a legend. Document what the colors mean in the surrounding Markdown.

## Frontmatter, copy this

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

## Diagram skeleton, copy this

```
flowchart TB
  subgraph main [" Diagram Title "]
    direction TB
    %% subgraphs and nodes here
  end

  classDef red fill:#f8d7da,stroke:#dc3545,color:#721c24
  classDef blue fill:#cce5ff,stroke:#0056b3,color:#004085
  classDef gray fill:#e9ecef,stroke:#6c757d,color:#495057

  class NodeA,NodeB blue
  class NodeC,NodeD red

  style main fill:#1e1e2e,stroke:#cdd6f4,stroke-width:2px
```

## Rendering, local first

Render with a locally installed `mmdc` (the mermaid CLI). It drives a headless browser, so a
sandbox that blocks process launches will block it; grant the permission rather than falling
back. Do not use a hosted rendering API unless `mmdc` is genuinely broken: the API fails on
complex diagrams.

## Color key, standard palette

- `green` is `fill:#d4edda,stroke:#28a745,color:#155724`
- `red` is `fill:#f8d7da,stroke:#dc3545,color:#721c24`
- `blue` is `fill:#cce5ff,stroke:#0056b3,color:#004085`
- `gray` is `fill:#e9ecef,stroke:#6c757d,color:#495057`

## Critical rules

1. A `classDef` name must NOT match a subgraph ID.
2. Keep subgraph titles short. A long title causes overlap.
3. Wrap a label containing special characters in double quotes: `A["Rule::in()"]`.
4. Never use the deprecated `%%{init: {...}}%%` directive. Use YAML frontmatter.
5. File naming: `diagram{N}_{snake_case_description}.mmd` with a matching `.png`.
6. No legends in the diagram. Put the color key in the surrounding Markdown.
