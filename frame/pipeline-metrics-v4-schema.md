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
    evidence: "All five manifest files updated to the same version."
    version-bump:
      from: "1.2.0"
      to: "1.3.0"
    symmetric-bump-verification:
      status: passed
      files-checked: ["plugin.json", ".claude-plugin/plugin.json", ".claude-plugin/marketplace.json", ".github/plugin/marketplace.json", "README.md"]
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
  - port: ce-gate-cli
    status: inconclusive
    block_kind: environment
    evidence: "CE Gate for cli surface blocked — no local Claude CLI binary in test runner."
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
- `credits[].mode.synthetic-backfill` is present on rows produced by historical reconstruction (backfill). It is a **nested object** (not a boolean) carrying two ISO-8601 UTC timestamps: `backfilled_at` (when the row was written to the PR body) and `original_pr_merged_at` (when the PR originally merged). Audit consumers use these to distinguish reconstructions from real-time emissions.
- `credits[].block_kind` (CE Gate ports only) is present on rows with `status: inconclusive` that were blocked by an environmental or tooling constraint. Enum: `environment | tooling | runtime | orchestration`. This field is absent on `not-applicable`, `passed`, `failed`, and `skipped` rows, and on non-CE-Gate ports. Forward-emitted CE Gate `inconclusive` rows carry `block_kind`; back-derived `inconclusive` rows (from the synthetic back-deriver) do not, since the original blockage reason cannot be reconstructed.
- `integrity_checks[]` captures audit provenance and confidence checks for the synthetic ledger. The same six-value status enum applies here.
- Report-layer buckets preserve valid credit statuses, including a distinct `failed` bucket and `not-persisted` for detected-but-not-written review runs, while `missing` remains an absence bucket for ports with no credit entry.

## Additive-Merge Rule (D9)

When the back-deriver runs against a PR body that already contains a partial v4 `credits[]` block (i.e., some ports are present but not all twelve), the merge rule is:

- **Back-deriver fills only absent ports.** If a port row already exists in the `credits[]` array, the back-deriver does not overwrite or duplicate it — that port's row is authoritative as written.
- **Presence of a port row short-circuits back-derivation for that port only.** Other absent ports are still back-derived normally.
- **No double-write.** The back-deriver never appends a second row for a port that already has at least one entry.

This ensures forward-emitted rows (from specialist agents or pipeline-entry deferred emission) are preserved as-is while the back-deriver fills the gaps.

## Forward Compatibility

Readers that understand v4 consume the inherited v3 metrics plus the frame additions above. Readers that only understand v3 continue to read the existing pipeline-metrics fields and ignore the extra frame keys. Readers that only understand v2 continue to consume the legacy fields they already know while treating missing later-version fields as absent rather than as parse errors.

## Out Of Scope

- Re-documenting inherited v1-v3 field semantics from `skills/calibration-pipeline/references/metrics-schema.md`
- Any enforcement, warning, or blocking behavior
- A runtime-evaluable trigger-condition DSL
- Adapter declarations or frontmatter changes outside the audit artifacts
