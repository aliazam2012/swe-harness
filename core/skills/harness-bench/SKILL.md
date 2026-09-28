---
name: harness-bench
description: "Measure the harness itself before and after changing it: hook latency, the test suite, and what sessions actually do. Use when editing anything under a unit's hooks directory, the generated settings.json, or a hook registry, and when asked whether a harness change helped or hurt. Not for benchmarking product code, not for an LLM eval set, and not for user-interface testing."
---

# harness-bench

A harness change has no visible cost. A hook that costs 20 ms is invisible until
you multiply it by how often it fires, and the answer is usually not the one you
guessed: a hook on the `Bash` matcher is paid on most tool calls in a turn, so a
change there costs an order of magnitude more per turn than the same change on a
`Stop` hook. Measure, or you are guessing.

## Rule routing

Read only the tool the change touches. The benchmark writes each run to
`$HARNESS_WORKSPACE/benchmarks/hooks.jsonl`, so a claim about cost has a history
behind it rather than being a claim.

| You changed | Run | It answers |
| --- | --- | --- |
| A hook, the generated `settings.json`, or a `registry.json` | `core/scripts/harness-bench.py` | What does this cost per turn and per session? |
| Any hook or harness script | `core/tests/run.sh` | Is the suite still green, as a number? |
| Nothing yet, you need the weights | `core/scripts/transcript-stats.py` | How often does this matcher actually fire? |

All three carry their own `--help`. Read it rather than guessing at flags.

## The order that works

1. **Baseline first, and store it.** `harness-bench.py --runs 15`. Without a
   stored run from before the change there is nothing to compare against.
2. **Make the change.**
3. **Compare.** `harness-bench.py --runs 15 --compare last --threshold-pct 25`.
   It exits non-zero on a regression.
4. **Run the suite.** `core/tests/run.sh --only <pattern>` while iterating, then
   the whole thing before handing back.

**Never compare below 15 runs.** Measured by taking identical back-to-back runs
and reading the spread: at `--runs 5` the median scenario drifted by about a
third between runs and more than half crossed the 25% threshold on their own, so
the tool would have called noise a regression. At `--runs 15` the median drift
was under 4% and none crossed it. The tool says so itself when a comparison is
built on too few runs. The built-in default is 50, which is the safe answer.

**Run it on an idle machine.** The tool warns above a load average of 2.0.
That warning is not decoration: a busy machine was the other half of the drift
above. Other agents in other panes count as load.

## What a run tells you, and what it refuses to

- **The headline is per turn and per session**, not per call. A per-call figure
  says nothing until it is multiplied by the invocation volume, which the tool
  reads out of the local transcripts rather than assuming.
- **Every branch is weighted off the corpus**, over a 14-day window by default.
  A weight that moved by more than 2x between the window's two halves is flagged
  and the headline built on it is reported as provisional.
- **`--compare` refuses two runs whose windows differ.** The same hook set
  weighted over two different slices of the corpus differs by more than any real
  regression would, and the difference would read as one.
- **A scenario that cannot prove it reached its branch is UNTRUSTED**, not fast.

## Safety

The tool executes real hooks with synthetic payloads, so it carries a
side-effect table. A hook classified SAFE runs as it is; SAFE-IF runs under the
sandbox named beside it; UNSAFE runs only when that sandbox provably contains
every effect, and one that cannot be contained is skipped unless
`--include-unsafe` is passed. **A hook with no row in that table is never
executed.** Core cannot classify a side effect it has never seen, so a layer's
hooks are discovered and reported as UNKNOWN rather than run blind; a layer that
wants its hooks measured contributes a row and a scenario.

## The gate

`core/hooks/stop-harness-bench-gate.py` blocks the hand-off when this session
edited a hook, the generated `settings.json` or a registry and no stored run
describes the result. It reads a recorded run rather than running the benchmark,
because a full run takes minutes and a Stop hook has seconds. Editing a hook's
*test* does not trip it; that changes no cost.

What counts as the harness is decided by `core/hooks/harness_fingerprint.py`,
which both the gate and the benchmark import, so the two can never disagree
about whether something changed.

If it blocks you, run step 3 above. `HARNESS_BENCH_GATE_DISABLE=1` is the
machine owner's call, not an agent's.

## What it does not measure

Latency, and the suite's own green or red. That is all. It says nothing about
tokens loaded, whether the right skill was picked, or whether the output got
better. Do not report a green benchmark as evidence that a documentation or
routing change helped; it is evidence about milliseconds only.
