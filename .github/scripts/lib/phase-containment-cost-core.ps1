#Requires -Version 7.0

# phase-containment-cost-core.ps1
# Core library for the phase-containment review-cost accounting (issue #768 s4).
# Aggregates a presentation-only "review cost" half — per-stage dismiss-rate,
# defense-kill rate, and defer count — alongside the existing "review value"
# ledger (phase-containment-rolling-history-core.ps1). Consumes
# Get-DispositionTally (phase-containment-emission-check-core.ps1) as the
# per-body parser; performs no GitHub fetching and no rendering itself.
#
# SECURITY: Do NOT import powershell-yaml or use ConvertFrom-Yaml in this file.
# These are forbidden for parsing untrusted GitHub comment bodies (YamlDotNet
# billion-laughs risk). All parsing uses a hand-rolled line-regex parser only.
#
# Non-goals (issue #768 s4 scope): no GitHub fetching (the caller supplies the
# Tuples/Source/Truncated output of Get-PhaseContainmentCommentCorpus plus the
# value-side PR-number set derived from Get-PhaseContainmentHistory's
# validated Entries); no rendering (that is Format-ReviewCostSection, s5); no
# relaxation-eligibility computation (the value ledger's own formula is
# untouched); never dot-sources phase-containment-rolling-history-core.ps1
# directly, so that 2,020-line file stays frozen per 768-D2.

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'phase-containment-emission-check-core.ps1')

#region Constants

# n<5 INSUFFICIENT DATA threshold (issue #768 s4, judge-sustained M15),
# applied independently per stage AND per reviewer-source AND per rate
# sub-section — see New-CostRateSubSection below.
$script:CostRateInsufficientDataThreshold = 5

#endregion

#region Private: head-presence detectors (routing, issue #768 s4 M1)

function script:Test-ReviewDispositionsHeadPresent {
    <#
    .SYNOPSIS
        Vocab-gated presence check for the <!-- review-dispositions-{N} -->
        marker head.
    .DESCRIPTION
        Test-EmissionMarkerPresent (phase-containment-emission-check-core.ps1)
        covers the judge-rulings/finding_dispositions marker heads only — it
        has no branch for the review-dispositions marker this file also needs
        to route on. This helper mirrors the SAME technique (bounded
        lookahead vocab gate after the head substring) so a maintainer's
        prose sentence merely describing the marker convention is not
        mistaken for a real block, and so Get-ReviewCostRollup can
        distinguish "no review-dispositions marker on this body" (ordinary
        chatter, contributes nothing) from "marker present but unparseable"
        (a real could-not-verify condition Get-DispositionTally's own
        Get-ReviewDispositionsTallyInternal reports).
    .PARAMETER Body
        The raw comment body text to scan.
    .OUTPUTS
        [bool]
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Body
    )
    if ([string]::IsNullOrWhiteSpace($Body)) { return $false }

    $headCandidates = [regex]::Matches($Body, '<!--\s*review-dispositions-\d+\s*-->')
    if ($headCandidates.Count -eq 0) { return $false }

    $lookaheadWindow = 400
    foreach ($candidate in $headCandidates) {
        $windowEnd = [Math]::Min($Body.Length, $candidate.Index + $candidate.Length + $lookaheadWindow)
        $window = $Body.Substring($candidate.Index, $windowEnd - $candidate.Index)
        if ([regex]::IsMatch($window, '(?m)^\s*(entries|schema_version|stable_finding_key)\s*:')) {
            return $true
        }
    }
    return $false
}

function script:Test-JudgeRulingsRealHeadPresent {
    <#
    .SYNOPSIS
        Real (vocab-gate-passing) judge-rulings head presence, decoupled from
        stage/surface semantics.
    .DESCRIPTION
        Delegates to Get-RealJudgeRulingsHeadMatches (private to
        phase-containment-emission-check-core.ps1, in scope here via this
        file's dot-source) rather than re-implementing the vocab-gate scan —
        this file only needs a yes/no presence signal, and reusing the
        hardened scan keeps a single source of truth for "what counts as a
        real judge-rulings head" across both files.
    .PARAMETER Body
        The raw comment body text to scan.
    .OUTPUTS
        [bool]
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Body
    )
    if ([string]::IsNullOrWhiteSpace($Body)) { return $false }
    return (Get-RealJudgeRulingsHeadMatches -Body $Body).Count -gt 0
}

#endregion

#region Private: judge-rulings vocabulary classification (issue #768 s4, M7)

function script:Test-JudgeRulingsHasDefenseSustainedConcept {
    <#
    .SYNOPSIS
        Reports whether a judge-rulings-headed body's disposition vocabulary
        is the canonical `judge_ruling: sustained|defense-sustained` form —
        the only one of the three code-review judge-rulings vocabularies with
        a real defense-sustained concept — versus the GitHub-intake
        `disposition: accept|reject` or four-value
        `Fix-now|Fix-in-PR|Defer|Dismiss` variants, neither of which has any
        defense-sustained concept at all.
    .DESCRIPTION
        Get-DispositionTally's plan-stress-test-surface branch (the only
        Get-DispositionTally surface that parses the judge-rulings marker
        shape) always returns DefenseSustainedCount=0 for the two
        non-canonical vocabularies — the SAME value a genuinely-zero
        canonical result would also return. Get-ReviewCostRollup needs to
        tell "real zero" apart from "no defense-sustained concept exists,
        must be could-not-verify" (judge-sustained M7), so this function
        re-checks the body with the SAME vocabulary-priority ordering
        Get-JudgeRulingsSustainedCountInternal uses (four-value/intake
        checked first, then canonical).

        CM3 fix (judge-sustained PR #833 review): this function used to scan
        the raw whole $Body rather than the isolated judge-rulings region —
        a stray line-start token elsewhere in the SAME body (e.g. a
        `disposition: reject` line quoted in unrelated prose, outside the
        real judge-rulings region) could misclassify a genuinely canonical
        block as non-canonical, silently shunting real sustained/
        defense-sustained data to could-not-verify. This function now calls
        Get-JudgeRulingsIsolatedRegion (the SAME region-isolation
        Get-JudgeRulingsSustainedCountInternal uses internally) and applies
        the vocabulary-priority check to that isolated region only, never to
        the raw body.
    .PARAMETER Body
        The raw comment body text to scan (the same body already parsed via
        Get-DispositionTally -Surface plan-stress-test).
    .OUTPUTS
        [bool] $true only for the canonical judge_ruling: vocabulary.
    #>
    param(
        [Parameter(Mandatory)][string]$Body
    )
    $isolated = Get-JudgeRulingsIsolatedRegion -Body $Body
    if ($isolated.ParseStatus -ne 'ok') { return $false }
    $region = $isolated.Region
    $keyAnchor = '(?:^\s*(?:-\s+)?|[{,]\s*)'
    $hasFourValue = $region -match "(?m)${keyAnchor}disposition\s*:\s*(Fix-now|Fix-in-PR|Defer|Dismiss)\b"
    $hasIntake = ($region -match "review_mode\s*:\s*['""]?github-intake-proxy-prosecution") -or
                 ($region -match "(?m)${keyAnchor}disposition\s*:\s*(accept|reject)\b")
    if ($hasFourValue -or $hasIntake) { return $false }
    return [bool]($region -match '(?m)judge_ruling\s*:\s*\S')
}

#endregion

#region Private: latest-generation selection (issue #768 s4, M6)

function script:Select-LatestByCreatedAt {
    <#
    .SYNOPSIS
        Picks the index of the chronologically latest candidate among a set
        of (Body, CreatedAt) pairs, falling back to the last candidate in
        array order when CreatedAt values are missing or unparseable.
    .DESCRIPTION
        Used for judge-rulings and finding_dispositions "latest marker
        generation per PR/issue" dedup (issue #768 s4, M6): these marker
        shapes carry no stable per-entry key at all, so re-review rounds are
        deduped by picking ONE winning comment per tuple rather than merging
        entries.
    .PARAMETER CreatedAtValues
        The tuple's full CreatedAtValues[] array (index-paired with Bodies[]
        per Get-PhaseContainmentCommentCorpus's contract). May contain empty
        strings.
    .PARAMETER CandidateIndices
        The indices (into Bodies[]/CreatedAtValues[]) to choose among.
    .OUTPUTS
        [int] the winning index from -CandidateIndices.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$CreatedAtValues,
        [Parameter(Mandatory)][int[]]$CandidateIndices
    )

    $bestIndex = $CandidateIndices[0]
    $bestDt = $null
    $haveBestDt = $false

    foreach ($idx in $CandidateIndices) {
        $raw = if ($idx -lt $CreatedAtValues.Count) { [string]$CreatedAtValues[$idx] } else { '' }
        $dt = $null
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            try {
                $dt = [datetime]::Parse($raw, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
            }
            catch {
                $dt = $null
            }
        }

        if (-not $haveBestDt) {
            # First candidate examined so far (array-order default).
            $bestIndex = $idx
            if ($null -ne $dt) { $bestDt = $dt; $haveBestDt = $true }
            continue
        }

        if ($null -eq $dt) {
            # Unparseable timestamp on a later-in-array candidate: array
            # order still wins over an unparseable comparison.
            $bestIndex = $idx
        }
        elseif ($dt -ge $bestDt) {
            $bestIndex = $idx
            $bestDt = $dt
        }
    }

    return $bestIndex
}

#endregion

#region Private: rate sub-section builder

function script:New-CostRateSubSection {
    <#
    .SYNOPSIS
        Builds one rate sub-section object with its own independent n<5
        INSUFFICIENT DATA gate (issue #768 s4, M15).
    .PARAMETER Numerator
        The "noise" count (dismissed / defense-sustained) for this sub-section.
    .PARAMETER N
        The dispositioned-finding count (denominator) for THIS sub-section
        specifically — never a shared/ambiguous count across sub-sections.
    .PARAMETER CouldNotVerifyCount
        Count of contributions excluded from N/Numerator because they could
        not be verified (unparseable body, or a non-canonical vocabulary
        lacking the concept this rate measures) — surfaced, never dropped.
    .OUTPUTS
        [PSCustomObject] with N, Numerator, Rate, InsufficientData,
        CouldNotVerifyCount.
    #>
    param(
        [Parameter(Mandatory)][int]$Numerator,
        [Parameter(Mandatory)][int]$N,
        [int]$CouldNotVerifyCount = 0
    )
    return [PSCustomObject]@{
        N                   = $N
        Numerator           = $Numerator
        Rate                = if ($N -gt 0) { [double]$Numerator / [double]$N } else { $null }
        InsufficientData    = ($N -lt $script:CostRateInsufficientDataThreshold)
        CouldNotVerifyCount = $CouldNotVerifyCount
    }
}

function script:New-DefenseKillRateSubSection {
    <#
    .SYNOPSIS
        Aggregates a defense-kill-rate sub-section from a list of judge-rulings
        contributions (issue #768 s4). Shared by the code-review and
        plan-stress-test defense-kill rates — both consume the SAME
        contribution shape from Get-ReviewCostRollup's judge-rulings branch
        (SustainedCount, DefenseSustainedCount, ParseStatus,
        HasDefenseConcept), just routed to a different STAGE bucket by
        (Surface, head) dispatch (M1).
    .PARAMETER Contribs
        List of contribution objects with SustainedCount,
        DefenseSustainedCount, ParseStatus, HasDefenseConcept.
    .OUTPUTS
        [PSCustomObject] a New-CostRateSubSection result: N is the canonical
        (ParseStatus 'ok' AND HasDefenseConcept) sustained + defense-sustained
        total; Numerator is the canonical defense-sustained total;
        CouldNotVerifyCount is the count of non-canonical-or-failed
        contributions (M7).
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Contribs
    )
    $canonical = @($Contribs | Where-Object { $_.ParseStatus -eq 'ok' -and $_.HasDefenseConcept })
    $nonCanonicalOrFailed = @($Contribs | Where-Object { -not ($_.ParseStatus -eq 'ok' -and $_.HasDefenseConcept) })
    $n = [int](($canonical | ForEach-Object { $_.SustainedCount + $_.DefenseSustainedCount } | Measure-Object -Sum).Sum)
    $numerator = [int](($canonical | ForEach-Object { $_.DefenseSustainedCount } | Measure-Object -Sum).Sum)
    return New-CostRateSubSection -Numerator $numerator -N $n -CouldNotVerifyCount $nonCanonicalOrFailed.Count
}

#endregion

#region Get-ReviewCostRollup

function Get-ReviewCostRollup {
    <#
    .SYNOPSIS
        Aggregates per-stage review-cost rates (dismiss-rate, defense-kill
        rate, defer count) from the raw phase-containment comment corpus
        (issue #768 s4).
    .DESCRIPTION
        Consumes the Tuples/Source/Truncated output of
        Get-PhaseContainmentCommentCorpus (phase-containment-rolling-history-core.ps1)
        and a caller-supplied value-side PR-number set (from
        Get-PhaseContainmentHistory's validated Entries, so the forward-gap
        count reflects the same honest PR population the value ledger uses,
        not a raw head-presence approximation).

        Routing (judge-sustained M1 — the load-bearing fix this function
        exists to implement): each body is classified by its OWN (tuple
        Surface, marker head) pair, never by head alone. Code-review and
        plan-stress-test judge-rulings share the byte-identical
        `<!-- judge-rulings` head, so a Surface='pr' judge-rulings body feeds
        the code-review defense-kill rate while a Surface='issue'
        judge-rulings body feeds plan-stress-test's — both parsed via
        Get-DispositionTally -Surface plan-stress-test (the only
        Get-DispositionTally surface that parses this marker shape; its
        result is then routed to the correct STAGE bucket by this function,
        independent of which -Surface argument was used to parse it). A
        `finding_dispositions:` head routes to design-challenge regardless of
        tuple Surface. A `<!-- review-dispositions-{N} -->` head routes to
        code-review's post-judge dismiss-rate. A body may carry more than one
        head (e.g. an issue's plan comment vs. its separate design comment)
        — each body is classified independently, never short-circuited by
        the tuple as a whole.

        Vocabulary variants (M7): a non-canonical code-review/plan-stress-test
        judge-rulings vocabulary (GitHub-intake `accept|reject`, or the
        four-value `Fix-now|Fix-in-PR|Defer|Dismiss` form) has no real
        defense-sustained concept — Test-JudgeRulingsHasDefenseSustainedConcept
        detects this and routes the contribution to CouldNotVerifyCount
        instead of a confident zero.

        n<5 gate (M15): New-CostRateSubSection applies INSUFFICIENT DATA
        independently per stage AND per reviewer-source AND per rate
        sub-section, using that sub-section's own dispositioned-finding N.

        Dedup: review-dispositions entries dedup latest-wins per-PR on
        stable_finding_key (M6 — remote stable_finding_keys are GitHub
        comment IDs that legitimately vary across re-review rounds for the
        "same" logical finding from the reviewer's perspective;
        latest-generation-wins on the literal key value is the best
        available fix, not a claim of perfect cross-round identity
        tracking). Judge-rulings and finding_dispositions bodies (no stable
        per-entry key at all) dedup by latest marker GENERATION per PR/issue
        via Select-LatestByCreatedAt — the single latest comment's counts are
        used, never summed across re-review rounds.

        Fetch-state: corpus Source 'timeout' | 'repo-resolution-failed' maps
        to FetchState 'unavailable' (COST DATA UNAVAILABLE), a state distinct
        from a thin-data (n<5) INSUFFICIENT DATA result — the two must never
        be confused with each other or with a confident zero.
    .PARAMETER Tuples
        The Tuples array from Get-PhaseContainmentCommentCorpus: each entry
        {Number; Surface 'issue'|'pr'; Bodies[]; CreatedAtValues[]}.
    .PARAMETER Source
        The corpus Source flag: 'graphql' | 'rest' | 'timeout' |
        'repo-resolution-failed'.
    .PARAMETER Truncated
        The corpus Truncated flag, passed through unchanged.
    .PARAMETER ValuePresentPrNumbers
        PR numbers present in Get-PhaseContainmentHistory's validated Entries
        (the value ledger's own PR population) — used for the forward-gap
        count ("PRs with value data but no cost marker").
    .OUTPUTS
        [PSCustomObject] with:
          FetchState      [string] — 'ok' | 'unavailable'
          FetchSource     [string] — the corpus Source, passed through
          Truncated       [bool]
          ForwardGapCount [int]
          DesignChallenge [PSCustomObject] — DismissRate (sub-section)
          CodeReview      [PSCustomObject] — PostJudgeDismissRate,
                          DefenseKillRate (sub-sections), DeferCount [int],
                          PerSource [ordered hashtable of ReviewerSource ->
                          sub-section]
          PlanStressTest  [PSCustomObject] — DefenseKillRate (sub-section)
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Tuples,
        [Parameter(Mandatory)][ValidateSet('graphql', 'rest', 'timeout', 'repo-resolution-failed')][string]$Source,
        [Parameter(Mandatory)][bool]$Truncated,
        [Parameter(Mandatory)][AllowEmptyCollection()][int[]]$ValuePresentPrNumbers
    )

    $fetchUnavailable = $Source -in @('timeout', 'repo-resolution-failed')

    # Deduped, flattened contribution lists — one item per entry (review-
    # dispositions) or one item per PR/issue (judge-rulings / finding_dispositions,
    # after latest-generation dedup).
    $reviewDispositionEntries = [System.Collections.Generic.List[PSCustomObject]]::new()
    $codeReviewDefenseKillContribs = [System.Collections.Generic.List[PSCustomObject]]::new()
    $planStressTestDefenseKillContribs = [System.Collections.Generic.List[PSCustomObject]]::new()
    $designChallengeContribs = [System.Collections.Generic.List[PSCustomObject]]::new()

    # PR numbers (Surface = 'pr') carrying ANY cost-surface marker at all —
    # used for the forward-gap count.
    $costPresentPrNumbers = [System.Collections.Generic.HashSet[int]]::new()

    if (-not $fetchUnavailable) {
        foreach ($tuple in $Tuples) {
            $number = [int]$tuple.Number
            $surface = [string]$tuple.Surface
            $bodies = @($tuple.Bodies)
            $createdAtValues = @($tuple.CreatedAtValues)

            # --- review-dispositions marker: code-review post-judge dismiss-rate ---
            # Per-PR dedup: latest-wins on stable_finding_key, ACROSS all
            # bodies/rounds on this tuple (issue #768 s4, M6) — unlike the
            # judge-rulings dedup below, this is a per-KEY merge, not a
            # whole-body "pick one round" selection.
            $perKeyLatestEntry = [System.Collections.Generic.Dictionary[string, PSCustomObject]]::new()
            $perKeyLatestCreatedAt = [System.Collections.Generic.Dictionary[string, datetime]]::new()

            for ($i = 0; $i -lt $bodies.Count; $i++) {
                $body = [string]$bodies[$i]
                if (-not (Test-ReviewDispositionsHeadPresent -Body $body)) { continue }
                if ($surface -eq 'pr') { $costPresentPrNumbers.Add($number) | Out-Null }

                $tally = Get-DispositionTally -Surface 'code-review' -Body $body
                if ($tally.ParseStatus -ne 'ok') {
                    # Real head present but unparseable: a genuine
                    # could-not-verify signal, surfaced as a synthetic
                    # excluded entry rather than silently dropped (DD3
                    # fail-loud parity).
                    $reviewDispositionEntries.Add([PSCustomObject]@{
                            Disposition    = $null
                            ReviewerSource = $null
                            CouldNotVerify = $true
                        })
                    continue
                }

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
                        elseif ($null -eq $createdAtDt) {
                            # Unparseable/missing timestamp: array order
                            # (later index processed later) still wins.
                            $shouldReplace = $true
                        }
                    }
                    if ($shouldReplace) {
                        $perKeyLatestEntry[$key] = [PSCustomObject]@{
                            Disposition    = $entry.Disposition
                            ReviewerSource = [string]::IsNullOrWhiteSpace($entry.ReviewerSource) ? 'local' : $entry.ReviewerSource
                            CouldNotVerify = $false
                        }
                        if ($null -ne $createdAtDt) {
                            $perKeyLatestCreatedAt[$key] = $createdAtDt
                        }
                        elseif ($perKeyLatestCreatedAt.ContainsKey($key)) {
                            # No timestamp for this replacement: clear any
                            # stale value from a prior (now-overwritten)
                            # entry so it can never wrongly win or lose a
                            # later comparison (EXT-F3, PR #843).
                            $perKeyLatestCreatedAt.Remove($key) | Out-Null
                        }
                    }
                }
            }
            foreach ($v in $perKeyLatestEntry.Values) { $reviewDispositionEntries.Add($v) }

            # --- judge-rulings marker: defense-kill rate (M1 (Surface, head) routing) ---
            $judgeRulingsCandidateIdx = [System.Collections.Generic.List[int]]::new()
            for ($i = 0; $i -lt $bodies.Count; $i++) {
                if (Test-JudgeRulingsRealHeadPresent -Body ([string]$bodies[$i])) {
                    $judgeRulingsCandidateIdx.Add($i)
                }
            }
            if ($judgeRulingsCandidateIdx.Count -gt 0) {
                if ($surface -eq 'pr') { $costPresentPrNumbers.Add($number) | Out-Null }
                $latestIdx = Select-LatestByCreatedAt -CreatedAtValues $createdAtValues -CandidateIndices $judgeRulingsCandidateIdx.ToArray()
                $latestBody = [string]$bodies[$latestIdx]
                $tally = Get-DispositionTally -Surface 'plan-stress-test' -Body $latestBody
                $hasDefenseConcept = ($tally.ParseStatus -eq 'ok') -and (Test-JudgeRulingsHasDefenseSustainedConcept -Body $latestBody)
                $contrib = [PSCustomObject]@{
                    SustainedCount        = $tally.SustainedCount
                    DefenseSustainedCount = $tally.DefenseSustainedCount
                    ParseStatus           = $tally.ParseStatus
                    HasDefenseConcept     = $hasDefenseConcept
                }
                if ($surface -eq 'pr') {
                    $codeReviewDefenseKillContribs.Add($contrib)
                }
                elseif ($surface -eq 'issue') {
                    $planStressTestDefenseKillContribs.Add($contrib)
                }
            }

            # --- finding_dispositions marker: design-challenge dismiss-rate ---
            # "Any surface" per the routing contract — a design-phase-complete
            # comment is issue-keyed, but this function does not gate on
            # tuple.Surface for this head.
            $designCandidateIdx = [System.Collections.Generic.List[int]]::new()
            for ($i = 0; $i -lt $bodies.Count; $i++) {
                if (Test-EmissionMarkerPresent -Surface 'design-challenge' -Body ([string]$bodies[$i])) {
                    $designCandidateIdx.Add($i)
                }
            }
            if ($designCandidateIdx.Count -gt 0) {
                $latestIdx = Select-LatestByCreatedAt -CreatedAtValues $createdAtValues -CandidateIndices $designCandidateIdx.ToArray()
                $latestBody = [string]$bodies[$latestIdx]
                $tally = Get-DispositionTally -Surface 'design-challenge' -Body $latestBody
                $designChallengeContribs.Add([PSCustomObject]@{
                        SustainedCount = $tally.SustainedCount
                        DismissedCount = $tally.DismissedCount
                        ParseStatus    = $tally.ParseStatus
                    })
            }
        }
    }

    # -------------------------------------------------------------------
    # Aggregate each sub-section.
    # -------------------------------------------------------------------

    # code-review: post-judge dismiss-rate + defer count + per-source table
    $validReviewEntries = @($reviewDispositionEntries | Where-Object { -not $_.CouldNotVerify })
    $reviewCouldNotVerifyCount = @($reviewDispositionEntries | Where-Object { $_.CouldNotVerify }).Count
    $dismissedCount = @($validReviewEntries | Where-Object { $_.Disposition -eq 'dismiss' }).Count
    $deferCount = @($validReviewEntries | Where-Object { $_.Disposition -eq 'defer' }).Count
    $postJudgeDismissRate = New-CostRateSubSection -Numerator $dismissedCount -N $validReviewEntries.Count -CouldNotVerifyCount $reviewCouldNotVerifyCount

    $perSourceTable = [ordered]@{}
    foreach ($grp in @($validReviewEntries | Group-Object -Property ReviewerSource)) {
        $sourceDismissed = @($grp.Group | Where-Object { $_.Disposition -eq 'dismiss' }).Count
        $perSourceTable[$grp.Name] = New-CostRateSubSection -Numerator $sourceDismissed -N $grp.Count
    }

    # code-review: defense-kill rate (from Surface='pr' judge-rulings bodies)
    $codeReviewDefenseKillRate = New-DefenseKillRateSubSection -Contribs $codeReviewDefenseKillContribs

    # plan-stress-test: defense-kill rate (from Surface='issue' judge-rulings bodies)
    $planStressTestDefenseKillRate = New-DefenseKillRateSubSection -Contribs $planStressTestDefenseKillContribs

    # design-challenge: dismiss-rate (over dispositioned findings)
    $designOk = @($designChallengeContribs | Where-Object { $_.ParseStatus -eq 'ok' })
    $designCouldNotVerify = @($designChallengeContribs | Where-Object { $_.ParseStatus -ne 'ok' }).Count
    $designN = [int](($designOk | ForEach-Object { $_.SustainedCount + $_.DismissedCount } | Measure-Object -Sum).Sum)
    $designNumerator = [int](($designOk | ForEach-Object { $_.DismissedCount } | Measure-Object -Sum).Sum)
    $designChallengeDismissRate = New-CostRateSubSection -Numerator $designNumerator -N $designN -CouldNotVerifyCount $designCouldNotVerify

    # forward gap: value-present PRs with no cost-surface marker at all.
    $forwardGapCount = @($ValuePresentPrNumbers | Where-Object { -not $costPresentPrNumbers.Contains([int]$_) }).Count

    return [PSCustomObject]@{
        FetchState      = if ($fetchUnavailable) { 'unavailable' } else { 'ok' }
        FetchSource     = $Source
        Truncated       = $Truncated
        ForwardGapCount = $forwardGapCount
        DesignChallenge = [PSCustomObject]@{
            DismissRate = $designChallengeDismissRate
        }
        CodeReview      = [PSCustomObject]@{
            PostJudgeDismissRate = $postJudgeDismissRate
            DefenseKillRate      = $codeReviewDefenseKillRate
            DeferCount           = $deferCount
            PerSource            = $perSourceTable
        }
        PlanStressTest  = [PSCustomObject]@{
            DefenseKillRate = $planStressTestDefenseKillRate
        }
    }
}

#endregion

#region Private: rate value display (issue #768 s5)

function script:Format-CostRateDisplayValue {
    <#
    .SYNOPSIS
        Renders a single cost rate sub-section's value as one of three
        honest states, or a numeric rate — never a confident-looking zero.
    .DESCRIPTION
        Checks FetchState BEFORE the n<5 gate: a corpus fetch failure
        (Rollup.FetchState 'unavailable') renders
        "COST DATA UNAVAILABLE (fetch {source})", a state distinct from a
        genuine thin-data "INSUFFICIENT DATA (n=X < 5)" result — the two
        must never be confused with each other or with a confident zero
        (issue #768 s5, judge-sustained M15).
    .PARAMETER RateSection
        A New-CostRateSubSection object (N, Numerator, Rate,
        InsufficientData, CouldNotVerifyCount).
    .PARAMETER FetchUnavailable
        Whether the corpus fetch itself failed (Rollup.FetchState 'unavailable').
    .PARAMETER FetchSource
        The Rollup.FetchSource value, interpolated into the
        COST DATA UNAVAILABLE state text.
    .OUTPUTS
        [string]
    #>
    param(
        [Parameter(Mandatory)][object]$RateSection,
        [Parameter(Mandatory)][bool]$FetchUnavailable,
        [Parameter(Mandatory)][string]$FetchSource
    )
    if ($FetchUnavailable) {
        return "COST DATA UNAVAILABLE (fetch $FetchSource)"
    }
    if ($RateSection.InsufficientData) {
        return "INSUFFICIENT DATA (n=$($RateSection.N) < 5)"
    }
    $display = '{0:F2} ({1} of {2})' -f $RateSection.Rate, $RateSection.Numerator, $RateSection.N
    if ($RateSection.CouldNotVerifyCount -gt 0) {
        $display += " [could-not-verify: $($RateSection.CouldNotVerifyCount)]"
    }
    return $display
}

#endregion

#region Format-ReviewCostSection

function Format-ReviewCostSection {
    <#
    .SYNOPSIS
        Renders the Get-ReviewCostRollup output as a per-stage review-cost
        table (issue #768 s5), meant to be printed immediately after
        Format-PhaseContainmentReport's value report output.
    .DESCRIPTION
        Presentation-only: never computes rates itself (Get-ReviewCostRollup
        owns aggregation) and never touches the frozen value renderer in
        phase-containment-rolling-history-core.ps1. Stage order mirrors
        Format-PhaseContainmentReport's own stage order (design-challenge,
        plan-stress-test, code-review) so the two sections read as one
        coherent pass.

        Per stage block, lines render in this order (issue #768 s5
        new-section ordering): a value-side reference line (pointing back
        at that stage's block in the value report above), the
        defense-kill rate (judge-rulings; code-review and plan-stress-test
        only), the post-judge dismiss-rate / dismiss-rate
        (review-dispositions for code-review, finding_dispositions for
        design-challenge), the defer count (code-review only), then the
        code-review per-reviewer-source sub-table. A stage with no
        applicable field for one of these positions simply omits that line.

        Two noise concepts are ALWAYS distinctly labeled and never merged
        under one label: "Defense-kill rate" (judge-rulings) and
        "Post-judge dismiss-rate" (review-dispositions). The
        design-challenge dismiss-rate line is explicitly labeled
        "Dismiss-rate (over dispositioned findings)" and is immediately
        followed by a comparability caveat noting that convergence-filtered
        findings are excluded from that denominator, so a reader cannot
        compare it apples-to-apples against the code-review post-judge
        dismiss-rate without that caveat (judge-sustained M17).

        Three honest, never-a-confident-zero states render via
        Format-CostRateDisplayValue: INSUFFICIENT DATA (n<5, per
        sub-section), COST DATA UNAVAILABLE (fetch {source}) (checked
        BEFORE the n<5 gate, so a corpus fetch failure is never mistaken
        for a thin-data n=0 result), and the forward-gap line ("PRs with
        value data but no cost marker: N"), rendered unconditionally at the
        end of the section regardless of fetch state.
    .PARAMETER Rollup
        The Get-ReviewCostRollup return object.
    .OUTPUTS
        [string[]] — the report lines.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][object]$Rollup
    )

    $fetchUnavailable = $Rollup.FetchState -eq 'unavailable'
    $lines = [System.Collections.Generic.List[string]]::new()

    $lines.Add('')
    $lines.Add('Review Cost (presentation-only)')
    $lines.Add('')

    # CM6 fix (judge-sustained PR #833 review, plan AC4): $Rollup.Truncated
    # was computed and passed through but never rendered here — only the
    # CLI-level population-DIVERGENCE warning (report.ps1) mentioned it, and
    # only when the value-side and cost-side Truncated flags DISAGREE. When
    # both agree Truncated=true, the section previously showed confident
    # rates with zero truncation caveat. Render an explicit caveat whenever
    # Rollup.Truncated is true, independent of that CLI-level check.
    if ($Rollup.Truncated) {
        $lines.Add('CAUTION: comment corpus fetch was Truncated — the rates below may be computed from an incomplete population.')
        $lines.Add('')
    }

    # ---- design-challenge ----
    $lines.Add('Stage: design-challenge')
    $lines.Add('  Value-side reference: see the Stage: design-challenge block in the report above.')
    $designRate = $Rollup.DesignChallenge.DismissRate
    $lines.Add("  Dismiss-rate (over dispositioned findings): $(Format-CostRateDisplayValue -RateSection $designRate -FetchUnavailable $fetchUnavailable -FetchSource $Rollup.FetchSource)")
    $lines.Add('  Comparability caveat: convergence-filtered findings are excluded from this denominator; do not compare this rate directly against the code-review post-judge dismiss-rate without accounting for that exclusion.')
    $lines.Add('')

    # ---- plan-stress-test ----
    $lines.Add('Stage: plan-stress-test')
    $lines.Add('  Value-side reference: see the Stage: plan-stress-test block in the report above.')
    $planRate = $Rollup.PlanStressTest.DefenseKillRate
    $lines.Add("  Defense-kill rate: $(Format-CostRateDisplayValue -RateSection $planRate -FetchUnavailable $fetchUnavailable -FetchSource $Rollup.FetchSource)")
    $lines.Add('')

    # ---- code-review ----
    $lines.Add('Stage: code-review')
    $lines.Add('  Value-side reference: see the Stage: code-review block in the report above.')
    $codeReviewDefenseRate = $Rollup.CodeReview.DefenseKillRate
    $lines.Add("  Defense-kill rate: $(Format-CostRateDisplayValue -RateSection $codeReviewDefenseRate -FetchUnavailable $fetchUnavailable -FetchSource $Rollup.FetchSource)")
    $codeReviewDismissRate = $Rollup.CodeReview.PostJudgeDismissRate
    $lines.Add("  Post-judge dismiss-rate: $(Format-CostRateDisplayValue -RateSection $codeReviewDismissRate -FetchUnavailable $fetchUnavailable -FetchSource $Rollup.FetchSource)")
    if ($fetchUnavailable) {
        $lines.Add("  Defer count: COST DATA UNAVAILABLE (fetch $($Rollup.FetchSource))")
    }
    else {
        $lines.Add("  Defer count: $($Rollup.CodeReview.DeferCount)")
    }
    $lines.Add('  Per-reviewer-source (code-review):')
    if ($fetchUnavailable) {
        $lines.Add("    COST DATA UNAVAILABLE (fetch $($Rollup.FetchSource))")
    }
    elseif ($Rollup.CodeReview.PerSource.Count -eq 0) {
        $lines.Add('    (no per-source data in window)')
    }
    else {
        foreach ($sourceName in $Rollup.CodeReview.PerSource.Keys) {
            $sourceRate = $Rollup.CodeReview.PerSource[$sourceName]
            $valueText = Format-CostRateDisplayValue -RateSection $sourceRate -FetchUnavailable $false -FetchSource $Rollup.FetchSource
            $lines.Add("    ${sourceName}: $valueText")
        }
    }
    $lines.Add('')

    # ---- forward gap (always rendered, independent of fetch state) ----
    # CM5 fix (judge-sustained PR #833 review): under a corpus fetch failure
    # (Source: timeout | repo-resolution-failed), Get-ReviewCostRollup skips
    # the tuple walk entirely, so ForwardGapCount becomes the ENTIRE
    # value-side population — a confident-looking number computed from data
    # that was never actually fetched. Render the same honest
    # COST DATA UNAVAILABLE state the rate lines already use instead of a
    # confident count in that case.
    if ($fetchUnavailable) {
        $lines.Add("PRs with value data but no cost marker: COST DATA UNAVAILABLE (fetch $($Rollup.FetchSource))")
    }
    else {
        $lines.Add("PRs with value data but no cost marker: $($Rollup.ForwardGapCount)")
    }
    $lines.Add('')

    return $lines.ToArray()
}

#endregion
