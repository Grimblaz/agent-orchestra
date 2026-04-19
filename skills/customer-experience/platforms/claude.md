# Platform — Claude Code

When `customer-experience` requires a user-facing structured question, Claude Code agents invoke the `AskUserQuestion` tool with the customer-framed prompt and the 2–3 option labels the skill's methodology specifies. The returned option label is what the skill's recommendation-path logic branches on.
