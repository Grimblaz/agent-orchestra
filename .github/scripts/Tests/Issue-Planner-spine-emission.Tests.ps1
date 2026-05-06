#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    RED contract tests for Issue-Planner frame spine emission guidance.

.DESCRIPTION
    Locks the issue #512 AC3 contract that Issue-Planner-authored plans emit a
    durable frame-spine block, one frame-slice block per implementation step,
    and an acceptance-criteria coverage manifest while preserving existing plan
    persistence semantics and agent identity wording.

    These tests intentionally target agents/Issue-Planner.agent.md guidance only.
    Production guidance is expected to fail these tests until Step 7 GREEN amends
    the Persist Plan section.
#>

Describe 'Issue-Planner frame spine emission contract' -Tag 'contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:IssuePlanner = Join-Path $script:RepoRoot 'agents\Issue-Planner.agent.md'
        $script:Content = Get-Content -Path $script:IssuePlanner -Raw

        $script:GetSection = {
            param(
                [Parameter(Mandatory)][string]$Content,
                [Parameter(Mandatory)][string]$HeadingPattern
            )

            $sectionMatch = [regex]::Match($Content, "(?ms)^$HeadingPattern\s*\r?\n(?<body>.*?)(?=^## |\z)")
            $sectionMatch.Success | Should -BeTrue -Because "the agent body must keep a bounded section matching $HeadingPattern"

            return $sectionMatch.Groups['body'].Value
        }

        $script:PersistPlanSection = & $script:GetSection -Content $script:Content -HeadingPattern '## 6\. Persist Plan'
        $script:CorePrinciplesSection = & $script:GetSection -Content $script:Content -HeadingPattern '## Core Principles'

        $script:AssertAppearsInOrder = {
            param(
                [Parameter(Mandatory)][string]$Content,
                [Parameter(Mandatory)][string[]]$Patterns,
                [Parameter(Mandatory)][string]$Because
            )

            $cursor = 0

            foreach ($pattern in $Patterns) {
                $match = [regex]::Match($Content.Substring($cursor), $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)
                $match.Success | Should -BeTrue -Because $Because
                $cursor += $match.Index + $match.Length
            }
        }

        $script:FrontmatterFormatPattern = '(?ms)^```yaml\s*\r?\n---\s*\r?\nstatus:\s+pending\s*\r?\npriority:\s+\{ priority \}.*\r?\nissue_id:\s+\{ issue-id \}\s*\r?\ncreated:\s+\{ date \}\s*\r?\nce_gate:\s+\{ true\|false \}'
    }

    It 'requires the plan-issue comment to include the spine, per-step slices, and AC coverage manifest in order' {
        & $script:AssertAppearsInOrder `
            -Content $script:PersistPlanSection `
            -Patterns @(
                '<!--\s*plan-issue-\{ID\}\s*-->',
                '<!--\s*frame-spine\b',
                'spine_schema_version:\s*1',
                '<!--\s*frame-slice\s*-->.{0,160}step_id:\s*s\{N\}',
                'coverage\s+manifest',
                'ac-refs-by-slice:'
            ) `
            -Because 'Persist Plan must describe the durable plan comment shape as plan marker, frame-spine schema v1, per-step frame-slice blocks, then AC coverage manifest mapping'

        $script:PersistPlanSection | Should -Match '(?is)(one|a)\s+(?:bare\s+)?`?<!--\s*frame-slice\s*-->`?.{0,220}(per|for each|each).{0,80}implementation step|(?:per|for each|each).{0,80}implementation step.{0,220}`?<!--\s*frame-slice\s*-->`?' -Because 'Issue-Planner must require one bare frame-slice block per implementation step'
        $script:PersistPlanSection | Should -Match '(?is)frame-slice.{0,180}step_id:\s*s\{N\}' -Because 'Issue-Planner must preserve slice addressability through the step_id field, not the marker suffix'
    }

    It 'requires frame-slice guidance to carry routing fields and the step Requirement Contract content' {
        $sliceGuidancePattern = '(?is)<!--\s*frame-slice\s*-->.{0,260}step_id:\s*(?:s\{N\}|\{step-id\}|sN).{0,220}commit-index:\s*(?:\{N\}|N|\d+).{0,220}provides:\s*\[[^\]]*port[^\]]*\].{0,220}(?:cycle:\s*N)?.{0,220}(?:terminal:\s*true)?.{0,220}(?:depends-on:\s*\[[^\]]*step-ids?[^\]]*\])?.{0,260}ac-refs:\s*\[[^\]]*AC[^\]]*\].{0,260}Requirement Contract'

        $script:PersistPlanSection | Should -Match $sliceGuidancePattern -Because 'each frame-slice block must document id, commit-index, provides, optional cycle/terminal/depends-on, ac-refs, and the original step Requirement Contract content'
    }

    It 'requires tiny plans to emit an explicit plan-too-small omission marker instead of a spine block' {
        $script:PersistPlanSection | Should -Match '(?is)(fewer than 3|less than 3|under 3).{0,260}implementation steps?.{0,260}spine-omitted:\s*plan-too-small.{0,260}(no|do not|omit|without).{0,160}(<!--\s*frame-spine|frame-spine block)' -Because 'plans with fewer than three implementation steps must mark spine omission and avoid emitting a frame-spine block'
    }

    It 'requires generated_at preservation and duplicate-comment normalization semantics' {
        $script:PersistPlanSection | Should -Match '(?is)generated_at.{0,160}(set|created|assigned).{0,120}plan creation' -Because 'generated_at must be set when the plan spine is first created'
        $script:PersistPlanSection | Should -Match '(?is)generated_at.{0,180}preserv(?:e|ed|es|ing).{0,220}same-content re-emissions|same-content re-emissions.{0,220}preserv(?:e|ed|es|ing).{0,180}generated_at' -Because 'same-content plan re-emissions must preserve generated_at'
        $script:PersistPlanSection | Should -Match '(?is)D9.{0,180}(normalized comparison|comparison hash|hash).{0,220}(hash-elides|elides|excludes|ignores).{0,80}generated_at.{0,260}(identical content|same content).{0,220}(does not|do not|must not|avoid).{0,120}(append|post|create).{0,120}duplicate comments?' -Because 'D9 comparison must hash-elide generated_at so unchanged plans do not append duplicate comments'
    }

    It 'preserves existing plan persistence markers, frontmatter, credit input, and session cache references' {
        $script:PersistPlanSection | Should -Match '<!--\s*plan-issue-\{ID\}\s*-->' -Because 'SMC-01 plan marker must remain present'
        $script:PersistPlanSection | Should -Match $script:FrontmatterFormatPattern -Because 'plan YAML frontmatter format must remain status/priority/issue_id/created/ce_gate'
        $script:PersistPlanSection | Should -Match '<!--\s*credit-input-plan-\{ISSUE_NUMBER\}\s*-->' -Because 'SMC-17 credit-input-plan marker must remain present'
        $script:PersistPlanSection | Should -Match 'SMC-01' -Because 'plan persistence must remain tied to SMC-01'
        $script:PersistPlanSection | Should -Match 'SMC-03' -Because 'design cache persistence must remain tied to SMC-03'
        $script:PersistPlanSection | Should -Match '(?i)/memories/session/plan-issue-\{id\}\.md' -Because 'canonical plan session-memory cache reference must remain present'
        $script:PersistPlanSection | Should -Match '(?i)/memories/session/design-issue-\{id\}\.md' -Because 'canonical design session-memory cache reference must remain present'
    }

    It 'preserves the agent identity and Core Principles stance while adding spine guidance' {
        $script:Content | Should -Match 'You are a meticulous strategist who leaves nothing to chance' -Because 'the top identity hook must remain stance-preserving'
        $script:CorePrinciplesSection | Should -Match '\*\*The plan is the contract\.\*\*' -Because 'Core Principles must keep the plan-contract identity wording'
        $script:CorePrinciplesSection | Should -Match '\*\*Planning is your sole responsibility\.\*\* NEVER start implementation' -Because 'Core Principles must keep the planner-not-implementer boundary'
        $script:CorePrinciplesSection | Should -Match '\*\*Every step earns its place\.\*\*' -Because 'Core Principles must keep AC traceability as a planning stance'
    }
}
