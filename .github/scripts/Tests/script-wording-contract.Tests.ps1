#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Contract tests for cleanup-script wording consistency.

.DESCRIPTION
    Asserts that the cleanup scripts contain the correct wording strings, scoped to
    specific function bodies. This prevents silent regression of the wording variants
    introduced in issue #548 (squash-merge orphan auto-delete).

    Scoped assertions:
      - Get-OrphanBranchLines (detector-core): per-line auto-resolve suffix
      - Remove-OrphanBranch (post-merge-cleanup): refined skip variants, no legacy wording
      - Remove-SiblingWorktree (post-merge-cleanup): legacy 'unmerged commits' preserved (out-of-scope carve-out)
#>

Describe 'cleanup script wording contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:DetectorCore = Get-Content (Join-Path $script:RepoRoot 'skills\session-startup\scripts\session-cleanup-detector-core.ps1') -Raw
        $script:PostMergeCleanup = Get-Content (Join-Path $script:RepoRoot 'skills\session-startup\scripts\post-merge-cleanup.ps1') -Raw

        # Extract Remove-OrphanBranch function body (from "function Remove-OrphanBranch" to the next "^function ")
        # This scopes assertions to avoid false matches from Remove-SiblingWorktree
        $script:RemoveOrphanBranchBody = ''
        $match = [regex]::Match($script:PostMergeCleanup, '(?ms)^function Remove-OrphanBranch\b.*?(?=^function |\z)')
        if ($match.Success) {
            $script:RemoveOrphanBranchBody = $match.Value
        }

        # Extract Remove-SiblingWorktree function body (from "function Remove-SiblingWorktree" to the next "^function " or end)
        $script:RemoveSiblingWorktreeBody = ''
        $match3 = [regex]::Match($script:PostMergeCleanup, '(?ms)^function Remove-SiblingWorktree\b.*?(?=^function |\z)')
        if ($match3.Success) {
            $script:RemoveSiblingWorktreeBody = $match3.Value
        }

        # Extract Get-OrphanBranchLines function body
        # The function lives at module scope (no leading indentation)
        $script:GetOrphanBranchLinesBody = ''
        $match2 = [regex]::Match($script:DetectorCore, '(?ms)^function Get-SCDOrphanBranchLines\b.*?(?=^function |\z)')
        if ($match2.Success) {
            $script:GetOrphanBranchLinesBody = $match2.Value
        }
    }

    It "Get-OrphanBranchLines contains the '; eligible for auto-resolve at cleanup time' suffix" {
        $script:GetOrphanBranchLinesBody | Should -Match ([regex]::Escape('; eligible for auto-resolve at cleanup time')) `
            -Because "Get-OrphanBranchLines must append the auto-resolve suffix for feature/issue-N orphan branches"
    }

    It "Remove-OrphanBranch contains 'auto-resolve declined' skip variant" {
        $script:RemoveOrphanBranchBody | Should -Match ([regex]::Escape('auto-resolve declined')) `
            -Because "Remove-OrphanBranch must emit the 'auto-resolve declined' skip variant when Test-OrphanBranchAutoResolveEligible returns false"
    }

    It "Remove-OrphanBranch contains 'could not verify GitHub signals' skip variant" {
        $script:RemoveOrphanBranchBody | Should -Match ([regex]::Escape('could not verify GitHub signals')) `
            -Because "Remove-OrphanBranch must emit the 'could not verify GitHub signals' skip variant when Test-OrphanBranchAutoResolveEligible returns null"
    }

    It "Remove-OrphanBranch contains 'became unmerged between re-check and force-delete' race-condition variant" {
        $script:RemoveOrphanBranchBody | Should -Match ([regex]::Escape('became unmerged between re-check and force-delete')) `
            -Because "Remove-OrphanBranch must emit the race-condition skip variant when the branch becomes unmerged between re-check and force-delete"
    }

    It "Remove-OrphanBranch body does not contain the legacy 'unmerged commits' wording" {
        $script:RemoveOrphanBranchBody | Should -Not -Match 'unmerged commits' `
            -Because "The legacy 'unmerged commits' wording was replaced in issue #548; Remove-OrphanBranch must not use it"
    }

    It "Remove-SiblingWorktree retains legacy 'unmerged commits' wording (out-of-scope carve-out)" {
        $script:RemoveSiblingWorktreeBody | Should -Match 'unmerged commits' `
            -Because "Remove-SiblingWorktree is out-of-scope for #548 and must still use the legacy 'unmerged commits' wording as a regression guard"
    }
}
