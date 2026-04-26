---
name: calibration-pipeline
description: "Calibration and review-pipeline tooling guidance. Use when running or maintaining calibration scripts, review aggregation, and related deterministic assets for issue #360. DO NOT USE FOR: changing orchestration ownership or agent review policy."
---

# Calibration Pipeline

Reusable entryway for deterministic tooling, committed assets, and pipeline-metrics reference material for the calibration pipeline introduced by issue #360.

> **Survival**: `SMC-09` covers raw aggregate/prosecution-depth snapshots as `per-dispatch` until selected PR-body metrics are durable. `SMC-10` covers the `within-worktree` per-finding cache; `SMC-11` covers `within-worktree` cross-PR state. Script temp files are `per-process` scratch only.

## When to Use

- When running or maintaining calibration writers, aggregation scripts, or helper libraries under `scripts/`
- When updating committed calibration data or configuration under `assets/`
- When a workflow needs the canonical pipeline-metrics schema, verdict mapping, or findings-construction rules without re-reading Code-Conductor

## Purpose

- Describe the calibration and review-aggregation domain
- Provide the stable home for pipeline scripts under `scripts/`
- Provide the stable home for committed pipeline data under `assets/`

## Contents

- `scripts/` contains calibration writers, aggregation tools, improvement-issue helpers, and related shared helpers
- `assets/` contains committed pipeline configuration and data consumed by those scripts
- `references/` contains extracted pipeline-metrics contract material that other skills and agents can load directly

## Composite References

- [references/metrics-schema.md](references/metrics-schema.md): canonical `## Pipeline Metrics` block shape, top-level field semantics, and the `write-calibration-entry.ps1` invocation contract
- [references/verdict-mapping.md](references/verdict-mapping.md): judge verdict to metrics-field mapping for main and post-fix review
- [references/findings-construction.md](references/findings-construction.md): findings-array construction, backward compatibility, malformed-entry handling, and rework-cycle population rules

## Boundary

- This skill owns deterministic tooling and static assets only
- Review orchestration, judgment, and step execution stay with the owning agents and existing methodology skills

## Gotchas

| Trigger                        | Gotcha                                                        | Fix                                                                                 |
| ------------------------------ | ------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| Adding review pipeline helpers | Tooling and orchestration responsibilities get mixed together | Keep scripts and assets here, but leave routing and judgment with the owning agents |
