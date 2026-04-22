# Platform — Claude Code

`adversarial-review` is consumed by the Claude Code `code-critic` shell in [../../../agents/code-critic.md](../../../agents/code-critic.md). The standard review commands that trigger it are [../../../commands/orchestra-review.md](../../../commands/orchestra-review.md), [../../../commands/orchestra-review-lite.md](../../../commands/orchestra-review-lite.md), [../../../commands/orchestra-review-prosecute.md](../../../commands/orchestra-review-prosecute.md), and [../../../commands/orchestra-review-defend.md](../../../commands/orchestra-review-defend.md).

Claude bindings:

- Use the `Agent` tool to invoke the `code-critic` shell for prosecution or defense passes.
- Use `Bash` for local repo inspection, `gh` CLI calls, and any terminal-scoped validation the skill references.
- Use `WebFetch` for external references when review evidence depends on published docs or remote pages.
- Use `AskUserQuestion` when the review target or missing evidence must be supplied by the user.

Keep methodology in `SKILL.md`; this platform note is only the Claude tool-binding shim.
