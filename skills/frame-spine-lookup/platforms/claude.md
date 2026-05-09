# Platform — Claude Code

`frame-spine-lookup` is used by Claude Code specialist shells when they need to
fetch an adjacent plan slice mid-turn. Specialists that have `Read` and `Bash`
grants can invoke this contract; see [Tool-Grant Verification](../SKILL.md#tool-grant-verification)
in the parent skill for the complete list.

Claude bindings:

- Use the `Bash` tool to fetch the plan-issue comment body:
  `gh api repos/{owner}/{repo}/issues/comments/{id}` — pipe the `.body` field to a temp file.
- Use the `Bash` tool to invoke the lookup:
  `pwsh -File .github/scripts/lib/frame-spine-core.ps1 -Op Lookup -CommentBodyPath {path} -GeneratedAt {generated_at} -StepId {id} -Format Json`
- Parse the JSON response to extract slice content.
- On `stale-spine` result, stop specialist work and return control to Conductor.
- Do **not** use `AskUserQuestion` — stale-spine pause belongs to Conductor via its own step.

Keep methodology in `SKILL.md`; this file is only the Claude tool-binding shim.
