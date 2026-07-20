#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Structural tests for the design grounding discipline shipped in issue #763,
    widened by issue #866 to also lock the grounding-evidence delivery-route
    persist contract.

.DESCRIPTION
    Locks the four-quadrant pre-challenge trace gate contract, plus the
    grounding-evidence delivery-route persist contract, across:
      - skills/design-exploration/SKILL.md   (section presence; canonical
        <!-- grounding-evidence --> template sentinel; the § 8 durable-payload
        and Grounding Discipline persist rules; D4 body-size compact-gate,
        D5 persist-time reconciliation, D6 pipe-escaping)
      - agents/Solution-Designer.agent.md    (gate ordering between Stage 2
        and Stage 3; Stage 4 persist enumeration; Completion Gate checklist)
      - skills/upstream-onboarding/SKILL.md  (Issue-Planner-lens backstop row;
        read-only consumer reference — not edited by issue #866)

    Issue #866's AC7 corpus-check test lives in its own test-file home, split
    out from this file; the "delivery route" group below covers only the
    nine persist-contract assertions enumerated in issue #866 plan step s1.
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
        $script:SkillContent | Should -Match '(?si)(?:path:line.{0,50}inference|inference.{0,50}path:line)' `
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
        $script:SkillContent | Should -Match '(?si)triple-backtick' `
            -Because 'issue #763 J5 requires fence-safe rendering for cited content'
        $script:SkillContent | Should -Match '(?si)skills/project-references/SKILL\.md' `
            -Because 'issue #763 J5 requires a project-references anchor for cited content'
    }

    # --- Group 2: Ordering in agents/Solution-Designer.agent.md ---

    It 'places the grounding gate token between Stage 2 and Stage 3 in Solution-Designer.agent.md' {
        $script:AgentContent | Should -Match '(?s)## Stage 2:.+\*\*grounding gate\*\*.+## Stage 3:' `
            -Because 'issue #763 s2 requires the grounding gate token anchored between the ## Stage 2 and ## Stage 3 headings, not just any "Stage 3" occurrence within the gate paragraph itself'
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

    # --- Group 4: Delivery route (issue #866 s1) ---

    It 'names the grounding-evidence sentinel comment in the canonical evidence-block template' {
        $script:SkillContent | Should -Match '(?s)<!--\s*grounding-evidence\s*-->' `
            -Because 'issue #866 s2 adds a <!-- grounding-evidence --> sentinel to the canonical template in design-exploration/SKILL.md; unlike the plan-side <!-- verification-evidence --> sentinel that .github/scripts/plan-tree-state-verification.ps1:77 already anchors on, this sentinel has no current runtime reader — it is forward-looking locate-infrastructure for a future consumer'
    }

    It 'lists the Grounding Evidence block in the § 8 durable design payload enumeration' {
        $script:SkillContent | Should -Match '(?s)### 8\. Prepare the Durable Design Payload.+\*\*Grounding Evidence\*\*.+## Grounding Discipline' `
            -Because 'issue #866 s2 requires the § 8 payload list in design-exploration/SKILL.md to name the Grounding Evidence block among the material the agent persists'
    }

    It 'places the Grounding Evidence block in the Stage 4 persist enumeration in Solution-Designer.agent.md' {
        $script:AgentContent | Should -Match '(?s)## Stage 4:.+\*\*Grounding Evidence\*\*.+## Completion Gate' `
            -Because 'issue #866 s2 requires the Stage 4 persist enumeration to name the Grounding Evidence block, section-anchored between ## Stage 4: and the next ## heading; a whole-file match is invalid because agents/Solution-Designer.agent.md:78 already contains the literal **Grounding Evidence** token in the Stage 2 grounding-gate sentence, which would make an unanchored assertion green before any edit'
    }

    It 'already carries the bold Grounding Evidence token on the producer, persist, and consumer surfaces' {
        $script:SkillContent | Should -Match '\*\*Grounding Evidence\*\*' `
            -Because 'the producer template in design-exploration/SKILL.md already carries the bold Grounding Evidence token in its existing durable-evidence-block section'
        $script:AgentContent | Should -Match '\*\*Grounding Evidence\*\*' `
            -Because 'agents/Solution-Designer.agent.md already carries the bold Grounding Evidence token at :78 in the Stage 2 grounding-gate sentence'
        $script:OnboardContent | Should -Match '\*\*Grounding Evidence\*\*' `
            -Because 'the consumer row at upstream-onboarding/SKILL.md:303 already carries the bold Grounding Evidence token'
    }

    It 'requires an escalation-note prose line for could-not-ground-escalate rows, and keeps the consumer clause-2 literal anchored' {
        $script:SkillContent | Should -Match '(?s)\*\*Escalation note.{0,20}\{artifact\}.{0,20}\*\*:.{0,40}\{reason\}' `
            -Because 'issue #866 s2 requires design-exploration/SKILL.md to mandate a **Escalation note — {artifact}**: {reason} prose line whenever a grounding row carries could-not-ground-escalate disposition'
        $script:OnboardContent | Should -Match '(?si)could-not-ground-escalate`? disposition with no accompanying escalation note in the design body' `
            -Because 'the consumer clause-2 literal at upstream-onboarding/SKILL.md:303 must remain present once design-exploration/SKILL.md adds the escalation-note rule'
    }

    It 'adds a Completion Gate checklist line naming the Grounding Evidence block, including escalation notes when applicable' {
        $script:AgentContent | Should -Match '(?s)## Completion Gate \(Mandatory\).+\[ \] \*\*Grounding Evidence\*\*.+escalation note.+## Boundaries' `
            -Because 'issue #866 s2 requires a Completion Gate checklist line in Solution-Designer.agent.md naming the Grounding Evidence block, including escalation notes when applicable, mirroring the existing checklist item pattern'
    }

    It 'defines the D4 body-size compact-gate rule with a mandatory compact-mode note and an overflow-floor halt' {
        $script:SkillContent | Should -Match '(?si)55,000\s*codepoints' `
            -Because 'issue #866 s2 D4 requires a roughly-55,000-codepoint compact-gate threshold in design-exploration/SKILL.md'
        $script:SkillContent | Should -Match '(?si)one row per artifact.{0,120}disposition.{0,120}inference digest' `
            -Because 'issue #866 s2 D4 compact form is one row per artifact with disposition and a one-line inference digest'
        $script:SkillContent | Should -Match '(?si)compact mode: full table was.{0,20}KB' `
            -Because 'issue #866 s2 D4 requires a mandatory "compact mode: full table was N KB" note'
        $script:SkillContent | Should -Match '(?si)escalation notes? (?:is|are) exempt from compaction' `
            -Because 'issue #866 s2 D4 exempts escalation notes from compaction'
        $script:SkillContent | Should -Match '(?si)overflow.floor' `
            -Because 'issue #866 s2 D4 requires an overflow-floor halt-and-surface rule for when the compact form plus notes would still exceed the cap'
    }

    It 'defines the D5 persist-time reconciliation rule for re-grounding and re-stamping HEAD' {
        $script:SkillContent | Should -Match '(?si)re-ground.{0,80}(?:Incorporate|grounded-conflict)' `
            -Because 'issue #866 s2 D5 requires re-grounding any artifact touched by an Incorporate or grounded-conflict revision'
        $script:SkillContent | Should -Match '(?si)re-stamp.{0,40}HEAD' `
            -Because 'issue #866 s2 D5 requires re-stamping HEAD when any re-grounding occurred at persist time'
        $script:SkillContent | Should -Match '(?si)original write-time stamp stands' `
            -Because 'issue #866 s2 D5 requires the original write-time HEAD stamp to stand when no re-grounding occurred'
    }

    It 'defines the D6 pipe-escaping rule for all table cells' {
        $script:SkillContent | Should -Match '(?si)escape.{0,20}literal.{0,10}\|.{0,20}\\\|.{0,60}(?:all table cells|every table cell)' `
            -Because 'issue #866 s2 D6 requires escaping literal | as \| in all table cells, not scoped to inference cells only'
    }
}
