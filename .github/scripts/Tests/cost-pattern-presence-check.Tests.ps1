#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Tests for the cost-pattern-presence-check GitHub Actions workflow (issue #467, Step 10).

.DESCRIPTION
    Tests the bash-script predicate logic (marker detection and retry loop) using
    PowerShell helpers that simulate the grep pattern. Also validates the workflow
    YAML file structure for required fields.
#>

Describe 'cost-pattern-presence-check workflow logic' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:WorkflowPath = Join-Path $script:RepoRoot '.github/workflows/cost-pattern-presence-check.yml'

        # PowerShell helper that simulates the bash grep predicate:
        #   gh pr view "$PR_NUM" --json comments --jq '.comments[].body' | grep -q '<!-- cost-pattern-data'
        # Returns $true when any comment body contains the marker substring.
        function script:Test-CostPatternMarker {
            param(
                [string[]]$CommentBodies
            )
            foreach ($body in $CommentBodies) {
                if ($body -match '<!-- cost-pattern-data') {
                    return $true
                }
            }
            return $false
        }

        # Counter-based retry mock: simulates a sequence of comment-body sets where
        # the marker appears on a given attempt (1-based index into $AttemptBodySets).
        # Each entry in $AttemptBodySets is a PSCustomObject with a Bodies array to
        # prevent PowerShell from flattening nested arrays.
        # Returns a hashtable with ExitCode and AttemptCount.
        function script:Invoke-RetryLoop {
            param(
                [int]$MaxAttempts = 5,
                [PSCustomObject[]]$AttemptBodySets = @()
            )
            $attempt = 0
            for ($i = 1; $i -le $MaxAttempts; $i++) {
                $attempt = $i
                $bodies = if ($AttemptBodySets.Count -ge $i) { $AttemptBodySets[$i - 1].Bodies } else { @() }
                if (script:Test-CostPatternMarker -CommentBodies $bodies) {
                    return @{ ExitCode = 0; AttemptCount = $attempt }
                }
            }
            return @{ ExitCode = 1; AttemptCount = $attempt }
        }
    }

    Context 'marker present' {

        It 'exits 0 immediately when marker found on first attempt' {
            $attemptSets = @(
                [PSCustomObject]@{ Bodies = @('Some unrelated comment', '<!-- cost-pattern-data ... -->') }
            )
            $result = script:Invoke-RetryLoop -MaxAttempts 5 -AttemptBodySets $attemptSets
            $result.ExitCode | Should -Be 0
            $result.AttemptCount | Should -Be 1
        }

        It 'exits 0 on later attempt when marker appears after retry' {
            # Attempt 1 and 2 have no marker; attempt 3 has the marker.
            $attemptSets = @(
                [PSCustomObject]@{ Bodies = @('No marker here') }
                [PSCustomObject]@{ Bodies = @('Still no marker') }
                [PSCustomObject]@{ Bodies = @('<!-- cost-pattern-data start', 'extra comment') }
            )
            $result = script:Invoke-RetryLoop -MaxAttempts 5 -AttemptBodySets $attemptSets
            $result.ExitCode | Should -Be 0
            $result.AttemptCount | Should -Be 3
        }
    }

    Context 'marker absent' {

        It 'exits 1 after all retries exhausted when marker never present' {
            $noMarkerSets = @(
                [PSCustomObject]@{ Bodies = @('no marker attempt 1') }
                [PSCustomObject]@{ Bodies = @('no marker attempt 2') }
                [PSCustomObject]@{ Bodies = @('no marker attempt 3') }
                [PSCustomObject]@{ Bodies = @('no marker attempt 4') }
                [PSCustomObject]@{ Bodies = @('no marker attempt 5') }
            )
            $result = script:Invoke-RetryLoop -MaxAttempts 5 -AttemptBodySets $noMarkerSets
            $result.ExitCode | Should -Be 1
            $result.AttemptCount | Should -Be 5
        }
    }

    Context 'unlabeled PR' {

        It 'workflow job condition is false for PR without cost-reduction label' {
            # Simulate the GitHub Actions `if:` condition evaluation.
            # The condition checks: contains(github.event.pull_request.labels.*.name, 'cost-reduction')
            $labels = @('bug', 'enhancement', 'documentation')
            $hasCostReduction = $labels -contains 'cost-reduction'
            $hasCostReduction | Should -Be $false
        }
    }

    Context 'label detection' {

        It 'job condition is true for PR with cost-reduction label' {
            $labels = @('bug', 'cost-reduction', 'enhancement')
            $hasCostReduction = $labels -contains 'cost-reduction'
            $hasCostReduction | Should -Be $true
        }

        It 'job condition is false for PR with other label only' {
            $labels = @('cost-analysis', 'cost-monitoring')
            $hasCostReduction = $labels -contains 'cost-reduction'
            $hasCostReduction | Should -Be $false
        }
    }

    Context 'workflow YAML structure' {

        It 'workflow YAML file exists' {
            Test-Path $script:WorkflowPath | Should -Be $true
        }

        It 'workflow YAML contains cost-reduction label check' {
            $content = Get-Content -Path $script:WorkflowPath -Raw
            $content | Should -Match 'cost-reduction'
        }

        It 'workflow YAML runs on ubuntu-latest' {
            $content = Get-Content -Path $script:WorkflowPath -Raw
            $content | Should -Match 'ubuntu-latest'
        }

        It 'workflow YAML triggers on pull_request and issue_comment' {
            $content = Get-Content -Path $script:WorkflowPath -Raw
            $content | Should -Match 'pull_request'
            $content | Should -Match 'issue_comment'
        }

        It 'workflow YAML uses 5-attempt retry loop' {
            $content = Get-Content -Path $script:WorkflowPath -Raw
            # The retry loop iterates 1 2 3 4 5
            $content | Should -Match '1 2 3 4 5'
        }
    }
}
