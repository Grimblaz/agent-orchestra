# Design: Frame Audit Ledger

## Summary

Issue #426 adds an audit-only frame ledger surface for Grimblaz/agent-orchestra. The implementation introduces a 17-port manifest under `frame/ports`, a v4 additive schema extension in `frame/pipeline-metrics-v4-schema.md`, a historical back-derivation library and wrapper, and an era-split audit report for maintainers.

This design exists to explain the current shipped behavior at the domain level. It does not replace the inherited pipeline-metrics schema reference, and it does not turn the frame surface into an enforcement mechanism.

## Implemented Surfaces

| Surface | Current Role |
| --- | --- |
| `frame/ports/*.yaml` | Declares the frame audit manifest, including applicability and port status metadata |
| `frame/pipeline-metrics-v4-schema.md` | Defines the additive v4 frame fields layered on top of inherited pipeline-metrics data |
| `frame/audit-fixtures/*.expected.yaml` | Pins expected historical replay output for representative PRs across metrics versions 1-4 |
| `.github/scripts/frame-back-derive.ps1` | Thin wrapper for historical back-derivation of one PR into a frame audit ledger |
| `.github/scripts/lib/frame-back-derive-core.ps1` | Owns the historical derivation rules and audit-surface output |
| `.github/scripts/frame-audit-report.ps1` | Thin wrapper for maintainer-facing aggregate reporting |
| `.github/scripts/lib/frame-audit-report-core.ps1` | Aggregates historical ledgers into era-split report output and deterministic recommendations |

## Design Decisions

| # | Decision | Choice | Rationale |
| --- | --- | --- | --- |
| D1 | Boundary | Keep the frame surface audit-only | The shipped implementation records and reports observability data without adding hooks, workflow wiring, warnings, or blocking behavior |
| D2 | Port model | Use a manifest of 17 named ports with explicit `applies` and `status` enums | The audit report needs a stable inventory and enough metadata to distinguish always-on ports from conditional ones and stable ports from deferred ones |
| D3 | Schema ownership | Start at `metrics_version: 4` and keep the frame additions additive | The inherited v1-v3 pipeline-metrics contract remains authoritative elsewhere; the frame surface adds only frame-specific fields |
| D4 | Historical derivation | Back-derive from merged PR payloads, metrics blocks, and lightweight fallbacks | The shipped audit reconstructs historical evidence without retrofitting older PRs or depending on new runtime instrumentation |
| D5 | Report semantics | Preserve real credit statuses, including `failed`, and reserve `missing` for absent credit entries only | The report layer distinguishes between negative evidence and no evidence |
| D6 | Maintainer prioritization | Rank post-pivot stable ports deterministically and keep deferred ports out of the ranking | The report is a prioritization aid for maintainers, not an automated policy decision |

## Audit-Only Boundary

The frame ledger exists to answer a maintainership question: what parts of the orchestration workflow were evidenced, ambiguous, absent, or not applicable across historical PRs?

The current implementation is intentionally limited to read-and-report behavior:

- It reads merged PR data through the GitHub CLI and cached payloads.
- It derives synthetic frame credits and integrity checks from the historical pipeline-metrics block plus lightweight linkage evidence.
- It renders aggregate audit output in `text`, `markdown`, and `json` formats.

The implementation does not ship any frame-specific enforcement entry point. The no-enforcement contract explicitly guards against wiring the frame scripts into hooks or workflows, and the wrapper wording stays free of blocking or warn-only language.

## Port Manifest

The frame manifest contains 17 ports in a fixed order:

1. `experience`
2. `design`
3. `plan`
4. `implement-code`
5. `implement-test`
6. `implement-refactor`
7. `implement-docs`
8. `review`
9. `ce-gate-cli`
10. `ce-gate-browser`
11. `ce-gate-canvas`
12. `ce-gate-api`
13. `release-hygiene`
14. `post-pr`
15. `post-fix-review`
16. `process-review`
17. `process-retrospective`

Each manifest file declares:

- `name`: the canonical port identifier used in credits and report output.
- `description`: a maintainer-facing description of the workflow question the port represents.
- `applies`: `always` or `trigger-conditional`.
- `status`: `stable` or `tbd-decision-pending`.

Three ports are currently trigger-conditional:

- `release-hygiene`
- `post-fix-review`
- `process-review`

`process-retrospective` is the only shipped `tbd-decision-pending` port. The report layer keeps it visible, but excludes it from the recommendation ranking until that decision is finalized.

The current manifest uses free-text trigger descriptions in the YAML files. There is no runtime-evaluable trigger DSL in the shipped implementation.

## v4 Additive Schema Position

The frame ledger starts at `metrics_version: 4` because v3 was already used for earlier pipeline-metrics additions. The frame design therefore extends the inherited schema instead of redefining it.

The additive v4 fields are:

- `frame_version`
- `credits[]`
- `integrity_checks[]`

`credits[]` is the audit ledger. Each credit records a `port`, a credit `status`, and short audit evidence. The shipped credit-status enum is:

- `passed`
- `failed`
- `skipped`
- `not-applicable`
- `inconclusive`

`integrity_checks[]` records provenance and confidence checks for the derived ledger. It uses the same five-value status enum.

This schema remains additive. The authoritative source for inherited v1-v3 fields and semantics stays in `skills/calibration-pipeline/references/metrics-schema.md`. The frame schema only owns the frame-specific extension and the report-layer interpretation of that extension.

## Historical Back-Derivation

`Invoke-FrameBackDerive` accepts historical `metrics_version` inputs `1`, `2`, `3`, and `4` and lifts them into one current frame audit surface.

The linked-issue resolution order is intentionally shallow and deterministic:

1. `closingIssuesReferences`
2. PR body issue references
3. Commit-message issue references

That order is used to populate both experience-oriented evidence and the linked-issue integrity check.

The derivation rules are conservative by design:

- `experience` can be credited from linked issue resolution.
- `design` and `plan` remain `inconclusive` when the audit only knows an issue was linked, because the back-deriver does not inspect issue-body markers or completion state.
- `review` can be credited as `passed` when the metrics block contains enough review evidence for that historical schema version.
- Implementation-lane ports stay `inconclusive` when historical metrics do not expose lane-level detail.
- CE Gate ports stay `inconclusive` when historical metrics confirm that CE happened but do not identify the audited surface.
- `post-fix-review` and `process-review` become `not-applicable` when their trigger is absent rather than being treated as missing.
- `release-hygiene` is `not-applicable` when no trigger is implied for later metrics versions, and remains `inconclusive` for older eras where the trigger cannot be reconstructed.
- `process-retrospective` stays `inconclusive` because the decision is still pending.

The back-deriver also emits integrity checks for linked-issue resolution, metrics-version input handling, and adapter-selection evidence. The last one stays `inconclusive` when the historical artifact does not expose enough detail to classify every implementation or CE surface port.

## Era-Split Report Model

`Invoke-FrameAuditReport` is a consumer of the back-deriver. It does not re-implement classification logic. Instead, it aggregates derived ledgers into two eras split around pivot PR `356`:

- pre-pivot: `PRs < 356`
- post-pivot: `PRs >= 356`

For each era and each port, the report records totals across these buckets:

- `passed`
- `failed`
- `N/A`
- `skipped`
- `inconclusive`
- `missing`

Two semantics matter here:

- `failed` is a first-class report bucket mapped directly from a real credit status.
- `missing` is not a credit status. It is an absence bucket used only when a port has no derived credit entry, or when a derivation-gap error forces the report to treat the PR as missing across all ports.

This separation is deliberate. A failed audit claim is different from the audit having no evidence for that port.

When the back-deriver cannot produce a ledger because the PR lacks a pipeline-metrics block, lacks `metrics_version`, or uses an unsupported version, the report treats that PR as a missing-data case instead of fabricating inconclusive credits.

## Recommendation Intent

The report produces a deterministic top-3 recommendation list from the post-pivot era only. The goal is to highlight where the current workflow most often lacks actionable historical evidence, not to make an automatic policy decision.

The shipped scoring rule is:

`score = (100 * missing) + (10 * inconclusive) + skipped`

The ranking is further constrained by current design intent:

- Only `stable` ports are eligible.
- Ports with zero score are ignored.
- `ce-gate-*` ports with inconclusive-only ambiguity are intentionally kept out of the recommendation ranking so CE surface ambiguity is visible historically without dominating the action list.
- `tbd-decision-pending` ports are listed separately under `tbd_ports` with pre-pivot and post-pivot totals and an explicit excluded reason.

The recommendation output is therefore a maintainer aid for triage and follow-up prioritization. It does not trigger hooks, mutate PRs, or escalate automatically.

## Non-Goals

The current frame design explicitly does not do the following:

- introduce blocking, warning, or enforcement behavior
- wire the frame scripts into hooks or GitHub workflows
- re-document inherited v1-v3 pipeline-metrics semantics
- add adapter declarations or frontmatter migrations outside the audit artifacts
- add a runtime-evaluable trigger-condition DSL
- treat linked issue presence as proof that design or plan completion occurred
- make recommendation ranking self-authenticating without maintainer judgment

## Deferred Areas

The shipped implementation leaves several follow-up areas outside this document's scope:

- any validator or symmetry-checking layer for ports versus adapters
- adapter-level declarations in agent or skill frontmatter
- any warn-only or blocking hook behavior
- the final decide-or-retire outcome for `process-retrospective`

This document should be updated when those areas ship. Until then, it describes only the current audit-only frame ledger behavior.
