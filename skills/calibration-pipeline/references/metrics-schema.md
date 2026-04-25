# Pipeline Metrics Schema

This reference owns the `## Pipeline Metrics` schema and top-level field semantics extracted from Code-Conductor.

See [verdict-mapping.md](verdict-mapping.md) for judge-to-metric mapping details and [findings-construction.md](findings-construction.md) for findings-array construction, backward compatibility, malformed-entry handling, and related metric-construction rules.

## PR Body Pipeline Metrics

Always include a `## Pipeline Metrics` section in the PR body with a hidden HTML comment block containing pipeline telemetry. Emit this at PR creation time after the full pipeline completes. Count values from the post-deduplication merged ledger (not raw per-pass totals). `pass_1_findings + pass_2_findings + pass_3_findings = prosecution_findings`. Fields `prosecution_findings` through `rework_cycles` cover the **main review cycle only**; `postfix_*` fields cover the post-fix targeted prosecution separately.

```markdown
## Pipeline Metrics

<!-- pipeline-metrics
metrics_version: 3
review_mode: {full|lite}
stages_run:
  prosecution: {true|false}
  defense: {true|false}
  judgment: {true|false}
prosecution_findings: {N}
pass_1_findings: {N}
pass_2_findings: {N}
pass_3_findings: {N}
defense_disproved: {N}
judge_accepted: {N}
judge_rejected: {N}
judge_deferred: {N}
ce_gate_result: {passed|skipped|not-applicable}
ce_gate_intent: {strong|partial|weak|n/a}
ce_gate_defects_found: {N}
rework_cycles: {N}
postfix_triggered: {true|false}
postfix_prosecution_findings: {N}
postfix_judge_accepted: {N}
postfix_judge_rejected: {N}
postfix_judge_deferred: {N}
postfix_defense_disproved: {N}
postfix_rework_cycles: {N}
express_lane_count: {N}
postfix_passes: {1|2|n/a}
batch_dispatch_calls: {N}
batch_dispatch_findings: {N}
rate_limit_retries: {N}
rate_limit_deferred: {true|false}
prosecution_depth_light: []  # list of category names at light depth
prosecution_depth_skip: []   # list of category names at skip depth
prosecution_depth_override: false  # true if global override was active
prosecution_depth_reactivations: 0  # count of re-activation events written via write-calibration-entry.ps1 -ReactivationEventJson during this PR (from Post-Judgment or CE/Proxy re-activation detection); 0 when no events are written
findings:
  - id: F1
    category: documentation-audit
    severity: low
    points: 1
    pass: 1
    review_stage: main
    systemic_fix_type: none
    express_lane: true  # optional — present only for express-laned findings; defense_verdict and judge_ruling are absent because express-laned findings bypass defense and judge (scripts default judge_ruling to "finding-sustained" for backward compat)
    judge_ruling: finding-sustained
  - id: F2
    category: performance
    severity: medium
    points: 5
    pass: 2
    defense_verdict: disproved
    judge_ruling: defense-sustained
    judge_confidence: medium
    systemic_fix_type: instruction  # always present for current findings; absent only in pre-adoption pipeline-metrics data (backward compat: defaults to none when absent)
    review_stage: main
  - id: F3
    category: documentation-audit
    severity: low
    points: 1
    pass: 1
    review_stage: postfix
    systemic_fix_type: none
    express_lane: true  # post-fix targeted prosecution express-lane example
    judge_ruling: finding-sustained
-->
```

## Top-Level Field Reference

`0` for numeric fields when the stage ran but found nothing. `n/a` for categorical fields when the stage was skipped entirely (e.g., `ce_gate_result: not-applicable`, `ce_gate_intent: n/a` when `ce_gate: false`). `review_mode` defaults to `full` for older metrics blocks that predate `metrics_version: 3`. `stages_run` defaults to all `true` for pre-v3 metrics because older PR-body metrics only represented completed review pipelines. `ce_gate_defects_found: n/a` when the CE Gate did not run (`ce_gate: false` or `⏭️ CE Gate not applicable`). For proxy prosecution (GitHub review intake): `pass_1_findings`, `pass_2_findings`, `pass_3_findings` → `n/a` (3-pass structure replaced by proxy pass); route total findings count to `prosecution_findings` only. `postfix_*` numeric fields default to `0` when post-fix review was triggered but found nothing; `n/a` when not triggered (`postfix_triggered: false`). Set `postfix_triggered: true` when trigger conditions are met and post-fix prosecution executes (regardless of whether any findings were accepted). New optimization fields: `express_lane_count`, `batch_dispatch_calls`, `batch_dispatch_findings`, `rate_limit_retries` default to `0` when the stage ran; `n/a` when the relevant phase was not active for the current review mode (e.g., `express_lane_count: n/a` for proxy, CE, or design review; `batch_dispatch_calls`/`batch_dispatch_findings: n/a` only for review modes where specialist dispatch is not active — such as standalone design-review flows that stop after prosecution). `postfix_passes` defaults to `n/a` when post-fix review was not triggered; `1` or `2` to reflect actual passes run. `rate_limit_deferred` defaults to `false`. `prosecution_depth_light` and `prosecution_depth_skip` default to empty lists `[]` when no categories are at those depths. `prosecution_depth_override` defaults to `false`. `prosecution_depth_reactivations` defaults to `0` (no re-activation events written via `write-calibration-entry.ps1 -ReactivationEventJson` during this PR; incremented by the Post-Judgment and CE/Proxy re-activation detection steps).

### Calibration Data Write (VS Code Copilot only)

After creating the PR body with the `<!-- pipeline-metrics -->` block, invoke the write script to persist calibration data locally. This is a VS Code Copilot optimization (calibration data can instead accumulate via backfill or the aggregate script's GitHub PR body path).

```powershell
# Test-Path guard — template portability for downstream repos without the write script
if (Test-Path skills/calibration-pipeline/scripts/write-calibration-entry.ps1) {
    $entryJson = @{
        pr_number  = <PR number as integer>
        created_at = ([System.DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))
        findings   = @(
            # One object per finding from the judge's <!-- judge-rulings --> block:
            @{
                id           = '<finding id>'
                category     = '<category>'
                judge_ruling = '<sustained|defense-sustained>'
                # Optional fields (include when present):
                review_stage    = '<main|postfix|ce|design|proxy>'
                defense_verdict = '<conceded|disproved>'
                judge_confidence = '<high|medium|low>'
                systemic_fix_type = '<type if present>'
            }
        )
        summary = @{
            prosecution_findings = <N>
            pass_1_findings      = <N>
            pass_2_findings      = <N>
            pass_3_findings      = <N>
            defense_disproved    = <N>
            judge_accepted       = <N>
            judge_rejected       = <N>
            judge_deferred       = <N>
            express_lane_count    = <N>
            postfix_passes        = '<1|2|n/a>'
            batch_dispatch_calls  = <N>
            batch_dispatch_findings = <N>
            rate_limit_retries    = <N>
            rate_limit_deferred   = $<true|false>
        }
    } | ConvertTo-Json -Depth 10 -Compress
    # -NoProfile prevents user profile scripts from interfering with unattended execution
   pwsh -NoProfile -NonInteractive -File skills/calibration-pipeline/scripts/write-calibration-entry.ps1 -EntryJson $entryJson
    if ($LASTEXITCODE -ne 0) { Write-Warning "Calibration write failed (non-fatal) — exit code $LASTEXITCODE" }
}
```

**Timing note**: Use `created_at` (current timestamp at write time — the PR is not merged yet). The aggregate script uses GitHub's `mergedAt` for decay weighting.

**Write failure is non-fatal**: If the write script fails, log a warning but do not block PR creation.
