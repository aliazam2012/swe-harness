# MCP and Skill Management

## Table of Contents

- [Purpose](#purpose)
- [Installation Rules](#installation-rules)
- [Version Policy](#version-policy)
- [Tool Review](#tool-review)
- [Community Server Vetting](#community-server-vetting)
- [Periodic Review](#periodic-review)

---

## Purpose

Rules for installing, updating, and reviewing MCP servers and Cursor/Claude Code skills. The goal is controlled adoption: use the ecosystem, but know exactly what's running and why.

This doc covers install, version, and vetting. For runtime safety of servers that can write to an external system (the write rule, reversibility classification, audit layers, enforcement hooks), see `MCP_WRITE_SAFETY.md`. Every write-capable server passes both. For how to author a skill (structure, description craft, progressive disclosure, evals), see `SKILL_AUTHORING_STANDARD.md`.

## Installation Rules

1. **Never install an MCP server or skill without the owner's explicit approval.** This includes new installs, version upgrades, and enabling/disabling individual tools.
2. **Never use `@latest` for MCP versions.** Always pin to a specific version (e.g., `@playwright/mcp@0.0.76`). Check the current version with `npm view <package> version` before pinning.
3. **Read the SKILL.md before installing any skill.** Understand what it does, what it writes, what network calls it makes, and what permissions it needs.
4. **A shared skill has one canonical source: the repository that owns it.** Author the real directory there, then surface it to each harness by symlink, not by copy, so one edit updates everywhere and the skill is in version control from day one. Never hand-create a skill directory inside a folder the harness manages for itself: the install step places the symlink, and a hand-made directory beside it becomes a copy that drifts. Verify with `core/scripts/harness-drift.sh`. For authoring quality of any skill, see `SKILL_AUTHORING_STANDARD.md`.
5. **MCP config lives in one file.** One file, all servers, so the inventory is readable in one place.
6. **A shared skill comes from its owning repository.** Never install a skill from an unknown source without review.

## Version Policy

- Pin every MCP server to the exact version tested and approved.
- To upgrade: check the changelog, run a quick test, then update `mcp.json` and the audit log.
- Never upgrade silently. Every version change gets a line in the audit log.

## Tool Review

When installing an MCP server that exposes multiple tools:

1. List all tools the server exposes.
2. Identify which tools are needed for the intended use case.
3. Block unneeded tools using `--blocked-tools` (Playwright) or equivalent server-specific flags.
4. Document the decision in the audit log.

Risk tiers for Playwright tools:
- **Core (always keep):** `browser_navigate`, `browser_snapshot`, `browser_click`, `browser_type`, `browser_fill_form`, `browser_press_key`, `browser_select_option`, `browser_close`
- **Useful (keep):** `browser_take_screenshot`, `browser_navigate_back`, `browser_tabs`, `browser_wait_for`, `browser_hover`, `browser_console_messages`, `browser_network_requests`, `browser_network_request`, `browser_resize`, `browser_handle_dialog`, `browser_drag`, `browser_drop`
- **Powerful (keep with caution):** `browser_evaluate` (runs arbitrary JS in page context)
- **Blocked:** `browser_run_code_unsafe`, `browser_file_upload`

## Community Server Vetting

Before installing any community (non-first-party) MCP server, run both checklists. First-party vendor servers (Atlassian Rovo, GitHub, etc.) skip the authority check but still pass the safety one. Record the result in the audit log line.

### Authority signals (is it credible?)

| Signal | What good looks like |
|---|---|
| Registry presence | Listed in the official MCP registry and/or major directories (Glama, mcpservers.org, MCP.Directory). Absent from all is a red flag. |
| Adoption | High stars/forks and real PyPI/npm download volume, not just stars. |
| Maintainer | Org-backed or several active maintainers. A single-maintainer project is usable but a bus-factor risk; weigh it for anything that holds write creds. |
| Activity | Commits in the last weeks, regular tagged releases, a changelog. |
| Hygiene | Permissive license present (MIT/Apache), issue backlog not unbounded relative to activity. |
| Release discipline | Semver tags that can be pinned exactly. No "install from main" as the only option. |

### Safety signals (can it hurt you?)

1. **Auth model.** OAuth with scoped permissions beats a static API token. If a token is required, it must be scoped and revocable, never `@latest`-loaded.
2. **Where the secret lives.** Never inline a token in `mcp.json`. Use a dedicated 600-perm env file (or OAuth / secret store) holding only the vars that server needs. Do not hand a third-party server your whole `.env.local`.
3. **Network egress.** It should only talk to the intended host. Read the source or run it once with network logging to confirm it does not phone home.
4. **Destructive tool surface.** List every tool. Disable products/tools you do not need (omit their env, use read-only or an `ENABLED_TOOLS` allowlist where supported). Any delete/bulk-write tool that stays enabled gets an explicit confirm at the agent layer per `core.mdc` §1.
5. **Supply chain.** Pin the exact version. Prefer a Docker image with a pinned digest for production. Check the dependency count and whether releases are signed.
6. **Secret handling in code.** Read the auth path and the write paths. Confirm the server does not log the token.
7. **Run isolation.** Docker or a sandbox beats running raw on the host with a live token.

### Decision rule

Use the official vendor server by default. Choose a community server only when it gives functionality the official one lacks (broader toolset, self-host, Server/Data-Center support) AND it clears both checklists above. Document the trade-off in the audit log.

## Periodic Review

Every 30 days (or when a major version drops), review:

1. Are all installed MCPs still needed?
2. Are versions current? Check `npm view <pkg> version` against pinned version.
3. Are blocked tools still the right set? Any new tools added by upstream that should be blocked?
4. Are all installed skills still used? Any new ones in the shared repository worth adopting?
5. Update the audit log with review findings.

Next review due: **2026-07-21**
