#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
        Contract tests for session-startup skill wording consistency.

.DESCRIPTION
        Locks the contributor-facing startup-check contract in:
            - skills/session-startup/SKILL.md

                The skill must describe the canonical semantics for:
            - one canonical session-memory marker path for the automatic startup guard
            - run-once guard order (guard check before automatic detector run, marker write after first automatic run)
            - fail-open behavior when session-memory access fails
            - manual detector runs remaining allowed after the automatic guard fires

        These tests are RED coverage for issue #345 until the skill exists and carries the full startup contract.
#>

Describe 'session startup wording contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:SessionStartupSkill = Join-Path $script:RepoRoot 'skills\session-startup\SKILL.md'
        $script:CanonicalMarkerPath = '/memories/session/session-startup-check-complete.md'
        $script:CanonicalTriggerText = 'Before the first substantive response in a new conversation, load the `session-startup` skill and follow its protocol.'
        $script:LegacySilentSkipSummary = 'Skip the automatic startup check silently when neither `$env:COPILOT_ORCHESTRA_ROOT` nor `$env:WORKFLOW_TEMPLATE_ROOT` is set, `pwsh` is unavailable, or the detector returns non-JSON output.'
        $script:DetectorCommandPattern = '(?ms)^pwsh -NoProfile -NonInteractive -File "[^"]*skills/session-startup/scripts/session-cleanup-detector\.ps1"\s*$'
        $script:ContractHeadingPattern = '(?m)^### Canonical Automatic Startup Guard Contract\s*$'
        $script:PipelineEntryAgents = @(
            @{
                Name = 'Experience-Owner'
                Path = Join-Path $script:RepoRoot 'agents\Experience-Owner.agent.md'
            },
            @{
                Name = 'Solution-Designer'
                Path = Join-Path $script:RepoRoot 'agents\Solution-Designer.agent.md'
            },
            @{
                Name = 'Issue-Planner'
                Path = Join-Path $script:RepoRoot 'agents\Issue-Planner.agent.md'
            },
            @{
                Name = 'Code-Conductor'
                Path = Join-Path $script:RepoRoot 'agents\Code-Conductor.agent.md'
            }
        )
        $script:ExpectedContract = [ordered]@{
            sessionStartupMarkerPath                    = $script:CanonicalMarkerPath
            checkMarkerBeforeAutomaticDetectorRun       = $true
            recordMarkerAfterFirstAutomaticStartupCheck = $true
            recordMarkerRegardlessOfCleanupChoice       = $true
            failOpenOnSessionMemoryAccessError          = $true
            manualDetectorRunsRemainAllowed             = $true
        }

        $script:GetDocumentState = {
            param([string]$Path)

            Test-Path $Path | Should -BeTrue -Because 'the session-startup skill file must exist as the full startup protocol'
            if (-not (Test-Path $Path)) {
                return @{
                    Path    = $Path
                    Content = ''
                }
            }

            $content = Get-Content -Path $Path -Raw

            return @{
                Path    = $Path
                Content = $content
            }
        }

        $script:GetHeadingIndex = {
            param(
                [string]$Content,
                [string]$HeadingPattern
            )

            $match = [regex]::Match($Content, $HeadingPattern)
            if (-not $match.Success) {
                return $null
            }

            return [int]$match.Index
        }

        $script:GetStepSection = {
            param(
                [string]$Content,
                [int]$StepNumber
            )

            $stepPattern = '(?ms)^### Step ' + $StepNumber + ' [^\r\n]*\r?\n(?<body>.*?)(?=^### Step \d+ [^\r\n]*\r?\n|^## |\z)'
            $match = [regex]::Match($Content, $stepPattern)
            if (-not $match.Success) {
                return ''
            }

            return $match.Value
        }

        $script:GetCanonicalContract = {
            param([string]$Content)

            $blockPattern = '(?ms)^### Canonical Automatic Startup Guard Contract\s*\r?\n\r?\n```json\r?\n(?<json>\{.*?\})\r?\n```'
            $match = [regex]::Match($Content, $blockPattern)
            if (-not $match.Success) {
                return @{}
            }

            return $match.Groups['json'].Value | ConvertFrom-Json -AsHashtable
        }

        $script:ConvertToCanonicalJson = {
            param([object]$Value)

            return ($Value | ConvertTo-Json -Depth 10 -Compress)
        }
    }

    It 'requires the session-startup skill to use the canonical session marker path in the guard lifecycle steps' {
        $skill = & $script:GetDocumentState -Path $script:SessionStartupSkill
        $step2 = & $script:GetStepSection -Content $skill.Content -StepNumber 2
        $step4 = & $script:GetStepSection -Content $skill.Content -StepNumber 4

        $step2 | Should -Match ([regex]::Escape($script:CanonicalMarkerPath)) -Because 'the session-startup skill Step 2 must name the canonical session-memory marker path'
        $step4 | Should -Match ([regex]::Escape($script:CanonicalMarkerPath)) -Because 'the session-startup skill Step 4 must record the same canonical session-memory marker path'
    }

    It 'requires the four pipeline-entry agents to carry the session-startup trigger stub with the canonical wording shape' {
        $script:PipelineEntryAgents.Count | Should -Be 4 -Because 'the startup trigger contract is owned by exactly the four pipeline-entry agents'

        foreach ($agent in $script:PipelineEntryAgents) {
            $document = & $script:GetDocumentState -Path $agent.Path
            $content = $document.Content
            $topBodyMatch = [regex]::Match($content, '(?ms)\A---\r?\n.*?^---[ \t]*\r?\n(?<topBody>.*?)(?=^## |\z)')
            $processSectionMatch = [regex]::Match($content, '(?ms)^## Process\s*\r?\n(?<body>.*?)(?=^## |\z)')

            $topBodyMatch.Success | Should -BeTrue -Because "$($agent.Name) must keep a bounded top-of-body region between frontmatter and the first section heading"
            $processSectionMatch.Success | Should -BeTrue -Because "$($agent.Name) must keep a bounded Process section for provenance-gate instructions"

            $topBody = $topBodyMatch.Groups['topBody'].Value
            $processSection = $processSectionMatch.Groups['body'].Value

            ([regex]::Matches($content, [regex]::Escape($script:CanonicalTriggerText))).Count | Should -Be 1 -Because "$($agent.Name) must include the startup trigger exactly once"
            $topBody | Should -Match ('(?ms)\S.*\r?\n\r?\n' + [regex]::Escape($script:CanonicalTriggerText) + '\s*\z') -Because "$($agent.Name) must make the startup trigger the final top-of-body paragraph immediately before the first section heading"
            $processSection | Should -Not -Match ([regex]::Escape($script:CanonicalTriggerText)) -Because "$($agent.Name) must not retain the startup trigger inside its Process section"
            $content | Should -Not -Match ([regex]::Escape($script:LegacySilentSkipSummary)) -Because "$($agent.Name) must not retain the legacy silent-skip summary anywhere in the file"
        }
    }

    It 'requires the session-startup skill to publish the canonical automatic startup guard contract' {
        $skill = & $script:GetDocumentState -Path $script:SessionStartupSkill
        $expectedJson = & $script:ConvertToCanonicalJson -Value $script:ExpectedContract

        $headingIndex = & $script:GetHeadingIndex -Content $skill.Content -HeadingPattern $script:ContractHeadingPattern
        ($null -ne $headingIndex) | Should -BeTrue -Because 'the session-startup skill must include the canonical automatic startup guard contract heading'

        $contract = & $script:GetCanonicalContract -Content $skill.Content
        (& $script:ConvertToCanonicalJson -Value $contract) | Should -Be $expectedJson -Because 'the session-startup skill must publish the exact startup guard contract'
    }

    It 'requires the session-startup skill to describe the run-once guard in the canonical order' {
        $skill = & $script:GetDocumentState -Path $script:SessionStartupSkill
        $guardCheck = & $script:GetHeadingIndex -Content $skill.Content -HeadingPattern '(?m)^### Step 2 — Check the automatic run-once guard\s*$'
        $detectorInvocation = & $script:GetHeadingIndex -Content $skill.Content -HeadingPattern '(?m)^### Step 3 — Run the detector(?: script)?\s*$'
        $markerWrite = & $script:GetHeadingIndex -Content $skill.Content -HeadingPattern '(?m)^### Step 4 — Record the run-once marker\s*$'

        ($null -ne $guardCheck) | Should -BeTrue -Because 'the session-startup skill must describe checking the session-memory marker before the automatic detector run'
        ($null -ne $detectorInvocation) | Should -BeTrue -Because 'the session-startup skill must still describe the automatic detector invocation'
        ($null -ne $markerWrite) | Should -BeTrue -Because 'the session-startup skill must describe recording the run-once marker after the first automatic startup check'

        ($guardCheck -lt $detectorInvocation) | Should -BeTrue -Because 'the session-startup skill must place the run-once guard before the detector command'
        ($detectorInvocation -lt $markerWrite) | Should -BeTrue -Because 'the session-startup skill must place marker recording after the first automatic detector run'
    }

    It 'requires the session-startup skill to preserve the detector command and fail-open/manual semantics' {
        $skill = & $script:GetDocumentState -Path $script:SessionStartupSkill
        $content = $skill.Content
        $step3 = & $script:GetStepSection -Content $content -StepNumber 3
        $step4 = & $script:GetStepSection -Content $content -StepNumber 4
        $step8 = & $script:GetStepSection -Content $content -StepNumber 8

        $step3 | Should -Match $script:DetectorCommandPattern -Because 'the session-startup skill must preserve the automatic detector command'
        $step4 | Should -Match '(?is)(fail open).{0,200}(allow later automatic checks|still run the detector)' -Because 'the session-startup skill must state that session-memory write failures fail open'
        $step8 | Should -Match '(?is)(explicit|manual).{0,80}(manual|detector).{0,160}(remain|still).{0,120}(allowed|possible|available)' -Because 'the session-startup skill must keep manual detector invocation available after the automatic startup check'
    }
}
