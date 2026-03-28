#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Contract tests for guidance complexity ceiling wiring.

.DESCRIPTION
    Locks the issue #211 guidance complexity contract across:
      - .github/agents/Process-Review.agent.md (§4.7, §4.8, §4.9)
      - .github/config/guidance-complexity.json
      - .github/scripts/measure-guidance-complexity.ps1
      - Documents/Design/guidance-complexity.md

        The files must satisfy:
            - §4.7 invokes measure-guidance-complexity.ps1 and makes output available to §4.9
            - §4.9 references compression_required and agents_over_ceiling, scoped to agent-prompt proposals
            - §4.8 and §4.9 share consistent trigger scope: both skip only CE Gate Track 2, both run during calibration-only mode
            - .github/config/guidance-complexity.json exists with a valid schema (version + default_ceiling.max_directives)
            - .github/scripts/measure-guidance-complexity.ps1 exists
            - Documents/Design/guidance-complexity.md documents D1, D2, and the compression concept

        These tests lock the landed issue #211 wiring so future edits to Process-Review, the config, or the
        design doc do not silently drift from the complexity-ceiling contract.
#>

Describe 'guidance complexity ceiling contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ProcessReview = Join-Path $script:RepoRoot '.github/agents/Process-Review.agent.md'
        $script:ConfigPath = Join-Path $script:RepoRoot '.github/config/guidance-complexity.json'
        $script:ScriptPath = Join-Path $script:RepoRoot '.github/scripts/measure-guidance-complexity.ps1'
        $script:DesignDoc = Join-Path $script:RepoRoot 'Documents/Design/guidance-complexity.md'

        $script:ProcessReviewContent = Get-Content -Path $script:ProcessReview -Raw

        # Extract individual sections: from heading until the next same-level heading or end of file
        $script:Section47 = [regex]::Match($script:ProcessReviewContent, '(?is)### 4\.7\b.*?(?=### 4\.\d|\Z)').Value
        $script:Section48 = [regex]::Match($script:ProcessReviewContent, '(?is)### 4\.8\b.*?(?=### 4\.\d|\Z)').Value
        $script:Section49 = [regex]::Match($script:ProcessReviewContent, '(?is)### 4\.9\b.*?(?=### 4\.\d|\Z)').Value

        # Extract the single "When to run" line from each section for scope-consistency checks
        $script:WhenToRun48 = [regex]::Match($script:Section48, '(?m)^\*\*When to run\*\*.*$').Value
        $script:WhenToRun49 = [regex]::Match($script:Section49, '(?m)^\*\*When to run\*\*.*$').Value
    }

    It 'requires Process-Review §4.7 to reference and invoke measure-guidance-complexity.ps1' {
        $script:Section47 | Should -Not -BeNullOrEmpty -Because '§4.7 section must exist in Process-Review'
        $script:Section47 | Should -Match 'measure-guidance-complexity\.ps1' `
            -Because '§4.7 must reference the guidance complexity measurement script'
        $script:Section47 | Should -Match '(?is)(pwsh|run|invoke|File).{0,120}measure-guidance-complexity\.ps1' `
            -Because '§4.7 must show context indicating the script is run or invoked (not just mentioned)'
    }

    It 'requires Process-Review §4.9 to reference compression_required and agents_over_ceiling scoped to agent-prompt proposals' {
        $script:Section49 | Should -Not -BeNullOrEmpty -Because '§4.9 section must exist in Process-Review'
        $script:Section49 | Should -Match 'compression_required' `
            -Because '§4.9 must reference the compression_required field that tags ceiling-exceeded guardrail proposals'
        $script:Section49 | Should -Match 'agents_over_ceiling' `
            -Because '§4.9 must read agents_over_ceiling from the complexity script output produced in §4.7'
        $script:Section49 | Should -Match 'agent-prompt' `
            -Because '§4.9 ceiling check must be scoped to agent-prompt proposals only (instruction/skill/plan-template proposals skip this check)'
    }

    It 'requires §4.8 When-to-run to include calibration-only mode as an inclusive clause, not a skip condition' {
        $script:WhenToRun48 | Should -Not -BeNullOrEmpty `
            -Because '§4.8 must have a When to run line'
        $script:WhenToRun48 | Should -Match 'calibration-only mode' `
            -Because '§4.8 must treat calibration-only mode as inclusive (run during it) rather than a skip condition'
        $script:WhenToRun48 | Should -Not -Match 'CE Gate Track 2,\s*Calibration-only' `
            -Because '§4.8 must no longer list Calibration-only as a comma-separated skip condition alongside CE Gate Track 2 — old skip-list text removed by issue #211'
        $script:WhenToRun48 | Should -Match 'CE Gate Track 2' `
            -Because '§4.8 must still identify CE Gate Track 2 subagent mode as the skip condition'
    }

    It 'requires §4.8 and §4.9 When-to-run to share CE Gate Track 2 as the consistent and exclusive skip condition' {
        $script:WhenToRun48 | Should -Match 'CE Gate Track 2' `
            -Because '§4.8 When to run must name CE Gate Track 2 as the skip condition'
        $script:WhenToRun49 | Should -Match 'CE Gate Track 2' `
            -Because '§4.9 When to run must name CE Gate Track 2 as the skip condition'
        $script:WhenToRun49 | Should -Not -Match 'unlike §4\.8' `
            -Because '§4.9 When to run must not reference §4.8 as a contrast (old contrast text removed by issue #211)'
    }

    It 'requires the guidance-complexity config file to exist with a valid schema' {
        Test-Path -Path $script:ConfigPath | Should -BeTrue `
            -Because '.github/config/guidance-complexity.json must be committed to the repo'
        $configJson = $null
        { $configJson = Get-Content -Path $script:ConfigPath -Raw | ConvertFrom-Json } | Should -Not -Throw `
            -Because 'guidance-complexity.json must be parseable as valid JSON'
        $configJson = Get-Content -Path $script:ConfigPath -Raw | ConvertFrom-Json
        [bool]($configJson.version -is [ValueType] -and $configJson.version -ge 1) | Should -BeTrue `
            -Because 'config schema requires a numeric version field with value >= 1'
        $configJson.default_ceiling | Should -Not -BeNullOrEmpty `
            -Because 'config schema requires a default_ceiling object'
        [bool]($configJson.default_ceiling.max_directives -is [ValueType] -and $configJson.default_ceiling.max_directives -gt 0) | Should -BeTrue `
            -Because 'default_ceiling must have a positive numeric max_directives field for ceiling comparison'
    }

    It 'requires measure-guidance-complexity.ps1 to exist' {
        Test-Path -Path $script:ScriptPath | Should -BeTrue `
            -Because '.github/scripts/measure-guidance-complexity.ps1 must exist — it is invoked by §4.7 and referenced by contract'
    }

    It 'requires the design doc to document D1, D2, and the compression concept' {
        $designContent = Get-Content -Path $script:DesignDoc -Raw
        $designContent | Should -Match '\bD1\b' `
            -Because 'guidance-complexity.md must document design decision D1 (complexity detection mechanism)'
        $designContent | Should -Match '\bD2\b' `
            -Because 'guidance-complexity.md must document design decision D2 (compression trigger mechanism)'
        $designContent | Should -Match 'compression' `
            -Because 'guidance-complexity.md must document the D2 compression trigger concept used by §4.9'
    }
}
