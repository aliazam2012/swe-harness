# Agent Orchestration

How the main pane runs work it does not do itself.

The evidence behind every rule here is in `REF-orchestrator-agent.md`. This doc is the procedure.
Placement, pane, and cleanup mechanics stay in the `herdr` skill.

## Table of Contents

- [The one rule](#the-one-rule)
- [Before you split anything](#before-you-split-anything)
- [Routing](#routing)
- [Allocating shared resources](#allocating-shared-resources)
- [The batch record](#the-batch-record)
- [Burst lanes](#burst-lanes)
- [The delegation brief](#the-delegation-brief)
- [Starting a child](#starting-a-child)
- [Coordinating without blocking](#coordinating-without-blocking)
- [Verifying what comes back](#verifying-what-comes-back)
- [Limits](#limits)
- [Failure modes to watch](#failure-modes-to-watch)
- [Absorbing a change mid-batch](#absorbing-a-change-mid-batch)
- [Reporting to the operator](#reporting-to-the-operator)
- [Releasing a child](#releasing-a-child)
- [Where a rule lives](#where-a-rule-lives)

---

## The one rule

**The pane the operator talks to leads. It does not take a lane.**

It plans, delegates, verifies, synthesizes, and reports. The moment it starts editing files for one
lane it stops being available, and the operator loses the pane they steer from.

Four things stay with the lead and are never delegated: the decomposition, the decision, the
synthesis, and the report. Delegating the work does not delegate the ownership.

## Before you split anything

Restraint first. OpenAI's instruction is to start with one agent whenever you can, because splitting
early adds prompts, traces, and approval surfaces without making the work better. Cognition's is that
a single continuous context beats a fragmented one.

Split only when at least one of these is true:

- The parts are genuinely independent and can run at the same time.
- A part needs a clean context, because the lead's history would bias it. A review is the standard
  case.
- A part is token heavy and its detail should never enter the lead's context.
- The operator may want to watch, steer, or talk to that part directly.

Do not split when the parts are sequential, when two parts touch the same file, or when the whole
job is smaller than the brief it would take to hand it off.

## Routing

| Work | Goes to | Why |
| --- | --- | --- |
| A fact, a file, one answer | The lead, directly | A brief costs more than the work |
| One bounded lookup, search, or read across many files | Subagent in the lead's own pane | Returns a result, keeps the detail out of the lead |
| One review pass with a clean context | Subagent, or `verifier` for a claim check | Clean context is the point |
| Several small targeted questions at once, read only | Burst lanes | Own pane, so the operator can watch and steer, but no worktree and no slot |
| A distinct workstream the operator may watch or steer | Herdr child pane, its own worktree | It gets a sidebar row and a keyboard |
| A build, a test run, a log tail | Split pane beside the lead, or `Monitor` | Not an agent, so no tab and no stamp |
| Decomposition, decision, synthesis, report | The lead | Never delegated |

Effort ladder, so a one-line question never spawns a team:

| Request | Response |
| --- | --- |
| A fact or a single answer | Answer it. No delegation. |
| One bounded lookup | One subagent, 3 to 10 tool calls. |
| A comparison across two or three angles | 2 to 4 subagents, 10 to 15 calls each. |
| A workstream with independent parts | Herdr children, one per part, one worktree each. |

## Allocating shared resources

A worktree isolates code. It does not isolate anything the code runs against. Ports, servers,
databases, containers, caches, browsers and external accounts are still one machine's worth of
resources, and two lanes reaching for the same one is the most common way parallel work goes wrong.
The symptom is rarely a clean error. It is a dev server that restarts every time a sibling saves, a
test that passes alone and fails in a batch, or a number read off the wrong tenant.

**The lead allocates. A child never picks.** The lead is one process, so it already knows what it
handed out, and central allocation removes the need for any lock between children. This is the same
reason the lead owns the merge.

Every shared resource gets exactly one of four dispositions. Decide it before the brief goes out.

| Disposition | Meaning | Use when |
| --- | --- | --- |
| **Isolate** | Each lane gets its own copy | A per-lane copy is cheap and correct |
| **Offset** | One namespace, a deterministic slice per lane | Copies are impossible but names or numbers can be split |
| **Serialize** | One lane at a time, and the others wait | Only one can exist, and turns are acceptable |
| **Lead only** | No child touches it | The action is irreversible, shared beyond this machine, or needs approval |

### This machine

| Resource | Disposition | How |
| --- | --- | --- |
| Repo checkout | Isolate | One worktree per lane. Register it at creation. |
| A multi-service local stack | Offset | One slot per lane. Slot N offsets each service port by `100N`, slots 1 to 9. The lead assigns the number, and the stack's own startup script refuses a port another process already holds rather than killing it. |
| Any other dev server | Isolate | One server per lane, started inside that lane's worktree on that lane's slot. Never point two lanes at one server: the file watcher then reloads on a sibling's save, and neither lane can trust what it sees. |
| Docker | Offset | A compose project name or container name prefix per lane. |
| Local database | Isolate, or offset | A file per lane where the engine allows it, otherwise a schema or database name prefixed with the lane. Never let two lanes run migrations against one database. |
| Browser automation | Isolate | The Playwright MCP already runs `--isolated`, so each session gets a clean profile. Its `--output-dir` is one fixed path for every session, so tell each lane to write screenshots and traces into its own worktree instead, or you cannot tell which lane produced which file. |
| A shared virtualenv | Lead only | One venv serves every lane. A child never runs `pip install` or `pip uninstall`. An install is approved by a person, through the lead. |
| Build and test caches | Serialize | Two simultaneous builds can corrupt an incremental cache. Give the cache to one lane, or give each lane its own cache directory. |
| `dev`, `stage`, prod | Lead only | One deploy at a time, and the lead owns it. A child that wants a deploy asks for it. |
| Shared external accounts, whatever they are | Serialize through the lead | Rate limits and audit trails are per account, not per lane. A child that needs a write asks the lead, which does it or grants that one lane the action. |
| Shared git refs | Serialize | Worktrees share one `.git`. Ordinary commits are per-worktree and safe. `fetch`, `gc`, and branch deletion touch shared refs, so one lane at a time. |
| Journals and ledgers | Isolate, then append | Each session writes its own journal. Ledger lines are short appends, so concurrent writes interleave safely. |

Do not allocate by hand. `session-lane.sh up <lane> --repo <path>` reserves the worktree and
the lowest free port slot, registers both, and prints the `Resources` block for the brief along with
the exact `--cwd` the child must start in.

Two variants exist because the work does not always start from nothing, and a road that does not
reach the destination gets driven around. `--branch <existing>` puts the lane on a branch that already
exists instead of cutting `lane/<name>`. `--adopt <path>` takes a checkout that already exists and
gives it a slot and a row, leaving the worktree unregistered on purpose: registration is what permits
the close to remove something, and a checkout this session did not create is not its to remove.
Reach for `herdr worktree create` only for a one-off checkout you are not running an agent in, since
it reserves no ports. Allocation and registration are one call, so they cannot
drift apart, and a slot whose ports another process already holds is skipped rather than trampled.

`session-lane.sh list` is the allocation table. It is live, so there is no second copy to keep in
step.

### Reading a collision

| Symptom | Usual cause |
| --- | --- |
| A dev server reloads when nobody in this lane saved | Two lanes share one server, or one server watches a directory two lanes write |
| `port already in use by pid N` | Two lanes took the same slot. Reassign, never kill the holder. |
| A test passes alone and fails in a batch | A shared database, a shared port, or a shared cache |
| A dashboard shows the wrong tenant or stale data | The lane is pointed at another lane's stack |
| A screenshot or export appears that this lane did not take | A shared output directory |
| A `git` command fails on a lock file | Two lanes hit shared refs at once |

Four to eight lanes on one machine is what holds in practice. Past that, allocation and review cost
more than the parallelism returns, which is the same ceiling the three to five children rule sets
from the other direction.

## The batch record

**The lead's context is not durable.** A compaction, a `/clear`, or a dead session loses the plan,
and then nobody can say what a running lane was for. Durable execution engines solve this with an
append-only event log that outlives the process. `session-batch.sh` is that log at the
smallest size that still works.

Open it before the first lane, and record the goal and the exit criteria:

```bash
session-batch.sh open <batch> --goal "<one sentence>" --exit "<how we know it is done>"
```

Then write to it at every transition, not at the end:

```bash
session-batch.sh brief  <batch> <lane> --text "<the seven-field brief>"
session-batch.sh state  <batch> <lane> working|blocked|done|failed [--note "..."]
session-batch.sh steer  <batch> --input "..." --disposition amend|add|quiesce [--lane <lane>]
session-batch.sh status [<batch>] [--stale <minutes>]
session-batch.sh close  <batch> --outcome "..."
```

Four properties follow from the log being the source of truth, and each closes a real gap:

- **Anyone can read it.** `status` is read-only and works from any shell, including after the lead has
  died. Nobody has to enter a pane to find out what a lane was asked to do.
- **Nothing is overwritten**, so the record is also the audit trail.
- **Silence is detectable, per lane.** `status` prints the age of each lane's own last state event, and
  `status --stale <minutes>` exits non-zero when no event has landed in the window. Read the ages, not
  just the exit status: one busy lane keeps the batch fresh while another sits dead, and the batch-wide
  check cannot see that.
- **The record is a claim, and `check` tests it against the disk.** It reports a lane recorded finished
  over a dirty or unpushed worktree, and a lane recorded working whose agent has stopped. Both are
  invisible to anything that only reads the record.

**Set the exit criteria before the first lane starts.** A batch with no agreed exit has no fact to
check at the end, only an opinion. The record warns when you skip it.

## Burst lanes

There was nothing between a subagent, which nobody can see or talk to, and a full lane, which costs a
worktree, a slot and a seven-field brief. A targeted question that takes two minutes does not justify
the second, and often should not be hidden inside the first.

A burst is a lane with no exclusive resources. Own pane, so it appears in the sidebar and the operator can
steer it. No worktree, no port slot, and a one-line task instead of a brief.

```bash
session-batch.sh burst <batch> <name> --task "<one line>"
```

That prints the spawn and release commands. Put it in the batch's existing child tab, stamp it, and
close its pane the moment it answers.

**A burst must not write to a repository.** It owns no worktree, so anything it writes lands in a
checkout someone else owns, which is the one-writer rule broken. If the answer turns out to need a
change, release the burst and allocate a real lane. Wanting to write is the signal that it was never
a burst.

**Recording it is one line and not optional.** An unrecorded child is exactly what the reconciliation
check exists to catch, so a burst that skipped the record would set off the alarm rather than slip
past it. That is deliberate: the cheapest path is also the recorded one.

**Release it when it answers.** A burst holds no resource anyone would miss, which is what makes it
the mode most likely to be left running. `check` reports a burst whose agent has gone idle, because
an idle burst has answered and is now only holding a pane.

Three to five still applies, and it counts bursts. Five bursts and two lanes is seven children, and
the sidebar and your attention are the constraint, not the ports.

## Long-running work goes in a pane

A child that starts a server, a tail or a watcher inside its own pane makes the work invisible. The
output scrolls past its transcript or disappears into a background job, and a server nobody can watch
is a server nobody can debug.

```bash
session-pane.sh web -- "npm run dev"
```

One command, because the alternative is four and a child gets four wrong. It splits a pane, sets the
terminal title so the sidebar says what it is, stamps it with the lead, registers it to the lead's
artifact file so the close owns it, and runs the command. It prints how to read the pane and how to
close it.

Registering to the lead rather than the caller matters. The registry is per pane and the close reads
the lead's copy, so a pane registered to a child that has since exited is a pane nobody removes.

There is deliberately no rule watching for a child that backgrounds something instead. Six observe
rules already exist, three of them have produced false positives on live traffic, and the complaint
that prompted this section was that the orchestrator has too much process, not too little. Make the
right thing one command and let the doctrine carry the rest.

## The delegation brief

Anthropic traced duplicated work to thin task descriptions. Told only "research the semiconductor
shortage", one subagent covered 2021 while two others covered 2025. Every brief carries seven fields.
No field is optional, and a missing boundary is the one that costs the most.

1. **Objective.** What this child owns, in one sentence.
2. **Output format.** Exactly what to return, and in what shape.
3. **Tools and sources.** Which scripts, repos, skills, and branches to use. Name what not to use.
4. **Boundaries.** The files and branch this child owns, and who owns the rest. Say what to leave
   alone.
5. **Resources.** The worktree, the port slot, the database or container prefix, and where to write
   output. Name what is lead only, so the child asks instead of reaching for it.
6. **Return path.** Write the final report to a named file and reply with the path only.
7. **Parent.** The pane or session name to report to.

Template:

```text
Objective: <one sentence>
Output: write your final report to <path>, then reply with that path and nothing else.
Sources: <repos, scripts, skills to use>. Do not touch <what is out of bounds>.
Boundaries: you own <files/branch>. <sibling> owns <files/branch>. Do not edit outside yours.
Resources: worktree <path>, slot <N> (ports <list>), <db/container prefix>. Write output under
  <path>. Lead only: installs, deploys, shared-account writes. Ask, do not reach.
Report to: <parent session name>
Stop and report if you are stuck on the same error three times.
```

The return path is not optional past four children. Each Herdr split halves a dimension, so at six
panes each child gets about twenty columns and its output wraps to a few characters per line. An
agent on the terminal alternate screen cannot be read back at all. Ask for file output up front
rather than discovering this after the wait.

## Starting a child

Give the child the same name in both systems, so one string addresses it everywhere:

```bash
herdr agent start atlas-front-client --kind claude --pane wM:p4 -- --name atlas-front-client
```

The trailing `-- --name <name>` is what makes `SendMessage` work by that name. Without it Claude Code
assigns its own name such as `claude-ac`, the Herdr namespace and the Claude namespace drift, and the
lead has to look the child up before every message.

Placement, the shared child tab, the `HERDR_PARENT_PANE` stamp, and registration are in the `herdr`
skill. Follow it rather than improvising the CLI.

## Coordinating without blocking

**Never block the pane the operator talks to.** `herdr agent prompt --wait` holds the lead until the child
settles. Use it only for the first kickoff into a fresh pane, and only when the answer is immediate.

For everything after that, use cross-session messaging. A Herdr child started as a Claude agent binds
a normal inbox socket, so the lead reaches it by name:

- `SendMessage` to give a child new instructions or an answer it is blocked on. Delivery is pushed,
  and the lead keeps its turn.
- `SendMessage` with `notify_when_idle` to be told once when a child finishes. Omit the message text
  for a pure subscription that costs the child nothing.

**`notify_when_idle` cannot tell you a child is stuck.** It fires when a session finishes its turn,
and a child sitting at a question or an approval has not finished its turn, so the notice never
comes. A lead relying on it alone will wait forever on a child that is waiting on it. This is not
theoretical: on the atlas run of 2026-08-31 two lanes recorded themselves blocked with precise reasons,
the lead did not notice, and the operator had to tell it to go unblock its own child.

**And an idle notice means stopped, not finished.** A child that asks a question and ends its turn
looks exactly like a child that is done. Read what it actually said before concluding anything.

Two mechanisms cover the gap, and neither asks the lead to remember:

- The plugin's watchdog **pushes** a blocked lane at the lead as a notification, so nothing has to go
  looking.
- A `Stop` gate **refuses the hand-off** while a lane is recorded blocked and the reply has not
  mentioned it. Handing back is still allowed, and is often right when only a person can unblock it, but
  not silently. Naming the lane satisfies the gate.
- Never poll. No `ListAgents` loop, no "are you done yet" messages.
- When briefing several children at once, send one message each and let them land. A rapid burst to
  one session is refused at the sender and identical repeats are dropped, so re-sending makes it
  worse. If a send is refused, batch the rest into one message instead.

Children report to the lead, not to each other. Peer to peer chatter between children is the
fragmentation both Anthropic and Cognition warn about. If two children need the same fact, the lead
gives it to both.

Permission boundaries are per session. Never ask a child to run something the lead was denied. Route
it back to the operator instead.

## Verifying what comes back

A child report is a claim, not evidence. This is the failure category that MAST found nobody covers.

For each returned claim, do one of three things:

1. **Read the artifact.** Open the file, run the command, read the log. Cheapest and best.
2. **Send it to `verifier`.** A clean-context subagent that checks the claim against the evidence
   the child cited. Use it when the claim is load bearing and re-running the work is expensive.
3. **Label it.** If neither is possible, carry `[UNVERIFIED]` into the report with what would
   resolve it.

Never pass a child's confident summary through as fact. One reviewer per three or four
builders is the working ratio.

## Limits

- Three to five children. Three focused beat five scattered.
- Past four children, file output is mandatory, not a fallback.
- Multi-agent runs cost roughly 15 times a chat turn in tokens. Spend it on research, review, and
  independent features. Do not spend it on sequential work or same-file edits.
- One worktree, one owner. Two writers in one checkout is the failure both camps name.
- Reassign after three stuck iterations on the same error. Cap a child near eight iterations before
  it must report back.
- Check progress every 5 to 10 minutes. Do not hover, and do not leave children unattended.

## Failure modes to watch

MAST groups 14 failure modes into three. Each has a countermeasure above.

| Group | Looks like | Countermeasure |
| --- | --- | --- |
| System design | Two children did the same thing, a part fell between them, or two lanes grabbed one resource | The seven-field brief, with boundaries and resources |
| Inter-agent misalignment | A child drifted from the request, or sat on a finding | Report to the lead only, and check in every 5 to 10 minutes |
| Task verification | Nobody checked the result | Read the artifact, or send it to `verifier` |

## Absorbing a change mid-batch

The operator will change the request while lanes are running. That is normal, and it is the moment a batch
most often goes wrong, because the change lands in the lead's head and nowhere else, and the next
compaction erases it.

**Two rules.** Record the change before acting on it. Apply it at a checkpoint, never mid-flight: a
system being reconfigured is quiesced first, so the change never lands halfway through an operation.

Every change gets one of three dispositions, and the record wants the disposition by name:

| Disposition | When | What the lead does |
| --- | --- | --- |
| **amend** | The change fits a running lane's scope | Record it, then re-send the amended brief to that lane at its next idle. Never mid-turn |
| **add** | The change is independent of what is running | Record it, allocate a new lane, brief it. Existing lanes are untouched |
| **quiesce** | The change invalidates work in flight | Record it, stop the affected lanes, take stock, re-plan. Work already done is kept, not discarded on reflex |

```bash
session-batch.sh steer <batch> --input "<what was said>" --disposition amend --lane api
```

What the lead must never do is absorb the change silently and carry it only in context. If it is not
in the record, it did not happen, and a lane will keep working to a brief that no longer holds.

Say which disposition you took and why. A change absorbed without a visible decision is how a
batch quietly stops delivering what was asked.

## Reporting to the operator

The lead has one channel to the person steering it, and two ways to ruin it. Say too much and every
message costs attention until none of them land. Say too little and the operator goes out of the loop, which
the human factors literature treats as a named failure: the operator's attention deteriorates, and
"when automation does not behave as expected, understanding the system or taking back manual control
may be difficult". Silence is not a free default. It is the other failure.

### Three channels, and what belongs in each

| Tier | Surface | Carries |
| --- | --- | --- |
| **Page** | A push notification | Blocked and actionable. Work stops until a person acts |
| **In band** | Terminal text at a turn boundary | Decisions, results, what changed, what is at risk |
| **Ambient** | The Herdr sidebar, `waiting on N`, the statusline | Per-child progress. Costs nothing to ignore |

**Per-child progress belongs in the sidebar, never in chat.** The sidebar already shows `working`,
`blocked`, `idle` and `done` per child, and marks a parent `waiting on 2` while its children run. A
lead that narrates lane status in the terminal is re-rendering a dashboard the operator already has, and
spending his attention to do it. Google's alerting guidance makes the same split: prefer the
dashboard for anything sub-critical, and reserve the interrupt for what is urgent and actionable.

### The interrupt budget

Page only when the work is blocked and a person is the one who can unblock it. Everything else waits for a
boundary.

For a ceiling, the process-control standards are the only place anyone has measured this. They put
about 12 new alarms per operator per hour as the most a human can manage, and call more than 10 in a
ten-minute window a flood. A terminal is not a control room and one person steering a few lanes should
sit far below those numbers, so treat them as the outer bound rather than the target. If the lead sends
more than a handful of pushes in an hour, it is narrating, not reporting.

Industry practice puts the priority mix near 80 percent low, 15 percent medium, 5 percent high. The
useful reading is the inverse: if most of what the lead says is high priority, none of it is.

### The escalation ladder

Four rungs, not two. Most orchestrator decisions live in the middle two, which is where the current
rules are silent.

| Rung | When | Where it goes |
| --- | --- | --- |
| **Act and log** | Reversible, low blast radius, obviously right | Ambient only |
| **Act and report at the next boundary** | Ordinary lane work and its results | In band |
| **Propose and proceed unless stopped** | A judgment call you can defend but might get wrong | In band, stated as a decision with its reason |
| **Stop and ask** | Irreversible, prod, customer, money, credentials, or a fork where being wrong wastes real work | Page |

### When you ask, offer three answers

A yes or no question throws away the operator's judgment. The three patterns that human-in-the-loop systems
converge on are approve as it stands, reject and take another route, and edit the proposal before it
runs. Offer all three. Put the recommendation first and say it is the recommendation.

### Confidence goes per claim, not per report

Presenting confidence case by case improves trust calibration and reduces automation bias. A blanket
"verified" on a report that contains one shaky claim produces the opposite: it invites complacency,
which is not an attitude but a behavior, the act of dropping your own checks because you believe they
are no longer needed.

So the `Verified:` and `Gaps:` footer is the floor, not the ceiling. Attach the uncertainty to the
claim it belongs to, the way the `verifier` agent's `COVERAGE` line names what its evidence does not
establish.

### The heartbeat

On a batch that runs longer than a few minutes, the operator needs a pulse every 5 to 10 minutes. It is a
ticket, not a page. It says what changed since the last one, or says plainly that nothing did. This is
the counterweight to the out-of-the-loop problem: it keeps the operator able to take over.

**The pulse is a write to the batch record, not a message.**

```bash
session-batch.sh state <batch> <lane> working --note "<what changed>"
herdr notification show "lanes: 2 working, 1 done" --sound none   # optional, when nobody is at the keyboard
```

A heartbeat the lead has to remember to send is not a heartbeat, because a wedged lead fails to send
it and fails silently. So **invert it**: the lead writes to the record as it works, and something else
watches for silence. The alarm is the absence of a pulse, not the presence of an error.

```bash
# The dead man's switch. It does not share fate with the lead.
Monitor: session-batch.sh status <batch> --stale 15 || printf 'batch went quiet\n'
```

Two reasons the pulse is a record write rather than a turn. A turn that used a tool must carry the
full `Verified:` and `Gaps:` footer, because the done gate fires on it, so a heartbeat sent as a turn
is either heavy or blocked. And progress is ambient by the rule three paragraphs up. A record write
satisfies both, and unlike a notification it leaves something a person can read later.

Reserve an in-band line for a heartbeat that carries a real change worth a claim, which then earns its
footer honestly.

### What a report looks like

Lead with what the operator would act on. "Lane B is blocked on a production credential" says more than "an
update on the three lanes".

Then, in order: what changed, what needs him, what is at risk. Report the shape of the work, not its
volume.

Do not send:

- **Progress theater.** "Still working", "making good progress", "almost there". The sidebar says this.
- **Per-child chatter.** What each child is doing minute to minute.
- **A transcript.** What the children did belongs in their own reports and the journal.
- **A restatement** of something the operator asked seconds ago and is clearly still watching.
- **A push when the operator is at the keyboard.** The terminal already reached him, and a notification on top
  of it is a duplicate.

## Releasing a child

Cleanup is not a step at the end of a batch. It is a duty the lead carries throughout: a lane that is
finished is released then, not when the last sibling finishes. A pane that looks live but is not is
worse than no pane, and a lane still holding a port is worse again.

Release only what you created. The ownership record is the `HERDR_PARENT_PANE` stamp on the pane plus
the rows this session wrote to `session-artifact.sh`. Kubernetes calls the same idea an owner
reference, and its purpose is the same one that matters here: to keep one actor from interfering with
objects it does not control.

### When a child is no longer needed

Three gates, and all three must hold:

1. **Output collected.** The artifact is read. A closed pane and its scrollback do not come back, and
   closed pane and tab ids are never reused.
2. **Claim verified, or labelled.** Releasing an unverified child throws away the ability to ask it
   again. Verify first, or carry `[UNVERIFIED]` forward deliberately.
3. **State is `idle` or `done`.** Never `working`. `unknown` does not prove completion. `blocked`
   means a person is needed: inspect it and ask rather than closing over it. To free a stuck
   child without losing it, `herdr agent send-keys <name> escape` returns it to idle.

A lane that was cut, superseded, or is stuck past its iteration cap is also releasable, through the
same three gates. Collect what it has, then release it.

### Release in reverse order of acquisition

Resources come back in the reverse order they were taken, so nothing is freed while something else
still depends on it. Acquisition ran worktree, slot, services, pane. Release runs:

1. **Collect and verify.** Everything below is irreversible.
2. **Stop what the child started, before closing its pane.** A service outlives the shell that
   started it, so a closed pane can leave a port held by a process nobody can attribute. Use the tool
   that started it: the stack script for that slot, the compose project for that lane, the background
   jobs it launched.
3. **Release the slot.** `session-lane.sh down <lane>` stops the services on that slot, warns if
   anything still holds its ports, and drops the registration so the number returns to the pool.
4. **Worktree.** Remove it only when it is clean, pushed and idle. Dirty or unpushed means keep it and
   report it with the command to resume. Cleanup that can destroy work is not cleanup.
5. **Close the child's pane, not the tab.** `herdr pane close <pane-id>`.
6. **Drop the registry rows** for what is really gone, so a later session cannot act on a dead handle.

Verified on 2026-08-30 on this machine: `herdr pane close` closes one pane and leaves the tab and every
sibling running, including when the pane closed is the tab's root. A tab disappears on its own once its
last pane closes, so there is no emptied tab to sweep up afterwards. Per-child release is safe at any
point in a batch, and `herdr tab close` is correct only when every child in that tab is already
finished.

### Do not touch what you did not create

- **Never `tab close` while any pane in that tab is still working, or belongs to someone else.** Close
  panes individually and let the tab retire itself.
- **Never stop a port, service or container you did not allocate.** A stack tool that refuses a port
  another process holds rather than killing it is doing its job; that refusal is a guard, not an obstacle.
- **Never remove a worktree another lane is inside or branched from.**
- **Never run `git gc`, `git worktree prune`, or a branch deletion while lanes are live.** Those touch
  refs every worktree shares. They belong after the last lane.
- **Never release a lead-only resource on a child's behalf**, and never let one child clean up after
  another. Releases go through the lead, for the same reason allocations do.

### The lead outlives its children

A parent scope does not exit while a child it started is still running. The lead does not wrap its
session while any child it created is `working` or `blocked`. `session-wrap.sh` holds this line
already: it keeps anything holding work and writes the resume command into the journal.

One deliberate difference from structured concurrency: there, a failing child cancels its siblings.
Lanes here are independent by construction, each in its own worktree with its own resources, so a
failed lane does not cancel the others. The lead decides what happens to the rest.

### Aborting a batch

Releasing a finished lane is the normal path. Stopping a batch that has gone wrong is a different
control, and it needs three tiers, not one.

| Tier | Use when | How |
| --- | --- | --- |
| **Graceful interrupt** | One child is stuck or heading the wrong way, but the batch is fine | `herdr agent send-keys <name> escape` returns it to idle without closing it, then re-brief it |
| **Circuit breaker** | A lane trips a threshold: three iterations on the same error, or a cap of about eight | The lead pauses that one lane and reports, rather than letting it burn |
| **Stop** | Something is wrong and nobody yet knows what | `session-lane.sh down --all`, then `session-cleanup.sh --apply` |

The stop tier has one property the other two do not: **it does not run through the lead.** A person runs
it from any shell. A stop that depends on the agent agreeing to stop is not a stop, and that is the whole
failure mode behind the phrase "kill switches do not work if the agent writes the policy".

It is also safe to reach for, because nothing it does destroys work. It stops services and frees slots.
Worktrees are left to `session-cleanup.sh`, which refuses to remove one that is dirty or unpushed.

### The backstop is not the plan

`session-cleanup.sh` reaps by the parent stamp and the registry when the session closes. Its tests
already cover the rules above: it closes a finished child's pane, issues no tab close when the tab
holds a stranger or a working child, closes a tab only when it holds nothing but its own finished
children, and keeps any worktree holding work. That is the net for a lead that dies mid-batch, the
same role a test-container reaper plays when it removes labelled resources after the process that
created them disconnects.

It only ever sees what was registered. It does now free a port slot, by delegating to
`session-lane.sh down`, because ports outlive a pane: services are detached and tracked by pidfile, so
closing a child's pane leaves its stack running and its ports held by a process nobody can attribute.
Slots are released before panes close, the same reverse-order rule a lane release uses. A lane whose
agent is still working or blocked is kept and reported, on the same rule that keeps such a child.

So register at allocation, release at completion, and leave the backstop for the crash case.

## Where a rule lives

A rule written in a document is a suggestion, because the thing reading it is
probabilistic. A rule in a hook is a default, because every session inherits it
whether or not it read anything. Move each rule down the stack until something
deterministic owns it.

**Availability ordering, the rule that governs the rest: a control must not depend
on anything less available than the thing it controls.**

Three consequences, all learned the hard way:

- The emergency stop must work when Claude is not running, so `session-lane.sh`
  stays a plain script on disk. A plugin's `bin/` is on PATH only inside a
  session with that plugin enabled, so `bin/` may hold a convenience wrapper
  and never the control itself.
- The done gate must work when the plugin is disabled, so it stays in
  `settings.json` and does not move into a plugin.
- A general capability every session uses, such as the `herdr` skill, must not
  come to depend on an orchestration plugin being enabled.

### Staged rollout

A rule written from a document is a guess about what people actually type.
Enforcing a guess blocks real work, so promote in three stages and let the
evidence decide.

| Stage | Behaviour | Leave it here until |
| --- | --- | --- |
| **Observe** | Log the violation, never block | Two real batches have run and the log has been read |

Coverage has a catch worth knowing before you read the log. The rules watch
orchestration commands, and only a lead runs those, but a long-running lead is the
session least likely to carry the plugin, because it started before the plugin was
activated. The drill on 2026-08-31 produced zero organic observations for exactly
that reason: its children only ran tests and edited code, and its lead predated the
hook. Read the log from a lead that started fresh, or the evidence stays thin.

| **Warn** | Return the reason, still allow | One batch runs with no false positives |
| **Deny** | `permissionDecision: "deny"` | It stays |

### Every blocking rule declares two things

**A failure policy.** What happens when the check itself crashes or times out.
A checker fails open, because a broken observer must not stop work. A guard fails
closed, because a guard that fails open is not a guard.

**An escape hatch.** A named environment variable that disables it, following the
`DONE_GATE_DISABLE=1` precedent. Without one, a rule with a bad pattern wedges the
session that has to fix it, and fixing it needs the tool calls it is blocking.

### Name a wrapper carefully

A plugin's `bin/` does not take precedence over the system PATH. A wrapper named
`batch` resolved to the macOS `at`-family `/usr/bin/batch` rather than the
plugin's, found by probe on 2026-08-30. Check `command -v <name>` before choosing
one, and prefix when in doubt.
