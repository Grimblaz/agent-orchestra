#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Contract tests for safe-operations §2b-bis label-independent Triage derivation
    invariant and §2b-ter creation-time board-positioning residue.

.DESCRIPTION
    Locks the invariant introduced by issue #774:
      - §2b-bis: ungrouped open issues auto-derive into Triage under Control Tower v2
        regardless of label (label is no longer load-bearing for Triage placement).
      - §2b-bis additive caveat: Triage is capped at 5 issues, sorted priority-first
        (Get-PriorityKey order), so an unlabeled issue may fall below the fold.
      - §2b-ter: agents must make a deliberate creation-time positioning decision and
        record a positioning residue note in the issue body.

    These tests ensure future edits do not silently drop the label-independence
    invariant or the cap/ranking caveat, and that the positioning residue format
    string remains unambiguously specified.
#>

Describe 'safe-operations §2b-bis / §2b-ter board-positioning contract' -Tag 'contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:SafeOps = Join-Path $script:RepoRoot 'skills/safe-operations/SKILL.md'
        $script:Content = Get-Content -Path $script:SafeOps -Raw -ErrorAction Stop
    }

    It '§2b-bis states label is no longer load-bearing for Triage placement under v2' {
        $script:Content | Should -Match 'no longer load-bearing.{0,5}for Triage placement' `
            -Because '§2b-bis must assert the triage-label invariant change: label is optional/advisory only under v2'
    }

    It '§2b-bis caveat documents the Triage cap-5 and priority-first ranking' {
        $script:Content | Should -Match 'Triage is capped at 5' `
            -Because 'the §2b-bis caveat must note the Triage bucket hard cap of 5 issues'

        $script:Content | Should -Match 'Get-PriorityKey' `
            -Because 'the caveat must reference Get-PriorityKey so agents can predict priority-ranking within Triage'
    }

    It '§2b-ter defines the positioning-residue format string' {
        $script:Content | Should -Match 'Board positioning: priority=' `
            -Because '§2b-ter must define the positioning residue format to allow auditability'

        $script:Content | Should -Match 'placement=standalone\|parent #N' `
            -Because '§2b-ter residue format must name both standalone and parent-edge placement options'
    }

    It '§2b-ter lever-mapping table Parent-edge row documents Set-IssueParent as the attach-existing mechanism (#800 A2 / PF7)' {
        # Tightened per #800 s4 (PF7, judge ruling: sustained/medium). The prior assertion
        # was '(?is)2b-ter.{0,800}Add-FollowUpIssue' — a loose proximity match that is
        # satisfied by ANY Add-FollowUpIssue mention within 800 chars of the "2b-ter"
        # heading, including unrelated prose at §2b-ter:144/:148/:169 (create-then-attach
        # guidance, the automated-path carve-out). That loose match would keep passing
        # even after #800 s5 rewrites the lever-mapping table's Parent-edge row to name
        # Set-IssueParent (the new standalone attach-existing script from #800 A2) —
        # silently certifying a now-false "Add-FollowUpIssue is the parent-edge mechanism"
        # claim. This assertion targets the "Parent edge" table row specifically by its
        # literal leading cell text and requires the Mechanism cell to name
        # Set-IssueParent, not Add-FollowUpIssue.
        #
        # STATUS: #800 s5 (the doc-fix step that rewrote this row) has landed and this
        # suite is GREEN. Kept as a standing regression guard against reverting the
        # Parent-edge row back to Add-FollowUpIssue.
        $script:Content | Should -Match '(?m)^\|\s*\*\*Parent edge\*\*\s*\(`Set-IssueParent -ParentIssueNumber N`\)' `
            -Because '§2b-ter lever-mapping table Parent-edge row must name Set-IssueParent as the attach-existing mechanism (#800 A2)'

        $script:Content | Should -Not -Match '(?m)^\|\s*\*\*Parent edge\*\*.*Add-FollowUpIssue' `
            -Because 'the Parent-edge row must not still reference Add-FollowUpIssue once #800 s5 lands (regression guard against reverting to the stale mechanism)'
    }

    It '§2b-ter lever table pins correct Get-PriorityKey numeric values matching render-portfolio.ps1' {
        $script:Content | Should -Match 'Get-PriorityKey.*= 0 \(high\), 1 \(medium\), or 2 \(low\)' `
            -Because '§2b-ter table must document correct rank values (0=high, 1=medium, 2=low), matching render-portfolio.ps1:47-49; no-label stays 3'
    }

    It '§2b pinned heading is preserved (required by downstream-ownership-boundary-contract)' {
        $script:Content | Should -Match '### 2b\. Priority Label Requirement' `
            -Because 'downstream-ownership-boundary-contract.Tests.ps1 pins this exact heading literal'
    }
}
