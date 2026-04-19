#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Contract tests for guidance complexity ceiling wiring.

.DESCRIPTION
    Locks the issue #211 guidance complexity contract across:
      - agents/Process-Review.agent.md (§4.7, §4.8, §4.9)
    - skills/calibration-pipeline/assets/guidance-complexity.json
    - skills/guidance-measurement/scripts/measure-guidance-complexity.ps1
      - Documents/Design/guidance-complexity.md

        The files must satisfy:
            - §4.7 invokes measure-guidance-complexity.ps1 and makes output available to §4.9
            - §4.9 references compression_required and agents_over_ceiling, scoped to agent-prompt proposals
            - §4.8 and §4.9 share consistent trigger scope: both skip only CE Gate Track 2, both run during calibration-only mode
            - skills/calibration-pipeline/assets/guidance-complexity.json exists with a valid schema (version + default_ceiling.max_directives)
            - skills/guidance-measurement/scripts/measure-guidance-complexity.ps1 exists
            - Documents/Design/guidance-complexity.md documents D1, D2, and the compression concept

        These tests lock the landed issue #211 wiring so future edits to Process-Review, the config, or the
        design doc do not silently drift from the complexity-ceiling contract.
#>

Describe 'guidance complexity ceiling contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ProcessReview = Join-Path $script:RepoRoot 'agents/Process-Review.agent.md'
        $script:ConfigPath = Join-Path $script:RepoRoot 'skills/calibration-pipeline/assets/guidance-complexity.json'
        $script:ScriptPath = Join-Path $script:RepoRoot 'skills/guidance-measurement/scripts/measure-guidance-complexity.ps1'
        $script:DesignDoc = Join-Path $script:RepoRoot 'Documents/Design/guidance-complexity.md'

        $script:ProcessReviewContent = Get-Content -Path $script:ProcessReview -Raw

        # Extract individual sections: from heading until the next same-level heading or end of file
        $script:Section47 = [regex]::Match($script:ProcessReviewContent, '(?is)### 4\.7\b.*?(?=### 4\.\d+|\Z)').Value
        $script:Section48 = [regex]::Match($script:ProcessReviewContent, '(?is)### 4\.8\b.*?(?=### 4\.\d+|\Z)').Value
        $script:Section49 = [regex]::Match($script:ProcessReviewContent, '(?is)### 4\.9\b.*?(?=### 4\.\d+|\Z)').Value

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

    It 'requires §4.7 to pass -ComplexityJsonPath to the aggregate-review-scores invocation' {
        # Fix M8: verify §4.7 wires the temp-file bridge by passing -ComplexityJsonPath to the
        # aggregate script. Future removal of the parameter wiring would break this contract.
        $script:Section47 | Should -Match '-ComplexityJsonPath' `
            -Because '§4.7 must pass -ComplexityJsonPath to aggregate-review-scores.ps1 so the temp-file bridge delivers complexity data to the history tracker (Phase 2 D7 integration contract)'
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
        $script:WhenToRun49 | Should -Match 'calibration' `
            -Because '§4.9 should run during calibration-only mode, not just full retrospectives'
    }

    It 'requires the guidance-complexity config file to exist with a valid schema' {
        Test-Path -Path $script:ConfigPath | Should -BeTrue `
            -Because 'skills/calibration-pipeline/assets/guidance-complexity.json must be committed to the repo'
        { $null = Get-Content -Path $script:ConfigPath -Raw | ConvertFrom-Json } | Should -Not -Throw `
            -Because 'guidance-complexity.json must be parseable as valid JSON'
        $configJson = Get-Content -Path $script:ConfigPath -Raw | ConvertFrom-Json
        [bool]($configJson.version -is [ValueType] -and $configJson.version -ge 1) | Should -BeTrue `
            -Because 'config schema requires a numeric version field with value >= 1'
        $configJson.default_ceiling | Should -Not -BeNullOrEmpty `
            -Because 'config schema requires a default_ceiling object'
        [bool]($configJson.default_ceiling.max_directives -is [ValueType] -and $configJson.default_ceiling.max_directives -gt 0) | Should -BeTrue `
            -Because 'default_ceiling must have a positive numeric max_directives field for ceiling comparison'
    }

    It 'requires the guidance-complexity config to declare a positive integer persistent_threshold' {
        $configJson = Get-Content -Path $script:ConfigPath -Raw | ConvertFrom-Json
        $configJson.persistent_threshold | Should -Not -BeNullOrEmpty `
            -Because 'config schema requires persistent_threshold for consolidation monitoring (Phase 2 D7)'
        [bool]($configJson.persistent_threshold -is [ValueType] -and $configJson.persistent_threshold -gt 0 -and $configJson.persistent_threshold % 1 -eq 0) | Should -BeTrue `
            -Because 'persistent_threshold must be a positive integer — the consecutive-over-ceiling count threshold before extraction advisory fires'
    }

    It 'requires measure-guidance-complexity.ps1 to exist' {
        Test-Path -Path $script:ScriptPath | Should -BeTrue `
            -Because 'skills/guidance-measurement/scripts/measure-guidance-complexity.ps1 must exist — it is invoked by §4.7 and referenced by contract'
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

    It 'requires the design doc to document D7, D8 (tiered advisory), and D9 (agent creation budget)' {
        # Fix M6: plan Step 4 Requirement Contract required contract verification of D7/D8/D9 sections.
        $designContent = Get-Content -Path $script:DesignDoc -Raw
        $designContent | Should -Match '\bD7\b' `
            -Because 'guidance-complexity.md must document design decision D7 (persistent over-ceiling detection, Phase 2)'
        $designContent | Should -Match '\bD8\b' `
            -Because 'guidance-complexity.md must document design decision D8 (tiered advisory — extraction replaces compression, Phase 2)'
        $designContent | Should -Match '\bD9\b' `
            -Because 'guidance-complexity.md must document design decision D9 (agent creation complexity budget, Phase 2)'
    }

    It 'requires Process-Review §4.9 to reference extraction_recommended field (Phase 2 D8)' {
        $script:Section49 | Should -Match 'extraction_recommended' `
            -Because '§4.9 proposals YAML must include extraction_recommended field to flag agents meeting persistent_threshold for skill extraction (Phase 2 D8)'
    }

    It 'requires Process-Review §4.9 to reference persistent_threshold (Phase 2 D7)' {
        $script:Section49 | Should -Match 'persistent_threshold' `
            -Because '§4.9 Step 1b must reference persistent_threshold when checking whether the extraction advisory applies (Phase 2 D7)'
    }

    It 'requires Process-Review §4.9 to contain an extraction advisory text (Phase 2 D8)' {
        $script:Section49 | Should -Match 'Extraction advisory \(D8\)' `
            -Because '§4.9 must contain the D8 extraction advisory wording for agents that have persistently exceeded the guidance-complexity ceiling'
    }

    It 'requires Process-Review §4.9 extraction advisory to replace (not stack with) compression advisory' {
        # The D8 advisory must NOT appear in the same sub-case as D2 — they are mutually exclusive
        # Verify by checking that the extraction advisory block contains "REPLACES D2" language
        $script:Section49 | Should -Match 'REPLACES D2' `
            -Because '§4.9 D8 advisory must state it replaces D2 to prevent advisory stacking — the extraction advisory is the sole advisory when extraction_recommended is true'
    }
}
