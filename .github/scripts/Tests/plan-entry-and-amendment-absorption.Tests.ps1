#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:PlanAuthoringPath = Join-Path $script:RepoRoot 'skills/plan-authoring/SKILL.md'
    $script:CodeConductorPath = Join-Path $script:RepoRoot 'agents/Code-Conductor.agent.md'
    $script:SpineRunnerPath = Join-Path $script:RepoRoot 'agents/Spine-Runner.agent.md'
    $script:ResponsibilityMapPath = Join-Path $script:RepoRoot 'Documents/Design/code-conductor-responsibility-map.md'

    function script:Get-PEAMMarkdownText {
        param(
            [Parameter(Mandatory)]
            [string]$Path
        )

        return [System.IO.File]::ReadAllText($Path)
    }

    function script:Get-PEAMMarkdownSection {
        param(
            [Parameter(Mandatory)]
            [string]$Markdown,

            [Parameter(Mandatory)]
            [string]$Heading,

            [Parameter(Mandatory)]
            [ValidateRange(1, 6)]
            [int]$Level
        )

        $headingMarker = '#' * $Level
        $escapedHeading = [regex]::Escape($Heading)
        $nextSameOrHigherHeadingPattern = if ($Level -eq 1) { '#{1}' } else { "#{1,$Level}" }
        $sectionMatch = [regex]::Match(
            $Markdown,
            "(?ms)^$headingMarker\s+$escapedHeading\s*\r?\n(?<section>.*?)(?=^$nextSameOrHigherHeadingPattern\s+|\z)"
        )

        if (-not $sectionMatch.Success) {
            return $null
        }

        return $sectionMatch.Groups['section'].Value
    }

    function script:Get-PEAMMarkdownH2Heading {
        param(
            [Parameter(Mandatory)]
            [string]$Markdown
        )

        return @(
            [regex]::Matches($Markdown, '(?m)^##\s+(?<heading>.+?)\s*$') | ForEach-Object {
                [pscustomobject]@{
                    Heading = $_.Groups['heading'].Value
                    Index   = $_.Index
                }
            }
        )
    }

    function script:Test-PEAMHasAdjacentH2Sequence {
        param(
            [Parameter(Mandatory)]
            [string]$Markdown,

            [Parameter(Mandatory)]
            [string[]]$Headings
        )

        $h2Headings = @(script:Get-PEAMMarkdownH2Heading -Markdown $Markdown)
        $positions = @()

        foreach ($heading in $Headings) {
            $headingMatches = @($h2Headings | Where-Object { $_.Heading -eq $heading })
            if ($headingMatches.Count -ne 1) {
                return $false
            }

            $positions += [array]::IndexOf($h2Headings, $headingMatches[0])
        }

        for ($index = 1; $index -lt $positions.Count; $index++) {
            if ($positions[$index] -ne ($positions[$index - 1] + 1)) {
                return $false
            }

            if ($h2Headings[$positions[$index]].Index -le $h2Headings[$positions[$index - 1]].Index) {
                return $false
            }
        }

        return $true
    }

    function script:Get-PEAMResponsibilityRow {
        param(
            [Parameter(Mandatory)]
            [string]$Markdown
        )

        return @(
            [regex]::Matches($Markdown, '(?ms)^-\s+source:\s+.*?(?=^-\s+source:\s+|^```\s*$|\z)') | ForEach-Object {
                $_.Value
            }
        )
    }

    function script:Get-PEAMIssueTransitionSection {
        param(
            [Parameter(Mandatory)]
            [string]$Markdown
        )

        $coreWorkflow = script:Get-PEAMMarkdownSection -Markdown $Markdown -Heading 'Core Workflow' -Level 2
        if ([string]::IsNullOrWhiteSpace($coreWorkflow)) {
            return $null
        }

        $stepMatch = [regex]::Match(
            $coreWorkflow,
            '(?ms)^0\.\s+\*\*Issue Transition \(Step 0, before implementation\)\*\*:\s*\r?\n(?<section>.*?)(?=^\s*(?:\d+\.|#{1,6}\s+)|\z)'
        )

        if (-not $stepMatch.Success) {
            return $null
        }

        return $stepMatch.Groups['section'].Value
    }

    function script:Test-PEAMContainsTermSet {
        param(
            [Parameter(Mandatory)]
            [string]$Text,

            [Parameter(Mandatory)]
            [string[]]$Terms
        )

        foreach ($term in $Terms) {
            if ($Text -notmatch [regex]::Escape($term)) {
                return $false
            }
        }

        return $true
    }

    function script:Test-PEAMHasPointerLine {
        param(
            [AllowNull()]
            [string]$Text
        )

        return -not [string]::IsNullOrWhiteSpace($Text) -and $Text -match '(?im)^\s*[-*]\s+.*Plan Entry and Amendment Triggers\b'
    }

    function script:Invoke-PEAMSemanticScan {
        param(
            [AllowNull()]
            [string]$SectionText
        )

        if ([string]::IsNullOrWhiteSpace($SectionText)) {
            Write-Warning "plan-entry-and-amendment-absorption warn-only: skills/plan-authoring/SKILL.md is missing the '## Plan Entry and Amendment Triggers' section, so semantic keyword coverage cannot be evaluated."
            return
        }

        $semanticChecks = @(
            [ordered]@{
                Name  = 'well-defined entry cue'
                Terms = @('well-defined', 'direct execution plan')
            },
            [ordered]@{
                Name  = 'exploratory entry cue'
                Terms = @('exploratory', 'stabilize')
            }
        )

        foreach ($semanticCheck in $semanticChecks) {
            if (-not (script:Test-PEAMContainsTermSet -Text $SectionText -Terms $semanticCheck.Terms)) {
                Write-Warning ("plan-entry-and-amendment-absorption warn-only: Plan Entry and Amendment Triggers is missing semantic cue '{0}' requiring terms: {1}." -f $semanticCheck.Name, [string]::Join(', ', $semanticCheck.Terms))
            }
        }

        $hasAmendmentCue = (
            $SectionText -match '(?i)\bscope\b' -and
            $SectionText -match '(?i)\bacceptance criteria\b' -and
            $SectionText -match '(?i)\bambiguous\b' -and
            (
                $SectionText -match '(?i)\bIssue-Planner\b' -or
                $SectionText -match '(?i)\bamendment\b' -or
                $SectionText -match '(?i)\bbefore runtime execution\b'
            )
        )

        if (-not $hasAmendmentCue) {
            Write-Warning "plan-entry-and-amendment-absorption warn-only: Plan Entry and Amendment Triggers is missing the amendment trigger cue involving scope, acceptance criteria, ambiguity, and Issue-Planner/amendment/before-runtime-execution language."
        }

        if ($SectionText -notmatch '(?im)^\s*Provenance:') {
            Write-Warning "plan-entry-and-amendment-absorption warn-only: Plan Entry and Amendment Triggers is missing a Provenance: line."
        }

        if ($SectionText -notmatch '(?im)^\s*Quick checklist\b') {
            Write-Warning "plan-entry-and-amendment-absorption warn-only: Plan Entry and Amendment Triggers is missing a Quick checklist marker."
        }

        $hasRationaleCue = $SectionText -match '(?is)\b(because|when|why)\b.{0,180}\b(stable|ambiguous|drift|stale)\b.{0,180}\b(criteria|acceptance criteria|scope)\b|\b(stable|ambiguous|drift|stale)\b.{0,180}\b(criteria|acceptance criteria|scope)\b.{0,180}\b(because|when|why)\b'
        if (-not $hasRationaleCue) {
            Write-Warning "plan-entry-and-amendment-absorption warn-only: Plan Entry and Amendment Triggers is missing rationale cues pairing because/when/why with stable, ambiguous, drift, or stale criteria concepts."
        }
    }
}

Describe 'Plan entry and amendment absorption into plan-authoring' {
    It 'keeps plan-entry and plan-amendment ownership in plan-authoring while agents retain only pointers' {
        $planAuthoring = script:Get-PEAMMarkdownText -Path $script:PlanAuthoringPath
        $codeConductor = script:Get-PEAMMarkdownText -Path $script:CodeConductorPath
        $spineRunner = script:Get-PEAMMarkdownText -Path $script:SpineRunnerPath
        $responsibilityMap = script:Get-PEAMMarkdownText -Path $script:ResponsibilityMapPath
        $planEntryAndAmendmentTriggers = script:Get-PEAMMarkdownSection -Markdown $planAuthoring -Heading 'Plan Entry and Amendment Triggers' -Level 2
        $planCreationStrategy = script:Get-PEAMMarkdownSection -Markdown $codeConductor -Heading 'Plan Creation Strategy' -Level 2
        $issueTransition = script:Get-PEAMIssueTransitionSection -Markdown $codeConductor
        $violations = [System.Collections.Generic.List[string]]::new()

        # AC1
        if ($planAuthoring -notmatch '(?m)^## Plan Entry and Amendment Triggers\s*$') {
            $violations.Add('AC1: skills/plan-authoring/SKILL.md must contain H2 heading ## Plan Entry and Amendment Triggers.')
        }

        if (-not (script:Test-PEAMHasAdjacentH2Sequence -Markdown $planAuthoring -Headings @('Purpose', 'Plan Entry and Amendment Triggers', 'Discovery Workflow'))) {
            $violations.Add('AC1: skills/plan-authoring/SKILL.md must keep H2 adjacency/order as ## Purpose, then ## Plan Entry and Amendment Triggers, then ## Discovery Workflow.')
        }

        if ([string]::IsNullOrWhiteSpace($planEntryAndAmendmentTriggers)) {
            $violations.Add('AC1: skills/plan-authoring/SKILL.md must include content under ## Plan Entry and Amendment Triggers.')
        }
        else {
            foreach ($requiredProvenanceTerm in @(
                    '08c55e7bbf9ca2386a20fc6db2aaa931a626798d',
                    'agents/Code-Conductor.agent.md',
                    '107-110',
                    '130',
                    '#557',
                    '#590'
                )) {
                if (-not $planEntryAndAmendmentTriggers.Contains($requiredProvenanceTerm)) {
                    $violations.Add("F3: Plan Entry and Amendment Triggers provenance must include '$requiredProvenanceTerm'.")
                }
            }
        }

        # AC10 / F3
        $issue590Action = 'Absorbed by issue https://github.com/Grimblaz/agent-orchestra/issues/590 into skills/plan-authoring/SKILL.md {0} Plan Entry and Amendment Triggers' -f ([char]0x00A7)
        $issue590ActionOccurrences = [regex]::Matches($responsibilityMap, [regex]::Escape($issue590Action)).Count
        if ($issue590ActionOccurrences -ne 2) {
            $violations.Add("F3: Documents/Design/code-conductor-responsibility-map.md must contain exactly two occurrences of the #590 absorption action; found $issue590ActionOccurrences.")
        }

        $issue590Rows = @(
            script:Get-PEAMResponsibilityRow -Markdown $responsibilityMap | Where-Object {
                $_ -match ("(?m)^\s*action:\s+`"{0}`"\s*$" -f [regex]::Escape($issue590Action))
            }
        )

        if ($issue590Rows.Count -ne 2) {
            $violations.Add("F3: Responsibility map must contain exactly two structured rows with the #590 absorption action; found $($issue590Rows.Count).")
        }

        foreach ($issue590Row in $issue590Rows) {
            if ($issue590Row -notmatch '(?m)^\s*verification_status:\s+verified\s*$') {
                $violations.Add('F3: Each #590 responsibility-map row must have verification_status: verified.')
            }

            if ($issue590Row -notmatch '(?m)^\s*verified-against-sha:\s+"467f0ee5111e6417b653341ae1090ea7c698aea6"\s*$') {
                $violations.Add('AC10/F3: Each #590 responsibility-map row must keep verified-against-sha as the post-pointer Code-Conductor blob 467f0ee5111e6417b653341ae1090ea7c698aea6.')
            }
        }

        # AC2, AC8, AC9
        if ([string]::IsNullOrWhiteSpace($planCreationStrategy)) {
            $violations.Add('AC2: agents/Code-Conductor.agent.md must keep a Plan Creation Strategy section for the replacement pointer.')
        }
        else {
            if ($planCreationStrategy -match '(?i)well-defined scope|exploratory scope') {
                $violations.Add("AC2: Code-Conductor Plan Creation Strategy must not retain 'well-defined scope' or 'exploratory scope' heuristics.")
            }

            if (-not (script:Test-PEAMHasPointerLine -Text $planCreationStrategy)) {
                $violations.Add('AC2: Code-Conductor Plan Creation Strategy must include a pointer line referencing Plan Entry and Amendment Triggers.')
            }

            if ($planCreationStrategy -notmatch [regex]::Escape('If plan assumptions drift from code reality')) {
                $violations.Add("AC9: Code-Conductor Plan Creation Strategy must preserve the spine-runner-keeps bullet beginning 'If plan assumptions drift from code reality'.")
            }

            if ($planCreationStrategy -notmatch [regex]::Escape('No scope exemption')) {
                $violations.Add("AC9: Code-Conductor Plan Creation Strategy must preserve the spine-runner-keeps bullet containing 'No scope exemption'.")
            }
        }

        # AC3, AC8
        if ([string]::IsNullOrWhiteSpace($issueTransition)) {
            $violations.Add('AC3: agents/Code-Conductor.agent.md must keep the Step 0 Issue Transition section for the replacement pointer.')
        }
        else {
            if ($issueTransition -match '(?i)Optional planning lane|scope/acceptance criteria changed') {
                $violations.Add("AC3: Code-Conductor Step 0 Issue Transition must not retain 'Optional planning lane' or 'scope/acceptance criteria changed' heuristics.")
            }

            if (-not (script:Test-PEAMHasPointerLine -Text $issueTransition)) {
                $violations.Add('AC3: Code-Conductor Step 0 Issue Transition must include a pointer line referencing Plan Entry and Amendment Triggers.')
            }
        }

        # AC8
        $spineRunnerHeuristicMatches = [regex]::Matches(
            $spineRunner,
            'plan-entry|plan-amendment|well-defined scope|exploratory scope',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )

        if ($spineRunnerHeuristicMatches.Count -ne 0) {
            $violations.Add('AC8: agents/Spine-Runner.agent.md must contain zero plan-entry/amendment heuristic matches for plan-entry|plan-amendment|well-defined scope|exploratory scope.')
        }

        $violations | Should -BeNullOrEmpty -Because 'plan-entry and plan-amendment trigger ownership must be absorbed into plan-authoring while runtime agents keep only pointers or independent spine-runner guidance'
    }
}

Describe 'Plan entry and amendment semantic-equivalence cues (warn-only)' {
    It 'reports missing semantic-equivalence and rationale cues without failing the suite' {
        $planAuthoring = script:Get-PEAMMarkdownText -Path $script:PlanAuthoringPath
        $planEntryAndAmendmentTriggers = script:Get-PEAMMarkdownSection -Markdown $planAuthoring -Heading 'Plan Entry and Amendment Triggers' -Level 2

        script:Invoke-PEAMSemanticScan -SectionText $planEntryAndAmendmentTriggers
    }
}