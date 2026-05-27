---
description: Run the standard Claude adversarial review pipeline for the current PR or supplied review target.
argument-hint: "[PR number, PR URL, or short review context]"
---

# /orchestra:review

Run the standard review pipeline: Code-Critic prosecution -> Code-Critic defense -> Code-Review-Response judge.

**Pre-flight**:

1. Resolve the review target from the arguments or the active PR context. If neither is available, use the `AskUserQuestion` tool.
2. Gather the diff, linked issue or plan context, and any prior review ledger that should travel with the prosecution prompt.

**Review-state persistence**:

Read `skills/adversarial-review/platforms/claude.md` and follow its parent-side dispatcher checklist as a thin caller with adapter `standard`. Pass the resolved review target, diff, linked issue or plan context, prior review ledger, active issue id if available, and review-state persistence target as the pre-dispatch context. Return the judge output unchanged so downstream callers can consume the Markdown score summary and the `judge-rulings` block in the same payload.

ARGUMENTS: $ARGUMENTS
