#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester tests for phase-containment-cost-core.ps1 (issue #768 s4, TDD red-green).
#
# File under test: .github/scripts/lib/phase-containment-cost-core.ps1
#
# Fixtures below are synthetic but modeled byte-for-shape on the real writer
# templates (skills/review-judgment/SKILL.md) and the live judge-rulings
# fixtures already pinned in phase-containment-emission-check-core.Tests.ps1
# (PRs #775/#778/#781), so Get-DispositionTally parses them exactly as it
# would parse the real thing.

BeforeAll {
    $script:LibRoot = Join-Path $PSScriptRoot '..' 'lib'
    . (Join-Path $script:LibRoot 'phase-containment-cost-core.ps1')

#region Fixture: review-dispositions v3 — PR 100, mixed dispositions + sources

    # 4 entries: 2 incorporate/local (1 untagged -> defaults to local), 1
    # dismiss/gemini-code-assist, 1 defer/local. Exercises defer-in-denominator
    # (not noise numerator) and per-source joint grouping in one fixture.
    $script:CostReviewDispositionsPr100Body = @'
<!-- review-dispositions-100 -->

```yaml
schema_version: 3
passes_run: [1, 2]
entries:
  - stable_finding_key: "src/foo.ts:10:issue-a1b2c3d4"
    pass: 1
    disposition: incorporate
    classification: routine
    severity: low
    stage: code-review
    reviewer_source: local
    disposition_rationale: "Fixed inline."
  - stable_finding_key: "src/bar.ts:20:issue-e5f6a7b8"
    pass: 1
    disposition: incorporate
    classification: routine
    severity: low
    stage: code-review
    disposition_rationale: "Fixed inline (untagged reviewer_source, v1/v2 entry)."
  - stable_finding_key: "gh-555111"
    pass: 2
    disposition: dismiss
    classification: routine
    severity: low
    stage: code-review
    reviewer_source: gemini-code-assist
    disposition_rationale: "Not applicable."
  - stable_finding_key: "src/baz.ts:30:issue-c9d0e1f2"
    pass: 2
    disposition: defer
    classification: load-bearing
    severity: medium
    stage: code-review
    reviewer_source: local
    disposition_rationale: "Partial AC match, cannot dismiss."
```
'@

#endregion

#region Fixture: review-dispositions v3 — PR 100, round 2 (re-review; disjoint keys, dedup test)

    # A later re-review comment on the SAME PR with a disjoint stable_finding_key
    # set (round-2 findings) plus one OVERLAPPING key from round 1
    # ("gh-555111") whose disposition changed from dismiss -> incorporate.
    # Latest-wins dedup must resolve "gh-555111" to incorporate (round 2),
    # not dismiss (round 1).
    $script:CostReviewDispositionsPr100RoundTwoBody = @'
<!-- review-dispositions-100 -->

```yaml
schema_version: 3
passes_run: [1]
entries:
  - stable_finding_key: "gh-555111"
    pass: 1
    disposition: incorporate
    classification: routine
    severity: low
    stage: code-review
    reviewer_source: gemini-code-assist
    disposition_rationale: "Re-reviewed and fixed after round 1."
```
'@

#endregion

#region Fixture: canonical judge-rulings (PR-surface) — round 1 and round 2 (dedup test)

    $script:CostJudgeRulingsPr200RoundOneBody = @'
```yaml
<!-- judge-rulings pr=200 -->
- id: R1
  judge_ruling: sustained
- id: R2
  judge_ruling: sustained
- id: R3
  judge_ruling: defense-sustained
```
'@

    # Round 2 (later re-review round on the same PR): a DIFFERENT count shape
    # (5 sustained, 0 defense-sustained). Dedup must select ONLY this round's
    # counts, never sum with round 1's (2, 1).
    $script:CostJudgeRulingsPr200RoundTwoBody = @'
```yaml
<!-- judge-rulings pr=200 -->
- id: R4
  judge_ruling: sustained
- id: R5
  judge_ruling: sustained
- id: R6
  judge_ruling: sustained
- id: R7
  judge_ruling: sustained
- id: R8
  judge_ruling: sustained
```
'@

#endregion

#region Fixture: canonical judge-rulings (issue-surface) — plan-stress-test routing

    $script:CostJudgeRulingsIssue300Body = @'
```yaml
<!-- judge-rulings pr=300 -->
- id: M1
  judge_ruling: sustained
- id: M2
  judge_ruling: sustained
- id: M3
  judge_ruling: defense-sustained
```
'@

#endregion

#region Fixture: intake-vocabulary (accept|reject) judge-rulings PR body — M7 could-not-verify

    $script:CostIntakeJudgeRulingsPr500Body = @'
<!-- judge-rulings
pr: 500
verdict: mixed
total_score: 3
review_mode: github-intake-proxy-prosecution
findings:
  - id: GF-1
    disposition: accept
    severity: low
    score: 1
  - id: GF-2
    disposition: reject
    severity: low
    score: 0
required_fixes:
  - id: GF-1
    file: some/file.ps1
    change: "Fix applied."
-->
'@

#endregion

#region Fixture: finding_dispositions (design-challenge) — issue 400, dual-marker test

    $script:CostFindingDispositionsIssue400Body = @'
<!-- design-phase-complete-400 -->

Phase summary: 5 finding(s) classified, 0 dismissed.

```yaml
finding_dispositions:
  schema_version: 1
  passes_run: [1]
  entries:
    - finding_id: F1
      pass: 1
      disposition: incorporate
      classification: routine
      disposition_rationale: "Kept."
    - finding_id: F2
      pass: 1
      disposition: incorporate
      classification: routine
      disposition_rationale: "Kept."
    - finding_id: F3
      pass: 1
      disposition: incorporate
      classification: routine
      disposition_rationale: "Kept."
    - finding_id: F4
      pass: 1
      disposition: escalate
      classification: load-bearing
      disposition_rationale: "Escalated."
    - finding_id: F5
      pass: 1
      disposition: dismiss
      classification: routine
      disposition_rationale: "Not applicable."
```
'@

    # Same issue's judge-rulings comment (plan surface) — a SEPARATE comment
    # body within the SAME issue tuple's Bodies[] array.
    $script:CostJudgeRulingsIssue400Body = @'
```yaml
<!-- judge-rulings pr=400 -->
- id: P1
  judge_ruling: sustained
- id: P2
  judge_ruling: defense-sustained
```
'@

#endregion

#region Fixture: thin design-challenge (n<5 gate) vs a well-populated one

    $script:CostThinFindingDispositionsIssue600Body = @'
```yaml
finding_dispositions:
  schema_version: 1
  passes_run: [1]
  entries:
    - finding_id: F1
      pass: 1
      disposition: incorporate
      classification: routine
      disposition_rationale: "Kept."
    - finding_id: F2
      pass: 1
      disposition: dismiss
      classification: routine
      disposition_rationale: "Not applicable."
```
'@

    $script:CostWellPopulatedFindingDispositionsIssue700Body = @'
```yaml
finding_dispositions:
  schema_version: 1
  passes_run: [1]
  entries:
    - finding_id: F1
      pass: 1
      disposition: incorporate
      classification: routine
      disposition_rationale: "Kept."
    - finding_id: F2
      pass: 1
      disposition: incorporate
      classification: routine
      disposition_rationale: "Kept."
    - finding_id: F3
      pass: 1
      disposition: incorporate
      classification: routine
      disposition_rationale: "Kept."
    - finding_id: F4
      pass: 1
      disposition: dismiss
      classification: routine
      disposition_rationale: "Not applicable."
    - finding_id: F5
      pass: 1
      disposition: dismiss
      classification: routine
      disposition_rationale: "Not applicable."
```
'@

#endregion

#region Fixture: CM3 regression — canonical judge-rulings block plus a stray
# `disposition: reject` line elsewhere in the SAME body (judge-sustained
# PR #833 review). Test-JudgeRulingsHasDefenseSustainedConcept must classify
# vocabulary off the ISOLATED judge-rulings region, not the raw body, or the
# stray intake-vocabulary line elsewhere shunts this canonical block to
# could-not-verify.

    $script:CostCanonicalJudgeRulingsWithStrayDispositionRejectBody = @'
Some earlier unrelated comment on this PR quoted a past decision inline:
disposition: reject

```yaml
<!-- judge-rulings pr=960 -->
- id: R1
  judge_ruling: sustained
- id: R2
  judge_ruling: sustained
- id: R3
  judge_ruling: defense-sustained
```
'@

#endregion

#region Fixture: CM4 regression — judge-rulings head embedded inside another
# marker's disposition_rationale block-scalar content (judge-sustained
# PR #833 review). Must not be treated as a real, separate judge-rulings
# head and must not fabricate a defense-kill contribution from string
# content.

    $script:CostBlockScalarEmbeddedJudgeRulingsDecoyBody = @'
<!-- review-dispositions-950 -->

```yaml
schema_version: 3
passes_run: [1]
entries:
  - stable_finding_key: "h.ps1:1:hhh"
    pass: 1
    disposition: incorporate
    classification: routine
    severity: medium
    stage: code-review
    reviewer_source: local
    disposition_rationale: |
      Earlier discussion referenced another PR's marker for context:
      <!-- judge-rulings pr=950 -->
      judge_ruling: sustained
```
'@

#endregion
}

Describe 'Get-ReviewCostRollup - (Surface, head) routing (M1 regression)' {
    It 'routes a Surface=pr judge-rulings body to code-review defense-kill, NOT plan-stress-test' {
        $tuple = @{ Number = 200; Surface = 'pr'; Bodies = @($script:CostJudgeRulingsPr200RoundOneBody); CreatedAtValues = @('2026-01-01T00:00:00Z') }
        $result = Get-ReviewCostRollup -Tuples @($tuple) -Source 'graphql' -Truncated $false -ValuePresentPrNumbers @(200)

        $result.CodeReview.DefenseKillRate.N | Should -Be 3
        $result.CodeReview.DefenseKillRate.Numerator | Should -Be 1
        $result.PlanStressTest.DefenseKillRate.N | Should -Be 0
        $result.PlanStressTest.DefenseKillRate.Numerator | Should -Be 0
    }

    It 'routes a Surface=issue judge-rulings body to plan-stress-test defense-kill, NOT code-review' {
        $tuple = @{ Number = 300; Surface = 'issue'; Bodies = @($script:CostJudgeRulingsIssue300Body); CreatedAtValues = @('2026-01-01T00:00:00Z') }
        $result = Get-ReviewCostRollup -Tuples @($tuple) -Source 'graphql' -Truncated $false -ValuePresentPrNumbers @()

        $result.PlanStressTest.DefenseKillRate.N | Should -Be 3
        $result.PlanStressTest.DefenseKillRate.Numerator | Should -Be 1
        $result.CodeReview.DefenseKillRate.N | Should -Be 0
    }
}

Describe 'Get-ReviewCostRollup - code-review post-judge dismiss-rate + defer semantics' {
    It 'counts defer in the denominator but not the dismissed noise numerator, and reports it as a separate column' {
        $tuple = @{ Number = 100; Surface = 'pr'; Bodies = @($script:CostReviewDispositionsPr100Body); CreatedAtValues = @('2026-01-01T00:00:00Z') }
        $result = Get-ReviewCostRollup -Tuples @($tuple) -Source 'graphql' -Truncated $false -ValuePresentPrNumbers @(100)

        # 4 entries total: 2 incorporate, 1 dismiss, 1 defer.
        $result.CodeReview.PostJudgeDismissRate.N | Should -Be 4
        $result.CodeReview.PostJudgeDismissRate.Numerator | Should -Be 1
        $result.CodeReview.DeferCount | Should -Be 1
    }
}

Describe 'Get-ReviewCostRollup - per-reviewer-source joint grouping' {
    It 'groups code-review dismiss-rate by reviewer_source, defaulting untagged entries to local' {
        $tuple = @{ Number = 100; Surface = 'pr'; Bodies = @($script:CostReviewDispositionsPr100Body); CreatedAtValues = @('2026-01-01T00:00:00Z') }
        $result = Get-ReviewCostRollup -Tuples @($tuple) -Source 'graphql' -Truncated $false -ValuePresentPrNumbers @(100)

        # local: 1 tagged (incorporate) + 1 untagged->local (incorporate) + 1
        # tagged local (defer) = 3 entries, 0 dismissed.
        $result.CodeReview.PerSource['local'].N | Should -Be 3
        $result.CodeReview.PerSource['local'].Numerator | Should -Be 0

        # gemini-code-assist: 1 entry, dismissed.
        $result.CodeReview.PerSource['gemini-code-assist'].N | Should -Be 1
        $result.CodeReview.PerSource['gemini-code-assist'].Numerator | Should -Be 1
    }
}

Describe 'Get-ReviewCostRollup - per-sub-section INSUFFICIENT DATA (n<5) gate' {
    It 'flags InsufficientData when the sub-section dispositioned-finding count is below 5' {
        $tuple = @{ Number = 600; Surface = 'issue'; Bodies = @($script:CostThinFindingDispositionsIssue600Body); CreatedAtValues = @('2026-01-01T00:00:00Z') }
        $result = Get-ReviewCostRollup -Tuples @($tuple) -Source 'graphql' -Truncated $false -ValuePresentPrNumbers @()

        $result.DesignChallenge.DismissRate.N | Should -Be 2
        $result.DesignChallenge.DismissRate.InsufficientData | Should -BeTrue
    }

    It 'does NOT flag InsufficientData once the sub-section dispositioned-finding count reaches 5' {
        $tuple = @{ Number = 700; Surface = 'issue'; Bodies = @($script:CostWellPopulatedFindingDispositionsIssue700Body); CreatedAtValues = @('2026-01-01T00:00:00Z') }
        $result = Get-ReviewCostRollup -Tuples @($tuple) -Source 'graphql' -Truncated $false -ValuePresentPrNumbers @()

        $result.DesignChallenge.DismissRate.N | Should -Be 5
        $result.DesignChallenge.DismissRate.Numerator | Should -Be 2
        $result.DesignChallenge.DismissRate.InsufficientData | Should -BeFalse
    }
}

Describe 'Get-ReviewCostRollup - Truncated flag propagation' {
    It 'passes the corpus Truncated flag through to the rollup unchanged' {
        $tuple = @{ Number = 100; Surface = 'pr'; Bodies = @($script:CostReviewDispositionsPr100Body); CreatedAtValues = @('2026-01-01T00:00:00Z') }

        $resultTruncated = Get-ReviewCostRollup -Tuples @($tuple) -Source 'graphql' -Truncated $true -ValuePresentPrNumbers @(100)
        $resultTruncated.Truncated | Should -BeTrue

        $resultNotTruncated = Get-ReviewCostRollup -Tuples @($tuple) -Source 'graphql' -Truncated $false -ValuePresentPrNumbers @(100)
        $resultNotTruncated.Truncated | Should -BeFalse
    }
}

Describe 'Get-ReviewCostRollup - fetch-state (COST DATA UNAVAILABLE distinct from INSUFFICIENT DATA)' {
    It 'reports FetchState unavailable for Source=timeout, distinct from a thin-data (n<5) result' {
        $result = Get-ReviewCostRollup -Tuples @() -Source 'timeout' -Truncated $false -ValuePresentPrNumbers @(1, 2, 3)

        $result.FetchState | Should -Be 'unavailable'
        $result.FetchSource | Should -Be 'timeout'
        # Every value-present PR is a forward gap when there is no cost data at all.
        $result.ForwardGapCount | Should -Be 3
    }

    It 'reports FetchState unavailable for Source=repo-resolution-failed' {
        $result = Get-ReviewCostRollup -Tuples @() -Source 'repo-resolution-failed' -Truncated $false -ValuePresentPrNumbers @()

        $result.FetchState | Should -Be 'unavailable'
        $result.FetchSource | Should -Be 'repo-resolution-failed'
    }

    It 'reports FetchState ok for a normal fetch even when a sub-section is thin (n<5)' {
        $tuple = @{ Number = 600; Surface = 'issue'; Bodies = @($script:CostThinFindingDispositionsIssue600Body); CreatedAtValues = @('2026-01-01T00:00:00Z') }
        $result = Get-ReviewCostRollup -Tuples @($tuple) -Source 'graphql' -Truncated $false -ValuePresentPrNumbers @()

        $result.FetchState | Should -Be 'ok'
        $result.DesignChallenge.DismissRate.InsufficientData | Should -BeTrue
    }
}

Describe 'Get-ReviewCostRollup - duplicate re-review markers dedup (latest generation, not summed)' {
    It 'dedups review-dispositions entries latest-wins per stable_finding_key across re-review rounds' {
        $tuple = @{
            Number          = 100
            Surface         = 'pr'
            Bodies          = @($script:CostReviewDispositionsPr100Body, $script:CostReviewDispositionsPr100RoundTwoBody)
            CreatedAtValues = @('2026-01-01T00:00:00Z', '2026-02-01T00:00:00Z')
        }
        $result = Get-ReviewCostRollup -Tuples @($tuple) -Source 'graphql' -Truncated $false -ValuePresentPrNumbers @(100)

        # Round 1 has 4 entries; round 2 re-dispositions "gh-555111" from
        # dismiss -> incorporate. Deduped total is still 4 entries (not 5),
        # and the dismissed numerator drops from 1 to 0 (round 2 wins).
        $result.CodeReview.PostJudgeDismissRate.N | Should -Be 4
        $result.CodeReview.PostJudgeDismissRate.Numerator | Should -Be 0
    }

    It 'dedups judge-rulings bodies to the latest generation per PR, never summing counts across rounds' {
        $tuple = @{
            Number          = 200
            Surface         = 'pr'
            Bodies          = @($script:CostJudgeRulingsPr200RoundOneBody, $script:CostJudgeRulingsPr200RoundTwoBody)
            CreatedAtValues = @('2026-01-01T00:00:00Z', '2026-02-01T00:00:00Z')
        }
        $result = Get-ReviewCostRollup -Tuples @($tuple) -Source 'graphql' -Truncated $false -ValuePresentPrNumbers @(200)

        # Round 2 alone: 5 sustained, 0 defense-sustained -> N=5. Summed
        # (wrong) would be (2+1)+(5+0)=8.
        $result.CodeReview.DefenseKillRate.N | Should -Be 5
        $result.CodeReview.DefenseKillRate.Numerator | Should -Be 0
    }
}

Describe 'Get-ReviewCostRollup - dual-marker issue body (both routed correctly)' {
    It 'routes an issue carrying both a finding_dispositions comment and a judge-rulings comment to both stages' {
        $tuple = @{
            Number          = 400
            Surface         = 'issue'
            Bodies          = @($script:CostFindingDispositionsIssue400Body, $script:CostJudgeRulingsIssue400Body)
            CreatedAtValues = @('2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z')
        }
        $result = Get-ReviewCostRollup -Tuples @($tuple) -Source 'graphql' -Truncated $false -ValuePresentPrNumbers @()

        # finding_dispositions: 4 incorporate/escalate (sustained) + 1 dismiss -> N=5.
        $result.DesignChallenge.DismissRate.N | Should -Be 5
        $result.DesignChallenge.DismissRate.Numerator | Should -Be 1

        # judge-rulings: 1 sustained, 1 defense-sustained -> N=2.
        $result.PlanStressTest.DefenseKillRate.N | Should -Be 2
        $result.PlanStressTest.DefenseKillRate.Numerator | Should -Be 1
    }
}

Describe 'Get-ReviewCostRollup - CM3 regression: defense-sustained-concept check must scan the isolated region, not the raw body (judge-sustained, PR #833 review)' {
    It 'does not shunt a canonical judge-rulings block to could-not-verify due to a stray disposition: reject line elsewhere in the same body' {
        $tuple = @{ Number = 960; Surface = 'pr'; Bodies = @($script:CostCanonicalJudgeRulingsWithStrayDispositionRejectBody); CreatedAtValues = @('2026-01-01T00:00:00Z') }
        $result = Get-ReviewCostRollup -Tuples @($tuple) -Source 'graphql' -Truncated $false -ValuePresentPrNumbers @(960)

        $result.CodeReview.DefenseKillRate.N | Should -Be 3
        $result.CodeReview.DefenseKillRate.Numerator | Should -Be 1
        $result.CodeReview.DefenseKillRate.CouldNotVerifyCount | Should -Be 0
    }
}

Describe 'Get-ReviewCostRollup - CM4 regression: block-scalar-embedded judge-rulings head must not be treated as real (judge-sustained, PR #833 review)' {
    It 'does not fabricate a defense-kill contribution from a judge-rulings head embedded inside another marker''s block-scalar content' {
        $tuple = @{ Number = 950; Surface = 'pr'; Bodies = @($script:CostBlockScalarEmbeddedJudgeRulingsDecoyBody); CreatedAtValues = @('2026-01-01T00:00:00Z') }
        $result = Get-ReviewCostRollup -Tuples @($tuple) -Source 'graphql' -Truncated $false -ValuePresentPrNumbers @(950)

        $result.CodeReview.DefenseKillRate.N | Should -Be 0
        $result.CodeReview.DefenseKillRate.Numerator | Should -Be 0
    }
}

Describe 'Get-ReviewCostRollup - non-canonical judge-rulings vocabulary (M7 could-not-verify)' {
    It 'reports the intake accept|reject vocabulary as could-not-verify for defense-kill, never a silent zero' {
        $tuple = @{ Number = 500; Surface = 'pr'; Bodies = @($script:CostIntakeJudgeRulingsPr500Body); CreatedAtValues = @('2026-01-01T00:00:00Z') }
        $result = Get-ReviewCostRollup -Tuples @($tuple) -Source 'graphql' -Truncated $false -ValuePresentPrNumbers @(500)

        # The non-canonical vocabulary contributes nothing countable to N/Numerator...
        $result.CodeReview.DefenseKillRate.N | Should -Be 0
        $result.CodeReview.DefenseKillRate.Numerator | Should -Be 0
        # ...but IS surfaced, never silently dropped.
        $result.CodeReview.DefenseKillRate.CouldNotVerifyCount | Should -Be 1
    }
}

Describe 'Get-ReviewCostRollup - forward gap (value-present PRs with no cost marker)' {
    It 'counts value-present PRs that carry no cost-surface marker at all as the forward gap' {
        $tuplePr100 = @{ Number = 100; Surface = 'pr'; Bodies = @($script:CostReviewDispositionsPr100Body); CreatedAtValues = @('2026-01-01T00:00:00Z') }
        $tuplePr200 = @{ Number = 200; Surface = 'pr'; Bodies = @($script:CostJudgeRulingsPr200RoundOneBody); CreatedAtValues = @('2026-01-01T00:00:00Z') }

        # PR 300 has value data but is never mentioned in Tuples at all.
        $result = Get-ReviewCostRollup -Tuples @($tuplePr100, $tuplePr200) -Source 'graphql' -Truncated $false -ValuePresentPrNumbers @(100, 200, 300)

        $result.ForwardGapCount | Should -Be 1
    }

    It 'reports zero forward gap when every value-present PR has a cost marker' {
        $tuplePr100 = @{ Number = 100; Surface = 'pr'; Bodies = @($script:CostReviewDispositionsPr100Body); CreatedAtValues = @('2026-01-01T00:00:00Z') }
        $result = Get-ReviewCostRollup -Tuples @($tuplePr100) -Source 'graphql' -Truncated $false -ValuePresentPrNumbers @(100)

        $result.ForwardGapCount | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
# Format-ReviewCostSection (issue #768 s5, TDD red-green)
# ---------------------------------------------------------------------------

Describe 'Format-ReviewCostSection - distinct noise-column labeling (no-merge invariant, M17 scope)' {
    BeforeAll {
        # A second review-dispositions PR (150) so the code-review post-judge
        # dismiss-rate aggregate crosses n>=5 (2 entries here + PR100's 4 = 6
        # total, 2 dismissed) and renders a real number instead of
        # INSUFFICIENT DATA, so this test can assert the two noise labels
        # never share a value.
        $script:CostReviewDispositionsPr150Body = @'
<!-- review-dispositions-150 -->

```yaml
schema_version: 3
passes_run: [1]
entries:
  - stable_finding_key: "src/qux.ts:5:issue-aaaa1111"
    pass: 1
    disposition: incorporate
    classification: routine
    severity: low
    stage: code-review
    reviewer_source: local
    disposition_rationale: "Fixed."
  - stable_finding_key: "src/quux.ts:15:issue-bbbb2222"
    pass: 1
    disposition: dismiss
    classification: routine
    severity: low
    stage: code-review
    reviewer_source: local
    disposition_rationale: "Not applicable."
```
'@

        # PR 100 + PR 150 supply code-review post-judge dismiss-rate data
        # (N=6, Numerator=2). PR 200's round-two body supplies code-review
        # defense-kill data (N=5, Numerator=0) via a judge-rulings body.
        # Combining both on the code-review stage's block lets this test
        # assert the two rates render under DIFFERENT labels with DIFFERENT
        # values, never sharing a column.
        $tuplePr100 = @{ Number = 100; Surface = 'pr'; Bodies = @($script:CostReviewDispositionsPr100Body); CreatedAtValues = @('2026-01-01T00:00:00Z') }
        $tuplePr150 = @{ Number = 150; Surface = 'pr'; Bodies = @($script:CostReviewDispositionsPr150Body); CreatedAtValues = @('2026-01-01T00:00:00Z') }
        $tuplePr200 = @{ Number = 200; Surface = 'pr'; Bodies = @($script:CostJudgeRulingsPr200RoundTwoBody); CreatedAtValues = @('2026-01-01T00:00:00Z') }
        $script:LabelRollup = Get-ReviewCostRollup -Tuples @($tuplePr100, $tuplePr150, $tuplePr200) -Source 'graphql' -Truncated $false -ValuePresentPrNumbers @(100, 150, 200)
        $script:LabelReportText = (Format-ReviewCostSection -Rollup $script:LabelRollup) -join "`n"
    }

    It 'renders the defense-kill rate and post-judge dismiss-rate as two distinctly labeled lines with different values' {
        $script:LabelReportText.Contains('Defense-kill rate: 0.00 (0 of 5)') | Should -BeTrue -Because (
            "code-review defense-kill rate is 0 defense-sustained of 5 dispositioned judge-rulings entries (PR 200 round two).`nActual report:`n$script:LabelReportText"
        )
        $script:LabelReportText.Contains('Post-judge dismiss-rate: 0.33 (2 of 6)') | Should -BeTrue -Because (
            "code-review post-judge dismiss-rate is 2 dismissed of 6 dispositioned review-dispositions entries (PR 100 + PR 150).`nActual report:`n$script:LabelReportText"
        )
    }

    It 'never merges the two noise labels under a shared column' {
        $script:LabelReportText.Contains('Defense-kill rate: 0.33 (2 of 6)') | Should -BeFalse -Because (
            "the post-judge dismiss-rate's value must never leak onto the defense-kill rate's label.`nActual report:`n$script:LabelReportText"
        )
        $script:LabelReportText.Contains('Post-judge dismiss-rate: 0.00 (0 of 5)') | Should -BeFalse -Because (
            "the defense-kill rate's value must never leak onto the post-judge dismiss-rate's label.`nActual report:`n$script:LabelReportText"
        )
    }
}

Describe 'Format-ReviewCostSection - INSUFFICIENT DATA rendering' {
    It 'renders INSUFFICIENT DATA for a thin (n<5) design-challenge dismiss-rate' {
        $tuple = @{ Number = 600; Surface = 'issue'; Bodies = @($script:CostThinFindingDispositionsIssue600Body); CreatedAtValues = @('2026-01-01T00:00:00Z') }
        $rollup = Get-ReviewCostRollup -Tuples @($tuple) -Source 'graphql' -Truncated $false -ValuePresentPrNumbers @()
        $reportText = (Format-ReviewCostSection -Rollup $rollup) -join "`n"

        $reportText.Contains('Dismiss-rate (over dispositioned findings): INSUFFICIENT DATA (n=2 < 5)') | Should -BeTrue -Because (
            "the design-challenge fixture has only 2 dispositioned findings.`nActual report:`n$reportText"
        )
    }
}

Describe 'Format-ReviewCostSection - COST DATA UNAVAILABLE rendering (distinct from INSUFFICIENT DATA)' {
    It 'renders COST DATA UNAVAILABLE (fetch {source}) and never INSUFFICIENT DATA when the corpus fetch failed' {
        $rollup = Get-ReviewCostRollup -Tuples @() -Source 'timeout' -Truncated $false -ValuePresentPrNumbers @(1, 2, 3)
        $reportText = (Format-ReviewCostSection -Rollup $rollup) -join "`n"

        $reportText.Contains('COST DATA UNAVAILABLE (fetch timeout)') | Should -BeTrue -Because (
            "Source='timeout' must render the fetch-failure state.`nActual report:`n$reportText"
        )
        $reportText.Contains('INSUFFICIENT DATA') | Should -BeFalse -Because (
            "a fetch failure must never be rendered as (or confused with) a thin-data n<5 result.`nActual report:`n$reportText"
        )
    }
}

Describe 'Format-ReviewCostSection - forward-gap line' {
    It 'renders the exact forward-gap line with the rollup ForwardGapCount when the fetch succeeded' {
        $tuple = @{ Number = 100; Surface = 'pr'; Bodies = @($script:CostReviewDispositionsPr100Body); CreatedAtValues = @('2026-01-01T00:00:00Z') }
        $rollup = Get-ReviewCostRollup -Tuples @($tuple) -Source 'graphql' -Truncated $false -ValuePresentPrNumbers @(100, 999)
        $reportText = (Format-ReviewCostSection -Rollup $rollup) -join "`n"

        $reportText.Contains('PRs with value data but no cost marker: 1') | Should -BeTrue -Because (
            "PR 999 has value data but no cost marker present in this corpus.`nActual report:`n$reportText"
        )
    }

    It 'renders a zero forward-gap line when every value-present PR has a cost marker' {
        $tuple = @{ Number = 100; Surface = 'pr'; Bodies = @($script:CostReviewDispositionsPr100Body); CreatedAtValues = @('2026-01-01T00:00:00Z') }
        $rollup = Get-ReviewCostRollup -Tuples @($tuple) -Source 'graphql' -Truncated $false -ValuePresentPrNumbers @(100)
        $reportText = (Format-ReviewCostSection -Rollup $rollup) -join "`n"

        $reportText.Contains('PRs with value data but no cost marker: 0') | Should -BeTrue -Because (
            "Actual report:`n$reportText"
        )
    }

    It 'renders COST DATA UNAVAILABLE for the forward-gap line, never a confident numeric count, when the corpus fetch failed (CM5 regression, judge-sustained PR #833 review)' {
        $rollup = Get-ReviewCostRollup -Tuples @() -Source 'timeout' -Truncated $false -ValuePresentPrNumbers @(1, 2, 3)
        $reportText = (Format-ReviewCostSection -Rollup $rollup) -join "`n"

        $reportText.Contains('PRs with value data but no cost marker: COST DATA UNAVAILABLE (fetch timeout)') | Should -BeTrue -Because (
            "the forward-gap line must render the same honest fetch-failure state as the rate lines, never a confident count derived from an unfetched population.`nActual report:`n$reportText"
        )
        $reportText.Contains('PRs with value data but no cost marker: 3') | Should -BeFalse -Because (
            "a fetch failure (Source=timeout) must never render a confident-looking numeric forward-gap count.`nActual report:`n$reportText"
        )
    }
}

Describe 'Format-ReviewCostSection - Truncated flag caveat rendering (CM6 regression, judge-sustained PR #833 review)' {
    It 'renders an explicit truncation caveat when Rollup.Truncated is true' {
        $tuple = @{ Number = 100; Surface = 'pr'; Bodies = @($script:CostReviewDispositionsPr100Body); CreatedAtValues = @('2026-01-01T00:00:00Z') }
        $rollup = Get-ReviewCostRollup -Tuples @($tuple) -Source 'graphql' -Truncated $true -ValuePresentPrNumbers @(100)
        $reportText = (Format-ReviewCostSection -Rollup $rollup) -join "`n"

        $reportText.Contains('Truncated') | Should -BeTrue -Because (
            "AC4 requires an explicit truncation caveat inside the cost section when Rollup.Truncated is true.`nActual report:`n$reportText"
        )
    }

    It 'does not render a truncation caveat when Rollup.Truncated is false' {
        $tuple = @{ Number = 100; Surface = 'pr'; Bodies = @($script:CostReviewDispositionsPr100Body); CreatedAtValues = @('2026-01-01T00:00:00Z') }
        $rollup = Get-ReviewCostRollup -Tuples @($tuple) -Source 'graphql' -Truncated $false -ValuePresentPrNumbers @(100)
        $reportText = (Format-ReviewCostSection -Rollup $rollup) -join "`n"

        $reportText.Contains('Truncated') | Should -BeFalse -Because (
            "Actual report:`n$reportText"
        )
    }
}

Describe 'Format-ReviewCostSection - per-reviewer-source sub-table (n<5 flagging)' {
    It 'renders each reviewer_source row flagged INSUFFICIENT DATA when its own n is below 5' {
        $tuple = @{ Number = 100; Surface = 'pr'; Bodies = @($script:CostReviewDispositionsPr100Body); CreatedAtValues = @('2026-01-01T00:00:00Z') }
        $rollup = Get-ReviewCostRollup -Tuples @($tuple) -Source 'graphql' -Truncated $false -ValuePresentPrNumbers @(100)
        $reportText = (Format-ReviewCostSection -Rollup $rollup) -join "`n"

        $reportText.Contains('local: INSUFFICIENT DATA (n=3 < 5)') | Should -BeTrue -Because (
            "the local reviewer_source group has 3 entries (below 5).`nActual report:`n$reportText"
        )
        $reportText.Contains('gemini-code-assist: INSUFFICIENT DATA (n=1 < 5)') | Should -BeTrue -Because (
            "the gemini-code-assist reviewer_source group has 1 entry (below 5).`nActual report:`n$reportText"
        )
    }
}

Describe 'Format-ReviewCostSection - design-challenge comparability caveat (M17)' {
    It 'renders the convergence-filtered comparability caveat alongside the design-challenge dismiss-rate' {
        $tuple = @{ Number = 700; Surface = 'issue'; Bodies = @($script:CostWellPopulatedFindingDispositionsIssue700Body); CreatedAtValues = @('2026-01-01T00:00:00Z') }
        $rollup = Get-ReviewCostRollup -Tuples @($tuple) -Source 'graphql' -Truncated $false -ValuePresentPrNumbers @()
        $reportText = (Format-ReviewCostSection -Rollup $rollup) -join "`n"

        $reportText.Contains('Dismiss-rate (over dispositioned findings): 0.40 (2 of 5)') | Should -BeTrue -Because (
            "Actual report:`n$reportText"
        )
        $reportText.Contains('convergence-filtered findings are excluded from this denominator') | Should -BeTrue -Because (
            "judge-sustained M17 requires an explicit comparability caveat next to the design-challenge dismiss-rate.`nActual report:`n$reportText"
        )
    }
}

Describe 'Format-ReviewCostSection - new-section ordering per stage block' {
    It 'orders the code-review block as defense-kill rate, then post-judge dismiss-rate, then defer count, then the per-source sub-table' {
        $tuple = @{ Number = 100; Surface = 'pr'; Bodies = @($script:CostReviewDispositionsPr100Body); CreatedAtValues = @('2026-01-01T00:00:00Z') }
        $rollup = Get-ReviewCostRollup -Tuples @($tuple) -Source 'graphql' -Truncated $false -ValuePresentPrNumbers @(100)
        $reportLines = Format-ReviewCostSection -Rollup $rollup

        $defenseKillIdx  = ($reportLines | Select-String -Pattern '^\s*Defense-kill rate:' | Select-Object -First 1).LineNumber
        $postJudgeIdx    = ($reportLines | Select-String -Pattern '^\s*Post-judge dismiss-rate:' | Select-Object -First 1).LineNumber
        $deferIdx        = ($reportLines | Select-String -Pattern '^\s*Defer count:' | Select-Object -First 1).LineNumber
        $perSourceIdx    = ($reportLines | Select-String -Pattern '^\s*Per-reviewer-source' | Select-Object -First 1).LineNumber

        $defenseKillIdx | Should -BeLessThan $postJudgeIdx -Because "actual lines:`n$($reportLines -join "`n")"
        $postJudgeIdx | Should -BeLessThan $deferIdx -Because "actual lines:`n$($reportLines -join "`n")"
        $deferIdx | Should -BeLessThan $perSourceIdx -Because "actual lines:`n$($reportLines -join "`n")"
    }
}

Describe 'Get-ReviewCostRollup - EXT-F3 regression: stale timestamp must not survive a null-timestamp replacement (PR #843 external review)' {
    # PR #843 external review (EXT-F3, low): in the review-dispositions
    # per-key dedup loop, when a later body's CreatedAt is null/unparseable,
    # $shouldReplace stays true (array-order fallback) and
    # $perKeyLatestEntry[$key] IS replaced — but $perKeyLatestCreatedAt[$key]
    # was only updated inside the "$null -ne $createdAtDt" branch, so a
    # STALE timestamp from a PRIOR (already-overwritten) entry survived and
    # could wrongly win or lose a later comparison. The fix removes the
    # stale timestamp whenever the entry is replaced with a null timestamp.
    It 'does not let a stale timestamp from an overwritten entry reject a later, genuinely-latest candidate' {
        # Same stable_finding_key across three re-review rounds on PR 700:
        #   Round 1 (idx0, ts=2026-01-03): disposition escalate. Establishes
        #     perKeyLatestCreatedAt[key] = Jan 3 (the "stale" value).
        #   Round 2 (idx1, no timestamp): disposition dismiss. Array-order
        #     fallback replaces the entry with "dismiss" regardless of
        #     timestamp comparison (both buggy and fixed code agree here) —
        #     but the BUG leaves perKeyLatestCreatedAt[key] at the stale Jan 3
        #     instead of clearing it.
        #   Round 3 (idx2, ts=2026-01-02 -- earlier than the stale Jan 3, but
        #     the true last-processed/array-order-latest round): disposition
        #     incorporate.
        #     - BUGGY: compares Jan 2 (round 3) against the STALE Jan 3 (left
        #       over from round 1, even though round 2's entry is what's
        #       actually stored) -> Jan 2 >= Jan 3 is false -> round 3 is
        #       wrongly rejected -> final entry stays "dismiss" (round 2).
        #     - FIXED: round 2's null timestamp cleared any stale value, so
        #       round 3 has no existing timestamp to compare against and the
        #       array-order fallback applies -> round 3's "incorporate" wins.
        $round1Body = @'
<!-- review-dispositions-700 -->

```yaml
schema_version: 3
passes_run: [1]
entries:
  - stable_finding_key: "gh-700111"
    pass: 1
    disposition: escalate
    classification: routine
    severity: low
    stage: code-review
    disposition_rationale: "Round 1 disposition."
```
'@
        $round2Body = @'
<!-- review-dispositions-700 -->

```yaml
schema_version: 3
passes_run: [1]
entries:
  - stable_finding_key: "gh-700111"
    pass: 1
    disposition: dismiss
    classification: routine
    severity: low
    stage: code-review
    disposition_rationale: "Round 2 disposition (no timestamp on this comment)."
```
'@
        $round3Body = @'
<!-- review-dispositions-700 -->

```yaml
schema_version: 3
passes_run: [1]
entries:
  - stable_finding_key: "gh-700111"
    pass: 1
    disposition: incorporate
    classification: routine
    severity: low
    stage: code-review
    disposition_rationale: "Round 3 disposition."
```
'@
        $tuple = @{
            Number          = 700
            Surface         = 'pr'
            Bodies          = @($round1Body, $round2Body, $round3Body)
            CreatedAtValues = @('2026-01-03T00:00:00Z', '', '2026-01-02T00:00:00Z')
        }
        $result = Get-ReviewCostRollup -Tuples @($tuple) -Source 'graphql' -Truncated $false -ValuePresentPrNumbers @(700)

        # Fixed behavior: round 3 ("incorporate") wins -> dismiss numerator is 0.
        $result.CodeReview.PostJudgeDismissRate.N | Should -Be 1
        $result.CodeReview.PostJudgeDismissRate.Numerator | Should -Be 0
    }
}

Describe 'Get-ReviewCostRollup / Select-LatestByCreatedAt - EXT-F4 regression: culture-sensitive DateTime.Parse (PR #843 external review)' {
    # PR #843 external review (EXT-F4): both CreatedAt-parsing sites passed
    # $null as the IFormatProvider to [datetime]::Parse, which resolves to
    # CurrentCulture rather than an explicit invariant parse. GitHub's own
    # ISO-8601 `Z`-suffixed timestamps happen to parse the same regardless
    # of culture, but the code should not rely on that — these tests force
    # a non-invariant thread culture (fr-FR, day/month-swapped format) and
    # assert the parse still resolves the way an invariant (month/day)
    # parse would, proving the fix pins InvariantCulture rather than
    # inheriting whatever culture the host process happens to run under.
    BeforeEach {
        $script:OriginalCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
        [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('fr-FR')
    }
    AfterEach {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = $script:OriginalCulture
    }

    It 'Select-LatestByCreatedAt picks the invariant (month/day) latest candidate under a day/month CurrentCulture' {
        # Under invariant (MM/dd) parsing: idx0 = March 1, 2026; idx1 = Jan 1, 2026 -> idx0 is later.
        # Under fr-FR (dd/MM) parsing:     idx0 = Jan 3, 2026;   idx1 = March 1, 2026 -> idx1 would be later.
        $createdAtValues = @('03/01/2026 00:00:00', '01/03/2026 00:00:00')
        $winner = Select-LatestByCreatedAt -CreatedAtValues $createdAtValues -CandidateIndices @(0, 1)

        $winner | Should -Be 0
    }

    It 'Get-ReviewCostRollup dedup resolves per-key latest-wins using invariant date parsing, not CurrentCulture' {
        # Same stable_finding_key across two bodies; the round with the
        # invariant-latest timestamp ("March 1, 2026") must win. Under the
        # pre-fix CurrentCulture (fr-FR, dd/MM) parse the OTHER round's
        # timestamp would be read as later, flipping the winner.
        $bodyA = @'
<!-- review-dispositions-701 -->

```yaml
schema_version: 3
passes_run: [1]
entries:
  - stable_finding_key: "gh-701111"
    pass: 1
    disposition: dismiss
    classification: routine
    severity: low
    stage: code-review
    disposition_rationale: "Round A: invariant-latest (March 1, 2026)."
```
'@
        $bodyB = @'
<!-- review-dispositions-701 -->

```yaml
schema_version: 3
passes_run: [1]
entries:
  - stable_finding_key: "gh-701111"
    pass: 1
    disposition: incorporate
    classification: routine
    severity: low
    stage: code-review
    disposition_rationale: "Round B: invariant-earlier (Jan 1, 2026)."
```
'@
        $tuple = @{
            Number          = 701
            Surface         = 'pr'
            Bodies          = @($bodyA, $bodyB)
            CreatedAtValues = @('03/01/2026 00:00:00', '01/03/2026 00:00:00')
        }
        $result = Get-ReviewCostRollup -Tuples @($tuple) -Source 'graphql' -Truncated $false -ValuePresentPrNumbers @(701)

        # Round A ("dismiss") is invariant-latest and must win -> numerator 1.
        $result.CodeReview.PostJudgeDismissRate.N | Should -Be 1
        $result.CodeReview.PostJudgeDismissRate.Numerator | Should -Be 1
    }
}
