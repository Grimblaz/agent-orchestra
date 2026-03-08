# Design: Plan Storage

**Domain**: Plan persistence and retrieval across agents
**Status**: Current
**Implemented in**: Issue #62

---

## Overview

Plans are stored in VS Code session memory at `/memories/session/plan-issue-{ID}.md` using the `memory` tool's `create` command. This replaces the previous approach of storing plans as local files in `.copilot-tracking/plans/`.

---

## Storage Architecture

| Layer | Location | Created by | Required |
|-------|----------|------------|----------|
| Primary | `/memories/session/plan-issue-{ID}.md` | Issue-Planner (`memory` tool `create`) | Yes |
| Secondary | GitHub issue comment with `<!-- plan-issue-{ID} -->` as first line | Issue-Planner (opt-in) | No |

### Lookup Chain (Code-Conductor)

1. Session memory — `view /memories/session/plan-issue-{ID}.md`
2. GitHub issue comment — search for `<!-- plan-issue-{ID} -->` marker
3. Escalate via `vscode/askQuestions` if neither source found

---

## Plan Format

```markdown
---
status: pending
priority: p2          # p1=high, p2=medium, p3=low; no label → p2
issue_id: "NNN"
created: YYYY-MM-DD
ce_gate: false        # true if CE Gate is required
---

## Plan: {Title}

**Steps**
...
```

---

## Design Decisions

### D1 — Session memory as primary storage

Session memory is immediately available, requires no file system operations, and avoids gitignored-file management overhead. Limitation: cleared when the VS Code conversation ends.

### D2 — GitHub issue comment as optional persistence

Providing an opt-in GitHub issue comment gives cross-session and cloud-agent handoff support without polluting issue threads for simple same-session work. The `<!-- plan-issue-{ID} -->` HTML comment on the first line is the canonical detection marker.

Default answer to the prompt is **No** (session memory only).

### D3 — Removal of `.copilot-tracking/plans/`

Only the `plans/` subdirectory was removed. The `research/` subdirectory and any archived files remain under `.copilot-tracking/`. Session-cleanup detector test fixtures were updated to reference `research/` paths.

---

## Agent Responsibilities

| Agent | Responsibility |
|-------|----------------|
| Issue-Planner (Section 6) | Write plan to session memory; prompt for optional issue-comment persistence |
| Code-Conductor (Step 1) | Read plan using the lookup chain above |
| Specialist agents | Reference "plan" (not "plan file") in instructions |

---

## Related Files

- `.github/agents/Issue-Planner.agent.md` — Section 6: plan persistence
- `.github/agents/Code-Conductor.agent.md` — Step 1: plan retrieval
- `.github/instructions/tracking-format.instructions.md` — YAML frontmatter spec for `.copilot-tracking/` research files (does not cover session-memory plan YAML; see Issue-Planner Section 6 above)

---

## Design Cache

The design cache stores the full design content from the GitHub issue body in a readily accessible location that survives conversation compaction.

### Design Cache Storage Architecture

| Layer | Location | Created by | Required |
|-------|----------|------------|----------|
| Primary | `/memories/session/design-issue-{ID}.md` | Issue-Planner (Section 6) after plan approval | No |
| Secondary | GitHub issue comment with `<!-- design-issue-{ID} -->` as first line | Issue-Planner (opt-in, same single "Yes" prompt as plan comment) | No |

### Design Cache Lookup Chain (Code-Conductor)

1. Session memory — `view /memories/session/design-issue-{ID}.md`
2. GitHub issue comment — search for `<!-- design-issue-{ID} -->` marker
3. Fall back: read issue body directly and create the cache file (fallback creator role)

### File Format

```markdown
<!-- design-issue-{ID} -->
{Full issue body content verbatim}

---
**Source**: Full design from issue #{ID} body. Re-read issue for any updates.
```

The cache stores the complete issue body content — no curation or summarization. Curation risks filtering out exactly the details that matter during implementation.

### Design Cache Decisions

#### DC1 — Full verbatim content, not a curated summary

Summarizing introduces the same context-loss risk the cache is intended to solve — the summarizer might filter out critical details. A typical Issue-Designer output (decisions, AC, constraints, CE Gate, rationale) is small enough that full verbatim content is not a context-window concern in practice.

#### DC2 — Session memory as primary, issue body as source of truth

The session memory file is a cache, not the source of truth. The GitHub issue body remains authoritative. On session reset, Code-Conductor recreates the cache from the issue body (fallback creator role).

#### DC3 — No staleness detection

Design should be settled before implementation begins. Mid-implementation design changes are exceptional — if they occur, the user should restart the affected plan steps. Adding issue-body re-reads at every phase boundary would reintroduce the API-call dependency the cache is meant to eliminate.

### Design Cache Agent Responsibilities

| Agent | Responsibility |
|-------|----------------|
| Issue-Planner (Section 6) | Create design cache to session memory after plan approval; optionally persist as GitHub issue comment (same "Yes" prompt as plan) |
| Code-Conductor (Step 1) | Read design cache using lookup chain above; recreate from issue body if absent (session reset recovery) |
| Code-Conductor (Step 3) | Re-read design cache at major phase boundaries for alignment checks |
| Code-Conductor (CE Gate) | Read design intent from cache (fallback: issue body) |
| Specialist agents with Plan Tracking | Read design cache at startup for full design requirements context |

### Design Cache Related Files

- `.github/agents/Issue-Planner.agent.md` — Section 6: design cache creation
- `.github/agents/Code-Conductor.agent.md` — Step 1: lookup chain; Step 3: alignment check; CE Gate: design intent reads
- `.github/agents/Code-Smith.agent.md` — Plan Tracking: design cache read
- `.github/agents/Test-Writer.agent.md` — Plan Tracking: design cache read
- `.github/agents/Refactor-Specialist.agent.md` — Plan Tracking: design cache read
- `.github/agents/Doc-Keeper.agent.md` — Plan Tracking: design cache read
- `.github/agents/Code-Critic.agent.md` — Plan Tracking: design cache read
