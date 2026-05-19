# Platform — Claude Code

> Auto-mode boundary: see [CLAUDE.md § Auto-mode boundary](/CLAUDE.md#auto-mode-boundary). Auto-mode does not suppress `AskUserQuestion`.

This skill's methodology is tool-agnostic. Platform-specific detail: Claude Code agents invoke the `AskUserQuestion` tool to fire structured questions on load-bearing decisions.

## Structured question invocation

Use `AskUserQuestion` with the decision brief as the question body. Include the `audit_rationale` sentence immediately before the question body in the conversation text (not inside the tool call). Include a `Decline engagement — proceed without classification` option as the last choice.

## Skip rule invocation

When `gate-fails` or `engineer-declined-engagement` applies, proceed without calling `AskUserQuestion`. Capture the decline verbatim in the conversation text.
