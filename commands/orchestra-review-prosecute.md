---
description: Run only the prosecution stage of the Claude adversarial review pipeline and return the prosecution ledger.
argument-hint: "[PR number, PR URL, or short review context]"
---

# /orchestra:review-prosecute

Run only the Code-Critic prosecution stage and return the resulting prosecution ledger as an intermediate stage artifact — input for a later `/orchestra:review-defend` run followed by `/orchestra:review-judge`, not a filtered or terminal verdict.

**Pre-flight**:

1. Resolve the review target from the arguments or the active PR context. If neither is available, use the `AskUserQuestion` tool.
2. Gather the diff, linked issue or plan context, and any prior review notes that should travel with the prosecution prompt.

**Review-state persistence**:

1. If the active branch matches `feature/issue-{N}-...`, target `/memories/session/review-state-{N}.md`; otherwise skip persistence silently.
2. Read any existing state through `skills/routing-tables/scripts/review-state-reader.ps1`. If the file is absent or malformed, fail closed and start from the default contract (`review_mode: full`, all stage booleans `false`).
3. After prosecution completes, write the same atomic front matter contract with only `prosecution_complete: true` forced in this command, preserve any readable stored values for the other fields, and update `last_updated`.
4. Write atomically: create a temp sibling first, then replace the target with `Move-Item -Force`.

**Stage-only prosecution override**:

Read `skills/adversarial-review/platforms/claude.md` and follow its parent-side dispatcher checklist as a thin caller for a standalone prosecution rerun. Reuse the standard code-review selector and prosecution-pass mechanics, but do not claim or execute the atomic multi-stage `standard` adapter contract: dispatch the five Code-Critic prosecution passes with `Review mode selector: "Use code review perspectives"`, merge the prosecution ledger per the shared dispatcher, then stop before defense and judge. Pass the resolved review target, diff, linked issue or plan context, prior review notes, active issue id if available, and review-state persistence target as the pre-dispatch context. Return the merged prosecution ledger unchanged as the intermediate stage artifact for a later `/orchestra:review-defend` → `/orchestra:review-judge` sequence.

ARGUMENTS: $ARGUMENTS
