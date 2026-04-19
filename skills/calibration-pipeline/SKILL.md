---
name: calibration-pipeline
description: "Calibration and review-pipeline tooling guidance. Use when running or maintaining calibration scripts, review aggregation, and related deterministic assets for issue #360. DO NOT USE FOR: changing orchestration ownership or agent review policy."
---

# Calibration Pipeline

This skill groups deterministic tooling and data for the calibration pipeline introduced by issue #360.

## Purpose

- Describe the calibration and review-aggregation domain
- Provide the stable home for pipeline scripts under `scripts/`
- Provide the stable home for committed pipeline data under `assets/`

## Contents

- `scripts/` contains calibration writers, aggregation tools, improvement-issue helpers, and related shared helpers
- `assets/` contains committed pipeline configuration and data consumed by those scripts

## Boundary

- This skill owns deterministic tooling and static assets only
- Review orchestration, judgment, and step execution stay with the owning agents and existing methodology skills

## Gotchas

| Trigger                        | Gotcha                                                        | Fix                                                                                 |
| ------------------------------ | ------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| Adding review pipeline helpers | Tooling and orchestration responsibilities get mixed together | Keep scripts and assets here, but leave routing and judgment with the owning agents |
