# Platform — Copilot (VS Code)

When `parallel-execution` escalates (budget exceeded, unresolved RC conformance, or unresolved correction cycles), Copilot agents invoke:

```text
#tool:vscode/askQuestions
```

Pass the root-cause summary with a recommended option and alternatives. The methodology specifies when each escalation path fires — this platform file only documents the invocation.
