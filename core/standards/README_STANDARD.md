# README Standard

## Table of Contents

- [Source](#source)
- [Rules](#rules)
- [Structure](#structure)
- [Anti-Patterns](#anti-patterns)

---

## Source

Derived from the READMEs of the ten most-starred public GitHub repositories at the time of
writing: `codecrafters-io/build-your-own-x`, `sindresorhus/awesome`, `public-apis/public-apis`,
`freeCodeCamp/freeCodeCamp`, `EbookFoundation/free-programming-books`, `openclaw/openclaw`,
`donnemartin/system-design-primer`, `nilbuild/developer-roadmap`,
`jwasham/coding-interview-university`, `vinta/awesome-python`.

Eight of the ten are curated link lists, not installable software, so their README has no install
step, no usage example and no directory layout to explain. Only `openclaw/openclaw` and
`freeCodeCamp/freeCodeCamp` are software projects comparable to what this harness ships, and the
rules below lean on those two wherever a list repo has nothing to say. What follows is not "copy
the most popular repo"; it is the handful of structural choices that held across all ten
regardless of what the repo was for, plus the install-and-use conventions the two software repos
demonstrate.

---

## Rules

1. **Title plus a one-line tagline, immediately.** Every repo leads with an H1 (or a bolded
   heading) and a single sentence saying what it is, before anything else. No repo made a reader
   scroll to find out what they were looking at.
2. **The first code block is the thing to run, not an example.** In both software repos, the
   install or quickstart command appears before any deep explanation, copy-pasteable as written,
   with no placeholders to fill in first.
3. **A short why, in prose, right after the quickstart.** Two to four sentences on the problem this
   solves and why it exists, not a feature list yet.
4. **A table of contents once the document has more than a handful of sections.** Nine of the ten
   repos have one, whether the repo is a list or a tool. A README a reader has to scroll blind
   through is the one universal failure mode this standard exists to prevent.
5. **The value, stated as a short list, not buried in prose.** Every repo eventually answers "what
   do I get," and the ones that do it well use a numbered or bulleted list, each item one line a
   reader can scan without reading the paragraph around it.
6. **Structure only when there is one to explain.** A directory tree belongs in a README only when
   the project has meaningful layout to navigate; a list repo has none and none of them fake one.
7. **Badges are a status report, not decoration.** Where badges appear, each one is a live fact
   (CI status, published version, license, chat) linking somewhere real. A repo with nothing to
   report has no badge row, and that is the correct choice more often than not.
8. **The close is short and operational.** Contributing, license and uninstall/removal information
   go at the end, one line each where possible, never a wall of policy text.

---

## Structure

```markdown
# <name>

<one-line tagline>

<install-or-run command, in a fenced code block, no placeholders>

<2-4 sentences: what this is and why it exists>

## Table of Contents

<only past a handful of sections>

## <the value, as a short numbered or bulleted list>

## <layout, only if there is one to explain>

## <secondary setup: writing an extension, configuring it, etc.>

## Requirements

## Tests
<omit if the project has none a user would run>

## <Contributing | Uninstall | License>
<short, operational, not a policy essay>
```

---

## Anti-Patterns

- Burying the install command below a wall of badges, logos and philosophy.
- A table of contents on a README short enough to read without scrolling.
- A directory tree for a project with three files.
- A badge that links to nothing, or reports a status nobody maintains.
- A features list that is really a paragraph with line breaks inserted.
- Closing sections (contributing, license, security) written as essays instead of one or two
  lines pointing at the real document.
