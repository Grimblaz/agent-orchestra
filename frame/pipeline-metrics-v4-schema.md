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
  - port: experience
    status: passed
    evidence: "Short, audit-facing explanation of why the credit was assigned."
  - port: post-fix-review
    status: not-applicable
    evidence: "Trigger was absent, so no targeted post-fix review ran."
  - port: process-retrospective
    status: inconclusive
    evidence: "Port pending decision per umbrella sub-issue #11."
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
- `credits[].status` uses the explicit enum `passed | failed | skipped | not-applicable | inconclusive`.
- `integrity_checks[]` captures audit provenance and confidence checks for the synthetic ledger. The same five-value status enum applies here.
- Report-layer buckets preserve valid credit statuses, including a distinct `failed` bucket, while `missing` remains an absence bucket for ports with no credit entry.

## Forward Compatibility

Readers that understand v4 consume the inherited v3 metrics plus the frame additions above. Readers that only understand v3 continue to read the existing pipeline-metrics fields and ignore the extra frame keys. Readers that only understand v2 continue to consume the legacy fields they already know while treating missing later-version fields as absent rather than as parse errors.

## Out Of Scope

- Re-documenting inherited v1-v3 field semantics from `skills/calibration-pipeline/references/metrics-schema.md`
- Any enforcement, warning, or blocking behavior
- A runtime-evaluable trigger-condition DSL
- Adapter declarations or frontmatter changes outside the audit artifacts
