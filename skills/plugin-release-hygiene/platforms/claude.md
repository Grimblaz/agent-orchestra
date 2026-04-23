# Platform — Claude Code

Claude Code loads `plugin-release-hygiene` from the plugin-distributed `PostToolUse` hook in `hooks/hooks.json`. The hook runs `skills/plugin-release-hygiene/scripts/plugin-release-hygiene-hook.ps1` via `${CLAUDE_PLUGIN_ROOT}`, filters the edited path against the entry-point list, and emits `hookSpecificOutput.additionalContext` only for the first relevant touch in a conversation.

When the skill needs a user-facing override, invoke `AskUserQuestion` with these option labels:

1. `Patch`
2. `Minor`
3. `Major`
4. `Skip`

Persist the conversation-scoped result in `.claude/.state/release-hygiene-{slug}.json` and reuse it silently for later entry-point touches in the same conversation.
