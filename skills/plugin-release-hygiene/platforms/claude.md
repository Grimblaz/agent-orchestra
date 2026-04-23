# Platform — Claude Code

Claude Code loads `plugin-release-hygiene` from a committed `PostToolUse` hook in `.claude/settings.json`. The hook runs `.claude/hooks/plugin-release-hygiene-hook.ps1`, filters the edited path against the entry-point list, and emits `hookSpecificOutput.additionalContext` only for the first relevant touch in a conversation.

When the skill needs a user-facing override, invoke `AskUserQuestion` with these option labels:

1. `Patch`
2. `Minor`
3. `Major`
4. `Skip`

Persist the conversation-scoped result in `.claude/.state/release-hygiene-{slug}.json` and reuse it silently for later entry-point touches in the same conversation.
