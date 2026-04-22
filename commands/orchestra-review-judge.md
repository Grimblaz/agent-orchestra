---
description: Run only the judge stage of the Claude adversarial review pipeline against existing prosecution and defense ledgers.
argument-hint: "[prosecution ledger plus defense report]"
---

# /orchestra:review-judge

Run only the Code-Review-Response judge stage against existing prosecution and defense ledgers and return the final judgment payload.

**Pre-flight**:

1. Require both a prosecution ledger and a defense report in the supplied arguments or conversation context. If either is missing, use the `AskUserQuestion` tool.
2. Gather any review target context that the judge needs for independent verification.

**Optional handshake context**:

If the ingested ledgers make tree-grounded claims and you want the judge prompt to carry the parent's current repo state, you may construct the same `<!-- subagent-env-handshake v1 -->` block described in `commands/plan.md` and prepend it to the judge prompt. This is optional for `/orchestra:review-judge`: the `code-review-response` Claude shell does not run a Step 0 verifier, so the handshake is contextual only, not a gating precondition.

**Dispatch**:

1. Use the `Agent` tool with `subagent_type: code-review-response`.
2. Pass the prosecution ledger and defense report together in one prompt.
3. Return the Markdown score summary, the `<!-- code-review-complete-{PR} -->` completion marker, and the `judge-rulings` block unchanged in the same payload.

ARGUMENTS: $ARGUMENTS
