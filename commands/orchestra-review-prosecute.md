---
description: Run only the prosecution stage of the Claude adversarial review pipeline and return the prosecution ledger.
argument-hint: "[PR number, PR URL, or short review context]"
---

# /orchestra:review-prosecute

Run only the Code-Critic prosecution stage and return the resulting prosecution ledger for later defense or judge reruns.

**Pre-flight**:

1. Resolve the review target from the arguments or the active PR context. If neither is available, use the `AskUserQuestion` tool.
2. Gather the diff, linked issue or plan context, and any prior review notes that should travel with the prosecution prompt.

**Review-state persistence**:

1. If the active branch matches `feature/issue-{N}-...`, target `/memories/session/review-state-{N}.md`; otherwise skip persistence silently.
2. Read any existing state through `skills/routing-tables/scripts/review-state-reader.ps1`. If the file is absent or malformed, fail closed and start from the default contract (`review_mode: full`, all stage booleans `false`).
3. After prosecution completes, write the same atomic front matter contract with only `prosecution_complete: true` forced in this command, preserve any readable stored values for the other fields, and update `last_updated`.
4. Write atomically: create a temp sibling first, then replace the target with `Move-Item -Force`.

**Singleton dispatch shape**:

Read `skills/adversarial-review/platforms/claude.md` and follow its parent-side dispatcher checklist as a thin caller using the singleton prosecution shape: one Code-Critic prosecution dispatch with the standard code-review selector, then stop before defense and judge. Pass the resolved review target, diff, linked issue or plan context, prior review notes, active issue id if available, and review-state persistence target as the pre-dispatch context. Return the prosecution ledger unchanged.

ARGUMENTS: $ARGUMENTS
