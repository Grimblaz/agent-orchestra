#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
        Contract tests for the explicit agents array in .claude-plugin/plugin.json.

.DESCRIPTION
        Locks the registration whitelist introduced in issue #468.

        The explicit agents array in .claude-plugin/plugin.json must:
            - be an array, not a string
            - contain exactly the lowercase Claude shell files from agents/*.md
            - contain no shared-body (.agent.md) files
            - be in set-equality with the discovery glob (no missing, no extra)
#>

Describe '.claude-plugin/plugin.json agents array contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:PluginJsonPath = Join-Path $script:RepoRoot '.claude-plugin/plugin.json'

        $script:PluginJson = Get-Content -Path $script:PluginJsonPath -Raw | ConvertFrom-Json

        $script:DiscoveredShells = @(
            Get-ChildItem -Path (Join-Path $script:RepoRoot 'agents') -Filter '*.md' -File |
                Where-Object { $_.Name -notlike '*.agent.md' } |
                ForEach-Object { './agents/' + $_.Name }
        )
    }

    It 'agents field is an array, not a string' {
        ($script:PluginJson.agents -is [array]) | Should -BeTrue -Because 'the agents field must be a JSON array so Claude registers only the listed shells'
    }

    It 'agents array contains no shared-body (.agent.md) entries' {
        $bodyEntries = @($script:PluginJson.agents | Where-Object { $_ -like '*.agent.md' })
        $bodyEntries | Should -BeNullOrEmpty -Because 'shared bodies must never appear in the registration whitelist — they are loaded by shells via Read, not dispatched directly'
    }

    It 'agents array is in set-equality with discovered lowercase Claude shells' {
        $declared = @($script:PluginJson.agents | Sort-Object)
        $discovered = @($script:DiscoveredShells | Sort-Object)

        $missing = @($discovered | Where-Object { $declared -cnotcontains $_ })
        $extra = @($declared | Where-Object { $discovered -cnotcontains $_ })

        $missing | Should -BeNullOrEmpty -Because "every Claude shell in agents/ must appear in the registration whitelist; missing: $($missing -join ', ')"
        $extra | Should -BeNullOrEmpty -Because "the registration whitelist must not reference shells that do not exist; extra: $($extra -join ', ')"
    }

    It 'agents array length matches discovered shell count' {
        $script:PluginJson.agents.Count | Should -Be $script:DiscoveredShells.Count -Because 'whitelist must have one entry per discovered Claude shell with no duplicates'
    }
}
