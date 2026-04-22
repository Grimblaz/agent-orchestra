# Platform — Claude Code

`code-review-intake` is consumed by the Claude Code `code-review-response` shell in [../../../agents/code-review-response.md](../../../agents/code-review-response.md) when that shell is handling raw GitHub-originated review intake. None of the new `orchestra-review-*` commands force this mode by default. A power-user [../../../commands/orchestra-review-judge.md](../../../commands/orchestra-review-judge.md) run still expects an existing prosecution ledger plus defense report; raw GitHub comments must be ingested first through the GitHub-intake proxy path.

Claude bindings:

- Use `Bash` with the `gh` CLI to fetch PR review threads, top-level comments, review summaries, and issue context.
- Use the `Agent` tool to invoke `code-critic` with `Review mode selector: "Score and represent GitHub review"` for proxy prosecution and `Review mode selector: "Use defense review perspectives"` for the defense pass, then invoke `code-review-response` for judgment.
- Use `AskUserQuestion` only when no active PR or explicit review target can be resolved.
- Use `WebFetch` only for supplemental remote evidence; GitHub intake itself stays on `gh` CLI.

Keep methodology in `SKILL.md`; this platform note is only the Claude tool-binding shim.
