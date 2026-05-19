#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#!
.SYNOPSIS
    Contract tests for issue #579 plan-authoring tree-state verification discipline.

.DESCRIPTION
    Locks the RED assertion-existence contract for AC1-AC4: the plan-authoring skill
    must define the discipline, the plan template must carry verification evidence,
    and Issue-Planner must run the discipline before adversarial stress testing.
#>

Describe 'Plan-authoring tree-state verification contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:PlanAuthoringPath = Join-Path $script:RepoRoot 'skills\plan-authoring\SKILL.md'
        $script:IssuePlannerPath = Join-Path $script:RepoRoot 'agents\Issue-Planner.agent.md'

        $script:GetNormalizedContent = {
            param([string]$Path)

            return ((Get-Content -Path $Path -Raw -ErrorAction Stop) -replace "`r`n?", "`n")
        }

        $script:GetMarkdownSection = {
            param(
                [string]$Content,
                [string]$Heading
            )

            $headingMatch = [regex]::Match($Content, ('(?m)^{0}\s*$' -f [regex]::Escape($Heading)))
            if (-not $headingMatch.Success) {
                return ''
            }

            $bodyStart = $headingMatch.Index + $headingMatch.Length
            $remaining = $Content.Substring($bodyStart)
            $nextHeading = [regex]::Match($remaining, '(?m)^##\s+')

            if ($nextHeading.Success) {
                return $remaining.Substring(0, $nextHeading.Index)
            }

            return $remaining
        }

        $script:GetContentBetween = {
            param(
                [string]$Content,
                [string]$StartText,
                [string]$EndText
            )

            $startIndex = $Content.IndexOf($StartText, [System.StringComparison]::Ordinal)
            $endIndex = $Content.IndexOf($EndText, [System.StringComparison]::Ordinal)

            if ($startIndex -lt 0 -or $endIndex -lt 0 -or $endIndex -le $startIndex) {
                return ''
            }

            return $Content.Substring($startIndex, $endIndex - $startIndex)
        }

        $script:PlanAuthoringContent = & $script:GetNormalizedContent -Path $script:PlanAuthoringPath
        $script:TreeStateSection = & $script:GetMarkdownSection -Content $script:PlanAuthoringContent -Heading '## Tree-State Verification Discipline'
        $script:IssuePlannerContent = & $script:GetNormalizedContent -Path $script:IssuePlannerPath
    }

    It 'defines the Tree-State Verification Discipline H2 in the plan-authoring skill' {
        $script:PlanAuthoringContent | Should -Match '(?m)^## Tree-State Verification Discipline\s*$' -Because 'the /plan methodology must expose the discipline as a stable H2 anchor'
    }

    It 'defines the five required verification category H3 subsections under the discipline H2' {
        $expectedHeadings = @(
            '### Text-presence',
            '### Structure-presence',
            '### Downstream-consumer',
            '### Numeric-or-structural',
            '### Named-standard'
        )

        foreach ($heading in $expectedHeadings) {
            $script:TreeStateSection | Should -Match ('(?m)^{0}\s*$' -f [regex]::Escape($heading)) -Because "$heading should be a stable subsection below Tree-State Verification Discipline"
        }
    }

    It 'defines load-bearing ACs, category precedence, scope guard, boundary examples, and the disposition enum' {
        $script:TreeStateSection | Should -Match '(?i)\bload-bearing AC\b' -Because 'the discipline must define the ACs that require live tree-state evidence'

        $script:TreeStateSection | Should -Match '(?is)text-presence.*structure-presence.*downstream-consumer.*numeric-or-structural.*named-standard' -Because 'the five category tokens should appear in precedence order'

        $script:TreeStateSection | Should -Match '(?i)(scope[- ]guard|non-load-bearing)' -Because 'the discipline must say what falls outside load-bearing verification scope'

        ([regex]::Matches($script:TreeStateSection, '(?i)\bboundary example\b|\bexample\b').Count) | Should -BeGreaterOrEqual 2 -Because 'the discipline must include at least two worked boundary examples'

        $script:TreeStateSection | Should -Match '(?i)verified\s*\|\s*revised\s*\|\s*exempted\s*\|\s*planned' -Because 'the disposition enum must include exactly the four planned values in the discipline section'
    }

    It 'adds the Verification Evidence block to the plan markdown template between Verification and Decisions' {
        $templateBetweenHeadings = & $script:GetContentBetween -Content $script:PlanAuthoringContent -StartText '**Verification**' -EndText '**Decisions**'

        $templateBetweenHeadings | Should -Not -Be '' -Because 'the existing plan template should keep Verification before Decisions'
        $templateBetweenHeadings | Should -Match '<!-- verification-evidence -->' -Because 'the template must include the stable evidence-block marker between Verification and Decisions'
        $templateBetweenHeadings | Should -Match '\*\*Verification Evidence\*\*' -Because 'the template must include the human-readable evidence heading between Verification and Decisions'
    }

    It 'directs Issue-Planner to run tree-state verification before adversarial stress testing' {
        $stressTestAnchor = 'Before presenting the plan, run the three-pass adversarial stress test'
        $stressTestIndex = $script:IssuePlannerContent.IndexOf($stressTestAnchor, [System.StringComparison]::Ordinal)

        $stressTestIndex | Should -BeGreaterOrEqual 0 -Because 'the existing adversarial stress-test directive is the placement anchor'

        $contentBeforeStressTest = $script:IssuePlannerContent.Substring(0, $stressTestIndex)
        $directiveLines = @(
            $contentBeforeStressTest -split "`n" |
                Where-Object {
                    $_ -match '(?i)(tree-state[- ]verification|Tree-State Verification Discipline)' -and
                    $_ -match '(?i)\b(run|apply|execute|populate|populating)\b' -and
                    $_ -match [regex]::Escape('skills/plan-authoring/SKILL.md') -and
                    $_ -match '(?i)Verification Evidence'
                }
        )

        $directiveLines.Count | Should -BeGreaterThan 0 -Because 'Issue-Planner should run the discipline and populate Verification Evidence before stress testing the plan'
    }
}