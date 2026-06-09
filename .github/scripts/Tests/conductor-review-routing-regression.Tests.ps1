#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#!
.SYNOPSIS
    Regression coverage for GitHub-review routing and response-posting behavior in Code-Conductor.

.DESCRIPTION
    Locks issue #403 follow-up behavior restoration: the shared Code-Conductor review loop
    must preserve GitHub review intake trigger routing and the extracted review reference
    must retain the proxy-review response-posting rule that existed before the refactor.
#>

Describe 'Code-Conductor review routing regression contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ConductorBodyPath = Join-Path $script:RepoRoot 'agents/Code-Conductor.agent.md'
        $script:ReviewReferencePath = Join-Path $script:RepoRoot 'skills/validation-methodology/references/review-reconciliation.md'

        $script:ConductorBody = (Get-Content -Path $script:ConductorBodyPath -Raw -ErrorAction Stop) -replace "`r`n?", "`n"
        $script:ReviewReference = (Get-Content -Path $script:ReviewReferencePath -Raw -ErrorAction Stop) -replace "`r`n?", "`n"
    }

    It 'keeps the shared Code-Conductor body explicit about GitHub-review trigger routing' {
        $script:ConductorBody | Should -Match '(?s)## Review Reconciliation Loop \(Mandatory\).*?github review.*?review github.*?cr review.*?GitHub intake path' -Because 'the shared review loop must keep the GitHub-review trigger path explicit after the thin-shell extraction'
    }

    It 'keeps the extracted review reference explicit about GitHub intake trigger routing' {
        $script:ReviewReference | Should -Match '(?s)### GitHub Review Intake & Judgment.*?`github review` / `review github` / `cr review`.*?skills/code-review-intake/SKILL\.md' -Because 'the extracted review reference must preserve the GitHub intake routing section'
        $script:ReviewReference | Should -Match '(?s)#### Short-Trigger Routing.*?`github review` / `review github` / `cr review`.*?run GitHub intake first' -Because 'the extracted review reference must preserve the short-trigger routing rule'
    }

    It 'keeps the extracted review reference explicit about GitHub response posting after proxy review' {
        $script:ReviewReference | Should -Match '(?s)#### GitHub Response Posting.*?review originated from GitHub.*?posts concise responses to GitHub review comments' -Because 'the extracted review reference must preserve the GitHub response-posting behavior that existed before the refactor'
    }
}
