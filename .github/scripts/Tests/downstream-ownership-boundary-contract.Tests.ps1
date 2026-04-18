#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Contract tests for Code-Conductor downstream ownership boundary wording.

.DESCRIPTION
    Locks the issue #196 downstream ownership contract across:
      - .github/agents/Code-Conductor.agent.md
      - Documents/Design/hub-mode-ux.md
    - .github/skills/safe-operations/SKILL.md
      - .github/agents/Process-Review.agent.md

        The files must describe the same semantics for:
            - exactly three work classes for downstream orchestration scope
            - a pre-edit ownership gate before any editing delegation or file mutation
            - a mid-run fail-closed stop when upstream mutation needs are discovered later
            - the visible stop text `requires upstream issue`
            - reuse of safe-operations for dedup/priority/output-capture rules
            - distinctness from Process-Review's gotcha-specific `upstream-gotcha` flow
            - repository-aware bypass when the active issue belongs to the shared workflow repo itself
            - pre-existing upstream dirty state as external context, not permission

        D9 durability ownership remains intentionally out of scope for this file and is locked by
        handoff-persistence-contract.Tests.ps1.

        These tests lock the landed issue #196 wording so future edits do not drift from the ownership-boundary contract.
#>

Describe 'downstream ownership boundary contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:CodeConductor = Join-Path $script:RepoRoot '.github/agents/Code-Conductor.agent.md'
        $script:HubModeUx = Join-Path $script:RepoRoot 'Documents/Design/hub-mode-ux.md'
        $script:SafeOperations = Join-Path $script:RepoRoot '.github/skills/safe-operations/SKILL.md'
        $script:ProcessReview = Join-Path $script:RepoRoot '.github/agents/Process-Review.agent.md'

        $script:ReadContent = {
            param([string]$Path)

            return Get-Content -Path $Path -Raw
        }

        $script:OwnershipWorkClassesPattern = '(?is)(distinguish(?:es)?|classif(?:y|ies)).{0,240}(three classes|exactly these work classes).{0,240}downstream-owned work.{0,200}shared read-only guidance.{0,200}upstream shared-workflow mutation'
        $script:PreEditGatePattern = '(?is)(pre-edit ownership gate|ownership gate).{0,240}before any editing delegation or file mutation'
        $script:PreEditVisibleStopTextPattern = '(?is)(before any editing delegation or file mutation|pre-edit ownership gate).{0,240}requires upstream issue.{0,220}(instead of starting mixed-repo implementation|instead of beginning mixed-repo edits|fail closed immediately)'
        $script:MidRunFailClosedPattern = '(?is)(mid-run|after work has started|discovered after work has started|new scope is discovered).{0,260}(fail-closed|stops at discovery time|stop at discovery time|does not widen scope).{0,220}(before any new mutation delegation|before new mutation delegation|avoids converting the downstream task into mixed-repo work)'
        $script:MidRunVisibleStopTextPattern = '(?is)(after work has started|new scope is discovered).{0,260}(requires upstream issue|emit(?:s)? `?requires upstream issue`?).{0,220}before any new mutation delegation'
        $script:RoutingReusePattern = '(?is)(reuse(?:s)? the existing upstream-routing conventions|reuse existing upstream routing|reuses the existing upstream-routing path).{0,260}(if an upstream issue already exists, link (?:to )?it and stop|link the existing upstream issue when present).{0,320}(when the upstream repo can be resolved and upstream access is available|when the upstream repo is resolvable and accessible).{0,320}(safe-operations).{0,220}(dedup(?: search|-first)?).{0,220}(priority(?:-labeled| label)?).{0,220}(output capture)'
        $script:ProcessGapFallbackPattern = '(?is)if the upstream repo cannot be resolved or upstream access is unavailable.{0,260}(local fallback artifact labeled `?process-gap-upstream`?|local .*process-gap-upstream).{0,260}(manual upstream handoff path|explicit manual upstream handoff path)'
        $script:DistinctGotchaFlowPattern = '(?is)(process-gap-upstream).{0,220}(distinct from|separate from).{0,220}(Process-Review''s gotcha-specific|gotcha-specific).{0,120}`?upstream-gotcha`?'
        $script:SafeOperationsDedupPattern = '(?is)Deduplication Check.{0,260}Before every `gh issue create`, search for existing open issues'
        $script:SafeOperationsPriorityLabelPattern = '(?is)Priority Label Requirement.{0,260}Every `gh issue create` command run by any agent.{0,120}(?:\*\*)?MUST(?:\*\*)? include a `--label` flag specifying a priority'
        $script:SafeOperationsOutputCapturePattern = '(?is)Output capture.{0,260}capture the returned issue URL.{0,260}Do not re-run'
        $script:ProcessReviewGotchaFallbackPattern = '(?is)gh access to \{copilot-orchestra-repo\} failed.{0,220}fall back to creating a local GitHub issue labeled `upstream-gotcha` and `priority: medium`'
        $script:RepositoryAwareBypassPattern = '(?is)(repository-aware|shared(?:-| )workflow repo itself|active issue itself belongs to the shared(?:-| )workflow repo).{0,260}(valid in-scope|normal in-scope work|shared-agent edits remain normal in-scope work)'
        $script:DirtyUpstreamStatePattern = '(?is)(pre-existing upstream dirty state|pre-existing upstream edits|upstream edits are already present in the local clone).{0,240}(external state|not permission|does not grant permission)'

        $script:SharedContractPatterns = @(
            @{
                Name    = 'work-class triad'
                Pattern = $script:OwnershipWorkClassesPattern
            },
            @{
                Name    = 'pre-edit gate'
                Pattern = $script:PreEditGatePattern
            },
            @{
                Name    = 'mid-run fail-closed stop'
                Pattern = $script:MidRunFailClosedPattern
            },
            @{
                Name    = 'pre-edit visible stop text'
                Pattern = $script:PreEditVisibleStopTextPattern
            },
            @{
                Name    = 'mid-run visible stop text'
                Pattern = $script:MidRunVisibleStopTextPattern
            },
            @{
                Name    = 'routing reuse guarantee'
                Pattern = $script:RoutingReusePattern
            },
            @{
                Name    = 'process-gap-upstream fallback'
                Pattern = $script:ProcessGapFallbackPattern
            },
            @{
                Name    = 'distinct gotcha flow'
                Pattern = $script:DistinctGotchaFlowPattern
            },
            @{
                Name    = 'repository-aware bypass'
                Pattern = $script:RepositoryAwareBypassPattern
            },
            @{
                Name    = 'dirty upstream state is not permission'
                Pattern = $script:DirtyUpstreamStatePattern
            }
        )
    }

    It 'requires Code-Conductor to distinguish exactly the allowed downstream ownership work classes' {
        $content = & $script:ReadContent -Path $script:CodeConductor

        $content | Should -Match $script:OwnershipWorkClassesPattern -Because 'Code-Conductor must classify downstream orchestration work using the exact three ownership classes from issue #196'
    }

    It 'requires the pre-edit ownership gate to fire before any editing delegation or file mutation' {
        $content = & $script:ReadContent -Path $script:CodeConductor

        $content | Should -Match $script:PreEditGatePattern -Because 'Code-Conductor must block upstream mutation scope before any edit delegation or file mutation begins'
    }

    It 'requires mid-run discovery of upstream mutation work to fail closed before new mutation delegation' {
        $content = & $script:ReadContent -Path $script:CodeConductor

        $content | Should -Match $script:MidRunFailClosedPattern -Because 'late discovery of upstream shared-workflow mutation must stop the run before new mutation work is delegated'
    }

    It 'requires the stop path to reuse the upstream issue-routing contract instead of collapsing into the gotcha flow' {
        $content = & $script:ReadContent -Path $script:CodeConductor

        $content | Should -Match $script:RoutingReusePattern -Because 'the downstream ownership stop path must link existing upstream issues and reuse the safe-operations-governed creation path when upstream access is available'
        $content | Should -Match $script:ProcessGapFallbackPattern -Because 'the downstream ownership stop path must fall back to local process-gap-upstream handoff only when both canonical fallback triggers are expressed together: upstream repo cannot be resolved or upstream access is unavailable'
        $content | Should -Match $script:DistinctGotchaFlowPattern -Because 'the downstream ownership fallback must remain distinct from Process-Review''s gotcha-specific upstream-gotcha flow'
    }

    It 'requires the visible stop outcome text requires upstream issue for both pre-edit and mid-run stop paths' {
        $content = & $script:ReadContent -Path $script:CodeConductor

        $content | Should -Match $script:PreEditVisibleStopTextPattern -Because 'the pre-edit stop path must visibly state requires upstream issue before implementation begins'
        $content | Should -Match $script:MidRunVisibleStopTextPattern -Because 'the mid-run stop path must visibly state requires upstream issue before any new mutation delegation'
    }

    It 'requires the reused upstream-routing sources to define the safe-operations and upstream-gotcha rules directly' {
        $safeOperations = & $script:ReadContent -Path $script:SafeOperations
        $processReview = & $script:ReadContent -Path $script:ProcessReview

        $safeOperations | Should -Match $script:SafeOperationsDedupPattern -Because 'safe-operations is the authoritative source for dedup-before-create rules reused by the ownership-boundary stop path'
        $safeOperations | Should -Match $script:SafeOperationsPriorityLabelPattern -Because 'safe-operations is the authoritative source for priority-label requirements reused by the ownership-boundary stop path'
        $safeOperations | Should -Match $script:SafeOperationsOutputCapturePattern -Because 'safe-operations is the authoritative source for output-capture rules reused by the ownership-boundary stop path'
        $processReview | Should -Match $script:ProcessReviewGotchaFallbackPattern -Because 'Process-Review is the authoritative source for the gotcha-specific upstream-gotcha fallback that must remain distinct from process-gap-upstream'
    }

    It 'requires a repository-aware bypass when the active issue belongs to the shared workflow repo itself' {
        $content = & $script:ReadContent -Path $script:CodeConductor

        $content | Should -Match $script:RepositoryAwareBypassPattern -Because 'shared workflow maintenance must remain in scope when the active issue is owned by the shared workflow repo itself'
    }

    It 'requires pre-existing upstream dirty state to remain external context rather than permission to continue cross-repo edits' {
        $content = & $script:ReadContent -Path $script:CodeConductor

        $content | Should -Match $script:DirtyUpstreamStatePattern -Because 'existing upstream dirty state must not authorize new cross-repo mutation during downstream orchestration'
    }

    It 'requires the committed hub-mode design doc to stay in sync with the ownership boundary wording' {
        $docs = @(
            @{ Name = 'Code-Conductor'; Path = $script:CodeConductor },
            @{ Name = 'hub-mode-ux'; Path = $script:HubModeUx }
        )

        foreach ($doc in $docs) {
            $content = & $script:ReadContent -Path $doc.Path

            foreach ($check in $script:SharedContractPatterns) {
                $content | Should -Match $check.Pattern -Because "$($doc.Name) must include the $($check.Name) wording for the issue #196 ownership boundary contract"
            }
        }
    }
}
