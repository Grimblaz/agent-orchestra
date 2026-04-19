# Platform — Copilot (VS Code)

When `step-commit` escalates after ≥2 consecutive failures, Copilot agents invoke:

```text
#tool:vscode/askQuestions
```

Pass the failure summary and recommended options (the methodology specifies what the options should cover). The user's selection drives the next action.
