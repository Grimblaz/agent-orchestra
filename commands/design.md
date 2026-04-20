---
description: Invoke Solution-Designer — technical design exploration with 3-pass adversarial challenge.
argument-hint: "[issue number]"
---

# /design

Dispatch the `solution-designer` subagent to do technical design exploration for the provided issue.

**Pre-flight**:

1. Require an issue number (the subagent needs a durable record to update). If missing, use the `AskUserQuestion` tool.
2. Check the issue's comments/timeline for the `<!-- experience-owner-complete-{ID} -->` marker (upstream framing completion lives on a comment, not in the issue body). If the marker is not present on the issue, use `AskUserQuestion` to ask whether to run `/experience` first or to proceed without upstream framing.

**Dispatch**:

Use the `Agent` tool with:

- `subagent_type: solution-designer`
- `description`: one short phrase describing the design task
- `prompt`: the issue number plus any upstream-framing context

The subagent will read `agents/Solution-Designer.agent.md` for its full methodology, run the 3-pass non-blocking design challenge, and persist the design in the issue body with a `<!-- design-phase-complete-{ID} -->` comment marker.

ARGUMENTS: $ARGUMENTS
