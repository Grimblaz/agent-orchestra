---
name: parallel-execution
description: Build-test orchestration protocol for choosing and running parallel or serial implementation lanes with shared requirement contracts, convergence gates, and triage routing. Use when coordinating multiple concurrent implementation paths, managing convergence gates, or running triage routing. DO NOT USE FOR: exploring ideas or trade-offs (use brainstorming) or evaluating architecture (use software-architecture).
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
5. **Classify failures** as `code defect`, `test defect`, or `harness/env defect` with evidence.
6. **Route corrections bidirectionally** until convergence:
   - `code defect` → Code-Smith
   - `test defect` → Test-Writer
   - `harness/env defect` → responsible specialist/tooling path
7. **Enforce convergence gate** before advancing.

## Convergence Gate (Mandatory)

Do not advance phase until Test-Writer explicitly confirms:

- Green tests
- Valid assertions
- No brittle coupling

## Loop Budget

- Maximum 3 correction cycles per step.
- If exceeded, perform root-cause review and escalate via `vscode/askQuestions` with a recommended option.

## Anti-Test-Chasing Guardrail

Code-Smith must satisfy the Requirement Contract and architecture constraints, not merely optimize for currently failing assertions.

If a property/test appears over-constrained or invalid, classify as potential `test defect` and route back for test review with evidence.

## Post-Issue Checkpoint (Mandatory)

At issue/PR completion, record a short process checkpoint:

- What slowed us down?
- What failed late that should fail earlier?
- What single guardrail should be added next?

Track this in the completion summary to improve future cycles.
