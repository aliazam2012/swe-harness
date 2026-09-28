# MCP Write Safety Standard

## Table of Contents

- [TLDR](#tldr)
- [When This Applies](#when-this-applies)
- [The Universal Write Rule](#the-universal-write-rule)
- [The Three Audit Layers](#the-three-audit-layers)
- [Per-Server Reversibility Classification](#per-server-reversibility-classification)
- [The Enforcement Pattern (Hooks)](#the-enforcement-pattern-hooks)
- [Right-Sizing to the Threat Model](#right-sizing-to-the-threat-model)
- [Per-Server Onboarding Checklist](#per-server-onboarding-checklist)
- [Reference Implementation](#reference-implementation)

---

## TLDR

Any MCP server that can write to an external system follows the same safety pattern: classify each tool's reversibility, capture before-state, write, verify, and log, with a hook backstop that enforces it at the tool boundary. This doc is the reusable pattern. The per-server specifics (which tools write, which are irreversible, what before-state looks like) differ per MCP and live with that server's setup, not here. Install and version rules live in `MCP_SKILL_MANAGEMENT.md`; this doc governs runtime writes.

---

## When This Applies

Applies to any MCP server that can mutate an external system of record: issue trackers, ticketing, docs, repos, CRMs, databases, cloud resources. If a server can only read, it is exempt from this standard (it still follows `MCP_SKILL_MANAGEMENT.md` for install and vetting).

A server is "write-capable" if any of its tools create, update, transition, delete, link, move, or otherwise change remote state. Mixed servers (mostly read, a few writes) are in scope for their write tools only.

## The Universal Write Rule

Every external write through an MCP server follows six steps, in order. This is server-agnostic.

1. **Classify reversibility.** Know before you call whether the tool is reversible, conditional, or irreversible (see the next section). If it is not cleanly reversible, get explicit approval and note the irreversibility.
2. **Get approval.** No external write without the user's go-ahead. Destructive or bulk writes are a hard stop.
3. **Capture before-state.** Read and persist the current value of whatever the write will change, so the change can be undone. For a create, there is no before-state; record that.
4. **Write.**
5. **Verify after write.** Re-read and confirm the result matches intent. Write-success is not proof of correct state. On mismatch, stop and surface it.
6. **Log.** Record the write with before-state, after-state, and a ready-to-run revert. No external write without a log entry.

The rule is the same for every server. What changes per server is the shape of before-state and the revert mechanism.

## The Three Audit Layers

A write-safe server has three layers, each answering a different question. Do not collapse them: each covers a gap the others cannot.

| Layer | Question it answers | Property |
|---|---|---|
| **Native changelog** | What changed, by whom, when? | Authoritative and complete (captures out-of-band writes too), but often weak at restoring prior rich-field values. The system of record. |
| **Machine trail** | Did a write happen, was prior state captured, did it confirm? | Hook-written, discipline-independent. Records intent and outcome. Only sees writes through this client. |
| **Curated revert log** | What was it before, and how do I undo it? | Human-readable, holds before-state and the exact revert. Discipline-dependent unless hook-assisted. |

The native changelog is the only complete record. The machine trail and curated log are the reversibility and detection layers for writes made through this client.

## Per-Server Reversibility Classification

Every write-capable server must ship a reversibility matrix: one row per write tool, classified. This is the highest-value per-server artifact, because it tells the agent which writes are safe to make freely and which are a hard stop.

Three classes:

- **Reversible.** An inverse tool exists, or the prior value can be restored. Safe with before-state captured.
- **Conditional.** Reversible only under a condition (a backward transition exists, the link still resolves, the prior parent is known). Check the condition before writing.
- **Irreversible.** No inverse through the server (delete, some creates, worklog adds when no delete tool exists). Hard-confirm and snapshot first; recreation will not preserve identity or history.

Build the matrix by listing the server's tools and checking which have an inverse in the same server's inventory. A write tool with no inverse is irreversible through that server, regardless of whether the underlying system supports undo by other means.

## The Enforcement Pattern (Hooks)

Discipline is not enough. Enforce the rule at the tool boundary with Cursor hooks so it does not depend on the agent remembering. The pattern is two hooks, server-agnostic in shape:

- **`beforeMCPExecution` guard.** Fires before every MCP call. Passes reads and non-target servers through. For a target-server write: auto-captures before-state (snapshot), appends an intent record to a machine trail, and returns **`deny`** for irreversible tools. ⚠️ **Use `deny`, not `ask`** — Cursor ignores `ask` on this hook (see step 8). Because `deny` blocks silently with no dialog, pair it with an out-of-band approval token so a deliberate human approval is still possible.
- **`afterMCPExecution` reconciler.** Fires after. For a target-server write, records the outcome (success or error) correlated to the intent record, so the trail distinguishes attempts from confirmed writes.

Non-negotiable properties of the pattern:

- **Fail loud, not silent.** If the hook does not load or the guard cannot run, that must be detectable. A guard that silently stops running removes all protection without warning. Verify the guard is registered at session start (`SESSION_PROTOCOL.md` step 8). Do not run live destructive probes against an external system as a health check.
- **Fail closed on irreversible tools.** A guard error must not let a delete or bulk-create through. Reversible writes may fail open so a bug never blocks normal work.
- **Stdlib and least-privilege.** Keep the hook dependency-light. If it needs creds for before-state capture, read them from the server's own scoped env file, never hardcode.

What differs per server: the write-tool list, the irreversible-tool set, and how before-state is fetched. The hook structure is copyable.

## Right-Sizing to the Threat Model

Do not over-build. Match the layers to the real threat. For a single-user tool writing to the user's own account, the realistic risks are (1) the agent silently skipping a log or snapshot, and (2) an accidental destructive change that cannot be undone. They are not a malicious actor forging the audit trail.

| Layer | Single-user brain tool | Shared or production-facing |
|---|---|---|
| Universal write rule | Required | Required |
| Reversibility matrix | Required | Required |
| Before-state capture | Required | Required |
| Fail-loud guard health | Required | Required |
| Machine trail (intent + outcome) | Recommended | Required |
| Destructive fail-closed | Recommended | Required |
| Tamper-resistance (append-only, external sink) | Skip (wrong threat model) | Consider |
| Out-of-band reconcile vs native changelog | Skip | Consider |

Decide the tier before building. Write the decision down so a later reader knows which omissions were deliberate.

## Per-Server Onboarding Checklist

When enabling a new write-capable MCP server:

1. Install and vet per `MCP_SKILL_MANAGEMENT.md` (version pin, tool review, audit-log line).
2. List every write tool the server exposes.
3. Build the reversibility matrix (reversible / conditional / irreversible).
4. Pick the threat tier (single-user vs shared) and record it.
5. Stand up the curated revert log and the before-state store.
6. If the tier calls for it, copy the hook pattern: set the server's write-tool list and irreversible set, wire before-state capture, verify it fires live.
7. Confirm fail-loud: prove the guard is active and that a missing guard is detectable.
8. **Register the health check so it runs automatically.** Document a non-destructive health check in the server README. Add the server to whatever start-of-session registration check the harness runs. A guard nobody checks is a guard that silently dies.

   ⚠️ **The check must assert the enforced outcome, not the intended one.** Learned the hard way, after a probe with a fake target still sent a real delete to the real system. Two rules follow:

   - **Use `deny`, not `ask`.** Cursor enforces only `permission: deny`. `ask` is accepted by the schema and **silently treated as allow** for `beforeMCPExecution`, so a guard returning `ask` blocks nothing. The hook permission path and Cursor's built-in MCP approval path are separate systems: a hook can only *subtract* permission, never *add* an approval prompt that the Run Mode or MCP allowlist has already waived.
   - **Do not prove guard health with a live destructive tool call.** A fake target still sends a destructive operation to the external system. Use non-destructive checks, hook registration checks, or a dedicated test tenant instead.

   Also set `failClosed: true` on any security-critical hook, so a crash or timeout blocks rather than waves the write through.
9. **Wire discoverability so future agents find it without prior knowledge.** Route the read and the write paths from wherever the agent's always-loaded memory lists its tools, pointing at the server README's MCP Writes section. An undiscoverable safe path gets bypassed for the unsafe one.
10. Document the limits you are accepting.

## Reference Implementation

Write the worked example down beside the server it guards, not here, because the
tool list is product-specific and this pattern is not. What to record for each
one: the threat tier and why, the write-tool list, the irreversible subset, the
before-state capture, the fail behavior, and the health probe with its expected
output.

Copy the structure, not the product-specific tool lists. When a new
write-capable server runs on the same MCP server key as an existing guard,
generalize that guard in place rather than adding a second hook, so the
destructive gate never depends on multi-hook resolution order.
