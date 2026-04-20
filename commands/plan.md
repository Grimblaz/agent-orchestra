---
description: Invoke Issue-Planner — produce an implementation plan with CE Gate coverage and the full adversarial review pipeline.
argument-hint: "[issue number]"
---

# /plan

Dispatch the `issue-planner` subagent to produce an implementation plan for the provided issue.

**Pre-flight**:

1. Require an issue number (the plan is posted as a durable comment on that issue). If missing, use the `AskUserQuestion` tool.
2. Check the issue's comments/timeline for the `<!-- design-phase-complete-{ID} -->` marker (design completion lives on a comment, not in the issue body). If the marker is not present on the issue, use `AskUserQuestion` to ask whether to run `/design` first or to plan from whatever framing already exists.

**Dispatch**:

Use the `Agent` tool with:

- `subagent_type: issue-planner`
- `description`: one short phrase describing the planning task
- `prompt`: the issue number plus any design/framing context

The subagent will read `agents/Issue-Planner.agent.md` for its full methodology, follow the Plan Style Guide and Plan Approval Prompt Format in `skills/plan-authoring/SKILL.md`, run the full adversarial pipeline (prosecution × 3 → defense → judge), and persist the approved plan as a GitHub issue comment with a `<!-- plan-issue-{ID} -->` marker.

ARGUMENTS: $ARGUMENTS
