---
name: design-challenge
integrity-contract:
  pipeline-stages: [prosecution]
  atomic: n/a
  prosecution-passes: [1, 2, 3]
  exempt: false
pass-lenses:
  - pass: 1
    lens: tree-grounding/feasibility
  - pass: 2
    lens: scope-fidelity/requirements-coverage
  - pass: 3
    lens: failure-modes/durability
---

# Design Challenge

Runs the prosecution-only design challenge variant. The sequence is three specialist passes, each investigating a distinct lens, all dispatched under the design-review selector.

## Consumers

Two, both reviewing a **design-shaped** artifact:

- **Solution-Designer Stage 3** — challenges a proposed design; Solution-Designer incorporates or dismisses findings and updates the issue body.
- **Issue-Planner, for a `plan-variant: brief` plan — whichever of the brief's two authority sources it carries** (a chunk of a designed parent, or a standalone issue with an affirmed open-for-work framing record; #936 D5, sites per DA4, added #941, sources per #957 D4) — the brief is a design-shaped artifact rather than a step-bearing one, so `CLAUDE.md`'s chunk-plan panel rule stops applying and this charter applies instead. Issue-Planner reconciles findings onto the plan comment rather than the issue body.

Both callers run the **convergence filter** (`skills/design-exploration/SKILL.md § Convergence Filter`, #785) over the merged three-lens ledger. That is not a Solution-Designer-only step: `skills/solution-authoring/SKILL.md` keys the classification gate's firing input on convergence-sustained findings, which is the only input this adapter can supply given it produces no judge ruling.

## Prosecution-only by design

Defense and judge stages are intentionally absent to preserve the non-blocking inform-but-don't-veto semantic both consumers rely on. Adding either stage is a contract change requiring design review.

## Pass Lenses

Each pass investigates a distinct lens (DD3); only the investigative focus varies from pass to pass — the selector string and pipeline shape (3 passes, non-blocking, prosecution-only) are shared across all three.

Each lens operates *within* the fixed 3-perspective report skeleton defined in `skills/adversarial-review/modes/design-review.md`'s `## Design Review` section (§D1 Feasibility & Risk / §D2 Scope & Completeness / §D3 Integration & Impact): the lens is the investigative focus, the §D headings are the report shape, and pass 3's failure-modes/durability lens reports under §D3 Integration & Impact.

- Pass 1 — **tree-grounding/feasibility**: does the design rest on artifacts that actually exist in the live tree, and is the proposed approach technically achievable given current repository structure and constraints?
- Pass 2 — **scope-fidelity/requirements-coverage**: does the design fully address the stated requirement without silently narrowing or drifting from the customer/owner intent, and are all acceptance-relevant surfaces covered?
- Pass 3 — **failure-modes/durability**: what breaks under edge cases, degraded conditions, or future maintenance pressure, and does the design hold up over time rather than only for the happy path?
