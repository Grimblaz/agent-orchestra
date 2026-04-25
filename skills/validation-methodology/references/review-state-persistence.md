# Review-State Persistence

This reference owns the pre-PR review-state persistence contract extracted from Code-Conductor.

## Session Memory Location

When the active branch matches `feature/issue-{N}-...`, persist review state to `/memories/session/review-state-{N}.md`. If no branch match exists, silently skip persistence.

Pre-PR review-state lookup reads session memory only. Post-PR resume lookup may instead use the durable review comment, then `<!-- pipeline-metrics -->`, then session memory.

## File Shape

Persist the exact YAML front matter fields below in this order:

```markdown
---
issue_id: {N}
review_mode: {full|lite}
prosecution_complete: {true|false}
defense_complete: {true|false}
judgment_complete: {true|false}
last_updated: {UTC ISO-8601 timestamp}
---
```

## Write Contract

- Composite commands `/orchestra:review` and `/orchestra:review-lite` write complete review-state after the judge stage completes.
- Individual commands `/orchestra:review-prosecute`, `/orchestra:review-defend`, and `/orchestra:review-judge` write only their own stage boolean while preserving the other stored booleans when a readable state file already exists.
- When an individual command creates the file from scratch, default missing booleans to `false` and `review_mode` to `full`.
- `review_mode` is label-only metadata. It does not participate in `Test-GateCriteria` criteria construction.
- All writes are atomic: write a temp sibling first, then replace the target with `Move-Item -Force`.

## Reader Contract

Use `skills/routing-tables/scripts/review-state-reader.ps1` for file reads. The reader fails closed by returning `$null` when the file is absent or malformed.
