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

#endregion

#region Fixture: review-dispositions marker bodies

    # Case 1: PR 1001's own marker, WITH external_sources_reconciled (GitHub
    # Review Mode signature) -> ExternalReconciledCount, never LandingGap.
    $script:LandingGapMarkerExternalReconciledPr1001Body = @'
<!-- review-dispositions-1001 -->

```yaml
schema_version: 3
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
        $reportText = (Format-DispositionsLandingGapSection -Rollup $result -WindowDays 90) -join "`n"

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
        $reportText = (Format-DispositionsLandingGapSection -Rollup $result -WindowDays 90) -join "`n"

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
        $reportText = (Format-DispositionsLandingGapSection -Rollup $result -WindowDays 90) -join "`n"

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

        $reportText = (Format-DispositionsLandingGapSection -Rollup $result -WindowDays 90) -join "`n"
        $reportText.Contains('ship-date floor not configured -- pass -FixShipDate to partition into post-ship/pre-ship backlog') | Should -BeTrue -Because (
            "Actual report:`n$reportText"
        )
    }
}
