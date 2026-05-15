#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Documentation-scope coverage for natural-language intent routing.

.DESCRIPTION
    Locks issue #567 Step 1 D3 scope documentation only. Runtime scope behavior belongs
    to CE Gate evidence, so this file asserts only the CLAUDE.md Intent Routing section.
#>

Describe 'Natural-language intent routing scope documentation' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ClaudeMdPath = Join-Path $script:RepoRoot 'CLAUDE.md'
        $script:ClaudeMd = Get-Content -Path $script:ClaudeMdPath -Raw

        $sectionMatch = [regex]::Match($script:ClaudeMd, '(?ms)^## Intent Routing\r?\n(?<section>.*?)(?=^## |\z)')
        $script:HasIntentRoutingSection = $sectionMatch.Success
        $script:IntentRoutingSection = if ($sectionMatch.Success) { $sectionMatch.Groups['section'].Value } else { '' }
    }

    It 'documents the D3 detection scope in the CLAUDE.md Intent Routing section' {
        $script:HasIntentRoutingSection | Should -BeTrue -Because 'CLAUDE.md must have a top-level ## Intent Routing section before runtime CE Gate validation'
        $script:IntentRoutingSection | Should -Match 'active slash-command turn'
        $script:IntentRoutingSection | Should -Match 'subagent dispatch'
    }
}
