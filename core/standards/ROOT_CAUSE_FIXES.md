# Root Cause Fixes

How to fix a defect, a review finding, a red check, or a bug report. The finding is a symptom. The fix goes at the cause, and you have to be able to name the cause before you touch the code.

Applies everywhere a fix happens: a MUST-FIX in `PR_LIFECYCLE.md`, a failing CI check, a Sentry error, a customer report, a hook that blocks you, a test that went red.

## Table of Contents

- [The Rule](#the-rule)
- [Step 1: Reproduce Before You Diagnose](#step-1-reproduce-before-you-diagnose)
- [Step 2: Name the Mechanism](#step-2-name-the-mechanism)
- [Step 3: Three Questions](#step-3-three-questions)
- [Step 4: Sweep the Class](#step-4-sweep-the-class)
- [Step 5: Fix at the Right Layer](#step-5-fix-at-the-right-layer)
- [Step 6: Prove It](#step-6-prove-it)
- [Whack-a-Mole Catalogue](#whack-a-mole-catalogue)
- [Two Defect Classes Worth Naming](#two-defect-classes-worth-naming)
- [When the Correct Fix Is Too Big](#when-the-correct-fix-is-too-big)
- [What to Write](#what-to-write)

---

## The Rule

You may not change code to make a symptom go away until you can state, in one sentence, the mechanism that produced it.

If you cannot state the mechanism, you are guessing. A guess that turns the check green is worse than a red check, because it removes the signal and leaves the defect.

Three failure shapes this exists to stop:

- **Symptom patching.** The error message is gone. The bug is still there, one layer down.
- **Instance patching.** This call site is fixed. The other six that share the cause are not.
- **Signal removal.** The check, the test, or the type is what changed, and the code that was wrong is untouched.

---

## Step 1: Reproduce Before You Diagnose

Get the failure to happen in front of you, at the smallest scale that still shows it: the failing test, the request in a local run, the query against the real row, the log line with the request ID.

A failure you cannot reproduce is a failure you cannot prove you fixed. If it is genuinely not reproducible, say so and label the fix `[HYPOTHESIS]` with what would confirm it.

Read the real error, not the summary of it. The stack trace, the full log line, the actual response body. A bot's or a teammate's description of the failure is a claim, not evidence.

---

## Step 2: Name the Mechanism

Trace from the symptom to the line that is actually wrong. Write the chain down before you edit:

```
Symptom  -> the observable failure (the message, the wrong number, the 500)
Trigger  -> the input or state that reaches it
Mechanism-> the line, the missing guard, the wrong assumption, the race
Origin   -> why that line is like that (a bad default, a stale contract, a copy-paste)
```

The mechanism is the sentence you must be able to say. "The parser assumes the carrier always returns a delivery date, and this carrier omits it on a cancelled shipment" is a mechanism. "The date was null" is a symptom restated.

Stop at the first cause you can act on and that explains every observation you have. Do not keep asking "why" until you reach the company's hiring policy. A cause you cannot act on is context for the report, not the fix.

---

## Step 3: Three Questions

Answer all three before you write the fix. Each one has caught a real miss.

1. **Why did it happen?** The mechanism from Step 2.
2. **Why did nothing catch it?** A test that did not exist, a type that was too loose, a check that does not run on this path, an error that was swallowed. The answer is usually a second, smaller fix, and it is the one that stops the next instance.
3. **Where else does this live?** The same author, the same pattern, the same copied block, the same assumption in a sibling module. This is Step 4.

A fix that answers only question 1 is half a fix.

---

## Step 4: Sweep the Class

A finding is one instance until you prove it is. Search for the pattern before you decide the scope of the fix.

```bash
rg -n '<the wrong pattern>' --type py
git log -S '<the wrong pattern>' --oneline    # where it came from, and who else copied it
```

Three outcomes, and each changes the fix:

- **One instance.** Fix it, and say in the PR that you checked.
- **A class.** Fix the class once, at the shared layer, rather than patching each site. Six identical patches are six chances to miss one.
- **A missing abstraction.** The pattern is repeated because nothing gives callers the correct thing to call. That is the real finding, and it usually belongs in this PR only if it is small; otherwise see [When the Correct Fix Is Too Big](#when-the-correct-fix-is-too-big).

---

## Step 5: Fix at the Right Layer

Push the fix to the layer that owns the invariant. Fixing above that layer leaves every other caller exposed.

| Symptom-level fix (wrong) | Cause-level fix (right) |
| --- | --- |
| Add a null check at the one call site that crashed | Make the function that returns the value never return null, or make its type say it can |
| Wrap the call in `try/except` and log | Handle the specific error the external API actually returns, and let the rest raise |
| Bump the timeout until the flake stops | Find what is slow, or make the wait deterministic |
| Retry until the race stops showing | Order the operations, or take the lock |
| Widen the lint exclusion | Fix the code the rule is pointing at |
| Add `# type: ignore` | Correct the type, or the call that violates it |
| Change the assertion to match the new output | Decide whether the output or the expectation is wrong, then fix that one |
| Special-case the input from the bug report | Fix the rule that mishandles that whole family of inputs |

The right layer is not always the deepest one. A change deep in a shared module to fix one caller's problem is its own defect. Fix where the invariant belongs, not as deep as you can reach.

---

## Step 6: Prove It

A fix is not done because the red thing turned green. Three pieces of evidence:

1. **The reproduction from Step 1 fails before and passes after.** Run it both ways. If you cannot run the "before", you have not proved the fix caused the change.
2. **A regression test at the cause level.** The test names the mechanism, not the ticket. It fails if someone reintroduces the cause through a different call site.
3. **The class sweep from Step 4 is clean.** Re-run the search after the fix.

Then check what the fix could have broken. A cause-level fix changes behaviour for every caller, which is the point of it and also the risk. Name the callers and exercise the nearest one.

---

## Whack-a-Mole Catalogue

These are never the fix on their own. Each one is allowed only with a written reason that names the mechanism it is deliberately working around, and a ticket if the real fix is deferred.

- Disabling, skipping, or deleting a test that is telling the truth.
- Widening a lint or type exclusion, or adding a blanket ignore.
- Catching `Exception` and continuing.
- Adding a retry, a sleep, or a longer timeout to a correctness problem.
- Defensive checks stacked at call sites to absorb a value that should never exist.
- Editing an expected value in a test until it matches the current output.
- Re-running CI until it passes.
- Changing a CI workflow, a branch rule, or a config so the check stops running.
- Special-casing the exact input from the report.

If you catch yourself reaching for one, that is the signal that Step 2 is not finished.

---

## Two Defect Classes Worth Naming

Both were hit repeatedly in one night on 2026-08-31, most of them in code written that same session. Neither can fail a test, which is why each needs a rule rather than more coverage.

### The default that quietly disables a guarantee

An injected seam given a default that is not the real behaviour. Every test supplies the value, so the default path never executes anywhere, and the suite stays green while the guarantee is off.

Real instances: a reaper whose clocks defaulted to `lambda: 0.0`, so every thread read as too young forever and it released nothing while reporting success. An inbox allow-list whose resolver defaulted to `None`, so the restricted configuration was the one configuration that silently discarded all mail, behind a log line that read like a working filter. A lease whose `commit` defaulted to `lambda: None`, leaving the lease undurable and re-running the work it existed to make once-only.

**The rule.** A default that can quietly disable a guarantee should not exist: make the parameter required, so a caller who forgets gets a `TypeError` at construction. A default that *is* the true value should exist and stay. The question to ask of a default is not "is this sensible" but "if this is taken in production, is the guarantee still delivered".

**The guard.** A structural test pinning every seam to either a working default or a boot refusal, so a new seam fails the build until it has one. Prose in a review does not outlive the people who wrote it.

**When you find one, sweep the module immediately** rather than waiting for the next review round. Most instances above came from one deliberate sweep; only the first was found by a human-shaped process.

**A sweep comes back clean when a test is defending the defect.** In the same session, one seam survived a deliberate sweep because its test set the two credentials the boot check looked at, never wired the resolver, and asserted that boot succeeded. It certified the broken state as correct. A test that asserts the wrong invariant is not weak coverage, it is **anti-coverage**: it actively defends the defect, and it makes both the suite and the sweep report health. When a sweep finds nothing in code you have reason to distrust, read the tests for what they assert rather than counting them.

### One column doing two jobs

A single field used both as a guard before an irreversible call and as the record that the call succeeded. The two have opposite timing requirements: the guard must be written *before* the call or it does not guard, and the completion mark must be written *after* it or it lies.

Real instance: a trigger table where `triggered_at` was moved before the call to close a double-trigger window. The outstanding query filtered on `triggered_at IS NULL`, so a claimed row left the work set permanently, and a transient timeout after a successful claim orphaned the ticket for good. The fix for the duplicate produced the exact failure the module existed to prevent.

**The rule.** Split them: an expiring lease written before the call, a completion mark written after it, and the outstanding query requiring both. Whenever a fix moves a write across an irreversible call, re-read every query that reads that column.

---

## When the Correct Fix Is Too Big

Sometimes the cause sits outside the change you are making. Do not paper over it, and do not silently expand the PR into a refactor nobody asked for.

Bring the decision:

1. State the mechanism in one sentence.
2. Give the options, with cost: fix it here, fix it in a follow-up, or contain it.
3. Recommend one.
4. If you ship a containment, label it in the code and the PR as containment, name the mechanism it does not fix, and link the ticket that holds the real fix. An unlinked "TODO: fix properly" is not a plan.

A contained fix with a named mechanism and a ticket is honest engineering. The same fix with no explanation is whack-a-mole with better formatting.

---

## What to Write

On the review thread, in the commit, or in the PR description, one or two sentences that carry the mechanism and the scope:

```
Cause: <the mechanism, in one sentence>.
Fix:   <what changed, and at which layer>.
Scope: <one instance, or the class; what the sweep found>.
Guard: <the test or type that stops it coming back>.
```

"Fixed the null check" says nothing a reader can verify. "The carrier client returned None for a cancelled shipment because the response schema marks `delivered_at` optional; the client now maps it to an explicit `CancelledShipment` rather than a bare None, and the two other call sites that assumed a date are updated" is the same fix, reported so somebody can check it.
