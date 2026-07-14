#Requires -Version 7.0
<#
.SYNOPSIS
    Thin CLI wrapper for the phase-containment escape-rate ledger.
.DESCRIPTION
    Dot-sources the rolling-history core library and renders a per-stage
    report, then appends a presentation-only review-cost section (issue
    #768). Calls Get-PhaseContainmentHistory to fetch and deduplicate value
    entries, then Get-PhaseContainmentRollup to aggregate per-stage
    escape/irreducible rates. Separately fetches the raw comment corpus via
    Get-PhaseContainmentCommentCorpus and rolls it up via
    Get-ReviewCostRollup / Format-ReviewCostSection to render per-stage
    dismiss-rate / defense-kill rate / defer cost metrics immediately after
    the value report.

    Output is intended as a CE Gate surface: insufficient_data and data_untrustworthy
    paths are displayed clearly so a maintainer cannot mistake "not enough data" for "clean."

    Dot-source order (issue #768 s6, judge-sustained M11): the value path
    (Get-PhaseContainmentHistory, Get-PhaseContainmentRollup,
    Format-PhaseContainmentReport, Get-PhaseContainmentCommentCorpus) lives in
    phase-containment-rolling-history-core.ps1 (frozen, dot-sourced first).
    Get-DispositionTally — which phase-containment-cost-core.ps1's
    Get-ReviewCostRollup calls — lives in
    phase-containment-emission-check-core.ps1, so that file is dot-sourced
    SECOND, explicitly, before phase-containment-cost-core.ps1 (dot-sourced
    third) ever has a chance to invoke it. phase-containment-cost-core.ps1
    also dot-sources phase-containment-emission-check-core.ps1 itself as an
    internal safety net (its own standing dependency declaration) — this
    file's explicit second dot-source is intentionally redundant with that:
    it makes the load-bearing order visible and correct standalone at the
    CLI-file level too, rather than relying on a transitive dot-source deep
    inside a sibling file. Both this file's own Pester coverage and the new
    phase-containment-cost-core.Tests.ps1 coverage replicate this same
    explicit three-file order rather than depending on Pester global-scope
    leakage from another test file's earlier dot-source in the same run.
.EXAMPLE
    pwsh -File .github/scripts/phase-containment-report.ps1
    pwsh -File .github/scripts/phase-containment-report.ps1 -WindowDays 30
    pwsh -File .github/scripts/phase-containment-report.ps1 -ValueCacheOk
#>

param(
    [string]$RepoOwner = '',
    [string]$RepoName  = '',
    [int]$WindowDays   = 90,
    [string]$Token     = $env:GH_TOKEN,
    [switch]$NoCache,
    [switch]$ValueCacheOk
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---- Dot-source order (issue #768 s6, judge-sustained M11 — see header) ----
$libRoot = Join-Path $PSScriptRoot 'lib'
. (Join-Path $libRoot 'phase-containment-rolling-history-core.ps1')
. (Join-Path $libRoot 'phase-containment-emission-check-core.ps1')
. (Join-Path $libRoot 'phase-containment-cost-core.ps1')

function Invoke-PhaseContainmentReportCli {
    <#
    .SYNOPSIS
        Core CLI logic, extracted into a function (issue #768 s6, judge-
        sustained M5) so Pester can dot-source this file, mock
        Get-PhaseContainmentHistory / Get-PhaseContainmentCommentCorpus, and
        call this function directly without a live `gh` fetch.
    .DESCRIPTION
        Fetch coherence (judge-sustained M8): the cache-bypass decision below
        edits $fetchParams BEFORE the value fetch call, not after the value
        report render. By default (no -ValueCacheOk) the value fetch bypasses
        its 1-hour cache so it is same-run fresh alongside the cost corpus
        fetch (Get-PhaseContainmentCommentCorpus, which never caches) —
        otherwise the two halves could silently describe different fetch
        moments. -ValueCacheOk restores cached-value mode and renders an
        explicit population-mismatch caveat. Precedence: -NoCache always wins
        over -ValueCacheOk (both bypass -> fresh, no caveat needed), since
        -NoCache is the stronger "always fresh" signal.

        Isolation (judge-sustained M5/M8): the value report ALWAYS renders,
        in full, before the cost path's try/catch region begins — a thrown
        exception anywhere in the cost path (corpus fetch, rollup, or
        rendering) can therefore never suppress the value report. On
        exception, a single "cost section unavailable: {reason}" line is
        printed instead of the cost section.
    .PARAMETER RepoOwner
        GitHub repository owner.
    .PARAMETER RepoName
        GitHub repository name.
    .PARAMETER WindowDays
        Number of past days to scan.
    .PARAMETER Token
        GitHub token, passed through to both fetches.
    .PARAMETER NoCache
        Forces the value fetch to bypass its 1-hour cache. Wins over
        -ValueCacheOk when both are supplied.
    .PARAMETER ValueCacheOk
        Restores cached-value mode for the value fetch (opting back out of
        the default same-run-fresh coherence behavior). Renders an explicit
        population-mismatch caveat when it takes effect.
    .OUTPUTS
        [string[]] — the full report (value report + cost section, or value
        report + degradation/caveat lines), written via Write-Output.
    #>
    [CmdletBinding()]
    param(
        [string]$RepoOwner,
        [string]$RepoName,
        [int]$WindowDays,
        [string]$Token,
        [switch]$NoCache,
        [switch]$ValueCacheOk
    )

    # ---- Fetch coherence (issue #768 s6, judge-sustained M8) ----
    # Edited BEFORE the value fetch call below (not appended after the
    # report render) so it actually governs the value fetch's cache
    # behavior. bypassValueCache is true whenever the run should be
    # same-run-fresh: the default (neither switch), -NoCache alone, or both
    # switches together (NoCache wins). It is false ONLY when -ValueCacheOk
    # is supplied without -NoCache.
    $bypassValueCache = $NoCache -or (-not $ValueCacheOk)
    $renderCacheCaveat = -not $bypassValueCache

    $fetchParams = @{
        RepoOwner  = $RepoOwner
        RepoName   = $RepoName
        WindowDays = $WindowDays
    }
    if ($Token) {
        $fetchParams['Token'] = $Token
    }
    if ($bypassValueCache) {
        # Force cache miss by pointing at a non-existent path.
        $fetchParams['CachePath'] = [System.IO.Path]::GetTempFileName() + '.nocache.json'
    }

    $history = Get-PhaseContainmentHistory @fetchParams

    $entries           = @($history.Entries)
    $fetchedAt         = $history.FetchedAt
    $source            = $history.Source
    $truncated         = $history.Truncated
    $invalidEntryCount = $history.InvalidEntryCount

    # ---- Compute rollup ----

    $rollup = Get-PhaseContainmentRollup -Entries $entries -WindowLabel "${WindowDays}d" -Truncated:$truncated

    # ---- Render value report ----
    # This MUST happen, and complete, before the cost path's try/catch
    # region below begins — a cost-path exception can then never suppress
    # it (issue #768 s6, judge-sustained M5/M8 isolation requirement).

    $reportContext = @{
        Rollup            = $rollup
        Source            = $source
        Truncated         = $truncated
        WindowDays        = $WindowDays
        FetchedAt         = $fetchedAt
        InvalidEntryCount = $invalidEntryCount
    }

    Format-PhaseContainmentReport -Context $reportContext | Write-Output

    if ($renderCacheCaveat) {
        Write-Output ''
        Write-Output 'CAVEAT: -ValueCacheOk was used; the value report above may reflect a cached fetch from an earlier run, while the cost section below (Get-PhaseContainmentCommentCorpus never caches) is same-run fresh. The two halves may describe different underlying comment populations -- do not read them as a single-moment snapshot.'
    }

    # ---- Cost path (issue #768 s6) ----
    # Wrapped end-to-end (corpus fetch through rendering) in a single
    # try/catch: on ANY exception here, print one degradation line and stop
    # -- the value report above has already rendered and is unaffected.
    try {
        $corpusParams = @{
            RepoOwner  = $RepoOwner
            RepoName   = $RepoName
            WindowDays = $WindowDays
        }
        if ($Token) {
            $corpusParams['Token'] = $Token
        }
        $corpus = Get-PhaseContainmentCommentCorpus @corpusParams

        if ($corpus.Truncated -ne $truncated) {
            Write-Output ''
            Write-Output "WARNING: the value fetch (Truncated=$truncated) and the cost corpus fetch (Truncated=$($corpus.Truncated)) disagree on truncation state -- the two halves may reflect divergent populations; treat any side-by-side comparison with caution rather than a confident match."
        }

        # Value-side PR-number set (issue #768 s6, judge-sustained M10): the
        # validated Entries' 'pr' surface (code-review's judge-rulings-on-PR
        # population), NOT a raw corpus tuple approximation, so the
        # forward-gap count reflects the same honest PR population the
        # value ledger uses.
        $valuePresentPrNumbers = @(
            $entries |
                Where-Object {
                    $s = if ($_ -is [hashtable]) { $_['surface'] } else { $_.surface }
                    $s -eq 'pr'
                } |
                ForEach-Object {
                    if ($_ -is [hashtable]) { [int]$_['issueOrPrNumber'] } else { [int]$_.issueOrPrNumber }
                } |
                Select-Object -Unique
        )

        $costRollup = Get-ReviewCostRollup -Tuples $corpus.Tuples -Source $corpus.Source -Truncated $corpus.Truncated -ValuePresentPrNumbers $valuePresentPrNumbers

        Format-ReviewCostSection -Rollup $costRollup | Write-Output
    }
    catch {
        Write-Output ''
        Write-Output "cost section unavailable: $($_.Exception.Message)"
    }
}

# Only auto-invoke when this file is executed directly (e.g. `pwsh -File` or
# `& script.ps1`), never when dot-sourced -- Pester dot-sources this file to
# load Invoke-PhaseContainmentReportCli (and, transitively, every function
# above) without triggering a live `gh` fetch.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-PhaseContainmentReportCli -RepoOwner $RepoOwner -RepoName $RepoName -WindowDays $WindowDays -Token $Token -NoCache:$NoCache -ValueCacheOk:$ValueCacheOk
}
