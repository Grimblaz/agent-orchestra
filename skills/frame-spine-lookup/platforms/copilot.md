# Platform — Copilot (VS Code)

`frame-spine-lookup` is used by Copilot specialist agents when they need to
fetch an adjacent plan slice mid-turn. Specialists that have `execute/runInTerminal`
(or `execute`) can invoke this contract; see [Tool-Grant Verification](../SKILL.md#tool-grant-verification)
in the parent skill for the complete list.

Copilot bindings:

- Use `execute/runInTerminal` to fetch the plan-issue comment body and pipe it via stdin:
  `gh api repos/{owner}/{repo}/issues/comments/{id} --jq .body | pwsh -File .github/scripts/lib/frame-spine-core.ps1 -Op Lookup -CommentBodyStdin -Format Json -GeneratedAt {generated_at} -StepId {id}`
  (`-CommentBodyStdin` and `-Format Json` added in issue #514.)
- Parse the JSON `status` field to determine the outcome. Do **not** branch on exit code alone —
  `stale-spine` exits 0. See the Exit Codes table in `SKILL.md` for the complete list.
- On `stale-spine` result, stop specialist work and return control to Conductor.
- Conductor pauses via `vscode/askQuestions` with the standard re-dispatch options.
- Do **not** use `vscode/askQuestions` from within the specialist — stale-spine pause belongs to Conductor.

**Wrapper-level error handling** (failures before the script runs):

| Error code            | Cause                                                           | Specialist action                                            |
| --------------------- | --------------------------------------------------------------- | ------------------------------------------------------------ |
| `gh-not-installed`    | `gh` CLI not found on PATH                                      | Report error; do not continue implementation.                |
| `gh-auth-expired`     | `gh auth status` fails; token invalid or expired                | Report error; do not continue implementation.                |
| `gh-rate-limited`     | GitHub API returns 403/429                                      | Report error; do not continue implementation.                |
| `pwsh-not-found`      | `pwsh` (PowerShell 7+) not found on PATH                        | Report error; do not continue implementation.                |
| `comment-not-found`   | GitHub returns 404 for the comment id                           | Report error; plan comment may have been deleted or re-filed. |
| `comment-id-missing`  | Conductor did not supply a comment id in the dispatch context   | Report error; escalate to Conductor.                         |

When any wrapper-level error is detected, return a structured error to Conductor rather than
attempting to fall back to a manual parse of the issue body.

Keep methodology in `SKILL.md`; this file is only the Copilot tool-binding shim.
