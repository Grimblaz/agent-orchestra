#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Tests for Get-FCLOriginContext (issue #769, slice s1).

.DESCRIPTION
    Verifies the CI-safe orchestrated-origin predicate:
      - PRIMARY: GITHUB_HEAD_REF branch-name matching
      - FALLBACK: PR body linked-issue signals
      - Detached-HEAD CI artifact ('HEAD') falls through to body fallback
      - Non-orchestrated refs return IsOrchestratedOrigin=$false

    Also covers the builder repro (New-PipelineMetricsV4Block) and its
    throw conditions, as required by the s1 Requirement Contract.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:PredicatePath = Join-Path $script:RepoRoot '.github/scripts/lib/Get-FCLOriginContext.ps1'
    $script:CorePath     = Join-Path $script:RepoRoot '.github/scripts/lib/frame-credit-ledger-core.ps1'

    if (Test-Path $script:PredicatePath) {
        . $script:PredicatePath
    }
    if (Test-Path $script:CorePath) {
        . $script:CorePath
    }
}

# ===========================================================================
# Get-FCLOriginContext — origin predicate tests
# ===========================================================================

Describe 'Get-FCLOriginContext — branch signal (PRIMARY)' {

    It 'Test 1: feature/issue-769-foo HeadRef returns IsOrchestratedOrigin=$true with LinkedIssueNumber=769 via branch' {
        # Arrange
        $headRef = 'feature/issue-769-foo'

        # Act
        $ctx = Get-FCLOriginContext -HeadRef $headRef

        # Assert
        $ctx                   | Should -Not -BeNullOrEmpty
        $ctx.IsOrchestratedOrigin | Should -Be $true
        $ctx.LinkedIssueNumber    | Should -Be 769
        $ctx.DetectionMethod      | Should -Be 'branch'
    }

    It 'Test 4: dependabot/npm-and-yarn/foo HeadRef returns IsOrchestratedOrigin=$false' {
        # Arrange
        $headRef = 'dependabot/npm-and-yarn/foo'

        # Act
        $ctx = Get-FCLOriginContext -HeadRef $headRef

        # Assert
        $ctx.IsOrchestratedOrigin | Should -Be $false
        $ctx.DetectionMethod      | Should -Be 'none'
    }
}

Describe 'Get-FCLOriginContext — detached-HEAD CI simulation (M3)' {

    It 'Test 2: HeadRef=HEAD (detached-HEAD CI artifact) with body fallback containing plan-issue-769 returns IsOrchestratedOrigin=$true via body' {
        # Arrange: simulate CI where rev-parse yields literal "HEAD"
        $headRef = 'HEAD'
        $prBody  = "## Summary`n`nFixes the bug.`n`n<!-- plan-issue-769 -->`n"

        # Act
        $ctx = Get-FCLOriginContext -HeadRef $headRef -PrBody $prBody

        # Assert: must NOT match on 'HEAD' string; must fall through to body
        $ctx.IsOrchestratedOrigin | Should -Be $true
        $ctx.LinkedIssueNumber    | Should -Be 769
        $ctx.DetectionMethod      | Should -Be 'body'
    }

    It 'Test 5: HeadRef=HEAD with no body signals returns IsOrchestratedOrigin=$false' {
        # Arrange
        $headRef = 'HEAD'
        $prBody  = "## Summary`n`nA regular PR with no linked issue signals."

        # Act
        $ctx = Get-FCLOriginContext -HeadRef $headRef -PrBody $prBody

        # Assert
        $ctx.IsOrchestratedOrigin | Should -Be $false
        $ctx.DetectionMethod      | Should -Be 'none'
    }
}

Describe 'Get-FCLOriginContext — body fallback signals' {

    It 'Test 3: null HeadRef with plan-issue-769 in body returns IsOrchestratedOrigin=$true via body' {
        # Arrange
        $prBody = "## Summary`n`nThis PR implements the fix.`n`n<!-- plan-issue-769 -->`n"

        # Act
        $ctx = Get-FCLOriginContext -HeadRef $null -PrBody $prBody

        # Assert
        $ctx.IsOrchestratedOrigin | Should -Be $true
        $ctx.LinkedIssueNumber    | Should -Be 769
        $ctx.DetectionMethod      | Should -Be 'body'
    }

    It 'body fallback: Fixes #769 keyword pattern NO LONGER returns IsOrchestratedOrigin=$true (keyword-linked leg removed)' {
        $prBody = "Fixes #769`n`nMore description."
        $ctx = Get-FCLOriginContext -HeadRef $null -PrBody $prBody

        # keyword-linked pattern was removed (B4a fix) — must NOT classify as orchestrated
        $ctx.IsOrchestratedOrigin | Should -Be $false
        $ctx.DetectionMethod      | Should -Be 'none'
    }

    It 'body fallback: PR with Fixes #N AND plan-issue comment marker is orchestrated (plan-issue signal survives removal of keyword leg)' {
        $prBody = "Fixes #769`n`n<!-- plan-issue-769 -->`n"
        $ctx = Get-FCLOriginContext -HeadRef $null -PrBody $prBody

        $ctx.IsOrchestratedOrigin | Should -Be $true
        $ctx.LinkedIssueNumber    | Should -Be 769
        $ctx.DetectionMethod      | Should -Be 'body'
    }

    It 'body fallback: issue_id: 769 pattern returns IsOrchestratedOrigin=$true via body' {
        $prBody = "## Summary`n`nissue_id: 769`n`nDescription."
        $ctx = Get-FCLOriginContext -HeadRef $null -PrBody $prBody

        $ctx.IsOrchestratedOrigin | Should -Be $true
        $ctx.LinkedIssueNumber    | Should -Be 769
        $ctx.DetectionMethod      | Should -Be 'body'
    }

    It 'body fallback: empty HeadRef with no body signals returns IsOrchestratedOrigin=$false' {
        $ctx = Get-FCLOriginContext -HeadRef '' -PrBody ''

        $ctx.IsOrchestratedOrigin | Should -Be $false
        $ctx.DetectionMethod      | Should -Be 'none'
    }
}

Describe 'Get-FCLOriginContext — branch signal prioritizes over body' {

    It 'branch takes priority: feature/issue-100 HeadRef with conflicting body returns LinkedIssueNumber=100 from branch' {
        # Arrange: branch says 100, body says 999
        $headRef = 'feature/issue-100-my-feature'
        $prBody  = "<!-- plan-issue-999 -->`n"

        # Act
        $ctx = Get-FCLOriginContext -HeadRef $headRef -PrBody $prBody

        # Assert: branch wins
        $ctx.IsOrchestratedOrigin | Should -Be $true
        $ctx.LinkedIssueNumber    | Should -Be 100
        $ctx.DetectionMethod      | Should -Be 'branch'
    }
}

# ===========================================================================
# New-PipelineMetricsV4Block — builder repro and throw conditions (s1 AC1)
# ===========================================================================

Describe 'New-PipelineMetricsV4Block — builder repro (s1 AC1)' {

    It 'Test 6: valid hand-fed credit row produces a block with metrics_version: 4' {
        # Arrange: hand-fed credit rows as required by the s1 builder-repro
        $credits = @(
            [pscustomobject]@{
                port        = 'implement-test'
                adapter     = 'skills/test-driven-development/adapters/implement-test-adapter.md'
                status      = 'passed'
                run_index   = 1
                evidence    = 'Get-FCLOriginContext.Tests.ps1 — all tests green (s1 builder repro)'
            }
        )
        $v3Base = "pr_number: 769`nbranch: feature/issue-769-v4-emission-reliability"

        # Act
        $block = New-PipelineMetricsV4Block `
            -V3BaseYaml $v3Base `
            -Credits $credits

        # Assert
        $block | Should -Not -BeNullOrEmpty

        # Exactly one opener and one closer
        $openerCount = ([regex]::Matches($block, [regex]::Escape('<!-- pipeline-metrics'))).Count
        $openerCount | Should -Be 1

        # Must carry metrics_version: 4
        $block | Should -Match '(?m)^metrics_version:\s*4\s*$'

        # Must carry frame_version: 1
        $block | Should -Match '(?m)^frame_version:\s*1\s*$'

        # Credit row must be present
        $block | Should -Match 'port: implement-test'
        $block | Should -Match 'status: passed'

        # Round-trip: wrapper must parse back as v4
        $prBody = "## PR`n`n$block`n"
        $parsed = Read-PRMetricsBlock -PrBody $prBody
        $parsed.MetricsVersion | Should -Be 4
        @($parsed.Credits).Count | Should -BeGreaterOrEqual 1
    }

    It 'Test 7: empty V3BaseYaml throws the expected error' {
        # Arrange + Act + Assert: line :2829-2831 of frame-credit-ledger-core.ps1
        {
            New-PipelineMetricsV4Block -V3BaseYaml ''
        } | Should -Throw -ExpectedMessage '*-V3BaseYaml must not be null or empty*'
    }

    It 'Test 8: V3BaseYaml containing <!-- pipeline-metrics opener throws the expected error' {
        # Arrange: pre-existing opener in V3BaseYaml triggers double-wrap guard (:2833-2835)
        $yamlWithOpener = "<!-- pipeline-metrics`nmetrics_version: 3`nfoo: bar"

        # Act + Assert
        {
            New-PipelineMetricsV4Block -V3BaseYaml $yamlWithOpener
        } | Should -Throw -ExpectedMessage '*already contains a <!-- pipeline-metrics*'
    }

    It 'builder repro: ExistingPRBody with v4 block throws (initial-creation-only guard, :2817-2822)' {
        # Arrange: pre-existing v4 block in ExistingPRBody
        $existingBody = "## PR`n`n<!-- pipeline-metrics`nmetrics_version: 4`nframe_version: 1`n-->`n"

        # Act + Assert
        {
            New-PipelineMetricsV4Block `
                -V3BaseYaml 'pr_number: 769' `
                -ExistingPRBody $existingBody
        } | Should -Throw -ExpectedMessage '*already has a v4 pipeline-metrics block*'
    }
}
