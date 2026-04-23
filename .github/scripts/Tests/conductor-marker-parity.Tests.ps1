#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Structural marker parity coverage for the Code-Conductor Claude/Copilot surfaces.

.DESCRIPTION
    Locks issue #403 Step 11 by asserting that the cross-tool durable marker shapes
    remain recognizable across the Code-Conductor shell, shared body, and Copilot
    entry points without over-coupling to surrounding prose.
#>

Describe 'Code-Conductor cross-tool marker parity contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:DocumentPaths = [ordered]@{
            ClaudeShell         = Join-Path $script:RepoRoot 'agents/code-conductor.md'
            SharedBody          = Join-Path $script:RepoRoot 'agents/Code-Conductor.agent.md'
            CopilotPrompt       = Join-Path $script:RepoRoot '.github/prompts/orchestrate.prompt.md'
            CopilotInstructions = Join-Path $script:RepoRoot '.github/copilot-instructions.md'
        }

        $script:DocumentContents = @{}
        foreach ($entry in $script:DocumentPaths.GetEnumerator()) {
            $script:DocumentContents[$entry.Key] = Get-Content -Path $entry.Value -Raw -ErrorAction Stop
        }

        $script:NormalizeMarkerShape = {
            param([string]$Text)

            if ([string]::IsNullOrWhiteSpace($Text)) {
                return ''
            }

            $shape = $Text.Trim()
            $shape = $shape -replace '`r`n?', "`n"
            $shape = $shape -replace '\{ID\}|\{PR\}|\\d\+', '\\d+'
            $shape = $shape -replace '\{reason\}', '.+'
            $shape = $shape -replace '\{strong\|partial\|weak\}', '(strong|partial|weak)'
            $shape = $shape -replace '\s+[—-]\s+', ' [—-] '
            $shape = $shape -replace '\s+', ' '

            return $shape
        }

        $script:GetMatchShapes = {
            param(
                [string]$Content,
                [string]$Pattern
            )

            return @(
                [regex]::Matches($Content, $Pattern) |
                    ForEach-Object {
                        & $script:NormalizeMarkerShape -Text $_.Value
                    }
            )
        }

        $script:AssertMarkerParity = {
            param(
                [string]$Pattern,
                [string]$CanonicalShape,
                [string[]]$RequiredDocuments,
                [string]$Because
            )

            foreach ($documentName in $RequiredDocuments) {
                $content = $script:DocumentContents[$documentName]
                $shapes = @(& $script:GetMatchShapes -Content $content -Pattern $Pattern)

                $shapes.Count | Should -BeGreaterThan 0 -Because "$documentName must carry $Because"
                $shapes | Should -Contain $CanonicalShape -Because "$documentName must preserve the canonical structural shape for $Because"
            }
        }
    }

    It 'keeps the durable issue and PR comment markers structurally aligned where they are documented' {
        & $script:AssertMarkerParity `
            -Pattern '<!--\s*plan-issue-(?:\{ID\}|\\d\+)\s*-->' `
            -CanonicalShape '<!-- plan-issue-\\d+ -->' `
            -RequiredDocuments @('ClaudeShell', 'SharedBody', 'CopilotInstructions') `
            -Because 'the plan handoff marker shape'

        & $script:AssertMarkerParity `
            -Pattern '<!--\s*experience-owner-complete-(?:\{ID\}|\\d\+)\s*-->' `
            -CanonicalShape '<!-- experience-owner-complete-\\d+ -->' `
            -RequiredDocuments @('ClaudeShell', 'SharedBody') `
            -Because 'the experience-owner completion marker shape'

        & $script:AssertMarkerParity `
            -Pattern '<!--\s*design-phase-complete-(?:\{ID\}|\\d\+)\s*-->' `
            -CanonicalShape '<!-- design-phase-complete-\\d+ -->' `
            -RequiredDocuments @('ClaudeShell', 'SharedBody') `
            -Because 'the design completion marker shape'

        & $script:AssertMarkerParity `
            -Pattern '<!--\s*code-review-complete-(?:\{PR\}|\\d\+)\s*-->' `
            -CanonicalShape '<!-- code-review-complete-\\d+ -->' `
            -RequiredDocuments @('ClaudeShell') `
            -Because 'the review completion marker shape'
    }

    It 'keeps the CE Gate result-marker families structurally aligned across conductor entry points' {
        & $script:AssertMarkerParity `
            -Pattern '✅\s+CE Gate passed\s*[—-]\s*intent match:\s*(?:strong|partial|weak)' `
            -CanonicalShape '✅ CE Gate passed [—-] intent match: strong' `
            -RequiredDocuments @('SharedBody', 'CopilotPrompt') `
            -Because 'the CE Gate pass marker family'

        & $script:AssertMarkerParity `
            -Pattern '✅\s+CE Gate passed after fix\s*[—-]\s*intent match:\s*(?:\(strong\|partial\|weak\)|\{strong\|partial\|weak\})' `
            -CanonicalShape '✅ CE Gate passed after fix [—-] intent match: (strong|partial|weak)' `
            -RequiredDocuments @('SharedBody', 'CopilotPrompt') `
            -Because 'the CE Gate pass-after-fix marker family'

        & $script:AssertMarkerParity `
            -Pattern '⚠️\s+CE Gate skipped\s*[—-]\s*\{reason\}' `
            -CanonicalShape '⚠️ CE Gate skipped [—-] .+' `
            -RequiredDocuments @('ClaudeShell', 'SharedBody', 'CopilotPrompt') `
            -Because 'the CE Gate skipped marker family'

        & $script:AssertMarkerParity `
            -Pattern '❌\s+CE Gate aborted\s*[—-]\s*\{reason\}' `
            -CanonicalShape '❌ CE Gate aborted [—-] .+' `
            -RequiredDocuments @('ClaudeShell', 'SharedBody', 'CopilotPrompt') `
            -Because 'the CE Gate aborted marker family'

        & $script:AssertMarkerParity `
            -Pattern '⏭️\s+CE Gate not applicable\s*[—-]\s*\{reason\}' `
            -CanonicalShape '⏭️ CE Gate not applicable [—-] .+' `
            -RequiredDocuments @('SharedBody', 'CopilotPrompt') `
            -Because 'the CE Gate not-applicable marker family'
    }

    It 'keeps the Claude shell persistence note anchored to the same CE Gate marker family as the exhaustive lists' {
        $shellShapes = @(
            & $script:GetMatchShapes -Content $script:DocumentContents['ClaudeShell'] -Pattern '✅\s+CE Gate passed\s*[—-]\s*intent match:\s*strong'
            & $script:GetMatchShapes -Content $script:DocumentContents['ClaudeShell'] -Pattern '⚠️\s+CE Gate skipped\s*[—-]\s*\{reason\}'
            & $script:GetMatchShapes -Content $script:DocumentContents['ClaudeShell'] -Pattern '❌\s+CE Gate aborted\s*[—-]\s*\{reason\}'
        )

        $shellShapes | Should -Contain '✅ CE Gate passed [—-] intent match: strong' -Because 'the Claude shell persistence note must reference the same pass-marker shape as the canonical lists'
        $shellShapes | Should -Contain '⚠️ CE Gate skipped [—-] .+' -Because 'the Claude shell persistence note must reference the same skipped-marker shape as the canonical lists'
        $shellShapes | Should -Contain '❌ CE Gate aborted [—-] .+' -Because 'the Claude shell persistence note must reference the same aborted-marker shape as the canonical lists'
    }
}
