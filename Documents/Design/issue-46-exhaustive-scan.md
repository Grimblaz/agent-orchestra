# Issue #46: Exhaustive-Scan Requirement for Migration-Type Issues

## Overview

Adds two surgical guardrails to prevent migration-type issues from leaving behind
unreplaced old-form references — a class of defect first surfaced in Issue #39 (C-1 blocker).

## Problem

For issues that migrate or replace a pattern across multiple files, plans previously
enumerated affected files from memory or from the issue description. This leaves symmetric
occurrences uncovered. In Issue #39, two instruction files with hardcoded relative paths
were missed by the plan and only caught in Code-Critic Pass 3 as a blocker (C-1).
A single `Select-String` scan before implementation would have caught them.

## Changes

### 1. Issue-Planner.agent.md — `<plan_style_guide>` conditional rule

New rule appended to the rules list (after "Keep scannable"):

> For migration-type issues — pattern replacement, API migration, rename/move across
> files, or issues with signal phrases like "replace X with Y" or "migrate from A to B"
> — Step 1 of the plan MUST be an exhaustive repo scan producing the authoritative
> file list. The issue author's file list must not be trusted as complete.
> Example: `Select-String -Path ".github/**/*.md",".github/**/*.json" -Recurse -Pattern "old-pattern"`

**Scope**: `.github/agents/Issue-Planner.agent.md`, `<plan_style_guide>` rules section only.

### 2. Code-Conductor.agent.md — Step 4 pre-PR migration gate

New bullet inserted between "Scope check" and "Validation evidence" in Step 4:

> **Migration completeness check** (migration-type issues only): Run a final scan for
> remaining old-form references and confirm count is 0. Include scan output as
> validation evidence in the PR body.

PR body MUST-include list updated to add `migration-scan result (migration-type issues
only)` after "validation evidence".

**Scope**: `.github/agents/Code-Conductor.agent.md`, Step 4 only.

## Design Decisions

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Scan guidance in `<plan_style_guide>` rules | Co-located with plan structure rules where plan authors naturally look; no new workflow phases |
| 2 | Final-grep in Step 4 PR checklist (not Validation Ladder tier) | Scope-completeness check fits alongside existing `git diff --name-status` scope check; Validation Ladder is for build/test/lint quality gates |
| 3 | Consistent qualifier: "migration-type issues only" | "(when applicable)" was ambiguous — consistent explicit qualifier in both the bullet and the PR body list |

## Acceptance Criteria Verification

- [x] `Issue-Planner.agent.md` includes exhaustive-scan guidance for migration issues in `<plan_style_guide>`
- [x] `Code-Conductor.agent.md` Step 4 includes final-grep check for migration issues (between scope check and validation evidence)
- [x] Example scan command provided (`Select-String` pattern)
- [x] PR body template updated to include migration-scan result

## CE Gate

`ce_gate: false` — these are internal agent instruction files with no customer-facing surface.

## References

- Issue #46: <https://github.com/Grimblaz/workflow-template/issues/46>
- Issue #39 — Gap C (C-1 blocker): missing instruction file updates after portability migration
