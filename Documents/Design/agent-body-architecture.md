# Design: Agent Body Architecture

**Status**: Implemented through Phase 0.3 and Phase 3

## Summary

Phase 0.3 established the thin-body pattern for the three Phase 1 upstream agents —
Experience-Owner, Solution-Designer, and Issue-Planner — by collapsing reusable methodology into
one-line skill-load pointers while preserving agent-specific identity sections verbatim.

Phase 3 extended the same architecture to Code-Conductor. The shared body stayed the canonical,
tool-agnostic contract, but large reusable methodology blocks were extracted into composite skills
and named reference files so the body could shrink from 966 lines to <=500 without losing explicit
load paths or orchestration boundaries. Claude parity now uses the same shared body through both
`agents/code-conductor.md` and `commands/orchestrate.md`.

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

Phase 3 added the same thin-shell wrapping model for Code-Conductor. `agents/code-conductor.md`
is a Claude-specific shell that performs Claude-only preconditions and tool mapping, then loads the
shared methodology from `agents/Code-Conductor.agent.md`. `commands/orchestrate.md` is the Claude
slash-command wrapper that resolves issue context, prepares the handshake preamble, and dispatches
the `code-conductor` shell rather than duplicating orchestration logic.

### Phase 3 Extension: Code-Conductor

Issue #403 applied the thin-body architecture to the largest shared agent body in the repo.
Code-Conductor remained the orchestration owner, but reusable methodology moved out to the owning
skills and reference files:

- **Customer Experience Gate** -> `skills/customer-experience/references/`
- **Pipeline Metrics** -> `skills/calibration-pipeline/references/`
- **Review Reconciliation Loop** -> `skills/validation-methodology/references/` plus
   `skills/code-review-intake/references/express-lane.md`
- **Error-handling process** -> `skills/parallel-execution/references/error-handling.md`
- **Refactoring integration** -> `skills/refactoring-methodology/SKILL.md` `## Conductor Integration`

The important boundary did not change: Code-Conductor still owns sequencing, delegation, and PR-gate
responsibilities. The extracted references hold reusable method text, schemas, routing contracts,
and recovery rules; the agent body keeps only the shell responsibilities and the explicit load
directives that point to those canonical sources.

### Composite-Skill Convention

Phase 3 also formalized a composite-skill pattern for large reusable methodology areas.

- `SKILL.md` stays a compact entryway that defines purpose, boundaries, and when to use the skill.
- Named `references/*.md` files carry the extracted methodology that agents load directly.
- The entryway enumerates every reference file so the skill remains discoverable without regrowing
   the extracted prose inline.

This keeps the owning skill readable while giving shared agent bodies stable, explicit paths to the
canonical extracted material.

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

For large shared bodies such as Code-Conductor, prefer the Phase 3 composite-skill form over adding
new long-form methodology back into the agent file: keep `SKILL.md` as the entryway, add or extend
named `references/*.md` files for extracted method text, and leave the agent body with explicit
load directives plus the orchestration decisions that only the agent can own. Future shell or
command wrappers should continue to load the shared body rather than fork it, so Copilot and Claude
stay aligned on one contract.
