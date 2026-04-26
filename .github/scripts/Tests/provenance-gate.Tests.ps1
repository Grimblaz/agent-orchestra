#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Contract tests for the issue #447 provenance-gate UX redesign.

.DESCRIPTION
    Locks the provenance-gate contract before the prompt surfaces are updated.
    These tests enforce the committed two-stage UX across the shared skill and
    platform notes so the suite stays red until the design is implemented.
#>

Describe 'provenance-gate UX contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:SkillPath = Join-Path $script:RepoRoot 'skills\provenance-gate\SKILL.md'
        $script:ClaudePlatformPath = Join-Path $script:RepoRoot 'skills\provenance-gate\platforms\claude.md'
        $script:CopilotPlatformPath = Join-Path $script:RepoRoot 'skills\provenance-gate\platforms\copilot.md'
        $script:LegacyLabels = @(
            'Assessment looks right - proceed with caution',
            'Needs rework - stop here'
        )

        $script:GetCanonicalLabelList = {
            param(
                [string]$Content,
                [string]$Heading,
                [int]$ExpectedCount
            )

            $pattern = '(?ms)^' + [regex]::Escape($Heading) + '\s*\r?\n\r?\n```yaml\r?\n(?<yaml>.*?)\r?\n```'
            $match = [regex]::Match($Content, $pattern)

            $match.Success | Should -BeTrue -Because "the skill must publish the $Heading fenced YAML block"
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
                $lineMatch.Success | Should -BeTrue -Because "$Heading entries must stay as single-line YAML list items"
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

            $labels.Count | Should -Be $ExpectedCount -Because "$Heading must publish $ExpectedCount canonical labels"
            return @($labels)
        }

        $script:GetYamlMap = {
            param(
                [string]$Content,
                [string]$Heading
            )

            $pattern = '(?ms)^' + [regex]::Escape($Heading) + '\s*\r?\n\r?\n```yaml\r?\n(?<yaml>.*?)\r?\n```'
            $match = [regex]::Match($Content, $pattern)

            $match.Success | Should -BeTrue -Because "the skill must publish the $Heading fenced YAML block"
            if (-not $match.Success) {
                return [ordered]@{}
            }

            $map = [ordered]@{}
            $linePattern = '^\s*(?<key>[A-Za-z0-9_]+):\s*(?<value>.*)$'
            foreach ($line in ($match.Groups['yaml'].Value -split "`r?`n")) {
                if ($line -match '^\s*$') {
                    continue
                }

                $lineMatch = [regex]::Match($line, $linePattern)
                $lineMatch.Success | Should -BeTrue -Because "$Heading entries must stay as single-line YAML mappings"
                if (-not $lineMatch.Success) {
                    continue
                }

                $map[$lineMatch.Groups['key'].Value] = $lineMatch.Groups['value'].Value.Trim()
            }

            return $map
        }

        $script:SkillContent = Get-Content -Path $script:SkillPath -Raw -ErrorAction Stop
        $script:ClaudePlatformContent = Get-Content -Path $script:ClaudePlatformPath -Raw -ErrorAction Stop
        $script:CopilotPlatformContent = Get-Content -Path $script:CopilotPlatformPath -Raw -ErrorAction Stop
        $script:Stage1Labels = & $script:GetCanonicalLabelList -Content $script:SkillContent -Heading '### Stage-1 Self-Classification Labels' -ExpectedCount 3
        $script:Stage2Labels = & $script:GetCanonicalLabelList -Content $script:SkillContent -Heading '### Stage-2 Cold-Only Assessment Labels' -ExpectedCount 3
        $script:OfflinePayloadSchema = & $script:GetYamlMap -Content $script:SkillContent -Heading '### Offline Fallback Payload Schema'
        $script:PlatformDocs = @(
            @{ Name = 'Claude Code platform note'; Content = $script:ClaudePlatformContent },
            @{ Name = 'Copilot platform note'; Content = $script:CopilotPlatformContent }
        )
    }

    It 'publishes the two-stage canonical label sets from the shared skill' {
        $script:Stage1Labels | Should -HaveCount 3
        $script:Stage1Labels[0] | Should -Be "I wrote this / I'm fully briefed"
        $script:Stage1Labels[1] | Should -Be "I'm picking this up cold"
        $script:Stage1Labels[2] | Should -Be 'Stop — needs rework first'

        $script:Stage2Labels | Should -HaveCount 3
        $script:Stage2Labels[0] | Should -Be 'Assessment looks right — proceed'
        $script:Stage2Labels[1] | Should -Be 'Proceed but carry concerns forward'
        $script:Stage2Labels[2] | Should -Be 'Needs rework — stop here'
    }

    It 'keeps stage 2 cold-only across the skill and platform notes' {
        $script:SkillContent | Should -Match '(?is)(only if|only when).{0,140}I''m picking this up cold|cold-only|cold path' -Because 'the skill must make the second question conditional on the cold path'

        foreach ($platform in $script:PlatformDocs) {
            foreach ($label in ($script:Stage1Labels + $script:Stage2Labels)) {
                $platform.Content | Should -Match ([regex]::Escape($label)) -Because "$($platform.Name) must mirror the canonical provenance-gate labels"
            }

            $platform.Content | Should -Match '(?is)(only if|only when).{0,140}I''m picking this up cold|cold-only|cold path' -Because "$($platform.Name) must tell the caller that stage 2 only runs on the cold path"
        }
    }

    It 'halts without posting the marker on both stop paths' {
        $script:SkillContent | Should -Match '(?is)Stop — needs rework first.{0,240}(stop|halt).{0,240}(do not post|without posting|no marker).{0,160}first-contact-assessed' -Because 'the stage-1 stop path must halt without recording the marker'
        $script:SkillContent | Should -Match '(?is)Needs rework — stop here.{0,240}(stop|halt).{0,240}(do not post|without posting|no marker).{0,160}first-contact-assessed' -Because 'the stage-2 stop path must halt without recording the marker'
    }

    It 'requires a two-line marker while keeping the HTML token as the only skip-check anchor' {
        $script:SkillContent | Should -Match '(?ms)<!-- first-contact-assessed-\{ID\} -->\s*\r?\n(?!\s*<!--)\s*\S.+' -Because 'the skill must show a two-line durable marker with a human-readable second line'
        $script:SkillContent | Should -Match '(?is)(HTML token).{0,120}(line 1).{0,180}(only skip-check anchor|only parser anchor|only anchor)' -Because 'the skill must preserve the HTML token as the sole skip-check anchor'
        $script:SkillContent | Should -Match '(?is)(second line|second-line).{0,120}(human-readable|decorative)' -Because 'the skill must describe the second marker line as decorative only'
    }

    It 'defines the offline fallback payload schema and the allowed persisted outcomes' {
        $script:OfflinePayloadSchema.Keys | Should -Contain 'issue_id'
        $script:OfflinePayloadSchema.Keys | Should -Contain 'outcome'
        $script:OfflinePayloadSchema.Keys | Should -Contain 'concerns'
        $script:OfflinePayloadSchema.Keys | Should -Contain 'sync_to_github_on_next_online_run'

        $script:SkillContent | Should -Match ([regex]::Escape('fast-path')) -Because 'the offline payload must support the fast-path persisted outcome'
        $script:SkillContent | Should -Match ([regex]::Escape('proceeded')) -Because 'the offline payload must support the proceeded persisted outcome'
        $script:SkillContent | Should -Match ([regex]::Escape('proceeded with concerns')) -Because 'the offline payload must support the carried-concerns persisted outcome'
    }

    It 'distinguishes an existing GitHub marker from a local fallback payload during recovery' {
        $script:SkillContent | Should -Match '(?is)(GitHub issue comments|GitHub marker).{0,180}<!-- first-contact-assessed-\{ID\} -->.{0,220}(skip the gate silently|skip the gate entirely)' -Because 'the skill must only let an existing durable GitHub marker resume normal skip behavior'
        $script:SkillContent | Should -Match '(?is)(next online invocation|next online run).{0,160}(GitHub marker is still missing|GitHub marker.*missing).{0,160}(local payload exists|local payload).{0,220}(reconstruct|rebuild|sync).{0,220}(GitHub marker|first-contact-assessed)' -Because 'the skill must require local fallback payloads to synchronize the GitHub marker before normal skip behavior resumes'
        $script:SkillContent | Should -Not -Match '(?is)(session memory|/memories/session/first-contact-assessed-\{ID\}\.md).{0,220}(skip the gate silently|skip the gate entirely)' -Because 'the local fallback payload must not silently short-circuit the recovery path as if it were already a durable GitHub marker'
    }

    It 'requires next-online GitHub sync and rejects the legacy label set' {
        $script:SkillContent | Should -Match '(?is)(next online invocation|next online run).{0,180}(local payload|offline fallback payload).{0,220}(reconstruct|rebuild|sync).{0,220}(GitHub marker|first-contact-assessed)' -Because 'the skill must trigger GitHub marker reconstruction when the next online run finds only the local payload'

        foreach ($content in @($script:SkillContent, $script:ClaudePlatformContent, $script:CopilotPlatformContent)) {
            foreach ($legacyLabel in $script:LegacyLabels) {
                $content | Should -Not -Match ([regex]::Escape($legacyLabel)) -Because "the new contract must not retain compatibility prose for the legacy label '$legacyLabel'"
            }
        }
    }
}
