---
description: Run the lite Claude adversarial review pipeline for the current PR or supplied review target.
argument-hint: "[PR number, PR URL, or short review context]"
---

# /orchestra:review-lite

Run the compact review pipeline: one all-perspectives prosecution pass.

**Pre-flight**:

1. Resolve the review target from the arguments or the active PR context. If neither is available, use the `AskUserQuestion` tool.
2. Gather the diff, linked issue or plan context, and any prior review ledger that should travel with the prosecution prompt.

**Review-state persistence**:

The `lite` adapter is prosecution-only. It does not write terminal review-state persistence unless a caller explicitly adds extra terminal stages outside this adapter contract.

**Shared dispatcher checklist**:

Read `skills/adversarial-review/platforms/claude.md` and follow its parent-side dispatcher checklist as a thin caller with adapter `lite`. Pass the resolved review target, diff, linked issue or plan context, prior review ledger, and active issue id if available as the pre-dispatch context. Return the prosecution ledger unchanged.

ARGUMENTS: $ARGUMENTS
