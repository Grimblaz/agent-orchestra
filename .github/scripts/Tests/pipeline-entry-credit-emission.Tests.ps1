#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# TDD tests for pipeline-entry credit row builders (issue #442, Step 4b).
#
# Builders: Build-ExperienceCreditRow, Build-DesignCreditRow, Build-PlanCreditRow
#
# Status logic (per D7 + D9 forward-emission semantics):
#   - -MarkerPresent $true  → status: passed
#   - -MarkerPresent $false + -AutoNaResult $true → status: not-applicable
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

Describe 'Pipeline-entry builders emit correct port names' {

    It 'Build-ExperienceCreditRow emits port experience' {
        $row = Build-ExperienceCreditRow -MarkerPresent $true -IssueNumber 42
        $row.port | Should -Be 'experience'
    }

    It 'Build-DesignCreditRow emits port design' {
        $row = Build-DesignCreditRow -MarkerPresent $true -IssueNumber 42
        $row.port | Should -Be 'design'
    }

    It 'Build-PlanCreditRow emits port plan' {
        $row = Build-PlanCreditRow -MarkerPresent $true -IssueNumber 42
        $row.port | Should -Be 'plan'
    }
}

# ---------------------------------------------------------------------------
# MarkerPresent $true → passed
# ---------------------------------------------------------------------------

Describe 'Pipeline-entry builders emit passed when marker is present' {

    It 'Build-ExperienceCreditRow emits passed when -MarkerPresent is true' {
        $row = Build-ExperienceCreditRow -MarkerPresent $true -IssueNumber 42
        $row.status | Should -Be 'passed'
    }

    It 'Build-DesignCreditRow emits passed when -MarkerPresent is true' {
        $row = Build-DesignCreditRow -MarkerPresent $true -IssueNumber 42
        $row.status | Should -Be 'passed'
    }

    It 'Build-PlanCreditRow emits passed when -MarkerPresent is true' {
        $row = Build-PlanCreditRow -MarkerPresent $true -IssueNumber 42
        $row.status | Should -Be 'passed'
    }
}

# ---------------------------------------------------------------------------
# MarkerPresent $false + AutoNaResult $true → not-applicable
# ---------------------------------------------------------------------------

Describe 'Pipeline-entry builders emit not-applicable when auto-N/A predicate fires' {

    It 'Build-ExperienceCreditRow emits not-applicable when -AutoNaResult is true' {
        $row = Build-ExperienceCreditRow -MarkerPresent $false -AutoNaResult $true -IssueNumber 42
        $row.status | Should -Be 'not-applicable'
    }

    It 'Build-DesignCreditRow emits not-applicable when -AutoNaResult is true' {
        $row = Build-DesignCreditRow -MarkerPresent $false -AutoNaResult $true -IssueNumber 42
        $row.status | Should -Be 'not-applicable'
    }

    It 'Build-PlanCreditRow emits not-applicable when -AutoNaResult is true' {
        $row = Build-PlanCreditRow -MarkerPresent $false -AutoNaResult $true -IssueNumber 42
        $row.status | Should -Be 'not-applicable'
    }
}

# ---------------------------------------------------------------------------
# AdapterName 'explicit-skip' → skipped
# ---------------------------------------------------------------------------

Describe 'Pipeline-entry builders emit skipped when explicit-skip adapter is used' {

    It 'Build-ExperienceCreditRow emits skipped when -AdapterName is explicit-skip' {
        $row = Build-ExperienceCreditRow -MarkerPresent $false -AdapterName 'explicit-skip' -IssueNumber 42
        $row.status | Should -Be 'skipped'
    }

    It 'Build-DesignCreditRow emits skipped when -AdapterName is explicit-skip' {
        $row = Build-DesignCreditRow -MarkerPresent $false -AdapterName 'explicit-skip' -IssueNumber 42
        $row.status | Should -Be 'skipped'
    }

    It 'Build-PlanCreditRow emits skipped when -AdapterName is explicit-skip' {
        $row = Build-PlanCreditRow -MarkerPresent $false -AdapterName 'explicit-skip' -IssueNumber 42
        $row.status | Should -Be 'skipped'
    }
}

# ---------------------------------------------------------------------------
# Builders return a hashtable, not $null
# ---------------------------------------------------------------------------

Describe 'Pipeline-entry builders always return a row object' {

    It 'Build-ExperienceCreditRow is not null' {
        $row = Build-ExperienceCreditRow -MarkerPresent $true -IssueNumber 1
        $row | Should -Not -BeNullOrEmpty
    }

    It 'Build-DesignCreditRow is not null' {
        $row = Build-DesignCreditRow -MarkerPresent $true -IssueNumber 1
        $row | Should -Not -BeNullOrEmpty
    }

    It 'Build-PlanCreditRow is not null' {
        $row = Build-PlanCreditRow -MarkerPresent $true -IssueNumber 1
        $row | Should -Not -BeNullOrEmpty
    }
}
