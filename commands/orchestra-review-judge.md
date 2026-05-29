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

ARGUMENTS: $ARGUMENTS
