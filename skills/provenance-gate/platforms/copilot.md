# Platform — Copilot (VS Code)

The `provenance-gate` developer gate invokes Copilot's built-in structured-question tool:

```text
#tool:vscode/askQuestions
```

Render the assessment summary and pass these option labels verbatim (SKILL.md expects them for branch-on-response):

1. `I wrote this / I'm fully briefed`
2. `Assessment looks right - proceed with caution`
3. `Needs rework - stop here`

The VS Code chat surface returns the selected label string.
