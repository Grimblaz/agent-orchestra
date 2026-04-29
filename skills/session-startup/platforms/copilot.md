# Platform — Copilot (VS Code)

Copilot receives `session-startup` through the plugin-distributed root `hooks.json` file referenced by the root `plugin.json` manifest. Because Copilot-format plugins do not define `${CLAUDE_PLUGIN_ROOT}`, the Copilot hook command resolves the installed plugin cache path explicitly before invoking `skills/session-startup/scripts/session-cleanup-detector.ps1`, then injects any resulting `additionalContext` into the agent's first turn.

When `session-startup` needs user confirmation before running the detector's fenced cleanup commands, Copilot agents invoke:

```text
#tool:vscode/askQuestions
```

Present the detector's `additionalContext` text and offer two options:

1. `Yes — run cleanup`
2. `No — skip for now`

Copilot skips the Claude-only plugin drift-check sub-step silently because Copilot does not use the Claude plugin cache model.

> **D3b exemption**: `session-startup/SKILL.md` intentionally retains this methodology verbatim (see `path-migration-sweep-gate.Tests.ps1` D3b whitelist). The platform file documents the Copilot-specific tool invocation without duplicating the full protocol.
