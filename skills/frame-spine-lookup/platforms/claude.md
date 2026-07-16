# Platform — Claude Code

`frame-spine-lookup` is used by Claude Code specialist shells when they need to
fetch an adjacent plan slice mid-turn. Specialists that have `Read` and `Bash`
grants can invoke this contract; see [Tool-Grant Verification](../SKILL.md#tool-grant-verification)
in the parent skill for the complete list.

Claude bindings:

- Use the `Bash` tool to fetch the plan-issue comment body:
  `gh api repos/{owner}/{repo}/issues/comments/{id} --jq .body > /tmp/plan-body.md`
  (`gh api repos/{owner}/{repo}/issues/comments/{id}` — pipe the `.body` field to a temp file.)
- **When a sibling comment id was dispatched** (the spine's `slice_comment_id` was present at
  dispatch time), also fetch the sibling body the same way:
  `gh api repos/{owner}/{repo}/issues/comments/{sibling-id} --jq .body > /tmp/sibling-body.md`
  Then run the identity check before concatenating — verify the sibling body carries a
  `<!-- frame-slices-{ID} -->` marker matching the dispatched issue number:
  `grep -q -- "<!-- frame-slices-{issue-id} -->" /tmp/sibling-body.md || echo sibling-identity-mismatch`
  If that check fails, report `sibling-identity-mismatch` to Conductor and stop — do not proceed
  to concatenation or invoke the lookup. If it passes, concatenate plan body then sibling body
  with a single blank line between them (plan body first):
  `{ cat /tmp/plan-body.md; printf '\n\n'; cat /tmp/sibling-body.md; } > /tmp/lookup-body.md`
- **When no sibling id was dispatched** (legacy plan, no `slice_comment_id` on the spine), use
  `/tmp/plan-body.md` directly as the lookup body — this is the unchanged single-fetch shape.
- Use the `Bash` tool to invoke the lookup against whichever body was produced above
  (`/tmp/lookup-body.md` when a sibling was fetched, `/tmp/plan-body.md` otherwise):
  `pwsh -File .github/scripts/lib/frame-spine-core.ps1 -Op Lookup -CommentBodyPath {path} -GeneratedAt {generated_at} -StepId {id} -Format Json`
- Parse the JSON `status` field to determine the outcome. Do **not** branch on exit code alone —
  `stale-spine` exits 0. See the Exit Codes table in `SKILL.md` for the complete list.
- On `stale-spine` result, stop specialist work and return control to Conductor.
- Do **not** use `AskUserQuestion` — stale-spine pause belongs to Conductor via its own step.

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

Keep methodology in `SKILL.md`; this file is only the Claude tool-binding shim.
