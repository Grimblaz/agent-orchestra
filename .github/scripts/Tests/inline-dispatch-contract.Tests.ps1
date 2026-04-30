#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Contract tests for inline-dispatch enforcement across issues #412 and #437.

.DESCRIPTION
    Verifies the Claude Code command-file prose contract across
    commands/experience.md, commands/design.md, commands/plan.md, and
    commands/orchestrate.md.

    Issue #437 intentionally rolls back the #412 D5/D6 /plan carve-out so
    /plan carries inline paired-body and provenance-gate prose like
    /experience and /design. The Copilot asymmetry remains tracked by #414.

    Issue #465 extends the same command-side inline contract to /orchestrate:
    it must adopt Code-Conductor inline, preserve hub-mode smart resume, and
    reconstruct downstream Agent handshakes live per dispatch.

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
        $script:OfflineModeNoticePattern = '(?is)(offline mode is active|If offline mode is active because MCP or API access is unavailable|If MCP or API access is unavailable, say that offline mode is active)'
        $script:ClaudeInlineNoPersistencePattern = '(?is)(offline mode is active).{0,220}(lacks a session-memory write surface|cannot persist).{0,220}(cannot persist|do not claim).{0,220}(local fallback payload).{0,220}(later online run|next online invocation|next online run|recover the GitHub marker|reconstruct the GitHub marker)'
        $script:ClaudeInlineLocalPayloadPathPattern = '/memories/session/first-contact-assessed-\{ID\}\.md'

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
                    '⚠️ Shared-body load failed for agents/Issue-Planner.agent.md',
                    'cannot continue without the canonical methodology',
                    '<!-- first-contact-assessed-',
                    '<!-- D6 (issue #412):',
                    'Read agents/Issue-Planner.agent.md',
                    '## Inline adversarial-pipeline dispatch',
                    'subagent_type: code-critic',
                    'Review mode selector: "Use design review perspectives"',
                    'Review mode selector: "Use product-alignment perspectives"',
                    'Review mode selector: "Use defense review perspectives"',
                    'subagent_type: code-review-response',
                    'pipeline-degraded',
                    'contextual metadata only',
                    'Dispatching prosecution x3 in parallel...',
                    'Merged prosecution ledger: {count} finding(s).'
                )
                RequiredSessionKeys          = @('cleanup_yes', 'cleanup_no', 'drift_stop', 'drift_continue')
                RequiredProvenanceStage1Keys = @(0, 1, 2)
                RequiredProvenanceStage2Keys = @(0, 1, 2)
                ForbiddenStatic              = @(
                    'subagent_type: issue-planner',
                    'Step 9 + provenance-gate deferral note'
                )
                OrderedMarkers               = @(
                    '### Step 4 — Run-once marker',
                    '### Step 6 — Cleanup confirmation',
                    '### Step 7b — Drift check',
                    '### Step 9 — Paired-body halt-on-fail',
                    '### Provenance-gate'
                )
            },
            @{
                Path                         = 'commands\orchestrate.md'
                RequiredStatic               = @(
                    $script:MarkerPath,
                    $script:D2FailOpenText,
                    $script:NoStaleStateNote,
                    '⚠️ Shared-body load failed for agents/Code-Conductor.agent.md',
                    'cannot continue without the canonical methodology',
                    '<!-- first-contact-assessed-',
                    'agents/Code-Conductor.agent.md',
                    '~/.claude/plugins/installed_plugins.json',
                    'installPath',
                    '~/.claude/plugins/cache/agent-orchestra/agent-orchestra/*/agents/Code-Conductor.agent.md',
                    '.claude-plugin/plugin.json',
                    'name: agent-orchestra',
                    'claude plugin install agent-orchestra@agent-orchestra',
                    '<!-- plan-issue-{ID} -->',
                    '<!-- design-issue-{ID} -->',
                    'Issue-Planner itself',
                    'SMC-01',
                    'SMC-03',
                    'SMC-08'
                )
                RequiredSessionKeys          = @('cleanup_yes', 'cleanup_no', 'drift_stop', 'drift_continue')
                RequiredProvenanceStage1Keys = @(0, 1, 2)
                RequiredProvenanceStage2Keys = @(0, 1, 2)
                ForbiddenStatic              = @(
                    'subagent_type: code-conductor',
                    'Dispatch the `code-conductor` subagent',
                    'The subagent will read `agents/code-conductor.md`'
                )
                OrderedMarkers               = @(
                    '### Step 4 — Run-once marker',
                    '### Step 6 — Cleanup confirmation',
                    '### Step 7b — Drift check',
                    '### Step 9 — Paired-body halt-on-fail',
                    '### Provenance-gate'
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

            $content | Should -Match '(?is)(only if|only when).{0,120}I''m picking this up cold|cold-only assessment|cold path' -Because "$($command.Path) must make stage 2 conditional on the cold path"
            $content | Should -Match '(?is)(Stop — needs rework first|Needs rework — stop here).{0,220}(do not post|without posting|no marker).{0,140}first-contact-assessed' -Because "$($command.Path) must keep both stop outcomes marker-free"
            $content | Should -Match '(?is)(HTML token).{0,120}(line 1).{0,180}(only skip-check anchor|only anchor|only parser anchor).{0,220}(second line|second-line).{0,120}(human-readable|decorative)' -Because "$($command.Path) must preserve the HTML token as the sole skip-check anchor while documenting the decorative second line"
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
        }
    }

    It 'forbids /orchestrate from dispatching Code-Conductor as a parent-side subagent' {
        $content = Get-Content -Path (Join-Path $script:RepoRoot 'commands\orchestrate.md') -Raw -ErrorAction Stop

        $content | Should -Not -Match '(?is)subagent_type:\s*code-conductor' -Because '/orchestrate must not dispatch Code-Conductor as a parent-side subagent'
        $content | Should -Not -Match '(?is)dispatch\s+the\s+`?code-conductor`?\s+subagent' -Because '/orchestrate must not keep parent-side Code-Conductor subagent dispatch wording'
        $content | Should -Not -Match '(?is)The subagent will read `agents/code-conductor\.md`' -Because '/orchestrate must not describe Code-Conductor as a delegated subagent shell'
    }

    It 'requires /orchestrate to adopt Code-Conductor inline after D1 body resolution' {
        $content = Get-Content -Path (Join-Path $script:RepoRoot 'commands\orchestrate.md') -Raw -ErrorAction Stop

        $d1ResolutionPatterns = @(
            '(?is)(Read|load|resolve).{0,160}agents/Code-Conductor\.agent\.md',
            '(?is)~/.claude/plugins/installed_plugins\.json.{0,160}installPath',
            '(?is)SemVer-sorted.{0,120}~/.claude/plugins/cache/agent-orchestra/agent-orchestra/\*/agents/Code-Conductor\.agent\.md',
            '(?is)\.claude-plugin/plugin\.json.{0,120}name: agent-orchestra',
            '(?is)claude plugin install agent-orchestra@agent-orchestra'
        )

        foreach ($pattern in $d1ResolutionPatterns) {
            $content | Should -Match $pattern -Because '/orchestrate must carry D1-equivalent Code-Conductor body-resolution wording inline'
        }

        $content | Should -Match '(?is)(adopt|run).{0,120}Code-Conductor.{0,120}(inline|role|conversation)|Code-Conductor.{0,120}(inline|role).{0,120}(rest of this conversation|conversation)' -Because '/orchestrate must adopt Code-Conductor in the parent conversation after loading the shared body'
    }

    It 'requires /orchestrate to reconstruct downstream Agent handshakes live per dispatch' {
        $content = Get-Content -Path (Join-Path $script:RepoRoot 'commands\orchestrate.md') -Raw -ErrorAction Stop

        $content | Should -Match '(?is)(before each|immediately before each|for each|for every|per-dispatch).{0,180}`?Agent`?.{0,160}dispatch.{0,240}(reconstruct|recapture|capture).{0,220}(HEAD|branch).{0,220}(CWD|dirty)' -Because '/orchestrate must document live handshake reconstruction for each downstream Agent dispatch'
        $content | Should -Match '(?is)((do not|must not).{0,160}(reuse|carry forward).{0,160}(command-entry|entry-time|single).{0,120}handshake|(command-entry|entry-time|single).{0,120}handshake.{0,160}(must not|do not).{0,120}(reuse|carry forward))' -Because '/orchestrate must explicitly reject a single command-entry-captured handshake for downstream Agent calls'
        $content | Should -Not -Match '(?is)\*\*Handshake preamble\*\*.{0,900}subagent_type:\s*code-conductor' -Because '/orchestrate must not keep the old one-shot Code-Conductor subagent handshake preamble'
    }

    It 'scopes /plan pipeline-degraded recovery to redundant prosecution body-load pass failures' {
        $content = Get-Content -Path (Join-Path $script:RepoRoot 'commands\plan.md') -Raw -ErrorAction Stop

        $matchesAnyPattern = {
            param(
                [string]$Content,
                [string[]]$Patterns
            )

            foreach ($pattern in $Patterns) {
                if ($Content -match $pattern) {
                    return $true
                }
            }

            return $false
        }

        $redundantProsecutionBodyLoadRecovery = & $matchesAnyPattern -Content $content -Patterns @(
            '(?is)(?:redundant|three|3).{0,180}(?:Code-Critic\s+)?prosecution.{0,260}(?:body-load|body load|shared-body|shared body|body).{0,220}(?:fail|failure|failed|missing|malformed|not load|cannot load)',
            '(?is)(?:Code-Critic\s+)?prosecution.{0,180}(?:redundant|three|3).{0,260}(?:body-load|body load|shared-body|shared body|body).{0,220}(?:fail|failure|failed|missing|malformed|not load|cannot load)',
            '(?is)(?:body-load|body load|shared-body|shared body|body).{0,220}(?:fail|failure|failed|missing|malformed|not load|cannot load).{0,260}(?:redundant|three|3).{0,180}(?:Code-Critic\s+)?prosecution'
        )
        $redundantProsecutionBodyLoadRecovery | Should -BeTrue -Because '/plan must explicitly scope body-load pass failure recovery to the redundant Code-Critic prosecution set'

        $content | Should -Match '(?is)\bretry\b.{0,80}\bonce\b|\bonce\b.{0,80}\bretry\b' -Because '/plan must retry a failed or malformed redundant prosecution body-load pass once before degrading'
        $content | Should -Match '(?is)\bpipeline-degraded\b' -Because '/plan must preserve the visible degraded-pipeline note for redundant prosecution partial failure'
        $content | Should -Match '(?is)(?:2-of-3|two-of-three|two of three).{0,200}(?:merged\s+)?prosecution ledger|(?:merged\s+)?prosecution ledger.{0,200}(?:2-of-3|two-of-three|two of three)' -Because '/plan must tie pipeline-degraded continuation to the 2-of-3 merged prosecution ledger'

        foreach ($singletonStage in @(
                [pscustomobject]@{ Name = 'defense'; Body = 'Code-Critic'; StagePattern = 'defense' },
                [pscustomobject]@{ Name = 'judge'; Body = 'Code-Review-Response'; StagePattern = 'judge|judgment' }
            )) {
            $bodyPattern = [regex]::Escape($singletonStage.Body)
            $strictSingletonFailure = & $matchesAnyPattern -Content $content -Patterns @(
                "(?is)(?:singleton|single|one).{0,160}(?:$($singletonStage.StagePattern)|$bodyPattern).{0,260}(?:body-load|body load|shared-body|shared body|body).{0,220}(?:fail|failure|failed|missing|malformed|not load|cannot load).{0,260}(?:halt-strict|halt strict|halt|stop|cannot continue|do not continue)",
                "(?is)(?:$($singletonStage.StagePattern)|$bodyPattern).{0,160}(?:singleton|single|one).{0,260}(?:body-load|body load|shared-body|shared body|body).{0,220}(?:fail|failure|failed|missing|malformed|not load|cannot load).{0,260}(?:halt-strict|halt strict|halt|stop|cannot continue|do not continue)",
                "(?is)(?:body-load|body load|shared-body|shared body|body).{0,220}(?:fail|failure|failed|missing|malformed|not load|cannot load).{0,260}(?:$($singletonStage.StagePattern)|$bodyPattern).{0,260}(?:halt-strict|halt strict|halt|stop|cannot continue|do not continue)"
            )
            $strictSingletonFailure | Should -BeTrue -Because "/plan must state that singleton $($singletonStage.Name) body-load failure stays halt-strict rather than pipeline-degraded"
        }

        $singletonRecoveryWindows = [regex]::Matches(
            $content,
            '(?is).{0,140}(?:defense|judge|judgment|Code-Review-Response).{0,140}(?:pipeline-degraded|2-of-3|two-of-three|two of three|degradation|degraded).{0,140}|.{0,140}(?:pipeline-degraded|2-of-3|two-of-three|two of three|degradation|degraded).{0,140}(?:defense|judge|judgment|Code-Review-Response).{0,140}'
        )

        foreach ($window in $singletonRecoveryWindows) {
            $window.Value | Should -Match '(?is)\b(?:no|not|never|without|does not|must not|only|except|halt-strict|halt strict|halt|stop)\b' -Because '/plan must not imply that singleton defense or judge body-load failures can use pipeline-degraded recovery'
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

    It 'documents the #437 plan rollback and #414 Copilot asymmetry in the test header' {
        $content = Get-Content -Path (Join-Path $script:RepoRoot '.github\scripts\Tests\inline-dispatch-contract.Tests.ps1') -Raw -ErrorAction Stop

        $content | Should -Match ([regex]::Escape('Issue #437 intentionally rolls back the #412 D5/D6 /plan carve-out')) -Because 'the test header must explain the intentional #437 rollback of the /plan carve-out'
        $content | Should -Match ([regex]::Escape('Copilot asymmetry remains tracked by #414')) -Because 'the test header must preserve the tracked Copilot asymmetry context'
    }
}
