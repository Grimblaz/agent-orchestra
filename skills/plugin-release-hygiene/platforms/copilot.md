# Platform — Copilot (VS Code)

Copilot loads `plugin-release-hygiene` from `.github/instructions/plugin-release-hygiene.instructions.md`, which auto-attaches whenever entry-point files are in conversation context.

When the skill needs a user-facing override, Copilot agents invoke:

```text
#tool:vscode/askQuestions
```

Use these option labels:

1. `Patch`
2. `Minor`
3. `Major`
4. `Skip`

Persist the result in `.claude/.state/release-hygiene-{slug}.json` so later entry-point touches in the same conversation can reuse the same choice silently.
