#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Contract tests for Issue-Planner frame spine emission guidance.

.DESCRIPTION
    Locks the issue #555 Step 2 contract that Issue-Planner-authored plans emit
    frame-slice adapter metadata while preserving durable frame-spine emission,
    acceptance-criteria coverage, plan persistence semantics, and agent identity
    wording.

    These tests cover agents/Issue-Planner.agent.md and the matching
    skills/plan-authoring/SKILL.md plan-template guidance.
#>

Describe 'Issue-Planner frame spine emission contract' -Tag 'contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:IssuePlanner = Join-Path $script:RepoRoot 'agents/Issue-Planner.agent.md'
        $script:PlanAuthoring = Join-Path $script:RepoRoot 'skills/plan-authoring/SKILL.md'
        $script:Content = Get-Content -Path $script:IssuePlanner -Raw
        $script:PlanAuthoringContent = Get-Content -Path $script:PlanAuthoring -Raw

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

        $script:GetFrameSliceBlocks = {
            param([Parameter(Mandatory)][string]$Content)

            $normalized = $Content -replace "`r`n", "`n" -replace "`r", "`n"
            $blocks = [System.Collections.Generic.List[string]]::new()
            $payloadLines = [System.Collections.Generic.List[string]]::new()
            $insideSlice = $false

            $appendPayload = {
                if ($payloadLines.Count -eq 0) { return }

                $payload = [string](($payloadLines.ToArray()) -join "`n").Trim("`n")
                if (-not [string]::IsNullOrWhiteSpace($payload)) {
                    $blocks.Add($payload) | Out-Null
                }

                $payloadLines.Clear()
            }

            foreach ($line in ($normalized -split "`n")) {
                if ($line -match '^\s*<!--\s*frame-slice(?:\s*-->)?\s*$') {
                    if ($insideSlice) { & $appendPayload }
                    $insideSlice = $true
                    continue
                }

                if (-not $insideSlice) { continue }

                if ($line -match '^\s*-->\s*$' -or $line -match '^\s*```\s*$') {
                    & $appendPayload
                    $insideSlice = $false
                    continue
                }

                $payloadLines.Add($line) | Out-Null
            }

            if ($insideSlice) {
                & $appendPayload
            }

            return [string[]]$blocks.ToArray()
        }

        $script:GetFrameSliceScalarValue = {
            param(
                [Parameter(Mandatory)][string]$SliceBlock,
                [Parameter(Mandatory)][string]$Name
            )

            $match = [regex]::Match($SliceBlock, "(?m)^\s*$([regex]::Escape($Name))\s*:\s*(?<value>.*?)\s*$")
            if (-not $match.Success) { return $null }
            return $match.Groups['value'].Value.Trim()
        }

        $script:GetFrameSliceDisplayId = {
            param(
                [Parameter(Mandatory)][string]$SliceBlock,
                [Parameter(Mandatory)][int]$Index
            )

            $id = & $script:GetFrameSliceScalarValue -SliceBlock $SliceBlock -Name 'id'
            if ([string]::IsNullOrWhiteSpace($id)) {
                $id = & $script:GetFrameSliceScalarValue -SliceBlock $SliceBlock -Name 'step_id'
            }

            if ([string]::IsNullOrWhiteSpace($id)) { return "slice#$Index" }
            return $id
        }

        $script:GetFrameSlicesMissingAdapter = {
            param([Parameter(Mandatory)][string]$Content)

            $missingSlices = [System.Collections.Generic.List[string]]::new()
            $sliceBlocks = @(& $script:GetFrameSliceBlocks -Content $Content)

            for ($index = 0; $index -lt $sliceBlocks.Count; $index++) {
                $sliceBlock = $sliceBlocks[$index]
                $adapter = & $script:GetFrameSliceScalarValue -SliceBlock $sliceBlock -Name 'adapter'
                if ([string]::IsNullOrWhiteSpace($adapter)) {
                    $missingSlices.Add((& $script:GetFrameSliceDisplayId -SliceBlock $sliceBlock -Index ($index + 1))) | Out-Null
                }
            }

            return [string[]]$missingSlices.ToArray()
        }

        $script:ResolveFrameSliceAdapterPath = {
            param([Parameter(Mandatory)][string]$AdapterValue)

            $adapterMap = @{
                'code-review-response' = 'agents\Code-Review-Response.agent.md'
                'code-smith'           = 'agents\Code-Smith.agent.md'
                'doc-keeper'           = 'agents\Doc-Keeper.agent.md'
                'experience-owner'     = 'agents\Experience-Owner.agent.md'
                'issue-planner'        = 'agents\Issue-Planner.agent.md'
                'process-review'       = 'agents\Process-Review.agent.md'
                'refactor-specialist'  = 'agents\Refactor-Specialist.agent.md'
                'solution-designer'    = 'agents\Solution-Designer.agent.md'
                'specification'        = 'agents\Specification.agent.md'
                'test-writer'          = 'agents\Test-Writer.agent.md'
                'ui-iterator'          = 'agents\UI-Iterator.agent.md'
            }

            $candidatePath = if ($adapterMap.ContainsKey($AdapterValue)) {
                Join-Path $script:RepoRoot $adapterMap[$AdapterValue]
            }
            elseif ([System.IO.Path]::IsPathRooted($AdapterValue)) {
                $AdapterValue
            }
            else {
                Join-Path $script:RepoRoot ($AdapterValue -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            }

            if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) { return $null }
            return (Resolve-Path -LiteralPath $candidatePath).ProviderPath
        }

        $script:GetFrameSlicesWithUnresolvedAdapter = {
            param([Parameter(Mandatory)][string]$Content)

            $unresolvedSlices = [System.Collections.Generic.List[string]]::new()
            $sliceBlocks = @(& $script:GetFrameSliceBlocks -Content $Content)

            for ($index = 0; $index -lt $sliceBlocks.Count; $index++) {
                $sliceBlock = $sliceBlocks[$index]
                $adapter = & $script:GetFrameSliceScalarValue -SliceBlock $sliceBlock -Name 'adapter'
                if ([string]::IsNullOrWhiteSpace($adapter)) { continue }

                $resolvedPath = & $script:ResolveFrameSliceAdapterPath -AdapterValue $adapter
                if ([string]::IsNullOrWhiteSpace($resolvedPath)) {
                    $sliceId = & $script:GetFrameSliceDisplayId -SliceBlock $sliceBlock -Index ($index + 1)
                    $unresolvedSlices.Add("${sliceId}: $adapter") | Out-Null
                }
            }

            return [string[]]$unresolvedSlices.ToArray()
        }

        $script:GetFrameSlicesWithMisorderedAdapter = {
            param([Parameter(Mandatory)][string]$Content)

            $misorderedSlices = [System.Collections.Generic.List[string]]::new()
            $sliceBlocks = @(& $script:GetFrameSliceBlocks -Content $Content)

            for ($index = 0; $index -lt $sliceBlocks.Count; $index++) {
                $sliceBlock = $sliceBlocks[$index]
                $fieldPositions = @{}
                $lines = $sliceBlock -split "`n"

                for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
                    if ($lines[$lineIndex] -match '^\s*(provides|adapter|depends-on)\s*:') {
                        $fieldName = $Matches[1]
                        if (-not $fieldPositions.ContainsKey($fieldName)) {
                            $fieldPositions[$fieldName] = $lineIndex
                        }
                    }
                }

                $hasRequiredFields = $fieldPositions.ContainsKey('provides') -and $fieldPositions.ContainsKey('adapter')
                $hasOrderedRequiredFields = $hasRequiredFields -and $fieldPositions['provides'] -lt $fieldPositions['adapter']
                $hasOrderedOptionalDependency = -not $fieldPositions.ContainsKey('depends-on') -or $fieldPositions['adapter'] -lt $fieldPositions['depends-on']
                $isOrdered = $hasOrderedRequiredFields -and $hasOrderedOptionalDependency

                if (-not $isOrdered) {
                    $misorderedSlices.Add((& $script:GetFrameSliceDisplayId -SliceBlock $sliceBlock -Index ($index + 1))) | Out-Null
                }
            }

            return [string[]]$misorderedSlices.ToArray()
        }

        $script:FrontmatterFormatPattern = '(?ms)^```yaml\s*\r?\n---\s*\r?\nstatus:\s+pending\s*\r?\npriority:\s+\{ priority \}.*\r?\nissue_id:\s+\{ issue-id \}\s*\r?\ncreated:\s+\{ date \}\s*\r?\nce_gate:\s+\{ true\|false \}'
    }

    It 'requires the plan-issue comment to include the spine, per-step slices, and AC coverage manifest in order' {
        & $script:AssertAppearsInOrder `
            -Content $script:PersistPlanSection `
            -Patterns @(
                '<!--\s*plan-issue-\{ID\}\s*-->',
                '<!--\s*frame-spine\b',
                'spine_schema_version:\s*2',
                '<!--\s*frame-slice\s*-->.{0,160}step_id:\s*s\{N\}',
                'coverage\s+manifest',
                'ac-refs-by-slice:'
            ) `
            -Because 'Persist Plan must describe the durable plan comment shape as plan marker, frame-spine schema v2, per-step frame-slice blocks, then AC coverage manifest mapping'

        $script:PersistPlanSection | Should -Match '(?is)(one|a)\s+(?:bare\s+)?`?<!--\s*frame-slice\s*-->`?.{0,220}(per|for each|each).{0,80}implementation step|(?:per|for each|each).{0,80}implementation step.{0,220}`?<!--\s*frame-slice\s*-->`?' -Because 'Issue-Planner must require one bare frame-slice block per implementation step'
        $script:PersistPlanSection | Should -Match '(?is)frame-slice.{0,180}step_id:\s*s\{N\}' -Because 'Issue-Planner must preserve slice addressability through the step_id field, not the marker suffix'
    }

    It 'requires frame-slice guidance to carry routing fields and the step Requirement Contract content' {
        $sliceGuidancePattern = '(?is)<!--\s*frame-slice\s*-->.{0,260}step_id:\s*(?:s\{N\}|\{step-id\}|sN).{0,220}commit-index:\s*(?:\{N\}|N|\d+).{0,220}provides:\s*\[[^\]]*port[^\]]*\].{0,220}adapter:\s*[^\r\n]+.{0,220}(?:cycle:\s*N)?.{0,220}(?:terminal:\s*true)?.{0,220}(?:depends-on:\s*\[[^\]]*step-ids?[^\]]*\])?.{0,260}ac-refs:\s*\[[^\]]*AC[^\]]*\].{0,260}Requirement Contract'

        $script:PersistPlanSection | Should -Match $sliceGuidancePattern -Because 'each frame-slice block must document id, commit-index, provides, adapter, optional cycle/terminal/depends-on, ac-refs, and the original step Requirement Contract content'
    }

    It 'flags a synthetic planner output when any emitted frame-slice omits adapter' {
        $plannerOutput = @(
            '<!-- frame-slice',
            'id: s1',
            'commit-index: 1',
            'provides: [implement-docs]',
            'adapter: doc-keeper',
            'depends-on: []',
            'ac-refs: [AC7]',
            'requirement-contract: |',
            '  RED docs emission test.',
            '-->',
            '',
            '<!-- frame-slice',
            'id: s2',
            'commit-index: 2',
            'provides: [implement-test]',
            'depends-on: [s1]',
            'ac-refs: [AC8]',
            'requirement-contract: |',
            '  Pre-flight fixture selection test.',
            '-->'
        ) -join "`n"

        $missingAdapters = @(& $script:GetFrameSlicesMissingAdapter -Content $plannerOutput)
        ($missingAdapters -join ',') | Should -Be 's2' -Because 'the adapter contract must identify the exact slice that omits adapter:'
    }

    It 'requires synthetic emitted frame-slice blocks to declare adapters resolvable to worktree files' {
        $plannerOutput = @(
            '<!-- frame-slice',
            'id: s1',
            'commit-index: 1',
            'provides: [implement-docs]',
            'adapter: doc-keeper',
            'depends-on: []',
            'ac-refs: [AC7]',
            'requirement-contract: |',
            '  RED docs emission test.',
            '-->',
            '',
            '<!-- frame-slice',
            'id: s2',
            'commit-index: 2',
            'provides: [implement-test]',
            'adapter: test-writer',
            'depends-on: [s1]',
            'ac-refs: [AC8]',
            'requirement-contract: |',
            '  Pre-flight fixture selection test.',
            '-->'
        ) -join "`n"

        $sliceBlocks = @(& $script:GetFrameSliceBlocks -Content $plannerOutput)
        $sliceBlocks.Count | Should -Be 2 -Because 'the synthetic fixture must exercise a multi-slice planner output'

        @(& $script:GetFrameSlicesMissingAdapter -Content $plannerOutput).Count | Should -Be 0 -Because 'every emitted frame-slice must include adapter:'
        @(& $script:GetFrameSlicesWithUnresolvedAdapter -Content $plannerOutput).Count | Should -Be 0 -Because 'adapter ids must resolve to deterministic working-tree agent files'
    }

    It 'requires Issue-Planner frame-slice output guidance to include a resolvable adapter on every slice' {
        $sliceBlocks = @(& $script:GetFrameSliceBlocks -Content $script:PersistPlanSection)
        $sliceBlocks.Count | Should -BeGreaterThan 0 -Because 'Persist Plan must include an example frame-slice payload that can be checked as synthetic planner output'

        @(& $script:GetFrameSlicesMissingAdapter -Content $script:PersistPlanSection).Count | Should -Be 0 -Because 'Issue-Planner must emit adapter: on every frame-slice it writes'
        @(& $script:GetFrameSlicesWithUnresolvedAdapter -Content $script:PersistPlanSection).Count | Should -Be 0 -Because 'documented adapter values must resolve to deterministic working-tree paths or installed-plugin-cache paths'
    }

    It 'does not flag a frame-slice with provides and adapter but no optional depends-on as misordered' {
        $plannerOutput = @(
            '<!-- frame-slice',
            'id: s1',
            'commit-index: 1',
            'provides: [implement-test]',
            'adapter: test-writer',
            'ac-refs: [AC8]',
            'requirement-contract: |',
            '  RED fixture covers optional dependency omission.',
            '-->'
        ) -join "`n"

        @(& $script:GetFrameSlicesWithMisorderedAdapter -Content $plannerOutput).Count | Should -Be 0 -Because 'depends-on is optional; present fields are ordered when provides appears before adapter'
    }

    It 'keeps adapter between provides and depends-on in documented frame-slice examples' {
        $issuePlannerSlices = @(& $script:GetFrameSliceBlocks -Content $script:PersistPlanSection)
        $planAuthoringSlices = @(& $script:GetFrameSliceBlocks -Content $script:PlanAuthoringContent)

        $issuePlannerSlices.Count | Should -BeGreaterThan 0 -Because 'Issue-Planner Persist Plan guidance must include a checkable frame-slice example'
        $planAuthoringSlices.Count | Should -BeGreaterThan 0 -Because 'Plan Authoring guidance must include checkable frame-slice examples'

        @(& $script:GetFrameSlicesWithMisorderedAdapter -Content $script:PersistPlanSection).Count | Should -Be 0 -Because 'Issue-Planner frame-slice guidance must place adapter: after provides: and before depends-on:'
        @(& $script:GetFrameSlicesWithMisorderedAdapter -Content $script:PlanAuthoringContent).Count | Should -Be 0 -Because 'Plan Authoring frame-slice examples must place adapter: after provides: and before depends-on:'
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
