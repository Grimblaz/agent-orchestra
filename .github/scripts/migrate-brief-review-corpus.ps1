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
# Item-5 fix (#963 review): dot-sourced for the shared
# Get-MarkerWholeLinePattern builder. This script deliberately paginates the
# REST comments endpoint directly (see script:Get-IssueComments) rather than
# switching to that file's `gh issue view`-based comment listing.
#
# THIS DOT-SOURCE ALSO HAS A LOAD-TIME SIDE EFFECT, and it is load-bearing
# (post-fix review, finding M16). marker-transport-core.ps1 sets
# [Console]::OutputEncoding to UTF-8 as its own first top-level statement,
# which fires here at dot-source time. That pin governs how `& gh api` stdout
# is decoded on the reads below AND how the ConvertTo-Json payload is encoded
# on its way into `gh api --input -`. This script had no such pin before.
# Do NOT "simplify" this away by inlining a local one-line pattern builder:
# the bodies are ASCII today, so nothing would visibly break, but the
# protection against a non-ASCII round-trip would be silently gone.
. (Join-Path $PSScriptRoot 'lib/marker-transport-core.ps1')

function script:Get-IssueComments {
    param([Parameter(Mandatory)][int]$Number)
    # Item-11 fix (#963 review): capture stderr instead of discarding it, so a
    # `gh` failure's actual message (auth expired, rate-limited, network) rides
    # along in the thrown error rather than forcing a re-run just to see it.
    $raw = & gh api "repos/$RepoOwner/$RepoName/issues/$Number/comments" --paginate 2>&1
    if ($LASTEXITCODE -ne 0) {
        $stderrText = ($raw | ForEach-Object { $_.ToString() }) -join "`n"
        throw "gh api failed reading comments for issue #$Number (exit $LASTEXITCODE): $stderrText"
    }
    # Strip ErrorRecords before parsing (post-fix review, finding M3). `2>&1`
    # is what lets the failure path above report gh's actual message, but it
    # also merges stderr into $raw on the SUCCESS path, where any
    # stderr-on-zero-exit line would be prepended to the JSON text and make
    # ConvertFrom-Json throw a parse error instead. Keep the diagnostic, drop
    # the hazard: only the stdout strings reach the parser.
    return @((($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) | Out-String) | ConvertFrom-Json)
}

function script:Get-SingleCommentBody {
    param([Parameter(Mandatory)][long]$CommentId)
    # Item-12 support: single-comment re-fetch used as the compare-and-swap
    # check immediately before a PATCH (see the write branch below).
    $raw = & gh api "repos/$RepoOwner/$RepoName/issues/comments/$CommentId" 2>&1
    if ($LASTEXITCODE -ne 0) {
        $stderrText = ($raw | ForEach-Object { $_.ToString() }) -join "`n"
        throw "gh api failed reading comment $CommentId immediately before PATCH (exit $LASTEXITCODE): $stderrText"
    }
    # Same ErrorRecord strip as Get-IssueComments (post-fix review, finding M3),
    # and it matters more here: this call sits inside the compare-and-swap
    # immediately before the PATCH, so a parse throw would abort the migration
    # instead of producing the diagnosable abort item-12 was written to give.
    $parsed = (($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) | Out-String) | ConvertFrom-Json
    return [string]$parsed.body
}

function script:Set-CommentBody {
    param([Parameter(Mandatory)][long]$CommentId, [Parameter(Mandatory)][string]$Body)
    # --input - with a JSON document on stdin. Never -f body=@path: that form
    # can send the literal path string, and never a shell-interpolated body:
    # these bodies contain backticks, dollar signs and newlines.
    $payload = @{ body = $Body } | ConvertTo-Json -Depth 3 -Compress
    # Item-11 fix (#963 review): capture stderr instead of discarding it.
    $patchOutput = $payload | & gh api "repos/$RepoOwner/$RepoName/issues/comments/$CommentId" -X PATCH --input - 2>&1
    if ($LASTEXITCODE -ne 0) {
        $stderrText = ($patchOutput | ForEach-Object { $_.ToString() }) -join "`n"
        throw "gh api PATCH failed for comment $CommentId (exit $LASTEXITCODE): $stderrText"
    }
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
    # Item-5 fix (#963 review): line-anchored, whole-line match via the
    # repo's shared Get-MarkerWholeLinePattern convention (see
    # Find-CommentIdByExactMarker in marker-transport-core.ps1), not a
    # substring .Contains() check. A substring match would select a comment
    # that merely quotes the marker in prose ahead of the real sibling.
    $ledgerLinePattern = Get-MarkerWholeLinePattern -Marker $ledgerMarker
    $sibling = @($comments | Where-Object { $_.body -and ([regex]::IsMatch([string]$_.body, $ledgerLinePattern)) }) | Select-Object -First 1
    if ($null -eq $sibling) {
        Write-Host "  FAILED: no comment carrying $ledgerMarker found."
        $overallOk = $false
        continue
    }

    $result = Convert-BRMLedgerBody -Body ([string]$sibling.body) -Issue $issueNumber
    # Item-13 fix (#963 review): track the ACTUAL write outcome instead of
    # inferring it later from $WhatIfPreference. ShouldProcess can return
    # false without -WhatIf being set (a declined -Confirm prompt), and the
    # old inference treated that case as "a real write happened" for
    # verification purposes.
    $didWrite = $false
    if (-not $result.Changed) {
        Write-Host "  no-op ($($result.Reason)) — this issue is already corrected. Re-running is how an interrupted run is resolved."
    }
    elseif ($PSCmdlet.ShouldProcess("comment $($sibling.id) on issue #$issueNumber", 'PATCH ledger sibling body')) {
        # Item-12 fix (#963 review): compare-and-swap immediately before the
        # PATCH. `gh api` offers no If-Match/ETag precondition for issue
        # comments, so this cannot CLOSE the append race the header already
        # documents as "narrowed, not closed" -- but it DETECTS the exact
        # window that race describes (a concurrent append landing between the
        # read above and this write) instead of silently clobbering it.
        # `-cne`, never `-ne` (post-fix review, finding M13). PowerShell's `-ne`
        # on strings is case-INSENSITIVE and culture-sensitive, so a concurrent
        # edit differing only in letter case would compare EQUAL and sail
        # through the very check whose only job is detecting a lost update.
        # The ordinal form can produce a spurious abort where the loose one did
        # not, which is the fail-closed direction and therefore acceptable.
        $liveBodyNow = script:Get-SingleCommentBody -CommentId ([long]$sibling.id)
        if ($liveBodyNow -cne [string]$sibling.body) {
            $overallOk = $false
            Write-Host "  ABORTED: comment $($sibling.id) changed since it was read (concurrent write detected). Re-run to pick up the new body rather than overwriting it."
            continue
        }
        script:Set-CommentBody -CommentId ([long]$sibling.id) -Body $result.Body
        Write-Host "  wrote comment $($sibling.id)."
        $didWrite = $true
    }
    elseif ($WhatIfPreference) {
        Write-Host "  WhatIf: would rewrite comment $($sibling.id) ($($result.Body.Length) chars vs $($sibling.body.Length))."
    }
    else {
        # A DECLINED -Confirm, not a dry run (post-fix review, finding M14).
        #
        # ShouldProcess returns false for two very different reasons, and item-13
        # originally collapsed them. `-WhatIf` is a dry run: the operator asked
        # what WOULD happen, nothing is wrong, exit 0 is correct. A declined
        # `-Confirm` is a REFUSAL: the operator was shown this exact write and
        # said no, so the corpus is knowingly left uncorrected and the run must
        # not report success. Before item-13 the decline fell through to the
        # re-fetch branch, failed verification against the unchanged corpus and
        # exited 1; item-13's $didWrite correctly redirected the verify TARGET
        # but also made the decline verify green and exit 0 under the banner
        # "Migration complete and verified at verdict grain." An automation
        # wrapper keying on $LASTEXITCODE would read a refused migration as a
        # completed one.
        #
        # $overallOk is set here rather than in a shared else branch on purpose:
        # doing it for both cases would make a plain -WhatIf dry run exit 1.
        $overallOk = $false
        Write-Host "  DECLINED: the write to comment $($sibling.id) was not confirmed, so this issue is NOT corrected. Exiting non-zero so a caller cannot mistake a refusal for a completed migration."
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
    $verifyBodies = if (-not $didWrite) {
        # Item-13 fix (#963 review): branch on the captured $didWrite outcome,
        # not $WhatIfPreference -or -not $result.Changed. Covers -WhatIf, the
        # already-corrected no-op, AND a declined -Confirm prompt uniformly:
        # none of them wrote anything, so all three verify against the
        # PROPOSED corpus rather than re-fetching as though the PATCH landed.
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
