#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Contract tests for handoff persistence wording and pipeline gate markers.

.DESCRIPTION
    Locks the execution handoff persistence contract across:
      - .github/agents/Issue-Planner.agent.md
      - .github/agents/Code-Conductor.agent.md
      - .github/copilot-instructions.md
      - .github/instructions/tracking-format.instructions.md
      - .github/prompts/start-issue.prompt.md
      - Documents/Design/plan-storage.md
      - Documents/Design/hub-mode-ux.md

        The files must describe the same semantics for:
            - Issue-Planner persists only session-memory artifacts at plan time
            - Code-Conductor D9 owns durable GitHub handoff persistence
            - Stop or pause persists durable handoff comments; Continue stays session-memory-only
            - Solution-Designer issue-body persistence remains unconditional
            - Canonical plan and design markers remain unchanged
            - Latest-comment-wins lookup and bundle plan naming remain unchanged
            - First-contact provenance gate trigger and marker reference present

        These tests actively enforce the D9-owned handoff persistence wording contract (issue #186) and the provenance gate trigger contract (issue #300), guarding against future contract drift.
#>

Describe 'execution handoff persistence contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:IssuePlanner = Join-Path $script:RepoRoot '.github\agents\Issue-Planner.agent.md'
        $script:CodeConductor = Join-Path $script:RepoRoot '.github\agents\Code-Conductor.agent.md'
        $script:CopilotInstructions = Join-Path $script:RepoRoot '.github\copilot-instructions.md'
        $script:ExperienceOwner = Join-Path $script:RepoRoot '.github\agents\Experience-Owner.agent.md'
        $script:SolutionDesigner = Join-Path $script:RepoRoot '.github\agents\Solution-Designer.agent.md'
        $script:TrackingInstructions = Join-Path $script:RepoRoot '.github\instructions\tracking-format.instructions.md'
        $script:StartIssuePrompt = Join-Path $script:RepoRoot '.github\prompts\start-issue.prompt.md'
        $script:PlanStorage = Join-Path $script:RepoRoot 'Documents\Design\plan-storage.md'
        $script:HubModeUx = Join-Path $script:RepoRoot 'Documents\Design\hub-mode-ux.md'
        $script:PipelineEntryAgents = @(
            @{
                Name = 'Experience-Owner'
                Path = $script:ExperienceOwner
            },
            @{
                Name = 'Solution-Designer'
                Path = $script:SolutionDesigner
            },
            @{
                Name = 'Issue-Planner'
                Path = $script:IssuePlanner
            },
            @{
                Name = 'Code-Conductor'
                Path = $script:CodeConductor
            }
        )

        $script:ReadContent = {
            param([string]$Path)

            return Get-Content -Path $Path -Raw
        }

        $script:CanonicalPlanPathPattern = '(?i)/memories/session/plan-issue-\{id\}\.md'
        $script:CanonicalDesignPathPattern = '(?i)/memories/session/design-issue-\{id\}\.md'
        $script:D9DurabilityPattern = '(?is)(Code-Conductor|D9).{0,240}(Stop|Pause|resume later|switch models).{0,320}(persist|durable|GitHub issue comment).{0,240}(plan-issue|design-issue)'
        $script:ContinueSessionMemoryPattern = '(?is)(Continue implementation|Continue|same-session).{0,240}(session memory only|session memory is the source of truth|no redundant GitHub|no new .*plan-issue.*design-issue.* comments?)'
        $script:PausePersistsBothMarkersPattern = '(?is)Pause here\s+—\s+I''ll resume with `/implement`.{0,500}(persist|save|append).{0,250}(plan-issue-\{ID\}|<!-- plan-issue-\{ID\} -->).{0,250}(design-issue-\{ID\}|<!-- design-issue-\{ID\} -->)'
        $script:PauseNormalizesTransportFormattingDriftPattern = '(?is)Pause here\s+—\s+I''ll resume with `/implement`.{0,500}(normalizing away|ignoring).{0,120}transport-only formatting drift.{0,220}(line-ending normalization|trailing newlines/whitespace).{0,320}(normalized content changed|artifact is missing or whose normalized content changed)'
        $script:LatestCommentWinsPattern = '(?is)(if multiple matching comments exist, use the most recently posted one|latest matching comment)'
        $script:D9SuppressionRequiresTierDurabilityPattern = '(?is)Smart resume found ALL prior-session artifacts required by the current pipeline tier.{0,400}abbreviated pipeline:.*plan-issue-\{ID\}.*required durable handoff artifact.{0,400}full pipeline:.*experience-owner-complete-\{ID\}.*design-phase-complete-\{ID\}.*plan-issue-\{ID\}.*design-issue-\{ID\}.*durable handoff comments.{0,300}D9 suppression requires those prior-session durable handoff artifacts when the selected tier needs them, not just phase markers'
        $script:BundleD9SuppressionPattern = '(?is)For multi-issue bundles, ALL required prior-session markers and durable handoff comments for ALL bundled issues \(not just the primary issue\) must already exist before D9 may be suppressed'
        $script:ProvenanceGateMarkerPattern = '(?i)first-contact-assessed-\{ID\}'
        $script:AssertSharedDocContract = {
            param(
                [string]$Content,
                [string]$Name,
                [string]$LegacyPattern
            )

            $Content | Should -Match $script:D9DurabilityPattern -Because "$Name must name Code-Conductor or D9 as the durable handoff owner"
            $Content | Should -Match $script:ContinueSessionMemoryPattern -Because "$Name must describe the session-memory-only continue path"
            $Content | Should -Not -Match $LegacyPattern -Because "$Name must stop describing planner-time comment posting as the normal cross-session path"
        }

        $script:SharedDocContracts = @(
            @{
                Name          = 'copilot-instructions'
                Path          = $script:CopilotInstructions
                LegacyPattern = '(?is)optionally persisted as GitHub issue comments|use GitHub issue comments for cross-session durability'
            },
            @{
                Name          = 'tracking-format.instructions'
                Path          = $script:TrackingInstructions
                LegacyPattern = '(?is)Issue-Planner can optionally post the plan as a GitHub issue comment|optionally posts as a GitHub issue comment with `<!-- plan-issue-\{ID\} -->` marker'
            },
            @{
                Name          = 'start-issue.prompt'
                Path          = $script:StartIssuePrompt
                LegacyPattern = '(?is)or GitHub issue comment if the plan was persisted there|Issue-Planner can optionally post the plan as a GitHub issue comment'
            },
            @{
                Name          = 'plan-storage'
                Path          = $script:PlanStorage
                LegacyPattern = '(?is)Issue-Planner \(opt-in\)|opt-in "Yes" at plan creation|Providing an opt-in GitHub issue comment'
            },
            @{
                Name          = 'hub-mode-ux'
                Path          = $script:HubModeUx
                LegacyPattern = '(?is)Issue-Planner creates a single bundled plan named .* posted as a GitHub issue comment to each bundled issue'
            }
        )
    }

    It 'requires Issue-Planner to stop prompting for immediate GitHub persistence' {
        $content = & $script:ReadContent -Path $script:IssuePlanner

        $content | Should -Match $script:CanonicalPlanPathPattern -Because 'Issue-Planner must still persist the plan to the canonical session-memory path'
        $content | Should -Match $script:CanonicalDesignPathPattern -Because 'Issue-Planner must still create the design cache at the canonical session-memory path'
        $content | Should -Not -Match 'Persist this plan as a GitHub issue comment\?' -Because 'durable persistence must no longer be prompted during planning'
        $content | Should -Not -Match '(?is)Post the plan as a GitHub issue comment using the MCP `mcp_github_add_issue_comment` tool' -Because 'Issue-Planner must no longer own durable plan comment writes'
        $content | Should -Not -Match '(?is)Then post a second GitHub issue comment using `mcp_github_add_issue_comment`' -Because 'Issue-Planner must no longer own durable design snapshot writes'
        $content | Should -Not -Match '(?is)Single "Yes" creates both comments' -Because 'planner-time durable handoff persistence must be removed entirely'
    }

    It 'requires Code-Conductor D9 to own durable handoff persistence while preserving lookup semantics' {
        $content = & $script:ReadContent -Path $script:CodeConductor

        $content | Should -Match $script:ContinueSessionMemoryPattern -Because 'Continue implementation at D9 must remain session-memory-only'
        $content | Should -Match $script:PausePersistsBothMarkersPattern -Because 'the pause path must persist both durable handoff artifacts at D9'
        $content | Should -Match $script:PauseNormalizesTransportFormattingDriftPattern -Because 'the pause path must normalize transport-only formatting drift before deciding a durable handoff artifact changed'
        $content | Should -Match $script:D9SuppressionRequiresTierDurabilityPattern -Because 'D9 suppression must require the selected tier''s durable handoff comments, not just upstream phase markers'
        $content | Should -Match $script:BundleD9SuppressionPattern -Because 'bundle D9 suppression must require per-issue durable handoff comments for every bundled issue'
        $content | Should -Match $script:LatestCommentWinsPattern -Because 'latest-comment-wins lookup must remain valid for persisted handoff comments'
        $content | Should -Match 'plan-bundle-\{primary\}-\{secondary1\}-\{secondaryN\}' -Because 'bundle plan naming must remain unchanged'
    }

    It 'requires shared docs to route cross-session durability through D9 instead of planner-time comment posting' {
        foreach ($doc in $script:SharedDocContracts) {
            $content = & $script:ReadContent -Path $doc.Path

            & $script:AssertSharedDocContract -Content $content -Name $doc.Name -LegacyPattern $doc.LegacyPattern
        }
    }

    It 'preserves unconditional design issue-body persistence and canonical marker names' {
        $copilotInstructions = & $script:ReadContent -Path $script:CopilotInstructions
        $issuePlanner = & $script:ReadContent -Path $script:IssuePlanner
        $planStorage = & $script:ReadContent -Path $script:PlanStorage
        $codeConductor = & $script:ReadContent -Path $script:CodeConductor

        $copilotInstructions | Should -Match '(?is)Design content goes in the GitHub issue body \(Solution-Designer outputs there\)' -Because 'Solution-Designer issue-body persistence must remain unconditional'
        $issuePlanner | Should -Match $script:CanonicalPlanPathPattern -Because 'the canonical plan marker name must remain plan-issue'
        $issuePlanner | Should -Match $script:CanonicalDesignPathPattern -Because 'the canonical design marker name must remain design-issue'
        $planStorage | Should -Match '<!-- plan-issue-\{ID\} -->' -Because 'the durable plan comment marker must remain canonical'
        $planStorage | Should -Match '<!-- design-issue-\{ID\} -->' -Because 'the durable design comment marker must remain canonical'
        $codeConductor | Should -Match $script:LatestCommentWinsPattern -Because 'the lookup contract must keep latest-comment-wins semantics'
    }

    It 'requires the four pipeline-entry agents to describe the first-contact provenance gate trigger' {
        $script:PipelineEntryAgents.Count | Should -Be 4 -Because 'the provenance trigger contract is owned by exactly the four pipeline-entry agents'

        foreach ($agent in $script:PipelineEntryAgents) {
            $content = & $script:ReadContent -Path $agent.Path
            $processSectionMatch = [regex]::Match($content, '(?ms)^## Process\s*\r?\n(?<body>.*?)(?=^## |\z)')

            $processSectionMatch.Success | Should -BeTrue -Because "$($agent.Name) must keep a bounded Process section for pre-response trigger handling"

            $processSection = $processSectionMatch.Groups['body'].Value

            $processSection | Should -Match ([regex]::Escape('When this user-invocable agent receives a request referencing an existing GitHub issue, load the `provenance-gate` skill and follow its protocol.')) -Because "$($agent.Name) must reference the provenance-gate skill from its Process section"
            $processSection | Should -Match $script:ProvenanceGateMarkerPattern -Because "$($agent.Name) must reference the first-contact-assessed marker for the provenance gate trigger"
            $processSection | Should -Match '(?is)(any option except|except).{0,60}Needs rework' -Because "$($agent.Name) must describe conditional marker posting (skip on Needs rework)"
            $processSection | Should -Match '(?is)(MCP tools are unavailable|API call fails).{0,80}fail open' -Because "$($agent.Name) must describe fail-open semantics when MCP tools are unavailable"
        }
    }

    It 'requires provenance-gate skill file to exist and use the same marker pattern' {
        $skillPath = Join-Path $PSScriptRoot '../../skills/provenance-gate/SKILL.md'

        Test-Path $skillPath | Should -BeTrue -Because 'provenance-gate/SKILL.md must exist as the full assessment protocol'
        $skillContent = Get-Content -Path $skillPath -Raw
        $skillContent | Should -Not -BeNullOrEmpty -Because 'provenance-gate/SKILL.md must have content'
        $skillContent | Should -Match $script:ProvenanceGateMarkerPattern -Because 'provenance-gate/SKILL.md must reference the same first-contact-assessed marker as copilot-instructions'
    }
}
