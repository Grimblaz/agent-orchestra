#Requires -Version 7.0
<#!
.SYNOPSIS
    Issue #951 D5 — the one-time corpus correction for the phase-containment
    ledger's falsely judge-attributed plan-surface rows.

.DESCRIPTION
    Fifty-six ledger rows across #939 and #941 assert `judge_ruling: sustained`
    for reviews no judge adjudicated. Both runs were reviewed under #936 D5's
    prosecution-only chunk-plan charter, which has no judge stage; both wrote
    the judge vocabulary anyway because it was the only vocabulary that
    existed, and both said so in a YAML comment no reader parses.

    This script corrects them:
      #939 — 29 rows relabelled to `caught_stage: brief-review` with matching
             `finding_key` prefixes, authorized by a conformant
             `brief_dispositions:` head declaring that the convergence filter
             ran and narrowed the panel's output by 8.
      #941 — 27 rows withdrawn. That review skipped the convergence filter, so
             its rows are raw prosecution output; relabelling them would move
             an ungraded population into the new sub-arm rather than removing
             the contamination. Its head is replaced by one declaring
             `convergence_filter_ran: false`, which authorizes no count and
             renders the honest unverified state.

    WHY THIS SCRIPT EXISTS AT ALL, rather than a documented primitive.
    `persist-phase-ledger.ps1` is the only sanctioned writer into this corpus,
    and it has no relabel mode, no withdraw mode, and an append-only block
    writer. It structurally cannot express this correction. Amendment A1(f)
    decided to amend the doctrine and bless this script as the SOLE sanctioned
    exception, bounded to this one-time correction — see
    skills/plan-authoring/SKILL.md § Phase-containment emission. It refuses any
    issue outside that bound.

    AND WHY A SCRIPT RATHER THAN DOING IT BY HAND. Hand-authoring blocks into
    this corpus is a documented failure mode: #944 records seven
    machine-invisible blocks produced that way. A hand edit also cannot express
    the coupled `caught_stage` + `finding_key` rewrite reliably, and cannot
    perform the post-write re-parse that catches a write which landed in the
    wrong shape.

    THE APPEND RACE IS NARROWED, NOT CLOSED — corrected here after the #963
    review found the original claim false. Re-reading immediately before the
    PATCH shrinks the window; the post-write re-parse does NOT close it. A
    concurrent append landing between the read and the PATCH is clobbered, and
    because the verification asserts the EXPECTED row count, the corpus is left
    at exactly that count and the check passes on the loss — the same shape
    that cost #922 sixteen rows. `gh api PATCH` offers no If-Match/ETag
    precondition for issue comments, so the only real mitigations are
    operational: run this when nothing else is writing to #939/#941, and
    confirm the pre-write body length reported below matches what you expect.

    HONEST LIMIT, recorded rather than papered over: this narrows the
    enforcement gap, it does not close it. Someone still has to run it. A test
    asserting the corrected end state would be red until the migration ran, and
    a red pull request cannot merge, so no clean continuous-integration gate is
    available. Running this is a precondition of CLOSING #951, not of merging
    its pull request.

.PARAMETER Issue
    Restrict the run to one issue. Omit to process every planned correction.

.PARAMETER WhatIf
    Compute and report what would change, and run the verdict-grain
    verification against the PROPOSED bodies, without writing anything.

.EXAMPLE
    pwsh .github/scripts/migrate-brief-review-corpus.ps1 -WhatIf
    pwsh .github/scripts/migrate-brief-review-corpus.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [int]$Issue = 0,
    [string]$RepoOwner = 'Grimblaz',
    [string]$RepoName = 'agent-orchestra'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/phase-containment-core.ps1')
. (Join-Path $PSScriptRoot 'lib/phase-containment-emission-check-core.ps1')
. (Join-Path $PSScriptRoot 'lib/brief-review-migration-core.ps1')

function script:Get-IssueComments {
    param([Parameter(Mandatory)][int]$Number)
    $raw = & gh api "repos/$RepoOwner/$RepoName/issues/$Number/comments" --paginate 2>$null
    if ($LASTEXITCODE -ne 0) { throw "gh api failed reading comments for issue #$Number (exit $LASTEXITCODE)" }
    return @(($raw | Out-String) | ConvertFrom-Json)
}

function script:Set-CommentBody {
    param([Parameter(Mandatory)][long]$CommentId, [Parameter(Mandatory)][string]$Body)
    # --input - with a JSON document on stdin. Never -f body=@path: that form
    # can send the literal path string, and never a shell-interpolated body:
    # these bodies contain backticks, dollar signs and newlines.
    $payload = @{ body = $Body } | ConvertTo-Json -Depth 3 -Compress
    $payload | & gh api "repos/$RepoOwner/$RepoName/issues/comments/$CommentId" -X PATCH --input - > $null 2>&1
    if ($LASTEXITCODE -ne 0) { throw "gh api PATCH failed for comment $CommentId (exit $LASTEXITCODE)" }
}

$plannedIssues = if ($Issue -gt 0) { @($Issue) } else { @($script:BRMPlannedCorrections | ForEach-Object { $_.Issue }) }

$overallOk = $true
foreach ($issueNumber in $plannedIssues) {
    $plan = Get-BRMPlannedCorrection -Issue $issueNumber
    if ($null -eq $plan) {
        Write-Host "REFUSED  #${issueNumber}: outside this one-time migration's sanctioned bound. This script is not a general-purpose ledger writer."
        $overallOk = $false
        continue
    }

    Write-Host ""
    Write-Host "=== #${issueNumber} ($($plan.Action)) ==="

    # Read LIVE, immediately before writing. The ledger sibling is an append
    # target by contract, so a body fetched minutes ago may already be stale;
    # #922 lost sixteen rows to exactly that read-modify-write window.
    # Re-reading NARROWS the window. Nothing here closes it — see the header's
    # "THE APPEND RACE IS NARROWED, NOT CLOSED".
    $comments = script:Get-IssueComments -Number $issueNumber
    $ledgerMarker = "<!-- phase-containment-ledger-$issueNumber -->"
    $sibling = @($comments | Where-Object { $_.body -and $_.body.Contains($ledgerMarker) }) | Select-Object -First 1
    if ($null -eq $sibling) {
        Write-Host "  FAILED: no comment carrying $ledgerMarker found."
        $overallOk = $false
        continue
    }

    $result = Convert-BRMLedgerBody -Body ([string]$sibling.body) -Issue $issueNumber
    if (-not $result.Changed) {
        Write-Host "  no-op ($($result.Reason)) — this issue is already corrected. Re-running is how an interrupted run is resolved."
    }
    elseif ($PSCmdlet.ShouldProcess("comment $($sibling.id) on issue #$issueNumber", 'PATCH ledger sibling body')) {
        script:Set-CommentBody -CommentId ([long]$sibling.id) -Body $result.Body
        Write-Host "  wrote comment $($sibling.id)."
    }
    else {
        Write-Host "  WhatIf: would rewrite comment $($sibling.id) ($($result.Body.Length) chars vs $($sibling.body.Length))."
    }

    # ------------------------------------------------------------------
    # VERDICT-GRAIN SELF-VERIFICATION.
    #
    # Re-FETCH (never reuse the body just sent — that would verify the
    # request, not the corpus), re-PARSE through the production reader, and
    # re-RENDER the emission verdict. Amendment A1(c): a count-grain recount
    # passes on a corpus whose rows are all present, all parseable, and all
    # invisible to every reader, which is exactly what a caught_stage-only
    # relabel produces. Only re-rendering the verdict fails in that case.
    # ------------------------------------------------------------------
    $verifyBodies = if ($WhatIfPreference -or -not $result.Changed) {
        # Nothing was written: verify against the PROPOSED corpus so -WhatIf
        # still exercises the real predicate rather than reporting nothing.
        @($comments | ForEach-Object {
                if ($_.id -eq $sibling.id) { $result.Body } else { [string]$_.body }
            })
    }
    else {
        @((script:Get-IssueComments -Number $issueNumber) | ForEach-Object { [string]$_.body })
    }

    $verdict = Test-BRMCorrectedVerdict -Bodies $verifyBodies -Issue $issueNumber
    Write-Host "  surfaces probed: $($verdict.Surfaces -join ', ')"
    Write-Host "  brief-review verdict: ParseStatus=$($verdict.Gap.ParseStatus) Reason=$($verdict.Gap.Reason) sustained=$($verdict.Gap.SustainedCount) blocks=$($verdict.Gap.BlockCount)"
    if ($verdict.Ok) {
        Write-Host "  VERIFIED: renders the planned terminal verdict."
    }
    else {
        $overallOk = $false
        Write-Host "  VERIFICATION FAILED:"
        foreach ($f in $verdict.Failures) { Write-Host "    - $f" }
    }
}

Write-Host ""
if ($overallOk) {
    Write-Host "Migration complete and verified at verdict grain."
    exit 0
}
Write-Host "Migration did NOT fully verify. The corpus may be partially corrected; re-run (this script is idempotent) and inspect the failures above."
exit 1
