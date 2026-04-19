---
name: parallel-execution
description: "Build-test orchestration protocol for choosing and running parallel or serial implementation lanes with shared requirement contracts, convergence gates, and triage routing. Use when coordinating multiple concurrent implementation paths, managing convergence gates, or running triage routing. DO NOT USE FOR: exploring ideas or trade-offs (use brainstorming) or evaluating architecture (use software-architecture)."
---

# Parallel Execution Skill

Execution protocol for implementation steps that may run in parallel or serial mode.

## Mode Declaration

For each implementation step, declare one mode before delegation:

- `Execution Mode: parallel`
- `Execution Mode: serial`

Record the declaration in:

1. Conductor progress log header
2. Step metadata/state (`step.metadata.execution_mode`)
3. User-facing progress update
4. Step commit details if tracked in the plan

## Requirement Contract (Mandatory)

Before delegation, define a shared Requirement Contract for the step:

1. Acceptance criteria slice for the step
2. Explicit invariants and edge cases
3. Non-goals for this step

Both implementation and testing lanes must use this same contract.

## Protocol

1. **Choose mode** using stability/risk criteria.
2. **Create Requirement Contract** before any lane starts.
3. **Run lanes**:
   - `parallel`: launch Code-Smith and Test-Writer against the same contract.
   - `serial`: run one lane first, then the second against the same contract.
4. **Run triage** via Test-Writer after outputs are available.
5. **Classify failures** as `code defect`, `test defect`, `harness/env defect`, or `rc-divergence` with evidence.
6. **Route corrections bidirectionally** until convergence:
   - `code defect` → Code-Smith
   - `test defect` → Test-Writer
   - `harness/env defect` → responsible specialist/tooling path
   - `rc-divergence` → conditional sequential pair: Code-Smith first (fix implementation to match RC); CC re-evaluates; if resolved → advance; if not → Test-Writer with instruction: "Re-derive test assertions from the Requirement Contract, not from the corrected implementation."
7. **Enforce convergence gate** before advancing.
8. **Run RC conformance check** — CC evaluates the step's Requirement Contract AC items against delivered code after convergence. Divergences route as `rc-divergence` with the conditional sequential pair described in step 6.

## Convergence Gate (Mandatory)

Do not advance phase until Test-Writer explicitly confirms:

- Green tests
- Valid assertions
- No brittle coupling

After convergence, the RC conformance check (protocol step 8) verifies that the step's Requirement Contract AC items are satisfied before step advance.

## Loop Budget

- Maximum 3 correction cycles per step.
- If exceeded, perform root-cause review and escalate via the platform's structured question tool (see `platforms/` for invocation details) with a recommended option.
- RC conformance correction uses 1 dedicated cycle outside the main 3-cycle budget. If unresolved after 1 cycle, escalate via the platform's structured question tool (see `platforms/`) with unresolved AC items and recommended options.

## Anti-Test-Chasing Guardrail

Code-Smith must satisfy the Requirement Contract and architecture constraints, not merely optimize for currently failing assertions.

If a property/test appears over-constrained or invalid, classify as potential `test defect` and route back for test review with evidence.

## Post-Issue Checkpoint (Mandatory)

At issue/PR completion, record a short process checkpoint:

- What slowed us down?
- What failed late that should fail earlier?
- What single guardrail should be added next?

Track this in the completion summary to improve future cycles.

## Gotchas

| Trigger                                                                                           | Gotcha                                                                                                | Fix                                                                                                                                                                               |
| ------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Test-Writer writes tests to match Code-Smith's implementation instead of the Requirement Contract | Tests pass but AC is not met; the test is wrong, not the implementation                               | Route back as `test defect` with evidence when assertion appears over-constrained relative to AC                                                                                  |
| Starting implementation lanes before the Requirement Contract is agreed                           | Lanes diverge against different assumptions; reconciliation is expensive                              | Mandate Requirement Contract before any lane begins — block execution until it exists                                                                                             |
| Advancing to the next phase on a verbal "looks good"                                              | Missing explicit green/valid/non-brittle confirmation; state is ambiguous                             | Block phase advance until all 3 convergence criteria explicitly stated in writing                                                                                                 |
| More than 3 correction cycles with no resolution                                                  | Infinite loop; work stalls; effort compounds with no progress                                         | At cycle 3, perform root-cause analysis and escalate via the platform's structured question tool (see `platforms/`) with concrete options                                              |
| Classifying a test defect as a code defect (or vice versa)                                        | Wrong agent receives the correction task; fix misses the actual problem                               | Triage before routing: `code defect`, `test defect`, `harness/env defect`, or `rc-divergence` — require evidence                                                                  |
| Skipping the post-issue process checkpoint after merge                                            | Lessons from slow steps and late failures are lost                                                    | Record the 3-question checkpoint in every completion summary                                                                                                                      |
| RC conformance flags divergence but CC routes as `code defect` instead of `rc-divergence`         | Code-Smith fixes code without Test-Writer re-deriving from RC; tests still reflect divergent behavior | Always route RC conformance divergences as `rc-divergence` — conditional sequential pair (Code-Smith → re-evaluate → Test-Writer with "re-derive from RC" if divergence persists) |

---

## Platform-specific invocation

This skill's methodology is tool-agnostic. Platform-specific routing lives alongside:

- Copilot: [platforms/copilot.md](platforms/copilot.md)
- Claude Code: [platforms/claude.md](platforms/claude.md)
