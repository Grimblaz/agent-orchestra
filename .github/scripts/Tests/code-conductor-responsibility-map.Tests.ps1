#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:ResponsibilityMapPath = Join-Path $script:RepoRoot 'Documents/Design/code-conductor-responsibility-map.md'

    function script:Get-CCRMIssueBody {
        $body = & gh issue view 557 --json body --jq .body 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to fetch issue #557 body via 'gh issue view 557 --json body --jq .body': $($body -join [Environment]::NewLine)"
        }

        return ($body -join "`n")
    }

    function script:Get-CCRMCoverageTargets {
        param(
            [Parameter(Mandatory)]
            [string]$IssueBody
        )

        $coverageSectionMatch = [regex]::Match($IssueBody, '(?ms)^### Coverage target\s*(?<section>.*?)(?=^###\s|\z)')
        if (-not $coverageSectionMatch.Success) {
            throw "Issue #557 body does not contain a '### Coverage target' section."
        }

        $coverageSection = $coverageSectionMatch.Groups['section'].Value
        $targetListMatch = [regex]::Match(
            $coverageSection,
            '(?ms)\bbody covers\s+(?<targets>.*?)\.\s+Each is in scope'
        )

        if (-not $targetListMatch.Success) {
            $targetListMatch = [regex]::Match(
                $coverageSection,
                '(?ms)Integration test 1.*?For each named section enumerated in\s+`### Coverage target`\s*\((?<targets>.*?)\)\s*,\s*assert'
            )
        }

        if (-not $targetListMatch.Success) {
            throw "Could not extract the coverage-target section list from issue #557."
        }

        return @(
            $targetListMatch.Groups['targets'].Value -split ',' |
                ForEach-Object { ($_ -replace '^\s*and\s+(the\s+)?', '' -replace '\s+section\s*$', '').Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
    }

    function script:ConvertTo-CCRMComparableText {
        param(
            [AllowNull()]
            [string]$Text
        )

        if ([string]::IsNullOrWhiteSpace($Text)) {
            return ''
        }

        return (($Text -replace '[\u2010-\u2015]', '-' -replace 'ΓÇô', '-') -replace '\s+', ' ').Trim()
    }

    function script:Get-CCRMRowSource {
        param(
            [Parameter(Mandatory)]
            [object]$Row
        )

        if ($Row -is [System.Collections.IDictionary]) {
            return [string]$Row['source']
        }

        return [string]$Row.source
    }

    function script:Get-CCRMResponsibilityRows {
        param(
            [Parameter(Mandatory)]
            [string]$MapPath
        )

        $yamlParser = Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue
        if (-not $yamlParser) {
            throw 'ConvertFrom-Yaml is required to parse the responsibility map YAML for this fail-the-build coverage test.'
        }

        $content = Get-Content -Path $MapPath -Raw -ErrorAction Stop
        $yamlMatch = [regex]::Match($content, '(?ms)^## Responsibilities\s*\r?\n\r?\n```yaml\r?\n(?<yaml>.*?)\r?\n```')
        if (-not $yamlMatch.Success) {
            throw "Could not find the fenced YAML block under '## Responsibilities' in $MapPath."
        }

        try {
            $parsedRows = $yamlMatch.Groups['yaml'].Value | ConvertFrom-Yaml -ErrorAction Stop
        } catch {
            throw "Could not parse responsibility-map YAML: $($_.Exception.Message)"
        }

        if ($parsedRows -is [System.Collections.IDictionary] -or $parsedRows -is [string]) {
            return $parsedRows
        }

        foreach ($row in $parsedRows) {
            $row
        }
    }
}

Describe 'Code-Conductor responsibility map — coverage completeness' {
    It 'lists every issue-declared coverage target as a responsibility-map source' {
        $issueBody = script:Get-CCRMIssueBody
        $expectedSections = script:Get-CCRMCoverageTargets -IssueBody $issueBody
        $rows = script:Get-CCRMResponsibilityRows -MapPath $script:ResponsibilityMapPath

        $expectedSections | Should -Not -BeNullOrEmpty -Because 'issue #557 must declare the expected coverage targets in its Coverage target section'
        $rows | Should -Not -BeNullOrEmpty -Because 'the responsibility map must expose YAML responsibility rows'
        $rows.Count | Should -BeGreaterThan $expectedSections.Count -Because 'the responsibility map must parse as individual responsibility rows, not as one collection wrapper that member-enumerates source values'

        $sources = @(
            $rows |
                ForEach-Object { script:Get-CCRMRowSource -Row $_ } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                ForEach-Object { script:ConvertTo-CCRMComparableText -Text $_ }
        )

        $missingSections = @(
            foreach ($section in $expectedSections) {
                $expectedSection = script:ConvertTo-CCRMComparableText -Text $section
                $matchingSource = $sources | Where-Object { $_.IndexOf($expectedSection, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 } | Select-Object -First 1

                if (-not $matchingSource) {
                    $section
                }
            }
        )

        $missingSections | Should -BeNullOrEmpty -Because "each section named in issue #557's Coverage target Integration test 1 list must appear as a source value in the responsibility map"
    }
}