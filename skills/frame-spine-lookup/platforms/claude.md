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
- Parse the JSON `status` field to determine the outcome. Do **not** branch on exit code alone —
  `stale-spine` exits 0. See the Exit Codes table in `SKILL.md` for the complete list.
- On `stale-spine` result, stop specialist work and return control to Conductor.
- Do **not** use `AskUserQuestion` — stale-spine pause belongs to Conductor via its own step.

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

Keep methodology in `SKILL.md`; this file is only the Claude tool-binding shim.
