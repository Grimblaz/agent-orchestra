# Platform — Claude Code

> Auto-mode boundary: see [CLAUDE.md § Auto-mode boundary](/CLAUDE.md#auto-mode-boundary). Auto-mode does not suppress `AskUserQuestion`.

When `design-exploration` escalates a choice to the user, Claude Code agents invoke the `AskUserQuestion` tool with the exploration-phase summary plus the concrete options the methodology recommends. The agent retains ownership of approval behavior — this platform file only documents the tool invocation.
