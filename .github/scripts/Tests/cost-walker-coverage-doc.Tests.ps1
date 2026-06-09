#Requires -Version 7.0

Describe 'cost walker coverage design documentation' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:DocPath = Join-Path $script:RepoRoot 'Documents/Design/cost-walker-coverage.md'
        $script:ExpectedH2Headings = @(
            '## Active attribution rules'
            '## Ambiguous-prompt fallback'
            '## Known gaps'
            '## Rejected alternatives summary'
        )
    }

    It 'documents cost walker coverage at the required design path' {
        Test-Path -LiteralPath $script:DocPath | Should -BeTrue -Because 'issue #529 Step 5 requires Documents/Design/cost-walker-coverage.md'
    }

    It 'keeps the required H2 headings byte-exact and in order' {
        $content = Get-Content -Path $script:DocPath -Raw -ErrorAction Stop
        $normalizedContent = $content -replace "`r`n?", "`n"
        $actualHeadings = @(
            [regex]::Matches($normalizedContent, '(?m)^## .+$') |
                ForEach-Object { $_.Value }
        )

        $actualHeadings | Should -BeExactly $script:ExpectedH2Headings -Because 'AC5 locks the required cost walker coverage documentation sections'
    }

    It 'keeps the lead-in before the first H2 customer-readable' {
        $content = Get-Content -Path $script:DocPath -Raw -ErrorAction Stop
        $normalizedContent = $content -replace "`r`n?", "`n"
        $firstHeadingIndex = $normalizedContent.IndexOf('## ')

        $firstHeadingIndex | Should -BeGreaterThan 0 -Because 'the document must open with a lead-in paragraph before the first H2'

        $leadIn = $normalizedContent.Substring(0, $firstHeadingIndex).Trim()
        $leadIn | Should -Not -BeNullOrEmpty -Because 'the lead-in must explain the customer-facing cost attribution behavior'
        $leadIn | Should -Not -Match '<command-name>' -Because 'XML marker details belong in the maintainer subsection, not the lead-in'
        $leadIn | Should -Not -Match '```' -Because 'the lead-in must not contain code fences or regex-like fenced content'
    }

    It 'links the known gap to issue 488' {
        $content = Get-Content -Path $script:DocPath -Raw -ErrorAction Stop

        $content | Should -Match ([regex]::Escape('https://github.com/Grimblaz/agent-orchestra/issues/488')) -Because 'the known gaps section must link the subagent-name dispatch follow-up'
    }
}
