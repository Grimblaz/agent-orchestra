#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Parity tests for specialist agent body wiring (issue #442, Step 12).
#
# (a) Each specialist agent references skills/frame-credit-emission/SKILL.md exactly once.
# (b) Each agent's terminal step section contains the Build-{Port}CreditRow invocation token.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
}

Describe 'Specialist agent references frame-credit-emission skill (Step 12a)' -ForEach @(
    @{ Name = 'Code-Smith';          AgentPath = 'agents/Code-Smith.agent.md' }
    @{ Name = 'Test-Writer';         AgentPath = 'agents/Test-Writer.agent.md' }
    @{ Name = 'Refactor-Specialist'; AgentPath = 'agents/Refactor-Specialist.agent.md' }
    @{ Name = 'Doc-Keeper';          AgentPath = 'agents/Doc-Keeper.agent.md' }
) {
    param($Name, $AgentPath)

    BeforeAll {
        $fullPath = Join-Path $script:RepoRoot $AgentPath
        $script:Content = if (Test-Path $fullPath) { Get-Content -Raw $fullPath } else { '' }
    }

    It "$Name agent references skills/frame-credit-emission/SKILL.md" {
        $script:Content | Should -Match ([regex]::Escape('skills/frame-credit-emission/SKILL.md')) `
            -Because "$Name must load the frame-credit-emission skill at its terminal step"
    }

    It "$Name agent references frame-credit-emission exactly once" {
        $count = ([regex]::Matches($script:Content, [regex]::Escape('skills/frame-credit-emission/SKILL.md'))).Count
        $count | Should -Be 1 -Because "$Name should reference the skill once"
    }
}

Describe 'Specialist agent contains Build-*CreditRow invocation (Step 12b)' -ForEach @(
    @{ Name = 'Code-Smith';          AgentPath = 'agents/Code-Smith.agent.md';          BuilderToken = 'Build-ImplementCodeCreditRow' }
    @{ Name = 'Test-Writer';         AgentPath = 'agents/Test-Writer.agent.md';         BuilderToken = 'Build-ImplementTestCreditRow' }
    @{ Name = 'Refactor-Specialist'; AgentPath = 'agents/Refactor-Specialist.agent.md'; BuilderToken = 'Build-ImplementRefactorCreditRow' }
    @{ Name = 'Doc-Keeper';          AgentPath = 'agents/Doc-Keeper.agent.md';          BuilderToken = 'Build-ImplementDocsCreditRow' }
) {
    param($Name, $AgentPath, $BuilderToken)

    BeforeAll {
        $fullPath = Join-Path $script:RepoRoot $AgentPath
        $script:Content = if (Test-Path $fullPath) { Get-Content -Raw $fullPath } else { '' }
    }

    It "$Name contains the '$BuilderToken' invocation token" {
        $script:Content | Should -Match ([regex]::Escape($BuilderToken)) `
            -Because "$Name must instruct the agent to call '$BuilderToken' at its terminal step"
    }
}
