# Design: Agent Body Architecture

**Status**: Implemented in PR #393 (issue #393)

## Summary

Phase 0.3 thinned the three Phase 1 upstream agents — Experience-Owner, Solution-Designer, and
Issue-Planner — from ~160 lines to ~125 lines each by collapsing methodology that lives in skills
into one-line skill-load pointers. Identity sections (completion markers, heading contracts,
agent-specific checklist items) were preserved verbatim. Claude shells (`agents/{name}.md`) were
left byte-identical throughout.

---

## Design

### Two-Tier Body Structure

Every `.agent.md` body follows two tiers:

1. **Identity sections** — kept verbatim; these are agent-specific and cannot be factored out
   without losing the agent's behavioral contract:

   - YAML frontmatter (`tools`, `handoffs`, `user-invocable`)
   - Core Principles
   - Role / Overview / When-to-use / Pipeline description
   - Completion markers and durable-artifact hard stops
   - Questioning Policy rules (platform syntax only in the footer)
   - Boundaries
   - Inline GitHub Setup (3-line branch creation repeated across agents — not worth a skill)
   - Per-agent `## Platform-specific invocation` footer

2. **Skill pointers** — methodology already covered by a named skill collapses to a single load
   instruction, e.g.:

   ```text
   Load `skills/provenance-gate/SKILL.md` and follow the protocol.
   ```

   Skill names, file paths, and load directives are the only implementation detail the agent body
   carries for methodology sections.

### Claude Shells

`agents/experience-owner.md`, `agents/solution-designer.md`, and `agents/issue-planner.md` are
delegation targets referenced by parent agents and the Claude Code plugin router. They are not
thinned; they remain byte-identical to their state before Phase 0.3.

### Platform-Specific Invocations

Copilot tool names (`#tool:vscode/askQuestions`, `vscode/memory`) and Claude tool names
(`AskUserQuestion`) live in YAML frontmatter (`tools:`) and the `## Platform-specific invocation`
footer at the bottom of each agent file — not in body sections.

---

## Key Decisions

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| D3 | Platform-specific wording location | Per-agent `## Platform-specific invocation` footer | Keeps body sections platform-neutral; a single section per agent is easier to maintain than separate `skills/platforms/` files that would require cross-file synchronization |
| D4 | BDD classification rubric in Issue-Planner | Keep inline (annotated "keep in sync with `bdd-scenarios` skill") | Tabular reference material consulted repeatedly during plan authoring; a skill-load interruption mid-planning adds latency without reducing duplication meaningfully — the table must stay synchronized with the skill regardless |
| D6 | Claude shells during body thinning | Untouched (byte-identical) | Shells serve as delegation targets; any structural change risks breaking the cross-tool handoff contract without a corresponding plugin schema update |
| D7 | Command dispatch strategy | Option F — `/experience` and `/design` rewired to inline role adoption (live `AskUserQuestion`); `/plan` stays subagent dispatch | Inline dispatch preserves main-context budget; `/plan` adversarial review requires multi-pass reasoning that benefits from subagent isolation |

---

## Maintenance Rule

When adding methodology sections to any `.agent.md` file, first check whether the content belongs
in a skill. If a skill can carry it, add it to the skill and insert a one-line load pointer in the
agent body. Only embed inline when the content is:

- **Agent-specific identity** (markers, checklist items, boundaries, pipeline description), or
- **Frequently-referenced tabular reference material** where a skill-load interruption degrades
  usability (D4 precedent — annotate with "keep in sync with `{skill}` skill").

Platform-specific invocations always belong in the per-agent footer, never in body sections.
