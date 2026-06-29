#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Tests for Add-FCLCreditRow and Get-FCLAccumulatedCredits (issue #769 s-acc).
#
# Scripts under test:
#   .github/scripts/lib/Add-FCLCreditRow.ps1
#   .github/scripts/lib/Get-FCLAccumulatedCredits.ps1
#
# Coverage:
#   1. Round-trip: Add-FCLCreditRow row -> Get-FCLAccumulatedCredits -> same data returned.
#   2. Multiple rows: 3 rows added -> all 3 returned in order.
#   3. Directory created when missing: remove .tmp/issue-{N} -> call Add-FCLCreditRow
#      -> directory + file created.
#   4. Get returns @() when no file: issue number with no file -> returns empty array.
#   5. Idempotency (no-dedup): Add same row twice -> Get returns 2 rows.

BeforeAll {
    $script:RepoRoot  = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:AddScript = Join-Path $script:RepoRoot '.github/scripts/lib/Add-FCLCreditRow.ps1'
    $script:GetScript = Join-Path $script:RepoRoot '.github/scripts/lib/Get-FCLAccumulatedCredits.ps1'

    # Load both functions into this session.
    . $script:AddScript
    . $script:GetScript

    # Unique test issue number unlikely to collide with real work.
    $script:TestIssueNumber = 99999

    # Canonical accumulator path for the test issue.
    $script:AccumulatorDir  = Join-Path $script:RepoRoot ".tmp/issue-$($script:TestIssueNumber)"
    $script:AccumulatorFile = Join-Path $script:AccumulatorDir 'fclcredits.jsonl'

    # A minimal valid credit row pscustomobject.
    $script:SampleRow = [pscustomobject]@{
        port      = 'implement-code'
        adapter   = 'skills/implementation-discipline/adapters/implement-code-adapter.md'
        status    = 'passed'
        run_index = 1
        evidence  = 'Add-FCLCreditRow.Tests.ps1 -- test fixture'
    }
}

AfterAll {
    # Remove the test accumulator directory to avoid cross-test contamination.
    if (Test-Path -LiteralPath $script:AccumulatorDir) {
        Remove-Item -LiteralPath $script:AccumulatorDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Add-FCLCreditRow / Get-FCLAccumulatedCredits' {

    BeforeEach {
        # Start each test with a clean accumulator file.
        if (Test-Path -LiteralPath $script:AccumulatorFile) {
            Remove-Item -LiteralPath $script:AccumulatorFile -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'Case 1 - round-trip: single row survives Add -> Get cycle' {

        It 'returns the same port and status after a single Add call' {
            Add-FCLCreditRow -IssueNumber $script:TestIssueNumber -CreditRow $script:SampleRow

            $rows = @(Get-FCLAccumulatedCredits -IssueNumber $script:TestIssueNumber)

            $rows.Count          | Should -Be 1
            $rows[0].port        | Should -Be 'implement-code'
            $rows[0].status      | Should -Be 'passed'
            $rows[0].adapter     | Should -Be 'skills/implementation-discipline/adapters/implement-code-adapter.md'
        }
    }

    Context 'Case 2 - multiple rows: all 3 rows returned in append order' {

        It 'returns 3 rows in the order they were appended' {
            $row1 = [pscustomobject]@{ port = 'implement-code';   status = 'passed'; run_index = 1 }
            $row2 = [pscustomobject]@{ port = 'implement-test';   status = 'failed'; run_index = 2 }
            $row3 = [pscustomobject]@{ port = 'implement-refactor'; status = 'not-applicable'; run_index = 3 }

            Add-FCLCreditRow -IssueNumber $script:TestIssueNumber -CreditRow $row1
            Add-FCLCreditRow -IssueNumber $script:TestIssueNumber -CreditRow $row2
            Add-FCLCreditRow -IssueNumber $script:TestIssueNumber -CreditRow $row3

            $rows = @(Get-FCLAccumulatedCredits -IssueNumber $script:TestIssueNumber)

            $rows.Count       | Should -Be 3
            $rows[0].port     | Should -Be 'implement-code'
            $rows[1].port     | Should -Be 'implement-test'
            $rows[2].port     | Should -Be 'implement-refactor'
        }
    }

    Context 'Case 3 - directory created when missing' {

        It 'creates the directory and file when they do not exist' {
            # Remove the entire directory first.
            if (Test-Path -LiteralPath $script:AccumulatorDir) {
                Remove-Item -LiteralPath $script:AccumulatorDir -Recurse -Force
            }

            $script:AccumulatorDir  | Should -Not -Exist

            Add-FCLCreditRow -IssueNumber $script:TestIssueNumber -CreditRow $script:SampleRow

            $script:AccumulatorDir  | Should -Exist
            $script:AccumulatorFile | Should -Exist
        }
    }

    Context 'Case 4 - Get returns empty array when no file exists' {

        It 'returns an empty array when the accumulator file is absent' {
            # Ensure no file exists for the test issue.
            if (Test-Path -LiteralPath $script:AccumulatorFile) {
                Remove-Item -LiteralPath $script:AccumulatorFile -Force
            }

            $rows = @(Get-FCLAccumulatedCredits -IssueNumber $script:TestIssueNumber)

            $rows.Count | Should -Be 0
        }
    }

    Context 'Case 5 - no dedup: same row added twice returns two rows' {

        It 'returns 2 rows when the same row is appended twice' {
            Add-FCLCreditRow -IssueNumber $script:TestIssueNumber -CreditRow $script:SampleRow
            Add-FCLCreditRow -IssueNumber $script:TestIssueNumber -CreditRow $script:SampleRow

            $rows = @(Get-FCLAccumulatedCredits -IssueNumber $script:TestIssueNumber)

            # Each append is intentional; no deduplication at accumulator level.
            $rows.Count | Should -Be 2
            $rows[0].port | Should -Be $rows[1].port
        }
    }
}
