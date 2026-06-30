# Pipeline Metrics — Conductor Protocol

> Extracted from `agents/Code-Conductor.agent.md ## Pipeline Metrics` via D5 compression.
> Authoritative source: this file. Update here; the agent body carries only the load pointer.

Load and follow these references:

- `skills/calibration-pipeline/references/metrics-schema.md` — authoritative for the inherited v3 base fields
- `skills/calibration-pipeline/references/verdict-mapping.md`
- `skills/calibration-pipeline/references/findings-construction.md`

Code-Conductor keeps only the emission timing and ownership boundary: at fresh PR creation time, the `.github/scripts/emit-pipeline-metrics-v4.ps1` script (called in the **Create PR** step above) owns `New-PipelineMetricsV4Block` invocation, `Test-PipelineMetricsV4Block` validation, and writing the body file — pass `-V3BaseYaml` (plain YAML string of v3 base fields; do not wrap in the HTML comment, do not include `metrics_version: 4`; the builder adds those), the accumulated `-Credits` / `-DispatchCostSamples` from the session-memory accumulator, and `-IssueNumber`. `Build-*CreditRow` outputs are `[pscustomobject]` rows — pass them directly, the builder normalizes them. The script is warn-only: if it exits non-zero, log the warning and proceed to `gh pr create` regardless (#429). On re-emit the initial-creation guard prevents double-wrapping; use additive-merge writers for updates after the initial PR exists.

After each `Build-*CreditRow` call that produces a credit row for the current issue, persist it to the file-based accumulator so `emit-pipeline-metrics-v4.ps1` can harvest it deterministically at PR creation time (issue #769 s-acc):

```powershell
. '.github/scripts/lib/Add-FCLCreditRow.ps1'
Add-FCLCreditRow -IssueNumber {ISSUE_NUMBER} -CreditRow $creditRow
```

This call is additive alongside the existing prose instruction — do not remove the `Build-*CreditRow` call itself. When `-IssueNumber` is provided to `emit-pipeline-metrics-v4.ps1` and no `-Credits` are passed explicitly, the script auto-harvests from `.tmp/issue-{N}/fclcredits.jsonl`.

**Output contract**: PR bodies must still include a `## Pipeline Metrics` section containing the `<!-- pipeline-metrics -->` block. The Create-PR emit step appends this automatically; do not remove the section from the PR body.

For v4 release-hygiene credit row construction (state-file reading, YAML examples) and the CE Gate S2 synthetic-PR test protocol, follow `skills/calibration-pipeline/references/release-hygiene-credit-emission.md`.

<!-- TODO: remove legacy v3 pipeline-metrics fallback at v2.9.0 when pre-v4 back-catalog backfill is confirmed complete (issue #441). -->

For v4 review credit row construction (parsing judge-rulings block, determining pass/fail status, building the credit row), follow `skills/calibration-pipeline/references/review-credit-emission.md`.

Dispatch-cost samples are additive v4 instrumentation owned by Code-Conductor. During implementation, placeholders and pre-PR RC/judge updates live in the same session-memory or PR-body draft accumulator used to build the initial PR body. PR creation flushes that accumulator into the emitted `<!-- pipeline-metrics -->` block. After PR creation, RC conformance and judge disposition back-fills update the live PR body only for the targeted `(step-id, mode)` sample.

For the Code-Conductor-owned credit-row emission procedures — Pipeline-Entry Credit Harvest (SMC-17), Deferred Port Credit Rows, the `process-review` trigger-absent emission, and the Post-PR Credit Row (D10 category 3) — load and follow `skills/calibration-pipeline/references/conductor-credit-emission.md`. Harvest pipeline-entry credits before emitting the `credits[]` block at PR creation; emit deferred-port and post-PR rows per the reference; apply the additive-merge rule (D9) on every upsert.
