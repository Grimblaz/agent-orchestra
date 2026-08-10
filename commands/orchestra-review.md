---
description: Run the standard Claude adversarial review pipeline for the current PR or supplied review target.
argument-hint: "[PR number, PR URL, or short review context]"
---

# /orchestra:review

Run the standard review pipeline: Code-Critic prosecution -> Code-Critic defense -> Code-Review-Response judge.

**Pre-flight**:

1. Resolve the review target from the arguments or the active PR context. If neither is available, ask for one.
2. Gather the diff, linked issue or plan context, and any prior review ledger that should travel with the prosecution prompt.

**Review-state persistence**:

Read `skills/adversarial-review/platforms/claude.md` and follow its parent-side dispatcher checklist as a thin caller with adapter `standard`. Pass the resolved review target, diff, linked issue or plan context, prior review ledger, active issue id if available, and review-state persistence target as the pre-dispatch context. Return the judge output unchanged so downstream callers can consume the Markdown score summary and the `judge-rulings` block in the same payload.

**Close-out record amendment**:

As soon as each judge pass's emission is in hand — and before the disposition gate below — load `skills/review-judgment/SKILL.md § Close-Out Record Amendment` and run that step as the owning parent. That section owns the trigger, the issue-resolution route, the write transport, and the outcome set; this command restates none of it and adds only the two facts it alone holds: the active issue id passed as pre-dispatch context above is what that section's route 2 reads, and its outcome is reported here as a `Close-out record amendment:` line appended to the returned judgment payload, immediately after the `judge-rulings` block. That line is this lane's named accountability channel; it is the parent's own addition and does not alter the judge output returned unchanged.

**Post-judgment disposition gate**:

After the full prosecution → defense → judgment pipeline completes, load `skills/review-judgment/SKILL.md § Post-Judge Disposition Gate` and run the disposition pass over judge-sustained findings. Follow the same steps as `/orchestra:review-judge` Post-judgment disposition gate: stable-key derivation, same-decision-resume check, per-finding gate classification, L0 token emission, and atomic marker persistence (`<!-- review-dispositions-{PR} -->` then `<!-- engagement-record-review-{PR} -->`). AC-refs: AC1, AC2.

ARGUMENTS: $ARGUMENTS
