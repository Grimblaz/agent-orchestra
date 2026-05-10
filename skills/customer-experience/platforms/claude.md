# Platform — Claude Code

> Auto-mode boundary: see [CLAUDE.md § Auto-mode boundary](/CLAUDE.md#auto-mode-boundary). Auto-mode does not suppress `AskUserQuestion`.

When `customer-experience` requires a user-facing structured question, Claude Code agents invoke the `AskUserQuestion` tool with the customer-framed prompt and the 2–3 option labels the skill's methodology specifies. The returned option label is what the skill's recommendation-path logic branches on.
