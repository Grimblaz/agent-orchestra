# Platform — Claude Code

When `step-commit` escalates after ≥2 consecutive failures, Claude Code agents invoke the `AskUserQuestion` tool with the failure summary and recommended options (the methodology specifies what the options should cover). The user's selection drives the next action.
