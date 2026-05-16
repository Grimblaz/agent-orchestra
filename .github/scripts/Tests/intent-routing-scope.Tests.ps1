#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Documentation-scope coverage for natural-language intent routing.

.DESCRIPTION
    Locks issue #567 Step 1 D3 scope documentation only. Runtime scope behavior belongs
    to CE Gate evidence, so this file asserts the Intent Routing section in both platform docs.
#>

Describe 'Natural-language intent routing scope documentation' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:DocPaths = @(
            'CLAUDE.md',
            '.github/copilot-instructions.md'
        )

        $script:GetIntentRoutingSection = {
            param([Parameter(Mandatory)][string]$RelativePath)

            $docPath = Join-Path $script:RepoRoot ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            $content = Get-Content -Path $docPath -Raw
            $sectionMatch = [regex]::Match($content, '(?ms)^## Intent Routing\r?\n(?<section>.*?)(?=^## |\z)')

            if ($sectionMatch.Success) {
                return $sectionMatch.Groups['section'].Value
            }

            return $null
        }
    }

    It 'documents the D3 detection scope in each platform Intent Routing section' {
        foreach ($relativePath in $script:DocPaths) {
            $intentRoutingSection = & $script:GetIntentRoutingSection $relativePath

            $intentRoutingSection | Should -Not -BeNullOrEmpty -Because "$relativePath must have a top-level ## Intent Routing section before runtime CE Gate validation"
            $intentRoutingSection | Should -Match 'active slash-command turn'
            $intentRoutingSection | Should -Match 'subagent dispatch'
        }
    }
}
