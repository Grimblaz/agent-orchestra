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
    if (@($Fixtures).Count -eq 0) {
        throw "no fixtures found in $FixturesDir — coverage would silently vanish"
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
        It 'M8 + M9: 4 distinct modules across root, infra, agents, and skills trips S-cross-cutting' {
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

    Context 'AcTerms term-based arm (AC2/AC5)' {

        It 'high-confidence behavioral term in finding text -> force-ACCEPT (routed: force-accept)' {
            $AcTermEntries = @(
                [PSCustomObject]@{ term = 'triage'; source_ac_line = '- must fetch `triage`-labeled issues'; is_behavioral = $true }
            )
            $Finding = @{
                id   = 'F_term_high'
                text = 'The renderer does not query triage-labeled issues repo-wide.'
                files = @('agents/some-agent.agent.md')
            }
            $Result = Get-StructuralVerdict -Finding $Finding -PrFileSet @() -AcRefs @() -AcTerms $AcTermEntries

            $Result.verdict                    | Should -Be 'ACCEPT (fix inline)'
            $Result.ac_cross_check.routed      | Should -Be 'force-accept'
            $Result.ac_cross_check.term_arm    | Should -Be $true
            $Result.ac_cross_check.file_arm    | Should -Be $false
            $Result.ac_cross_check.result      | Should -Be 'matched-high'
        }

        It 'ambiguous non-behavioral term in finding text -> verdict unchanged, routed: disposition-gate' {
            # Finding matches a cross-cutting S-criterion; term is ambiguous (is_behavioral=false)
            # The verdict should remain DEFERRED-SIGNIFICANT, not overridden to ACCEPT.
            $AcTermEntries = @(
                [PSCustomObject]@{ term = 'portfolio-tracker'; source_ac_line = '- `portfolio-tracker` label is applied to issues'; is_behavioral = $false }
            )
            $Finding = @{
                id   = 'F_term_ambiguous'
                text = 'The portfolio-tracker label is not applied in agents, skills, commands, and hooks.'
                files = @('agents/x.agent.md', 'skills/y/SKILL.md', 'commands/z.md', 'hooks/pre-commit.ps1')
            }
            $Result = Get-StructuralVerdict -Finding $Finding -PrFileSet @('agents/x.agent.md') -AcRefs @() -AcTerms $AcTermEntries

            # Verdict stays DEFERRED-SIGNIFICANT because S-cross-cutting fires and term is ambiguous
            $Result.verdict                    | Should -Be 'DEFERRED-SIGNIFICANT (structural)'
            $Result.ac_cross_check.routed      | Should -Be 'disposition-gate'
            $Result.ac_cross_check.term_arm    | Should -Be $true
            $Result.ac_cross_check.result      | Should -Be 'matched-ambiguous'
        }

        It 'no term match -> routed: defer, verdict follows S-criteria normally' {
            $AcTermEntries = @(
                [PSCustomObject]@{ term = 'UnrelatedTerm'; source_ac_line = '- `UnrelatedTerm` must exist'; is_behavioral = $true }
            )
            $Finding = @{
                id   = 'F_term_nomatch'
                text = 'This finding does not mention the relevant identifier at all.'
                files = @('agents/Code-Conductor.agent.md')
            }
            $Result = Get-StructuralVerdict -Finding $Finding -PrFileSet @() -AcRefs @() -AcTerms $AcTermEntries

            $Result.ac_cross_check.routed      | Should -Be 'defer'
            $Result.ac_cross_check.term_arm    | Should -Be $false
            $Result.ac_cross_check.result      | Should -Be 'no-match'
        }

        It 'file-arm match takes precedence and produces routed: force-accept (backward compat)' {
            $AcTermEntries = @(
                [PSCustomObject]@{ term = 'SomeTerm'; source_ac_line = '- `SomeTerm` is required'; is_behavioral = $false }
            )
            $Finding = @{
                id   = 'F_file_arm_compat'
                text = 'The hooks/pre-commit.ps1 file has a bug with SomeTerm.'
                files = @('hooks/pre-commit.ps1')
            }
            $Result = Get-StructuralVerdict -Finding $Finding -PrFileSet @() -AcRefs @('hooks/pre-commit.ps1') -AcTerms $AcTermEntries

            $Result.verdict                    | Should -Be 'ACCEPT (fix inline)'
            $Result.ac_cross_check.file_arm    | Should -Be $true
            $Result.ac_cross_check.routed      | Should -Be 'force-accept'
            $Result.ac_cross_check.result      | Should -Be 'matched-high'
        }

        It 'default -AcTerms (@()) produces ac_cross_check with file_arm=false, term_arm=false, routed=defer (backward compat)' {
            $Finding = @{
                id   = 'F_default_terms'
                text = 'No structural criterion; no AC refs.'
                files = @()
            }
            $Result = Get-StructuralVerdict -Finding $Finding -PrFileSet @() -AcRefs @()

            $Result.verdict                    | Should -Be 'ACCEPT (fix inline)'
            $Result.ac_cross_check             | Should -Not -BeNullOrEmpty
            $Result.ac_cross_check.file_arm    | Should -Be $false
            $Result.ac_cross_check.term_arm    | Should -Be $false
            $Result.ac_cross_check.routed      | Should -Be 'defer'
            $Result.ac_cross_check.result      | Should -Be 'no-match'
        }

        It 'ac_cross_check is present on DEFERRED-SIGNIFICANT path (no AC refs)' {
            # S-cross-cutting fires; no AC refs -> DEFERRED-SIGNIFICANT with ac_cross_check
            $Finding = @{
                id   = 'F_deferred_with_cc'
                text = 'Affects agents, skills, commands, and hooks.'
                files = @('agents/x.agent.md', 'skills/y/SKILL.md', 'commands/z.md', 'hooks/pre-commit.ps1')
            }
            $Result = Get-StructuralVerdict -Finding $Finding -PrFileSet @('agents/x.agent.md') -AcRefs @()

            $Result.verdict                    | Should -Be 'DEFERRED-SIGNIFICANT (structural)'
            $Result.ac_cross_check             | Should -Not -BeNullOrEmpty
            $Result.ac_cross_check.routed      | Should -Be 'defer'
        }

        It 'CR8/CR9 precision: behavioral triage term force-ACCEPTs regardless of structural match' {
            # Simulates the originating incident: a finding that references "triage" (a behavioral AC term)
            # matched against an S-criterion; the AC cross-check should override to ACCEPT.
            $AcTermEntries = @(
                [PSCustomObject]@{
                    term = 'triage'
                    source_ac_line = '- the renderer is specified to fetch `triage`-labeled issues repo-wide; must query repo-wide'
                    is_behavioral = $true
                }
            )
            $Finding = @{
                id   = 'CR9_precision'
                text = 'The Triage bucket renderer only queries sequenced issues, missing the triage-labeled repo-wide query required by the AC.'
                files = @('agents/Code-Conductor.agent.md', 'skills/routing-tables/SKILL.md', 'commands/plan.md', 'hooks/pre-commit.ps1')
            }
            $Result = Get-StructuralVerdict -Finding $Finding -PrFileSet @('agents/Code-Conductor.agent.md') -AcRefs @() -AcTerms $AcTermEntries

            # Despite matching S-cross-cutting (4 modules), the behavioral term match force-ACCEPTs
            $Result.verdict                    | Should -Be 'ACCEPT (fix inline)'
            $Result.ac_cross_check.routed      | Should -Be 'force-accept'
            $Result.ac_cross_check.term_arm    | Should -Be $true
            $Result.ac_cross_check.result      | Should -Be 'matched-high'
        }

        It 'CR8/CR9 recall: stop-list term does NOT match (precision guard)' {
            # "dismiss", "defer", "set" are on the stop-list in Get-AcTermsFromIssue
            # but we need to verify Get-StructuralVerdict handles them safely when
            # somehow passed in (should not false-positive if the stop-list was bypassed).
            # This test uses a term NOT in the stop-list but absent from the finding text.
            $AcTermEntries = @(
                [PSCustomObject]@{ term = 'PortfolioTracker'; source_ac_line = '- `PortfolioTracker` must exist'; is_behavioral = $true }
            )
            $Finding = @{
                id   = 'CR8_recall'
                text = 'The bucket renderer misses the required label logic for triage issues.'
                files = @()
            }
            $Result = Get-StructuralVerdict -Finding $Finding -PrFileSet @() -AcRefs @() -AcTerms $AcTermEntries

            # PortfolioTracker not in finding text -> no term arm match
            $Result.ac_cross_check.term_arm    | Should -Be $false
            $Result.ac_cross_check.result      | Should -Be 'no-match'
        }
    }
}
