# Chunked delivery: design to the seams, plan to the contract

Ratified 2026-07-26 (issue #920, process outcome of the #848 tree review). The operative summary lives in [CLAUDE.md § Chunked delivery](../../CLAUDE.md); this document carries the full doctrine and rationale.

## Why

Shift-left works on **specification defects** — requirements, contracts, interfaces — where analysis is cheaper than rework. It does not extend to **operational unknowns**: how software actually behaves once it runs. Those are discovered cheapest by running real code, not by deeper analysis. Chunked delivery takes both benefits — waterfall's coherent upstream decisions made once, iterative development's ground truth between decisions — by bounding **where detail is allowed to live** at two distinct levels. Both bounds are load-bearing; enforcing only one recreates the waterfall failure mode one level down.

The evidence behind this: in the #848 tree, churn concentrated where sub-issues of an already-designed parent re-entered the full upstream pipeline (#901 reached NO PLAN after multiple full adversarial panels before its later approved redesign), and where analysis was applied to failure modes of software with zero live runs (#910/#912). The cheapest catches in the tree were live probes (#871, #898).

## The two bounds

**Bound 1 — the parent design stops at the seams.** A parent issue carries the experience framing and technical design once, to a bounded depth: the design decides the **boundaries between implementation chunks** — interfaces, data shapes, spanning invariants, and the chunk sequence — and deliberately does **not** design any chunk's internals. If the design is specifying mechanism inside a chunk, it has gone too deep.

**Bound 2 — the chunk plan is a contract, not a recipe.** Each chunk's goal-contract plan (the #848/#872 plan variant consumed by `/goal-run`) hands the executor machine-checkable targets, invariants, evidence obligations, halt conditions, and a budget — and stops there. Unknowns *inside* the chunk (mechanism choices, internal structure, how to make the targets pass) belong to the executor's run; the planner must **not** pre-solve them. Plan-phase discovery is read-only grounding sufficient to write checkable targets and honest halt conditions — the moment planning turns into designing the implementation, it has crossed the boundary. The one exception: an unknown that could void a target, invariant, or the chunk boundary itself is not an in-box unknown — surface it as a design gap rather than resolving it unilaterally.

## Operating rules

- **Chunks are plan-only sub-issues.** A chunk sub-issue of a designed parent goes straight to the planner in goal-contract mode — no worth-it check, no experience phase, no design phase, and no standards-check re-litigation of the parent's decisions; the chunk inherits them. One chunk = one sub-issue = one goal-contract plan = one `/goal-run` = one pull request (PR). Do not split chunks at the PR level under a single issue: the harness's plan marker, run-state, and halt plumbing are all issue-scoped.
- **Inheritance is loaded, not assumed.** The chunk sub-issue body must link its parent, and the planner's first act in chunk mode is reading the parent's design — seams, spanning invariants, and any recorded amendments — before authoring the contract; the chunk's goal-contract cites the parent decisions it implements. Without this, `upstream-onboarding` would synthesize context from the child's own body (which carries no design markers) and the plan could silently violate parent seams.
- **Design gaps route up, not sideways.** If a chunk cannot be planned without a new design decision, that is a design gap on the **parent** — recorded there as a single design amendment — not a design phase on the child. This upward channel is the iterative discovery mechanism: running code corrects the design without re-running the design.
- **Walking skeleton first.** The first chunk is the thinnest end-to-end path through all the seams, so boundary errors surface at chunk-1 prices instead of chunk-5 prices.
- **Panel depth earns its way down.** Chunk plans start with the full adversarial plan review (the prosecution → defense → judge pipeline; methodology in `skills/adversarial-review/SKILL.md`, run by Issue-Planner). Annotate findings in the phase-containment ledger with whether each was catchable only at plan time; relaxation to a lite stress-test for routine chunks is earned by ledger evidence, never by a cost argument (consistent with CLAUDE.md § Quality-first, shift-left).

## Deferred follow-up

Once the doctrine has been exercised on a real parent/chunk tree: wire the chunk fast path into the `upstream-onboarding` and `plan-authoring` skill prose so the planner's contract-not-recipe bound is enforced at authoring time, not only by this doctrine.

**Interim behavior until that wiring lands:** the shipped `/plan` pre-flight does not recognize a designed parent — on a chunk sub-issue it will still find no `design-phase-complete` marker on the child and offer to run `/design`. Decline that offer for chunk sub-issues, citing this doctrine; the fast path is applied by the operator and by agents reading CLAUDE.md, not yet by the command prose.
