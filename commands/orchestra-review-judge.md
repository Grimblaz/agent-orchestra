---
description: Run only the judge stage of the Claude adversarial review pipeline against existing prosecution and defense ledgers.
argument-hint: "[prosecution ledger plus defense report]"
---

# /orchestra:review-judge

Run only the Code-Review-Response judge stage against existing prosecution and defense ledgers and return the final judgment payload.

**Pre-flight**:

1. Require both a prosecution ledger and a defense report in the supplied arguments or conversation context. If either is missing, use the `AskUserQuestion` tool.
2. Gather any review target context that the judge needs for independent verification.

**Review-state persistence**:

1. If the active branch matches `feature/issue-{N}-...`, target `/memories/session/review-state-{N}.md`; otherwise skip persistence silently.
2. Read any existing state through `skills/routing-tables/scripts/review-state-reader.ps1`. If the file is absent or malformed, fail closed and start from the default contract (`review_mode: full`, all stage booleans `false`).
3. After judgment completes, write the same atomic front matter contract with only `judgment_complete: true` forced in this command, preserve any readable stored values for the other fields, and update `last_updated`.
4. Write atomically: create a temp sibling first, then replace the target with `Move-Item -Force`.

**Shared dispatcher checklist**:

Read `skills/adversarial-review/platforms/claude.md` and follow its parent-side dispatcher checklist as a thin caller with adapter `judge-only`. Pass the prosecution ledger, defense report, review target context, active issue id if available, existing review state, and review-state persistence target as the pre-dispatch context. Return the Markdown score summary and the `judge-rulings` block unchanged in the same payload.

**Post-judgment disposition gate**:

After the judge emits the `<!-- review-judge-produced-{PR} -->` sentinel and the judge-rulings comment, load `skills/review-judgment/SKILL.md § Post-Judge Disposition Gate` and run the full disposition pass over judge-sustained findings (`judge_ruling: sustained`). Defense-sustained findings are skipped silently. Steps in order:

1. Compute a `stable_finding_key` for each sustained finding per the Stable Finding Key derivation rules.
2. Call `Read-EngagementRecords -Phase review -PullRequestNumber {PR}` to check for prior dispositions (same-decision-resume).
3. Run the solution-authoring classification gate per finding. Routine findings record silently; load-bearing findings fire `AskUserQuestion` with the escalation-tier decision brief and options: Incorporate / Dismiss / Escalate / Decline engagement.
4. Emit one L0 gate-decision token per finding per `skills/solution-authoring/SKILL.md` § L0 Gate Token (authoritative path: `/memories/session/gate-events-{session_key}.jsonl`, fallback: `.copilot-tracking/gate-events.jsonl`) with `window_position: review-disposition` and `pull_request_number: {PR}`.
5. Persist **in order**: (a) `<!-- review-dispositions-{PR} -->` PR comment, then (b) `<!-- engagement-record-review-{PR} -->` PR comment.

AC-refs: AC1, AC3, AC4, AC5, AC6, AC7.

ARGUMENTS: $ARGUMENTS
