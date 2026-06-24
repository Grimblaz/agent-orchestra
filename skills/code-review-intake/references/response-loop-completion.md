<!-- markdownlint-disable-file MD041 MD003 -->

# Response Loop Completion (Terminal Step)

Extracted terminal-step sequence for the `code-review-intake` GitHub-intake response loop. Load this reference when completing a `/review-github` run after all judgment states reach terminal.

After all judgment states reach terminal, the GitHub-intake response loop completes with these ordered steps:

1. **Disposition gate** — honor the `<!-- review-dispositions-{PR} -->` marker: skip findings with `disposition: escalate`; only `disposition: incorporate` entries proceed.
2. **Batch Specialist Dispatch (R4)** — dispatch accepted findings to specialists (see `skills/validation-methodology/references/review-reconciliation.md § Batch Specialist Dispatch (R4)`).
3. **Post-fix targeted prosecution pass** — when triggered per the R2 conditions (see `skills/validation-methodology/references/review-reconciliation.md § Post-Fix Targeted Prosecution Pass`).
4. **CE Gate** — run the CE Gate when a customer surface is affected (see `agents/Code-Conductor.agent.md § Customer Experience Gate`).
5. **Persist changes** — fire `skills/persist-changes/SKILL.md` as the terminal step (see `### Response Commit & Push` in `skills/validation-methodology/references/review-reconciliation.md` for the SSOT contract). The executor commits fix files and pushes to the PR's head remote, or surfaces a loud not-pushed reason.
6. **Response Summary** — assemble and return the Response Summary per the shape in `skills/validation-methodology/references/review-reconciliation.md § Response Commit & Push`.

This step sequence is what makes a bare `/review-github` complete the full response loop — accepted fixes are applied, committed, and pushed to the existing PR branch without requiring an additional user instruction.

> **Invariant preserved**: the routing gate in the SKILL.md Gotchas table ("All items must reach terminal state… before any routing") applies to fix-dispatch routing only — this section documents the post-routing terminal completion steps.
