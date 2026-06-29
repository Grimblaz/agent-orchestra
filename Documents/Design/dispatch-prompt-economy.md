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

The economy rule is appended inline to the "Call specialist with focused instructions" bullet in Code-Conductor Step 3 ("Execute Each Step") — co-located with the existing dispatch-economy machinery (`dispatch-cost-samples`, `frame-spine-lookup`). Placing the rule at the dispatch-construction site (rather than a separate skill) keeps the guidance proximate to the action it governs.

### DD2 — Lean dispatch example documented in this design doc

A before/after lean dispatch example lives in `skills/parallel-execution/references/lean-dispatch-example.md`, indexed from `## Composite References` in `SKILL.md`. A copy is reproduced below (see `## Lean dispatch example`) for design-doc context. The example was originally added inline to the Protocol section of `SKILL.md`, then extracted to a `references/` file to keep the composite skill within the 80-line compact-entryway ceiling enforced by `composite-skill-structure.Tests.ps1`. No existing example was converted — the skill was a purely abstract protocol before this change. The example concretely demonstrates the ~2 KB → ~300 B reduction achieved by pointing at `<!-- plan-issue-N --> step M` rather than restating its content.

### DD3 — Rule scope: contract-restatement economy within the dispatch prompt

The rule governs contract-restatement economy **within** the dispatch prompt. It is orthogonal to the legacy "dispatch the full plan" fallback (which fires when the plan has no frame-spine block or the context budget is exceeded). The economy rule applies only where the specialist can resolve the reference — via a spine slice through `frame-spine-lookup`, or by the specialist fetching the slice directly. Novel constraints (those not already documented in the plan or design) always stay inline regardless of reference availability.

---

## Rule Text

From `agents/Code-Conductor.agent.md`, Step 3:

> **dispatch-prompt economy**: prefer pointing at the canonical source (`Read <!-- plan-issue-N --> step M for contract`) over inlining contract detail; reserve inline prose for genuinely novel constraints (e.g., the lowercase-shell quirk, mocking patterns, or any rule not already documented in the plan/design). Applies where the specialist can resolve the reference (spine slice via `frame-spine-lookup`, or the specialist fetches the slice); otherwise inline.

---

## Scope Note

Issue #472 delivered **C2.a only** (Proceed-lite scope per the worth-it check). The following are deferred-optional:

- **C2.b** — prepared-payload optimization (pre-loading the resolved slice into the dispatch body rather than instructing the specialist to fetch it)
- **M1** — telemetry-proof AC (instrumented evidence that dispatch token cost decreased)

---

## Related Files

- `agents/Code-Conductor.agent.md` — the economy rule is appended inline to the "Call specialist … focused instructions" bullet in Step 3 ("Execute Each Step")
- `skills/parallel-execution/references/lean-dispatch-example.md` — canonical lean dispatch before/after example (indexed in `## Composite References`)
- `Documents/Design/dispatch-prompt-economy.md § Lean dispatch example` — copy of the example for design-doc context (this file)
- `skills/frame-spine-lookup/SKILL.md` — the reference-lookup contract the specialist uses to resolve adjacent spine slices

---

## Lean dispatch example

**Before** (~2 KB — contract restatement inlined in the dispatch prompt):

> "Call @Code-Smith for Step 2 (event-batch debouncer): implement the
> file-watch debounce. Requirements: the watcher batches events with a
> 500 ms window; overlapping events within the window collapse to one
> emit; the debounce is per-resource-id, not global; if a resource is
> deleted mid-window, emit the delete immediately and cancel the pending
> batch. Acceptance criteria: a 600 ms wait with two events yields one
> callback; a delete mid-window fires immediately and cancels the batch.
> Non-goals: no retry logic; no cross-process coordination. Edge case:
> high-frequency emission (>100 events/sec) must not accumulate unbounded
> pending batches — collapse into one."

**After** (~300 B — canonical-source reference + one novel constraint):

> "Call @Code-Smith for Step 2: Read `<!-- plan-issue-472 --> step 2` for the
> full Requirement Contract. Novel constraint not in the plan: the debounce
> timer must survive GC pressure at >100 events/sec (avoid closure capture
> of large event payloads)."

The "after" form is shorter because the Requirement Contract already lives in
the plan comment; only the constraint that is NOT already documented there
travels inline.
