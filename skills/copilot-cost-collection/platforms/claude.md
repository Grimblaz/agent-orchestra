# Platform - Claude Code

Claude Code does not produce Copilot Chat OTel records. This skill is still useful to Code-Conductor consumers when a shared checkout needs Copilot-side telemetry available for PR metrics or cost-ledger runs.

When Claude is operating in the same worktree as Copilot, it can inspect the committed skill and run the same installer if the maintainer wants local Copilot capture prepared:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File skills/copilot-cost-collection/scripts/Initialize-CopilotCostCollection.ps1 -WorkspacePath . -Yes -NonInteractive
```

Use `-UserSettingsPath` whenever the intended Copilot window uses VS Code Insiders, a profile, or a custom user-data directory. The default path targets stable VS Code user settings for the current OS.

Do not use `.copilot-cost-collection-installed`, `.vscode/settings.json`, or the OTel JSONL path as Claude session memory. They are machine-local setup artifacts only. Durable orchestration state remains the GitHub issue/PR markers and PR-body metrics named by `skills/session-memory-contract/SKILL.md`.
