#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# TDD tests for specialist implement-* credit row builders (issue #442, Step 4c).
#
# Builders: Build-ImplementCodeCreditRow, Build-ImplementTestCreditRow,
#           Build-ImplementRefactorCreditRow, Build-ImplementDocsCreditRow
#
# Status logic (D8 + AC9):
#   - -ValidationEvidence @() empty list → status: skipped, reason in evidence
#   - -ValidationEvidence with all 'passed' (case-insensitive) → status: passed
#   - -ValidationEvidence with any non-passed → status: failed, offending name in evidence
#   - -AutoNaResult $true → status: not-applicable
#   - -AdapterName 'explicit-skip' → status: skipped

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

    $script:LedgerCoreLib = Join-Path $script:RepoRoot '.github/scripts/lib/frame-credit-ledger-core.ps1'
    if (Test-Path $script:LedgerCoreLib) {
        . $script:LedgerCoreLib
    }
}

# ---------------------------------------------------------------------------
# Port naming
# ---------------------------------------------------------------------------

Describe 'Implement builders emit correct port names' {

    It 'Build-ImplementCodeCreditRow emits port implement-code' {
        $row = Build-ImplementCodeCreditRow -ValidationEvidence @(@{ Name = 'lint'; Status = 'passed' })
        $row.port | Should -Be 'implement-code'
    }

    It 'Build-ImplementTestCreditRow emits port implement-test' {
        $row = Build-ImplementTestCreditRow -ValidationEvidence @(@{ Name = 'pester'; Status = 'passed' })
        $row.port | Should -Be 'implement-test'
    }

    It 'Build-ImplementRefactorCreditRow emits port implement-refactor' {
        $row = Build-ImplementRefactorCreditRow -ValidationEvidence @(@{ Name = 'sonar'; Status = 'passed' })
        $row.port | Should -Be 'implement-refactor'
    }

    It 'Build-ImplementDocsCreditRow emits port implement-docs' {
        $row = Build-ImplementDocsCreditRow -ValidationEvidence @(@{ Name = 'doc-lint'; Status = 'passed' })
        $row.port | Should -Be 'implement-docs'
    }
}

# ---------------------------------------------------------------------------
# Empty ValidationEvidence → skipped
# ---------------------------------------------------------------------------

Describe 'Implement builders emit skipped when ValidationEvidence is empty' {

    It 'Build-ImplementCodeCreditRow emits skipped with reason when evidence is empty' {
        $row = Build-ImplementCodeCreditRow -ValidationEvidence @()
        $row.status | Should -Be 'skipped'
        $row.evidence | Should -Match 'no validator evidence'
    }

    It 'Build-ImplementTestCreditRow emits skipped with reason when evidence is empty' {
        $row = Build-ImplementTestCreditRow -ValidationEvidence @()
        $row.status | Should -Be 'skipped'
        $row.evidence | Should -Match 'no validator evidence'
    }

    It 'Build-ImplementRefactorCreditRow emits skipped with reason when evidence is empty' {
        $row = Build-ImplementRefactorCreditRow -ValidationEvidence @()
        $row.status | Should -Be 'skipped'
        $row.evidence | Should -Match 'no validator evidence'
    }

    It 'Build-ImplementDocsCreditRow emits skipped with reason when evidence is empty' {
        $row = Build-ImplementDocsCreditRow -ValidationEvidence @()
        $row.status | Should -Be 'skipped'
        $row.evidence | Should -Match 'no validator evidence'
    }
}

# ---------------------------------------------------------------------------
# All passed (case-insensitive) → passed
# ---------------------------------------------------------------------------

Describe 'Implement builders emit passed when all validators pass (case-insensitive)' {

    It 'emits passed when validator status is "passed" (lowercase)' {
        $row = Build-ImplementCodeCreditRow -ValidationEvidence @(@{ Name = 'lint'; Status = 'passed' })
        $row.status | Should -Be 'passed'
    }

    It 'emits passed when validator status is "Passed" (mixed case)' {
        $row = Build-ImplementCodeCreditRow -ValidationEvidence @(@{ Name = 'lint'; Status = 'Passed' })
        $row.status | Should -Be 'passed'
    }

    It 'emits passed when validator status is "PASSED" (uppercase)' {
        $row = Build-ImplementCodeCreditRow -ValidationEvidence @(@{ Name = 'lint'; Status = 'PASSED' })
        $row.status | Should -Be 'passed'
    }

    It 'emits passed when multiple validators all pass' {
        $row = Build-ImplementTestCreditRow -ValidationEvidence @(
            @{ Name = 'pester'; Status = 'passed' }
            @{ Name = 'coverage'; Status = 'Passed' }
        )
        $row.status | Should -Be 'passed'
    }
}

# ---------------------------------------------------------------------------
# Any non-passed → failed with offending name
# ---------------------------------------------------------------------------

Describe 'Implement builders emit failed when any validator is non-passed' {

    It 'emits failed when one validator has status "failed"' {
        $row = Build-ImplementCodeCreditRow -ValidationEvidence @(
            @{ Name = 'lint'; Status = 'passed' }
            @{ Name = 'typecheck'; Status = 'failed' }
        )
        $row.status | Should -Be 'failed'
    }

    It 'includes offending validator name in evidence' {
        $row = Build-ImplementCodeCreditRow -ValidationEvidence @(
            @{ Name = 'typecheck'; Status = 'error' }
        )
        $row.status | Should -Be 'failed'
        $row.evidence | Should -Match 'typecheck'
    }

    It 'emits failed when status is neither passed nor failed (e.g. "error")' {
        $row = Build-ImplementTestCreditRow -ValidationEvidence @(
            @{ Name = 'pester'; Status = 'error' }
        )
        $row.status | Should -Be 'failed'
    }
}

# ---------------------------------------------------------------------------
# AutoNaResult → not-applicable
# ---------------------------------------------------------------------------

Describe 'Implement builders emit not-applicable when AutoNaResult is true' {

    It 'Build-ImplementCodeCreditRow emits not-applicable when -AutoNaResult is true' {
        $row = Build-ImplementCodeCreditRow -AutoNaResult $true
        $row.status | Should -Be 'not-applicable'
    }

    It 'Build-ImplementTestCreditRow emits not-applicable when -AutoNaResult is true' {
        $row = Build-ImplementTestCreditRow -AutoNaResult $true
        $row.status | Should -Be 'not-applicable'
    }

    It 'Build-ImplementRefactorCreditRow emits not-applicable when -AutoNaResult is true' {
        $row = Build-ImplementRefactorCreditRow -AutoNaResult $true
        $row.status | Should -Be 'not-applicable'
    }

    It 'Build-ImplementDocsCreditRow emits not-applicable when -AutoNaResult is true' {
        $row = Build-ImplementDocsCreditRow -AutoNaResult $true
        $row.status | Should -Be 'not-applicable'
    }
}

# ---------------------------------------------------------------------------
# explicit-skip adapter → skipped
# ---------------------------------------------------------------------------

Describe 'Implement builders emit skipped when explicit-skip adapter is used' {

    It 'Build-ImplementCodeCreditRow emits skipped when -AdapterName is explicit-skip' {
        $row = Build-ImplementCodeCreditRow -AdapterName 'explicit-skip'
        $row.status | Should -Be 'skipped'
    }

    It 'Build-ImplementRefactorCreditRow accepts -DebtThreshold hashtable without error' {
        $row = Build-ImplementRefactorCreditRow -ValidationEvidence @() -DebtThreshold @{ lineCount = 300; complexity = 10 }
        $row | Should -Not -BeNullOrEmpty
    }
}
