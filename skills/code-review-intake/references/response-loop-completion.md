<!-- markdownlint-disable-file MD041 MD003 -->

# Response Loop Completion (Terminal Step)

Extracted terminal-step sequence for the `code-review-intake` GitHub-intake response loop. Load this reference when completing a `/review-github` run after all judgment states reach terminal.

After all judgment states reach terminal, the GitHub-intake response loop completes with these ordered steps:

1. **Post-Judge Disposition Gate** — after each judge pass reaches terminal state (the main judge pass, and the post-fix targeted prosecution pass's own defense → judge cycle — see `skills/validation-methodology/references/review-reconciliation.md § Post-Fix Targeted Prosecution Pass`, lines 155-185), run the Post-Judge Disposition Gate (`skills/review-judgment/SKILL.md § Post-Judge Disposition Gate`) over that pass's judge-sustained findings. This response loop always runs in GitHub Review Mode (a session property, not derived from entry presence — `skills/review-judgment/SKILL.md:286`), so emit the PR-level `external_sources_reconciled` field on the dispositions marker even when empty (`external_sources_reconciled: []`); a genuine zero-finding external reconciliation is a required M9 coverage record, not an omission. A zero-sustained judge pass still emits both markers below, with `entries: []` on the dispositions marker.

   Persist, in order (`skills/review-judgment/SKILL.md § Persistence — Ordering`):

   1. `<!-- review-dispositions-{PR} -->`
   2. `<!-- engagement-record-review-{PR} -->`

   Emission runs **once per judge pass**: once after the main judge pass reaches terminal, and again after the post-fix judge pass (§ Post-Fix Targeted Prosecution Pass, above) reaches terminal — this repeated firing is new; the prior version of this step fired only once, against the main pass.

   Idempotency is scoped to the `stable_finding_key`, not to the pass: `skills/review-judgment/SKILL.md § Stable-Key Resume` (around line 402-411 — not the Stable Finding Key definition around line 254-262) governs resume, detecting prior dispositions and skipping re-asking already-gated findings whether the resumed pass is main or post-fix.

   Immediately after both markers persist, run Post-Judgment Re-Activation Detection (`skills/validation-methodology/references/post-judgment-routing.md:19-34`), preserving the ordering invariant **disposition gate → re-activation detection → fix routing** (`post-judgment-routing.md:17`). Only once re-activation detection completes does fix routing begin — step 2 (Batch Specialist Dispatch) for the main pass, or the post-fix pass's own routing back into step 3, for the post-fix pass.

   Skip findings with `disposition: escalate`; only `disposition: incorporate` entries proceed to fix routing.

   A failed post of either marker never halts the loop — emit the corresponding loud literal and continue, carrying it into the Response Summary (step 6):

   - `⚠️ review-dispositions-{PR} not posted — {reason}`
   - `⚠️ engagement-record-review-{PR} not posted — {reason}`
2. **Batch Specialist Dispatch (R4)** — dispatch accepted findings to specialists (see `skills/validation-methodology/references/review-reconciliation.md § Batch Specialist Dispatch (R4)`).
3. **Post-fix targeted prosecution pass** — when triggered per the R2 conditions (see `skills/validation-methodology/references/review-reconciliation.md § Post-Fix Targeted Prosecution Pass`). This pass's defense → judge cycle re-enters step 1's Post-Judge Disposition Gate — see step 1 above.
4. **CE Gate** — run the CE Gate when a customer surface is affected (see `agents/Code-Conductor.agent.md § Customer Experience Gate`).
5. **Persist changes** — fire `skills/persist-changes/SKILL.md` as the terminal step (see `### Response Commit & Push` in `skills/validation-methodology/references/review-reconciliation.md` for the SSOT contract). The executor commits fix files and pushes to the PR's head remote, or surfaces a loud not-pushed reason.
6. **Response Summary** — assemble and return the Response Summary per the shape in `skills/validation-methodology/references/review-reconciliation.md § Response Commit & Push`.

This step sequence is what makes a bare `/review-github` complete the full response loop — accepted fixes are applied, committed, and pushed to the existing PR branch without requiring an additional user instruction.

> **Invariant preserved**: the routing gate in the SKILL.md Gotchas table ("All items must reach terminal state… before any routing") applies to fix-dispatch routing only — this section documents both the pre-routing Post-Judge Disposition Gate (step 1, which runs *before* fix routing) and the post-routing terminal completion steps (steps 2-6), not post-routing steps alone.
