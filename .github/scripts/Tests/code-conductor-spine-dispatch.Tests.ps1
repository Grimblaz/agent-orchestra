#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    RED contract tests for Code-Conductor frame-spine specialist dispatch guidance.

.DESCRIPTION
    Locks issue #512 AC5 before production guidance is updated. Code-Conductor
    must dispatch specialists with a bounded spine-bearing context when a plan
    contains a frame-spine, fall back visibly for legacy or over-budget plans,
    and preserve its existing ownership and ANNOUNCE-before-tool-call stance.

    These tests intentionally target agents/Code-Conductor.agent.md guidance only.
    Production guidance is expected to fail the spine/fallback assertions until
    Step 8 GREEN amends the Execute Each Step section.
#>

Describe 'Code-Conductor frame-spine dispatch contract' -Tag 'contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:CodeConductor = Join-Path $script:RepoRoot 'agents/Code-Conductor.agent.md'
        $script:FrameSpineCore = Join-Path $script:RepoRoot '.github/scripts/lib/frame-spine-core.ps1'

        if (Test-Path $script:FrameSpineCore) {
            . $script:FrameSpineCore
        }

        $script:Content = (Get-Content -Path $script:CodeConductor -Raw -ErrorAction Stop) -replace "`r`n?", "`n"

        $script:GetBoundedSection = {
            param(
                [Parameter(Mandatory)][string]$Content,
                [Parameter(Mandatory)][string]$StartPattern,
                [Parameter(Mandatory)][string]$EndPattern,
                [Parameter(Mandatory)][string]$SectionName
            )

            $pattern = '(?ms)^' + $StartPattern + '\s*\n(?<body>.*?)(?=^' + $EndPattern + '|\z)'
            $match = [regex]::Match($Content, $pattern)
            $match.Success | Should -BeTrue -Because "the Code-Conductor body must keep an extractable $SectionName section"

            if (-not $match.Success) {
                return ''
            }

            return $match.Groups['body'].Value
        }

        $script:ExecuteEachStepSection = & $script:GetBoundedSection `
            -Content $script:Content `
            -StartPattern '\s*3\.\s+\*\*Execute Each Step\*\*:' `
            -EndPattern '\s*4\.\s+\*\*Create PR\b' `
            -SectionName '3. Execute Each Step'

        $script:OwnershipPrinciplesSection = & $script:GetBoundedSection `
            -Content $script:Content `
            -StartPattern '## Ownership Principles' `
            -EndPattern '<critical_rules>' `
            -SectionName 'Ownership Principles'

        $script:PipelineMetricsSection = & $script:GetBoundedSection `
            -Content $script:Content `
            -StartPattern '## Pipeline Metrics' `
            -EndPattern '### Pipeline-Entry Credit Harvest' `
            -SectionName 'Pipeline Metrics'

        $script:DispatchMetricsLifecycleText = "$($script:ExecuteEachStepSection)`n$($script:PipelineMetricsSection)"

        $script:WriteCommentBody = {
            param([Parameter(Mandatory)][string]$Content)

            $path = Join-Path -Path 'TestDrive:' -ChildPath "conductor-spine-$([System.Guid]::NewGuid().ToString('N')).md"
            Set-Content -Path $path -Value $Content -Encoding utf8NoBOM
            return $path
        }
    }

    It 'requires spine-bearing specialist dispatch context to include spine, active slice, and depth-1 dependencies' {
        $script:ExecuteEachStepSection | Should -Match '(?is)spine-bearing plans?.{0,900}(dispatch context|specialist dispatch context|context).{0,500}(frame-spine block|<!--\s*frame-spine\b)' `
            -Because 'spine-bearing plans must dispatch a focused context that includes the frame-spine block'

        $script:ExecuteEachStepSection | Should -Match '(?is)(active step''?s?|current step''?s?).{0,180}(frame-slice|slice)' `
            -Because 'spine-bearing dispatch context must include the active step frame-slice'

        $script:ExecuteEachStepSection | Should -Match '(?is)(depth-1|depth 1|one-hop).{0,220}depends-on.{0,220}slices?.{0,260}(resolved against|resolve(?:d)? from|via).{0,160}spine' `
            -Because 'spine-bearing dispatch context must include only depth-1 depends-on slices resolved against the spine'
    }

    It 'uses the spine lookup path to select the active slice from a schema v2 plan with adapters' {
        $spine = @(
            'spine_schema_version: 2'
            'generated_at: 2026-05-11T10:05:00Z'
            'coverage: complete'
            'ports:'
            '  implement-code: [s2]'
            '  implement-test: [s3#terminal]'
            'slices:'
            '  s2:'
            '    execution_mode: serial'
            '    adapter: agents/Code-Smith.agent.md'
            '    rc: GREEN code action'
            '    ac_refs: [AC1]'
            '    depends_on: []'
            '    cycle: 1'
            '  s3:'
            '    execution_mode: serial'
            '    adapter: agents/Test-Writer.agent.md'
            '    rc: RED tests for v2 schema acceptance'
            '    ac_refs: [AC1, AC5, AC7]'
            '    depends_on: [s2]'
            '    cycle: 1'
            '    terminal: true'
        ) -join "`n"
        $s2Slice = @(
            'id: s2'
            'provides: [implement-code]'
            'adapter: agents/Code-Smith.agent.md'
            'execution_mode: serial'
            'rc: GREEN code action'
            'ac_refs: [AC1]'
            'depends_on: []'
            'cycle: 1'
        ) -join "`n"
        $s3Slice = @(
            'id: s3'
            'provides: [implement-test]'
            'adapter: agents/Test-Writer.agent.md'
            'execution_mode: serial'
            'rc: RED tests for v2 schema acceptance'
            'ac_refs: [AC1, AC5, AC7]'
            'depends_on: [s2]'
            'cycle: 1'
            'terminal: true'
        ) -join "`n"
        $planComment = @(
            '<!-- plan-issue-555 -->'
            ''
            '<!-- frame-spine'
            $spine
            '-->'
            ''
            '<!-- frame-slice'
            $s2Slice
            '-->'
            ''
            '<!-- frame-slice'
            $s3Slice
            '-->'
        ) -join "`n"
        $commentFile = & $script:WriteCommentBody -Content $planComment
        $resolvedPath = (Resolve-Path -LiteralPath $commentFile).ProviderPath

        $result = Invoke-FSCSpineLookupCli -CommentBodyPath $resolvedPath -Format Json -GeneratedAt '2026-05-11T10:05:00Z' -StepId 's3'

        $result.ExitCode | Should -Be 0
        $parsed = (($result.Lines) -join "`n") | ConvertFrom-Json
        $parsed.status | Should -Be 'ok'
        $parsed.step_id | Should -Be 's3'
        $parsed.slice | Should -Match 'adapter:\s*agents/Test-Writer\.agent\.md'
        $parsed.slice | Should -Match 'provides:\s*\[implement-test\]'
        $parsed.slice | Should -Not -Match 'adapter:\s*agents/Code-Smith\.agent\.md'
        $parsed.slice | Should -Not -Match 'provides:\s*\[implement-code\]'
    }

    It 'requires legacy no-spine plans to fall back to full-plan dispatch with a visible metrics event' {
        $script:ExecuteEachStepSection | Should -Match '(?is)(legacy plans?|no spine block|without (?:a )?frame-spine block).{0,700}(dispatch|send|include).{0,180}(full plan|entire plan).{0,900}dispatch-fallback-events:\s*(?:\n|\s).{0,260}legacy-plan-shape:\s*true' `
            -Because 'legacy plans without a spine must dispatch the full plan and record dispatch-fallback-events: legacy-plan-shape: true in PR-body pipeline metrics'
    }

    It 'requires over-budget spine contexts to fall back to full-plan dispatch with a visible metrics event' {
        $script:ExecuteEachStepSection | Should -Match '(?is)(8\s*KB|8192|context budget).{0,900}(frame-spine|spine).{0,300}(active.{0,80}slice|frame-slice).{0,300}(depends-on|dependenc).{0,900}(exceed|over|larger than).{0,600}(full plan|entire plan).{0,700}dispatch-fallback-events:\s*(?:\n|\s).{0,260}pre-load-budget-exceeded:\s*true' `
            -Because 'when spine plus active slice plus depth-1 dependencies exceed the 8 KB context budget, Code-Conductor must dispatch the full plan and record pre-load-budget-exceeded: true'
    }

    It 'requires spine-bearing dispatch announcements to cite the frame-spine lookup skill' {
        $script:ExecuteEachStepSection | Should -Match '(?is)(ANNOUNCE|announcement|Calling @\{Agent-Name\}).{0,1500}(spine-bearing|spine context|frame-spine).{0,700}skills/frame-spine-lookup/SKILL\.md|skills/frame-spine-lookup/SKILL\.md.{0,1500}(ANNOUNCE|announcement|Calling @\{Agent-Name\})' `
            -Because 'when dispatch carries spine-bearing context, the visible specialist announcement must cite skills/frame-spine-lookup/SKILL.md'
    }

    It 'requires dispatch-cost samples to accumulate before PR creation and flush into the initial PR body' {
        $script:DispatchMetricsLifecycleText | Should -Match '(?is)dispatch-cost-samples.{0,700}(session memory|PR-body draft|pre-PR accumulator).{0,500}(not a live PR body|before a PR exists)' `
            -Because 'dispatch-time placeholders can occur before a PR exists, so Code-Conductor must use a pre-PR accumulator or draft PR body'

        $script:DispatchMetricsLifecycleText | Should -Match '(?is)RC conformance.{0,240}back-fill.{0,420}accumulator.{0,420}PR creation' `
            -Because 'RC conformance back-fill before PR creation must update the same accumulated sample that will be flushed later'

        $script:DispatchMetricsLifecycleText | Should -Match '(?is)PR creation.{0,240}flush(?:es)?.{0,420}(initial PR body|emitted `<!-- pipeline-metrics -->` block)' `
            -Because 'the initial PR body must receive accumulated dispatch-cost samples during PR creation'

        $script:DispatchMetricsLifecycleText | Should -Match '(?is)After (?:the )?PR (?:exists|creation).{0,420}(RC conformance|judge disposition).{0,420}live PR body.{0,420}\(step-id, mode\)' `
            -Because 'post-creation RC or judge updates must target the live PR body sample by composite key'
    }

    It 'requires Copilot-only cost-collection pre-flight sub-bullet under Hub Execution Workflow item 3' {
        # Platform-scope prefix must be present
        $script:ExecuteEachStepSection | Should -Match '(?is)\*\*Copilot\s+dispatch\s+only\*\*' `
            -Because 'the Copilot-only pre-flight check must begin with the **Copilot dispatch only:** platform-scope prefix'

        # Sentinel detection must be referenced
        $script:ExecuteEachStepSection | Should -Match '(?is)\.copilot-cost-collection-installed' `
            -Because 'the pre-flight must detect the cost-collection sentinel file at workspace root'

        # D8 option 1 must begin with the prescribed text (F12a: amended to clarify producer-wiring needed)
        $script:ExecuteEachStepSection | Should -Match ([regex]::Escape('Install Copilot cost collection now? (Recommended')) `
            -Because 'D8 option 1 text must begin with the prescribed Install... (Recommended prefix in the Copilot dispatch pre-flight sub-bullet'

        # D8 option 2 verbatim
        $script:ExecuteEachStepSection | Should -Match 'Continue without\s+\u2014\s+S4 cost-parity scenario will be INCONCLUSIVE for this PR' `
            -Because 'D8 option 2 text must be present verbatim in the Copilot dispatch pre-flight sub-bullet'

        # Session-scoped suppression key
        $script:ExecuteEachStepSection | Should -Match ([regex]::Escape('cost-collection-install-prompt-{repo-cwd}')) `
            -Because 'session-scoped suppression key (SMC-18) must be referenced to suppress repeated prompts within a session'
    }

    It 'requires SMC-18 suppression: skip-if-set behavior, headless skip, and platform-gate are all documented (F8 behavioral coverage)' {
        # Suppression check: if the key is already set, skip the prompt
        $script:ExecuteEachStepSection | Should -Match '(?is)(key is already set|key.{0,60}set|suppression key.{0,80}skip).{0,400}(skip.{0,80}prompt|prompt.{0,80}skip)' `
            -Because 'SMC-18 suppression must document: check key first; if set, skip prompt entirely (no re-prompt this session)'

        # Headless skip: when vscode/askQuestions is unavailable, skip silently
        $script:ExecuteEachStepSection | Should -Match '(?is)(Headless skip|vscode/askQuestions.{0,80}unavailable|CI or programmatic).{0,300}skip' `
            -Because 'the sub-bullet must document the headless-skip clause for CI / programmatic invocations'

        # Platform gate: Claude orchestration paths skip this sub-bullet entirely
        $script:ExecuteEachStepSection | Should -Match '(?is)(Claude orchestration|Claude.{0,40}paths).{0,200}(skip|gate|not.{0,20}applicable)' `
            -Because 'the platform-scope gate must document that Claude orchestration paths skip this sub-bullet entirely'
    }

    It 'preserves Code-Conductor ownership stance and ANNOUNCE-before-tool-call rule' {
        $script:OwnershipPrinciplesSection | Should -Match '\*\*You own the outcome, not just the process\.\*\*' `
            -Because 'Step 8 must preserve Code-Conductor outcome ownership language'

        $script:Content | Should -Match 'You are an ORCHESTRATOR AGENT, NOT an implementation agent' `
            -Because 'Step 8 must preserve the conductor-not-implementer stance'

        $script:Content | Should -Match '(?is)MUST delegate all specialized tasks to expert agents via `runSubagent`' `
            -Because 'Step 8 must preserve specialist delegation ownership boundaries'

        $script:ExecuteEachStepSection | Should -Match '(?is)\*\*ANNOUNCE\*\*.{0,180}Calling @\{Agent-Name\} for \{step\}.{0,120}BEFORE tool call' `
            -Because 'Step 8 must preserve the ANNOUNCE-before-tool-call rule'
    }
}
