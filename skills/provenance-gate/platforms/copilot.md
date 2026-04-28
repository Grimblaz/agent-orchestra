# Platform — Copilot (VS Code)

The `provenance-gate` developer gate invokes Copilot's built-in structured-question tool:

> **Survival**: `SMC-04` governs this marker. The GitHub issue-comment token is durable; Copilot can use `/memories/session/first-contact-assessed-{ID}.md` only as within-conversation recovery input when GitHub posting fails.

```text
#tool:vscode/askQuestions
```

Run the gate in two stages.

Stage 1 comes first and happens before any assessment text. Pass these option labels verbatim:

1. `I wrote this / I'm fully briefed`
2. `I'm picking this up cold`
3. `Stop — needs rework first`

Only if the stage-1 answer is `I'm picking this up cold`, show the assessment summary and ask the cold-only stage-2 question with these option labels verbatim:

1. `Assessment looks right — proceed`
2. `Proceed but carry concerns forward`
3. `Needs rework — stop here`

Both stop outcomes halt without posting `<!-- first-contact-assessed-{ID} -->`.

For non-stop outcomes, post the two-line marker from the shared skill. The HTML token on line 1 remains the only skip-check anchor and the only parser anchor; the second line is decorative and human-readable only.

If MCP or API access is unavailable, say that offline mode is active, write the structured local payload with at least `issue_id`, `outcome`, `concerns`, and `sync_to_github_on_next_online_run`, then proceed. On the next online run, if the GitHub marker is still missing but the local payload exists, reconstruct and post the GitHub marker from that local payload before continuing.

The VS Code chat surface returns the selected label string.
