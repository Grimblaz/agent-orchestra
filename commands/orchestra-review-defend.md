---
description: Run only the defense stage of the Claude adversarial review pipeline against an existing prosecution ledger.
argument-hint: "[prosecution ledger context]"
---

# /orchestra:review-defend

Run only the Code-Critic defense stage against an existing prosecution ledger and return the defense report.

**Pre-flight**:

1. Require a prosecution ledger in the supplied arguments or conversation context. If it is missing, use the `AskUserQuestion` tool.
2. Gather any review target context that the defense pass needs for counter-evidence verification.

**Review-state persistence**:

1. If the active branch matches `feature/issue-{N}-...`, target `/memories/session/review-state-{N}.md`; otherwise skip persistence silently.
2. Read any existing state through `skills/routing-tables/scripts/review-state-reader.ps1`. If the file is absent or malformed, fail closed and start from the default contract (`review_mode: full`, all stage booleans `false`).
3. After defense completes, write the same atomic front matter contract with only `defense_complete: true` forced in this command, preserve any readable stored values for the other fields, and update `last_updated`.
4. Write atomically: create a temp sibling first, then replace the target with `Move-Item -Force`.

**Shared dispatcher checklist**:

Read `skills/adversarial-review/platforms/claude.md` and follow its parent-side dispatcher checklist as a thin caller using the defense-singleton flow: one Code-Critic defense dispatch, then stop before judge. Pass the prosecution ledger, review target context, active issue id if available, and review-state persistence target as the pre-dispatch context. Return the defense report unchanged.

ARGUMENTS: $ARGUMENTS
