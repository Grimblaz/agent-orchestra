# Platform — Claude Code

The `provenance-gate` developer gate invokes Claude Code's `AskUserQuestion` tool.

Run the gate in two stages.

Stage 1 comes first and happens before any assessment text. Pass these option labels verbatim:

1. `I wrote this / I'm fully briefed`
2. `I'm picking this up cold`
3. `Stop — needs rework first`

Only if the stage-1 answer is `I'm picking this up cold`, pass the assessment summary as the prompt and ask the cold-only stage-2 question with these option labels verbatim:

1. `Assessment looks right — proceed`
2. `Proceed but carry concerns forward`
3. `Needs rework — stop here`

Both stop outcomes halt without posting `<!-- first-contact-assessed-{ID} -->`.

For non-stop outcomes, post the two-line marker from the shared skill. The HTML token on line 1 remains the only skip-check anchor and the only parser anchor; the second line is decorative and human-readable only.

If offline mode is active because MCP or API access is unavailable, say so and continue. Claude Code inline currently lacks a session-memory write surface, so this surface cannot persist the shared skill's local fallback payload or recover the GitHub marker on a later online run. Do not claim that either happened here.

Claude Code returns the selected label string.
