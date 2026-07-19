#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester tests for Get-DispositionsLandingGap / Format-DispositionsLandingGapSection
# (issue #869 s4/s6, TDD red-green, s5 fixture matrix).
#
# File under test: .github/scripts/lib/phase-containment-cost-core.ps1
#
# All fixtures below are synthetic, constructed to the documented Tuples /
# SupplementalTuples shapes (Get-PhaseContainmentCommentCorpus and
# Get-DispositionsLandingGapSupplementalCorpus's own .OUTPUTS) -- no live
# GitHub calls. Each Describe block below isolates ONE of the 9 scenarios
# from the approved plan slice s5 fixture matrix, calling
# Get-DispositionsLandingGap with only the tuple(s) that scenario needs so
# the resulting counts are exact and unambiguous.

BeforeAll {
    $script:LibRoot = Join-Path $PSScriptRoot '..' 'lib'
    . (Join-Path $script:LibRoot 'phase-containment-cost-core.ps1')

    # Get-DispositionsLandingGapMarkerContribution's own .DESCRIPTION
    # documents a runtime (not dot-source) dependency on
    # Select-PhaseContainmentJudgeAuthoredBodies, defined in
    # phase-containment-rolling-history-core.ps1 -- that file is not
    # dot-sourced by phase-containment-cost-core.ps1 itself (issue #768-D2
    # keeps the 2,020-line file frozen), so a standalone Pester run covering
    # this function must add the dot-source here, exactly as documented.
    . (Join-Path $script:LibRoot 'phase-containment-rolling-history-core.ps1')

    $script:LandingGapJudgeLogin = 'github-actions[bot]'

#region Fixture: canonical judge-rulings bodies (data-path (a) evidence / (b) skip-domain proof)

    # Surface B's own invariant is that every Surface='pr' tuple in corpus
    # (a) already carries judge-rulings evidence -- these bodies model that
    # evidence for realism. Shape mirrors the existing canonical
    # judge-rulings fixtures already pinned elsewhere in this test suite
    # (phase-containment-cost-core.Tests.ps1's CostJudgeRulingsPr200RoundOneBody).
    $script:LandingGapJudgeRulingsPr1001Body = @'
```yaml
<!-- judge-rulings pr=1001 -->
- id: R1
  judge_ruling: sustained
```
'@

    $script:LandingGapJudgeRulingsPr1002Body = @'
```yaml
<!-- judge-rulings pr=1002 -->
- id: R1
  judge_ruling: sustained
```
'@

    $script:LandingGapJudgeRulingsPr1005Body = @'
```yaml
<!-- judge-rulings pr=1005 -->
- id: R1
  judge_ruling: sustained
```
'@

    $script:LandingGapJudgeRulingsPr1009Body = @'
```yaml
<!-- judge-rulings pr=1009 -->
- id: R1
  judge_ruling: sustained
```
'@

    $script:LandingGapJudgeRulingsPr1010Body = @'
```yaml
<!-- judge-rulings pr=1010 -->
- id: R1
  judge_ruling: sustained
```
'@

    # Post-review finding B/D2 fixtures (issue #869): reuse the same
    # canonical shape as the fixtures above for two new PR numbers.
    $script:LandingGapJudgeRulingsPr1015Body = @'
```yaml
<!-- judge-rulings pr=1015 -->
- id: R1
  judge_ruling: sustained
```
'@

    $script:LandingGapJudgeRulingsPr1017Body = @'
```yaml
<!-- judge-rulings pr=1017 -->
- id: R1
  judge_ruling: sustained
```
'@

    # R3b fix (issue #869 PR #880 post-review): PR-1018's own judge-rulings
    # body, clone of the Pr1017Body shape above with the marker's PR number
    # corrected to match the fixture's own Number = 1018 -- the test case
    # below previously reused $script:LandingGapJudgeRulingsPr1017Body
    # (marker pr=1017) for a PR numbered 1018, a genuine PR-number mismatch.
    $script:LandingGapJudgeRulingsPr1018Body = @'
```yaml
<!-- judge-rulings pr=1018 -->
- id: R1
  judge_ruling: sustained
```
'@

#endregion

#region Fixture: review-dispositions marker bodies

    # Case 1: PR 1001's own marker, WITH external_sources_reconciled (GitHub
    # Review Mode signature) -> ExternalReconciledCount, never LandingGap.
    # schema_version: 4 (issue #869 post-review finding H1 -- external_sources_reconciled is v4-only per skills/review-judgment/SKILL.md; a v3 pairing was unrealistic).
    $script:LandingGapMarkerExternalReconciledPr1001Body = @'
<!-- review-dispositions-1001 -->

```yaml
schema_version: 4
passes_run: [1]
entries:
  - stable_finding_key: "a.ps1:1:aaa"
    pass: 1
    disposition: incorporate
    classification: routine
    severity: low
    stage: code-review
    reviewer_source: local
    disposition_rationale: "Reconciled against an external reviewer's finding."
external_sources_reconciled: ["a.ps1:1:aaa"]
```
'@

    # Case 5: PR 1005's own marker, WITHOUT external_sources_reconciled
    # (internal-mode signature) -> InternalOnlyCount, never LandingGap or
    # IntegrityWarning.
    $script:LandingGapMarkerInternalOnlyPr1005Body = @'
<!-- review-dispositions-1005 -->

```yaml
schema_version: 3
passes_run: [1]
entries:
  - stable_finding_key: "e.ps1:1:eee"
    pass: 1
    disposition: incorporate
    classification: routine
    severity: low
    stage: code-review
    reviewer_source: local
    disposition_rationale: "Internal-only pass, no external reconciliation attempted."
```
'@

    # Case 4: PR #843's own marker with NO judge-rulings evidence anywhere
    # (the real, confirmed seed per plan stress-test M19 -- PR #843 carries 2
    # real review-dispositions marker comments and ZERO judge-rulings
    # comments; #722 was the design phase's own miscalibrated seed and is
    # explicitly NOT used here).
    $script:LandingGapMarkerPr843Body = @'
<!-- review-dispositions-843 -->

```yaml
schema_version: 3
passes_run: [1]
entries:
  - stable_finding_key: "f.ps1:1:fff"
    pass: 1
    disposition: incorporate
    classification: routine
    severity: low
    stage: code-review
    reviewer_source: local
    disposition_rationale: "Marker posted without a judge-rulings comment ever landing on this PR (issue #869 real seed)."
```
'@

    # Post-review finding B (issue #869): PR #1015's own REAL marker, but
    # authored by a login that does NOT match -JudgeLogin -- must count as
    # a landing gap (not covered), demonstrating identity mismatch inflates
    # rather than hides.
    $script:LandingGapMarkerWrongAuthorPr1015Body = @'
<!-- review-dispositions-1015 -->

```yaml
schema_version: 4
passes_run: [1]
entries:
  - stable_finding_key: "h.ps1:1:hhh"
    pass: 1
    disposition: incorporate
    classification: routine
    severity: low
    stage: code-review
    reviewer_source: local
    disposition_rationale: "Marker posted, but authored by a non-judge login -- must not count as covered."
```
'@

#endregion

#region Fixture: decoys (cases 6 and 7)

    # Case 6: cross-PR quoted-rulings decoy on supplemental PR 1006. The body
    # carries a REAL, vocab-gate-passing review-dispositions head -- but its
    # own {N} is 2000, NOT 1006, so Test-ReviewDispositionsHeadPresent
    # -ExpectedNumber 1006 must correctly report "no marker for 1006"
    # (mirrors the existing G-CR10 regression in
    # phase-containment-cost-core.Tests.ps1, exercised here at
    # Get-DispositionsLandingGap's own level). The SAME body also embeds a
    # full, real, vocab-gate-passing judge-rulings block for a DIFFERENT PR
    # (#3000) inside disposition_rationale's block-scalar content (mirrors
    # the existing CM4 regression fixture) -- Get-RealJudgeRulingsHeadMatches'
    # block-scalar-span exclusion must keep this from setting
    # hasJudgeRulingsAnywhere for PR 1006. Neither decoy may cause a false
    # positive: PR 1006 must land in the UNREVIEWED split, not the
    # integrity-warning arm and not (implicitly) the landing gap.
    $script:LandingGapCrossPrQuotedDecoyBody = @'
Cross-referencing related work on this thread:

<!-- review-dispositions-2000 -->

```yaml
schema_version: 3
passes_run: [1]
entries:
  - stable_finding_key: "g.ps1:1:ggg"
    pass: 1
    disposition: incorporate
    classification: routine
    severity: low
    stage: code-review
    reviewer_source: local
    disposition_rationale: |
      Also worth noting, PR #3000's judge-rulings verdict for comparison:
      <!-- judge-rulings pr=3000 -->
      judge_ruling: sustained
```
'@

    # Case 7: prose/fenced-quote decoy on supplemental PR 1007. Both marker
    # HEAD literals are present (inside a fenced code block, documenting
    # what the markers will look like once posted) but neither is followed
    # by real field vocabulary within the lookahead window -- the vocab gate
    # must reject both, so PR 1007 lands in the UNREVIEWED split, never the
    # integrity-warning arm.
    $script:LandingGapProseFencedDecoyPr1007Body = @'
We have not posted either marker yet. For reference, here is what they will
look like once posted:

```text
<!-- review-dispositions-1007 -->
<!-- judge-rulings pr=1007 -->
```

No actual entries or judge_ruling data exists on this PR yet.
'@

    # Post-review finding A regression fixture (issue #869, THE core fix):
    # same fenced-decoy shape as case 7 above, reused on PR #1016. Corpus
    # (a)'s own admission regex (`<!--\s*judge-rulings`, no vocab gate) LOOSE-
    # matches the literal text inside the fenced block below, so this PR can
    # be loose-admitted as a Surface='pr' tuple; the STRICT vocab-gated
    # Test-JudgeRulingsRealHeadPresent (already proven to reject this exact
    # shape by case 7 above) correctly fails it. Used to prove a decoy tuple
    # present in BOTH $Tuples and $SupplementalTuples is counted in exactly
    # ONE data path's output, never both, never neither.
    $script:LandingGapLooseAdmitDecoyPr1016Body = @'
We have not posted either marker yet. For reference, here is what they will
look like once posted:

```text
<!-- review-dispositions-1016 -->
<!-- judge-rulings pr=1016 -->
```

No actual entries or judge_ruling data exists on this PR yet.
'@

#endregion
}

Describe 'Get-DispositionsLandingGap - case 1: rulings+marker (no gap)' {
    It 'a PR carrying both judge-rulings evidence and its own review-dispositions marker contributes to ExternalReconciledCount, not LandingGap' {
        $tuple = @{
            Number       = 1001
            Surface      = 'pr'
            Bodies       = @($script:LandingGapJudgeRulingsPr1001Body, $script:LandingGapMarkerExternalReconciledPr1001Body)
            AuthorLogins = @($script:LandingGapJudgeLogin, $script:LandingGapJudgeLogin)
        }

        $result = Get-DispositionsLandingGap `
            -Tuples @($tuple) -Source 'graphql' -Truncated $false `
            -SupplementalTuples @() -SupplementalSource 'graphql' -SupplementalTruncated $false `
            -JudgeLogin $script:LandingGapJudgeLogin

        $result.LandingGap.TotalCount | Should -Be 0
        $result.InternalOnlyCoverage.ExternalReconciledCount | Should -Be 1
        $result.InternalOnlyCoverage.InternalOnlyCount | Should -Be 0
    }
}

Describe 'Get-DispositionsLandingGap - case 2: rulings-only (landing gap)' {
    It 'a PR carrying judge-rulings evidence but no review-dispositions marker increments LandingGap.TotalCount' {
        $tuple = @{
            Number       = 1002
            Surface      = 'pr'
            Bodies       = @($script:LandingGapJudgeRulingsPr1002Body)
            AuthorLogins = @($script:LandingGapJudgeLogin)
        }

        $result = Get-DispositionsLandingGap `
            -Tuples @($tuple) -Source 'graphql' -Truncated $false `
            -SupplementalTuples @() -SupplementalSource 'graphql' -SupplementalTruncated $false `
            -JudgeLogin $script:LandingGapJudgeLogin

        $result.LandingGap.TotalCount | Should -Be 1
        $result.IntegrityWarning.Count | Should -Be 0
    }
}

Describe 'Get-DispositionsLandingGap - case 3: neither (unreviewed, substantive)' {
    It 'a merged PR with no judge-rulings evidence and no review-dispositions marker, diff size > 20, increments UnreviewedSplit.SubstantiveCount' {
        $supplementalTuple = @{
            Number       = 1003
            MergedAt     = '2026-06-01T00:00:00Z'
            Additions    = 15
            Deletions    = 10
            Bodies       = @('Looks good to me, approved.')
            AuthorLogins = @('some-reviewer')
        }

        $result = Get-DispositionsLandingGap `
            -Tuples @() -Source 'graphql' -Truncated $false `
            -SupplementalTuples @($supplementalTuple) -SupplementalSource 'graphql' -SupplementalTruncated $false `
            -JudgeLogin $script:LandingGapJudgeLogin

        $result.UnreviewedSplit.SubstantiveCount | Should -Be 1
        $result.UnreviewedSplit.TrivialCount | Should -Be 0
        $result.IntegrityWarning.Count | Should -Be 0
    }
}

Describe 'Get-DispositionsLandingGap - case 4: marker-without-judge-evidence, SEED ON #843 (verified live)' {
    It 'PR #843 carries a review-dispositions marker with NO judge-rulings evidence anywhere -> IntegrityWarning.Count increments and #843 appears in PrNumbers' {
        # PR #843 was verified live to carry 2 real review-dispositions
        # marker comments and ZERO judge-rulings comments -- the confirmed,
        # owner-approved seed (plan stress-test M19). #722 (no marker at
        # all, the design phase's own miscalibrated seed) is deliberately
        # NOT used.
        $supplementalTuple = @{
            Number       = 843
            MergedAt     = '2026-06-01T00:00:00Z'
            Additions    = 50
            Deletions    = 10
            Bodies       = @($script:LandingGapMarkerPr843Body)
            AuthorLogins = @($script:LandingGapJudgeLogin)
        }

        $result = Get-DispositionsLandingGap `
            -Tuples @() -Source 'graphql' -Truncated $false `
            -SupplementalTuples @($supplementalTuple) -SupplementalSource 'graphql' -SupplementalTruncated $false `
            -JudgeLogin $script:LandingGapJudgeLogin

        $result.IntegrityWarning.Count | Should -Be 1
        $result.IntegrityWarning.PrNumbers | Should -Contain 843
        $result.UnreviewedSplit.TrivialCount | Should -Be 0
        $result.UnreviewedSplit.SubstantiveCount | Should -Be 0
    }
}

Describe 'Get-DispositionsLandingGap - case 5: internal-mode marker (informational, not a gap of any kind)' {
    It 'a PR carrying judge-rulings evidence and an internal-mode marker (no external_sources_reconciled) increments InternalOnlyCount, and never appears in LandingGap or IntegrityWarning' {
        $tuple = @{
            Number       = 1005
            Surface      = 'pr'
            Bodies       = @($script:LandingGapJudgeRulingsPr1005Body, $script:LandingGapMarkerInternalOnlyPr1005Body)
            AuthorLogins = @($script:LandingGapJudgeLogin, $script:LandingGapJudgeLogin)
        }

        $result = Get-DispositionsLandingGap `
            -Tuples @($tuple) -Source 'graphql' -Truncated $false `
            -SupplementalTuples @() -SupplementalSource 'graphql' -SupplementalTruncated $false `
            -JudgeLogin $script:LandingGapJudgeLogin

        $result.InternalOnlyCoverage.InternalOnlyCount | Should -Be 1
        $result.InternalOnlyCoverage.ExternalReconciledCount | Should -Be 0
        $result.LandingGap.TotalCount | Should -Be 0
        $result.IntegrityWarning.Count | Should -Be 0
        $result.IntegrityWarning.PrNumbers | Should -Not -Contain 1005
    }
}

Describe 'Get-DispositionsLandingGap - case 6: cross-PR quoted-rulings decoy (no false positive)' {
    It 'a wrong-PR-numbered review-dispositions head and a block-scalar-embedded judge-rulings head for ANOTHER PR never contaminate this PR''s own classification' {
        $supplementalTuple = @{
            Number       = 1006
            MergedAt     = '2026-06-01T00:00:00Z'
            Additions    = 25
            Deletions    = 10
            Bodies       = @($script:LandingGapCrossPrQuotedDecoyBody)
            AuthorLogins = @($script:LandingGapJudgeLogin)
        }

        $result = Get-DispositionsLandingGap `
            -Tuples @() -Source 'graphql' -Truncated $false `
            -SupplementalTuples @($supplementalTuple) -SupplementalSource 'graphql' -SupplementalTruncated $false `
            -JudgeLogin $script:LandingGapJudgeLogin

        # Neither decoy registers: PR 1006 has no real marker of its own
        # (2000 != 1006) and no real judge-rulings evidence of its own
        # (the #3000 block is block-scalar-embedded content, not a real
        # head) -- it lands in the unreviewed split (35 > 20, substantive).
        $result.IntegrityWarning.Count | Should -Be 0
        $result.IntegrityWarning.PrNumbers | Should -Not -Contain 1006
        $result.UnreviewedSplit.SubstantiveCount | Should -Be 1
        $result.UnreviewedSplit.TrivialCount | Should -Be 0
    }
}

Describe 'Get-DispositionsLandingGap - case 7: prose/fenced-quote decoy (no false positive)' {
    It 'a fenced-code-block mention of both marker head literals, with no real field vocabulary nearby, is not detected as either a real marker or real judge-rulings evidence' {
        $supplementalTuple = @{
            Number       = 1007
            MergedAt     = '2026-06-01T00:00:00Z'
            Additions    = 2
            Deletions    = 1
            Bodies       = @($script:LandingGapProseFencedDecoyPr1007Body)
            AuthorLogins = @('some-reviewer')
        }

        $result = Get-DispositionsLandingGap `
            -Tuples @() -Source 'graphql' -Truncated $false `
            -SupplementalTuples @($supplementalTuple) -SupplementalSource 'graphql' -SupplementalTruncated $false `
            -JudgeLogin $script:LandingGapJudgeLogin

        $result.IntegrityWarning.Count | Should -Be 0
        $result.UnreviewedSplit.TrivialCount | Should -Be 1
        $result.UnreviewedSplit.SubstantiveCount | Should -Be 0
    }
}

Describe 'Format-DispositionsLandingGapSection - case 8: >100-comment pagination (Truncated CAUTION lines)' {
    It 'surfaces the corpus (a) Truncated CAUTION line when Rollup.Truncated is true' {
        $result = Get-DispositionsLandingGap `
            -Tuples @() -Source 'graphql' -Truncated $true `
            -SupplementalTuples @() -SupplementalSource 'graphql' -SupplementalTruncated $false `
            -JudgeLogin $script:LandingGapJudgeLogin
        $reportText = (Format-DispositionsLandingGapSection -Rollup $result -WindowDays 90 -JudgeLogin $script:LandingGapJudgeLogin) -join "`n"

        $reportText.Contains('CAUTION: the review-cost comment corpus fetch (data path a) was Truncated') | Should -BeTrue -Because (
            "corpus (a) Truncated=true must surface a caution line.`nActual report:`n$reportText"
        )
        $reportText.Contains('CAUTION: the supplemental fetch (data path b) was Truncated') | Should -BeFalse -Because (
            "corpus (b) Truncated=false must NOT surface its own caution line.`nActual report:`n$reportText"
        )
    }

    It 'surfaces BOTH Truncated CAUTION lines when both corpus (a) and corpus (b) are Truncated' {
        $result = Get-DispositionsLandingGap `
            -Tuples @() -Source 'graphql' -Truncated $true `
            -SupplementalTuples @() -SupplementalSource 'graphql' -SupplementalTruncated $true `
            -JudgeLogin $script:LandingGapJudgeLogin
        $reportText = (Format-DispositionsLandingGapSection -Rollup $result -WindowDays 90 -JudgeLogin $script:LandingGapJudgeLogin) -join "`n"

        $reportText.Contains('CAUTION: the review-cost comment corpus fetch (data path a) was Truncated') | Should -BeTrue -Because (
            "Actual report:`n$reportText"
        )
        $reportText.Contains('CAUTION: the supplemental fetch (data path b) was Truncated') | Should -BeTrue -Because (
            "Actual report:`n$reportText"
        )
    }

    It 'renders no CAUTION line at all when neither corpus is Truncated' {
        $result = Get-DispositionsLandingGap `
            -Tuples @() -Source 'graphql' -Truncated $false `
            -SupplementalTuples @() -SupplementalSource 'graphql' -SupplementalTruncated $false `
            -JudgeLogin $script:LandingGapJudgeLogin
        $reportText = (Format-DispositionsLandingGapSection -Rollup $result -WindowDays 90 -JudgeLogin $script:LandingGapJudgeLogin) -join "`n"

        $reportText.Contains('CAUTION:') | Should -BeFalse -Because (
            "Actual report:`n$reportText"
        )
    }
}

Describe 'Get-DispositionsLandingGap - case 9: pre/post -FixShipDate floor' {
    BeforeAll {
        # PR 1009: landing gap, merged BEFORE the fix ship date -> pre-ship backlog.
        $script:LandingGapTuple1009 = @{
            Number       = 1009
            Surface      = 'pr'
            Bodies       = @($script:LandingGapJudgeRulingsPr1009Body)
            AuthorLogins = @($script:LandingGapJudgeLogin)
        }
        $script:LandingGapSupplemental1009 = @{
            Number       = 1009
            MergedAt     = '2026-01-15T00:00:00Z'
            Additions    = 5
            Deletions    = 5
            Bodies       = @($script:LandingGapJudgeRulingsPr1009Body)
            AuthorLogins = @($script:LandingGapJudgeLogin)
        }

        # PR 1010: landing gap, merged AFTER the fix ship date -> post-ship (expected 0).
        $script:LandingGapTuple1010 = @{
            Number       = 1010
            Surface      = 'pr'
            Bodies       = @($script:LandingGapJudgeRulingsPr1010Body)
            AuthorLogins = @($script:LandingGapJudgeLogin)
        }
        $script:LandingGapSupplemental1010 = @{
            Number       = 1010
            MergedAt     = '2026-04-15T00:00:00Z'
            Additions    = 5
            Deletions    = 5
            Bodies       = @($script:LandingGapJudgeRulingsPr1010Body)
            AuthorLogins = @($script:LandingGapJudgeLogin)
        }

        # PR 1011: landing gap, but this PR number never appears in
        # SupplementalTuples at all -> MergedAtUnresolvedCount.
        $script:LandingGapTuple1011 = @{
            Number       = 1011
            Surface      = 'pr'
            Bodies       = @('```yaml' + "`n<!-- judge-rulings pr=1011 -->`n- id: R1`n  judge_ruling: sustained`n" + '```')
            AuthorLogins = @($script:LandingGapJudgeLogin)
        }

        $script:LandingGapFixShipDate = [datetime]::Parse('2026-03-01T00:00:00Z', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
    }

    It 'buckets a landing-gap PR merged before -FixShipDate into PreShipBacklogCount' {
        $result = Get-DispositionsLandingGap `
            -Tuples @($script:LandingGapTuple1009) -Source 'graphql' -Truncated $false `
            -SupplementalTuples @($script:LandingGapSupplemental1009) -SupplementalSource 'graphql' -SupplementalTruncated $false `
            -JudgeLogin $script:LandingGapJudgeLogin -FixShipDate $script:LandingGapFixShipDate

        $result.LandingGap.Partitioned | Should -BeTrue
        $result.LandingGap.TotalCount | Should -Be 1
        $result.LandingGap.PreShipBacklogCount | Should -Be 1
        $result.LandingGap.PostShipCount | Should -Be 0
        $result.LandingGap.MergedAtUnresolvedCount | Should -Be 0
    }

    It 'buckets a landing-gap PR merged after -FixShipDate into PostShipCount' {
        $result = Get-DispositionsLandingGap `
            -Tuples @($script:LandingGapTuple1010) -Source 'graphql' -Truncated $false `
            -SupplementalTuples @($script:LandingGapSupplemental1010) -SupplementalSource 'graphql' -SupplementalTruncated $false `
            -JudgeLogin $script:LandingGapJudgeLogin -FixShipDate $script:LandingGapFixShipDate

        $result.LandingGap.Partitioned | Should -BeTrue
        $result.LandingGap.TotalCount | Should -Be 1
        $result.LandingGap.PostShipCount | Should -Be 1
        $result.LandingGap.PreShipBacklogCount | Should -Be 0
        $result.LandingGap.MergedAtUnresolvedCount | Should -Be 0
    }

    It 'counts a landing-gap PR absent from SupplementalTuples entirely as MergedAtUnresolvedCount, excluded from the post/pre split' {
        $result = Get-DispositionsLandingGap `
            -Tuples @($script:LandingGapTuple1011) -Source 'graphql' -Truncated $false `
            -SupplementalTuples @() -SupplementalSource 'graphql' -SupplementalTruncated $false `
            -JudgeLogin $script:LandingGapJudgeLogin -FixShipDate $script:LandingGapFixShipDate

        $result.LandingGap.Partitioned | Should -BeTrue
        $result.LandingGap.TotalCount | Should -Be 1
        $result.LandingGap.MergedAtUnresolvedCount | Should -Be 1
        $result.LandingGap.PostShipCount | Should -Be 0
        $result.LandingGap.PreShipBacklogCount | Should -Be 0
    }

    It 'renders unpartitioned with a floor-not-configured note when -FixShipDate is omitted' {
        $result = Get-DispositionsLandingGap `
            -Tuples @($script:LandingGapTuple1009) -Source 'graphql' -Truncated $false `
            -SupplementalTuples @($script:LandingGapSupplemental1009) -SupplementalSource 'graphql' -SupplementalTruncated $false `
            -JudgeLogin $script:LandingGapJudgeLogin

        $result.LandingGap.Partitioned | Should -BeFalse
        $result.LandingGap.PostShipCount | Should -BeNullOrEmpty
        $result.LandingGap.PreShipBacklogCount | Should -BeNullOrEmpty

        $reportText = (Format-DispositionsLandingGapSection -Rollup $result -WindowDays 90 -JudgeLogin $script:LandingGapJudgeLogin) -join "`n"
        $reportText.Contains('ship-date floor not configured -- pass -FixShipDate to partition into post-ship/pre-ship backlog') | Should -BeTrue -Because (
            "Actual report:`n$reportText"
        )
    }
}

Describe 'Get-DispositionsLandingGap - A: loose-vs-strict judge-rulings mismatch never double-counts (issue #869 post-review finding A)' {
    It 'a decoy that loose-admits to corpus (a) but strict-fails is counted in data path (b) only, never data path (a)' {
        $tuple = @{
            Number       = 1016
            Surface      = 'pr'
            Bodies       = @($script:LandingGapLooseAdmitDecoyPr1016Body)
            AuthorLogins = @('some-reviewer')
        }
        $supplementalTuple = @{
            Number       = 1016
            MergedAt     = '2026-06-01T00:00:00Z'
            Additions    = 2
            Deletions    = 1
            Bodies       = @($script:LandingGapLooseAdmitDecoyPr1016Body)
            AuthorLogins = @('some-reviewer')
        }

        $result = Get-DispositionsLandingGap `
            -Tuples @($tuple) -Source 'graphql' -Truncated $false `
            -SupplementalTuples @($supplementalTuple) -SupplementalSource 'graphql' -SupplementalTruncated $false `
            -JudgeLogin $script:LandingGapJudgeLogin

        # Before the fix: PR 1016 would land in BOTH LandingGap.TotalCount
        # (data path a, no strict recheck) AND UnreviewedSplit (data path
        # b) -- a double count. After the fix: data path (a) strict-rechecks
        # and finds no real judge-rulings evidence, so it skips the tuple
        # entirely; data path (b) is unaffected and correctly buckets it.
        $result.LandingGap.TotalCount | Should -Be 0
        $result.UnreviewedSplit.TrivialCount | Should -Be 1
        $result.UnreviewedSplit.SubstantiveCount | Should -Be 0
        $result.IntegrityWarning.Count | Should -Be 0
    }
}

Describe 'Get-DispositionsLandingGap - B: identity-mismatch inflates, never hides (issue #869 post-review finding B)' {
    It 'a real review-dispositions marker authored by a DIFFERENT login than -JudgeLogin counts as a landing gap, not covered' {
        $tuple = @{
            Number       = 1015
            Surface      = 'pr'
            Bodies       = @($script:LandingGapJudgeRulingsPr1015Body, $script:LandingGapMarkerWrongAuthorPr1015Body)
            AuthorLogins = @($script:LandingGapJudgeLogin, 'not-the-judge')
        }

        $result = Get-DispositionsLandingGap `
            -Tuples @($tuple) -Source 'graphql' -Truncated $false `
            -SupplementalTuples @() -SupplementalSource 'graphql' -SupplementalTruncated $false `
            -JudgeLogin $script:LandingGapJudgeLogin

        $result.LandingGap.TotalCount | Should -Be 1
        $result.InternalOnlyCoverage.InternalOnlyCount | Should -Be 0
        $result.InternalOnlyCoverage.ExternalReconciledCount | Should -Be 0
    }
}

Describe 'Format-DispositionsLandingGapSection - B: identity-mismatch caveat' {
    It 'renders a one-line caveat naming the -JudgeLogin value used to gate marker authorship' {
        $result = Get-DispositionsLandingGap `
            -Tuples @() -Source 'graphql' -Truncated $false `
            -SupplementalTuples @() -SupplementalSource 'graphql' -SupplementalTruncated $false `
            -JudgeLogin $script:LandingGapJudgeLogin
        $reportText = (Format-DispositionsLandingGapSection -Rollup $result -WindowDays 90 -JudgeLogin $script:LandingGapJudgeLogin) -join "`n"

        $reportText.Contains("marker authorship is gated on -JudgeLogin '$($script:LandingGapJudgeLogin)'") | Should -BeTrue -Because (
            "Actual report:`n$reportText"
        )
        $reportText.Contains('#842') | Should -BeTrue
    }
}

Describe 'Get-DispositionsLandingGap - D2: beyond-hunt-cap PRs are surfaced, not silently invisible (issue #869 post-review finding D2)' {
    It 'a supplemental tuple with real judge-rulings evidence but absent from corpus (a) increments BeyondHuntCapCount' {
        $supplementalTuple = @{
            Number       = 1017
            MergedAt     = '2026-06-01T00:00:00Z'
            Additions    = 5
            Deletions    = 5
            Bodies       = @($script:LandingGapJudgeRulingsPr1017Body)
            AuthorLogins = @($script:LandingGapJudgeLogin)
        }

        $result = Get-DispositionsLandingGap `
            -Tuples @() -Source 'graphql' -Truncated $false `
            -SupplementalTuples @($supplementalTuple) -SupplementalSource 'graphql' -SupplementalTruncated $false `
            -JudgeLogin $script:LandingGapJudgeLogin

        $result.BeyondHuntCapCount | Should -Be 1
        $result.BeyondHuntCapPrNumbers | Should -Contain 1017
        $result.LandingGap.TotalCount | Should -Be 0
        $result.UnreviewedSplit.TrivialCount | Should -Be 0
        $result.UnreviewedSplit.SubstantiveCount | Should -Be 0
        $result.IntegrityWarning.Count | Should -Be 0
    }

    It 'does not flag a PR as beyond-hunt-cap when it correctly appears in corpus (a) too' {
        $tuple = @{
            Number       = 1002
            Surface      = 'pr'
            Bodies       = @($script:LandingGapJudgeRulingsPr1002Body)
            AuthorLogins = @($script:LandingGapJudgeLogin)
        }
        $supplementalTuple = @{
            Number       = 1002
            MergedAt     = '2026-06-01T00:00:00Z'
            Additions    = 5
            Deletions    = 5
            Bodies       = @($script:LandingGapJudgeRulingsPr1002Body)
            AuthorLogins = @($script:LandingGapJudgeLogin)
        }

        $result = Get-DispositionsLandingGap `
            -Tuples @($tuple) -Source 'graphql' -Truncated $false `
            -SupplementalTuples @($supplementalTuple) -SupplementalSource 'graphql' -SupplementalTruncated $false `
            -JudgeLogin $script:LandingGapJudgeLogin

        $result.BeyondHuntCapCount | Should -Be 0
        $result.BeyondHuntCapPrNumbers | Should -Not -Contain 1002
    }

    It 'a PR with a decoy-only body in corpus (a) and a REAL judge-rulings body in corpus (b) is caught by beyond-hunt-cap, not silently absent from every bucket (F1 fix, issue #869 post-review)' {
        # DIVERGENT bodies for the SAME PR: corpus (a)'s tuple carries only
        # the decoy (loose-admits under corpus (a)'s raw regex, strict-fails
        # here), while corpus (b)'s supplemental tuple carries a REAL,
        # strict-passing judge-rulings body for the SAME PR number -- this is
        # the exact divergent-bodies case the F1 fix addresses: corpus (a)
        # and corpus (b) are independent fetches (corpus (a)'s marker hunt is
        # capped at 5 pages, corpus (b) is unbounded), so the SAME PR can
        # legitimately carry different comment bodies across the two fetches.
        # Before the F1 fix, the beyond-hunt-cap check compared against RAW
        # corpus-(a) membership -- this PR IS present in $Tuples (decoy-only),
        # so it was wrongly treated as "already covered by (a)" even though
        # (a)'s own strict-recheck gate actually skipped it, and data path
        # (b) also skips it as "already (a)'s domain" -- the PR would
        # silently vanish into NO bucket at all. After the fix, the check
        # compares against the strict-PROCESSED subset instead, so this PR
        # is correctly recognized as never actually processed by (a) and is
        # flagged beyond-hunt-cap. The existing case-A regression test above
        # cannot catch this: it reuses the SAME decoy body in BOTH corpora,
        # so (b)'s hasJudgeRulingsAnywhere check is also false there, landing
        # the PR in the unreviewed split rather than the skipped-for-(a)
        # beyond-hunt-cap candidate list.
        $tuple = @{
            Number       = 1018
            Surface      = 'pr'
            Bodies       = @($script:LandingGapLooseAdmitDecoyPr1016Body)
            AuthorLogins = @('some-reviewer')
        }
        $supplementalTuple = @{
            Number       = 1018
            MergedAt     = '2026-06-01T00:00:00Z'
            Additions    = 5
            Deletions    = 5
            Bodies       = @($script:LandingGapJudgeRulingsPr1018Body)
            AuthorLogins = @($script:LandingGapJudgeLogin)
        }

        $result = Get-DispositionsLandingGap `
            -Tuples @($tuple) -Source 'graphql' -Truncated $false `
            -SupplementalTuples @($supplementalTuple) -SupplementalSource 'graphql' -SupplementalTruncated $false `
            -JudgeLogin $script:LandingGapJudgeLogin

        $result.BeyondHuntCapCount | Should -Be 1
        $result.BeyondHuntCapPrNumbers | Should -Contain 1018
        $result.LandingGap.TotalCount | Should -Be 0
        $result.UnreviewedSplit.TrivialCount | Should -Be 0
        $result.UnreviewedSplit.SubstantiveCount | Should -Be 0
        $result.IntegrityWarning.Count | Should -Be 0
    }
}

Describe 'Format-DispositionsLandingGapSection - D2: beyond-hunt-cap CAUTION line' {
    It 'renders the beyond-hunt-cap caution line with PR numbers when BeyondHuntCapCount > 0' {
        $supplementalTuple = @{
            Number       = 1017
            MergedAt     = '2026-06-01T00:00:00Z'
            Additions    = 5
            Deletions    = 5
            Bodies       = @($script:LandingGapJudgeRulingsPr1017Body)
            AuthorLogins = @($script:LandingGapJudgeLogin)
        }
        $result = Get-DispositionsLandingGap `
            -Tuples @() -Source 'graphql' -Truncated $false `
            -SupplementalTuples @($supplementalTuple) -SupplementalSource 'graphql' -SupplementalTruncated $false `
            -JudgeLogin $script:LandingGapJudgeLogin
        $reportText = (Format-DispositionsLandingGapSection -Rollup $result -WindowDays 90 -JudgeLogin $script:LandingGapJudgeLogin) -join "`n"

        $reportText.Contains("CAUTION: 1 PR(s) had judge-rulings evidence beyond corpus (a)'s hunt-page cap") | Should -BeTrue -Because (
            "Actual report:`n$reportText"
        )
        $reportText.Contains('#1017') | Should -BeTrue
    }
}

Describe 'Get-DispositionsLandingGap - H2: <=20 trivial/substantive diff-size boundary (issue #869 post-review finding H2)' {
    It 'additions+deletions == 20 classifies as TRIVIAL (boundary is inclusive)' {
        $supplementalTuple = @{
            Number       = 1013
            MergedAt     = '2026-06-01T00:00:00Z'
            Additions    = 12
            Deletions    = 8
            Bodies       = @('Looks good to me, approved.')
            AuthorLogins = @('some-reviewer')
        }

        $result = Get-DispositionsLandingGap `
            -Tuples @() -Source 'graphql' -Truncated $false `
            -SupplementalTuples @($supplementalTuple) -SupplementalSource 'graphql' -SupplementalTruncated $false `
            -JudgeLogin $script:LandingGapJudgeLogin

        $result.UnreviewedSplit.TrivialCount | Should -Be 1
        $result.UnreviewedSplit.SubstantiveCount | Should -Be 0
    }

    It 'additions+deletions == 21 classifies as SUBSTANTIVE (one over the boundary)' {
        $supplementalTuple = @{
            Number       = 1014
            MergedAt     = '2026-06-01T00:00:00Z'
            Additions    = 12
            Deletions    = 9
            Bodies       = @('Looks good to me, approved.')
            AuthorLogins = @('some-reviewer')
        }

        $result = Get-DispositionsLandingGap `
            -Tuples @() -Source 'graphql' -Truncated $false `
            -SupplementalTuples @($supplementalTuple) -SupplementalSource 'graphql' -SupplementalTruncated $false `
            -JudgeLogin $script:LandingGapJudgeLogin

        $result.UnreviewedSplit.SubstantiveCount | Should -Be 1
        $result.UnreviewedSplit.TrivialCount | Should -Be 0
    }
}

Describe 'Get-DispositionsLandingGapSupplementalCorpus - D1: GraphQL pagination coverage (issue #869 post-review finding D1)' {
    # Mirrors the established `gh` mock convention in
    # phase-containment-rolling-history-core.Tests.ps1's
    # 'Get-SurfaceBCorpusGraphQL — D2 capped marker hunt' Describe block
    # (function global:gh { param([Parameter(ValueFromRemainingArguments =
    # $true)]$Args) ... }, routed by inspecting the joined argument text,
    # fixtures held in $global: variables, cleaned up in AfterEach) --
    # replicated here rather than re-derived, since this function's own
    # ~240 lines of GraphQL search/pagination logic previously had ZERO
    # real test coverage (every existing test above mocks the whole
    # function via a hand-built SupplementalTuples array instead of
    # driving the fetch itself).

    BeforeAll {
        # A single search-page response: N PR nodes, each with its own
        # inline first comment page (mirrors this function's own outer
        # `search(query: ...) { nodes { ... on PullRequest { ... comments(
        # first: 100) { ... } } } }` shape).
        function script:New-D1SearchPage {
            param(
                [Parameter(Mandatory)][array]$PrNodes,
                [bool]$SearchHasNextPage = $false,
                [string]$SearchEndCursor = $null
            )
            $nodes = foreach ($n in $PrNodes) {
                @{
                    number    = $n.Number
                    mergedAt  = $n.MergedAt
                    additions = $n.Additions
                    deletions = $n.Deletions
                    comments  = @{
                        nodes    = @(@{ author = @{ login = $n.CommentAuthor }; body = $n.CommentBody; createdAt = '2026-01-01T00:00:00Z' })
                        pageInfo = @{ hasNextPage = [bool]$n.CommentHasNext; endCursor = $n.CommentCursor }
                    }
                }
            }
            $payload = @{
                data = @{
                    search = @{
                        pageInfo = @{ hasNextPage = $SearchHasNextPage; endCursor = $SearchEndCursor }
                        nodes    = @($nodes)
                    }
                }
            }
            return ($payload | ConvertTo-Json -Depth 12)
        }

        # A single per-PR comment follow-up page (mirrors this function's
        # own `repository(owner: ...) { pullRequest(number: $prNum) {
        # comments(first: 100, after: "$cursor") { ... } } }` shape).
        function script:New-D1PrCommentPage {
            param([string]$Body, [string]$AuthorLogin = 'some-reviewer', [bool]$HasNextPage = $false, [string]$EndCursor = $null)
            $payload = @{
                data = @{
                    repository = @{
                        pullRequest = @{
                            comments = @{
                                nodes    = @(@{ author = @{ login = $AuthorLogin }; body = $Body; createdAt = '2026-01-02T00:00:00Z' })
                                pageInfo = @{ hasNextPage = $HasNextPage; endCursor = $EndCursor }
                            }
                        }
                    }
                }
            }
            return ($payload | ConvertTo-Json -Depth 12)
        }

        # Routes: a per-PR follow-up call always contains
        # 'pullRequest(number:'; a search-level call never does. Both call
        # shapes may carry an `after: "<cursor>"` clause (the search's own
        # outer cursor vs. the per-PR comments() cursor), so
        # 'pullRequest(number:' presence must be checked FIRST -- mirrors
        # the established Install-D2BGhMock routing order exactly.
        function script:Install-D1GhMock {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)]$Args)
                $joined = $Args -join ' '
                $global:LASTEXITCODE = 0
                if ($joined -match 'pullRequest\(number:\s*(\d+)\)') {
                    $prNum = $Matches[1]
                    if ($joined -match 'after: "([^"]*)"') {
                        $key = "$prNum|$($Matches[1])"
                        if ($global:d1PrPageMap.ContainsKey($key)) { return $global:d1PrPageMap[$key] }
                    }
                    return '{}'
                }
                if ($joined -match 'after: "([^"]*)"') {
                    return $global:d1SearchPageMap[$Matches[1]]
                }
                return $global:d1SearchPage1
            }
        }
    }

    AfterEach {
        if (Get-Command 'gh' -CommandType Function -ErrorAction SilentlyContinue) {
            Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
        }
        Remove-Variable -Name d1SearchPage1, d1SearchPageMap, d1PrPageMap -Scope Global -ErrorAction SilentlyContinue
    }

    It '(1) two-page SEARCH-level pagination: follows the outer search cursor and accumulates both PRs'' fields' {
        $global:d1SearchPage1 = script:New-D1SearchPage `
            -PrNodes @(@{ Number = 2001; MergedAt = '2026-05-01T00:00:00Z'; Additions = 10; Deletions = 5; CommentAuthor = 'reviewer-a'; CommentBody = 'first PR, page 1'; CommentHasNext = $false; CommentCursor = $null }) `
            -SearchHasNextPage $true -SearchEndCursor 'SEARCHCUR1'
        $global:d1SearchPageMap = @{
            'SEARCHCUR1' = (script:New-D1SearchPage `
                    -PrNodes @(@{ Number = 2002; MergedAt = '2026-05-02T00:00:00Z'; Additions = 20; Deletions = 8; CommentAuthor = 'reviewer-b'; CommentBody = 'second PR, page 2'; CommentHasNext = $false; CommentCursor = $null }) `
                    -SearchHasNextPage $false -SearchEndCursor $null)
        }
        $global:d1PrPageMap = @{}
        script:Install-D1GhMock

        $result = Get-DispositionsLandingGapSupplementalCorpus -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 30 -TimeoutSeconds 30 3>$null

        $result.Source    | Should -Be 'graphql'
        $result.Truncated | Should -Be $false
        $result.Tuples    | Should -HaveCount 2

        # MergedAt is compared as a parsed instant, not exact string equality:
        # ConvertFrom-Json -AsHashtable auto-converts an ISO8601-shaped JSON
        # string to a real [datetime], and this function's own
        # ConvertTo-DispositionsLandingGapIsoString round-trips it back via
        # .ToString('o') (e.g. '2026-05-01T00:00:00.0000000Z') -- a
        # differently-formatted but equally-valid ISO8601 UTC representation
        # of the SAME instant as the original literal.
        $pr2001 = $result.Tuples | Where-Object { $_['Number'] -eq 2001 }
        ([datetime]::Parse($pr2001.MergedAt, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)) | Should -Be ([datetime]::Parse('2026-05-01T00:00:00Z', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind))
        $pr2001.Additions    | Should -Be 10
        $pr2001.Deletions    | Should -Be 5
        $pr2001.Bodies       | Should -Contain 'first PR, page 1'
        $pr2001.AuthorLogins | Should -Contain 'reviewer-a'

        $pr2002 = $result.Tuples | Where-Object { $_['Number'] -eq 2002 }
        ([datetime]::Parse($pr2002.MergedAt, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)) | Should -Be ([datetime]::Parse('2026-05-02T00:00:00Z', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind))
        $pr2002.Additions    | Should -Be 20
        $pr2002.Deletions    | Should -Be 8
        $pr2002.Bodies       | Should -Contain 'second PR, page 2'
        $pr2002.AuthorLogins | Should -Contain 'reviewer-b'
    }

    It '(2) two-page PER-PR COMMENT pagination: follows a single PR''s comment cursor and accumulates both comment pages' {
        $global:d1SearchPage1 = script:New-D1SearchPage `
            -PrNodes @(@{ Number = 2003; MergedAt = '2026-05-03T00:00:00Z'; Additions = 30; Deletions = 12; CommentAuthor = 'reviewer-c'; CommentBody = 'PR 2003, comment page 1'; CommentHasNext = $true; CommentCursor = 'PRCUR1' }) `
            -SearchHasNextPage $false -SearchEndCursor $null
        $global:d1SearchPageMap = @{}
        $global:d1PrPageMap = @{
            '2003|PRCUR1' = (script:New-D1PrCommentPage -Body 'PR 2003, comment page 2' -AuthorLogin 'reviewer-d' -HasNextPage $false -EndCursor $null)
        }
        script:Install-D1GhMock

        $result = Get-DispositionsLandingGapSupplementalCorpus -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 30 -TimeoutSeconds 30 3>$null

        $result.Source    | Should -Be 'graphql'
        $result.Truncated | Should -Be $false
        $result.Tuples    | Should -HaveCount 1

        $pr2003 = $result.Tuples[0]
        $pr2003.Number       | Should -Be 2003
        ([datetime]::Parse($pr2003.MergedAt, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)) | Should -Be ([datetime]::Parse('2026-05-03T00:00:00Z', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind))
        $pr2003.Additions    | Should -Be 30
        $pr2003.Deletions    | Should -Be 12
        $pr2003.Bodies       | Should -HaveCount 2
        $pr2003.Bodies       | Should -Contain 'PR 2003, comment page 1'
        $pr2003.Bodies       | Should -Contain 'PR 2003, comment page 2'
        $pr2003.AuthorLogins | Should -Contain 'reviewer-c'
        $pr2003.AuthorLogins | Should -Contain 'reviewer-d'
    }
}
