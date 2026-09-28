# Writing Style Guide

## Table of Contents

- [Purpose](#purpose)
- [AI Tropes to Kill](#ai-tropes-to-kill)
- [Banned Words and Phrases](#banned-words-and-phrases)
- [Voice Rules](#voice-rules)
- [Sentence Rules](#sentence-rules)
- [Structure Rules](#structure-rules)

---

## Purpose

Every file the agent creates or edits should sound like a senior engineer wrote it. Not an AI. Not a marketing team. An engineer explaining something to other engineers.

This guide applies to ALL agent output: notes, session logs, scope documents, proposals, internal documents, anything the team or a customer reads, and any other generated text. No exceptions.

Writing style covers voice. The **structure** of a technical report or an ask is a separate question, and a layer that has a house format for one supplies it. Both apply together.

---

## AI Tropes to Kill

These are the most recognizable patterns of AI-generated text. Never use them.


| Trope                  | Example (bad)                                                  | Why it's bad                                                                                           |
| ---------------------- | -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| Negative parallelism   | "It's not X — it's Y"                                          | Creates false profundity. Real people don't reframe everything as a surprise reveal.                   |
| Triple negation reveal | "Not a bug. Not a feature. A design flaw."                     | Dramatic countdown that builds tension nobody asked for.                                               |
| Rhetorical Q&A         | "The result? Devastating."                                     | Self-posed questions answered immediately. Nobody was asking.                                          |
| Anaphora abuse         | "They assume... They assume... They assume..."                 | Repeating sentence openings for rhetorical effect.                                                     |
| Tricolon abuse         | Three-item lists used for rhythm instead of content            | One tricolon in a doc is fine. Three back-to-back is a pattern failure.                                |
| Filler transitions     | "It's worth noting", "Notably", "Importantly"                  | These words add nothing. Cut them and the sentence is better.                                          |
| Em dash overuse        | "context — everything — matters"                               | Never use em dashes. Use periods, commas, colons, or parentheses instead. Zero tolerance. |
| Significance inflation | "pivotal", "crucial", "vital", "stands as a testament"         | Everything becomes dramatic. Use plain language.                                                       |
| False ranges           | "From innovation to implementation to cultural transformation" | Implies a spectrum that doesn't exist.                                                                 |
| Superficial analysis   | "highlighting its importance", "reflecting broader trends"     | Tacking on "-ing" phrases that say nothing.                                                            |
| Gerund fragment litany | "Building trust. Creating alignment. Driving results."         | Standalone fragments with no subject after making a claim.                                             |


---

## Banned Words and Phrases

Never use these in any document. Replace with the plain alternative.


| Banned                 | Use instead                                      |
| ---------------------- | ------------------------------------------------ |
| delve                  | look at, examine, dig into                       |
| leverage               | use                                              |
| utilize                | use                                              |
| streamline             | simplify, clean up                               |
| robust                 | solid, reliable                                  |
| seamless               | smooth, clean                                    |
| comprehensive          | full, complete, thorough                         |
| innovative             | new, different                                   |
| elevate                | improve                                          |
| harness                | use                                              |
| foster                 | build, encourage                                 |
| underscore             | show, highlight                                  |
| tapestry               | (just don't)                                     |
| landscape              | space, area, field                               |
| pivotal                | important, key                                   |
| crucial                | important                                        |
| testament              | proof, evidence                                  |
| showcase               | show, demonstrate                                |
| it's worth noting      | (delete the phrase, start with the actual point) |
| it bears mentioning    | (same)                                           |
| notably                | (same)                                           |
| importantly            | (same)                                           |
| in today's fast-paced  | (never)                                          |
| when it comes to       | (delete, start with the subject)                 |
| at the end of the day  | (never)                                          |
| goes beyond            | does more than, also handles                     |
| the assumption is that | (delete, state the assumption directly)          |


---

## Voice Rules

Write like a senior engineer documenting for peers. Direct, technically precise, properly written. No AI polish, no corporate speak, no filler. The standard to match: Stripe's engineering blog, Google's eng-practices docs, a well-written RFC.

1. **State the fact. Move on.** Don't build up to the point. Start with it.
2. **Plain vocabulary.** If a simpler word exists, use it. "Use" not "leverage". "Show" not "showcase". But don't dumb it down either. Technical terms are fine when they're the right word.
3. **No drama.** Don't inflate importance. If something is good, say it's good. Don't call it "pivotal" or "a testament to".
4. **Proper grammar and capitalization.** These are professional docs, not chat messages. Complete sentences, correct punctuation, proofread.
5. **Contractions are fine.** "Doesn't", "won't", "it's" all read more naturally than their expanded forms in technical writing.
6. **Be specific.** "The script fetches PRs via the GitHub API" beats "The system comprehensively retrieves pull request data."
7. **Short paragraphs.** 2-3 sentences per paragraph. Dense walls of text lose readers.
8. **Tables over prose** for comparisons, feature lists, and anything with parallel structure.
9. **No hedge words in docs.** "Might", "could", "consider", "perhaps" are weak. Either commit to the statement or cut it. (Behavior & Intent review items are the one exception, where conditional framing is intentional.)
10. **Confident but not arrogant.** State what the tool does and why. Don't oversell it or add qualifiers for every claim.

---

## Sentence Rules

1. **Vary sentence length.** Mix short and medium. Don't let every sentence be the same length.
2. **Zero em dashes.** Never use em dashes in any output. Use periods, commas, colons, or parentheses instead.
3. **Don't start consecutive sentences the same way.** Especially with "The", "This", "It".
4. **No tricolon for rhythm.** If you're grouping three things, it should be because there are three things, not because three sounds good.
5. **Cut filler openings.** Delete "It's worth noting that" and start with the actual content.
6. **Active voice by default.** "The bot reviews PRs" not "PRs are reviewed by the bot."
7. **No rhetorical questions.** Don't ask a question and immediately answer it. Just state the answer.

---

## Structure Rules

1. **Lists over inline enumeration.** When a sentence contains three or more items, break them into bullet points. Don't bury a list in a long sentence. "The team asked for rhythm, boundaries, visible effort, and capacity awareness" should be four bullets, not one run-on line. Easier to scan, easier to reference, easier to remember.
2. **Leadership-first ordering.** The top half of every document should cover the strategic picture: what it is, why it matters, design principles, and key differentiators. The bottom half is for engineers who want to go deeper: examples, implementation details, operational specifics. Leadership reads sections 1-5 and gets the full picture. Engineers keep going.
2. **Fold redundant intro sections.** If "What It Does" and "Why We Built It" overlap with the executive summary, merge them into the summary. Don't repeat the same information in three places.
3. **Lead with what it does.** First sentence of any section should tell the reader what they're going to learn.
4. **Examples go in their own sections.** Don't interleave explanation and example in the same paragraph. Place them in the second half of the doc.
5. **Headers should be descriptive.** "How It Reviews Code" is better than "Overview of the Review Process."
6. **Don't over-format.** Not everything needs bold, bullets, and tables. Sometimes a sentence is enough.
7. **Callouts should earn their space.** Don't add "What to notice" boxes unless the insight isn't obvious from the content itself.
