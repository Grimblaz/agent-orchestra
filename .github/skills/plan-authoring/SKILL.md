---

name: plan-authoring
description: Reusable implementation-plan authoring methodology. Use when running read-only discovery, drafting execution steps with CE Gate coverage, or preparing a plan for adversarial stress-testing and approval. DO NOT USE FOR: plan persistence, approval-policy enforcement, or direct implementation work (keep those in Issue-Planner.agent.md or use implementation-discipline)
---

<!-- platform-assumptions: markdown skill guidance for VS Code custom agents in Copilot Orchestra; assumes Issue-Planner retains no-edit boundaries, approval prompting, and session-memory persistence semantics. -->
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
