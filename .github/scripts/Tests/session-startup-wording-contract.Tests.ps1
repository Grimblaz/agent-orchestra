#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Contract tests for startup-instruction wording consistency.

.DESCRIPTION
    Locks the contributor-facing startup-check contract across:
      - .github/copilot-instructions.md
      - .github/instructions/session-startup.instructions.md

        The files must describe the same semantics for:
            - one canonical session-memory marker path for the automatic startup guard
            - run-once guard order (guard check before automatic detector run, marker write after first automatic run)
            - fail-open behavior when session-memory access fails
            - manual detector runs remaining allowed after the automatic guard fires

    These tests are RED coverage for issue #185 until both documents are aligned.
#>

Describe 'session startup wording contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:CopilotInstructions = Join-Path $script:RepoRoot '.github\copilot-instructions.md'
        $script:StartupInstructions = Join-Path $script:RepoRoot '.github\instructions\session-startup.instructions.md'
        $script:CanonicalMarkerPath = '/memories/session/session-startup-check-complete.md'
        $script:DetectorCommandPattern = '(?ms)^pwsh -NoProfile -NonInteractive -File "\$copilotRoot/\.github/scripts/session-cleanup-detector\.ps1"\s*$'
        $script:ContractHeadingPattern = '(?m)^### Canonical Automatic Startup Guard Contract\s*$'
        $script:ExpectedContract = [ordered]@{
            sessionStartupMarkerPath = $script:CanonicalMarkerPath
            checkMarkerBeforeAutomaticDetectorRun = $true
            recordMarkerAfterFirstAutomaticStartupCheck = $true
            recordMarkerRegardlessOfCleanupChoice = $true
            failOpenOnSessionMemoryAccessError = $true
            manualDetectorRunsRemainAllowed = $true
        }

        $script:GetDocumentState = {
            param([string]$Path)

            $content = Get-Content -Path $Path -Raw

            return @{
                Path = $Path
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
                throw "Could not find Step $StepNumber section."
            }

            return $match.Value
        }

        $script:GetCanonicalContract = {
            param([string]$Content)

            $blockPattern = '(?ms)^### Canonical Automatic Startup Guard Contract\s*\r?\n\r?\n```json\r?\n(?<json>\{.*?\})\r?\n```'
            $match = [regex]::Match($Content, $blockPattern)
            if (-not $match.Success) {
                throw 'Could not find canonical automatic startup guard contract JSON block.'
            }

            return $match.Groups['json'].Value | ConvertFrom-Json -AsHashtable
        }

        $script:ConvertToCanonicalJson = {
            param([object]$Value)

            return ($Value | ConvertTo-Json -Depth 10 -Compress)
        }
    }

    It 'requires both documents to use the canonical session marker path in the guard lifecycle steps' {
        $docs = @(
            @{ Name = 'copilot-instructions'; State = & $script:GetDocumentState -Path $script:CopilotInstructions },
            @{ Name = 'session-startup.instructions'; State = & $script:GetDocumentState -Path $script:StartupInstructions }
        )

        foreach ($doc in $docs) {
            $step2 = & $script:GetStepSection -Content $doc.State.Content -StepNumber 2
            $step4 = & $script:GetStepSection -Content $doc.State.Content -StepNumber 4

            $step2 | Should -Match ([regex]::Escape($script:CanonicalMarkerPath)) -Because "$($doc.Name) Step 2 must name the canonical session-memory marker path"
            $step4 | Should -Match ([regex]::Escape($script:CanonicalMarkerPath)) -Because "$($doc.Name) Step 4 must record the same canonical session-memory marker path"
        }
    }

    It 'requires both documents to publish the same canonical automatic startup guard contract' {
        $docs = @(
            @{ Name = 'copilot-instructions'; State = & $script:GetDocumentState -Path $script:CopilotInstructions },
            @{ Name = 'session-startup.instructions'; State = & $script:GetDocumentState -Path $script:StartupInstructions }
        )

        $expectedJson = & $script:ConvertToCanonicalJson -Value $script:ExpectedContract

        foreach ($doc in $docs) {
            $headingIndex = & $script:GetHeadingIndex -Content $doc.State.Content -HeadingPattern $script:ContractHeadingPattern
            ($null -ne $headingIndex) | Should -BeTrue -Because "$($doc.Name) must include the canonical automatic startup guard contract heading"

            $contract = & $script:GetCanonicalContract -Content $doc.State.Content
            (& $script:ConvertToCanonicalJson -Value $contract) | Should -Be $expectedJson -Because "$($doc.Name) must publish the exact startup guard contract"
        }

        $left = & $script:GetCanonicalContract -Content $docs[0].State.Content
        $right = & $script:GetCanonicalContract -Content $docs[1].State.Content
        (& $script:ConvertToCanonicalJson -Value $left) | Should -Be (& $script:ConvertToCanonicalJson -Value $right) -Because 'both startup instruction documents must carry the same canonical contract block'
    }

    It 'requires both documents to describe the run-once guard in the same order' {
        $docs = @(
            @{ Name = 'copilot-instructions'; State = & $script:GetDocumentState -Path $script:CopilotInstructions },
            @{ Name = 'session-startup.instructions'; State = & $script:GetDocumentState -Path $script:StartupInstructions }
        )

        foreach ($doc in $docs) {
            $guardCheck = & $script:GetHeadingIndex -Content $doc.State.Content -HeadingPattern '(?m)^### Step 2 — Check the automatic run-once guard\s*$'
            $detectorInvocation = & $script:GetHeadingIndex -Content $doc.State.Content -HeadingPattern '(?m)^### Step 3 — Run the detector(?: script)?\s*$'
            $markerWrite = & $script:GetHeadingIndex -Content $doc.State.Content -HeadingPattern '(?m)^### Step 4 — Record the run-once marker\s*$'

            ($null -ne $guardCheck) | Should -BeTrue -Because "$($doc.Name) must describe checking the session-memory marker before the automatic detector run"
            ($null -ne $detectorInvocation) | Should -BeTrue -Because "$($doc.Name) must still describe the automatic detector invocation"
            ($null -ne $markerWrite) | Should -BeTrue -Because "$($doc.Name) must describe recording the run-once marker after the first automatic startup check"

            ($guardCheck -lt $detectorInvocation) | Should -BeTrue -Because "$($doc.Name) must place the run-once guard before the detector command"
            ($detectorInvocation -lt $markerWrite) | Should -BeTrue -Because "$($doc.Name) must place marker recording after the first automatic detector run"
        }
    }

    It 'requires both documents to keep the detector command and fail-open/manual semantics aligned' {
        foreach ($path in @($script:CopilotInstructions, $script:StartupInstructions)) {
            $content = Get-Content -Path $path -Raw
            $step3 = & $script:GetStepSection -Content $content -StepNumber 3
            $step4 = & $script:GetStepSection -Content $content -StepNumber 4
            $step8 = & $script:GetStepSection -Content $content -StepNumber 8

            $step3 | Should -Match $script:DetectorCommandPattern -Because "$path must preserve the automatic detector command"
            $step4 | Should -Match '(?is)(fail open).{0,200}(allow later automatic checks|still run the detector)' -Because "$path must state that session-memory write failures fail open"
            $step8 | Should -Match '(?is)(explicit|manual).{0,80}(manual|detector).{0,160}(remain|still).{0,120}(allowed|possible|available)' -Because "$path must keep manual detector invocation available after the automatic startup check"
        }
    }
}