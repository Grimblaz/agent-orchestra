---
name: parallel-execution
description: "Build-test orchestration protocol for choosing and running parallel or serial implementation lanes with shared requirement contracts, convergence gates, and triage routing. Use when coordinating multiple concurrent implementation paths, managing convergence gates, or running triage routing. DO NOT USE FOR: exploring ideas or trade-offs (use brainstorming) or evaluating architecture (use software-architecture)."
---

# Parallel Execution Skill

## Composite References

- [references/error-handling.md](references/error-handling.md): canonical R5 subagent-call resilience, common issue routing, escalation patterns, terminal non-interactive guardrails, and terminal lifecycle protocol.

## Mode Declaration

Declare one mode before delegation: `Execution Mode: parallel` or `Execution Mode: serial`.

Record it in the progress-log header, `step.metadata.execution_mode`, the user-facing update, and any step-commit details tracked in the plan.

## Requirement Contract (Mandatory)

Before delegation, define one shared Requirement Contract for the step:

Acceptance-criteria slice, explicit invariants and edge cases, and non-goals.

Both implementation and testing lanes must use the same contract.

## Protocol

1. **Choose mode** using stability/risk criteria.
2. **Create Requirement Contract** before any lane starts.
3. **Run lanes**:
   - `parallel`: launch Code-Smith and Test-Writer against the same contract.
   - `serial`: run one lane first, then the second against the same contract.
4. **Run triage** via Test-Writer after outputs are available.
5. **Classify failures** as `code defect`, `test defect`, `harness/env defect`, or `rc-divergence` with evidence.
6. **Route corrections bidirectionally** until convergence:
   - `code defect` -> Code-Smith
   - `test defect` -> Test-Writer
   - `harness/env defect` -> responsible specialist or tooling path
   - `rc-divergence` -> Code-Smith fixes implementation to match the Requirement Contract; CC re-evaluates; if divergence remains, Test-Writer re-derives assertions from the Requirement Contract, not the corrected implementation.
7. **Enforce convergence gate** before advancing.
8. **Run RC conformance check**: CC evaluates the step's Requirement Contract AC items against delivered code after convergence. Divergences route as `rc-divergence` using step 6.

## Convergence Gate (Mandatory)

Do not advance until Test-Writer explicitly confirms:

Green tests, valid assertions, and no brittle coupling.

After convergence, protocol step 8 verifies the Requirement Contract AC items before step advance.

## Loop Budget

- Maximum 3 correction cycles per step.
- If exceeded, perform root-cause review and escalate via the platform's structured question tool (see `platforms/`) with a recommended option.
- RC conformance correction gets 1 dedicated cycle outside the main 3-cycle budget. If still unresolved, escalate with the unresolved AC items and recommended options.

## Anti-Test-Chasing Guardrail

Code-Smith must satisfy the Requirement Contract and architecture constraints, not merely optimize for current failing assertions.

If a property or test appears over-constrained or invalid, classify it as potential `test defect` and route it back for test review with evidence.

## Post-Issue Checkpoint (Mandatory)

At issue/PR completion, record a short process checkpoint:

What slowed us down, what failed late, and what single guardrail should be added next?

Track this in the completion summary to improve future cycles. For subagent rate-limit handling, execution-time escalation, and terminal guardrails that pair with this execution contract, load [references/error-handling.md](references/error-handling.md).

## Gotchas

| Trigger                                | Gotcha                                                              | Fix                                                                |
| -------------------------------------- | ------------------------------------------------------------------- | ------------------------------------------------------------------ |
| Lanes start with different requirements | Parallel work diverges and convergence turns into rework or churn | Define one shared Requirement Contract before any lane starts      |

## Platform-specific invocation

This skill's methodology is tool-agnostic. Platform-specific routing lives alongside [platforms/copilot.md](platforms/copilot.md) and [platforms/claude.md](platforms/claude.md).
