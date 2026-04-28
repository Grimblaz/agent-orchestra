# Requires -Version 7.0
# Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Focused parity coverage for the Code-Conductor Claude shell.

.DESCRIPTION
    Supplements the generic claude-shell-parity contract with Code-Conductor-specific
    checks for discovery, shared-body bijection, Step 0 handshake ordering, shell size,
    and Phase 3 specialist fallback wording.
#>

Describe 'Code-Conductor Claude shell parity contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:AgentsDirectory = Join-Path $script:RepoRoot 'agents'
        $script:ParitySuffixPattern = '($|: |\s+\(|\s*$)'

        $script:ShellPath = Join-Path $script:AgentsDirectory 'code-conductor.md'
        $script:BodyPath = Join-Path $script:AgentsDirectory 'Code-Conductor.agent.md'
        $script:HandshakeSkillPath = Join-Path $script:RepoRoot 'skills/subagent-env-handshake/SKILL.md'

        $script:ShellContent = Get-Content -Path $script:ShellPath -Raw -ErrorAction Stop
        $script:BodyContent = Get-Content -Path $script:BodyPath -Raw -ErrorAction Stop
        $script:HandshakeSkillContent = Get-Content -Path $script:HandshakeSkillPath -Raw -ErrorAction Stop

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

        $script:GetShellEnumerationParagraph = {
            param([string]$SharedMethodology)

            $match = [regex]::Match($SharedMethodology, '(?ms)^After loading, follow everything under its (?<paragraph>.*?)(?=\r?\n\r?\n|\z)')
            if (-not $match.Success) {
                return ''
            }

            return 'After loading, follow everything under its ' + $match.Groups['paragraph'].Value
        }

        $script:GetShellSectionTokens = {
            param([string]$EnumerationParagraph)

            return @(
                [regex]::Matches($EnumerationParagraph, '`(?<token>## [^`]+?)`') |
                    ForEach-Object { $_.Groups['token'].Value }
            )
        }

        $script:GetBodyH2Headings = {
            param([string]$Content)

            return @(
                [regex]::Matches($Content, '(?m)^## (?<title>[^\r\n]+)\s*$') |
                    ForEach-Object {
                        $title = $_.Groups['title'].Value.Trim()
                        if ($title -ne 'Platform-specific invocation') {
                            '## ' + $title
                        }
                    }
            )
        }

        $script:GetHeadingMatchesForToken = {
            param(
                [string]$Token,
                [string[]]$BodyHeadings
            )

            $pattern = '^' + [regex]::Escape($Token) + $script:ParitySuffixPattern
            return @($BodyHeadings | Where-Object { $_ -match $pattern })
        }

        $script:GetTokenMatchesForHeading = {
            param(
                [string]$Heading,
                [string[]]$ShellTokens
            )

            return @(
                $ShellTokens | Where-Object {
                    $Heading -match ('^' + [regex]::Escape($_) + $script:ParitySuffixPattern)
                }
            )
        }

        $script:SharedMethodology = & $script:GetSharedMethodologySection -Content $script:ShellContent
        $script:EnumerationParagraph = & $script:GetShellEnumerationParagraph -SharedMethodology $script:SharedMethodology
        $script:ShellTokens = @(& $script:GetShellSectionTokens -EnumerationParagraph $script:EnumerationParagraph)
        $script:BodyHeadings = @(& $script:GetBodyH2Headings -Content $script:BodyContent)

        $shellDecisionTree = [regex]::Match(
            $script:ShellContent,
            '(?ms)<!-- subagent-env-handshake v1 decision tree -->\s*\r?\n(?<body>.*?)\r?\n<!-- /subagent-env-handshake v1 decision tree -->'
        )
        $script:ShellDecisionTreeBody = $shellDecisionTree.Groups['body'].Value

        $script:ShellDecisionOutcomes = @(
            [regex]::Matches($script:ShellDecisionTreeBody, '(?m)^\s*(?<num>[1-4])\.\s+(?<outcome>match|mismatch|error|missing-handshake)\b') |
                ForEach-Object { $_.Groups['outcome'].Value }
        )

        $skillOutcomeHeading = [regex]::Match(
            $script:HandshakeSkillContent,
            '(?m)^## Subagent contract [—-] (?<order>match / mismatch / error / missing-handshake)\s*$'
        )
        $script:SkillOutcomeOrder = if ($skillOutcomeHeading.Success) {
            @($skillOutcomeHeading.Groups['order'].Value -split '\s*/\s*')
        }
        else {
            @()
        }

        $script:ShellNd2Heading = [regex]::Match(
            $script:ShellContent,
            '(?m)^## Finding: environment-divergence \(halting\)\s*$'
        ).Value.Trim()
        $script:SkillNd2Heading = [regex]::Match(
            $script:HandshakeSkillContent,
            '(?m)^## Finding: environment-divergence \(halting\)\s*$'
        ).Value.Trim()

        $script:ShellLineCount = (($script:ShellContent -replace "`r`n?", "`n") -split "`n").Count

        $specialistSectionMatch = [regex]::Match(
            $script:ShellContent,
            '(?ms)^## Specialist availability\s*\r?\n(?<body>.*?)(?=^## |\z)'
        )
        $script:SpecialistSection = $specialistSectionMatch.Groups['body'].Value
    }

    It 'keeps code-conductor discoverable by the generic claude-shell-parity contract' {
        $discoveredNames = @(
            Get-ChildItem -Path $script:AgentsDirectory -Filter '*.md' -File |
                Where-Object { $_.Name -notlike '*.agent.md' } |
                Where-Object { (Get-Content -Path $_.FullName -Raw) -match '(?m)^## Shared methodology\s*$' } |
                ForEach-Object { $_.BaseName }
        )

        $discoveredNames | Should -Contain 'code-conductor'
    }

    It 'keeps an explicit shared-body pointer and H2 bijection with agents/Code-Conductor.agent.md' {
        (& $script:GetBodyPointer -SharedMethodology $script:SharedMethodology) | Should -Be 'agents/Code-Conductor.agent.md'
        $script:ShellTokens.Count | Should -Be $script:BodyHeadings.Count -Because 'the code-conductor shell must enumerate every shared-body H2 heading except the platform footer'

        foreach ($token in $script:ShellTokens) {
            $headingMatches = @(& $script:GetHeadingMatchesForToken -Token $token -BodyHeadings $script:BodyHeadings)
            $headingMatches.Count | Should -Be 1 -Because "code-conductor token '$token' must map to exactly one shared-body H2 heading"
        }

        foreach ($heading in $script:BodyHeadings) {
            $tokenMatches = @(& $script:GetTokenMatchesForHeading -Heading $heading -ShellTokens $script:ShellTokens)
            $tokenMatches.Count | Should -Be 1 -Because "code-conductor heading '$heading' must map back to exactly one shell token"
        }
    }

    It 'keeps Step 0 outcome ordering aligned with the locked handshake skill list and ND-2 heading' {
        $script:SkillOutcomeOrder | Should -Be @('match', 'mismatch', 'error', 'missing-handshake') -Because 'the handshake skill heading is the locked four-outcome list for Step 0 ordering'
        $script:ShellDecisionOutcomes | Should -Be $script:SkillOutcomeOrder -Because 'the code-conductor Step 0 decision tree must preserve the skill-locked outcome ordering'
        $script:ShellNd2Heading | Should -Be '## Finding: environment-divergence (halting)'
        $script:ShellNd2Heading | Should -Be $script:SkillNd2Heading -Because 'the code-conductor ND-2 heading must stay in lockstep with the handshake skill heading'
    }

    It 'keeps agents/code-conductor.md at 220 lines or fewer' {
        $script:ShellLineCount | Should -BeLessOrEqual 220 -Because 'issue #403 Step 11 locks the Claude shell size ceiling'
    }

    It 'keeps the Phase 3 specialist sentence exact, adds the Phase 4 specialist sentence, and preserves D1 fallback labels' {
        $script:SpecialistSection | Should -Match 'Phase 3 Claude specialist shells available for Code-Conductor dispatch are `code-critic`, `code-review-response`, `experience-owner`, and `issue-planner`\.' -Because 'the shell must advertise the Phase 3 specialist shells exactly'
        $script:SpecialistSection | Should -Match 'Phase 4 Claude specialist shells available for Code-Conductor dispatch are `code-smith`, `test-writer`, `refactor-specialist`, and `doc-keeper`\.' -Because 'the shell must advertise the Phase 4 specialist shells exactly'
        $script:SpecialistSection | Should -Match '(?m)^1\. Hand off this step to Copilot, resume in Claude after\s*$' -Because 'D1 fallback option 1 is locked'
        $script:SpecialistSection | Should -Match '(?m)^2\. Attempt inline in the main conversation \(no specialist dispatch\)\s*$' -Because 'D1 fallback option 2 is locked'
        $script:SpecialistSection | Should -Match '(?m)^3\. Pause here - wait for the missing specialist shell to land\s*$' -Because 'D1 fallback option 3 is locked'
    }
}
