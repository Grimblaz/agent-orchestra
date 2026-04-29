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
        $script:SessionStartupClaudePlatform = Join-Path $script:RepoRoot 'skills\session-startup\platforms\claude.md'
        $script:CanonicalMarkerPath = '/memories/session/session-startup-check-complete.md'
        $script:RetiredTriggerText = 'Before the first substantive response in a new conversation, load the `session-startup` skill and follow its protocol.'
        $script:LegacySilentSkipSummary = 'Skip the automatic startup check silently when neither `$env:COPILOT_ORCHESTRA_ROOT` nor `$env:WORKFLOW_TEMPLATE_ROOT` is set, `pwsh` is unavailable, or the detector returns non-JSON output.'
        $script:DetectorCommandPattern = '(?ms)^pwsh -NoProfile -NonInteractive -File "[^"]*skills/session-startup/scripts/session-cleanup-detector\.ps1"\s*$'
        $script:ContractHeadingPattern = '(?m)^### Canonical Automatic Startup Guard Contract\s*$'
        $script:ClaudeDriftRegionStartMarker = 'For the Claude-only drift-check sub-step'
        $script:ClaudeDriftRegionEndMarker = 'D3b soft exemption'
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
        $script:Step7bFreshnessDocuments = @(
            @{
                Name = 'session-startup skill'
                Path = $script:SessionStartupSkill
            },
            @{
                Name = 'session-startup Claude companion'
                Path = $script:SessionStartupClaudePlatform
            },
            @{
                Name = 'experience command'
                Path = Join-Path $script:RepoRoot 'commands\experience.md'
            },
            @{
                Name = 'design command'
                Path = Join-Path $script:RepoRoot 'commands\design.md'
            },
            @{
                Name = 'plan command'
                Path = Join-Path $script:RepoRoot 'commands\plan.md'
            },
            @{
                Name = 'polish command'
                Path = Join-Path $script:RepoRoot 'commands\polish.md'
            }
        )
        # Guard counter to ensure command documents are actually detected by the checks below
        $script:Step7bFreshnessCommandDocsFound = 0
        $script:ExpectedContract = [ordered]@{
            sessionStartupMarkerPath                    = $script:CanonicalMarkerPath
            checkMarkerBeforeAutomaticDetectorRun       = $true
            recordMarkerAfterFirstAutomaticStartupCheck = $true
            recordMarkerRegardlessOfCleanupChoice       = $true
            failOpenOnSessionMemoryAccessError          = $true
            manualDetectorRunsRemainAllowed             = $true
            confirmSharedBodyLoadForAgentShells         = $true
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

            try {
                $content = Get-Content -Path $Path -Raw -ErrorAction Stop
                return @{
                    Path    = $Path
                    Content = $content
                }
            }
            catch {
                return @{
                    Path    = $Path
                    Content = ''
                    Error   = $_.Exception.Message
                }
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
                [Parameter(Mandatory = $true)]
                [ValidateNotNullOrEmpty()]
                [object]$StepId
            )

            # Allow numeric or string step ids such as 2 or '7b'
            $id = [string]$StepId

            # Match a heading like '### Step 7b — Title' or '### Step 3 — Title'
            # Stop at the next '### Step <token>' or the next top-level '## ' heading.
            $escapedId = [regex]::Escape($id)
            $stepPattern = '(?ms)^### Step ' + $escapedId + ' [^\r\n]*\r?\n(?<body>.*?)(?=^### Step [\w\d-]+ [^\r\n]*\r?\n|^## |\z)'
            $match = [regex]::Match($Content, $stepPattern)
            if (-not $match.Success) {
                return ''
            }

            return $match.Value
        }

        $script:GetStep7bDriftRegion = {
            param(
                [string]$Path,
                [string]$Content
            )

            $section = & $script:GetStepSection -Content $Content -StepId '7b'
            if (-not [string]::IsNullOrEmpty($section)) {
                return $section
            }

            if ($Path -ne $script:SessionStartupClaudePlatform) {
                return ''
            }

            $startIndex = $Content.IndexOf($script:ClaudeDriftRegionStartMarker, [System.StringComparison]::Ordinal)
            if ($startIndex -lt 0) {
                return ''
            }

            $endIndex = $Content.IndexOf($script:ClaudeDriftRegionEndMarker, $startIndex, [System.StringComparison]::Ordinal)
            if ($endIndex -lt 0) {
                return $Content.Substring($startIndex)
            }

            return $Content.Substring($startIndex, $endIndex - $startIndex)
        }

        $script:GetCanonicalContract = {
            param([string]$Content)

            $blockPattern = '(?ms)^### Canonical Automatic Startup Guard Contract\s*\r?\n\r?\n```json\r?\n(?<json>\{.*?\})\r?\n```'
            $match = [regex]::Match($Content, $blockPattern)
            if (-not $match.Success) {
                return @{}
            }

            return $match.Groups['json'].Value | ConvertFrom-Json
        }

        $script:ConvertToCanonicalJson = {
            param([object]$Value)

            return ($Value | ConvertTo-Json -Depth 10 -Compress)
        }
    }

    It 'requires the session-startup skill to use the canonical session marker path in the guard lifecycle steps' {
        $skill = & $script:GetDocumentState -Path $script:SessionStartupSkill
        $step2 = & $script:GetStepSection -Content $skill.Content -StepId 2
        $step4 = & $script:GetStepSection -Content $skill.Content -StepId 4

        $step2 | Should -Match ([regex]::Escape($script:CanonicalMarkerPath)) -Because 'the session-startup skill Step 2 must name the canonical session-memory marker path'
        $step4 | Should -Match ([regex]::Escape($script:CanonicalMarkerPath)) -Because 'the session-startup skill Step 4 must record the same canonical session-memory marker path'
    }

    It 'requires the four pipeline-entry agents to remove the retired session-startup trigger stub' {
        $script:PipelineEntryAgents.Count | Should -Be 4 -Because 'the startup trigger contract is owned by exactly the four pipeline-entry agents'

        foreach ($agent in $script:PipelineEntryAgents) {
            $document = & $script:GetDocumentState -Path $agent.Path
            $content = $document.Content
            $processSectionMatch = [regex]::Match($content, '(?ms)^## Process\s*\r?\n(?<body>.*?)(?=^## |\z)')

            $processSectionMatch.Success | Should -BeTrue -Because "$($agent.Name) must keep a bounded Process section for provenance-gate instructions"

            $processSection = $processSectionMatch.Groups['body'].Value

            $content | Should -Not -Match ([regex]::Escape($script:RetiredTriggerText)) -Because "$($agent.Name) must not retain the retired startup trigger text anywhere in the file"
            $processSection | Should -Not -Match ([regex]::Escape($script:RetiredTriggerText)) -Because "$($agent.Name) must not retain the retired startup trigger inside its Process section"
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

    It 'requires Step 9 to describe shared-body load with Read + cite + halt semantics for agent shells' {
        $skill = & $script:GetDocumentState -Path $script:SessionStartupSkill
        $step9 = & $script:GetStepSection -Content $skill.Content -StepId 9
        $warningGlyph = [string]([char]0x26A0) + [char]0xFE0F
        $successCitation = 'Shared body loaded ' + [char]0x2014 + ' proceeding as'

        # 240-char budget: room for the guard-clause sentence (~120 chars) plus paragraph reformatting headroom
        $step9 | Should -Match '(?is)(not gated by .*run-once marker|outside .*run-once guard|fires on every agent-role adoption).{0,240}(every subagent dispatch|Do not wrap this step in the Step 2 or Step 4 marker guard)' -Because 'Step 9 must keep shared-body loading outside the session-startup run-once guard'
        $step9 | Should -Match ([regex]::Escape('agents/{Name}.agent.md')) -Because 'Step 9 must name the paired shared-body path pattern literally'
        $step9 | Should -Match ('(?s)' + [regex]::Escape($warningGlyph) + '.*cannot continue without the canonical methodology') -Because 'Step 9 must require the canonical halt message when the shared-body load fails'
        $step9 | Should -Match ([regex]::Escape('Shared-body load failed for agents/')) -Because 'Step 9 must name the halt path prefix in the canonical halt message'
        $step9 | Should -Match ([regex]::Escape('surface this to the user and stop')) -Because 'Step 9 must require the agent to surface the failure and stop'
        $step9 | Should -Match '(?is)further tool calls|no further.*agent actions|further.*subagent' -Because 'Step 9 must prohibit any further tool calls or agent actions after the halt message'
        $step9 | Should -Match ([regex]::Escape($successCitation)) -Because 'Step 9 must require the canonical success citation'
        $step9 | Should -Match ([regex]::Escape("platform's file-read tool")) -Because 'Step 9 must describe loading the paired body with a platform-neutral file-read tool reference'
        $step9 | Should -Not -Match '(?i)(?<![\w-])Read tool\b' -Because 'Step 9 must not hardcode the Copilot-specific Read tool name'
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

    It 'validates Step 7b freshness and drift-check wording and ordering' {
        $skill = & $script:GetDocumentState -Path $script:SessionStartupSkill
        $content = $skill.Content

        $copilotSkip = 'After the cleanup path completes, run this Claude-only sub-step before continuing with the user''s request. Copilot skips this sub-step silently because it has no version-cache analog.'

        $step7b = & $script:GetStepSection -Content $content -StepId '7b'

        # Ensure extractor works for string ID and returned the section
        ($step7b -ne '') | Should -BeTrue -Because 'Step 7b must be present and extractable by the new string-aware extractor'

        # Copilot skip clause must appear inside Step 7b and before the Resolve step
        $copilotIndex = $step7b.IndexOf($copilotSkip, [System.StringComparison]::Ordinal)
        ($copilotIndex -ge 0) | Should -BeTrue -Because 'The exact Copilot skip clause must appear inside Step 7b'

        # Ensure Step 7b region contains the resolve step marker reference after freshness content within the same section
        $resolveText = '1. Resolve the installed plugin state'
        $resolveIndex = $step7b.IndexOf($resolveText, [System.StringComparison]::Ordinal)
        ($resolveIndex -gt $copilotIndex) | Should -BeTrue -Because 'Step 7b freshness must appear before the Resolve step inside Step 7b'

        # Required fragments inside Step 7b
        $step7b | Should -Match ([regex]::Escape('claude plugin marketplace update')) -Because 'Step 7b must reference the claude plugin marketplace update flow'
        $step7b | Should -Match '5-second' -Because 'Step 7b must reference a 5-second freshness window/backoff detail'

        $freshnessPhrase = [regex]::Escape('marketplace freshness check failed — using cached view')
        $step7b | Should -Match $freshnessPhrase -Because 'Step 7b must include the exact marketplace freshness failed phrase'

        $step7b | Should -Match '(?is)\bemit\b.*marketplace freshness check failed' -Because 'Step 7b must use an imperative "emit ... marketplace freshness check failed" emission pattern'

        # Local-path suppression and non-git/dirty/detached handling
        $step7b | Should -Match '(?is)local-?path' -Because 'Step 7b must contain local-path suppression text'
        $step7b | Should -Match '(?is)(non-?git|gitless)' -Because 'Step 7b must describe non-git suppression cases'
        $step7b | Should -Match '(?is)(dirty|detached)' -Because 'Step 7b must mention dirty or detached working-tree cases'

        # Headless fail-open emission behavior + fail-open mention
        $step7b | Should -Match '(?is)headless' -Because 'Step 7b must document headless failure behavior'
        $step7b | Should -Match '(?is)(fail open|fail-open)' -Because 'Step 7b must describe fail-open emission behavior'

        # Ensure an `emit` instruction appears close to the exact freshness-failed phrase
        $freshnessPhraseExact = 'marketplace freshness check failed — using cached view'
        $freshnessIndex = $step7b.IndexOf($freshnessPhraseExact, [System.StringComparison]::Ordinal)
        ($freshnessIndex -ge 0) | Should -BeTrue -Because 'Step 7b must contain the exact freshness-failed phrase'

        $emitNearby = $false
        if ($freshnessIndex -ge 0) {
            $start = [Math]::Max(0, $freshnessIndex - 80)
            $len = [Math]::Min(160, $step7b.Length - $start)
            $snippet = $step7b.Substring($start, $len)
            $emitNearby = ($snippet -match '(?is)\bemit\b')
        }
        $emitNearby | Should -BeTrue -Because 'Step 7b must include an emit instruction near the freshness failure phrase'

        # Cached-view continuation wording must be present
        $step7b | Should -Match '(?is)cached( marketplace)? view' -Because 'Step 7b must include a cached-view continuation wording (cached view or cached marketplace view)'

        # Verified-current / silence only on freshness-success branch
        $step7b | Should -Match '(?is)verified-?current' -Because 'Step 7b must mention verified-current semantics'
        $step7b | Should -Match '(?is)silenc|silence' -Because 'Step 7b must mention silence semantics on freshness-success branch'

        # SMC-07 callout must exist in the overall skill content (not necessarily inside Step 7b)
        $smc07 = 'Do not add a second marker or new persistence mechanic'
        $content | Should -Match ([regex]::Escape($smc07)) -Because 'SMC-07 callout must remain in the skill callout text'

        # Step 7b should cite Step 4 (the run-once marker) but need not contain the literal canonical marker path
        $step7b | Should -Match 'Step 4' -Because 'Step 7b must cite the Step 4 run-once marker by reference'

        # Exact Copilot skip clause preserved in Step 7b
        $step7b | Should -Match ([regex]::Escape($copilotSkip)) -Because 'The exact Copilot skip clause must be preserved in Step 7b'

        # Verify ordering: freshness emission appears after the Copilot skip clause and before the Resolve step
        $freshnessPhrase = 'marketplace freshness check failed — using cached view'
        $freshnessIndex = $step7b.IndexOf($freshnessPhrase, [System.StringComparison]::Ordinal)
        ($freshnessIndex -gt $copilotIndex) | Should -BeTrue -Because 'Freshness failure text must appear after the Copilot skip clause'
        ($freshnessIndex -lt $resolveIndex) | Should -BeTrue -Because 'Freshness failure text must appear before the Resolve step in Step 7b'

        # Distinguish pwsh silent-skip vs claude fail-open emission
        $step7b | Should -Match '(?i)pwsh' -Because 'Step 7b must mention pwsh setup/environment failures as a silent skip case'
        $step7b | Should -Match '(?i)claude' -Because 'Step 7b must mention claude execution failure and its fail-open emission behavior'
        $step7b | Should -Match '(?is)silent.*skip' -Because 'Step 7b must distinguish silent skip for pwsh failures'
        $step7b | Should -Match '(?is)fail open|fail-open' -Because 'Step 7b must distinguish fail-open emission for claude failures'
    }

    It 'verifies Step 7b drift wording exists in the six active command/skill files' {
        $freshnessPhraseExact = 'marketplace freshness check failed — using cached view'
        $stopLabel = [regex]::Escape("Stop — I'll restart now")
        $continueLabel = [regex]::Escape('Continue — run under old code')

        foreach ($document in $script:Step7bFreshnessDocuments) {
            $doc = & $script:GetDocumentState -Path $document.Path
            $sec = & $script:GetStep7bDriftRegion -Path $document.Path -Content $doc.Content

            ($sec -ne '') | Should -BeTrue -Because "$($document.Name) must contain a Step 7b/drift region"

            # Core required fragments for every active region
            $sec | Should -Match ([regex]::Escape('claude plugin marketplace update')) -Because "$($document.Name) Step 7b must mention 'claude plugin marketplace update'"
            $sec | Should -Match '5-second' -Because "$($document.Name) Step 7b must reference a 5-second freshness window/backoff detail"
            $sec | Should -Match ([regex]::Escape($freshnessPhraseExact)) -Because "$($document.Name) Step 7b must include the exact marketplace freshness failed phrase"
            $sec | Should -Match '(?is)cached( marketplace)? view' -Because "$($document.Name) Step 7b must include cached-view continuation wording (cached view or cached marketplace view)"

            # Ensure `emit` appears near the freshness-failed phrase (within ~80 chars)
            $freshnessIndex = $sec.IndexOf($freshnessPhraseExact, [System.StringComparison]::Ordinal)
            ($freshnessIndex -ge 0) | Should -BeTrue -Because "$($document.Name) Step 7b must contain the freshness-failed phrase"
            $emitNearby = $false
            if ($freshnessIndex -ge 0) {
                $start = [Math]::Max(0, $freshnessIndex - 80)
                $len = [Math]::Min(160, $sec.Length - $start)
                $snippet = $sec.Substring($start, $len)
                $emitNearby = ($snippet -match '(?is)\bemit\w*\b')
            }
            $emitNearby | Should -BeTrue -Because "$($document.Name) Step 7b must include an emit instruction near the freshness failure phrase"

            # Additional checks for the four command mirrors (commands: experience/design/plan/polish)
            # Use a robust detection that tolerates both backslashes and forward-slashes
            $docPathNormalized = $document.Path -replace '\\','/'
            if ($docPathNormalized -match '/commands/') {
                $script:Step7bFreshnessCommandDocsFound = $script:Step7bFreshnessCommandDocsFound + 1
                $sec | Should -Match '(?i)non-git' -Because "$($document.Name) must mention non-git local-path carve-out"
                $sec | Should -Match '(?i)dirty' -Because "$($document.Name) must mention dirty working-tree local-path carve-out"
                $sec | Should -Match '(?i)detached' -Because "$($document.Name) must mention detached HEAD local-path carve-out"
                $sec | Should -Match '(?i)suppress' -Because "$($document.Name) must mention suppress/suppression local-path carve-out"

                $sec | Should -Match $stopLabel -Because "$($document.Name) must preserve the 'Stop — I'll restart now' option label"
                $sec | Should -Match $continueLabel -Because "$($document.Name) must preserve the 'Continue — run under old code' option label"
            }

            # For the Claude platform companion, assert headless prompt-suppression wording in addition to fail-open phrase
            if ($document.Path -eq $script:SessionStartupClaudePlatform) {
                $sec | Should -Match ([regex]::Escape($freshnessPhraseExact)) -Because 'Claude companion region must contain the exact freshness-failed phrase'
                $sec | Should -Match '(?is)headless.*suppress|suppress.*prompt' -Because 'Claude companion region must include headless prompt-suppression wording'
            }
        }
        # Structural guard: ensure all four command mirrors were detected.
        $script:Step7bFreshnessCommandDocsFound | Should -Be 4 -Because 'There must be four command mirrors detected for Step 7b (experience/design/plan/polish) — guards against path-detection regressions'
    }

    It 'requires the session-startup skill to preserve the detector command and fail-open/manual semantics' {
        $skill = & $script:GetDocumentState -Path $script:SessionStartupSkill
        $content = $skill.Content
        $step3 = & $script:GetStepSection -Content $content -StepId 3
        $step4 = & $script:GetStepSection -Content $content -StepId 4
        $step8 = & $script:GetStepSection -Content $content -StepId 8

        $step3 | Should -Match $script:DetectorCommandPattern -Because 'the session-startup skill must preserve the automatic detector command'
        $step4 | Should -Match '(?is)(fail open).{0,200}(allow later automatic checks|still run the detector)' -Because 'the session-startup skill must state that session-memory write failures fail open'
        $step8 | Should -Match '(?is)(explicit|manual).{0,80}(manual|detector).{0,160}(remain|still).{0,120}(allowed|possible|available)' -Because 'the session-startup skill must keep manual detector invocation available after the automatic startup check'
        $step8 | Should -Match 'Step 9' -Because 'Step 8 must explicitly reference Step 9 to establish the sequencing dependency'
    }
}
