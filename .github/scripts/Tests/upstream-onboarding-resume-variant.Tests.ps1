#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Contract tests for upstream-onboarding resume-variant inline orientation snapshots.

.DESCRIPTION
    Locks the issue #633 contract in:
      - skills/upstream-onboarding/SKILL.md
      - agents/Code-Conductor.agent.md

    These tests lock the landed resume-variant snapshot wording for issue #633 going forward.
#>

Describe 'upstream onboarding resume variant' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:SkillFile = Join-Path $script:RepoRoot 'skills\upstream-onboarding\SKILL.md'
        $script:ConductorFile = Join-Path $script:RepoRoot 'agents\Code-Conductor.agent.md'

        $script:SkillContent = Get-Content -Path $script:SkillFile -Raw
        $script:ConductorContent = Get-Content -Path $script:ConductorFile -Raw
    }

    It 'requires ### Resume Variant section to exist under ## The Brief in SKILL.md' {
        $script:SkillContent | Should -Match '(?si)### Resume Variant' -Because 'issue #633 requires a ### Resume Variant heading under ## The Brief'
    }

    It 'carves out the resume snapshot from same-agent-resume skip sites in SKILL.md' {
        # Check that we distinguish skip brief + standards check from rendering the snapshot
        $script:SkillContent | Should -Match '(?i)distinguish: the brief and the non-overridable standards check still skip on same-agent resume, but the resume-variant orientation snapshot now renders' -Because 'issue #633 requires carving out same-agent-resume skip sites to allow rendering the snapshot'
        $script:SkillContent | Should -Match '(?i)skip the brief and standards check \(same-agent resume\), but render the \*\*resume-variant orientation snapshot\*\*' -Because 'issue #633 requires updating Marker-Boundary Trigger rule 3'
    }

    It 'defines the field-to-artifact mapping and missing-record fallback' {
        $script:SkillContent | Should -Match '(?i)current phase.*phase marker' -Because 'current phase must map to latest phase marker'
        $script:SkillContent | Should -Match '(?i)last decision.*engagement-record' -Because 'last decision must map to most recent engagement-record decisions'
        $script:SkillContent | Should -Match '(?i)next step.*pipeline position' -Because 'next step must map to pipeline position'
        $script:SkillContent | Should -Match '(?i)last decision: not recorded' -Because 'missing-record fallback must render last decision: not recorded'
    }

    It 'declares on-demand expand and affordance-hint predicate' {
        $script:SkillContent | Should -Match '(?i)on-demand expand' -Because 'on-demand expand must be declared'
        $script:SkillContent | Should -Match '(?i)affordance-hint predicate' -Because 'affordance-hint predicate must be declared'
    }

    It 'declares that standards-check is NOT re-fired on same-agent resume' {
        $script:SkillContent | Should -Match '(?si)Surfacing.{0,20}this snapshot.{0,200}without re-firing' -Because 'issue #633 requires that the standards-check protocol is not re-fired'
    }

    It 'references user-invocable resume entries and subagent self-skip' {
        $script:SkillContent | Should -Match '(?si)user-invocable.{0,20}resume entries' -Because 'onboarding snapshot fires only at user-invocable entries'
    }

    It 'requires Code-Conductor smart-resume to declare the snapshot render in Code-Conductor.agent.md' {
        $script:ConductorContent | Should -Match '(?i)smart-resume' -Because 'smart-resume section must exist'
        $script:ConductorContent | Should -Match '(?i)independently assemble and render the \*\*resume-variant orientation snapshot\*\* inline' -Because 'Code-Conductor must independently render the snapshot'
        $script:ConductorContent | Should -Match '(?i)last decision: not recorded' -Because 'Code-Conductor snapshot must specify the last decision fallback'
    }
}
