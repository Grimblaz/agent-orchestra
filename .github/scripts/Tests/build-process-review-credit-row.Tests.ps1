#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Tests for Build-ProcessReviewCreditRow (issue #443, Step 3).
#
# Canonical emitter for the process-review frame port.  Status logic:
#   DefectsFound > 0   → passed  (trigger fired, process-review ran)
#   DefectsFound == 0  → not-applicable (trigger predicate false)
#   DefectsFound $null → skipped (CeGate data unavailable)

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

    $lib = Join-Path $script:RepoRoot '.github/scripts/lib/frame-credit-ledger-core.ps1'
    if (Test-Path $lib) { . $lib }
}

Describe 'Build-ProcessReviewCreditRow' {
    It 'port is always process-review' {
        $row = Build-ProcessReviewCreditRow -DefectsFound 1
        $row.port | Should -Be 'process-review'
    }

    Context 'DefectsFound > 0' {
        It 'returns status=passed' {
            $row = Build-ProcessReviewCreditRow -DefectsFound 3
            $row.status | Should -Be 'passed'
        }

        It 'evidence mentions defectsFound count' {
            $row = Build-ProcessReviewCreditRow -DefectsFound 3
            $row.evidence | Should -BeLike '*3*'
        }

        It 'accepts custom Evidence string' {
            $row = Build-ProcessReviewCreditRow -DefectsFound 2 -Evidence 'custom-evidence'
            $row.evidence | Should -Be 'custom-evidence'
        }
    }

    Context 'DefectsFound == 0' {
        It 'returns status=not-applicable' {
            $row = Build-ProcessReviewCreditRow -DefectsFound 0
            $row.status | Should -Be 'not-applicable'
        }

        It 'evidence mentions trigger predicate false' {
            $row = Build-ProcessReviewCreditRow -DefectsFound 0
            $row.evidence | Should -BeLike '*trigger predicate false*'
        }
    }

    Context 'DefectsFound is $null' {
        It 'returns status=skipped' {
            $row = Build-ProcessReviewCreditRow -DefectsFound $null
            $row.status | Should -Be 'skipped'
        }

        It 'evidence mentions data unavailable' {
            $row = Build-ProcessReviewCreditRow -DefectsFound $null
            $row.evidence | Should -BeLike '*not available*'
        }
    }

    It 'default AdapterName is standard' {
        $row = Build-ProcessReviewCreditRow -DefectsFound 1
        $row.adapter | Should -Be 'standard'
    }

    It 'accepts custom AdapterName' {
        $row = Build-ProcessReviewCreditRow -DefectsFound 1 -AdapterName 'custom'
        $row.adapter | Should -Be 'custom'
    }
}
