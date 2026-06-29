#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Structural tests for the design grounding discipline shipped in issue #763.

.DESCRIPTION
    Locks the four-quadrant pre-challenge trace gate contract across:
      - skills/design-exploration/SKILL.md   (section presence)
      - agents/Solution-Designer.agent.md    (gate ordering between Stage 2 and Stage 3)
      - skills/upstream-onboarding/SKILL.md  (Issue-Planner-lens backstop row)
#>

Describe 'design grounding discipline' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:SkillFile   = Join-Path $script:RepoRoot 'skills/design-exploration/SKILL.md'
        $script:AgentFile   = Join-Path $script:RepoRoot 'agents/Solution-Designer.agent.md'
        $script:OnboardFile = Join-Path $script:RepoRoot 'skills/upstream-onboarding/SKILL.md'

        $script:SkillContent   = Get-Content -Path $script:SkillFile   -Raw
        $script:AgentContent   = Get-Content -Path $script:AgentFile   -Raw
        $script:OnboardContent = Get-Content -Path $script:OnboardFile -Raw
    }

    # --- Group 1: Presence in design-exploration/SKILL.md ---

    It 'has a ## Grounding Discipline heading in design-exploration/SKILL.md' {
        $script:SkillContent | Should -Match '(?si)## Grounding Discipline' `
            -Because 'issue #763 s1 adds the Grounding Discipline section to design-exploration'
    }

    It 'defines Q1 output-to-consumer quadrant' {
        $script:SkillContent | Should -Match '(?si)Q1.*Output.*consumer' `
            -Because 'issue #763 requires four overlapping-lens quadrants; Q1 is output-to-consumer'
    }

    It 'defines Q2 input-to-exec-env quadrant' {
        $script:SkillContent | Should -Match '(?si)Q2.*Input.*exec-env' `
            -Because 'issue #763 requires four overlapping-lens quadrants; Q2 is input-to-exec-env'
    }

    It 'defines Q3 current-behavior quadrant' {
        $script:SkillContent | Should -Match '(?si)Q3.*Current behavior' `
            -Because 'issue #763 requires four overlapping-lens quadrants; Q3 is current-behavior/structure'
    }

    It 'defines Q4 cross-cutting-premise quadrant' {
        $script:SkillContent | Should -Match '(?si)Q4.*Cross-cutting premise' `
            -Because 'issue #763 requires four overlapping-lens quadrants; Q4 is cross-cutting premise'
    }

    It 'declares the full disposition enum including grounded-conflict' {
        $script:SkillContent | Should -Match '(?si)grounded \| grounded-conflict \| could-not-ground-escalate \| n/a' `
            -Because 'issue #763 D4 adds grounded-conflict to represent grounding that falsifies a design premise'
    }

    It 'requires path:line citation and stated inference (anti-rubber-stamp)' {
        $script:SkillContent | Should -Match '(?si)path:line.{0,50}inference|inference.{0,50}path:line' `
            -Because 'issue #763 M4 requires path:line AND stated inference to prevent rubber-stamp citations'
    }

    It 'names the Grounding Evidence durable block' {
        $script:SkillContent | Should -Match '(?si)\*\*Grounding Evidence\*\*' `
            -Because 'issue #763 D7 requires a durable **Grounding Evidence** block in the design session'
    }

    It 'stamps the HEAD sha in the evidence block' {
        $script:SkillContent | Should -Match '(?si)HEAD:' `
            -Because 'issue #763 D7 requires a HEAD sha stamp on the Grounding Evidence block at write time'
    }

    It 'includes the 60 KB payload guard' {
        $script:SkillContent | Should -Match '(?si)60 KB' `
            -Because 'issue #763 AC3/J3 requires a 60 KB guard at the evidence block write step'
    }

    It 'includes the fence/content-trust discipline clause' {
        $script:SkillContent | Should -Match '(?si)triple-backtick|skills/project-references/SKILL\.md' `
            -Because 'issue #763 J5 requires fence-safe rendering and a project-references anchor for cited content'
    }

    # --- Group 2: Ordering in agents/Solution-Designer.agent.md ---

    It 'places the grounding gate token between Stage 2 and Stage 3 in Solution-Designer.agent.md' {
        $script:AgentContent | Should -Match '(?s)Stage 2.+grounding gate.+Stage 3' `
            -Because 'issue #763 s2 requires the literal grounding gate token between Stage 2 and Stage 3 so the gate is enforced by the agent body'
    }

    # --- Group 3: Issue-Planner-lens backstop in skills/upstream-onboarding/SKILL.md ---

    It 'adds Missing grounding evidence trigger to the Issue-Planner lens concern table' {
        $script:OnboardContent | Should -Match '(?si)Missing grounding evidence' `
            -Because 'issue #763 s3 adds a 5th Issue-Planner-lens concern-trigger row keyed to the Grounding Evidence block absence'
    }

    It 'anchors the grounding evidence trigger to skills/design-exploration/SKILL.md' {
        $script:OnboardContent | Should -Match '(?si)Missing grounding evidence.{0,300}skills/design-exploration/SKILL\.md' `
            -Because 'issue #763 s3 requires the Issue-Planner-lens row to anchor to skills/design-exploration/SKILL.md'
    }
}
