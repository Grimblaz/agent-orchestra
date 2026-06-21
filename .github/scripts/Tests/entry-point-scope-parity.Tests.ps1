#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Parity test: skills/plugin-release-hygiene/SKILL.md § Entry-Point Scope vs
    Get-FVPluginEntryPointPatterns in frame-predicate-core.ps1 (#703 s4).

.DESCRIPTION
    Asserts that the canonical entry-point set in the skill prose exactly mirrors
    the function's output. Any drift causes CI to fail here rather than silently.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'lib' 'frame-predicate-core.ps1')
}

Describe 'Entry-point scope parity: SKILL.md vs Get-FVPluginEntryPointPatterns' {

    It 'skill list and function output share the same canonical entry-point set' {
        # --- Parse the skill's Entry-Point Scope section ---
        $skillPath = Join-Path $PSScriptRoot '..' '..' '..' 'skills' 'plugin-release-hygiene' 'SKILL.md'
        $skillContent = Get-Content -Path $skillPath -Raw

        # Extract the section between ## Entry-Point Scope and the next ## (or EOF)
        $sectionMatch = [regex]::Match($skillContent, '(?ms)^## Entry-Point Scope.*?(?=^##|\Z)')
        $sectionMatch.Success | Should -BeTrue -Because 'SKILL.md must have an ## Entry-Point Scope section'

        $section = $sectionMatch.Value

        # Extract backtick-quoted entries from bullet lines: - `path/**`
        $rawSkillEntries = [regex]::Matches($section, '(?m)^-\s+`([^`]+)`') |
            ForEach-Object { $_.Groups[1].Value }

        # Normalize: strip /**  /*  \* suffixes; convert \ to /
        $skillCanonical = $rawSkillEntries | ForEach-Object {
            $_ -replace '/\*\*$', '' -replace '/\*$', '' -replace '\\\*$', '' -replace '\\', '/'
        } | Sort-Object -Unique

        # --- Get function output and normalize ---
        $functionPatterns = Get-FVPluginEntryPointPatterns

        $functionCanonical = $functionPatterns | ForEach-Object {
            $_ -replace '/\*$', '' -replace '\\\*$', '' -replace '\\', '/'
        } | Sort-Object -Unique

        # --- Assert parity ---
        $skillCanonical | Should -BeExactly $functionCanonical -Because (
            "The skill's Entry-Point Scope section must mirror Get-FVPluginEntryPointPatterns exactly. " +
            "Skill canonical: [$($skillCanonical -join ', ')]. " +
            "Function canonical: [$($functionCanonical -join ', ')]."
        )
    }
}
