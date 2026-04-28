---

name: plan-authoring
description: "Reusable implementation-plan authoring methodology. Use when running read-only discovery, drafting execution steps with CE Gate coverage, or preparing a plan for adversarial stress-testing and approval. DO NOT USE FOR: plan persistence, approval-policy enforcement, or direct implementation work (keep those in Issue-Planner.agent.md or use implementation-discipline)"
---

<!-- platform-assumptions: markdown skill guidance for VS Code custom agents in Agent Orchestra; assumes Issue-Planner retains no-edit boundaries, approval prompting, and session-memory persistence semantics. -->
<!-- markdownlint-disable-file MD041 MD003 -->

# Plan Authoring

Reusable methodology for turning researched scope into an executable implementation plan.

## When to Use

- When a task needs read-only discovery before planning begins
- When ambiguities must be narrowed into approval-ready choices
- When a plan needs execution modes, requirement contracts, review stages, and CE Gate coverage
- When the draft plan should be stress-tested before approval

## Purpose

Reduce ambiguity before implementation starts. Discovery should produce evidence, alignment should resolve open decisions, and the draft plan should be specific enough that downstream agents can execute it without re-deriving the work.

## Discovery Workflow

### 1. Gather Read-Only Evidence

Search broadly before reading deeply. Review the issue body, related design documents, decisions, instructions, and nearby implementations. The discovery pass should identify blockers, ambiguities, affected files or areas, and whether the change touches a customer-facing surface.

### 2. Reuse Existing CE Gate Inputs

If Experience-Owner already documented customer surface identification, tool availability, and scenarios in the issue body, reuse them directly. If that data is absent, derive a minimal CE Gate readiness assessment inline from the feature description and repository context.

When BDD is enabled, prepare scenario IDs and `[auto]` or `[manual]` classification using the `bdd-scenarios` skill.

### 3. Keep the Research Subagent Bounded

When delegating discovery to a subagent, keep the brief read-only and scope it to:

- High-level search before file reading
- Design and decision document review
- CE Gate surface identification and exercise method selection
- Missing information, technical unknowns, and feasibility risks

Do not let the discovery pass draft the full plan.

## Alignment Workflow

If research surfaces ambiguity, convert it into a small decision set:

- Summarize the viable choices
- Recommend one option with explicit trade-offs
- Clarify the minimum missing information needed to proceed

If the user's answer materially changes scope or mechanism, loop back through discovery before drafting the plan.

## Draft Workflow

### 1. Build the Execution Skeleton

Prepare a plan that ties every step to an acceptance-criteria slice and names the expected execution mode. The draft should include the implementation steps, validation approach, review pipeline, CE Gate handling when applicable, deferred-significant follow-up behavior, and a short retrospective checkpoint.

### 2. Write Requirement Contracts

For each implementation step, name:

- The acceptance-criteria slice being delivered
- Key invariants or edge cases
- Important non-goals or exclusions
- The narrowest validation expected at the end of the step

### 3. Carry CE Gate Through the Plan

When the work has a customer-facing surface, draft a dedicated final `[CE GATE]` step with:

- Surface type
- Design intent reference
- Functional and intent scenarios to exercise
- Exercise method for each scenario

If no customer-facing surface exists, state why `ce_gate: false` is justified.

### 4. Keep the Review Pipeline Explicit

Include the fixed adversarial review pipeline: three prosecution passes, merged findings ledger, one defense pass, one judge pass, and local resolution of accepted findings before completion.

## Stress-Test Preparation

Before approval, prepare the draft plan for adversarial review:

1. Run three independent Code-Critic prosecution passes. Passes 1 and 2 use design review perspectives and must tag each finding with the current pass number. Pass 3 uses product-alignment perspectives, must tag each finding with the current pass number, and should include the plan plus any available issue-body, design-doc, decision-doc, guidance-file, and planned-work context needed to judge alignment. Each pass must receive the full plan content rather than a partial excerpt.
1. Merge and deduplicate the findings. Treat the same perspective target plus the same failure mode as a duplicate, keep the earliest pass's finding as the primary entry, and annotate cross-pass or cross-perspective repeats on that entry instead of counting them twice.
1. Decide which findings to incorporate, dismiss, or escalate.
1. Run defense and judge passes.
1. Reconcile the draft against the judge outcome before presenting approval.

The agent remains responsible for the approval prompt contract and for persisting the approved plan.

### Post-Judge Reconciliation

After the judge rules, cross-check any plan changes made during the prosecution incorporation phase against the judge's final rulings. If a prosecution finding that was incorporated was subsequently disproved by defense and confirmed rejected by the judge, revert the plan change derived from that finding.

Exception: if the incorporation was user-confirmed (the finding was escalated via the platform's structured-question tool and the user confirmed it), do not silently revert — instead, flag the conflict in the Plan Stress-Test entry as `judge-rejected / user-confirmed` and surface it for user reconsideration before presenting the final plan draft.

Update the `Plan Stress-Test` summary block by replacing the `Judge: pending` placeholder in each entry with the judge's final ruling. Keep the Prosecution field intact.

## Plan Style Guide

### Plan-markdown template

```markdown
## Plan: {Title (2-10 words)}

{TL;DR — what, how, why. Reference key decisions. (30-200 words)}

**Steps**

1. {Action with file path links and `symbol` refs}
   - Execution Mode: {serial | parallel}
   - Requirement Contract: acceptance-criteria slice; invariants/edge cases; non-goals.
2. {Next step}
   - Execution Mode: {serial | parallel}
   - Requirement Contract: …

**Verification**
{How to test: commands, tests, manual checks}

**Decisions** (if applicable)

- {Decision: chose X over Y}

**Plan Stress-Test** (summary of Code-Critic review)

- Challenge: {finding} — Prosecution: {incorporated | dismissed with rationale | escalated+confirmed | escalated+rejected} — Judge: {pending → replaced with: sustained | rejected | judge-rejected/user-confirmed}
- Overall confidence: {high | medium | low} — {one-sentence rationale}
```

### Base rules

- No code blocks — describe changes, link to files and symbols.
- No questions at the end — ask via the platform's structured-question tool during the workflow.
- Include execution metadata (mode + requirement contract expectations) so implementers can execute without re-deriving process rules.
- When a step crosses a layer boundary (as defined in `.github/architecture-rules.md`), note the dependency direction and verify it aligns with documented architecture rules. Scope steps to a single layer where feasible.
- Insert a dedicated **`[CE GATE]`** numbered step as the final implementation step after the Code-Critic review step (and after all accepted Code-Critic findings are resolved). Format: `N. [CE GATE] — Surface: {type} — Design Intent: {link or one-line summary} — Scenarios: {functional + intent} — Method: {how each scenario is exercised}`. When BDD is enabled, list each scenario by concrete ID with classification, e.g., `S1: {description} [auto/manual]` or placeholder `S{N}: {description} [auto/manual]`. The `[CE GATE]` step is blocking — advancement past it requires either completion or the documented skip marker. Omit only when `ce_gate: false`.
- For backend/non-UI/CLI projects, the CE Gate surface is the API or CLI — identify appropriate scenarios for customer-perspective verification.
- Keep the plan scannable.

### Specialized rules

- **Agent-file insertion strategies** — when a step modifies `.agent.md` files, categorize each file as exactly one of: (a) **clean insert** — no existing identity/personality text at the canonical insertion point (top of body, immediately before the main heading); (b) **fragment replacement** — existing identity/personality text is present at the canonical insertion point; (c) **stance-preserving insert** — a named stance section sits at the insertion point and must be preserved. Behavioral guidance found elsewhere in the body (not at the canonical insertion point) does not qualify as a fragment — classify those files as clean inserts.
- **Migration-type issues** — issues involving pattern replacement, API migration, rename/move across files, or signal phrases like "replace X with Y", "migrate from A to B", "rename Z across the codebase", or "remove all references to W" — require that **Step 1 of the plan MUST be an exhaustive repo scan**. The scan produces the authoritative list of files to update; the issue author's file list must not be relied on as complete. Subsequent steps must be scoped to scan-discovered files only — additions require a documented reason.
- **Removal steps** — when a step removes a concept, feature, section, or phrase from a file, the Requirement Contract must include a completeness validation grep confirming zero remaining references in the target file and any other files that referenced it.
- **Cross-file constants** — when a step (a) implements or modifies a script or module that consumes enumerated values produced by another file (stage names, category strings, enum labels), or (b) creates or modifies a file that authoritatively defines enumerated values consumed by scripts, the Requirement Contract must: (i) for case (a) name the authoritative source file; for case (b) identify all known consumer scripts via grep — and (ii) list the exact allowed values as a quoted string enum (example format: `Allowed values: 'main' | 'postfix' | 'ce'`).
- **Multi-tier statistical output** — when a step involves a statistical output schema with multiple independent sub-sections (calibration scripts, metrics aggregators), the Requirement Contract must enumerate each output section that requires a `sufficient_data` gate rather than describing gating as a single aggregate requirement.
- **CE Gate multi-path output coverage** — when a script emits a new output block in more than one conditional path, require at least one CE Gate scenario for each path where the block appears. Each scenario's acceptance criterion must specify the expected behavior of every consuming agent in that path, not merely output format.
- **New-section ordering** — when a step creates a new section with multiple sub-items (subsections, list items, blocks), list them in the intended reading/document order and annotate "add in this order" so placement is deterministic.
- **Security-sensitive field carve-out** — when a step defers conflict resolution for a data migration, the Requirement Contract must enumerate security-sensitive fields (auth hashes, tokens, permission flags) and specify their merge semantics separately from data fields. If no security-sensitive fields exist, state that explicitly.

### Agent-capability verification

When any plan step characterizes another agent's capabilities, permissions, or scope, verify the claim against that agent's own specification (read the agent's `.agent.md` file) before finalizing the requirement contract.

## Plan Approval Prompt Format

When asking for plan approval, treat the approval prompt as a decision-card-first consent surface. The approval dialog must stand on its own so the user can approve from the dialog alone without depending on the transcript or conversation history.

The approval prompt must include a mandatory approval card in this compact labeled shape:

- `Change:` one sentence describing the planned behavior or workflow change in user-relevant terms.
- `No change:` one sentence naming the meaningful boundary, exclusion, or non-goal the user might otherwise assume is included.
- `Trade-off:` the main compromise, watchpoint, or cost the user is accepting.
- `Areas:` the affected files, workflow areas, or systems at a glance.

`Execution:` is conditional. Include it only when execution shape materially affects approval — for example, plans with more than three steps, plans using parallel execution lanes, or cases where sequencing itself is likely to change the approval decision. When present, summarize the plan shape rather than restating every step.

Prefer exact files only when there are a few high-signal paths. When exact files are noisy, collapse to grouped areas or area-level summaries instead of a raw file dump. If exclusions are implicit, derive `No change` from the plan boundary, non-goals, or unaffected surfaces. If `Change` or `No change` still cannot be stated concretely after those fallbacks, stop and clarify before asking for approval.

Present the plan as a **DRAFT**, then immediately ask for approval via the platform's structured-question tool. Never end a turn after presenting a draft without calling the approval tool — this wastes a user turn just to say "looks good."

## Context Management

If discovery becomes long or tool-heavy, compact before drafting. Preserve the key decisions, rejected alternatives, acceptance criteria, open questions, and CE Gate assessment so the plan draft starts from stable context instead of a partially remembered transcript.

## Related Guidance

- Load `research-methodology` when the main challenge is evidence gathering rather than plan structure
- Load `bdd-scenarios` when scenario IDs and classification are required for the CE Gate step
- Load `implementation-discipline` once the work shifts from planning to code changes

## Gotchas

| Trigger                                             | Gotcha                                                                 | Fix                                                                   |
| --------------------------------------------------- | ---------------------------------------------------------------------- | --------------------------------------------------------------------- |
| Discovery starts writing implementation steps early | The plan inherits assumptions before feasibility and scope are checked | Keep discovery read-only and delay the full plan until alignment ends |

| Trigger                                               | Gotcha                                                                     | Fix                                                                          |
| ----------------------------------------------------- | -------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| CE Gate is drafted from mechanics instead of outcomes | The plan exercises the surface but misses design intent and customer value | Reuse Experience-Owner scenarios when present, or derive both scenario types |
