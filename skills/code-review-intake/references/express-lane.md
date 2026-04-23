# Express Lane Gate (R6)

This reference owns the reusable express-lane gate details that pair with review reconciliation while remaining outside GitHub proxy-prosecution execution.

See [../../validation-methodology/references/review-reconciliation.md](../../validation-methodology/references/review-reconciliation.md) for the main review-reconciliation loop that can hand findings into this gate.

## Express Lane Gate (R6, Standard and Post-Fix Code Review Only)

After merging and deduplicating the prosecution ledger, partition findings before the defense pass.

Load `skills/routing-tables/SKILL.md` and evaluate the canonical six-condition express-lane gate with `Test-GateCriteria -Gate express_lane -Criteria @{ ... }`. The authoritative criteria and default non-qualifying outcome live in `skills/routing-tables/assets/gate-criteria.json`.

Route express-eligible findings directly to the specialist dispatch queue with an `express_lane: true` marker. All remaining findings continue to the defense -> judge pipeline as normal.

**Scope restriction**: Express lane applies to **standard code review prosecution and post-fix targeted prosecution only** - it does NOT apply to proxy prosecution (GitHub review intake), CE prosecution, or design/plan review prosecution. (In proxy prosecution sessions, Code-Conductor does not have access to the diff context required to verify criteria 2 and 3. R4 and R5 still apply to proxy prosecution sessions.)

**Tier 1 re-validation required**: After the specialist applies an express-lane fix, re-run Tier 1 validation (build + lint/typecheck + tests) before proceeding. (When batched under R4, Tier 1 re-validation runs once after all express-lane specialist fixes in the batch are applied.) If Tier 1 fails, route the failure via the Failure Triage Rule and resolve it before proceeding.
