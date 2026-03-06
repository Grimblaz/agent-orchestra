# Design: Agent Personality System

## Summary

All 13 agents now open with a standardized role-grounded identity paragraph plus a principles section. Without persona guidance, agents default to generic assistant patterns. Code-Conductor's `## Ownership Principles` block proved the value — extending the same structure to all specialists produces consistent, role-specific behavior with no functional changes.

---

## Design Decisions

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| D1 | Fragment handling | Replace existing fragments, don't weave around them | Cleaner, standardized result; weaving would leave inconsistent structure |
| D2 | Principle count | 3–5 per specialist agent | Enough behavioral guidance without reaching Code-Conductor's orchestrator-level detail (7) |
| D3 | Heading for specialists | `## Core Principles` | Consistent label; `## Ownership Principles` reserved for Code-Conductor's orchestrator-specific framing |
| D4 | Stance sections | Preserved, not replaced | Code-Critic/Code-Review-Response/Refactor-Specialist stance sections reinforce personality; personality inserted before them |

---

## Pattern

Each agent opens with:

1. **Identity paragraph** (1–2 sentences, "You are…") — defines role and core value
2. **Principles section** (`## Core Principles` or `## Ownership Principles`) — 3–5 bullets, bold lead-in + one-sentence explanation

Code-Conductor's existing `## Ownership Principles` (7 principles) is the reference archetype.

---

## Application

Three insertion strategies were used across the 12 specialist agents:

- **Clean insert** (5 agents — Doc-Keeper, Issue-Designer, Process-Review, Test-Writer, UI-Iterator): New identity + principles block inserted after frontmatter, before the `# {Agent} Agent` heading. No existing content removed.
- **Fragment replacement** (4 agents — Code-Smith, Issue-Planner, Research-Agent, Specification): Existing partial identity text replaced with standardized block. Semantic constraints preserved as principles (e.g., Issue-Planner's planning-only responsibility, Research-Agent's read-only constraint).
- **Stance-preserving insert** (3 agents — Code-Critic, Code-Review-Response, Refactor-Specialist): Personality inserted before existing stance section. Stance sections remain intact and reinforce the personality.

---

## Agent Summary

| Agent | Identity (condensed) | Principles Section |
|-------|---------------------|--------------------|
| Code-Conductor | Technical lead who owns the outcome | `## Ownership Principles` |
| Code-Critic | Forensic investigator who finds what everyone else missed | `## Core Principles` |
| Code-Review-Response | Fair but firm referee who weighs evidence, not pressure | `## Core Principles` |
| Code-Smith | Craftsman who builds exactly what's needed, nothing more | `## Core Principles` |
| Doc-Keeper | Precision editor who treats documentation as source of truth | `## Core Principles` |
| Issue-Designer | Curious explorer who asks "why?" before "what?" | `## Core Principles` |
| Issue-Planner | Meticulous strategist who leaves nothing to chance | `## Core Principles` |
| Process-Review | Systems thinker who sees patterns across workflow executions | `## Core Principles` |
| Refactor-Specialist | Code archaeologist who sees structural debt others walk past | `## Core Principles` |
| Research-Agent | Investigative analyst who follows evidence trails | `## Core Principles` |
| Specification | Technical writer who values precision and structure above all | `## Core Principles` |
| Test-Writer | Quality advocate who thinks in edge cases | `## Core Principles` |
| UI-Iterator | Design-eye perfectionist who thinks like the user, not the developer | `## Core Principles` |
