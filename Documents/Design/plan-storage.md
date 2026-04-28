# Design: Plan Storage

**Domain**: Plan persistence and retrieval across agents
**Status**: Current
**Implemented in**: Issue #62

---

## Overview

This design describes the VS Code/Copilot plan cache: plans are stored in VS Code session memory at `/memories/session/plan-issue-{ID}.md` using the `memory` tool's `create` command. This replaces the previous approach of storing plans as local files in `.copilot-tracking/plans/`.

The `Primary` `/memories/session` layer below is scoped to the VS Code/Copilot session-memory implementation. Cross-tool Claude/GitHub survival, fungibility, and read/write precedence for plan and design state live in the canonical operational contract at [skills/session-memory-contract/SKILL.md](../../skills/session-memory-contract/SKILL.md) (`SMC-01`, `SMC-02`, `SMC-03`, `SMC-08`). The rationale for centralizing those rules is documented in [Documents/Design/session-memory-contract.md](session-memory-contract.md).

---

## Storage Architecture

| Layer | Location | Created by | Required |
|-------|----------|------------|----------|
| Primary | `/memories/session/plan-issue-{ID}.md` | Issue-Planner (`memory` tool `create`) | Yes |
| Secondary | GitHub issue comment with `<!-- plan-issue-{ID} -->` as first line | Code-Conductor at D9 Stop / Pause when durable handoff is needed | No |

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

### D2 — GitHub issue comment as explicit D9 durable handoff

Continue implementation uses session memory only as the same-session source of truth. Cross-session and cloud-agent handoff rely on Code-Conductor writing the current plan to a GitHub issue comment only when the user explicitly chooses Stop / Pause at D9. The `<!-- plan-issue-{ID} -->` HTML comment on the first line remains the canonical detection marker, and readers continue to use the latest matching comment.

This cache-vs-durable split is governed by `SMC-01`, `SMC-02`, and the D7 conflict rule in the session-memory contract rationale.

### D3 — Removal of `.copilot-tracking/plans/`

Only the `plans/` subdirectory was removed. The `research/` subdirectory and any archived files remain under `.copilot-tracking/`. Session-cleanup detector test fixtures were updated to reference `research/` paths.

---

## Agent Responsibilities

| Agent | Responsibility |
|-------|----------------|
| Issue-Planner (Section 6) | Write plan to session memory |
| Code-Conductor (D9) | On explicit Stop / Pause, persist the current plan to the canonical GitHub comment when the latest persisted handoff is missing or changed after normalizing away transport-only formatting drift, including line-ending normalization and trailing newlines/whitespace |
| Code-Conductor (Step 1) | Read plan using the lookup chain above |
| Specialist agents | Reference "plan" (not "plan file") in instructions |

---

## Related Files

- `agents/Issue-Planner.agent.md` — Section 6: plan persistence
- `agents/Code-Conductor.agent.md` — Step 1: plan retrieval
- `skills/tracking-format/SKILL.md` — YAML frontmatter spec for `.copilot-tracking/` research files (does not cover session-memory plan YAML; see Issue-Planner Section 6 above)

---

## Design Cache

The design cache stores the full design content from the GitHub issue body in a readily accessible location that survives conversation compaction.

### Design Cache Storage Architecture

| Layer | Location | Created by | Required |
|-------|----------|------------|----------|
| Primary | `/memories/session/design-issue-{ID}.md` | Issue-Planner (Section 6) after plan approval when the cache is absent, or when current-pass issue/design updates require a refresh | No |
| Secondary | GitHub issue comment with `<!-- design-issue-{ID} -->` as first line | Code-Conductor at D9 Stop / Pause when durable handoff is needed | No |

### Design Cache Lookup Chain (Code-Conductor)

1. Session memory — `view /memories/session/design-issue-{ID}.md`
2. GitHub issue comment — search for `<!-- design-issue-{ID} -->` marker
3. Fall back: read issue body directly and create the cache file (fallback creator role)

### File Format

```markdown
<!-- design-issue-{ID} -->
{Full issue body content verbatim}

---
**Source**: Snapshot of issue #{ID} body at plan creation. Design changes require a new plan.
```

The cache stores the complete issue body content — no curation or summarization. Curation risks filtering out exactly the details that matter during implementation.

### Design Cache Decisions

#### DC1 — Full verbatim content, not a curated summary

Summarizing introduces the same context-loss risk the cache is intended to solve — the summarizer might filter out critical details. A typical Solution-Designer output (decisions, AC, constraints, rationale) is small enough that full verbatim content is not a context-window concern in practice.

#### DC2 — Session memory as primary, issue body as source of truth

The session memory file is a cache, not the source of truth. Solution-Designer still writes the authoritative design to the GitHub issue body unconditionally during design. On session reset, Code-Conductor first checks the latest matching `<!-- design-issue-{ID} -->` handoff comment if one was written at D9 Stop / Pause, then falls back to recreating the cache from the issue body.

`SMC-03` owns the operational design-cache precedence. The design cache stays an optimization; the issue body and explicit durable marker remain the cross-tool sources.

#### DC3 — No staleness detection

Design should be settled before implementation begins. Mid-implementation design changes are exceptional — if they occur, the user should restart the affected plan steps. Adding issue-body re-reads at every phase boundary would reintroduce the API-call dependency the cache is meant to eliminate.

#### DC4 — Conditional creation avoids redundant cache churn

Issue-Planner should check for `/memories/session/design-issue-{ID}.md` before creating it. When the cache already exists and the current planning pass did not refresh the issue body or other design-relevant content during research/refinement, re-reading the issue body and deleting and recreating the file adds no value. If the current planning pass did refresh design-relevant issue content before approval, Issue-Planner should recreate the cache from the latest issue body before handoff. This preserves the issue-218 dedup goal, aligns Issue-Planner with Code-Conductor's check-before-create pattern, and preserves DC2: the issue body remains the source of truth, while the session-memory copy is refreshed only when the current pass made the cached snapshot stale.

### Design Cache Agent Responsibilities

| Agent | Responsibility |
|-------|----------------|
| Issue-Planner (Section 6) | Check for an existing design cache after plan approval; keep it unless current-pass issue/design updates require a refresh, then create or refresh it from the issue body |
| Code-Conductor (D9) | On explicit Stop / Pause, persist the current design snapshot to the canonical GitHub comment when the latest persisted handoff is missing or changed after normalizing away transport-only formatting drift, including line-ending normalization and trailing newlines/whitespace |
| Code-Conductor (Step 1) | Read design cache using lookup chain above; recreate from issue body if absent (session reset recovery) |
| Code-Conductor (Step 3) | Re-read design cache at major phase boundaries for alignment checks |
| Code-Conductor (CE Gate) | Read design intent from cache (fallback: issue body) |
| Specialist agents with Plan Tracking | Read design cache at startup for full design requirements context |

### Design Cache Related Files

- `agents/Issue-Planner.agent.md` — Section 6: design cache creation
- `agents/Code-Conductor.agent.md` — Step 1: lookup chain; Step 3: alignment check; CE Gate: design intent reads
- `agents/Code-Smith.agent.md` — Plan Tracking: design cache read
- `agents/Test-Writer.agent.md` — Plan Tracking: design cache read
- `agents/Refactor-Specialist.agent.md` — Plan Tracking: design cache read
- `agents/Doc-Keeper.agent.md` — Plan Tracking: design cache read
- `agents/Code-Critic.agent.md` — Plan Tracking: design cache read

---

## VS Code 1.110 Compaction Resilience

VS Code 1.110 introduced **automatic context compaction** — when the context window fills, VS Code compacts conversation history automatically without user intervention. This is distinct from the manual `/compact` command. The interaction with the plan and design cache strategy is documented here.

### How 1.110 Auto-Compaction Interacts with the Storage Strategy

The session memory strategy (primary plan store at `/memories/session/plan-issue-{ID}.md`, design cache at `/memories/session/design-issue-{ID}.md`) was designed specifically to survive compaction. VS Code 1.110 confirms this design remains correct:

| Event | Plan/design cache outcome |
|-------|--------------------------|
| Manual `/compact` (user-initiated) | Session memory files survive — accessible immediately after compaction |
| Auto-compaction (VS Code 1.110+ trigger) | Session memory files survive — same durable store, same outcome |
| Session end (conversation closed) | Session memory cleared — plan/design cache lost |
| Cross-session or cloud agent handoff | Requires an explicit D9 Stop / Pause so Code-Conductor persists the latest `plan-issue` / `design-issue` handoff comments |

### Progress Checkpointing (1.110 Addition)

Code-Conductor now maintains progress annotations in the session memory plan file: each completed step's title line is annotated with `— ✅ DONE`. This ensures:

1. **Deterministic post-compaction resume**: Code-Conductor can identify the first incomplete step by scanning for title lines not ending in `— ✅ DONE`, without re-deriving progress from git state.
2. **Cross-session recovery**: If the user explicitly chose Stop / Pause and Code-Conductor persisted the plan as a GitHub issue comment, Code-Conductor recreates the session memory plan file from the latest matching comment on session reset, then uses branch-state inference to determine the resume point (the persisted comment does not contain `— ✅ DONE` annotations; those exist only in the live session memory file).

**Implementation**: Code-Conductor's Step 3 execution loop uses `vscode/memory str_replace` to append exactly `— ✅ DONE` to the completed step's title line. This is atomic (no risk of double annotation), preserves all other step content, and produces a scannable text marker.

### Custom `/compact` Instructions

VS Code 1.110 allows agents to supply custom instructions to the compaction summarizer via `/compact focus on: ...`. This feature complements session memory by ensuring the auto-generated summary retains orchestration-critical context (issue ID, step progress, design intent, open decisions) alongside the durable plan file.

- **Code-Conductor** template: preserves issue number, step progress, branch name, design intent summary, and open blockers (see `agents/Code-Conductor.agent.md`)
- **Issue-Planner** template: preserves design decisions, rejected alternatives with rationale, acceptance criteria, open questions, CE Gate assessment (see `agents/Issue-Planner.agent.md`)

These templates use bracket-token substitution so each invocation carries session-specific values, not static categories.

### Design Validation

The existing storage strategy (session memory primary, GitHub issue comment secondary, issue body as source of truth) remains sound under 1.110's auto-compaction model. The 1.110 addition improves the strategy in three ways:

1. Proactive compaction at phase boundaries (reduces probability of mid-step auto-compaction)
2. Progress annotation for deterministic step tracking after compaction
3. Custom compaction instructions to preserve orchestration context across compaction events

No changes to the storage architecture, lookup chain, or fallback logic were required.
