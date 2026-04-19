# Platform — Copilot (VS Code)

When `customer-experience` requires a user-facing structured question, Copilot agents invoke the built-in question tool:

```text
#tool:vscode/askQuestions
```

Pass the customer-framed prompt with the 2–3 option labels the skill's methodology specifies. Keep labels short enough for the VS Code chat surface; option text is what the skill's recommendation-path logic branches on.
