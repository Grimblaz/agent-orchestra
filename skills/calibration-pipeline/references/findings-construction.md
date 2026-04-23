# Pipeline Metrics Findings Construction

This reference owns findings-array construction and related metric-population rules extracted from Code-Conductor's pipeline-metrics contract.

See [metrics-schema.md](metrics-schema.md) for the canonical YAML block and [verdict-mapping.md](verdict-mapping.md) for judge-to-metric field mapping.

## Findings Array

Construct the `findings:` array by reading Code-Review-Response's `<!-- judge-rulings -->` YAML block and merging with prosecution ledger data (`id`, `category`, `severity`, `points`, `pass`) and defense report (`defense_verdict`). Set `review_stage` to the active pipeline stage: `main` for main code review, `postfix` for post-fix targeted prosecution, `ce` for CE prosecution, `design` for design prosecution, `proxy` for GitHub review intake (proxy prosecution). If `<!-- judge-rulings -->` is absent, parse the Markdown score summary table as fallback data source.

For `findings:` array: emit as an empty list (`findings: []`) when no findings exist. For proxy prosecution (GitHub review intake), include all validated GitHub findings with `review_stage: proxy`. `express_lane: true` is present in the findings array only for express-laned items — absence means the item went through the full prosecution→defense→judge pipeline. `systemic_fix_type` defaults to `none` when absent — older PRs and findings without root cause tagging are handled gracefully by downstream consumers.

## Rework Cycle Metrics

**`rework_cycles`**: Count of fix-revalidate loops after routing accepted review findings to specialists (main review fix loops only — not CE Gate loops or post-fix review loops; those are tracked in `postfix_rework_cycles`). Each route-to-specialist → implement → re-validate cycle = 1. If no findings accepted, `rework_cycles: 0`.

**`postfix_rework_cycles`**: Count of fix-revalidate loops during the post-fix targeted prosecution phase (post-fix fix loops only). Each route-to-specialist → implement → re-validate cycle = 1; loop budget is 1. If post-fix prosecution was not triggered, `postfix_rework_cycles: n/a`. If judge accepted zero findings (triggered but clean), `postfix_rework_cycles: 0`.

## Backward Compatibility

PRs without a `metrics_version` field are version 1 (aggregate counts only). The aggregation script handles both formats gracefully; old PRs contribute aggregate counts, new PRs contribute per-finding detail.

## Malformed Entries

If a finding entry is incomplete (missing required fields), omit the malformed entry from the array and emit a warning comment in the PR body: `<!-- warning: finding {id} omitted from metrics due to incomplete data -->`.
