#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#!
.SYNOPSIS
    Regression tests for Code-Conductor CE Gate reference ownership on Copilot surfaces.

.DESCRIPTION
    Locks issue #403 Step 8 / D5: Copilot-facing Code-Conductor surfaces must keep
    the extracted CE Gate orchestration contract anchored to the customer-experience
    reference file rather than drifting back to the composite entry skill.
#>

Describe 'Copilot CE Gate regression contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ConductorBodyPath = Join-Path $script:RepoRoot 'agents\Code-Conductor.agent.md'
        $script:OrchestratePromptPath = Join-Path $script:RepoRoot '.github\prompts\orchestrate.prompt.md'
        $script:CanonicalReference = 'skills/customer-experience/references/orchestration-protocol.md'
        $script:CompositeSkillPath = 'skills/customer-experience/SKILL.md'

        $script:GetNormalizedContent = {
            param([string]$Path)

            return ((Get-Content -Path $Path -Raw -ErrorAction Stop) -replace "`r`n?", "`n")
        }

        $script:GetCeGateMarkers = {
            param([string]$Content)

            return @(
                [regex]::Matches($Content, '(?m)^\s*-\s*`(?<marker>(?:✅|⚠️|❌|⏭️) CE Gate [^`]+)`') |
                    ForEach-Object { $_.Groups['marker'].Value }
            )
        }

        $script:ConductorBody = & $script:GetNormalizedContent -Path $script:ConductorBodyPath
        $script:OrchestratePrompt = & $script:GetNormalizedContent -Path $script:OrchestratePromptPath
        $script:ConductorMarkers = @(& $script:GetCeGateMarkers -Content $script:ConductorBody)
        $script:PromptMarkers = @(& $script:GetCeGateMarkers -Content $script:OrchestratePrompt)
    }

    It 'requires both Copilot surfaces to name the extracted CE Gate orchestration reference explicitly' {
        foreach ($surface in @(
                @{ Name = 'Code-Conductor shared body'; Content = $script:ConductorBody },
                @{ Name = '/orchestrate prompt'; Content = $script:OrchestratePrompt }
            )) {
            $surface.Content | Should -Match ([regex]::Escape($script:CanonicalReference)) -Because "$($surface.Name) must point CE Gate orchestration at the extracted customer-experience reference file"
        }
    }

    It 'requires both Copilot surfaces to name the same CE Gate result markers' {
        $script:ConductorMarkers.Count | Should -BeGreaterThan 0 -Because 'the shared Code-Conductor body must enumerate the CE Gate result markers explicitly'
        $script:PromptMarkers.Count | Should -Be $script:ConductorMarkers.Count -Because 'the /orchestrate prompt must repeat the same CE Gate result markers as the shared body'
        $script:PromptMarkers | Should -BeExactly $script:ConductorMarkers -Because 'Copilot orchestration surfaces must stay in marker parity for CE Gate result reporting'
    }

    It 'prevents either Copilot surface from relying on the customer-experience entry skill alone for CE Gate orchestration' {
        foreach ($surface in @(
                @{ Name = 'Code-Conductor shared body'; Content = $script:ConductorBody },
                @{ Name = '/orchestrate prompt'; Content = $script:OrchestratePrompt }
            )) {
            $surface.Content | Should -Not -Match ('(?i)(canonical reference file|load and follow|follow|treat).*' + [regex]::Escape($script:CompositeSkillPath)) -Because "$($surface.Name) must not point Conductor-scoped CE Gate orchestration back at the customer-experience entry skill"
            $surface.Content | Should -Match ([regex]::Escape($script:CanonicalReference)) -Because "$($surface.Name) must keep the extracted orchestration reference as the authoritative CE Gate contract"
        }
    }
}
