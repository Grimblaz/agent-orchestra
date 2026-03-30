#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Contract tests for BDD structured scenario wording across agents.

.DESCRIPTION
    Locks the issue #223 BDD framework contract in:
      - .github/agents/Experience-Owner.agent.md
      - .github/agents/Issue-Planner.agent.md
      - .github/agents/Code-Conductor.agent.md
      - .github/agents/Code-Critic.agent.md

        Each agent file must describe the same BDD integration semantics:
            - Conditional G/W/T authoring when ## BDD Framework section is present
            - Scenario ID convention (S1, S2...) with ### SN heading pattern
            - Natural-language fallback when BDD not enabled
            - [auto]/[manual] classification (Issue-Planner)
            - Pre-flight coverage check and recovery path (Code-Conductor)
            - Per-scenario evidence mapping (Code-Critic)

        These tests lock the BDD contract for issue #223 going forward; update them
        only when the contract semantics intentionally change.
#>

Describe 'Experience-Owner BDD scenario contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ExperienceOwner = Join-Path $script:RepoRoot '.github\agents\Experience-Owner.agent.md'
        $script:Content = Get-Content -Path $script:ExperienceOwner -Raw

        $script:GwtConditionalPattern = '(?is)(## BDD Framework).{0,300}(G/W/T|Given.{0,10}When.{0,10}Then|structured scenario).{0,300}(natural.{0,30}language|fallback)'
        $script:ScenarioIdHeadingPattern = '(?is)(###\s+S\d+|###\s+SN|### S1|S\d+\s+—\s+\{title\}|SN\s+—\s+\{title\}).{0,200}(Type|Functional|Intent)'
        $script:BddSkillReferencePattern = 'bdd-scenarios'
        $script:CustomerLanguagePattern = '(?is)(customer.{0,30}(language|terms|vocabulary)|no (technical|jargon|implementation detail|code term)).{0,300}(G/W/T|Given|When|Then|scenario clause)'
    }

    It 'Experience-Owner activates G/W/T authoring when BDD Framework section present, with natural-language fallback' {
        $script:Content | Should -Match $script:GwtConditionalPattern -Because 'issue #223 requires Experience-Owner to detect ## BDD Framework and author structured G/W/T scenarios with a natural-language fallback when not enabled'
    }

    It 'Experience-Owner uses SN heading convention with Type tag' {
        $script:Content | Should -Match $script:ScenarioIdHeadingPattern -Because 'issue #223 requires Experience-Owner to use ### SN heading convention and include a Type tag in scenarios'
    }

    It 'Experience-Owner references bdd-scenarios skill' {
        $script:Content | Should -Match $script:BddSkillReferencePattern -Because 'issue #223 requires Experience-Owner to load and reference the bdd-scenarios skill for scenario authoring guidance'
    }

    It 'Experience-Owner specifies customer-language principle for G/W/T clauses' {
        $script:Content | Should -Match $script:CustomerLanguagePattern -Because 'issue #223 requires Experience-Owner to apply customer-facing language (no technical/implementation terms) in Given/When/Then clauses'
    }

    It 'instructs ## Scenarios H2 heading for issue body updates' {
        $script:Content | Should -Match '(?s)use\s+`## Scenarios`\s*\(H2\)' -Because 'issue #223 requires Experience-Owner to instruct using ## Scenarios (H2) as the section heading in the issue body for Code-Conductor pre-flight extraction'
    }
}

Describe 'Issue-Planner BDD classification contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:IssuePlanner = Join-Path $script:RepoRoot '.github\agents\Issue-Planner.agent.md'
        $script:IPContent = Get-Content -Path $script:IssuePlanner -Raw
    }

    It 'Issue-Planner classification rubric maps Functional+observable to [auto] and Intent+subjective to [manual]' {
        $script:IPContent | Should -Match '(?is)(Functional.{0,100}observable.{0,100}\[auto\]).{0,200}(Intent.{0,100}subjective.{0,100}\[manual\])' -Because 'issue #223 requires Issue-Planner to document a classification rubric table mapping Functional+observable to [auto] and Intent+subjective to [manual]'
    }

    It 'Issue-Planner extends CE GATE format with scenario IDs and classification tags when BDD enabled' {
        $script:IPContent | Should -Match '(?is)(## BDD Framework|BDD.{0,30}enabled|BDD.{0,30}active).{0,500}(SN|S\d+|scenario ID).{0,300}(\[auto\]|\[manual\])' -Because 'issue #223 requires Issue-Planner to include scenario IDs and classification tags in the CE GATE step when BDD is enabled'
    }

    It 'Issue-Planner documents Test-Writer reclassification of [auto]/[manual] during implementation' {
        $script:IPContent | Should -Match '(?is)(Test-Writer|test writer).{0,200}(reclassif|reclassify).{0,200}(auto.{0,20}manual|manual.{0,20}auto|\[auto\].{0,20}\[manual\])' -Because 'issue #223 requires Issue-Planner to document that Test-Writer may reclassify [auto]/[manual] scenarios during implementation'
    }

    It 'Issue-Planner references bdd-scenarios skill' {
        $script:IPContent | Should -Match 'bdd-scenarios' -Because 'issue #223 requires Issue-Planner to load and reference the bdd-scenarios skill'
    }
}

Describe 'Code-Conductor BDD CE Gate pre-flight contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:CodeConductor = Join-Path $script:RepoRoot '.github\agents\Code-Conductor.agent.md'
        $script:CCContent = Get-Content -Path $script:CodeConductor -Raw
    }

    It 'Code-Conductor CE Gate pre-flight reads scenario IDs from issue body using S\d+ pattern' {
        $script:CCContent | Should -Match '(?is)(pre-flight|preflight|pre flight).{0,400}(### S\\d\+|S\\d\+|scenario ID).{0,300}(issue body|## Scenarios)' -Because 'issue #223 requires Code-Conductor CE Gate pre-flight to read scenario IDs from the issue body using the ### S\d+ heading pattern'
    }

    It 'Code-Conductor CE Gate pre-flight recovery offers Re-exercise, Waive, and Abort options' {
        $script:CCContent | Should -Match '(?is)(Re-exercise missing scenario|re-exercise.{0,30}missing|re.{0,5}exercise.{0,50}missing).{0,300}(Waive with documented reason|waive.{0,20}documented).{0,300}(Abort CE Gate|abort.{0,20}CE Gate)' -Because 'issue #223 requires Code-Conductor CE Gate pre-flight to offer Re-exercise, Waive with documented reason, and Abort CE Gate recovery options'
    }

    It 'Code-Conductor CE Gate pre-flight has independent cycle budget from Track 1' {
        $script:CCContent | Should -Match '(?is)(pre-flight|preflight).{0,500}(independent.{0,30}(Track 1|track 1 budget)|separate.{0,30}budget)' -Because 'issue #223 requires Code-Conductor to document that the CE Gate pre-flight cycle budget is independent of the Track 1 budget'
    }

    It 'Code-Conductor PR body includes per-scenario coverage table with ID, Type, Class, Result, Evidence columns' {
        $script:CCContent | Should -Match '(?is)\|\s*ID\s*\|\s*Type\s*\|\s*Class\s*\|\s*Result\s*\|\s*Evidence\s*\|' -Because 'issue #223 requires Code-Conductor to include a per-scenario coverage table with ID, Type, Class, Result, and Evidence columns in the PR body'
    }
}

Describe 'Code-Critic BDD CE prosecution contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:CodeCritic = Join-Path $script:RepoRoot '.github\agents\Code-Critic.agent.md'
        $script:CriticContent = Get-Content -Path $script:CodeCritic -Raw
    }

    It 'Code-Critic evaluates each scenario individually when BDD scenario IDs present in evidence' {
        $script:CriticContent | Should -Match '(?is)(BDD.{0,30}scenario ID|scenario ID.{0,30}BDD|S\d+.{0,100}evidence|evidence.{0,100}S\d+).{0,300}(evaluate each|each scenario|individually)' -Because 'issue #223 requires Code-Critic to evaluate each scenario individually when BDD scenario IDs appear in evidence'
    }

    It 'Code-Critic includes scenario ID in finding references (e.g., S2: Intent — partial match)' {
        $script:CriticContent | Should -Match '(?is)(S\d+:\s*(Functional|Intent|Error|finding)|scenario ID.{0,200}finding reference|finding reference.{0,200}scenario ID)' -Because 'issue #223 requires Code-Critic to include scenario ID in finding references such as S2: Intent — partial match'
    }

    It 'Code-Critic applies all three lenses per BDD scenario evaluation' {
        $script:CriticContent | Should -Match '(?is)(BDD.{0,400}(three lenses|3 lenses|Functional.{0,30}Intent.{0,30}Error)|(three lenses|3 lenses).{0,400}BDD)' -Because 'issue #223 requires Code-Critic to apply all three lenses (Functional, Intent, Error States) when evaluating each BDD scenario'
    }

    It 'Code-Critic per-scenario evaluation is conditional on BDD scenario IDs present in evidence' {
        $script:CriticContent | Should -Match '(?is)(when.{0,60}(BDD.{0,30}scenario ID|scenario ID.{0,30}BDD|S\d+.{0,30}ID).{0,100}(present|found|available|contain)|BDD.{0,100}conditional)' -Because 'issue #223 requires Code-Critic to specify that per-scenario evaluation is conditional on BDD scenario IDs being present in evidence'
    }
}
