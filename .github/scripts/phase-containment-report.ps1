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
    [string]$RepoOwner  = '',
    [string]$RepoName   = '',
    [int]$WindowDays    = 90,
    [string]$Token      = $env:GH_TOKEN,
    [switch]$NoCache,
    [switch]$ValueCacheOk,
    # Issue #854 s6: the identity a judge-authored review-dispositions/
    # judge-rulings comment is posted under. Caller-supplied (matches
    # Test-PhaseContainmentCommentAuthoredByJudge's contract, issue #854
    # s4 -- that function does not discover the judge identity itself).
    # Default mirrors the fixture convention Get-DispositionTally's own
    # Tests use for the repo's known CI poster identity.
    [string]$JudgeLogin = 'github-actions[bot]'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Issue #842 M4: resolve the judge identity from ambient `gh` auth when the
# caller (whether the script itself or a direct Invoke-PhaseContainmentReportCli
# caller) did not supply -JudgeLogin explicitly. Defined here, before both
# resolution sites below, so it exists at script scope in time for the
# (gated -- post-review M4 fix, see below) script-scope resolution
# immediately below AND for Invoke-PhaseContainmentReportCli's own
# function-level gate.
# ---------------------------------------------------------------------------
function Resolve-JudgeLogin {
    <#
    .SYNOPSIS
        Resolves the judge identity's login via `gh api user`.
    .DESCRIPTION
        Used whenever -JudgeLogin is not explicitly supplied, so the
        author-forgery gate (Test-PhaseContainmentCommentAuthoredByJudge)
        always has a real identity to compare against instead of falling
        back to the static 'github-actions[bot]' default literal, which is
        wrong for a run authenticated as a different account. An empty or
        whitespace-only return (auth failure, no ambient `gh` session) is
        the CALLER's responsibility to reject (issue #842 M21) — this
        function reports what `gh` returned, including a legitimate '' on
        failure, rather than throwing itself, so callers can choose their
        own fail-loud wording.
    .OUTPUTS
        [string] — the resolved login, or '' when resolution failed.
    .NOTES
        Identity-degradation envelope (issue #842 s6): the auto-resolved
        default assumes the report-runner IS the judge-poster. If that
        identity changes within a measurement window (maintainer handoff,
        bot migration, a different account running the report), older
        posters' entries silently filter out of `matched` under the NEW
        identity. This no longer degrades silently, though: it surfaces
        loudly via the FILTERED-EMPTY / INVALID-EMPTY render states
        (phase-containment-rolling-history-core.ps1, `Get-DispositionTally`'s
        DenominatorZero-branch discrimination) and the always-on header
        disclosure line naming the identity actually used, both added
        alongside this identity-resolution gate. Pass -JudgeLogin explicitly
        to pin the identity across a handoff instead of relying on the
        auto-resolved default.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    try {
        $login = & gh api user --jq '.login' 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "phase-containment-report: gh api user failed (exit $LASTEXITCODE) while resolving the judge identity"
            return ''
        }
        return [string]$login
    }
    catch {
        # Defensive: a missing `gh` binary or other native-command failure
        # must degrade to '' (a resolution failure the caller rejects per
        # M21), never crash whatever dot-sourced this file.
        Write-Warning "phase-containment-report: failed to resolve the judge identity: $_"
        return ''
    }
}

# ---- Script-scope identity resolution (issue #842 M4, post-review fix) ----
# M4 fix (judge-sustained): the earlier version of this block ran
# unconditionally at dot-source/load time -- every dot-source of this file
# (including Pester's own BeforeAll, before any mock is in place) shelled
# out to a live `gh api user` call. This is now gated on the SAME
# `$MyInvocation.InvocationName -ne '.'` check the auto-invoke guard at the
# bottom of this file uses, so dot-sourcing the file to reuse its functions
# (the whole point of the auto-invoke guard's own design) never triggers a
# live network call -- resolution only happens on the real `pwsh -File`
# execution path.
#
# M1 fix (judge-sustained): $JudgeLoginSource is captured HERE, at the one
# point where "the script's own caller passed -JudgeLogin explicitly" vs.
# "the script auto-resolved it from ambient gh auth" is still knowable. It
# is threaded through to Invoke-PhaseContainmentReportCli via
# -JudgeLoginSource below so the header's provenance label reflects what
# ACTUALLY happened here, rather than being re-derived from
# $PSBoundParameters.ContainsKey('JudgeLogin') inside the function -- that
# re-derivation can no longer tell the two cases apart once this script
# always forwards a concrete -JudgeLogin value (it would always say "from
# -JudgeLogin", even for an auto-resolved identity).
$JudgeLoginSource = $null
if ($MyInvocation.InvocationName -ne '.') {
    if ($PSBoundParameters.ContainsKey('JudgeLogin')) {
        $JudgeLoginSource = 'from -JudgeLogin'
    }
    else {
        $JudgeLogin = Resolve-JudgeLogin
        $JudgeLoginSource = 'resolved from gh auth'
    }
}

# ---- Dot-source order (issue #768 s6, judge-sustained M11 — see header) ----
$libRoot = Join-Path $PSScriptRoot 'lib'
. (Join-Path $libRoot 'phase-containment-rolling-history-core.ps1')
. (Join-Path $libRoot 'phase-containment-emission-check-core.ps1')
. (Join-Path $libRoot 'phase-containment-cost-core.ps1')

function Get-PhaseContainmentTerminalObservation {
    <#
    .SYNOPSIS
        Derives the -TerminalObservation hashtable for Get-PhaseContainmentRollup
        from the raw comment corpus (issue #854 s6).
    .DESCRIPTION
        Walks the corpus's PR-surface tuples, restricts every read to
        judge-authored bodies (Test-PhaseContainmentCommentAuthoredByJudge /
        JudgeLogin -- issue #854 s4, M8: a forged non-judge body must
        contribute ZERO coverage), and aggregates the Seam Specification's
        escape-side counts:
          CoObservedPRCount              N - all PR tuples in the fetched
                                          corpus window (the same population
                                          code-review already observes).
                                          NOT DD3's "co-observed" population
                                          (see MeasuredCoveragePRCount below)
                                          -- used only as the denominator for
                                          the K-of-N coverage-ratio display
                                          (M12 fix).
          MeasuredCoveragePRCount        K - PRs with a judge-authored,
                                          cleanly-parsed review-dispositions
                                          record carrying an
                                          ExternalSourcesReconciled coverage
                                          record (M9: a head-present, clean
                                          parse with zero entries IS a legal
                                          coverage record -- coverage means
                                          measurement, not >=1 finding; M5
                                          review fix: the earlier
                                          >=1-resolved-finding requirement
                                          wrongly zeroed out a legitimate
                                          zero-finding measurement and has
                                          been removed). This is also DD3's
                                          "co-observed" population -- n1
                                          (InternalCoObservedCatchCount) is
                                          scoped to PR numbers in THIS set,
                                          not to CoObservedPRCount's
                                          whole-window population (M2/M12
                                          fix).
          DispositionsNovelExternalCount, ExternalCatchCount (n2),
          DuplicateCount (m) - tallied from each PR's judge-authored,
                                latest-wins-per-stable_finding_key merged
                                entries (mirrors Get-ReviewCostRollup's
                                per-key dedup in phase-containment-cost-
                                core.ps1, restricted here to judge-authored
                                bodies only per the Seam Specification's
                                "restrict replacement to same-author
                                (judge) bodies" narrowing) whose MatchStatus
                                is 'duplicate' or 'novel' respectively;
                                'ambiguous' entries are excluded from both,
                                per the Seam Specification.
          InternalCoObservedCatchCount (n1) - derived from the ALREADY-
                                VALIDATED value-side $Entries (not the raw
                                corpus): caught_stage='code-review' AND
                                catchable_phase='implementation', non-
                                apparatus_meta, restricted to PR numbers in
                                the co-observed corpus (Seam Specification
                                n1 population rule).
        ObserverEscapeCount is intentionally omitted -- Get-PhaseContainmentRollup
        defaults it to the observer-block count it derives from $Entries
        directly.
    .PARAMETER Corpus
        The Get-PhaseContainmentCommentCorpus result (Tuples/Source/Truncated).
    .PARAMETER Entries
        The value-side Get-PhaseContainmentHistory.Entries array (already
        validated/deduped phase-containment blocks).
    .PARAMETER JudgeLogin
        The expected judge identity's login (issue #854 s4's
        Test-PhaseContainmentCommentAuthoredByJudge comparison target).
    .PARAMETER ValueCacheOk
        Seam Specification -ValueCacheOk coherence rule: $true when the
        value fetch is same-run-fresh (safe to join to the corpus); $false
        when the value fetch used a cached population (withholds the
        escape arm entirely; see Get-PhaseContainmentRollup's ValueCacheOk
        handling).
    .OUTPUTS
        [hashtable] suitable for Get-PhaseContainmentRollup -TerminalObservation.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Corpus,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entries,
        [Parameter(Mandatory)][string]$JudgeLogin,
        [Parameter(Mandatory)][bool]$ValueCacheOk
    )

    $prTuples = @($Corpus.Tuples | Where-Object { [string]$_.Surface -eq 'pr' })

    $coObservedPrNumbers = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($t in $prTuples) { $coObservedPrNumbers.Add([int]$t.Number) | Out-Null }

    $measuredCoveragePrNumbers      = [System.Collections.Generic.HashSet[int]]::new()
    $externalCatchCount             = 0
    $duplicateCount                 = 0
    $dispositionsNovelExternalCount = 0

    foreach ($tuple in $prTuples) {
        $number          = [int]$tuple.Number
        $bodies          = @($tuple.Bodies)
        $authorLogins    = @($tuple.AuthorLogins)
        $createdAtValues = @($tuple.CreatedAtValues)

        $judgeIdx = [System.Collections.Generic.List[int]]::new()
        for ($i = 0; $i -lt $bodies.Count; $i++) {
            $authorLogin = if ($i -lt $authorLogins.Count) { [string]$authorLogins[$i] } else { '' }
            if (Test-PhaseContainmentCommentAuthoredByJudge -AuthorLogin $authorLogin -JudgeLogin $JudgeLogin) {
                $judgeIdx.Add($i)
            }
        }
        if ($judgeIdx.Count -eq 0) { continue }

        $hadCoverageRecord     = $false
        $perKeyLatestEntry     = [System.Collections.Generic.Dictionary[string, PSCustomObject]]::new()
        $perKeyLatestCreatedAt = [System.Collections.Generic.Dictionary[string, datetime]]::new()

        foreach ($i in $judgeIdx) {
            $body = [string]$bodies[$i]
            # M13 fix: gate on the marker's OWN {N} matching this tuple's PR
            # number, so a judge-authored comment on this PR that happens to
            # quote a DIFFERENT PR's review-dispositions block is skipped
            # (not counted) rather than contributing to this PR's tallies.
            if (-not (Test-ReviewDispositionsHeadPresent -Body $body -ExpectedNumber $number)) { continue }

            $tally = Get-DispositionTally -Surface 'code-review' -Body $body
            if ($tally.ParseStatus -ne 'ok') { continue }
            # Post-fix batch 4 (issue #854 s6): gate the coverage/K signal on
            # ExternalSourcesFound, NOT on ParseStatus -eq 'ok' alone.
            # ParseStatus 'ok' only means this body's entries (if any) parsed
            # cleanly -- a purely internal-only review-dispositions marker
            # (e.g. a plain /orchestra:review pass, no GitHub-sourced review
            # ever reconciled against) also parses 'ok' when it carries real
            # entries, but it never attempted external reconciliation and
            # must NOT be counted as a measured co-observed PR. Before this
            # fix, ANY successful entries-parse inflated K, reconstituting
            # the exact false-clean coverage vector issue #854 exists to
            # eliminate (internal-only markers standing in for measurement
            # that was never actually taken).
            if ($tally.ExternalSourcesFound) { $hadCoverageRecord = $true }

            $createdAtRaw = if ($i -lt $createdAtValues.Count) { [string]$createdAtValues[$i] } else { '' }
            $createdAtDt = $null
            if (-not [string]::IsNullOrWhiteSpace($createdAtRaw)) {
                try { $createdAtDt = [datetime]::Parse($createdAtRaw, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { $createdAtDt = $null }
            }

            foreach ($entry in $tally.Entries) {
                $key = [string]$entry.StableFindingKey
                $shouldReplace = $true
                if ($perKeyLatestEntry.ContainsKey($key)) {
                    $existingDt = $perKeyLatestCreatedAt.ContainsKey($key) ? $perKeyLatestCreatedAt[$key] : $null
                    if ($null -ne $existingDt -and $null -ne $createdAtDt) {
                        $shouldReplace = $createdAtDt -ge $existingDt
                    }
                    elseif ($null -eq $createdAtDt -and $null -ne $existingDt) {
                        # M11 fix (judge-sustained post-fix review): an
                        # undated candidate (unparseable/missing createdAt)
                        # must never unconditionally displace an
                        # already-dated existing entry -- comment ordering on
                        # GitHub is not guaranteed chronological, so array
                        # order alone is not a safe tiebreaker once one side
                        # carries real timestamp evidence. $shouldReplace
                        # stays $true (its initial value) only when BOTH
                        # sides are undated (array order wins) or the
                        # existing entry doesn't exist yet.
                        $shouldReplace = $false
                    }
                }
                if ($shouldReplace) {
                    $perKeyLatestEntry[$key] = $entry
                    if ($null -ne $createdAtDt) {
                        $perKeyLatestCreatedAt[$key] = $createdAtDt
                    }
                    elseif ($perKeyLatestCreatedAt.ContainsKey($key)) {
                        $perKeyLatestCreatedAt.Remove($key) | Out-Null
                    }
                }
            }
        }

        if (-not $hadCoverageRecord) { continue }

        # M5 fix (refined, post-fix batch 4 / issue #854 s6): a judge-
        # authored coverage record counts toward K regardless of whether the
        # review found anything -- the original ">=1 resolved-external-
        # finding" gate zeroed out a legitimate M9 zero-finding measurement.
        # $hadCoverageRecord is now the CORRECTED predicate: it is set above
        # only when $tally.ExternalSourcesFound was $true for at least one
        # judge comment on this PR -- i.e. a REAL PR-level
        # external_sources_reconciled field was found and parsed (M9's
        # "measured zero" legal-coverage case, or a non-empty reconciled
        # list), never merely "some entries parsed". A purely internal-only
        # marker (real entries, ParseStatus 'ok', but no external
        # reconciliation ever attempted) never sets $hadCoverageRecord, so it
        # is never added here. This PR is ALWAYS added once the `continue`
        # above has been passed, because $hadCoverageRecord already encodes
        # the genuine-measurement predicate. This is also DD3's "co-observed"
        # set (M2/M12): the n1 scoping below uses THIS set, not
        # $coObservedPrNumbers (the whole-window population).
        $measuredCoveragePrNumbers.Add($number) | Out-Null

        $prExternalEntries = @($perKeyLatestEntry.Values | Where-Object {
                $rs = if ([string]::IsNullOrWhiteSpace($_.ReviewerSource)) { 'local' } else { [string]$_.ReviewerSource }
                $rs -ne 'local' -and $rs -ne 'unresolved'
            })

        foreach ($e in $prExternalEntries) {
            # M3 fix: mirror Get-ExternalSourceNovelSustainedCount's dismiss
            # exclusion (phase-containment-emission-check-core.ps1) -- a
            # dismissed finding was never sustained and must never count
            # toward K/novel/n2/m regardless of MatchStatus.
            if ($e.Disposition -eq 'dismiss') { continue }
            if ($e.MatchStatus -eq 'duplicate') {
                $duplicateCount++
                $externalCatchCount++
            }
            elseif ($e.MatchStatus -eq 'novel') {
                $dispositionsNovelExternalCount++
                $externalCatchCount++
            }
            # 'ambiguous' -> excluded from n2/m per the Seam Specification.
        }
    }

    # M2/M12 fix: n1's population is DD3's actual "co-observed" set --
    # PRs whose dispositions actually carry a reconciled coverage record
    # ($measuredCoveragePrNumbers, built above) -- NOT $coObservedPrNumbers
    # (every PR tuple in the whole fetched window, unfiltered). Pooling n1
    # against the whole window dilutes the miss rate the estimators exist
    # to guard against.
    $internalCoObservedCatchCount = 0
    foreach ($e in $Entries) {
        $caughtStage    = if ($e -is [hashtable]) { [string]$e['caught_stage'] }    else { [string]$e.caught_stage }
        $catchablePhase = if ($e -is [hashtable]) { [string]$e['catchable_phase'] } else { [string]$e.catchable_phase }
        $apparatusMeta  = if ($e -is [hashtable]) { [bool]$e['apparatus_meta'] }    else { [bool]$e.apparatus_meta }
        $surface        = if ($e -is [hashtable]) { [string]$e['surface'] }        else { [string]$e.surface }
        $prNumber       = if ($e -is [hashtable]) { [int]$e['issueOrPrNumber'] }   else { [int]$e.issueOrPrNumber }

        if ($caughtStage -eq 'code-review' -and $catchablePhase -eq 'implementation' -and -not $apparatusMeta -and $surface -eq 'pr' -and $measuredCoveragePrNumbers.Contains($prNumber)) {
            $internalCoObservedCatchCount++
        }
    }

    return @{
        CoObservedPRCount              = $coObservedPrNumbers.Count
        MeasuredCoveragePRCount        = $measuredCoveragePrNumbers.Count
        DispositionsNovelExternalCount = $dispositionsNovelExternalCount
        InternalCoObservedCatchCount   = $internalCoObservedCatchCount
        ExternalCatchCount             = $externalCatchCount
        DuplicateCount                 = $duplicateCount
        ValueCacheOk                   = $ValueCacheOk
        # M8 fix: thread the CORPUS fetch's own Truncated flag through --
        # distinct from the value fetch's $Truncated (a separate,
        # independent fetch Get-PhaseContainmentRollup already receives via
        # its own -Truncated switch). When the corpus truncates, novel-
        # carrying PRs can silently drop from this derivation while K stays
        # >=5, so the escape arm must fail closed on this signal too, not
        # just render a non-gating warning.
        CorpusTruncated                = [bool]$Corpus.Truncated
    }
}

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

        Fetch hoist (issue #854 s6, M2 — intentionally revises #768's value/
        cost isolation for the code-review row, owner decision
        `value-block-cost-dependency-854`): the corpus fetch now happens
        ONCE, here, BEFORE the rollup call, in its own try/catch that
        captures any error into $corpusError rather than letting it
        propagate. Get-PhaseContainmentTerminalObservation derives the
        code-review escape-side parameter from that same fetched $corpus
        (never re-fetched) and is passed to Get-PhaseContainmentRollup
        -TerminalObservation. When the fetch failed, or derivation itself
        failed for a reason OTHER than the fetch (e.g. a head-gate/parsing
        bug), $null is passed instead — Get-PhaseContainmentRollup fails
        closed on a $null TerminalObservation, so the code-review row's
        escape-side arm downgrades to unavailable rather than fabricating a
        clean signal. The existing cost-path try/catch below RE-THROWS
        $corpusError as its very first statement, so the "cost section
        unavailable: {reason}" degradation line renders byte-for-byte for a
        corpus-fetch failure exactly as it did before the hoist (issue #768
        M5/M8 isolation, re-pinned not silently defeated) — this is what
        makes the hoist safe: a failed fetch both (a) lets the rollup fail
        closed via -TerminalObservation $null and (b) still shows the
        cost-unavailable degradation message.
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
        population-mismatch caveat when it takes effect. Also threaded into
        Get-PhaseContainmentTerminalObservation as the Seam Specification's
        ValueCacheOk coherence flag (issue #854 s6): a cached value fetch
        withholds the code-review escape arm entirely, since a cached value
        population cannot be honestly joined to a same-run-fresh corpus.
    .PARAMETER JudgeLogin
        The judge identity's login, threaded to
        Get-PhaseContainmentTerminalObservation (issue #854 s4/s6) so only
        judge-authored bodies contribute coverage/escape-side data.
    .PARAMETER JudgeLoginSource
        Issue #842 M1 fix (post-review): optional true-provenance override
        ('from -JudgeLogin' or 'resolved from gh auth'), supplied by the
        script-scope auto-invoke path so the header's provenance label is
        never re-derived from $PSBoundParameters.ContainsKey('JudgeLogin')
        alone -- that check can no longer distinguish an explicit caller
        value from an auto-resolved one once the script always forwards a
        concrete -JudgeLogin. Direct function callers normally omit this.
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
        [switch]$ValueCacheOk,
        [string]$JudgeLogin = 'github-actions[bot]',
        # Issue #842 M1 fix (post-review): optional provenance override.
        # The script-scope auto-invoke path (above) always supplies this --
        # it already knows, unambiguously, whether $JudgeLogin was
        # explicitly passed by the script's own caller or auto-resolved
        # from gh auth, at the one point that distinction is still
        # knowable. Direct function callers (tests, or another script
        # dot-sourcing this file and calling this function itself) omit
        # this and fall back to the original ContainsKey-based derivation
        # below, unchanged from before this fix.
        [string]$JudgeLoginSource
    )

    # ---- Function-level identity resolution gate (issue #842 M4) ----
    # Direct function callers (tests, or another script that dot-sources this
    # file and calls Invoke-PhaseContainmentReportCli itself) bypass the
    # script-scope resolution above entirely -- this gate is what keeps THAT
    # call path honest too. An explicit -JudgeLogin always wins outright and
    # is never re-resolved.
    #
    # M1 fix (judge-sustained): when the caller supplies -JudgeLoginSource
    # explicitly (the script-scope auto-invoke path always does), that value
    # is authoritative and used as-is. $PSBoundParameters.ContainsKey(
    # 'JudgeLogin') alone can no longer distinguish "explicitly passed by
    # the original caller" from "auto-resolved then forwarded" once a
    # caller always forwards a concrete -JudgeLogin value -- it would
    # always say "from -JudgeLogin", even for an auto-resolved identity.
    # Direct function callers that omit -JudgeLoginSource keep the original
    # ContainsKey-based derivation exactly as before this fix.
    if ($PSBoundParameters.ContainsKey('JudgeLoginSource')) {
        $judgeLoginSource = $JudgeLoginSource
    }
    elseif ($PSBoundParameters.ContainsKey('JudgeLogin')) {
        $judgeLoginSource = 'from -JudgeLogin'
    }
    else {
        $JudgeLogin = Resolve-JudgeLogin
        $judgeLoginSource = 'resolved from gh auth'
    }

    # M21 fix: an empty/whitespace resolved identity silently disables
    # Test-PhaseContainmentCommentAuthoredByJudge's gate for every body
    # scanned (fail-closed only works if there IS an identity to compare
    # against) -- fail loud here, naming -JudgeLogin as the remedy, rather
    # than letting it flow through and degrade quietly.
    if ([string]::IsNullOrWhiteSpace($JudgeLogin)) {
        throw "phase-containment-report: could not resolve a judge identity (gh auth failed or returned empty) -- pass -JudgeLogin explicitly to avoid silently disabling the judge-authorship gate."
    }

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
        # G-CR3 fix (PR #859 GitHub-review post-fix, security): thread the
        # same JudgeLogin already used to gate Get-PhaseContainmentTerminalObservation's
        # coverage/dispositions tally (below) into the value-side entries
        # fetch too, so a non-judge-authored phase-containment block (e.g. a
        # forged post-review-observer block) contributes zero entries
        # instead of silently participating in reconciliation.
        JudgeLogin = $JudgeLogin
    }
    if ($Token) {
        $fetchParams['Token'] = $Token
    }
    if ($bypassValueCache) {
        # Force cache miss by pointing at a non-existent path. issue #842 s6
        # (CM16 fix a): a prior version called [System.IO.Path]::GetTempFileName()
        # and appended '.nocache.json' to ITS return value -- GetTempFileName()
        # creates a real 0-byte file on disk and returns that path, so the
        # appended-suffix path named here was always a DIFFERENT, never-created
        # path, orphaning the original 0-byte file on every default/-NoCache
        # run. A GUID-based name under the platform temp directory (resolved
        # via [System.IO.Path]::GetTempPath(), not $env:TEMP -- see issue
        # #876 F1, which is unset on PowerShell Core/Linux/macOS) names a
        # throwaway path without ever creating a file, matching the
        # cache-path construction convention already documented by the
        # `# host-path-ok` marker in phase-containment-rolling-history-core.ps1.
        $fetchParams['CachePath'] = Join-Path ([System.IO.Path]::GetTempPath()) "phase-containment-bypass-$([guid]::NewGuid().ToString('N')).json"  # host-path-ok
        # M5 fix (issue #842 post-review): signal the throwaway-cache bypass
        # through to Get-PhaseContainmentHistory so it skips writing a full-
        # content orphan JSON for this never-reused GUID path.
        $fetchParams['SkipCacheWrite'] = $true
    }

    $history = Get-PhaseContainmentHistory @fetchParams

    $entries           = @($history.Entries)
    $fetchedAt         = $history.FetchedAt
    $source            = $history.Source
    $truncated         = $history.Truncated
    $invalidEntryCount = $history.InvalidEntryCount

    # Issue #842 M8: read Matched/AuthorFilteredCount defensively (PSObject.
    # Properties lookup, not dot-access) rather than $history.Matched --
    # under this file's Set-StrictMode -Version Latest, a bare dot-access
    # throws PropertyNotFoundException against any fixture object (existing
    # or future test-double) that has not been updated to carry these new
    # fields, which would fail every pre-existing test using such a fixture
    # rather than degrading gracefully to "not tracked" (0).
    $matchedProp = $history.PSObject.Properties['Matched']
    $historyMatched = if ($null -ne $matchedProp) { [int]$matchedProp.Value } else { 0 }
    $authorFilteredProp = $history.PSObject.Properties['AuthorFilteredCount']
    $historyAuthorFilteredCount = if ($null -ne $authorFilteredProp) { [int]$authorFilteredProp.Value } else { 0 }
    $commentBodyCount = $historyMatched + $historyAuthorFilteredCount

    # ---- Corpus fetch, hoisted (issue #854 s6, M2 — see the header for the
    # full ordering rationale). Fetched exactly ONCE: this same $corpus is
    # reused by the cost path below, never re-fetched. $corpusError is
    # captured, not thrown, so a fetch failure cannot suppress the value
    # report that renders further down.
    $corpus      = $null
    $corpusError = $null
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
    }
    catch {
        $corpusError = $_
    }

    # ---- Derive terminal-observation (issue #854 s6) ----
    # Only attempted when the fetch itself succeeded. A failure here is a
    # DIFFERENT class of problem than a fetch failure (e.g. a head-gate/
    # parsing bug in the derivation logic) and must not be silently
    # swallowed as expected degradation -- it is surfaced via Write-Warning
    # -- but the rollup still fails closed on $null either way.
    #
    # G-CR6 fix (PR #859 GitHub-review post-fix): Get-PhaseContainmentCommentCorpus
    # can return a non-null, non-throwing result with Source='timeout' or
    # 'repo-resolution-failed' and empty Tuples -- $corpusError stays $null
    # and $corpus is non-null, so the check above alone let this branch
    # proceed with a genuinely empty corpus. That derives K=0/N=0, which the
    # rollup then renders as "coverage insufficient (0 of 0 co-observed PRs
    # measured, need >=5)" -- a real corpus-fetch failure disguised as a
    # measured-but-thin population. Gate on Corpus.Source too, matching the
    # cost path's own pattern (Get-ReviewCostRollup already consults
    # $corpus.Source), so both failure sources fall through to the same
    # $null/"terminal observation unavailable" degradation as a thrown fetch
    # error.
    $corpusSourceOk = $null -ne $corpus -and [string]$corpus.Source -notin @('timeout', 'repo-resolution-failed')
    $terminalObservation = $null
    if ($null -eq $corpusError -and $corpusSourceOk) {
        try {
            $terminalObservation = Get-PhaseContainmentTerminalObservation -Corpus $corpus -Entries $entries -JudgeLogin $JudgeLogin -ValueCacheOk $bypassValueCache
        }
        catch {
            Write-Warning "phase-containment-report: terminal-observation derivation failed (not a fetch failure -- a real bug): $_"
            $terminalObservation = $null
        }
    }

    # ---- Compute rollup ----

    $rollup = Get-PhaseContainmentRollup -Entries $entries -WindowLabel "${WindowDays}d" -Truncated:$truncated -TerminalObservation $terminalObservation

    # ---- Render value report ----
    # This MUST happen, and complete, before the cost path's try/catch
    # region below begins — a cost-path exception can then never suppress
    # it (issue #768 s6, judge-sustained M5/M8 isolation requirement).

    $reportContext = @{
        Rollup              = $rollup
        Source              = $source
        Truncated           = $truncated
        WindowDays          = $WindowDays
        FetchedAt           = $fetchedAt
        InvalidEntryCount   = $invalidEntryCount
        Matched             = $historyMatched
        CommentBodyCount    = $commentBodyCount
        AuthorFilteredCount = $historyAuthorFilteredCount
        JudgeLogin          = $JudgeLogin
        JudgeLoginSource    = $judgeLoginSource
    }

    Format-PhaseContainmentReport -Context $reportContext | Write-Output

    if ($renderCacheCaveat) {
        Write-Output ''
        Write-Output 'CAVEAT: -ValueCacheOk was used; the value report above may reflect a cached fetch from an earlier run, while the cost section below (Get-PhaseContainmentCommentCorpus never caches) is same-run fresh. The two halves may describe different underlying comment populations -- do not read them as a single-moment snapshot.'
    }

    # ---- Cost path (issue #768 s6; corpus fetch hoisted above, issue #854
    # s6 M2) ----
    # Wrapped end-to-end (through rendering) in a single try/catch: on ANY
    # exception here, print one degradation line and stop -- the value
    # report above has already rendered and is unaffected. The FIRST
    # statement re-throws the corpus fetch's own captured error (if any),
    # so a corpus-fetch failure still produces the byte-for-byte-identical
    # "cost section unavailable: {reason}" degradation line it always did,
    # even though the fetch itself now happens earlier (before the rollup
    # call, not inside this try block).
    try {
        if ($null -ne $corpusError) {
            throw $corpusError
        }

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
#
# M1 fix (issue #842, judge-sustained post-review): -JudgeLoginSource
# forwards the TRUE provenance computed by the script-scope resolution
# block above, rather than letting the function re-derive it from
# $PSBoundParameters.ContainsKey('JudgeLogin') -- which is always $true
# here since this line always forwards a concrete -JudgeLogin value,
# regardless of whether it was explicitly supplied or auto-resolved.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-PhaseContainmentReportCli -RepoOwner $RepoOwner -RepoName $RepoName -WindowDays $WindowDays -Token $Token -NoCache:$NoCache -ValueCacheOk:$ValueCacheOk -JudgeLogin $JudgeLogin -JudgeLoginSource $JudgeLoginSource
}
