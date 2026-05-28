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
        }
        else {
            # Stub functions for red phase
            function Test-SCriterionNewAbstraction { param($Finding, $PrFileSet, $RepoRoot) return @{ matched = $false } }
            function Test-SCriterionCrossCutting { param($Finding, $PrFileSet, $RepoRoot) return @{ matched = $false } }
            function Test-SCriterionDesignDecision { param($Finding, $PrFileSet, $RepoRoot) return @{ matched = $false } }
            function Test-SCriterionSchemaOrContract { param($Finding, $PrFileSet, $RepoRoot) return @{ matched = $false } }
            function Test-SCriterionDifferentSurface { param($Finding, $PrFileSet, $RepoRoot) return @{ matched = $false } }
            function Test-SCriterionMaintainerJudgment { param($Finding, $PrFileSet, $RepoRoot) return @{ matched = $false } }
            function Get-StructuralVerdict { param($Finding, $PrFileSet, $AcRefs, $RepoRoot) return @{ verdict = 'ACCEPT (fix inline)'; matched_criteria = @() } }
        }
    }

    Context 'Fixture Schema Unit Tests' {

        # M17: tighten per-fixture assertion. The previous test used `Should -Contain` per
        # expected ID, which admits supersets — a fixture could match additional structural
        # criteria undetected. Switch to a sort-and-join exact-set comparison so the
        # `matched_criteria` set is contract-grade observable.
        It 'correctly evaluates verdict and exact matched_criteria set for <basename>' -ForEach $Fixtures {
            $Fixture = $_
            $Finding = @{
                id    = $Fixture['finding_id']
                text  = $Fixture['finding_text']
                files = $Fixture['finding_file_set']
            }
            $PrFileSet = [string[]]$Fixture['pr_file_set']
            $AcRefs = [string[]]$Fixture['ac_refs']

            $Result = Get-StructuralVerdict -Finding $Finding -PrFileSet $PrFileSet -AcRefs $AcRefs

            $Result.verdict | Should -Be $Fixture['expected_verdict']

            $expectedSet = @()
            if ($Fixture['expected_criterion_ids']) {
                $expectedSet = @($Fixture['expected_criterion_ids'])
            }
            $observed = @()
            if ($Result.matched_criteria) {
                $observed = @($Result.matched_criteria)
            }

            $observedJoined = ($observed | Sort-Object) -join ','
            $expectedJoined = ($expectedSet | Sort-Object) -join ','

            $observedJoined | Should -Be $expectedJoined -Because "matched_criteria for $($Fixture['basename']) must be the exact expected set (no supersets)"
        }
    }

    Context 'AC Cross-Check Precedence (AC2)' {
        It 'forces ACCEPT even when a structural criterion matches if the finding maps to an AC reference' {
            # S-new-abstraction matches (text uses the verb-anchored pattern), but finding
            # is mapped to an AC item -> verdict overrides to ACCEPT.
            $Finding = @{
                id    = "F_ac_precedence"
                text  = "Introduce a new skill skills/auth/SKILL.md."
                files = @("skills/auth/SKILL.md")
            }
            $PrFileSet = @("agents/Code-Conductor.agent.md")
            $AcRefs = @("skills/auth/SKILL.md") # Mapped to AC

            $Result = Get-StructuralVerdict -Finding $Finding -PrFileSet $PrFileSet -AcRefs $AcRefs

            $Result.verdict | Should -Be 'ACCEPT (fix inline)'
            # M12: AC precedence override preserves matched_criteria for D7 calibration —
            # this finding tripped both S-new-abstraction (verb-anchored prose) and
            # S-different-surface (finding files disjoint from PR files), and both must
            # remain visible after the override.
            $Result.ac_precedence | Should -Be $true
            $Result.matched_criteria | Should -Contain 'S-new-abstraction'
            $Result.matched_criteria | Should -Contain 'S-different-surface'
        }
    }

    Context 'S-cross-cutting weightings (D1)' {
        It 'does not count docs-only and test-only changes toward the module count' {
            $Finding = @{
                id    = "F_cross_cut_weight"
                text  = "Touch files across multiple directories."
                files = @(
                    "Documents/Design/review.md", # docs-only
                    "skills/auth/Tests/SKILL.Tests.ps1", # test-only
                    "hooks/pre-commit.ps1", # module 1: hooks
                    "memory/history.json"                    # module 2: memory
                )
            }
            $PrFileSet = @("agents/Code-Conductor.agent.md")
            $AcRefs = @()

            # Evaluating structural criteria directly or via verdict
            $Result = Test-SCriterionCrossCutting -Finding $Finding -PrFileSet $PrFileSet -RepoRoot $script:RepoRoot
            $Result.matched | Should -Be $false # only 2 valid modules, should not match
        }
    }

    Context 'M8 / M9 module-mapping invariants (root and infra)' {
        # M8: root-level files become a virtual <root> module.
        # M9: dotfile-prefixed top-level dirs collapse into a virtual <infra> module.
        It 'M8 + M9: 4 distinct modules across <root>, <infra>, agents, and skills trips S-cross-cutting' {
            $Finding = @{
                id    = "F_m8_m9"
                text  = "Touches root file, dotfile-dir, agents, and skills."
                files = @(
                    'README.md', # <root>
                    '.github/workflows/ci.yml', # <infra>
                    'agents/Code-Conductor.agent.md', # agents
                    'skills/routing-tables/SKILL.md'   # skills
                )
            }
            # README.md is docs-only by extension+location (no agents/skills/commands/hooks
            # prefix), so it is filtered out by the docs-only rule. To exercise M8 we use a
            # root-level non-doc file too. Build a second-shape finding instead.
            $Finding2 = @{
                id    = "F_m8_m9b"
                text  = "Touches a root non-doc, dotfile-dir, agents, and commands."
                files = @(
                    'plugin.json', # <root>, non-doc
                    '.github/workflows/ci.yml', # <infra>
                    'agents/Code-Conductor.agent.md', # agents
                    'commands/plan.md'                 # commands
                )
            }
            $Result = Test-SCriterionCrossCutting -Finding $Finding2 -PrFileSet @('agents/Code-Conductor.agent.md') -RepoRoot $script:RepoRoot
            $Result.matched | Should -Be $true -Because 'M8 <root> + M9 <infra> + agents + commands = 4 modules'
        }
    }
}
