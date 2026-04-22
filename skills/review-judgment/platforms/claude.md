# Platform — Claude Code

`review-judgment` is consumed by the Claude Code `code-review-response` shell in [../../../agents/code-review-response.md](../../../agents/code-review-response.md). The review commands that trigger it are [../../../commands/orchestra-review.md](../../../commands/orchestra-review.md), [../../../commands/orchestra-review-lite.md](../../../commands/orchestra-review-lite.md), and [../../../commands/orchestra-review-judge.md](../../../commands/orchestra-review-judge.md).

Claude bindings:

- Use the `Agent` tool to invoke the `code-review-response` shell for the judge pass.
- Use `Bash` for local verification reads and `gh` CLI operations when the judgment path is GitHub-backed.
- Use `WebFetch` only when the cited evidence lives outside the workspace.
- Use `AskUserQuestion` if the prosecution ledger, defense report, or review target context is incomplete.

Keep methodology in `SKILL.md`; this platform note is only the Claude tool-binding shim.
