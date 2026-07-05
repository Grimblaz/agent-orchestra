<!-- markdownlint-disable-file MD041 MD003 -->

# Code-Conductor Credit-Emission Procedures

Extracted from `agents/Code-Conductor.agent.md` § Pipeline Metrics. These are the Code-Conductor-owned credit-row emission procedures that run at (or after) PR creation: pipeline-entry credit harvest, deferred-port credit rows, the `process-review` trigger-absent emission, and the post-PR credit row. Load this reference when assembling the `credits[]` block.

## Pipeline-Entry Credit Harvest (SMC-17)

As of issue #794 step s2, this harvest runs automatically **inside** the emit script's own logic — `Invoke-PipelineMetricsV4Emit` (`.github/scripts/lib/emit-pipeline-metrics-v4-core.ps1`) — rather than as a separate step Code-Conductor orchestrates before invoking the emit script. Code-Conductor's existing call to the emit script already passes `-IssueNumber`, so the harvest triggers with zero additional wiring needed on the conductor's part:

1. When `Invoke-PipelineMetricsV4Emit` is called with `-IssueNumber {ID}` greater than 0 and `-SkipMarkerHarvest` is **not** set, it internally resolves the repo (`-Repo`, or derived via `Resolve-EmitV4Repo`) and calls `Invoke-CreditInputHarvest -IssueNumber {ID} -Repo {owner/name} -GhCliPath {gh path} -MaxRetries 0` on Code-Conductor's behalf.
2. The harvester scans `<!-- credit-input-experience-{ID} -->`, `<!-- credit-input-design-{ID} -->`, and `<!-- credit-input-plan-{ID} -->` comments, parses their YAML payloads, and calls `Build-ExperienceCreditRow`, `Build-DesignCreditRow`, or `Build-PlanCreditRow` with the evidence from the payload.
3. The emit core merges the returned credit rows into the `credits[]` array alongside the review, release-hygiene, and other credits already composed. Deduplicate by port: if a credit row for a port is already present in the array (port-only dedup — harvested rows never carry a positive `terminal-step-id`), the harvested row for that port is skipped (additive-merge rule, D9).
4. Tests that exercise only the pre-existing accumulator/sentinel path should pass `-SkipMarkerHarvest` to bypass this branch entirely and avoid any `gh` involvement.

Code-Conductor's only remaining responsibility is to keep passing `-IssueNumber` on its existing emit-script call; no separate pre-emit harvest call is needed.

## Deferred Port Credit Rows

For any port whose `frame/ports/{port}.yaml` carries `trigger-status: deferred`, emit a deferred credit row at PR-creation time alongside the other credits:

1. Identify all ports with `trigger-status: deferred` by scanning `frame/ports/*.yaml`.
2. For each deferred port, call `Build-DeferredPortCreditRow -Port {name} -DeferredToIssue {N} -DeferredSince {date}` (parameters from the port YAML fields `trigger-deferred-to` and `trigger-deferred-since`).
3. Upsert the returned credit row into the `credits[]` array. Apply the additive-merge rule (D9): if a credit row for the port already exists, skip the upsert.

**`process-review` trigger-absent emission**: When `ceGate.defectsFound == 0` (CE Gate found no defects), emit the `process-review` trigger-absent credit at PR-creation time:

1. Read the `defects_found` field from the CE Gate surface credits in the pipeline-metrics block (sum across all `ce-gate-*` rows).
2. If the sum is 0, call `Build-ProcessReviewCreditRow -DefectsFound 0` and upsert the result (status: `not-applicable`) into `credits[]`.
3. If the sum is > 0, the Process-Review agent emits its own credit after Track-2 analysis completes — do not pre-emit.
4. If CE Gate data is unavailable, call `Build-ProcessReviewCreditRow -DefectsFound $null` (status: `skipped`) and upsert.

## Post-PR Credit Row (D10 category 3)

After the post-merge cleanup path completes (post-PR steps driven by `skills/post-pr-review/SKILL.md`), emit the `post-pr` credit row:

1. Collect the structured outcome hashtable from the post-pr-review skill per its "Structured Outcome Contract" section: `@{ archive = '...'; docs = '...'; version = '...'; releaseTag = '...' }`.
2. Call `Build-PostPrCreditRow -ChecklistOutcomes @{...}` with the outcome hashtable.
3. Upsert the returned credit row into the PR-body `<!-- pipeline-metrics -->` block's `credits[]` array.
4. Apply the additive-merge rule (D9): if a credit row for `post-pr` already exists in the block, skip the upsert.
