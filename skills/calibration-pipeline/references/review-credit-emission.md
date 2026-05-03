# Review v4 Credit Emission

Extracted per the D5 size-ceiling extraction pattern (issue #441 Step 8b, judge H2 fix).

## Frame Credits (v4) — review Row

After the judge ruling is finalized and the `<!-- judge-rulings -->` YAML block is
persisted as a PR comment, Code-Conductor constructs the v4 `review` credit row by
calling `Build-ReviewCreditRow` from
`.github/scripts/lib/frame-credit-ledger-core.ps1`.

### Calling Build-ReviewCreditRow

Locate the judge-rulings PR comment from the PR's comment list:

```powershell
# Find the comment containing <!-- judge-rulings -->
$judgeComment = (gh pr view {PR} --json comments --jq '.comments[]') |
    ConvertFrom-Json |
    Where-Object { $_.body -match '<!--\s*judge-rulings' } |
    Select-Object -Last 1

# Dot-source the library (already loaded by the hook in most contexts)
. ".github/scripts/lib/frame-credit-ledger-core.ps1"

# Build the credit row
$reviewRow = Build-ReviewCreditRow `
    -JudgeRulingsComment ([string]$judgeComment.body) `
    -AdapterName 'standard' `
    -RunIndex 1
```

The returned `$reviewRow` has the shape:

```yaml
port: review
adapter: standard         # or 'lite', 'proxy-github', 'judge-only' per the review mode
status: passed            # or 'failed' when any sustained finding has P+10 (Critical/High)
run_index: 1
evidence: "Review completed; N finding(s) sustained, status: passed."
judge-score:
  findings_sustained: N
  prosecutor_points: P
  defense_points: D
integrity-check: passed   # or 'not-applicable' for adapters with exempt: true
```

Include this row in the `credits[]` array of the pipeline-metrics block when creating
or updating the PR body.

### Status semantics

`Build-ReviewCreditRow` sets `status: failed` when any finding has
`judge_ruling: sustained` AND `points_awarded` matches `P\+10\b` (10 or more points,
bounded — will not match `P+100`). All other sustained findings produce `status: passed`.

This maps to the routing table in `frame/ports/review.yaml`.

### Adapter selection

| Review mode | AdapterName |
|---|---|
| Full prosecution × 3 → defense → judge | `standard` |
| Lite (single compact pass) | `lite` |
| Judge-only (no prosecution/defense) | `judge-only` |
| Proxy-GitHub (inherits from upstream) | `proxy-github` |

### RunIndex

Set `run_index` to `1` for the first review cycle. Increment when a prior `review`
credit row already exists in the PR body for the same `(port, adapter)` pair (e.g.,
a re-review after a fix cycle).

### Cross-tool handoff

`Build-ReviewCreditRow` is a pure PowerShell function. On the Claude Code path,
Code-Conductor invokes it via Bash tool or inline PowerShell, then includes the
returned row YAML in the PR body `<!-- pipeline-metrics -->` block at PR creation
time.

On the Copilot path, the same lib is dot-sourced and called from the workflow hooks.

### CE Gate S3 coverage

CE Gate scenario S3 verifies that PR #446 (which has a `<!-- review-judge-produced-446 -->`
sentinel comment but no review credit in its pipeline-metrics block) receives a
synthesized `not-persisted` review credit from `Resolve-NotPersistedSynthesis`
(running in the warn-hook on every pre-PR check). The `Build-ReviewCreditRow`
function is used on the Code-Conductor PR-creation path to emit a `passed` or
`failed` credit when the judge ruling is directly available; `Resolve-NotPersistedSynthesis`
handles the deferred case where the judge ran but the credit was never written.
