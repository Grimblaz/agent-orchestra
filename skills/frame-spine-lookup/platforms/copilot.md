# Platform — Copilot (VS Code)

`frame-spine-lookup` is used by Copilot specialist agents when they need to
fetch an adjacent plan slice mid-turn. Specialists that have `execute/runInTerminal`
(or `execute`) can invoke this contract; see [Tool-Grant Verification](../SKILL.md#tool-grant-verification)
in the parent skill for the complete list.

Copilot bindings:

- Use `execute/runInTerminal` to fetch the plan-issue comment body and pipe it via stdin:
  `gh api repos/{owner}/{repo}/issues/comments/{id} --jq .body | pwsh -File .github/scripts/lib/frame-spine-core.ps1 -Op Lookup -CommentBodyStdin -Format Json -GeneratedAt {generated_at} -StepId {id}`
  (`-CommentBodyStdin` and `-Format Json` added in issue #514.)
- Parse the JSON response to extract slice content.
- On `stale-spine` result, stop specialist work and return control to Conductor.
- Conductor pauses via `vscode/askQuestions` with the standard re-dispatch options.
- Do **not** use `vscode/askQuestions` from within the specialist — stale-spine pause belongs to Conductor.

Keep methodology in `SKILL.md`; this file is only the Copilot tool-binding shim.
