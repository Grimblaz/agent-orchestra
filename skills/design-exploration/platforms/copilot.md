# Platform — Copilot (VS Code)

When `design-exploration` escalates a choice to the user, Copilot agents invoke:

```text
#tool:vscode/askQuestions
```

Pass the exploration-phase summary plus the concrete options the methodology recommends. The agent retains ownership of approval behavior — this platform file only documents the tool invocation.
