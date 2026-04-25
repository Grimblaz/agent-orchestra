# Platform — Copilot (VS Code)

Copilot loads `plugin-release-hygiene` from the plugin-distributed `PostToolUse` hook in root `hooks.json`. That hook resolves the installed plugin cache path explicitly, then runs `skills/plugin-release-hygiene/scripts/plugin-release-hygiene-hook.ps1` for relevant entry-point edits.

Copilot does not expose a Claude-style stable `session_id` to this hook payload, so state keying remains branch-based here. That divergence is intentional: Claude prefers `session_id` when available, while Copilot continues to use the branch-derived slug and falls back to `session` only when branch resolution fails.

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

Persist `keying_strategy` in the same state file so the active keying path is observable during tests and review. In normal Copilot flows this should be `branch_slug`; `session_fallback` is reserved for branch-resolution failure.

This means Copilot's silence contract is branch-scoped rather than conversation-scoped. Document the difference instead of implying cross-platform identity.
