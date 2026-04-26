#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
        Contract tests for issue #412 inline-dispatch enforcement.

.DESCRIPTION
        Verifies the Claude Code command-file prose contract for issue #412 across
        commands/experience.md, commands/design.md, and commands/plan.md.

        Cross-tool asymmetry (D6 of #412): Copilot's .github/prompts/*.prompt.md files
        are thin one-line dispatchers without a parent-side prose surface. Copilot
        inline-dispatch enforcement is owned by the agent body and tracked in #414.

        Canonical option-label assertions extract fenced YAML blocks from
        skills/session-startup/SKILL.md and skills/provenance-gate/SKILL.md so label
        changes cause explicit contract-test failures instead of silent drift.
#>

Describe 'inline dispatch contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:SessionStartupSkill = Join-Path $script:RepoRoot 'skills\session-startup\SKILL.md'
        $script:ProvenanceGateSkill = Join-Path $script:RepoRoot 'skills\provenance-gate\SKILL.md'
        $script:MarkerPath = '/memories/session/session-startup-check-complete.md'
        $script:NoStaleStateNote = 'no stale state detected'
        $script:D2FailOpenText = 'Claude Code inline currently lacks a session-memory write surface'
        $script:PlanDeferralNote = 'Step 9 (paired-body halt-on-fail) and the provenance-gate cold-pickup assessment are enforced by the issue-planner subagent shell at agents/issue-planner.md'
        $script:OfflineModeNoticePattern = '(?is)(offline mode is active|If offline mode is active because MCP or API access is unavailable|If MCP or API access is unavailable, say that offline mode is active)'
        $script:ClaudeInlineNoPersistencePattern = '(?is)(offline mode is active).{0,220}(lacks a session-memory write surface|cannot persist).{0,220}(cannot persist|do not claim).{0,220}(local fallback payload).{0,220}(later online run|next online invocation|next online run|recover the GitHub marker|reconstruct the GitHub marker)'
        $script:ClaudeInlineLocalPayloadPathPattern = '/memories/session/first-contact-assessed-\{ID\}\.md'
        $script:PlanOfflineBoundaryPattern = '(?is)(offline mode is active|local payload|/memories/session/first-contact-assessed-\{ID\}\.md|next online invocation|next online run|reconstruct and post the GitHub marker|reconstruct the GitHub marker)'

        $script:GetCanonicalLabelMap = {
            param(
                [string]$SkillPath,
                [string]$Heading,
                [int]$ExpectedCount
            )

            $content = Get-Content -Path $SkillPath -Raw -ErrorAction Stop
            $pattern = '(?ms)^' + [regex]::Escape($Heading) + '\s*\r?\n\r?\n```yaml\r?\n(?<yaml>.*?)\r?\n```'
            $match = [regex]::Match($content, $pattern)

            $match.Success | Should -BeTrue -Because "$SkillPath must publish the $Heading fenced YAML block"
            if (-not $match.Success) {
                return [ordered]@{}
            }

            $labels = [ordered]@{}
            $linePattern = '^\s+(?<key>\w+):\s*(?:''(?<single>[^'']*)''|"(?<double>[^"]*)"|(?<unquoted>\S.*?))\s*$'
            foreach ($line in ($match.Groups['yaml'].Value -split "`r?`n")) {
                if ($line -match '^\s*$' -or $line -match '^canonical_option_labels:\s*$') {
                    continue
                }

                $lineMatch = [regex]::Match($line, $linePattern)
                $lineMatch.Success | Should -BeTrue -Because "$SkillPath must keep $Heading entries as single-line YAML values"
                if (-not $lineMatch.Success) {
                    continue
                }

                $value = if ($lineMatch.Groups['single'].Success) {
                    $lineMatch.Groups['single'].Value
                }
                elseif ($lineMatch.Groups['double'].Success) {
                    $lineMatch.Groups['double'].Value
                }
                else {
                    $lineMatch.Groups['unquoted'].Value
                }

                $labels[$lineMatch.Groups['key'].Value] = $value
            }

            $labels.Count | Should -Be $ExpectedCount -Because "$SkillPath must expose $ExpectedCount canonical labels under $Heading"
            return $labels
        }

        $script:GetCanonicalLabelList = {
            param(
                [string]$SkillPath,
                [string]$Heading,
                [int]$ExpectedCount
            )

            $content = Get-Content -Path $SkillPath -Raw -ErrorAction Stop
            $pattern = '(?ms)^' + [regex]::Escape($Heading) + '\s*\r?\n\r?\n```yaml\r?\n(?<yaml>.*?)\r?\n```'
            $match = [regex]::Match($content, $pattern)

            $match.Success | Should -BeTrue -Because "$SkillPath must publish the $Heading fenced YAML block"
            if (-not $match.Success) {
                return @()
            }

            $labels = [System.Collections.Generic.List[string]]::new()
            $linePattern = '^\s*-\s*(?:''(?<single>[^'']*)''|"(?<double>[^"]*)"|(?<unquoted>\S.*?))\s*$'
            foreach ($line in ($match.Groups['yaml'].Value -split "`r?`n")) {
                if ($line -match '^\s*$' -or $line -match '^canonical_option_labels:\s*$') {
                    continue
                }

                $lineMatch = [regex]::Match($line, $linePattern)
                $lineMatch.Success | Should -BeTrue -Because "$SkillPath must keep $Heading entries as single-line YAML list items"
                if (-not $lineMatch.Success) {
                    continue
                }

                $value = if ($lineMatch.Groups['single'].Success) {
                    $lineMatch.Groups['single'].Value
                }
                elseif ($lineMatch.Groups['double'].Success) {
                    $lineMatch.Groups['double'].Value
                }
                else {
                    $lineMatch.Groups['unquoted'].Value
                }

                $labels.Add($value)
            }

            $labels.Count | Should -Be $ExpectedCount -Because "$SkillPath must expose $ExpectedCount canonical labels under $Heading"
            return @($labels)
        }

        $script:SessionStartupLabels = & $script:GetCanonicalLabelMap -SkillPath $script:SessionStartupSkill -Heading '### Inline-Dispatch Option Labels' -ExpectedCount 4
        $script:ProvenanceStage1Labels = & $script:GetCanonicalLabelList -SkillPath $script:ProvenanceGateSkill -Heading '### Stage-1 Self-Classification Labels' -ExpectedCount 3
        $script:ProvenanceStage2Labels = & $script:GetCanonicalLabelList -SkillPath $script:ProvenanceGateSkill -Heading '### Stage-2 Cold-Only Assessment Labels' -ExpectedCount 3
        $script:LegacyProvenanceLabels = @(
            'Assessment looks right - proceed with caution',
            'Needs rework - stop here'
        )

        $script:CommandMatrix = @(
            @{
                Path                         = 'commands\experience.md'
                RequiredStatic               = @(
                    $script:MarkerPath,
                    $script:D2FailOpenText,
                    $script:NoStaleStateNote,
                    '⚠️ Shared-body load failed for agents/Experience-Owner.agent.md',
                    'cannot continue without the canonical methodology',
                    '<!-- first-contact-assessed-',
                    '<!-- D6 (issue #412):'
                )
                RequiredSessionKeys          = @('cleanup_yes', 'cleanup_no', 'drift_stop', 'drift_continue')
                RequiredProvenanceStage1Keys = @(0, 1, 2)
                RequiredProvenanceStage2Keys = @(0, 1, 2)
                ForbiddenStatic              = @()
                OrderedMarkers               = @(
                    '### Step 4 — Run-once marker',
                    '### Step 6 — Cleanup confirmation',
                    '### Step 7b — Drift check',
                    '### Step 9 — Paired-body halt-on-fail',
                    '### Provenance-gate'
                )
            },
            @{
                Path                         = 'commands\design.md'
                RequiredStatic               = @(
                    $script:MarkerPath,
                    $script:D2FailOpenText,
                    $script:NoStaleStateNote,
                    '⚠️ Shared-body load failed for agents/Solution-Designer.agent.md',
                    'cannot continue without the canonical methodology',
                    '<!-- first-contact-assessed-',
                    '<!-- D6 (issue #412):'
                )
                RequiredSessionKeys          = @('cleanup_yes', 'cleanup_no', 'drift_stop', 'drift_continue')
                RequiredProvenanceStage1Keys = @(0, 1, 2)
                RequiredProvenanceStage2Keys = @(0, 1, 2)
                ForbiddenStatic              = @()
                OrderedMarkers               = @(
                    '### Step 4 — Run-once marker',
                    '### Step 6 — Cleanup confirmation',
                    '### Step 7b — Drift check',
                    '### Step 9 — Paired-body halt-on-fail',
                    '### Provenance-gate'
                )
            },
            @{
                Path                         = 'commands\plan.md'
                RequiredStatic               = @(
                    $script:MarkerPath,
                    $script:D2FailOpenText,
                    $script:NoStaleStateNote,
                    $script:PlanDeferralNote,
                    'See issue #412 for the parent-vs-subagent enforcement split'
                )
                RequiredSessionKeys          = @('cleanup_yes', 'cleanup_no', 'drift_stop', 'drift_continue')
                RequiredProvenanceStage1Keys = @()
                RequiredProvenanceStage2Keys = @()
                ForbiddenStatic              = @('Shared-body load failed')
                OrderedMarkers               = @(
                    '### Step 4 — Run-once marker',
                    '### Step 6 — Cleanup confirmation',
                    '### Step 7b — Drift check',
                    '### Step 9 + provenance-gate deferral note'
                )
            }
        )
    }

    It 'extracts canonical inline-dispatch labels from the source skills' {
        $script:SessionStartupLabels.Count | Should -Be 4
        $script:SessionStartupLabels['cleanup_yes'] | Should -Be 'Yes — run cleanup'
        $script:SessionStartupLabels['cleanup_no'] | Should -Be 'No — skip for now'
        $script:SessionStartupLabels['drift_stop'] | Should -Be "Stop — I'll restart now"
        $script:SessionStartupLabels['drift_continue'] | Should -Be 'Continue — run under old code'

        $script:ProvenanceStage1Labels.Count | Should -Be 3
        $script:ProvenanceStage1Labels[0] | Should -Be "I wrote this / I'm fully briefed"
        $script:ProvenanceStage1Labels[1] | Should -Be "I'm picking this up cold"
        $script:ProvenanceStage1Labels[2] | Should -Be 'Stop — needs rework first'

        $script:ProvenanceStage2Labels.Count | Should -Be 3
        $script:ProvenanceStage2Labels[0] | Should -Be 'Assessment looks right — proceed'
        $script:ProvenanceStage2Labels[1] | Should -Be 'Proceed but carry concerns forward'
        $script:ProvenanceStage2Labels[2] | Should -Be 'Needs rework — stop here'
    }

    It 'requires each Claude command file to contain the expected inline-dispatch contract prose' {
        foreach ($command in $script:CommandMatrix) {
            $path = Join-Path $script:RepoRoot $command.Path
            $content = Get-Content -Path $path -Raw -ErrorAction Stop

            foreach ($required in $command.RequiredStatic) {
                $content | Should -Match ([regex]::Escape($required)) -Because "$($command.Path) must contain required contract prose: $required"
            }

            foreach ($key in $command.RequiredSessionKeys) {
                $label = $script:SessionStartupLabels[$key]
                $content | Should -Match ([regex]::Escape($label)) -Because "$($command.Path) must include the canonical session-startup label '$key'"
            }

            foreach ($index in $command.RequiredProvenanceStage1Keys) {
                $label = $script:ProvenanceStage1Labels[$index]
                $content | Should -Match ([regex]::Escape($label)) -Because "$($command.Path) must include the canonical provenance-gate stage-1 label at index $index"
            }

            foreach ($index in $command.RequiredProvenanceStage2Keys) {
                $label = $script:ProvenanceStage2Labels[$index]
                $content | Should -Match ([regex]::Escape($label)) -Because "$($command.Path) must include the canonical provenance-gate stage-2 label at index $index"
            }

            foreach ($forbidden in $command.ForbiddenStatic) {
                $content | Should -Not -Match ([regex]::Escape($forbidden)) -Because "$($command.Path) must not contain forbidden prose: $forbidden"
            }

            foreach ($legacyLabel in $script:LegacyProvenanceLabels) {
                $content | Should -Not -Match ([regex]::Escape($legacyLabel)) -Because "$($command.Path) must not keep the legacy provenance-gate label '$legacyLabel'"
            }

            if ($command.Path -ne 'commands\plan.md') {
                $content | Should -Match '(?is)(only if|only when).{0,120}I''m picking this up cold|cold-only assessment|cold path' -Because "$($command.Path) must make stage 2 conditional on the cold path"
                $content | Should -Match '(?is)(Stop — needs rework first|Needs rework — stop here).{0,220}(do not post|without posting|no marker).{0,140}first-contact-assessed' -Because "$($command.Path) must keep both stop outcomes marker-free"
                $content | Should -Match '(?is)(HTML token).{0,120}(line 1).{0,180}(only skip-check anchor|only anchor|only parser anchor).{0,220}(second line|second-line).{0,120}(human-readable|decorative)' -Because "$($command.Path) must preserve the HTML token as the sole skip-check anchor while documenting the decorative second line"
            }

            if ($command.Path -eq 'commands\plan.md') {
                foreach ($label in ($script:ProvenanceStage1Labels + $script:ProvenanceStage2Labels)) {
                    $content | Should -Not -Match ([regex]::Escape($label)) -Because 'commands\plan.md must not duplicate provenance-gate developer labels'
                }
            }
        }
    }

    It 'requires the inline-dispatch step blocks to appear in the documented order' {
        foreach ($command in $script:CommandMatrix) {
            $path = Join-Path $script:RepoRoot $command.Path
            $content = Get-Content -Path $path -Raw -ErrorAction Stop
            $indices = foreach ($marker in $command.OrderedMarkers) {
                $index = $content.IndexOf($marker, [System.StringComparison]::Ordinal)
                $index | Should -BeGreaterThan -1 -Because "$($command.Path) must contain the ordered marker '$marker'"
                $index
            }

            for ($i = 1; $i -lt $indices.Count; $i++) {
                $indices[$i] | Should -BeGreaterThan $indices[$i - 1] -Because "$($command.Path) must keep inline-dispatch sections in reading order"
            }

            if ($command.Path -eq 'commands\plan.md') {
                $preflightIndex = $content.IndexOf('## Pre-flight (parent-side, before handshake preamble)', [System.StringComparison]::Ordinal)
                $handshakeIndex = $content.IndexOf('**Handshake preamble**', [System.StringComparison]::Ordinal)
                $preflightIndex | Should -BeGreaterThan -1 -Because 'commands\plan.md must add the parent-side pre-flight section'
                $handshakeIndex | Should -BeGreaterThan -1 -Because 'commands\plan.md must retain the handshake preamble heading'
                $preflightIndex | Should -BeLessThan $handshakeIndex -Because 'commands\plan.md must place the parent-side pre-flight section before the handshake preamble'
            }
        }
    }

    It 'requires experience and design to carry the offline fallback notice and Claude-inline no-persistence warning' {
        foreach ($commandPath in @('commands\experience.md', 'commands\design.md')) {
            $content = Get-Content -Path (Join-Path $script:RepoRoot $commandPath) -Raw -ErrorAction Stop

            $content | Should -Match $script:OfflineModeNoticePattern -Because "$commandPath must visibly tell the developer when offline mode is active"
            $content | Should -Match $script:ClaudeInlineNoPersistencePattern -Because "$commandPath must explain that Claude inline cannot persist the fallback payload or arm next-online recovery on this surface"
            $content | Should -Not -Match $script:ClaudeInlineLocalPayloadPathPattern -Because "$commandPath must not claim that this inline surface wrote the session-memory fallback payload"
        }
    }

    It 'keeps the plan command on the provenance-gate deferral boundary for offline recovery details' {
        $content = Get-Content -Path (Join-Path $script:RepoRoot 'commands\plan.md') -Raw -ErrorAction Stop

        $content | Should -Not -Match $script:PlanOfflineBoundaryPattern -Because 'commands\plan.md must not duplicate the offline-mode notice or local-payload recovery prose that remains delegated to the issue-planner shell'
    }

    It 'requires the plan deferral note to remain user-visible prose' {
        $content = Get-Content -Path (Join-Path $script:RepoRoot 'commands\plan.md') -Raw -ErrorAction Stop
        $line = ($content -split "`r?`n" | Where-Object { $_ -like '*Step 9 (paired-body halt-on-fail) and the provenance-gate cold-pickup assessment are enforced*' } | Select-Object -First 1)

        [string]::IsNullOrWhiteSpace($line) | Should -BeFalse -Because 'commands\plan.md must contain the Step 9 + provenance-gate deferral note'
        $line.TrimStart().StartsWith('<!--', [System.StringComparison]::Ordinal) | Should -BeFalse -Because 'commands\plan.md must keep the deferral note user-visible rather than hiding it in an HTML comment'
    }

    It 'documents the D6 Copilot asymmetry in the test header' {
        $content = Get-Content -Path (Join-Path $script:RepoRoot '.github\scripts\Tests\inline-dispatch-contract.Tests.ps1') -Raw -ErrorAction Stop

        $content | Should -Match ([regex]::Escape('Cross-tool asymmetry (D6 of #412)')) -Because 'the test header must explain the intentional Copilot asymmetry from issue #412'
    }
}
