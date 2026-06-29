# Design: Dispatch-Prompt Economy

**Domain**: Code-Conductor dispatch cost and prompt construction
**Status**: Current
**Implemented in**: Issue #472

---

## Overview

Dispatch-prompt economy is a rule in Code-Conductor's Step 3 ("Execute Each Step") that governs how specialist dispatch prompts are constructed. Instead of re-inlining contract detail that already exists in the plan comment, the conductor references the canonical source and reserves inline prose for constraints that are genuinely novel. This was introduced to eliminate redundant token spend on every dispatch while keeping the specialist fully informed.

---

## Problem

Before issue #472, dispatch prompts routinely restated the Requirement Contract verbatim: requirements, acceptance criteria, non-goals, and edge cases were inlined into the dispatch message even though the specialist could read the same content directly from the plan comment. This grew per-dispatch cost without providing any information the plan comment didn't already contain. With multi-step plans and parallel dispatch, the overhead compounded per step.

---

## Design Decisions

### DD1 — Rule placement in Step 3

The economy rule lands as a sub-bullet under the "focused instructions" bullet in Code-Conductor Step 3 ("Execute Each Step"), co-located with the existing dispatch-economy machinery (`dispatch-cost-samples`, `frame-spine-lookup`). Placing the rule at the dispatch-construction site (rather than a separate skill) keeps the guidance proximate to the action it governs.

### DD2 — Lean dispatch example added to `skills/parallel-execution/SKILL.md`

A before/after lean dispatch example was added under `### Lean dispatch example` in the Protocol section of `skills/parallel-execution/SKILL.md`. No existing example was converted — the skill was a purely abstract protocol before this change. The example concretely demonstrates the ~2 KB → ~300 B reduction achieved by pointing at `<!-- plan-issue-N --> step M` rather than restating its content.

### DD3 — Rule scope: contract-restatement economy within the dispatch prompt

The rule governs contract-restatement economy **within** the dispatch prompt. It is orthogonal to the legacy "dispatch the full plan" fallback (which fires when the plan has no frame-spine block or the context budget is exceeded). The economy rule applies only where the specialist can resolve the reference — via a spine slice through `frame-spine-lookup`, or by the specialist fetching the slice directly. Novel constraints (those not already documented in the plan or design) always stay inline regardless of reference availability.

---

## Rule Text

From `agents/Code-Conductor.agent.md`, Step 3:

> **Dispatch-prompt economy**: prefer pointing at the canonical source (`Read <!-- plan-issue-N --> step M for contract`) over inlining contract detail; reserve inline prose for genuinely novel constraints (e.g., the lowercase-shell quirk, mocking patterns, or any rule not already documented in the plan/design). Applies where the specialist can resolve the reference (spine slice via `frame-spine-lookup`, or the specialist fetches the slice); otherwise inline.

---

## Scope Note

Issue #472 delivered **C2.a only** (Proceed-lite scope per the worth-it check). The following are deferred-optional:

- **C2.b** — prepared-payload optimization (pre-loading the resolved slice into the dispatch body rather than instructing the specialist to fetch it)
- **M1** — telemetry-proof AC (instrumented evidence that dispatch token cost decreased)

---

## Related Files

- `agents/Code-Conductor.agent.md` — the economy rule lives in Step 3 ("Execute Each Step"), under the "focused instructions" sub-bullet
- `skills/parallel-execution/SKILL.md` — lean dispatch example under `### Lean dispatch example` in the Protocol section
- `skills/frame-spine-lookup/SKILL.md` — the reference-lookup contract the specialist uses to resolve adjacent spine slices
