#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Regression coverage for fresh hub-mode planning in the Claude /orchestrate path.

.DESCRIPTION
    Locks the issue #403 follow-up fix: /orchestrate must not require an existing
    plan marker before dispatch, and the shared Code-Conductor body must allow
    hub mode to continue into Issue-Planner when no plan exists yet.
#>

Describe 'Code-Conductor hub-mode planning regression contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:OrchestrateCommandPath = Join-Path $script:RepoRoot 'commands/orchestrate.md'
        $script:ConductorBodyPath = Join-Path $script:RepoRoot 'agents/Code-Conductor.agent.md'

        $script:OrchestrateCommand = (Get-Content -Path $script:OrchestrateCommandPath -Raw -ErrorAction Stop) -replace "`r`n?", "`n"
        $script:ConductorBody = (Get-Content -Path $script:ConductorBodyPath -Raw -ErrorAction Stop) -replace "`r`n?", "`n"
    }

    It 'keeps /orchestrate from blocking on a missing plan marker before dispatch' {
        $script:OrchestrateCommand | Should -Not -Match '(?is)missing its `<!-- plan-issue-\{ID\} -->` marker.*?/plan first|continue only after a plan exists' -Because 'the Claude /orchestrate command must allow fresh hub-mode entry instead of forcing a prior /plan run'
        $script:OrchestrateCommand | Should -Match '(?is)missing its `<!-- plan-issue-\{ID\} -->` marker.*?do not block dispatch.*?Issue-Planner itself' -Because 'the Claude /orchestrate command must carry missing-plan state into Code-Conductor so hub mode can create the plan in-session'
    }

    It 'keeps /orchestrate smart-resume markers tied to the owning SMC rows' {
        $script:OrchestrateCommand | Should -Match '(?is)smart-resume markers.{0,360}SMC-08' -Because 'durable phase-completion marker handling must stay tied to SMC-08'
        $script:OrchestrateCommand | Should -Match '(?is)<!-- plan-issue-\{ID\} -->.{0,420}SMC-01|SMC-01.{0,420}<!-- plan-issue-\{ID\} -->' -Because 'the plan-marker resume path must stay tied to SMC-01'
        $script:OrchestrateCommand | Should -Match '(?is)<!-- design-issue-\{ID\} -->.{0,520}SMC-03|SMC-03.{0,520}<!-- design-issue-\{ID\} -->' -Because 'the design fallback and D9 suppression path must stay tied to SMC-03'
    }

    It 'keeps the shared Code-Conductor body explicit that hub mode may create the plan in-session' {
        $script:ConductorBody | Should -Match '(?is)If no plan exists.*?In hub mode.*?continue to scope classification.*?call Issue-Planner.*?create the plan in-session' -Because 'fresh hub-mode execution must continue into Issue-Planner when no durable plan exists yet'
        $script:ConductorBody | Should -Match '(?is)Outside hub mode.*?plan-dependent execution path without a plan' -Because 'plan-dependent non-hub flows must still fail closed when the expected approved plan is missing'
    }
}
