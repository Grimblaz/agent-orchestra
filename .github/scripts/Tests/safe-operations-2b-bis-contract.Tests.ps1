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

    It '§2b-ter lever-mapping table documents priority label and parent-edge mechanisms' {
        $script:Content | Should -Match '(?is)2b-ter.{0,800}Add-FollowUpIssue' `
            -Because '§2b-ter must document Add-FollowUpIssue as the parent-edge mechanism in the lever-mapping table'
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
