---
name: validation-methodology
description: "Reusable validation and review methodology for staged validation, failure triage, and prosecution-depth setup. Use when running validation ladders, triaging failures, or executing adversarial review passes. DO NOT USE FOR: CE Gate orchestration, specialist dispatch ownership, or step execution flow (keep those in Code-Conductor)."
---

<!-- platform-assumptions: markdown skill guidance for VS Code custom agents in Agent Orchestra; assumes the owning agent already controls routing, step order, and specialist handoffs. -->
<!-- markdownlint-disable-file MD041 MD003 -->

# Validation Methodology

Reusable entryway for staged validation and extracted review-reconciliation references.

## When to Use

- When an agent needs a graduated validation sequence from cheap automated checks to independent review
- When validation failures need a consistent triage rule before re-delegation
- When a review cycle needs the shared review-reconciliation contract without re-reading Code-Conductor
- When an agent needs reusable review heuristics but must keep specialist routing, express-lane ownership, and CE Gate ownership in the agent

## Purpose

Run validation in increasing-cost tiers, classify failures before rework, and point callers at the canonical review-reconciliation references. The owning agent still decides who speaks next, when CE Gate runs, and how accepted fixes are routed.

## Validation Ladder

Validation runs in this graduated 4-tier order:

1. **Tier 1 — Build & Validate**: run quick-validate commands, lint/typecheck, and the full test suite together when practical so all failures are visible before fixing. Prefer lint/typecheck before tests when the project supports it. For migration-type issues, also run the migration completeness scan required by the owning workflow. Projects with slow test suites can override in `copilot-instructions.md` by adding `<!-- slow-test-suite: true -->`, which splits Tier 1 into: (a) quick-validate, lint/typecheck, and targeted tests, then (b) the full test suite.
2. **Tier 2 — Structural validation**: run project architecture or structural validation commands defined by the repository.
3. **Tier 3 — Strength validation**: run configured coverage, robustness, or deeper confidence checks defined by the repository.
4. **Tier 4 — Independent review lane**: load [references/review-reconciliation.md](references/review-reconciliation.md) after the lower tiers pass. The owning agent keeps any CE Gate orchestration, post-fix routing, and specialist-dispatch authority that follows this tier.

Do not skip ahead when an earlier tier fails. Resolve failures at the current tier before advancing.

## Failure Triage Rule

When a validation tier fails, classify first, then route:

- `code defect` → route to the implementation specialist with failing evidence
- `test defect` → route to the testing specialist with failure analysis
- `harness/env defect` → route to the responsible tooling or environment path
- `rc-divergence` → run one dedicated correction cycle outside the main convergence budget: dispatch implementation first with the divergent acceptance-criteria items, re-run Tier 1, re-evaluate all acceptance-criteria items, then dispatch testing only if divergence persists and the assertions must be re-derived from the Requirement Contract rather than the corrected implementation

Always include the failure evidence, attempted diagnosis, and the next action in the handoff prompt. Avoid blind retries.

## Composite References

- [references/review-reconciliation.md](references/review-reconciliation.md): pre-review gate, prosecution-depth setup and use, fixed 3-pass review mechanics, non-GitHub review mode, improvement-first rule, AC cross-check, R4 batch dispatch, and the R2 post-fix review loop
- [references/post-judgment-routing.md](references/post-judgment-routing.md): post-judgment prosecution-depth re-activation detection and the paired routing index
- [../code-review-intake/references/express-lane.md](../code-review-intake/references/express-lane.md): canonical R6 express-lane gate, scope restriction, and Tier 1 re-validation requirement

## Review Heuristics At A Glance

- Complete the full prosecution to defense to judgment cycle before fix routing.
- Avoid blind retries; carry forward the failure evidence and current hypothesis with each re-delegation.
- Preserve the change-type classification and any prosecution-depth exclusions in every prosecution prompt.
- Keep merged-ledger deduplication evidence-based: same evidence at the same file and line collapses; materially different evidence remains additive.

## Boundaries

This skill does not decide:

- which agent speaks next
- when a step begins or ends
- how accepted findings are routed to specialists
- whether express-lane routing is available or how it dispatches
- when CE Gate orchestration or PR creation runs
- when review-mode entry, post-fix prosecution entry, or post-judgment follow-up occurs
- whether durable handoff state is written
- whether calibration or other write-back side effects occur

Keep those decisions in the owning agent.

## Gotchas

| Trigger                                                                                | Gotcha                                                                                                | Fix                                                                                                                                                                    |
| -------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Copying specialist routing, CE Gate ownership, or step-order decisions into this skill | The skill stops being reusable methodology and starts stealing orchestration authority from the agent | Keep routing, step execution flow, durable handoff ownership, and CE Gate orchestration in the owning agent; move only reusable validation and review method text here |
