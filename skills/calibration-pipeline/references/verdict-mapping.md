# Pipeline Metrics Verdict Mapping

This reference owns the verdict-to-metric mapping details extracted from Code-Conductor's pipeline-metrics contract.

See [metrics-schema.md](metrics-schema.md) for the canonical block shape and [findings-construction.md](findings-construction.md) for findings-array construction and related metric-population rules.

## Verdict Mapping

Map verdicts from the judge's score summary table to the corresponding metric fields:

- **Main review**: `✅ Sustained` → `judge_accepted`; `❌ Defense sustained` → `judge_rejected`; `📋 DEFERRED-SIGNIFICANT` → `judge_deferred`
- **Post-fix review**: `✅ Sustained` → `postfix_judge_accepted`; `❌ Defense sustained` → `postfix_judge_rejected`; `📋 DEFERRED-SIGNIFICANT` → `postfix_judge_deferred`
