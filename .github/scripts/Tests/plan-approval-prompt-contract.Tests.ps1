#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Contract tests for approval-prompt decision-card wording.

.DESCRIPTION
    Locks the issue #187 plan-approval prompt contract across:
      - agents/Issue-Planner.agent.md
      - Documents/Design/hub-mode-ux.md

        The files must describe the same semantics for:
            - a decision-card-first approval prompt with mandatory fields `Change`, `No change`, `Trade-off`, and `Areas`
            - a conditional `Execution` digest that appears only when execution shape materially affects approval
            - no transcript dependency for informed approval
            - grouped-area fallback behavior instead of noisy file dumps
            - clarify-before-approval behavior when `Change` or `No change` cannot be stated concretely

        These tests intentionally avoid brittle exact-sentence locks and do not cover VS Code rendering behavior or D9 persistence behavior.
        They are RED coverage for issue #187 until Issue-Planner and the committed hub-mode UX design are aligned.
#>

Describe 'plan approval prompt contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:IssuePlanner = Join-Path $script:RepoRoot 'agents\Issue-Planner.agent.md'
        $script:HubModeUx = Join-Path $script:RepoRoot 'Documents\Design\hub-mode-ux.md'

        $script:ReadContent = {
            param([string]$Path)

            return Get-Content -Path $Path -Raw
        }

        $script:MandatoryDecisionCardPattern = '(?is)(decision card|approval card|approval prompt|approval surface).{0,420}(mandatory|required|always present|first four fields are mandatory).{0,260}Change.{0,180}No change.{0,180}Trade-off.{0,180}Areas'
        $script:ConditionalExecutionDigestPattern = '(?is)Execution.{0,220}(conditional|optional|only when needed|only when present|appears only when|omitted otherwise).{0,420}(more than three steps|plan has more than three steps|parallel (?:execution )?lanes|parallelism|sequencing(?: itself)? is likely to change the approval decision|plan shape materially affects approval(?: risk| safety)?)'
        $script:NoTranscriptDependencyPattern = '(?is)(approval (?:dialog|prompt|surface)|dialog|prompt).{0,260}(stand on its own|self-sufficient|from the dialog alone|without rereading the transcript|without back-scrolling|without scrolling back|no transcript dependency|without depending on (?:the )?(?:transcript|conversation history))'
        $script:NoChangeBoundaryFallbackPattern = '(?is)((No change).{0,260}(derive|derived|deriving|infer|inferred)|(derive|derived|deriving|infer|inferred).{0,160}(No change)).{0,260}(plan(?:''s)? boundary|approved plan boundary|scope boundary|non-goals?|unaffected surfaces?)'
        $script:GroupedAreasFallbackPattern = '(?is)(Areas|affected files|workflow areas|touched files).{0,260}(group(?:ed|ing)|collapse to grouped areas|grouped workflow areas|area-level summaries).{0,260}(instead of|over|rather than|when).{0,220}(noisy|exhaustive|raw|file dump|file dumps|file enumeration|exact files are noisy)'
        $script:ClarifyBeforeApprovalPattern = '(?is)(Change|No change).{0,260}(cannot|can''t|still cannot|if .* cannot).{0,220}(state|describe).{0,120}(concretely|meaningfully|with meaningful specificity).{0,260}(clarify|ask for clarification|stop and clarify).{0,180}(before approval|before asking for approval)'
        $script:LegacyApprovalHeuristicPattern = '(?is)(step count.{0,200}1-line(?:-| )per-step summaries?.{0,200}top-3 risks|top-3 risks.{0,200}step count.{0,200}1-line(?:-| )per-step summaries?)'

        $script:SharedContractPatterns = @(
            @{
                Name    = 'mandatory decision-card fields'
                Pattern = $script:MandatoryDecisionCardPattern
            },
            @{
                Name    = 'conditional execution digest trigger'
                Pattern = $script:ConditionalExecutionDigestPattern
            },
            @{
                Name    = 'no-transcript-dependency rule'
                Pattern = $script:NoTranscriptDependencyPattern
            },
            @{
                Name    = 'No change boundary/non-goal fallback rule'
                Pattern = $script:NoChangeBoundaryFallbackPattern
            },
            @{
                Name    = 'grouped-area fallback rule'
                Pattern = $script:GroupedAreasFallbackPattern
            },
            @{
                Name    = 'clarify-before-approval rule'
                Pattern = $script:ClarifyBeforeApprovalPattern
            }
        )
    }

    It 'requires Issue-Planner to replace the legacy step-count approval heuristic with a decision-card-first approval contract' {
        $content = & $script:ReadContent -Path $script:IssuePlanner

        $content | Should -Match $script:MandatoryDecisionCardPattern -Because 'Issue-Planner must require the approval prompt to expose Change, No change, Trade-off, and Areas as the decision card'
        $content | Should -Match $script:ConditionalExecutionDigestPattern -Because 'Issue-Planner must make Execution conditional on approval-relevant execution shape rather than always dumping plan structure'
        $content | Should -Match $script:NoTranscriptDependencyPattern -Because 'Issue-Planner must require informed approval from the prompt itself rather than from transcript archaeology'
        $content | Should -Match $script:NoChangeBoundaryFallbackPattern -Because 'Issue-Planner must allow No change to be derived from plan boundaries, non-goals, or unaffected surfaces when exclusions are implicit'
        $content | Should -Match $script:GroupedAreasFallbackPattern -Because 'Issue-Planner must prefer grouped areas when exact file lists become noisy'
        $content | Should -Match $script:ClarifyBeforeApprovalPattern -Because 'Issue-Planner must require clarification before approval if Change or No change cannot be stated concretely'
        $content | Should -Not -Match $script:LegacyApprovalHeuristicPattern -Because 'Issue-Planner must stop describing plan approval as step-count plus top-three-risk enrichment'
    }

    It 'requires the committed hub-mode UX design to stay aligned with the approval decision-card contract' {
        $content = & $script:ReadContent -Path $script:HubModeUx

        foreach ($check in $script:SharedContractPatterns) {
            $content | Should -Match $check.Pattern -Because "hub-mode-ux must include the $($check.Name) wording for the issue #187 approval prompt contract"
        }

        $content | Should -Not -Match $script:LegacyApprovalHeuristicPattern -Because 'hub-mode-ux must stop describing plan approval as step-count plus top-three-risk enrichment'
    }

    It 'requires Issue-Planner and hub-mode-ux to carry the same shared approval semantics' {
        $docs = @(
            @{ Name = 'Issue-Planner'; Path = $script:IssuePlanner },
            @{ Name = 'hub-mode-ux'; Path = $script:HubModeUx }
        )

        foreach ($doc in $docs) {
            $content = & $script:ReadContent -Path $doc.Path

            foreach ($check in $script:SharedContractPatterns) {
                $content | Should -Match $check.Pattern -Because "$($doc.Name) must include the $($check.Name) wording so the approval prompt contract stays synchronized across the agent and design doc"
            }
        }
    }
}