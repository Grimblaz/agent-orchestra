---
description: Run the lite Claude adversarial review pipeline for the current PR or supplied review target.
argument-hint: "[PR number, PR URL, or short review context]"
---

# /orchestra:review-lite

Run the compact review pipeline: one all-perspectives prosecution pass, then defense, then judge. The `lite` adapter runs the full prosecution, defense, and judge pipeline.

**Pre-flight**:

1. Resolve the review target from the arguments or the active PR context. If neither is available, use the `AskUserQuestion` tool.
2. Gather the diff, linked issue or plan context, and any prior review ledger that should travel with the prosecution prompt.

**Review-state persistence**:

The `lite` adapter runs the full prosecution, defense, and judge pipeline as one atomic sequence. After the terminal judge stage completes, write `/memories/session/review-state-{ISSUE_ID}.md` with `review_mode: lite`, `prosecution_complete: true`, `defense_complete: true`, `judgment_complete: true`, and an updated `last_updated` UTC timestamp.

**Shared dispatcher checklist**:

Read `skills/adversarial-review/platforms/claude.md` and follow its parent-side dispatcher checklist as a thin caller with adapter `lite`. Pass the resolved review target, diff, linked issue or plan context, prior review ledger, and active issue id if available as the pre-dispatch context. Return the Markdown score summary and the `judge-rulings` block unchanged so downstream callers can consume the judge verdict in the same payload.

**Post-judgment disposition gate**:

After the full prosecution → defense → judgment pipeline completes, load `skills/review-judgment/SKILL.md § Post-Judge Disposition Gate` and run the disposition pass over judge-sustained findings. Follow the same steps as `/orchestra:review-judge` Post-judgment disposition gate: stable-key derivation, same-decision-resume check, per-finding gate classification, L0 token emission, and atomic marker persistence (`<!-- review-dispositions-{PR} -->` then `<!-- engagement-record-review-{PR} -->`).

ARGUMENTS: $ARGUMENTS
