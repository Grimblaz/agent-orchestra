---
description: Invoke Solution-Designer inline — technical design exploration with 3-pass adversarial challenge.
argument-hint: "[issue number]"
---

# /design

Run the Solution-Designer role inline in this conversation for the provided issue.

**Pre-flight**:

1. Require an issue number (the agent needs a durable record to update). If missing, use the `AskUserQuestion` tool.
2. Check the issue's comments/timeline for the `<!-- experience-owner-complete-{ID} -->` marker. If not present, use `AskUserQuestion` to ask whether to run `/experience` first or to proceed without upstream framing.

**Inline execution**:

Read `agents/Solution-Designer.agent.md` and adopt that role for the rest of this conversation. Follow all methodology sections, run the 3-pass non-blocking design challenge, and persist the design in the issue body with a `<!-- design-phase-complete-{ID} -->` comment marker.

ARGUMENTS: $ARGUMENTS
