#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Contract tests for Code-Conductor review pipeline enforcement before PR completion.

.DESCRIPTION
    Locks issue #421 acceptance criteria: Code-Conductor must have a hard enforcement
    check ensuring prosecution, defense, and judgment all ran before PR creation.
    Partial review must not silently pass as full review.

    Verifies:
      - Code-Conductor stopping rules include a review pipeline completeness hard stop.
      - Code-Conductor Step 4 (PR creation) contains an explicit review pipeline gate.
      - Code-Conductor Review Reconciliation Loop documents review-state persistence to session memory.
      - review-reconciliation.md documents the Review Pipeline Completion Gate with state schema.
      - An abbreviated review path is explicitly documented and surfaced (not silently permitted).
#>

Describe 'Code-Conductor review pipeline enforcement contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ConductorBodyPath = Join-Path $script:RepoRoot 'agents\Code-Conductor.agent.md'
        $script:ReviewReferencePath = Join-Path $script:RepoRoot 'skills\validation-methodology\references\review-reconciliation.md'

        $script:ConductorBody = (Get-Content -Path $script:ConductorBodyPath -Raw -ErrorAction Stop) -replace "`r`n?", "`n"
        $script:ReviewReference = (Get-Content -Path $script:ReviewReferencePath -Raw -ErrorAction Stop) -replace "`r`n?", "`n"

        $script:StoppingRulesBlock = if ($script:ConductorBody -match '(?si)<stopping_rules>(.*?)</stopping_rules>') {
            $Matches[1]
        }
        else {
            ''
        }
    }

    It 'keeps the review pipeline completeness rule in the stopping_rules hard stop list' {
        $script:StoppingRulesBlock | Should -Not -BeNullOrEmpty -Because 'Code-Conductor must have a <stopping_rules> block'
        $script:StoppingRulesBlock | Should -Match '(?si)(prosecution|review cycle).{0,300}(defense).{0,300}(judgment|judge)' -Because 'stopping rules must name prosecution, defense, and judgment as required stages for review completeness'
        $script:StoppingRulesBlock | Should -Match '(?si)(missing|skip|absent).{0,200}(askQuestions|ask.{0,15}questions|protocol violation)' -Because 'stopping rules must require askQuestions or flag a protocol violation when review stages are missing'
    }

    It 'keeps an explicit review pipeline gate in Code-Conductor Step 4 before PR creation' {
        $script:ConductorBody | Should -Match '(?si)review pipeline gate.{0,600}(prosecution|defense|judgment).{0,200}(missing|absent|skipped).{0,200}askQuestions' -Because 'Step 4 must include an explicit review pipeline gate that blocks PR creation when stages are missing'
    }

    It 'keeps review-state persistence instructions in the Review Reconciliation Loop section' {
        $script:ConductorBody | Should -Match '(?si)## Review Reconciliation Loop.{0,2000}review-state.{0,200}session memory' -Because 'Code-Conductor must instruct the agent to write review-state to session memory after each stage'
        $script:ConductorBody | Should -Match '(?si)review-state-issue-\{ID\}' -Because 'Code-Conductor must name the canonical session-memory path for review-state'
        $script:ConductorBody | Should -Match '(?si)prosecution.{0,50}complete.{0,200}defense.{0,50}complete.{0,200}judgment.{0,50}complete' -Because 'Code-Conductor must name all three stage completion markers for review-state persistence'
    }

    It 'documents the Review Pipeline Completion Gate in review-reconciliation.md' {
        $script:ReviewReference | Should -Match '(?si)### Review Pipeline Completion Gate' -Because 'review-reconciliation.md must contain an explicit Review Pipeline Completion Gate section'
        $script:ReviewReference | Should -Match '(?si)(prosecution|3.{0,10}pass).{0,200}(defense).{0,200}(judgment)' -Because 'the gate must name all three required review stages'
        $script:ReviewReference | Should -Match '(?si)(MUST NOT proceed|do not proceed).{0,300}(PR creation|CE Gate|fix routing)' -Because 'the gate must explicitly block progression when a stage is absent'
    }

    It 'documents review-state schema in review-reconciliation.md with all three stage fields' {
        $script:ReviewReference | Should -Match '(?si)review-state-issue-\{ID\}' -Because 'review-reconciliation.md must name the canonical session-memory path for review-state'
        $script:ReviewReference | Should -Match '(?si)prosecution:.{0,10}complete' -Because 'review-state schema must include a prosecution field'
        $script:ReviewReference | Should -Match '(?si)defense:.{0,10}complete' -Because 'review-state schema must include a defense field'
        $script:ReviewReference | Should -Match '(?si)judgment:.{0,10}complete' -Because 'review-state schema must include a judgment field'
    }

    It 'documents an explicit abbreviated review path that surfaces skipped stages to the PR body' {
        $script:ReviewReference | Should -Match '(?si)abbreviated.{0,200}(PR body|review coverage)' -Because 'review-reconciliation.md must document that abbreviated paths require surfacing skipped stages in the PR body'
        $script:ConductorBody | Should -Match '(?si)(abbreviated|abbreviated review|review coverage).{0,300}(skipped|stages|missing)' -Because 'Code-Conductor must document the abbreviated review path and its PR body obligation'
    }
}
