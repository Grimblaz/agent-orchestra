# Pipeline Metrics v4 Schema

## Why v4, not v3

Frame ledger data starts at `metrics_version: 4` because v3 was already claimed by issue #417 / PR #423 for review-mode, stage-run, and prosecution-depth additions. The frame extension is additive on top of that schema rather than a rewrite of the inherited pipeline-metrics contract.

## Scope And Inherited Schema Boundary

This document owns only the frame-specific audit additions introduced with v4. The inherited pipeline-metrics fields, including the existing `findings:` array and all v1-v3 semantics, remain authoritative in `skills/calibration-pipeline/references/metrics-schema.md`.

The v4 surface is audit-only. It records synthetic frame credits and integrity metadata for historical analysis without introducing adapter duplication, enforcement behavior, or a runtime trigger grammar.

## v4 Additions

The v4 extension adds these fields alongside the inherited v3 block:

```yaml
metrics_version: 4
frame_version: 1
credits:
  - port: review
    adapter: standard
    status: passed
    run_index: 1
    evidence: "Full prosecution × 3 → defense → judge completed; judge ruling passed."
    judge-score:
      ruling: passed
      findings: []
    integrity-check:
      pass-blocks: [1, 2, 3]
      status: passed
  - port: release-hygiene
    adapter: symmetric-bump
    status: passed
    run_index: 1
    evidence: "All four manifest files updated to the same version."
    version-bump:
      from: "1.2.0"
      to: "1.3.0"
    symmetric-bump-verification:
      status: passed
      files-checked: ["plugin.json", ".claude-plugin/plugin.json", ".claude-plugin/marketplace.json", "README.md"]
  - port: post-fix-review
    adapter: post-fix
    status: not-applicable
    run_index: 1
    evidence: "Trigger was absent — no sustained Critical/High finding in prior review."
    trigger:
      predicate: "review.sustainedCriticalOrHigh == true"
      evaluated: false
  - port: experience
    status: passed
    evidence: "Short, audit-facing explanation of why the credit was assigned."
  - port: process-retrospective
    status: inconclusive
    evidence: "Port pending decision per umbrella sub-issue #11."
  - port: review
    adapter: standard
    status: not-persisted
    run_index: 2
    evidence: "Sentinel <!-- review-judge-produced-{PR} --> present but no credit row written."
    mode:
      synthetic-backfill:
        backfilled_at: "2026-05-01T00:00:00Z"
        original_pr_merged_at: "2025-03-15T12:34:56Z"
integrity_checks:
  - name: linked-issue-resolution
    status: passed
    evidence: "closingIssuesReferences or fallback issue extraction resolved successfully."
  - name: adapter-selection-evidence
    status: inconclusive
    evidence: "The PR body did not encode enough surface detail to infer every adapter-level credit."
```

Field notes:

- `frame_version` tracks the frame-specific additive schema independently from the inherited v1-v3 pipeline-metrics history.
- `credits[]` is the audit ledger. Each entry records a `port`, a frame credit `status`, and brief audit evidence.
- `credits[].status` uses the explicit enum `passed | failed | skipped | not-applicable | inconclusive | not-persisted`.
  - `not-persisted` is synthesized by the warn-only hook when the sentinel `<!-- review-judge-produced-{PR} -->` is present but no credit row was written. It is never emitted directly as an inline credit.
- `credits[].adapter` (optional on non-review ports) names the specific adapter that produced this credit row.
- `credits[].run_index` is a monotonically increasing integer per `(port, adapter)` pair. Multiple entries for the same port and adapter are appended; the latest by `run_index` is the authoritative summary value. There is no `timestamp` field on credit rows — `run_index` provides re-run ordering without violating the audit-only framing.
- `credits[].judge-score` (review port only) carries the judge ruling and findings list used to produce the credit.
- `credits[].integrity-check` (review port, standard/lite adapters) records the pass-blocks verified during prosecution.
- `credits[].version-bump` (release-hygiene port) records the version range for which the bump was verified.
- `credits[].symmetric-bump-verification` (release-hygiene port) records the symmetric-bump verifier result and file set checked.
- `credits[].trigger` (post-fix-review port) records the predicate and its evaluated result.
- `credits[].mode.synthetic-backfill` is present on rows produced by historical reconstruction (backfill). It carries two ISO-8601 UTC timestamps: `backfilled_at` (when the row was written to the PR body) and `original_pr_merged_at` (when the PR originally merged). Audit consumers use these to distinguish reconstructions from real-time emissions.
- `integrity_checks[]` captures audit provenance and confidence checks for the synthetic ledger. The same six-value status enum applies here.
- Report-layer buckets preserve valid credit statuses, including a distinct `failed` bucket and `not-persisted` for detected-but-not-written review runs, while `missing` remains an absence bucket for ports with no credit entry.

## Forward Compatibility

Readers that understand v4 consume the inherited v3 metrics plus the frame additions above. Readers that only understand v3 continue to read the existing pipeline-metrics fields and ignore the extra frame keys. Readers that only understand v2 continue to consume the legacy fields they already know while treating missing later-version fields as absent rather than as parse errors.

## Out Of Scope

- Re-documenting inherited v1-v3 field semantics from `skills/calibration-pipeline/references/metrics-schema.md`
- Any enforcement, warning, or blocking behavior
- A runtime-evaluable trigger-condition DSL
- Adapter declarations or frontmatter changes outside the audit artifacts
