# Platform - Copilot (VS Code)

Copilot-side cost collection depends on VS Code Copilot Chat OTel file export. Install it from the workspace you want to measure:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File skills/copilot-cost-collection/scripts/Initialize-CopilotCostCollection.ps1 -WorkspacePath . -Yes -NonInteractive
```

The installer writes stable VS Code user settings by default. If the active window uses a VS Code profile, Insiders, a portable user-data directory, or another settings root, pass `-UserSettingsPath` to that `settings.json`.

Required Copilot OTel settings:

- `github.copilot.chat.otel.enabled=true`
- `github.copilot.chat.otel.exporterType="file"`
- `github.copilot.chat.otel.captureContent=false`
- Workspace `github.copilot.chat.otel.outfile=<literal path>`

After the settings change, reload VS Code if Copilot Chat does not start writing records. The OTel settings are window-reload sensitive in current VS Code builds.

The workspace outfile must be a literal path. Do not write `${userHome}` or `${workspaceFolderBasename}` into `github.copilot.chat.otel.outfile` unless you are intentionally testing template behavior; issue #488 OQ1 showed file export did not expand VS Code variables in this environment.

Survival: `within-worktree`. The sentinel, workspace setting, and JSONL path are machine-local setup state and are not durable workflow memory.
