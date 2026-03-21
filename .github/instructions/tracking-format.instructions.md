# Tracking Format Instructions

## Purpose

This document defines the standard YAML frontmatter format for tracking files stored in `.copilot-tracking/`. These files help agents maintain context and state across work sessions.

## Directory Structure

```
.copilot-tracking/
├── research/
│   └── {date}-{topic}.md
├── archived/
│   └── issue-001-feature-name.md
└── calibration/
    └── review-data.json
```

- `calibration/` — persistent per-finding calibration cache (populated by `write-calibration-entry.ps1` or `backfill-calibration.ps1`)
  - `review-data.json` — JSON calibration data (schema: `{ calibration_version: 1, entries: [{ pr_number, created_at, findings[], summary }] }`)

> **Note**: `.copilot-tracking/` stores research notes, archived tracking files, and persistent calibration data. Plans are now stored in session memory at `/memories/session/plan-issue-{ID}.md`, not as local files.

## YAML Frontmatter Format

> **Scope**: The following format applies to `.copilot-tracking/` research and tracking files only — not to session memory plan files. For session memory plan YAML fields, see Issue-Planner Section 6 in `.github/agents/Issue-Planner.agent.md`.

All tracking files **MUST** include YAML frontmatter at the top of the file:

```yaml
---
status: in-progress
priority: p1
issue_id: "001"
tags: [feature, api, backend]
created: 2025-12-09
updated: 2025-12-09
---
```

## Field Definitions

### Required Fields

| Field      | Type   | Description                                     |
| ---------- | ------ | ----------------------------------------------- |
| `status`   | string | Current work status (see Status Values below)   |
| `priority` | string | Work priority level (see Priority Levels below) |
| `issue_id` | string | Reference to issue number or tracking ID        |
| `created`  | date   | Creation date in YYYY-MM-DD format              |

### Optional Fields

| Field            | Type   | Description                                           |
| ---------------- | ------ | ----------------------------------------------------- |
| `tags`           | array  | Categorization tags (e.g., feature, bugfix, refactor) |
| `updated`        | date   | Last update date in YYYY-MM-DD format                 |
| `assigned_agent` | string | Current agent working on this item                    |
| `blocked_by`     | string | Dependency or blocker reference                       |
| `related_issues` | array  | Related issue IDs                                     |

### Status Values

Use one of these standardized status values:

- **`pending`** - Work not yet started, awaiting resources or dependencies
- **`in-progress`** - Actively being worked on
- **`complete`** - Work finished and verified
- **`blocked`** - Cannot proceed due to external dependency
- **`on-hold`** - Paused by decision, may resume later

### Priority Levels

Use one of these standardized priority levels:

- **`p1`** - Critical/Urgent - Immediate attention required
- **`p2`** - High - Important but not blocking
- **`p3`** - Normal - Standard priority work
- **`p4`** - Low - Nice-to-have, can be deferred

#### GitHub Label Mapping

When deriving priority from a GitHub issue label, use this mapping:

| GitHub label | Frontmatter value |
| --- | --- |
| `priority: high` | `p1` |
| `priority: medium` | `p2` |
| `priority: low` | `p3` |
| (unlabeled) | `p2` (default) |

## File Naming Convention

Format: `issue-{ID}-{short-description}.md`

Examples:

- `issue-001-authentication-system.md`
- `issue-042-fix-memory-leak.md`
- `issue-123-refactor-database-layer.md`

## Content Structure

After the YAML frontmatter, include:

1. **Summary** - Brief description of the work
2. **Context** - Background information and decisions
3. **Progress** - Current state and completed items
4. **Next Steps** - What needs to happen next
5. **Notes** - Any relevant observations or blockers

## Example Tracking File

```markdown
---
status: in-progress
priority: p2
issue_id: "042"
tags: [bugfix, performance]
created: 2025-12-09
updated: 2025-12-09
assigned_agent: "Code-Smith"
---

# Issue #42: Optimize Query Performance

## Summary

Database queries in the reporting module are taking too long. Need to add indexes and optimize query structure.

## Context

- User reported 30+ second load times
- Profiling identified N+1 query problem
- Decision: Add composite index on frequently queried columns

## Progress

- [x] Profiled slow queries
- [x] Identified missing indexes
- [ ] Apply index migrations
- [ ] Validate performance improvement

## Next Steps

1. Create migration for new indexes
2. Test in staging environment
3. Measure performance improvement
4. Update documentation

## Notes

- Be careful with index size - monitor disk usage
- Consider query caching as future enhancement
```

## Archiving Completed Work

For any tracking files (research notes, prompt output) in `.copilot-tracking/` that reach `complete` status:

1. Move the file to `.copilot-tracking/archived/`
2. Update `status` to `complete`
3. Add `completed` date field
4. Keep file for historical reference

Plans saved to session memory (`/memories/session/plan-issue-{ID}.md`) do not need archiving — session memory is scoped to the conversation.

## Cloud Agent Handoff Protocol

When using a cloud agent (e.g., Codex) for implementation, it creates its own branch from `main` and cannot read local files or VS Code session memory. Issue-Planner can optionally post the plan as a GitHub issue comment so the cloud agent can read it:

| Phase | Agent | Output Location |
| --- | --- | --- |
| Design | Issue Designer | Updates **issue body** with full design details |
| Planning | Issue Planner | Saves plan to session memory (`/memories/session/plan-issue-{ID}.md`); optionally posts as a GitHub issue comment with `<!-- plan-issue-{ID} -->` marker (user opt-in) |
| Implementation | Code Conductor | Reads plan from session memory; falls back to GitHub issue comment; reads issue body for design details only. Commits design doc to `Documents/Design/{domain-slug}.md` with the implementation PR |

### Rules

- **Design doc file** under `Documents/Design/` (e.g., `Documents/Design/{domain-slug}.md`) is committed during implementation, not during design
- **Plan** lives in session memory (`/memories/session/plan-issue-{ID}.md`); for cross-session or cloud agent handoffs, Issue-Planner can optionally post the plan as a GitHub issue comment with `<!-- plan-issue-{ID} -->` marker
- One branch, one PR — no prerequisite branch needed for context sharing
- For local-only workflows (no cloud agent), agents may still commit design doc files under `Documents/Design/` to the feature branch first — the issue-based flow works for both

### Tracking Files vs. Issue Coordination

`.copilot-tracking/` files are local scaffolding for tracking agent state (research notes, prompt output) across sessions on the **same machine**. They are gitignored and not suitable for cross-agent handoffs where a new branch is created (e.g., cloud agent workflows). Use GitHub issues for durable, cross-agent coordination. Plans use session memory, not `.copilot-tracking/`.

## Customization

This format is a template. Projects may add custom fields as needed:

- `test_coverage` - Percentage or status
- `review_status` - Code review state
- `deployment_target` - Environment information
- `customer_impact` - Business impact notes

Maintain consistency within your project's tracking files.
