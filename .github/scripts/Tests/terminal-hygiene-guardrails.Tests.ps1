#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Contract tests for terminal-hygiene guardrails introduced by issue #524.

.DESCRIPTION
    RED coverage for issue #524 until the two new sections are written into
    skills/terminal-hygiene/SKILL.md. Tests use section-scoped extraction so
    that tokens already present in the existing '## Terminal Retry Hygiene'
    section (kill_terminal, fresh terminal) cannot false-GREEN assertions
    intended to target the new '## Multiline Continuation-Prompt Hazard' section.

    Assertion coverage (ac-refs: AC1, AC2, AC3, AC4, AC5, AC6, AC7):
        (a) Both new H2 headings exist in SKILL.md
        (b) Each new section body is non-empty
        (c) Non-Fatal Diagnostic Wrapper Pattern section contains required tokens
        (d) Multiline Continuation-Prompt Hazard section describes kill/fresh-terminal recovery
        (e) Code-Conductor.agent.md references both new section names verbatim
        (f) Gotchas section contains the two new operator-vocabulary rows
        (g) All pre-existing H2 sections remain present
        (h) terminal-test-hygiene.md has a D12 entry referencing both new sections
#>

Describe 'terminal hygiene guardrails contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:SkillPath     = Join-Path $script:RepoRoot 'skills\terminal-hygiene\SKILL.md'
        $script:ConductorPath = Join-Path $script:RepoRoot 'agents\Code-Conductor.agent.md'
        $script:DesignDocPath = Join-Path $script:RepoRoot 'Documents\Design\terminal-test-hygiene.md'

        $script:MultilineHeading = '## Multiline Continuation-Prompt Hazard'
        $script:WrapperHeading   = '## Non-Fatal Diagnostic Wrapper Pattern'

        # Load file content normalized to LF line endings
        $script:GetContent = {
            param([string]$Path)
            (Get-Content -Path $Path -Raw -ErrorAction Stop) -replace "`r`n?", "`n"
        }

        # Extract the body of a named H2 section.
        # Returns content from the line after the heading up to the next '## ' heading or EOF.
        # Uses section-scoped extraction to avoid cross-section false-GREENs.
        $script:GetH2Section = {
            param([string]$Content, [string]$Heading)
            $escaped = [regex]::Escape($Heading)
            # Match heading line (heading + anything on same line + newline), then capture body
            $pattern = "(?ms)^$escaped[^\n]*\n(?<body>.*?)(?=^## |\z)"
            $m = [regex]::Match($Content, $pattern)
            if (-not $m.Success) { return '' }
            return $m.Groups['body'].Value
        }

        # Extract the body of a named ### section from the design doc.
        # Returns content from the line after the heading up to the next '### ', '## ', or EOF.
        $script:GetH3Section = {
            param([string]$Content, [string]$HeadingPrefix)
            $escaped = [regex]::Escape($HeadingPrefix)
            $pattern = "(?ms)^$escaped[^\n]*\n(?<body>.*?)(?=^### |^## |\z)"
            $m = [regex]::Match($Content, $pattern)
            if (-not $m.Success) { return '' }
            return $m.Groups['body'].Value
        }

        # Load all target files
        $script:SkillContent     = if (Test-Path $script:SkillPath)     { & $script:GetContent -Path $script:SkillPath }     else { '' }
        $script:ConductorContent = if (Test-Path $script:ConductorPath) { & $script:GetContent -Path $script:ConductorPath } else { '' }
        $script:DesignContent    = if (Test-Path $script:DesignDocPath)  { & $script:GetContent -Path $script:DesignDocPath }  else { '' }
    }

    # (a) Both new H2 headings exist in SKILL.md
    It 'requires both new H2 headings to be present in terminal-hygiene SKILL.md' {
        $script:SkillContent | Should -Match '(?m)^## Multiline Continuation-Prompt Hazard\s*$' `
            -Because 'AC1: Multiline Continuation-Prompt Hazard section must be added to SKILL.md'
        $script:SkillContent | Should -Match '(?m)^## Non-Fatal Diagnostic Wrapper Pattern\s*$' `
            -Because 'AC2: Non-Fatal Diagnostic Wrapper Pattern section must be added to SKILL.md'
    }

    # (b) Each new section body is non-empty
    It 'requires each new section to have a non-empty body' {
        $multilineBody = & $script:GetH2Section -Content $script:SkillContent -Heading $script:MultilineHeading
        $wrapperBody   = & $script:GetH2Section -Content $script:SkillContent -Heading $script:WrapperHeading

        $multilineBody.Trim() | Should -Not -BeNullOrEmpty `
            -Because 'AC1: Multiline Continuation-Prompt Hazard section must contain guidance'
        $wrapperBody.Trim() | Should -Not -BeNullOrEmpty `
            -Because 'AC2: Non-Fatal Diagnostic Wrapper Pattern section must contain guidance'
    }

    # (c) Non-Fatal Diagnostic Wrapper Pattern section contains VALIDATION_STATUS tokens (section-scoped)
    It 'requires the Non-Fatal Diagnostic Wrapper Pattern section to document VALIDATION_STATUS tokens' {
        $wrapperBody = & $script:GetH2Section -Content $script:SkillContent -Heading $script:WrapperHeading

        $wrapperBody | Should -Match 'VALIDATION_STATUS=pass' `
            -Because 'AC3: wrapper pattern must document the VALIDATION_STATUS=pass token'
        $wrapperBody | Should -Match 'VALIDATION_STATUS=fail' `
            -Because 'AC3: wrapper pattern must document the VALIDATION_STATUS=fail token'
        $wrapperBody | Should -Match 'exit 0' `
            -Because 'AC3: wrapper pattern must specify exit 0 so orchestration continues'
        $wrapperBody | Should -Match '(?i)non-?zero|retain.*exit' `
            -Because 'AC3: wrapper pattern must clarify that real validation gates retain non-zero exits'
    }

    # (d) Multiline Continuation-Prompt Hazard section describes kill/fresh-terminal recovery (section-scoped).
    # IMPORTANT: kill_terminal and fresh terminal already appear in '## Terminal Retry Hygiene'
    # (lines 70 and 73 of the current SKILL.md). A flat-file regex would pass RED before s2 runs.
    # This assertion is scoped to the extracted section body to prevent that false-GREEN.
    It 'requires the Multiline Continuation-Prompt Hazard section to describe kill_terminal or fresh terminal recovery' {
        $multilineBody = & $script:GetH2Section -Content $script:SkillContent -Heading $script:MultilineHeading

        $multilineBody | Should -Match '(?i)kill_terminal|fresh terminal|reissue' `
            -Because 'AC4: multiline hazard section must describe recovery (section-scoped to prevent false-GREEN from existing Terminal Retry Hygiene section)'
    }

    # (e) Code-Conductor.agent.md references both new section names verbatim
    It 'requires Code-Conductor.agent.md to reference both new section names' {
        $script:ConductorContent | Should -Match ([regex]::Escape('Multiline Continuation-Prompt Hazard')) `
            -Because 'AC5: Code-Conductor must pointer-reference the Multiline Continuation-Prompt Hazard section'
        $script:ConductorContent | Should -Match ([regex]::Escape('Non-Fatal Diagnostic Wrapper Pattern')) `
            -Because 'AC5: Code-Conductor must pointer-reference the Non-Fatal Diagnostic Wrapper Pattern section'
    }

    # (f) Gotchas table contains the two new operator-vocabulary rows (section-scoped)
    It 'requires the Gotchas section to include both new operator-vocabulary rows' {
        $gotchasBody = & $script:GetH2Section -Content $script:SkillContent -Heading '## Gotchas'

        $gotchasBody | Should -Match '(?i)silently.{0,60}multi-?line|multi-?line.{0,60}silent' `
            -Because 'AC6: Gotchas must include a row for the terminal sitting silently after a multi-line command'
        $gotchasBody | Should -Match '(?i)diagnostic.{0,80}halt|halt.{0,80}diagnostic|causes orchestration to halt' `
            -Because 'AC6: Gotchas must include a row for a diagnostic check causing orchestration to halt unexpectedly'
    }

    # (g) All pre-existing H2 sections remain present (non-regression)
    It 'requires all pre-existing terminal-hygiene H2 sections to remain intact' {
        $preExistingHeadings = @(
            '(?m)^## Pester Scope\s*$',
            '(?m)^## `isBackground` Default\s*$',
            '(?m)^## No Terminal/Subagent Batching\s*$',
            '(?m)^## Terminal Cleanup\s*$',
            '(?m)^## Terminal Retry Hygiene\s*$',
            '(?m)^## Gotchas\s*$'
        )

        foreach ($pattern in $preExistingHeadings) {
            $script:SkillContent | Should -Match $pattern `
                -Because "non-regression: pre-existing heading matching '$pattern' must remain in SKILL.md"
        }
    }

    # (h) terminal-test-hygiene.md contains a D12 entry with non-empty body referencing both new sections
    It 'requires terminal-test-hygiene.md to record a D12 design entry referencing both new sections' {
        $script:DesignContent | Should -Match '(?m)^### D12' `
            -Because 'AC7: design doc must include a D12 entry recording the issue #524 decisions'

        $d12Body = & $script:GetH3Section -Content $script:DesignContent -HeadingPrefix '### D12'

        $d12Body.Trim() | Should -Not -BeNullOrEmpty `
            -Because 'AC7: D12 entry must have content'
        $d12Body | Should -Match ([regex]::Escape('Multiline Continuation-Prompt Hazard')) `
            -Because 'AC7: D12 must reference the Multiline Continuation-Prompt Hazard section by name'
        $d12Body | Should -Match ([regex]::Escape('Non-Fatal Diagnostic Wrapper Pattern')) `
            -Because 'AC7: D12 must reference the Non-Fatal Diagnostic Wrapper Pattern section by name'
    }
}
