# Platform — Claude Code

`review-judgment` is consumed by the Claude Code `code-review-response` shell in [../../../agents/code-review-response.md](../../../agents/code-review-response.md). The review commands that trigger it are [../../../commands/orchestra-review.md](../../../commands/orchestra-review.md), [../../../commands/orchestra-review-lite.md](../../../commands/orchestra-review-lite.md), and [../../../commands/orchestra-review-judge.md](../../../commands/orchestra-review-judge.md).

The skill has a **second, wider consumer set**: its parent-owned § Close-Out Record Amendment is named by six lane entry documents — those three plus `review-github`, `orchestrate`/`code-conductor` (through `agents/Code-Conductor.agent.md`), and `goal-run` (through `agents/Goal-Run.agent.md`). Use that section's own lane table as the consumer list when editing or repointing it; the three commands above are the judge-dispatch consumers only, and sweeping from them alone touches three of six.

Claude bindings:

- Use the `Agent` tool to invoke the `code-review-response` shell for the judge pass.
- Use `Bash` for local verification reads and `gh` CLI operations when the judgment path is GitHub-backed.
- Use `WebFetch` only when the cited evidence lives outside the workspace.
- Ask the user if the prosecution ledger, defense report, or review target context is incomplete.

Keep methodology in `SKILL.md`; this platform note is only the Claude tool-binding shim.
