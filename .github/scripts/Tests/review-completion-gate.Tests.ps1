#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'review completion gate contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        . (Join-Path $script:RepoRoot 'skills\routing-tables\scripts\routing-tables-core.ps1')
        . (Join-Path $script:RepoRoot 'skills\routing-tables\scripts\review-state-reader.ps1')

        $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "pester-review-completion-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null

        $script:WriteReviewState = {
            param(
                [string]$Path,
                [string]$ReviewMode = 'full',
                [bool]$ProsecutionComplete = $false,
                [bool]$DefenseComplete = $false,
                [bool]$JudgmentComplete = $false,
                [string]$LastUpdated = '2026-04-24T14:00:00Z'
            )

            @"
---
issue_id: 417
review_mode: $ReviewMode
prosecution_complete: $($ProsecutionComplete.ToString().ToLowerInvariant())
defense_complete: $($DefenseComplete.ToString().ToLowerInvariant())
judgment_complete: $($JudgmentComplete.ToString().ToLowerInvariant())
last_updated: $LastUpdated
---
"@ | Set-Content -Path $Path -Encoding UTF8
        }

        $script:GetMissingStages = {
            param([hashtable]$State)

            $missingStages = [System.Collections.Generic.List[string]]::new()
            foreach ($stage in @('prosecution', 'defense', 'judgment')) {
                $fieldName = '{0}_complete' -f $stage
                if (-not ($State.Contains($fieldName) -and [bool]$State[$fieldName])) {
                    [void]$missingStages.Add($stage)
                }
            }

            return @($missingStages)
        }
    }

    AfterAll {
        Remove-Item -Path $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'maps the full review_completion truth table across all eight stage permutations' {
        $cases = @(
            @{ Prosecution = $false; Defense = $false; Judgment = $false; Expected = 'incomplete' }
            @{ Prosecution = $false; Defense = $false; Judgment = $true; Expected = 'incomplete' }
            @{ Prosecution = $false; Defense = $true; Judgment = $false; Expected = 'incomplete' }
            @{ Prosecution = $false; Defense = $true; Judgment = $true; Expected = 'incomplete' }
            @{ Prosecution = $true; Defense = $false; Judgment = $false; Expected = 'incomplete' }
            @{ Prosecution = $true; Defense = $false; Judgment = $true; Expected = 'incomplete' }
            @{ Prosecution = $true; Defense = $true; Judgment = $false; Expected = 'incomplete' }
            @{ Prosecution = $true; Defense = $true; Judgment = $true; Expected = 'complete' }
        )

        foreach ($case in $cases) {
            $result = Test-GateCriteria -Gate 'review_completion' -Criteria @{
                prosecution_complete = $case.Prosecution
                defense_complete     = $case.Defense
                judgment_complete    = $case.Judgment
            }

            $label = '({0},{1},{2})' -f [int]$case.Prosecution, [int]$case.Defense, [int]$case.Judgment
            $result | Should -Be $case.Expected -Because "review_completion must fail closed for $label unless all three stages are true"
        }
    }

    It 'treats review_mode as label-only metadata for a complete state in both full and lite modes' {
        foreach ($reviewMode in @('full', 'lite')) {
            $result = Test-GateCriteria -Gate 'review_completion' -Criteria @{
                prosecution_complete = $true
                defense_complete     = $true
                judgment_complete    = $true
                review_mode          = $reviewMode
            }

            $result | Should -Be 'complete' -Because "review_mode '$reviewMode' must not affect a complete review state"
        }
    }

    It 'treats review_mode as label-only metadata for an incomplete state in both full and lite modes' {
        foreach ($reviewMode in @('full', 'lite')) {
            $result = Test-GateCriteria -Gate 'review_completion' -Criteria @{
                prosecution_complete = $true
                defense_complete     = $false
                judgment_complete    = $true
                review_mode          = $reviewMode
            }

            $result | Should -Be 'incomplete' -Because "review_mode '$reviewMode' must not mask a missing review stage"
        }
    }

    It 'fails closed when the review-state file is missing' {
        $missingPath = Join-Path $script:TempRoot 'review-state-missing.md'

        Read-ReviewStateFile -Path $missingPath | Should -BeNullOrEmpty
    }

    It 'fails closed when the review-state file is malformed' {
        $cases = @(
            @{
                Name    = 'missing required field'
                Content = @"
---
issue_id: 417
review_mode: full
prosecution_complete: true
defense_complete: false
last_updated: 2026-04-24T14:00:00Z
---
"@
            }
            @{
                Name    = 'invalid review mode'
                Content = @"
---
issue_id: 417
review_mode: partial
prosecution_complete: true
defense_complete: false
judgment_complete: false
last_updated: 2026-04-24T14:00:00Z
---
"@
            }
            @{
                Name    = 'invalid boolean value'
                Content = @"
---
issue_id: 417
review_mode: full
prosecution_complete: true
defense_complete: maybe
judgment_complete: false
last_updated: 2026-04-24T14:00:00Z
---
"@
            }
            @{
                Name    = 'non-utc iso timestamp'
                Content = @"
---
issue_id: 417
review_mode: full
prosecution_complete: true
defense_complete: false
judgment_complete: false
last_updated: 2026-04-24 14:00:00
---
"@
            }
        )

        foreach ($case in $cases) {
            $path = Join-Path $script:TempRoot ("review-state-malformed-{0}.md" -f ($case.Name -replace '\s+', '-'))
            $case.Content | Set-Content -Path $path -Encoding UTF8

            Read-ReviewStateFile -Path $path | Should -BeNullOrEmpty -Because "$($case.Name) must fail closed"
        }
    }

    It 'fails closed when the review-state file issue_id does not match the requested issue' {
        $sessionMemoryPath = Join-Path $script:TempRoot 'session-memory-mismatch'
        New-Item -ItemType Directory -Path $sessionMemoryPath -Force | Out-Null
        $statePath = Join-Path $sessionMemoryPath 'review-state-417.md'

        @"
---
issue_id: 999
review_mode: full
prosecution_complete: true
defense_complete: true
judgment_complete: true
last_updated: 2026-04-24T14:00:00Z
---
"@ | Set-Content -Path $statePath -Encoding UTF8

        Read-ReviewStateByIssueId -IssueId 417 -SessionMemoryPath $sessionMemoryPath | Should -BeNullOrEmpty
    }

    It 'derives missing resume stages in order from a seeded review-state-417 file' {
        $sessionMemoryPath = Join-Path $script:TempRoot 'session-memory'
        New-Item -ItemType Directory -Path $sessionMemoryPath -Force | Out-Null
        $statePath = Join-Path $sessionMemoryPath 'review-state-417.md'

        & $script:WriteReviewState -Path $statePath -ReviewMode 'full' -ProsecutionComplete $true -DefenseComplete $false -JudgmentComplete $false

        $state = Read-ReviewStateByIssueId -IssueId 417 -SessionMemoryPath $sessionMemoryPath
        $missingStages = & $script:GetMissingStages -State $state

        $state | Should -Not -BeNullOrEmpty
        $missingStages | Should -Be @('defense', 'judgment') -Because 'resume logic must re-enter missing stages in canonical order'
    }
}