# Platform — Copilot (VS Code)

`frame-spine-lookup` is used by Copilot specialist agents when they need to
fetch an adjacent plan slice mid-turn. Specialists that have `execute/runInTerminal`
(or `execute`) can invoke this contract; see [Tool-Grant Verification](../SKILL.md#tool-grant-verification)
in the parent skill for the complete list.

Copilot bindings:

- **When no sibling comment id was dispatched** (legacy plan, no `slice_comment_id` on the
  spine): the original single-pipeline shape is unchanged —
  use `execute/runInTerminal` to fetch the plan-issue comment body and pipe it via stdin:
  `gh api repos/{owner}/{repo}/issues/comments/{id} --jq .body | pwsh -File .github/scripts/lib/frame-spine-core.ps1 -Op Lookup -CommentBodyStdin -Format Json -GeneratedAt {generated_at} -StepId {id}`
  (`-CommentBodyStdin` and `-Format Json` added in issue #514.)
- **When a sibling comment id was dispatched**: a single `gh api ... | pwsh ...` pipeline cannot
  express two independent `gh api` reads into one stdin, so restructure into separate
  `execute/runInTerminal` calls that write to temp files, then concatenate to a file and invoke
  lookup by path instead of by stdin:
  1. Fetch the plan comment body to a temp file:
     `gh api repos/{owner}/{repo}/issues/comments/{id} --jq .body > $env:TEMP\plan-body.md`
  2. Fetch the sibling comment body to a second temp file:
     `gh api repos/{owner}/{repo}/issues/comments/{sibling-id} --jq .body > $env:TEMP\sibling-body.md`
  3. Run the identity check before concatenating — verify the sibling body carries a
     `<!-- frame-slices-{ID} -->` marker matching the dispatched issue number:
     `if (-not (Select-String -Path $env:TEMP\sibling-body.md -Pattern '<!-- frame-slices-{issue-id} -->' -Quiet)) { Write-Output 'sibling-identity-mismatch' }`
     If that check reports `sibling-identity-mismatch`, report it to Conductor and stop — do not
     proceed to step 4.
  4. Concatenate plan body then sibling body with a single blank line between them (plan body
     first) into one lookup body file:
     `(Get-Content $env:TEMP\plan-body.md -Raw) + "`n`n" + (Get-Content $env:TEMP\sibling-body.md -Raw) | Set-Content $env:TEMP\lookup-body.md -NoNewline`
  5. Invoke lookup against the concatenated file by path (not stdin):
     `pwsh -File .github/scripts/lib/frame-spine-core.ps1 -Op Lookup -CommentBodyPath $env:TEMP\lookup-body.md -Format Json -GeneratedAt {generated_at} -StepId {id}`
- Parse the JSON `status` field to determine the outcome. Do **not** branch on exit code alone —
  `stale-spine` exits 0. See the Exit Codes table in `SKILL.md` for the complete list.
- On `stale-spine` result, stop specialist work and return control to Conductor.
- Conductor pauses via `vscode/askQuestions` with the standard re-dispatch options.
- Do **not** use `vscode/askQuestions` from within the specialist — stale-spine pause belongs to Conductor.

**Wrapper-level error handling** (failures before the script runs):

| Error code                  | Cause                                                            | Specialist action                                              |
| ---------------------------- | ----------------------------------------------------------------- | ------------------------------------------------------------- |
| `gh-not-installed`           | `gh` CLI not found on PATH                                        | Report error; do not continue implementation.                 |
| `gh-auth-expired`            | `gh auth status` fails; token invalid or expired                  | Report error; do not continue implementation.                 |
| `gh-rate-limited`            | GitHub API returns 403/429                                        | Report error; do not continue implementation.                 |
| `pwsh-not-found`             | `pwsh` (PowerShell 7+) not found on PATH                          | Report error; do not continue implementation.                 |
| `comment-not-found`          | GitHub returns 404 for the comment id                             | Report error; plan comment may have been deleted or re-filed. |
| `comment-id-missing`         | Conductor did not supply a comment id in the dispatch context     | Report error; escalate to Conductor.                          |
| `sibling-identity-mismatch`  | Fetched sibling body's `<!-- frame-slices-{ID} -->` marker does not match the dispatched issue number, or the marker is absent | Report error; do not concatenate or invoke lookup; escalate to Conductor as a possible stale or copy-pasted sibling id. |

When any wrapper-level error is detected, return a structured error to Conductor rather than
attempting to fall back to a manual parse of the issue body.

This file is frozen with the rest of the Copilot/VS Code surface per `CLAUDE.md`'s
GitHub Copilot deprecation notice — no further fixes are expected here.

Keep methodology in `SKILL.md`; this file is only the Copilot tool-binding shim.
