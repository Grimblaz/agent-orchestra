#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Test-DeferralCriteria' {

    # Pre-load fixtures during Discovery phase for Pester 5 compatibility
    $FixturesDir = Join-Path $PSScriptRoot 'fixtures/deferral-criteria'
    $Fixtures = @()
    if (Test-Path $FixturesDir) {
        $Fixtures = Get-ChildItem -Path $FixturesDir -Filter '*.json' | ForEach-Object {
            $data = Get-Content -Raw $_.FullName | ConvertFrom-Json -AsHashtable
            $data['basename'] = $_.BaseName
            $data
        }
    }

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ScriptFile = Join-Path $script:RepoRoot 'skills/review-judgment/scripts/Test-DeferralCriteria.ps1'
        
        if (Test-Path $script:ScriptFile) {
            . $script:ScriptFile
        } else {
            # Stub functions for red phase
            function Test-SCriterionNewAbstraction { param($Finding, $PrFileSet) return @{ matched = $false } }
            function Test-SCriterionCrossCutting { param($Finding, $PrFileSet) return @{ matched = $false } }
            function Test-SCriterionDesignDecision { param($Finding, $PrFileSet) return @{ matched = $false } }
            function Test-SCriterionSchemaOrContract { param($Finding, $PrFileSet) return @{ matched = $false } }
            function Test-SCriterionDifferentSurface { param($Finding, $PrFileSet) return @{ matched = $false } }
            function Test-SCriterionMaintainerJudgment { param($Finding, $PrFileSet) return @{ matched = $false } }
            function Get-StructuralVerdict { param($Finding, $PrFileSet, $AcRefs) return @{ verdict = 'ACCEPT (fix inline)'; matched_criteria = @() } }
        }
    }

    Context 'Fixture Schema Unit Tests' {
        It 'correctly evaluates verdict for <basename>' -ForEach $Fixtures {
            $Fixture = $_
            $Finding = @{
                id = $Fixture['finding_id']
                text = $Fixture['finding_text']
                files = $Fixture['finding_file_set']
            }
            $PrFileSet = [string[]]$Fixture['pr_file_set']
            $AcRefs = [string[]]$Fixture['ac_refs']

            $Result = Get-StructuralVerdict -Finding $Finding -PrFileSet $PrFileSet -AcRefs $AcRefs

            $Result.verdict | Should -Be $Fixture['expected_verdict']
            foreach ($expected_id in $Fixture['expected_criterion_ids']) {
                $Result.matched_criteria | Should -Contain $expected_id
            }
        }
    }

    Context 'AC Cross-Check Precedence (AC2)' {
        It 'forces ACCEPT even when a structural criterion matches if the finding matches an AC reference' {
            # S-new-abstraction matches, but finding is mapped to an AC item
            $Finding = @{
                id = "F_ac_precedence"
                text = "Introduce a new skill skills/auth/SKILL.md."
                files = @("skills/auth/SKILL.md")
            }
            $PrFileSet = @("agents/Code-Conductor.agent.md")
            $AcRefs = @("skills/auth/SKILL.md") # Mapped to AC

            $Result = Get-StructuralVerdict -Finding $Finding -PrFileSet $PrFileSet -AcRefs $AcRefs

            $Result.verdict | Should -Be 'ACCEPT (fix inline)'
            $Result.matched_criteria | Should -HaveCount 0
        }
    }

    Context 'S-cross-cutting weightings (D1)' {
        It 'does not count docs-only and test-only changes toward the module count' {
            $Finding = @{
                id = "F_cross_cut_weight"
                text = "Touch files across multiple directories."
                files = @(
                    "Documents/Design/review.md",            # docs-only
                    "skills/auth/Tests/SKILL.Tests.ps1",      # test-only
                    "hooks/pre-commit.ps1",                  # module 1: hooks
                    "memory/history.json"                    # module 2: memory
                )
            }
            $PrFileSet = @("agents/Code-Conductor.agent.md")
            $AcRefs = @()

            # Evaluating structural criteria directly or via verdict
            $Result = Test-SCriterionCrossCutting -Finding $Finding -PrFileSet $PrFileSet
            $Result.matched | Should -Be $false # only 2 valid modules, should not match
        }
    }
}
