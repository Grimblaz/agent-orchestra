#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Focused coverage for the two Claude review shells added in issue #379.

.DESCRIPTION
    Supplements claude-shell-parity.Tests.ps1 by asserting that the new
    code-critic and code-review-response shells remain discoverable by the
    generic parity contract and keep their review-specific invocation and
    mode-trigger references aligned with the shared bodies.
#>

Describe 'orchestra-review Claude shell coverage contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:AgentsDirectory = Join-Path $script:RepoRoot 'agents'
        $script:RetiredTriggerText = 'Before the first substantive response in a new conversation, load the `session-startup` skill and follow its protocol.'
        $script:CodeCriticShellPath = Join-Path $script:AgentsDirectory 'code-critic.md'
        $script:CodeCriticBodyPath = Join-Path $script:AgentsDirectory 'Code-Critic.agent.md'
        $script:CodeReviewResponseShellPath = Join-Path $script:AgentsDirectory 'code-review-response.md'
        $script:LiteMarker = 'Use lite code review perspectives'

        $script:GetSharedMethodologySection = {
            param([string]$Content)

            $match = [regex]::Match($Content, '(?ms)^## Shared methodology\s*\r?\n(?<body>.*?)(?=^## |\z)')
            if (-not $match.Success) {
                return ''
            }

            return $match.Groups['body'].Value
        }

        $script:GetBodyPointer = {
            param([string]$SharedMethodology)

            $match = [regex]::Match($SharedMethodology, '(?m)^The full tool-agnostic methodology for this role lives at `(?<pointer>agents/[^`]+\.agent\.md)` in the repo root\.\s*$')
            if (-not $match.Success) {
                return ''
            }

            return $match.Groups['pointer'].Value
        }
    }

    It 'keeps the two review shells free of the retired startup trigger stub' {
        $codeCriticShell = Get-Content -Path $script:CodeCriticShellPath -Raw
        $codeReviewResponseShell = Get-Content -Path $script:CodeReviewResponseShellPath -Raw

        $codeCriticShell | Should -Not -Match ([regex]::Escape($script:RetiredTriggerText))
        $codeReviewResponseShell | Should -Not -Match ([regex]::Escape($script:RetiredTriggerText))
    }

    It 'keeps explicit shared-body pointers for both new review shells' {
        $codeCriticSharedMethodology = & $script:GetSharedMethodologySection -Content (Get-Content -Path $script:CodeCriticShellPath -Raw)
        $codeReviewResponseSharedMethodology = & $script:GetSharedMethodologySection -Content (Get-Content -Path $script:CodeReviewResponseShellPath -Raw)

        (& $script:GetBodyPointer -SharedMethodology $codeCriticSharedMethodology) | Should -Be 'agents/Code-Critic.agent.md'
        (& $script:GetBodyPointer -SharedMethodology $codeReviewResponseSharedMethodology) | Should -Be 'agents/Code-Review-Response.agent.md'
    }

    It 'keeps the lite-mode trigger string aligned between the code-critic shell and shared body' {
        $shellContent = Get-Content -Path $script:CodeCriticShellPath -Raw
        $bodyReviewModeSection = [regex]::Match(
            (Get-Content -Path $script:CodeCriticBodyPath -Raw),
            '(?ms)^## Review Mode Routing\s*\r?\n(?<body>.*?)(?=^## |\z)'
        ).Groups['body'].Value

        $shellContent | Should -Match ([regex]::Escape($script:LiteMarker)) -Because 'the code-critic shell invocation guidance must reference the lite-mode marker verbatim'
        $bodyReviewModeSection | Should -Match ([regex]::Escape($script:LiteMarker)) -Because 'the shared Code-Critic body must carry the same lite-mode marker verbatim'
    }

    It 'keeps the two review shells invocation sections tied to the expected slash-command surface' {
        $codeCriticShell = Get-Content -Path $script:CodeCriticShellPath -Raw
        $codeReviewResponseShell = Get-Content -Path $script:CodeReviewResponseShellPath -Raw

        $codeCriticShell | Should -Match '/orchestra:review`, `/orchestra:review-lite`, `/orchestra:review-prosecute`, `/orchestra:review-defend' -Because 'code-critic must advertise the four prosecution/defense command entry points'
        $codeReviewResponseShell | Should -Match '/orchestra:review`, `/orchestra:review-lite`, `/orchestra:review-judge' -Because 'code-review-response must advertise the judge-capable command entry points'
    }
}
