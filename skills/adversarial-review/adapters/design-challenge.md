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

Runs the prosecution-only design challenge variant for Solution-Designer Stage 3. The sequence is three specialist passes, each investigating a distinct lens, all dispatched under the design-review selector.

## Prosecution-only by design

Defense and judge stages are intentionally absent to preserve Solution-Designer Stage 3's non-blocking inform-but-don't-veto semantic. Adding either stage is a contract change requiring design review.

## Pass Lenses

Each pass investigates a distinct lens (DD3); only the focus each pass is asked to apply changes — the selector string and pipeline shape (3 passes, non-blocking, prosecution-only) are shared across all three.

- Pass 1 — **tree-grounding/feasibility**: does the design rest on artifacts that actually exist in the live tree, and is the proposed approach technically achievable given current repository structure and constraints?
- Pass 2 — **scope-fidelity/requirements-coverage**: does the design fully address the stated requirement without silently narrowing or drifting from the customer/owner intent, and are all acceptance-relevant surfaces covered?
- Pass 3 — **failure-modes/durability**: what breaks under edge cases, degraded conditions, or future maintenance pressure, and does the design hold up over time rather than only for the happy path?
