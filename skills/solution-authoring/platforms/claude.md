# Platform — Claude Code

> Auto-mode boundary: see [CLAUDE.md § Auto-mode boundary](/CLAUDE.md#auto-mode-boundary). Auto-mode does not suppress engagement gates.

This skill's methodology is tool-agnostic, and so is the presentation of the gate: this file specifies no mechanism for surfacing a decision, and the agent chooses per turn what works. What follows are the parts of the contract that bind whatever presentation the agent picks.

## Gate firing

Put the decision brief to the engineer as the question body — for load-bearing adversarial-review dispositions, use the escalation tier (full prose per `§Rule: Decision brief structure`); for all other load-bearing decisions, use the base tier (3-sentence brief). Include the `audit_rationale` sentence in the conversation text immediately before the question body, never anywhere inside the question artifact itself. Include a `Decline engagement — proceed without classification` option as the last choice.

## Skip rule invocation

When `gate-fails` or `engineer-declined-engagement` applies, proceed without asking. Capture the decline verbatim in the conversation text.

## L0 token emission

Before asking a load-bearing decision (or before recording a lawful skip), emit a classification-decision token per `## L0 Gate Token (Classification-Decision Self-Report)` in `skills/solution-authoring/SKILL.md`. Use the schema at `skills/solution-authoring/schemas/gate-decision-token.schema.json`. The token is emitted first — the ordering is what `window_position: pre-ask` records.
