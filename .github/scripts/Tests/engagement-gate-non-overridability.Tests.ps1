#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#!
.SYNOPSIS
    Contract tests for engagement-gate non-overridability documentation clauses.

.DESCRIPTION
    Locks issue #585 RED requirements: the non-overridability clauses must be
    present inside explicit anchor-marker-bounded regions across the three
    methodology skills and both platform instruction surfaces.
#>

$clauseCases = @(
    @{
        Name = 'solution-authoring'
        RelativePath = 'skills\solution-authoring\SKILL.md'
        Begin = '<!-- solution-authoring-non-overridability:begin -->'
        End = '<!-- solution-authoring-non-overridability:end -->'
        RequiredPhrases = @(
            'unconditional',
            'Decline engagement — proceed without classification'
        )
    },
    @{
        Name = 'upstream-onboarding'
        RelativePath = 'skills\upstream-onboarding\SKILL.md'
        Begin = '<!-- upstream-onboarding-non-overridability:begin -->'
        End = '<!-- upstream-onboarding-non-overridability:end -->'
        RequiredPhrases = @(
            'unconditional',
            'methodology checkpoints',
            'select an alternative option'
        )
    },
    @{
        Name = 'plan-authoring'
        RelativePath = 'skills\plan-authoring\SKILL.md'
        Begin = '<!-- plan-authoring-non-overridability:begin -->'
        End = '<!-- plan-authoring-non-overridability:end -->'
        RequiredPhrases = @(
            'unconditional',
            'methodology checkpoints',
            'documented `Reject` or equivalent option'
        )
    },
    @{
        Name = 'CLAUDE.md'
        RelativePath = 'CLAUDE.md'
        Begin = '<!-- engagement-gate-non-overridability:begin -->'
        End = '<!-- engagement-gate-non-overridability:end -->'
        RequiredPhrases = @(
            'preference-clarifying',
            'methodology checkpoints',
            'including but not limited to',
            'solution-authoring/SKILL.md',
            'Rule: Classification gate',
            '#575'
        )
    },
    @{
        Name = '.github/copilot-instructions.md'
        RelativePath = '.github\copilot-instructions.md'
        Begin = '<!-- engagement-gate-non-overridability:begin -->'
        End = '<!-- engagement-gate-non-overridability:end -->'
        RequiredPhrases = @(
            'preference-clarifying',
            'methodology checkpoints',
            'including but not limited to',
            'solution-authoring/SKILL.md',
            'Rule: Classification gate',
            '#575'
        )
    }
)

$headingCases = @(
    @{ Name = 'CLAUDE.md'; RelativePath = 'CLAUDE.md' },
    @{ Name = '.github/copilot-instructions.md'; RelativePath = '.github\copilot-instructions.md' }
)

Describe 'engagement-gate non-overridability clauses' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

        function Get-NormalizedContent {
            param([string]$RelativePath)

            $path = Join-Path $script:RepoRoot $RelativePath
            return (Get-Content -Path $path -Raw -ErrorAction Stop) -replace "`r`n?", "`n"
        }

        function Get-BoundedClause {
            param([hashtable]$Case)

            $content = Get-NormalizedContent -RelativePath $Case.RelativePath
            $beginIndex = $content.IndexOf($Case.Begin, [System.StringComparison]::Ordinal)
            $endIndex = $content.IndexOf($Case.End, [System.StringComparison]::Ordinal)

            if ($beginIndex -lt 0 -or $endIndex -lt 0 -or $beginIndex -ge $endIndex) {
                return ''
            }

            $start = $beginIndex + $Case.Begin.Length
            return $content.Substring($start, $endIndex - $start).Trim()
        }

        function Get-SectionBeforeMarker {
            param(
                [string]$RelativePath,
                [string]$Heading,
                [string]$Marker
            )

            $content = Get-NormalizedContent -RelativePath $RelativePath
            $sectionMatch = [regex]::Match(
                $content,
                "(?ms)^## $([regex]::Escape($Heading))\s*\n(?<body>.*?)(?=^## |\z)"
            )

            if (-not $sectionMatch.Success) {
                return ''
            }

            $sectionBody = $sectionMatch.Groups['body'].Value
            $markerIndex = $sectionBody.IndexOf($Marker, [System.StringComparison]::Ordinal)
            if ($markerIndex -lt 0) {
                return $sectionBody.Trim()
            }

            return $sectionBody.Substring(0, $markerIndex).Trim()
        }
    }

    It '<Name> has exactly one ordered non-empty bounded clause' -ForEach $clauseCases {
        $content = Get-NormalizedContent -RelativePath $RelativePath
        $beginMatches = [regex]::Matches($content, [regex]::Escape($Begin))
        $endMatches = [regex]::Matches($content, [regex]::Escape($End))

        $beginMatches.Count | Should -Be 1 -Because "$Name begin anchor must appear exactly once"
        $endMatches.Count | Should -Be 1 -Because "$Name end anchor must appear exactly once"

        if ($beginMatches.Count -eq 1 -and $endMatches.Count -eq 1) {
            $beginMatches[0].Index | Should -BeLessThan $endMatches[0].Index -Because "$Name begin anchor must precede end anchor"
            $boundedContent = Get-BoundedClause -Case $_
            $boundedContent | Should -Not -BeNullOrEmpty -Because "$Name bounded clause content must be non-empty"
        }
    }

    It '<Name> bounded clause covers required phrases' -ForEach $clauseCases {
        $boundedContent = Get-BoundedClause -Case $_

        foreach ($phrase in $RequiredPhrases) {
            $boundedContent | Should -Match ([regex]::Escape($phrase)) -Because "$Name bounded clause must include '$phrase'"
        }
    }

    It '<Name> top-level heading appears exactly once and within 5 lines above begin marker' -ForEach $headingCases {
        $content = Get-NormalizedContent -RelativePath $RelativePath
        $lines = $content -split "`n"
        $heading = '## Engagement-gate non-overridability'
        $begin = '<!-- engagement-gate-non-overridability:begin -->'

        $headingLineNumbers = @()
        $beginLineNumbers = @()

        for ($lineNumber = 0; $lineNumber -lt $lines.Count; $lineNumber++) {
            if ($lines[$lineNumber] -eq $heading) {
                $headingLineNumbers += $lineNumber
            }

            if ($lines[$lineNumber] -eq $begin) {
                $beginLineNumbers += $lineNumber
            }
        }

        $headingLineNumbers.Count | Should -Be 1 -Because "$Name must contain the engagement-gate non-overridability heading exactly once"
        $beginLineNumbers.Count | Should -Be 1 -Because "$Name must contain the engagement-gate non-overridability begin marker exactly once"

        if ($headingLineNumbers.Count -eq 1 -and $beginLineNumbers.Count -eq 1) {
            $lineDistance = $beginLineNumbers[0] - $headingLineNumbers[0]
            $lineDistance | Should -BeGreaterThan 0 -Because "$Name heading must appear above the begin marker"
            $lineDistance | Should -BeLessOrEqual 5 -Because "$Name heading must be within 5 lines above the begin marker"
        }
    }

    It 'plan-authoring approval prompt format requires approval and reject options' {
        $promptFormat = Get-SectionBeforeMarker -RelativePath 'skills\plan-authoring\SKILL.md' `
            -Heading 'Plan Approval Prompt Format' `
            -Marker '<!-- plan-authoring-non-overridability:begin -->'

        $promptFormat | Should -Match ([regex]::Escape('structured-question options')) `
            -Because 'the prompt-format section itself must document the option set contract'
        $promptFormat | Should -Match ([regex]::Escape('explicit approval option')) `
            -Because 'the prompt-format section must require an approval option'
        $promptFormat | Should -Match ([regex]::Escape('reject/non-approval option')) `
            -Because 'the prompt-format section must require a reject or non-approval option'
        $promptFormat | Should -Match ([regex]::Escape('`Reject` or equivalent wording')) `
            -Because 'the prompt-format section must preserve the documented reject-equivalent lever'
    }
}