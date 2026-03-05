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
