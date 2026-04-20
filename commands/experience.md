---
description: Invoke Experience-Owner — customer framing upstream or CE Gate evidence capture downstream.
argument-hint: "[issue number or short description of what needs customer framing]"
---

# /experience

Dispatch the `experience-owner` subagent to do customer framing for the provided issue (upstream) or CE Gate evidence capture (downstream). Pass along the user's arguments verbatim as the task description.

**Pre-flight**:

1. If the arguments reference an existing GitHub issue (e.g., `#369` or a URL), include that context in the dispatch.
2. If there are no arguments, use the `AskUserQuestion` tool to ask whether this is upstream framing (issue to frame) or downstream CE Gate (issue with a branch ready to exercise).

**Dispatch**:

Use the `Agent` tool with:

- `subagent_type: experience-owner`
- `description`: one short phrase describing the task
- `prompt`: the user's arguments plus any context gathered in pre-flight

The subagent will read `agents/Experience-Owner.agent.md` for its full methodology, load the relevant skills, and persist results via GitHub issue comments.

ARGUMENTS: $ARGUMENTS
