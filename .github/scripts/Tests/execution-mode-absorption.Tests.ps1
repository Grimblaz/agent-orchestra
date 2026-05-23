#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:PlanAuthoringPath = Join-Path $script:RepoRoot 'skills/plan-authoring/SKILL.md'
    $script:CodeConductorPath = Join-Path $script:RepoRoot 'agents/Code-Conductor.agent.md'
    $script:CodeSmithPath = Join-Path $script:RepoRoot 'agents/Code-Smith.agent.md'

    function script:Get-EMAMarkdownText {
        param(
            [Parameter(Mandatory)]
            [string]$Path
        )

        return [System.IO.File]::ReadAllText($Path)
    }

    function script:Get-EMAMarkdownSection {
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

    function script:Test-EMAContainsTermSet {
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

    function script:Invoke-EMAExecutionModeSemanticScan {
        param(
            [AllowNull()]
            [string]$SectionText
        )

        if ([string]::IsNullOrWhiteSpace($SectionText)) {
            Write-Warning "execution-mode-absorption warn-only: skills/plan-authoring/SKILL.md is missing the '### Execution mode selection' section, so semantic keyword coverage cannot be evaluated."
            return
        }

        $semanticChecks = @(
            [ordered]@{
                Name = 'per-step declaration cue'
                Terms = @('per-step', 'declare')
            },
            [ordered]@{
                Name = 'requirement contract and convergence gates co-occurrence'
                Terms = @('requirement contract', 'convergence gates')
            },
            [ordered]@{
                Name = 'parallel preference cue'
                Terms = @('stable AC', 'low coupling')
            },
            [ordered]@{
                Name = 'serial preference cue'
                Terms = @('ambiguous AC', 'high-risk')
            }
        )

        foreach ($semanticCheck in $semanticChecks) {
            if (-not (script:Test-EMAContainsTermSet -Text $SectionText -Terms $semanticCheck.Terms)) {
                Write-Warning ("execution-mode-absorption warn-only: Execution mode selection is missing semantic cue '{0}' requiring terms: {1}." -f $semanticCheck.Name, [string]::Join(', ', $semanticCheck.Terms))
            }
        }
    }
}

Describe 'Execution mode absorption into plan-authoring' {
    It 'moves execution-mode ownership from Code-Conductor into plan-authoring guidance' {
        $planAuthoring = script:Get-EMAMarkdownText -Path $script:PlanAuthoringPath
        $codeConductor = script:Get-EMAMarkdownText -Path $script:CodeConductorPath
        $codeSmith = script:Get-EMAMarkdownText -Path $script:CodeSmithPath
        $codeConductorOverview = script:Get-EMAMarkdownSection -Markdown $codeConductor -Heading 'Overview' -Level 2
        $executionSkeleton = script:Get-EMAMarkdownSection -Markdown $planAuthoring -Heading '1. Build the Execution Skeleton' -Level 3
        $violations = [System.Collections.Generic.List[string]]::new()

        # AC1
        if ($planAuthoring -notmatch '(?m)^### Execution mode selection\s*$') {
            $violations.Add('AC1: skills/plan-authoring/SKILL.md must contain H3 heading ### Execution mode selection.')
        }

        # AC2
        $staleCodeConductorPhrases = @(
            '**Execution mode policy**: Support both parallel and serial execution. Declare the mode explicitly per implementation step and keep Requirement Contract and convergence gates identical across both modes.',
            '**Execution mode decision rule**:',
            'Prefer **parallel** when requirements are stable, the step is isolated, and fast implementation+test feedback is valuable.',
            'Prefer **serial** when requirements are exploratory, test-first clarification is needed, or implementation complexity/risk is high.',
            'Stable AC + low coupling + clear interfaces',
            'Ambiguous AC or high-risk refactor/dependencies'
        )

        foreach ($stalePhrase in $staleCodeConductorPhrases) {
            if ($codeConductor -match [regex]::Escape($stalePhrase)) {
                $violations.Add("AC2: agents/Code-Conductor.agent.md must remove stale execution-mode policy phrase: $stalePhrase")
            }
        }

        if ([string]::IsNullOrWhiteSpace($codeConductorOverview)) {
            $violations.Add('AC2: agents/Code-Conductor.agent.md must keep an Overview area for the replacement pointer.')
        } else {
            $sectionSign = [char]0x00A7
            $requiredPointerTerms = @(
                [ordered]@{
                    Term = 'skills/plan-authoring/SKILL.md'
                    Message = 'AC2: Code-Conductor Overview must name skills/plan-authoring/SKILL.md.'
                },
                [ordered]@{
                    Term = "$sectionSign Execution mode selection"
                    Message = "AC2: Code-Conductor Overview must point to $sectionSign Execution mode selection."
                },
                [ordered]@{
                    Term = 'per-step execution-mode declaration'
                    Message = 'AC2: Code-Conductor Overview must mention the per-step execution-mode declaration.'
                },
                [ordered]@{
                    Term = 'parallel-vs-serial selection heuristic'
                    Message = 'AC2: Code-Conductor Overview must mention the parallel-vs-serial selection heuristic.'
                },
                [ordered]@{
                    Term = "at runtime, honor the mode surfaced from each plan slice's metadata"
                    Message = "AC2: Code-Conductor Overview must preserve the runtime-consumer clause that honors the mode surfaced from each plan slice's metadata."
                }
            )

            foreach ($requiredPointerTerm in $requiredPointerTerms) {
                if ($codeConductorOverview -notmatch [regex]::Escape($requiredPointerTerm.Term)) {
                    $violations.Add($requiredPointerTerm.Message)
                }
            }
        }

        # AC9
        if ($codeSmith -match [regex]::Escape('declared by Code-Conductor')) {
            $violations.Add("AC9: agents/Code-Smith.agent.md must remove the stale phrase 'declared by Code-Conductor'.")
        }

        # AC10
        if ([string]::IsNullOrWhiteSpace($executionSkeleton)) {
            $violations.Add('AC10: skills/plan-authoring/SKILL.md must keep the ### 1. Build the Execution Skeleton section.')
        } elseif ($executionSkeleton -notmatch [regex]::Escape('Execution mode selection')) {
            $violations.Add('AC10: Build the Execution Skeleton must point forward to Execution mode selection.')
        }

        $violations | Should -BeNullOrEmpty -Because 'execution-mode selection ownership must be absorbed into plan-authoring while downstream agents keep only pointers or consumer guidance'
    }

    It 'requires execution-mode selection guidance to keep semantic-equivalence cues and source provenance' {
        $planAuthoring = script:Get-EMAMarkdownText -Path $script:PlanAuthoringPath
        $executionModeSelection = script:Get-EMAMarkdownSection -Markdown $planAuthoring -Heading 'Execution mode selection' -Level 3

        $executionModeSelection | Should -Not -BeNullOrEmpty -Because 'AC3: skills/plan-authoring/SKILL.md must contain ### Execution mode selection before provenance can be evaluated'

        # AC3
        script:Invoke-EMAExecutionModeSemanticScan -SectionText $executionModeSelection

        $hasCodeConductorPolicyProvenance = $executionModeSelection -match '(?is)(prior|previous|formerly|absorbed|moved|source|provenance).{0,160}Code-Conductor.{0,80}policy|Code-Conductor.{0,80}policy.{0,160}(prior|previous|formerly|absorbed|moved|source|provenance)'
        $hasIssueTraceability = ($executionModeSelection -match [regex]::Escape('#589')) -or ($executionModeSelection -match '(?is)#557.{0,120}responsibility-map disposition|responsibility-map disposition.{0,120}#557')

        $hasCodeConductorPolicyProvenance | Should -BeTrue -Because 'AC3: Execution mode selection must include source/provenance tying the heuristic to the prior Code-Conductor policy'
        $hasIssueTraceability | Should -BeTrue -Because 'AC3: Execution mode selection provenance must cite issue #589 or the #557 responsibility-map disposition'
    }
}