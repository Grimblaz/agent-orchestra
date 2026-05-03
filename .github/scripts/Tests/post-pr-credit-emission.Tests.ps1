#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# TDD tests for Build-PostPrCreditRow builder (issue #442, Step 4d).
#
# Builder accepts -ChecklistOutcomes hashtable with keys:
#   archive, docs, version, releaseTag
#
# Status logic:
#   - All keys true → status: passed
#   - Any key false → status: failed, failing key in evidence
#   - ChecklistOutcomes absent/empty → status: skipped

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

    $script:LedgerCoreLib = Join-Path $script:RepoRoot '.github/scripts/lib/frame-credit-ledger-core.ps1'
    if (Test-Path $script:LedgerCoreLib) {
        . $script:LedgerCoreLib
    }
}

# ---------------------------------------------------------------------------
# port naming
# ---------------------------------------------------------------------------

Describe 'Build-PostPrCreditRow port naming' {

    It 'emits port post-pr' {
        $row = Build-PostPrCreditRow -ChecklistOutcomes @{ archive = $true; docs = $true; version = $true; releaseTag = $true }
        $row.port | Should -Be 'post-pr'
    }
}

# ---------------------------------------------------------------------------
# all-true → passed
# ---------------------------------------------------------------------------

Describe 'Build-PostPrCreditRow emits passed when all checklist items are true' {

    It 'emits passed when all four keys are true' {
        $row = Build-PostPrCreditRow -ChecklistOutcomes @{
            archive    = $true
            docs       = $true
            version    = $true
            releaseTag = $true
        }
        $row.status | Should -Be 'passed'
    }
}

# ---------------------------------------------------------------------------
# any-false → failed with failing key in evidence
# ---------------------------------------------------------------------------

Describe 'Build-PostPrCreditRow emits failed when any checklist item is false' {

    It 'emits failed when archive is false' {
        $row = Build-PostPrCreditRow -ChecklistOutcomes @{
            archive    = $false
            docs       = $true
            version    = $true
            releaseTag = $true
        }
        $row.status | Should -Be 'failed'
        $row.evidence | Should -Match 'archive'
    }

    It 'emits failed when docs is false' {
        $row = Build-PostPrCreditRow -ChecklistOutcomes @{
            archive    = $true
            docs       = $false
            version    = $true
            releaseTag = $true
        }
        $row.status | Should -Be 'failed'
        $row.evidence | Should -Match 'docs'
    }

    It 'emits failed when version is false' {
        $row = Build-PostPrCreditRow -ChecklistOutcomes @{
            archive    = $true
            docs       = $true
            version    = $false
            releaseTag = $true
        }
        $row.status | Should -Be 'failed'
        $row.evidence | Should -Match 'version'
    }

    It 'emits failed when releaseTag is false' {
        $row = Build-PostPrCreditRow -ChecklistOutcomes @{
            archive    = $true
            docs       = $true
            version    = $true
            releaseTag = $false
        }
        $row.status | Should -Be 'failed'
        $row.evidence | Should -Match 'releaseTag'
    }

    It 'emits failed when multiple keys are false — lists all failing keys in evidence' {
        $row = Build-PostPrCreditRow -ChecklistOutcomes @{
            archive    = $false
            docs       = $false
            version    = $true
            releaseTag = $true
        }
        $row.status | Should -Be 'failed'
        $row.evidence | Should -Match 'archive'
        $row.evidence | Should -Match 'docs'
    }
}

# ---------------------------------------------------------------------------
# string value acceptance: 'passed' and 'skipped' per-key are non-failure
# ---------------------------------------------------------------------------

Describe "Build-PostPrCreditRow: string values 'passed' and 'skipped' are treated as non-failure" {

    It "emits passed when all four keys are the string 'passed'" {
        $row = Build-PostPrCreditRow -ChecklistOutcomes @{
            archive    = 'passed'
            docs       = 'passed'
            version    = 'passed'
            releaseTag = 'passed'
        }
        $row.status | Should -Be 'passed'
    }

    It "emits passed when keys mix bool `$true` and string 'passed'" {
        $row = Build-PostPrCreditRow -ChecklistOutcomes @{
            archive    = $true
            docs       = 'passed'
            version    = $true
            releaseTag = 'passed'
        }
        $row.status | Should -Be 'passed'
    }

    It "emits passed when one key is 'skipped' and the rest are true — skipped is not a failure" {
        $row = Build-PostPrCreditRow -ChecklistOutcomes @{
            archive    = $true
            docs       = $true
            version    = 'skipped'
            releaseTag = $true
        }
        $row.status | Should -Be 'passed'
    }

    It "emits failed when a key is the string 'failed'" {
        $row = Build-PostPrCreditRow -ChecklistOutcomes @{
            archive    = $true
            docs       = 'failed'
            version    = $true
            releaseTag = $true
        }
        $row.status | Should -Be 'failed'
        $row.evidence | Should -Match 'docs'
    }
}

# ---------------------------------------------------------------------------
# absent/empty ChecklistOutcomes → skipped
# ---------------------------------------------------------------------------

Describe 'Build-PostPrCreditRow emits skipped when ChecklistOutcomes is absent or empty' {

    It 'emits skipped when ChecklistOutcomes is not provided' {
        $row = Build-PostPrCreditRow
        $row.status | Should -Be 'skipped'
    }

    It 'emits skipped when ChecklistOutcomes is an empty hashtable' {
        $row = Build-PostPrCreditRow -ChecklistOutcomes @{}
        $row.status | Should -Be 'skipped'
    }
}
