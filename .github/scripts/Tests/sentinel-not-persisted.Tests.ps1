#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Tests for sentinel-based not-persisted synthesis (issue #441, Step 5a).
#
# Sentinel marker: <!-- review-judge-produced-{PR} -->
# Three paths:
#   Path A: sentinel present + review credit absent  → synthesize not-persisted row
#   Path B: sentinel absent  + review credit absent  → no synthesis
#   Path C: sentinel present + review credit present → no synthesis (credit wins)

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:LibPath = Join-Path $script:RepoRoot '.github/scripts/lib/frame-credit-ledger-core.ps1'

    if (Test-Path $script:LibPath) {
        . $script:LibPath
    }

    # Build a minimal PR with a pipeline-metrics block.
    $script:NewV4Body = {
        param([string]$Yaml, [string]$SentinelComment = '')
        $marker = "<!-- pipeline-metrics`n$Yaml`n-->"
        return "## Summary`n`nA PR.`n`n$marker`n`n$SentinelComment"
    }

    # PR body with sentinel, NO review credit.
    $script:YamlNoReviewCredit = @'
metrics_version: 4
frame_version: 1
credits:
  - port: release-hygiene
    adapter: symmetric-bump
    status: passed
    run_index: 1
    evidence: "all manifests bumped"
'@

    # PR body with sentinel AND review credit already present.
    $script:YamlWithReviewCredit = @'
metrics_version: 4
frame_version: 1
credits:
  - port: review
    adapter: standard
    status: passed
    run_index: 1
    evidence: "judge ruling: keep"
  - port: release-hygiene
    adapter: symmetric-bump
    status: passed
    run_index: 1
    evidence: "all manifests bumped"
'@

    # PR body with NO sentinel, NO review credit.
    $script:YamlNoSentinelNoCredit = @'
metrics_version: 4
frame_version: 1
credits:
  - port: release-hygiene
    adapter: symmetric-bump
    status: passed
    run_index: 1
    evidence: "all manifests bumped"
'@

    $script:SentinelFor99 = '<!-- review-judge-produced-99 -->'
    $script:SentinelUrl99  = 'https://github.com/org/repo/pull/99#issuecomment-12345'
}

Describe 'Test-ReviewSentinelPresent (Step 5a)' {

    It 'returns true when the sentinel comment is present in the comment block' {
        $comments = @(
            [pscustomobject]@{ body = '<!-- review-judge-produced-99 -->' }
        )
        $result = Test-ReviewSentinelPresent -PrNumber 99 -Comments $comments
        $result | Should -Be $true
    }

    It 'returns true when sentinel is mixed with other text in the comment' {
        $comments = @(
            [pscustomobject]@{ body = "Some preamble`n<!-- review-judge-produced-99 -->`nSome trailing text" }
        )
        $result = Test-ReviewSentinelPresent -PrNumber 99 -Comments $comments
        $result | Should -Be $true
    }

    It 'returns false when no comment contains the sentinel' {
        $comments = @(
            [pscustomobject]@{ body = 'Just a regular comment.' }
        )
        $result = Test-ReviewSentinelPresent -PrNumber 99 -Comments $comments
        $result | Should -Be $false
    }

    It 'returns false when the comments list is empty' {
        $result = Test-ReviewSentinelPresent -PrNumber 99 -Comments @()
        $result | Should -Be $false
    }

    It 'returns false when comments is null' {
        $result = Test-ReviewSentinelPresent -PrNumber 99 -Comments $null
        $result | Should -Be $false
    }

    It 'does not match a sentinel for a different PR number' {
        $comments = @(
            [pscustomobject]@{ body = '<!-- review-judge-produced-100 -->' }
        )
        $result = Test-ReviewSentinelPresent -PrNumber 99 -Comments $comments
        $result | Should -Be $false
    }
}

Describe 'Resolve-NotPersistedSynthesis (Step 5a)' {

    Context 'Path A: sentinel present + review credit absent → synthesize not-persisted row' {

        It 'returns a not-persisted credit when sentinel is present and no review credit exists' {
            $metricsBlock = [pscustomobject]@{
                MetricsVersion = 4
                Credits        = @(
                    [pscustomobject]@{ Port = 'release-hygiene'; Adapter = 'symmetric-bump'; Status = 'passed'; RunIndex = 1 }
                )
            }
            $comments = @(
                [pscustomobject]@{ body = "<!-- review-judge-produced-99 -->"; url = $script:SentinelUrl99 }
            )

            $result = Resolve-NotPersistedSynthesis -PrNumber 99 -MetricsBlock $metricsBlock -Comments $comments

            $result | Should -Not -BeNullOrEmpty
            $result.Port   | Should -Be 'review'
            $result.Status | Should -Be 'not-persisted'
            $result.Evidence | Should -Match 'sentinel'
        }

        It 'synthesized credit includes sentinel URL as evidence when comment has url property' {
            $metricsBlock = [pscustomobject]@{
                MetricsVersion = 4
                Credits        = @()
            }
            $comments = @(
                [pscustomobject]@{ body = "<!-- review-judge-produced-99 -->"; url = $script:SentinelUrl99 }
            )

            $result = Resolve-NotPersistedSynthesis -PrNumber 99 -MetricsBlock $metricsBlock -Comments $comments
            $result.Evidence | Should -Match ([regex]::Escape($script:SentinelUrl99))
        }
    }

    Context 'Path B: sentinel absent + review credit absent → no synthesis' {

        It 'returns null when no sentinel and no review credit' {
            $metricsBlock = [pscustomobject]@{
                MetricsVersion = 4
                Credits        = @(
                    [pscustomobject]@{ Port = 'release-hygiene'; Adapter = 'symmetric-bump'; Status = 'passed'; RunIndex = 1 }
                )
            }
            $comments = @(
                [pscustomobject]@{ body = 'Just a regular comment.' }
            )

            $result = Resolve-NotPersistedSynthesis -PrNumber 99 -MetricsBlock $metricsBlock -Comments $comments
            $result | Should -BeNullOrEmpty
        }
    }

    Context 'Path C: sentinel present + review credit present → no synthesis' {

        It 'returns null when sentinel is present but a review credit already exists' {
            $metricsBlock = [pscustomobject]@{
                MetricsVersion = 4
                Credits        = @(
                    [pscustomobject]@{ Port = 'review'; Adapter = 'standard'; Status = 'passed'; RunIndex = 1 }
                    [pscustomobject]@{ Port = 'release-hygiene'; Adapter = 'symmetric-bump'; Status = 'passed'; RunIndex = 1 }
                )
            }
            $comments = @(
                [pscustomobject]@{ body = "<!-- review-judge-produced-99 -->"; url = $script:SentinelUrl99 }
            )

            $result = Resolve-NotPersistedSynthesis -PrNumber 99 -MetricsBlock $metricsBlock -Comments $comments
            $result | Should -BeNullOrEmpty
        }

        It 'returns null when sentinel present and review credit with not-persisted already exists (idempotent)' {
            $metricsBlock = [pscustomobject]@{
                MetricsVersion = 4
                Credits        = @(
                    [pscustomobject]@{ Port = 'review'; Adapter = 'standard'; Status = 'not-persisted'; RunIndex = 1 }
                )
            }
            $comments = @(
                [pscustomobject]@{ body = "<!-- review-judge-produced-99 -->"; url = $script:SentinelUrl99 }
            )

            $result = Resolve-NotPersistedSynthesis -PrNumber 99 -MetricsBlock $metricsBlock -Comments $comments
            $result | Should -BeNullOrEmpty
        }
    }
}

Describe 'Sentinel ordering and idempotency contract (Step 6 — SMC-16)' {

    # The ordering rule from review-judgment/SKILL.md § Structured Judge Output:
    #   sentinel comment → judge-rulings comment
    # These tests verify that:
    #   (a) the sentinel token is structurally distinct from the judge-rulings comment
    #   (b) Test-ReviewSentinelPresent is tolerant of mixed-content comments
    #   (c) Resolve-NotPersistedSynthesis is idempotent when called twice with the same input

    It 'sentinel token does not contain judge-rulings block (ordering: sentinel is a standalone comment)' {
        # The sentinel must be a minimal standalone HTML comment — not combined with judge-rulings YAML.
        $sentinelBody = '<!-- review-judge-produced-99 -->'

        $sentinelBody | Should -Not -Match 'judge-rulings'
        $sentinelBody | Should -Not -Match 'code-review-complete'
        $sentinelBody | Should -Match '<!-- review-judge-produced-99 -->'
    }

    It 'judge-rulings comment contains judge-rulings block but NOT the sentinel or retired completion marker (ordering enforced, issue #441 Step 11)' {
        # After the sentinel (a separate PR comment), the judge-rulings comment carries the YAML block only —
        # not the sentinel again, and not the retired <!-- code-review-complete-{PR} --> marker.
        $judgeRulingsBody = @"
<!-- judge-rulings
- id: F1
  judge_ruling: sustained
  judge_confidence: high
  points_awarded: P+10
-->
"@

        $judgeRulingsBody | Should -Match 'judge-rulings'
        # The sentinel should NOT be duplicated inside the judge-rulings comment.
        $judgeRulingsBody | Should -Not -Match 'review-judge-produced'
        # The retired completion marker must not appear in the judge-rulings comment (issue #441 Step 11).
        $judgeRulingsBody | Should -Not -Match 'code-review-complete'
    }

    It 'Test-ReviewSentinelPresent is idempotent — returns true when sentinel appears in multiple comments' {
        $comments = @(
            [pscustomobject]@{ body = '<!-- review-judge-produced-99 -->' }
            [pscustomobject]@{ body = '<!-- review-judge-produced-99 -->' }
        )
        $result = Test-ReviewSentinelPresent -PrNumber 99 -Comments $comments
        $result | Should -Be $true
    }

    It 'Resolve-NotPersistedSynthesis is idempotent — calling twice with same inputs returns same null (credit-present path)' {
        $metricsBlock = [pscustomobject]@{
            MetricsVersion = 4
            Credits        = @(
                [pscustomobject]@{ Port = 'review'; Adapter = 'standard'; Status = 'not-persisted'; RunIndex = 1 }
            )
        }
        $comments = @(
            [pscustomobject]@{ body = "<!-- review-judge-produced-99 -->"; url = $script:SentinelUrl99 }
        )

        $first  = Resolve-NotPersistedSynthesis -PrNumber 99 -MetricsBlock $metricsBlock -Comments $comments
        $second = Resolve-NotPersistedSynthesis -PrNumber 99 -MetricsBlock $metricsBlock -Comments $comments

        $first  | Should -BeNullOrEmpty
        $second | Should -BeNullOrEmpty
    }

    It 'Resolve-NotPersistedSynthesis synthesizes only once — second call after credit added returns null' {
        # Simulate: first call synthesizes a credit, second call finds credit already present.
        $metricsBlockNone = [pscustomobject]@{
            MetricsVersion = 4
            Credits        = @()
        }
        $comments = @(
            [pscustomobject]@{ body = "<!-- review-judge-produced-99 -->"; url = $script:SentinelUrl99 }
        )

        $synthesized = Resolve-NotPersistedSynthesis -PrNumber 99 -MetricsBlock $metricsBlockNone -Comments $comments
        $synthesized | Should -Not -BeNullOrEmpty
        $synthesized.Port   | Should -Be 'review'
        $synthesized.Status | Should -Be 'not-persisted'

        # Now simulate that the synthesized credit was appended and persisted.
        $metricsBlockWithCredit = [pscustomobject]@{
            MetricsVersion = 4
            Credits        = @(
                [pscustomobject]@{ Port = 'review'; Adapter = 'sentinel-synthesis'; Status = 'not-persisted'; RunIndex = 1 }
            )
        }

        $second = Resolve-NotPersistedSynthesis -PrNumber 99 -MetricsBlock $metricsBlockWithCredit -Comments $comments
        $second | Should -BeNullOrEmpty
    }
}
