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

# Trivial-diff heuristic threshold for Get-DispositionsLandingGap's
# unreviewed-PR split (issue #869 s4): a merged PR whose additions+deletions
# is <= this value is bucketed "trivial" rather than "substantive" when it
# carries neither a judge-rulings head nor a review-dispositions marker.
# Chosen as a conservative small-diff cutoff (e.g. a one-line doc fix, a
# version bump, a single changelog entry) rather than derived from any
# historical review-skip dataset -- no such dataset exists yet. Revisit if
# evidence surfaces that this cutoff mis-buckets real review gaps as
# trivial.
$script:DispositionsLandingGapTrivialDiffThreshold = 20

#endregion

#region Private: head-presence detectors (routing, issue #768 s4 M1)

# Test-ReviewDispositionsHeadPresent (vocab-gated presence check for the
# <!-- review-dispositions-{N} --> marker head, consumed by
# Get-ReviewCostRollup below) relocated to
# phase-containment-emission-check-core.ps1 (issue #854 s3, M10) — it now
# lives beside Get-DispositionTally and Get-ReviewDispositionsRealHeadMatch,
# the function it wraps. This file dot-sources that file above and consumes
# the relocated function directly (same established pattern as
# Test-JudgeRulingsRealHeadPresent below, which has always delegated to
# emission-check-core.ps1's Get-RealJudgeRulingsHeadMatches). This retires,
# rather than extends, the CM17 script:-private cross-file duplication this
# gate used to carry as its own second copy of the head-detection logic
# (issue #842 CM11's duplication class).

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

        CM2 fix (issue #842): mirrors Test-EmissionMarkerPresent's 811-D1
        prose-body fallback (plan-stress-test surface only). A plan comment
        can legitimately carry a prose-only "Plan Stress-Test" section
        (heading + narrative bullets, `<!-- plan-issue-` marker present) with
        no machine-readable judge-rulings block at all — every plan
        persisted before the 811 writer change is exactly this shape.
        Without this fallback, such a body's index never enters
        Get-ReviewCostRollup's judge-rulings candidate list at all, so the
        whole tuple contributes nothing (silence) instead of an honest
        could-not-verify. -Surface 'plan-stress-test' opts into the SAME
        two-condition check Test-EmissionMarkerPresent uses (both a durable
        `<!-- plan-issue-` marker AND a line-start `**Plan Stress-Test**`
        heading required together, so ordinary chatter that merely mentions
        the heading in prose does not qualify).
    .PARAMETER Body
        The raw comment body text to scan.
    .PARAMETER Surface
        Optional, defaults to 'code-review'. Set to 'plan-stress-test' to
        additionally apply the 811-D1 prose-body fallback described above.
    .OUTPUTS
        [bool]
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Body,
        [ValidateSet('code-review', 'plan-stress-test')][string]$Surface = 'code-review'
    )
    if ([string]::IsNullOrWhiteSpace($Body)) { return $false }
    if ((Get-RealJudgeRulingsHeadMatches -Body $Body).Count -gt 0) { return $true }
    if ($Surface -eq 'plan-stress-test') {
        $hasPlanIssueMarker = [regex]::IsMatch($Body, '<!--\s*plan-issue-')
        $hasPlanStressTestHeading = [regex]::IsMatch($Body, '(?m)^\*\*Plan Stress-Test\*\*')
        if ($hasPlanIssueMarker -and $hasPlanStressTestHeading) { return $true }
    }
    return $false
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

        if ($null -eq $dt) {
            # Unparseable timestamp: array order (later index processed
            # later) wins, but only among unparseable candidates. CM9 fix
            # (issue #842): clear $bestDt/$haveBestDt here so this
            # unparseable candidate does not silently inherit a
            # previously-established real timestamp as its own -- a later
            # parseable candidate must be judged as the new best outright,
            # not compared against a stale $bestDt that no longer describes
            # the candidate at $bestIndex.
            $bestIndex = $idx
            $bestDt = $null
            $haveBestDt = $false
        }
        elseif (-not $haveBestDt -or $dt -ge $bestDt) {
            $bestIndex = $idx
            $bestDt = $dt
            $haveBestDt = $true
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
                # G-CR10 fix (PR #859 GitHub-review post-fix): pass -ExpectedNumber,
                # matching the G-C1 fix at the sibling emission-check module's own
                # Get-ExternalSourceNovelSustainedCount call site. Without it, a
                # quoted/cross-referenced review-dispositions-{N} marker for a
                # DIFFERENT PR than $number would be treated as present here and
                # feed this PR's cost/dismiss-rate tallies.
                if (-not (Test-ReviewDispositionsHeadPresent -Body $body -ExpectedNumber $number)) { continue }
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
            # CM2 (issue #842): pass the plan-stress-test surface hint only
            # for Surface='issue' tuples, so the 811-D1 prose-body fallback
            # applies to plan-stress-test bodies only, matching
            # Test-EmissionMarkerPresent's own surface-scoped divergence.
            $headCheckSurface = if ($surface -eq 'issue') { 'plan-stress-test' } else { 'code-review' }
            for ($i = 0; $i -lt $bodies.Count; $i++) {
                if (Test-JudgeRulingsRealHeadPresent -Body ([string]$bodies[$i]) -Surface $headCheckSurface) {
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
                # CM18 fix (issue #842): the review-dispositions and
                # judge-rulings branches above both add the PR number to
                # $costPresentPrNumbers when Surface='pr'; this branch never
                # did, even though design-challenge is "any surface" per this
                # function's own routing contract -- a PR carrying ONLY a
                # finding_dispositions marker was wrongly counted as a
                # forward gap (no cost data) despite having real cost data.
                if ($surface -eq 'pr') { $costPresentPrNumbers.Add($number) | Out-Null }
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
        $insufficientDisplay = "INSUFFICIENT DATA (n=$($RateSection.N) < 5)"
        # CM13 fix (issue #842): the could-not-verify suffix used to render
        # only on the confident-rate path below, so a thin-data section
        # (n<5) that ALSO had could-not-verify contributions silently
        # dropped that signal -- a reader saw only "n<5" with no hint that
        # some contributions were excluded as unparseable rather than
        # genuinely absent.
        if ($RateSection.CouldNotVerifyCount -gt 0) {
            $insufficientDisplay += " $(Format-CouldNotVerifySuffix -Count $RateSection.CouldNotVerifyCount)"
        }
        return $insufficientDisplay
    }
    $display = '{0:F2} ({1} of {2})' -f $RateSection.Rate, $RateSection.Numerator, $RateSection.N
    if ($RateSection.CouldNotVerifyCount -gt 0) {
        $display += " $(Format-CouldNotVerifySuffix -Count $RateSection.CouldNotVerifyCount)"
    }
    return $display
}

function script:Format-CouldNotVerifySuffix {
    <#
    .SYNOPSIS
        Renders the "[could-not-verify: N body|bodies]" suffix shared by
        both Format-CostRateDisplayValue branches (issue #842 CM15).
    .DESCRIPTION
        N and Numerator (rendered elsewhere on the same line) count
        individual findings/entries; CouldNotVerifyCount always counts
        whole excluded BODIES (one per unparseable comment, regardless of
        how many findings that body might have contained) -- see
        Get-ReviewCostRollup's per-body could-not-verify accounting and
        New-DefenseKillRateSubSection's per-contribution (one contribution
        per PR/issue tuple, itself body-shaped after Select-LatestByCreatedAt
        dedup) CouldNotVerifyCount. Naming the unit explicitly stops a
        reader from mistaking this count as additional findings.
    .PARAMETER Count
        The CouldNotVerifyCount value (must be > 0; callers already gate on
        this before calling).
    .OUTPUTS
        [string]
    #>
    param(
        [Parameter(Mandatory)][int]$Count
    )
    $unit = if ($Count -eq 1) { 'body' } else { 'bodies' }
    return "[could-not-verify: $Count $unit]"
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

#region Private: review-dispositions marker contribution (issue #869 s4)

function script:Get-DispositionsLandingGapMarkerContribution {
    <#
    .SYNOPSIS
        Resolves whether a PR tuple carries a real, judge-authored
        review-dispositions marker, and if so, that marker's latest
        generation's ExternalSourcesFound/ParseStatus state (issue #869 s4).
    .DESCRIPTION
        Shared by Get-DispositionsLandingGap's data path (a) (landing-gap
        detection + internal-only-coverage contribution) and data path (b)'s
        integrity-warning arm (marker-without-judge-evidence detection +
        its own internal-only-coverage contribution) — both need the SAME
        "does this PR have a judge-authored review-dispositions head, and
        what does its latest generation say" answer, just sourced from a
        different fetch (corpus (a) vs the supplemental fetch (b)).

        Reuses Select-PhaseContainmentJudgeAuthoredBodies
        (phase-containment-rolling-history-core.ps1, exported/public — the
        frozen file's own NON-GOALS explicitly permit read-only reuse of its
        exported functions, issue #768-D2) for the author filter, rather
        than re-deriving the judge-identity comparison here. Among the
        judge-authored bodies carrying a real review-dispositions head
        (Test-ReviewDispositionsHeadPresent, -ExpectedNumber-gated so a
        quoted/cross-referenced marker for a DIFFERENT PR is never mistaken
        for this PR's own), the LAST one in Bodies' original (creation)
        order is treated as the latest generation.
        Select-PhaseContainmentJudgeAuthoredBodies does not preserve each
        body's original index, so this is a documented simplification of
        this file's usual Select-LatestByCreatedAt dedup (acceptable here:
        this function only ever feeds an informational/descriptive count —
        Get-DispositionsLandingGap's (c) internal-only-coverage arm — never
        a gating numerator).

        Runtime dependency (documented, not a violation of 768-D2): this
        function calls Select-PhaseContainmentJudgeAuthoredBodies, which
        this file does not dot-source itself — the CALLER must already have
        dot-sourced phase-containment-rolling-history-core.ps1 before this
        function runs, exactly as phase-containment-report.ps1's documented
        3-file dot-source order already guarantees for its own production
        call path. A standalone Pester run covering this function would need
        to add that dot-source too.
    .PARAMETER Bodies
        The tuple's Bodies[] array.
    .PARAMETER AuthorLogins
        The tuple's AuthorLogins[] array, index-paired with Bodies.
    .PARAMETER JudgeLogin
        The expected judge identity's login.
    .PARAMETER Number
        The PR number, passed to Test-ReviewDispositionsHeadPresent's
        -ExpectedNumber.
    .OUTPUTS
        [PSCustomObject] with HasMarker [bool], ParseStatus [string]|$null
        ('ok' | 'could-not-verify'), ExternalSourcesFound [bool].
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Bodies,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AuthorLogins,
        [Parameter(Mandatory)][string]$JudgeLogin,
        [Parameter(Mandatory)][int]$Number
    )
    $judgeBodies = Select-PhaseContainmentJudgeAuthoredBodies -Bodies $Bodies -AuthorLogins $AuthorLogins -JudgeLogin $JudgeLogin
    $realHeadJudgeBodies = @($judgeBodies | Where-Object { Test-ReviewDispositionsHeadPresent -Body $_ -ExpectedNumber $Number })
    if ($realHeadJudgeBodies.Count -eq 0) {
        return [PSCustomObject]@{ HasMarker = $false; ParseStatus = $null; ExternalSourcesFound = $false }
    }
    $latestBody = $realHeadJudgeBodies[-1]
    $tally = Get-DispositionTally -Surface 'code-review' -Body $latestBody
    return [PSCustomObject]@{ HasMarker = $true; ParseStatus = $tally.ParseStatus; ExternalSourcesFound = [bool]$tally.ExternalSourcesFound }
}

#endregion

#region Get-DispositionsLandingGapSupplementalCorpus

function script:Get-DispositionsLandingGapSupplementalAuthorLogin {
    <#
    .SYNOPSIS
        Extracts a GraphQL comment node's author login, defaulting to ''
        (issue #869 s4 — mirrors phase-containment-rolling-history-core.ps1's
        script:Get-PhaseContainmentCommentAuthorLogin, duplicated in miniature
        here rather than reached into cross-file: that helper is script:-
        scoped/private to the frozen file, unlike the exported functions this
        file's other new code reuses).
    .PARAMETER CommentNode
        A single comment node hashtable (from ConvertFrom-Json -AsHashtable).
    .OUTPUTS
        [string] the author's login, or '' when unresolvable.
    #>
    param([AllowNull()]$CommentNode)
    if ($null -eq $CommentNode -or $CommentNode -isnot [hashtable]) { return '' }
    if (-not $CommentNode.ContainsKey('author')) { return '' }
    $author = $CommentNode['author']
    if ($null -eq $author -or $author -isnot [hashtable]) { return '' }
    if (-not $author.ContainsKey('login')) { return '' }
    return [string]$author['login']
}

function Get-DispositionsLandingGapSupplementalCorpus {
    <#
    .SYNOPSIS
        Independent, scoped GraphQL fetch of merged PRs' mergedAt/additions/
        deletions plus full comment corpus (issue #869 s4).
    .DESCRIPTION
        Get-PhaseContainmentCommentCorpus's Surface B
        (phase-containment-rolling-history-core.ps1, frozen per 768-D2)
        structurally DROPS any merged PR whose joined comment text never
        matches the judge-rulings head regex, and never captures each PR's
        mergedAt/additions/deletions — Get-DispositionsLandingGap's
        integrity-warning arm, unreviewed split, and ship-date floor
        partition all need exactly the population that fetch discards, plus
        fields it never asked for. This is a SEPARATE, SCOPED fetch modeled
        on script:Get-SurfaceBCorpusGraphQL's search-query shape (same
        `repo:$Owner/$Repo is:pr is:merged merged:>$since` search, same
        outer-cursor pagination style) — not a modification of that frozen
        function, and its output never contributes to
        Get-DispositionsLandingGap's landing-gap numerator (that stays
        corpus (a)-only per locked design decision d2).

        Unlike script:Get-SurfaceBCorpusGraphQL, this fetch does NOT skip
        comment pagination for PRs lacking a judge-rulings marker — the
        integrity-warning and unreviewed-split arms need to see PRs with NO
        artifacts at all, so every discovered PR's full comment set is
        collected (bounded by -TimeoutSeconds, the same fail-safe truncation
        convention used throughout this codebase).

        GraphQL-only (issue #869 s4 scope decision, YAGNI): unlike
        Get-PhaseContainmentCommentCorpus, this fetch has no REST fallback.
        A GraphQL failure degrades to Source 'timeout' |
        'repo-resolution-failed' (an honest "unavailable" state — see
        Format-DispositionsLandingGapSection) rather than silently retrying
        via `gh issue/pr view`. The two arms this fetch feeds already render
        an explicit unavailable state on failure, so a REST-fallback code
        path (which would roughly double this function's size) is deferred
        until evidence shows GraphQL failures actually matter for this seam.
    .PARAMETER RepoOwner
        GitHub repository owner. Resolved via `gh repo view` if not supplied.
    .PARAMETER RepoName
        GitHub repository name. Resolved via `gh repo view` if not supplied.
    .PARAMETER WindowDays
        Number of past days to scan. Default: 90 (matches
        Get-PhaseContainmentCommentCorpus's default so callers can pass the
        SAME -WindowDays to both fetches and get population-comparable
        results).
    .PARAMETER TimeoutSeconds
        Per-run budget in seconds. Default: 30.
    .OUTPUTS
        [PSCustomObject] with:
          Tuples    [array] — each entry: @{ Number [int]; MergedAt [string]
                    ISO8601 (raw, unconverted); Additions [int]; Deletions
                    [int]; Bodies [string[]]; CreatedAtValues [string[]];
                    AuthorLogins [string[]] }
          FetchedAt [datetime]
          Source    [string] — 'graphql' | 'timeout' | 'repo-resolution-failed'
          Truncated [bool]
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string]$RepoOwner   = '',
        [string]$RepoName    = '',
        [int]$WindowDays     = 90,
        [int]$TimeoutSeconds = 30
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # ---- Resolve repo owner/name (mirrors Get-PhaseContainmentCommentCorpus's
    # own resolution block; duplicated rather than reached into cross-file --
    # that block is not itself an exported function). ----
    if (-not $RepoOwner -or -not $RepoName) {
        if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            Write-Warning "phase-containment-cost-core: timed out before supplemental repo resolution"
            return [PSCustomObject]@{ Tuples = @(); FetchedAt = (Get-Date); Source = 'timeout'; Truncated = $false }
        }
        $repoViewJson = & gh repo view --json 'owner,name' 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "phase-containment-cost-core: gh repo view failed (exit $LASTEXITCODE)"
            return [PSCustomObject]@{ Tuples = @(); FetchedAt = (Get-Date); Source = 'repo-resolution-failed'; Truncated = $false }
        }
        try {
            $repoInfo = ($repoViewJson | Out-String) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if (-not $RepoOwner) { $RepoOwner = [string]$repoInfo['owner']['login'] }
            if (-not $RepoName) { $RepoName = [string]$repoInfo['name'] }
        }
        catch {
            Write-Warning "phase-containment-cost-core: failed to parse repo view: $_"
            return [PSCustomObject]@{ Tuples = @(); FetchedAt = (Get-Date); Source = 'repo-resolution-failed'; Truncated = $false }
        }
    }

    if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
        Write-Warning "phase-containment-cost-core: timed out before supplemental GraphQL fetch"
        return [PSCustomObject]@{ Tuples = @(); FetchedAt = (Get-Date); Source = 'timeout'; Truncated = $false }
    }

    $tuples = [System.Collections.Generic.List[hashtable]]::new()
    $truncated = $false
    $since = (Get-Date).ToUniversalTime().AddDays(-$WindowDays).ToString('yyyy-MM-dd')

    $searchCursor = $null
    $searchHasNext = $true

    try {
        while ($searchHasNext) {
            if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                Write-Warning "phase-containment-cost-core: timed out paginating supplemental search"
                $truncated = $true
                break
            }

            $searchAfterClause = if ($null -ne $searchCursor) { ", after: `"$searchCursor`"" } else { '' }
            $query = @"
{
  search(query: "repo:$RepoOwner/$RepoName is:pr is:merged merged:>$since", type: ISSUE, first: 50$searchAfterClause) {
    pageInfo { hasNextPage endCursor }
    nodes {
      ... on PullRequest {
        number
        mergedAt
        additions
        deletions
        comments(first: 100) {
          nodes { author { login } body createdAt }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }
}
"@

            $output = & gh api graphql -f "query=$query" 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "phase-containment-cost-core: supplemental GraphQL search failed (exit $LASTEXITCODE)"
                return [PSCustomObject]@{ Tuples = @(); FetchedAt = (Get-Date); Source = 'timeout'; Truncated = $false }
            }

            $parsed = ($output | Out-String) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if ($parsed.ContainsKey('errors') -and $null -ne $parsed['errors'] -and @($parsed['errors']).Count -gt 0) {
                Write-Warning "phase-containment-cost-core: supplemental GraphQL returned errors"
                return [PSCustomObject]@{ Tuples = @(); FetchedAt = (Get-Date); Source = 'timeout'; Truncated = $false }
            }

            $searchBlock = $parsed['data']['search']
            $nodes = @($searchBlock['nodes'])

            foreach ($prNode in $nodes) {
                if ($null -eq $prNode) { continue }
                $prNum = [int]$prNode['number']
                $mergedAt = [string]$prNode['mergedAt']
                $additions = [int]$prNode['additions']
                $deletions = [int]$prNode['deletions']

                $commentBodies = [System.Collections.Generic.List[string]]::new()
                $commentCreatedAt = [System.Collections.Generic.List[string]]::new()
                $commentAuthorLogins = [System.Collections.Generic.List[string]]::new()

                $commentBlock = $prNode['comments']
                $commentNodes = @($commentBlock['nodes'])
                foreach ($cn in $commentNodes) {
                    if ($null -ne $cn) {
                        $commentBodies.Add([string]$cn['body'])
                        $commentCreatedAt.Add([string]$cn['createdAt'])
                        $commentAuthorLogins.Add((script:Get-DispositionsLandingGapSupplementalAuthorLogin -CommentNode $cn))
                    }
                }

                $pageInfo = $commentBlock['pageInfo']
                $cursor = if ([bool]$pageInfo['hasNextPage']) { [string]$pageInfo['endCursor'] } else { $null }

                # Unlike script:Get-SurfaceBCorpusGraphQL, always paginate
                # every PR's remaining comments regardless of marker
                # presence — see .DESCRIPTION.
                while ($null -ne $cursor) {
                    if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                        Write-Warning "phase-containment-cost-core: timed out paginating supplemental PR #$prNum"
                        $truncated = $true
                        break
                    }

                    $pageQuery = @"
{
  repository(owner: "$RepoOwner", name: "$RepoName") {
    pullRequest(number: $prNum) {
      comments(first: 100, after: "$cursor") {
        nodes { author { login } body createdAt }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}
"@
                    $pageOutput = & gh api graphql -f "query=$pageQuery" 2>$null
                    if ($LASTEXITCODE -ne 0) {
                        Write-Warning "phase-containment-cost-core: supplemental post-page gh call failed for PR #$prNum (exit $LASTEXITCODE)"
                        $truncated = $true
                        break
                    }

                    try {
                        $pageParsed = ($pageOutput | Out-String) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                        $pageComments = $pageParsed['data']['repository']['pullRequest']['comments']
                        foreach ($cn in @($pageComments['nodes'])) {
                            if ($null -ne $cn) {
                                $commentBodies.Add([string]$cn['body'])
                                $commentCreatedAt.Add([string]$cn['createdAt'])
                                $commentAuthorLogins.Add((script:Get-DispositionsLandingGapSupplementalAuthorLogin -CommentNode $cn))
                            }
                        }
                        $pi = $pageComments['pageInfo']
                        $cursor = if ([bool]$pi['hasNextPage']) { [string]$pi['endCursor'] } else { $null }
                    }
                    catch {
                        Write-Warning "phase-containment-cost-core: failed to parse supplemental pagination response for PR #${prNum}: $_"
                        $truncated = $true
                        break
                    }
                }

                $tuples.Add(@{
                        Number          = $prNum
                        MergedAt        = $mergedAt
                        Additions       = $additions
                        Deletions       = $deletions
                        Bodies          = $commentBodies.ToArray()
                        CreatedAtValues = $commentCreatedAt.ToArray()
                        AuthorLogins    = $commentAuthorLogins.ToArray()
                    })
            }

            $searchPageInfo = $searchBlock['pageInfo']
            $nextCursor = if ($null -ne $searchPageInfo -and $searchPageInfo.ContainsKey('endCursor')) { [string]$searchPageInfo['endCursor'] } else { '' }
            if ([bool]$searchPageInfo['hasNextPage'] -and -not [string]::IsNullOrEmpty($nextCursor)) {
                $searchCursor = $nextCursor
                $searchHasNext = $true
            }
            else {
                $searchCursor = $null
                $searchHasNext = $false
            }
        }
    }
    catch {
        Write-Warning "phase-containment-cost-core: failed to parse supplemental GraphQL response: $_"
        return [PSCustomObject]@{ Tuples = @(); FetchedAt = (Get-Date); Source = 'timeout'; Truncated = $false }
    }

    return [PSCustomObject]@{
        Tuples    = $tuples.ToArray()
        FetchedAt = (Get-Date)
        Source    = 'graphql'
        Truncated = $truncated
    }
}

#endregion

#region Get-DispositionsLandingGap

function Get-DispositionsLandingGap {
    <#
    .SYNOPSIS
        Aggregates the review-dispositions marker landing gap against the
        judge-rulings-anchored corpus, an integrity-warning arm, an
        unreviewed-PR split, and an internal-only-coverage informational
        count (issue #869 s4).
    .DESCRIPTION
        Mirrors Get-ReviewCostRollup's shape: a rollup function that returns
        a data object and performs no GitHub fetching itself — callers
        supply both the existing corpus (a) (Get-PhaseContainmentCommentCorpus's
        Tuples/Source/Truncated, already fetched once and shared with
        Get-ReviewCostRollup) and the new supplemental corpus (b)
        (Get-DispositionsLandingGapSupplementalCorpus's own
        Tuples/Source/Truncated).

        Two data paths:

        (a) Landing gap — corpus (a) is rulings-anchored: Surface B only
        admits a merged PR when its joined comment text matches the
        judge-rulings head regex, so every Surface='pr' tuple here already
        has judge-rulings evidence. For each such tuple, this checks
        whether it ALSO carries a real, judge-authored
        `review-dispositions-{PR}` marker head
        (Get-DispositionsLandingGapMarkerContribution, above). No marker ->
        landing gap. This numerator stays corpus (a)-only, per locked
        design decision d2 — the supplemental fetch (b) below NEVER
        contributes to or replaces it.

        (b) Supplemental fetch arms — corpus (a) structurally drops any PR
        lacking judge-rulings evidence, so it cannot see marker-without-
        judge-evidence PRs or PRs with no artifacts at all.
        SupplementalTuples (from Get-DispositionsLandingGapSupplementalCorpus)
        covers exactly that population. For each supplemental tuple that has
        NO real judge-rulings head anywhere in its comments (unauthored-
        gated: judge-rulings evidence from ANY commenter counts, matching
        Get-ReviewCostRollup's own Test-JudgeRulingsRealHeadPresent reuse) —
        a tuple WITH judge-rulings evidence is already data path (a)'s
        domain and is skipped here to avoid double-counting — this derives:
          (i)  integrity-warning arm: a real, judge-authored
               review-dispositions marker head IS present -> a genuine
               data-integrity anomaly (marker without judge evidence),
               rendered as an explicit warning, never folded into a count.
          (ii) unreviewed split: NEITHER head is present -> bucketed
               trivial (additions+deletions <=
               $script:DispositionsLandingGapTrivialDiffThreshold) vs
               substantive.

        (c) Internal-only-coverage — an INFORMATIONAL count, not a "gap":
        among PRs carrying a real, judge-authored review-dispositions
        marker from EITHER data path (data path (a)'s covered PRs, and data
        path (b)'s integrity-warning arm — mutually exclusive sets by
        construction, since (a) requires judge-rulings evidence and (b)'s
        arm requires its absence), counts how many carry the marker WITHOUT
        `external_sources_reconciled` present (internal-mode signature) vs
        WITH it present (GitHub-Review-Mode signature, S6-eligible). Per
        skills/review-judgment/SKILL.md, `external_sources_reconciled` is a
        SESSION property (GitHub Review Mode only), never inferred from
        marker content — this deliberately does NOT flag the internal-only
        case as a defect.

        (d) Ship-date floor — when -FixShipDate is supplied, partitions the
        landing-gap PRs (data path (a)) into post-ship (mergedAt >
        FixShipDate, expected 0) and pre-ship backlog (not alarmed). Data
        path (a)'s own corpus has no mergedAt; this reuses
        SupplementalTuples' MergedAt for PR numbers that also appear there
        (chosen over a second small supplemental lookup — both fetches
        share the same "is:pr is:merged merged:>$since" search population
        for the SAME -WindowDays, so the overlap is expected to be
        near-total). A landing-gap PR whose MergedAt cannot be resolved
        this way is counted in MergedAtUnresolvedCount instead of being
        silently guessed into either bucket. When -FixShipDate is omitted,
        the landing-gap count renders unpartitioned with a
        floor-not-configured note (see Format-DispositionsLandingGapSection).
    .PARAMETER Tuples
        The Tuples array from Get-PhaseContainmentCommentCorpus (data path
        a; reused, never re-fetched by this function).
    .PARAMETER Source
        The corpus (a) Source flag: 'graphql' | 'rest' | 'timeout' |
        'repo-resolution-failed'.
    .PARAMETER Truncated
        The corpus (a) Truncated flag, passed through unchanged.
    .PARAMETER SupplementalTuples
        The Tuples array from Get-DispositionsLandingGapSupplementalCorpus
        (data path b).
    .PARAMETER SupplementalSource
        The supplemental fetch's Source flag: 'graphql' | 'timeout' |
        'repo-resolution-failed'.
    .PARAMETER SupplementalTruncated
        The supplemental fetch's Truncated flag, passed through unchanged.
    .PARAMETER JudgeLogin
        The judge identity's login. REQUIRED, no default — matches
        Select-PhaseContainmentJudgeAuthoredBodies's own no-default
        contract. A default here would risk the same default-trap
        phase-containment-report.ps1's own -JudgeLogin history warns
        against (a default that matches nothing silently reads 0 entries);
        callers must supply the resolved identity explicitly.
    .PARAMETER FixShipDate
        Optional. When supplied, partitions the landing-gap PRs into
        post-ship / pre-ship-backlog (see (d) above).
    .OUTPUTS
        [PSCustomObject] with:
          FetchState              [string] — 'ok' | 'unavailable' (corpus a)
          FetchSource             [string] — corpus (a) Source, passed through
          Truncated               [bool] — corpus (a) Truncated
          SupplementalFetchState  [string] — 'ok' | 'unavailable' (corpus b)
          SupplementalFetchSource [string] — corpus (b) Source, passed through
          SupplementalTruncated   [bool] — corpus (b) Truncated
          LandingGap              [PSCustomObject] — Partitioned [bool],
                                  TotalCount [int], PostShipCount [int]|$null,
                                  PreShipBacklogCount [int]|$null,
                                  MergedAtUnresolvedCount [int]
          IntegrityWarning        [PSCustomObject] — Count [int],
                                  PrNumbers [int[]]
          UnreviewedSplit         [PSCustomObject] — TrivialCount [int],
                                  SubstantiveCount [int],
                                  TrivialThreshold [int]
          InternalOnlyCoverage    [PSCustomObject] — InternalOnlyCount [int],
                                  ExternalReconciledCount [int],
                                  CouldNotVerifyCount [int]
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Tuples,
        [Parameter(Mandatory)][ValidateSet('graphql', 'rest', 'timeout', 'repo-resolution-failed')][string]$Source,
        [Parameter(Mandatory)][bool]$Truncated,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$SupplementalTuples,
        [Parameter(Mandatory)][ValidateSet('graphql', 'timeout', 'repo-resolution-failed')][string]$SupplementalSource,
        [Parameter(Mandatory)][bool]$SupplementalTruncated,
        [Parameter(Mandatory)][AllowEmptyString()][string]$JudgeLogin,
        [Nullable[datetime]]$FixShipDate
    )

    if ([string]::IsNullOrWhiteSpace($JudgeLogin)) {
        throw "Get-DispositionsLandingGap: -JudgeLogin is required and must not be empty -- a default here would silently disable the judge-authorship gate (matches phase-containment-report.ps1's -JudgeLogin default-trap history)."
    }

    $fetchAUnavailable = $Source -in @('timeout', 'repo-resolution-failed')
    $fetchBUnavailable = $SupplementalSource -in @('timeout', 'repo-resolution-failed')

    $landingGapPrNumbers = [System.Collections.Generic.List[int]]::new()
    $landingGapMergedAtByNumber = [System.Collections.Generic.Dictionary[int, string]]::new()
    $internalOnlyCount = 0
    $externalReconciledCount = 0
    $internalCoverageCouldNotVerifyCount = 0
    $integrityWarningPrNumbers = [System.Collections.Generic.List[int]]::new()
    $unreviewedTrivialCount = 0
    $unreviewedSubstantiveCount = 0

    # ---- data path (a): landing gap + its internal-only-coverage contribution ----
    if (-not $fetchAUnavailable) {
        foreach ($tuple in $Tuples) {
            if ([string]$tuple.Surface -ne 'pr') { continue }
            $number = [int]$tuple.Number
            $bodies = @($tuple.Bodies)
            $authorLogins = @($tuple.AuthorLogins)

            $contrib = Get-DispositionsLandingGapMarkerContribution -Bodies $bodies -AuthorLogins $authorLogins -JudgeLogin $JudgeLogin -Number $number
            if (-not $contrib.HasMarker) {
                $landingGapPrNumbers.Add($number)
                continue
            }
            if ($contrib.ParseStatus -ne 'ok') {
                $internalCoverageCouldNotVerifyCount++
            }
            elseif ($contrib.ExternalSourcesFound) {
                $externalReconciledCount++
            }
            else {
                $internalOnlyCount++
            }
        }
    }

    # ---- data path (b): integrity-warning arm + unreviewed split ----
    if (-not $fetchBUnavailable) {
        foreach ($tuple in $SupplementalTuples) {
            $number = [int]$tuple.Number
            $mergedAtRaw = [string]$tuple.MergedAt
            $additions = [int]$tuple.Additions
            $deletions = [int]$tuple.Deletions
            $bodies = @($tuple.Bodies)
            $authorLogins = @($tuple.AuthorLogins)

            # Feed (d)'s ship-date lookup for EVERY supplemental PR (option
            # (ii) in the .DESCRIPTION above), not just the ones classified
            # below -- a landing-gap PR (data path a) resolves its MergedAt
            # from here whenever the two fetches' populations overlap.
            $landingGapMergedAtByNumber[$number] = $mergedAtRaw

            $hasJudgeRulingsAnywhere = $false
            foreach ($b in $bodies) {
                if (Test-JudgeRulingsRealHeadPresent -Body ([string]$b) -Surface 'code-review') {
                    $hasJudgeRulingsAnywhere = $true
                    break
                }
            }
            if ($hasJudgeRulingsAnywhere) {
                # Already data path (a)'s domain -- never double-count here.
                continue
            }

            $contrib = Get-DispositionsLandingGapMarkerContribution -Bodies $bodies -AuthorLogins $authorLogins -JudgeLogin $JudgeLogin -Number $number
            if ($contrib.HasMarker) {
                # (b)(i) integrity-warning arm.
                $integrityWarningPrNumbers.Add($number)
                if ($contrib.ParseStatus -ne 'ok') {
                    $internalCoverageCouldNotVerifyCount++
                }
                elseif ($contrib.ExternalSourcesFound) {
                    $externalReconciledCount++
                }
                else {
                    $internalOnlyCount++
                }
            }
            else {
                # (b)(ii) unreviewed split.
                $diffSize = $additions + $deletions
                if ($diffSize -le $script:DispositionsLandingGapTrivialDiffThreshold) {
                    $unreviewedTrivialCount++
                }
                else {
                    $unreviewedSubstantiveCount++
                }
            }
        }
    }

    # ---- (d): ship-date floor partition ----
    $landingGapTotalCount = $landingGapPrNumbers.Count
    $partitioned = $null -ne $FixShipDate
    $postShipCount = 0
    $preShipBacklogCount = 0
    $mergedAtUnresolvedCount = 0

    if ($partitioned) {
        foreach ($num in $landingGapPrNumbers) {
            $mergedAtStr = if ($landingGapMergedAtByNumber.ContainsKey($num)) { $landingGapMergedAtByNumber[$num] } else { $null }
            $mergedAtDt = $null
            if (-not [string]::IsNullOrWhiteSpace($mergedAtStr)) {
                try { $mergedAtDt = [datetime]::Parse($mergedAtStr, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { $mergedAtDt = $null }
            }
            if ($null -eq $mergedAtDt) {
                $mergedAtUnresolvedCount++
                continue
            }
            if ($mergedAtDt -gt $FixShipDate) {
                $postShipCount++
            }
            else {
                $preShipBacklogCount++
            }
        }
    }

    return [PSCustomObject]@{
        FetchState              = if ($fetchAUnavailable) { 'unavailable' } else { 'ok' }
        FetchSource             = $Source
        Truncated                = $Truncated
        SupplementalFetchState  = if ($fetchBUnavailable) { 'unavailable' } else { 'ok' }
        SupplementalFetchSource = $SupplementalSource
        SupplementalTruncated   = $SupplementalTruncated
        LandingGap              = [PSCustomObject]@{
            Partitioned             = $partitioned
            TotalCount              = $landingGapTotalCount
            PostShipCount           = if ($partitioned) { $postShipCount } else { $null }
            PreShipBacklogCount     = if ($partitioned) { $preShipBacklogCount } else { $null }
            MergedAtUnresolvedCount = if ($partitioned) { $mergedAtUnresolvedCount } else { 0 }
        }
        IntegrityWarning        = [PSCustomObject]@{
            Count     = $integrityWarningPrNumbers.Count
            PrNumbers = $integrityWarningPrNumbers.ToArray()
        }
        UnreviewedSplit          = [PSCustomObject]@{
            TrivialCount     = $unreviewedTrivialCount
            SubstantiveCount = $unreviewedSubstantiveCount
            TrivialThreshold = $script:DispositionsLandingGapTrivialDiffThreshold
        }
        InternalOnlyCoverage     = [PSCustomObject]@{
            InternalOnlyCount       = $internalOnlyCount
            ExternalReconciledCount = $externalReconciledCount
            CouldNotVerifyCount     = $internalCoverageCouldNotVerifyCount
        }
    }
}

#endregion

#region Format-DispositionsLandingGapSection

function Format-DispositionsLandingGapSection {
    <#
    .SYNOPSIS
        Renders the Get-DispositionsLandingGap output as a landing-gap /
        integrity-warning / unreviewed-split / internal-only-coverage
        section (issue #869 s4), meant to be printed immediately after
        Format-ReviewCostSection's output.
    .DESCRIPTION
        Presentation-only: never computes anything itself, mirroring
        Format-ReviewCostSection's own contract. Renders, in order: the
        landing-gap row (partitioned by -FixShipDate, or a single
        unpartitioned count with a floor-not-configured note), the
        integrity-warning line(s), the unreviewed trivial/substantive
        counts, and the internal-only-coverage informational count
        (explicitly labeled descriptive, never a "gap").

        Honest states: the landing-gap row renders
        "LANDING-GAP DATA UNAVAILABLE (fetch {source})" when
        Rollup.FetchState is 'unavailable' (corpus (a) fetch failed) rather
        than a confident zero. The integrity-warning and unreviewed-split
        rows render "SUPPLEMENTAL DATA UNAVAILABLE (fetch {source})" when
        Rollup.SupplementalFetchState is 'unavailable'.
        Internal-only-coverage renders an explicit caveat when EITHER fetch
        is unavailable, since its count unions both data paths (issue #869
        s4 (c)) and a single-side outage silently undercounts it rather
        than zeroing it cleanly.
    .PARAMETER Rollup
        The Get-DispositionsLandingGap return object.
    .OUTPUTS
        [string[]] — the report lines.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][object]$Rollup
    )

    $fetchAUnavailable = $Rollup.FetchState -eq 'unavailable'
    $fetchBUnavailable = $Rollup.SupplementalFetchState -eq 'unavailable'
    $lines = [System.Collections.Generic.List[string]]::new()

    $lines.Add('')
    $lines.Add('Review-Dispositions Landing Gap (presentation-only)')
    $lines.Add('')

    if ($Rollup.Truncated) {
        $lines.Add('CAUTION: the review-cost comment corpus fetch (data path a) was Truncated -- the landing-gap count below may be computed from an incomplete population.')
    }
    if ($Rollup.SupplementalTruncated) {
        $lines.Add('CAUTION: the supplemental fetch (data path b) was Truncated -- the integrity-warning/unreviewed-split counts below may be computed from an incomplete population.')
    }
    if ($Rollup.Truncated -or $Rollup.SupplementalTruncated) {
        $lines.Add('')
    }

    # ---- (a)/(d): landing gap, partitioned or not ----
    if ($fetchAUnavailable) {
        $lines.Add("Landing gap (judge-rulings present, no review-dispositions marker): LANDING-GAP DATA UNAVAILABLE (fetch $($Rollup.FetchSource))")
    }
    else {
        $lg = $Rollup.LandingGap
        if ($lg.Partitioned) {
            $lines.Add("Landing gap (judge-rulings present, no review-dispositions marker): $($lg.TotalCount) total -- post-ship: $($lg.PostShipCount) (expected 0), pre-ship backlog: $($lg.PreShipBacklogCount)")
            if ($lg.MergedAtUnresolvedCount -gt 0) {
                $lines.Add("  NOTE: $($lg.MergedAtUnresolvedCount) of the $($lg.TotalCount) landing-gap PR(s) could not be assigned a mergedAt date (not found in the supplemental fetch, or unparseable) and are excluded from the post-ship/pre-ship split above.")
            }
        }
        else {
            $lines.Add("Landing gap (judge-rulings present, no review-dispositions marker): $($lg.TotalCount) (ship-date floor not configured -- pass -FixShipDate to partition into post-ship/pre-ship backlog)")
        }
    }
    $lines.Add('')

    # ---- (b)(i): integrity-warning arm ----
    if ($fetchBUnavailable) {
        $lines.Add("Integrity warning (review-dispositions marker present, NO judge-rulings evidence anywhere): SUPPLEMENTAL DATA UNAVAILABLE (fetch $($Rollup.SupplementalFetchSource))")
    }
    else {
        $iw = $Rollup.IntegrityWarning
        if ($iw.Count -gt 0) {
            $prList = ($iw.PrNumbers | ForEach-Object { "#$_" }) -join ', '
            $lines.Add("WARNING: $($iw.Count) PR(s) carry a review-dispositions marker with NO judge-rulings evidence anywhere in their comments -- a genuine data-integrity anomaly, not a benign case: $prList")
        }
        else {
            $lines.Add('Integrity warning (review-dispositions marker present, NO judge-rulings evidence anywhere): 0 (none found)')
        }
    }
    $lines.Add('')

    # ---- (b)(ii): unreviewed split ----
    if ($fetchBUnavailable) {
        $lines.Add("Unreviewed merged PRs (neither judge-rulings nor review-dispositions): SUPPLEMENTAL DATA UNAVAILABLE (fetch $($Rollup.SupplementalFetchSource))")
    }
    else {
        $us = $Rollup.UnreviewedSplit
        $lines.Add("Unreviewed merged PRs (neither judge-rulings nor review-dispositions) -- trivial (additions+deletions <= $($us.TrivialThreshold)): $($us.TrivialCount); substantive: $($us.SubstantiveCount)")
    }
    $lines.Add('')

    # ---- (c): internal-only-coverage informational count ----
    $ioc = $Rollup.InternalOnlyCoverage
    $iocLabel = "Informational: $($ioc.InternalOnlyCount) PR(s) reviewed via internal-only passes (review-dispositions marker present, no external_sources_reconciled), not S6-eligible. $($ioc.ExternalReconciledCount) PR(s) reviewed via GitHub Review Mode (external_sources_reconciled present), S6-eligible."
    if ($ioc.CouldNotVerifyCount -gt 0) {
        $iocLabel += " $(Format-CouldNotVerifySuffix -Count $ioc.CouldNotVerifyCount)"
    }
    $lines.Add($iocLabel)
    if ($fetchAUnavailable -or $fetchBUnavailable) {
        $lines.Add('  CAVEAT: this count unions data paths (a) and (b) above; one or both are unavailable this run, so it likely undercounts rather than reflecting the true total.')
    }
    $lines.Add('')

    return $lines.ToArray()
}

#endregion
