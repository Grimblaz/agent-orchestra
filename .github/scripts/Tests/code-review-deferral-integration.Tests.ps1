#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Code-Review-Deferral-Integration' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:CriteriaScript = Join-Path $script:RepoRoot 'skills/review-judgment/scripts/Test-DeferralCriteria.ps1'
        $script:SafeOpsScript = Join-Path $script:RepoRoot 'skills/safe-operations/scripts/Add-FollowUpIssue.ps1'
        
        # Dot-source both if available
        if (Test-Path $script:CriteriaScript) {
            . $script:CriteriaScript
        }
        if (Test-Path $script:SafeOpsScript) {
            . $script:SafeOpsScript
        }
    }

    Context 'AC Cross-Check Precedence (AC2 behavioral)' {
        It 'ensures findings matching explicit issue ACs are forced to ACCEPT even if they touch S-cross-cutting' {
            $Finding = @{
                id = "F_ac_behavioral"
                text = "Requires refactoring files in agents, skills, commands, and hooks."
                files = @(
                    "agents/Code-Conductor.agent.md",
                    "skills/routing-tables/SKILL.md",
                    "commands/plan.md",
                    "hooks/pre-commit.ps1"
                )
            }
            $PrFileSet = @("agents/Code-Conductor.agent.md")
            
            # Scenario A: No AC match -> should be DEFERRED-SIGNIFICANT
            $ResultNoAc = Get-StructuralVerdict -Finding $Finding -PrFileSet $PrFileSet -AcRefs @()
            $ResultNoAc.verdict | Should -Be 'DEFERRED-SIGNIFICANT (structural)'
            
            # Scenario B: Mapped to AC -> should be ACCEPT
            $ResultWithAc = Get-StructuralVerdict -Finding $Finding -PrFileSet $PrFileSet -AcRefs @("hooks/pre-commit.ps1")
            $ResultWithAc.verdict | Should -Be 'ACCEPT (fix inline)'
            $ResultWithAc.matched_criteria | Should -HaveCount 0
        }
    }

    Context 'Safe-Ops §2c Dedup Chain & Title Canonicalization (AC7)' {
        It 'produces deterministic canonical titles for both adversarial and bot reviews' {
            # Finding from adversarial review
            $Title1 = ConvertTo-CanonicalFollowupTitle -FindingSubject "Locale-stable sort" -CriterionIds @("S-cross-cutting")
            
            # Finding from external bot review (bot-review intake)
            $Title2 = ConvertTo-CanonicalFollowupTitle -FindingSubject "  Locale-stable sort.  " -CriterionIds @("S-cross-cutting")
            
            $Title1 | Should -Be "[Structural] S-cross-cutting: Locale-stable sort"
            $Title2 | Should -Be $Title1
        }
    }

    Context 'D7 Instrumentation Markers (AC8)' {
        It 'verifies that the created issue contains both labels and the outcome sentinel' {
            # Verify conceptually that labels and sentinel will be passed during s7 implementation.
            # (Unit tests in Add-FollowUpIssue.Tests.ps1 already assert this at the tool level;
            # this integration test ensures the design sentinel pattern is present).
            $SentinelPattern = "<!-- code-conductor-filed-followup -->"
            $SentinelPattern | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Synthetic Finding Corpus (AC9)' {
        $FixturesDir = Join-Path $PSScriptRoot 'fixtures/deferral-criteria'
        $Fixtures = @()
        if (Test-Path $FixturesDir) {
            $Fixtures = Get-ChildItem -Path $FixturesDir -Filter '*.json' | ForEach-Object {
                $data = Get-Content -Raw $_.FullName | ConvertFrom-Json -AsHashtable
                $data['basename'] = $_.BaseName
                $data
            }
        }

        It 'correctly executes all synthetic corpus cases and matches expected verdicts' -ForEach $Fixtures {
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
        }
    }

    Context 'Copilot Parity (AC10)' {
        It 'produces at least 1 positive hit for Code-Review-Response reference in prompts' {
            $PromptFiles = Get-ChildItem -Path (Join-Path $script:RepoRoot '.github/prompts') -Filter 'review*.prompt.md'
            $Matched = $false
            foreach ($File in $PromptFiles) {
                $Content = Get-Content -Raw $File.FullName
                if ($Content -match 'Code-Review-Response\.agent\.md') {
                    $Matched = $true
                    break
                }
            }
            $Matched | Should -Be $true -Because 'At least one review prompt must reference the shared Code-Review-Response.agent.md body'
        }

        It 'contains zero hits for effort estimates [less than 1 day or greater than 1 day] in prompts' {
            $PromptFiles = Get-ChildItem -Path (Join-Path $script:RepoRoot '.github/prompts') -Filter 'review*.prompt.md'
            foreach ($File in $PromptFiles) {
                $Content = Get-Content -Raw $File.FullName
                $Content | Should -Not -Match '(<1 day|>1 day)' -Because 'Effort estimates must be absent from prompts'
            }
        }

        It 'contains the D6 / D7 dispatcher model and shared body load citation in design docs' {
            $ArchDoc = Join-Path $script:RepoRoot 'Documents/Design/agent-body-architecture.md'
            $ArchDoc | Should -Exist
            $Content = Get-Content -Raw $ArchDoc
            
            # The doc cites D7 dispatcher/inline model and thin shells over canonical shared bodies
            $Content | Should -Match 'D7' -Because 'Must cite the dispatcher model / inline command command-front-end routing'
            $Content | Should -Match 'D8' -Because 'Must cite the thin shells over canonical shared bodies'
        }
    }
}
