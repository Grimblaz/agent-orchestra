---
description: Invoke Experience-Owner inline — customer framing upstream or CE Gate evidence capture downstream.
argument-hint: "[issue number or short description of what needs customer framing]"
---

# /experience

Run the Experience-Owner role inline in this conversation for the provided issue (upstream framing or CE Gate evidence capture).

**Pre-flight**:

1. If the arguments reference an existing GitHub issue (e.g., `#369` or a URL), include that context.
2. If there are no arguments, use the `AskUserQuestion` tool to ask whether this is upstream framing (issue to frame) or downstream CE Gate (issue with a branch ready to exercise).

**Inline execution**:

Read `agents/Experience-Owner.agent.md` and adopt that role for the rest of this conversation. Follow all methodology sections, load the relevant skills, and persist results via GitHub issue comments.

ARGUMENTS: $ARGUMENTS
