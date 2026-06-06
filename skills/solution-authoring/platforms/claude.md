# Platform — Claude Code

> Auto-mode boundary: see [CLAUDE.md § Auto-mode boundary](/CLAUDE.md#auto-mode-boundary). Auto-mode does not suppress `AskUserQuestion`.

This skill's methodology is tool-agnostic. Platform-specific detail: Claude Code agents invoke the `AskUserQuestion` tool to fire structured questions on load-bearing decisions.

## Structured question invocation

Use `AskUserQuestion` with the decision brief as the question body — for load-bearing adversarial-review dispositions, use the escalation tier (full prose per `§Rule: Decision brief structure`); for all other load-bearing decisions, use the base tier (3-sentence brief). Include the `audit_rationale` sentence immediately before the question body in the conversation text (not inside the tool call). Include a `Decline engagement — proceed without classification` option as the last choice.

## Skip rule invocation

When `gate-fails` or `engineer-declined-engagement` applies, proceed without calling `AskUserQuestion`. Capture the decline verbatim in the conversation text.

## L0 token emission

Before calling `AskUserQuestion` for a load-bearing decision (or before recording a lawful skip), emit a classification-decision token per `## L0 Gate Token (Classification-Decision Self-Report)` in `skills/solution-authoring/SKILL.md`. Use the schema at `skills/solution-authoring/schemas/gate-decision-token.schema.json`. Set `session_key` when the PostToolUse event logger (L1) is active so the L2 validator can locate corroborating events.
