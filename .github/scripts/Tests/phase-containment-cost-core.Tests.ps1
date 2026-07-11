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
