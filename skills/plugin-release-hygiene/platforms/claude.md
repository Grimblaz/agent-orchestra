# Platform — Claude Code

Claude Code loads `plugin-release-hygiene` from the plugin-distributed `PostToolUse` hook in `hooks/hooks.json`. The hook runs `skills/plugin-release-hygiene/scripts/plugin-release-hygiene-hook.ps1` via `${CLAUDE_PLUGIN_ROOT}`, filters the edited path against the entry-point list, and emits `hookSpecificOutput.additionalContext` only for the first relevant touch in a conversation.

State keying behavior:

- Prefer the PostToolUse payload's `session_id` when it is present.
- Fall back to the existing branch-derived slug when `session_id` is absent.
- Fall back again to the short HEAD SHA when the repo is in detached HEAD and no `session_id` is available.
- Use `session` only when neither `session_id`, branch, nor HEAD SHA can be resolved.
- Persist the selected path as `keying_strategy` with one of: `session_id`, `branch_slug`, `session_fallback`.

The hook also stays silent when the repo's managed version set is both internally lockstep and ahead of the resolved default branch. If the baseline comparison cannot be completed, the hook fails open and preserves the original first-warning behavior.

The state file resolves from the git common root rather than the current worktree root, so linked worktrees in the same clone reuse the same `.claude/.state/` directory for a shared `session_id`.

When the skill needs a user-facing override, invoke `AskUserQuestion` with these option labels:

1. `Patch`
2. `Minor`
3. `Major`
4. `Skip`

Persist the conversation-scoped result in `.claude/.state/release-hygiene-{slug}.json` and reuse it silently for later entry-point touches in the same conversation.
